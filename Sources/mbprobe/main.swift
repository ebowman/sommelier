import Foundation
import SommelierCore

// Hand-rolled argument parsing.
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mbprobe list [--json] [--include-self] [--timing] [--debug]
           mbprobe set-position <bundleID> <autosaveName> <number> [--host] [--store legacy|agent]
           mbprobe watch [--seconds N]
           mbprobe agent-restart

    """.utf8))
    exit(2)
}

func clip(_ s: String, _ n: Int) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ")
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

func row(_ idx: Int, _ i: MenuBarItem) -> String {
    let label = [i.title, i.axDescription, i.axIdentifier].map { clip($0, 36) }.joined(separator: " | ")
    let pad = { (s: String, n: Int) in s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    return "\(pad(String(idx), 3)) x=\(pad(String(Int(i.frame.minX)), 6)) w=\(pad(String(Int(i.frame.width)), 4)) "
        + "\(pad(clip(i.ownerName, 28), 28)) \(pad(i.ownerBundleID ?? "-", 40)) \(label)  [\(i.source.rawValue)]"
}

func runList(_ flags: [String]) {
    let known: Set<String> = ["--json", "--include-self", "--timing", "--debug"]
    guard flags.allSatisfy(known.contains) else { usage() }
    let start = Date()
    let debug = flags.contains("--debug")
    let logger: @Sendable (String) -> Void = { msg in
        if debug { FileHandle.standardError.write(Data(("debug: " + msg + "\n").utf8)) }
    }
    let snap = MenuBarScanner(includeSelf: flags.contains("--include-self"), log: logger).scan()
    let elapsed = Date().timeIntervalSince(start)
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
        let msg = String(format: "scan time: %.0f ms\n", elapsed * 1000)
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
    s.onBarLeftToRight.map { "\($0.ownerBundleID ?? $0.ownerName)|\([$0.axIdentifier, $0.axDescription, $0.title].first { !$0.isEmpty } ?? "")" }
}

func runWatch(_ a: [String]) {
    var seconds: Double = 60
    if !a.isEmpty {
        guard a.count == 2, a[0] == "--seconds", let n = Double(a[1]), n > 0 else { usage() }
        seconds = n
    }
    let start = Date()
    var last: [String]? = nil
    while true {
        let snap = MenuBarScanner().scan()
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

switch args.first {
case "set-position": runSetPosition(Array(args.dropFirst()))
case "watch": runWatch(Array(args.dropFirst()))
case "agent-restart": runAgentRestart()
case "list": runList(Array(args.dropFirst()))
default: usage()
}
