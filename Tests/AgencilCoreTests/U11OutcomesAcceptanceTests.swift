/* API contract: docs/U11-SPEC.md and PLAN U11.
 CommitEvidenceParser.claimIDs(in:) returns ordered unique whole AG ids;
 revertedSHA(in:) recognizes a 40-hex This reverts commit line.
 OutcomeBook(ledger:) records idempotent commit/PR evidence without labels.
 adjudicator(for:seats:synthesizerVendor:) chooses the first independent vendor,
 failing closed for an unknown raiser. adjudicate records answer, seat, certainty,
 reason and time, requires evidence and independence, and cannot override owner.
 dispose records the owner's final confirm/dismiss; the latest owner row wins.
 status(of:now:) uses owner then adjudication labels, otherwise pending until
 30 days since the latest claim/evidence/outcome event, then unresolved.
 FindingGrouper.group(_:links:) transitively joins explicit links or equal non-nil
 kind/file with lines within 3, only within one sitting; ids/seats are sorted.
 Wilson.interval(successes:total:) uses z=1.96; zero total is nil.
 Share exposes numerator, denominator, value, interval, rounded display or n=0.
 scoreboard(now:) sorts council/seat cells with confirmedShare, coverage,
 participation, costPerConfirmed and medianSeconds. No non-golden recall.
 overlap(_:_:council:now:) is confirmed intersection / union, nil for empty.
 GoldenScore.score sums found/known, clean-brief falseAlarm and confirmedShare.
 VotingSeatGate.check requires probation floors and minBriefs; n=0 fails and
 blocked reasons name every failed check and its numbers. Non-probation passes.
 ScoreExport.json(scores:golden:) permits recall only under golden.
 Scoreboard must run below 50 ms on 10,000 claims and 100,000 assessments.
 */
import Foundation
import Testing
import AgencilCore

struct U11OutcomesAcceptanceTests {
    @Test func commitBodyRecordsPendingEvidenceWithoutOutcome() throws {
        let f = try U11Fixture(), id = try f.basic()
        let sha = String(repeating: "a", count: 40)
        #expect(try f.book.recordCommit(sha: sha, body: "Fixes AG-41-3", revertedBody: nil, at: u11Date(1)) == [id])
        let rows = try f.book.evidence(claim: id)
        #expect(rows.count == 1)
        #expect(rows.first?.claim == id && rows.first?.source == "fix-commit" && rows.first?.detail == sha)
        #expect(try f.book.status(of: id, now: u11Date(1)) == .pending)
        #expect(try f.sql("SELECT count(*) FROM outcomes") == [["0"]])
    }

    @Test func claimIDAndRevertParsingRespectWholeTokensAndOrder() {
        #expect(CommitEvidenceParser.claimIDs(in: "XAG-41-3 AG-41 AG-41-3x (AG-41-3), AG-2-10 AG-41-3\nAG-2-1") == ["AG-41-3", "AG-2-10", "AG-2-1"])
        let sha = "0123456789abcdef0123456789ABCDEF01234567"
        #expect(CommitEvidenceParser.revertedSHA(in: "Revert\n\nThis reverts commit \(sha).") == sha)
        #expect(CommitEvidenceParser.revertedSHA(in: "This reverts commit abc.") == nil)
        #expect(CommitEvidenceParser.revertedSHA(in: "This reverts commit \(sha)0.") == nil)
    }

