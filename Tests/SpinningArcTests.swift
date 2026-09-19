import AppKit
import XCTest
@testable import Codenotch

/// The working arc turns in Core Animation rather than SwiftUI, so what the
/// SwiftUI version said in its modifiers is pinned here on the layer instead.
@MainActor
final class SpinningArcTests: XCTestCase {
    private func hosted(_ view: SpinningArcView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: true)
        // Closed by the test while ARC still holds it.
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func arcView(queued: Bool = false, turns: Bool = true) -> SpinningArcView {
        let side = NotchLayout.ringDiameter
        let view = SpinningArcView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let inset = (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
        view.configure(color: .white, arcFraction: queued ? 1 : 0.25, dashed: queued,
                       inset: inset, turns: turns)
        view.layout()
        return view
    }

    func testTheArcIsAQuarterOfTheActivityCircle() {
        let view = arcView()
        XCTAssertEqual(view.arc.strokeStart, 0)
        XCTAssertEqual(view.arc.strokeEnd, 0.25)
        XCTAssertNil(view.arc.lineDashPattern)
        XCTAssertEqual(view.arc.lineWidth, NotchLayout.activityStroke)
        XCTAssertEqual(view.arc.lineCap, .round)

        let box = view.arc.path?.boundingBoxOfPath ?? .zero
        XCTAssertEqual(box.width, NotchLayout.activityDiameter, accuracy: 0.01,
                       "The arc must sit on the same circle the SwiftUI inset produced")
        XCTAssertEqual(box.midX, view.bounds.midX, accuracy: 0.01)
        XCTAssertEqual(box.midY, view.bounds.midY, accuracy: 0.01)
    }

    func testQueuedRequestsDrawTheWholeCircleAsDots() {
        let view = arcView(queued: true)
        XCTAssertEqual(view.arc.strokeEnd, 1)
        XCTAssertEqual(view.arc.lineDashPattern?.count, 2)
    }

    func testItTurnsClockwiseOnceEveryPointOneOneSecondsOnScreen() throws {
        let view = arcView()
        let window = hosted(view)
        defer { window.close() }

        let turn = try XCTUnwrap(view.arc.animation(forKey: SpinningArcView.animationKey) as? CABasicAnimation)
        XCTAssertEqual(turn.keyPath, "transform.rotation.z")
        XCTAssertEqual(turn.duration, 1.1)
        XCTAssertEqual(turn.repeatCount, .infinity)
        // y-up layer coordinates: a negative angle is a clockwise turn.
        XCTAssertEqual((turn.toValue as? Double) ?? 0, -2 * .pi, accuracy: 0.0001)
    }

    func testReduceMotionHoldsItStill() {
        let view = arcView(turns: false)
        let window = hosted(view)
        defer { window.close() }
        XCTAssertNil(view.arc.animation(forKey: SpinningArcView.animationKey))
    }

    func testItNeverTakesAClick() {
        let view = arcView()
        XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }
}

/// The blocked / finished ring pulses in Core Animation for the same reason
/// the arc turns there: a SwiftUI `repeatForever` re-lays-out the hosting view
/// on every frame.
@MainActor
final class PulsingRingTests: XCTestCase {
    private func ringView(pulses: Bool = true, dimmed: Float = 0.3) -> PulsingRingView {
        let side = NotchLayout.ringDiameter
        let view = PulsingRingView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let inset = (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
        view.configure(color: .white, inset: inset, dimmedOpacity: dimmed, pulses: pulses)
        view.layout()
        return view
    }

    private func hosted(_ view: PulsingRingView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    func testItDrawsTheWholeActivityCircle() {
        let view = ringView()
        XCTAssertEqual(view.ring.lineWidth, NotchLayout.activityStroke)
        let box = view.ring.path?.boundingBoxOfPath ?? .zero
        XCTAssertEqual(box.width, NotchLayout.activityDiameter, accuracy: 0.01)
        XCTAssertEqual(box.midX, view.bounds.midX, accuracy: 0.01)
    }

    func testItFadesAndReturnsForeverOnScreen() throws {
        let view = ringView(dimmed: 0.65)
        let window = hosted(view)
        defer { window.close() }

        let fade = try XCTUnwrap(view.ring.animation(forKey: PulsingRingView.animationKey) as? CABasicAnimation)
        XCTAssertEqual(fade.keyPath, "opacity")
        XCTAssertEqual(fade.duration, 0.9)
        XCTAssertTrue(fade.autoreverses)
        XCTAssertEqual(fade.repeatCount, .infinity)
        XCTAssertEqual((fade.toValue as? Float) ?? 0, 0.65, accuracy: 0.0001)
    }

    func testReduceMotionHoldsItStill() {
        let view = ringView(pulses: false)
        let window = hosted(view)
        defer { window.close() }
        XCTAssertNil(view.ring.animation(forKey: PulsingRingView.animationKey))
    }

    func testAnUnchangedUpdateDoesNotRestartThePulse() throws {
        let view = ringView()
        let window = hosted(view)
        defer { window.close() }
        let first = try XCTUnwrap(view.ring.animation(forKey: PulsingRingView.animationKey))
        view.configure(color: .white, inset: 3, dimmedOpacity: 0.3, pulses: true)
        XCTAssertTrue(first === view.ring.animation(forKey: PulsingRingView.animationKey))
    }

    func testItNeverTakesAClick() {
        XCTAssertNil(ringView().hitTest(NSPoint(x: 5, y: 5)))
    }
}
