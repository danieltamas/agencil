import AgencilCore
import SwiftUI

/// The menu bar panel, rendered from the store. Layout follows docs/DESIGN.md "Panel".
struct PanelView: View {
    let store: PanelStore
    @State private var tab: String
    @State private var search = ""
    @State private var filter = "All"
    @Environment(\.openSettings) private var openSettings

    init(store: PanelStore, tab: String = "threads") {
        self.store = store
        _tab = State(initialValue: tab)
    }

    private var tabs: [TabItem] {
        [
            TabItem(id: "threads", title: "Threads", symbol: "bubble.left.and.bubble.right"),
            TabItem(id: "sittings", title: "Sittings", symbol: "circle.hexagongrid", badge: store.liveSittings),
            TabItem(id: "findings", title: "Findings", symbol: "exclamationmark.bubble", badge: store.openFindings),
            TabItem(id: "seats", title: "Seats", symbol: "person.2.wave.2"),
            TabItem(id: "learn", title: "Learn", symbol: "sparkles", badge: store.proposals.count),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: Space.l) {
                bento
                TabIsland(tabs: tabs, selection: $tab)
                SearchField(text: $search, prompt: "Search")
                filters
                content
            }
            .padding(.horizontal, Space.panelInset)
            .padding(.bottom, Space.l)
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: Size.panelWidth)
        .frame(height: Size.panelHeight)
        .background(Backdrop())
        .houseScheme()
        .trackPanelVisibility()
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            BrandGlyph()
            Text("Agencil").font(.house.header).foregroundStyle(Theme.textPrimary)
            Chip(text: store.seatChip, color: store.data == nil ? Theme.unknown : Theme.ok)
            Spacer(minLength: 0)
            AsyncIconButton(symbol: "arrow.clockwise", help: "Refresh", id: "refresh", action: store.refresh)
            IconButton(symbol: "gearshape", help: "Settings") { AppRelaunch.activate(); openSettings() }
            HStack(spacing: Space.xs) {
                PulseDot(live: store.liveCount > 0)
                Text("\(store.liveCount) live").font(.house.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .panelHeaderInsets()
    }

    private var bento: some View {
        Bento {
            bigTile
        } top: {
            BentoTile(eyebrow: "Seats", value: store.data.map { "\($0.seats.up) of \($0.seats.total)" } ?? "...") { EmptyView() }
        } bottom: {
            BentoTile(eyebrow: "This week", value: store.weekSpend) {
                if let share = store.weekShare { Text(share).font(.house.meta).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    @ViewBuilder private var bigTile: some View {
        switch store.bento {
        case .none:
            BentoTile(eyebrow: "Needs you", value: "...", tint: Theme.accent, big: true) { EmptyView() }
        case .firstStep:
            BentoTile(eyebrow: "First step", value: "Add a seat", tint: Theme.accent, big: true) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("A council needs seats and a council type.").font(.house.meta).foregroundStyle(Theme.textTertiary)
                    ChipButton(title: "Open Settings") { AppRelaunch.activate(); openSettings() }
                }
            }
        case .council:
            BentoTile(eyebrow: "In session", value: "Sitting", tint: Theme.running, big: true) {
                ChipButton(title: "Show sittings") { tab = "sittings" }
            }
            .overlay(alignment: .trailing) { BentoRing { store.ringView }.padding(.trailing, Space.l) }
        case .needsYou(let count, let findings, let proposals, let stopped):
            BentoTile(eyebrow: "Needs you", value: "\(count)", tint: Theme.accent, big: true) {
                HStack(spacing: Space.s) {
                    if findings > 0 { ChipButton(title: "\(findings) findings") { tab = "findings" } }
                    if proposals > 0 { ChipButton(title: "\(proposals) proposals") { tab = "seats" } }
                    if stopped > 0 { ChipButton(title: "\(stopped) stopped") { tab = "sittings" } }
                }
            }
        }
    }

    @ViewBuilder private var filters: some View {
        let names: [String] = switch tab {
        case "threads": ["All", "Live", "Failed", "Mine"]
        case "seats": ["All", "Auth", "Schema", "UI", "Refactor", "Infra"]
        default: []
        }
        if !names.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(names, id: \.self) { name in FilterChip(title: name, selected: filter == name) { filter = name } }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.data == nil {
            WaitingState(title: waiting)
        } else {
            ScrollView { rows }.scrollIndicators(.hidden)
        }
    }

    private var waiting: String {
        switch tab {
        case "threads": "Reading threads..."
        case "sittings": "Reading sittings..."
        case "findings": "Reading findings..."
        case "learn": "Reading proposals..."
        default: "Reading seats..."
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(spacing: Space.m) {
            switch tab {
            case "threads":
                let items = store.threads(filter: filter, search: search)
                if items.isEmpty { EmptyState(symbol: "bubble.left.and.bubble.right", title: "No threads yet", detail: "Agents ask a seat through Agencil and the exchange lands here.") }
                ForEach(items) { ThreadRow(thread: $0) }
            case "sittings":
                let items = store.sittings(search: search)
                if items.isEmpty { EmptyState(symbol: "circle.hexagongrid", title: "No sittings yet", detail: "A council sits when an agent or a trigger wakes it.") }
                ForEach(items) { item in SittingRow(sitting: item, stopping: store.stopping.contains(item.id), stop: store.stopAction(item.id),
                                         open: { store.open(sitting: item.id) }) }
            case "findings":
                let items = store.findings(search: search)
                if items.isEmpty { EmptyState(symbol: "checkmark.seal", title: "Nothing to decide", detail: "Claims from a sitting wait here for your call.") }
                ForEach(items) { item in FindingRow(finding: item, confirm: store.decideAction(item.id, confirm: true), dismiss: store.decideAction(item.id, confirm: false),
                                       adjudicate: store.adjudicateAction(item.id)) }
            case "learn":
                if store.proposals.isEmpty && !store.canRollback {
                    EmptyState(symbol: "sparkles", title: "Nothing to learn yet", detail: "Proposals to drop, swap or add a seat appear here once outcomes pile up.")
                }
                ForEach(store.proposals) { item in
                    ProposalRow(proposal: item, approve: store.learnAction(item.id, "approve"), reject: store.learnAction(item.id, "reject"),
                                review: store.learnAction(item.id, "review"))
                }
                if store.canRollback {
                    AsyncPress(id: "rollback", action: store.learnAction(nil, "rollback")) { running, press in
                        ChipButton(title: running ? "Rolling back..." : "Roll back the last council change", action: press)
                    }
                }
            default:
                let items = store.seats(search: search)
                if items.isEmpty { EmptyState(symbol: "person.2.wave.2", title: "No seats configured", detail: "Add a seat in Settings to start.") }
                ForEach(items) { SeatScoreRow(seat: $0) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            if store.starOffer {
                AsyncPress(id: "star", action: store.star) { running, press in
                    StarOffer(starring: running, help: "Star \(RepoStar.repo) on GitHub with your gh account", star: press)
                }
            }
            if let problem = store.problem {
                Text(problem).font(.house.meta).foregroundStyle(Theme.crit).lineLimit(1)
            } else {
                ForEach(Array(store.pollAges.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: Space.xs) {
                        Image(systemName: item.symbol).font(.house.badge)
                        Text(item.age).font(.house.meta).monospacedDigit()
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            AppControls(restart: AppRelaunch.restart, quit: AppRelaunch.quit)
        }
        .panelFooterInsets()
    }
}
