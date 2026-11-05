import Foundation
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SommelierCore

// gdu.104: read-only measurement. Captures ONLY the menu bar strip of the main display (never the full screen) and compares the
// blobs drawn there with the live scanner's on-bar items. No drags, no plist writes. Needs the Screen Recording permission.

/// Receives strip frames, segments each one immediately and keeps only the derived blob rects (the pixel buffer is never retained).
final class StripFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let scale: CGFloat, originX: CGFloat, stripHeight: CGFloat
    private var blobs: [CGRect] = []
    private var previous: [CGRect]? = nil
    private var movedSinceTake = false
    private(set) var frames = 0

    init(scale: CGFloat, originX: CGFloat, stripHeight: CGFloat) {
        self.scale = scale; self.originX = originX; self.stripHeight = stripHeight
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Skip idle/blank status frames (no new content).
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h)
        let occ = StripSegmenter.occupancy(width: w, height: h, bgra: buf, bytesPerRow: bpr, background: nil)
        let segs = StripSegmenter.segments(occupied: occ, scale: scale, originX: originX, stripY: 0, stripHeight: stripHeight)
        lock.lock(); defer { lock.unlock() }
        if let p = previous, Self.differ(p, segs) { movedSinceTake = true }
        previous = segs; blobs = segs; frames += 1
    }

    /// Latest blobs, and whether any frame since the last call changed the blob set by more than 2 pt.
    func take() -> (blobs: [CGRect], moving: Bool, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let m = movedSinceTake; movedSinceTake = false
        return (blobs, m, frames)
    }

    static func differ(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        guard a.count == b.count else { return true }
        return zip(a, b).contains { abs($0.minX - $1.minX) > 2 || abs($0.maxX - $1.maxX) > 2 }
    }
}

private func errPrint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func runPixelWatch(_ a: [String]) async {
    var seconds: Double? = nil, out: String? = nil, fps = 15, intervalMS = 500
    var i = 0
    func val() -> String { i += 1; guard i < a.count else { usage() }; return a[i] }
    while i < a.count {
        switch a[i] {
        case "--seconds": guard let n = Double(val()), n > 0 else { usage() }; seconds = n
        case "--out": out = val()
        case "--fps": guard let n = Int(val()), (1...60).contains(n) else { usage() }; fps = n
        case "--interval-ms": guard let n = Int(val()), n >= 50 else { usage() }; intervalMS = n
        default: usage()
        }
        i += 1
    }
    guard let seconds, let out else { usage() }

    guard let content = try? await SCShareableContent.current else {
        errPrint("mbprobe pixelwatch: cannot read shareable content (no Screen Recording permission?).")
        errPrint("Grant Screen Recording to mbprobe's terminal in System Settings > Privacy & Security > Screen Recording, then rerun")
        exit(2)
    }
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        errPrint("mbprobe pixelwatch: no display found"); exit(1)
    }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let stripH = NSStatusBar.system.thickness
    let originX = CGFloat(display.frame.minX)
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: stripH)   // display points, strip only
    cfg.width = Int((CGFloat(display.width) * scale).rounded())
    cfg.height = Int((stripH * scale).rounded())
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    cfg.capturesShadowsOnly = false
    cfg.queueDepth = 3
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let sink = StripFrameSink(scale: scale, originX: originX, stripHeight: stripH)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    do {
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pixelwatch.frames"))
        try await stream.startCapture()
    } catch {
        errPrint("mbprobe pixelwatch: capture failed to start: \(error)")
        errPrint("Grant Screen Recording to mbprobe's terminal in System Settings > Privacy & Security > Screen Recording, then rerun")
        exit(2)
    }

    FileManager.default.createFile(atPath: out, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: out) else { errPrint("mbprobe pixelwatch: cannot open \(out)"); exit(1) }
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]

    final class Stop: @unchecked Sendable { var flag = false }
    let stop = Stop()
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { stop.flag = true }
    sig.resume()

    let scanner = MenuBarScanner()   // live read, NOT the SOMMELIER_PROBE_CACHE cache; element caches persist across samples
    let resolver = IdentityResolver()
    let t0 = Date()
    var samples: [PixelSample] = [], scanTimes: [Double] = []
    var lastSig: [String]? = nil
    var lastProgress = 0.0
    errPrint("pixelwatch: \(Int(seconds)) s, strip \(Int(CGFloat(display.width)))x\(Int(stripH)) pt @\(scale)x, \(fps) fps, sample every \(intervalMS) ms -> \(out)")
    while !stop.flag {
        let now = Date().timeIntervalSince(t0)
        if now >= seconds { break }
        let frame = sink.take()
        let snap = scanner.scan()
        let tScan = Date().timeIntervalSince(t0)
        let resolved = resolver.resolve(snapshot: snap)
        // Items MenuBarAgent reports on the bar and that macOS draws (system-overflow items are clipped, nothing is drawn).
        let onBar = resolved.filter { $0.item.isOnMenuBar && $0.item.frame.width > 0 && !$0.item.systemOverflow && !$0.item.isOverflowChevron }
        let sigNow = onBar.map { "\($0.key.description)@\(Int($0.item.frame.minX.rounded()))w\(Int($0.item.frame.width.rounded()))" }
        if let l = lastSig, l != sigNow { scanTimes.append(tScan) }
        lastSig = sigNow
        let latest = sink.take()
        var s = PixelSample.match(items: onBar.map { ($0.key.description, $0.item.frame, $0.item.stale) }, blobs: latest.blobs)
        s.t = tScan
        s.moving = frame.moving || latest.moving
        samples.append(s)
        if let line = try? enc.encode(s) { fh.write(line); fh.write(Data("\n".utf8)) }
        if tScan - lastProgress >= 30 {
            lastProgress = tScan
            errPrint(String(format: "pixelwatch: %.0f s, %d samples, %d frames, disagreeing so far %d", tScan, samples.count, latest.frames, samples.filter(\.disagrees).count))
        }
        let spent = Date().timeIntervalSince(t0) - tScan
        let wait = max(0.0, Double(intervalMS) / 1000 - spent - (tScan - now))
        // Sleep in small steps so SIGINT and the deadline are honoured promptly.
        var slept = 0.0
        while slept < wait, !stop.flag { try? await Task.sleep(for: .milliseconds(50)); slept += 0.05 }
    }
    try? await stream.stopCapture()
    let summary = PixelWatchSummary(samples: samples, scanTimes: scanTimes)
    print(summary.description)
    struct Final: Encodable { var summary: String; var samples: Int; var disagreementFraction: Double; var movingFrames: Int; var unnoticedMoving: Int }
    let f = Final(summary: summary.description, samples: summary.sampleCount, disagreementFraction: summary.disagreementFraction,
                  movingFrames: summary.movingFrames, unnoticedMoving: summary.unnoticedMoving)
    if let line = try? enc.encode(f) { fh.write(line); fh.write(Data("\n".utf8)) }
    try? fh.close()
}
