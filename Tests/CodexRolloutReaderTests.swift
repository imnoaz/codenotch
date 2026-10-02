import XCTest
@testable import Codenotch

/// The reader keeps its place in the rollout between ticks; what matters is
/// that it says what the bounded scan would on the first read, and what
/// reading the whole file would for every line added after it.
final class CodexRolloutReaderTests: XCTestCase {
    private let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    private let complete = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    private let aborted = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    private let noise = #"{"type":"response_item","payload":{"type":"message","text":"task_complete"}}"#

    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodenotchRolloutReader-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testAGrownFileFoldsInOnlyTheNewLines() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(noise + "\n" + complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
        try append(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
    }

    func testAnUnchangedFileGivesTheSameAnswer() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n" + complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testALineStillBeingWrittenCountsButIsReadAgain() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n" + #"{"type":"event_msg","payload":{"type":"task_comp"#, to: url)
        XCTAssertEqual(reader.state(from: url), .busy, "half a line is not an event")
        try append(#"lete"}}"# + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success, "the finished line must not have been skipped")
    }

    func testAnUnterminatedFinalLineIsEvaluated() throws {
        let url = file()
        try write(started + "\n" + complete, to: url)
        XCTAssertEqual(CodexRolloutReader().state(from: url), .success)
    }

    func testAbortClearsTheState() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(aborted + "\n", to: url)
        XCTAssertNil(reader.state(from: url))
    }

    func testAShrunkOrReplacedFileIsReadFromTheStart() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n" + noise + "\n" + noise + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try write(complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)

