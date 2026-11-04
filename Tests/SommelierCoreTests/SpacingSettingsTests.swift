import Testing
import Foundation
@testable import SommelierCore

private final class FakeBackend: SpacingPreferencesBackend, @unchecked Sendable {
    var store: [String: Int] = [:]
    func integer(forKey key: String) -> Int? { store[key] }
    func set(_ value: Int?, forKey key: String) -> Bool { store[key] = value; return true }
}

@Test func spacingEmptyByDefault() {
    let s = SpacingSettings(backend: FakeBackend())
    #expect(s.current().spacing == nil && s.current().padding == nil)
}

@Test func spacingSetClampsAndReads() {
    let b = FakeBackend()
    let s = SpacingSettings(backend: b)
    s.set(spacing: 99, padding: -5)
    #expect(s.current().spacing == 24 && s.current().padding == 0)
    #expect(b.store[SpacingSettings.spacingKey] == 24)
}

@Test func spacingPartialSetLeavesOtherKey() {
    let s = SpacingSettings(backend: FakeBackend())
    s.set(spacing: 6)
    #expect(s.current().spacing == 6 && s.current().padding == nil)
    s.set(padding: 8)
    #expect(s.current().spacing == 6 && s.current().padding == 8)
}

@Test func spacingResetRemovesBoth() {
    let b = FakeBackend()
    let s = SpacingSettings(backend: b)
    s.set(spacing: 3, padding: 4)
    s.reset()
    #expect(b.store.isEmpty)
}
