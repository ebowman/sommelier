import Foundation

/// Builds a `Layout` from an observed, resolved snapshot (pure; no AX).
public enum LayoutBuilder {
    /// On-bar items -> `visible` (order preserved); parked items -> `hidden`. Items with width <= 1 (e.g. the frontmost
    /// app's main-menu entries reported by MenuBarAgent) are not status items and are excluded. Duplicate keys collapse
    /// (first occurrence wins). `excluded` lists "key (title)" for each ignored non-item.
    public static func build(from resolved: [ResolvedItem]) -> (layout: Layout, excluded: [String]) {
        var layout = Layout()
        var excluded: [String] = []
        for r in resolved {
            if r.item.frame.width <= 1 {
                excluded.append("\(r.key) (\(r.item.title))")
                continue
            }
            if layout.section(of: r.key) != nil { continue }
            layout.append(r.key, to: r.item.isOnMenuBar ? .visible : .hidden)
        }
        return (layout, excluded)
    }
}
