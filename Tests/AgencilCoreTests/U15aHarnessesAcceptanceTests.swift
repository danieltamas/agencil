import Foundation
import Testing
import AgencilCore

@Suite(.serialized)
struct U15aHarnessesAcceptanceTests {
    private let fields: Set<String> = [
        "kind", "found", "path", "version", "signed_in", "probe_status", "chain", "installs"
    ]

    private func harnesses(_ rig: U6aRig, probe: Bool? = nil) throws -> [[String: Any]] {
        var request: [String: Any] = ["op": "harnesses"]
        if let probe { request["probe"] = probe }
        let reply = try rig.home.request(request)
        #expect(reply["ok"] as? Bool == true)
        #expect(reply.keys.contains("data_note"))
        let data = try #require(reply["data"] as? [String: Any])
        let rows = try #require(data["harnesses"] as? [[String: Any]])
        let kinds = try HarnessCatalog.embedded().entries.map(\.kind)
        #expect(rows.compactMap { $0["kind"] as? String } == kinds)
        #expect(Set(rows.compactMap { $0["kind"] as? String }).count == kinds.count)
        for row in rows {
            #expect(Set(row.keys) == fields)
            #expect(["yes", "no", "unknown"].contains(row["signed_in"] as? String ?? ""))
            #expect(["ok", "timed out", "failed"].contains(row["probe_status"] as? String ?? ""))
            #expect(["supported", "unsupported", "untested"].contains(row["chain"] as? String ?? ""))
            #expect(row["found"] is Bool)
            #expect(row["installs"] is Int)
        }
        return rows
    }

    @Test func catalogFieldsFoundMissingAndSignInStates() throws {
        let rig = try U6aRig(["claude", "codex"], mode: "codex-out")
        let rows = try harnesses(rig)
        for row in rows {
            let kind = try #require(row["kind"] as? String)
            let installed = ["claude", "codex"].contains(kind)
            #expect(row["found"] as? Bool == installed)
            #expect(row["installs"] as? Int == (installed ? 1 : 0))
            #expect(row["probe_status"] as? String == (installed ? "ok" : "failed"))
            if installed {
                #expect(row["path"] as? String == rig.bin.appendingPathComponent(kind).path)
                #expect(row["version"] as? String == "0.9.4")
                #expect(row["signed_in"] as? String == (kind == "claude" ? "yes" : "no"))
            } else {
                #expect(row["path"] is NSNull)
                #expect(row["version"] is NSNull)
                #expect(row["signed_in"] as? String == "unknown")
            }
        }
    }

    @Test func plainReplyUsesCacheAndExplicitProbeRefreshesReplacedStub() throws {
        let rig = try U6aRig(["claude", "codex"], mode: "codex-out")
        let first = try harnesses(rig)
        let original = try #require(first.first { $0["kind"] as? String == "claude" })
        #expect(original["version"] as? String == "0.9.4")

        try rig.install("claude", version: "1.2.3")
        let cached = try harnesses(rig)
        #expect(NSDictionary(dictionary: ["rows": cached]).isEqual(to: ["rows": first]))

        let refreshed = try harnesses(rig, probe: true)
        let updated = try #require(refreshed.first { $0["kind"] as? String == "claude" })
        #expect(updated["version"] as? String == "1.2.3")
        #expect(updated["found"] as? Bool == true)
        #expect(updated["path"] as? String == rig.bin.appendingPathComponent("claude").path)
        #expect(updated["signed_in"] as? String == "yes")
        #expect(updated["installs"] as? Int == 1)
        #expect(updated["probe_status"] as? String == "ok")

        try rig.install("claude", version: "2.0.0")
        let cachedAfterRefresh = try harnesses(rig, probe: false)
        #expect(NSDictionary(dictionary: ["rows": cachedAfterRefresh]).isEqual(to: ["rows": refreshed]))
    }
}
