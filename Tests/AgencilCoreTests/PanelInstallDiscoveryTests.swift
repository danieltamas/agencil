import Darwin
@testable import AgencilCore
import Foundation
import Testing

/// The panel op judges a seat's install the way a wake does: through harness discovery, which also looks in the
/// user's well-known install directories (`~/.opencode/bin`), not only the broker's PATH.
@Suite(.serialized) struct PanelInstallDiscoveryTests {
    /// The account's home as the system database has it. `HOME` does not move it, so the broker's known install
    /// directories cannot be pointed at a fake home; the live-broker check needs the machine's own opencode.
    private static let accountHome: String = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
    private static let realOpencode = accountHome + "/.opencode/bin/opencode"
    private static let hasRealOpencode = FileManager.default.isExecutableFile(atPath: realOpencode)

    private final class Rig {
        let home = try! BrokerHome()
        var broker: BrokerProcess?

        init(seats: [(String, String)], seams: Bool) throws {
            _ = try ConfigStore(directory: home.url).update {
                $0 = ["seats": try! u6aText(seats.map { u6aSeat($0.0, $0.1) }), "aliases": "{}", "routes": "[]", "triggers": "[]",
                      "councils": try! u6aText([["name": "panel", "seats": seats.map(\.0)] as [String: Any]]), "agent_access": "on"]
            }
            // A bare PATH: the only way to an install is a well-known install directory.
            broker = try home.serve(["PATH": "/usr/bin:/bin", "AGENCIL_TEST_SEAMS": seams ? "1" : "0"])
        }

        func panel() throws -> [String: Any] {
            try #require(try home.request(["op": "panel", "caller": "owner"])["data"] as? [String: Any])
        }

        func seat(_ name: String) throws -> [String: Any] {
            let seats = try #require(try panel()["seats"] as? [String: Any])
            let items = try #require(seats["items"] as? [[String: Any]])
            return try #require(items.first { $0["name"] as? String == name })
        }

        func harness(_ kind: String) throws -> [String: Any] {
            let data = try #require(try home.request(["op": "harnesses", "caller": "owner"])["data"] as? [String: Any])
            return try #require((data["harnesses"] as? [[String: Any]])?.first { $0["kind"] as? String == kind })
        }
    }

    // MARK: live broker

    @Test(.enabled(if: PanelInstallDiscoveryTests.hasRealOpencode, "needs an executable ~/.opencode/bin/opencode on this machine"))
    func anOpencodeInstalledOnlyUnderDotOpencodeBinIsUpWithNoProblem() throws {
        let rig = try Rig(seats: [("o", "opencode")], seams: false)
        let found = try rig.harness("opencode")
        #expect(found["found"] as? Bool == true)
        #expect(found["path"] as? String == Self.realOpencode)
        let seat = try rig.seat("o")
        #expect(seat["up"] as? Bool == true)
        #expect(seat["problem"] == nil)
    }

    @Test func noInstallAnywhereIsDownAndSaysNotInstalled() throws {
        // Test seams drop the machine's own install directories, so no real opencode can leak in.
        let rig = try Rig(seats: [("o", "opencode")], seams: true)
        let seat = try rig.seat("o")
        #expect(seat["up"] as? Bool == false)
        #expect(seat["problem"] as? String == "opencode is not installed")
    }

    @Test func aHarnessWithoutAnAdapterIsDownAndSaysSo() throws {
        let rig = try Rig(seats: [("x", "aider")], seams: true)
        let seat = try rig.seat("x")
        #expect(seat["up"] as? Bool == false)
        #expect(seat["problem"] as? String == "aider has no adapter")
    }

    @Test func eachSeatGetsItsOwnVerdictInOnePanelRead() throws {
        let rig = try Rig(seats: [("o", "opencode"), ("x", "aider")], seams: true)
        let seats = try #require(try rig.panel()["seats"] as? [String: Any])
        #expect(seats["total"] as? Int == 2 && seats["up"] as? Int == 0)
        #expect(try rig.seat("o")["problem"] as? String == "opencode is not installed")
        #expect(try rig.seat("x")["problem"] as? String == "aider has no adapter")
    }

    // MARK: discovery of a fake home, resolved the way the panel resolves

    private func seat(_ harness: String) throws -> Seat {
        let values = ["seats": try u6aText([u6aSeat("o", harness)]), "aliases": "{}", "councils": "[]", "routes": "[]"]
        return try #require(SeatConfig(values: values).seats.first)
    }

    private func world(searching path: [URL], known: [URL]) async throws -> ResolverWorld {
        let catalog = try HarnessCatalog.embedded()
        let probes = try await HarnessDiscovery().discover(catalog: catalog, searchPath: path, knownInstallDirectories: known, environment: [:])
        let byKind = Dictionary(probes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        return ResolverWorld(probe: { byKind[$0] }, statusless: Set(catalog.entries.filter { $0.status == nil }.map(\.kind)),
                             ollamaProblem: { _ in nil })
    }

    private func fakeHome(installing: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agencil-fake-home-" + UUID().uuidString)
        let bin = home.appendingPathComponent(".opencode/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if installing {
            let tool = bin.appendingPathComponent("opencode")
            try "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'opencode 77.7.7'; fi\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        return home
    }

    @Test func statuslessOpencodeInAKnownInstallDirectoryResolvesAsInstalledAndUsable() async throws {
        let home = try fakeHome(installing: true); defer { try? FileManager.default.removeItem(at: home) }
        let world = try await world(searching: [URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/bin")],
                                    known: [home.appendingPathComponent(".opencode/bin")])
        let result = Resolver.installed(try seat("opencode"), world)
        guard case .success(let path) = result else { Issue.record("opencode in a known install directory was refused: \(result)"); return }
        #expect(path == home.appendingPathComponent(".opencode/bin/opencode").path)
    }

    @Test func theSameBarePathWithoutTheKnownDirectoryIsNotInstalled() async throws {
        let home = try fakeHome(installing: false); defer { try? FileManager.default.removeItem(at: home) }
        let world = try await world(searching: [URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/bin")],
                                    known: [home.appendingPathComponent(".opencode/bin")])
        #expect(Resolver.installed(try seat("opencode"), world) == .failure(Resolver.Unusable(reason: "opencode is not installed")))
    }
}
