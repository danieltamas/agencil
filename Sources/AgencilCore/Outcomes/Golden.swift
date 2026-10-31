import Foundation

/// One seat on one golden brief, whose every defect is known.
public struct GoldenResult: Equatable, Sendable {
    public let brief: String
    public let known: Int
    public let found: Int
    public let raisedBlocker: Bool
    public let confirmedClaims: Int
    public let refutedClaims: Int

    public init(brief: String, known: Int, found: Int, raisedBlocker: Bool, confirmedClaims: Int, refutedClaims: Int) {
        self.brief = brief
        self.known = known
        self.found = found
        self.raisedBlocker = raisedBlocker
        self.confirmedClaims = confirmedClaims
        self.refutedClaims = refutedClaims
    }
}

/// The only place a recall exists: on the golden set, where the defects are all known.
public struct GoldenScore: Equatable, Sendable {
    public let briefs: Int
    public let recall: Share
    public let falseAlarm: Share
    public let confirmedShare: Share

    /// One result per brief: a repeated brief id counts once (the first), so repeats cannot pad the sample.
    public static func score(_ all: [GoldenResult]) -> GoldenScore {
        var seen = Set<String>()
        let results = all.filter { seen.insert($0.brief).inserted }
        let defective = results.filter { $0.known > 0 }, clean = results.filter { $0.known == 0 }
        let confirmed = results.reduce(0) { $0 + $1.confirmedClaims }, refuted = results.reduce(0) { $0 + $1.refutedClaims }
        return GoldenScore(briefs: results.count,
                           recall: Share(defective.reduce(0) { $0 + $1.found }, of: defective.reduce(0) { $0 + $1.known }),
                           falseAlarm: Share(clean.filter(\.raisedBlocker).count, of: clean.count),
                           confirmedShare: Share(confirmed, of: confirmed + refuted))
    }
}

public struct Floors: Equatable, Sendable {
    public var recall = 0.5
    public var confirmedShare = 0.6
    public var minBriefs = 10
    public init() {}
}

public enum GateDecision: Equatable, Sendable {
    case allowed
    case blocked(reason: String)
}

public enum VotingSeatGate {
    /// A seat on probation votes only after enough golden briefs at or above both floors; an empty share fails.
    public static func check(onProbation: Bool, golden: GoldenScore?, floors: Floors) -> GateDecision {
        guard onProbation else { return .allowed }
        guard floors.recall.isFinite, floors.confirmedShare.isFinite, floors.minBriefs > 0 else {
            return .blocked(reason: "the council type's probation floors are invalid")
        }
        guard let golden else { return .blocked(reason: "no golden results yet; \(floors.minBriefs) golden briefs are required") }
        var failures: [String] = []
        if golden.briefs < floors.minBriefs { failures.append("\(golden.briefs) golden briefs < \(floors.minBriefs) required") }
        func check(_ name: String, _ share: Share, _ floor: Double) {
            let floorText = String(format: "%.2f", floor)
            guard let value = share.value else { return failures.append("golden \(name) n=0 < \(floorText)") }
            if value < floor { failures.append("golden \(name) \(String(format: "%.2f", value)) < \(floorText)") }
        }
        check("recall", golden.recall, floors.recall)
        check("confirmed share", golden.confirmedShare, floors.confirmedShare)
        return failures.isEmpty ? .allowed : .blocked(reason: failures.joined(separator: "; "))
    }
}

public enum ScoreExport {
    private static func share(_ share: Share) -> [String: Any] {
        ["numerator": share.numerator, "denominator": share.denominator, "display": share.display]
    }

    /// `recall` appears only inside "golden".
    public static func json(scores: [SeatScore], golden: [String: GoldenScore]) -> String {
        let cells: [[String: Any]] = scores.map {
            ["seat": $0.seat, "council": $0.council, "confirmedShare": share($0.confirmedShare), "coverage": share($0.coverage),
             "participation": share($0.participation), "costPerConfirmed": $0.costPerConfirmed ?? NSNull(),
             "medianSeconds": $0.medianSeconds ?? NSNull()]
        }
        let known = golden.mapValues { score -> [String: Any] in
            ["briefs": score.briefs, "recall": share(score.recall), "falseAlarm": share(score.falseAlarm),
             "confirmedShare": share(score.confirmedShare)]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["scores": cells, "golden": known], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
