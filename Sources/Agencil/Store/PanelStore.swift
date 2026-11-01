import AgencilCore
import Foundation
import Observation
import SwiftUI

/// The panel's state: the last `panel` read, what the owner has opened, and the presses in flight. Views render it
/// and call its methods; every `Task` of the panel lives here (docs/DESIGN.md "Enforcement").
@MainActor @Observable final class PanelStore {
    private(set) var data: PanelData?
    private(set) var stopping: Set<String> = []
    @ObservationIgnored private var deciding: Set<String> = []
    private(set) var decided: Set<String> = []
    private(set) var proposals: [ProposalItem] = []
    private(set) var canRollback = false
    private(set) var seen: Set<String> = []
    private(set) var problem: String?
    private(set) var readAt: Date?
    private(set) var starOffer = false
    @ObservationIgnored private var repoStar: RepoStar?
    @ObservationIgnored private var starChecked = false

    @ObservationIgnored private var client: PanelClient?
    @ObservationIgnored private var notifier: PanelNotifier?
    @ObservationIgnored private var control: StopControl?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var reading = false

    /// An inert snapshot: no timers, no broker, no notifications. `nil` is the state before the first read.
    init(data: PanelData?) { self.data = data }

    static func waiting() -> PanelStore { PanelStore(data: nil) }

    static func demo() -> PanelStore {
        let store = PanelStore(data: DemoPanel.data)
        store.starOffer = true
        return store
    }

    /// The running app reads the broker in `~/.agencil`; a home that cannot be opened leaves the panel waiting.
    static func launch() -> PanelStore {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil")
        guard let home = try? AgencilHome(directory: directory, environment: ProcessInfo.processInfo.environment) else { return .waiting() }
        return live(home: home)
    }

