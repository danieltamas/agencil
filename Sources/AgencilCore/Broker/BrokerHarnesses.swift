import Foundation

extension Broker {
    /// The `harnesses` op: what is installed, its version and sign-in, one row per catalog kind.
    func harnessesOp(_ request: [String: Any]) -> [String: Any] {
        let probes = discovery.snapshot(environment: environment, home: directory, force: request["probe"] as? Bool == true)
        let rows = probes.map { probe -> [String: Any] in
            let signedIn: String
            switch probe.signedIn {
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
