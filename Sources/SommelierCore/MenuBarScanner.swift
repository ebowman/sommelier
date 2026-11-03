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
    /// Cap (seconds) for the whole per-app extras phase of a full scan, retries included.
    public var extrasBudget: TimeInterval
    /// How long (seconds) an app whose extras read succeeded empty is skipped by later full scans of this scanner.
    public var emptyTTL: TimeInterval
    /// Overall deadline (seconds) of the fast path's agent-tree read.
    public var fastDeadline: TimeInterval = 0.3
    private let state: ScanState

    /// - Parameter cacheURL: when set, the scan cache is loaded from / saved to this file, so a new process starts warm.
    public init(source: any AccessibilitySource = LiveAccessibilitySource(),
                includeSelf: Bool = false,
                fallbackStrip: CGRect = CGRect(x: -100_000, y: 0, width: 200_000, height: 40),
                retryTimeout: Float = 1.0,
                extrasBudget: TimeInterval = 1.5,
                emptyTTL: TimeInterval = 20,
                cacheURL: URL? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.retryTimeout = retryTimeout
        self.extrasBudget = extrasBudget
        self.emptyTTL = emptyTTL
        self.log = log
        self.source = source
        self.includeSelf = includeSelf
        self.fallbackStrip = fallbackStrip
        self.state = ScanState(url: cacheURL)
    }

    public static var defaultCacheURL: URL { ScanState.defaultURL }
    /// True when this scanner has app-side data (from an earlier full scan or the cache file) for owner attribution.
    public var isWarm: Bool { state.loadIfNeeded(); return state.hasFullScan }

    static let maxConcurrency = 8

    private struct Candidate {
        var app: RunningAppInfo
        var info: AXElementInfo
        var stale = false
    }

    // MARK: - Agent tree

    /// Longest an item may be carried forward as stale before it is believed gone.
    static let maxStaleScans = 3

    /// Reads the MenuBarAgent tree. Items whose element read specifically timed out are carried forward from the
    /// previous scan (marked stale, bounded by `maxStaleScans`, dropped if their owner quit). An item that is merely
    /// absent is gone, after one confirming re-read.
    private func readHosted(agent: RunningAppInfo?, apps: [RunningAppInfo], retry: Bool, lap: (String) -> Void) -> AgentHostedTree {
        guard let agent else { return AgentHostedTree(stripFrame: nil, elements: []) }
        let src = source
        let fastDeadline = self.fastDeadline
        func readOnce() -> AgentHostedTree {
            if retry { return src.agentHostedTree(for: agent, retry: true) }
            // Backstop: whatever the source does, the fast path returns by the deadline (plus a little grace).
            let res = boundedParallelMap([agent], workers: 1, deadline: Date().addingTimeInterval(fastDeadline + 0.15)) {
                src.agentHostedTree(for: $0, retry: false)
            }
            if let t = res.first ?? nil { return t }
            log("MenuBarAgent hosted read missed the \(Int(fastDeadline * 1000)) ms deadline; carrying previous items")
            let prev = state.lastHosted.filter { $0.frame.width > 0 && $0.frame.height > 0 }
            return AgentHostedTree(stripFrame: nil, elements: [], failedReads: 1, timedOut: prev)
        }
        var tree = AgentHostedTree(stripFrame: nil, elements: [])
        for attempt in 1...(retry ? 3 : 1) {
            tree = readOnce()
            if !tree.elements.isEmpty || !tree.timedOut.isEmpty { break }
            log("MenuBarAgent hosted tree empty (attempt \(attempt))")
        }
        lap("agent tree read (\(tree.elements.count) elements, \(tree.failedReads) failed reads, \(tree.timedOut.count) timed out)")
        let strip = tree.stripFrame ?? state.lastStrip ?? fallbackStrip
        func onBar(_ f: CGRect) -> Bool { f.width > 0 && f.height > 0 && f.midY >= strip.minY && f.midY <= strip.maxY }
        let previous = state.lastHosted.filter { onBar($0.frame) }
        func missing(_ t: AgentHostedTree) -> [AXElementInfo] {
            let keys = Set(t.elements.map(\.identityKey)).union(t.timedOut.map(\.identityKey))
            return previous.filter { !keys.contains($0.identityKey) }
        }
        // Absent without any read error: either gone or a transient gap (agent mid-relayout). Look once more.
        if !previous.isEmpty, tree.unnamedTimeouts == 0, !missing(tree).isEmpty, !tree.elements.isEmpty || retry {
            log("\(missing(tree).count) previously visible item(s) absent; re-reading to confirm")
            let again = readOnce()
            let have = Set(again.elements.map(\.identityKey))
            let firstOnly = tree.elements.filter { !have.contains($0.identityKey) }
            tree = AgentHostedTree(stripFrame: again.stripFrame ?? tree.stripFrame, elements: again.elements + firstOnly,
                                   failedReads: again.failedReads, timedOut: again.timedOut + tree.timedOut,
                                   unnamedTimeouts: again.unnamedTimeouts)
            lap("agent tree confirm read")
        }

        // Carry forward only elements whose own read timed out.
        let running = Set(apps.map(\.pid))
        let freshKeys = Set(tree.elements.map(\.identityKey))
        var seen = Set<String>()
        var carried: [AXElementInfo] = []
        // Groups that timed out without the source knowing their contents: carry what was visible before and is
        // missing now (still bounded by the stale-scan cap and the owner check below).
        var candidatesToCarry = tree.timedOut
        if tree.unnamedTimeouts > 0 { candidatesToCarry += missing(tree) }
        for t in candidatesToCarry where !freshKeys.contains(t.identityKey) && seen.insert(t.identityKey).inserted {
            let prior = state.lastHosted.first { $0.identityKey == t.identityKey }
            let count = (prior?.staleCount ?? 0) + 1
            if count > Self.maxStaleScans {
                log("dropping \(t.identityKey): stale for \(count - 1) consecutive scans"); continue
            }
            if ownerGone(t, running: running) {
                log("dropping \(t.identityKey): owning app is no longer running"); continue
            }
            var s = t; s.stale = true; s.staleCount = count; s.element = nil
            carried.append(s)
        }
        if !carried.isEmpty { log("carried \(carried.count) item(s) forward as stale (read timed out)") }
        tree.elements += carried
        state.lastHosted = tree.elements
        if let s = tree.stripFrame { state.lastStrip = s }
        return tree
    }

    /// True when the item matches cached extras of app(s) that are all no longer running.
    private func ownerGone(_ e: AXElementInfo, running: Set<pid_t>) -> Bool {
        var owners: [pid_t] = []
        for (pid, c) in state.perApp where c.infos.contains(where: {
            (!e.identifier.isEmpty && $0.identifier == e.identifier) || (e.identifier.isEmpty && !e.axDescription.isEmpty && $0.axDescription == e.axDescription)
        }) { owners.append(pid) }
        return !owners.isEmpty && !owners.contains { running.contains($0) }
    }

    // MARK: - Public scans

    /// Fast path: reads only the MenuBarAgent hosted tree. Owners are attributed from the cache populated by the
    /// last full scan (same join rules); hosted items that match nothing are `agentHostedOnly`.
    public func scanVisible() -> MenuBarSnapshot {
        state.loadIfNeeded()
        let apps = source.runningApps()
        let agent = apps.first { $0.bundleID == menuBarAgentBundleID }
        let myPID = source.currentPID
        let t0 = Date()
        let log = self.log
        func lap(_ what: String) { log("fast phase \(what) at \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        let tree = readHosted(agent: agent, apps: apps, retry: false, lap: lap)
        let queried = apps.filter { $0.bundleID != menuBarAgentBundleID && (includeSelf || $0.pid != myPID) }
        var candidates: [Candidate] = []
        for c in state.validCached(running: queried) {
            for info in c.infos { candidates.append(Candidate(app: c.app, info: info)) }
        }
        state.save()
        return assemble(agent: agent, tree: tree, candidates: candidates, failedApps: [], verifiedOnly: true,
                        carryUnverified: tree.failedReads > 0 && tree.unnamedTimeouts > 0)
    }

    public func scan() -> MenuBarSnapshot {
        state.loadIfNeeded()
        let apps = source.runningApps()
        let agent = apps.first { $0.bundleID == menuBarAgentBundleID }
        let myPID = source.currentPID

        let source = self.source
        let log = self.log
        let t0 = Date()
        func lap(_ what: String) { log("phase \(what) at \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }

        // 1. Query apps through a small worker pool (unbounded fan-out makes every call hit its timeout), under a
        //    wall-clock budget for the whole phase. It runs on a background thread while the agent tree is read:
        //    MenuBarAgent's slow answers (it forwards each query to the owning app) overlap with the app pass.
        let queried = apps.filter { $0.bundleID != menuBarAgentBundleID && (includeSelf || $0.pid != myPID) }
        let phaseStart = Date()
        let deadline = phaseStart.addingTimeInterval(extrasBudget)
        let skip: Set<pid_t> = Set(queried.filter { a in
            if let t = state.emptyAt[a.pid], phaseStart.timeIntervalSince(t) < emptyTTL { return true }
            return false
        }.map(\.pid))
        let toRead = queried.filter { !skip.contains($0.pid) }
        let retryTimeoutSetting = self.retryTimeout
        let chronic = state.chronic
        let extrasDone = DispatchGroup()
        let holder = Holder<[ExtrasRead?]>()
        extrasDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var reads: [ExtrasRead?] = boundedParallelMap(toRead, workers: Self.maxConcurrency, deadline: deadline) {
                source.readExtras(for: $0, timeout: nil)
            }
            // Retry failed/timed-out apps once with a longer timeout, within what is left of the budget. Apps that
            // failed even their retry last time are not retried again (they cost the whole retry window).
            let failedIdx = reads.indices.filter { if case .failed = reads[$0] { return true } else { return false } }
            let retryIdx = failedIdx.filter { !chronic.contains(toRead[$0].pid) }
            if !retryIdx.isEmpty, deadline.timeIntervalSinceNow > 0.15 {
                let retryTimeout = min(retryTimeoutSetting, Float(deadline.timeIntervalSinceNow))
                let retried = boundedParallelMap(retryIdx.map { toRead[$0] }, workers: 4, deadline: deadline) {
                    source.readExtras(for: $0, timeout: retryTimeout)
                }
                for (k, i) in retryIdx.enumerated() { if let r = retried[k] { reads[i] = r } }
            }
            holder.value = reads
            extrasDone.leave()
        }

        // 2. The agent tree is the authoritative visible set.
        let tree = readHosted(agent: agent, apps: apps, retry: true, lap: lap)
        lap("agent tree")
        extrasDone.wait()
        lap("app pass")
        let reads = holder.value ?? []

        var failedApps: [RunningAppInfo] = []
        var candidates: [Candidate] = []
        let now = Date()
        for (app, read) in zip(toRead, reads) {
            switch read {
            case .items(let infos)?:
                state.perApp[app.pid] = CachedApp(app: app, infos: infos)
                state.emptyAt[app.pid] = infos.isEmpty ? now : nil
                for info in infos { candidates.append(Candidate(app: app, info: info)) }
            case .failed(let why)?:
                log("AX read failed for \(app.name) (\(app.bundleID ?? "?"), pid \(app.pid)): \(why)")
                fallBack(app, &candidates, &failedApps)
            case nil:
                log("extras budget (\(Int(extrasBudget * 1000)) ms) missed for \(app.name) (\(app.bundleID ?? "?"), pid \(app.pid))")
                fallBack(app, &candidates, &failedApps)
            }
        }
        // Skipped (recently empty) apps contribute nothing, but keep candidate order = discovery order.
        let order = Dictionary(queried.enumerated().map { ($1.pid, $0) }, uniquingKeysWith: { a, _ in a })
        candidates.sort { (order[$0.app.pid] ?? 0) < (order[$1.app.pid] ?? 0) }
        state.chronic = Set(failedApps.map(\.pid))
        state.hasFullScan = true
        state.save()
        return assemble(agent: agent, tree: tree, candidates: candidates, failedApps: failedApps)
    }

    /// An app whose read failed or missed the budget keeps its items from the previous scan (marked stale).
    private func fallBack(_ app: RunningAppInfo, _ candidates: inout [Candidate], _ failedApps: inout [RunningAppInfo]) {
        failedApps.append(app)
        if let c = state.perApp[app.pid], c.app.bundleID == app.bundleID, !c.infos.isEmpty {
            log("using \(c.infos.count) cached item(s) for \(app.name)")
            for info in c.infos { candidates.append(Candidate(app: app, info: info, stale: true)) }
        }
    }

    // MARK: - Join

    private func assemble(agent: RunningAppInfo?, tree: AgentHostedTree, candidates: [Candidate],
                          failedApps: [RunningAppInfo], verifiedOnly: Bool = false,
                          carryUnverified: Bool = false) -> MenuBarSnapshot {
        let strip = tree.stripFrame ?? state.lastStrip ?? fallbackStrip

        // Dedupe hosted elements (group + button may both report the same item).
        var hosted: [AXElementInfo] = []
        for e in tree.elements where !hosted.contains(where: {
            $0.frame == e.frame && $0.identifier == e.identifier && $0.axDescription == e.axDescription && $0.title == e.title
        }) { hosted.append(e) }

        // Join: identifier, then description, then frame intersection. Each app item matches at most once.
        var matchedCandidates: [Int: AXElementInfo] = [:]
        var matchedHosted = Set<Int>()
        func pass(_ matches: (AXElementInfo, AXElementInfo) -> Bool) {
            for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) {
                if let ci = candidates.indices.first(where: {
                    matchedCandidates[$0] == nil && matches(h, candidates[$0].info)
                }) {
                    matchedHosted.insert(hi); matchedCandidates[ci] = h
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

        var items: [MenuBarItem] = []
        var carriedUnverified: [String: Int] = [:]
        for (ci, c) in candidates.enumerated() {
            // The fast path never re-reads apps, so a cached app item the agent tree does not show is unverified.
            // Exception: while some agent group provably timed out, an on-bar cached item (freshly read from its
            // owning app, which is running) is carried as stale for at most `maxStaleScans` consecutive scans.
            var carriedCount = 0
            if let h = matchedCandidates[ci], h.stale { carriedUnverified["\(c.app.pid)|\(c.info.identityKey)"] = h.staleCount }
            let ckey = "\(c.app.pid)|\(c.info.identityKey)"
            // Only items that the agent tree showed in the last full scan are expected there; app-only items (e.g.
            // SystemUIServer's) never appear in it and are taken from the cache as before.
            if verifiedOnly && matchedCandidates[ci] == nil && state.hostedKeys.contains(ckey) {
                let key = ckey
                let n = (state.unverifiedCount[key] ?? 0) + 1
                guard carryUnverified, onBar(c.info.frame), n <= Self.maxStaleScans else { continue }
                carriedUnverified[key] = n
                carriedCount = n
            }
            // A candidate verified by the hosted tree takes the hosted (authoritative, fresh) frame and is not stale.
            let h = matchedCandidates[ci]
            let frame = h?.frame ?? c.info.frame
            items.append(MenuBarItem(
                ownerPID: c.app.pid, ownerBundleID: c.app.bundleID, ownerName: c.app.name,
                title: c.info.title, axDescription: c.info.axDescription,
                axIdentifier: c.info.identifier, frame: frame,
                source: .appExtras, isOnMenuBar: onBar(frame), axElement: c.info.element,
                stale: h == nil ? (c.stale || carriedCount > 0) : h!.stale,
                staleCount: h?.staleCount ?? carriedCount))
        }
        for (hi, owner) in attributed {
            let h = hosted[hi]
            items.append(MenuBarItem(
                ownerPID: owner.pid, ownerBundleID: owner.bundleID, ownerName: owner.name,
                title: h.title, axDescription: h.axDescription, axIdentifier: h.identifier,
                frame: h.frame, source: .appExtras, isOnMenuBar: onBar(h.frame), axElement: h.element, stale: h.stale, staleCount: h.staleCount))
        }
        if let agent {
            for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) {
                items.append(MenuBarItem(
                    ownerPID: agent.pid, ownerBundleID: agent.bundleID,
                    ownerName: h.axDescription.isEmpty ? "System item" : h.axDescription,
                    title: h.title, axDescription: h.axDescription, axIdentifier: h.identifier,
                    frame: h.frame, source: .agentHostedOnly, isOnMenuBar: onBar(h.frame),
                    axElement: h.element, stale: h.stale, staleCount: h.staleCount))
            }
        }

        if verifiedOnly {
            state.unverifiedCount = carriedUnverified
        } else {
            let matchedKeys = Set(matchedCandidates.keys.map { "\(candidates[$0].app.pid)|\(candidates[$0].info.identityKey)" })
            state.hostedKeys = tree.failedReads == 0 ? matchedKeys : state.hostedKeys.union(matchedKeys)
        }

        // Stable partition: on-bar sorted by minX (ties keep discovery order), parked in discovery order.
        let indexed = Array(items.enumerated())
        let on = indexed.filter { $0.element.isOnMenuBar }
            .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }
        let off = indexed.filter { !$0.element.isOnMenuBar }
        return MenuBarSnapshot(items: (on + off).map(\.element), capturedAt: Date())
    }
}

private final class Holder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
