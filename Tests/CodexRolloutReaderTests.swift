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
        try write(started + "\n" + noise + "\n", to: url)
        XCTAssertEqual(CodexRolloutReader().state(from: url), .busy)
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
