import Foundation

/// What the bento's big tile shows (docs/U8-SPEC.md "Bento").
public enum Bento: Equatable, Sendable {
    case firstStep
    case council(sitting: String)
    case needsYou(count: Int, findings: Int, proposals: Int, stopped: Int)
}

public enum PanelModel {
    private static let recent: TimeInterval = 24 * 3600

    /// `seen` holds the sitting ids the owner has opened; only unseen stopped sittings of the last 24 hours count.
    public static func bento(_ data: PanelData, seen: Set<String>, now: Date) -> Bento {
        guard data.configured else { return .firstStep }
        if let live = data.sittings.filter({ $0.state == "running" }).max(by: { $0.started < $1.started }) {
            return .council(sitting: live.id)
        }
        let findings = data.findings.filter { $0.disposition == "open" }.count
        let stopped = data.sittings.filter {
            ["INCOMPLETE", "failed"].contains($0.state) && !seen.contains($0.id) && now.timeIntervalSince($0.started) <= recent
        }.count
        return .needsYou(count: findings + data.proposalsPending + stopped, findings: findings,
                         proposals: data.proposalsPending, stopped: stopped)
    }
}
