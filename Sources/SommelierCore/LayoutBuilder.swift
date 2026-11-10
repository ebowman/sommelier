import Foundation

/// Builds a `Layout` from an observed, resolved snapshot (pure; no AX).
public enum LayoutBuilder {
    /// The one shared "not a status item" rule: width <= 1 (the frontmost app's main-menu entries and zero-width read noise).
    /// Used by `build` and by `BarSignature` so the agreement signature sees exactly what the layout will contain.
    public static func isNonItem(_ r: ResolvedItem) -> Bool { r.item.frame.width <= 1 }

    /// Keys whose placement is unknown (gdu.79): app-side frame only, no hosted element, Control Center does not say hidden. A layout built
    /// from a scan with any of these would have to guess; callers refuse (`init-from-current` exits 1, the first-launch build waits for
    /// the next launch/scan). `build` itself never writes them anywhere, so a guess can never land in `visible`.
    public static func unknownPlacement(in resolved: [ResolvedItem]) -> [ItemKey] {
        var seen = Set<ItemKey>()
        return resolved.filter { $0.item.placementUnknown && !EngineFactory.isOwnHosted($0) && !isNonItem($0) && seen.insert($0.key).inserted }.map(\.key)
    }

    /// The message of that refusal (names the keys).
    /// gdu.84: each key carries its own reason when known (`reasons`), e.g. "no hosted element" or "weak join (frameAmbiguous) with a
    /// hosted element in the overflow pile", plus what to do about it.
    public static func unknownPlacementMessage(_ keys: [ItemKey], reasons: [ItemKey: String] = [:]) -> String {
        "placement unknown for \(keys.count) items: "
            + keys.map { "\($0.description) (\(reasons[$0] ?? "no hosted element; make room in the bar so the item is drawn, or hide it in Control Center"))" }.joined(separator: ", ")
    }

    /// Per-key reasons of the placement-unknown items of `resolved`.
    public static func unknownReasons(in resolved: [ResolvedItem]) -> [ItemKey: String] {
        var out: [ItemKey: String] = [:]
        for r in resolved where r.item.placementUnknown { if let w = r.item.placementReason, out[r.key] == nil { out[r.key] = w } }
        return out
    }

    /// On-bar items -> `visible` (order preserved); parked items -> `hidden`. Items with width <= 1 (e.g. the frontmost
    /// app's main-menu entries reported by MenuBarAgent) are not status items and are excluded. Duplicate keys collapse
    /// (first occurrence wins). `excluded` lists "key (title)" for each ignored non-item.
    ///
    /// The input order is the observed left-to-right order (frames, ties by discovery order; see
    /// `MenuBarScanner.assemble`) and is kept verbatim, modules included. Sections are filled directly, NOT through
    /// `Layout.append`: that applies the "insert before the trailing system block" default for user-facing shows and
    /// would reverse the trailing modules and drag every module-then-app sequence to the end (sommelier-gdu.43).
    /// Items in Apple's overflow area share stacked frames; for those the scanner's discovery order stands.
    ///
    /// The result is hide-unit normalized (gdu.44): an app with one item on the bar and a sibling parked would otherwise be a
    /// split unit that can never converge. `build(from:)` normalizes silently; use `buildReportingNormalization` to learn
    /// which parked keys were moved to `visible`.
    public static func build(from resolved: [ResolvedItem], resolver: TrackedEntryResolver? = nil) -> (layout: Layout, excluded: [String]) {
        let r = buildReportingNormalization(from: resolved, resolver: resolver)
        return (r.layout, r.excluded)
    }

    /// Like `build(from:)`, also returning the keys normalization moved from `hidden` to `visible` (empty when none).
    public static func buildReportingNormalization(from resolved: [ResolvedItem], resolver: TrackedEntryResolver? = nil) -> (layout: Layout, excluded: [String], normalized: [ItemKey]) {
        var layout = Layout()
        var excluded: [String] = []
        var seen = Set<ItemKey>()
        for r in resolved {
            if EngineFactory.isOwnHosted(r) {   // gdu.147: our own status item is an ordinary Visible record key; it is never hidden
                if !isNonItem(r), seen.insert(.sommelierStatusItem).inserted { layout.visible.append(.sommelierStatusItem) }
                continue
            }
            if isNonItem(r) {
                excluded.append("\(r.key) (\(r.item.title))")
                continue
            }
            if r.item.isOverflowChevron || r.key.isOverflowChevron { continue }   // 9o9.14: the chevron is the agent's control, never a record key
            if r.item.placementUnknown { continue }   // never guessed into a section (gdu.79); callers refuse first
            if !seen.insert(r.key).inserted { continue }
            if r.item.isOnMenuBar { layout.visible.append(r.key) } else { layout.hidden.append(r.key) }
        }
        var ids: [ItemKey: String] = [:]
        for r in resolved { if let b = r.item.ownerBundleID, ids[r.key] == nil { ids[r.key] = b } }
        let n = layout.normalizedHideUnits(units: HideUnitRule(resolver: resolver, bundleIDs: ids))
        return (n.layout, excluded, n.moved)
    }
}
