import AgencilCore
import Foundation

/// One pushed detail screen of the panel, already in the words it shows. The store builds it from a row and, once
/// the broker's `detail` reply arrives, from that too; views only lay it out.
struct DetailPage: Equatable, Identifiable {
    enum Kind { case thread, sitting, finding }
    struct Fact: Equatable, Identifiable { let name: String; let value: String; var id: String { name } }
    struct Section: Equatable, Identifiable {
        let heading: String; let text: String; var tone: Signal?
        var id: String { heading + String(text.prefix(24)) }
    }
    struct Answer: Equatable, Identifiable {
        let seat: String; let meta: String; let text: String; let tone: Signal
        var vendor = ""; var structured: StructuredAnswer?
        var id: String { seat + meta + String(text.prefix(24)) }
    }
    struct Round: Equatable, Identifiable { let name: String; let answers: [Answer]; var id: String { name } }
    struct Turn: Equatable {
        let question: String; let answer: String; let meta: String; let tone: Signal
        /// The answer's blocks, for the kit to draw.
        var items: [MarkdownBlock.Item] { DetailPage.markdownItems(answer) }
    }
    struct Followup: Equatable, Identifiable { let seat: String; let vendor: String; let turns: [Turn]; var id: String { seat } }
    /// `writer` is the caption: who wrote it, and that no synthesizer was set when a council seat did.
    struct Synthesis: Equatable {
        let markdown: String
        let writer: String

        /// The blocks the kit draws.
        var items: [MarkdownBlock.Item] { DetailPage.markdownItems(markdown) }
    }

    /// The kit imports no logic, so the parsed blocks are handed over in its own type.
    static func markdownItems(_ markdown: String) -> [MarkdownBlock.Item] {
        MarkdownDocument.parse(markdown).map { block in
            switch block {
            case .heading(let level, let title): .heading(level, title)
            case .paragraph(let text): .paragraph(text)
            case .bullets(let items): .bullets(items)
            case .numbered(let items): .numbered(items)
            case .code(let text): .code(text)
            }
        }
    }

    static let unknown = "unknown"
    /// How many seats a follow-up picker shows as chips across the panel; more go in a menu.
    static let seatChipLimit = 3
    /// The card's cost slot when no seat reported a figure: the ledger holds none, and a $0.00 would be a guess.
    static let unknownCost = "cost unknown"

    let id: String
    let kind: Kind
    var title: String
    var state: String
    var tone: Signal
    var live = false
    var facts: [Fact] = []
    var sections: [Section] = []
    var seats: [Fact] = []
    /// The seat's model vendor, for the mark beside a thread's title; "" when unknown.
    var vendor = ""
    var brief: [Fact] = []
    /// What the council concluded, written by one seat once the sitting ended; nil until then or when none was written.
    var synthesis: Synthesis?
    /// The `Copy as Markdown` text of a sitting that has a synthesis.
    var recordMarkdown: String?
    /// What the owner asked the council's seats after it sat, per seat; and the seats a new question may go to.
    var followups: [Followup] = []
    var followUpSeats: [String] = []
    var followUpDefault: String?
    /// The composer shows once the sitting is over, its detail has loaded and there is a seat to ask.
    var canFollowUp = false
    var rounds: [Round] = []
    var claims: [DemoPanel.Finding] = []
    /// A consult sitting's seats and where each ended up, in the broker's order; empty for a review.
    var positions: [Position] = []
    var loading = false
    var problem: String?
}

extension DetailPage {
    struct Position: Equatable, Identifiable {
        let seat: String
        var vendor = ""
        let finalPosition: String
        let confidence: String?
        let crux: String
        let changed: Bool
        /// The seat's own reason for moving, shown with the position it started from.
        let change: String?
        let minority: Bool
        var id: String { seat }
    }

    static func positions(_ detail: SittingDetail, vendors: [String: String]) -> [Position] {
        detail.positions.map { stand in
            let change = stand.changed ? "was: " + stand.blindPosition + (stand.because.map { " - because " + $0 } ?? "") : nil
            return Position(seat: stand.seat, vendor: vendors[stand.seat] ?? stand.vendor ?? "", finalPosition: stand.finalPosition,
                            confidence: ClaimBody.percent(stand.confidence), crux: stand.crux, changed: stand.changed,
                            change: change, minority: stand.minority)
        }
    }
}

extension DetailPage {
    private static func fact(_ name: String, _ value: String?) -> Fact { Fact(name: name, value: value ?? unknown) }

    private static func tokens(_ count: Int?) -> String? {
        count.map { $0.formatted(.number.grouping(.automatic)) }
    }

    /// A cost that was worked out from a price list, or is not what a subscription bills, says so; the harness's own dollars do not.
    private static func costText(_ dollars: Double, notes: [String?]) -> String {
        let estimate = notes.compactMap { $0 }.first { $0 != "reported" }
        return PanelFormat.money(dollars) + (estimate.map { " (\($0))" } ?? "")
    }

