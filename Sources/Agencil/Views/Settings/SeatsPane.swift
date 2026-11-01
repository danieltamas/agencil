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
                        ForEach(store.seatInfos) { seat in
                            if seat.id != store.seatInfos.first?.id { RowDivider() }
                            entry(seat).id(seat.id)
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

    private func entry(_ seat: SettingsStore.SeatInfo) -> some View {
        let standing = store.panes.standings[seat.id]
        return SeatEntry(vendor: seat.vendor, name: seat.id, model: seat.model, meta: store.panes.seatMeta(seat.harness, plan: seat.plan, model: seat.model),
                         status: standing?.line, statusOK: standing?.ok ?? false, detail: standing?.ok == false ? standing?.detail ?? "" : "",
                         marked: route.seat == seat.id) {
            AsyncPress(id: "recheck:\(seat.id)", action: store.panes.recheckAction(seat: seat.id)) { running, press in
                ChipButton(title: running ? "Checking..." : "Re-check", action: press)
            }
        }
    }
}
