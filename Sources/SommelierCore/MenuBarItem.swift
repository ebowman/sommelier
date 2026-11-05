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
    /// The owner's own AX frame still says "on the bar" but there is NO hosted MenuBarAgent element for it and the Control
    /// Center readback says `isAllowed == false` (gdu.79): the agent enforces that store, so the item is hidden.
    case controlCenterHidden
    /// The owner's own AX frame says "on the bar", no hosted element joins it and the Control Center flag does not say hidden
    /// (allowed or unreadable) although the item has a tracked entry (gdu.79): its placement is unknown, never "on the bar".
    case placementUnknown
}

/// How the owner's own AX item was paired with the MenuBarAgent hosted element that supplies its frame (gdu.28).
/// Only the scanner sets this; everything but `.none` means the pairing was examined.
public enum JoinEvidence: String, Codable, Sendable {
    /// Not examined (app-side only item, hosted-only item, tests, older caches).
    case none
    /// Hosted and owner elements carry the same non-empty AXIdentifier.
    case identifier
    /// Same non-empty AXDescription, and that description is unique among the owner candidates and among the hosted elements.
    case description
    /// Frame join, but the pairing is MUTUAL and exclusive: the hosted element substantially overlaps (>= half of the narrower
    /// width) exactly this owner item and no other, this owner item overlaps no other hosted element, and the widths agree
    /// within 2 pt. An app-side frame that lags a move overlaps a neighbour as well, which breaks this.
    case frameUnique
    /// Frame join where more than one owner item or hosted element competes for the overlap (crowded or stacked bar,
    /// lagging app-side frame). The label may belong to a neighbour (docs/findings-drag.md pitfall 2).
    case frameAmbiguous

    /// A pairing that does not rest on a bare, possibly mislabelled frame overlap.
    public var corroborated: Bool { self == .identifier || self == .description || self == .frameUnique }
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
    /// gdu.79: app-side frame only (no hosted element joined) and Control Center says `isAllowed == false`: hidden, whatever the frame says.
    public var hiddenInControlCenter: Bool
    /// gdu.79: app-side frame only, no hosted element, and the Control Center flag does not prove it hidden: not on the bar, not
    /// known to be anywhere. Never listed as visible and never shown by the engine because of this scan.
    public var placementUnknown: Bool
    /// The Control Center `isAllowed` readback the scanner consulted for an app-side-only item (nil = not consulted / unreadable / no entry).
    public var controlCenterAllowed: Bool?
    /// gdu.84: why `placementUnknown` is set ("no hosted element" vs "weak join (frameAmbiguous) in the overflow pile" ...), with what
    /// to do about it. Diagnostic only: not serialized, not part of identity.
    public var placementReason: String?
    /// nil when on the bar; otherwise why it is off it.
    public var hiddenReason: HiddenReason? {
        isOnMenuBar ? nil : (assumedNotHosted ? .assumedNotHosted : (notHostedByAgent ? .notHosted
            : (hiddenInControlCenter ? .controlCenterHidden : (placementUnknown ? .placementUnknown : .parkedFrame))))
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
    /// How the owner item and its hosted frame were paired (gdu.28). Not part of the item's identity.
    public var joinEvidence: JoinEvidence

    public init(
        ownerPID: pid_t, ownerBundleID: String?, ownerName: String,
        title: String, axDescription: String, axIdentifier: String,
        frame: CGRect, source: MenuBarItemSource, isOnMenuBar: Bool,
        axElement: AXUIElement? = nil, stale: Bool = false, staleCount: Int = 0,
        notHostedByAgent: Bool = false, isOverflowChevron: Bool = false, systemOverflow: Bool = false,
        assumedNotHosted: Bool = false, joinEvidence: JoinEvidence = .none,
        hiddenInControlCenter: Bool = false, placementUnknown: Bool = false, controlCenterAllowed: Bool? = nil
    ) {
        self.hiddenInControlCenter = hiddenInControlCenter
        self.placementUnknown = placementUnknown
        self.controlCenterAllowed = controlCenterAllowed
        self.joinEvidence = joinEvidence
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
        case frame, source, isOnMenuBar, stale, staleCount, hidden, systemOverflow, overflowChevron, joinEvidence, ccAllowed
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
            assumedNotHosted: reason == .assumedNotHosted,
            joinEvidence: try c.decodeIfPresent(JoinEvidence.self, forKey: .joinEvidence) ?? .none,
            hiddenInControlCenter: reason == .controlCenterHidden, placementUnknown: reason == .placementUnknown,
            controlCenterAllowed: try c.decodeIfPresent(Bool.self, forKey: .ccAllowed))
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
        if joinEvidence != .none { try c.encode(joinEvidence, forKey: .joinEvidence) }
        try c.encodeIfPresent(controlCenterAllowed, forKey: .ccAllowed)
    }
}

