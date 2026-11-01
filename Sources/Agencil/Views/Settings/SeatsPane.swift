import SwiftUI

/// Settings > Seats: every configured seat with its vendor mark, full model, harness and plan, the last preflight
/// in plain words and a Re-check that probes it now. A seat opened from the panel is marked and scrolled to.
struct SeatsPane: View {
    @Bindable var store: SettingsStore
    private let route = SettingsRoute.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack { Spacer(); PillButton(title: SheetKind.seat.title, symbol: "plus") { store.startSheet(.seat); store.presenting = .seat } }
            SettingsCard(title: "Configured") {
                if store.seatInfos.isEmpty {
                    SettingsRow(title: "Nothing yet", detail: "Create the first one with the button above.") { EmptyView() }
                }
                if let problem = store.panes.problem { ProblemText(text: problem) }
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ForEach(Array(store.seatInfos.enumerated()), id: \.element.id) { index, seat in
                            if index > 0 { RowDivider() }
                            entry(seat, index: index).id(seat.id)
                        }
                    }
                    .onAppear { reveal(proxy) }
                    .onChange(of: route.seat) { _, _ in reveal(proxy) }
                }
            }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        if let seat = route.seat { proxy.scrollTo(seat, anchor: .center) }
    }

    /// The whole entry opens the Edit seat sheet. Re-check is a sibling of that button, laid over the trailing edge: the
    /// row's own trailing slot holds an invisible copy of it, so the two controls share one measured position.
    private func entry(_ seat: SettingsStore.SeatInfo, index: Int) -> some View {
        let standing = store.panes.standings[seat.id]
        let recheck = AsyncPress(id: "recheck:\(seat.id)", action: store.panes.recheckAction(seat: seat.id)) { running, press in
            ChipButton(title: running ? "Checking..." : "Re-check", action: press)
        }
        let chevron = Image(systemName: "chevron.right").font(.house.meta).foregroundStyle(Theme.textTertiary)
        return PressRow(label: "Edit \(seat.id)") { store.startEdit(.seat, index: index) } content: {
            SeatEntry(vendor: seat.vendor, name: seat.id, model: seat.model, meta: store.panes.seatMeta(seat.harness, plan: seat.plan, model: seat.model),
                      status: standing?.line, statusOK: standing?.ok ?? false, detail: standing?.ok == false ? standing?.detail ?? "" : "",
                      marked: route.seat == seat.id) {
                HStack(spacing: Space.m) { recheck.hidden(); chevron }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Space.m) { recheck; chevron.hidden() }
                .padding(.top, Space.m)
                .padding(.trailing, SettingsMetrics.rowInset)
        }
    }
}
