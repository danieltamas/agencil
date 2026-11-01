import AgencilCore
import Foundation
import Observation
import ServiceManagement

/// What a "New ..." sheet creates.
enum SheetKind: String, Identifiable, CaseIterable {
    case seat, council, route

    var id: String { rawValue }
    var title: String { "New \(rawValue)" }
    var detail: String { "Saved to config.json; the broker picks it up without a restart." }
}

struct SeatForm {
    var name = ""
    /// A harness or model edited after a preset leaves the preset's vendor, plan and hosted flag behind: the config
    /// infers them from the new harness and model instead (a free preset's plan must not follow a paid model).
    var harness = "codex" { didSet { if harness != oldValue { forgetPreset() } } }
    var model = "" { didSet { if model != oldValue { forgetPreset() } } }
    var endpoint = "", pin = "", cap = ""
    /// Empty means the config infers it. A chosen preset fills them; the sheet shows them and they can be edited.
    var preset = "", vendor = "", plan = ""
    var hosted: Bool?
    var role = ""

    private mutating func forgetPreset() { preset = ""; vendor = ""; plan = ""; hosted = nil }
}
struct CouncilForm { var name = "", seats: [String] = [], rule = "majority", quorum = "", spare: [String] = [], synthesizer: [String] = [] }
struct RouteForm { var callers = "", target = "", hops = "" }

/// What an Edit sheet changes: a seat or council by its name, a route by its place in the list and what it was
/// when the sheet opened (a route has no name).
enum EditTarget: Equatable {
    case named(String)
    case route(index: Int, was: RouteDraft)
}

/// The Settings window's state: what the config holds now, the sheet forms, and the saves. Every save goes through
/// `ConfigEditor`, which re-reads the file first; nothing here keeps a second copy of a setting.
@MainActor @Observable final class SettingsStore {
    /// One configured seat, as the Seats pane lists it.
    struct SeatInfo: Identifiable { let id: String; let vendor: String; let harness: String; let model: String; let plan: String }

    private(set) var seatInfos: [SeatInfo] = []
    private(set) var councilRows: [DemoPanel.ListRow] = []
    private(set) var routeRows: [DemoPanel.ListRow] = []
    private(set) var seatNames: [String] = []
    private(set) var targets: [String] = []
    private(set) var access: [String: AccessState] = [:]
    private(set) var wiring: [String: Wiring] = [:]
    /// The broker socket as last probed (on open and after every change); nil until a home is known.
    private(set) var socket: AccessFacts.Socket?
    /// The broker-fed panes (harnesses, models, budgets, data, leaderboard).
    var panes = PaneStore()
    /// The More apps list and the release check About shows.
    private(set) var apps = MoreAppsStore()
    private(set) var update = UpdateStore(home: nil)
    private(set) var configProblem: String?
    private(set) var notify: Set<String> = NotifySettings.kinds
    private(set) var seatsAtOnce = ""
    private(set) var limitsProblem: String?
    private(set) var accessProblem: String?
    var seatForm = SeatForm()
    var councilForm = CouncilForm()
    var routeForm = RouteForm()
    var presenting: SheetKind?
    /// Set while the sheet edits an existing object; nil while it creates one.
    var editing: EditTarget?
    var confirmingDelete = false
    /// Owned here, not by a view, so an install press stays guarded while the owner is on another pane.
    let inFlight = InFlightActions()
    private(set) var agentAccessOn = false
    var problems: [String: String] = [:]

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored let editor: ConfigEditor?
    @ObservationIgnored private let agentAccess: AgentAccess?
    @ObservationIgnored private var environment: [String: String] = [:]

    /// An inert store: no file, no broker. `demo()` and the tests use it.
    init() {
        directory = nil
        editor = nil
        agentAccess = nil
    }

    init(directory: URL, environment: [String: String]) {
        self.directory = directory
        editor = ConfigEditor(directory: directory)
        agentAccess = AgentAccess(home: directory, environment: environment)
        self.environment = environment
        apps = MoreAppsStore(directory: directory)
        update = UpdateStore.shared
        reload()
    }

