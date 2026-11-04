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
}

/// One menu bar item (status item / menu extra).
public struct MenuBarItem: @unchecked Sendable {
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
    /// nil when on the bar; otherwise why it is off it.
    public var hiddenReason: HiddenReason? { isOnMenuBar ? nil : (notHostedByAgent ? .notHosted : .parkedFrame) }
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
        notHostedByAgent: Bool = false
    ) {
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
        case frame, source, isOnMenuBar, stale, staleCount, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
            notHostedByAgent: (try c.decodeIfPresent(HiddenReason.self, forKey: .hidden)) == .notHosted)
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
