import Foundation

/// The decision behind `mbprobe layout init-from-current` (gdu.82), pure over an observer so it is testable with a scripted source.
/// A layout is built only from an agreed result that rests on a complete read and in which NO considered scan marked an item
/// `placementUnknown` (an item flipping between unknown and "placed" across scans must not be written either way).
public enum LayoutInit {
    public enum Outcome {
        case refuse(String)
        case build(items: [ResolvedItem], scans: Int, notes: [String])
    }

    public static let incompleteMessage = "layout init needs a complete read; retry when the bar settles"

    public static func evaluate(observer: AgreedScanObserver) async -> Outcome {
        let r: (items: [ResolvedItem], scans: Int, disagreement: ScanDisagreement?, completeness: ReadCompleteness, unknownSeen: [ItemKey],
               unknownReasons: [ItemKey: String], incompleteReasons: [String])
        do { r = try await observer.observeDiagnosed() } catch { return .refuse("\(error); not writing") }
        if let d = r.disagreement { return .refuse(d.message) }
        if r.completeness == .incomplete {
            // gdu.84: say which groups/reads made it incomplete (the scanner's gdu.51 reason), not just "retry".
            return .refuse(r.incompleteReasons.isEmpty ? incompleteMessage : incompleteMessage + " (incomplete: " + r.incompleteReasons.joined(separator: "; ") + ")")
        }
        var notes: [String] = []
        switch BarSignature().staleVerdict(r.items) {
        case .clean: break
        case .refuse(let keys): return .refuse("stale items in the agreed scan, not writing: " + keys.joined(separator: ", "))
        }
        // The union over every scan the agreement loop considered, plus the final result.
        var unknown = r.unknownSeen
        for k in LayoutBuilder.unknownPlacement(in: r.items) where !unknown.contains(k) { unknown.append(k) }
        var reasons = r.unknownReasons
        reasons.merge(LayoutBuilder.unknownReasons(in: r.items)) { old, _ in old }
        if !unknown.isEmpty { return .refuse(LayoutBuilder.unknownPlacementMessage(unknown, reasons: reasons) + "; not writing") }
        return .build(items: r.items, scans: r.scans, notes: notes)
    }
}
