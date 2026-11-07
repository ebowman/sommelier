import Testing
import CoreGraphics
@testable import SommelierCore

private func st(_ owner: String, _ auto: String = "Item-0") -> ItemKey { .status(ownerKey: owner, autosaveName: auto) }
private func info(_ k: ItemKey, desc: String = "", title: String = "", owner: String) -> ItemInfo {
    ItemInfo(key: k, title: title, axDescription: desc, ownerPID: 1, ownerBundleID: nil, ownerName: owner, width: 30, isOnBar: true)
}

@Suite struct RowNameRuleTests {
    @Test func symbolLabelsAndLiveValuesAreNotLabels() {
        for s in ["Shield Lefthalf Filled With A Check…", "Shield Lefthalf Filled With A Checkmark", "65%", "7. November 2026",
                  "menubar image", "AppleScript scroll document, filled", "Eric's AirPods Pro #2", "Micro Snitch, no microphone or came…",
                  "GateOpener — click to open the gate", "", "  "] {
            #expect(RowNameRule.isSymbolOrLiveLabel(s), "\(s)")
        }
        for s in ["iStat Menus Network", "iStat Menus Sensors", "iStat Menus CPU", "Dropbox", "Work VPN"] {
            #expect(!RowNameRule.isSymbolOrLiveLabel(s), "\(s)")
        }
    }

