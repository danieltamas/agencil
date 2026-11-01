import AgencilCore
import SwiftUI

/// A seat's answer laid out as the structure it is: the vote, the claims it raised, what it thinks of the others'
/// claims, and its notes. Empty parts are not drawn.
struct AnswerBody: View {
    let answer: StructuredAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let vote = answer.vote { voteRow(vote) }
            if !answer.claims.isEmpty {
                section("Claims", count: answer.claims.count) {
                    ForEach(answer.claims) { claim in claimRow(claim) }
                }
            }
            if !answer.assessments.isEmpty {
                section("Assessments", count: answer.assessments.count) {
                    ForEach(answer.assessments) { assessment in assessmentRow(assessment) }
                }
            }
            if let notes = answer.notes {
                section("Notes", count: nil) {
                    Text(notes).font(.house.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private func voteRow(_ vote: String) -> some View {
        HStack(spacing: Space.s) {
            Text("Vote").font(.house.meta).foregroundStyle(Theme.textTertiary)
            Chip(text: vote, color: vote == "approve" ? Theme.ok : vote == "block" ? Theme.crit : Theme.unknown)
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Eyebrow(text: count.map { "\(title) (\($0))" } ?? title)
            content()
        }
    }

    private func claimRow(_ claim: StructuredAnswer.Claim) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Chip(text: claim.severity, color: Theme.color(for: PanelTone.signal(severity: claim.severity)))
                if let place = claim.place { Text(place).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                Spacer(minLength: 0)
                if let confidence = claim.body.confidence { Text(confidence).font(.house.meta).foregroundStyle(Theme.textTertiary) }
            }
            Text(claim.body.text).font(.house.body).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let fix = claim.body.fix {
                Text("Fix: " + fix).font(.house.meta).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assessmentRow(_ assessment: StructuredAnswer.Assessment) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Chip(text: assessment.stance, color: Theme.color(for: stanceSignal(assessment.stance)))
                Text(assessment.claim).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let why = assessment.why {
                Text(why).font(.house.meta).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stanceSignal(_ stance: String) -> Signal {
        switch stance {
        case "support": .ok
        case "dispute": .crit
        default: .unknown
        }
    }
}
