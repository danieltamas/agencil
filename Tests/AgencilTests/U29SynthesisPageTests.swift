import AgencilCore
import Foundation
import Testing
@testable import Agencil

func u29PanelData() throws -> PanelData {
    try PanelData(json: [
        "configured": true, "seats": ["total": 0, "up": 0, "thinking": 0, "items": [[String: Any]]()],
        "threads": [[String: Any]](), "findings": [[String: Any]](), "proposals_pending": 0,
        "week": ["spend_usd": 0], "live": 0,
        "sittings": [["id": "sit_harbor", "no": 1, "council": "panel", "question": "Is harbor ready?",
                      "state": "done", "verdict": "PASS", "round": "synthesis", "cost_usd": 0,
                      "started": "2030-01-01T12:00:00Z", "ended": "2030-01-01T12:00:07Z"]]
    ])
}

func u29DetailJSON(summary: String? = nil, fallback: Bool = false) -> [String: Any] {
    var json: [String: Any] = [
        "question": "Is harbor ready?", "brief": "change_kind: design\nquestion: Is harbor ready?",
        "verdict": ["verdict": "PASS", "reasons": ["majority approve"],
                    "votes": [["seat": "a", "state": "done", "vote": "approve"],
                              ["seat": "b", "state": "done", "vote": "approve"]]],
        "rounds": [
            ["round": "blind", "seats": [["seat": "a", "state": "answered", "answer": "EARLY_A"],
                                          ["seat": "b", "state": "answered", "answer": "EARLY_B"]]],
            ["round": "rebuttal", "seats": [["seat": "a", "state": "answered", "answer": "FINAL_A"],
                                             ["seat": "b", "state": "answered", "answer": "FINAL_B"]]]
        ]
    ]
    if let summary {
        json["summary"] = summary
        json["summary_by"] = fallback ? "a" : "d"
        json["summary_fallback"] = fallback
    }
    return json
}

@Suite struct U29SynthesisPageTests {
    // A12: the real compose action opts in at its external broker boundary.
    @Test @MainActor func startSittingRequestsSynthesis() async throws {
        let store = PanelStore(data: DemoPanel.data)
        var wakes: [[String: Any]] = []
        store.brokerRequest = { request in
            if request["op"] as? String == "councils" {
                return ["councils": [["name": "panel"]]]
            }
            #expect(request["op"] as? String == "wake")
            wakes.append(request)
            return ["sitting": "s-new", "state": "running"]
        }
        store.detailReader = { _ in ["state": "running", "rounds": []] }
        await store.newSitting()
        try #require(store.compose != nil)
        store.compose?.council = "panel"
        store.compose?.kind = "design"
        store.compose?.question = "Inspect harbor checkout"
        await store.startSitting()
        #expect(wakes.count == 1)
        let request = try #require(wakes.first)
        #expect(request["synthesize"] as? Bool == true)
        #expect(store.detail?.id == "s-new")
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    // A7: both captions, absent/loading states, and the complete copy payload.
    @Test func sittingSynthesisAndRecordMarkdownReflectSummaryAndFinalAnswers() throws {
        let row = try #require(u29PanelData().sittings.first)
        let markdown = "## Answer\n**Ready.**\n\n## Recommendation\n- Review once."
        for fallback in [false, true] {
            let page = DetailPage.sitting(row, detail: SittingDetail(json: u29DetailJSON(summary: markdown, fallback: fallback)))
            let synthesis = try #require(page.synthesis)
            #expect(synthesis.markdown == markdown)
            #expect(synthesis.writer == (fallback ? "written by a, no synthesizer is set" : "written by d"))
            let record = try #require(page.recordMarkdown)
            #expect(record.hasPrefix("# Is harbor ready?\n"))
            let verdict = try #require(record.range(of: "PASS"))
            let summary = try #require(record.range(of: markdown))
            #expect(verdict.upperBound <= summary.lowerBound)
            for seat in ["a", "b"] {
                let heading = "### " + seat
                #expect(record.components(separatedBy: "\n").filter { $0 == heading }.count == 1)
                let position = try #require(record.range(of: heading))
                #expect(summary.upperBound <= position.lowerBound)
                #expect(record.contains("FINAL_" + seat.uppercased()))
                #expect(!record.contains("EARLY_" + seat.uppercased()))
            }
        }
        for detail in [nil, SittingDetail(json: u29DetailJSON())] as [SittingDetail?] {
            let page = DetailPage.sitting(row, detail: detail)
            #expect(page.synthesis == nil)
            #expect(page.recordMarkdown == nil)
        }
        // Pin presentation order at the actual view boundary, since synthesis is
        // a separate model property, not an item in page.sections.
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/Agencil/Views/Panel/PanelDetailView.swift"), encoding: .utf8)
        let tokens = GuardScanner.tokens(source).map(\.text)
        let synthesis = try #require(tokens.firstIndex(of: "synthesis"))
        let brief = try #require(tokens.firstIndex(of: "brief"))
        #expect(synthesis < brief)
    }

    // A8: only the kit may add block Markdown parsing. The sole pre-U29
    // inline renderer is PanelDetailView.styled, explicitly grandfathered below.
    @Test func viewsDoNotImplementBlockMarkdownOutsideKit() throws {
        let files = try GuardScanner.files(in: Self.root.appendingPathComponent("Sources/Agencil/Views"))
        #expect(!files.isEmpty)
        let existingInline = "Sources/Agencil/Views/Panel/PanelDetailView.swift"
        var violations: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(Self.root.path.count + 1))
            let tokens = GuardScanner.tokens(try String(contentsOf: file, encoding: .utf8))
            var inlineCount = 0
            for (index, token) in tokens.enumerated() {
                if token.text == "inlineOnlyPreservingWhitespace" {
                    inlineCount += 1
                    if relative != existingInline { violations.append("\(relative):\(token.line): inline Markdown belongs in MarkdownBlock") }
                }
                if token.text == "interpretedSyntax" {
                    let end = min(tokens.count, index + 5)
                    if tokens[index..<end].contains(where: { $0.text == "full" }) {
                        violations.append("\(relative):\(token.line): full Markdown belongs in MarkdownBlock")
                    }
                }
                if token.text == "MarkdownDocument" {
                    violations.append("\(relative):\(token.line): block parsing belongs in MarkdownBlock")
                }
            }
            if relative == existingInline { #expect(inlineCount <= 1, "Only the existing styled helper is allowed") }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Sources/Agencil/Kit/MarkdownBlock.swift").path))
    }
}
