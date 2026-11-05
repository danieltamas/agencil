import Foundation

/// A consult sitting (docs/U33-SPEC.md): blind positions, an anonymous review of each other's positions, a synthesis
/// that may not leave a seat out, and a record of every position built from the answers themselves.
extension Broker {
    func consultRounds(_ s: SittingRun) throws {
        let seated = s.slots.filter { $0.phase == .pending }
        try sitRound(s, "blind", slots: seated) { _, seat in SittingPrompt.consultBlind(self.header(s, "blind", seat)) }
        let answered = s.locked { s.slots.filter { $0.phase == .answered && !$0.excluded && $0.blindConsult != nil } }
        // One random permutation per sitting: a label tells a seat nothing about who holds the position.
        let names = answered.map(\.seat.name).shuffled()
        let labels = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, "P\($0.offset + 1)") })
        s.locked { s.labels = labels }
        if s.council.rebuttal, answered.count >= 2, !s.isOver {
            let blind = s.locked { answered.compactMap { slot in slot.blindConsult.map { (seat: slot.seat.name, answer: $0) } } }
            s.locked { s.reviewRan = true }
            try sitRound(s, "rebuttal", slots: answered) { _, seat in
                let others = blind.filter { $0.seat != seat.name }.compactMap { entry in labels[entry.seat].map { (label: $0, answer: entry.answer) } }
                    .sorted { Int($0.label.dropFirst()) ?? 0 < Int($1.label.dropFirst()) ?? 0 }
                return SittingPrompt.consultReview(self.header(s, "rebuttal", seat), others: others)
            }
        }
    }

    /// The seats with a valid answer, in council order, with their blind and final answers.
    func consultAnswers(_ s: SittingRun) -> [(slot: Slot, blind: ConsultAnswer?, final: ConsultAnswer)] {
        s.locked {
            s.slots.compactMap { slot in
                guard slot.phase == .answered, !slot.excluded, let final = slot.finalConsult else { return nil }
                return (slot, slot.blindConsult, final)
            }
        }
    }

    /// Each review-round assessment of a position the seat was shown, resolved from its label to the seat; a seat's own
    /// label and a label it was not shown are dropped, and so is a second assessment of the same position.
    private func consultStances(_ s: SittingRun) -> [ConsultStance] {
        let seatOf = Dictionary(uniqueKeysWithValues: s.locked { s.labels }.map { ($0.value, $0.key) })
        var stances: [ConsultStance] = []
        for entry in consultAnswers(s) where entry.final.kept != nil {
            let seat = entry.slot.seat.name
            for item in entry.final.assessments {
                guard let about = seatOf[item.label], about != seat, !stances.contains(where: { $0.seat == seat && $0.about == about }) else { continue }
                stances.append(ConsultStance(seat: seat, about: about, stance: item.stance, why: item.why))
            }
        }
        return stances
    }

    func consultOutcome(_ s: SittingRun, synthesizerFailed: Bool?, noSynthesis: Bool) -> (ConsultOutcome, [ConsultStance]) {
        let stances = consultStances(s)
        let answers = consultAnswers(s).map { ConsultInput.Answer(seat: $0.slot.seat.name, vendor: $0.slot.seat.vendor, answer: $0.final) }
        let input = ConsultInput(convened: s.slots.filter { $0.phase != .recused }.count, quorum: s.council.quorum, answers: answers,
                                 reviewRan: s.locked { s.reviewRan }, stances: stances, conveneVendors: s.conveneVendors,
                                 fallbackUsed: s.fallbackUsed, synthesizerFailed: synthesizerFailed, noSynthesis: noSynthesis)
        return (ConsultVerdict.decide(input), stances)
    }

    func consultSynthesisPrompt(_ s: SittingRun, seat: Seat) -> String {
        let flags = consultOutcome(s, synthesizerFailed: nil, noSynthesis: false).0.flags
        let positions = consultAnswers(s).map { (seat: $0.slot.seat.name, blind: $0.blind, final: $0.final) }
        return SittingPrompt.consultSynthesis(header(s, "synthesis", seat), positions: positions, flags: flags)
    }

    /// The seats with a valid answer that a summary does not name, as the retry error; nil when it names them all.
    func consultLeftOut(_ s: SittingRun, summary: String) -> String? {
        let missing = consultAnswers(s).map(\.slot.seat.name).filter { name in
            let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_-])"
            return summary.range(of: pattern, options: .regularExpression) == nil
        }
        return missing.isEmpty ? nil : "the summary leaves out " + missing.joined(separator: ", ")
    }

    /// The verdict JSON of a consult sitting (docs/U33-SPEC.md item 11) and its ledger row.
    func consultRecord(_ s: SittingRun) -> (json: [String: Any], verdict: String, flags: [String], minority: [[String: String]]) {
        let (outcome, stances) = consultOutcome(s, synthesizerFailed: s.synthesizerFailed, noSynthesis: s.summary == nil)
        let labels = s.locked { s.labels }
        let answers = consultAnswers(s)
        let positions = answers.map { entry -> [String: Any] in
            let name = entry.slot.seat.name, final = entry.final
            var row: [String: Any] = [
                "seat": name, "vendor": entry.slot.seat.vendor, "label": labels[name] ?? "P1",
                "blind": ["position": (entry.blind ?? final).position, "confidence": (entry.blind ?? final).confidence],
                "final": ["position": final.position, "confidence": final.confidence, "reasoning": final.reasoning, "crux": final.crux],
                "kept": final.kept ?? true, "questions_back": final.questionsBack, "minority": outcome.minority.contains(name),
            ]
            if final.kept == false {
                row["because"] = final.because ?? ""
                row["new_evidence"] = final.newEvidence ?? false
            }
            return row
        }
        let minority = answers.filter { outcome.minority.contains($0.slot.seat.name) }
            .map { ["seat": $0.slot.seat.name, "vendor": $0.slot.seat.vendor, "position": $0.final.position] }
        let valid = Set(answers.map(\.slot.seat.name))
        var json: [String: Any] = [
            "sitting": s.id, "council": s.council.name, "state": "done", "mode": "consult", "verdict": outcome.verdict,
            "reasons": outcome.reasons, "snapshot": s.snapshot.id, "claims": [Any](), "independence": outcome.flags,
            "votes": votes(s).map { vote -> [String: Any] in
                ["seat": vote.seat, "vendor": vote.vendor, "state": vote.state.rawValue, "valid": valid.contains(vote.seat),
                 "reason": vote.reason ?? NSNull()]
            },
            "positions": positions,
            "assessments": stances.map { ["seat": $0.seat, "about": $0.about, "stance": $0.stance, "why": $0.why ?? ""] },
            "minority": minority,
        ]
        if let summary = s.summary {
            json["summary"] = summary
            json["summary_by"] = s.summaryBy
            if s.summaryFallback { json["summary_fallback"] = true }
        }
        return (json, outcome.verdict, outcome.flags, minority)
    }
}
