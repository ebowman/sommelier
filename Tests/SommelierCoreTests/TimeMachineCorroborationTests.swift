import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// 9o9.29. Numbers from the live `mbprobe list --json --debug` capture of 2026-11-07 21:03 (build 326): the agent tree holds only
// Wi-Fi + Focus (in the pile at 794), the chevron (799 w17.5), Control Center and Clock; SystemUIServer's Time Machine
// (827, 3.5, 22x22, no identifier/description/title) has NO hosted element, so no frame join can ever corroborate it. The owner's
// fresh frame, uncontested by any hosted element or other owner item, is the evidence (`.ownerFrame`).

private let tmAgent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")

private func tmFixture(tmX: CGFloat = 827, bundle: String = "com.apple.systemuiserver", extraHosted: [AXElementInfo] = [],
                       other: (pid_t, CGRect)? = nil) -> FixtureSource {
    let sui = RunningAppInfo(pid: 825, bundleID: bundle, name: "SystemUIServer")
    var s = FixtureSource(apps: [tmAgent, sui])
    s.extras[825] = [AXElementInfo(frame: CGRect(x: tmX, y: 3.5, width: 22, height: 22))]
    if let (pid, f) = other {
        s.apps.append(RunningAppInfo(pid: pid, bundleID: "x.other", name: "Other"))
        s.extras[pid] = [AXElementInfo(frame: f)]
    }
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "Wi-Fi", identifier: "com.apple.menuextra.wifi", frame: CGRect(x: 794, y: 3.5, width: 22, height: 22)),
        AXElementInfo(axDescription: "Focus", identifier: "com.apple.menuextra.focusmode", frame: CGRect(x: 794, y: 3.5, width: 22, height: 22)),
        AXElementInfo(axDescription: "Show Hidden Menu Bar Items", frame: CGRect(x: 799, y: 1, width: 17.5, height: 26)),
        AXElementInfo(axDescription: "Control Center", identifier: "com.apple.menuextra.controlcenter", frame: CGRect(x: 1272, y: 3.5, width: 26, height: 22)),
        AXElementInfo(axDescription: "Clock", identifier: "com.apple.menuextra.clock", frame: CGRect(x: 1314, y: 3.5, width: 18, height: 22)),
    ] + extraHosted)
    return s
}

private func tm(_ s: FixtureSource) -> MenuBarItem? {
    MenuBarScanner(source: s).scan().items.first { $0.ownerBundleID?.hasSuffix("systemuiserver") == true }
}

@Test func timeMachineWithNoHostedElementIsCorroboratedByTheOwnerFrame() {
    let i = tm(tmFixture())
    #expect(i?.joinEvidence == .ownerFrame)
    #expect(i?.joinEvidence.corroborated == true)
    #expect(i?.isOnMenuBar == true)
}

@Test func timeMachineStaysUncorroboratedWhenAHostedElementContestsItsFrame() {
    // Two unknown hosted elements straddle the item: the frame join is ambiguous and the owner-frame rule must not take over.
    let contested = tmFixture(extraHosted: [AXElementInfo(axDescription: "A", frame: CGRect(x: 816, y: 3.5, width: 22, height: 22)),
                                            AXElementInfo(axDescription: "B", frame: CGRect(x: 838, y: 3.5, width: 22, height: 22))])
    #expect(tm(contested)?.joinEvidence.corroborated != true)
    // One lone hosted element that exactly overlaps it is the ordinary frame join, never the owner-frame rule.
    let lone = tmFixture(extraHosted: [AXElementInfo(axDescription: "Mystery", frame: CGRect(x: 830, y: 3.5, width: 22, height: 22))])
    #expect(tm(lone)?.joinEvidence != .ownerFrame)
}

@Test func timeMachineWithinTheChevronsReachStaysUncorroborated() {
    // The chevron spans 799..816.5; its reach is +-2 pt (to 818.5). A frame that starts at 817 or 818 sits in it.
    #expect(tm(tmFixture(tmX: 817))?.joinEvidence.corroborated != true)
    #expect(tm(tmFixture(tmX: 818))?.joinEvidence.corroborated != true)
    #expect(tm(tmFixture(tmX: 819))?.joinEvidence == .ownerFrame)
}

@Test func timeMachineStaysUncorroboratedWhenAnotherOwnerItemOverlapsIt() {
    let s = tmFixture(other: (60, CGRect(x: 835, y: 2.5, width: 24, height: 24)))
    #expect(tm(s)?.joinEvidence.corroborated != true)
}

@Test func onlySystemUIServerIsCorroboratedByItsOwnerFrameAlone() {
    // gdu.94: any other owner with no hosted element keeps the bare app-side frame (it may be stale or hidden in Control Center).
    let s = tmFixture(bundle: "x.some.app")
    let i = MenuBarScanner(source: s).scan().items.first { $0.ownerBundleID == "x.some.app" }
    #expect(i?.joinEvidence == JoinEvidence.none)
}

@Test func timeMachineIsNotOwnerFrameOnAFastScanAfterAMove() {
    var s = tmFixture(tmX: 827)
    var scanner = MenuBarScanner(source: s)
    #expect(scanner.scan().items.first { $0.ownerBundleID?.hasSuffix("systemuiserver") == true }?.joinEvidence == .ownerFrame)
    s.extras[825] = [AXElementInfo(frame: CGRect(x: 900, y: 3.5, width: 22, height: 22))]
    scanner.source = s
    let fast = scanner.scanVisible().items.first { $0.ownerBundleID?.hasSuffix("systemuiserver") == true }
    #expect(fast?.joinEvidence != .ownerFrame)
}
