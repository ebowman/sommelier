import CoreGraphics
import Foundation

public struct OverflowEntry: Equatable, Sendable {
    public var key: ItemKey
    public var displayName: String
    public var ownerBundleID: String?
    public var ownerPID: pid_t
    public var width: CGFloat
    public var isOnBar: Bool
    public init(key: ItemKey, displayName: String, ownerBundleID: String?, ownerPID: pid_t, width: CGFloat, isOnBar: Bool) {
        self.key = key; self.displayName = displayName; self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID; self.width = width; self.isOnBar = isOnBar
    }
}

public enum OverflowEntries {
    public static let maxNameLength = 24
    public static let minWidth: CGFloat = 28

    public static func make(layout: Layout, items: [ItemKey: ItemInfo], includeAlwaysHidden: Bool = false) -> [OverflowEntry] {
        let keys = layout.hidden + (includeAlwaysHidden ? layout.alwaysHidden : [])
        var seen = Set<ItemKey>()
        var out: [OverflowEntry] = []
        for k in keys where seen.insert(k).inserted {
            guard let i = items[k] else { continue }
            out.append(OverflowEntry(key: k, displayName: displayName(i), ownerBundleID: i.ownerBundleID,
                                     ownerPID: i.ownerPID, width: max(minWidth, i.width), isOnBar: i.isOnBar))
        }
        return out
    }

    public static func displayName(_ i: ItemInfo) -> String {
        let candidates = [i.axDescription, i.title, i.ownerName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = candidates.first { !$0.isEmpty } ?? ""
        if name.count <= maxNameLength { return name }
        return String(name.prefix(maxNameLength - 1)) + "…"
    }
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
