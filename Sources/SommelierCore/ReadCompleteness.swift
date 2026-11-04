import Foundation

/// How much a full scan can be trusted (gdu.51).
///  - `complete`: the MenuBarAgent hosted tree was read without a failed group (the old `hostedReadComplete == true`).
///  - `completeExceptSelfPositioning`: the tree has failed groups, but EVERY stale (carried) item belongs to a
///    self-positioning owner (iStat: its AX answers time out for 40+ s at a time) and those items account for every failed
///    read. Enough for MEMBERSHIP evidence of other owners (hide/show verification, hosted-element evidence, agreement of
///    two scans); not for the notHosted judgement and not for drags involving the self-positioning owners.
///  - `incomplete`: anything else.
public enum ReadCompleteness: String, Codable, Sendable {
    case complete, completeExceptSelfPositioning, incomplete

    /// Usable for membership evidence of a unit that is not self-positioning.
    /// Name used by `mbprobe list` (`level=...` and the json `completeness` field).
    public var displayName: String { self == .completeExceptSelfPositioning ? "exceptSelfPositioning" : rawValue }

    public var membershipUsable: Bool { self != .incomplete }
}

/// Identifies self-positioning owners (`LiveActuator.Config.selfPositioningOwners`: bundle ids or process names) among
/// scanner items, hosted identifiers and keys.
public enum SelfPositioning {
    /// Reverse-DNS prefixes under which an owner's hosted elements are identified ("com.bjango.istatmenus.status" owns
    /// "com.bjango.istatmenus.cpu"): the bundle id itself and its parent.
    static func prefixes(_ bundle: String) -> [String] {
        var out = [bundle + "."]
        var comps = bundle.split(separator: ".").map(String.init)
        comps.removeLast()
        if comps.count >= 3 { out.append(comps.joined(separator: ".") + ".") }
        return out
    }

    public static func matches(identifier: String, owners: Set<String>) -> Bool {
        guard !identifier.isEmpty else { return false }
        return owners.contains { $0.contains(".") && prefixes($0).contains { identifier.hasPrefix($0) } }
    }

    public static func matches(bundleID: String?, name: String?, owners: Set<String>) -> Bool {
        if let b = bundleID, owners.contains(b) { return true }
        if let n = name, owners.contains(n) { return true }
        return false
    }

    public static func matches(_ item: MenuBarItem, owners: Set<String>) -> Bool {
        matches(bundleID: item.ownerBundleID, name: item.ownerName, owners: owners)
            || matches(identifier: item.axIdentifier, owners: owners)
    }

    /// Drops the hosted entries of self-positioning owners (by identifier prefix), so layouts of a complete and of a
    /// `completeExceptSelfPositioning` read compare on everything else.
    public static func strip(_ layout: [HostedEntry], owners: Set<String>) -> [HostedEntry] {
        layout.filter { !matches(identifier: $0.sig, owners: owners) }
    }
}