/// What the agent's top level shows about its overflow chevron (gdu.65).
public struct OverflowProbe: Equatable, Sendable {
    /// The chevron's frame; nil when the bar has none (nothing is in the system overflow then).
    public var chevron: CGRect?
    /// The chevron is open: the overflowed items are drawn in the widened strip (frames are real again).
    public var expanded: Bool
    /// Frames of the other hosted groups, whatever their state (stacked frames included).
    public var hosted: [CGRect]
    public init(chevron: CGRect?, expanded: Bool = false, hosted: [CGRect] = []) {
        self.chevron = chevron; self.expanded = expanded; self.hosted = hosted
    }

    /// Is `frame` (a revealed item's settled frame) a system-overflow frame? The shared `SystemOverflowRule` (gdu.69), against
    /// this probe's chevron and hosted groups. Never true when the bar has no chevron or it is expanded.
    public func isStacked(_ frame: CGRect) -> Bool {
        guard let c = chevron, !expanded else { return false }
        return SystemOverflowRule.isOverflowed(frame, chevron: c, hosted: hosted)
    }
}

/// THE rule for "macOS put this item in its own overflow area" (gdu.69). One definition shared by the scanner's
/// `systemOverflow` flag, `ActuationVerifier.overflowed` and `OverflowProbe.isStacked`, so the planner, the actuator and the
/// activator can never disagree. With a chevron on the bar, a frame is overflowed when
///  (a) it lies left of the chevron's minX, or
///  (b) its centre lies on the chevron (within 2 pt), or
///  (c) it is stacked on another hosted frame (centres within 2 pt) AND within the chevron's reach (starts left of the
///      chevron's maxX): the clipped pile macOS draws behind the chevron extends past its minX (seen live: 1Password, Tailscale
///      and others at x 783..799 with the chevron at 795..812).
/// Bare frame coincidence right of the chevron is NOT overflow (two drawn items can coincide by chance; findings-drag
/// "False-positive incident"). No chevron: nothing is overflowed (the caller decides).
public enum SystemOverflowRule {
    /// gdu.84: the exact-frame tie-break of the scanner's join (`MenuBarScanner.assemble`, the `exactFrame` pass). Inside the overflow
    /// pile neighbours overlap (TextInputMenuAgent 798/w27 and #4 799/w22 around KeepingYouAwake at 795/w30), so a plain intersection
    /// join is ambiguous even when one unowned hosted element sits EXACTLY on the app item's frame. An ALLOWED item (never a
    /// Control Center flag-false one, gdu.79) whose app-side frame equals an unowned hosted element's within `exactFrameTolerance`
    /// in x AND width joins it as `frameUnique`, provided no other allowed candidate matches that element exactly too (and the
    /// candidate matches no other element exactly). Two exact matches stay ambiguous.
    public static let exactFrameTolerance: CGFloat = 1
    public static func exactFrameMatch(_ hosted: CGRect, _ app: CGRect) -> Bool {
        guard hosted.width > 0, app.width > 0 else { return false }
        let i = hosted.intersection(app)
        return !i.isNull && i.height > 0
            && abs(hosted.minX - app.minX) <= exactFrameTolerance && abs(hosted.width - app.width) <= exactFrameTolerance
    }
    public static func isOverflowed(_ frame: CGRect, chevron c: CGRect, hosted: [CGRect]) -> Bool {
        if frame.minX < c.minX { return true }
        if c.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY)) { return true }
        guard frame.minX < c.maxX else { return false }
        // The frame's own group is usually in `hosted` too: a second one on this x means it is stacked.
        return hosted.filter { abs($0.midX - frame.midX) <= 2 }.count >= 2
    }
}

