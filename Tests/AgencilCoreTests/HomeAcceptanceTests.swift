// API contract: AgencilHome(directory: URL, environment: [String: String]) throws,
// public directory: URL. AGENCIL_HOME wins over the supplied fallback directory.
import Foundation
import Darwin
import Testing
import AgencilCore

@Suite struct HomeAcceptanceTests {
    @Test func explicitEnvironmentAndPrivateDirectory() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let fallback = temp.url.appendingPathComponent("fallback")
        let override = temp.url.appendingPathComponent("override")
        let home = try AgencilHome(directory: fallback, environment: ["AGENCIL_HOME": override.path])
        #expect(home.directory.standardizedFileURL == override.standardizedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: override.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        let other = try AgencilHome(directory: fallback, environment: [:])
        #expect(other.directory == fallback)
        let mode = try FileManager.default.attributesOfItem(atPath: fallback.path)
        #expect((mode[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

struct AcceptanceDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// Independent OS helpers, deliberately not using the process runner under test.
func acceptanceCommand(_ argv: [String]) throws -> (Int32, String) {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
