import AgencilCore
import SwiftUI

/// The menu bar panel, on demo data until U8 wires the live store. Layout follows docs/DESIGN.md "Panel".
struct PanelView: View {
    @State private var tab: String
    @State private var search = ""
    @State private var filter = "All"
    @Environment(\.openSettings) private var openSettings

    init(tab: String = "threads") { _tab = State(initialValue: tab) }

    private let tabs = [
        TabItem(id: "threads", title: "Threads", symbol: "bubble.left.and.bubble.right"),
        TabItem(id: "sittings", title: "Sittings", symbol: "circle.hexagongrid", badge: 1),
        TabItem(id: "findings", title: "Findings", symbol: "exclamationmark.bubble", badge: DemoPanel.findings.count),
        TabItem(id: "seats", title: "Seats", symbol: "person.2.wave.2"),
    ]

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
            footer
        }
        .frame(width: Size.panelWidth)
        .frame(maxHeight: Size.panelMaxHeight)
        .background(Backdrop())
        .houseScheme()
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            BrandGlyph()
            Text("Agencil").font(.house.header).foregroundStyle(Theme.textPrimary)
            Chip(text: "4/5 seats up", color: Theme.ok)
            Spacer(minLength: 0)
            AsyncIconButton(symbol: "arrow.clockwise", help: "Refresh", id: "refresh", action: DemoPanel.refresh)
            IconButton(symbol: "gearshape", help: "Settings") { openSettings() }
            HStack(spacing: Space.xs) {
                PulseDot()
                Text("1 live").font(.house.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .panelHeaderInsets()
    }

    private var bento: some View {
        Bento {
            BentoTile(eyebrow: "Needs you", value: "4", tint: Theme.accent, big: true) {
                HStack(spacing: Space.s) {
                    ChipButton(title: "3 findings") { tab = "findings" }
                    ChipButton(title: "1 stopped") { tab = "sittings" }
                }
            }
        } top: {
            BentoTile(eyebrow: "Seats", value: "4 of 5") { EmptyView() }
        } bottom: {
            BentoTile(eyebrow: "This week", value: "$6.40") {
                Text("32% of budget").font(.house.meta).foregroundStyle(Theme.textTertiary)
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
                    ForEach(names, id: \.self) { name in SegmentChip(title: name, selected: filter == name) { filter = name } }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                switch tab {
                case "threads": ForEach(DemoPanel.threads) { ThreadRow(thread: $0) }
                case "sittings": ForEach(DemoPanel.sittings) { SittingRow(sitting: $0) }
                case "findings": ForEach(DemoPanel.findings) { FindingRow(finding: $0) }
                default: ForEach(DemoPanel.seatRows) { SeatScoreRow(seat: $0) }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            Text(DemoPanel.polls).font(.house.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 0)
            ChipButton(title: "Restart") {}
            ChipButton(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .panelFooterInsets()
    }
}
