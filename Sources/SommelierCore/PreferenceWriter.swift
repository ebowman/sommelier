import Foundation

public enum PreferenceWriterError: Error, CustomStringConvertible {
    case unreadable(String)
    case malformed(String)
    case writeFailed(String)
    public var description: String {
        switch self {
        case .unreadable(let s): return "unreadable: \(s)"
        case .malformed(let s): return "malformed: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        }
    }
}

/// Legacy per-app `NSStatusItem Preferred Position <autosave>` writes via CFPreferences.
public enum PreferenceWriter {
    public static func legacyKey(autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// Writes (or removes, when `value` is nil) a number in the app's defaults domain and synchronizes.
    /// `currentHost` selects kCFPreferencesCurrentHost instead of kCFPreferencesAnyHost.
    @discardableResult
    public static func setValue(_ value: Double?, forKey key: String, bundleID: String, currentHost: Bool = false) -> Bool {
        let host = currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, bundleID as CFString,
                              kCFPreferencesCurrentUser, host)
        return CFPreferencesSynchronize(bundleID as CFString, kCFPreferencesCurrentUser, host)
    }

    /// Same as `setValue` but through `CFPreferencesSetAppValue` (current user, any host) + app synchronize.
    @discardableResult
    public static func setAppValue(_ value: Double?, forKey key: String, bundleID: String) -> Bool {
        CFPreferencesSetAppValue(key as CFString, value.map { NSNumber(value: $0) }, bundleID as CFString)
        return CFPreferencesAppSynchronize(bundleID as CFString)
    }

    public static func setLegacyPosition(bundleID: String, autosaveName: String, value: Double, currentHost: Bool) -> Bool {
        let key = legacyKey(autosaveName: autosaveName)
        return currentHost ? setValue(value, forKey: key, bundleID: bundleID, currentHost: true)
                           : setAppValue(value, forKey: key, bundleID: bundleID)
    }

    public static func readLegacy(bundleID: String, autosaveName: String) -> Any? {
        CFPreferencesCopyAppValue(legacyKey(autosaveName: autosaveName) as CFString, bundleID as CFString)
    }
}

/// Reads/writes `TrailingItemPreferredPositions` in the MenuBarAgent group-container plist.
public struct MenuBarOrderStore {
    public static let dictKey = "TrailingItemPreferredPositions"
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    public var url: URL
    /// Raw bytes of the file as first read by this store (before any write through it).
    public private(set) var backup: Data?

    public init(url: URL = MenuBarOrderStore.defaultURL) { self.url = url }

    public static func key(bundleID: String, autosaveName: String) -> String {
        "status:\(bundleID)::\(autosaveName)"
    }

    private func loadRoot() throws -> (root: [String: Any], format: PropertyListSerialization.PropertyListFormat, raw: Data) {
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch { throw PreferenceWriterError.unreadable("\(url.path): \(error)") }
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard let obj = try? PropertyListSerialization.propertyList(from: raw, options: [], format: &fmt),
              let root = obj as? [String: Any] else { throw PreferenceWriterError.malformed("top level is not a dictionary") }
        return (root, fmt, raw)
    }

    /// All positions (integers and reals both surface as Double).
    public func readPositions() throws -> [String: Double] {
        let (root, _, _) = try loadRoot()
        guard let d = root[Self.dictKey] as? [String: Any] else { throw PreferenceWriterError.malformed("missing \(Self.dictKey)") }
        return d.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Sets one or more keys, keeping all others. Refuses `module:` keys. Atomic write preserving permissions;
    /// keeps the original bytes in `backup` (first write only).
    public mutating func setPositions(_ updates: [String: Double]) throws {
        if let bad = updates.keys.first(where: { $0.hasPrefix("module:") }) {
            throw PreferenceWriterError.malformed("refusing to edit \(bad)")
        }
        var (root, fmt, raw) = try loadRoot()
        guard var d = root[Self.dictKey] as? [String: Any] else { throw PreferenceWriterError.malformed("missing \(Self.dictKey)") }
        if backup == nil { backup = raw }
        for (k, v) in updates { d[k] = NSNumber(value: v) }
        root[Self.dictKey] = d
        let out: Data
        do { out = try PropertyListSerialization.data(fromPropertyList: root, format: fmt, options: 0) }
        catch { throw PreferenceWriterError.writeFailed("serialize: \(error)") }
        try atomicWrite(out)
    }

    public mutating func setPosition(bundleID: String, autosaveName: String, value: Double) throws {
        try setPositions([Self.key(bundleID: bundleID, autosaveName: autosaveName): value])
    }

    /// Restores the in-memory backup (the bytes read before this store's first write).
    public func restoreBackup() throws {
        guard let b = backup else { throw PreferenceWriterError.writeFailed("no backup") }
        try atomicWrite(b)
    }

    private func atomicWrite(_ data: Data) throws {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sommelier-\(getpid()).tmp")
        do {
            try data.write(to: tmp)
            if let perms = attrs?[.posixPermissions] { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path) }
            if rename(tmp.path, url.path) != 0 {
                throw PreferenceWriterError.writeFailed("rename: \(String(cString: strerror(errno)))")
            }
        } catch {
            try? fm.removeItem(at: tmp)
            if error is PreferenceWriterError { throw error }
            throw PreferenceWriterError.writeFailed("\(error)")
        }
    }
}

/// Restarts MenuBarAgent (launchd respawns it) and measures time until the hosted item count recovers.
public enum MenuBarAgentControl {
    /// Number of fresh (non-carried-forward) hosted items, read with the fast path.
    public static func hostedCount(scanner: MenuBarScanner) -> Int {
        scanner.scanVisible().items.filter { !$0.stale }.count
    }

    public struct RestartResult { public var before: Int; public var after: Int; public var elapsedMS: Int; public var recovered: Bool }

    public static func restart(timeout: TimeInterval = 10) -> RestartResult {
        // One scanner (no cache file) for the whole call: the fast path reads only the agent tree.
        let scanner = MenuBarScanner(source: LiveAccessibilitySource())
        let before = hostedCount(scanner: scanner)
        // The AX hosted count is noisy (+-10%: occasional read timeouts), so accept 90% of the pre-kill count.
        let threshold = before - before / 10
        let start = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["MenuBarAgent"]
        try? p.run(); p.waitUntilExit()
        var after = 0
        while Date().timeIntervalSince(start) < timeout {
            after = hostedCount(scanner: scanner)
            if after > 0 && after >= threshold { break }
            // NSWorkspace.runningApplications only refreshes while the run loop spins.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return RestartResult(before: before, after: after, elapsedMS: ms, recovered: after > 0 && after >= threshold)
    }
}
