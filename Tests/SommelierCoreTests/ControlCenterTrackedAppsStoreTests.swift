import Foundation
import Testing
@testable import SommelierCore

private func evidenceCopy() throws -> (URL, Data, URL) {
    // Tests/SommelierCoreTests/<this file> -> repo root -> docs/evidence
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let src = root.appendingPathComponent("docs/evidence/gdu6-cc-before.plist")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent("cc.plist")
    try FileManager.default.copyItem(at: src, to: dst)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    return (dst, try Data(contentsOf: dst), dir)
}

@Test func trackedAppsDecode() throws {
    let (url, _, dir) = try evidenceCopy()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ControlCenterTrackedAppsStore(url: url)
    let all = try store.entries()
    #expect(all.count == 73)
    #expect(try store.isAllowed("at.EternalStorms.Yoink") == false)
    #expect(try store.isAllowed("info.marcel-dierkes.KeepingYouAwake") == true)
    #expect(try store.isAllowed("no.such.app") == nil)
}

@Test func trackedAppsRoundTrip() throws {
    let (url, original, dir) = try evidenceCopy()
    defer { try? FileManager.default.removeItem(at: dir) }
    var store = ControlCenterTrackedAppsStore(url: url)
    let before = try store.entries()
    try store.setAllowed("info.marcel-dierkes.KeepingYouAwake", false)
    #expect(try store.isAllowed("info.marcel-dierkes.KeepingYouAwake") == false)
    // everything else unchanged
    let after = try store.entries()
    #expect(after.count == before.count)
    for (b, a) in zip(before, after) where b.key != "info.marcel-dierkes.KeepingYouAwake" { #expect(a == b) }
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    #expect(store.backup == original)
    try store.setAllowed("info.marcel-dierkes.KeepingYouAwake", true)
    #expect(try store.entries() == before)
    try store.restoreBackup()
    #expect(try Data(contentsOf: url) == original)
}

@Test func trackedAppsRefusesUnknownAndSystem() throws {
    let (url, original, dir) = try evidenceCopy()
    defer { try? FileManager.default.removeItem(at: dir) }
    var store = ControlCenterTrackedAppsStore(url: url)
    #expect(throws: PreferenceWriterError.self) { try store.setAllowed("no.such.app", false) }
    #expect(throws: PreferenceWriterError.self) { try store.setAllowed("module:Clock", false, create: true) }
    #expect(throws: PreferenceWriterError.self) { try store.setAllowed("com.apple.ScriptMenuApp", false) }
    #expect(try Data(contentsOf: url) == original)   // nothing written
    try store.setAllowed("no.such.app", false, create: true)
    #expect(try store.isAllowed("no.such.app") == false)
    #expect(try store.entries().count == 74)
}
