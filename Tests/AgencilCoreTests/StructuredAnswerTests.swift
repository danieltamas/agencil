import Foundation
import Testing
@testable import AgencilCore

/// A seat's JSON answer and a brief, read as structure for the detail screen.
@Suite struct StructuredAnswerTests {
    private let council = """
    {"assessments":[{"claim":"AG-1","stance":"dispute","why":"The diff shows otherwise."}],
     "claims":[{"id":"c1","kind":"defect","severity":"p1","confidence":0.95,"file":"src/charge.ts","line":88,
                "evidence":"The retry re-sends the key.","fix":"Keep the first body."}],
     "notes":"Looks fine.","vote":"block"}
    """

    @Test func aCouncilAnswerBecomesClaimsAssessmentsVoteAndNotes() throws {
        let answer = try #require(StructuredAnswer(council))
        #expect(answer.vote == "block" && answer.notes == "Looks fine.")
        #expect(answer.claims.count == 1 && answer.claims[0].place == "src/charge.ts:88" && answer.claims[0].severity == "P1")
        #expect(answer.claims[0].body.text == "The retry re-sends the key." && answer.claims[0].body.confidence == "95%")
        #expect(answer.assessments == [.init(claim: "AG-1", stance: "dispute", why: "The diff shows otherwise.")])
    }

    @Test func emptyListsAndEmptyNotesStayEmpty() throws {
        let answer = try #require(StructuredAnswer(#"{"assessments":[],"claims":[],"notes":"","vote":"approve"}"#))
        #expect(answer.claims.isEmpty && answer.assessments.isEmpty && answer.notes == nil && answer.vote == "approve")
    }

    @Test func fencedJsonIsReadAndProseIsNot() {
        #expect(StructuredAnswer("```json\n" + #"{"vote":"approve"}"# + "\n```")?.vote == "approve")
        for text in ["Fixing a typo is fine.", "", "{broken", "[1,2]", #"{"other":1}"#] { #expect(StructuredAnswer(text) == nil, "\(text)") }
    }

    @Test func aHugeConfidenceDoesNotTrap() throws {
        let answer = try #require(StructuredAnswer(#"{"claims":[{"id":"c","confidence":1e300,"evidence":"x"}]}"#))
        #expect(answer.claims[0].body.confidence == "100%")
    }

    @Test func aBriefBecomesLabelledFactsWithMultiLineValues() throws {
        let facts = try #require(BriefFacts.parse("change_kind: refactor\nquestion: Is it risky?\nOne sentence.\nauthor_vendor: unknown"))
        #expect(facts.map(\.name) == ["Change kind", "Question", "Author vendor"])
        #expect(facts.map(\.value) == ["refactor", "Is it risky?\nOne sentence.", "unknown"])
    }

    @Test func textThatIsNotAKeyedBriefStaysText() {
        #expect(BriefFacts.parse("Please review the diff: it is large.") == nil)
        #expect(BriefFacts.parse("") == nil)
    }
}
