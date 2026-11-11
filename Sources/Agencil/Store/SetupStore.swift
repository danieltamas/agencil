import AgencilCore
import Foundation

/// The first-run Setup window (docs/U37-SPEC.md): what is installed, the seats it proposes, one council and the routes
/// to it. Every step writes only on its own press, through the same `ConfigEditor` the Settings sheets use, and the
/// config is read again before each write.
@MainActor @Observable final class SetupStore {
    enum Step: CaseIterable { case found, council, routes, done }

    /// The Setup window's scene id, for opening and closing it.
    static let windowID = "setup"
    /// A council needs two seats to compare answers.
    static let councilMinimum = 2

    var step: Step = .found
    private(set) var proposal = SetupProposal(seats: [], missing: [])
    private(set) var checked: Set<String> = []
    private(set) var detecting = false
    /// The kinds the probe found, so the routes step offers only agents that are installed.
    private(set) var foundKinds: [String] = []
    private(set) var versions: [String: String] = [:]
    /// False until the first Find agents press has come back.
    private(set) var searched = false
    /// Every seat the config holds once the seats step is written: the council step picks from these.
    private(set) var candidates: [SeatDraft] = []
    private(set) var members: [String] = []
    private(set) var councilName = ""
    private(set) var targets: [String] = []
    private(set) var routes: [RouteDraft] = []
    /// A caller pressed first; the next target pressed makes the route, as a drag would.
    private(set) var pickedCaller: String?
    private(set) var written: [String] = []
    private(set) var problem: String?

    @ObservationIgnored private let settings: SettingsStore?

    init(settings: SettingsStore?) {
        self.settings = settings
    }

    /// Inert: no broker, no file. The proposal is already made from `findings`, as after a probe.
    static func demo(findings: [HarnessFinding]) -> SetupStore {
        let store = SetupStore(settings: nil)
        store.apply(findings)
        return store
    }

