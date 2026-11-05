// Live check (gdu.35): right-click the Sommelier status item and read the menu it opens. NOT run by the author: a live
// task runs `swift scripts/check-rightclick-menu.swift` with Sommelier.app running and Accessibility granted to the terminal.
// It posts one CGEvent right-click at the item and one Escape, so do not touch the mouse/keyboard while it runs.
// Exit 0: the menu appeared with titles, closed on Escape. Exit 1: failure. Exit 2: item not found / not trusted.
import AppKit
import ApplicationServices

let ident = "ie.boboco.sommelier.statusitem"
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func frame(_ e: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute),
          AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
func find(_ e: AXUIElement, _ depth: Int, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    guard depth < 5, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids.prefix(80) { if let r = find(k, depth + 1, pred) { return r } }
    return nil
}
func menus(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.5)
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        if str(e, kAXRoleAttribute) == "AXMenu" { out.append(e); return }
        guard d < 4, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids.prefix(40) { walk(k, d + 1) }
    }
    walk(app, 0)
    return out
}
func post(_ type: CGEventType, _ at: CGPoint, _ button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)?.post(tap: .cghidEventTap)
}

guard AXIsProcessTrusted() else { print("FAIL: this process is not Accessibility-trusted"); exit(2) }
guard let sommelier = NSRunningApplication.runningApplications(withBundleIdentifier: "ie.boboco.sommelier").first else {
    print("FAIL: Sommelier is not running"); exit(2)
}
// The status item is hosted by MenuBarAgent (or sits in the app's own extras bar); search both for our AX identifier.
var button: AXUIElement?
let owners = [sommelier] + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
for o in owners where button == nil {
    let ax = AXUIElementCreateApplication(o.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.5)
    button = find(ax, 0) { str($0, kAXIdentifierAttribute) == ident }
}
guard let button, let f = frame(button), f.width > 0 else { print("FAIL: Sommelier status item not found (hidden or in system overflow?)"); exit(2) }
let c = CGPoint(x: f.midX, y: f.midY)
print("status item frame:", f)

let before = menus(pid: sommelier.processIdentifier).count
post(.rightMouseDown, c, .right); usleep(80_000); post(.rightMouseUp, c, .right)
usleep(600_000)
let opened = menus(pid: sommelier.processIdentifier)
var ok = true
if opened.count > before, let m = opened.last, let f2 = frame(m) {
    let titles = ((attr(m, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { str($0, kAXTitleAttribute) }
    print("menu titles:", titles.map { $0.isEmpty ? "---" : $0 }.joined(separator: " | "))
    print("menu frame:", f2)
    if titles.filter({ !$0.isEmpty }).isEmpty { print("FAIL: menu has no titled items"); ok = false }
    if abs(f2.minX - f.minX) > 400 || f2.minY > f.maxY + 40 { print("FAIL: menu did not appear at the status item"); ok = false }
} else { print("FAIL: no AXMenu appeared after the right click"); ok = false }

// Escape (key code 53) must close it.
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
usleep(500_000)
if menus(pid: sommelier.processIdentifier).count > before { print("FAIL: menu still open after Escape"); ok = false }
print(ok ? "PASS" : "FAIL")
print("Manual remainder: left-click the item and confirm the panel toggles (this script does not click left).")
exit(ok ? 0 : 1)
