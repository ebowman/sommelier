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
    /// Why the detector did not accept a verdict or took extra scans (empty in the normal case).
    public var trace: String = ""
}

/// Waits until the menu bar stops changing.
///
/// 1. Poll `scanVisible()` until two consecutive on-bar observations agree (same item keys in the same order,
///    frames within 1 pt, at least `stableFor` apart) or `maxWait` passes.
/// 2. Take a full `scan()` as the verdict snapshot. If phase 1 agreed and the verdict agrees with the last fast observation
///    (`verdictAgrees`), that is the answer; if it disagrees, poll again (new fast pair, new verdict) until `maxWait` /
///    `maxFullScans`, then report not settled. If phase 1 did not agree (or the fast read was incomplete; e.g. the fast
///    path mislabels identifier-less items right after a move), require two consecutive full scans to agree.
/// A snapshot in which a subject item is stale never counts as settled (a stale frame is a cached value).
public struct SettleDetector: Sendable {
    public var scanner: any SnapshotScanning
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// Items the action is about; if one of them is stale in an observation, that observation cannot settle.
    public var isSubject: @Sendable (MenuBarItem) -> Bool
    /// Bounds the total number of full scans (verdicts and fallback re-reads), so a persistently disagreeing source cannot loop.
    public var maxFullScans: Int
    public static let frameTolerance: CGFloat = 1

    public init(scanner: any SnapshotScanning,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                isSubject: @escaping @Sendable (MenuBarItem) -> Bool = { _ in false },
                maxFullScans: Int = 3) {
        self.maxFullScans = maxFullScans
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

    /// Rule for "the verdict full scan agrees with the last fast observation" (gdu.27). Compared: the on-bar keys, in order
    /// (`key`, sorted by frame.minX), of the items that BOTH scans can know about. Left out of the comparison: items stale in
    /// either scan (a stale frame is a cached value; the key is dropped from both sides), noise elements (width <= 1), and
    /// self-positioning owners' items (their slots move on their own; `SelfPositioning.defaultOwners`). Frames are not
    /// compared (only the order). Parked/hidden set: required only when the fast scan reports parked items (every such key,
    /// same exclusions, must be parked in the verdict too); a fast scan that reports none says nothing about hiding.
    /// Our own status item is never in scanner output (`includeSelf` is false), so there is nothing to exclude.
    public static func verdictAgrees(fast: MenuBarSnapshot, verdict: MenuBarSnapshot) -> Bool {
        let owners = SelfPositioning.defaultOwners
        let excluded = Set((fast.items + verdict.items).filter { $0.stale }.map(key))
        func usable(_ i: MenuBarItem) -> Bool {
            i.frame.width > 1 && !i.stale && !excluded.contains(key(i)) && !SelfPositioning.matches(i, owners: owners)
        }
        func order(_ s: MenuBarSnapshot) -> [String] {
            s.onBarLeftToRight.enumerated().filter { usable($0.element) }
                .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }.map { key($0.element) }
        }
        guard order(fast) == order(verdict) else { return false }
        let fastParked = Set(fast.parked.filter { !$0.stale && !excluded.contains(key($0)) && !SelfPositioning.matches($0, owners: owners) }.map(key))
        if fastParked.isEmpty { return true }
        let verdictParked = Set(verdict.parked.map(key))
        return fastParked.isSubset(of: verdictParked)
    }

    public func settled(maxWait: TimeInterval = 3, stableFor: TimeInterval = 0.15) async -> SettleOutcome {
        let start = now()
        var polls = 0, fulls = 0
        var trace: [String] = []
        while true {
            var prev: (snap: MenuBarSnapshot, at: Date)?
            var fastAgreed = false
            var lastFast: MenuBarSnapshot?
            while true {
                let snap = await scanner.scanVisible()
                polls += 1
                let t = now()
                if subjectStale(snap) {
                    prev = nil
                } else if let p = prev, Self.agree(p.snap, snap) {
                    if t.timeIntervalSince(p.at) >= stableFor - 1e-6 { fastAgreed = true; lastFast = snap; break }
                } else {
                    prev = (snap, t)
                }
                if t.timeIntervalSince(start) >= maxWait { break }
                await sleep(stableFor)
            }
            if fastAgreed, lastFast?.completeness == .incomplete {
                fastAgreed = false
                trace.append("fast observation incomplete; requiring two agreeing full scans")
            }
            var verdict = await scanner.scan()
            fulls += 1
            // A scan with no on-bar item at all is a failed read, never a verdict.
            for _ in 0..<2 where verdict.onBarLeftToRight.isEmpty { await sleep(0.3); verdict = await scanner.scan(); fulls += 1 }
            var ok = !subjectStale(verdict) && !verdict.onBarLeftToRight.isEmpty   // an empty scan never settles
            if fastAgreed, ok, let f = lastFast, !Self.verdictAgrees(fast: f, verdict: verdict) {
                trace.append("verdict disagreed with fast observation (full scan \(fulls))")
                if fulls < maxFullScans, now().timeIntervalSince(start) < maxWait { continue }   // new fast pair, new verdict
                trace.append(fulls >= maxFullScans ? "maxFullScans reached" : "maxWait reached")
                ok = false
            } else if !fastAgreed {
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
                                 elapsed: now().timeIntervalSince(start), trace: trace.joined(separator: "; "))
        }
    }
}
