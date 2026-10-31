import Foundation

extension LearnLoop {
    static let maxNoteLength = 2000
    /// Harnesses that only ever run their own vendor's models; any other harness can serve any vendor's model.
    private static let singleVendorHarnesses: Set<String> = ["claude", "codex", "gemini"]

    /// Seat vendors the independence rule may trust: a single-vendor harness, or a vendor the owner wrote down.
    /// A generic harness with no explicit vendor defaults to its own name, which says nothing about the model.
    private struct Vendors {
        let config: SeatConfig
        let explicit: Set<String>

        init(values: [String: String], config: SeatConfig) {
            self.config = config
            let listed = (try? SeatConfig.array(values["seats"], "seats")) ?? []
            explicit = Set(listed.compactMap { $0["vendor"] is String ? $0["name"] as? String : nil })
        }

        func vendor(of name: String?) -> String? {
            guard let name, let seat = config.seat(named: name), !seat.vendor.isEmpty,
                  explicit.contains(name) || LearnLoop.singleVendorHarnesses.contains(seat.harness) else { return nil }
            return seat.vendor
        }
    }

    /// The vendors of every seat the proposal touches, or nil when one is unknown: an unknown vendor cannot be
    /// shown to differ from the reviewer's, so nobody may review.
    private func touchedVendors(_ proposal: Proposal, _ known: Vendors) -> Set<String>? {
        let names: [String?]
        switch proposal.kind {
        case .dropSeat: names = [proposal.seat]
        case .addSeat: names = [proposal.replacement]
        case .swapSeat: names = [proposal.seat, proposal.replacement]
        case .promptChange:
            guard let council = known.config.council(named: proposal.council) else { return nil }
            names = council.seats
        }
        let vendors = names.map { known.vendor(of: $0) }
        guard !vendors.isEmpty, !vendors.contains(where: { $0 == nil }) else { return nil }
        return Set(vendors.compactMap { $0 })
    }

    /// The first seat in config order whose vendor differs from every seat the proposal touches.
    public func reviewer(for proposal: String) throws -> Seat? {
        guard let found = try ledger.locked({ try loadProposals(id: proposal) }).first else {
            throw LearnError(message: "unknown proposal \(proposal)")
        }
        let values = try store.read().values
        let known = Vendors(values: values, config: try SeatConfig(values: values))
        guard let touched = touchedVendors(found, known) else { return nil }
        return known.config.seats.first { seat in known.vendor(of: seat.name).map { !touched.contains($0) } ?? false }
    }

    /// `by` is looked up by name in the current config; the caller's copy of the seat is never trusted. A review
    /// made against an older config revision is stale and may be made again.
    public func review(_ proposal: String, by: Seat, verdict: ReviewVerdict, note: String, at: Date) throws {
        guard note.count <= Self.maxNoteLength else { throw LearnError(message: "the review note is too long") }
        let snapshot = try store.read()
        let known = Vendors(values: snapshot.values, config: try SeatConfig(values: snapshot.values))
        guard let vendor = known.vendor(of: by.name) else {
            throw LearnError(message: "\(by.name) is not a configured seat with a known vendor")
        }
        try transition(proposal, from: ["proposed", "reviewed"], to: "reviewed") { found in
            if found.status == "reviewed", found.reviewRevision == snapshot.revision {
                throw LearnError(message: "proposal \(proposal) is already reviewed")
            }
            guard let touched = touchedVendors(found, known), !touched.contains(vendor) else {
                throw LearnError(message: "seat \(by.name) may not review \(proposal): it shares a vendor with a seat it touches")
            }
            var body = found.storedBody
            body.reviewer = by.name
            body.verdict = verdict.rawValue
            body.note = note
            body.reviewedAt = OutcomeBook.stamp(at)
            body.reviewRevision = snapshot.revision
            return body
        }
    }

    public func reject(_ proposal: String, at: Date) throws {
        try transition(proposal, from: ["proposed", "reviewed"], to: "rejected") { $0.storedBody }
    }
}