        let other = file()
        try write(started + "\n", to: other)
        XCTAssertEqual(reader.state(from: other), .busy)
    }

    func testAFileReplacedInPlaceIsReadFromTheStartEvenIfItIsNoSmaller() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)

        // Moved aside rather than deleted, so the new file cannot be handed
        // the old one's inode.
        let aside = file()
        try FileManager.default.moveItem(at: url, to: aside)
        try write(complete + "\n" + noise + "\n" + noise + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testAFileThatGoesMissingForgetsWhatWasRead() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(reader.state(from: url))
        try write(complete + "\n" + noise + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testChatterThatMentionsAMarkerIsNotAnEvent() throws {
        let url = file()
        let lookalike = #"{"type":"response_item","payload":{"type":"task_complete"}}"#
        try write(started + "\n" + lookalike + "\n", to: url)
        XCTAssertEqual(CodexRolloutReader().state(from: url), .busy)
    }

    func testChatterThatQuotesAMarkerInItsTextIsNotAnEvent() throws {
        let url = file()
        try write(started + "\n" + noise + "\n", to: url)
        XCTAssertEqual(CodexRolloutReader().state(from: url), .busy)
    }

    func testAnEventSpelledWithAnEscapeIsStillAnEvent() throws {
        let url = file()
        let reader = CodexRolloutReader()
        let backslash = String(UnicodeScalar(0x5C))
        let escaped = #"{"type":"event_msg","payload":{"type":"task"# + backslash + #"u005fcomplete"}}"#
        XCTAssertFalse(escaped.contains("task_complete"))
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(escaped + "\n", to: url)
        XCTAssertEqual(CodexRolloutActivity.state(from: url), .success)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testOnlyLinesThatCouldSpellAnEventAreParsed() {
        let backslash = String(UnicodeScalar(0x5C))
        let output = #"{"type":"response_item","payload":{"output":"line one"# + backslash + "n"
            + backslash + #""quoted"# + backslash + #"""}}"#
        let escaped = #"{"type":"event_msg","payload":{"type":"task"# + backslash + #"u005fcomplete"}}"#
        var parsed: [String] = []
        func lifecycle(_ line: String) -> CodexRolloutActivity.Lifecycle? {
            CodexRolloutActivity.Lifecycle(line: Data(line.utf8)) {
                parsed.append(line)
                return try? JSONSerialization.jsonObject(with: $0)
            }
        }
        XCTAssertNil(lifecycle(output))
        XCTAssertEqual(parsed, [], "ordinary escapes must not send a line to the parser")
        XCTAssertEqual(lifecycle(escaped), .complete)
        XCTAssertEqual(lifecycle(complete), .complete)
        XCTAssertEqual(parsed, [escaped, complete])
    }

    func testAnUnterminatedTailThatTurnsOutBrokenIsNotRemembered() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n" + complete, to: url)
        XCTAssertEqual(reader.state(from: url), .success)
        try append("x\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy, "the finished line does not parse")
    }

    func testALineLongerThanTheTailWindowIsReadOnceItIsFinished() throws {
        let url = file()
        let reader = CodexRolloutReader()
        let head = #"{"type":"event_msg","payload":{"type":"task_complete"},"pad":""#
        try write(started + "\n" + head + String(repeating: "x", count: 300_000), to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(#""}"# + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testATruncatedAndRewrittenFileIsReadFromTheStart() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(complete + "\n" + String(repeating: " ", count: 1000), to: url)
        XCTAssertEqual(reader.state(from: url), .success)

        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(String(repeating: " ", count: 200).utf8))
        try handle.close()
        XCTAssertNil(reader.state(from: url))
    }

    /// Shorter than it was, still longer than what was read, and changed only
    /// further back than the bytes the reader compares.
    func testAFileRewrittenShorterIsReadFromTheStart() throws {
        let url = file()
        let reader = CodexRolloutReader()
        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started"},"p":"x"}"# + "\n"
        let completeLine = #"{"type":"event_msg","payload":{"type":"task_complete"},"p":""}"# + "\n"
        let tail = filler(1000)
        try write(completeLine + tail + String(repeating: " ", count: 1000), to: url)
        XCTAssertEqual(reader.state(from: url), .success)

        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((startedLine + tail + String(repeating: " ", count: 200)).utf8))
        try handle.close()
        XCTAssertEqual(reader.state(from: url), .busy)
    }

    func testAFileOverwrittenInPlaceWithMoreBytesIsReadFromTheStart() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)

        let rewrite = started + "\n" + filler(111)
        XCTAssertEqual(rewrite.utf8.count, 166)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(rewrite.utf8))
        try handle.close()
        XCTAssertEqual(reader.state(from: url), .busy)
    }

    /// Same size, same inode, only the modification time moved, and the
    /// changed bytes lie further back than anything else the reader compares.
    func testAFileRewrittenAtTheSameSizeIsReadFromTheStart() throws {
        let url = file()
        let reader = CodexRolloutReader()
        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started"},"p":"x"}"# + "\n"
        let completeLine = #"{"type":"event_msg","payload":{"type":"task_complete"},"p":""}"# + "\n"
        let tail = filler(1000)
        try write(startedLine + tail, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(reader.state(from: url), .busy)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64

        try write(completeLine + tail, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64,
                       inode, "the file must have been rewritten in place")
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testOneReadIsBoundedAndTheRestFollowsOnTheNext() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(String(repeating: filler(100 * 1024), count: 11) + complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy, "more than one read's worth was added")
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testALineLongerThanOneReadIsSkippedAndWhatFollowsIsRead() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        let overlong = #"{"type":"event_msg","payload":{"type":"task_complete"},"pad":""#
            + String(repeating: "x", count: 3 * 1024 * 1024 / 2) + #""}"# + "\n"
        try append(overlong + complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        XCTAssertEqual(reader.state(from: url), .success)
        try append(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
    }

    func testTheCacheKeepsReadingWhileTheReaderIsBehind() throws {
        let url = file()
        let cache = CodexStoreCache()
        try write(started + "\n", to: url)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .busy)
        try append(String(repeating: filler(100 * 1024), count: 11) + complete + "\n", to: url)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .busy)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .success,
                       "the file has not changed, but the reader had not finished it")
    }

    func testTheCacheNoticesAFileReplacedAtTheSameSizeAndTime() throws {
        let url = file()
        let cache = CodexStoreCache()
        let startedLine = #"{"type":"event_msg","payload":{"type":"task_started"},"p":"x"}"# + "\n"
        let completeLine = #"{"type":"event_msg","payload":{"type":"task_complete"},"p":""}"# + "\n"
        let stamp = Date(timeIntervalSinceNow: -60)
        try write(startedLine, to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .busy)

        let aside = file()
        try FileManager.default.moveItem(at: url, to: aside)
        try write(completeLine, to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        XCTAssertEqual(cache.rolloutState(of: url, keeping: [url.path]), .success)
    }

    /// A line of `bytes` that parses but is no lifecycle event.
    private func filler(_ bytes: Int) -> String {
        #"{"pad":""# + String(repeating: "x", count: bytes - 11) + #""}"# + "\n"
    }

    func testTheFirstReadOfALargeFileIsBoundedAndLaterLinesAreFoldedIn() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(complete + "\n" + filler(4 * 256 * 1024 + 100), to: url)
        XCTAssertNil(reader.state(from: url), "an event beyond the bounded scan is not read on the first pass")
        try append(started + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(complete + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testALargeFileWithAHalfWrittenTailResumesAtTheTail() throws {
        let url = file()
        let reader = CodexRolloutReader()
        try write(filler(300 * 1024) + started + "\n" + #"{"type":"event_msg","payload":{"type":"task_comp"#, to: url)
        XCTAssertEqual(reader.state(from: url), .busy)
        try append(#"lete"}}"# + "\n", to: url)
        XCTAssertEqual(reader.state(from: url), .success)
    }

    func testAMissingFileReadsAsNothing() {
        XCTAssertNil(CodexRolloutReader().state(from: file()))
    }
}
