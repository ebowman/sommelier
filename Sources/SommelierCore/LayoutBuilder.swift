import Foundation

/// Builds a `Layout` from an observed, resolved snapshot (pure; no AX).
public enum LayoutBuilder {
    /// The one shared "not a status item" rule: width <= 1 (the frontmost app's main-menu entries and zero-width read noise).
    /// Used by `build` and by `BarSignature` so the agreement signature sees exactly what the layout will contain.
    public static func isNonItem(_ r: ResolvedItem) -> Bool { r.item.frame.width <= 1 }

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
    public static func build(from resolved: [ResolvedItem]) -> (layout: Layout, excluded: [String]) {
        let r = buildReportingNormalization(from: resolved)
        return (r.layout, r.excluded)
    }

    /// Like `build(from:)`, also returning the keys normalization moved from `hidden` to `visible` (empty when none).
    public static func buildReportingNormalization(from resolved: [ResolvedItem]) -> (layout: Layout, excluded: [String], normalized: [ItemKey]) {
        var layout = Layout()
        var excluded: [String] = []
        var seen = Set<ItemKey>()
        for r in resolved {
            if EngineFactory.isOwnHosted(r) { continue }   // our own status item is never part of a layout
            if isNonItem(r) {
                excluded.append("\(r.key) (\(r.item.title))")
                continue
            }
            if !seen.insert(r.key).inserted { continue }
            if r.item.isOnMenuBar { layout.visible.append(r.key) } else { layout.hidden.append(r.key) }
        }
        let n = layout.normalizedHideUnits()
        return (n.layout, excluded, n.moved)
    }
}
