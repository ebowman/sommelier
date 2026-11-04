import CoreGraphics
import Foundation

/// Scan access used by the settle detector and the actuator (the live implementation wraps `MenuBarScanner`).
public protocol SnapshotScanning: Sendable {
    /// Fast path (agent tree only). For polling only: never the final verdict.
    func scanVisible() async -> MenuBarSnapshot
    /// Full scan: the only source of verification verdicts.
    func scan() async -> MenuBarSnapshot
}

public struct SettleOutcome: Sendable {
    /// The final full-scan snapshot (the verdict snapshot), or the last observation when `settled == false`.
    public var snapshot: MenuBarSnapshot
    /// True when two consecutive observations agreed AND no subject item was stale in the verdict snapshot.
    public var settled: Bool
    /// Number of fast polls and full scans performed.
    public var polls: Int
    public var fullScans: Int
    /// Seconds spent.
    public var elapsed: TimeInterval
}

/// Waits until the menu bar stops changing.
///
/// 1. Poll `scanVisible()` until two consecutive on-bar observations agree (same item keys in the same order,
///    frames within 1 pt, at least `stableFor` apart) or `maxWait` passes.
/// 2. Take a full `scan()` as the verdict snapshot. If phase 1 agreed, that is the answer. If it did not (e.g. the fast
///    path mislabels identifier-less items right after a move), require two consecutive full scans to agree.
/// A snapshot in which a subject item is stale never counts as settled (a stale frame is a cached value).
public struct SettleDetector: Sendable {
    public var scanner: any SnapshotScanning
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// Items the action is about; if one of them is stale in an observation, that observation cannot settle.
    public var isSubject: @Sendable (MenuBarItem) -> Bool
    /// Maximum number of full scans taken when the fast poll did not agree.
    public var maxFullScans = 3
    public static let frameTolerance: CGFloat = 1

    public init(scanner: any SnapshotScanning,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                isSubject: @escaping @Sendable (MenuBarItem) -> Bool = { _ in false }) {
        self.scanner = scanner; self.now = now; self.sleep = sleep; self.isSubject = isSubject
    }

    public static func key(_ i: MenuBarItem) -> String { ItemResolver.key(i) }

    /// Same on-bar keys in the same order with frames within 1 pt.
    public static func agree(_ a: MenuBarSnapshot, _ b: MenuBarSnapshot) -> Bool {
        let x = a.onBarLeftToRight, y = b.onBarLeftToRight
        guard x.count == y.count else { return false }
        for (p, q) in zip(x, y) {
            if key(p) != key(q) { return false }
            let f = p.frame, g = q.frame
            if abs(f.minX - g.minX) > frameTolerance || abs(f.maxX - g.maxX) > frameTolerance
                || abs(f.minY - g.minY) > frameTolerance || abs(f.maxY - g.maxY) > frameTolerance { return false }
        }
        return true
    }

    private func subjectStale(_ s: MenuBarSnapshot) -> Bool { s.items.contains { isSubject($0) && $0.stale } }

    public func settled(maxWait: TimeInterval = 3, stableFor: TimeInterval = 0.15) async -> SettleOutcome {
        let start = now()
        var polls = 0, fulls = 0
        var prev: (snap: MenuBarSnapshot, at: Date)?
        var fastAgreed = false
        while true {
            let snap = await scanner.scanVisible()
            polls += 1
            let t = now()
            if subjectStale(snap) {
                prev = nil
            } else if let p = prev, Self.agree(p.snap, snap) {
                if t.timeIntervalSince(p.at) >= stableFor - 1e-6 { fastAgreed = true; break }
            } else {
                prev = (snap, t)
            }
            if t.timeIntervalSince(start) >= maxWait { break }
            await sleep(stableFor)
        }
        var verdict = await scanner.scan()
        fulls += 1
        // A scan with no on-bar item at all is a failed read, never a verdict.
        for _ in 0..<2 where verdict.onBarLeftToRight.isEmpty { await sleep(0.3); verdict = await scanner.scan(); fulls += 1 }
        var ok = !subjectStale(verdict) && !verdict.onBarLeftToRight.isEmpty   // an empty scan never settles
        if !fastAgreed {
            ok = false
            while fulls < maxFullScans {
                let again = await scanner.scan()
                fulls += 1
                let agreed = Self.agree(verdict, again)
                verdict = again
                if agreed && !subjectStale(again) && !again.onBarLeftToRight.isEmpty { ok = true; break }
            }
        }
        return SettleOutcome(snapshot: verdict, settled: ok, polls: polls, fullScans: fulls,
                             elapsed: now().timeIntervalSince(start))
    }
}
