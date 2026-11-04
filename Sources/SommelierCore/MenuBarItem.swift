import ApplicationServices
import CoreGraphics
import Foundation

/// Where an item was discovered.
public enum MenuBarItemSource: String, Codable, Sendable {
    /// Exposed by the owning app via `AXExtrasMenuBar`.
    case appExtras
    /// Only visible in the MenuBarAgent's hosted tree (Control Center modules, clock, ...).
    case agentHostedOnly
}

/// Why an item is not on the bar (`MenuBarItem.hiddenReason`).
public enum HiddenReason: String, Codable, Sendable {
    /// The frame is off the strip or empty (the item is parked, e.g. x -1..3 / y ~1188).
    case parkedFrame
    /// MenuBarAgent no longer hosts the item although its owning app is running and still reports on-bar frames. This is
    /// what a live (cfprefsd-notified) hide looks like: the agent unregisters the scene, the app's own AX frames and
    /// the `stale` flag do not change (docs/findings-live-trigger.md section 4).
    case notHosted
    /// Our own successful live hide of the owner's identifier-less items was confirmed by a hosted-count drop, and nothing
    /// has contradicted it since; the app-side frame still says "on the bar" (of7). Never inferred from frames alone.
    case assumedNotHosted
}

/// One menu bar item (status item / menu extra).
public struct MenuBarItem: @unchecked Sendable {
    /// macOS's English name for the overflow chevron; also the stable `.module` key name for it under every locale.
    public static let overflowChevronName = "Show Hidden Menu Bar Items"

    public var ownerPID: pid_t
    public var ownerBundleID: String?
    public var ownerName: String
    public var title: String
    public var axDescription: String
    public var axIdentifier: String
    public var frame: CGRect
    public var source: MenuBarItemSource
    /// True when the frame is non-empty and its midY lies within the menu bar strip.
    public var isOnMenuBar: Bool
    /// True when the scanner concluded the item is hidden because a complete MenuBarAgent hosted read no longer
    /// contains it (`isOnMenuBar` is then false although `frame` may still look on-bar). See `HiddenReason.notHosted`.
    public var notHostedByAgent: Bool
    /// True when the item is reported hidden only because of the assumed-hidden state (`HiddenReason.assumedNotHosted`).
    public var assumedNotHosted: Bool
    /// nil when on the bar; otherwise why it is off it.
    public var hiddenReason: HiddenReason? {
        isOnMenuBar ? nil : (assumedNotHosted ? .assumedNotHosted : (notHostedByAgent ? .notHosted : .parkedFrame))
    }
    /// True for the agent's overflow chevron ("<<", `overflowChevronName` in English): the control MenuBarAgent hosts when
    /// the bar is full. Detected structurally (see `AXElementInfo.isOverflowChevron`), so it is the same under any locale.
    public var isOverflowChevron: Bool
    /// True when macOS itself pushed the item into its own overflow (behind the chevron): the agent still reports it
    /// on the bar (`isOnMenuBar`) with a clipped, stacked frame, but nothing is drawn and a drag is a no-op (gdu.25).
    /// Set by the scanner (`SystemOverflow.mark`); `isOnMenuBar` keeps meaning "on the bar per the agent".
    public var systemOverflow: Bool
    /// Opaque handle for later AX actions. Never serialized.
    public var axElement: AXUIElement?
    /// True when this item was carried forward from an earlier scan because a fresh read failed or missed its budget.
    public var stale: Bool
    /// Consecutive scans this item has been carried forward (0 when fresh).
    public var staleCount: Int

    public init(
        ownerPID: pid_t, ownerBundleID: String?, ownerName: String,
        title: String, axDescription: String, axIdentifier: String,
        frame: CGRect, source: MenuBarItemSource, isOnMenuBar: Bool,
        axElement: AXUIElement? = nil, stale: Bool = false, staleCount: Int = 0,
        notHostedByAgent: Bool = false, isOverflowChevron: Bool = false, systemOverflow: Bool = false,
        assumedNotHosted: Bool = false
    ) {
        self.assumedNotHosted = assumedNotHosted
        self.isOverflowChevron = isOverflowChevron
        self.systemOverflow = systemOverflow
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.ownerName = ownerName
        self.title = title
        self.axDescription = axDescription
        self.axIdentifier = axIdentifier
        self.frame = frame
        self.source = source
        self.isOnMenuBar = isOnMenuBar
        self.notHostedByAgent = notHostedByAgent
        self.axElement = axElement
        self.stale = stale
        self.staleCount = staleCount
    }
}

