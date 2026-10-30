import Foundation
import Testing

@Suite struct SourceGuardTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func check(_ rule: GuardScanner.Rule) throws {
        let fixtures = Self.root.appendingPathComponent("Tests/Fixtures/Guards/\(rule.rawValue)")
        let good = try GuardScanner.files(in: fixtures.appendingPathComponent("good"))
        let bad = try GuardScanner.files(in: fixtures.appendingPathComponent("bad"))
        #expect(!good.isEmpty)
        #expect(!bad.isEmpty)
        let clean = try GuardScanner.violations(guard: rule, in: good)
        #expect(clean.isEmpty, "Good fixtures: \(clean.map(\.description).joined(separator: "\n"))")
        if rule == .press {
            let missing = try GuardScanner.violations(guard: rule, in: [])
            #expect(missing.contains { $0.rule.contains("found 0") && $0.line == 1 })
            let duplicate = try GuardScanner.violations(guard: rule, in: good + good)
            #expect(duplicate.contains { $0.rule.contains("found 2") })
        }
        let seeded = try GuardScanner.violations(guard: rule, in: bad)
        #expect(!seeded.isEmpty, "Seeded \(rule.rawValue) violation must be red")
        // Every adversarial file is checked, rather than accepting one hit for the whole tree.
        let goodNames = Set(good.map(\.lastPathComponent))
        for file in bad where !goodNames.contains(file.lastPathComponent) {
            #expect(seeded.contains { $0.file == file.path && $0.line > 0 && $0.description.contains("\(file.path):\($0.line):") },
                    "Missing file:line violation for \(file.path)")
        }
        let source = try GuardScanner.files(in: Self.root.appendingPathComponent("Sources/Agencil"))
        #expect(!source.isEmpty)
        let violations = try GuardScanner.violations(guard: rule, in: source)
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    @Test func press() throws { try check(.press) }
    @Test func buttons() throws { try check(.buttons) }
    @Test func font() throws { try check(.font) }
    @Test func sizeAndSpacing() throws { try check(.size) }
    @Test func color() throws { try check(.color) }
    @Test func nativeControls() throws { try check(.nativeControls) }
    @Test func scheme() throws { try check(.scheme) }
    @Test func motion() throws { try check(.motion) }
    @Test func sheet() throws { try check(.sheet) }
    @Test func kitPurity() throws { try check(.purity) }
}

@Suite struct ScannerGuardTests {
    @Test func commentsStringsAndLineNumbers() {
        let source = ##"""
        // Task {
        let label = "Button("
        /* Task {
           /* Button( */ await work()
        */
        let raw = #"Task { Button("#; Task.detached {}
        let multiline = """
        Button( Task {
        """
        let escaped = "a\"Button("; await work()
        """##
        let tokens = GuardScanner.tokens(source)
        #expect(tokens.filter { $0.text == "Task" }.map(\.line) == [6])
        #expect(tokens.filter { $0.text == "await" }.map(\.line) == [10])
        #expect(!tokens.contains { $0.text == "Button" })
    }
}
