import Foundation

/// Storage for the two global status-item spacing keys (injectable for tests).
public protocol SpacingPreferencesBackend: Sendable {
    func integer(forKey key: String) -> Int?
    /// nil removes the key. Returns whether the write was synchronized.
    @discardableResult func set(_ value: Int?, forKey key: String) -> Bool
}

/// Real backend: global domain, current user, current host (== `defaults -currentHost ... -globalDomain`).
public struct GlobalCurrentHostBackend: SpacingPreferencesBackend {
    public init() {}
    public func integer(forKey key: String) -> Int? {
        _ = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let v = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { return nil }
        return (v as? NSNumber)?.intValue
    }
    @discardableResult
    public func set(_ value: Int?, forKey key: String) -> Bool {
        CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}

/// `NSStatusItemSpacing` (gap between items) and `NSStatusItemSelectionPadding` (highlight padding).
public struct SpacingSettings: Sendable {
    public static let spacingKey = "NSStatusItemSpacing"
    public static let paddingKey = "NSStatusItemSelectionPadding"
    public static let range = 0...24

    private let backend: SpacingPreferencesBackend
    public init(backend: SpacingPreferencesBackend = GlobalCurrentHostBackend()) { self.backend = backend }

    public static func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }

    /// What `mbprobe spacing set` does with one requested value: negative = refused (exit 2), above the range = clamped with a
    /// warning, otherwise used as is.
    public enum Decision: Equatable, Sendable {
        case use(Int)
        case clamped(from: Int, to: Int)
        case refused(Int)
    }

    public static func decide(_ v: Int) -> Decision {
        if v < range.lowerBound { return .refused(v) }
        let c = clamp(v)
        return c == v ? .use(v) : .clamped(from: v, to: c)
    }

    public func current() -> (spacing: Int?, padding: Int?) {
        (backend.integer(forKey: Self.spacingKey), backend.integer(forKey: Self.paddingKey))
    }

    /// Writes the given values (clamped); nil leaves that key untouched. Returns false if a write failed to sync.
    @discardableResult
    public func set(spacing: Int? = nil, padding: Int? = nil) -> Bool {
        var ok = true
        if let s = spacing { ok = backend.set(Self.clamp(s), forKey: Self.spacingKey) && ok }
        if let p = padding { ok = backend.set(Self.clamp(p), forKey: Self.paddingKey) && ok }
        return ok
    }

    /// Removes both keys (system default).
    @discardableResult
    public func reset() -> Bool {
        let a = backend.set(nil, forKey: Self.spacingKey)
        let b = backend.set(nil, forKey: Self.paddingKey)
        return a && b
    }
}
