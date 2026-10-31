import AgencilCore
import Foundation
import Observation

/// The panel's state: the last `panel` read, what the owner has opened, and the presses in flight. Views render it
/// and call its methods; every `Task` of the panel lives here (docs/DESIGN.md "Enforcement").
@MainActor @Observable final class PanelStore {
    private(set) var data: PanelData?
    private(set) var stopping: Set<String> = []
    private(set) var seen: Set<String> = []
    private(set) var problem: String?
    private(set) var readAt: Date?

    @ObservationIgnored private var client: PanelClient?
    @ObservationIgnored private var notifier: PanelNotifier?
    @ObservationIgnored private var control: StopControl?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var reading = false

    /// An inert snapshot: no timers, no broker, no notifications. `nil` is the state before the first read.
    init(data: PanelData?) { self.data = data }

    static func waiting() -> PanelStore { PanelStore(data: nil) }

    static func demo() -> PanelStore { PanelStore(data: DemoPanel.data) }

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
        (data?.findings ?? []).filter { $0.disposition == "open" }.map(DemoPanel.Finding.init)
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
