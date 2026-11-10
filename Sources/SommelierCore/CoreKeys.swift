import Foundation

/// Why a key could not be interned.
public enum CoreKeysError: Error, Equatable, Sendable {
    /// The key is (or was seen as) the overflow chevron. The chevron is the boundary, never a menu bar item the core reasons about (A7).
    case chevron(ItemKey)
    /// All 2^32 ids are used (cannot happen in practice; typed so that it can never wrap around and reuse an id).
    case exhausted
}

/// A bijective interner `ItemKey <-> UInt32` for the decision core (A4: a `Key` names the same menu bar item in the record, in the reading and
/// on the bar). Ids are assigned in first-seen order and are NEVER reused within the lifetime of the value: there is no removal. The overflow
/// chevron is never interned: `rejectChevron` registers its key, and `intern` throws `.chevron` for it forever after.
///
/// A value type, `Sendable`: the engine actor will own the one instance (the single serial owner, wiring plan section 5).
public struct CoreKeys: Sendable {
    private var ids: [ItemKey: UInt32] = [:]
    private var keys: [ItemKey] = []
    private var chevrons: Set<ItemKey> = []
    public init() {}

    /// Number of interned keys (the next id).
    public var count: Int { keys.count }

    /// The id of `key`, assigning the next free one when it is new.
    public mutating func intern(_ key: ItemKey) throws(CoreKeysError) -> UInt32 {
        if chevrons.contains(key) { throw .chevron(key) }
        if let id = ids[key] { return id }
        guard keys.count <= Int(UInt32.max) else { throw .exhausted }
        let id = UInt32(keys.count)
        ids[key] = id
        keys.append(key)
        return id
    }

    /// Records that `key` is the overflow chevron. If it had been interned earlier its id stays reserved (never reused) but `id(for:)` no longer
    /// answers for it and `intern` throws.
    public mutating func rejectChevron(_ key: ItemKey) { chevrons.insert(key) }
    public func isChevron(_ key: ItemKey) -> Bool { chevrons.contains(key) }

    /// The id of an already interned, non-chevron key.
    public func id(for key: ItemKey) -> UInt32? { chevrons.contains(key) ? nil : ids[key] }
    /// The key an id was assigned to (nil for an id never handed out, or one whose key was later registered as the chevron).
    public func key(for id: UInt32) -> ItemKey? {
        guard Int(id) < keys.count, !chevrons.contains(keys[Int(id)]) else { return nil }
        return keys[Int(id)]
    }
}
