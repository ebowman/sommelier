import AppKit


/// Global NSEvent monitor feeding `ItemActivator` menu-close hints (mouse-up anywhere, Escape). Installed only while an
/// activation waits for its menu to close. Event points are converted to global top-left coordinates.
public final class NSEventCloseMonitor: CloseMonitoring, @unchecked Sendable {
    private let buffer = CloseEventBuffer()
    private let lock = NSLock()
    private var monitor: Any?

    public init() {}
    public func start() {
        _ = buffer.drain()
        DispatchQueue.main.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { [buffer] ev in
                if ev.type == .keyDown {
                    if ev.keyCode == 53 { buffer.push(.escape) }
                    return
                }
                let p = NSEvent.mouseLocation
                let h = NSScreen.screens.first?.frame.maxY ?? 0   // primary screen: origin of the global top-left space
                buffer.push(.mouseUp(CGPoint(x: p.x, y: h - p.y)))
            }
        }
    }

    public func stop() {
        DispatchQueue.main.async { [self] in
            lock.lock(); defer { lock.unlock() }
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }

    public func drain() -> [CloseEvent] { buffer.drain() }
}
