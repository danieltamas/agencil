import SwiftUI

/// One tab of the island: an icon, a name that shows only while open, and a badge for what needs a human.
struct TabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    var badge: Int = 0
}

/// The row of tabs under the bento. Only the open tab shows its name; with no room, every tab is icon-only.
struct TabIsland: View {
    let tabs: [TabItem]
    @Binding var selection: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(named: true)
            row(named: false)
        }
        .padding(Space.xs)
        .frame(height: Size.tabIsland + Space.xs * 2)
        .background(Theme.core.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func row(named: Bool) -> some View {
        HStack(spacing: Space.xs) {
            ForEach(tabs) { tab in
                let open = tab.id == selection
                Button { withAnimation(Motion.snappy) { selection = tab.id } } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: tab.symbol).font(.system(size: 12, weight: .semibold))
                        if open && named { Text(tab.title).font(.house.control).lineLimit(1) }
                        if tab.badge > 0 { Chip(text: "\(tab.badge)", color: Theme.accent, style: open ? .filled : .tinted) }
                    }
                    .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, Space.l)
                    .frame(maxWidth: open ? .infinity : nil, minHeight: Size.tabIsland)
                    .background { if open { Capsule().fill(Theme.coreHover) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}
