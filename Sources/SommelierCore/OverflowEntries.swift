import CoreGraphics
import Foundation

/// One hidden item in the overflow panel. `unit`/`unitSize` expose the hide unit (all items of one Control Center entry hide or show
/// together): the panel draws a divider between units and a badge when `unitSize > 1`. The future Arrange window
/// (gdu.19) should group by the same `unit` field.
public struct OverflowEntry: Equatable, Sendable {
    public var key: ItemKey
    public var displayName: String
    public var ownerBundleID: String?
    public var ownerPID: pid_t
    public var width: CGFloat
    public var isOnBar: Bool
    public var unit: HideUnit
    /// Number of entries in the panel that belong to `unit` (including this one).
    public var unitSize: Int
    /// A `hidden` item whose app also has an `alwaysHidden` item: "reveal hidden" never shows it. The UI marks it.
    public var pinnedHidden: Bool
    public enum Kind: Equatable, Sendable {
        /// Hidden by Sommelier (the layout's hidden section).
        case hiddenByUs
        /// macOS moved it into its own overflow because the bar is full (gdu.45); shown after the hidden-by-us entries.
        case notFitting
    }
    public var kind: Kind
    /// 9o9.15: the raw description (else title) the app reports, for the tooltip; may differ from `displayName`.
    public var detail: String = ""
    public init(key: ItemKey, displayName: String, ownerBundleID: String?, ownerPID: pid_t, width: CGFloat, isOnBar: Bool,
                unit: HideUnit? = nil, unitSize: Int = 1, pinnedHidden: Bool = false, kind: Kind = .hiddenByUs, detail: String = "") {
        self.detail = detail
        self.kind = kind
        self.pinnedHidden = pinnedHidden
        self.unit = unit ?? key.hideUnit; self.unitSize = unitSize
        self.key = key; self.displayName = displayName; self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID; self.width = width; self.isOnBar = isOnBar
    }
}

public enum OverflowEntries {
    public static let maxNameLength = RowNameRule.maxNameLength
    public static let minWidth: CGFloat = 28

    public static func make(layout: Layout, items: [ItemKey: ItemInfo], includeAlwaysHidden: Bool = false, units: HideUnitRule = .ownerKeys) -> [OverflowEntry] {
        let keys = layout.hidden + (includeAlwaysHidden ? layout.alwaysHidden : [])
        var seen = Set<ItemKey>()
        var out: [OverflowEntry] = []
        let namer = RowNameRule.Namer(layout: layout, items: items)
        for k in keys where seen.insert(k).inserted {
            guard let i = items[k] else { continue }
            out.append(OverflowEntry(key: k, displayName: namer.name(k), ownerBundleID: i.ownerBundleID,
                                     ownerPID: i.ownerPID, width: max(minWidth, i.width), isOnBar: i.isOnBar, detail: namer.detail(k)))
        }
        let pinnedUnits = Set(layout.alwaysHidden.map { units.unit(of: $0) })
        out = out.map { var e = $0; e.pinnedHidden = layout.hidden.contains(e.key) && pinnedUnits.contains(units.unit(of: e.key)); return e }
        // Items macOS pushed into its own overflow are "the rest" too: after the ones we hid, in bar (layout) order.
        let hiddenKeys = Set(out.map(\.key))
        var rest: [OverflowEntry] = []
        for k in layout.visible where !hiddenKeys.contains(k) && seen.insert(k).inserted {
            guard let i = items[k], i.systemOverflow else { continue }
            rest.append(OverflowEntry(key: k, displayName: namer.name(k), ownerBundleID: i.ownerBundleID,
                                      ownerPID: i.ownerPID, width: max(minWidth, i.width), isOnBar: i.isOnBar, kind: .notFitting, detail: namer.detail(k)))
        }
        return grouped(out, units) + grouped(rest, units)
    }

    /// Keeps the keys of a unit adjacent, stable by first appearance, and records the unit size.
    private static func grouped(_ entries: [OverflowEntry], _ units: HideUnitRule) -> [OverflowEntry] {
        var grouped: [OverflowEntry] = []
        for g in hideUnits(entries.map(\.key), rule: units) {
            for k in g.keys {
                guard var e = entries.first(where: { $0.key == k }) else { continue }
                e.unit = g.unit; e.unitSize = g.keys.count
                grouped.append(e)
            }
        }
        return grouped
    }

    /// Context-free name of one item (no siblings known): the app name. Callers that know the layout use `RowNameRule.Namer` (9o9.15).
    public static func displayName(_ i: ItemInfo) -> String { RowNameRule.soleName(i) }
}

public enum OverflowPlacement {
    /// Widest the panel may be: 80 % of the visible width, and never reaching further left than 8 pt inside the
    /// visible frame when right-aligned to the anchor.
    public static func maxWidth(anchor itemFrame: CGRect, screenVisible: CGRect) -> CGFloat {
        max(0, min(screenVisible.width * 0.8, itemFrame.maxX - screenVisible.minX - 8))
    }

    /// AppKit coordinates (origin bottom-left). Width = min(content, `maxWidth(...)`); the right edge always sits on the
    /// anchor's right edge (only clamped into `screenVisible` when the anchor itself is near an edge); top edge at the
    /// menu bar bottom.
    public static func panelFrame(anchor itemFrame: CGRect, menuBarBottomY: CGFloat, screenVisible: CGRect,
                                  contentSize: CGSize) -> CGRect {
        let w = min(contentSize.width, maxWidth(anchor: itemFrame, screenVisible: screenVisible), screenVisible.width)
        let h = min(contentSize.height, screenVisible.height)
        var x = itemFrame.maxX - w
        x = max(screenVisible.minX, min(x, screenVisible.maxX - w))
        var y = menuBarBottomY - h
        y = max(screenVisible.minY, min(y, screenVisible.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
