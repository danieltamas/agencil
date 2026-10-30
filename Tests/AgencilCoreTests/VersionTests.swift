import Testing
@testable import AgencilCore

@Suite struct VersionTests {
    @Test func unstampedBuildReportsZero() {
        #expect(AgencilVersion.current(infoDictionary: nil) == AgencilVersion.unstamped)
    }

    @Test func stampedBuildReportsItsVersion() {
        #expect(AgencilVersion.current(infoDictionary: ["CFBundleShortVersionString": "1.2.3"]) == "1.2.3")
    }
}