    /// The store of the running app: it reads the broker every few seconds and tells the owner what changed.
    static func live(home: AgencilHome) -> PanelStore {
        let store = PanelStore(data: nil)
        let client = PanelClient(home: home)
        store.client = client
        store.repoStar = RepoStar(directory: home.directory)
        store.notifier = PanelNotifier(settings: { (try? ConfigStore(directory: home.directory).read()).flatMap { try? NotifySettings(values: $0.values) } })
        store.control = StopControl(stop: { id in try await client.stop(id) })
        store.start()
        return store
    }

    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// One read at a time: a timer read and a press never commit out of order, so a stale snapshot cannot rearm a notification.
    func refresh() async {
        guard let client, !reading else { return }
        reading = true
        defer { reading = false }
        do {
            let next = try await client.read()
            notifier?.deliver(previous: data, current: next)
            data = next
            problem = nil
            readAt = Date()
            control?.observe(next)
            syncStopping(next)
            await readProposals(client)
            await refreshStarOffer()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The Stop press of one sitting: "Stopping..." shows at once and a second press is nothing.
    func stop(_ id: String) async {
        guard let control else { return }
        stopping.insert(id)
        await control.press(id)
        if case .idle(let reason?) = control.state(for: id) { problem = reason }
        if let data { syncStopping(data) }
    }

    func stopAction(_ id: String) -> () async -> Void { { [self] in await stop(id) } }

    /// The owner's Confirm or Dismiss of one finding: one broker call, then a fresh read.
    func decideAction(_ id: String, confirm: Bool) -> () async -> Void {
        { [self] in
            // One decision at a time per finding, whichever button; a decided finding leaves the list at once.
            guard let client, !deciding.contains(id), !decided.contains(id) else { return }
            deciding.insert(id)
            defer { deciding.remove(id) }
            var failure: String?
            do {
                _ = try await client.call("dispose", ["id": id, "disposition": confirm ? "confirm" : "dismiss"])
                decided.insert(id)
            } catch { failure = error.localizedDescription }
            await refresh()
            if let failure { problem = failure }
        }
    }
    /// Best effort: a failed read leaves the last list, since the panel read itself already reports a dead broker.
    private func readProposals(_ client: PanelClient) async {
        guard let reply = try? await client.call("proposals"), let rows = reply["proposals"] as? [[String: Any]] else { return }
        proposals = rows.compactMap(ProposalItem.init)
        canRollback = reply["can_rollback"] as? Bool == true
    }

    /// The owner's decision on one proposal (`id` nil for the rollback): one broker call, then a fresh read.
    func learnAction(_ id: String?, _ action: String) -> () async -> Void {
        { [self] in
            guard let client, !deciding.contains(id ?? action) else { return }
            deciding.insert(id ?? action)
            defer { deciding.remove(id ?? action) }
            var failure: String?
            var extra = ["action": action]
            if let id { extra["id"] = id }
            do { _ = try await client.call("learn", extra) }
            catch { failure = error.localizedDescription }
            await refresh()
            if let failure { problem = failure }
        }
    }

    /// Asks an independent seat to weigh one finding's evidence: one broker call, then a fresh read.
    func adjudicateAction(_ id: String) -> () async -> Void {
        { [self] in
            guard let client, !deciding.contains(id) else { return }
            deciding.insert(id)
            defer { deciding.remove(id) }
            var failure: String?
            do { _ = try await client.call("adjudicate", ["id": id]) } catch { failure = error.localizedDescription }
            await refresh()
            if let failure { problem = failure }
        }
    }

    /// Asks GitHub once per run, on the first open, and only while `config.json` does not already say starred.
    func refreshStarOffer() async {
        guard let repoStar, !starChecked else { return }
        starChecked = true
        guard repoStar.shouldOffer() else { return }
        starOffer = await repoStar.refresh() == .notStarred
    }

    func star() async {
        guard let repoStar else { return }
        if await repoStar.star() { starOffer = false } else { problem = "Could not star " + RepoStar.repo + ": is gh logged in?" }
    }

    func open(sitting id: String) { seen.insert(id) }

    private func syncStopping(_ data: PanelData) {
        guard let control else { return }
        stopping = Set(stopping.filter { control.state(for: $0) == .stopping })
    }

    // MARK: what the panel shows

    var bento: AgencilCore.Bento? { data.map { PanelModel.bento($0, seen: seen, now: Date()) } }

    var seatChip: String {
        guard let seats = data?.seats else { return "reading seats" }
        if seats.total == 0 { return "no seats" }
        if let down = seats.items.first(where: { !$0.up }), seats.up == seats.total - 1 { return "\(down.name) down" }
        return "\(seats.up)/\(seats.total) seats up"
    }

    var footer: String {
        guard let readAt else { return "Reading..." }
        return "Updated " + readAt.formatted(date: .omitted, time: .standard)
    }

    /// The ring's seats are the configured ones; its events arrive with `feedRing` as claims land.
    var ringSeats: [String] { (data?.seats.items ?? []).map(\.name) }
    private(set) var ringEvents: [SynapseEvent] = []

    func feedRing(_ event: SynapseEvent) { ringEvents.append(event) }

    var ringView: AnyView { AnyView(CouncilRingView(seats: ringSeats, events: ringEvents, live: liveSittings > 0)) }

    var liveSittings: Int { data?.sittings.filter { $0.state == "running" }.count ?? 0 }
    var openFindings: Int { data?.findings.filter { $0.disposition == "open" }.count ?? 0 }
    var liveCount: Int { data?.live ?? 0 }

    var weekSpend: String { (data?.week.spendUSD).map(PanelFormat.money) ?? "..." }

    var weekShare: String? {
        guard let week = data?.week, let budget = week.budgetUSD, budget > 0 else { return nil }
        return "\(Int((week.spendUSD / budget * 100).rounded()))% of budget"
    }

    func threads(filter: String, search: String) -> [DemoPanel.Thread] {
        (data?.threads ?? []).filter { thread in
            switch filter {
            case "Live": thread.state == "asking"
            case "Failed": thread.state == "failed"
            case "Mine": thread.caller == "owner"
            default: true
            }
        }
        .map(DemoPanel.Thread.init)
        .filter { Self.matches(search, [$0.question, $0.caller, $0.seat]) }
    }

    func sittings(search: String) -> [DemoPanel.Sitting] {
        (data?.sittings ?? []).map(DemoPanel.Sitting.init).filter { Self.matches(search, [$0.target, $0.kind, $0.state]) }
    }

    func findings(search: String) -> [DemoPanel.Finding] {
        (data?.findings ?? []).filter { $0.disposition == "open" && !decided.contains($0.id) }.map(DemoPanel.Finding.init)
            .filter { Self.matches(search, [$0.claim, $0.place]) }
    }

    func seats(search: String) -> [DemoPanel.SeatRow] {
        (data?.seats.items ?? []).map(DemoPanel.SeatRow.init).filter { Self.matches(search, [$0.id, $0.model]) }
    }

    private static func matches(_ search: String, _ fields: [String]) -> Bool {
        search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    static func money(_ dollars: Double) -> String { PanelFormat.money(dollars) }
}

/// One open learn proposal as the panel shows it.
struct ProposalItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: String
    let endorsed: Bool
    var needsReview: Bool { status == "proposed" }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let kind = row["kind"] as? String, let council = row["council"] as? String else { return nil }
        let change = [row["seat"], row["replacement"], row["variable"], row["value"]].compactMap { $0 as? String }.joined(separator: " to ")
        let verdict = row["verdict"] as? String
        self.id = id
        title = kind.replacingOccurrences(of: "_", with: " ") + " on " + council
        detail = [change, "n \(row["n"] as? Int ?? 0)", verdict, row["note"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        status = row["status"] as? String ?? "proposed"
        endorsed = status == "reviewed" && verdict == "endorse"
    }
}