    @Test func commitAndPRDismissalEvidenceAreIdempotentAndSkipUnknownIDs() throws {
        let f = try U11Fixture(), id = try f.basic()
        for _ in 0..<2 {
            _ = try f.book.recordCommit(sha: "first", body: "AG-41-3 AG-999-1", revertedBody: nil, at: u11Date(1))
            _ = try f.book.recordPRDismissal(url: "https://example.com/harbor/checkout/pull/1#comment-1", body: "Dismiss AG-41-3 AG-999-1", at: u11Date(2))
        }
        let rows = try f.book.evidence(claim: id)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.source)) == ["fix-commit", "pr-dismissal"])
        #expect(rows.first { $0.source == "pr-dismissal" }?.detail == "https://example.com/harbor/checkout/pull/1#comment-1")
        #expect(try f.sql("SELECT count(*) FROM outcomes") == [["0"]])
        #expect(try f.book.status(of: id, now: u11Date(2)) == .pending)
    }

    @Test func independentAdjudicatorLabelsAndRecordsProvenance() throws {
        let f = try U11Fixture(), id = try f.basic()
        let maya = try u11Seat("maya", vendor: "alpha"), jonas = try u11Seat("jonas", vendor: "beta")
        let lee = try u11Seat("lee", vendor: "gamma"), other = try u11Seat("other", vendor: "gamma")
        let seats = [maya, jonas, lee, other]
        let selected = try #require(try f.book.adjudicator(for: id, seats: seats, synthesizerVendor: "beta"))
        #expect(selected == lee)
        try f.evidence(id)
        try f.book.adjudicate(claim: id, answer: .confirmed, by: selected, seats: seats,
            synthesizerVendor: "beta", certainty: "high", reason: "reproduced failure", at: u11Date(1))
        #expect(try f.book.status(of: id, now: u11Date(100)) == .confirmed)
        #expect(try f.sql("SELECT source,adjudicator,label,certainty,detail FROM outcomes") ==
                [["adjudication", "lee", "confirmed", "high", "reproduced failure"]])
        #expect(try f.book.adjudicator(for: id, seats: [maya, jonas], synthesizerVendor: "beta") == nil)
        #expect(throws: (any Error).self) { try f.book.adjudicator(for: id, seats: [lee], synthesizerVendor: "beta") }
        #expect(throws: (any Error).self) { try f.book.adjudicator(for: "AG-999-1", seats: seats, synthesizerVendor: "beta") }
    }

    @Test func adjudicationRejectsSharedVendorsAndMissingEvidence() throws {
        let f = try U11Fixture(), id = try f.basic()
        let maya = try u11Seat("maya", vendor: "alpha"), lee = try u11Seat("lee", vendor: "gamma")
        let alias = try u11Seat("jonas", vendor: "alpha"), synth = try u11Seat("synth", vendor: "beta")
        let seats = [maya, alias, synth, lee]
        #expect(throws: (any Error).self) {
            try f.book.adjudicate(claim: id, answer: .confirmed, by: lee, seats: seats,
                synthesizerVendor: "beta", certainty: "high", reason: "no evidence", at: u11Date(1))
        }
        try f.evidence(id)
        for by in [maya, alias, synth] {
            #expect(throws: (any Error).self) {
                try f.book.adjudicate(claim: id, answer: .confirmed, by: by, seats: seats,
                    synthesizerVendor: "beta", certainty: "high", reason: "conflict", at: u11Date(1))
            }
        }
        #expect(try f.sql("SELECT count(*) FROM outcomes") == [["0"]])
    }

    @Test func ownerDismissOverridesLabelAndBlocksFurtherAdjudication() throws {
        let f = try U11Fixture(), id = try f.basic()
        try f.evidence(id); try f.outcome(id, label: "confirmed")
        try f.book.dispose(claim: id, as: .dismiss, reason: "expected behavior", at: u11Date(1))
        #expect(try f.book.status(of: id, now: u11Date(2)) == .refuted)
        #expect(try f.sql("SELECT source,certainty,label,detail FROM outcomes WHERE source='owner'") ==
                [["owner", "final", "refuted", "expected behavior"]])
        let maya = try u11Seat("maya", vendor: "alpha"), lee = try u11Seat("lee", vendor: "gamma")
        #expect(throws: (any Error).self) {
            try f.book.adjudicate(claim: id, answer: .confirmed, by: lee, seats: [maya, lee],
                synthesizerVendor: "beta", certainty: "high", reason: "late", at: u11Date(2))
        }
        try f.book.dispose(claim: id, as: .confirm, reason: nil, at: u11Date(3))
        #expect(try f.book.status(of: id, now: u11Date(4)) == .confirmed)
        let bare = try f.claim(4, line: 50)
        try f.book.dispose(claim: bare, as: .dismiss, reason: nil, at: u11Date(1))
        #expect(try f.book.status(of: bare, now: u11Date(1)) == .refuted)
    }

    @Test func revertAloneNeverConfirmsOrRefutes() throws {
        let f = try U11Fixture(), id = try f.basic(), other = try f.claim(4, line: 40)
        let sha = String(repeating: "b", count: 40)
        #expect(try f.book.recordCommit(sha: "reverting", body: "AG-41-4\nThis reverts commit \(sha).",
            revertedBody: "Fixes AG-41-3", at: u11Date(1)) == [id])
        #expect(try f.book.evidence(claim: id).map(\.source) == ["revert"])
        #expect(try f.book.evidence(claim: id).first?.detail == "reverting")
        #expect(try f.book.evidence(claim: other).isEmpty)
        #expect(try f.book.status(of: id, now: u11Date(1)) == .pending)
        #expect(try f.sql("SELECT count(*) FROM outcomes") == [["0"]])
    }

    @Test func cannotTellIsAnEventAndThirtyDayBoundaryUsesLatestEvent() throws {
        let f = try U11Fixture(), id = try f.basic()
        #expect(try f.book.status(of: id, now: u11Date(29)) == .pending)
        #expect(try f.book.status(of: id, now: u11Date(30)) == .unresolved)
        try f.evidence(id, days: 20)
        #expect(try f.book.status(of: id, now: u11Date(49)) == .pending)
        #expect(try f.book.status(of: id, now: u11Date(50)) == .unresolved)
        let maya = try u11Seat("maya", vendor: "alpha"), lee = try u11Seat("lee", vendor: "gamma")
        try f.book.adjudicate(claim: id, answer: .cannotTell, by: lee, seats: [maya, lee],
            synthesizerVendor: "beta", certainty: "low", reason: "insufficient evidence", at: u11Date(40))
        #expect(try f.sql("SELECT label,adjudicator,certainty,detail FROM outcomes") ==
                [["cannot-tell", "lee", "low", "insufficient evidence"]])
        #expect(try f.book.status(of: id, now: u11Date(69)) == .pending)
        #expect(try f.book.status(of: id, now: u11Date(70)) == .unresolved)
        try f.outcome(id, label: "refuted", days: 71)
        try f.outcome(id, label: "cannot-tell", days: 72)
        #expect(try f.book.status(of: id, now: u11Date(200)) == .refuted)
    }

    @Test func staleUnlabelledFindingsAreExcludedFromScoresAndExport() throws {
        let f = try U11Fixture(), stale = try f.basic()
        let confirmed = try f.claim(4, line: 40), refuted = try f.claim(5, line: 70)
        let pending = try f.claim(6, line: 100, days: 29)
        try f.outcome(confirmed, label: "confirmed"); try f.outcome(refuted, label: "refuted")
        #expect(try f.book.status(of: stale, now: u11Date(30)) == .unresolved)
        #expect(try f.book.status(of: pending, now: u11Date(30)) == .pending)
        let scores = try f.book.scoreboard(now: u11Date(30)), score = try #require(scores.first)
        #expect(scores.count == 1)
        #expect(score.confirmedShare == Share(1, of: 2))
        #expect(score.coverage == Share(1, of: 1))
        let json = ScoreExport.json(scores: scores, golden: [:])
        #expect(!json.contains(stale) && !json.contains(pending))
    }

    @Test func duplicatesCreditEachSeatOnceAndMetricsUseValidSittings() throws {
        let f = try U11Fixture()
        try f.sitting(); try f.seat(cost: 2, seconds: 10); try f.seat("jonas", cost: 3, seconds: 20)
        let a = try f.claim(1), b = try f.claim(2, seat: "jonas"), c = try f.claim(3, line: 12)
        for id in [a, b, c] { try f.outcome(id, label: "confirmed") }
        let solo = try f.claim(4, seat: "jonas", line: 80)
        try f.outcome(solo, label: "confirmed")
        let wrong = try f.claim(5, line: 150); try f.outcome(wrong, label: "refuted")
        try f.sitting(42); try f.seat(sitting: 42, exit: 1, cost: 4, seconds: 30)
        try f.seat("jonas", sitting: 42, cost: 1, seconds: 40)
        let missed = try f.claim(1, sitting: 42, seat: "jonas"); try f.outcome(missed, label: "confirmed")
        try f.sitting(43); try f.seat(sitting: 43, exit: nil, cost: 6, seconds: 50)
        try f.sitting(44, council: "audit"); try f.seat("lee", sitting: 44)
        let scores = try f.book.scoreboard(now: u11Date(1))
        #expect(scores.map { "\($0.council)/\($0.seat)" } == ["audit/lee", "review/jonas", "review/maya"])
        let maya = try #require(scores.first { $0.seat == "maya" })
        #expect(maya.confirmedShare == Share(1, of: 2))
        #expect(maya.coverage == Share(1, of: 2))
        #expect(maya.participation == Share(1, of: 3))
        #expect(maya.costPerConfirmed == 12 && maya.medianSeconds == 30)
        let jonas = try #require(scores.first { $0.seat == "jonas" })
        #expect(jonas.confirmedShare == Share(3, of: 3))
        #expect(jonas.coverage == Share(3, of: 3))
        #expect(jonas.participation == Share(2, of: 2))
        #expect(jonas.costPerConfirmed == 4.0 / 3.0 && jonas.medianSeconds == 30)
        let lee = try #require(scores.first { $0.seat == "lee" })
        #expect(lee.confirmedShare == Share(0, of: 0) && lee.coverage == Share(0, of: 0))
        #expect(lee.costPerConfirmed == nil)
        #expect(try f.book.overlap("maya", "jonas", council: "review", now: u11Date(1)) == 1.0 / 3.0)
        #expect(try f.book.overlap("maya", "jonas", council: "audit", now: u11Date(1)) == nil)
    }

    @Test func findingGroupsAreTransitiveDeterministicAndSittingBounded() {
        func row(_ id: String, _ sitting: String = "41", _ seat: String = "maya",
                 _ kind: String? = "defect", _ file: String? = "cart.swift", _ line: Int? = 10) -> ClaimRow {
            ClaimRow(id: id, sitting: sitting, seat: seat, kind: kind, file: file, line: line)
        }
        let rows = [row("AG-41-2"), row("AG-41-10", "41", "jonas", "defect", "cart.swift", 13),
                    row("AG-41-3", "41", "maya", "defect", "cart.swift", 16),
                    row("AG-41-4", "41", "lee", nil, nil, nil), row("AG-42-1", "42"),
                    row("AG-41-5", "41", "lee", nil, nil, nil),
                    row("AG-41-6", "41", "lee", "security", "cart.swift", 10)]
        let groups = FindingGrouper.group(rows, links: [["AG-41-3", "AG-41-4", "AG-42-1"]])
        #expect(groups == FindingGrouper.group(Array(rows.reversed()), links: [["AG-42-1", "AG-41-4", "AG-41-3"]]))
        #expect(groups.count == 4)
        let joined = groups.first { $0.id == "AG-41-10" }
        #expect(joined?.claimIDs == ["AG-41-10", "AG-41-2", "AG-41-3", "AG-41-4"])
        #expect(joined?.seats == ["jonas", "lee", "maya"])
        #expect(groups.first { $0.id == "AG-42-1" }?.claimIDs == ["AG-42-1"])
    }

    @Test func wilsonMatchesIndependentTextbookReferenceToThreeDecimals() throws {
        // Independently: (p+z*z/(2*n) +/- z*sqrt(p*(1-p)/n+z*z/(4*n*n))) / (1+z*z/n).
        #expect(Wilson.interval(successes: 0, total: 0) == nil)
        let references: [(Int, Int, Double, Double)] = [(8, 10, 0.490, 0.943),
            (1, 1, 0.207, 1.000), (0, 5, 0.000, 0.434), (50, 100, 0.404, 0.596)]
        for (successes, total, lower, upper) in references {
            let actual = try #require(Wilson.interval(successes: successes, total: total))
            #expect(u11Rounded(actual.lower) == lower && u11Rounded(actual.upper) == upper)
            let share = try #require(Share(successes, of: total).interval)
            #expect(u11Rounded(share.lower) == lower && u11Rounded(share.upper) == upper)
        }
        #expect(Share(0, of: 0).display == "n=0")
        #expect(Share(0, of: 0).value == nil && Share(0, of: 0).interval == nil)
        #expect(Share(2, of: 3).display == "67%" && Share(0, of: 5).display == "0%")
        #expect(Share(2, of: 3).value == 2.0 / 3.0)
        #expect(Share(1, of: 2) != Share(2, of: 4))
    }

    @Test func goldenRecallIncludesFailedBriefsAndCleanBriefsMeasureFalseAlarms() {
        let score = GoldenScore.score([
            .init(brief: "found", known: 4, found: 3, raisedBlocker: true, confirmedClaims: 3, refutedClaims: 1),
            .init(brief: "failed", known: 2, found: 0, raisedBlocker: false, confirmedClaims: 0, refutedClaims: 0),
            .init(brief: "abstained", known: 4, found: 0, raisedBlocker: false, confirmedClaims: 0, refutedClaims: 0),
            .init(brief: "clean", known: 0, found: 0, raisedBlocker: false, confirmedClaims: 0, refutedClaims: 0),
            .init(brief: "alarm", known: 0, found: 0, raisedBlocker: true, confirmedClaims: 0, refutedClaims: 2)])
        #expect(score.briefs == 5 && score.recall == Share(3, of: 10))
        #expect(score.falseAlarm == Share(1, of: 2) && score.confirmedShare == Share(3, of: 6))
        let empty = GoldenScore.score([])
        #expect(empty.briefs == 0 && empty.recall.display == "n=0" && empty.falseAlarm.display == "n=0")
        #expect(empty.confirmedShare.display == "n=0")
    }

    @Test func probationGateEnforcesEveryFloorAndExplainsFailures() throws {
        func golden(_ count: Int, _ found: Int, _ confirmed: Int) -> GoldenScore {
            GoldenScore.score((0..<count).map { .init(brief: "brief-\($0)", known: 10, found: found,
                raisedBlocker: false, confirmedClaims: confirmed, refutedClaims: 10 - confirmed) })
        }
        var floors = Floors()
        #expect(floors.recall == 0.5 && floors.confirmedShare == 0.6 && floors.minBriefs == 10)
        #expect(VotingSeatGate.check(onProbation: true, golden: golden(10, 5, 6), floors: floors) == .allowed)
        #expect(VotingSeatGate.check(onProbation: false, golden: nil, floors: floors) == .allowed)
        let decision = VotingSeatGate.check(onProbation: true, golden: golden(9, 4, 5), floors: floors)
        guard case .blocked(let reason) = decision else { Issue.record("below-floor seat allowed"); return }
        #expect(reason.contains("golden recall 0.40 < 0.50"))
        #expect(reason.contains("0.50 < 0.60") && reason.contains("9") && reason.contains("10"))
        #expect(VotingSeatGate.check(onProbation: true, golden: nil, floors: floors) != .allowed)
        #expect(VotingSeatGate.check(onProbation: true, golden: GoldenScore.score([]), floors: floors) != .allowed)
        let clean = GoldenScore.score((0..<10).map { .init(brief: "clean-\($0)", known: 0, found: 0,
            raisedBlocker: false, confirmedClaims: 0, refutedClaims: 0) })
        #expect(clean.briefs == 10 && clean.recall.display == "n=0")
        #expect(VotingSeatGate.check(onProbation: true, golden: clean, floors: floors) != .allowed)
        floors.recall = 0.8; floors.confirmedShare = 0.9; floors.minBriefs = 11
        #expect(VotingSeatGate.check(onProbation: true, golden: golden(10, 5, 6), floors: floors) != .allowed)
    }

    @Test func exportAndSeatScoreHaveRecallOnlyInsideGolden() throws {
        let f = try U11Fixture(), id = try f.basic()
        try f.outcome(id, label: "confirmed")
        let scores = try f.book.scoreboard(now: u11Date(1)), score = try #require(scores.first)
        #expect(!Mirror(reflecting: score).children.contains { $0.label?.lowercased().contains("recall") == true })
        let text = ScoreExport.json(scores: scores, golden: ["maya": GoldenScore.score([])])
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(root.keys) == ["scores", "golden"])
        let cells = try #require(root["scores"] as? [[String: Any]])
        let cell = try #require(cells.first)
        #expect(Set(cell.keys) == ["seat", "council", "confirmedShare", "coverage", "participation", "costPerConfirmed", "medianSeconds"])
        for key in ["confirmedShare", "coverage", "participation"] {
            let share = try #require(cell[key] as? [String: Any])
            #expect(Set(share.keys) == ["numerator", "denominator", "display"])
            #expect(share["numerator"] as? Int == 1 && share["denominator"] as? Int == 1)
            #expect(share["display"] as? String == "100%")
        }
        let golden = try #require(root["golden"] as? [String: [String: Any]])
        #expect(golden["maya"]?["recall"] != nil)
        let nongolden = try JSONSerialization.data(withJSONObject: root.filter { $0.key != "golden" })
        #expect(!String(decoding: nongolden, as: UTF8.self).lowercased().contains("recall"))
    }

    @Test func scoreboardTenThousandClaimsAndHundredThousandAssessmentsUnderFiftyMilliseconds() throws {
        let f = try U11Fixture()
        try f.sql("BEGIN IMMEDIATE")
        try f.sitting(); try f.seat()
        // Recursive inserts keep all fixture creation within the same transaction.
        try f.sql("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
            INSERT INTO claims(id,run_id,seat_run_id,body,kind,file,line,created_at)
            SELECT 'AG-41-'||x,'41','41-maya','missing check','defect','src/cart.swift',x*10,? FROM n
            """, [f.stamp(0)])
        try f.sql("""
            INSERT INTO outcomes(id,claim_id,source,adjudicator,certainty,label,created_at)
            SELECT 'o-'||id,id,'adjudication','lee','high','confirmed',? FROM claims
            """, [f.stamp(1)])
        try f.sql("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10)
            INSERT INTO assessments(id,claim_id,seat_run_id,stance,reason,created_at,run_id,snapshot_id)
            SELECT claims.id||'-'||n.x,claims.id,'41-maya','agree','checked',?,'41','41' FROM claims CROSS JOIN n
            """, [f.stamp(1)])
        try f.sql("COMMIT")
        #expect(try f.sql("SELECT count(*) FROM claims") == [["10000"]])
        #expect(try f.sql("SELECT count(*) FROM assessments") == [["100000"]])
        var best = Double.infinity
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let scores = try f.book.scoreboard(now: u11Date(2))
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            best = min(best, seconds)
            #expect(scores.count == 1)
            #expect(scores.first?.confirmedShare == Share(10000, of: 10000))
            #expect(scores.first?.coverage == Share(10000, of: 10000))
        }
        #expect(best < 0.050, "best scoreboard duration: \(best) seconds")
    }
}
