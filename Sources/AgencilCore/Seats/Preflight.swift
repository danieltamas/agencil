import Foundation

/// Why a seat can or cannot sit right now (docs/U25-SPEC.md "Preflight"): a closed set, so every caller and the
/// panel speak the same words. Anything a probe says that matches no row is `error`, never `ok`.
public enum PreflightReason: String, Sendable, CaseIterable {
    case ok, notInstalled = "not_installed", notLoggedIn = "not_logged_in", usageLimit = "usage_limit",
         noCredit = "no_credit", modelUnavailable = "model_unavailable", busy, unreachable, timeout, error

    /// The reason behind a `Resolver.usable` failure.
    static func unusable(_ reason: String) -> PreflightReason {
        let text = reason.lowercased()
        if text.contains("not installed") || text.contains("could not be probed") || text.contains("outside the pin") { return .notInstalled }
        if text.contains("signed in") || text.contains("sign-in") { return .notLoggedIn }
        if text.hasSuffix(" down") { return .unreachable }
        if text.contains("not loaded") { return .modelUnavailable }
        return PreflightClassifier.reason(in: reason) ?? .error
    }

    /// The words the panel shows.
    public var standing: String {
        switch self {
        case .ok: "ok"
        case .notInstalled: "not installed"
        case .notLoggedIn: "not logged in"
        case .usageLimit: "usage limit"
        case .noCredit: "no credit"
        case .modelUnavailable: "model gone"
        case .busy: "busy"
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .error: "error"
        }
    }
}

/// One probe's result as the ledger keeps it.
public struct PreflightStanding: Equatable, Sendable {
    public let seat: String
    public let harness: String
    public let model: String
    public let plan: String
    public let reason: PreflightReason
    public let detail: String
    /// The reset text a usage limit came with (`try again at Oct 9`), verbatim after sanitizing.
    public let until: String?
    public let probedAt: Date

    /// The panel line: the reason's words, with the reset time when the harness gave one.
    public var display: String {
        if reason == .usageLimit, let until { return "usage limit until \(until)" }
        return reason.standing
    }

    /// `<reason>[ until <text>]`, as refusals spell it.
    public var summary: String { reason.rawValue + (until.map { " until \($0)" } ?? "") }

    /// The reason as a resolver failure reads it.
    public var failure: String { "\(seat) preflight: \(summary)" }
}

/// Maps what a harness printed to a reason. The order is the spec's: a subscription limit is read before a credit
/// problem because codex's limit text also says "purchase more credits".
enum PreflightClassifier {
    static let patterns: [(PreflightReason, [String])] = [
        (.usageLimit, ["usage limit", "rate limit", "rate-limit", "too many requests", "try again at", "try again in", "quota exceeded"]),
        (.noCredit, ["insufficient balance", "insufficient_quota", "insufficient credit", "purchase more credits", "payment required", "billing"]),
        (.notLoggedIn, ["not logged in", "unauthorized", "please log in", "login required", "invalid api key", "authentication"]),
        (.modelUnavailable, ["unexpected server error", "unknown model", "no such model", "does not exist", "not supported"]),
        (.busy, ["database is locked"]),
        (.unreachable, ["could not connect", "connection refused", "econnrefused", "enotfound", "getaddrinfo", "network is unreachable",
                        "fetch failed", "502", "503", "overloaded"]),
    ]
    private static let modelMissing = try! NSRegularExpression(pattern: #"model\b.{0,40}?\bnot (found|available|offered)"#, options: [.caseInsensitive])
    private static let resetTime = try! NSRegularExpression(pattern: #"try again at ([^.\n]{1,60})"#, options: [.caseInsensitive])
    static let detailLimit = 200

    /// The reason the output names, else nil (the exit status then decides between `ok` and `error`).
    static func reason(in output: String) -> PreflightReason? {
        let text = output.lowercased()
        for (reason, needles) in patterns where needles.contains(where: text.contains) { return reason }
        if modelMissing.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil { return .modelUnavailable }
        return nil
    }

    static func until(in output: String) -> String? {
        guard let match = resetTime.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return clean(String(output[range]), limit: 60)
    }

    /// Exit status and output to a reason. Any failure the output names wins, whatever the exit status; `ok` needs
    /// exit 0 and the expected reply (`OK`, punctuation and case aside). Anything else is `error`, never `ok`.
    static func classify(status: Int32, output: String, answer: String) -> (PreflightReason, String) {
        if let named = reason(in: output + "\n" + answer) { return (named, clean(output)) }
        guard status == 0 else { return (.error, clean(output.isEmpty ? "exit \(status)" : output)) }
        guard !answer.isEmpty else { return (.error, clean(output.isEmpty ? "answered nothing" : output)) }
        return isExpectedReply(answer) ? (.ok, "") : (.error, clean("unexpected reply: " + answer))
    }

    static func isExpectedReply(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased() == "ok"
    }

    /// Stored and shown text: no terminal escapes, no credential-looking run, one line, bounded.
    static func clean(_ text: String, limit: Int = detailLimit) -> String {
        let flat = Redaction.scrubbed(Redaction.sanitizeText(text)).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " | ")
        return String(flat.suffix(limit))
    }
}

/// The `preflights` rows: appended per probe, read as the latest per seat.
struct PreflightStore: Sendable {
    static let lifetime: TimeInterval = 600
    let ledger: Ledger
    private static var clock: ISO8601DateFormatter { ISO8601DateFormatter() }

