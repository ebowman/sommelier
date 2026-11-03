// usage: cmddrag <fromX> <y> <toX>   (global top-left-origin screen coords)
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count == 4, let fx = Double(a[1]), let y = Double(a[2]), let tx = Double(a[3]) else { print("usage: cmddrag fromX y toX"); exit(2) }
let saved = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ x: Double) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
}
CGWarpMouseCursorPosition(CGPoint(x: fx, y: y)); usleep(100_000)
post(.mouseMoved, fx); usleep(100_000)
post(.leftMouseDown, fx); usleep(150_000)
let n = 10
for i in 1...n { post(.leftMouseDragged, fx + (tx - fx) * Double(i) / Double(n)); usleep(15_000) }
usleep(150_000)
post(.leftMouseUp, tx); usleep(200_000)
CGWarpMouseCursorPosition(saved)
print("dragged \(fx)->\(tx) at y=\(y)")
