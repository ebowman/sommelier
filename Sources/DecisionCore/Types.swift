// Value types mirroring lean/Sommelier/Model.lean, Truth.lean and Status.lean, name for name.
// This module runs the PROVED Lean code (see DecisionCore.swift); these types only carry data across the boundary.

/// A menu bar item. Identity is all the core needs.
public typealias Key = UInt32

/// Does the read show the « chevron? `stale` = carried from an earlier scan.
public enum ChevronRead: UInt32, Sendable, CaseIterable { case fresh, stale, absent }
/// How much of the agent's accessibility tree was read.
public enum ReadLevel: UInt32, Sendable, CaseIterable { case complete, exceptSelfPositioning, incomplete }
/// A pass read may plan; a quiet poll is evidence only.
public enum ReadKind: UInt32, Sendable, CaseIterable { case pass, poll }

/// One observation of the bar (Lean `Read`).
public struct Read: Equatable, Sendable {
    public var kind: ReadKind
    public var chevron: ChevronRead
    public var level: ReadLevel
    public var settled: Bool
    public var stripOpen: Bool
    public var drawn: [Key]
    public var pile: [Key]
    public var folded: [Key]
    public var trusted: [Key]
    public var nearFold: [Key]
    public var observed: Bool
    public var unread: [Key]
    public var notFullProven: Bool

    public init(kind: ReadKind, chevron: ChevronRead, level: ReadLevel, settled: Bool, stripOpen: Bool,
                drawn: [Key], pile: [Key], folded: [Key], trusted: [Key], nearFold: [Key],
                observed: Bool = true, unread: [Key] = [], notFullProven: Bool = false) {
        self.kind = kind; self.chevron = chevron; self.level = level; self.settled = settled; self.stripOpen = stripOpen
        self.drawn = drawn; self.pile = pile; self.folded = folded; self.trusted = trusted; self.nearFold = nearFold
        self.observed = observed; self.unread = unread; self.notFullProven = notFullProven
    }
}

/// The result of one drag. `refused`: the actuator declined it; `busy`: the user interrupted.
public enum Outcome: UInt32, Sendable, CaseIterable { case verified, failed, refused, busy }

/// Where a move puts its subject. The target is always a key, never a position.
public enum Rel: Equatable, Sendable {
    case before(Key)
    case after(Key)
}

/// What the core can be told (Lean `Event`).
public enum Event: Equatable, Sendable {
    case read(Read)
    case userEdit(record: [Key], moved: [Key])
    case userRetry
    case retryKey(Key)
    case moveResult(Key, Outcome, posted: Bool)
    case passBoundary
}

/// The only thing the core ever asks the world to do: ONE physical drag.
public struct Action: Equatable, Sendable {
    public var subject: Key
    public var rel: Rel
    public var strip: Bool
    public var user: Bool
    public init(subject: Key, rel: Rel, strip: Bool, user: Bool) {
        self.subject = subject; self.rel = rel; self.strip = strip; self.user = user
    }
}

/// Why the bar differs and nothing is happening (Lean `Why`). `needsReapply(k)`: the engine's planned move of `k` needs the strip (it or its target is near the fold) and waits for Re-apply (ejb.20).
public enum Why: Equatable, Sendable { case stopped, barFull, needsReapply(Key), plain }

/// The bottom line of the Arrange window (Lean `Status`).
public enum Status: Equatable, Sendable {
    case moving
    case matches
    case matchesExcept([Key])
    case differs(Why)
    case checking
}

/// The verdict of the record against a read (Lean `Verdict`).
public enum Verdict: Equatable, Sendable {
    case matches
    case matchesExcept([Key])
    case differs
    case cannotTell
}

/// What a record row shows (Lean `RowLine`).
public enum Row: Equatable, Sendable { case moving, waiting, tick, behind, notWherePut, notOnBar, cannotTell }

/// The note beside a row that says "not where you put it" (Lean `RowNote`). A row with no note is `nil` in `DecisionCore.rowNote`.
///
/// `needsReapply` is NOT a Lean `rowNote` code (the codec never decodes it): it is the row signal Lean defines as `rowReapply` (ejb.20), derived by the driver from the core status
/// `differs(needsReapply k)` and the row of `k` being `notWherePut`.
public enum RowNote: Equatable, Sendable { case noMoveHelps, cantJudge, noMoveHere, needsReapply }

/// The verdict on one key (Lean `RowVerdict`).
public enum RowVerdict: Equatable, Sendable { case inOrder, behindChevron, behindOutOfTurn, notOnBar, outOfPlace, cannotTell }

/// A section of the layout (Lean `Section`).
public enum LayoutSection3: UInt32, Sendable, CaseIterable { case visible, hidden, alwaysHidden }

/// The three ordered sections of the layout, as core keys (Lean `Layout3`).
public struct Layout3: Equatable, Sendable {
    public var visible: [Key]
    public var hidden: [Key]
    public var alwaysHidden: [Key]
    public init(visible: [Key], hidden: [Key], alwaysHidden: [Key]) { self.visible = visible; self.hidden = hidden; self.alwaysHidden = alwaysHidden }
}

/// What the user did to the layout (Lean `Gesture`). `index` is an insertion index in the section AFTER the lifted keys are removed (clamped by the core); `nil` appends
/// (Visible: before the trailing system block).
public enum LayoutGesture: Equatable, Sendable {
    case drop(Key, LayoutSection3, index: UInt32?)
    case hideNotFitting([Key])
}

/// Why a call into the proved core failed. A failure is NEVER answered with a default value.
public enum DecisionError: Error, Equatable, Sendable {
    /// The Lean side could not decode the input words (answer tag 1).
    case malformedInput
    /// The Lean side answered, but the answer is not one the Swift decoder knows (a version mismatch between Swift and Lean).
    case undecodableOutput
    /// The Lean runtime did not initialise.
    case runtimeUnavailable
}
