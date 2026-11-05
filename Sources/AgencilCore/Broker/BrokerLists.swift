import Foundation

/// The read ops over config and the ledger, and the owner's two writes (docs/U18-SPEC.md). Replies carry no
/// endpoint, pin, key or prompt.
extension Broker {
    func seatConfig() throws -> (SeatConfig, [String: String]) {
        let values = try ConfigStore(directory: directory).read().values
        return (try SeatConfig(values: values), values)
    }

    func reply(_ data: [String: Any]) -> [String: Any] { ["ok": true, "data": data, "data_note": Self.note] }

    /// The CLI speaks as `owner` only from outside every seat: a seat's child that claims it is refused.
    func requireOwner(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws {
        guard request["caller"] as? String == "owner" else { throw Failure(message: "refused: only the owner may do this", exit: 3) }
        try requireRoot(request, peer: peer, peerStart: peerStart)
    }

    private func requireRoot(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws {
        guard case .success(.root) = attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) else {
            throw Failure(message: "refused: a seat cannot act as the owner", exit: 3)
        }
    }

    func listOp(_ op: String, _ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        let (config, values) = try seatConfig()
        switch op {
        case "seats":
            return reply(["seats": config.seats.map { seat -> [String: Any] in
                ["name": seat.name, "harness": seat.harness, "model": seat.model, "role": seat.role,
                 "hosted": seat.hosted, "vendor": seat.vendor]
            }])
        case "councils":
            return reply(["councils": config.councils.map { council -> [String: Any] in
                ["name": council.name, "mode": council.mode.rawValue, "seats": council.seats, "spares": council.spares,
                 "synthesizers": council.synthesizers, "rule": council.rule.rawValue, "high_risk": council.highRisk]
            }])
        case "routes":
            return reply(["routes": config.routes.map { route -> [String: Any] in
                ["callers": route.callers, "target": route.target, "hop_limit": route.hopLimit,
                 "fallbacks": route.fallbacks, "local_only": route.localOnly]
            }])
        case "models":
            let byModel = Dictionary(grouping: config.seats, by: \.model)
            return reply(["models": byModel.keys.sorted().map { ["model": $0, "seats": (byModel[$0] ?? []).map(\.name)] as [String: Any] }])
        default:
            return reply(["list_targets": try targets(config, values, request, peer: peer, peerStart: peerStart)])
        }
    }

    private func targets(_ config: SeatConfig, _ values: [String: String], _ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [[String: Any]] {
        let caller = request["caller"] as? String ?? ""
        let owner = caller == "owner"
        if owner { try requireRoot(request, peer: peer, peerStart: peerStart) }
        if !owner && values["agent_access"] != "on" { throw Failure(message: "refused: agent access is off", exit: 3) }
        var kinds: [String: String] = [:]
        for seat in config.seats { kinds[seat.name] = "seat" }
        for council in config.councils { kinds[council.name] = "council" }
        for alias in config.aliases.keys { kinds[alias] = "alias" }
        let ownerLimit = config.routes.map(\.hopLimit).max() ?? 1
        return kinds.keys.sorted().compactMap { name -> [String: Any]? in
            let limit: Int
            if owner { limit = ownerLimit } else if let route = config.route(from: caller, to: name) { limit = route.hopLimit } else { return nil }
            var row: [String: Any] = ["target": name, "kind": kinds[name] ?? "seat", "hop_limit": limit]
            // A council's mode tells an agent whether it gates a change or gives positions on a question.
            if let council = config.council(named: name) { row["mode"] = council.mode.rawValue }
            return row
        }
    }

    func findingsOp(_ request: [String: Any]) throws -> [String: Any] {
        _ = try seatConfig()
        let rows = try panelFindings()
        let open = request["open"] as? Bool == true
        return reply(["findings": open ? rows.filter { $0["disposition"] as? String == "open" } : rows])
    }

    func disposeOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        try requireOwner(request, peer: peer, peerStart: peerStart)
        _ = try seatConfig()
        let id = (request["id"] as? String) ?? "?"
        guard let word = request["disposition"] as? String else { throw Failure(message: "dispose needs a disposition", exit: 64) }
        let disposition: OwnerDisposition
        switch word {
        case "confirm": disposition = .confirm
        case "dismiss": disposition = .dismiss
        case "will-fix": throw Failure(message: "will-fix is not recorded yet", exit: 64)
        default: throw Failure(message: "dispose takes confirm, dismiss or will-fix", exit: 64)
        }
        do { try OutcomeBook(ledger: ledger).dispose(claim: id, as: disposition, reason: nil, at: Date()) }
        catch let error as OutcomeError where error.message.hasPrefix("unknown claim") { throw Failure(message: "unknown id \(id)", exit: 64) }
        return reply(["id": id, "disposition": word])
    }

    func leaderboardOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        try requireOwner(request, peer: peer, peerStart: peerStart)
        guard let action = request["action"] as? String, ["preview", "publish"].contains(action) else {
            throw Failure(message: "leaderboard takes preview or publish", exit: 64)
        }
        do {
            if action == "preview" {
                let bytes = try LeaderboardPublisher(ledger: ledger, directory: directory, github: GhClient()).preview(now: Date(), golden: [:])
                let cells = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["cells"] as? [Any]
                return reply(["bytes": String(decoding: bytes, as: UTF8.self), "cells": cells?.count ?? 0])
            }
            let values = try ConfigStore(directory: directory).read().values
            let repo = try LeaderboardSettings(values: values).repo
            try LeaderboardPublisher(ledger: ledger, directory: directory, github: GhClient(repo: repo)).press(now: Date(), golden: [:])
            return reply(["published": true])
        } catch let error as LeaderboardError {
            throw Failure(message: error.message, exit: 4)
        }
    }
}
