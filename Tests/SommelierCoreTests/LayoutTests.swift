import Foundation
import Testing
@testable import SommelierCore

private let a = ItemKey.status(ownerKey: "com.example", autosaveName: "A")
private let b = ItemKey.module(name: "Wifi")
private let c = ItemKey.heuristic(bundleID: "com.x", fingerprint: "fp::with#hash", ordinal: 2)
private let d = ItemKey.status(ownerKey: "com.example", autosaveName: "Main: Status #1")

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

struct LayoutTests {
    @Test func moveBetweenSectionsRemovesFromOld() {
        var l = Layout(visible: [a, b])
        l.move(a, to: .hidden)
        #expect(l.visible == [b]); #expect(l.hidden == [a]); #expect(l.isValid)
        #expect(l.section(of: a) == .hidden)
    }
    @Test func moveClampsIndex() {
        var l = Layout(visible: [a, b])
        l.move(c, to: .visible, index: 99); #expect(l.visible == [a, b, c])
        l.move(c, to: .visible, index: -5); #expect(l.visible == [c, a, b])
        l.reorder(c, in: .visible, toIndex: 1); #expect(l.visible == [a, c, b])
        l.move(a, to: .visible, index: 50); #expect(l.visible == [c, b, a])
    }
    @Test func moveUnknownAppends() {
        var l = Layout(visible: [a]); l.move(b, to: .alwaysHidden)
        #expect(l.alwaysHidden == [b]); #expect(l.allKeys == [a, b])
        l.append(c, to: .hidden); #expect(l.hidden == [c])
    }
    @Test func removeReturnsSection() {
        var l = Layout(visible: [a], hidden: [b])
        #expect(l.remove(b) == .hidden); #expect(l.remove(b) == nil); #expect(l.hidden.isEmpty)
    }
    @Test func validatedKeepsFirst() {
        let l = Layout(visible: [a], hidden: [a, b], alwaysHidden: [b, c, c])
        #expect(!l.isValid)
        let v = l.validated()
        #expect(v.visible == [a]); #expect(v.hidden == [b]); #expect(v.alwaysHidden == [c]); #expect(v.isValid)
    }
    @Test func codableRoundTripAndStringForm() throws {
        let l = Layout(visible: [a, d], hidden: [b], alwaysHidden: [c], newItemPolicy: .hidden)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(l)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"status:com.example::A\""))
        #expect(text.contains("\"module:Wifi\""))
        let back = try Layout.decode(data)
        #expect(back.layout == l); #expect(back.warnings.isEmpty)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == l)
    }
    @Test func lenientDecode() throws {
        let r = try Layout.decode(Data(#"{"visible":["module:Wifi"]}"#.utf8))
        #expect(r.layout.schemaVersion == 1); #expect(r.layout.newItemPolicy == .visibleAtEnd)
        #expect(r.layout.visible == [b]); #expect(r.layout.hidden.isEmpty)
    }
    @Test func duplicatesWarn() throws {
        let r = try Layout.decode(Data(#"{"visible":["module:Wifi"],"hidden":["module:Wifi","status:com.example::A"]}"#.utf8))
        #expect(r.layout.hidden == [a]); #expect(r.warnings == ["duplicate key module:Wifi dropped from hidden"])
    }
    @Test func migrate() throws {
        let low = Layout(schemaVersion: 0, visible: [a])
        #expect(try Layout.migrate(low).schemaVersion == Layout.currentSchemaVersion)
        #expect(throws: LayoutError.self) { try Layout.migrate(Layout(schemaVersion: 99)) }
    }
}

struct FileLayoutStoreTests {
    @Test func missingIsEmpty() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try FileLayoutStore(url: dir.appendingPathComponent("layout.json")).load() == .empty)
    }
    @Test func roundTripNoTempLeft() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = FileLayoutStore(url: dir.appendingPathComponent("sub/layout.json"))
        let l = Layout(visible: [a, d], hidden: [b], alwaysHidden: [c])
        try s.save(l); try s.save(l)
        #expect(try s.load() == l)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("sub").path) == ["layout.json"])
    }
    @Test func corruptBacksUp() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("layout.json")
        try Data("{not json".utf8).write(to: f)
        #expect(throws: LayoutError.self) { try FileLayoutStore(url: f).load() }
        #expect(try Data(contentsOf: dir.appendingPathComponent("layout.json.bak")) == Data("{not json".utf8))
    }
    @Test func badKeyIsCorrupt() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("layout.json")
        try Data(#"{"visible":["status:Item-0"]}"#.utf8).write(to: f)
        do { _ = try FileLayoutStore(url: f).load(); Issue.record("expected throw") }
        catch LayoutError.corrupt(_, let bak) { #expect(FileManager.default.fileExists(atPath: bak.path)) }
    }
    @Test func higherSchemaUnsupported() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("layout.json")
        try Data(#"{"schemaVersion":7}"#.utf8).write(to: f)
        do { _ = try FileLayoutStore(url: f).load(); Issue.record("expected throw") }
        catch LayoutError.unsupportedSchema(let v) { #expect(v == 7) }
    }
    @Test func unwritableParentThrows() {
        let s = FileLayoutStore(url: URL(fileURLWithPath: "/System/nope/layout.json"))
        #expect(throws: (any Error).self) { try s.save(.empty) }
    }
}

struct LayoutBuilderTests {
    private func r(_ key: ItemKey, x: CGFloat, w: CGFloat, onBar: Bool, title: String = "") -> ResolvedItem {
        ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: title, axDescription: "",
                                       axIdentifier: "", frame: CGRect(x: x, y: 3, width: w, height: 24),
                                       source: .appExtras, isOnMenuBar: onBar),
                     key: key, confidence: .exact)
    }
    @Test func builds() {
        let z = ItemKey.heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "File", ordinal: 0)
        let res = [r(a, x: 100, w: 24, onBar: true), r(b, x: 130, w: 24, onBar: true),
                   r(c, x: 2, w: 24, onBar: false), r(z, x: 0, w: 0, onBar: false, title: "File"),
                   r(a, x: 100, w: 24, onBar: true)]
        let out = LayoutBuilder.build(from: res)
        #expect(out.layout.visible == [a, b])
        #expect(out.layout.hidden == [c])
        #expect(out.excluded.count == 1)
        #expect(out.excluded[0].hasSuffix("(File)"))
        #expect(out.layout.isValid)
    }
}
