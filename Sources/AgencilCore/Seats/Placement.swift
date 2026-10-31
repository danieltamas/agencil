import Foundation

/// Where a seat may run for a given ask: the checks every candidate passes after resolution and before it
/// takes a reservation (docs/U6-SPEC.md "Admission checks per candidate").
enum Placement {
    /// Nil when the seat may answer on this route; else the refusal that makes the next fallback be tried.
    static func refusal(seat: Seat, route: Route, hasRepo: Bool) -> Refusal? {
        if route.localOnly, seat.hosted {
            return Refusal(exit: 3, message: "refused: residency (\(seat.name) is hosted)")
        }
        var required = route.requires
        if hasRepo, seat.hosted { required.formUnion([.readOnlyFiles, .noNetworkTools]) }
        let missing = required.subtracting(Adapter.enforces(seat.harness)).map(\.name).sorted()
        guard missing.isEmpty else {
            return Refusal(exit: 3, message: "refused: \(seat.harness) cannot enforce \(missing.joined(separator: ", "))")
        }
        return nil
    }
}
