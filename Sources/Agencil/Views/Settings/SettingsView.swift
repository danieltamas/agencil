import SwiftUI

/// The Settings window: sidebar of panes on the left, the open pane on the right (docs/DESIGN.md "Settings").
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, seats, councils, routes, harnesses, models, budgets, scoring, leaderboard, data, access, apps, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"; case .seats: "Seats"; case .councils: "Councils"; case .routes: "Routes"
        case .harnesses: "Harnesses"; case .models: "Models"; case .budgets: "Budgets"; case .scoring: "Scoring"
        case .leaderboard: "Leaderboard"; case .data: "Data"; case .access: "Agent access"; case .apps: "More apps"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"; case .seats: "person.2.wave.2"; case .councils: "circle.hexagongrid"
        case .routes: "arrow.triangle.branch"; case .harnesses: "terminal"; case .models: "cpu"
        case .budgets: "gauge.with.dots.needle.50percent"; case .scoring: "checkmark.seal"
        case .leaderboard: "chart.bar.xaxis"; case .data: "internaldrive"; case .access: "sparkles"
        case .apps: "square.grid.2x2"; case .about: "info.circle"
        }
    }

    var tint: PaneTint {
        switch self {
        case .councils, .leaderboard: .cool
        case .routes, .scoring: .good
        case .budgets: .caution
        case .harnesses, .data, .about: .quiet
        case .models, .apps: .rose
        default: .accent
        }
    }
}

struct SettingsView: View {
    let store: SettingsStore
    @State private var pane: SettingsPane

    init(store: SettingsStore, pane: SettingsPane = .general) {
        self.store = store
        _pane = State(initialValue: pane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                SettingsPaneView(store: store, pane: pane)
                    .environment(\.inFlight, store.inFlight)
                    .id(pane)
                    .transition(.opacity)
                    .padding(Space.pane)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .paneSwap(pane)
        }
        .frame(minWidth: Size.settingsMin.width, minHeight: Size.settingsMin.height)
        .background(Backdrop())
        .houseScheme()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Eyebrow(text: "Settings").padding(.horizontal, Space.l).padding(.bottom, Space.s)
            ScrollView {
                VStack(spacing: Space.xxs) {
                    ForEach(SettingsPane.allCases) { item in
                        SidebarRow(title: item.title, symbol: item.symbol, tint: item.tint, selected: item == pane) { pane = item }
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack(spacing: Space.m) {
                ChipButton(title: "Restart") {}
                ChipButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, Space.l).padding(.top, Space.s)
        }
        .padding(.vertical, Space.l).padding(.horizontal, Space.s)
        .frame(width: Size.settingsSidebar)
        .sidebarWash()
    }
}
