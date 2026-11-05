import Testing
@testable import SommelierCore

@Suite struct AppNameCacheTests {
    @Test func repeatedCallsLookUpOnce() {
        var c = AppNameCache(lookup: { _ in "Foo" })
        #expect(c.name(for: "a") == "Foo")
        #expect(c.name(for: "a") == "Foo")
        #expect(c.name(for: "a") == "Foo")
        #expect(c.lookupCount == 1)
    }
    @Test func nilIsCached() {
        var c = AppNameCache(lookup: { _ in nil })
        #expect(c.name(for: "a") == nil)
        #expect(c.name(for: "a") == nil)
        #expect(c.lookupCount == 1)
    }
    @Test func invalidateRequeries() {
        var c = AppNameCache(lookup: { _ in "Foo" })
        _ = c.name(for: "a")
        c.invalidate()
        _ = c.name(for: "a")
        #expect(c.lookupCount == 2)
    }
}
