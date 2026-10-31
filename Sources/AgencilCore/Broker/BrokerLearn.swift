import Foundation

/// The learn loop's proposals for the owner: a read, and approve, reject and rollback (docs/U22-SPEC.md).
extension Broker {
    func proposalsOp(_ request: [String: Any]) throws -> [String: Any] {
        _ = try seatConfig()
        let loop = LearnLoop(ledger: ledger, directory: directory)
        let everything = request["all"] as? Bool == true
        let rows = try loop.proposals().filter { everything || $0.isOpen }.map { found -> [String: Any] in
            ["id": found.id, "kind": found.kind.rawValue, "council": found.council, "seat": found.seat ?? NSNull(),
             "replacement": found.replacement ?? NSNull(), "variable": found.variable ?? NSNull(),
             "value": found.value.map(Self.plain) ?? NSNull(), "status": found.status, "n": found.n,
             "reviewer": found.reviewer ?? NSNull(), "verdict": found.verdict?.rawValue ?? NSNull(),
             "note": found.note.map(Self.plain) ?? NSNull()]
        }
        return reply(["proposals": rows, "can_rollback": try loop.versions().count >= 2])
    }

    func learnOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        try requireOwner(request, peer: peer, peerStart: peerStart)
        _ = try seatConfig()
        let loop = LearnLoop(ledger: ledger, directory: directory)
        let id = request["id"] as? String
        do {
            switch request["action"] as? String {
            case "approve":
                guard let id else { throw Failure(message: "learn approve needs an id", exit: 64) }
                return reply(["action": "approve", "id": id, "version": try loop.approve(id, at: Date()).version])
            case "reject":
                guard let id else { throw Failure(message: "learn reject needs an id", exit: 64) }
                try loop.reject(id, at: Date())
                return reply(["action": "reject", "id": id])
            case "rollback":
                return reply(["action": "rollback", "version": try loop.rollback(at: Date()).version])
            default:
                throw Failure(message: "learn takes approve, reject or rollback", exit: 64)
            }
        } catch let error as LearnError {
            throw Failure(message: error.message, exit: 4)
        }
    }
}

extension Broker {
    /// Seat-written text reaches the owner's screen and other callers as plain text: no control or invisible characters.
    static func plain(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format) || scalar == "\n"
        })
    }
}
