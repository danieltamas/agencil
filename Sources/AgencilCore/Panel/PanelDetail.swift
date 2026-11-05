import Foundation

/// What the `detail` op tells the panel about one thread (docs/AGENT-API.md "detail"). Decoding is lenient: this is
/// display only, and a missing field leaves a line out rather than hiding the whole screen.
public struct ThreadDetail: Sendable, Equatable {
    public struct Exchange: Sendable, Equatable {
        public let question: String
        public let answer: String?
        public let state: String
        public let reason: String?
        public let costUSD: Double?
        public let tokens: Int?
        public let tokensIn: Int?
        public let tokensOut: Int?
        /// "reported", "estimated" or "estimated, subscription"; nil when there is no cost.
        public let costNote: String?
    }

    public let exchanges: [Exchange]
    public let model: String?
    public let harness: String?
    public let project: String?

    public init(json: [String: Any]) {
        model = json["model"] as? String
        harness = json["harness"] as? String
        project = json["project"] as? String
        exchanges = (json["exchanges"] as? [[String: Any]] ?? []).map(Exchange.init(json:))
    }
}

extension ThreadDetail.Exchange {
    init(json: [String: Any]) {
        self.init(question: json["question"] as? String ?? "", answer: json["answer"] as? String, state: json["state"] as? String ?? "",
                  reason: json["reason"] as? String, costUSD: (json["cost_usd"] as? NSNumber)?.doubleValue,
                  tokens: (json["tokens"] as? NSNumber)?.intValue, tokensIn: (json["tokens_in"] as? NSNumber)?.intValue,
                  tokensOut: (json["tokens_out"] as? NSNumber)?.intValue, costNote: json["cost_note"] as? String)
    }
}

/// What the `detail` op tells the panel about one sitting: the brief, the verdict and every round's seat answers.
public struct SittingDetail: Sendable, Equatable {
    public struct Seat: Sendable, Equatable {
        public let name: String
        public let state: String
        public let answer: String?
        public let reason: String?
        public let started: Date?
        public let ended: Date?
        public let costUSD: Double?
        public let tokens: Int?
        public let tokensIn: Int?
        public let tokensOut: Int?
        public let costNote: String?
        public let model: String?
        public let harness: String?
    }

    public struct Round: Sendable, Equatable {
        public let name: String
        public let seats: [Seat]
    }

    public struct Vote: Sendable, Equatable {
        public let seat: String
        public let state: String
        public let vote: String?
    }

    public struct Claim: Sendable, Equatable {
        public let id: String
        public let seat: String
        public let severity: String
        public let place: String
        public let body: ClaimBody
        public let backers: [String]
        public let dissenters: [String]
        public let minority: Bool
        public let refuted: Bool
    }

    public let brief: String?
    public let project: String?
    public let changeKind: String?
    public let question: String?
    public let diffRange: String?
    public let repo: String?
    public let snapshot: String?
    public let rule: String?
    public let verdict: String?
    public let reasons: [String]
    public let reason: String?
    /// The council's written synthesis (Markdown), the seat that wrote it, and whether it did so for want of a synthesizer.
    public let summary: String?
    public let summaryBy: String?
    public let summaryFallback: Bool
    /// The owner's follow-ups to the council's seats, and the seats a new one may go to (docs/U30-SPEC.md).
    public struct Followup: Sendable, Equatable {
        public let seat: String
        public let thread: String
        public let model: String?
        public let harness: String?
        public let exchanges: [ThreadDetail.Exchange]
    }

    public let followups: [Followup]
    public let followUpSeats: [String]
    public let followUpDefault: String?
    /// One seat's stand in a consult sitting (docs/U33-SPEC.md): where it started, where it ended and whether it moved.
    public struct Position: Sendable, Equatable {
        public let seat: String
        public let vendor: String?
        public let blindPosition: String
        public let finalPosition: String
        public let confidence: Double?
        public let crux: String
        public let changed: Bool
        public let because: String?
        public let questionsBack: [String]
        public let minority: Bool
    }

    /// `review` or `consult`; a record from before modes existed is a review.
    public let mode: String
    public let positions: [Position]
    public let votes: [Vote]
    public let claims: [Claim]
    public let rounds: [Round]

