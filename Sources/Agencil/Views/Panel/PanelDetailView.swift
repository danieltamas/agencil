import SwiftUI

/// A pushed detail screen inside the panel: a back chip, what the card is, then the whole record, scrollable.
struct PanelDetailView: View {
    let page: DetailPage
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                ChipButton(title: "Back", symbol: "chevron.left", action: back)
                Spacer(minLength: 0)
                Chip(text: page.state, color: Theme.color(for: page.tone))
            }
            HStack(spacing: Space.m) {
                if !page.vendor.isEmpty { VendorMark(vendor: page.vendor) }
                Text(page.title).font(.house.header).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let problem = page.problem { ProblemText(text: problem) }
                    if page.loading { WaitingState(title: "Reading the record...") }
                    factsCard(page.facts)
                    if !page.brief.isEmpty { VStack(alignment: .leading, spacing: Space.xs) { Eyebrow(text: "Brief"); factsCard(page.brief) } }
                    ForEach(page.sections) { section in block(section) }
                    if !page.seats.isEmpty { seats }
                    ForEach(page.rounds) { round in roundView(round) }
                    if !page.claims.isEmpty { claims }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private func factsCard(_ facts: [DetailPage.Fact]) -> some View {
        if !facts.isEmpty {
            HoverCard(accent: nil, action: nil) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(facts) { fact in
                        HStack(alignment: .top, spacing: Space.m) {
                            Text(fact.name).font(.house.meta).foregroundStyle(Theme.textTertiary).frame(width: Size.detailLabel, alignment: .leading)
                            Text(fact.value).font(.house.meta)
                                .foregroundStyle(fact.value == DetailPage.unknown ? Theme.textTertiary : Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func block(_ section: DetailPage.Section) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: section.heading, color: section.tone.map(Theme.color(for:)) ?? Theme.textTertiary)
            Text(styled(section.text)).font(.house.body)
                .foregroundStyle(section.tone == .crit ? Theme.crit : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var seats: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: "Seats")
            ForEach(page.seats) { seat in
                HStack(spacing: Space.m) {
                    Text(seat.name).font(.house.body).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(seat.value).font(.house.meta).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func roundView(_ round: DetailPage.Round) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Eyebrow(text: round.name + " round")
            ForEach(round.answers) { answer in
                HoverCard(accent: Theme.color(for: answer.tone), action: nil) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            VendorMark(vendor: answer.vendor)
                            Text(answer.seat).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                        }
                        Text(answer.meta).font(.house.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if let structured = answer.structured { AnswerBody(answer: structured) }
                        else {
                            Text(styled(answer.text)).font(.house.body).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var claims: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Eyebrow(text: "Claims")
            ForEach(page.claims) { FindingRow(finding: $0) }
        }
    }

    /// Answers are mostly prose with the odd `code` or **bold**; inline markdown, whitespace kept.
    private func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
