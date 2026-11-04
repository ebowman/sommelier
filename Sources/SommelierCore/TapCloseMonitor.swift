import CoreGraphics
import Foundation

/// Listen-only CGEvent tap (own thread and run loop, no AppKit event loop needed) feeding `ItemActivator` menu-close hints:
/// mouse-up anywhere and Escape. Used by `mbprobe`; the app uses `NSEventCloseMonitor`. If the tap cannot be created
/// (no Accessibility / Input Monitoring permission) it stays silent and the activator falls back to polling.
public final class TapCloseMonitor: CloseMonitoring, @unchecked Sendable {
    private let buffer = CloseEventBuffer()
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    public private(set) var tapCreated = false

    public init() {}

    public func start() {
        _ = buffer.drain()
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue) | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
                | CGEventMask(1 << CGEventType.keyDown.rawValue)
            let ref = Unmanaged.passUnretained(buffer).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                              eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let buf = Unmanaged<CloseEventBuffer>.fromOpaque(refcon).takeUnretainedValue()
                if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 { buf.push(.escape) }
                else if type == .leftMouseUp || type == .rightMouseUp { buf.push(.mouseUp(event.location)) }
                return Unmanaged.passUnretained(event)
            }, userInfo: ref) else { ready.signal(); return }
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let rl = CFRunLoopGetCurrent()
            lock.lock(); runLoop = rl; tapCreated = true; lock.unlock()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        thread = t
        lock.unlock()
        t.start()
        ready.wait()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let rl = runLoop { CFRunLoopStop(rl) }
        runLoop = nil; thread = nil
    }

    public func drain() -> [CloseEvent] { buffer.drain() }
}
