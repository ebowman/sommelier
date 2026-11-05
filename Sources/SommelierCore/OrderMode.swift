import Foundation

/// Who owns the left-to-right ORDER of the real menu bar (persisted on `Layout`, sommelier-8z5).
///
/// - `macOSOwns` (default; the migration target for every layout written before this field existed): the engine never plans or
///   performs an order move (no synthesized Command-drags). It manages membership only (hide/show/reveal). `Layout.placed` keys
///   stay recorded but are inert: the placement is remembered, not enforced.
/// - `placedOnly`: the gdu.89 semantics. Only the keys the user placed in Arrange (`Layout.placed`) are ordered on the real bar;
///   every other visible key follows whatever order macOS gives it.
///
/// The engine behaviour for the modes is enforced in sommelier-8z5.2; this type only carries the choice.
public enum OrderMode: String, Codable, Sendable, CaseIterable { case macOSOwns, placedOnly }
