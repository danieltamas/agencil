import Foundation

extension Broker {
    /// The `harnesses` op: what is installed, its version and sign-in, one row per catalog kind.
    func harnessesOp(_ request: [String: Any]) -> [String: Any] {
        // A result carried over a failed probe keeps its install, but its sign-in is from an earlier check: shown as
        // unknown, never as a fresh yes or no.
        let (probes, carried) = discovery.marked(environment: environment, home: directory, force: request["probe"] as? Bool == true)
        let rows = probes.map { probe -> [String: Any] in
            let signedIn: String
            switch probe.signedIn {
            case _ where carried.contains(probe.kind): signedIn = "unknown"
            case .signedIn: signedIn = "yes"
            case .signedOut: signedIn = "no"
            case .unknown: signedIn = "unknown"
            }
            let status: String
            switch probe.probeStatus {
            case .ok: status = "ok"
            case .timedOut: status = "timed out"
            case .failed: status = "failed"
            }
            let chain: String
            switch probe.chainSupport {
            case .supported: chain = "supported"
            case .unsupported: chain = "unsupported"
            case .untested: chain = "untested"
            }
            return ["kind": probe.kind, "found": !probe.paths.isEmpty, "path": probe.executable?.path ?? NSNull(),
                    "version": probe.version ?? NSNull(), "signed_in": signedIn, "probe_status": status, "chain": chain,
                    "installs": probe.installs.count]
        }
        return ["ok": true, "data": ["harnesses": rows], "data_note": Self.note]
    }
}
