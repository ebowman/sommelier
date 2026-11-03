import Foundation
import SommelierCore
import ApplicationServices
import CoreGraphics

// Hand-rolled argument parsing.
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mbprobe list [--json] [--include-self] [--timing] [--debug] [--fast] [--repeat N]
           mbprobe set-position <bundleID> <autosaveName> <number> [--host] [--store legacy|agent]
           mbprobe watch [--seconds N]
           mbprobe agent-restart
           mbprobe set-visible <bundleID> <autosaveName> <0|1> [--host]
           mbprobe cc-allowed list
           mbprobe cc-allowed set <appKey> <0|1> [--restart] [--create] [--restart-cc]
           mbprobe press <bundleID-or-key> [--escape-after SECONDS]

    """.utf8))
    exit(2)
}

func clip(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ")
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

func row(_ idx: Int, _ i: MenuBarItem) -> String {
    let label = (i.stale ? "(stale) " : "") + [i.title, i.axDescription, i.axIdentifier].map { clip($0, 36) }.joined(separator: " | ")
    let pad = { (s: String, n: Int) in s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    return "\(pad(String(idx), 3)) x=\(pad(String(Int(i.frame.minX)), 6)) w=\(pad(String(Int(i.frame.width)), 4)) "
        + "\(pad(clip(i.ownerName, 28), 28)) \(pad(i.ownerBundleID ?? "-", 40)) \(label)  [\(i.source.rawValue)]"
}

func runList(_ rawFlags: [String]) {
    // --repeat N: scan N times with one scanner (shows warm-cache speedups); only the last result is printed.
    var flags = rawFlags
    var repeats = 1
    if let i = flags.firstIndex(of: "--repeat") {
        guard i + 1 < flags.count, let n = Int(flags[i + 1]), n > 0 else { usage() }
        repeats = n
        flags.removeSubrange(i...(i + 1))
    }
    let known: Set<String> = ["--json", "--include-self", "--timing", "--debug", "--fast"]
    guard flags.allSatisfy(known.contains) else { usage() }
    let start = Date()
    let debug = flags.contains("--debug")
    let logger: @Sendable (String) -> Void = { msg in
        if debug { FileHandle.standardError.write(Data(("debug: " + msg + "\n").utf8)) }
    }
    let scanner = MenuBarScanner(includeSelf: flags.contains("--include-self"),
                                 cacheURL: MenuBarScanner.defaultCacheURL, log: logger)
    var fast = flags.contains("--fast")
    if fast && !scanner.isWarm {
        FileHandle.standardError.write(Data("mbprobe: no scan cache yet; doing one full scan to populate it\n".utf8))
        fast = false
    }
    var snap = fast ? scanner.scanVisible() : scanner.scan()
    var elapsed = Date().timeIntervalSince(start)
    for n in 2...max(2, repeats) where repeats > 1 {
        let t = Date()
        snap = fast ? scanner.scanVisible() : scanner.scan()
        elapsed = Date().timeIntervalSince(t)
        FileHandle.standardError.write(Data(String(format: "scan %d: %.0f ms\n", n, elapsed * 1000).utf8))
    }
    if flags.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(snap), as: UTF8.self))
    } else {
        print("on bar (left to right):")
        for (n, i) in snap.onBarLeftToRight.enumerated() { print(row(n, i)) }
        print("\nparked / off-bar:")
        for (n, i) in snap.parked.enumerated() { print(row(n, i)) }
    }
    if flags.contains("--timing") {
        let msg = String(format: "scan time: %.0f ms (%@)\n", elapsed * 1000, fast ? "fast" : "full")
        FileHandle.standardError.write(Data(msg.utf8))
    }
}

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("mbprobe: " + m + "\n").utf8)); exit(1)
}

func runSetPosition(_ a: [String]) {
    var pos: [String] = []
    var host = false
    var store = "legacy"
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--host": host = true
        case "--store":
            i += 1
            guard i < a.count, ["legacy", "agent"].contains(a[i]) else { usage() }
            store = a[i]
        default:
            if a[i].hasPrefix("--") { usage() }
            pos.append(a[i])
        }
        i += 1
    }
    guard pos.count == 3, let value = Double(pos[2]) else { usage() }
    if store == "agent" {
        var s = MenuBarOrderStore()
        do { try s.setPosition(bundleID: pos[0], autosaveName: pos[1], value: value) } catch { fail("\(error)") }
        print("agent store: \(MenuBarOrderStore.key(bundleID: pos[0], autosaveName: pos[1])) = \(value)")
    } else {
        let ok = PreferenceWriter.setLegacyPosition(bundleID: pos[0], autosaveName: pos[1], value: value, currentHost: host)
        print("legacy: \(PreferenceWriter.legacyKey(autosaveName: pos[1])) = \(value) in \(pos[0]) (\(host ? "current host" : "any host")) synchronize=\(ok)")
        if !ok { exit(1) }
    }
}

func signature(_ s: MenuBarSnapshot) -> [String] {
    s.onBarLeftToRight.map { i in
        // A title-only item can be a live readout ("64%"): digits are masked so it does not look like a change.
        let label = !i.axIdentifier.isEmpty ? i.axIdentifier : !i.axDescription.isEmpty ? i.axDescription
            : String(i.title.map { $0.isNumber ? "#" : $0 })
        return "\(i.ownerBundleID ?? i.ownerName)|\(label)"
    }
}

func runWatch(_ a: [String]) {
    var seconds: Double = 60
    if !a.isEmpty {
        guard a.count == 2, a[0] == "--seconds", let n = Double(a[1]), n > 0 else { usage() }
        seconds = n
    }
    let start = Date()
    var last: [String]? = nil
    let scanner = MenuBarScanner()  // one instance: element and extras caches persist between iterations
    while true {
        let snap = scanner.scan()
        let sig = signature(snap)
        let stamp = String(format: "[+%.1fs]", Date().timeIntervalSince(start))
        if let l = last {
            if l != sig {
                print("\(stamp) order changed")
                for line in diffLines(l, sig) { print("  " + line) }
            }
        } else {
            print("\(stamp) initial (\(sig.count) items)")
            for (n, k) in sig.enumerated() { print("  \(n) \(k)") }
        }
        last = sig
        fflush(stdout)
        if Date().timeIntervalSince(start) + 2 >= seconds { break }
        Thread.sleep(forTimeInterval: 2)
    }
}

/// Simple diff: removed (-), added (+), and moved items (index old -> new).
func diffLines(_ a: [String], _ b: [String]) -> [String] {
    var out: [String] = []
    for (i, k) in a.enumerated() {
        if let j = b.firstIndex(of: k) { if i != j { out.append("~ \(k): \(i) -> \(j)") } } else { out.append("- \(k) (was \(i))") }
    }
    for (j, k) in b.enumerated() where !a.contains(k) { out.append("+ \(k) (now \(j))") }
    return out
}

func runAgentRestart() {
    let r = MenuBarAgentControl.restart(timeout: 10)
    print("hosted before=\(r.before) after=\(r.after) elapsed=\(r.elapsedMS) ms recovered=\(r.recovered)")
    if !r.recovered { exit(1) }
}

func runSetVisible(_ a: [String]) {
    let host = a.contains("--host")
    let pos = a.filter { $0 != "--host" }
    guard pos.count == 3, !pos[0].hasPrefix("--"), ["0", "1"].contains(pos[2]) else { usage() }
    let key = "NSStatusItem Visible \(pos[1])"
    let v = pos[2] == "1"
    let ok: Bool
    if host {
        CFPreferencesSetValue(key as CFString, v as CFBoolean, pos[0] as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        ok = CFPreferencesSynchronize(pos[0] as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    } else {
        CFPreferencesSetAppValue(key as CFString, v as CFBoolean, pos[0] as CFString)
        ok = CFPreferencesAppSynchronize(pos[0] as CFString)
    }
    print("legacy: \(key) = \(v) in \(pos[0]) (\(host ? "current host" : "any host")) synchronize=\(ok)")
    if !ok { exit(1) }
}

func runCCAllowed(_ a: [String]) {
    guard let sub = a.first else { usage() }
    var store = ControlCenterTrackedAppsStore()
    switch sub {
    case "list":
        do {
            for e in try store.entries() {
                print("\(e.isAllowed ? "1" : "0") \(e.key)" + (e.menuItemKeys == [e.key] ? "" : "  items=\(e.menuItemKeys)"))
            }
        } catch { fail("\(error)") }
    case "set":
        let flags = Set(a.filter { $0.hasPrefix("--") })
        guard flags.isSubset(of: ["--restart", "--create", "--restart-cc"]) else { usage() }
        let pos = a.dropFirst().filter { !$0.hasPrefix("--") }
        guard pos.count == 2, ["0", "1"].contains(pos[1]) else { usage() }
        do { try store.setAllowed(pos[0], pos[1] == "1", create: flags.contains("--create")) } catch { fail("\(error)") }
        print("cc-allowed: \(pos[0]) isAllowed=\(pos[1] == "1")")
        if flags.contains("--restart") { runAgentRestart() }
        if flags.contains("--restart-cc") {
            // NOT killall: third-party apps (e.g. Elgato Control Center) are also named "ControlCenter".
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "^/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter$"]
            try? p.run(); p.waitUntilExit(); print("killed system ControlCenter")
        }
    default: usage()
    }
}

func runPress(_ a: [String]) {
    var pos: [String] = []
    var escapeAfter: Double? = nil
    var i = 0
    while i < a.count {
        if a[i] == "--escape-after" {
            i += 1
            guard i < a.count, let n = Double(a[i]) else { usage() }
            escapeAfter = n
        } else if a[i].hasPrefix("--") { usage() } else { pos.append(a[i]) }
        i += 1
    }
    guard pos.count == 1 else { usage() }
    let snap = MenuBarScanner().scan()
    guard let item = snap.items.first(where: {
        $0.source == .appExtras && ($0.ownerBundleID == pos[0] || $0.axIdentifier == pos[0] || "\($0.ownerBundleID ?? "")::\($0.axIdentifier)" == pos[0])
    }), let el = item.axElement else { fail("no app-side item matches \(pos[0])") }
    print("target: \(item.ownerName) \(item.axIdentifier) frame=\(item.frame) onBar=\(item.isOnMenuBar)")
    let t0 = Date()
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    print("AXPress -> AXError \(err.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    Thread.sleep(forTimeInterval: 0.7)
    var ch: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch)
    for c in (ch as? [AXUIElement]) ?? [] {
        var r: CFTypeRef?; AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &r)
        var p: CFTypeRef?; AXUIElementCopyAttributeValue(c, kAXPositionAttribute as CFString, &p)
        var pt = CGPoint.zero
        if let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &pt) }
        print("child role=\(r as? String ?? "?") pos=\(pt)")
    }
    var pid: pid_t = 0; AXUIElementGetPid(el, &pid)
    var wins: CFTypeRef?
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
    for w in (wins as? [AXUIElement]) ?? [] {
        var r: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &r)
        var p: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p)
        var sz: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sz)
        var pt = CGPoint.zero, s = CGSize.zero
        if let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &pt) }
        if let sz, CFGetTypeID(sz) == AXValueGetTypeID() { AXValueGetValue(unsafeBitCast(sz, to: AXValue.self), .cgSize, &s) }
        print("window role=\(r as? String ?? "?") pos=\(pt) size=\(s)")
    }
    if let e = escapeAfter {
        Thread.sleep(forTimeInterval: e)
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
        print("escape sent")
    }
}

switch args.first {
case "set-visible": runSetVisible(Array(args.dropFirst()))
case "cc-allowed": runCCAllowed(Array(args.dropFirst()))
case "press": runPress(Array(args.dropFirst()))
case "set-position": runSetPosition(Array(args.dropFirst()))
case "watch": runWatch(Array(args.dropFirst()))
case "agent-restart": runAgentRestart()
case "list": runList(Array(args.dropFirst()))
default: usage()
}
