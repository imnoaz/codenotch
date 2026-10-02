import Foundation
import CoreServices

/// Reads Claude Code's session transcripts and extracts *only* token counts.
///
/// What it reads, per record, and nothing else:
///   timestamp, cwd, gitBranch, sessionId, requestId, version,
///   message.model, message.usage.{input,output,cache_read,cache_creation}_tokens
///
/// It never touches `message.content`, `toolUseResult`, `attachment` records, or
/// the `tool-results/` and `subagents/` sibling directories. Transcripts can hold
/// secrets an agent read from a project; this feature must never be a way for them
/// to leave the machine — and nothing here is ever sent anywhere.
///
/// Reading is incremental: each file's byte offset is stored, so later passes only
/// parse what was appended. A trailing partial line (Claude Code mid-write) is left
/// unconsumed until its newline arrives.
final class CostIndexer {
    /// Which CLI wrote the transcripts under `root`.
    enum Format { case claude, codex }

    private let store: CostStore
    private let root: URL
    private let format: Format
    /// Codex rollouts carry session id, cwd and model in earlier lines than the
    /// token counts; remember them per file across incremental reads.
    private var codexContext: [String: (sessionId: String, cwd: String, model: String)] = [:]
    private let queue = DispatchQueue(label: "com.vinz.codenotch.costs.indexer", qos: .utility)
    private var stream: FSEventStreamRef?
    private var gitRootCache: [String: String] = [:]
    private var scanScheduled = false

    /// FSEvents can drop or coalesce events (and a whole directory moved into the
    /// tree reports only the directory), so a full pass still runs this often.
    static let safetyNetScanInterval: TimeInterval = 600
    private let safetyNetInterval: TimeInterval
    private var safetyNet: DispatchSourceTimer?
    private var pendingPaths: Set<String> = []
    private var pendingFullScan = false
    /// Mirror of the store's `file_cursor` table, loaded once; every commit
    /// updates both. Queue-confined.
    private var cursors: [String: CostStore.FileCursor]?
    /// FSEvents reports resolved paths; so does the directory enumerator, which
    /// makes both spell a file the same way in `file_cursor`.
    private lazy var resolvedRoot: String = {
        guard let r = realpath(root.path, nil) else { return root.path }
        defer { free(r) }
        return String(cString: r)
    }()

    private var counters = Counters()
    struct Counters { var parsedLines = 0, examinedFiles = 0, fullScans = 0 }

    /// Called on the indexer queue after a pass that changed something.
    var onChange: (() -> Void)?

    init?(store: CostStore, root: URL, format: Format = .claude,
          safetyNetInterval: TimeInterval = CostIndexer.safetyNetScanInterval) {
        self.store = store
        self.root = root
        self.format = format
        self.safetyNetInterval = safetyNetInterval
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    }

    deinit { stopWatching() }

    // MARK: Scanning

    /// Watching starts first so a write landing during the initial pass is not
    /// left to the safety net.
    func start() {
        startWatching()
        scan()
    }

    func scan() {
        queue.async { [weak self] in self?.performScan() }
    }

    func scanAndWait() { queue.sync { performScan() } }

    /// Feeds `paths` as FSEvents would report them (unflagged) and drains at once.
    func indexChangedAndWait(_ paths: [String]) {
        receiveAndWait(paths.map { ($0, FSEventStreamEventFlags(kFSEventStreamEventFlagNone)) })
    }

    func receiveAndWait(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        queue.sync {
            for e in events { note(path: e.path, flags: e.flags) }
            drainPending()
        }
    }

    var snapshotCounters: Counters { queue.sync { counters } }

