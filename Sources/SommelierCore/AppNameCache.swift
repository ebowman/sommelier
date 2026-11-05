import Foundation

/// Memoizes app display-name lookups (a LaunchServices round trip each) until `invalidate()` (gdu.93).
/// Nil results are cached too, so a not-running app is not re-queried.
public struct AppNameCache {
    private let lookup: (String) -> String?
    private var cache: [String: String?] = [:]
    public private(set) var lookupCount = 0

    public init(lookup: @escaping (String) -> String?) { self.lookup = lookup }

    public mutating func name(for bundleID: String) -> String? {
        if let hit = cache[bundleID] { return hit }
        lookupCount += 1
        let value = lookup(bundleID)
        cache[bundleID] = .some(value)
        return value
    }

    public mutating func invalidate() { cache.removeAll() }
}
