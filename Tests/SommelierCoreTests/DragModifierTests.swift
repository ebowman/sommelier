import XCTest
@testable import SommelierCore

private final class FakeModifierState: ModifierStateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Bool]
    private(set) var reads = 0
    init(_ script: [Bool]) { self.script = script }
    var isCommandLatched: Bool {
        lock.withLock { reads += 1; return script.count > 1 ? script.removeFirst() : (script.first ?? false) }
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CGEvent] = []
    func add(_ e: CGEvent) { lock.withLock { events.append(e) } }
    var all: [CGEvent] { lock.withLock { events } }
}

/// sommelier-9o9.20: the synthetic Command-drag must never leave Command latched. Hermetic: no real posting, no HID reads.
final class DragModifierTests: XCTestCase {
    private func captureDrag() -> [CGEvent] {
        let cap = Captured()
        let mover = DragMover(steps: 3, stepDelay: 0, holdTime: 0, poster: { cap.add($0) })
        let plan = DragPlan.make(from: CGPoint(x: 100, y: 10), toX: 160, steps: 3, stepDelay: 0, hold: 0)
        _ = mover.perform(plan: plan, src: nil, sleep: { _ in }, warp: { _ in })
        return cap.all
    }

    func testSequenceEndsWithFlaglessMouseUpThenCommandKeyUp() {
        let ev = captureDrag()
        XCTAssertGreaterThanOrEqual(ev.count, 3)
        let up = ev[ev.count - 2], key = ev[ev.count - 1]
        XCTAssertEqual(up.type, CGEventType.leftMouseUp)
        XCTAssertEqual(up.flags.intersection(.maskCommand), [])
        XCTAssertEqual(up.flags.rawValue & CGEventFlags.maskCommand.rawValue, 0)
        XCTAssertEqual(key.type, CGEventType.flagsChanged)
        XCTAssertEqual(key.getIntegerValueField(.keyboardEventKeycode), 0x37)
        XCTAssertFalse(key.flags.contains(.maskCommand))
    }

    func testDraggedEventsStillCarryCommand() {
        let ev = captureDrag().filter { $0.type == .leftMouseDown || $0.type == .leftMouseDragged }
        XCTAssertFalse(ev.isEmpty)
        for e in ev { XCTAssertTrue(e.flags.contains(.maskCommand)) }
    }

    func testPostCommandKeyUpUsesInjectedPoster() {
        let cap = Captured()
        XCTAssertTrue(DragMover(poster: { cap.add($0) }).postCommandKeyUp())
        XCTAssertEqual(cap.all.count, 1)
        XCTAssertEqual(cap.all[0].type, CGEventType.flagsChanged)
        XCTAssertEqual(cap.all[0].getIntegerValueField(.keyboardEventKeycode), 0x37)
    }

    func testSettleClearNoExtraKeyUp() {
        var posted = 0; var logs: [String] = []
        let ok = DragModifierGuard.settle(state: FakeModifierState([false]), postKeyUp: { posted += 1 }, sleep: { _ in }, log: { logs.append($0) })
        XCTAssertTrue(ok); XCTAssertEqual(posted, 0); XCTAssertTrue(logs.isEmpty)
    }

    func testSettleLatchedOnceOneExtraKeyUpThenClear() {
        var posted = 0; var logs: [String] = []
        let ok = DragModifierGuard.settle(state: FakeModifierState([true, false]), postKeyUp: { posted += 1 }, sleep: { _ in }, log: { logs.append($0) })
        XCTAssertTrue(ok); XCTAssertEqual(posted, 1)
        XCTAssertEqual(logs, ["drag: modifier still latched; posted key-up", "drag: modifier state clear"])
    }

    func testSettleStillLatchedNeverLoops() {
        var posted = 0; var logs: [String] = []
        let st = FakeModifierState([true])
        let ok = DragModifierGuard.settle(state: st, postKeyUp: { posted += 1 }, sleep: { _ in }, log: { logs.append($0) })
        XCTAssertFalse(ok); XCTAssertEqual(posted, 1); XCTAssertEqual(st.reads, 2)
        XCTAssertEqual(logs, ["drag: modifier still latched; posted key-up", "drag: modifier STILL latched"])
    }
}
