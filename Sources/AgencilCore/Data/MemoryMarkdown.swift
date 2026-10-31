import Foundation

extension MemoryExport {
    /// One value on one line: control characters and line breaks become spaces, so a value never starts a new block.
    private static func line(_ text: String?) -> String {
        String((text ?? "").unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }

    /// An identifier we or the ledger mint (council, state, claim id, time): anything else becomes an underscore.
    private static func token(_ text: String) -> String {
        String(text.unicodeScalars.map { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "._-:".unicodeScalars.contains($0)) ? Character($0) : "_" })
    }

    /// Untrusted text in a code fence longer than any run of backticks inside it, so nothing in it can close the fence.
    private static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
    }

    /// The Markdown of one sitting: a pure function of the ledger rows, so a re-run on an unchanged ledger writes the same bytes.
    func render(_ sitting: String, number: Int, statuses: [String: String]) throws -> String {
        struct Header { let council: String; let state: String; let opened: String }
        struct Verdict { let text: String; let minority: String?; let flags: String? }
        struct Claim { let id: String; let seat: String; let kind: String?; let severity: String?; let file: String?; let line: String?; let body: String }
        let (header, verdict, claims) = try ledger.locked {
            let header = try ledger.query("SELECT council, state, created_at FROM sittings WHERE id = ?;", [sitting]) {
                Header(council: Ledger.text($0, 0) ?? "", state: Ledger.text($0, 1) ?? "", opened: Ledger.text($0, 2) ?? "")
            }.first
            let verdict = try ledger.query("""
                SELECT verdict, minority, independence_flags FROM verdicts WHERE run_id = ? ORDER BY created_at DESC, id DESC LIMIT 1;
                """, [sitting]) { Verdict(text: Ledger.text($0, 0) ?? "", minority: Ledger.text($0, 1), flags: Ledger.text($0, 2)) }.first
            let claims = try ledger.query("""
                SELECT c.id, COALESCE(sr.seat, ''), c.kind, c.severity, c.file, c.line, c.body
                FROM claims c LEFT JOIN seat_runs sr ON sr.id = c.seat_run_id WHERE c.run_id = ? ORDER BY c.id;
                """, [sitting]) {
                Claim(id: Ledger.text($0, 0) ?? "", seat: Ledger.text($0, 1) ?? "", kind: Ledger.text($0, 2), severity: Ledger.text($0, 3),
                      file: Ledger.text($0, 4), line: Ledger.text($0, 5), body: Ledger.text($0, 6) ?? "")
            }
            return (header, verdict, claims)
        }
        guard let header else { throw DataError(message: "unknown sitting \(sitting)") }

        var out = "# Sitting \(number): \(Self.token(header.council))\n\n"
        out += "- state: \(Self.token(header.state))\n- opened: \(Self.token(header.opened))\n"
        if let verdict {
            out += "\n## Verdict\n\n" + Self.fenced(verdict.text)
            if let minority = verdict.minority, !minority.isEmpty { out += "\n### Minority report\n\n" + Self.fenced(minority) }
            if let flags = verdict.flags, !flags.isEmpty { out += "\n### Independence flags\n\n" + Self.fenced(flags) }
        }
        out += "\n## Claims\n"
        for claim in claims {
            let place = [claim.file.map(Self.line), claim.line.map(Self.line)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
            out += "\n### \(Self.token(claim.id))\n\n- status: \(statuses[claim.id] ?? "pending")\n\n"
            out += Self.fenced("seat: \(Self.line(claim.seat))\nkind: \(Self.line(claim.kind))\nseverity: \(Self.line(claim.severity))\nlocation: \(place)\n")
            out += "\n"
            out += Self.fenced(claim.body)
        }
        return out
    }
}
