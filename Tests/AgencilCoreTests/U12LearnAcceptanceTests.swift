/*
 U12 API contract (docs/U12-SPEC.md and PLAN U12):
 LearnLoop(ledger:directory:) reads OutcomeBook scoreboard cells and config.json.
 propose(now:candidates:ideas:) writes and returns new Proposals; proposals() lists
 all oldest first. minOutcomes is 20 decided findings, per cell for drop/swap,
 summed per council for add/prompt. Drop requires Wilson upper < 0.30 and leaves
 at least two seats; the first outside different-vendor candidate makes it a swap.
 Add requires at least two eligible coverage cells, all below 0.5. PromptIdea
 (council:variable:value:) changes one variable at a time. Open proposals dedupe.
 Proposal exposes id, kind, council, seat, replacement, variable, value, status,
 n, evidence JSON, reviewer, verdict. ProposalKind has dropSeat/addSeat/swapSeat/
 promptChange; ReviewVerdict has endorse/object. reviewer(for:) selects the first
 configured vendor independent of every touched seat. review(_:by:verdict:note:at:)
 resolves the caller by name, rejects unknown/non-independent/non-proposed reviews,
 and records reviewed status. reject(_:at:) accepts proposed/reviewed only.
 Only approve(_:at:) mutates config, after review and revision/membership checks.
 It preserves other keys, validates SeatConfig, records baseline then new version,
 and marks applied. ConfigVersion exposes version, hash (lowercase SHA-256 of exact
 councils text), body. versions() is oldest first. rollback(at:) restores the
 previous councils bytes as a new version and marks its proposal rolled_back;
 no previous version throws. Dates are injected and all listed operations throw.
 */
import Foundation
import CryptoKit
import Testing
import AgencilCore

