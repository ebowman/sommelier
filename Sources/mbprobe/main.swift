import Foundation
import SommelierCore

// Hand-rolled argument parsing.
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: mbprobe list [--json] [--include-self] [--timing] [--debug]\n".utf8))
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

switch args.first {
case "list": runList(Array(args.dropFirst()))
default: usage()
}
