import Testing
import Foundation
@testable import DecisionCore

private final class Tally: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Threads: the runtime is initialised once; threads Swift/GCD created are initialised on their first call (the shim does it).
@Suite(.serialized) struct ThreadingTests {
    /// Two threads, each with its own states, replay different halves of the fuzz cases concurrently, repeatedly.
    @Test func twoThreadsReplayIndependentStates() {
        let cases = Fixture.all
        let tally = Tally(), errors = Tally(), g = DispatchGroup()
        for t in 0..<2 {
            g.enter()
            Thread.detachNewThread {
                for round in 0..<3 {
                    for (i, c) in cases.enumerated() where (i + round) % 2 == t {
                        do { tally.add(try Fixture.mismatches(c)) } catch { errors.add(1) }
                    }
                }
                g.leave()
            }
        }
        g.wait()
        #expect(tally.value == 0)
        #expect(errors.value == 0)
    }

    /// One shared state, read from four threads at once while two more threads step it (step returns new states; the shared one never changes).
    @Test func sharedStateAcrossThreads() throws {
        let cases = Fixture.all.filter { !$0.name.hasPrefix("fuzz") }
        let c = try #require(cases.first { $0.name == "W2" })
        var s = try DecisionState(record: c.record)
        var lastProbe: FixtureProbe?
        for item in c.items { if case .step(let st) = item { s = try DecisionCore.step(s, st.event).0 }; if case .probe(let p) = item { lastProbe = p } }
        let probe = try #require(lastProbe)
        let shared = s
        let want = try DecisionCore.status(shared, probe.read)
        let wantRow = try DecisionCore.row(shared, probe.read, 3)
        let stepWant = try DecisionCore.step(shared, .read(probe.read)).1
        let bad = Tally(), g = DispatchGroup()
        for _ in 0..<4 {
            g.enter()
            Thread.detachNewThread {
                for _ in 0..<5000 {
                    if (try? DecisionCore.status(shared, probe.read)) != want { bad.add(1) }
                    if (try? DecisionCore.row(shared, probe.read, 3)) != wantRow { bad.add(1) }
                }
                g.leave()
            }
        }
        for _ in 0..<2 {
            g.enter()
            Thread.detachNewThread {
                for _ in 0..<2000 {
                    guard let (n, a) = try? DecisionCore.step(shared, .read(probe.read)) else { bad.add(1); continue }
                    if a != stepWant { bad.add(1) }
                    if (try? DecisionCore.status(n, probe.read)) == nil { bad.add(1) }
                }
                g.leave()
            }
        }
        g.wait()
        #expect(bad.value == 0)
        #expect(try DecisionCore.status(shared, probe.read) == want)   // the shared state was not changed by the steppers
    }

    /// A state created on one thread, released on another (the last reference dies off-thread).
    @Test func stateReleasedOnAnotherThread() throws {
        let g = DispatchGroup()
        for _ in 0..<50 {
            let s = try DecisionState(record: [1, 2, 3])
            g.enter()
            Thread.detachNewThread { _ = try? DecisionCore.step(s, .passBoundary); g.leave() }
        }
        g.wait()
        let t = Tally(); let g2 = DispatchGroup(); g2.enter()
        DispatchQueue.global().async { t.add((try? DecisionState(record: [1])) == nil ? 1 : 0); g2.leave() }
        g2.wait(); #expect(t.value == 0)
    }

    /// From Swift concurrency's cooperative pool too.
    @Test func backgroundTask() async throws {
        let c = try #require(Fixture.all.first { $0.name == "tm" })
        let bad = try await Task.detached { try Fixture.mismatches(c) }.value
        #expect(bad == 0)
    }
}
