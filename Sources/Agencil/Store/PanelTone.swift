import Foundation

/// The one mapping from a state or severity to the signal that colours a card's bar, its glyph and its chip
/// (docs/DESIGN.md "State colour"). Rows never choose a colour themselves.
enum PanelTone {
    /// Thread, sitting and verdict states: running blue, finished green, failed red, stopped or unfinished orange.
    static func signal(state: String) -> Signal {
        switch state.lowercased() {
        case "asking", "running", "sitting", "pending", "deliberating": .running
        case "answered", "pass", "agreed", "done", "confirmed", "up": .ok
        case "failed", "block", "dismissed", "crit": .crit
        case "stopped", "incomplete", "busy", "needs you", "will_fix": .warn
        default: .unknown
        }
    }

    /// p0 and p1 are red, p2 orange, anything lower is neutral (the siblings colour only what needs attention).
    static func signal(severity: String) -> Signal {
        switch severity.lowercased() {
        case "p0", "p1": .crit
        case "p2": .warn
        default: .unknown
        }
    }
}