/// gdu.80: one complete read of the bar as the churn rule needs it (frames and the chevron, nothing else).
public struct ChurnRead: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: ItemKey
        public var frame: CGRect
        public var isChevron: Bool
        public var stale: Bool
        public init(key: ItemKey, frame: CGRect, isChevron: Bool = false, stale: Bool = false) {
            self.key = key; self.frame = frame; self.isChevron = isChevron; self.stale = stale
        }
    }
    /// A fresh chevron was on the bar (the bar is full).
    public var hasChevron: Bool
    /// Keys macOS had in its pile in this read (`SystemOverflowRule`).
    public var overflow: Set<ItemKey>
    /// Pile keys plus the drawn items within one item-width of the first drawn item right of the chevron.
    public var zone: Set<ItemKey>

    /// `extraOverflow`: further keys the caller knows are piled (the actuator's coincident-frame guard).
    public init(entries: [Entry], extraOverflow: Set<ItemKey> = []) {
        let bar = entries.enumerated().filter { $0.element.frame.width > 1 }
            .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }.map(\.element)
        guard let c = bar.first(where: { $0.isChevron && !$0.stale }) else {
            hasChevron = false; overflow = []; zone = []; return
        }
        hasChevron = true
        let ovfIdx = SystemOverflow.indices(order: bar.map { SystemOverflow.Entry(frame: $0.frame, stale: $0.stale, isChevron: $0.isChevron) })
        var ovf = Set(ovfIdx.map { bar[$0].key }).union(extraOverflow)
        ovf.remove(c.key)
        overflow = ovf
        let fresh = bar.filter { !$0.stale && !$0.isChevron }
        var z = ovf
        let drawn = fresh.filter { !ovf.contains($0.key) && $0.frame.minX >= c.frame.minX }
        if let first = drawn.first {
            let w = fresh.map(\.frame.width).max() ?? SystemOverflowRule.fallbackItemWidth
            for e in drawn where e.frame.maxX >= first.frame.minX - w && e.frame.minX <= first.frame.minX + w { z.insert(e.key) }
        }
        zone = z
    }

    public init(resolved: [ResolvedItem]) {
        let on = resolved.filter { $0.item.isOnMenuBar && $0.item.frame.width > 0 }
        self.init(entries: on.map { Entry(key: $0.key, frame: $0.item.frame, isChevron: $0.item.isOverflowChevron, stale: $0.item.stale) },
                  extraOverflow: ActuationVerifier.overflowed(resolved))
    }
}

extension SystemOverflowRule {
    /// Item width used for the churn zone when a read has no hosted width at all.
    public static let fallbackItemWidth: CGFloat = 40

    /// Why a churn-zone item is not planned or dragged (gdu.80). Same family as `Reconciler.overflowSkipReason`.
    public static let churnSkipReason = "bar is full; macOS decides what fits"
    /// Text carried by the actuator's refusal of a churn-zone subject or anchor. Contains the overflow refusal marker so the
    /// engine treats it like any other overflow refusal (a skip, never a strike).
    public static let churnRefusalMarker = "\(ActuationError.overflowRefusalMarker) (bar is full; macOS decides what fits)"

    /// gdu.80 churn zone: keys that were in the pile, or within one item-width of the first drawn item right of the chevron, in
    /// EITHER of the given (last two complete) reads. When the bar's membership changes on a full bar the pile changes with it,
    /// so these are the items a plan could otherwise drag although macOS is about to move them. Empty without a chevron.
    public static func churnZone(_ reads: [ChurnRead]) -> Set<ItemKey> {
        reads.suffix(2).reduce(into: Set<ItemKey>()) { $0.formUnion($1.zone) }
    }

