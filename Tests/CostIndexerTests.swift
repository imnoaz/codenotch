import XCTest
import SQLite3
@testable import Codenotch

final class CostIndexerTests: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostIndexerTests-\(UUID().uuidString)", isDirectory: true)
        // The real roots live under dot directories (~/.claude/projects, ~/.codex/sessions).
        root = base.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    private func claudeLine(_ request: String, output: Int = 5, session: String = "s1") -> String {
        #"{"type":"assistant","cwd":"/nonexistent/proj","sessionId":"\#(session)","timestamp":"2026-01-01T00:00:00.000Z","requestId":"\#(request)","version":"1","message":{"model":"claude-x","usage":{"input_tokens":10,"output_tokens":\#(output)}}}"#
            + "\n"
    }

    private func userLine() -> String {
        #"{"type":"user","cwd":"/nonexistent/proj","sessionId":"s1","timestamp":"2026-01-01T00:00:00.000Z"}"# + "\n"
    }

    private func makeStore(_ name: String = "db") -> CostStore {
        CostStore(url: base.appendingPathComponent("\(name).sqlite"))!
    }

    private func makeIndexer(_ store: CostStore, format: CostIndexer.Format = .claude) -> CostIndexer {
        CostIndexer(store: store, root: root, format: format)!
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    /// The spelling FSEvents reports: symlinks resolved (/var → /private/var).
    private func eventPath(_ url: URL) -> String {
        guard let r = realpath(url.path, nil) else { return url.path }
        defer { free(r) }
        return String(cString: r)
    }

    private struct Dump: Equatable {
        var events: [String]
        var cursors: [String]
        var errors: Int
    }

    private func dump(_ store: CostStore) -> Dump {
        store.queue.sync {
            func rows(_ sql: String, _ columns: Int32) -> [String] {
                guard let st = store.prepare(sql) else { return [] }
                defer { sqlite3_finalize(st) }
                var out: [String] = []
                while sqlite3_step(st) == SQLITE_ROW {
                    out.append((0..<columns).map { store.text(st, $0) ?? "nil" }.joined(separator: "|"))
                }
                return out
            }
            let events = rows("""
                SELECT dedupe_key, ts, session_id, project, cwd, branch, model, input, output, cache_read, cache_write, cc_version
                FROM usage_event ORDER BY dedupe_key
                """, 12)
            let cursors = rows("SELECT path, inode, size, offset, mtime FROM file_cursor ORDER BY path", 5)
            let errors = Int(rows("SELECT COUNT(*) FROM parse_error", 1).first ?? "0") ?? 0
            return Dump(events: events, cursors: cursors, errors: errors)
        }
    }

    private func outputs(_ store: CostStore) -> [String: Int] {
        var out: [String: Int] = [:]
        for row in dump(store).events {
            let f = row.split(separator: "|", omittingEmptySubsequences: false)
            out[String(f[0])] = Int(f[8])
        }
        return out
    }

    private func cursorOffset(_ store: CostStore, _ url: URL) -> Int? {
        let key = eventPath(url)
        for row in dump(store).cursors {
            let f = row.split(separator: "|", omittingEmptySubsequences: false)
            if String(f[0]) == key { return Int(f[3]) }
        }
        return nil
    }

    // MARK: (a) append

    func testAppendIsIndexedIncrementally() throws {
        let store = makeStore()
        let url = try write("p/a.jsonl", claudeLine("r1"))
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        XCTAssertEqual(outputs(store), ["r:r1": 5])

        let before = indexer.snapshotCounters.parsedLines
        let partial = String(claudeLine("r3").dropLast(20))
        try append(url, claudeLine("r2") + partial)
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(outputs(store), ["r:r1": 5, "r:r2": 5])
        XCTAssertEqual(indexer.snapshotCounters.parsedLines - before, 1, "only the appended complete line is parsed")
        XCTAssertEqual(cursorOffset(store, url), (claudeLine("r1") + claudeLine("r2")).utf8.count)

        try append(url, String(claudeLine("r3").suffix(20)))
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(outputs(store), ["r:r1": 5, "r:r2": 5, "r:r3": 5])
    }

    // MARK: (b) new file

    func testNewFileInNewFolderIsIndexed() throws {
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        XCTAssertEqual(dump(store).events.count, 0)

        var changes = 0
        indexer.onChange = { changes += 1 }
        let url = try write("new-project/b.jsonl", userLine() + claudeLine("r1"))
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(outputs(store), ["r:r1": 5])
        XCTAssertEqual(changes, 1)
    }

    // MARK: (c) delete

    func testDeletedFileKeepsItsRowsAndCursor() throws {
        let store = makeStore()
        let url = try write("p/c.jsonl", claudeLine("r1"))
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let indexed = dump(store)

        var changes = 0
        indexer.onChange = { changes += 1 }
        let path = eventPath(url)
        try FileManager.default.removeItem(at: url)
        indexer.indexChangedAndWait([path])
        indexer.scanAndWait()
        XCTAssertEqual(dump(store), indexed)
        XCTAssertEqual(changes, 0)
    }

    // MARK: (d) shrink / replace

    func testReplacedFileIsReadFromTheStart() throws {
        let store = makeStore()
        let url = try write("p/d.jsonl", claudeLine("r1") + claudeLine("r2"))
        let indexer = makeIndexer(store)
        indexer.scanAndWait()

        // A new inode with fewer bytes than the cursor: re-read from offset 0.
        let replacement = base.appendingPathComponent("replacement.jsonl")
        try Data((claudeLine("r1", output: 9)).utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(outputs(store), ["r:r1": 9, "r:r2": 5])
        XCTAssertEqual(cursorOffset(store, url), claudeLine("r1", output: 9).utf8.count)
    }

    func testTruncatedFileIsReadFromTheStart() throws {
        let store = makeStore()
        let url = try write("p/t.jsonl", claudeLine("r1") + claudeLine("r2"))
        let indexer = makeIndexer(store)
        indexer.scanAndWait()

        // Same inode, smaller than the stored offset.
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data(claudeLine("r4").utf8))
        try h.close()
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(outputs(store), ["r:r1": 5, "r:r2": 5, "r:r4": 5])
        XCTAssertEqual(cursorOffset(store, url), claudeLine("r4").utf8.count)
    }

    // MARK: (e) incremental == full scan

    func testIncrementalResultEqualsAFreshFullScan() throws {
        let live = makeStore("live")
        let indexer = makeIndexer(live)
        let a = try write("p1/a.jsonl", claudeLine("a1"))
        indexer.scanAndWait()

        let b = try write("p2/b.jsonl", userLine() + claudeLine("b1", session: "s2"))
        try append(a, claudeLine("a2") + "{\"type\":\"assistant\" broken\n")
        indexer.indexChangedAndWait([eventPath(a), eventPath(b)])
        try append(b, claudeLine("b1", output: 50, session: "s2") + String(claudeLine("b2").prefix(30)))
        let c = try write("p1/sub/c.jsonl", claudeLine("c1", session: "s3"))
        indexer.indexChangedAndWait([eventPath(b), eventPath(c), eventPath(a)])

        let fresh = makeStore("fresh")
        makeIndexer(fresh).scanAndWait()
        XCTAssertEqual(dump(live), dump(fresh))
        XCTAssertEqual(outputs(live), ["r:a1": 5, "r:a2": 5, "r:b1": 50, "r:c1": 5])
        XCTAssertEqual(dump(live).errors, 1)
    }

    func testCodexAppendKeepsTheFileContext() throws {
        let store = makeStore()
        let head = #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/nonexistent/codex"}}"# + "\n"
            + #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"turn_context","payload":{"type":"turn_context","cwd":"/nonexistent/codex","model":"gpt-5"}}"# + "\n"
        func tick(_ s: Int) -> String {
            #"{"timestamp":"2026-01-01T00:00:0\#(s).000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}}}"# + "\n"
        }
        let url = try write("2026/01/01/rollout-x.jsonl", head + tick(1))
        let indexer = makeIndexer(store, format: .codex)
        indexer.scanAndWait()
        try append(url, tick(2))
        indexer.indexChangedAndWait([eventPath(url)])

        let fresh = makeStore("fresh")
        makeIndexer(fresh, format: .codex).scanAndWait()
        XCTAssertEqual(dump(store).events, dump(fresh).events)
        XCTAssertEqual(dump(store).events.count, 2)
        XCTAssertTrue(dump(store).events.allSatisfy { $0.contains("|sess-1|") && $0.contains("|gpt-5|") })

        // A new indexer has no per-file context and primes the session from the head line.
        try append(url, tick(3))
        makeIndexer(store, format: .codex).indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(dump(store).events.count, 3)
        XCTAssertTrue(dump(store).events.allSatisfy { $0.contains("|sess-1|") })
    }

    // MARK: (f) repeated notifications without changes

    func testUnchangedNotificationsDoNotReparse() throws {
        let store = makeStore()
        let url = try write("p/f.jsonl", claudeLine("r1") + claudeLine("r2"))
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let parsed = indexer.snapshotCounters.parsedLines
        let indexed = dump(store)

        var changes = 0
        indexer.onChange = { changes += 1 }
        for _ in 0..<5 { indexer.indexChangedAndWait([eventPath(url)]) }
        indexer.scanAndWait()
        XCTAssertEqual(indexer.snapshotCounters.parsedLines, parsed)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(dump(store), indexed)
    }

    // MARK: (g) startup backfill

    func testStartupIngestsExistingFilesInOnePass() throws {
        for p in 0..<10 {
            for f in 0..<20 { try write("p\(p)/f\(f).jsonl", userLine() + claudeLine("r\(p)-\(f)")) }
        }
        let store = makeStore()
        let indexer = makeIndexer(store)
        var changes = 0
        indexer.onChange = { changes += 1 }
        indexer.scanAndWait()
        XCTAssertEqual(dump(store).events.count, 200)
        XCTAssertEqual(dump(store).cursors.count, 200)
        XCTAssertEqual(changes, 1)

        let parsed = indexer.snapshotCounters.parsedLines
        indexer.scanAndWait()
        XCTAssertEqual(indexer.snapshotCounters.parsedLines, parsed)
        XCTAssertEqual(changes, 1)
    }

    // MARK: (h) identical bytes rewritten

    func testSameBytesRewrittenInPlaceIsNotReparsed() throws {
        let store = makeStore()
        let text = claudeLine("r1") + claudeLine("r2")
        let url = try write("p/h.jsonl", text)
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let indexed = dump(store)
        let parsed = indexer.snapshotCounters.parsedLines

        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: url.path)
        indexer.indexChangedAndWait([eventPath(url)])
        indexer.scanAndWait()
        XCTAssertEqual(indexer.snapshotCounters.parsedLines, parsed)
        XCTAssertEqual(dump(store), indexed, "same inode and size: the cursor (and its stored mtime) stay as they were")
    }

    func testSameBytesWrittenAsANewInodeIsReparsedWithoutNewRows() throws {
        let store = makeStore()
        let text = claudeLine("r1") + claudeLine("r2")
        let url = try write("p/h.jsonl", text)
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let indexed = dump(store)
        let parsed = indexer.snapshotCounters.parsedLines

        var changes = 0
        indexer.onChange = { changes += 1 }
        try Data(text.utf8).write(to: url, options: .atomic)
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(indexer.snapshotCounters.parsedLines - parsed, 2)
        XCTAssertEqual(dump(store).events, indexed.events)
        XCTAssertNotEqual(dump(store).cursors, indexed.cursors, "the cursor follows the new inode")
        XCTAssertEqual(changes, 1, "re-read rows count as new events, as before")
    }

    // MARK: Event-driven processing

    func testOneEventExaminesOnlyThatFile() throws {
        var urls: [URL] = []
        for p in 0..<5 {
            for f in 0..<10 { urls.append(try write("p\(p)/f\(f).jsonl", claudeLine("r\(p)-\(f)"))) }
        }
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let before = indexer.snapshotCounters
        XCTAssertEqual(before.examinedFiles, 50)

        try append(urls[17], claudeLine("extra"))
        indexer.indexChangedAndWait([eventPath(urls[17])])
        let after = indexer.snapshotCounters
        XCTAssertEqual(after.examinedFiles - before.examinedFiles, 1)
        XCTAssertEqual(after.fullScans, before.fullScans)
        XCTAssertEqual(after.parsedLines - before.parsedLines, 1)
        XCTAssertEqual(dump(store).events.count, 51)
    }

    func testEventPathsUseTheSameKeysAsTheFullScan() throws {
        let url = try write("p/k.jsonl", claudeLine("r1"))
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        XCTAssertEqual(dump(store).cursors.count, 1)

        try append(url, claudeLine("r2"))
        indexer.indexChangedAndWait([eventPath(url)])
        XCTAssertEqual(dump(store).cursors.count, 1)
        XCTAssertEqual(store.stats().files, 1)
        XCTAssertEqual(cursorOffset(store, url), (claudeLine("r1") + claudeLine("r2")).utf8.count)
    }

    func testEventsForHiddenOrForeignPathsAreIgnoredLikeTheFullScan() throws {
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let hidden = try write(".cache/x.jsonl", claudeLine("hidden"))
        let hiddenFolder = try write("p/.tmp/y.jsonl", claudeLine("hidden2"))
        let other = try write("p/notes.txt", claudeLine("txt"))
        let outside = base.appendingPathComponent("outside.jsonl")
        try Data(claudeLine("outside").utf8).write(to: outside)
        indexer.indexChangedAndWait([hidden, hiddenFolder, other, outside].map(eventPath))
        XCTAssertEqual(dump(store).events.count, 0)
        XCTAssertEqual(indexer.snapshotCounters.examinedFiles, 0)
        indexer.scanAndWait()
        XCTAssertEqual(dump(store).events.count, 0)
    }

    func testDroppedEventFlagsFallBackToAFullScan() throws {
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let missed = try write("p/missed.jsonl", claudeLine("m1"))
        _ = missed

        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged] {
            let scans = indexer.snapshotCounters.fullScans
            indexer.receiveAndWait([(eventPath(root), FSEventStreamEventFlags(flag))])
            XCTAssertEqual(indexer.snapshotCounters.fullScans, scans + 1, "flag \(flag)")
        }
        XCTAssertEqual(outputs(store), ["r:m1": 5])
    }

    func testDirectoryMovedIntoTheTreeTriggersAFullScan() throws {
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let outside = base.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(claudeLine("moved").utf8).write(to: outside.appendingPathComponent("m.jsonl"))
        let inside = root.appendingPathComponent("restored")
        try FileManager.default.moveItem(at: outside, to: inside)

        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        indexer.receiveAndWait([(eventPath(inside), flags)])
        XCTAssertEqual(outputs(store), ["r:moved": 5])
        XCTAssertEqual(indexer.snapshotCounters.fullScans, 2)
    }

    func testARenamedFileOrAPlainDirectoryEventDoesNotTriggerAFullScan() throws {
        let store = makeStore()
        let indexer = makeIndexer(store)
        indexer.scanAndWait()
        let scans = indexer.snapshotCounters.fullScans

        let outside = base.appendingPathComponent("r.jsonl")
        try Data(claudeLine("renamed").utf8).write(to: outside)
        let inside = root.appendingPathComponent("p/r.jsonl")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: outside, to: inside)
        indexer.receiveAndWait([(eventPath(inside), FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))])
        XCTAssertEqual(indexer.snapshotCounters.fullScans, scans, "a renamed file is indexed on its own")
        XCTAssertEqual(outputs(store), ["r:renamed": 5])

        indexer.receiveAndWait([(eventPath(inside.deletingLastPathComponent()),
                                 FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir))])
        XCTAssertEqual(indexer.snapshotCounters.fullScans, scans, "a directory event that is not a rename")
    }

    func testTheSafetyNetTimerRunsFullScansAtItsInterval() throws {
        XCTAssertEqual(CostIndexer.safetyNetScanInterval, 600)
        let store = makeStore()
        let indexer = try XCTUnwrap(CostIndexer(store: store, root: root, safetyNetInterval: 0.2))
        try write("p/n.jsonl", claudeLine("r1"))
        indexer.startSafetyNet()

        let deadline = Date().addingTimeInterval(10)
        while indexer.snapshotCounters.fullScans < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThanOrEqual(indexer.snapshotCounters.fullScans, 2)
        XCTAssertEqual(outputs(store), ["r:r1": 5])
    }

    // MARK: Codex robustness

    private func codexMeta(_ session: String) -> String {
        #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(session)","cwd":"/nonexistent/codex"}}"# + "\n"
    }

    private func codexTick(_ second: Int, input: String = "100", output: String = "7") -> String {
        #"{"timestamp":"2026-01-01T00:00:0\#(second).000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":40,"output_tokens":\#(output)}}}}"# + "\n"
    }

    func testAReplacedCodexFileDoesNotInheritTheOldFilesModel() throws {
        let store = makeStore()
        let modelLine = #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"turn_context","payload":{"type":"turn_context","cwd":"/nonexistent/codex","model":"gpt-5"}}"# + "\n"
        let url = try write("2026/01/01/rollout-r.jsonl", codexMeta("old") + modelLine + codexTick(1))
        let indexer = makeIndexer(store, format: .codex)
        indexer.scanAndWait()
        XCTAssertTrue(dump(store).events.allSatisfy { $0.contains("|gpt-5|") })

        let replacementText = codexMeta("new") + codexTick(2)
        let replacement = base.appendingPathComponent("replacement.jsonl")
        try Data(replacementText.utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        indexer.indexChangedAndWait([eventPath(url)])

        let fresh = makeStore("fresh")
        try FileManager.default.removeItem(at: root)
        try write("2026/01/01/rollout-r.jsonl", replacementText)
        makeIndexer(fresh, format: .codex).scanAndWait()

        let newRows = dump(store).events.filter { $0.hasPrefix("c:new:") }
        XCTAssertEqual(newRows.count, 1)
        XCTAssertTrue(newRows.allSatisfy { $0.contains("|codex|") }, "\(newRows)")
        XCTAssertEqual(newRows, dump(fresh).events)
    }

    func testOutOfRangeCodexTokenCountsAreSkippedWithoutCrashing() throws {
        let store = makeStore()
        let text = codexMeta("big")
            + codexTick(1, input: "9223372036854775807", output: "1")
            + codexTick(2, input: "1e19", output: "1")
            + codexTick(3, input: "-5", output: "1")
            + codexTick(4)
        try write("2026/01/01/rollout-big.jsonl", text)
        makeIndexer(store, format: .codex).scanAndWait()

        let clean = makeStore("clean")
        try FileManager.default.removeItem(at: root)
        try write("2026/01/01/rollout-big.jsonl", codexMeta("big") + codexTick(4))
        makeIndexer(clean, format: .codex).scanAndWait()

        XCTAssertEqual(dump(store).events, dump(clean).events)
        XCTAssertEqual(dump(store).events.count, 1)
        XCTAssertTrue(dump(store).events[0].contains("|60|7|40|"), dump(store).events[0])
        XCTAssertEqual(dump(store).errors, 1, "one parse_error row per pass over the file")
    }

    func testFileStatMatchesTheAttributesEarlierReleasesStored() throws {
        let url = try write("p/s.jsonl", claudeLine("r1"))
        let s = try XCTUnwrap(CostIndexer.FileStat(path: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(s.inode, attrs[.systemFileNumber] as? Int)
        XCTAssertEqual(s.size, attrs[.size] as? Int)
        XCTAssertEqual(s.mtime, (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1, accuracy: 1e-6)
        XCTAssertNil(CostIndexer.FileStat(path: url.path + ".missing"))
    }

    /// The real wiring: FSEvents → collected paths → indexFile, without a second full pass.
    func testFSEventsDeliverAnAppendWithoutAFullScan() throws {
        let url = try write("p/live.jsonl", claudeLine("r1"))
        let store = makeStore()
        let indexer = makeIndexer(store)
        let changed = expectation(description: "onChange after the append")
        changed.assertForOverFulfill = false
        indexer.start()
        indexer.scanAndWait()   // the start() pass has run once this returns
        XCTAssertEqual(outputs(store), ["r:r1": 5])
        let scans = indexer.snapshotCounters.fullScans
        Thread.sleep(forTimeInterval: 0.5)   // let the stream settle before writing

        indexer.onChange = { changed.fulfill() }
        try append(url, claudeLine("r2"))
        wait(for: [changed], timeout: 15)
        XCTAssertEqual(outputs(store), ["r:r1": 5, "r:r2": 5])
        XCTAssertEqual(indexer.snapshotCounters.fullScans, scans, "the append arrived through the event path")
    }
}
