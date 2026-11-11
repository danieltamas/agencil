/* API contract
 HarnessFinding.init(kind:found:version:signedIn:).
 SetupPlan.kinds, propose(_:), council(_:), routes(callers:council:), pending(_:existing:).
 SetupProposal.seats, missing; ProposedSeat.draft, state, checked.
 ProposedSeat.State.ready, unconfirmed, signIn(command:), noAdapter.
 Adapter.runs(_:); SeatPreset.all, named(_:), draft.
 SeatDraft.init(name:harness:model:vendor:), mutable model and capSeconds.
 CouncilDraft.name, seats, quorum, rule, mode; RouteDraft.init(callers:target:).
 ConfigEditor.init(directory:), add(SeatDraft/CouncilDraft/RouteDraft).
 ConfigSnapshot.values; SeatConfig.init(values:), seats, councils, routes.
 ConfigStore.init(directory:), read(). No process or broker test hooks.
 */
import Foundation
import Testing
@testable import AgencilCore

struct U37SetupPlanAcceptanceTests {
    private func finding(_ kind: String, _ signedIn: String = "yes", found: Bool = true) -> HarnessFinding {
        HarnessFinding(kind: kind, found: found, version: found ? "1.0" : nil, signedIn: signedIn)
    }

    private func draft(_ name: String) throws -> SeatDraft {
        try #require(SeatPreset.named(name)).draft
    }

    // Acceptance 1.
    @Test func mixedFindingsProposePresetStatesInCatalogOrder() throws {
        #expect(SetupPlan.kinds == ["claude", "codex", "opencode", "gemini", "antigravity"])
        let proposal = SetupPlan.propose([
            finding("antigravity", found: false), finding("gemini"), finding("opencode", "unknown"),
            finding("codex", "no"), finding("claude")
        ])
        let free = SeatPreset.all.filter { $0.harness == "opencode" }
        #expect(!free.isEmpty)
        #expect(proposal.seats.map(\.draft.name) == ["claude-opus", "gpt-codex"] + free.map(\.name) + ["gemini"])
        let claude = try #require(proposal.seats.first { $0.draft.name == "claude-opus" })
        #expect(claude.draft == (try draft("claude-opus")))
        #expect(claude.state == .ready && claude.checked)
        let codex = try #require(proposal.seats.first { $0.draft.name == "gpt-codex" })
        #expect(codex.draft == (try draft("gpt-codex")))
        #expect(codex.state == .signIn(command: "codex login") && !codex.checked)
        for (index, preset) in free.enumerated() {
            let seat = try #require(proposal.seats.first { $0.draft.name == preset.name })
            #expect(seat.draft == preset.draft)
            #expect(seat.state == .ready)
            #expect(seat.checked == (index == 0))
        }
        let gemini = try #require(proposal.seats.first { $0.draft.name == "gemini" })
        #expect(gemini.state == .noAdapter && !gemini.checked)
        #expect(proposal.missing == ["antigravity"])
    }

    // Acceptance 2.
    @Test func unknownClaudeSignInIsUnconfirmedAndChecked() throws {
        let seats = SetupPlan.propose([finding("claude", "unknown")]).seats
        #expect(seats.count == 1)
        let seat = try #require(seats.first)
        #expect(seat.draft == (try draft("claude-opus")))
        #expect(seat.state == .unconfirmed && seat.checked)
    }

    // Acceptance 3.
    @Test func absentFindingsAndUnsupportedKindsYieldOnlyMissingKinds() {
        for findings in [[HarnessFinding](), [finding("aider")]] {
            let proposal = SetupPlan.propose(findings)
            #expect(proposal.seats.isEmpty)
            #expect(proposal.missing == SetupPlan.kinds)
        }
    }