struct U12LearnAcceptanceTests {
    @Test func underMinimumWritesNoProposal() throws {
        let f = try U12Fixture()
        try f.seed(19)
        let before = try f.bytes()
        #expect(LearnLoop.minOutcomes == 20)
        #expect(try f.propose(ideas: [.init(council: "review", variable: "tone", value: "brief")]).isEmpty)
        #expect(try f.loop.proposals().isEmpty)
        #expect(try f.bytes() == before)
        try f.seed(1, sitting: 42)
        let proposals = try f.propose()
        let drop = try #require(proposals.first { $0.kind == .dropSeat })
        #expect(drop.n == 20 && drop.seat == "maya" && drop.council == "review")
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(drop.evidence.utf8)) as? [String: Any])
        #expect(evidence["n"] as? Int == 20)
        #expect(evidence["cell"] as? [String: Any] != nil)
        let share = try #require(evidence["confirmedShare"] as? [String: Any])
        #expect(share["numerator"] as? Int == 0)
        #expect(share["denominator"] as? Int == 20)
    }

    @Test func approvedProposalVersionsConfigAndNextSittingReadsIt() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let original = try f.store.read().values, body = try f.councilBody()
        let proposal = try f.drop()
        try f.reviewed(proposal)
        let version = try f.loop.approve(proposal.id, at: u12Now)
        let versions = try f.loop.versions()
        #expect(versions.count == 2)
        #expect(versions.map(\.version) == [1, 2])
        #expect(versions.first?.body == body)
        #expect(versions.last == version)
        #expect(version.body == (try f.councilBody()))
        let digest = SHA256.hash(data: Data(version.body.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(version.hash == digest)
        #expect(try f.config().council(named: "review")?.seats == ["jonas", "lee"])
        let nextRead = ConfigStore(directory: f.directory)
        #expect(try SeatConfig(values: nextRead.read().values).council(named: "review")?.seats == ["jonas", "lee"])
        let after = try f.store.read().values
        for (key, value) in original where key != "councils" { #expect(after[key] == value) }
        #expect(try f.loop.proposals().first?.status == "applied")
    }

    @Test func rollbackRestoresExactPreviousVersionHashAndBody() throws {
        let f = try U12Fixture()
        u12Refuses { try f.loop.rollback(at: u12Now) }
        try f.seed(20)
        let body = try f.councilBody(), p = try f.drop()
        try f.reviewed(p)
        _ = try f.loop.approve(p.id, at: u12Now)
        let baseline = try #require(try f.loop.versions().first)
        let restored = try f.loop.rollback(at: u12Now.addingTimeInterval(1))
        #expect(restored.version == 3)
        #expect(restored.hash == baseline.hash)
        #expect(restored.body == body)
        #expect(try f.councilBody() == body)
        #expect(try f.config().council(named: "review")?.seats == ["maya", "jonas", "lee"])
        #expect(try f.loop.proposals().first?.status == "rolled_back")
        #expect(try f.loop.versions().count == 3)
    }

    @Test func reviewerUsesConfigOrderAndAllTouchedVendors() throws {
        let f = try U12Fixture(vendors: ["harbor", "lumen", "cedar", "maple"])
        try f.seed(20)
        let candidate = try f.seat("rory")
        let p = try #require(try f.propose(candidates: [candidate]).first { $0.kind == .swapSeat })
        let reviewer = try #require(try f.loop.reviewer(for: p.id))
        #expect(reviewer.name == "jonas")
        #expect(reviewer.vendor != (try f.seat("maya").vendor))
        #expect(reviewer.vendor != candidate.vendor)
        try f.reviewed(p)
        let recorded = try #require(try f.loop.proposals().first)
        #expect(recorded.status == "reviewed" && recorded.reviewer == "jonas")
        #expect(recorded.verdict == .endorse)
        u12Refuses { try f.loop.review(p.id, by: reviewer, verdict: .object, note: "again", at: u12Now) }
    }

    @Test func nothingChangesWithoutOwnerApproval() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let before = try f.bytes(), p = try f.drop()
        #expect(try f.bytes() == before)
        u12Refuses { try f.loop.approve(p.id, at: u12Now) }
        #expect(try f.bytes() == before)
        try f.reviewed(p, verdict: .object)
        #expect(try f.bytes() == before)
        try f.loop.reject(p.id, at: u12Now)
        #expect(try f.bytes() == before)
        #expect(try f.loop.proposals().first?.status == "rejected")
        #expect(try f.loop.versions().isEmpty)
        u12Refuses { try f.loop.approve(p.id, at: u12Now) }
        u12Refuses { try f.loop.reject(p.id, at: u12Now) }
        #expect(try f.bytes() == before)
    }

    @Test func wilsonUpperBoundControlsDropAtAdjacentCounts() throws {
        // For n=20, 1 confirmed is below 0.30; 2 confirmed is above it.
        #expect(u12Wilson(1, 20).upper < 0.30)
        #expect(u12Wilson(2, 20).upper > 0.30)
        for confirmed in [1, 2] {
            let f = try U12Fixture()
            try f.seed(20, confirmed: confirmed)
            let score = try #require(try OutcomeBook(ledger: f.ledger).scoreboard(now: u12Now).first)
            #expect(score.confirmedShare.numerator == confirmed)
            #expect(score.confirmedShare.denominator == 20)
            let drops = try f.propose().filter { $0.kind == .dropSeat }
            #expect(drops.count == (u12Wilson(confirmed, 20).upper < 0.30 ? 1 : 0))
        }
    }

    @Test func twoSeatCouncilCannotDropAndOtherCouncilCannotSupplyMinimum() throws {
        let f = try U12Fixture(members: ["maya", "jonas"])
        try f.seed(20)
        #expect(try f.propose().isEmpty)
        let g = try U12Fixture()
        try g.seed(19)
        try g.seed(20, sitting: 42, council: "other")
        #expect(try g.propose().filter { $0.council == "review" }.isEmpty)
    }

    @Test func swapPreferredAndReplacesSeatInPlace() throws {
        let f = try U12Fixture(members: ["jonas", "maya", "lee"])
        try f.seed(20)
        var sameVendor = try f.seat("rory")
        sameVendor.vendor = "harbor"
        // Candidate ordering skips an existing member and same-vendor outsider.
        let p = try #require(try f.propose(candidates: [f.seat("jonas"), sameVendor, f.seat("rory")])
            .first { $0.kind == .swapSeat })
        #expect(p.seat == "maya" && p.replacement == "rory" && p.n == 20)
        #expect(try f.loop.proposals().filter { $0.kind == .dropSeat }.isEmpty)
        try f.reviewed(p)
        _ = try f.loop.approve(p.id, at: u12Now)
        #expect(try f.config().council(named: "review")?.seats == ["jonas", "rory", "lee"])
    }

    @Test func addRequiresTwoLowCoverageCellsAndAppendsFirstCandidate() throws {
        let f = try U12Fixture()
        // Each confirmed finding is unique; maya and jonas see 20 but raise zero.
        try f.seed(20, confirmed: 20, seat: "lee", participants: ["maya", "jonas", "lee"])
        // lee's high coverage is below the eligibility denominator via invalid answer.
        try f.sql("UPDATE seat_runs SET exit_code=1 WHERE seat='lee'")
        let p = try #require(try f.propose(candidates: [f.seat("maya"), f.seat("rory")])
            .first { $0.kind == .addSeat })
        #expect(p.replacement == "rory" && p.n == 20)
        try f.reviewed(p)
        _ = try f.loop.approve(p.id, at: u12Now)
        #expect(try f.config().council(named: "review")?.seats == ["maya", "jonas", "lee", "rory"])
    }

    @Test func addRefusedForHighCoverageOrOnlyOneEligibleCell() throws {
        for participants in [["maya", "jonas", "lee"], ["maya", "lee"]] {
            let f = try U12Fixture()
            try f.seed(20, confirmed: 20, seat: "lee", participants: participants)
            if participants.count == 2 { try f.sql("UPDATE seat_runs SET exit_code=1 WHERE seat='lee'") }
            #expect(try f.propose(candidates: [f.seat("rory")]).filter { $0.kind == .addSeat }.isEmpty)
        }
    }

    @Test func coverageExactlyOneHalfDoesNotProposeAddition() throws {
        let f = try U12Fixture()
        try f.seed(10, confirmed: 10, participants: ["maya", "jonas"])
        try f.seed(10, confirmed: 10, seat: "jonas", sitting: 42, participants: ["maya", "jonas"])
        let cells = try OutcomeBook(ledger: f.ledger).scoreboard(now: u12Now)
        #expect(cells.count == 2)
        for cell in cells {
            #expect(cell.coverage.numerator == 10 && cell.coverage.denominator == 20)
        }
        #expect(try f.propose(candidates: [f.seat("rory")]).filter { $0.kind == .addSeat }.isEmpty)
    }

    @Test func pendingEvidenceDoesNotReachDecidedMinimum() throws {
        let f = try U12Fixture()
        try f.seed(19)
        let time = ISO8601DateFormatter().string(from: u12Now)
        try f.sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) VALUES('AG-41-99','41','41-maya','missing check','defect','p1','src/cart.swift',999,?)", [time])
        try f.sql("INSERT INTO evidence(id,claim_id,source,detail,created_at) VALUES('pending','AG-41-99','fix-commit','sha',?)", [time])
        #expect(try f.propose(ideas: [.init(council: "review", variable: "tone", value: "brief")]).isEmpty)
        #expect(try f.loop.proposals().isEmpty)
    }

    @Test func promptUsesCouncilMinimumAndOneVariableAtATime() throws {
        let f = try U12Fixture()
        try f.seed(10, confirmed: 10)
        try f.seed(10, confirmed: 10, seat: "jonas", sitting: 42)
        let ideas = [PromptIdea(council: "review", variable: "tone", value: "brief"),
                     PromptIdea(council: "review", variable: "depth", value: "high")]
        let prompts = try f.propose(ideas: ideas).filter { $0.kind == .promptChange }
        #expect(prompts.count == 1)
        let p = try #require(prompts.first)
        #expect(p.n == 20 && p.variable == "tone" && p.value == "brief")
        #expect(try f.loop.reviewer(for: p.id)?.name == "rory")
        #expect(try f.propose(ideas: ideas).isEmpty)
        try f.reviewed(p)
        #expect(try f.propose(ideas: ideas).isEmpty)
        _ = try f.loop.approve(p.id, at: u12Now)
        let variant = try #require(try f.councilObject()["prompt_variant"] as? [String: String])
        #expect(variant == ["variable": "tone", "value": "brief"])
        #expect(try f.propose(ideas: [ideas[1]]).isEmpty)
        #expect(try f.propose(ideas: [.init(council: "review", variable: "tone", value: "detailed")])
            .filter { $0.kind == .promptChange }.count == 1)
    }

    @Test func openProposalsDeduplicateAndRejectedProposalsAreRetained() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let first = try f.drop()
        #expect(first.status == "proposed")
        #expect(try f.propose().isEmpty)
        try f.reviewed(first)
        #expect(try f.propose().isEmpty)
        try f.loop.reject(first.id, at: u12Now)
        let second = try f.drop()
        #expect(second.id != first.id)
        #expect(try f.loop.proposals().map(\.id) == [first.id, second.id])
    }

    @Test func forgedAndUnknownReviewersAreRefusedWithoutMutation() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let p = try f.drop(), before = try f.bytes()
        var forged = try f.seat("maya")
        forged.vendor = "maple"
        u12Refuses { try f.loop.review(p.id, by: forged, verdict: .endorse, note: "forged", at: u12Now) }
        let unknownConfig = try SeatConfig(values: ["seats": u12JSON([
            ["name": "unknown", "harness": "codex", "model": "demo", "vendor": "maple"]])])
        let unknown = try #require(unknownConfig.seats.first)
        u12Refuses { try f.loop.review(p.id, by: unknown, verdict: .endorse, note: "unknown", at: u12Now) }
        #expect(try f.loop.proposals().first?.status == "proposed")
        #expect(try f.bytes() == before)
        let g = try U12Fixture(vendors: ["harbor", "harbor", "harbor", "harbor"])
        try g.seed(20)
        let other = try g.drop()
        #expect(try g.loop.reviewer(for: other.id) == nil)
    }

    @Test func staleRevisionApprovalRefusesAndPreservesCurrentBytes() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let p = try f.drop()
        try f.reviewed(p)
        _ = try f.store.update { $0["unrelated"] = "owner changed this" }
        let before = try f.bytes()
        u12Refuses { try f.loop.approve(p.id, at: u12Now) }
        #expect(try f.bytes() == before)
        #expect(try f.loop.proposals().first?.status == "reviewed")
    }

    @Test func changedCouncilAndInvalidResultApprovalRefuseAtomically() throws {
        for invalidQuorum in [false, true] {
            let f = try U12Fixture(extra: invalidQuorum ? ["quorum": 3] : [:])
            try f.seed(20)
            let p = try f.drop()
            try f.reviewed(p)
            if !invalidQuorum {
                let changed = try u12JSON([["name": "review", "seats": ["jonas", "lee"]]])
                _ = try f.store.update { $0["councils"] = changed }
            }
            let before = try f.bytes()
            u12Refuses { try f.loop.approve(p.id, at: u12Now) }
            #expect(try f.bytes() == before)
            #expect(try f.loop.proposals().first?.status == "reviewed")
        }
    }
}
