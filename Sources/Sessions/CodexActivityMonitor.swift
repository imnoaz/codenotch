import AppKit
import Combine
import Darwin
import Foundation

/// The small, stable part of a Codex rollout that is useful for activity.
///
/// `item_completed` is intentionally ignored: commands and other child items
/// emit it too. A turn is complete only after Codex writes `task_complete`.
struct CodexRolloutActivity {
    enum State: Equatable {
        case busy
        case success
    }

    /// One window into the end of the rollout. Rollouts run to hundreds of
    /// megabytes, so the file is walked backwards in slices rather than read
    /// whole — the same `tail` trick the Claude and Antigravity readers use.
    private static let windowBytes: UInt64 = 256 * 1024
    /// How far back a lifecycle event may be before the search gives up. A
    /// mid-turn rollout keeps its `task_started` arbitrarily far behind the
    /// writes streaming in — walking to it would read the whole file on every
    /// tick. A fresh file with no lifecycle event in its last megabyte is a
    /// turn in progress in every realistic case, and the caller maps a miss
    /// to `.busy` — the same answer the full scan would give.
    private static let maxWindows: UInt64 = 4
    static let reach = maxWindows * windowBytes

    static func state(from url: URL) -> State? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        return state(of: handle, through: end, notBefore: end > reach ? end - reach : 0)
    }

    static func state(of handle: FileHandle, through end: UInt64, notBefore floor: UInt64) -> State? {
        var windowEnd = end
        // The newest lifecycle event wins, so windows are scanned newest
        // first and the first match is the answer. A window's first line is
        // cut in half by the read; the fragment is carried into the earlier
        // window, where the rest of it lives, rather than parsed half a line.
        var carried = Data()
        while windowEnd > floor {
            let windowStart = max(floor, windowEnd > windowBytes ? windowEnd - windowBytes : 0)
            guard (try? handle.seek(toOffset: windowStart)) != nil else { return nil }

            // `read(upToCount:)` may legally deliver fewer bytes than asked
            // for, and a window that came back short would silently lose the
            // lines its tail never reached — and join `carried` to a stretch
            // of file it does not follow. Read until the window is filled.
            // An error still fails the scan; hitting EOF early means the
            // file shrank between the seek and the read (rotation), and what
            // arrived is still contiguous with `windowStart`.
            var window = Data()
            window.reserveCapacity(Int(windowEnd - windowStart))
            while window.count < Int(windowEnd - windowStart) {
                guard let chunk = try? handle.read(
                    upToCount: Int(windowEnd - windowStart) - window.count
                ) else { return nil }
                if chunk.isEmpty { break }
                window.append(chunk)
            }
            // `carried` continues the line this window's start cut — but only
            // when the read reached `windowEnd`, where the fragment begins. A
            // short window ends somewhere else entirely, and joining the two
            // would fabricate a line out of unrelated bytes.
            if window.count == Int(windowEnd - windowStart) {
                window.append(carried)
            }

            // A window that opens on a newline was not cut mid-line: its first
            // line is whole, and the earlier window's last line is the one
            // missing its newline. Carrying anything back would glue the two.
            let startsOnALineBreak = window.first == UInt8(ascii: "\n")
            var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            carried = windowStart > 0 && !startsOnALineBreak && !lines.isEmpty
                ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() {
                if let event = Lifecycle(line: Data(line)) { return event.state }
            }
            windowEnd = windowStart
        }
        return nil
    }

    enum Lifecycle {
        case started
        case complete
        case aborted

        private static let names = ["task_started", "task_complete", "turn_aborted"].map { Data($0.utf8) }
        private static let unicodeEscape = Data([UInt8(ascii: "\\"), UInt8(ascii: "u")])

        /// Whether a line could be a lifecycle event, decided on bytes so that
        /// most lines never reach the JSON parser. The names are letters and
        /// `_`, which JSON can spell differently only as `\uXXXX`; the `\n` and
        /// `\"` that fill command output and messages do not make a line a
        /// candidate.
        private static func mayBeEvent(_ line: Data) -> Bool {
            line.range(of: unicodeEscape) != nil || names.contains(where: { line.range(of: $0) != nil })
        }

        init?(line: Data, parse: (Data) -> Any? = { try? JSONSerialization.jsonObject(with: $0) }) {
            guard Self.mayBeEvent(line),
                  let record = parse(line) as? [String: Any],
                  record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any] else { return nil }
            switch payload["type"] as? String {
            case "task_started": self = .started
            case "task_complete": self = .complete
            case "turn_aborted": self = .aborted
            default: return nil
            }
        }

        var state: State? {
            switch self {
            case .started: .busy
            case .complete: .success
            // An aborted turn is not a successful completion. Nil lets the
            // activity monitor drop it without announcing.
            case .aborted: nil
            }
        }
    }
}

