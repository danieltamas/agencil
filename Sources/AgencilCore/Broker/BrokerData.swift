import Foundation

/// The Data pane's reads and its one write (docs/U19-SPEC.md): sizes and targets, and pruning old raw output now.
extension Broker {
    func dataOp() throws -> [String: Any] {
        let retention = Retention(ledger: ledger, directory: directory)
        do {
            let days = try retention.days(), size = try retention.size()
            let targets = try MemoryExport(ledger: ledger, directory: directory).targets()
            return ["ok": true, "data_note": Self.note, "data": [
                "retention_days": days, "database_bytes": size.database, "raw_bytes": size.rawOutputs, "total_bytes": size.total,
                "memory_targets": targets.map { ["repo": $0.repo, "folder": $0.folder, "enabled": $0.enabled] as [String: Any] }]]
        } catch let error as DataError {
            throw ConfigProblem(key: "data", problem: error.message)
        }
    }

    func pruneOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        guard request["caller"] as? String == "owner" else { throw Failure(message: "refused: only the owner may do this", exit: 3) }
        guard case .success(.root) = attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) else {
            throw Failure(message: "refused: a seat cannot act as the owner", exit: 3)
        }
        let report = try Retention(ledger: ledger, directory: directory).prune(now: Date())
        return ["ok": true, "data_note": Self.note, "data": [
            "files_deleted": report.filesDeleted, "bytes_freed": report.bytesFreed, "exchanges_cleared": report.exchangesCleared]]
    }
}