    private func performScan() {
        counters.fullScans += 1
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
                                                     options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, stat: FileStat)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let s = FileStat(path: url.path) else { continue }
            files.append((url, s))
        }
        index(files)
    }

    private func indexPending(_ paths: Set<String>) {
        var files: [(url: URL, stat: FileStat)] = []
        for path in paths where isIndexable(eventPath: path) {
            guard let s = FileStat(path: path) else { continue }   // deleted or moved away
            files.append((URL(fileURLWithPath: path), s))
        }
        index(files)
    }

    private func index(_ files: [(url: URL, stat: FileStat)]) {
        // Newest first: the current period becomes correct before the backfill finishes.
        let ordered = files.sorted { $0.stat.mtime > $1.stat.mtime }
        var changed = false
        for f in ordered where indexFile(f.url, f.stat) { changed = true }
        if changed { onChange?() }
    }

    /// Mirrors the full scan's filter: `.jsonl` under the root, no hidden component
    /// below the root (the root itself sits under `~/.claude` or `~/.codex`).
    private func isIndexable(eventPath path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(resolvedRoot + "/") else { return false }
        let relative = path.dropFirst(resolvedRoot.count + 1)
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    struct FileStat {
        let inode: Int
        let size: Int
        let mtime: Double

        /// `lstat`, like `FileManager.attributesOfItem`, whose values earlier
        /// releases stored in `file_cursor`.
        init?(path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            inode = Int(truncatingIfNeeded: st.st_ino)
            size = Int(st.st_size)
            mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        }
    }

    /// Returns true when new rows were written.
    @discardableResult
    private func indexFile(_ url: URL, _ stat: FileStat) -> Bool {
        counters.examinedFiles += 1
        let path = url.path
        let size = stat.size
        let inode = stat.inode
        let mtime = stat.mtime

        if cursors == nil { cursors = store.allFileCursors() }
        var offset = 0
        if let cursor = cursors?[path] {
            if cursor.inode != inode || size < cursor.offset {
                offset = 0                          // rotated or truncated: re-read
                codexContext[path] = nil            // the old file's session and model are not this one's
            } else if size == cursor.offset {
                return false                        // nothing appended
            } else {
                offset = cursor.offset
            }
        }
        guard size > offset else { return false }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return false }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

        // The directory name encodes the folder the session was started in, which
        // is a better project key than a deep cwd when the git root is gone.
        let folder = format == .claude ? url.deletingLastPathComponent().lastPathComponent : ""
        if format == .codex, offset > 0, codexContext[path] == nil { primeCodexContext(url) }
        var events: [UsageEvent] = []
        var malformed = 0
        var consumed = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base, count: raw.count)
            var start = 0
            for i in 0..<buf.count {
                guard buf[i] == 0x0A else { continue }
                if i > start {
                    let slice = UnsafeBufferPointer(rebasing: buf[start..<i])
                    counters.parsedLines += 1
                    switch format == .claude ? parse(slice, folder: folder) : parseCodex(slice, path: path) {
                    case .event(let e): events.append(e)
                    case .malformed:    malformed += 1
                    case .skip:         break
                    }
                }
                start = i + 1
                consumed = start          // only advance past complete lines
            }
        }

        guard consumed > 0 else { return false }   // no complete line yet
        if store.commit(events: events, path: path, inode: inode, size: size,
                        offset: offset + consumed, mtime: mtime) {
            cursors?[path] = CostStore.FileCursor(inode: inode, size: size, offset: offset + consumed)
        }
        store.recordParseErrors(path: path, count: malformed, reason: "malformed line")
        return !events.isEmpty
    }

    // MARK: Parsing

    private enum ParseResult {
        case event(UsageEvent)
        case skip          // not an assistant turn, or synthetic — expected, not an error
        case malformed     // broken JSON or a missing field we require
    }

    private static let marker = Array("\"assistant\"".utf8)

    private lazy var isoWithMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private lazy var isoPlain = ISO8601DateFormatter()

    private func parse(_ line: UnsafeBufferPointer<UInt8>, folder: String) -> ParseResult {
        // Cheap pre-filter: most lines are user turns or attachments and never
        // reach the JSON parser.
        guard Self.contains(line, Self.marker) else { return .skip }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            return .malformed
        }
        guard obj["type"] as? String == "assistant" else { return .skip }

        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String else { return .malformed }
        // Synthetic turns are local error placeholders, not billed requests.
        guard model != "<synthetic>" else { return .skip }

        guard let cwd = obj["cwd"] as? String,
              let sessionId = obj["sessionId"] as? String ?? obj["session_id"] as? String,
              let stamp = obj["timestamp"] as? String,
              let date = isoWithMillis.date(from: stamp) ?? isoPlain.date(from: stamp),
              let input = int(usage["input_tokens"]),
              let output = int(usage["output_tokens"]) else { return .malformed }

        let cacheRead = int(usage["cache_read_input_tokens"]) ?? 0
        let cacheWrite = int(usage["cache_creation_input_tokens"]) ?? 0
        let ts = Int(date.timeIntervalSince1970)

        // Claude Code appends the same turn several times while streaming, each
        // write carrying a larger output count. Collapse them by request id and
        // keep the maximum (see CostStore.commit).
        let key: String
        if let requestId = obj["requestId"] as? String, !requestId.isEmpty {
            key = "r:\(requestId)"
        } else {
            key = "s:\(sessionId):\(ts):\(input):\(output):\(cacheRead):\(cacheWrite)"
        }

        var branch = obj["gitBranch"] as? String
        if branch?.isEmpty ?? false { branch = nil }

        return .event(UsageEvent(
            ts: ts,
            sessionId: sessionId,
            dedupeKey: key,
            project: projectRoot(for: cwd, folder: folder),
            cwd: cwd,
            branch: branch,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            ccVersion: obj["version"] as? String
        ))
    }

    // MARK: Codex rollouts
    //
    // Lines: {"timestamp","type":"session_meta","payload":{"id","cwd",…}},
    //        {"type":"response_item"|"event_msg","payload":{"type":"turn_context","cwd","model"}},
    //        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{…}}}}.
    // Only the token counts become events; the other two feed the per-file context.

    private static let codexMarkers: [[UInt8]] = [Array("token_count".utf8), Array("session_meta".utf8), Array("turn_context".utf8)]

    /// When resuming mid-file, read the head line for the session id and cwd.
    private func primeCodexContext(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 64 * 1024)
        for line in head.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] {
                codexContext[url.path] = (p["id"] as? String ?? p["session_id"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                          p["cwd"] as? String ?? "", "")
                return
            }
        }
    }

    private static let modelMarker = Array("\"model\":\"".utf8)
    private static let modelRegex = try! NSRegularExpression(pattern: "\"model\":\"([^\"]+)\"")

    private func parseCodex(_ line: UnsafeBufferPointer<UInt8>, path: String) -> ParseResult {
        // The model name travels in several record kinds (turn context, task
        // start, item events); any line naming one updates the file's context.
        if Self.contains(line, Self.modelMarker) {
            let text = String(decoding: line, as: UTF8.self)
            if let m = Self.modelRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                var ctx = codexContext[path] ?? ("", "", "")
                ctx.model = String(text[r])
                codexContext[path] = ctx
            }
        }
        guard Self.codexMarkers.contains(where: { Self.contains(line, $0) }) else { return .skip }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return .malformed }
        let type = obj["type"] as? String ?? ""
        if type == "session_meta" {
            codexContext[path] = (payload["id"] as? String ?? payload["session_id"] as? String
                                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                  payload["cwd"] as? String ?? "", codexContext[path]?.model ?? "")
            return .skip
        }
        if payload["type"] as? String == "turn_context" {
            var ctx = codexContext[path] ?? ("", "", "")
            if let c = payload["cwd"] as? String, !c.isEmpty { ctx.cwd = c }
            if let m = payload["model"] as? String, !m.isEmpty { ctx.model = m }
            codexContext[path] = ctx
            return .skip
        }
        guard payload["type"] as? String == "token_count" else { return .skip }
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return .skip }   // rate-limit-only ticks
        guard let stamp = obj["timestamp"] as? String,
              let date = isoWithMillis.date(from: stamp) ?? isoPlain.date(from: stamp),
              let inputAll = int(last["input_tokens"]), let output = int(last["output_tokens"]) else { return .malformed }
        let ctx = codexContext[path] ?? ("", "", "")
        let sessionId = ctx.sessionId.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : ctx.sessionId
        let cwd = ctx.cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : ctx.cwd
        let cached = int(last["cached_input_tokens"]) ?? 0
        let cacheWrite = int(last["cache_write_input_tokens"]) ?? 0
        let ts = Int(date.timeIntervalSince1970)
        // A corrupt or hostile line must not trap the indexer: negative counts
        // are meaningless and a sum past Int.max cannot be a real turn.
        guard inputAll >= 0, output >= 0, cached >= 0, cacheWrite >= 0 else { return .malformed }
        let (total, overflow) = inputAll.addingReportingOverflow(output)
        guard !overflow else { return .malformed }
        guard total > 0 else { return .skip }
        return .event(UsageEvent(
            ts: ts, sessionId: sessionId,
            dedupeKey: "c:\(sessionId):\(ts):\(inputAll):\(output)",
            project: projectRoot(for: cwd, folder: ""), cwd: cwd, branch: nil,
            model: ctx.model.isEmpty ? "codex" : ctx.model,
            input: max(0, inputAll - cached), output: output, cacheRead: cached, cacheWrite: cacheWrite,
            ccVersion: nil))
    }

    private func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        // `Double(Int.max)` is 2^63, one past Int.max, hence `<`.
        if let d = any as? Double, d >= Double(Int.min), d < Double(Int.max) { return Int(d) }
        return nil
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        for i in 0...last where haystack[i] == needle[0] {
            var match = true
            for j in 1..<needle.count where haystack[i + j] != needle[j] { match = false; break }
            if match { return true }
        }
        return false
    }

    // MARK: Project grouping

    /// Sessions started from subfolders of one repo should read as one project, so
    /// the cwd is walked up to its git root. A folder in one project directory can
    /// hold dozens of distinct cwds, which would otherwise fill the list with
    /// `Sources`, `windows`, `docs` rows. Falls back to the cwd itself.
    private func projectRoot(for cwd: String, folder: String) -> String {
        let key = folder + "\u{0}" + cwd
        if let cached = gitRootCache[key] { return cached }

        var result: String?

        // 1. The git root, when the project is still on disk.
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                result = dir.path
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == "/" { break }
            dir = parent
        }

        // 2. Otherwise the transcript's directory name, which Claude Code derives
        //    from where the session started by replacing every non-alphanumeric
        //    character with "-". Matching it against the same transform of the cwd
        //    recovers the real prefix without decoding anything, and rescues
        //    deleted projects that would otherwise show up as a deep subfolder.
        if result == nil, !folder.isEmpty, folder.count < cwd.count {
            let normalized = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            if normalized.hasPrefix(folder) {
                result = String(cwd.prefix(folder.count))
            }
        }

        let resolved = result ?? cwd
        gitRootCache[key] = resolved
        return resolved
    }

    // MARK: Watching

    private static let fullScanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    private func startWatching() {
        startSafetyNet()

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // Runs on `queue` (FSEventStreamSetDispatchQueue below).
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let indexer = Unmanaged<CostIndexer>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count {
                indexer.note(path: list[i] as? String ?? "", flags: flags[i])
            }
            indexer.scheduleDrain()
        }
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        guard let s = FSEventStreamCreate(nil, callback, &context,
                                          [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0,   // latency doubles as debounce
                                          FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Leeway scales with the interval: 30 s at the default 600 s.
    func startSafetyNet() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safetyNetInterval, repeating: safetyNetInterval,
                       leeway: .milliseconds(Int(safetyNetInterval * 1000 / 20)))
        timer.setEventHandler { [weak self] in self?.performScan() }
        timer.resume()
        safetyNet = timer
    }

    private func stopWatching() {
        safetyNet?.cancel()
        safetyNet = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Queue-confined. A directory renamed into the tree reports only itself, not
    /// the transcripts inside, so it needs a full pass like a dropped-events flag.
    private func note(path: String, flags: FSEventStreamEventFlags) {
        let isDirRename = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            && flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
        if flags & Self.fullScanFlags != 0 || isDirRename {
            pendingFullScan = true
        } else if path.hasSuffix(".jsonl") {
            pendingPaths.insert(path)
        }
    }

    /// FSEvents can fire repeatedly while a session is being written; collapse
    /// bursts into one pass.
    private func scheduleDrain() {
        guard !scanScheduled, pendingFullScan || !pendingPaths.isEmpty else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.drainPending()
        }
    }

    private func drainPending() {
        let paths = pendingPaths
        pendingPaths.removeAll()
        if pendingFullScan {
            pendingFullScan = false
            performScan()
        } else if !paths.isEmpty {
            indexPending(paths)
        }
    }
}