/// Reads one rollout's state incrementally.
///
/// While a conversation works its rollout grows every second, and the bounded
/// backward scan in `CodexRolloutActivity.state` re-reads up to a megabyte of
/// it on each change. This keeps how far it has read and what it found, so a
/// grown file costs parsing only the new lines. The first read of a file is
/// that same bounded scan, not a read from byte zero: rollouts run to hundreds
/// of megabytes and a couple of dozen are asked about at once. From there the
/// answer is the bounded scan's, with every later lifecycle event folded in.
final class CodexRolloutReader {
    typealias State = CodexRolloutActivity.State

    private static let seedWindowBytes: UInt64 = 256 * 1024
    /// The most one call reads, so a burst of writes is never split and parsed
    /// on the main actor all at once. The rest is read by the calls after it.
    static let readLimit = 1024 * 1024
    /// How much of what was read is compared before reading on: a file
    /// overwritten from its start without truncation grows like an append.
    private static let witnessBytes: UInt64 = 256

    private var url: URL?
    /// Which file at `url` was read: a rollout replaced in place keeps its path
    /// and may keep its size, but not its inode.
    private var inode: UInt64 = 0
    private var size: UInt64 = 0
    private var modified = timespec()
    /// Where the first line not yet folded into `state` starts.
    private var offset: UInt64 = 0
    private var witness = Data()
    /// `offset` is inside a line longer than `readLimit`. No lifecycle event
    /// is that long, so the rest of it is passed over unparsed.
    private var skippingLine = false
    /// The state after every complete line before `offset`.
    private var state: State?
    /// The last call stopped at `readLimit`, short of the size it saw.
    private(set) var isBehind = false

