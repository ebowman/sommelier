import Foundation

/// Injectable CFPreferences access for the live (cfprefsd-notified) write, so tests never touch real preferences.
public struct LivePrefsAccess {
    /// Current `trackedApplications` value through CFPreferences (nil when absent).
    public var read: () -> Data?
    /// `CFPreferencesSetValue` + `CFPreferencesSynchronize`; false when synchronize failed.
    public var write: (Data) -> Bool
    /// Fallback blob source when CFPreferences returns nil (the on-disk file).
    public var fileBlob: () -> Data?

    public init(read: @escaping () -> Data?, write: @escaping (Data) -> Bool, fileBlob: @escaping () -> Data?) {
        self.read = read; self.write = write; self.fileBlob = fileBlob
    }

    /// Real CFPreferences: domain group.com.apple.controlcenter, current user, any host.
    public static func system(fileURL: URL = ControlCenterTrackedAppsStore.defaultURL) -> LivePrefsAccess {
        let domain = AppGroupEntitlement.controlCenterGroup as CFString
        let key = ControlCenterTrackedAppsStore.blobKey as CFString
        return LivePrefsAccess(
            read: {
                CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data
            },
            write: { data in
                CFPreferencesSetValue(key, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            },
            fileBlob: {
                guard let raw = try? Data(contentsOf: fileURL),
                      let obj = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
                      let root = obj as? [String: Any] else { return nil }
                return root[ControlCenterTrackedAppsStore.blobKey] as? Data
            })
    }
}

extension ControlCenterTrackedAppsStore {
    /// `isAllowed` flags read through CFPreferences (never the lagging file).
    public static func allowedLive(_ keys: [String], access: LivePrefsAccess = .system()) throws -> [String: Bool] {
        guard let blob = access.read() else { throw PreferenceWriterError.unreadable("CFPreferences has no \(blobKey)") }
        let list = try parseBlob(blob).list
        var out: [String: Bool] = [:]
        for i in stride(from: 0, to: list.count, by: 2) {
            guard let k = locationKey(list[i]), keys.contains(k), let v = list[i + 1] as? [String: Any] else { continue }
            out[k] = (v["isAllowed"] as? Bool) ?? true
        }
        return out
    }

    static func parseBlob(_ blob: Data) throws -> (list: [Any], fmt: PropertyListSerialization.PropertyListFormat) {
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard let inner = try? PropertyListSerialization.propertyList(from: blob, options: [], format: &fmt),
              let list = inner as? [Any], list.count % 2 == 0 else { throw PreferenceWriterError.malformed("blob is not an even-length array") }
        return (list, fmt)
    }

    /// Like `setAllowedBatch` but through CFPreferences, so cfprefsd notifies MenuBarAgent, which applies the change without
    /// a respawn. REQUIRES the app-group entitlement (the caller checks `AppGroupEntitlement`; an unentitled write would
    /// silently land in the wrong file). All-or-nothing validation before any write; the written value is read back through
    /// CFPreferences and must carry the requested flags. `liveBackup` records the blob as first read.
    public mutating func setAllowedBatchLive(_ changes: [String: Bool], access: LivePrefsAccess = .system()) throws {
        guard !changes.isEmpty else { return }
        for key in changes.keys where key.hasPrefix("module:") || key.hasPrefix("com.apple.") {
            throw PreferenceWriterError.malformed("refusing to edit Apple/system entry \(key)")
        }
        let blob: Data
        if let b = access.read() { blob = b }
        else if let b = access.fileBlob() { blob = b }
        else { throw PreferenceWriterError.unreadable("\(Self.blobKey): CFPreferences returned nil and the file \(url.path) has no readable blob") }
        var (list, ifmt) = try Self.parseBlob(blob)
        var remaining = Set(changes.keys)
        for i in stride(from: 0, to: list.count, by: 2) {
            guard let k = Self.locationKey(list[i]), let want = changes[k] else { continue }
            guard var v = list[i + 1] as? [String: Any] else { throw PreferenceWriterError.malformed("entry for \(k) is not a dictionary") }
            v["isAllowed"] = want
            list[i + 1] = v
            remaining.remove(k)
        }
        if let missing = remaining.sorted().first { throw PreferenceWriterError.malformed("unknown entry \(missing)") }
        let newBlob: Data
        do { newBlob = try PropertyListSerialization.data(fromPropertyList: list, format: ifmt, options: 0) }
        catch { throw PreferenceWriterError.writeFailed("serialize: \(error)") }
        if liveBackup == nil { liveBackup = blob }
        guard access.write(newBlob) else { throw PreferenceWriterError.writeFailed("CFPreferencesSynchronize returned false") }
        guard let back = access.read(), let parsed = try? Self.parseBlob(back) else {
            throw PreferenceWriterError.writeFailed("read back through CFPreferences failed")
        }
        for i in stride(from: 0, to: parsed.list.count, by: 2) {
            guard let k = Self.locationKey(parsed.list[i]), let want = changes[k] else { continue }
            let got = (parsed.list[i + 1] as? [String: Any])?["isAllowed"] as? Bool
            if got != want { throw PreferenceWriterError.writeFailed("read back through CFPreferences: \(k) isAllowed=\(String(describing: got)), wanted \(want)") }
        }
    }
}
