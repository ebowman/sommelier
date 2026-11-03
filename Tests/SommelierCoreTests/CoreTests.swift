import Testing
@testable import SommelierCore

@Test func bundleID() {
    #expect(SommelierCore.bundleID == "ie.boboco.sommelier")
}

import Foundation

@Test func orderStoreKeyFormat() {
    #expect(MenuBarOrderStore.key(bundleID: "ie.boboco.mbdummy", autosaveName: "Dummy-A") == "status:ie.boboco.mbdummy::Dummy-A")
    #expect(PreferenceWriter.legacyKey(autosaveName: "Dummy-A") == "NSStatusItem Preferred Position Dummy-A")
}

@Test func orderStoreRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("os-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("t.plist")
    let initial: [String: Any] = ["TrailingItemPreferredPositions": ["module:Clock": 0, "status:a.b::X": 10.5, "status:a.b::Y": 20]]
    try PropertyListSerialization.data(fromPropertyList: initial, format: .binary, options: 0).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let original = try Data(contentsOf: url)

    var store = MenuBarOrderStore(url: url)
    try store.setPositions(["status:a.b::X": 99, "status:new.app::Item-0": 5])
    let p = try store.readPositions()
    #expect(p["status:a.b::X"] == 99)
    #expect(p["status:a.b::Y"] == 20)
    #expect(p["module:Clock"] == 0)
    #expect(p["status:new.app::Item-0"] == 5)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    #expect(store.backup == original)
    #expect(throws: PreferenceWriterError.self) { try store.setPositions(["module:Clock": 5]) }
    try store.restoreBackup()
    #expect(try Data(contentsOf: url) == original)
}