    func state(from url: URL) -> State? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            forget()
            return nil
        }
        defer { try? handle.close() }

        var info = stat()
        let known = fstat(handle.fileDescriptor, &info) == 0
        let id = known ? UInt64(info.st_ino) : 0
        let modified = known ? info.st_mtimespec : timespec()
        // A different file, one that shrank, one that changed without
        // growing, or one whose bytes before `offset` are no longer the ones
        // read was rewritten rather than appended to: not a continuation of
        // what was read before.
        let rewritten = size == self.size
            && (modified.tv_sec != self.modified.tv_sec || modified.tv_nsec != self.modified.tv_nsec)
        if url != self.url || id != inode || size < self.size || rewritten || !witnessHolds(in: handle) {
            seed(url: url, inode: id, handle: handle, size: size)
        }
        self.size = size
        self.modified = modified
        return readOn(from: handle, size: size)
    }

    private func readOn(from handle: FileHandle, size: UInt64) -> State? {
        isBehind = false
        let count = Int(min(size - offset, UInt64(Self.readLimit)))
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil,
              var chunk = try? handle.read(upToCount: count) else { return state }
        let reachedEnd = offset + UInt64(chunk.count) >= size
        isBehind = !reachedEnd

        if skippingLine {
            guard let newline = chunk.firstIndex(of: 0x0A) else {
                consume(chunk)
                return state
            }
            consume(chunk[...newline])
            chunk = chunk[chunk.index(after: newline)...]
            skippingLine = false
        }

        let complete = chunk.lastIndex(of: 0x0A).map { chunk[...$0] } ?? chunk[chunk.startIndex..<chunk.startIndex]
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            state = Self.apply(Data(line), to: state)
        }
        consume(complete)

        let rest = chunk[complete.endIndex...]
        if rest.count == Self.readLimit {
            skippingLine = true
            consume(rest)
            return state
        }
        // A last line with no newline after it may still be being written.
        // It counts for this answer if it parses, but is read again next time
        // rather than committed. One cut short by `readLimit` is neither.
        return reachedEnd && !rest.isEmpty ? Self.apply(Data(rest), to: state) : state
    }

    private func consume(_ bytes: Data) {
        offset += UInt64(bytes.count)
        let keep = Int(Self.witnessBytes)
        witness = bytes.count >= keep ? Data(bytes.suffix(keep)) : Data((witness + bytes).suffix(keep))
    }

    private func witnessHolds(in handle: FileHandle) -> Bool {
        witness.isEmpty || Self.bytes(in: handle, before: offset, count: UInt64(witness.count)) == witness
    }

    private func forget() {
        url = nil
        inode = 0
        size = 0
        modified = timespec()
        offset = 0
        witness = Data()
        skippingLine = false
        state = nil
        isBehind = false
    }

    /// Starts from the bounded scan's answer over the file's complete lines,
    /// positioned after the last of them. The unterminated line after that is
    /// left to the read that follows, so what it says is not remembered until
    /// it is finished.
    private func seed(url: URL, inode: UInt64, handle: FileHandle, size: UInt64) {
        forget()
        self.url = url
        self.inode = inode
        let floor = size > CodexRolloutActivity.reach ? size - CodexRolloutActivity.reach : 0
        if let end = Self.lineEnd(in: handle, before: size, notBefore: floor) {
            state = CodexRolloutActivity.state(of: handle, through: end, notBefore: floor)
            offset = end
        } else if floor > 0 {
            // No line starts within the bounded scan's reach: the end of the
            // file is one line longer than that.
            offset = size
            skippingLine = true
        }
        witness = Self.bytes(in: handle, before: offset, count: Self.witnessBytes) ?? Data()
    }

    private static func lineEnd(in handle: FileHandle, before end: UInt64, notBefore floor: UInt64) -> UInt64? {
        var windowEnd = end
        while windowEnd > floor {
            let windowStart = max(floor, windowEnd > seedWindowBytes ? windowEnd - seedWindowBytes : 0)
            guard (try? handle.seek(toOffset: windowStart)) != nil,
                  let window = try? handle.read(upToCount: Int(windowEnd - windowStart)) else { return nil }
            if let newline = window.lastIndex(of: 0x0A) {
                return windowStart + UInt64(newline - window.startIndex) + 1
            }
            windowEnd = windowStart
        }
        return nil
    }

    private static func bytes(in handle: FileHandle, before end: UInt64, count: UInt64) -> Data? {
        let start = end - min(end, count)
        guard start < end else { return Data() }
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.read(upToCount: Int(end - start))
    }

    private static func apply(_ line: Data, to state: State?) -> State? {
        guard let event = CodexRolloutActivity.Lifecycle(line: line) else { return state }
        return event.state
    }
}

