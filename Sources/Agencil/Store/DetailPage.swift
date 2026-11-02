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

    static let unknown = "unknown"
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
    var rounds: [Round] = []
    var claims: [DemoPanel.Finding] = []
    var loading = false
    var problem: String?
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
        if let brief = detail.brief {
            if let facts = BriefFacts.parse(brief) { page.brief = facts.map { Fact(name: $0.name, value: $0.value) } }
            else { page.sections.append(Section(heading: "Brief", text: brief)) }
        }
        if !detail.reasons.isEmpty {
            page.sections.append(Section(heading: "Verdict: \(detail.verdict ?? state)", text: detail.reasons.map { "- " + $0 }.joined(separator: "\n"), tone: page.tone))
        }
        if let reason = detail.reason { page.sections.append(Section(heading: "Why it ended", text: reason, tone: page.tone)) }
        page.seats = detail.votes.map { Fact(name: $0.seat, value: $0.vote ?? $0.state) }
        page.rounds = detail.rounds.map { round in
            Round(name: String(round.name.prefix(1).uppercased() + round.name.dropFirst()), answers: round.seats.map { answer(round: $0, vendor: vendors[$0.name] ?? "") })
        }
        page.claims = detail.claims.map { claim in
            DemoPanel.Finding(id: claim.id, severity: claim.severity.uppercased(), place: claim.place, claim: claim.body.text,
                              backers: claim.backers.count, dissent: claim.dissenters.count, fix: claim.body.fix,
                              confidence: claim.body.confidence, voices: voices(claim))
        }
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