    // Acceptance 4.
    @Test func adapterRunnableKindsMatchContract() {
        for kind in ["codex", "claude", "opencode", "hermes"] { #expect(Adapter.runs(kind)) }
        for kind in ["gemini", "aider", "goose", "ollama", "antigravity"] { #expect(!Adapter.runs(kind)) }
    }

    // Acceptance 5, including first-of-vendor selection in input order.
    @Test func councilRequiresTwoVendorsAndUsesFirstSeatOfEach() throws {
        let seats = try ["claude-opus", "gpt-codex", "glm-free", "deepseek-free"].map { try draft($0) }
        let council = try #require(SetupPlan.council(seats))
        #expect(council.name == "review")
        #expect(council.seats == seats.map(\.name))
        #expect(council.quorum == 2 && council.rule == "any_blocker" && council.mode == "review")
        var secondClaude = seats[0]
        secondClaude.name = "second-claude"
        #expect(SetupPlan.council([seats[0], secondClaude]) == nil)
        #expect(SetupPlan.council([seats[0]]) == nil)
        #expect(SetupPlan.council([seats[0], secondClaude, seats[1]])?.seats == [seats[0].name, seats[1].name])
    }

    // Acceptance 6.
    @Test func routesDropDuplicateCallersAndPreserveOrder() {
        #expect(SetupPlan.routes(callers: ["claude", "codex", "claude"], council: "review") == [
            RouteDraft(callers: ["claude"], target: "review"), RouteDraft(callers: ["codex"], target: "review")
        ])
    }

    // Acceptance 7.
    @Test func pendingSkipsExistingNamesWithoutReordering() throws {
        let seats = try ["glm-free", "claude-opus", "gpt-codex", "deepseek-free"].map { try draft($0) }
        #expect(SetupPlan.pending(seats, existing: ["claude-opus", "deepseek-free"]) == [seats[0], seats[2]])
    }

    // Acceptance 8. The explicit directory is the temp AGENCIL_HOME; no global environment mutation.
    @Test func plannedWritesParseAndPreserveExistingSeatBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let editor = ConfigEditor(directory: directory)
        var existing = try draft("claude-opus")
        existing.model = "existing-model"
        existing.capSeconds = 321
        let before = try editor.add(existing)
        let originalSeats = try #require(before.values["seats"])
        let originalSeat = try #require(try seatBytes(originalSeats, name: existing.name))
        let proposed = SetupPlan.propose([finding("claude"), finding("codex"), finding("opencode")])
        let checked = proposed.seats.filter(\.checked).map(\.draft)
        let pending = SetupPlan.pending(checked, existing: [existing.name])
        #expect(!pending.contains { $0.name == existing.name })
        for seat in pending { try editor.add(seat) }
        let council = try #require(SetupPlan.council(pending))
        try editor.add(council)
        let routes = SetupPlan.routes(callers: ["claude", "codex", "opencode"], council: council.name)
        for route in routes { try editor.add(route) }
        let file = directory.appendingPathComponent("config.json")
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let values = try #require(document["values"] as? [String: String])
        let parsed = try SeatConfig(values: values)
        #expect(parsed.seats.map(\.name) == [existing.name] + pending.map(\.name))
        #expect(parsed.councils.map(\.name) == ["review"])
        #expect(parsed.routes.map(\.callers) == routes.map(\.callers))
        #expect(parsed.routes.allSatisfy { $0.target == "review" })
        #expect(try seatBytes(try #require(values["seats"]), name: existing.name) == originalSeat)
    }

    // Extract the literal object's bytes, without decoding and re-encoding it.
    // ConfigEditor writes compact, sorted-key JSON; braces inside strings must be ignored.
    private func seatBytes(_ text: String, name: String) throws -> Data? {
        let bytes = Array(text.utf8)
        var depth = 0, start = 0
        var quoted = false, escaped = false
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            if byte == 123 { if depth == 0 { start = index }; depth += 1 }
            if byte == 125 {
                depth -= 1
                if depth == 0 {
                    let data = Data(bytes[start...index])
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if object?["name"] as? String == name { return data }
                }
            }
        }
        return nil
    }
}