/// Reports whether Codex is mid-turn.
///
/// Codex does not publish a live status field, but its rollout includes
/// lifecycle events. `task_started` and `task_complete` are used when present;
/// the file's recent modification time remains the activity fallback.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. A stale rollout is deliberately not
/// converted into `.success` or `.idle`, because inactivity is not evidence
/// that a Codex turn completed — a long-running command can be quiet too.
/// If Codex grows a real status field this should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private let storeCache = CodexStoreCache()

    /// When each row entered the state it is in, by session id. See `settled`.
    private var entered: [String: (state: AgentSession.State, at: Date)] = [:]

    private func rescan() {
        let read = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                             staleAfter: staleAfter, profile: profile, cache: storeCache)
        let found = Self.settled(read, entered: &entered)
        guard found != sessions else { return }
        // Only on a change, as the Claude monitor does, and for the same
        // reason: it is the one way to see what the notch thinks is running
        // without hovering over it.
        let summary = found.map { "\($0.name)=\($0.state)" }.joined(separator: " ")
        Log.sessions.debug("\(self.profile.id, privacy: .public): \(summary, privacy: .public)")
        sessions = found
    }

    /// Every Codex conversation working right now, each under its own name.
    ///
    /// This used to be one row at most, called "Codex": the newest rollout or
    /// the newest desktop thread, whichever moved last. Two conversations
    /// running at once drew as one, and nothing on the notch said which
    /// request was being worked on — while the Claude rows beside it named
    /// every session. Codex does name its conversations; the name is in the
    /// same `threads` row the rollout path was already being read from.
    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default(),
                     cache: CodexStoreCache = CodexStoreCache(),
                     openRollouts: Set<String>? = nil) -> [AgentSession] {
        var found: [AgentSession] = []
        // Every thread id that is part of a conversation drawn below, so the
        // desktop app's copy of the same conversation is not drawn again.
        var drawn: Set<String> = []

        // "Codex" is two programs that record their work in different places:
        // the CLI and the VS Code extension append to a rollout, and the
        // desktop app writes to its own catalogue.
        let openRollouts = openRollouts ?? CodexOpenRollouts.paths(
            under: profile.configDirectory.appendingPathComponent("sessions")
        )
        for conversation in liveConversations(cache.recentThreads(in: stateStore),
                                              staleAfter: staleAfter, now: now, cache: cache,
                                              openRollouts: openRollouts) {
            let root = conversation.root
            // The id the single row always had, so a conversation that is not
            // a sub-agent's keeps it and nothing keyed on it moves.
            let handle = root.rollout?.lastPathComponent ?? root.id
            guard let session = session(id: "\(profile.id).\(handle)",
                                        name: root.label(fallback: profile.displayName),
                                        modified: conversation.at, state: conversation.state,
                                        staleAfter: staleAfter, now: now,
                                        allowStale: conversation.isOpen)
            else { continue }
            found.append(session)
            drawn.formUnion(conversation.members)
        }

        if let desktop = cache.newestDesktopThread(in: desktopStore),
           desktop.threadID.isEmpty || !drawn.contains(desktop.threadID),
           let session = session(id: "\(profile.id).desktop", name: desktop.title,
                                 modified: desktop.updatedAt, state: .busy,
                                 staleAfter: staleAfter, now: now) {
            found.append(session)
        }

        // Newest first, with the id breaking ties so two ticks that read the
        // same thing cannot draw the rows in a different order.
        return found.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// One working conversation: the thread it started from, when any of it
    /// last moved, what it is doing, and every thread id that is part of it.
    struct Conversation {
        let root: CodexThread
        let at: Date
        let state: AgentSession.State
        let members: Set<String>
        let isOpen: Bool
    }

    /// Every conversation with a rollout written inside the window, each once.
    ///
    /// A sub-agent is folded into the conversation that spawned it rather than
    /// drawn as a row of its own. Codex can run half a dozen for one request,
    /// each with a rollout, and a row per helper would bury the one thing the
    /// person asked for — while the parent, waiting on them, may write nothing
    /// at all for minutes. So the work is credited to the root, under the
    /// root's name, for as long as any of it is moving.
    static func liveConversations(_ threads: [CodexThread],
                                  staleAfter: TimeInterval,
                                  now: Date,
                                  cache: CodexStoreCache = CodexStoreCache(),
                                  openRollouts: Set<String> = []) -> [Conversation] {
        let byID = Dictionary(threads.filter { !$0.id.isEmpty }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })

        func root(of thread: CodexThread) -> CodexThread {
            var current = thread
            var seen: Set<String> = [thread.key]
            while let parent = current.parentID, let next = byID[parent],
                  seen.insert(next.key).inserted {
                current = next
            }
            return current
        }

        var newest: [String: Date] = [:]
        var roots: [String: CodexThread] = [:]
        var members: [String: Set<String>] = [:]
        var busyRoots: Set<String> = []
        var openRoots: Set<String> = []
        let rollouts = Set(threads.compactMap { $0.rollout?.path })
        for thread in threads {
            guard let rollout = thread.rollout,
                  let modified = CodexStoreCache.stamp(ofFile: rollout).modified
            else { continue }
            let activity = cache.rolloutState(of: rollout, keeping: rollouts)
            let isRecent = now.timeIntervalSince(modified) <= staleAfter
            guard isRecent || (openRollouts.contains(rollout.path) && activity == .busy)
            else { continue }
            let root = root(of: thread)
            // A helper whose conversation cannot be found is not drawn at all.
            // Drawing it as a conversation of its own is the one wrong answer:
            // a row named after a prompt the person never wrote, announcing
            // "Complete" for a review while the real request is still working.
            guard !root.isHelper else { continue }
            roots[root.key] = root
            members[root.key, default: []].formUnion([thread.id, root.id].filter { !$0.isEmpty })
            if activity == .busy || thread.key != root.key { busyRoots.insert(root.key) }
            if openRollouts.contains(rollout.path), activity == .busy {
                openRoots.insert(root.key)
            }
            if newest[root.key].map({ $0 < modified }) ?? true { newest[root.key] = modified }
        }

        let live = Set(roots.values.compactMap { $0.rollout?.path })
        return roots.compactMap { key, root in
            guard let at = newest[key] else { return nil }
            return Conversation(root: root, at: at,
                                state: busyRoots.contains(key) ? .busy
                                    : state(of: root, staleAfter: staleAfter, now: now,
                                            cache: cache, live: live),
                                members: members[key] ?? [],
                                isOpen: openRoots.contains(key))
        }
    }

    /// The rows with `since` meaning what `AgentSession` says it means: when
    /// the row entered its current state.
    ///
    /// What `read` can see is a rollout's last write, which moves every
    /// second while a conversation works. As `since` that sorted two busy
    /// conversations by whichever wrote last, so they swapped places every
    /// few seconds, showed an elapsed time of about nothing, and made every
    /// tick look like a change. So the first sighting of a row in a state is
    /// kept until the state changes, and rows no longer present are
    /// forgotten.
    static func settled(_ sessions: [AgentSession],
                        entered: inout [String: (state: AgentSession.State, at: Date)])
    -> [AgentSession] {
        var next: [String: (state: AgentSession.State, at: Date)] = [:]
        let settled = sessions.map { session -> AgentSession in
            let held = entered[session.id]
            let at = held.flatMap { $0.state == session.state ? $0.at : nil } ?? session.since
            next[session.id] = (session.state, at)
            return AgentSession(id: session.id, name: session.name, detail: session.detail,
                                state: session.state, waitingFor: session.waitingFor,
                                since: at, processID: session.processID)
        }
        entered = next
        return settled.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The conversation's own answer when its root is writing, and busy when
    /// only its helpers are.
    ///
    /// Never a helper's answer. A sub-agent finishing writes `task_complete`
    /// into *its* rollout while the request it was helping with is still
    /// under way, and reading that as the conversation's state would announce
    /// "Complete" for work that is not.
    ///
    /// A stale rollout is not parsed at all — the parse is the expensive part,
    /// and a file that has stopped moving has nothing current to say.
    static func state(of root: CodexThread, staleAfter: TimeInterval, now: Date,
                      cache: CodexStoreCache, live: Set<String>) -> AgentSession.State {
        guard let rollout = root.rollout,
              let modified = CodexStoreCache.stamp(ofFile: rollout).modified,
              now.timeIntervalSince(modified) <= staleAfter
        else { return .busy }
        switch cache.rolloutState(of: rollout, keeping: live) {
        case .success: return .success
        case .busy, .none: return .busy
        }
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date,
        allowStale: Bool = false
    ) -> AgentSession? {
        guard allowStale || now.timeIntervalSince(modified) <= staleAfter else { return nil }

        return AgentSession(
            id: id,
            name: name,
            detail: state == .success ? L10n.t("Complete") : L10n.t("Working"),
            state: state,
            waitingFor: nil,
            since: modified
        )
    }
}