    static func demo(accessOn: Bool = true) -> SettingsStore {
        let store = SettingsStore()
        store.seatInfos = DemoPanel.seatRows.map { SeatInfo(id: $0.id, vendor: $0.vendor, harness: $0.harness, model: $0.model, plan: $0.plan) }
        store.panes = PaneStore.demo()
        store.councilRows = DemoPanel.councils
        store.routeRows = DemoPanel.routes
        store.seatNames = DemoPanel.seatRows.map(\.id)
        store.targets = store.seatNames + DemoPanel.councils.map(\.name)
        store.seatsAtOnce = "3"
        store.apps = MoreAppsStore.demo(now: DemoStore.now)
        store.update = UpdateStore.demo(now: DemoStore.now)
        store.agentAccessOn = accessOn
        store.socket = AccessFacts.Socket(path: NSHomeDirectory() + "/.agencil/agencil.sock", reachable: true, ownerOnly: true)
        let states: [(String, Bool, InstructionState, [String])] = [
            ("claude", true, .current, ["lumen-review"]), ("codex", true, .outdated, []), ("opencode", false, .absent, []),
        ]
        for (harness, installed, instruction, routes) in states {
            let state = AccessState(harness: harness, installed: installed, path: "~/.\(harness)/config",
                                    entry: installed ? "[mcp_servers.agencil]" : nil, problem: nil)
            store.access[harness] = state
            store.wiring[harness] = Wiring(harness: harness, mcp: state, instruction: instruction, caller: harness, routes: routes,
                                           drift: instruction == .outdated ? ["instructions outdated"] : [])
        }
        return store
    }

    static func launch() -> SettingsStore {
        let environment = ProcessInfo.processInfo.environment
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil")
        let directory = (try? AgencilHome(directory: fallback, environment: environment))?.directory ?? fallback
        let store = SettingsStore(directory: directory, environment: environment)
        if let home = try? AgencilHome(directory: fallback, environment: environment) {
            store.panes = PaneStore(directory: directory, client: PanelClient(home: home))
        }
        return store
    }

    // MARK: reading

    func reload() {
        guard let directory else { return }
        do {
            let values = try ConfigStore(directory: directory).read().values
            let config = try SeatConfig(values: values)
            configProblem = nil
            seatInfos = config.seats.map { SeatInfo(id: $0.name, vendor: $0.vendor, harness: $0.harness, model: $0.model, plan: $0.plan.rawValue) }
            councilRows = config.councils.map { DemoPanel.ListRow(name: $0.name, detail: "\($0.seats.count) seats, \($0.rule.rawValue)", up: true) }
            routeRows = config.routes.map { DemoPanel.ListRow(name: $0.callers.joined(separator: ", ") + " to " + $0.target,
                                                              detail: "hop limit \($0.hopLimit)", up: true) }
            seatNames = config.seats.map(\.name)
            targets = seatNames + config.aliases.keys.sorted() + config.councils.map(\.name)
            notify = (try? NotifySettings(values: values))?.notify ?? NotifySettings.kinds
            seatsAtOnce = String(config.limits.seatsAtOnce)
            agentAccessOn = values["agent_access"] == "on"
        } catch let problem as ConfigProblem {
            configProblem = problem.message
        } catch {
            configProblem = error.localizedDescription
        }
        for harness in ["claude", "codex", "opencode"] {
            access[harness] = try? agentAccess?.state(harness)
        }
        refreshWiring()
        probeSocket()
    }

    /// A connect and an immediate close: cheap, and the broker treats it as a client that said nothing.
    private func probeSocket() {
        guard let directory, let home = try? AgencilHome(directory: directory, environment: environment) else { return }
        socket = AccessFacts.socket(home: home)
    }

    private func refreshWiring() {
        guard let directory, let agentAccess else { return }
        let values = (try? ConfigStore(directory: directory).read().values) ?? [:]
        wiring = Dictionary(uniqueKeysWithValues: agentAccess.audit(values: values).map { ($0.harness, $0) })
    }

    /// One line for the pane: how many drift lines the harness cards carry ("access is off" is information, not drift).
    var wiringSummary: String {
        let drifted = wiring.values.reduce(0) { $0 + $1.drift.filter { $0 != "access is off" }.count }
        return drifted == 0 ? "All wired" : "\(drifted) thing\(drifted == 1 ? "" : "s") drifted"
    }

    // MARK: sheets

    func startSheet(_ kind: SheetKind) {
        problems = [:]
        editing = nil
        confirmingDelete = false
        switch kind {
        case .seat: seatForm = SeatForm()
        case .council: councilForm = CouncilForm()
        case .route: routeForm = RouteForm()
        }
    }

    /// Fills the seat sheet from a preset (docs/U25-SPEC.md); the owner can still edit any field before saving.
    func applyPreset(_ name: String) {
        guard let preset = SeatPreset.named(name) else { return }
        seatForm = SeatForm(name: preset.name, harness: preset.harness, model: preset.model, endpoint: preset.endpoint ?? "", pin: "",
                            cap: String(preset.capSeconds), preset: preset.name, vendor: preset.vendor, plan: preset.plan.rawValue,
                            hosted: preset.hosted)
    }

