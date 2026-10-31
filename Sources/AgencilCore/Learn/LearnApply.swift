import CryptoKit
import Foundation

private struct StoredVersion {
    let id: String
    let kind: String
    let version: ConfigVersion
}

extension LearnLoop {
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Call inside `ledger.locked`.
    private func loadVersions() throws -> [StoredVersion] {
        try ledger.query("""
            SELECT id, kind, version, hash, body FROM configs WHERE kind IN ('council', 'council-rollback') ORDER BY version;
            """, []) { row in
            StoredVersion(id: Ledger.text(row, 0) ?? "", kind: Ledger.text(row, 1) ?? "",
                          version: ConfigVersion(version: Int(Ledger.text(row, 2) ?? "") ?? 0, hash: Ledger.text(row, 3) ?? "",
                                                 body: Ledger.text(row, 4) ?? ""))
        }
    }

    public func versions() throws -> [ConfigVersion] { try ledger.locked { try loadVersions().map(\.version) } }

    /// Appends a version after `last`; the caller holds the ledger transaction.
    private func append(body: String, hash: String, kind: String, after last: StoredVersion?, at: Date) throws -> StoredVersion {
        let stored = StoredVersion(id: SittingStore.newID("cfg_"), kind: kind,
                                   version: ConfigVersion(version: (last?.version.version ?? 0) + 1, hash: hash, body: body))
        try ledger.run("""
            INSERT INTO configs (id, kind, version, hash, body, supersedes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [stored.id, kind, String(stored.version.version), hash, body, last?.id, OutcomeBook.stamp(at)])
        return stored
    }

    /// The `councils` text with the proposal applied; refuses a council or seat that no longer matches.
    private static func applying(_ proposal: Proposal, to text: String) throws -> String {
        guard var list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
              let at = list.firstIndex(where: { $0["name"] as? String == proposal.council }),
              var seats = list[at]["seats"] as? [String] else {
            throw LearnError(message: "council \(proposal.council) is not in config.json")
        }
        var council = list[at]
        func position(_ name: String?) throws -> Int {
            guard let name, let index = seats.firstIndex(of: name) else { throw LearnError(message: "\(name ?? "seat") is no longer in \(proposal.council)") }
            return index
        }
        func entering() throws -> String {
            guard let name = proposal.replacement, !seats.contains(name) else { throw LearnError(message: "the added seat is already in \(proposal.council)") }
            return name
        }
        switch proposal.kind {
        case .dropSeat:
            let index = try position(proposal.seat)
            guard seats.count > 2 else { throw LearnError(message: "\(proposal.council) would keep fewer than 2 seats") }
            seats.remove(at: index)
        case .swapSeat:
            let index = try position(proposal.seat)
            seats[index] = try entering()
        case .addSeat:
            seats.append(try entering())
        case .promptChange:
            guard let variable = proposal.variable, let value = proposal.value else { throw LearnError(message: "the prompt change is incomplete") }
            council["prompt_variant"] = ["variable": variable, "value": value]
        }
        council["seats"] = seats
        list[at] = council
        let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }


    /// Writes `councils` as the last step of an open ledger transaction, so a refusal anywhere earlier leaves both
    /// stores untouched. A write that replaced the file but could not confirm the flush still counts as written.
    private func writeCouncils(_ councils: String, revision: Int64) throws {
        do {
            try store.update(expectedRevision: revision) { $0["councils"] = councils }
        } catch ConfigStore.Failure.durabilityUnconfirmed {
            return
        }
    }

    /// Puts the old councils back when the ledger could not commit what the config already says.
    private func restoreCouncils(_ councils: String) {
        _ = try? store.update { $0["councils"] = councils }
    }

    /// The only call that changes the council configuration on a proposal's behalf. The proposal's status, the
    /// config revision and the result are all checked inside one ledger transaction that is still open when
    /// `config.json` is written, so a concurrent reject cannot be overwritten and a failure leaves no half state.
    public func approve(_ proposal: String, at: Date) throws -> ConfigVersion {
        var previous: String?
        return try transaction(undoing: { previous.map(restoreCouncils) }) {
            guard let found = try loadProposals(id: proposal).first else { throw LearnError(message: "unknown proposal \(proposal)") }
            guard found.status == "reviewed", let reviewed = found.reviewRevision else {
                throw LearnError(message: "proposal \(proposal) is \(found.status): it needs a review first")
            }
            guard found.verdict == .endorse else { throw LearnError(message: "proposal \(proposal) was not endorsed by its reviewer") }
            let snapshot = try store.read()
            guard snapshot.revision == reviewed else {
                throw LearnError(message: "config.json changed since the review; review it again")
            }
            guard let current = snapshot.values["councils"] else { throw LearnError(message: "config.json has no councils") }
            let next = try Self.applying(found, to: current)
            var values = snapshot.values
            values["councils"] = next
            _ = try SeatConfig(values: values)

            var last = try loadVersions().last
            if last?.version.body != current {
                // First approval, or the owner edited the councils by hand: the state being replaced becomes a version.
                last = try append(body: current, hash: Self.hash(current), kind: "council", after: last, at: at)
            }
            let applied = try append(body: next, hash: Self.hash(next), kind: "council", after: last, at: at).version
            var body = found.storedBody
            body.appliedVersion = applied.version
            try ledger.run("UPDATE proposals SET status = 'applied', body = ? WHERE id = ?;", [try body.encoded(), proposal])
            try writeCouncils(next, revision: snapshot.revision)
            previous = current
            return applied
        }
    }

    /// Restores the councils of the version before the latest as a new version with that version's hash.
    public func rollback(at: Date) throws -> ConfigVersion {
        var current: String?
        return try transaction(undoing: { current.map(restoreCouncils) }) {
            let all = try loadVersions()
            guard all.count >= 2, let latest = all.last else { throw LearnError(message: "there is no previous council version") }
            let previous = all[all.count - 2].version
            let snapshot = try store.read()
            guard snapshot.values["councils"] == latest.version.body else {
                throw LearnError(message: "the councils changed outside the learn loop since version \(latest.version.version)")
            }
            var values = snapshot.values
            values["councils"] = previous.body
            _ = try SeatConfig(values: values)

            let restored = try append(body: previous.body, hash: previous.hash, kind: "council-rollback", after: latest, at: at).version
            for behind in try loadProposals() where behind.status == "applied" && behind.appliedVersion == latest.version.version {
                try ledger.run("UPDATE proposals SET status = 'rolled_back' WHERE id = ?;", [behind.id])
            }
            try writeCouncils(previous.body, revision: snapshot.revision)
            current = latest.version.body
            return restored
        }
    }
}
