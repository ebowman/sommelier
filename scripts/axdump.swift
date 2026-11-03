// Throwaway AX dump: per-app AXExtrasMenuBar items + MenuBarAgent hosted buttons, sorted left to right.
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func fr(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
var rows: [(CGFloat, String)] = []
func add(_ src: String, _ e: AXUIElement) {
    let f = fr(e)
    rows.append((f.minX, String(format: "x=%6.0f y=%5.0f w=%4.0f h=%3.0f  %@ | %@ sub=%@ title='%@' desc='%@' id='%@'", f.minX, f.minY, f.width, f.height, src, str(e,kAXRoleAttribute), str(e,kAXSubroleAttribute), str(e,kAXTitleAttribute), str(e,kAXDescriptionAttribute), str(e,kAXIdentifierAttribute))))
}
func walk(_ src: String, _ e: AXUIElement, _ depth: Int) {
    if str(e, kAXRoleAttribute) == "AXMenuBarItem" || str(e, kAXRoleAttribute) == "AXButton" || str(e, kAXRoleAttribute) == "AXMenuButton" || str(e, kAXRoleAttribute) == "AXStatusItem" { add(src, e) }
    guard depth < 4, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids.prefix(80) { walk(src, k, depth + 1) }
}
print("trusted:", AXIsProcessTrusted())
for app in NSWorkspace.shared.runningApplications {
    let ax = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.25)
    let name = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) pid=\(app.processIdentifier)"
    if app.bundleIdentifier == "com.apple.MenuBarAgent" {
        print("MenuBarAgent pid=\(app.processIdentifier)")
        for w in (attr(ax, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk("[Agent] " + name, w, 0) }
        continue
    }
    guard let extras = attr(ax, "AXExtrasMenuBar") else { continue }
    for k in (attr(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { add("[Extras] " + name, k) }
}
for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
