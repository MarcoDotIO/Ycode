import Foundation

// B4-POLISH (1.0.0-beta.4, council round 11): rules both IDEs draw from,
// so the macOS IDE (`YcodeUI`) and the Linux IDE (`ycode-ide`) behave one
// to one.

/// What the title area's icon shows (`BuildRingProgress`, rows 212 and
/// 236): the build ring while an action runs, Ycode's mark otherwise. While
/// the debugger is paused nothing is in progress, so the title area is
/// static: the mark, with "Paused <product>" under the title (the reference
/// shows no activity indicator there while paused).
public enum TitleAreaIcon: Equatable, Sendable {
    case mark
    case ring

    public static func shown(busy: Bool, paused: Bool) -> TitleAreaIcon { busy && !paused ? .ring : .mark }
}
