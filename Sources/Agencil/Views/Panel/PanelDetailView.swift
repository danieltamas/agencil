import AgencilCore
import SwiftUI

/// A pushed detail screen inside the panel: a back chip, what the card is, then the whole record, scrollable.
struct PanelDetailView: View {
    let page: DetailPage
    let store: PanelStore
    let back: () -> Void
    @State private var copied = false
    @State private var linkCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                ChipButton(title: "Back", symbol: "chevron.left", action: back)
                Spacer(minLength: 0)
                if let link = SittingLink.link(for: page.id) {
                    IconButton(symbol: linkCopied ? "checkmark" : "link", help: "Copy an agencil:// link another agent can open") {
                        Clipboard.copy(link)
                        linkCopied = true
                    }
                }
                if let record = page.recordMarkdown {
                    ChipButton(title: copied ? "Copied" : "Copy as Markdown", symbol: copied ? "checkmark" : "doc.on.doc") {
                        Clipboard.copy(record)
                        copied = true
                    }
                }
                Chip(text: page.state, color: Theme.color(for: page.tone))
            }
            HStack(spacing: Space.m) {
                if !page.vendor.isEmpty { VendorMark(vendor: page.vendor) }
                Text(page.title).font(.house.header).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                // Lazy: a sitting with many long answers lays out what is on screen, not the whole record.
                LazyVStack(alignment: .leading, spacing: Space.l) {
                    if let problem = page.problem { ProblemText(text: problem) }
                    if page.loading { WaitingState(title: "Reading the record...") }
                    if let synthesis = page.synthesis { synthesisBlock(synthesis) }
                    if !page.positions.isEmpty { positions }
                    factsCard(page.facts)
                    if !page.brief.isEmpty { VStack(alignment: .leading, spacing: Space.xs) { Eyebrow(text: "Brief"); factsCard(page.brief) } }
                    ForEach(page.sections) { section in block(section) }
                    if !page.seats.isEmpty { seats }
                    ForEach(page.rounds) { round in roundView(round) }
                    if !page.claims.isEmpty { claims }
                    if page.kind == .sitting { FollowUpView(page: page, store: store) }
                }
            }
            .scrollIndicators(.hidden)
            if page.kind == .sitting { FollowUpComposer(page: page, store: store) }
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

    private func synthesisBlock(_ synthesis: DetailPage.Synthesis) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: "Synthesis")
            HoverCard(accent: Theme.color(for: page.tone), action: nil) {
                VStack(alignment: .leading, spacing: Space.s) {
                    MarkdownBlock(items: synthesis.items)
                    Text(synthesis.writer).font(.house.meta).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// Each consult seat's final position, kept apart: whether it moved and whether most others disagree with it.
    private var positions: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Eyebrow(text: "Positions (\(page.positions.count))")
            ForEach(page.positions) { stand in
                HoverCard(accent: stand.minority ? Theme.warn : nil, action: nil) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            VendorMark(vendor: stand.vendor)
                            Text(stand.seat).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer(minLength: 0)
                            if stand.changed { Chip(text: "changed", color: Theme.unknown) }
                            if stand.minority { Chip(text: "minority", color: Theme.warn) }
                            if let confidence = stand.confidence { Text(confidence).font(.house.meta).foregroundStyle(Theme.textTertiary) }
                        }
                        Text(stand.finalPosition).font(.house.body).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let change = stand.change {
                            Text(change).font(.house.meta).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if !stand.crux.isEmpty {
                            LongText(text: "Would change it: " + stand.crux, color: Theme.textSecondary, blocks: DetailPage.markdownItems)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func block(_ section: DetailPage.Section) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: section.heading, color: section.tone.map(Theme.color(for:)) ?? Theme.textTertiary)
            LongText(text: section.text, color: section.tone == .crit ? Theme.crit : Theme.textPrimary, blocks: DetailPage.markdownItems)
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
                        else { LongText(text: answer.text, blocks: DetailPage.markdownItems) }
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
}
