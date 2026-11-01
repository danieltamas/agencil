import SwiftUI

/// One tab of the island: an icon, a name that shows only while open, and a badge for what needs a human.
struct TabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    var badge: Int = 0
}

/// The row of tabs under the bento. Only the open tab shows its name; with no room, every tab is icon-only.
/// One row, one identity: the open tab's pill slides to the next tab and the names grow and shrink with it. Whether the
/// name fits is decided from the measured width, not by trying two layouts, since a layout that flips mid-animation
/// drops the pill's motion.
struct TabIsland: View {
    let tabs: [TabItem]
    @Binding var selection: String
    @Namespace private var island
    @State private var width: CGFloat = 0

    var body: some View {
        row
            .animation(Motion.spring, value: selection)
            .padding(Space.xs)
            .frame(height: Size.tabIsland + Space.xs * 2)
            .background(Theme.core.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Room for every tab's icon and badge, spacing, and the open tab's name.
    private var nameFits: Bool {
        let each = Space.l * 2 + 14 + Space.xs
        let badges = tabs.reduce(CGFloat(0)) { $0 + ($1.badge > 0 ? Space.s + 12 + CGFloat(String($1.badge).count) * 7 : 0) }
        let name = CGFloat(tabs.first { $0.id == selection }?.title.count ?? 0) * 8 + Space.s
        return width == 0 || each * CGFloat(tabs.count) + badges + name + Space.xs * 2 <= width
    }

    private var row: some View {
        HStack(spacing: Space.xs) {
            ForEach(tabs) { tab in
                let open = tab.id == selection
                Button { withAnimation(Motion.spring) { selection = tab.id } } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: tab.symbol).font(.system(size: 12, weight: .semibold))
                        if open && nameFits { Text(tab.title).font(.house.control).lineLimit(1).fixedSize().transition(.opacity) }
                        if tab.badge > 0 { Chip(text: "\(tab.badge)", color: Theme.accent, style: open ? .filled : .tinted) }
                    }
                    .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, Space.l)
                    .frame(maxWidth: open ? .infinity : nil, minHeight: Size.tabIsland)
                    .background {
                        if open {
                            Capsule().fill(Theme.coreHover)
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 0.75))
                                .matchedGeometryEffect(id: "tab", in: island)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(tab.title)
            }
        }
    }
}
