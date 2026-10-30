import SwiftUI

/// The pill under a list whose remote has more rows: its title, whether the owner of the list is fetching now,
/// and what a press does. The press id is stable per list (`more:<slug>`).
struct RowStackMore {
    let id: String
    let title: String
    var loading = false
    let action: () async -> Void
}

/// The scrolling column every tab uses, rows rising in on first show. A page at a time, so a long history never
/// builds hundreds of rows nobody scrolls to.
struct RowStack<Item: Identifiable, Row: View, Header: View>: View {
    static var page: Int { 25 }
    let items: [Item]
    let row: (Item) -> Row
    let header: () -> Header
    /// Once every local item is shown: a pill with this title that fetches more. Nil when the list is complete.
    var more: RowStackMore?
    var footer: AnyView?
    @Environment(\.stillImage) private var stillImage
    @State private var shown = Self.page

    init(items: [Item], more: RowStackMore? = nil, footer: AnyView? = nil,
         @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder header: @escaping () -> Header) {
        self.items = items
        self.more = more
        self.footer = footer
        self.row = row
        self.header = header
    }

    var body: some View {
        if stillImage {
            VStack(spacing: Space.s) { rows }.padding(.horizontal, Space.panelInset)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView {
                LazyVStack(spacing: Space.s) { rows }
                    .padding(.horizontal, Space.panelInset)
                    .padding(.bottom, Space.l)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder private var rows: some View {
        header()
        ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, item in
            row(item).riseIn(index)
        }
        if items.count > shown {
            PillButton(title: "Show \(min(Self.page, items.count - shown)) more of \(items.count - shown)",
                       symbol: "chevron.down", prominent: false) {
                withAnimation(Motion.spring) { shown += Self.page }
            }
            .padding(.top, Space.xs)
        } else if let more {
            AsyncPillButton(title: more.loading ? "Loading..." : more.title, runningTitle: "Loading...",
                            symbol: "arrow.down.circle", prominent: false, disabled: more.loading, id: more.id) {
                await more.action()
                withAnimation(Motion.spring) { shown = max(shown, items.count) + Self.page * 2 }
            }
            .padding(.top, Space.xs)
        }
        if let footer { footer }
    }
}
