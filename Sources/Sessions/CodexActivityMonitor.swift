import AppKit
import Combine
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

    /// The state a rollout ends in, read from scratch.
    static func state(from url: URL) -> State? {
        CodexRolloutReader().state(from: url)
    }
}

/// Reads a rollout's state incrementally.
///
/// The monitor asks every two seconds, and a long session's rollout runs to
/// tens of megabytes. Reading and parsing all of it each time held the main
/// thread for a large share of the app's idle CPU, to learn something that
/// almost never changes. This keeps how far it has read and what it found, so a
/// tick on an unchanged file costs a `stat` and a tick on a grown one parses
/// only the new lines. The answer is the same as reading the whole file: only
/// the last lifecycle event counts, and it is folded in as the file grows.
final class CodexRolloutReader {
    private static let markers = ["task_started", "task_complete", "turn_aborted"].map { Data($0.utf8) }

    private var url: URL?
    /// Which file at `url` was read: a rollout replaced in place keeps its path
    /// and may keep its size, but not its inode.
    private var inode: UInt64 = 0
    /// Bytes consumed up to and including the last newline seen.
    private var offset: UInt64 = 0
    /// The state after every complete line before `offset`.
    private var state: CodexRolloutActivity.State?

    func state(from url: URL) -> CodexRolloutActivity.State? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            reset(to: nil, inode: 0)
            return nil
        }
        defer { try? handle.close() }

        var info = stat()
        let id = fstat(handle.fileDescriptor, &info) == 0 ? UInt64(info.st_ino) : 0
        // A different file, or one that shrank (rotated or rewritten), is not
        // a continuation of what was read before.
        if url != self.url || id != inode || size < offset { reset(to: url, inode: id) }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd() else { return state }

        var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: true)
        // A last line with no newline after it may still be being written.
        // It counts for this answer if it parses, but is read again next time
        // rather than committed.
        let unterminated = chunk.last != 0x0A ? lines.popLast() : nil
        for line in lines { state = Self.apply(Data(line), to: state) }
        offset += UInt64(chunk.count - (unterminated?.count ?? 0))
        return unterminated.map { Self.apply(Data($0), to: state) } ?? state
    }

    private func reset(to url: URL?, inode: UInt64) {
        self.url = url
        self.inode = inode
        offset = 0
        state = nil
    }

    /// The state after one line. Lines that are not lifecycle events leave it
    /// alone, and are rejected on a byte search before any JSON is parsed.
    ///
    /// The search looks for the event names as written, so a line that spells
    /// one with a `\u` escape would be missed. Codex's JSON writer does not
    /// escape `_`, and no byte search can be complete against a format that
    /// allows every character to be escaped.
    private static func apply(_ line: Data, to state: CodexRolloutActivity.State?) -> CodexRolloutActivity.State? {
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return state }

        switch type {
        case "task_started":
            return .busy
        case "task_complete":
            return .success
        case "turn_aborted":
            // An aborted turn is not a successful completion. Returning
            // nil lets the activity monitor drop it without announcing.
            return nil
        default:
            return state
        }
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
    private let rollouts = CodexRolloutReader()

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

    private func rescan() {
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter, profile: profile, rollouts: rollouts)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default(),
                     rollouts: CodexRolloutReader = CodexRolloutReader()) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date, state: AgentSession.State)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date {
            let state: AgentSession.State
            switch rollouts.state(from: rollout) {
            case .success: state = .success
            case .busy, .none: state = .busy
            }
            candidates.append((id: "\(profile.id).\(rollout.lastPathComponent)",
                               name: profile.displayName, at: modified, state: state))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "\(profile.id).desktop", name: desktop.title,
                               at: desktop.updatedAt, state: .busy))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, state: newest.state,
                                    staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }

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
