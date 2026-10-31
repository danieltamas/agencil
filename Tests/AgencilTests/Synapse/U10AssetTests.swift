/* API contract: docs/U10-SPEC.md.
 MeshTexture.opacity == 0.04
 MeshTexture.visible(in: Look) == (look == .agencil)
 Brand/menubar-frames/1.svg ... 14.svg: viewBox="0 0 36 36", pairwise different.
 Brand/mesh.svg exists.
 scripts/render-icons.sh <out> writes MenuBarFrames/<n>.pdf (1...14) and mesh.png;
 repeated runs produce identical bytes.
 scripts/perf.sh --scenarios prints closed, open, live, menubar, one per line.
 scripts/perf.sh --verdict <scenario> <mean-cpu-percent> exits 0 strictly below
 budgets closed=0.3, open=1, live=6, menubar=1.5; otherwise exits 1,
 including unknown scenarios, negative numbers and non-numbers.
 */
import Foundation
import Testing
@testable import Agencil

@Suite(.serialized) struct U10AssetTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func fourteenDistinctSVGFramesAndMeshExist() throws {
        var frames: [Data] = []
        for index in 1...14 {
            let data = try Data(contentsOf: root.appendingPathComponent("Brand/menubar-frames/\(index).svg"))
            let svg = try #require(String(data: data, encoding: .utf8))
            #expect(svg.contains("viewBox=\"0 0 36 36\""))
            frames.append(data)
        }
        #expect(Set(frames).count == 14)
        let mesh = try Data(contentsOf: root.appendingPathComponent("Brand/mesh.svg"))
        #expect(!mesh.isEmpty)
    }

    @Test @MainActor func meshIsFourPercentAndExclusiveToAgencil() {
        #expect(MeshTexture.opacity == 0.04)
        for look in Look.allCases {
            #expect(MeshTexture.visible(in: look) == (look == .agencil))
        }
    }

    @Test func renderedFramesAndMeshAreDeterministic() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("u10-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = temporary.appendingPathComponent("first", isDirectory: true)
        let second = temporary.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            let result = try run("scripts/render-icons.sh", [directory.path])
            #expect(result.status == 0, "render-icons: \(result.output)")
            let files = try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("MenuBarFrames"), includingPropertiesForKeys: nil)
            #expect(files.filter { $0.pathExtension == "pdf" }.count == 14)
        }
        var frames: [Data] = []
        for path in (1...14).map({ "MenuBarFrames/\($0).pdf" }) + ["mesh.png"] {
            let a = try Data(contentsOf: first.appendingPathComponent(path))
            let b = try Data(contentsOf: second.appendingPathComponent(path))
            #expect(!a.isEmpty)
            #expect(a == b, "Non-deterministic asset: \(path)")
            if path.hasSuffix(".pdf") {
                #expect(a.starts(with: Data("%PDF-".utf8)))
                frames.append(a)
            } else {
                #expect(a.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])))
            }
        }
        #expect(Set(frames).count == 14)
    }

    @Test func performanceScenarioListAndStrictBudgetBoundary() throws {
        let scenarios = try run("scripts/perf.sh", ["--scenarios"])
        #expect(scenarios.status == 0)
        #expect(scenarios.output == "closed\nopen\nlive\nmenubar\n")
        let limits = [("closed", "0.29", "0.3"), ("open", "0.99", "1"),
                      ("live", "5.99", "6"), ("menubar", "1.49", "1.5")]
        for (scenario, below, exact) in limits {
            #expect(try run("scripts/perf.sh", ["--verdict", scenario, below]).status == 0)
            #expect(try run("scripts/perf.sh", ["--verdict", scenario, exact]).status == 1)
            #expect(try run("scripts/perf.sh", ["--verdict", scenario, "-0.01"]).status == 1)
            #expect(try run("scripts/perf.sh", ["--verdict", scenario, "not-a-number"]).status == 1)
        }
        #expect(try run("scripts/perf.sh", ["--verdict", "unknown", "0"]).status == 1)
    }

    private func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent(script).path] + arguments
        process.currentDirectoryURL = root
        // A file avoids pipe backpressure while the icon renderer runs.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("u10-output-\(UUID().uuidString)")
        try Data().write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        // Keep diagnostics out of --scenarios' exact stdout contract.
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
    }
}
