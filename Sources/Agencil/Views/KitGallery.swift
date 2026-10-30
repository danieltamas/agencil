import SwiftUI

/// Every kit component at the panel width, with the longest demo values. The layout tests render it in each look.
struct KitGallery: View {
    @State private var text = ""
    @State private var enabled = true

    /// The controls that sit in a row, each alone, so a test can measure its height.
    static let controls: [(name: String, view: AnyView)] = [
        ("PillButton", AnyView(PillButton(title: "Ask the council") {})),
        ("PillButton quiet", AnyView(PillButton(title: "Cancel", symbol: "xmark", prominent: false) {})),
        ("ChipButton", AnyView(ChipButton(title: "Stop") {})),
        ("SegmentChip", AnyView(SegmentChip(title: "3 seats", selected: true) {})),
        ("IconButton", AnyView(IconButton(symbol: "gearshape", help: "Settings") {})),
        ("GlassField", AnyView(GlassField(placeholder: "Repo", text: .constant(DemoStore.longRepo)).frame(width: Size.panelWidth))),
        ("SecretField", AnyView(SecretField(placeholder: "Key", text: .constant("")).frame(width: Size.panelWidth))),
        ("MenuField", AnyView(MenuField(title: DemoStore.longModelId, options: [DemoStore.longModelId]) { _ in }.frame(width: Size.panelWidth))),
        ("SearchField", AnyView(SearchField(text: .constant("")).frame(width: Size.panelWidth))),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Eyebrow(text: "Council")
            HoverCard(accent: Theme.color(for: .running), action: {}) {
                HStack(spacing: Space.l) {
                    GlyphDisc(symbol: "checkmark", color: Theme.color(for: .ok))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(DemoStore.longRepo).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(DemoStore.longReason).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines()
                    }
                    Spacer(minLength: Space.s)
                    Chip(text: "PASS", color: Theme.color(for: .ok))
                }
            }
            SearchField(text: $text, prompt: "Search runs")
            GlassField(placeholder: "Repo", text: $text)
            MenuField(title: DemoStore.longModelId, options: DemoStore.seats) { _ in }
            HStack(spacing: Space.m) {
                PillButton(title: "Ask the council") {}
                PillButton(title: "Cancel", symbol: "xmark", prominent: false) {}
                ChipButton(title: "Stop", destructive: true) {}
            }
            HStack(spacing: Space.s) {
                SegmentChip(title: "1 seat", selected: false) {}
                SegmentChip(title: "3 seats", selected: true) {}
            }
            StatusLine(text: DemoStore.longReason, signal: .warn, hint: "Check the endpoint with agencil doctor.")
            SettingsCard(title: "Notifications", detail: "Tell me when a council reaches a verdict.") {
                SwitchRow(title: "Verdicts", isOn: $enabled)
                RowDivider()
                SettingsRow(title: "Seats", detail: DemoStore.seats.joined(separator: ", ")) {
                    Chip(text: "5", color: Theme.color(for: .unknown))
                }
            }
            EmptyState(symbol: "tray", title: "No councils yet", detail: "Ask one from the CLI or an agent.")
        }
        .padding(Space.panelInset)
        .frame(width: Size.panelWidth, alignment: .leading)
        .background(Backdrop())
        .houseScheme()
    }
}