    func record(_ standing: PreflightStanding) throws {
        try ledger.locked {
            try ledger.run("""
                INSERT INTO preflights (id, seat, harness, model, plan, reason, detail, until, probed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [SittingStore.newID("pf_"), standing.seat, standing.harness, standing.model, standing.plan, standing.reason.rawValue,
                      standing.detail, standing.until, Self.clock.string(from: standing.probedAt)])
        }
    }

    /// The newest row of the seat, whatever its age or model. `insideLock` is for a caller that already holds the ledger.
    func latest(seat: String, insideLock: Bool = false) throws -> PreflightStanding? {
        let read = {
            try ledger.query("""
                SELECT seat, harness, model, plan, reason, detail, until, probed_at FROM preflights WHERE seat = ?
                ORDER BY probed_at DESC, rowid DESC LIMIT 1;
                """, [seat]) { row in
                PreflightStanding(seat: Ledger.text(row, 0) ?? "", harness: Ledger.text(row, 1) ?? "", model: Ledger.text(row, 2) ?? "",
                                  plan: Ledger.text(row, 3) ?? "", reason: PreflightReason(rawValue: Ledger.text(row, 4) ?? "") ?? .error,
                                  detail: Ledger.text(row, 5) ?? "", until: Ledger.text(row, 6),
                                  probedAt: Ledger.text(row, 7).flatMap(Self.clock.date) ?? .distantPast)
            }.first
        }
        return insideLock ? try read() : try ledger.locked(read)
    }

    /// The standing of `seat` while it is fresh and still describes the configured harness and model.
    func fresh(_ seat: Seat, now: Date = Date(), insideLock: Bool = false) throws -> PreflightStanding? {
        guard let standing = try latest(seat: seat.name, insideLock: insideLock), standing.harness == seat.harness,
              standing.model == seat.model, now.timeIntervalSince(standing.probedAt) < Self.lifetime else { return nil }
        return standing
    }

    /// Probes that found the seat ready, over every probe of it: availability, kept apart from accuracy.
    func availability(seat: String) throws -> (ok: Int, probes: Int) {
        try ledger.locked {
            try ledger.query("SELECT COALESCE(SUM(reason = 'ok'), 0), COUNT(*) FROM preflights WHERE seat = ?;", [seat]) {
                (ok: Int(Ledger.text($0, 0) ?? "") ?? 0, probes: Int(Ledger.text($0, 1) ?? "") ?? 0)
            }.first ?? (0, 0)
        }
    }
}
