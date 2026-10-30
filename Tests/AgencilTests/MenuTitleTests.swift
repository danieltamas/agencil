import Testing
@testable import Agencil

@Suite struct MenuTitleTests {
    @Test func titleNamesTheVersion() {
        #expect(MenuTitle.text(version: "1.2.3") == "Agencil 1.2.3")
    }
}