    /// The overflow set is settled when the last two complete reads agree on it (and on the bar being full) -- gdu.80.
    public static func overflowSettled(_ reads: [ChurnRead]) -> Bool {
        let r = reads.suffix(2)
        guard r.count == 2, let a = r.first, let b = r.last else { return false }
        return a.hasChevron == b.hasChevron && a.overflow == b.overflow
    }
}

/// One element of MenuBarAgent's hosted tree on the strip (non-stale, width > 1), as read by one scan (of7).
public struct HostedEntry: Equatable, Sendable {
    /// Identifier, else description, else "" (identifier-less items).
    public var sig: String
    public var minX: CGFloat
    public var width: CGFloat
    /// Owner pid when the scanner attributed the element to an app item (join or prefix); nil for modules / agent-only /
    /// unattributed elements and for raw tree reads.
    public var ownerPID: pid_t?
    public init(sig: String, minX: CGFloat, width: CGFloat, ownerPID: pid_t? = nil) {
        self.sig = sig; self.minX = minX; self.width = width; self.ownerPID = ownerPID
    }
}

/// Element-level evidence that a live write hid (or restored) exactly a unit's hosted elements (of7). Counts alone are
/// coincidence-prone (another item vanishing while one appears); the ordered element sequence is not.
public enum HostedEvidence {
    static let widthTolerance: CGFloat = 2

    /// `after` is `before` minus exactly the elements owned by `unitPIDs`: nothing else vanished or appeared, in the same order.
    /// Elements the scanner attributed to no app (modules) must still be present and in place, but their width is not compared.
    public static func removedExactly(before: [HostedEntry], after: [HostedEntry], unitPIDs: Set<pid_t>) -> Bool {
        mismatch(before: before, after: after, unitPIDs: unitPIDs) == nil
    }

    /// nil when `after` is `before` minus exactly the unit's elements; otherwise a short description of the first difference.
    public static func mismatch(before: [HostedEntry], after: [HostedEntry], unitPIDs: Set<pid_t>) -> String? {
        let b = before.sorted { $0.minX < $1.minX }
        let removed = b.filter { $0.ownerPID.map(unitPIDs.contains) ?? false }
        guard !removed.isEmpty else { return "the unit owned no joined hosted element" }
        return sequenceMismatch(b.filter { !($0.ownerPID.map(unitPIDs.contains) ?? false) }, after)
    }

    /// `after` is `before` again (a reveal followed by the re-hide).
    public static func restored(before: [HostedEntry], after: [HostedEntry]) -> Bool { restoredMismatch(before: before, after: after) == nil }
    public static func restoredMismatch(before: [HostedEntry], after: [HostedEntry]) -> String? {
        sequenceMismatch(before.sorted { $0.minX < $1.minX }, after)
    }

    /// Widths are compared only for identifier-less elements: named items (iStat readouts) change width on their own, while
    /// an unnamed element is distinguishable from another one only by its width.
    private static func sequenceMismatch(_ expected: [HostedEntry], _ after: [HostedEntry]) -> String? {
        let a = after.sorted { $0.minX < $1.minX }
        guard expected.count == a.count else { return "\(a.count) elements, expected \(expected.count)" }
        for (i, (e, x)) in zip(expected, a).enumerated() {
            if e.sig != x.sig { return "element \(i) is '\(x.sig)' (w\(Int(x.width))), expected '\(e.sig)' (w\(Int(e.width)))" }
            if e.sig.isEmpty, e.ownerPID != nil || x.ownerPID != nil, abs(e.width - x.width) > widthTolerance {
                return "element \(i) unnamed width \(Int(x.width)), expected \(Int(e.width))"
            }
        }
        return nil
    }
}