    static func thread(_ row: PanelData.Thread, detail: ThreadDetail?, vendor: String = "") -> DetailPage {
        let card = DemoPanel.Thread(row)
        let word = row.state == "asking" ? "Asking" : row.state == "answered" ? "Answered" : card.status == "stopped" ? "Stopped" : "Failed"
        var page = DetailPage(id: row.id, kind: .thread, title: "\(row.caller) to \(row.seat)", state: word,
                              tone: PanelTone.signal(state: card.status), live: card.live)
        page.vendor = vendor
        let spent = detail?.exchanges.compactMap(\.costUSD).reduce(0, +)
        let tokenSum = detail?.exchanges.compactMap(\.tokens).reduce(0, +)
        let anyCost = detail?.exchanges.contains { $0.costUSD != nil } == true
        let anyTokens = detail?.exchanges.contains { $0.tokens != nil } == true
        let model = detail?.model.map { name in detail?.harness.map { "\(name) (\($0))" } ?? name }
        page.facts = [
            fact("Asked by", row.caller), fact("Project", detail?.project), fact("Seat", row.seat), fact("Model", model),
            Fact(name: "Response time", value: card.live ? "still running" : PanelFormat.duration(from: row.started, to: row.ended)),
            fact("Tokens", anyTokens ? tokens(tokenSum) : nil), fact("Cost", anyCost ? spent.map { costText($0, notes: detail?.exchanges.map(\.costNote) ?? []) } : nil),
        ]
        guard let detail, !detail.exchanges.isEmpty else {
            page.sections = [Section(heading: "Question", text: row.question)]
            if let reason = row.reason, row.state == "failed" { page.sections.append(Section(heading: "Why it failed", text: reason, tone: .crit)) }
            page.loading = detail == nil
            return page
        }
        for (index, exchange) in detail.exchanges.enumerated() {
            let number = detail.exchanges.count > 1 ? " \(index + 1)" : ""
            page.sections.append(Section(heading: "Question" + number, text: exchange.question))
            if let answer = exchange.answer { page.sections.append(Section(heading: "Answer" + number, text: ReadableAnswer.text(answer))) }
            if let reason = exchange.reason, exchange.state == "failed" { page.sections.append(Section(heading: "Why it failed", text: reason, tone: .crit)) }
        }
        return page
    }

    static func sitting(_ row: PanelData.Sitting, detail: SittingDetail?, vendors: [String: String] = [:]) -> DetailPage {
        let card = DemoPanel.Sitting(row)
        let state = row.state == "running" ? "Sitting" : row.verdict ?? (row.state == "failed" ? "Stopped" : row.state)
        var page = DetailPage(id: row.id, kind: .sitting, title: row.question ?? "\(row.council) sitting \(row.no)", state: state,
                              tone: PanelTone.signal(state: detail?.reason == "stopped" ? "stopped" : state), live: card.live)
        let reported = detail?.rounds.flatMap(\.seats).compactMap(\.costUSD)
        let spent = (reported?.isEmpty == false ? reported?.reduce(0, +) : nil) ?? (row.costUSD > 0 ? row.costUSD : nil)
        let allTokens = detail?.rounds.flatMap(\.seats).compactMap(\.tokens)
        page.facts = [
            fact("Project", detail?.project), fact("Repo", detail?.repo), fact("Change", detail?.changeKind), fact("Diff", detail?.diffRange),
            fact("Round", row.round), Fact(name: "Elapsed", value: PanelFormat.duration(from: row.started, to: row.ended)),
            fact("Tokens", allTokens?.isEmpty == false ? tokens(allTokens?.reduce(0, +)) : nil), fact("Cost", spent.map { costText($0, notes: detail?.rounds.flatMap(\.seats).map(\.costNote) ?? []) }),
            fact("Rule", detail?.rule), fact("Snapshot", detail?.snapshot),
        ]
        guard let detail else { page.loading = true; return page }
        if let summary = detail.summary {
            let by = detail.summaryBy ?? "a seat"
            page.synthesis = Synthesis(markdown: summary, writer: "written by " + by + (detail.summaryFallback ? ", no synthesizer is set" : ""))
            page.recordMarkdown = recordMarkdown(title: detail.question ?? row.question ?? page.title, verdict: detail.verdict ?? state, summary: summary,
                                                 finalAnswers: finalAnswers(of: detail))
        }
        if let brief = detail.brief {
            if let facts = BriefFacts.parse(brief) { page.brief = facts.map { Fact(name: $0.name, value: $0.value) } }
            else { page.sections.append(Section(heading: "Brief", text: brief)) }
        }
        if !detail.reasons.isEmpty {
            page.sections.append(Section(heading: "Verdict: \(detail.verdict ?? state)", text: detail.reasons.map { "- " + $0 }.joined(separator: "\n"), tone: page.tone))
        }
        if let reason = detail.reason { page.sections.append(Section(heading: "Why it ended", text: reason, tone: page.tone)) }
        page.positions = positions(detail, vendors: vendors)
        // A consult seat casts no vote: its row shows the confidence it ended on.
        let confidence = Dictionary(page.positions.map { ($0.seat, $0.confidence) }, uniquingKeysWith: { first, _ in first })
        page.seats = detail.votes.map { Fact(name: $0.seat, value: (confidence[$0.seat] ?? nil) ?? $0.vote ?? $0.state) }
        page.rounds = detail.rounds.map { round in
            // The ledger names a consult's second round rebuttal; to the owner it is the review of the other positions.
            let name = detail.mode == "consult" && round.name == "rebuttal" ? "review" : round.name
            return Round(name: String(name.prefix(1).uppercased() + name.dropFirst()), answers: round.seats.map { answer(round: $0, vendor: vendors[$0.name] ?? "") })
        }
        page.claims = detail.claims.map { claim in
            DemoPanel.Finding(id: claim.id, severity: claim.severity.uppercased(), place: claim.place, claim: claim.body.text,
                              backers: claim.backers.count, dissent: claim.dissenters.count, fix: claim.body.fix,
                              confidence: claim.body.confidence, voices: voices(claim))
        }
        page.followups = detail.followups.map { followup in
            Followup(seat: followup.seat, vendor: vendors[followup.seat] ?? "", turns: followup.exchanges.map { turn(followup, $0) })
        }
        page.followUpSeats = detail.followUpSeats
        page.followUpDefault = detail.followUpDefault
        page.canFollowUp = row.state != "running" && !detail.followUpSeats.isEmpty
        if detail.followups.contains(where: { $0.exchanges.contains { $0.state == "asking" } }) { page.live = true }
        return page
    }

