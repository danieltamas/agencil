import AgencilCore
import Foundation

/// Presentation values for the panel rows, built from a read. The row views take these, not the wire types.
extension DemoPanel.Thread {
    init(_ row: PanelData.Thread) {
        let state: String = switch row.state {
        case "asking": "asking"
        case "answered": "answered " + PanelFormat.duration(from: row.started, to: row.ended)
        default: "failed: " + (row.reason ?? "no reason given")
        }
        self.init(id: row.id, caller: row.caller, seat: row.seat, question: row.question, state: state,
                  live: row.state == "asking", failed: row.state == "failed")
    }
}

extension DemoPanel.Sitting {
    init(_ row: PanelData.Sitting) {
        self.init(id: row.id, kind: row.council, hue: PanelFormat.hue(row.council), target: "\(row.council) sitting \(row.no)",
                  wokenBy: "", state: row.state == "running" ? "Sitting" : row.verdict ?? row.state, seats: 0,
                  elapsed: PanelFormat.duration(from: row.started, to: row.ended), cost: PanelFormat.money(row.costUSD),
                  live: row.state == "running")
    }
}

extension DemoPanel.Finding {
    init(_ row: PanelData.Finding) {
        self.init(id: row.id, severity: row.severity.uppercased(), place: "\(row.file):\(row.line)", claim: row.body,
                  backers: row.backers, dissent: row.dissenters)
    }
}

extension DemoPanel.SeatRow {
    init(_ row: PanelData.SeatItem) {
        self.init(id: row.name, model: row.model, up: row.up, confirmed: "n=0, too few", coverage: "n=0, too few",
                  cost: "-", median: "-", overlap: row.up ? "no outcomes yet" : "not reachable", enough: false)
    }
}

enum PanelFormat {
    static func money(_ dollars: Double) -> String { String(format: "$%.2f", dollars) }

    static func duration(from start: Date, to end: Date?) -> String {
        let seconds = Int((end ?? Date()).timeIntervalSince(start))
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes)m \(seconds % 60)s" : "\(max(seconds, 0))s"
    }

    /// A council keeps one hue from the fixed set, the same every launch.
    static func hue(_ name: String) -> Int {
        name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 8 }
    }
}
