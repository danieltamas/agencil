import AgencilCore
import Foundation
import Testing
@testable import Agencil

func u33DetailJSON(position: String = "Keep harbor small", crux: String = "Measured demand would change this") -> [String: Any] {
    let positions: [[String: Any]] = [
        ["seat": "a", "vendor": "harbor", "label": "P2",
         "blind": ["position": "Wait for demand", "confidence": 0.5],
         "final": ["position": position, "confidence": 0.75, "reasoning": "**Capacity** matters", "crux": crux],
         "kept": false, "because": "Capacity was measured", "new_evidence": true,
         "questions_back": ["How many callers?"], "minority": true],
        ["seat": "b", "vendor": "lumen", "label": "P1",
         "blind": ["position": "Expand harbor now", "confidence": 0.8],
         "final": ["position": "Expand harbor now", "confidence": 0.8, "reasoning": "Demand is rising", "crux": "A smaller forecast"],
         "kept": true, "questions_back": [], "minority": false]
    ]
    var json = u29DetailJSON(summary: "## Answer\na and b split on capacity.")
    json["verdict"] = ["mode": "consult", "verdict": "SPLIT", "reasons": [], "claims": [],
        "positions": positions, "minority": [["seat": "a", "vendor": "harbor", "position": position]],
        "assessments": [["seat": "b", "about": "a", "stance": "disagree", "why": "Forecast differs"]],
        "votes": [["seat": "a", "state": "done", "valid": true], ["seat": "b", "state": "done", "valid": true]]]
    let answer: [String: Any] = ["position": position, "confidence": 0.75, "reasoning": "**Capacity** matters",
        "crux": crux, "questions_back": ["How many callers?"],
        "assessments": [["position": "P1", "stance": "disagree", "why": "Forecast differs"]],
        "kept": false, "because": "Capacity was measured", "new_evidence": true]
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    json["rounds"] = [["round": "rebuttal", "seats": [["seat": "a", "state": "answered", "answer": text]]]]
    return json
}

@Suite struct U33ConsultPageTests {
    // A12: preserve consult structure and the existing review presentation.
    @Test func structuredConsultAndReviewAnswersRemainDistinct() throws {
        let text = """
        {"position":"Keep harbor small","confidence":0.75,"reasoning":"**Capacity** matters",
        "crux":"Measured demand","questions_back":["How many callers?"],"kept":false,
        "because":"Capacity was measured","new_evidence":true,
        "assessments":[{"position":"P1","stance":"disagree","why":"Forecast differs"}]}
        """
        let answer = try #require(StructuredAnswer(text))
        let consult = try #require(answer.consult)
        #expect(consult.position == "Keep harbor small" && consult.confidence == "75%")
        #expect(consult.reasoning == "**Capacity** matters" && consult.crux == "Measured demand")
        #expect(consult.questionsBack == ["How many callers?"])
        #expect(consult.assessments.count == 1)
        #expect(consult.assessments[0].label == "P1" && consult.assessments[0].stance == "disagree")
        #expect(consult.assessments[0].why == "Forecast differs")
        #expect(consult.change == "Capacity was measured")
        let review = try #require(StructuredAnswer(#"{"vote":"approve","claims":[],"assessments":[],"notes":"Keep it"}"#))
        #expect(review.consult == nil && review.vote == "approve" && review.notes == "Keep it")
        #expect(review.claims.isEmpty && review.assessments.isEmpty)
        let unchanged = try #require(StructuredAnswer(#"{"position":"Wait","confidence":0.5,"reasoning":"Evidence","crux":"Demand","kept":true}"#))
        #expect(unchanged.consult?.change == nil)
    }

    // A12: decode broker JSON then project through the same detail-page seam as U29.
    @Test func consultDetailPositionsKeepOrderConfidenceChangeAndMinority() throws {
        let row = try #require(u29PanelData().sittings.first)
        let detail = SittingDetail(json: u33DetailJSON())
        #expect(detail.mode == "consult")
        #expect(detail.positions.map(\.seat) == ["a", "b"])
        #expect(detail.positions.map(\.finalPosition) == ["Keep harbor small", "Expand harbor now"])
        #expect(detail.positions.map(\.confidence) == [0.75, 0.8])
        #expect(detail.positions.map(\.changed) == [true, false])
        #expect(detail.positions.map(\.minority) == [true, false])
        let page = DetailPage.sitting(row, detail: detail)
        #expect(page.positions.count == 2)
        #expect(page.positions.map(\.seat) == ["a", "b"])
        #expect(page.positions.map(\.changed) == [true, false])
        #expect(page.positions.map(\.minority) == [true, false])
        let review = SittingDetail(json: u29DetailJSON())
        #expect(review.mode == "review" && review.positions.isEmpty)
        #expect(DetailPage.sitting(row, detail: review).positions.isEmpty)
    }
}
