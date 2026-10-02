import XCTest
@testable import Codenotch

final class CodexStoreStampTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStoreStampTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the stamp was computed from before it read `lstat` itself.
    private func foundationStamp(_ url: URL) -> CodexStoreCache.Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return CodexStoreCache.Stamp(
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    func testAFreshlyWrittenFileStampsAsFoundationDescribesIt() throws {
        let url = try write("{\"a\":1}\n", to: "rollout.jsonl")
        let stamp = CodexStoreCache.stamp(ofFile: url)
        let expected = foundationStamp(url)

        XCTAssertEqual(stamp, expected)
        XCTAssertEqual(stamp.modified?.timeIntervalSinceReferenceDate.bitPattern,
                       expected.modified?.timeIntervalSinceReferenceDate.bitPattern)
        XCTAssertEqual(stamp.size, 8)
        XCTAssertNotEqual(stamp.inode, 0)
    }

    /// One file's nanoseconds can land on the same `Date` either way they
    /// are added; a few hundred cannot.
    func testEveryFreshMtimeConvertsToTheSameDateFoundationGives() throws {
        var differing: [String] = []
        for index in 0..<300 {
            let url = try write("\(index)", to: "rollout-\(index).jsonl")
            let stamp = CodexStoreCache.stamp(ofFile: url)
            let expected = foundationStamp(url)
            if stamp.modified?.timeIntervalSinceReferenceDate.bitPattern
                != expected.modified?.timeIntervalSinceReferenceDate.bitPattern {
                differing.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(differing, [])
    }

    func testASymlinkStampsAsTheLinkItselfAsFoundationDid() throws {
        let target = try write(String(repeating: "x", count: 100), to: "target.jsonl")
        let link = directory.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let stamp = CodexStoreCache.stamp(ofFile: link)

        XCTAssertEqual(stamp, foundationStamp(link))
        XCTAssertNotEqual(stamp.size, 100)
    }

    func testAMissingFileStampsAsNothing() {
        let stamp = CodexStoreCache.stamp(ofFile: directory.appendingPathComponent("gone.jsonl"))

        XCTAssertNil(stamp.modified)
        XCTAssertEqual(stamp.size, 0)
        XCTAssertEqual(stamp.inode, 0)
    }

    func testAFileReplacedAtTheSameSizeAndTimeStampsDifferently() throws {
        let url = try write("same bytes\n", to: "rollout.jsonl")
        try setModified(url, 1_800_000_000)
        let before = CodexStoreCache.stamp(ofFile: url)

        let replacement = try write("same bytes\n", to: "replacement.jsonl")
        try setModified(replacement, 1_800_000_000)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        let after = CodexStoreCache.stamp(ofFile: url)

        XCTAssertEqual(after.modified, before.modified)
        XCTAssertEqual(after.size, before.size)
        XCTAssertNotEqual(after, before)
    }

    func testAnAppendChangesTheSizeAndATouchChangesTheTime() throws {
        let url = try write("one\n", to: "rollout.jsonl")
        try setModified(url, 1_800_000_000)
        let first = CodexStoreCache.stamp(ofFile: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        try setModified(url, 1_800_000_000)
        let appended = CodexStoreCache.stamp(ofFile: url)

        XCTAssertEqual(appended.size, 8)
        XCTAssertNotEqual(appended, first)

        try setModified(url, 1_800_000_060)
        let touched = CodexStoreCache.stamp(ofFile: url)

        XCTAssertEqual(touched.size, appended.size)
        XCTAssertEqual(touched.modified, Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertNotEqual(touched, appended)
    }

    func testADatabaseAloneStampsAsItsOwnTimeAndSizeWithNoInode() throws {
        let db = try write(String(repeating: "d", count: 40), to: "state.sqlite")
        try setModified(db, 1_800_000_000)

        XCTAssertEqual(CodexStoreCache.stamp(of: db),
                       CodexStoreCache.Stamp(modified: Date(timeIntervalSince1970: 1_800_000_000),
                                             size: 40))
    }

    func testADatabaseAndItsWalStampAsTheNewerTimeAndTheSummedSize() throws {
        let db = try write(String(repeating: "d", count: 40), to: "state.sqlite")
        let wal = try write(String(repeating: "w", count: 7), to: "state.sqlite-wal")
        try setModified(db, 1_800_000_000)
        try setModified(wal, 1_800_000_090)

        XCTAssertEqual(CodexStoreCache.stamp(of: db),
                       CodexStoreCache.Stamp(modified: Date(timeIntervalSince1970: 1_800_000_090),
                                             size: 47))

        try setModified(db, 1_800_000_120)
        XCTAssertEqual(CodexStoreCache.stamp(of: db).modified,
                       Date(timeIntervalSince1970: 1_800_000_120))
    }

    func testAWalWithoutItsDatabaseStillCounts() throws {
        let db = directory.appendingPathComponent("state.sqlite")
        let wal = try write(String(repeating: "w", count: 7), to: "state.sqlite-wal")
        try setModified(wal, 1_800_000_000)

        XCTAssertEqual(CodexStoreCache.stamp(of: db),
                       CodexStoreCache.Stamp(modified: Date(timeIntervalSince1970: 1_800_000_000),
                                             size: 7))
    }

    func testAnAbsentStoreStampsAsNothing() {
        XCTAssertEqual(CodexStoreCache.stamp(of: directory.appendingPathComponent("none.sqlite")),
                       CodexStoreCache.Stamp(modified: nil, size: 0))
    }
}
