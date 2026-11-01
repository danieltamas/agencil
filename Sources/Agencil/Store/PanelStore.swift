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
        store.detailReader = { DemoPanel.detailJSON($0) ?? [:] }
        return store
    }

    /// The demo panel with one detail screen open and already filled in, for the screenshots.
    static func demo(opening id: String) -> PanelStore {
        let store = demo()
        if id.hasPrefix("f") { store.open(finding: id) }
        else if id.hasPrefix("s") { store.open(sitting: id) }
        else { store.open(thread: id) }
        if let json = DemoPanel.detailJSON(id), let open = store.detail { store.detail = store.rebuilt(open, json: json) }
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
        store.detailReader = { id in try await client.call("detail", ["id": id]) }
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
            if detail?.live == true { await loadDetail() }
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

    // MARK: detail screens

    /// The broker's `detail` reply for one thread or sitting id; the demo store answers from `DemoPanel`.
    @ObservationIgnored var detailReader: ((String) async throws -> [String: Any])?
    @ObservationIgnored private var detailLoad: Task<Void, Never>?
    private(set) var detail: DetailPage?

    func open(thread id: String) {
        guard let row = data?.threads.first(where: { $0.id == id }) else { return }
        present(.thread(row, detail: nil))
    }

    func open(sitting id: String) {
        seen.insert(id)
        guard let row = data?.sittings.first(where: { $0.id == id }) else { return }
        present(.sitting(row, detail: nil))
    }

    func open(finding id: String) {
        guard let row = data?.findings.first(where: { $0.id == id }) else { return }
        present(.finding(DemoPanel.Finding(row)))
    }

    func closeDetail() {
        detailLoad?.cancel()
        detail = nil
    }

    private func present(_ page: DetailPage) {
        detail = page
        detailLoad?.cancel()
        guard page.kind != .finding else { return }
        detailLoad = Task { [weak self] in await self?.loadDetail() }
    }

    /// Rebuilds the open page from the latest row and the broker's detail; a failed read keeps what is shown and says why.
    private func loadDetail() async {
        guard let reader = detailReader, let open = detail, open.kind != .finding else { return }
        do {
            let json = try await reader(open.id)
            guard !Task.isCancelled, detail?.id == open.id else { return }
            detail = rebuilt(open, json: json)
        } catch {
            guard detail?.id == open.id else { return }
            detail?.problem = error.localizedDescription
            detail?.loading = false
        }
    }

    private func rebuilt(_ open: DetailPage, json: [String: Any]) -> DetailPage {
        switch open.kind {
        case .thread:
            guard let row = data?.threads.first(where: { $0.id == open.id }) else { return open }
            return .thread(row, detail: ThreadDetail(json: json))
        case .sitting:
            guard let row = data?.sittings.first(where: { $0.id == open.id }) else { return open }
            return .sitting(row, detail: SittingDetail(json: json))
        case .finding:
            return open
        }
    }

    /// A seat row opens that seat in Settings; the caller brings the window forward.
    func open(seat name: String) { SettingsRoute.shared.show(seat: name) }

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

    /// The chip's colour: all up is ok, a seat down is crit (warn when every down seat is only busy), nothing to judge is unknown.
    var seatChipColor: Color {
        guard let seats = data?.seats, seats.total > 0 else { return Theme.unknown }
        let down = seats.items.filter { !$0.up }
        if down.isEmpty { return Theme.ok }
        return down.allSatisfy { $0.reason == "busy" } ? Theme.warn : Theme.crit
    }

    /// How old the last read of each source is, for the footer: the seats' probe and the panel read itself.
    var pollAges: [(symbol: String, age: String)] {
        guard let readAt else { return [] }
        var ages: [(symbol: String, age: String)] = []
        if let probed = (data?.seats.items ?? []).compactMap(\.probedAgo).min() { ages.append(("person.2.wave.2", Self.age(probed))) }
        ages.append(("arrow.triangle.2.circlepath", Self.age(max(0, Date().timeIntervalSince(readAt)))))
        return ages
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

    /// "40s", "5m", "2h": how long ago, for the footer's poll age.
    static func age(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: "\(Int(seconds))s"
        case ..<3600: "\(Int(seconds / 60))m"
        default: "\(Int(seconds / 3600))h"
        }
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