    public init(json: [String: Any]) {
        summary = json["summary"] as? String
        summaryBy = json["summary_by"] as? String
        summaryFallback = json["summary_fallback"] as? Bool ?? false
        followups = (json["followups"] as? [[String: Any]] ?? []).map {
            Followup(seat: $0["seat"] as? String ?? "", thread: $0["thread"] as? String ?? "", model: $0["model"] as? String,
                     harness: $0["harness"] as? String, exchanges: ($0["exchanges"] as? [[String: Any]] ?? []).map(ThreadDetail.Exchange.init(json:)))
        }
        followUpSeats = json["follow_up_seats"] as? [String] ?? []
        followUpDefault = json["follow_up_default"] as? String
        brief = json["brief"] as? String
        project = json["project"] as? String
        changeKind = json["change_kind"] as? String
        question = json["question"] as? String
        diffRange = json["diff_range"] as? String
        repo = json["repo"] as? String
        snapshot = json["snapshot"] as? String
        reason = json["reason"] as? String
        let result = json["verdict"] as? [String: Any]
        verdict = result?["verdict"] as? String
        rule = result?["rule"] as? String
        reasons = result?["reasons"] as? [String] ?? []
        mode = result?["mode"] as? String ?? "review"
        positions = mode != "consult" ? [] : (result?["positions"] as? [[String: Any]] ?? []).map { row in
            let blind = row["blind"] as? [String: Any] ?? [:], final = row["final"] as? [String: Any] ?? [:]
            return Position(seat: row["seat"] as? String ?? "", vendor: row["vendor"] as? String,
                            blindPosition: blind["position"] as? String ?? "", finalPosition: final["position"] as? String ?? "",
                            confidence: (final["confidence"] as? NSNumber)?.doubleValue, crux: final["crux"] as? String ?? "",
                            changed: row["kept"] as? Bool == false, because: row["because"] as? String,
                            questionsBack: row["questions_back"] as? [String] ?? [], minority: row["minority"] as? Bool ?? false)
        }
        votes = (result?["votes"] as? [[String: Any]] ?? []).map {
            Vote(seat: $0["seat"] as? String ?? "", state: $0["state"] as? String ?? "", vote: $0["vote"] as? String)
        }
        claims = (result?["claims"] as? [[String: Any]] ?? []).map { row in
            let file = row["file"] as? String
            let place = file.map { "\($0):\((row["line"] as? NSNumber)?.intValue ?? 0)" } ?? ""
            let body = ClaimBody(text: row["evidence"] as? String ?? "", fix: row["fix"] as? String,
                                 confidence: (row["confidence"] as? NSNumber)?.doubleValue)
            return Claim(id: row["id"] as? String ?? "", seat: row["seat"] as? String ?? "", severity: row["severity"] as? String ?? "",
                         place: place, body: body, backers: row["backers"] as? [String] ?? [],
                         dissenters: row["dissenters"] as? [String] ?? [], minority: row["minority"] as? Bool ?? false,
                         refuted: row["refuted"] as? Bool ?? false)
        }
        let stamp = ISO8601DateFormatter()
        rounds = (json["rounds"] as? [[String: Any]] ?? []).map { round in
            Round(name: round["round"] as? String ?? "", seats: (round["seats"] as? [[String: Any]] ?? []).map {
                Seat(name: $0["seat"] as? String ?? "", state: $0["state"] as? String ?? "", answer: $0["answer"] as? String,
                     reason: $0["reason"] as? String, started: ($0["started"] as? String).flatMap(stamp.date),
                     ended: ($0["ended"] as? String).flatMap(stamp.date), costUSD: ($0["cost_usd"] as? NSNumber)?.doubleValue,
                     tokens: ($0["tokens"] as? NSNumber)?.intValue, tokensIn: ($0["tokens_in"] as? NSNumber)?.intValue,
                     tokensOut: ($0["tokens_out"] as? NSNumber)?.intValue, costNote: $0["cost_note"] as? String,
                     model: $0["model"] as? String, harness: $0["harness"] as? String)
            })
        }
    }
}
