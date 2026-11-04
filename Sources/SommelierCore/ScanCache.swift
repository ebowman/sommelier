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
    var at: Date
    /// Complete hosted count right after the hide (nil when unknown).
    var hostedAfter: Int?
    /// Number of the owner's items that were on the bar before the hide.
    var items: Int
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
    private var lastSaved: Data?
    /// Consecutive fast scans each unverified cached item has been shown as stale (in-memory only).
    var unverifiedCount: [String: Int] = [:]
    private var loaded = false
    let url: URL?

    init(url: URL?) { self.url = url }

    private struct FileApp: Codable { var pid: Int32; var bundleID: String?; var name: String; var infos: [FileInfo] }
    private struct FileInfo: Codable {
        var title: String, axDescription: String, identifier: String, frame: CGRect
        init(_ i: AXElementInfo) { title = i.title; axDescription = i.axDescription; identifier = i.identifier; frame = i.frame }
        var info: AXElementInfo { AXElementInfo(title: title, axDescription: axDescription, identifier: identifier, frame: frame) }
    }
    private struct File: Codable { var apps: [FileApp]; var hosted: [FileInfo]; var strip: CGRect?; var chronic: [Int32]?; var hostedKeys: [String]?; var hiddenKeys: [String]?; var seenHostedKeys: [String]?; var assumedHidden: [AssumedHidden]? }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        for a in f.apps {
            perApp[a.pid] = CachedApp(app: RunningAppInfo(pid: a.pid, bundleID: a.bundleID, name: a.name), infos: a.infos.map(\.info))
        }
        lastHosted = f.hosted.map(\.info)
        lastStrip = f.strip
        chronic = Set(f.chronic ?? [])
        hostedKeys = Set(f.hostedKeys ?? [])
        hiddenKeys = Set(f.hiddenKeys ?? [])
        seenHostedKeys = Set(f.seenHostedKeys ?? [])
        assumedHidden = Dictionary((f.assumedHidden ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        hasFullScan = !f.apps.isEmpty
    }

    func save() {
        guard let url else { return }
        let f = File(apps: perApp.values.filter { !$0.infos.isEmpty }.sorted { $0.app.pid < $1.app.pid }.map {
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