    /// True while the config has no seat: a missing, empty or `[]` `seats` value.
    static func shouldOpen(values: [String: String]) -> Bool {
        let seats = values["seats"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !seats.isEmpty else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(seats.utf8)) as? [Any])?.isEmpty == true
    }

    /// Whether Setup opens by itself at launch: a config that reads and holds no seat. An unreadable config does not
    /// open it; Settings shows that problem instead.
    var wantedAtLaunch: Bool { settings?.configValues().map(Self.shouldOpen) ?? false }

    @ObservationIgnored private var launchClaimed = false
    /// Seats created by this run, counted as each write lands, so a retry after a refusal still reports them.
    @ObservationIgnored private var createdSeats = 0

    /// True once per launch, when Setup should open by itself: the menu bar label may appear again later.
    func claimLaunchOpen() -> Bool {
        guard !launchClaimed else { return false }
        launchClaimed = true
        return wantedAtLaunch
    }

    /// The agents that can ask Agencil and are installed: the left column of the routes step.
    var callers: [String] { AgentAccess.supported.filter(foundKinds.contains) }

    var councilReady: Bool { members.count >= Self.councilMinimum }

    /// Whether the agents are wired to ask Agencil at all; routes do nothing until they are.
    var accessOn: Bool { settings?.agentAccessOn ?? false }

    /// The mark beside an agent's name: the company behind the harness, empty when it runs many vendors' models.
    static func vendor(ofHarness harness: String) -> String {
        ["claude": "anthropic", "codex": "openai", "gemini": "google", "antigravity": "google"][harness] ?? ""
    }

    /// One line under a proposed seat: whether it can run, and what to do when it cannot.
    static func stateLine(_ seat: ProposedSeat) -> String {
        switch seat.state {
        case .ready: "Ready"
        case .unconfirmed: "Found; sign-in not confirmed"
        case .signIn(let command): "Signed out: run \(command)"
        // Google serves Gemini CLI only on a paid key now (docs/U35-SPEC.md); its models come through Antigravity.
        case .noAdapter where seat.draft.harness == "gemini": "Found; not runnable here, use Antigravity for Google models"
        case .noAdapter: "Found; Agencil cannot run it yet"
        }
    }

    // MARK: step 1, found

    /// The window opened: a finished run starts over (Settings' "Run setup again"); one in progress keeps its place.
    /// The window opened: a finished run starts over (Settings' "Run setup again"); one in progress keeps its place.
    /// Nothing is probed until the owner presses Find agents: opening at launch runs no installed binary.
    func begin() {
        if step == .done { reset() }
    }

    /// Find agents, then Recheck: runs each harness's version and sign-in check afresh.
    func recheck() async { await detect(force: true) }

    private func detect(force: Bool) async {
        guard let settings, !detecting else { return }
        detecting = true
        defer { detecting = false }
        await settings.panes.refresh(probe: force)
        // A failed read proposes nothing: the last good result is not evidence of what is installed or signed in now.
        if let failure = settings.panes.problem {
            apply([])
            problem = "Could not check the coding agents: \(failure)"
            return
        }
        apply(settings.panes.harnesses.map {
            HarnessFinding(kind: $0.id, found: $0.found, version: $0.version == "-" ? nil : $0.version, signedIn: $0.signedIn)
        })
        problem = nil
    }

    private func reset() {
        step = .found
        proposal = SetupProposal(seats: [], missing: [])
        checked = []
        foundKinds = []
        versions = [:]
        searched = false
        candidates = []
        members = []
        councilName = ""
        targets = []
        routes = []
        pickedCaller = nil
        written = []
        createdSeats = 0
        problem = nil
    }

    private func apply(_ findings: [HarnessFinding]) {
        proposal = SetupPlan.propose(findings)
        checked = Set(proposal.seats.filter(\.checked).map(\.draft.name))
        foundKinds = findings.filter(\.found).map(\.kind)
        versions = Dictionary(findings.compactMap { finding in finding.version.map { (finding.kind, $0) } }, uniquingKeysWith: { first, _ in first })
        searched = true
    }

    /// `claude 2.3.1`: the harness a proposed seat runs on, with the version found.
    func harnessLine(_ harness: String) -> String { versions[harness].map { "\(harness) \($0)" } ?? harness }

    func toggle(seat name: String) {
        guard let seat = proposal.seats.first(where: { $0.draft.name == name }), seat.state != .noAdapter else { return }
        if checked.contains(name) { checked.remove(name) } else { checked.insert(name) }
    }

    func createSeats() {
        guard let settings, let editor = settings.editor else { return refuse("Settings are not connected to a config here.") }
        settings.reload()
        let drafts = proposal.seats.filter { checked.contains($0.draft.name) }.map(\.draft)
        let pending = SetupPlan.pending(drafts, existing: Set(settings.seatNames))
        do {
            for draft in pending {
                try editor.add(draft)
                createdSeats += 1
            }
        } catch {
            settings.reload()
            return refuse(Self.message(error))
        }
        settings.reload()
        if createdSeats > 0 { written.append(Self.count(createdSeats, "seat")) }
        // Only the seats picked in this run, made now or already there under that name: an unrelated seat the owner
        // set up before never joins the proposed council or becomes a route target by itself.
        let present = Set(settings.seatNames)
        candidates = drafts.filter { present.contains($0.name) }
        members = SetupPlan.council(candidates)?.seats ?? []
        councilName = Self.free("review", taken: settings.targets)
        problem = nil
        step = .council
    }

    // MARK: step 2, council

    func toggle(member name: String) {
        if let index = members.firstIndex(of: name) { members.remove(at: index) } else { add(member: name) }
    }

    func add(member name: String) {
        guard candidates.contains(where: { $0.name == name }), !members.contains(name) else { return }
        members.append(name)
    }

    func createCouncil() {
        guard let settings, let editor = settings.editor else { return refuse("Settings are not connected to a config here.") }
        guard councilReady else { return refuse("A council needs at least two seats.") }
        settings.reload()
        let draft = CouncilDraft(name: councilName, seats: members, rule: "any_blocker", quorum: min(Self.councilMinimum, members.count), mode: "review")
        do {
            try editor.add(draft)
        } catch {
            settings.reload()
            return refuse(Self.message(error))
        }
        settings.reload()
        written.append("the \(councilName) council of \(Self.count(members.count, "seat"))")
        targets = [councilName] + candidates.map(\.name)
        routes = SetupPlan.routes(callers: callers, council: councilName)
        problem = nil
        step = .routes
    }

    func skipCouncil() {
        targets = candidates.map(\.name)
        routes = []
        problem = nil
        step = .routes
    }

    // MARK: step 3, routes

    func pick(caller: String) { pickedCaller = pickedCaller == caller ? nil : caller }

    /// A press on a target: completes the route from the caller picked before it.
    func press(target: String) {
        guard let caller = pickedCaller else { return }
        connect(caller: caller, target: target)
        pickedCaller = nil
    }

    func connect(caller: String, target: String) {
        guard callers.contains(caller), targets.contains(target),
              !routes.contains(where: { $0.callers == [caller] && $0.target == target }) else { return }
        routes.append(RouteDraft(callers: [caller], target: target))
    }

    func disconnect(caller: String, target: String) {
        routes.removeAll { $0.callers == [caller] && $0.target == target }
    }

    func callers(of target: String) -> [String] { routes.filter { $0.target == target }.flatMap(\.callers) }

    func createRoutes() {
        guard let settings, let editor = settings.editor else { return refuse("Settings are not connected to a config here.") }
        settings.reload()
        var made = 0
        do {
            for route in routes {
                try editor.add(route)
                made += 1
            }
        } catch {
            settings.reload()
            // Routes written before the refusal stay; the list keeps only the ones still to write.
            routes.removeFirst(made)
            if made > 0 { written.append(Self.count(made, "route")) }
            return refuse(Self.message(error))
        }
        settings.reload()
        if made > 0 { written.append(Self.count(made, "route")) }
        problem = nil
        step = .done
    }

    func skipRoutes() {
        problem = nil
        step = .done
    }

    // MARK: helpers

    private func refuse(_ message: String) { problem = message }

    private static func message(_ error: Error) -> String {
        if let problems = error as? SheetProblems { return problems.fields.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ") }
        return error.localizedDescription
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// `review`, or `review-2` and up when a council, alias or seat already has the name.
    private static func free(_ name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var index = 2
        while taken.contains("\(name)-\(index)") { index += 1 }
        return "\(name)-\(index)"
    }
}
