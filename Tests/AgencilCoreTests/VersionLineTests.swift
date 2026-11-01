import Testing
@testable import AgencilCore

@Suite struct VersionLineTests {
    private func line(_ version: String, source: String? = nil) -> String {
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let source { info[AgencilVersion.sourceKey] = source }
        return AgencilVersion.line(infoDictionary: info)
    }

    @Test func releaseBuildNamesOnlyItsVersion() {
        #expect(line("0.4.0") == "v0.4.0")
    }

    @Test func buildFromSourceNamesCommitsAndCommit() {
        #expect(line("0.3.0", source: "v0.3.0-4-g3f9a2c1") == "v0.3.0 + 4 commits (3f9a2c1), built from source")
        #expect(line("0.3.0", source: "v0.3.0-1-g3f9a2c1") == "v0.3.0 + 1 commit (3f9a2c1), built from source")
        #expect(line("0.3.0", source: "v0.3.0") == "v0.3.0, built from source")
    }

    @Test func uncommittedChangesAreSaid() {
        #expect(line("0.3.0", source: "v0.3.0-2-g3f9a2c1-dirty") == "v0.3.0 + 2 commits (3f9a2c1), built from source, uncommitted changes")
    }

    @Test func aSourceThatIsNotATagIsShownAsIs() {
        #expect(line("0.0.0", source: "3f9a2c1") == "v0.0.0 (3f9a2c1), built from source")
    }

    @Test func missingInfoIsUnstamped() {
        #expect(AgencilVersion.line(infoDictionary: nil) == "v0.0.0")
    }
}
