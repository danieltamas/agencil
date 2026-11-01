import Testing
@testable import Agencil

/// docs/DESIGN.md "State colour": one mapping from a state or severity to the signal, so no card picks its own colour.
@Suite struct PanelToneTests {
    @Test func finishedStatesAreOk() {
        for state in ["answered", "PASS", "pass", "done", "confirmed", "up"] {
            #expect(PanelTone.signal(state: state) == .ok, "\(state)")
        }
    }

    @Test func liveStatesAreRunning() {
        for state in ["asking", "running", "Sitting", "pending", "deliberating"] {
            #expect(PanelTone.signal(state: state) == .running, "\(state)")
        }
    }

    @Test func faultsAreCritical() {
        for state in ["failed", "BLOCK", "block", "dismissed", "crit"] {
            #expect(PanelTone.signal(state: state) == .crit, "\(state)")
        }
    }

    @Test func stoppedAndUnfinishedAreWarningsNotFaults() {
        for state in ["stopped", "incomplete", "INCOMPLETE", "busy", "will_fix"] {
            #expect(PanelTone.signal(state: state) == .warn, "\(state)")
        }
    }

    @Test func anUnknownStateIsNeutralNeverGreenOrRed() {
        for state in ["", "banana", "answered-ish", " pass"] {
            #expect(PanelTone.signal(state: state) == .unknown, "\(state)")
        }
    }

    @Test func severityP0AndP1AreRedP2IsOrangeLowerIsNeutral() {
        #expect(PanelTone.signal(severity: "p0") == .crit)
        #expect(PanelTone.signal(severity: "P1") == .crit)
        #expect(PanelTone.signal(severity: "p2") == .warn)
        #expect(PanelTone.signal(severity: "P2") == .warn)
        for severity in ["p3", "P3", "", "note"] { #expect(PanelTone.signal(severity: severity) == .unknown, "\(severity)") }
    }

    @Test func everyDocumentedCardStateHasAColour() {
        // No documented state may fall through to neutral by a typo in the table.
        let documented = ["asking", "answered", "failed", "stopped", "running", "PASS", "BLOCK", "INCOMPLETE"]
        for state in documented { #expect(PanelTone.signal(state: state) != .unknown, "\(state)") }
    }
}
