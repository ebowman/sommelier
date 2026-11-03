import CoreGraphics
import Foundation

public struct MenuBarScanner {
    public var source: any AccessibilitySource
    public var includeSelf: Bool
    /// Strip used when the MenuBarAgent window frame is unavailable (main screen, y < 40).
    public var fallbackStrip: CGRect
    /// Debug logger (e.g. AX read failures). Default discards.
    public var log: @Sendable (String) -> Void
    /// Messaging timeout for the sequential retry of apps whose first read failed.
    public var retryTimeout: Float

    public init(source: any AccessibilitySource = LiveAccessibilitySource(),
                includeSelf: Bool = false,
                fallbackStrip: CGRect = CGRect(x: -100_000, y: 0, width: 200_000, height: 40),
                retryTimeout: Float = 1.0,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.retryTimeout = retryTimeout
        self.log = log
        self.source = source
        self.includeSelf = includeSelf
        self.fallbackStrip = fallbackStrip
    }

    static let maxConcurrency = 8

    private func parallelMap<T, R>(_ input: [T], workers: Int = MenuBarScanner.maxConcurrency,
                                   _ f: @Sendable (T) -> R) -> [R] where T: Sendable, R: Sendable {
        let box = ResultBox<R>(count: input.count)
        let next = Counter()
        let n = min(workers, max(1, input.count))
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            while let i = next.take(upTo: input.count) { box.set(i, f(input[i])) }
        }
        return box.values.map { $0! }
    }

    private struct Candidate {
        var app: RunningAppInfo
        var info: AXElementInfo
    }

    public func scan() -> MenuBarSnapshot {
        let apps = source.runningApps()
        let agent = apps.first { $0.bundleID == menuBarAgentBundleID }
        let myPID = source.currentPID

        let source = self.source
        let log = self.log
        let t0 = Date()
        func lap(_ what: String) { log("phase \(what) at \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }

        // 1. The agent tree is the authoritative visible set: read it first, alone (no contention),
        //    and retry the whole read if it comes back empty.
        var tree = AgentHostedTree(stripFrame: nil, elements: [])
        if let agent {
            for attempt in 1...3 {
                tree = source.agentHostedTree(for: agent)
                if !tree.elements.isEmpty { break }
                log("MenuBarAgent hosted tree empty (attempt \(attempt))")
            }
        }

        lap("agent tree")
        // 2. Query apps through a small worker pool: unbounded fan-out makes every call hit its timeout.
        let queried = apps.filter { $0.bundleID != menuBarAgentBundleID && (includeSelf || $0.pid != myPID) }
        var reads = parallelMap(queried) { source.readExtras(for: $0, timeout: nil) }

        lap("parallel app pass")
        // 3. Retry failed/timed-out apps once with a longer timeout.
        let retryTimeout = self.retryTimeout
        let failedIdx = reads.indices.filter { if case .failed = reads[$0] { return true } else { return false } }
        if !failedIdx.isEmpty {
            let retried = parallelMap(failedIdx.map { queried[$0] }, workers: 4) {
                source.readExtras(for: $0, timeout: retryTimeout)
            }
            for (k, i) in failedIdx.enumerated() { reads[i] = retried[k] }
        }
        lap("retry pass")
        var failedApps: [RunningAppInfo] = []
        var candidates: [Candidate] = []
        for (app, read) in zip(queried, reads) {
            switch read {
            case .items(let infos):
                for info in infos { candidates.append(Candidate(app: app, info: info)) }
            case .failed(let why):
                failedApps.append(app)
                log("AX read failed for \(app.name) (\(app.bundleID ?? "?"), pid \(app.pid)): \(why)")
            }
        }
        let strip = tree.stripFrame ?? fallbackStrip

        // Dedupe hosted elements (group + button may both report the same item).
        var hosted: [AXElementInfo] = []
        for e in tree.elements where !hosted.contains(where: {
            $0.frame == e.frame && $0.identifier == e.identifier && $0.axDescription == e.axDescription && $0.title == e.title
        }) { hosted.append(e) }

        // Join: identifier, then description, then frame intersection. Each app item matches at most once.
        var matchedCandidates = Set<Int>()
        var matchedHosted = Set<Int>()
        func pass(_ matches: (AXElementInfo, AXElementInfo) -> Bool) {
            for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) {
                if let ci = candidates.indices.first(where: {
                    !matchedCandidates.contains($0) && matches(h, candidates[$0].info)
                }) {
                    matchedHosted.insert(hi); matchedCandidates.insert(ci)
                }
            }
        }
        pass { !$0.identifier.isEmpty && $0.identifier == $1.identifier }
        pass { !$0.axDescription.isEmpty && $0.axDescription == $1.axDescription }
        pass { h, c in
            guard h.frame.width > 0, c.frame.width > 0 else { return false }
            let i = h.frame.intersection(c.frame)
            return !i.isNull && i.width > 0 && i.height > 0
        }

        // Identifier-prefix attribution: hosted element id "com.bjango.istatmenus.weather" belongs to a
        // failed-read app whose bundle id is a reverse-DNS prefix relative (com.bjango.istatmenus.status).
        func relatedPrefixes(_ bundle: String) -> [String] {
            var out = [bundle + "."]
            var comps = bundle.split(separator: ".").map(String.init)
            comps.removeLast()
            if comps.count >= 3 { out.append(comps.joined(separator: ".") + ".") }
            return out
        }
        var attributed: [(Int, RunningAppInfo)] = []
        for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) && !h.identifier.isEmpty {
            let owners = failedApps.filter { app in
                guard let b = app.bundleID else { return false }
                return relatedPrefixes(b).contains { h.identifier.hasPrefix($0) }
            }
            if let owner = owners.max(by: { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }) {
                matchedHosted.insert(hi)
                attributed.append((hi, owner))
            }
        }

        func onBar(_ f: CGRect) -> Bool {
            f.width > 0 && f.height > 0 && f.midY >= strip.minY && f.midY <= strip.maxY
        }

        var items: [MenuBarItem] = candidates.map { c in
            MenuBarItem(ownerPID: c.app.pid, ownerBundleID: c.app.bundleID, ownerName: c.app.name,
                        title: c.info.title, axDescription: c.info.axDescription,
                        axIdentifier: c.info.identifier, frame: c.info.frame,
                        source: .appExtras, isOnMenuBar: onBar(c.info.frame), axElement: c.info.element)
        }
        for (hi, owner) in attributed {
            let h = hosted[hi]
            items.append(MenuBarItem(
                ownerPID: owner.pid, ownerBundleID: owner.bundleID, ownerName: owner.name,
                title: h.title, axDescription: h.axDescription, axIdentifier: h.identifier,
                frame: h.frame, source: .appExtras, isOnMenuBar: onBar(h.frame), axElement: h.element))
        }
        if let agent {
            for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) {
                items.append(MenuBarItem(
                    ownerPID: agent.pid, ownerBundleID: agent.bundleID,
                    ownerName: h.axDescription.isEmpty ? "System item" : h.axDescription,
                    title: h.title, axDescription: h.axDescription, axIdentifier: h.identifier,
                    frame: h.frame, source: .agentHostedOnly, isOnMenuBar: onBar(h.frame),
                    axElement: h.element))
            }
        }

        // Stable partition: on-bar sorted by minX (ties keep discovery order), parked in discovery order.
        let indexed = Array(items.enumerated())
        let on = indexed.filter { $0.element.isOnMenuBar }
            .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }
        let off = indexed.filter { !$0.element.isOnMenuBar }
        return MenuBarSnapshot(items: (on + off).map(\.element), capturedAt: Date())
    }
}

/// Lock-protected slot array for concurrent result collection.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [T?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: T) { lock.lock(); slots[i] = v; lock.unlock() }
    var values: [T?] { lock.lock(); defer { lock.unlock() }; return slots }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func take(upTo limit: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard n < limit else { return nil }
        n += 1
        return n - 1
    }
}
