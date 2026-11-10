import Testing
import Foundation
@testable import SommelierCore

/// sommelier-ejb.7 corrective pass 2: a user's drop that arrives while ANOTHER engine pass is running must still be performed.
/// The running pass is superseded by the drop (`setLayout`); it must not end the user's chain (`passBoundary`) or consume its owed state,
/// because the drop's own pass has not run yet. Before the fix the core's chain was ended by the superseded pass and the drop was lost.
private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

@MainActor @Suite(.serialized) struct DropDuringPassTests {
    private static let stall: (inout LayoutEngine.Config) -> Void = { $0.delaySleep = { _ in try? await Task.sleep(for: .seconds(3600)) } }

    /// Timers stalled: only `reconcileOnce` runs the drop's pass, so the outcome is decided by what the superseded pass left behind.
    @Test func aDropDuringAPollPassIsPerformed_stalledTimers() async {
        let r = await holdRig(failCalls: 10, configure: Self.stall)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let before = await moveCalls(r.actuator)
        await r.engine.requestReconcile(reason: "poll")                 // a poll pass starts running in the drain
        await r.engine.setLayout(r.layout, moved: [k("P2")])            // the user drops while it runs
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) > before)
    }

    /// Control: no pass running when the drop arrives.
    @Test func aDropWithNoPassRunningIsPerformed_control() async {
        let r = await holdRig(failCalls: 10, configure: Self.stall)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let before = await moveCalls(r.actuator)
        await r.engine.setLayout(r.layout, moved: [k("P2")])
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) > before)
    }

    /// Production timers: the coalescing window's own pass and the follow-up perform the drop without any help.
    @Test func aDropDuringAPollPassIsPerformed_productionTimers() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let before = await moveCalls(r.actuator)
        await r.engine.requestReconcile(reason: "poll")
        await r.engine.setLayout(r.layout, moved: [k("P2")])
        var after = before
        for _ in 0..<80 where after <= before {                          // up to 8 s: the 300 ms window, then the 3 s follow-up if needed
            try? await Task.sleep(for: .milliseconds(100))
            after = await moveCalls(r.actuator)
        }
        #expect(after > before)
    }

    /// Symmetric: a SECOND drop arriving while the first drop's own pass runs (a user-chain pass superseded by the drop); the latest drop is performed.
    @Test func aSecondDropDuringTheUsersPassIsPerformed_stalledTimers() async {
        let r = await holdRig(failCalls: 10, drop: [], configure: Self.stall)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let before = await moveCalls(r.actuator)
        await r.engine.setLayout(r.layout, moved: [k("P1")])
        await r.engine.requestReconcile(reason: "poll")                 // runs as the user's pass for P1 (the owed flag is consumed)
        await r.engine.setLayout(r.layout, moved: [k("P2")])            // the second drop lands while that pass runs
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        // The core's userEdit owes the LATEST drop's keys (a newer edit replaces an older, unperformed one): P2 must be performed.
        #expect(await moveCalls(r.actuator) > before)
    }
}