    /// True when the object was saved; otherwise `problems` says which field to fix and the sheet stays open.
    func save(_ kind: SheetKind) -> Bool {
        guard let editor else {
            problems = ["form": "Settings are not connected to a config in this view."]
            return false
        }
        var found: [String: String] = [:]
        func whole(_ text: String, _ key: String) -> Int? {
            guard !text.isEmpty else { return nil }
            guard let value = Int(text) else { found[key] = "a whole number"; return nil }
            return value
        }
        do {
            switch kind {
            case .seat:
                let cap = whole(seatForm.cap, "capSeconds")
                guard found.isEmpty else { throw SheetProblems(fields: found) }
                let draft = SeatDraft(name: seatForm.name, harness: seatForm.harness, model: seatForm.model,
                                         endpoint: seatForm.endpoint, pin: seatForm.pin, capSeconds: cap,
                                         vendor: seatForm.vendor, plan: seatForm.plan, hosted: seatForm.hosted, role: seatForm.role)
                if case .named(let old) = editing { try editor.update(seat: old, with: draft) } else { try editor.add(draft) }
            case .council:
                let quorum = whole(councilForm.quorum, "quorum")
                guard found.isEmpty else { throw SheetProblems(fields: found) }
                let draft = CouncilDraft(name: councilForm.name, seats: councilForm.seats, rule: councilForm.rule, quorum: quorum,
                                         spare: councilForm.spare, synthesizer: councilForm.synthesizer)
                if case .named(let old) = editing { try editor.update(council: old, with: draft) } else { try editor.add(draft) }
            case .route:
                let hops = whole(routeForm.hops, "hopLimit")
                guard found.isEmpty else { throw SheetProblems(fields: found) }
                let callers = routeForm.callers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let draft = RouteDraft(callers: callers, target: routeForm.target, hopLimit: hops)
                if case .route(let index, let was) = editing { try editor.update(routeAt: index, was: was, with: draft) } else { try editor.add(draft) }
            }
        } catch let refused as SheetProblems {
            problems = refused.fields
            return false
        } catch {
            problems = ["form": error.localizedDescription]
            return false
        }
        problems = [:]
        reload()
        return true
    }

    func clearProblems() { problems = [:] }

    // MARK: scalars

    func notifies(_ kind: String) -> Bool { notify.contains(kind) }

    func setNotify(_ kind: String, _ on: Bool) {
        guard let editor else { return }
        do { try editor.setNotify(kind, on: on); reload() }
        catch { accessProblem = (error as? SheetProblems)?.fields.values.first }
    }

    /// Saved as it is typed once it is a whole number from 1 to 16; anything else shows the problem and writes nothing.
    func setSeatsAtOnce(_ text: String) {
        seatsAtOnce = text
        guard let editor else { return }
        guard let value = Int(text), (1...16).contains(value) else {
            limitsProblem = "1 to 16"
            return
        }
        do { try editor.setLimit("seats_at_once", value); limitsProblem = nil }
        catch { limitsProblem = (error as? SheetProblems)?.fields.values.first }
    }

    /// Where a harness reads the Agencil paragraph, with `~` for the home directory.
    func instructionPath(_ harness: String) -> String { AccessFacts.instructionPath(harness, environment: environment) }

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        guard directory != nil else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { accessProblem = error.localizedDescription }
    }

    // MARK: agent access

    func setAgentAccess(_ on: Bool) {
        guard let editor else { return }
        do { try editor.set("agent_access", on ? "on" : "off"); agentAccessOn = on; accessProblem = nil }
        catch { accessProblem = (error as? SheetProblems)?.fields.values.first ?? error.localizedDescription }
    }

    func installAction(_ harness: String, uninstall: Bool) -> () async -> Void {
        { [self] in await changeAccess(harness, uninstall: uninstall) }
    }

    private func changeAccess(_ harness: String, uninstall: Bool) async {
        guard let agentAccess else { return }
        let result = await Task.detached { () -> Result<AccessState, AccessError> in
            do { return .success(uninstall ? try agentAccess.uninstall(harness) : try agentAccess.install(harness)) }
            catch let error as AccessError { return .failure(error) }
            catch { return .failure(AccessError(message: error.localizedDescription)) }
        }.value
        switch result {
        case .success(let state): access[harness] = state; accessProblem = nil; refreshWiring(); probeSocket()
        case .failure(let error): accessProblem = error.message
        }
    }
}

extension SettingsStore {
    func instructionAction(_ harness: String, remove: Bool) -> () async -> Void {
        { [self] in await changeInstruction(harness, remove: remove) }
    }

    private func changeInstruction(_ harness: String, remove: Bool) async {
        guard let directory else { return }
        let environment = self.environment
        let failure = await Task.detached { () -> String? in
            let instruction = AgentInstruction(environment: environment)
            do { remove ? try instruction.remove(harness) : try instruction.install(harness); return nil }
            catch let error as AccessError { return error.message }
            catch { return error.localizedDescription }
        }.value
        accessProblem = failure
        refreshWiring()
    }
}
