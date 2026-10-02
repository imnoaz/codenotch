import XCTest
@testable import Codenotch

@MainActor
final class CodexOpenRolloutTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOpenRolloutTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQuietOpenConversationStaysBusyUntilTaskComplete() throws {
        let rollout = try makeRollout(events: ["task_started"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        )

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.state, .busy)
        XCTAssertTrue(conversations.first?.isOpen == true)
    }

    func testOpenCompletedConversationIsNotBusy() throws {
        let rollout = try makeRollout(events: ["task_started", "task_complete"])
        XCTAssertTrue(CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        ).isEmpty)
    }

    func testFindsARolloutHeldOpenByAProcess() throws {
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }

        XCTAssertTrue(CodexOpenRollouts.paths(under: sessions, pids: [getpid()]).contains(rollout.path))
    }

    /// Without supplied pids only Codex processes are asked: the test process
    /// holds a rollout open, and is not one.
    func testTheDefaultLookupIgnoresARolloutHeldOpenByANonCodexProcess() throws {
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }

        XCTAssertFalse(CodexOpenRollouts.codexProcesses().contains(getpid()))
        XCTAssertTrue(CodexOpenRollouts.paths(under: sessions, pids: [getpid()]).contains(rollout.path))
        XCTAssertEqual(CodexOpenRollouts.paths(under: sessions), [])
    }

    /// Every process on the machine whose open files can be listed is among
    /// the ones asked about — the rest could never contribute a rollout.
    /// Only processes readable both before and after the listing are held to
    /// it, so one starting or exiting meanwhile cannot fail the test.
    func testEveryProcessWhoseFilesCanBeReadIsAskedAbout() {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        var all = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all,
                              Int32(all.count * MemoryLayout<pid_t>.stride))
        func readable(_ pid: pid_t) -> Bool { pid > 0 && proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0) > 0 }
        let before = all.prefix(Int(count) / MemoryLayout<pid_t>.stride).filter(readable)

        let listed = Set(CodexOpenRollouts.readableProcesses())

        XCTAssertTrue(listed.contains(getpid()))
        XCTAssertEqual(before.filter(readable).filter { !listed.contains($0) }, [])
    }

    private func makeRollout(events: [String]) throws -> URL {
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        let lines = events.map { #"{"type":"event_msg","payload":{"type":"\#($0)"}}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: rollout.path
        )
        return rollout
    }

    private func thread(_ rollout: URL) -> CodexThread {
        CodexThread(
            id: "thread",
            rollout: rollout,
            name: "Long-running command",
            preview: nil,
            cwd: nil,
            parentID: nil,
            isHelper: false
        )
    }
}
