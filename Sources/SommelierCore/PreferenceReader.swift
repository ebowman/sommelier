import Foundation

/// One autosave name known for an owner, with every value we could read for it.
public struct AutosaveEntry: Hashable, Sendable {
    public var name: String
    /// Value in MenuBarAgent's order store (distance from the right edge; bigger = further left).
    public var storeValue: Double?
    /// `NSStatusItem Preferred Position <name>` in the app's own defaults.
    public var legacyPosition: Double?
    /// `NSStatusItem Visible <name>` in the app's own defaults.
    public var legacyVisible: Double?

    public init(name: String, storeValue: Double? = nil, legacyPosition: Double? = nil, legacyVisible: Double? = nil) {
        self.name = name; self.storeValue = storeValue; self.legacyPosition = legacyPosition; self.legacyVisible = legacyVisible
    }
}

/// Source of autosave names. Live implementation reads the order store file and CFPreferences.
public protocol PreferenceReader: Sendable {
    /// Raw order store: store key (`status:...`, `module:...`) -> value. Empty when unreadable.
    func orderStore() -> [String: Double]
    /// Legacy `NSStatusItem Preferred Position *` / `NSStatusItem Visible *` entries in a defaults domain.
    func legacyEntries(domain: String) -> [AutosaveEntry]
}

public extension PreferenceReader {
    /// Order-store entries whose key parses as `status:<ownerKey>::<name>`, grouped by ownerKey, names sorted.
    func storeEntriesByOwner() -> [String: [AutosaveEntry]] {
        var out: [String: [AutosaveEntry]] = [:]
        for (k, v) in orderStore() {
            guard case .status(let o, let a)? = ItemKey(storeKey: k) else { continue }
            out[o, default: []].append(AutosaveEntry(name: a, storeValue: v))
        }
        return out.mapValues { $0.sorted { $0.name < $1.name } }
    }

    /// Autosave names for an owner: (a) order store (primary), merged with (b) the legacy keys in the defaults domain
    /// `legacyDomain` (secondary; defaults to the owner key). Names found only in the legacy domain are included.
    func autosaveEntries(ownerKey: String, legacyDomain: String? = nil) -> [AutosaveEntry] {
        var byName: [String: AutosaveEntry] = [:]
        for e in storeEntriesByOwner()[ownerKey] ?? [] { byName[e.name] = e }
        for l in legacyEntries(domain: legacyDomain ?? ownerKey) {
            var e = byName[l.name] ?? AutosaveEntry(name: l.name)
            e.legacyPosition = l.legacyPosition; e.legacyVisible = l.legacyVisible
            byName[l.name] = e
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}

/// Reads `MenuBarOrderStore` (plain PropertyListSerialization; the group container is not reachable via CFPreferences)
/// and CFPreferences (any-host and current-host variants of the user domain).
public struct LivePreferenceReader: PreferenceReader {
    public static let positionPrefix = "NSStatusItem Preferred Position "
    public static let visiblePrefix = "NSStatusItem Visible "
    public var storeURL: URL

    public init(storeURL: URL = MenuBarOrderStore.defaultURL) { self.storeURL = storeURL }

    public func orderStore() -> [String: Double] {
        (try? MenuBarOrderStore(url: storeURL).readPositions()) ?? [:]
    }

    public func legacyEntries(domain: String) -> [AutosaveEntry] {
        var byName: [String: AutosaveEntry] = [:]
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            guard let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, host) as? [String] else { continue }
            for k in keys {
                let isPos = k.hasPrefix(Self.positionPrefix), isVis = k.hasPrefix(Self.visiblePrefix)
                guard isPos || isVis else { continue }
                let name = String(k.dropFirst(isPos ? Self.positionPrefix.count : Self.visiblePrefix.count))
                let v = (CFPreferencesCopyValue(k as CFString, domain as CFString, kCFPreferencesCurrentUser, host) as? NSNumber)?.doubleValue
                var e = byName[name] ?? AutosaveEntry(name: name)
                // Any-host value wins over current-host only when current-host has none (first writer wins).
                if isPos { e.legacyPosition = e.legacyPosition ?? v } else { e.legacyVisible = e.legacyVisible ?? v }
                byName[name] = e
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}
