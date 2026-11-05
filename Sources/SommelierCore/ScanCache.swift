import CoreGraphics
import Foundation

/// App-side extras of one app as of the last successful read.
struct CachedApp {
    var app: RunningAppInfo
    var infos: [AXElementInfo]
}

/// Write-time evidence that an owner's identifier-less items are live-hidden although their app-side frames still say
/// "on the bar" (docs/architecture.md, assumed-hidden state). Only our own successful write plus a hosted-count drop sets it.
struct AssumedHidden: Codable, Equatable {
    var pid: Int32
    var bundleID: String?
    /// Control Center tracked key of the owner (for the `isAllowed` readback); nil when unknown.
    var trackedKey: String?
    /// When we recorded it (the hard safety expiry counts from here).
    var at: Date
    /// Complete hosted count right after the hide (nil when unknown).
    var hostedAfter: Int?
    /// Number of the owner's items that were on the bar before the hide.
    var items: Int
}

/// A hosted agent group (one status item) last seen for a self-positioning owner (gdu.53).
struct SPGroup: Codable, Equatable {
    var key: String
    var identifier: String
    var frame: CGRect
    init(_ e: AXElementInfo) { key = e.identityKey; identifier = e.identifier; frame = e.frame }
}

/// State kept between scans by one `MenuBarScanner`: per-app extras (for attribution in the fast path and for
/// budget-miss fallback), the last hosted tree (for stale carry-forward) and the strip frame. Optionally persisted
/// to disk so a fresh process (e.g. `mbprobe list --fast`) starts warm.
final class ScanState: @unchecked Sendable {
    var perApp: [pid_t: CachedApp] = [:]
    /// Pids whose last read succeeded with no extras, with the time of that read (in-memory only).
    var emptyAt: [pid_t: Date] = [:]
    var lastHosted: [AXElementInfo] = []
    var lastStrip: CGRect?
    /// Pids whose extras read failed even after the retry in the last full scan.
    var chronic: Set<pid_t> = []
    var hasFullScan = false
    /// Cached app items that the agent tree showed in the last full scan ("pid|identity"); persisted.
    var hostedKeys: Set<String> = []
    /// Cached app items a complete hosted read proved absent while their owner runs (live-hidden); persisted.
    var hiddenKeys: Set<String> = []
    /// Cached app items that were positively matched to a hosted element BY NAME (identifier, else description) in some
    /// read. Only these may become `notHosted`; persisted.
    var seenHostedKeys: Set<String> = []
    /// Owners whose identifier-less items we hid ourselves (live write) and a hosted-count drop confirmed (of7). Keyed by
    /// pid because the unit is the owner and the items' own keys are frame-based (volatile). Persisted.
    var assumedHidden: [pid_t: AssumedHidden] = [:]
    /// Last complete hosted tree (attributed by the join) and when it was read (in-memory only).
    var lastCompleteLayout: (entries: [HostedEntry], at: Date)?
    /// When the Control Center `isAllowed` readback of an assumed-hidden owner was last done (in-memory only).
    var assumedCheckedAt: [pid_t: Date] = [:]
    /// Hosted groups last seen (fresh) for each running self-positioning owner, independent of the 3-scan stale carry-over
    /// (gdu.53); persisted. Refreshed on complete and attributed (middle-level) reads, pruned when the owner quits.
    var selfPositioningGroups: [pid_t: [SPGroup]] = [:]
    /// Bundle id recorded with each pid's groups (pid reuse guard; persisted).
    var selfPositioningBundles: [pid_t: String] = [:]
    /// When a COMPLETE read last refreshed each pid's record (gdu.54; persisted). A record older than the scanner's maximum
    /// age stops attributing unnamed timeouts until the next complete read.
    var selfPositioningRefreshed: [pid_t: Date] = [:]
    /// Pids whose expired record was already logged (once until the next refresh; in-memory only).
    var expiredRecordLogged: Set<pid_t> = []
    private var lastSaved: Data?
    /// Consecutive fast scans each unverified cached item has been shown as stale (in-memory only).
    var unverifiedCount: [String: Int] = [:]
    /// Last logged incomplete reason and when (rate limit: identical consecutive reasons log once per 10 s).
    var lastIncompleteLog: (reason: String, at: Date)?
    /// Identity keys of hosted elements the actuator expects to vanish (it is hiding their unit); they are not "missing"
    /// for the attribution rule (gdu.51). Cleared when the batch ends; expires on its own after 60 s.
    var expectedToVanish: (keys: Set<String>, at: Date)?
    /// Noise elements already logged (once per frame key).
    var loggedNoise: Set<String> = []
    private var loaded = false
    let url: URL?

