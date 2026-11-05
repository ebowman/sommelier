import AppKit
import SommelierCore

/// Auto re-hide of an inline reveal (docs/architecture.md, App shell): after `autoRehideSeconds` without mouse activity over the
/// menu bar strip (0 = never), or once the menu of a clicked menu bar item has closed, whichever comes first. Runs only while
/// a reveal is requested. Same shape as the overflow panel's pointer machinery (100 ms tick, global NSEvent monitors).
@MainActor
final class RevealAutoRehide {
    private let state: EngineState
    private let controller: RevealController
    private let ownFrame: () -> CGRect?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastActivity = Date()
    private var requestedSince = Date()
    private var lastPointer: CGPoint = .zero
    /// A menu bar item was clicked (its menu is probably open): the idle timer is suspended until the menu closes.
    private var armedAt: Date?
    private var closeSeenAt: Date?

    /// The menu closing is detected from the next click outside the strip or Escape; it settles this long before the re-hide.
    static let settle: TimeInterval = 0.6
    /// A menu that is never seen closing (e.g. closed by clicking its own item) still ends the reveal after this.
    static let armedCap: TimeInterval = 20
    /// A reveal that never converges is withdrawn after this.
    static let convergeCap: TimeInterval = 20

    init(state: EngineState, controller: RevealController, ownFrame: @escaping () -> CGRect?) {
        self.state = state; self.controller = controller; self.ownFrame = ownFrame
    }

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastActivity = Date(); requestedSince = Date(); armedAt = nil; closeSeenAt = nil
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown], handler: { [weak self] ev in
            let type = ev.type, code = ev.keyCode
            MainActor.assumeIsolated { self?.event(type, keyCode: code) }
        }) { monitors.append(m) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        timer?.invalidate(); timer = nil
        armedAt = nil; closeSeenAt = nil
    }

    private func strip(at p: CGPoint) -> CGRect? {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main else { return nil }
        let h = max(NSStatusBar.system.thickness, s.frame.maxY - s.visibleFrame.maxY)
        return CGRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h)
    }

    private func overStrip(_ p: CGPoint) -> Bool { strip(at: p)?.contains(p) ?? false }

    private func event(_ type: NSEvent.EventType, keyCode: UInt16) {
        let p = NSEvent.mouseLocation, now = Date()
        switch type {
        case .keyDown:
            if keyCode == 53, armedAt != nil { closeSeenAt = now }   // Escape closes a menu
        case .leftMouseDown:
            if overStrip(p), !(ownFrame()?.contains(p) ?? false) { armedAt = now; closeSeenAt = nil; lastActivity = now }
        case .leftMouseUp:
            if overStrip(p) {
                lastActivity = now
            } else if armedAt != nil, closeSeenAt == nil {
                closeSeenAt = now   // a click below the strip while a menu is open: an entry chosen or the menu dismissed
            }
        default: break
        }
    }

    private func tick() {
        guard state.showHiddenSection || state.showAlwaysHidden else { stop(); return }
        let now = Date(), p = NSEvent.mouseLocation
        if !state.revealedObserved {
            lastActivity = now   // the idle clock starts when the reveal is observed, not when it was requested
            if now.timeIntervalSince(requestedSince) >= Self.convergeCap { controller.rehide(reason: "reveal never converged"); stop() }
            return
        }
        if overStrip(p), p != lastPointer || NSEvent.pressedMouseButtons != 0 { lastActivity = now }
        lastPointer = p
        if let c = closeSeenAt, now.timeIntervalSince(c) >= Self.settle {
            controller.rehide(reason: "menu bar item menu closed"); stop(); return
        }
        if let a = armedAt {
            if now.timeIntervalSince(a) >= Self.armedCap { controller.rehide(reason: "menu bar item clicked, close not seen"); stop() }
            return
        }
        let secs = UserDefaults.standard.object(forKey: "autoRehideSeconds") as? Int ?? 10
        if secs > 0, now.timeIntervalSince(lastActivity) >= Double(secs) { controller.rehide(reason: "idle \(secs) s"); stop() }
    }
}
