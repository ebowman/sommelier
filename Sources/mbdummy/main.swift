// mbdummy: creates N NSStatusItems for menu bar experiments.
// Usage: mbdummy [--count N] [--removal-allowed]
// NOTE: MenuBarAgent keys items as status:<bundleID>::<autosaveName>; a bare
// executable is keyed by process name. Run as build/MBDummy.app (make dummy)
// so the bundle id is ie.boboco.mbdummy.
import AppKit

var count = 2
var removalAllowed = false
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--count":
        guard let v = argv.first, let n = Int(v), n > 0 else {
            FileHandle.standardError.write(Data("mbdummy: --count needs a positive integer\n".utf8)); exit(2)
        }
        argv.removeFirst(); count = n
    case "--removal-allowed": removalAllowed = true
    default:
        FileHandle.standardError.write(Data("mbdummy: unknown argument \(a)\n".utf8)); exit(2)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var items: [NSStatusItem] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        for i in 0..<count {
            let letter = i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : "\(i)"
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if removalAllowed { item.behavior = [.removalAllowed] }
            item.autosaveName = "Dummy-\(letter)"
            item.button?.title = "D\(letter)"
            items.append(item)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
