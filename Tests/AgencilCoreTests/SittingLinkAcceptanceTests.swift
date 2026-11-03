import Testing
@testable import AgencilCore

@Suite struct SittingLinkAcceptanceTests {
    @Test(arguments: [
        ("sit_abc123", "agencil://sitting/sit_abc123"),
        ("th_abc123", "agencil://thread/th_abc123")
    ])
    func linksSupportedIDs(id: String, expected: String) {
        #expect(SittingLink.link(for: id) == expected)
    }

    @Test(arguments: ["", "abc", "x_sit_1"])
    func rejectsUnsupportedIDs(id: String) {
        #expect(SittingLink.link(for: id) == nil)
    }

    @Test(arguments: [
        ("agencil://sitting/sit_abc123", "sit_abc123"),
        ("agencil://thread/th_abc123", "th_abc123"),
        (" \n agencil://sitting/sit_abc123\n\t", "sit_abc123"),
        ("\t agencil://thread/th_abc123 \n", "th_abc123")
    ])
    func extractsIDsFromLinks(input: String, expected: String) {
        #expect(SittingLink.id(from: input) == expected)
    }

    @Test(arguments: ["sit_abc123", "th_abc123"])
    func preservesBareIDs(id: String) {
        #expect(SittingLink.id(from: id) == id)
    }

    @Test(arguments: [
        "https://sitting/sit_abc123",
        "agencil://other/sit_abc123",
        "agencil://sitting/th_abc123",
        "agencil://thread/sit_abc123",
        "agencil://sitting/",
        " \n arbitrary text\t ",
        " \n https://sitting/sit_abc123 \n"
    ])
    func preservesMalformedLinksAndTextExactly(input: String) {
        #expect(SittingLink.id(from: input) == input)
    }

    @Test(arguments: ["sit_abc123", "th_abc123"])
    func roundTripsSupportedIDs(id: String) throws {
        let link = try #require(SittingLink.link(for: id))
        #expect(SittingLink.id(from: link) == id)
    }
}