enum CodexOpenRollouts {
    static func paths(under root: URL, pids suppliedPIDs: [pid_t]? = nil) -> Set<String> {
        let pids = suppliedPIDs ?? codexProcesses()

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var resolvedPrefix = prefix
        if let resolved = realpath(root.path, nil) {
            let path = String(cString: resolved)
            free(resolved)
            resolvedPrefix = path.hasSuffix("/") ? path : path + "/"
        }
        var found: Set<String> = []
        for pid in pids where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                    count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                    Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            guard read > 0 else { continue }
            for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
                where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                     &info, infoSize) == infoSize else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }
                guard path.hasSuffix(".jsonl") else { continue }
                if path.hasPrefix(prefix) {
                    found.insert(path)
                } else if path.hasPrefix(resolvedPrefix) {
                    found.insert(prefix + path.dropFirst(resolvedPrefix.count))
                }
            }
        }
        return found
    }

    /// Our own processes only: another user's cannot be asked for its open
    /// files (PROC_PIDLISTFDS fails), so listing every process on the machine
    /// paid a `proc_pidinfo` per process for nothing.
    static func readableProcesses() -> [pid_t] {
        var count = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard count > 0 else { return [] }
        var listed = [pid_t](repeating: 0,
                             count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &listed,
                              Int32(listed.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(listed.prefix(Int(count) / MemoryLayout<pid_t>.stride))
    }

    static func codexProcesses() -> [pid_t] {
        readableProcesses().filter(isCodex)
    }

    private static func isCodex(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return false }
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0) == "codex"
            }
        }
    }
}
