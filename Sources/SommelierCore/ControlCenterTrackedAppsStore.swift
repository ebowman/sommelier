import Foundation

/// Reads/writes the "Allow in the Menu Bar" flags (`isAllowed`) of the Control Center group-container plist.
///
/// Format (macOS 27): the plist's top-level key `trackedApplications` is a `Data` value that is itself a
/// binary property list: an ARRAY of alternating key/value dictionaries (a Swift `Dictionary<Location, Entry>`
/// encoded as a flat array):
///   even index: `{ bundle: { _0: "<bundle id>" } }` or `{ adhocBinary: { _0: { relative: "file:///path" } } }`
///   odd  index: `{ location: <same as key>, menuItemLocations: [<location>...], isAllowed: Bool }`
/// `isAllowed == false` is what Bartender 7 writes to hide an item (the item is parked off-screen).
public struct ControlCenterTrackedAppsStore {
    public static let blobKey = "trackedApplications"
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    public struct Entry: Equatable {
        public var key: String       // bundle id, or the "relative" URL for adhocBinary locations
        public var isAllowed: Bool
        public var menuItemKeys: [String]
    }

    public var url: URL
    /// Raw bytes of the file as first read before any write through this store.
    public private(set) var backup: Data?

    public init(url: URL = ControlCenterTrackedAppsStore.defaultURL) { self.url = url }

    static func locationKey(_ loc: Any?) -> String? {
        guard let d = loc as? [String: Any] else { return nil }
        if let b = d["bundle"] as? [String: Any], let s = b["_0"] as? String { return s }
        if let a = d["adhocBinary"] as? [String: Any], let u = a["_0"] as? [String: Any], let s = u["relative"] as? String { return s }
        return nil
    }

    private func load() throws -> (root: [String: Any], fmt: PropertyListSerialization.PropertyListFormat,
                                   list: [Any], innerFmt: PropertyListSerialization.PropertyListFormat, raw: Data) {
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch { throw PreferenceWriterError.unreadable("\(url.path): \(error)") }
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard let obj = try? PropertyListSerialization.propertyList(from: raw, options: [], format: &fmt),
              let root = obj as? [String: Any] else { throw PreferenceWriterError.malformed("top level is not a dictionary") }
        guard let blob = root[Self.blobKey] as? Data else { throw PreferenceWriterError.malformed("missing \(Self.blobKey) data") }
        var ifmt = PropertyListSerialization.PropertyListFormat.binary
        guard let inner = try? PropertyListSerialization.propertyList(from: blob, options: [], format: &ifmt),
              let list = inner as? [Any], list.count % 2 == 0 else { throw PreferenceWriterError.malformed("blob is not an even-length array") }
        return (root, fmt, list, ifmt, raw)
    }

    public func entries() throws -> [Entry] {
        let (_, _, list, _, _) = try load()
        var out: [Entry] = []
        for i in stride(from: 0, to: list.count, by: 2) {
            guard let k = Self.locationKey(list[i]), let v = list[i + 1] as? [String: Any] else { continue }
            let items = (v["menuItemLocations"] as? [Any] ?? []).compactMap { Self.locationKey($0) }
            out.append(Entry(key: k, isAllowed: (v["isAllowed"] as? Bool) ?? true, menuItemKeys: items))
        }
        return out
    }

    public func isAllowed(_ key: String) throws -> Bool? {
        try entries().first { $0.key == key }?.isAllowed
    }

    /// Sets `isAllowed` for an existing entry. Unknown keys throw unless `create` (then a bundle-id entry is appended).
    /// `module:` keys and `com.apple.*` bundles are refused. Atomic write preserving permissions.
    public mutating func setAllowed(_ key: String, _ allowed: Bool, create: Bool = false) throws {
        if key.hasPrefix("module:") || key.hasPrefix("com.apple.") {
            throw PreferenceWriterError.malformed("refusing to edit Apple/system entry \(key)")
        }
        var (root, fmt, list, ifmt, raw) = try load()
        var found = false
        for i in stride(from: 0, to: list.count, by: 2) where Self.locationKey(list[i]) == key {
            guard var v = list[i + 1] as? [String: Any] else { throw PreferenceWriterError.malformed("entry for \(key) is not a dictionary") }
            v["isAllowed"] = allowed
            list[i + 1] = v
            found = true
        }
        if !found {
            guard create else { throw PreferenceWriterError.malformed("unknown entry \(key) (pass --create to add)") }
            let loc: [String: Any] = ["bundle": ["_0": key]]
            list.append(loc)
            list.append(["location": loc, "menuItemLocations": [loc], "isAllowed": allowed] as [String: Any])
        }
        if backup == nil { backup = raw }
        let blob: Data
        do {
            blob = try PropertyListSerialization.data(fromPropertyList: list, format: ifmt, options: 0)
            root[Self.blobKey] = blob
            try atomicWrite(try PropertyListSerialization.data(fromPropertyList: root, format: fmt, options: 0))
        } catch let e as PreferenceWriterError { throw e }
        catch { throw PreferenceWriterError.writeFailed("serialize: \(error)") }
    }

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
            if rename(tmp.path, url.path) != 0 { throw PreferenceWriterError.writeFailed("rename: \(String(cString: strerror(errno)))") }
        } catch {
            try? fm.removeItem(at: tmp)
            if error is PreferenceWriterError { throw error }
            throw PreferenceWriterError.writeFailed("\(error)")
        }
    }
}
