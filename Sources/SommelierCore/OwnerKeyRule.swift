import AppKit
import Foundation

/// What we know about a running app that is relevant to deriving MenuBarAgent's `ownerKey`.
public struct OwnerAppInfo: Sendable, Equatable {
    public var bundleID: String?
    public var localizedName: String?
    /// `executableURL.lastPathComponent` (the process name).
    public var executableName: String?
    /// Full path of the executable (used to decide whether the app is "installed").
    public var executablePath: String?
    /// `bundleURL.lastPathComponent` minus `.app`.
    public var bundleDirName: String?
    /// CFBundleName.
    public var bundleName: String?
    /// Code-signing identifier, when known (never needed for the rule; only a last-resort candidate).
    public var signingIdentifier: String?

    public init(bundleID: String? = nil, localizedName: String? = nil, executableName: String? = nil,
                executablePath: String? = nil, bundleDirName: String? = nil, bundleName: String? = nil,
                signingIdentifier: String? = nil) {
        self.bundleID = bundleID; self.localizedName = localizedName; self.executableName = executableName
        self.executablePath = executablePath; self.bundleDirName = bundleDirName; self.bundleName = bundleName
        self.signingIdentifier = signingIdentifier
    }

    /// Reads the info from a live process. Does not shell out to codesign.
    public static func live(pid: pid_t) -> OwnerAppInfo? {
        guard let a = NSRunningApplication(processIdentifier: pid) else { return nil }
        let bundleName = a.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return OwnerAppInfo(
            bundleID: a.bundleIdentifier, localizedName: a.localizedName,
            executableName: a.executableURL?.lastPathComponent, executablePath: a.executableURL?.path,
            bundleDirName: a.bundleURL?.deletingPathExtension().lastPathComponent, bundleName: bundleName)
    }
}

/// How MenuBarAgent derives the first component of `status:<ownerKey>::<autosaveName>` (empirical, see
/// docs/findings-identity.md):
///
/// * the **bundle identifier** when the app runs from an installed location (/Applications, /System, /Library,
///   login-item helpers, registered helpers under ~/Library/Application Support);
/// * the **executable (process) name** otherwise (apps run from a build directory, ~/Applications, ~/src,
///   App Translocation, bare executables).
///
/// It is NOT the code-signing identifier, CFBundleName, localized name or bundle directory name (controlled
/// experiment with executable, bundle dir, CFBundleName and bundle id all different). Because the rule is inferred,
/// `candidates` returns every plausible value in rule order and the resolver validates them against the live store.
public enum OwnerKeyRule {
    /// True when the path looks like a location where bundle-id keying was observed.
    public static func isInstalledLocation(_ path: String?) -> Bool {
        guard let p = path else { return false }
        let prefixes = ["/Applications/", "/System/", "/Library/", "/usr/", "/opt/"]
        if prefixes.contains(where: { p.hasPrefix($0) }) { return true }
        if p.contains("/Contents/Library/LoginItems/") || p.contains("/Contents/Library/LaunchServices/") { return true }
        // Registered per-user helpers (e.g. iStat Menus Menubar.app) observed keyed by bundle id.
        if p.contains("/Library/Application Support/") { return true }
        return false
    }

    /// Candidate owner keys, most likely first, de-duplicated, empty values dropped.
    public static func candidates(for app: OwnerAppInfo) -> [String] {
        let bid = app.bundleID
        let exe = app.executableName
        let installed = isInstalledLocation(app.executablePath)
        // Without a path we cannot tell; bundle id is right for 33 of 40 observed apps.
        let known = app.executablePath != nil
        let primary: [String?] = (installed || !known) ? [bid, exe] : [exe, bid]
        let rest: [String?] = [app.bundleDirName, app.bundleName, app.localizedName, app.signingIdentifier]
        var seen = Set<String>()
        return (primary + rest).compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
