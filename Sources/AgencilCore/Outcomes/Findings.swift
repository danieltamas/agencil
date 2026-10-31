import Foundation

public struct ClaimRow: Equatable, Sendable {
    public let id: String
    public let sitting: String
    public let seat: String
    public let kind: String?
    public let file: String?
    public let line: Int?

    public init(id: String, sitting: String, seat: String, kind: String?, file: String?, line: Int?) {
        self.id = id
        self.sitting = sitting
        self.seat = seat
        self.kind = kind
        self.file = file
        self.line = line
    }
}

/// Claims that are one finding; each seat that raised it is credited once.
public struct Finding: Equatable, Sendable {
    public let id: String
    public let claimIDs: [String]
    public let seats: [String]
}

public enum FindingGrouper {
    /// Claims of one sitting join when linked, or when they share kind and file and sit within 3 lines.
    public static func group(_ claims: [ClaimRow], links: [[String]]) -> [Finding] {
        var parent = Array(0..<claims.count)
        var position: [String: Int] = [:]
        for (index, claim) in claims.enumerated() { position[claim.id] = index }
        for link in links {
            var firstOfSitting: [String: Int] = [:]
            for index in link.compactMap({ position[$0] }) {
                if let first = firstOfSitting[claims[index].sitting] { union(&parent, first, index) } else { firstOfSitting[claims[index].sitting] = index }
            }
        }
        let ordered = claims.indices.sorted { a, b in
            let (x, y) = (claims[a], claims[b])
            if x.sitting != y.sitting { return x.sitting < y.sitting }
            if x.kind != y.kind { return (x.kind ?? "") < (y.kind ?? "") }
            if x.file != y.file { return (x.file ?? "") < (y.file ?? "") }
            return (x.line ?? 0) < (y.line ?? 0)
        }
        joinNearby(claims, order: ordered, parent: &parent)

        var members: [Int: [Int]] = [:]
        for index in claims.indices { members[find(&parent, index), default: []].append(index) }
        return members.values.map { indexes in
            let ids = indexes.map { claims[$0].id }.sorted()
            return Finding(id: ids[0], claimIDs: ids, seats: Array(Set(indexes.map { claims[$0].seat })).sorted())
        }.sorted { $0.id < $1.id }
    }

    /// Walks `order` once: neighbours with one sitting, kind and file whose lines differ by at most 3 join.
    private static func joinNearby(_ claims: [ClaimRow], order: [Int], parent: inout [Int]) {
        var previous: Int?
        for index in order {
            let claim = claims[index]
            guard claim.kind != nil, claim.file != nil, let line = claim.line else { previous = nil; continue }
            if let before = previous {
                let other = claims[before]
                if other.sitting == claim.sitting, other.kind == claim.kind, other.file == claim.file, line - other.line! <= 3 {
                    union(&parent, before, index)
                }
            }
            previous = index
        }
    }

    private static func find(_ parent: inout [Int], _ index: Int) -> Int {
        var index = index
        while parent[index] != index {
            parent[index] = parent[parent[index]]
            index = parent[index]
        }
        return index
    }

    private static func union(_ parent: inout [Int], _ a: Int, _ b: Int) {
        let (x, y) = (find(&parent, a), find(&parent, b))
        if x != y { parent[x] = y }
    }
}
