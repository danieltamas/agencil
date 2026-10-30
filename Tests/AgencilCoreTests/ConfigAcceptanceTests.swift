// API contract: ConfigStore(directory: URL, beforeRename: (() throws -> Void)? = nil).
// read() throws -> ConfigSnapshot { revision: Int64, values: [String: String] }.
// update(expectedRevision: Int64? = nil, _ change: (inout [String: String]) -> Void)
// throws -> ConfigSnapshot. nil means locked read-modify-write; a stale explicit revision
// throws ConfigStore.Failure.staleRevision BEFORE invoking change. New files start at 0;
// each successful write increments once. beforeRename runs after temp fsync, before rename.
import Foundation
import Darwin
import Testing
import AgencilCore

@Suite struct ConfigAcceptanceTests {
    @Test(.timeLimit(.minutes(1))) func independentWritersPreserveEveryChange() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let store = ConfigStore(directory: temp.url)
        _ = try store.update { $0["seed"] = "kept" }
        let fixture = try fixtureURL()
        let start = ContinuousClock.now
        let processes = try ["maya", "jonas"].map { key -> Process in
            let process = Process()
            process.executableURL = fixture
            process.arguments = [temp.url.path, key]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            return process
        }
        defer { for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Both children announce readiness before either is released, proving overlap.
        let deadline = ContinuousClock.now + .seconds(15)
        while processes.contains(where: { $0.isRunning }) && ContinuousClock.now < deadline {
            let ready = ["maya", "jonas"].allSatisfy {
                FileManager.default.fileExists(atPath: temp.url.appendingPathComponent($0 + ".ready").path)
            }
            if ready { try Data().write(to: temp.url.appendingPathComponent("go")) }
            try await Task.sleep(for: .milliseconds(10))
        }
        for process in processes {
            try #require(!process.isRunning, "Writer exceeded 15 second deadline")
            #expect(process.terminationStatus == 0)
        }
        #expect(start.duration(to: .now) < .seconds(20))
        let result = try store.read()
        #expect(result.revision == 201)
        #expect(result.values["seed"] == "kept")
        for key in ["maya", "jonas"] {
            for index in 0..<100 { #expect(result.values["\(key).\(index)"] == String(index)) }
        }
    }

    @Test func malformedConfigFailsEveryWriteWithoutChangingBytes() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let file = temp.url.appendingPathComponent("config.json")
        let bytes = Data("{ broken syntax\n".utf8)
        try bytes.write(to: file)
        let store = ConfigStore(directory: temp.url)
        for _ in 0..<3 {
            do {
                _ = try store.update { $0["look"] = "light" }
                Issue.record("Malformed config allowed a write")
            } catch {
                #expect(!error.localizedDescription.isEmpty)
                #expect(error.localizedDescription.contains("config"), "Problem must identify the config")
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func symlinkIsRefusedEvenWhenTargetIsValid() throws {
        let temp = try AcceptanceDirectory(), target = try AcceptanceDirectory()
        defer { temp.remove(); target.remove() }
        _ = try ConfigStore(directory: target.url).update { $0["protected"] = "original" }
        let destination = target.url.appendingPathComponent("config.json")
        let bytes = try Data(contentsOf: destination)
        let link = temp.url.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: (any Error).self) {
            _ = try ConfigStore(directory: temp.url).update { $0["protected"] = "changed" }
        }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
    }

    @Test func failureAfterFsyncPreservesOldReadableConfig() throws {
        enum Injected: Error { case crash }
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let normal = ConfigStore(directory: temp.url)
        let original = try normal.update { $0["look"] = "dark" }
        let file = temp.url.appendingPathComponent("config.json")
        let bytes = try Data(contentsOf: file)
        let failing = ConfigStore(directory: temp.url, beforeRename: {
            #expect(try Data(contentsOf: file) == bytes)
            throw Injected.crash
        })
        #expect(throws: Injected.crash) { _ = try failing.update { $0["look"] = "light" } }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try normal.read().revision == original.revision)
        #expect(try normal.read().values == original.values)
    }

    @Test func staleRevisionIsRefusedThenCallerRereadsAndRetries() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let first = ConfigStore(directory: temp.url), second = ConfigStore(directory: temp.url)
        let stale = try first.read()
        let fresh = try second.update { $0["look"] = "dark" }
        var invoked = false
        #expect(throws: ConfigStore.Failure.staleRevision) {
            _ = try first.update(expectedRevision: stale.revision) { invoked = true; $0["seat"] = "maya" }
        }
        #expect(!invoked)
        #expect(try first.read().revision == fresh.revision)
        #expect(try first.read().values["seat"] == nil)
        let reread = try first.read()
        let saved = try first.update(expectedRevision: reread.revision) { $0["seat"] = "maya" }
        #expect(saved.revision == fresh.revision + 1)
        #expect(saved.values["look"] == "dark")
        #expect(saved.values["seat"] == "maya")
    }

    // Changing ownership to another uid requires root on macOS. That sub-case is not exercised.
    private func fixtureURL() throws -> URL {
        let arguments = CommandLine.arguments
        var bundlePaths: [String] = []
        if let index = arguments.firstIndex(of: "--test-bundle-path"),
           arguments.indices.contains(index + 1) {
            bundlePaths.append(arguments[index + 1])
        }
        bundlePaths.append(contentsOf: arguments.filter { $0.contains(".xctest/") })

        for path in bundlePaths {
            var bundleURL = URL(fileURLWithPath: path)
            while !bundleURL.lastPathComponent.hasSuffix(".xctest"),
                  bundleURL.path != "/" {
                bundleURL.deleteLastPathComponent()
            }
            guard bundleURL.lastPathComponent.hasSuffix(".xctest") else { continue }
            let candidate = bundleURL.deletingLastPathComponent()
                .appendingPathComponent("ConfigWriterFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        var directory = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
        for _ in 0..<7 {
            let candidate = directory.appendingPathComponent("ConfigWriterFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
