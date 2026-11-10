import CoreGraphics
import Testing
@testable import SommelierCore

@Suite struct DropSelfTests {
    private func item(bundle: String?, name: String = "X", ident: String = "") -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: bundle, ownerName: name, title: "", axDescription: "", axIdentifier: ident,
                    frame: CGRect(x: 0, y: 0, width: 20, height: 20), source: .appExtras, isOnMenuBar: true)
    }
    private func resolved(_ key: ItemKey, bundle: String? = nil, name: String = "X", ident: String = "") -> ResolvedItem {
        ResolvedItem(item: item(bundle: bundle, name: name, ident: ident), key: key, confidence: .exact)
    }
    private func drop(_ items: [ResolvedItem]) -> [ResolvedItem] {
        EngineFactory.dropSelf(items, bundleID: "ie.boboco.sommelier", moduleName: "Sommelier")
    }

    @Test func selfLookAlikesAreDroppedByModuleNameBundleIDAndOwnerKey() {
        let byModule = resolved(.module(name: "Sommelier"))
        let byBundle = resolved(.status(ownerKey: "com.other", autosaveName: "a"), bundle: "ie.boboco.sommelier")
        let byOwnerKey = resolved(.status(ownerKey: "ie.boboco.sommelier", autosaveName: "b"))
        #expect(drop([byModule, byBundle, byOwnerKey]).isEmpty)
    }

    /// gdu.147: the hosted own item (by identifier, by the legacy module key or by its stable key) is KEPT.
    @Test func theOwnHostedItemIsKept() {
        let byIdent = resolved(.module(name: "ie.boboco.sommelier.statusitem"), ident: "ie.boboco.sommelier.statusitem")
        let byKey = resolved(.sommelierStatusItem)
        let byIdentAndKey = resolved(.sommelierStatusItem, bundle: "com.apple.MenuBarAgent", ident: "ie.boboco.sommelier.statusitem")
        for x in [byIdent, byKey, byIdentAndKey] { #expect(drop([x]).count == 1) }
        #expect(drop([byIdent, byKey, byIdentAndKey]).count == 1)   // duplicates collapse to one
    }

    @Test func duplicateOwnEntriesCollapseToExactlyOne() {
        let a = resolved(.sommelierStatusItem, ident: "ie.boboco.sommelier.statusitem")
        let b = resolved(.sommelierStatusItem, bundle: "com.apple.MenuBarAgent", ident: "ie.boboco.sommelier.statusitem")
        let other = resolved(.module(name: "WiFi"))
        let out = drop([a, other, b])
        #expect(out.map(\.key) == [.sommelierStatusItem, .module(name: "WiFi")])
    }

    @Test func lookAlikesAreKept() {
        let named = resolved(.status(ownerKey: "com.x.SommelierHelper", autosaveName: "a"), bundle: "com.x.SommelierHelper", name: "Sommelier Notes")
        let moduleX = resolved(.module(name: "SommelierX"))
        let lower = resolved(.module(name: "sommelier"))
        let prefixBundle = resolved(.status(ownerKey: "ie.boboco.sommelier2", autosaveName: "c"), bundle: "ie.boboco.sommelier2")
        let kept = drop([named, moduleX, lower, prefixBundle])
        #expect(kept.map(\.key) == [named, moduleX, lower, prefixBundle].map(\.key))
    }

    @Test func mixedInputKeepsOrderOfSurvivors() {
        let a = resolved(.status(ownerKey: "com.a", autosaveName: "a"), bundle: "com.a")
        let own = resolved(.module(name: "Sommelier"))
        let b = resolved(.module(name: "WiFi"))
        #expect(drop([a, own, b]).map(\.key) == [a.key, b.key])
    }

    @Test func emptyInputGivesEmptyOutput() { #expect(drop([]).isEmpty) }
}