    init(url: URL?) { self.url = url }

    private struct FileApp: Codable { var pid: Int32; var bundleID: String?; var name: String; var infos: [FileInfo] }
    private struct FileInfo: Codable {
        var title: String, axDescription: String, identifier: String, frame: CGRect
        init(_ i: AXElementInfo) { title = i.title; axDescription = i.axDescription; identifier = i.identifier; frame = i.frame }
        var info: AXElementInfo { AXElementInfo(title: title, axDescription: axDescription, identifier: identifier, frame: frame) }
    }
    private struct FileSP: Codable { var pid: Int32; var bundleID: String?; var groups: [SPGroup]; var refreshed: Date? }
    private struct File: Codable { var spGroups: [FileSP]?; var apps: [FileApp]; var hosted: [FileInfo]; var strip: CGRect?; var chronic: [Int32]?; var hostedKeys: [String]?; var hiddenKeys: [String]?; var seenHostedKeys: [String]?; var assumedHidden: [AssumedHidden]? }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        for a in f.apps {
            perApp[a.pid] = CachedApp(app: RunningAppInfo(pid: a.pid, bundleID: a.bundleID, name: a.name), infos: a.infos.map(\.info))
        }
        // gdu.29: files written before main-menu entries were dropped may hold them; ignore those records so the fix is
        // effective at once. (Per-app extras never contain them; they come from the agent tree only.)
        lastHosted = f.hosted.map(\.info).filter { !$0.looksLikeMainMenuRecord }
        lastStrip = f.strip
        chronic = Set(f.chronic ?? [])
        hostedKeys = Set(f.hostedKeys ?? [])
        hiddenKeys = Set(f.hiddenKeys ?? [])
        seenHostedKeys = Set(f.seenHostedKeys ?? [])
        assumedHidden = Dictionary((f.assumedHidden ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for g in f.spGroups ?? [] {
            selfPositioningGroups[g.pid] = g.groups
            if let b = g.bundleID { selfPositioningBundles[g.pid] = b }
            selfPositioningRefreshed[g.pid] = g.refreshed ?? Date()    // files written before gdu.54 carry no timestamp
        }
        hasFullScan = !f.apps.isEmpty
    }

    func save() {
        guard let url else { return }
        let sp = selfPositioningGroups.keys.sorted().map { FileSP(pid: $0, bundleID: selfPositioningBundles[$0], groups: selfPositioningGroups[$0] ?? [], refreshed: selfPositioningRefreshed[$0]) }
        let f = File(spGroups: sp, apps: perApp.values.filter { !$0.infos.isEmpty }.sorted { $0.app.pid < $1.app.pid }.map {
            FileApp(pid: $0.app.pid, bundleID: $0.app.bundleID, name: $0.app.name, infos: $0.infos.map(FileInfo.init))
        }, hosted: lastHosted.filter { !$0.stale }.map(FileInfo.init), strip: lastStrip, chronic: chronic.sorted(), hostedKeys: hostedKeys.sorted(), hiddenKeys: hiddenKeys.sorted(), seenHostedKeys: seenHostedKeys.sorted(), assumedHidden: assumedHidden.values.sorted { $0.pid < $1.pid })
        // Written only when the content changed since the last write by this process.
        guard let data = try? JSONEncoder().encode(f), data != lastSaved else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { lastSaved = data }
    }

    /// Cached entries whose pid is running with the same bundle id (guards pid reuse across reboots).
    func validCached(running apps: [RunningAppInfo]) -> [CachedApp] {
        apps.compactMap { a in
            guard let c = perApp[a.pid], c.app.bundleID == a.bundleID else { return nil }
            return CachedApp(app: a, infos: c.infos)
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sommelier/scan-cache.json")
    }
}