public struct MenuBarSnapshot: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case items, capturedAt, hostedReadComplete }
    /// The hosted tree of this scan, left to right (set by the scanner; not serialized). nil on hand-built snapshots.
    public var hostedLayout: [HostedEntry]? = nil

    /// All items: on-bar left-to-right first, then parked.
    public var items: [MenuBarItem]
    public var capturedAt: Date
    /// Whether the agent's hosted tree was read completely (no failed reads or unnamed timeouts). Only a complete read can
    /// report a live-hidden item (docs/findings-live-trigger.md section 4). nil = not a full scan / unknown (treated as complete).
    public var hostedReadComplete: Bool?
    /// True when the read was incomplete ONLY because of self-positioning owners' stale items (see `ReadCompleteness`; set by
    /// the scanner, not serialized).
    public var incompleteOnlyForSelfPositioning = false
    /// Why a full scan is not `.complete` (nil when complete or unknown); for logs, `mbprobe list` and the live-verify trace.
    public var completenessReason: String?

    /// `hostedReadComplete` stays true only for `.complete` (compatibility); membership consumers use this level.
    public var completeness: ReadCompleteness {
        if hostedReadComplete != false { return .complete }
        return incompleteOnlyForSelfPositioning ? .completeExceptSelfPositioning : .incomplete
    }

    public init(items: [MenuBarItem], capturedAt: Date, hostedReadComplete: Bool? = nil, hostedLayout: [HostedEntry]? = nil,
                incompleteOnlyForSelfPositioning: Bool = false) {
        self.incompleteOnlyForSelfPositioning = incompleteOnlyForSelfPositioning
        self.hostedLayout = hostedLayout
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

    /// Indices (into `order`, the on-bar items left to right) that macOS overflowed: the FRESH items for which
    /// `SystemOverflowRule` holds against a FRESH chevron of the same read (gdu.69: left of / on the chevron, or stacked within
    /// its reach). Nothing else flags (gdu.45 corrective: coincidental identical frames on a normal bar and a chevron missed by
    /// a partial read must not cascade); a stale or absent chevron flags nothing.
    public static func indices(order: [Entry]) -> Set<Int> {
        guard let c = order.firstIndex(where: { $0.isChevron && !$0.stale }) else { return [] }
        let chevron = order[c].frame
        let fresh = order.indices.filter { $0 != c && !order[$0].isChevron && !order[$0].stale }
        let frames = fresh.map { order[$0].frame }
        return Set(fresh.filter { SystemOverflowRule.isOverflowed(order[$0].frame, chevron: chevron, hosted: frames) })
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

/// The Control Center modules whose hosted elements blink in and out of the agent's tree (gdu.86): Wi-Fi and Focus. ONE definition
/// shared by the poll signature (`AgreedScanObserver.defaultVolatileKeys`, e7t) and the scanner's missing-element rule
/// (`MenuBarScanner.readHosted`): a volatile module missing between two reads is not an incomplete read.
public enum VolatileModules {
    /// Store/module names of the volatile Control Center modules.
    public static let moduleNames: Set<String> = ["WiFi", "com.apple.menuextra.focusmode"]
    /// The signature's volatile keys: the modules plus the overflow chevron (its presence follows the bar's fill).
    public static let keys: Set<ItemKey> = Set(moduleNames.map { ItemKey.module(name: $0) }).union([.module(name: MenuBarItem.overflowChevronName)])
    /// Does a hosted element (identifier, else description) belong to a volatile module? Same normalisation as the resolver's
    /// module match (last identifier component, case/punctuation-insensitive).
    public static func matches(identifier: String, description: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var probes: [String] = []
        if !identifier.isEmpty { probes.append(norm(identifier.split(separator: ".").last.map(String.init) ?? identifier)) }
        if !description.isEmpty { probes.append(norm(description)) }
        let names = moduleNames.map { norm($0.split(separator: ".").last.map(String.init) ?? $0) }
        return probes.contains { !$0.isEmpty && names.contains($0) }
    }
}
