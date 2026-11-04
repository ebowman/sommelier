import Foundation
import Security

/// Whether this process carries `com.apple.security.application-groups` containing `group.com.apple.controlcenter`.
/// Without it CFPreferences writes to that domain do NOT fail: they silently land in
/// ~/Library/Preferences/group.com.apple.controlcenter.plist where MenuBarAgent never looks
/// (docs/findings-live-trigger.md), so the live path must be decided before writing.
public enum AppGroupEntitlement {
    public static let controlCenterGroup = "group.com.apple.controlcenter"

    private static let cached: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) else { return false }
        return (v as? [String])?.contains(controlCenterGroup) ?? false
    }()

    public static func hasControlCenterGroup() -> Bool { cached }
}
