import SwiftUI

/// One seat in a Settings list: its vendor mark, name, the whole model id (it wraps, never cut), the meta line,
/// the last preflight in plain words, and a control on the right. `marked` is the seat the panel opened.
struct SeatEntry<Control: View>: View {
    let vendor: String
    let name: String
    let model: String
    let meta: String
    var status: String?
    var statusOK = false
    var detail = ""
    var marked = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VendorMark(vendor: vendor, color: marked ? Theme.accent : Theme.textSecondary).padding(.top, Space.xxs)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(name).font(.house.body.weight(.medium)).foregroundStyle(marked ? Theme.accent : Theme.textPrimary).lineLimit(1)
                Text(model).font(.house.mono).foregroundStyle(Theme.textSecondary).detailLines()
                Text(meta).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines()
                if let status {
                    Text(status).font(.house.meta).foregroundStyle(statusOK ? Theme.ok : Theme.crit).detailLines()
                    if !detail.isEmpty { Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines() }
                }
            }
            Spacer(minLength: Space.l)
            control
        }
        .padding(.vertical, Space.m)
        .frame(minHeight: SettingsMetrics.rowHeight)
        .background(Theme.accent.opacity(marked ? Theme.opacity.faint : 0))
    }
}
