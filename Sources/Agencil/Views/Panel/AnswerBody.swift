import AgencilCore
import SwiftUI

/// A seat's answer laid out as the structure it is: the vote, the claims it raised, what it thinks of the others'
/// claims, and its notes. Empty parts are not drawn.
struct AnswerBody: View {
    let answer: StructuredAnswer

    var body: some View {
        if let consult = answer.consult { consultBody(consult) } else { reviewBody }
    }

    private var reviewBody: some View {
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

    /// A consult answer: the position first, then why, what would change it, what it asks back and how it read the others.
    private func consultBody(_ consult: StructuredAnswer.Consult) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(consult.position).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
                if let confidence = consult.confidence { Text(confidence).font(.house.meta).foregroundStyle(Theme.textTertiary) }
            }
            if let change = consult.change { prose("Changed: " + change, secondary: true) }
            if !consult.reasoning.isEmpty {
                section("Reasoning", count: nil) { LongText(text: consult.reasoning, blocks: DetailPage.markdownItems) }
            }
            if !consult.crux.isEmpty { section("Would change it", count: nil) { prose(consult.crux, secondary: false) } }
            if !consult.questionsBack.isEmpty {
                section("Questions back", count: consult.questionsBack.count) {
                    ForEach(Array(consult.questionsBack.enumerated()), id: \.offset) { _, question in prose(question, secondary: false) }
                }
            }
            if !consult.assessments.isEmpty {
                section("Assessments", count: consult.assessments.count) {
                    ForEach(consult.assessments) { assessment in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(spacing: Space.s) {
                                Chip(text: assessment.stance, color: Theme.color(for: consultStanceSignal(assessment.stance)))
                                Text(assessment.label).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            if let why = assessment.why { prose(why, secondary: true) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func prose(_ text: String, secondary: Bool) -> some View {
        Text(text).font(.house.meta).foregroundStyle(secondary ? Theme.textSecondary : Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func consultStanceSignal(_ stance: String) -> Signal {
        switch stance {
        case "agree": .ok
        case "disagree": .crit
        case "partly": .warn
        default: .unknown
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
