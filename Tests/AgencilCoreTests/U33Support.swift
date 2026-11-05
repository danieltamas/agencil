@testable import AgencilCore
import Foundation
import Testing

func u33Answer(_ seat: String = "a", review: Bool = false, stance: String = "agree",
               extra: [String: Any] = [:]) -> [String: Any] {
    var answer: [String: Any] = ["position": "POSITION_" + seat, "confidence": 0.75,
        "reasoning": "REASON_" + seat, "crux": "CRUX_" + seat, "questions_back": ["Which constraint matters?"]]
    if review {
        answer["kept"] = true
        // The broker ignores unshown labels. Supplying the superset avoids guessing
        // the sitting's random permutation and exercises that filtering too.
        answer["assessments"] = (1...3).map {
            ["position": "P\($0)", "stance": stance, "why": "ARGUMENT_" + seat]
        }
    }
    return answer.merging(extra) { _, b in b }
}

func u33Rig(_ extra: [String: Any] = [:], seats: [[String: Any]] = u7aSeats()) throws -> U7aRig {
    let r = try U7aRig()
    try r.configure(u7aCouncil(["mode": "consult", "seats": ["a", "b"],
        "rounds": ["rebuttal": true, "challenge": true]].merging(extra) { _, b in b }), seats: seats)
    for seat in ["a", "b", "c", "d"] {
        try r.reply(seat, "blind", u6aText(u33Answer(seat)))
        try r.reply(seat, "rebuttal", u6aText(u33Answer(seat, review: true)))
        try r.reply(seat, "synthesis", u6aText(["summary": "## Answer\nSeats a, b, c and d retain their positions."]))
    }
    return r
}

@discardableResult
func u33Decided(_ r: U7aRig, _ expected: String, brief: String =
    "change_kind: design\nquestion: inspect harbor\n", extra: [String] = []) throws -> [String: Any] {
    // U7aRig.decided predates consult's successful verdicts. Its wake seam still
    // checks the real CLI exit status, including INCOMPLETE's existing exit 2.
    let v = try r.verdict(r.wake(extra, exit: expected == "INCOMPLETE" ? 2 : 0, brief: brief))
    #expect(v["verdict"] as? String == expected)
    #expect(v["state"] as? String == "done")
    return v
}

func u33Config(_ councils: [[String: Any]]) throws -> SeatConfig {
    try SeatConfig(values: ["seats": u6aText(u7aSeats()), "councils": u6aText(councils)])
}

func u33Consult(_ object: [String: Any], review: Bool = false) throws -> ConsultAnswer {
    try AnswerContract.parseConsult(u6aText(object), review: review).get()
}

func u33Reject(_ object: [String: Any], key: String, review: Bool = false) throws {
    switch AnswerContract.parseConsult(try u6aText(object), review: review) {
    case .success: Issue.record("Accepted invalid consult field: \(key)")
    case .failure(let problem): #expect(problem.message.contains(key))
    }
}