    @Test func singleItemOwnerWithSymbolLabelShowsAppName() {
        let k = st("ie.boboco.vpnswitch")
        let items = [k: info(k, desc: "Shield Lefthalf Filled With A Check…", owner: "VPN Switch")]
        let n = RowNameRule.Namer(keys: [k], items: items)
        #expect(n.name(k) == "VPN Switch")
        #expect(n.detail(k) == "Shield Lefthalf Filled With A Check…")   // raw description kept for the tooltip
        let l = Layout(visible: [k])
        #expect(ArrangeSections.make(observed: ObservedOrder(onBar: [k], parked: []), layout: l, items: items, perItem: [:], capabilities: { _ in .init(canMove: true, canHide: true) })
            .visible.rows.first?.title == "VPN Switch")
    }

    @Test func multiItemOwnerKeepsPerItemDescriptions() {
        let ks = ["Network", "Sensors", "CPU"].map { st("com.bjango.istatmenus", $0) }
        var items: [ItemKey: ItemInfo] = [:]
        for (k, d) in zip(ks, ["iStat Menus Network", "iStat Menus Sensors", "iStat Menus CPU"]) { items[k] = info(k, desc: d, owner: "iStat Menus") }
        let n = RowNameRule.Namer(keys: ks, items: items)
        #expect(ks.map(n.name) == ["iStat Menus Network", "iStat Menus Sensors", "iStat Menus CPU"])
    }

    @Test func multiItemOwnerWithSymbolOrSharedDescriptionsIsNumbered() {
        let ks = [st("net.toothfairy", "a"), st("net.toothfairy", "b")]
        var items: [ItemKey: ItemInfo] = [:]
        items[ks[0]] = info(ks[0], desc: "Eric's AirPods Pro #2", owner: "ToothFairy")
        items[ks[1]] = info(ks[1], desc: "menubar image", owner: "ToothFairy")
        let n = RowNameRule.Namer(keys: ks, items: items)
        #expect(ks.map(n.name) == ["ToothFairy (1)", "ToothFairy (2)"])
        // identical real labels are not distinguishing: numbered too
        for k in ks { items[k]?.axDescription = "Same Label" }
        let m = RowNameRule.Namer(keys: ks, items: items)
        #expect(ks.map(m.name) == ["ToothFairy (1)", "ToothFairy (2)"])
        // observed-only siblings count towards "several items"
        let solo = RowNameRule.Namer(keys: [ks[0]], items: items)
        #expect(solo.name(ks[0]) == "ToothFairy (1)")
    }

    @Test func emptyEverythingShowsAppName_andEmptyAppNameFallsBackToDescription() {
        let k = st("x.y")
        #expect(RowNameRule.Namer(keys: [k], items: [k: info(k, owner: "Thing")]).name(k) == "Thing")
        #expect(RowNameRule.Namer(keys: [k], items: [k: info(k, desc: "Some Tooltip Text", owner: "")]).name(k) == "Some Tooltip Text")
        #expect(RowNameRule.Namer(keys: [k], items: [k: info(k, title: "T", owner: "")]).name(k) == "T")
    }

    @Test func moduleNamesAreHuman() {
        func n(_ m: String) -> String { RowNameRule.moduleName(m) }
        #expect(n("Clock") == "Clock")
        #expect(n("com.apple.menuextra.clock") == "Clock")
        #expect(n("ControlCenter") == "Control Center")
        #expect(n("com.apple.menuextra.focusmode") == "Focus")
        #expect(n("WiFi") == "Wi-Fi")
        #expect(n("com.apple.menuextra.TimeMachine") == "Time Machine")
        #expect(n("com.apple.menuextra.Battery") == "Battery")
        #expect(n("com.apple.menuextra.SomeNewThing") == "Some New Thing")
        let k = ItemKey.module(name: "com.apple.menuextra.TimeMachine")
        let items = [k: info(k, owner: "SystemUIServer")]
        #expect(RowNameRule.Namer(keys: [k], items: items).name(k) == "Time Machine")
        #expect(RowNameRule.Namer(keys: [k], items: [:]).name(k) == "Time Machine")
    }

    @Test func filterMatchesRawDescription() {
        let k = st("ie.boboco.vpnswitch")
        let items = [k: info(k, desc: "Shield Lefthalf Filled With A Check…", owner: "VPN Switch")]
        func rows(_ f: String) -> Int {
            ArrangeSections.make(observed: ObservedOrder(onBar: [k], parked: []), layout: Layout(visible: [k]), items: items, perItem: [:],
                                 capabilities: { _ in .init(canMove: true, canHide: true) }, filter: f).visible.rows.count
        }
        #expect(rows("lefthalf") == 1)
        #expect(rows("vpn") == 1)
        #expect(rows("nomatch") == 0)
    }

    @Test func leftoverHeuristicKeyNeverInflatesTheCountOrNumbers() {
        // one status key + a leftover heuristic key: the app name, never "(1)"
        let s = st("com.example.app"), h = ItemKey.heuristic(bundleID: "com.example.app", fingerprint: "", ordinal: 0)
        let items = [s: info(s, owner: "Example"), h: info(h, owner: "Example")]
        let n = RowNameRule.Namer(keys: [s, h], items: items)
        #expect(n.name(s) == "Example")
        #expect(n.name(h) == "Example")
        // two status items + two heuristic keys: only the status items are numbered
        let t0 = st("com.robinlu.mac.Tooth-Fairy", "Item-0"), t1 = st("com.robinlu.mac.Tooth-Fairy", "Item-1")
        let h0 = ItemKey.heuristic(bundleID: "com.robinlu.mac.Tooth-Fairy", fingerprint: "", ordinal: 0)
        let h1 = ItemKey.heuristic(bundleID: "com.robinlu.mac.Tooth-Fairy", fingerprint: "Eric’s AirPods Pro #2", ordinal: 0)
        var ti: [ItemKey: ItemInfo] = [:]
        for k in [t0, t1, h0, h1] { ti[k] = info(k, owner: "ToothFairy") }
        let m = RowNameRule.Namer(keys: [t0, t1, h0, h1], items: ti)
        #expect([t0, t1].map(m.name) == ["ToothFairy (1)", "ToothFairy (2)"])
        #expect([h0, h1].map(m.name) == ["ToothFairy", "ToothFairy"])
        // an owner with ONLY heuristic keys still counts them
        var oi: [ItemKey: ItemInfo] = [:]
        for k in [h0, h1] { oi[k] = info(k, owner: "ToothFairy") }
        let o = RowNameRule.Namer(keys: [h0, h1], items: oi)
        #expect([h0, h1].map(o.name) == ["ToothFairy (1)", "ToothFairy (2)"])
    }

    @Test func statusKeyTimeMachineIsNamedLikeAModule() {
        let tm = st("com.apple.systemuiserver", "com.apple.menuextra.TimeMachine")
        let wf = st("com.apple.MenuBarAgent", "com.apple.menuextra.WiFi")
        let items = [tm: info(tm, desc: "Time Machine", owner: "SystemUIServer"), wf: info(wf, desc: "Wi-Fi, 3 bars", owner: "MenuBarAgent")]
        let n = RowNameRule.Namer(keys: [tm, wf], items: items)
        #expect(n.name(tm) == "Time Machine")
        #expect(n.name(wf) == "Wi-Fi")
    }

    @Test func appleAgentMatchIsExactSoCorsairControlCenterIsNotAnAppleModule() {
        let k = st("com.corsair.ControlCenter", "com.apple.menuextra.Fans")
        let n = RowNameRule.Namer(keys: [k], items: [k: info(k, owner: "ControlCenter")])
        #expect(n.name(k) == "ControlCenter")
        #expect(RowNameRule.appleModuleName(k) == nil)
        let real = st("COM.APPLE.controlcenter", "com.apple.menuextra.Fans")
        #expect(RowNameRule.appleModuleName(real) == "Fans")
    }

    @Test func blankHeuristicNamesFallBackToAppThenOwnerComponent() {
        let blank = ItemKey.heuristic(bundleID: "signal", fingerprint: " \n ##%", ordinal: 0)
        let empty = ItemKey.heuristic(bundleID: "signal", fingerprint: "   ", ordinal: 1)
        let withApp = RowNameRule.Namer(keys: [blank], items: [blank: info(blank, owner: "WiFi Signal")])
        #expect(withApp.name(blank) == "WiFi Signal")
        let noApp = RowNameRule.Namer(keys: [blank, empty], items: [blank: info(blank, owner: ""), empty: info(empty, owner: "")])
        #expect(noApp.name(blank) == "signal (1)" || noApp.name(blank) == "signal")
        #expect(!noApp.name(empty).trimmingCharacters(in: .whitespaces).isEmpty)
        let solo = RowNameRule.Namer(keys: [empty], items: [:])
        #expect(solo.name(empty) == "signal")
        // an orphan Apple-agent heuristic row
        let sui = ItemKey.heuristic(bundleID: "com.apple.systemuiserver", fingerprint: "", ordinal: 0)
        #expect(RowNameRule.Namer(keys: [sui], items: [:]).name(sui) == "SystemUIServer item")
        #expect(RowNameRule.Namer(keys: [sui], items: [sui: info(sui, owner: "")]).name(sui) == "SystemUIServer item")
    }

    /// Real key shapes lifted from the user's layout.json (2026-11-07); (store key, observed app name, expected row name).
    @Test func userLikeLayoutNamesEveryRow() throws {
        let istat = ["astronomy", "battery", "cpu", "disks", "memory", "network", "sensors", "time", "weather"]
        let istatNames = ["iStat Menus Astronomy", "iStat Menus Battery", "iStat Menus CPU", "iStat Menus Disks", "iStat Menus Memory",
                          "iStat Menus Network", "iStat Menus Sensors", "iStat Menus Time", "iStat Menus Weather"]
        var rows: [(String, String, String, String)] = [   // key, owner app name, AX description, expected
            ("status:ie.boboco.vpnswitch::Item-0", "VPN Switch", "Shield Lefthalf Filled With A Check…", "VPN Switch"),
            ("status:GateOpener::Item-0", "GateOpener", "GateOpener — click to open the gate", "GateOpener"),
            ("status:signal::Item-0", "WiFi Signal", "65%", "WiFi Signal"),
            ("heuristic:signal:: \n ##%#0", "WiFi Signal", "", "WiFi Signal"),
            ("status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine", "SystemUIServer", "Time Machine", "Time Machine"),
            ("heuristic:com.apple.systemuiserver::#0", "SystemUIServer", "", "SystemUIServer"),
            ("heuristic:com.apple.MenuBarAgent:: \n ##%#0", "MenuBarAgent", "", "MenuBarAgent"),
            ("module:WiFi", "", "", "Wi-Fi"),
            ("module:com.apple.menuextra.focusmode", "", "", "Focus"),
            ("module:com.apple.menuextra.controlcenter", "", "", "Control Center"),
            ("module:Clock", "", "", "Clock"),
            ("status:85C27NK92C.com.flexibits.fantastical2.mac.helper::Fantastical", "Fantastical Helper", "5. November 2026", "Fantastical Helper"),
            ("heuristic:85C27NK92C.com.flexibits.fantastical2.mac.helper::5. November 2026#0", "Fantastical Helper", "", "Fantastical Helper"),
            ("status:com.airmail2hookmark.app::Item-0", "Hookmark", "menubar image", "Hookmark"),
            ("status:com.apple.ScriptMenuApp::com.apple.scriptmenu", "Script Menu", "AppleScript scroll document, filled", "Script Menu"),
            ("status:at.obdev.MicroSnitch::Item-0", "Micro Snitch", "Micro Snitch, no microphone or camera is active", "Micro Snitch"),
            ("heuristic:at.obdev.MicroSnitch::Micro Snitch, no microphone or camera is active#0", "Micro Snitch", "", "Micro Snitch"),
            ("status:com.robinlu.mac.Tooth-Fairy::Item-0", "ToothFairy", "menubar image", "ToothFairy (1)"),
            ("status:com.robinlu.mac.Tooth-Fairy::Item-1", "ToothFairy", "Eric’s AirPods Pro #2", "ToothFairy (2)"),
            ("heuristic:com.robinlu.mac.Tooth-Fairy::#0", "ToothFairy", "", "ToothFairy"),
            ("heuristic:com.robinlu.mac.Tooth-Fairy::Eric’s AirPods Pro #2#0", "ToothFairy", "", "ToothFairy"),
            ("status:info.marcel-dierkes.KeepingYouAwake::Item-0", "KeepingYouAwake", "", "KeepingYouAwake"),
            ("heuristic:info.marcel-dierkes.KeepingYouAwake::#0", "KeepingYouAwake", "", "KeepingYouAwake"),
            ("status:com.iconfactory.Tot::Item-0", "Tot", "", "Tot"),
            ("heuristic:com.iconfactory.Tot::#0", "Tot", "", "Tot"),
            ("status:at.EternalStorms.Yoink::Item-0", "Yoink", "", "Yoink"),
            ("heuristic:at.EternalStorms.Yoink::#0", "Yoink", "", "Yoink"),
            ("status:com.valerijs.boguckis.store.TextSniper::Item-0", "TextSniper", "", "TextSniper"),
            ("heuristic:com.valerijs.boguckis.store.TextSniper::#0", "TextSniper", "", "TextSniper"),
            ("status:com.p5sys.jump.connect::Item-0", "Jump Desktop Connect", "", "Jump Desktop Connect"),
            ("status:com.king.cto.mcpmaestro::Item-0", "MCP Maestro", "", "MCP Maestro"),
            ("status:ie.boboco.FloTile::Item-0", "FlöTile", "", "FlöTile"),
            ("heuristic:ie.boboco.FloTile::FlöTile#0", "FlöTile", "", "FlöTile"),
            ("status:com.corsair.ControlCenter::Item-0", "ControlCenter", "", "ControlCenter"),
            ("status:co.podzim.boltai-mobile::Item-0", "BoltAI", "", "BoltAI"),
            ("heuristic:co.podzim.boltai-mobile::BoltAI#0", "BoltAI", "", "BoltAI"),
            ("heuristic:com.bjango.istatmenus.status::com.bjango.istatmenus.combined#0", "iStat Menus", "", "iStat Menus"),
        ]
        for (a, d) in zip(istat, istatNames) {
            rows.append(("status:com.bjango.istatmenus.status::com.bjango.istatmenus.\(a)", "iStat Menus", d, d))
        }
        var keys: [ItemKey] = [], items: [ItemKey: ItemInfo] = [:]
        for r in rows {
            let k = try #require(ItemKey(storeKey: r.0), "\(r.0)")
            keys.append(k)
            items[k] = info(k, desc: r.2, owner: r.1)
        }
        let n = RowNameRule.Namer(keys: keys, items: items)
        for (k, r) in zip(keys, rows) { #expect(n.name(k) == r.3, "\(r.0)") }
    }
}
