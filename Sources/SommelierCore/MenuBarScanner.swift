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
    /// Owners that re-position their own items and whose AX answers are slow (iStat); their stale items do not make a read
    /// "incomplete" for membership evidence (`ReadCompleteness`, gdu.51).
    public var selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners
    /// Longest a persisted self-positioning record may go without a complete read refreshing it before it stops attributing
    /// unnamed timeouts (gdu.54).
    public var selfPositioningRecordMaxAge: TimeInterval = 600
    /// Messaging timeout (seconds) of the extras read of an owner whose read failed even its retry in the previous full scan
    /// (gdu.51); the default timeout is used for every other owner. 0 = no cap.
    public var slowOwnerExtrasTimeout: Float = 0.3
    /// Control Center `isAllowed` readback for a tracked key (nil = unreadable); injectable for tests.
    public var allowedReadback: @Sendable (String) -> Bool? = { k in (try? ControlCenterTrackedAppsStore.allowedLive([k]))?[k] }
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

    /// Accessibility identifier of Sommelier's own status item button (set by the app). Its hosted element must never be
    /// attributed to another app's candidate by the frame join (it can sit on a stale frame of the same width).
    public static let ownStatusItemIdentifier = "ie.boboco.sommelier.statusitem"
    static func isOwnHostedElement(_ e: AXElementInfo) -> Bool {
        e.identifier == ownStatusItemIdentifier || (e.identifier.isEmpty && e.axDescription == "Sommelier")
    }

    /// Hard safety expiry of an assumed-hidden record (counted from when we recorded it).
    static let assumedHiddenHardExpiry: TimeInterval = 2 * 3600
    /// Minimum interval between Control Center `isAllowed` readbacks per assumed-hidden owner.
    static let assumedReadbackInterval: TimeInterval = 10

    /// Records that WE hid `pid`'s identifier-less items with a live write and the hosted tree lost exactly that unit's
    /// elements (`LiveActuator`, `ItemActivator`). Until contradicted (see `assemble`) such an owner's on-bar-framed,
    /// identifier-less candidates are reported hidden (`HiddenReason.assumedNotHosted`). Called ONLY with write-time
    /// evidence, never from frames.
    public func recordAssumedHidden(pid: pid_t, bundleID: String?, trackedKey: String? = nil, items: Int, hostedAfter: Int?, at: Date = Date()) {
        state.loadIfNeeded()
        state.assumedHidden[pid] = AssumedHidden(pid: pid, bundleID: bundleID, trackedKey: trackedKey, at: at, hostedAfter: hostedAfter, items: items)
        state.assumedCheckedAt[pid] = at
        log("assumed-hidden: recorded pid \(pid) (\(items) item(s), hosted after \(hostedAfter.map(String.init) ?? "?"))")
        state.save()
    }

    /// The last complete (attributed) hosted tree, if at most `maxAge` seconds old.
    public func recentCompleteHostedLayout(maxAge: TimeInterval) -> [HostedEntry]? {
        guard let l = state.lastCompleteLayout, Date().timeIntervalSince(l.at) <= maxAge else { return nil }
        return l.entries
    }

    /// The actuator is about to hide the unit owned by `pids`: its hosted elements legitimately vanish from the tree and must
    /// not count as a read defect (gdu.51). Expires after 60 s; `clearExpectedToVanish` ends it with the batch.
    public func expectToVanish(pids: Set<pid_t>) {
        state.loadIfNeeded()
        var keys = Set<String>()
        for p in pids { for i in state.perApp[p]?.infos ?? [] { keys.insert(i.identityKey) } }
        state.expectedToVanish = (keys, Date())
        log("expected to vanish: \(keys.sorted().joined(separator: ", "))")
    }

    public func clearExpectedToVanish() { state.expectedToVanish = nil }

    /// Forgets the assumed-hidden state of these owners (a show by us, a respawn, a failed attempt).
    public func clearAssumedHidden(pids: Set<pid_t>) {
        state.loadIfNeeded()
        let had = pids.filter { state.assumedHidden[$0] != nil }
        guard !had.isEmpty else { return }
        for p in had { state.assumedHidden[p] = nil }
        log("assumed-hidden: cleared pid(s) \(had.sorted().map(String.init).joined(separator: ","))")
        state.save()
    }

    /// MenuBarAgent respawned (gdu.21): forgets what was read from the old agent (last hosted tree, carried-forward stale
    /// items, the last complete layout, the strip frame, unverified counters) so nothing stale is reported as live.
    /// Keeps `assumedHidden` (the Control Center store still says hidden), the per-app caches and the seen-hosted names.
    public func invalidateAgentState() {
        state.loadIfNeeded()
        state.lastHosted = []
        state.lastCompleteLayout = nil
        state.lastStrip = nil
        state.unverifiedCount = [:]
        log("scanner: agent state invalidated")
    }

    /// The display configuration changed (gdu.21): the menu bar strip frame is recomputed from the next agent read.
    public func invalidateStrip() {
        state.loadIfNeeded()
        state.lastStrip = nil
    }

    /// Owners currently assumed live-hidden (diagnostics, tests).
    public var assumedHiddenPIDs: Set<pid_t> { state.loadIfNeeded(); return Set(state.assumedHidden.keys) }

    private struct Candidate {
        var app: RunningAppInfo
        var info: AXElementInfo
        var stale = false
    }

    // MARK: - Agent tree

    /// Removes the frontmost app's main-menu entries (`isMainMenuEntry`, gdu.29) from a hosted read: they are not status
    /// items. Nothing else is touched. If every timed-out element was such an entry (and nothing else failed), the failure
    /// was a main-menu group and is not counted.
    static func droppingMainMenu(_ t: AgentHostedTree) -> AgentHostedTree {
        guard t.elements.contains(where: \.isMainMenuEntry) || t.timedOut.contains(where: \.isMainMenuEntry) else { return t }
        var r = t
        r.elements = t.elements.filter { !$0.isMainMenuEntry }
        r.timedOut = t.timedOut.filter { !$0.isMainMenuEntry }
        if r.timedOut.isEmpty, !t.timedOut.isEmpty, t.unnamedTimeouts == 0, t.topFailures == 0 { r.failedReads = 0 }
        return r
    }

    /// Longest an item may be carried forward as stale before it is believed gone.
    static let maxStaleScans = 3

    /// Reads the MenuBarAgent tree. Items whose element read specifically timed out are carried forward from the
    /// previous scan (marked stale, bounded by `maxStaleScans`, dropped if their owner quit). An item that is merely
    /// absent is gone, after one confirming re-read.
    /// `ownExtras` (full scans only) returns the app-side extras read in THIS scan, by pid; it may block until they are in.
    private func readHosted(agent: RunningAppInfo?, apps: [RunningAppInfo], retry: Bool, lap: (String) -> Void,
                            ownExtras: (() -> [pid_t: [AXElementInfo]])? = nil) -> AgentHostedTree {
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
            tree = Self.droppingMainMenu(readOnce())
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
            let again = Self.droppingMainMenu(readOnce())
            let have = Set(again.elements.map(\.identityKey))
            let firstOnly = tree.elements.filter { !have.contains($0.identityKey) }
            tree = AgentHostedTree(stripFrame: again.stripFrame ?? tree.stripFrame, elements: again.elements + firstOnly,
                                   failedReads: again.failedReads, timedOut: again.timedOut + tree.timedOut,
                                   unnamedTimeouts: again.unnamedTimeouts, topFailures: again.topFailures + tree.topFailures)
            lap("agent tree confirm read")
        }

        // Carry forward only elements whose own read timed out.
        let running = Set(apps.map(\.pid))
        let freshKeys = Set(tree.elements.map(\.identityKey))
        var seen = Set<String>()
        var carried: [AXElementInfo] = []
        // Groups that timed out without the source knowing their contents: carry what was visible before and is
        // missing now (still bounded by the stale-scan cap and the owner check below).
        // Read noise (gdu.51): a zero-width element, or a nameless one parked at the menu bar strip's LEFT EDGE (gdu.54: the
        // strip's own minX, not x = 0, so an item on a display arranged left of the main one never matches), is the same class
        // as the main-menu noise; it never blocks completeness and is not carried forward.
        func isNoise(_ e: AXElementInfo) -> Bool {
            e.frame.width <= 1 || (e.identifier.isEmpty && e.axDescription.isEmpty && e.frame.minX >= strip.minX - 1 && e.frame.minX <= strip.minX + 1)
        }
        var candidatesToCarry = tree.timedOut.filter { !isNoise($0) }
        // Attribution by IDENTITY (gdu.51): every failed group is a self-positioning owner's when there is no top-level
        // failure, every named timeout carries a self-positioning element, and the unnamed timeouts are covered by
        // self-positioning elements that were hosted in the previous tree and are missing now, with NO other previously
        // hosted element missing and uncarried. Counts of the owner's cached items prove nothing.
        let owners = selfPositioningOwners
        func isSP(_ e: AXElementInfo) -> Bool { SelfPositioning.matches(identifier: e.identifier, owners: owners) }
        for e in tree.timedOut where isNoise(e) && state.loggedNoise.insert(e.identityKey).inserted {
            log("ignored noise element (frame \(Int(e.frame.minX)),\(Int(e.frame.minY)) w\(Int(e.frame.width)))")
        }
        // Elements that legitimately left the tree are not "missing": the actuator is hiding their unit, their owner is gone
        // or assumed hidden by us.
        if let e = state.expectedToVanish, Date().timeIntervalSince(e.at) > 60 { state.expectedToVanish = nil }
        let vanishing = state.expectedToVanish?.keys ?? []
        let hiddenOwnerKeys: Set<String> = Set(state.assumedHidden.keys.flatMap { pid in state.perApp[pid]?.infos.map(\.identityKey) ?? [] })
        func legitimatelyGone(_ e: AXElementInfo) -> Bool {
            vanishing.contains(e.identityKey) || hiddenOwnerKeys.contains(e.identityKey) || ownerGone(e, running: running)
        }
        let miss = missing(tree).filter { !isNoise($0) && !legitimatelyGone($0) }
        let spMiss = miss.filter(isSP)
        // Persisted group identity (gdu.53): the self-positioning groups last seen for a running owner survive the 3-scan
        // carry-over, so a long streak stays attributable. Unnamed timeouts are covered when their count does not exceed the
        // persisted (or previous-tree) self-positioning groups absent from this read; an unnamed timeout of anything else
        // makes the count exceed them. No other previously hosted element may be missing.
        let spApps = apps.filter { SelfPositioning.matches(bundleID: $0.bundleID, name: $0.name, owners: owners) }
        for pid in Array(state.selfPositioningGroups.keys) {
            let a = spApps.first { $0.pid == pid }
            if a == nil || (state.selfPositioningBundles[pid] != nil && a?.bundleID != state.selfPositioningBundles[pid]) {
                state.selfPositioningGroups[pid] = nil; state.selfPositioningBundles[pid] = nil; state.selfPositioningRefreshed[pid] = nil
                log("self-positioning groups: pid \(pid) no longer running; record pruned")
            }
        }
        // Prune by the owner's own extras (gdu.54): iStat enumerates its items, so a persisted group its fresh extras no longer
        // list was removed and must not keep covering an unnamed timeout. Only extras read in this scan count.
        var prunedKeys = Set<String>()
        if let extras = ownExtras?() {
            for a in spApps {
                guard let infos = extras[a.pid], let rec = state.selfPositioningGroups[a.pid] else { continue }
                // `readExtras` reports success even when single children timed out (they come back without an identifier), and an
                // empty result may be a failed read: neither is proof that a group was removed.
                if infos.isEmpty || infos.contains(where: { $0.identifier.isEmpty }) { continue }
                let listed = Set(infos.map(\.identifier).filter { !$0.isEmpty })
                let kept = rec.filter { listed.contains($0.identifier) }
                if kept.count != rec.count {
                    let gone = rec.filter { !listed.contains($0.identifier) }.map(\.key)
                    prunedKeys.formUnion(gone)
                    log("self-positioning groups: pid \(a.pid) extras no longer list \(gone.joined(separator: ", ")); pruned from the record")
                    if kept.isEmpty { state.selfPositioningGroups[a.pid] = nil; state.selfPositioningBundles[a.pid] = nil; state.selfPositioningRefreshed[a.pid] = nil }
                    else { state.selfPositioningGroups[a.pid] = kept }
                }
            }
        }
        // Record age (gdu.54): without a complete read refreshing it, a record stops attributing unnamed timeouts.
        var recordExpired = false
        for a in spApps where state.selfPositioningGroups[a.pid] != nil {
            let at = state.selfPositioningRefreshed[a.pid] ?? Date()
            state.selfPositioningRefreshed[a.pid] = at
            if Date().timeIntervalSince(at) > selfPositioningRecordMaxAge {
                recordExpired = true
                if state.expiredRecordLogged.insert(a.pid).inserted {
                    log("self-positioning groups: record for pid \(a.pid) not refreshed by a complete read for over \(Int(selfPositioningRecordMaxAge)) s; a complete read is required before attributing unnamed timeouts again")
                }
            }
        }
        let namedKeys = Set(tree.timedOut.map(\.identityKey))
        var absentSP = Set(state.selfPositioningGroups.values.joined().map(\.key)).union(spMiss.map(\.identityKey))
        absentSP.subtract(freshKeys); absentSP.subtract(namedKeys); absentSP.subtract(prunedKeys)   // a removed group is not absent, it is gone
        var attributable = false
        let namedRelevant = tree.timedOut.filter { !isNoise($0) }
        if tree.failedReads > 0, tree.topFailures == 0, namedRelevant.allSatisfy(isSP),
           tree.unnamedTimeouts > 0 || !tree.timedOut.isEmpty {
            if tree.unnamedTimeouts == 0 {
                // A dropped noise element hides which group failed: then the missing set must be iStat's too (gdu.54).
                attributable = namedRelevant.count == tree.timedOut.count || miss.allSatisfy(isSP)
            } else {
                attributable = !recordExpired && absentSP.count >= tree.unnamedTimeouts && miss.allSatisfy(isSP)
            }
        }
        // Refresh the record from this read: exactly on a complete read, merged on an attributed one.
        let completeRead = tree.failedReads == 0 && tree.unnamedTimeouts == 0 && !tree.elements.isEmpty
        if completeRead || attributable {
            func ownerPID(_ e: AXElementInfo) -> pid_t? {
                spApps.first { a in a.bundleID.map { b in SelfPositioning.prefixes(b).contains { e.identifier.hasPrefix($0) } } ?? false }?.pid
                    ?? (spApps.count == 1 ? spApps[0].pid : nil)
            }
            var fresh: [pid_t: [SPGroup]] = [:]
            for e in tree.elements where !e.stale && isSP(e) {
                if let pid = ownerPID(e) { fresh[pid, default: []].append(SPGroup(e)) }
            }
            let freshAll = Set(fresh.values.joined().map(\.key))
            for pid in Array(state.selfPositioningGroups.keys) {   // a group now shown under another owner leaves this one
                let other = Set((fresh[pid] ?? []).map(\.key))
                state.selfPositioningGroups[pid] = state.selfPositioningGroups[pid]!.filter { !freshAll.contains($0.key) || other.contains($0.key) }
            }
            for a in spApps {
                let mine = fresh[a.pid] ?? []
                var cur = completeRead ? [] : (state.selfPositioningGroups[a.pid] ?? [])
                for g in mine { if let i = cur.firstIndex(where: { $0.key == g.key }) { cur[i] = g } else { cur.append(g) } }
                if cur.isEmpty { state.selfPositioningGroups[a.pid] = nil; state.selfPositioningBundles[a.pid] = nil; state.selfPositioningRefreshed[a.pid] = nil }
                else {
                    state.selfPositioningGroups[a.pid] = cur; state.selfPositioningBundles[a.pid] = a.bundleID
                    if completeRead || state.selfPositioningRefreshed[a.pid] == nil { state.selfPositioningRefreshed[a.pid] = Date(); state.expiredRecordLogged.remove(a.pid) }
                }
            }
        }
        tree.failuresAreSelfPositioning = attributable
        if tree.failedReads > 0, !attributable {
            if tree.topFailures > 0 || (tree.timedOut.isEmpty && tree.unnamedTimeouts == 0) { tree.incompleteReason = "top-level failure" }
            else if let t = namedRelevant.first(where: { !isSP($0) }) { tree.incompleteReason = "named timeout not self-positioning (\(t.identityKey))" }
            else if tree.unnamedTimeouts > 0, recordExpired {
                tree.incompleteReason = "\(tree.unnamedTimeouts) unnamed timeouts, self-positioning record older than \(Int(selfPositioningRecordMaxAge)) s (a complete read is required)"
            }
            else if tree.unnamedTimeouts > 0, absentSP.count < tree.unnamedTimeouts {
                // Previously hosted non-iStat groups that are missing now: the best candidates for the uncovered timeouts.
                let uncovered = miss.filter { !isSP($0) }.map(\.identityKey)
                let recorded = spApps.filter { state.selfPositioningGroups[$0.pid] != nil }.count
                tree.incompleteReason = "\(tree.unnamedTimeouts) unnamed timeouts, persisted self-positioning groups absent: \(absentSP.count), previous-tree absent: \(spMiss.count)"
                    + (uncovered.isEmpty ? "" : " uncovered: \(uncovered.prefix(3).joined(separator: ", ")) (owner unknown)")
                    + (recorded == 0 ? spApps.map { " (no persisted record for pid \($0.pid))" }.joined() + (spApps.isEmpty ? " (no self-positioning app running)" : "") : "")
            } else if let m = miss.first(where: { !isSP($0) }) { tree.incompleteReason = "non-self-positioning element missing (\(m.identityKey))" }
            else { tree.incompleteReason = "failed reads not attributable to self-positioning owners" }
        }
        if retry { source.noteUnresolvedGroups(selfPositioning: attributable) }
        if tree.unnamedTimeouts > 0 { candidatesToCarry += attributable ? spMiss : miss }
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
        return assemble(agent: agent, tree: tree, candidates: candidates, failedApps: [], running: Set(apps.map(\.pid)), verifiedOnly: true,
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
        let capSlow = slowOwnerExtrasTimeout
        let extrasDone = DispatchGroup()
        let holder = Holder<[ExtrasRead?]>()
        extrasDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var reads: [ExtrasRead?] = boundedParallelMap(toRead, workers: Self.maxConcurrency, deadline: deadline) {
                source.readExtras(for: $0, timeout: capSlow > 0 && chronic.contains($0.pid) ? capSlow : nil)
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
        let tree = readHosted(agent: agent, apps: apps, retry: true, lap: lap, ownExtras: {
            extrasDone.wait()
            var m: [pid_t: [AXElementInfo]] = [:]
            for (app, read) in zip(toRead, holder.value ?? []) { if case .items(let infos)? = read { m[app.pid] = infos } }
            return m
        })
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
        return assemble(agent: agent, tree: tree, candidates: candidates, failedApps: failedApps, running: Set(apps.map(\.pid)))
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
                          failedApps: [RunningAppInfo], running: Set<pid_t>, verifiedOnly: Bool = false,
                          carryUnverified: Bool = false) -> MenuBarSnapshot {
        let strip = tree.stripFrame ?? state.lastStrip ?? fallbackStrip

        // Dedupe hosted elements (group + button may both report the same item).
        var hosted: [AXElementInfo] = []
        for e in tree.elements where !hosted.contains(where: {
            $0.frame == e.frame && $0.identifier == e.identifier && $0.axDescription == e.axDescription && $0.title == e.title
        }) { hosted.append(e) }

        func onBar(_ f: CGRect) -> Bool {
            f.width > 0 && f.height > 0 && f.midY >= strip.minY && f.midY <= strip.maxY
        }
        let hostedComplete = agent != nil && !hosted.isEmpty && tree.failedReads == 0 && tree.unnamedTimeouts == 0
        // Completeness level (gdu.51): a FULL scan whose only incompleteness is stale items of self-positioning owners
        // (iStat's AX answers time out for 40+ s at a time). Every stale hosted element and every stale app-side candidate
        // must be theirs, there is no top-level failure, there is fresh hosted data, and their stale items account for
        // every failed read. `hostedReadComplete` itself stays strict (== hostedComplete).
        let spOwners = selfPositioningOwners
        var spOnly = false
        var reason: String?
        if !verifiedOnly, !hostedComplete, agent != nil, tree.topFailures == 0, tree.failedReads > 0, tree.failuresAreSelfPositioning,
           hosted.contains(where: { !$0.stale }) {
            let staleHosted = hosted.filter(\.stale)
            let staleCands = candidates.filter(\.stale)
            // No "something is stale" requirement (gdu.53): a long streak outlives the carry-over, and the failures are
            // attributed by identity (`failuresAreSelfPositioning`).
            spOnly = staleHosted.allSatisfy { SelfPositioning.matches(identifier: $0.identifier, owners: spOwners) }
                && staleCands.allSatisfy { SelfPositioning.matches(bundleID: $0.app.bundleID, name: $0.app.name, owners: spOwners) }
            if !spOnly {
                if let c = staleCands.first(where: { !SelfPositioning.matches(bundleID: $0.app.bundleID, name: $0.app.name, owners: spOwners) }) {
                    reason = "stale app-side item of \(c.app.bundleID ?? c.app.name)"
                } else if let h = staleHosted.first(where: { !SelfPositioning.matches(identifier: $0.identifier, owners: spOwners) }) {
                    reason = "stale hosted element not self-positioning (\(h.identityKey))"
                } else { reason = "no stale self-positioning item" }
            }
        } else if !verifiedOnly, !hostedComplete {
            reason = tree.incompleteReason ?? (agent == nil ? "no MenuBarAgent" : hosted.isEmpty ? "empty hosted tree" : tree.failedReads == 0 ? "unnamed or failed read without a count" : "no fresh hosted data")
        }
        if reason == nil, !verifiedOnly, !hostedComplete, !spOnly { reason = tree.incompleteReason }

        // Assumed-hidden state (of7). Identifier-less items (Tot, Yoink, Moom) cannot be judged by name, so after a live
        // hide their stale on-bar app-side frame looks "on the bar". When WE hid such an owner (live write confirmed by
        // hosted-ELEMENT evidence, or found already hidden in the Control Center store; `recordAssumedHidden`), its unnamed
        // on-bar-framed candidates are reported hidden for as long as the Control Center store says `isAllowed == false`
        // (CFPreferences readback, at most every 10 s per owner): that store is what the agent enforces. A record also ends
        // when the owner quits, its pid now belongs to another bundle, we show the unit (actuator/activator clear it), or
        // after a 2 h hard safety expiry. There is deliberately NO frame/width/count contradiction rule: a foreign element
        // (e.g. our own status item) can overlap a stale frame with the same width. The flag is set ONLY by our own write
        // plus evidence, never inferred from frames, so it cannot produce a false hidden on an untouched bar.
        let nowT = Date()
        for (pid, rec) in state.assumedHidden {
            func drop(_ why: String) { state.assumedHidden[pid] = nil; state.assumedCheckedAt[pid] = nil; log("assumed-hidden: pid \(pid) \(why); dropped") }
            if !running.contains(pid) { drop("quit"); continue }
            // Pid reuse guard: the owner must still be the app we recorded.
            if let b = rec.bundleID, let c = candidates.first(where: { $0.app.pid == pid }), let cb = c.app.bundleID, cb != b {
                drop("is now \(cb), recorded for \(b)"); continue
            }
            if nowT.timeIntervalSince(rec.at) > Self.assumedHiddenHardExpiry {
                drop("hit the \(Int(Self.assumedHiddenHardExpiry / 3600)) h safety expiry"); continue
            }
            // Someone else showed it: Control Center says isAllowed (checked at most every 10 s).
            if let tk = rec.trackedKey, nowT.timeIntervalSince(state.assumedCheckedAt[pid] ?? rec.at) >= Self.assumedReadbackInterval {
                state.assumedCheckedAt[pid] = nowT
                let r = allowedReadback(tk)
                log("assumed-hidden: Control Center readback \(tk) isAllowed=\(r.map(String.init(describing:)) ?? "unreadable")")
                if r == true { drop("is allowed again in Control Center (\(tk))") }
            }
        }
        var assumedIdx = Set<Int>()
        for (i, c) in candidates.enumerated()
        where state.assumedHidden[c.app.pid] != nil && !c.stale && c.info.identifier.isEmpty && c.info.axDescription.isEmpty
            && c.info.frame.width > 1 && onBar(c.info.frame) {
            assumedIdx.insert(i)
        }

        // Join: identifier, then description, then frame intersection. Each app item matches at most once.
        var matchedCandidates: [Int: AXElementInfo] = [:]
        var matchedHosted = Set<Int>()
        var hostedOwner: [Int: pid_t] = [:]
        // Which pass paired each candidate, and with which hosted element (gdu.28 `JoinEvidence`).
        var matchedBy: [Int: (pass: JoinEvidence, hosted: Int)] = [:]
        func pass(_ kind: JoinEvidence, _ matches: (AXElementInfo, AXElementInfo) -> Bool) {
            for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) && !Self.isOwnHostedElement(h) && !h.isOverflowChevron {
                if let ci = candidates.indices.first(where: {
                    matchedCandidates[$0] == nil && !assumedIdx.contains($0) && matches(h, candidates[$0].info)
                }) {
                    matchedHosted.insert(hi); matchedCandidates[ci] = h; hostedOwner[hi] = candidates[ci].app.pid
                    matchedBy[ci] = (kind, hi)
                }
            }
        }
        pass(.identifier) { !$0.identifier.isEmpty && $0.identifier == $1.identifier }
        pass(.description) { !$0.axDescription.isEmpty && $0.axDescription == $1.axDescription }
        pass(.frameAmbiguous) { h, c in
            guard h.frame.width > 0, c.frame.width > 0 else { return false }
            let i = h.frame.intersection(c.frame)
            return !i.isNull && i.width > 0 && i.height > 0
        }

        /// gdu.28: how trustworthy the pairing of candidate `ci` with its hosted element is (see `JoinEvidence`).
        func joinEvidence(_ ci: Int) -> JoinEvidence {
            guard let m = matchedBy[ci] else { return .none }
            let h = hosted[m.hosted]
            switch m.pass {
            case .identifier: return .identifier
            case .description:
                let d = h.axDescription
                let owners = candidates.filter { $0.info.axDescription == d }.count
                let hostedWith = hosted.enumerated().filter { !Self.isOwnHostedElement($0.element) && $0.element.axDescription == d }.count
                return owners == 1 && hostedWith == 1 ? .description : .frameAmbiguous
            default:
                func substantial(_ a: CGRect, _ b: CGRect) -> Bool {
                    guard a.width > 0, b.width > 0 else { return false }
                    let i = a.intersection(b)
                    return !i.isNull && i.height > 0 && i.width >= 0.5 * min(a.width, b.width)
                }
                let c = candidates[ci].info
                guard substantial(h.frame, c.frame), abs(h.frame.width - c.frame.width) <= 2 else { return .frameAmbiguous }
                let hostedHits = hosted.indices.filter { !Self.isOwnHostedElement(hosted[$0]) && substantial(hosted[$0].frame, c.frame) }
                let ownerHits = candidates.indices.filter { substantial(candidates[$0].info.frame, h.frame) }
                return hostedHits == [m.hosted] && ownerHits == [ci] ? .frameUnique : .frameAmbiguous
            }
        }

        let activeAssumed = assumedIdx.filter { state.assumedHidden[candidates[$0].app.pid] != nil }

        // Identifier-prefix attribution: hosted element id "com.bjango.istatmenus.weather" belongs to a
        // failed-read app whose bundle id is a reverse-DNS prefix relative (com.bjango.istatmenus.status).
        func relatedPrefixes(_ bundle: String) -> [String] { SelfPositioning.prefixes(bundle) }
        var attributed: [(Int, RunningAppInfo)] = []
        for (hi, h) in hosted.enumerated() where !matchedHosted.contains(hi) && !h.identifier.isEmpty {
            let owners = failedApps.filter { app in
                guard let b = app.bundleID else { return false }
                return relatedPrefixes(b).contains { h.identifier.hasPrefix($0) }
            }
            if let owner = owners.max(by: { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }) {
                matchedHosted.insert(hi)
                hostedOwner[hi] = owner.pid
                attributed.append((hi, owner))
            }
        }

        // Live-hide detection (docs/findings-live-trigger.md section 4). After a cfprefsd-notified hide MenuBarAgent drops
        // the app's scenes at once (its hosted tree no longer contains the item at all), but the owning app's own
        // AXExtrasMenuBar children keep their on-bar frames and the `stale` flag stays false, so the frame rule alone
        // reports the item on the bar. The agent's hosted tree is the authority: an app-extras candidate whose owner is
        // running (it was read, not carried), whose frame says "on bar", and which has a NAME the hosted tree should
        // mirror, but for which a COMPLETE hosted read has no element of that name, is hidden: `notHosted`.
        //  - Name rule (AX identifier or description; the identifier set spans ALL owners, not just this item's bundle; the autosave name is what the app publishes as
        //    AXIdentifier and the agent mirrors it): with an identifier, no hosted element carries that identifier. The
        //    frame join is NOT consulted, because a crowded bar stacks unrelated items on top of each other and a frame
        //    overlap with another item's element must not keep a hidden item alive. Without an identifier, the
        //    description-only candidate must be unmatched by the joins and share no title with an unmatched hosted element.
        //  - Only an item previously seen hosted by name (`ScanState.seenHostedKeys`: identifier, else description, positively
        //    present in an earlier read) can become `notHosted`; never-seen items stay frame-ruled, because a false "visible"
        //    resolves after one action while a false "hidden" would make the engine try to show it forever.
        //  - Candidates with neither identifier nor description are never judged (the join cannot be trusted): frame rule.
        //  - Complete = agent present, non-empty tree, no failed reads, no unnamed timeouts. Any flaky read keeps the frame
        //    rule, so a slow AX call never produces a false "hidden"; the one exception is sticky: an item an earlier complete
        //    read proved hidden stays hidden through incomplete reads unless the partial tree shows it hosted.
        //  - Width <= 1 candidates (main-menu noise) are never judged. The parked-frame rule (x -1..3, y ~1188..1204) stays
        //    the second signal and wins when the frame is off the strip (`parkedFrame`).
        let hostedIdentifiers = Set(hosted.map(\.identifier).filter { !$0.isEmpty })
        let hostedDescriptions = Set(hosted.map(\.axDescription).filter { !$0.isEmpty })
        // Positive evidence that the agent mirrors this item's name; only such items may later become `notHosted`
        // (an app whose hosted element carries another or no identifier stays frame-ruled instead of looping as "hidden").
        func nameHosted(_ c: Candidate) -> Bool {
            !c.info.identifier.isEmpty ? hostedIdentifiers.contains(c.info.identifier)
                : (!c.info.axDescription.isEmpty && hostedDescriptions.contains(c.info.axDescription))
        }
        let unmatchedHostedTitles = Set(hosted.indices.filter { !matchedHosted.contains($0) }.map { hosted[$0].title }.filter { !$0.isEmpty })
        func provablyNotHosted(_ ci: Int) -> Bool {
            let c = candidates[ci]
            guard agent != nil, !c.stale, c.info.frame.width > 1, onBar(c.info.frame) else { return false }
            let named = !c.info.identifier.isEmpty || !c.info.axDescription.isEmpty
            guard named else { return false }
            // Never seen hosted by name in an earlier read: no evidence the agent ever mirrors this item, so frame rule.
            guard state.seenHostedKeys.contains("\(c.app.pid)|\(c.info.identityKey)") else { return false }
            // Incomplete read: it proves nothing by absence, so an item already known to be live-hidden stays hidden until
            // a read shows it hosted again (no flip-flop on flaky scans); everything else keeps the frame rule.
            // On a read that is incomplete only because of self-positioning owners (gdu.51), the absence of a NON-self-positioning
            // item's name is still proof: every failed group is theirs.
            let trusted = hostedComplete || (spOnly && !SelfPositioning.matches(bundleID: c.app.bundleID, name: c.app.name, owners: spOwners))
            if !trusted && !state.hiddenKeys.contains("\(c.app.pid)|\(c.info.identityKey)") { return false }
            if !c.info.identifier.isEmpty { return !hostedIdentifiers.contains(c.info.identifier) }
            guard matchedCandidates[ci] == nil else { return false }
            // An unmatched hosted element with the same (non-empty) title may be this item under a drifted description.
            return c.info.title.isEmpty || !unmatchedHostedTitles.contains(c.info.title)
        }

        var items: [MenuBarItem] = []
        var carriedUnverified: [String: Int] = [:]
        var newHidden = Set<String>()
        for (ci, c) in candidates.enumerated() {
            // The fast path never re-reads apps, so a cached app item the agent tree does not show is unverified.
            // Exception: while some agent group provably timed out, an on-bar cached item (freshly read from its
            // owning app, which is running) is carried as stale for at most `maxStaleScans` consecutive scans.
            var carriedCount = 0
            if let h = matchedCandidates[ci], h.stale { carriedUnverified["\(c.app.pid)|\(c.info.identityKey)"] = h.staleCount }
            let ckey = "\(c.app.pid)|\(c.info.identityKey)"
            let notHosted = provablyNotHosted(ci)
            let assumed = activeAssumed.contains(ci)
            if notHosted { newHidden.insert(ckey) }
            // Only items that the agent tree showed in the last full scan are expected there; app-only items (e.g.
            // SystemUIServer's) never appear in it and are taken from the cache as before. An item that a complete read
            // proves absent is not dropped but reported as hidden (`notHosted`), so order observers see it leave the bar.
            let expectedHosted = state.hostedKeys.contains(ckey) || state.hiddenKeys.contains(ckey)
            if verifiedOnly && matchedCandidates[ci] == nil && expectedHosted && !(notHosted && expectedHosted) && !assumed {
                let key = ckey
                let n = (state.unverifiedCount[key] ?? 0) + 1
                guard carryUnverified, onBar(c.info.frame), n <= Self.maxStaleScans else { continue }
                carriedUnverified[key] = n
                carriedCount = n
            }
            // The fast path only trusts a "not hosted" verdict for items it knew to be hosted (or already hidden).
            let reportNotHosted = (notHosted && (!verifiedOnly || expectedHosted)) || assumed
            if !reportNotHosted { newHidden.remove(ckey) }
            // A candidate verified by the hosted tree takes the hosted (authoritative, fresh) frame and is not stale.
            let h = reportNotHosted ? nil : matchedCandidates[ci]
            let frame = h?.frame ?? c.info.frame
            items.append(MenuBarItem(
                ownerPID: c.app.pid, ownerBundleID: c.app.bundleID, ownerName: c.app.name,
                title: c.info.title, axDescription: c.info.axDescription,
                axIdentifier: c.info.identifier, frame: frame,
                source: .appExtras, isOnMenuBar: onBar(frame) && !reportNotHosted, axElement: c.info.element,
                stale: h == nil ? (c.stale || carriedCount > 0) : h!.stale,
                staleCount: h?.staleCount ?? carriedCount,
                notHostedByAgent: reportNotHosted, assumedNotHosted: assumed,
                joinEvidence: h == nil ? .none : joinEvidence(ci)))
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
                    axElement: h.element, stale: h.stale, staleCount: h.staleCount, isOverflowChevron: h.isOverflowChevron))
            }
        }

        let matchedKeys = Set(matchedCandidates.keys.map { "\(candidates[$0].app.pid)|\(candidates[$0].info.identityKey)" })
        if verifiedOnly {
            state.unverifiedCount = carriedUnverified
        } else {
            state.hostedKeys = tree.failedReads == 0 ? matchedKeys : state.hostedKeys.union(matchedKeys)
        }
        // Remembered so the fast path keeps reporting a live-hidden item as hidden after a full scan dropped it from
        // `hostedKeys`; an item the agent hosts again leaves the set. An incomplete read leaves the set as it was.
        if hostedComplete || spOnly { state.hiddenKeys = state.hiddenKeys.subtracting(matchedKeys).union(newHidden) }
        for c in candidates where !c.stale && nameHosted(c) { state.seenHostedKeys.insert("\(c.app.pid)|\(c.info.identityKey)") }
        if hostedComplete {
            // Drop keys of owners that are no longer running.
            func alive(_ k: String) -> Bool { Int32(k.prefix { $0 != "|" }).map(running.contains) ?? false }
            state.hiddenKeys = state.hiddenKeys.filter(alive)
            state.seenHostedKeys = state.seenHostedKeys.filter(alive)
        }
        let layout: [HostedEntry] = hosted.enumerated().filter { !$0.element.stale && $0.element.frame.width > 1 && onBar($0.element.frame) }
            .map { HostedEntry(sig: $0.element.identifier.isEmpty ? $0.element.axDescription : $0.element.identifier,
                               minX: $0.element.frame.minX, width: $0.element.frame.width, ownerPID: hostedOwner[$0.offset]) }
            .sorted { $0.minX < $1.minX }
        if hostedComplete { state.lastCompleteLayout = (layout, Date()) }
        state.save()   // writes only if the cache content changed

        // Stable partition: on-bar sorted by minX (ties keep discovery order), parked in discovery order.
        let indexed = Array(items.enumerated())
        let on = indexed.filter { $0.element.isOnMenuBar }
            .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }
        let off = indexed.filter { !$0.element.isOnMenuBar }
        // Apple's own overflow (gdu.45): items left of the chevron, or stacked on one another, are reported on the bar but
        // not drawn. Flagged here, once, so every consumer (resolver, planner, verifier, UI) reads the same truth.
        // Our own hosted status item is counted in `hostedLayout` (evidence) but is not an item to report (unless asked for).
        let reported = (on + off).map(\.element).filter { includeSelf || $0.axIdentifier != Self.ownStatusItemIdentifier }
        let marked = SystemOverflow.mark(reported)
        var snapshot = MenuBarSnapshot(items: marked, capturedAt: Date(), hostedReadComplete: hostedComplete, hostedLayout: layout,
                                       incompleteOnlyForSelfPositioning: spOnly)
        snapshot.completenessReason = hostedComplete || spOnly ? nil : reason
        // One line per incomplete full scan that has a stale self-positioning item (identical consecutive reasons: once per 10 s).
        if let r = snapshot.completenessReason, marked.contains(where: { $0.stale && SelfPositioning.matches($0, owners: spOwners) }) {
            let line = "incomplete: " + r
            if state.lastIncompleteLog?.reason != line || Date().timeIntervalSince(state.lastIncompleteLog!.at) >= 10 {
                state.lastIncompleteLog = (line, Date()); log(line)
            }
        }
        return snapshot
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
