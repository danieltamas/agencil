import AgencilCore
import SwiftUI

/// The first-run Setup window (docs/U37-SPEC.md): three steps that propose seats, a council and routes from what is
/// installed. Each step writes on its own press; the last screen says where to change it all.
struct SetupView: View {
    let store: SetupStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    init(store: SetupStore) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    switch store.step {
                    case .found: found
                    case .council: council
                    case .routes: routes
                    case .done: done
                    }
                    if let problem = store.problem { ProblemText(text: problem) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .padding(Space.pane)
        .frame(width: Size.setupWindow.width, height: Size.setupWindow.height, alignment: .topLeading)
        .background(Backdrop())
        .houseScheme()
        .onAppear { store.begin() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                BrandGlyph()
                Text("Set up Agencil").font(.house.paneTitle).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                stepChip("1 Seats", .found)
                stepChip("2 Council", .council)
                stepChip("3 Routes", .routes)
            }
            Text(Self.lead(store.step)).font(.house.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepChip(_ title: String, _ step: SetupStore.Step) -> some View {
        Chip(text: title, color: store.step == step ? Theme.accent : Theme.textTertiary, style: store.step == step ? .filled : .outline)
    }

    // MARK: steps

    private var found: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if store.proposal.seats.isEmpty {
                Text(Self.emptyLine(searched: store.searched, detecting: store.detecting))
                    .font(.house.body).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Size.setupTile), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
                ForEach(store.proposal.seats, id: \.draft.name) { seat in
                    DropTile(payload: seat.draft.name, selected: store.checked.contains(seat.draft.name),
                             dimmed: seat.state == .noAdapter, action: { store.toggle(seat: seat.draft.name) }) {
                        seatTile(seat)
                    }
                }
            }
            if !store.proposal.missing.isEmpty {
                Text("Not found: \(store.proposal.missing.joined(separator: ", ")). Add them later in Settings > Harnesses.")
                    .font(.house.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func seatTile(_ seat: ProposedSeat) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            VendorMark(vendor: seat.draft.vendor ?? SetupStore.vendor(ofHarness: seat.draft.harness))
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(seat.draft.name).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if !seat.draft.model.isEmpty {
                    Text(seat.draft.model).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Text(store.harnessLine(seat.draft.harness)).font(.house.meta).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text(SetupStore.stateLine(seat)).font(.house.meta)
                    .foregroundStyle(seat.state == .ready ? Theme.ok : Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: store.checked.contains(seat.draft.name) ? "checkmark.circle.fill" : "circle")
                .font(.house.rowTitle).foregroundStyle(store.checked.contains(seat.draft.name) ? Theme.accent : Theme.textTertiary)
        }
    }

    private var council: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                Eyebrow(text: "Seats")
                ForEach(store.candidates, id: \.name) { seat in
                    DropTile(payload: seat.name, selected: store.members.contains(seat.name), action: { store.toggle(member: seat.name) }) {
                        HStack(spacing: Space.m) {
                            VendorMark(vendor: seat.vendor ?? "")
                            Text(seat.name).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(width: Size.setupColumn)
            DropCard(title: store.councilName, detail: "Drag seats here, or click one. A review council blocks a change when any seat finds a blocker.",
                     accept: store.add(member:)) {
                if store.members.isEmpty {
                    Text("No seats yet.").font(.house.meta).foregroundStyle(Theme.textTertiary)
                } else {
                    FlowLayout {
                        ForEach(store.members, id: \.self) { name in
                            ChipButton(title: name, symbol: "xmark") { store.toggle(member: name) }
                        }
                    }
                }
            }
        }
    }

    private var routes: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                Eyebrow(text: "Agents that ask")
                if store.callers.isEmpty {
                    Text("No agent that can ask Agencil was found.").font(.house.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(store.callers, id: \.self) { caller in
                    DropTile(payload: caller, selected: store.pickedCaller == caller, action: { store.pick(caller: caller) }) {
                        HStack(spacing: Space.m) {
                            VendorMark(vendor: SetupStore.vendor(ofHarness: caller))
                            Text(caller).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Text(store.accessOn ? "Agent access is on." : "Agent access is off: these agents cannot ask until it is on.")
                    .font(.house.meta).foregroundStyle(store.accessOn ? Theme.ok : Theme.warn).fixedSize(horizontal: false, vertical: true)
                ChipButton(title: "Open Agent access", symbol: "arrow.up.right") {
                    SettingsRoute.shared.show(pane: .access)
                    openSettings()
                }
            }
            .frame(width: Size.setupColumn)
            VStack(alignment: .leading, spacing: Space.m) {
                Eyebrow(text: "Who they may ask")
                ForEach(store.targets, id: \.self) { target in
                    DropCard(title: target, detail: target == store.councilName ? "Council" : "Seat",
                             accept: { store.connect(caller: $0, target: target) }) {
                        FlowLayout {
                            ForEach(store.callers(of: target), id: \.self) { caller in
                                ChipButton(title: caller, symbol: "xmark") { store.disconnect(caller: caller, target: target) }
                            }
                            if let picked = store.pickedCaller, !store.callers(of: target).contains(picked) {
                                ChipButton(title: "Let \(picked) ask", prominent: true) { store.press(target: target) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if store.written.isEmpty {
                Text("Nothing was written.").font(.house.body).foregroundStyle(Theme.textSecondary)
            }
            ForEach(store.written, id: \.self) { line in
                HStack(spacing: Space.s) {
                    Image(systemName: "checkmark").font(.house.badge).foregroundStyle(Theme.ok)
                    Text("Created \(line)").font(.house.body).foregroundStyle(Theme.textPrimary)
                }
            }
            Text("Change any of this in Settings > Seats, Councils and Routes.")
                .font(.house.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.l) {
            Spacer()
            switch store.step {
            case .found:
                AsyncPillButton(title: store.searched ? "Recheck" : "Find agents", runningTitle: "Checking...",
                                symbol: store.searched ? "arrow.clockwise" : "magnifyingglass", prominent: !store.searched,
                                id: "setup:detect", action: store.recheck)
                if store.searched {
                    PillButton(title: "Create seats", symbol: "checkmark", disabled: store.detecting, action: store.createSeats)
                }
            case .council:
                PillButton(title: "Skip", symbol: "forward", prominent: false, action: store.skipCouncil)
                PillButton(title: "Create council", symbol: "checkmark", disabled: !store.councilReady, action: store.createCouncil)
            case .routes:
                PillButton(title: "Skip", symbol: "forward", prominent: false, action: store.skipRoutes)
                PillButton(title: "Create routes", symbol: "checkmark", disabled: store.routes.isEmpty, action: store.createRoutes)
            case .done:
                PillButton(title: "Open Settings", symbol: "gearshape", prominent: false) { openSettings() }
                PillButton(title: "Close", symbol: "checkmark") { dismissWindow(id: SetupStore.windowID) }
            }
        }
    }

    private static func emptyLine(searched: Bool, detecting: Bool) -> String {
        if detecting { return "Looking for coding agents on this Mac..." }
        if !searched { return "Press Find agents to look for Claude Code, Codex, OpenCode, Gemini CLI and Antigravity. It runs each one's version and sign-in check." }
        return "No coding agent Agencil can run was found."
    }

    private static func lead(_ step: SetupStore.Step) -> String {
        switch step {
        case .found: "These are the coding agents on this Mac. Pick the seats to create; each is a harness plus a model."
        case .council: "A council is seats that answer the same question and agree on a verdict. Pick at least two."
        case .routes: "A route lets an agent ask a council or a seat. Drag an agent onto a target, or click one, then the target."
        case .done: "Agencil is set up."
        }
    }
}