    static func finding(_ finding: DemoPanel.Finding) -> DetailPage {
        var page = DetailPage(id: finding.id, kind: .finding, title: finding.place, state: finding.severity,
                              tone: PanelTone.signal(severity: finding.severity))
        page.facts = [fact("Confidence", finding.confidence), Fact(name: "Backers", value: "\(finding.backers)"),
                      Fact(name: "Dissent", value: "\(finding.dissent)")]
        page.sections = [Section(heading: "Claim", text: finding.claim)]
        if let fix = finding.fix { page.sections.append(Section(heading: "Fix", text: fix)) }
        return page
    }

    private static func turn(_ followup: SittingDetail.Followup, _ exchange: ThreadDetail.Exchange) -> Turn {
        let model = followup.model.map { name in followup.harness.map { "\(name) (\($0))" } ?? name }
        let meta = [model, exchange.costUSD.map { costText($0, notes: [exchange.costNote]) }, tokens(exchange.tokens).map { "\($0) tokens" }]
            .compactMap { $0 }.joined(separator: " - ")
        let text = exchange.answer ?? exchange.reason ?? (exchange.state == "asking" ? "Thinking..." : "No answer recorded.")
        return Turn(question: exchange.question, answer: text, meta: meta.isEmpty ? exchange.state : meta, tone: PanelTone.signal(state: exchange.state))
    }

    /// Each seat's last answer, in the order the seats first appear; a seat that failed a later round keeps its earlier one.
    private static func finalAnswers(of detail: SittingDetail) -> [(seat: String, text: String)] {
        var order: [String] = [], latest: [String: String] = [:]
        for seat in detail.rounds.filter({ $0.name != "synthesis" }).flatMap(\.seats) {
            if !order.contains(seat.name) { order.append(seat.name) }
            if let answer = seat.answer { latest[seat.name] = ReadableAnswer.text(answer) }
        }
        return order.compactMap { name in latest[name].map { (seat: name, text: $0) } }
    }

    private static func recordMarkdown(title: String, verdict: String, summary: String, finalAnswers: [(seat: String, text: String)]) -> String {
        var out = "# \(title)\n\n**Verdict:** \(verdict)\n\n## Synthesis\n\n\(summary)\n\n## Seats\n"
        for answer in finalAnswers { out += "\n### \(answer.seat)\n\n\(answer.text)\n" }
        return out
    }

    private static func answer(round seat: SittingDetail.Seat, vendor: String) -> Answer {
        let elapsed = seat.started.map { PanelFormat.duration(from: $0, to: seat.ended) }
        let model = seat.model.map { name in seat.harness.map { "\(name) (\($0))" } ?? name }
        let meta = [model, elapsed, seat.costUSD.map { costText($0, notes: [seat.costNote]) }, tokens(seat.tokens).map { "\($0) tokens" }]
            .compactMap { $0 }.joined(separator: " - ")
        let text = seat.answer.map(ReadableAnswer.text) ?? seat.reason ?? (seat.state == "asking" ? "Thinking..." : "No answer recorded.")
        return Answer(seat: seat.name, meta: meta.isEmpty ? seat.state : meta, text: text, tone: PanelTone.signal(state: seat.state),
                      vendor: vendor, structured: seat.answer.flatMap { StructuredAnswer($0) })
    }

    private static func voices(_ claim: SittingDetail.Claim) -> String {
        var parts = ["raised by \(claim.seat)"]
        if !claim.backers.isEmpty { parts.append("backed by " + claim.backers.joined(separator: ", ")) }
        if !claim.dissenters.isEmpty { parts.append("disputed by " + claim.dissenters.joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }
}