extension MenuBarItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case ownerPID, ownerBundleID, ownerName, title, axDescription, axIdentifier
        case frame, source, isOnMenuBar, stale, staleCount, hidden, systemOverflow, overflowChevron
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try c.decodeIfPresent(HiddenReason.self, forKey: .hidden)
        self.init(
            ownerPID: try c.decode(pid_t.self, forKey: .ownerPID),
            ownerBundleID: try c.decodeIfPresent(String.self, forKey: .ownerBundleID),
            ownerName: try c.decode(String.self, forKey: .ownerName),
            title: try c.decode(String.self, forKey: .title),
            axDescription: try c.decode(String.self, forKey: .axDescription),
            axIdentifier: try c.decode(String.self, forKey: .axIdentifier),
            frame: try c.decode(CGRect.self, forKey: .frame),
            source: try c.decode(MenuBarItemSource.self, forKey: .source),
            isOnMenuBar: try c.decode(Bool.self, forKey: .isOnMenuBar),
            axElement: nil,
            stale: try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false,
            staleCount: try c.decodeIfPresent(Int.self, forKey: .staleCount) ?? 0,
            notHostedByAgent: reason == .notHosted || reason == .assumedNotHosted,
            isOverflowChevron: try c.decodeIfPresent(Bool.self, forKey: .overflowChevron) ?? false,
            systemOverflow: try c.decodeIfPresent(Bool.self, forKey: .systemOverflow) ?? false,
            assumedNotHosted: reason == .assumedNotHosted)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ownerPID, forKey: .ownerPID)
        try c.encodeIfPresent(ownerBundleID, forKey: .ownerBundleID)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encode(title, forKey: .title)
        try c.encode(axDescription, forKey: .axDescription)
        try c.encode(axIdentifier, forKey: .axIdentifier)
        try c.encode(frame, forKey: .frame)
        try c.encode(source, forKey: .source)
        try c.encode(isOnMenuBar, forKey: .isOnMenuBar)
        try c.encode(stale, forKey: .stale)
        try c.encode(staleCount, forKey: .staleCount)
        try c.encodeIfPresent(hiddenReason, forKey: .hidden)
        try c.encode(systemOverflow, forKey: .systemOverflow)
        if isOverflowChevron { try c.encode(true, forKey: .overflowChevron) }
    }
}

public struct MenuBarSnapshot: Codable, Sendable {
    /// All items: on-bar left-to-right first, then parked.
    public var items: [MenuBarItem]
    public var capturedAt: Date
    /// Whether the agent's hosted tree was read completely (no failed reads or unnamed timeouts). Only a complete read can
    /// report a live-hidden item (docs/findings-live-trigger.md section 4). nil = not a full scan / unknown (treated as complete).
    public var hostedReadComplete: Bool?

    public init(items: [MenuBarItem], capturedAt: Date, hostedReadComplete: Bool? = nil) {
        self.items = items
        self.capturedAt = capturedAt
        self.hostedReadComplete = hostedReadComplete
    }

    /// On-bar items sorted by frame.minX (stable for equal x).
    public var onBarLeftToRight: [MenuBarItem] { items.filter { $0.isOnMenuBar } }
    /// Off-bar or zero-size items, in discovery order.
    public var parked: [MenuBarItem] { items.filter { !$0.isOnMenuBar } }
}

/// Apple's own overflow area (gdu.45). When the bar is full MenuBarAgent hosts a chevron and pushes the leftmost items
/// behind it: they stay in the hosted tree (so they count as on the bar) with clipped frames stacked at the left edge of
/// the usable area, but nothing is drawn there and drags on them are no-ops.
public enum SystemOverflow {
    /// One bar-ordered entry (left to right).
    public struct Entry: Sendable {
        public var frame: CGRect
        public var stale: Bool
        public var isChevron: Bool
        public init(frame: CGRect, stale: Bool, isChevron: Bool) { self.frame = frame; self.stale = stale; self.isChevron = isChevron }
    }

    /// Indices (into `order`, the on-bar items left to right) that macOS overflowed: the FRESH items ordered before a
    /// FRESH chevron of the same read. Nothing else flags (gdu.45 corrective: coincidental identical frames on a normal bar
    /// and a chevron missed by a partial read must not cascade); a stale or absent chevron flags nothing.
    public static func indices(order: [Entry]) -> Set<Int> {
        guard let c = order.firstIndex(where: { $0.isChevron && !$0.stale }) else { return [] }
        return Set((0..<c).filter { !order[$0].stale })
    }

    /// Sets `systemOverflow` on a snapshot's items. Expects the on-bar items first and sorted left to right (the
    /// scanner's output order); off-bar items are never flagged.
    public static func mark(_ items: [MenuBarItem]) -> [MenuBarItem] {
        let barIdx = items.indices.filter { items[$0].isOnMenuBar && items[$0].frame.width > 0 }
            .sorted { (items[$0].frame.minX, $0) < (items[$1].frame.minX, $1) }
        let flagged = indices(order: barIdx.map { Entry(frame: items[$0].frame, stale: items[$0].stale, isChevron: items[$0].isOverflowChevron) })
        var out = items
        for i in out.indices { out[i].systemOverflow = false }
        for n in flagged { out[barIdx[n]].systemOverflow = true }
        return out
    }
}
