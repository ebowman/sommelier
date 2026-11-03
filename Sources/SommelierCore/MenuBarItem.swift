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
    /// Opaque handle for later AX actions. Never serialized.
    public var axElement: AXUIElement?

    public init(
        ownerPID: pid_t, ownerBundleID: String?, ownerName: String,
        title: String, axDescription: String, axIdentifier: String,
        frame: CGRect, source: MenuBarItemSource, isOnMenuBar: Bool,
        axElement: AXUIElement? = nil
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
        self.axElement = axElement
    }
}

extension MenuBarItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case ownerPID, ownerBundleID, ownerName, title, axDescription, axIdentifier
        case frame, source, isOnMenuBar
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
            axElement: nil)
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
    }
}

public struct MenuBarSnapshot: Codable, Sendable {
    /// All items: on-bar left-to-right first, then parked.
    public var items: [MenuBarItem]
    public var capturedAt: Date

    public init(items: [MenuBarItem], capturedAt: Date) {
        self.items = items
        self.capturedAt = capturedAt
    }

    /// On-bar items sorted by frame.minX (stable for equal x).
    public var onBarLeftToRight: [MenuBarItem] { items.filter { $0.isOnMenuBar } }
    /// Off-bar or zero-size items, in discovery order.
    public var parked: [MenuBarItem] { items.filter { !$0.isOnMenuBar } }
}
