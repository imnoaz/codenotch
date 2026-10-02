import AppKit
import CoreGraphics
import XCTest
@testable import Codenotch

final class FullScreenWindowListTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let front: pid_t = 12345

    private func window(pid: Int, layer: Int, bounds: CGRect?) -> NSDictionary {
        let info = NSMutableDictionary()
        info[kCGWindowOwnerPID] = NSNumber(value: pid)
        info[kCGWindowLayer] = NSNumber(value: layer)
        if let bounds { info[kCGWindowBounds] = bounds.dictionaryRepresentation }
        return info
    }

    /// The windows the old `as? [[String: Any]]` reading kept, narrowed to
    /// the ones `isFullScreen` looks at.
    private func bridgedCandidates(_ list: CFArray, frontmostPID: pid_t) -> [CGRect] {
        (list as? [[String: Any]] ?? []).compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  pid == frontmostPID, layer == 0
            else { return nil }
            return bounds
        }
    }

    private func candidates(_ list: CFArray, frontmostPID: pid_t) -> [CGRect] {
        FullScreenDetector.candidateWindows(in: list, frontmostPID: frontmostPID).map(\.bounds)
    }

    func testTheFrontmostAppsOrdinaryWindowsAreReadInOrder() {
        let list = [
            window(pid: 9999, layer: 0, bounds: screen),
            window(pid: Int(front), layer: 24, bounds: screen),
            window(pid: Int(front), layer: 0, bounds: CGRect(x: 50, y: 50, width: 800, height: 600)),
            window(pid: Int(front), layer: 0, bounds: nil),
            window(pid: Int(front), layer: 0, bounds: CGRect(x: 0, y: 44, width: 1728, height: 1073)),
        ] as NSArray as CFArray

        let read = FullScreenDetector.candidateWindows(in: list, frontmostPID: front)
        XCTAssertEqual(read.map(\.pid), [front, front])
        XCTAssertEqual(read.map(\.layer), [0, 0])
        XCTAssertEqual(read.map(\.bounds), [
            CGRect(x: 50, y: 50, width: 800, height: 600),
            CGRect(x: 0, y: 44, width: 1728, height: 1073),
        ])
    }

    func testAnEntryMissingItsOwnerOrLayerIsSkipped() {
        let noOwner = NSMutableDictionary(dictionary: window(pid: Int(front), layer: 0, bounds: screen))
        noOwner.removeObject(forKey: kCGWindowOwnerPID)
        let noLayer = NSMutableDictionary(dictionary: window(pid: Int(front), layer: 0, bounds: screen))
        noLayer.removeObject(forKey: kCGWindowLayer)
        let list = [noOwner, noLayer] as NSArray as CFArray

        XCTAssertEqual(candidates(list, frontmostPID: front), [])
        XCTAssertFalse(FullScreenDetector.isFullScreen(
            screenBounds: screen, frontmostPID: front,
            windows: FullScreenDetector.candidateWindows(in: list, frontmostPID: front)))
    }

    func testOnlyTheFrontmostAppsFullScreenWindowCounts() {
        let others = [window(pid: 9999, layer: 0, bounds: screen),
                      window(pid: Int(front), layer: 24, bounds: screen)] as NSArray as CFArray
        let mine = [window(pid: 9999, layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)),
                    window(pid: Int(front), layer: 0, bounds: screen)] as NSArray as CFArray

        XCTAssertFalse(FullScreenDetector.isFullScreen(
            screenBounds: screen, frontmostPID: front,
            windows: FullScreenDetector.candidateWindows(in: others, frontmostPID: front)))
        XCTAssertTrue(FullScreenDetector.isFullScreen(
            screenBounds: screen, frontmostPID: front,
            windows: FullScreenDetector.candidateWindows(in: mine, frontmostPID: front)))
    }

    /// Every app with a window on screen right now, read both ways.
    func testTheLiveWindowListReadsAsTheBridgedReadingDid() throws {
        let list = try XCTUnwrap(CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
        let owners = Set((list as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        // Without a window on screen both readings are empty and agree on
        // nothing; the synthetic lists above carry the assertions then.
        if owners.isEmpty { throw XCTSkip("no on-screen windows to compare") }
        for pid in owners.union([front]) {
            XCTAssertEqual(candidates(list, frontmostPID: pid),
                           bridgedCandidates(list, frontmostPID: pid), "pid \(pid)")
        }
    }
}
