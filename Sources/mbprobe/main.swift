import Foundation
import SommelierCore
import ApplicationServices
import CoreGraphics
import AppKit

// Hand-rolled argument parsing.
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mbprobe permissions [--prompt]
           mbprobe keys <ownerKey|bundleID>
           mbprobe list [--json] [--include-self] [--timing] [--debug] [--fast] [--repeat N]
           mbprobe set-position <bundleID> <autosaveName> <number> [--host] [--store legacy|agent]
           mbprobe watch [--seconds N]
           mbprobe agent-restart
           mbprobe set-visible <bundleID> <autosaveName> <0|1> [--host]
           mbprobe cc-allowed list
           mbprobe cc-allowed set <appKey> <0|1> [--restart] [--create] [--restart-cc]
           mbprobe drag <item> --before <item> | --after <item> | --to-x <n> [--steps N] [--hold-ms N] [--step-ms N]
           mbprobe move <key> --before <key> | --after <key> | --leftmost | --rightmost [--force-fallback] [--no-fallback]
           mbprobe hide <key...> | mbprobe show <key...>      (keys as printed by `list`, e.g. status:ie.boboco.mbdummy::Dummy-A)
           mbprobe layout show [--json] [--file PATH]
           mbprobe layout init-from-current [--file PATH] [--force]
           mbprobe layout move <key> <visible|hidden|always> [index(1-based)] [--file PATH]
           mbprobe layout remove <key> [--file PATH]
           mbprobe plan [--show-hidden] [--file PATH] [--json]      (read-only: prints the reconciler plan, executes nothing)
           mbprobe apply --file PATH [--show-hidden] [--fake] [--max-actions N] [--allow-fallback]      (ONE engine pass: executes the plan)
           mbprobe press <bundleID-or-key> [--escape-after SECONDS]

    """.utf8))
    exit(2)
}

func clip(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ")
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

func row(_ idx: Int, _ r: ResolvedItem) -> String {
    let i = r.item
    let label = (i.stale ? "(stale) " : "") + [i.title, i.axDescription, i.axIdentifier].map { clip($0, 36) }.joined(separator: " | ")
    let pad = { (s: String, n: Int) in s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    return "\(pad(String(idx), 3)) x=\(pad(String(Int(i.frame.minX)), 6)) w=\(pad(String(Int(i.frame.width)), 4)) "
        + "\(pad(clip(i.ownerName, 28), 28)) \(pad(i.ownerBundleID ?? "-", 40)) \(r.confidence.marker) \(pad(r.key.description, 78)) \(label)  [\(i.source.rawValue)]"
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
    let resolved = IdentityResolver().resolve(snapshot: snap)
    if flags.contains("--json") {
        // `keys` / `keyConfidence` are parallel to `items`.
        struct Out: Encodable {
            var items: [MenuBarItem]; var capturedAt: Date; var keys: [String]; var keyConfidence: [String]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let out = Out(items: snap.items, capturedAt: snap.capturedAt,
                      keys: resolved.map { $0.key.description }, keyConfidence: resolved.map { $0.confidence.rawValue })
        print(String(decoding: try! enc.encode(out), as: UTF8.self))
    } else {
        // resolved is in snap.items order: on-bar items first (left to right), then parked.
        let onCount = snap.onBarLeftToRight.count
        print("on bar (left to right):   [key marker: = exact, ~ inferred, ? heuristic]")
        for (n, r) in resolved.prefix(onCount).enumerated() { print(row(n, r)) }
        print("\nparked / off-bar:")
        for (n, r) in resolved.dropFirst(onCount).enumerated() { print(row(n, r)) }
        let counts = Dictionary(grouping: resolved, by: \.confidence).mapValues(\.count)
        print("\nkeys: \(counts[.exact] ?? 0) exact, \(counts[.inferred] ?? 0) inferred, \(counts[.heuristic] ?? 0) heuristic")
    }
    if flags.contains("--timing") {
        let msg = String(format: "scan time: %.0f ms (%@)\n", elapsed * 1000, fast ? "fast" : "full")
        FileHandle.standardError.write(Data(msg.utf8))
    }
}

func runKeys(_ a: [String]) {
    guard a.count == 1 else { usage() }
    let arg = a[0]
    let prefs = LivePreferenceReader()
    let store = prefs.storeEntriesByOwner()
    // Owner keys to show: the argument itself plus every candidate of running apps whose bundle id / name matches.
    var owners: [String] = [arg]
    var legacyDomain: String? = nil   // legacy NSStatusItem keys live in the app's bundle-id domain
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == arg || app.localizedName == arg {
        if let info = OwnerAppInfo.live(pid: app.processIdentifier) {
            legacyDomain = legacyDomain ?? info.bundleID
            print("running: pid \(app.processIdentifier) \(info.executablePath ?? "-")")
            owners += OwnerKeyRule.candidates(for: info)
        }
    }
    var seen = Set<String>()
    owners = owners.filter { seen.insert($0).inserted }
    var shown = false
    for o in owners {
        let entries = prefs.autosaveEntries(ownerKey: o, legacyDomain: legacyDomain ?? o)
        guard !entries.isEmpty else { continue }
        shown = true
        let inStore = store[o] != nil
        print("owner key \"\(o)\"  (order store: \(inStore ? "yes" : "no"))")
        let pad = { (s: String, n: Int) in s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        print("  \(pad("autosaveName", 52)) \(pad("store", 8)) \(pad("legacyPos", 10)) legacyVisible")
        func fmt(_ v: Double?) -> String { v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "-" }
        for e in entries.sorted(by: { ($0.storeValue ?? $0.legacyPosition ?? -1) > ($1.storeValue ?? $1.legacyPosition ?? -1) }) {
            print("  \(pad(e.name, 52)) \(pad(fmt(e.storeValue), 8)) \(pad(fmt(e.legacyPosition), 10)) \(fmt(e.legacyVisible))")
        }
    }
    if !shown { print("no autosave names found for \(owners.map { "\"\($0)\"" }.joined(separator: ", "))"); exit(1) }
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

func runDrag(_ a: [String]) {
    var pos: [String] = []
    var relation: DragRelation? = nil
    var targetQuery: String? = nil
    var steps = 10, holdMS = 100.0, stepMS = 15.0
    var quiet = false, trace = false, fullPoll = false
    var i = 0
    func val() -> String { i += 1; guard i < a.count else { usage() }; return a[i] }
    while i < a.count {
        switch a[i] {
        case "--before": targetQuery = val(); relation = .before(targetQuery!)
        case "--after": targetQuery = val(); relation = .after(targetQuery!)
        case "--to-x": guard let x = Double(val()) else { usage() }; relation = .toX(CGFloat(x))
        case "--steps": guard let n = Int(val()), n > 0 else { usage() }; steps = n
        case "--hold-ms": guard let n = Double(val()), n >= 0 else { usage() }; holdMS = n
        case "--step-ms": guard let n = Double(val()), n >= 0 else { usage() }; stepMS = n
        case "--quiet": quiet = true
        case "--trace": trace = true
        case "--full": fullPoll = true
        default: if a[i].hasPrefix("--") { usage() }; pos.append(a[i])
        }
        i += 1
    }
    guard pos.count == 1, let relation else { usage() }
    if NSEvent.pressedMouseButtons != 0 { fail("a mouse button is pressed (user is using the mouse); aborting") }
    let scanner = MenuBarScanner(cacheURL: MenuBarScanner.defaultCacheURL)
    var snap = scanner.scan()

    func pick(_ q: String, _ snap: MenuBarSnapshot) -> MenuBarItem {
        switch ItemResolver.resolve(q, in: snap.items) {
        case .match(let m): return m
        case .none: fail("no on-bar item matches '\(q)'")
        case .ambiguous(let c):
            FileHandle.standardError.write(Data("mbprobe: '\(q)' is ambiguous; candidates:\n".utf8))
            for m in c { FileHandle.standardError.write(Data("  \(m.ownerBundleID ?? m.ownerName)::\(m.axIdentifier.isEmpty ? m.axDescription : m.axIdentifier)\n".utf8)) }
            exit(1)
        }
    }
    var moved = pick(pos[0], snap)
    var target: MenuBarItem? = targetQuery.map { pick($0, snap) }
    // Re-scan until both items have fresh (non-stale) frames.
    for _ in 0..<4 where moved.stale || (target?.stale ?? false) {
        snap = scanner.scan()
        moved = pick(pos[0], snap); target = targetQuery.map { pick($0, snap) }
    }
    if moved.stale || (target?.stale ?? false) { fail("item frames are stale after rescans; refusing to drag") }
    if ItemResolver.protected(moved) || (target.map(ItemResolver.protected) ?? false) { fail("refusing to drag Control Center/clock/system module items") }
    // Relation by resolved key (not the user's query string)
    var keyRelation = relation
    if let t = target { switch relation { case .before: keyRelation = .before(ItemResolver.key(t)); case .after: keyRelation = .after(ItemResolver.key(t)); default: break } }
    guard let dropX = DragTarget.dropX(for: relation, moved: moved, target: target, bar: snap.onBarLeftToRight) else { fail("no drop x") }
    let movedKey = ItemResolver.key(moved)
    let before = snap.onBarLeftToRight.map(ItemResolver.key)
    if DragTarget.holds(keyRelation, moved: movedKey, order: before) { print("verified: yes (already satisfied; no drag performed)"); exit(0) }

    let mover = DragMover(steps: steps, stepDelay: stepMS / 1000, holdTime: holdMS / 1000)
    let upAt: Date
    do { upAt = try mover.move(itemFrame: moved.frame, toX: dropX) } catch { fail("\(error)") }

    // Poll until two consecutive scans agree (max 4 s).
    var prevSig: [String]? = nil
    var cur = snap
    var firstChangeMS: Int? = nil
    var settledMS: Int? = nil
    var history: [(Int, [String])] = []
    while Date().timeIntervalSince(upAt) < 4.0 {
        cur = fullPoll ? scanner.scan() : scanner.scanVisible()
        let fresh = cur.onBarLeftToRight.filter { !$0.stale || $0.ownerBundleID == moved.ownerBundleID }
        let sig = fresh.map(ItemResolver.key)
        let ms = Int(Date().timeIntervalSince(upAt) * 1000)
        if trace { let m = cur.onBarLeftToRight.first { ItemResolver.key($0) == movedKey }; let mx = m.map { String(Int($0.frame.minX)) } ?? "-"; print("  t=\(ms)ms moved x=\(mx) stale=\(m?.stale ?? false)") }
        history.append((ms, sig))
        if !trace, ms >= 2000, let p = prevSig, p == sig, fresh.contains(where: { ItemResolver.key($0) == movedKey && !$0.stale }) { settledMS = ms; break }
        prevSig = sig
    }
    // visible latency: first poll from which every later poll equals the final signature
    if let last = history.last?.1, let k = history.lastIndex(where: { $0.1 != last }) { firstChangeMS = k + 1 < history.count ? history[k + 1].0 : nil } else { firstChangeMS = history.first?.0 }
    // Final authoritative check: the fast scan can mis-join identifier-less items right after a move
    // (app-side frame lags the hosted frame), so confirm with one full scan.
    let confirmStart = Date()
    cur = scanner.scan()
    let confirmMS = Int(Date().timeIntervalSince(confirmStart) * 1000)
    let now = cur.onBarLeftToRight
    let order = now.map(ItemResolver.key)
    let movedNow = now.first { ItemResolver.key($0) == movedKey && !$0.stale }
    let ok = DragTarget.holds(keyRelation, moved: movedKey, order: order, movedMidX: movedNow?.frame.midX)
    if !quiet {
        print("order after drag:")
        for (n, it) in now.enumerated() { print("  \(n) x=\(Int(it.frame.minX)) \(ItemResolver.key(it))\(it.stale ? " (stale)" : "")") }
    }
    print(String(format: "mouse_up_epoch=%.3f", upAt.timeIntervalSince1970))
    print("dropX=\(Int(dropX)) confirm_scan_ms=\(confirmMS) visible_ms=\(firstChangeMS.map(String.init) ?? "none") settled_ms=\(settledMS.map(String.init) ?? "unsettled")")
    print("verified: \(ok ? "yes" : "no")")
    if !ok { exit(3) }
}

// MARK: - closed-loop actuation (LiveActuator)

func parseKey(_ s: String) -> ItemKey {
    guard let k = ItemKey(storeKey: s) else { fail("not an item key: \(s) (expected status:<owner>::<name> or module:<name>)") }
    return k
}

func describe(_ r: ActuationResult) -> String {
    switch r {
    case .verified: return "verified"
    case .failed(let e, _): return "failed(\(e))"
    }
}

func printFinalOrder(_ snap: MenuBarSnapshot?) {
    guard let snap else { print("final order: (no snapshot)"); return }
    let resolved = IdentityResolver().resolve(snapshot: snap)
    print("final order (on bar, left to right):")
    for (n, r) in ActuationVerifier.barOrder(resolved).enumerated() { print("  \(n) \(r.confidence.marker) \(r.key)\(r.item.stale ? " (stale)" : "")") }
}

func snapshotOf(_ r: ActuationResult) -> MenuBarSnapshot? {
    switch r { case .verified(let s): return s; case .failed(_, let s): return s }
}

func runMove(_ a: [String]) async {
    var pos: [String] = []
    var relation: Relation?
    var config = LiveActuator.Config()
    var i = 0
    func val() -> String { i += 1; guard i < a.count else { usage() }; return a[i] }
    while i < a.count {
        switch a[i] {
        case "--before": relation = .before(parseKey(val()))
        case "--after": relation = .after(parseKey(val()))
        case "--leftmost": relation = .leftmost
        case "--rightmost": relation = .rightmost
        case "--force-fallback": config.forceFallback = true
        case "--no-fallback": config.allowFallback = false
        default: if a[i].hasPrefix("--") { usage() }; pos.append(a[i])
        }
        i += 1
    }
    guard pos.count == 1, let relation else { usage() }
    let key = parseKey(pos[0])
    let act = LiveActuator(platform: LivePlatform(), config: config,
                           log: { FileHandle.standardError.write(Data(("actuator: " + $0 + "\n").utf8)) })
    let t0 = Date()
    let r = await act.move(key, relation: relation)
    print("RESULT \(describe(r))")
    print(String(format: "ELAPSED_MS %.0f", Date().timeIntervalSince(t0) * 1000))
    printFinalOrder(snapshotOf(r))
    exit(r.isVerified ? 0 : 1)
}

func runHideShow(_ a: [String], hide: Bool) async {
    guard !a.isEmpty, a.allSatisfy({ !$0.hasPrefix("--") }) else { usage() }
    let keys = a.map(parseKey)
    let act = LiveActuator(platform: LivePlatform(),
                           log: { FileHandle.standardError.write(Data(("actuator: " + $0 + "\n").utf8)) })
    let t0 = Date()
    let out = await act.applyHiddenBatchDetailed(Dictionary(uniqueKeysWithValues: keys.map { ($0, hide) }))
    print("RESULT \(describe(out.result))")
    for (k, r) in out.perKey.sorted(by: { $0.key.description < $1.key.description }) { print("  \(k): \(describe(r))") }
    print(String(format: "ELAPSED_MS %.0f", Date().timeIntervalSince(t0) * 1000))
    printFinalOrder(snapshotOf(out.result))
    exit(out.result.isVerified ? 0 : 1)
}

/// Shared with the engine: two consecutive agreeing full scans (max 6 scans / 15 s).
func makeObserver(platform: LivePlatform = LivePlatform()) -> AgreedScanObserver { EngineFactory.makeObserver(platform: platform) }

func makeCapabilityRules(bundleIDs: BundleIDs? = nil) -> CapabilityRules { EngineFactory.makeCapabilityRules(bundleIDs: bundleIDs) }

func runPlan(_ a: [String]) async {
    var file = FileLayoutStore.defaultURL()
    var showHidden = false, json = false
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--show-hidden": showHidden = true
        case "--json": json = true
        case "--file": i += 1; guard i < a.count else { usage() }; file = URL(fileURLWithPath: a[i])
        default: usage()
        }
        i += 1
    }
    guard FileManager.default.fileExists(atPath: file.path) else {
        FileHandle.standardError.write(Data("no layout; run `mbprobe layout init-from-current`\n".utf8))
        exit(1)
    }
    let layout: Layout
    do { layout = try FileLayoutStore(url: file).load() } catch { fail("cannot load \(file.path): \(error)") }
    let res: [ResolvedItem]
    do { res = try await makeObserver().observe() } catch {
        if case ObserveError.permissionDenied = error { fail("\(error)") }
        fail("scans did not agree; not planning")
    }
    let observed = ObservedOrder(resolved: res)
    let rules = makeCapabilityRules()
    let plan = Reconciler().plan(observed: observed, layout: layout, capabilities: { rules.capability(for: $0) },
                                 showHiddenSection: showHidden)
    func act(_ x: PlannedAction) -> String {
        switch x {
        case .hide(let k): return "hide \(k)"
        case .show(let k): return "show \(k)"
        case .move(let k, let r):
            switch r {
            case .before(let t): return "move \(k) before \(t)"
            case .after(let t): return "move \(k) after \(t)"
            case .leftmost: return "move \(k) leftmost"
            case .rightmost: return "move \(k) rightmost"
            }
        }
    }
    if json {
        let obj: [String: Any] = [
            "phase": "\(plan.phase)", "actions": plan.actions.map(act),
            "newItems": plan.newItems.map { "\($0.key) -> \($0.section.rawValue)" },
            "absent": plan.absent.map(\.description),
            "skipped": plan.skipped.map { "\($0.key): \($0.reason)" },
            "desiredOnBar": plan.desiredOnBar.map(\.description),
        ]
        let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
        return
    }
    print("phase: \(plan.phase)  (observed \(observed.onBar.count) on bar, \(observed.parked.count) parked; showHidden=\(showHidden))")
    print("actions (\(plan.actions.count)):")
    for (n, x) in plan.actions.enumerated() { print("  \(n + 1). \(act(x))") }
    print("newItems (\(plan.newItems.count)):")
    for n in plan.newItems { print("  \(n.key) -> \(n.section.rawValue)") }
    print("absent: \(plan.absent.count)" + (plan.absent.isEmpty ? "" : " (first 5: " + plan.absent.prefix(5).map(\.description).joined(separator: ", ") + ")"))
    print("skipped (\(plan.skipped.count)):")
    for s in plan.skipped { print("  \(s.key): \(s.reason)") }
    print("desiredOnBar (\(plan.desiredOnBar.count)):")
    for (n, k) in plan.desiredOnBar.enumerated() { print("  \(n + 1). \(k)") }
}

@MainActor
func runApply(_ a: [String]) async {
    var file: URL?
    var showHidden = false, fake = false, allowFallback = false
    var maxActions = LayoutEngine.Config().maxActionsPerPass
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--show-hidden": showHidden = true
        case "--fake": fake = true
        case "--allow-fallback": allowFallback = true
        case "--file": i += 1; guard i < a.count else { usage() }; file = URL(fileURLWithPath: a[i])
        case "--max-actions": i += 1; guard i < a.count, let n = Int(a[i]), n > 0 else { usage() }; maxActions = n
        default: usage()
        }
        i += 1
    }
    guard let file else {
        FileHandle.standardError.write(Data("pass --file; refusing to use the real layout.json during development\n".utf8))
        exit(2)
    }
    let platform = LivePlatform()
    if !fake, let m = platform.conflictingManager() {
        FileHandle.standardError.write(Data("\(m); quit it first. Nothing was touched.\n".utf8))
        exit(1)
    }
    let ids = BundleIDs()
    let rules = makeCapabilityRules(bundleIDs: ids)
    let logger: @Sendable (String) -> Void = { print("engine: " + $0); fflush(stdout) }
    let observer: any MenuBarObserver
    let actuator: any MenuBarActuator
    let resolver: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    if fake {
        let res: [ResolvedItem]
        do { res = try await makeObserver(platform: platform).observe(); ids.record(res) } catch { fail("cannot observe: \(error)") }
        let o = ObservedOrder(resolved: res)
        observer = FixtureObserver([FakeMenuBar.resolved(onBar: o.onBar, parked: o.parked)])
        actuator = FakeActuator(order: o.onBar + o.parked, hidden: Set(o.parked), capabilities: rules,
                                makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        resolver = { FakeMenuBar.resolve($0) }
    } else {
        observer = RecordingObserver(inner: makeObserver(platform: platform), ids: ids)
        var lc = LiveActuator.Config()
        lc.allowFallback = allowFallback   // default drag-only: the order-store fallback needs an explicit opt-in
        actuator = LiveActuator(platform: platform, config: lc, log: { FileHandle.standardError.write(Data(("actuator: " + $0 + "\n").utf8)) })
        resolver = { platform.resolve($0) }
    }
    let state = EngineState(showHiddenSection: showHidden)
    var cfg = LayoutEngine.Config()
    cfg.maxActionsPerPass = maxActions
    let engine = LayoutEngine(observer: observer, actuator: actuator, store: FileLayoutStore(url: file), capabilities: rules,
                              state: state, busy: { platform.pressedMouseButtons() != 0 }, resolveSnapshot: resolver,
                              log: logger, showHiddenSection: showHidden, config: cfg)
    await engine.start()
    if let e = state.lastError { fail("\(e)") }
    let t0 = Date()
    let report = await engine.reconcileOnce()
    let view = Reconciler().plan(observed: state.observed, layout: state.layout, capabilities: { rules.capability(for: $0) },
                                 showHiddenSection: showHidden)
    var shown = Set<ItemKey>()
    for k in view.desiredOnBar + state.observed.onBar + state.observed.parked where shown.insert(k).inserted {
        switch state.perItem[k] ?? .inPlace {
        case .inPlace: print("= \(k)")
        case .pending: print("~ \(k)")
        case .moving: print("> \(k)")
        case .failed(let e): print("x \(k) failed(\(e))")
        case .unsupported(let r): print("! \(k) unsupported(\(r))")
        }
    }
    if let e = state.lastError { print("error: \(e)") }
    print(String(format: "ELAPSED_MS %.0f", Date().timeIntervalSince(t0) * 1000))
    print("phase: \(report.phase.map { "\($0)" } ?? "-")  outcome: \(report.outcome)  actions: \(report.actionCount)")
    let ok = report.outcome == .converged
    print(ok ? "converged" : "not converged")
    exit(ok ? 0 : 1)
}

func runLayout(_ a: [String]) async {
    var a = a
    var file: URL = FileLayoutStore.defaultURL()
    var force = false, json = false
    var pos: [String] = []
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--file": i += 1; guard i < a.count else { usage() }; file = URL(fileURLWithPath: a[i])
        case "--force": force = true
        case "--json": json = true
        default: pos.append(a[i])
        }
        i += 1
    }
    a = pos
    guard let sub = a.first else { usage() }
    let store = FileLayoutStore(url: file)
    func load() -> Layout {
        do {
            let (l, w) = try store.loadWithWarnings()
            for m in w { FileHandle.standardError.write(Data(("warning: " + m + "\n").utf8)) }
            return l
        } catch { fail("cannot load \(file.path): \(error)") }
    }
    func printLayout(_ l: Layout, only: LayoutSection? = nil) {
        for s in LayoutSection.allCases where only == nil || only == s {
            print("\(s.rawValue) (\(l.keys(in: s).count)):")
            for (n, k) in l.keys(in: s).enumerated() { print("  \(n + 1). \(k)") }
        }
        if only == nil { print("newItemPolicy: \(l.newItemPolicy.rawValue)") }
    }
    func parseKey(_ s: String) -> ItemKey {
        guard let k = ItemKey(storeKey: s) else {
            fail("not a full item key: \(s) (expected status:<owner>::<name>, module:<name> or heuristic:...)")
        }
        return k
    }
    switch sub {
    case "show":
        let l = load()
        if json {
            if FileManager.default.fileExists(atPath: file.path), let d = try? Data(contentsOf: file) {
                print(String(decoding: d, as: UTF8.self))
            } else {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try! enc.encode(l), as: UTF8.self))
            }
        } else { printLayout(l) }
    case "init-from-current":
        if !force, FileManager.default.fileExists(atPath: file.path), !load().allKeys.isEmpty {
            fail("\(file.path) already has a non-empty layout; use --force to overwrite")
        }
        let res: [ResolvedItem]
        let scans: Int
        do { (res, scans) = try await makeObserver().observeCounting() } catch ObserveError.noAgreement(let n) {
            fail("scans did not agree after \(n) attempts; not writing")
        } catch { fail("\(error); not writing") }
        let stale = res.filter { $0.item.stale }.map { $0.key.description }
        if !stale.isEmpty { fail("stale items, not writing: " + stale.joined(separator: ", ")) }
        let (l, excluded) = LayoutBuilder.build(from: res)
        guard !l.visible.isEmpty else { fail("scan returned no items; not writing") }
        for e in excluded { FileHandle.standardError.write(Data(("ignored non-item: " + e + "\n").utf8)) }
        do { try store.save(l) } catch { fail("save failed: \(error)") }
        printLayout(l)
        print("wrote \(l.allKeys.count) keys (\(l.visible.count) visible, \(l.hidden.count) hidden, \(l.alwaysHidden.count) always-hidden); excluded \(excluded.count) non-items; scans \(scans)")
    case "move":
        guard a.count == 3 || a.count == 4 else { usage() }
        let key = parseKey(a[1])
        let section: LayoutSection
        switch a[2] {
        case "visible": section = .visible
        case "hidden": section = .hidden
        case "always", "alwaysHidden": section = .alwaysHidden
        default: usage()
        }
        var idx: Int? = nil
        if a.count == 4 { guard let n = Int(a[3]) else { usage() }; idx = n - 1 }
        var l = load()
        l.move(key, to: section, index: idx)
        do { try store.save(l) } catch { fail("save failed: \(error)") }
        printLayout(l, only: section)
    case "remove":
        guard a.count == 2 else { usage() }
        let key = parseKey(a[1])
        var l = load()
        guard let s = l.remove(key) else { fail("\(key) is not in the layout") }
        do { try store.save(l) } catch { fail("save failed: \(error)") }
        print("removed \(key) from \(s.rawValue)")
    default: usage()
    }
}

func runPermissions(_ a: [String]) {
    let checker = LivePermissionChecker()
    let prompt = a.contains("--prompt")
    let ax = checker.accessibility(prompt: prompt)
    print("accessibility: \(ax)")
    print("screenRecording: \(checker.screenRecording())")
}

switch args.first {
case "permissions": runPermissions(Array(args.dropFirst()))
case "layout": await runLayout(Array(args.dropFirst()))
case "apply": await runApply(Array(args.dropFirst()))
case "plan": await runPlan(Array(args.dropFirst()))
case "move": await runMove(Array(args.dropFirst()))
case "hide": await runHideShow(Array(args.dropFirst()), hide: true)
case "show": await runHideShow(Array(args.dropFirst()), hide: false)
case "drag": runDrag(Array(args.dropFirst()))
case "set-visible": runSetVisible(Array(args.dropFirst()))
case "cc-allowed": runCCAllowed(Array(args.dropFirst()))
case "press": runPress(Array(args.dropFirst()))
case "set-position": runSetPosition(Array(args.dropFirst()))
case "watch": runWatch(Array(args.dropFirst()))
case "agent-restart": runAgentRestart()
case "keys": runKeys(Array(args.dropFirst()))
case "list": runList(Array(args.dropFirst()))
default: usage()
}
