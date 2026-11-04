import Foundation

/// Builds a `Layout` from an observed, resolved snapshot (pure; no AX).
public enum LayoutBuilder {
    /// On-bar items -> `visible` (order preserved); parked items -> `hidden`. Items with width <= 1 (e.g. the frontmost
    /// app's main-menu entries reported by MenuBarAgent) are not status items and are excluded. Duplicate keys collapse
    /// (first occurrence wins). `excluded` lists "key (title)" for each ignored non-item.
    ///
    /// The input order is the observed left-to-right order (frames, ties by discovery order; see
    /// `MenuBarScanner.assemble`) and is kept verbatim, modules included. Sections are filled directly, NOT through
    /// `Layout.append`: that applies the "insert before the trailing system block" default for user-facing shows and
    /// would reverse the trailing modules and drag every module-then-app sequence to the end (sommelier-gdu.43).
    /// Items in Apple's overflow area share stacked frames; for those the scanner's discovery order stands.
    public static func build(from resolved: [ResolvedItem]) -> (layout: Layout, excluded: [String]) {
        var layout = Layout()
        var excluded: [String] = []
        var seen = Set<ItemKey>()
        for r in resolved {
            if EngineFactory.isOwnHosted(r) { continue }   // our own status item is never part of a layout
            if r.item.frame.width <= 1 {
                excluded.append("\(r.key) (\(r.item.title))")
                continue
            }
            if !seen.insert(r.key).inserted { continue }
            if r.item.isOnMenuBar { layout.visible.append(r.key) } else { layout.hidden.append(r.key) }
        }
        return (layout, excluded)
    }
}
