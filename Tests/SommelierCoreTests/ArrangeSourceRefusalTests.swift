import Testing
@testable import SommelierCore

/// gdu.116: the drag gesture is attached to every capsule; a source that could not be picked up is refused at drop time.
@Suite struct ArrangeSourceRefusalTests {
    private let key = ItemKey.status(ownerKey: "o", autosaveName: "a")

    private func row(ghost: Bool = false, draggable: Bool = true, stale: Bool = false, anchor: Bool = false,
                     running: Bool = true, note: String? = nil) -> ArrangeRow {
        var r = ArrangeRow(key: key, title: "t", ownerName: "o", ownerBundleID: nil, ownerPID: nil, badge: .none, draggable: draggable, canHide: true,
                           isAnchor: anchor, isGhost: ghost, isBoundary: false, notFitting: false, notRunning: !running,
                           unit: HideUnitRule.ownerKeys.unit(of: key), unitMates: [], capabilityNote: note)
        r.staleFrame = stale
        return r
    }

    @Test func draggableSourceIsAccepted() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row()]) == nil)
    }
    @Test func staleSourceIsRefusedWithStaleReason() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row(draggable: false, stale: true)]) == ArrangeDrop.sourceStale)
    }
    @Test func notRunningSourceIsRefused() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row(draggable: false, running: false)]) == ArrangeDrop.sourceNotRunning)
    }
    @Test func anchorUsesCapabilityNoteElseGenericReason() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row(draggable: false, anchor: true, note: "System item.")]) == "System item.")
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row(draggable: false, anchor: true)]) == ArrangeDrop.sourceFixed)
    }
    @Test func staleWinsOverNotRunning() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: [row(draggable: false, stale: true, running: false)]) == ArrangeDrop.sourceStale)
    }
    @Test func ghostSourceFollowsGhostInteractive() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: true, rows: [row(ghost: true)]) == nil)
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: true, rows: [row(ghost: true, running: false)]) == ArrangeDrop.sourcePending)
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: true, rows: [row(ghost: true, draggable: false)]) == ArrangeDrop.sourcePending)
    }
    @Test func realAndGhostRowsOfOneKeyAreJudgedSeparately() {
        let rows = [row(draggable: false, stale: true), row(ghost: true)]
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: rows) == ArrangeDrop.sourceStale)
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: true, rows: rows) == nil)
    }
    @Test func draggabilityFlipDoesNotChangeRowIdentity() {
        #expect(row(draggable: true).id == row(draggable: false, stale: true).id)
        #expect(row(ghost: true).id != row().id)   // ghost -> real is a different identity by design
    }
    @Test func unknownSourceIsNotRefusedByThisRule() {
        #expect(ArrangeDrop.sourceRefusal(key: key, fromGhost: false, rows: []) == nil)
    }
}
