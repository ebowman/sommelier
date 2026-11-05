import AppKit
import Foundation

/// Wording for hide-unit refusals and notes (gdu.76): the parent app's display name when known, the tracked key as fallback.
public enum HideUnitNames {
    /// `lookup` maps a bundle id to a localized app name (NSRunningApplication in the app); blank/nil/failed falls back to the key.
    public static func display(trackedKey key: String, lookup: (String) -> String?) -> String {
        guard let n = lookup(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return key }
        return n
    }

    /// The running app's localized name for a bundle id (nil when not running or the key is not a bundle id).
    public static func runningAppName(_ bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
    }

    public static func groupRefusal(entry: String) -> String { "hides together with \(entry): move the whole group" }

    public static func staleMemberRefusal(entry: String) -> String {
        "hides together with \(entry): a member's state is unknown; retrying when the bar settles"
    }

    /// The Arrange tooltip of a unit row: "Hides together with <mates>", naming the governing app when it is known and not
    /// already among the mates ("Hides together with Hazel Helper (all part of Hazel)").
    public static func unitNote(mates: [String], app: String?) -> String? {
        guard !mates.isEmpty else { return nil }
        var s = "Hides together with " + mates.joined(separator: ", ")
        if let app, !app.isEmpty, !mates.contains(app) { s += " (all governed by \(app))" }
        return s
    }
}
