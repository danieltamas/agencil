import SwiftUI

/// A calm empty list: a glyph in a lit ring, one line, one hint.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.brand)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Theme.core))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Theme.accent.opacity(Theme.opacity.ring), Theme.accent.opacity(0.1)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: Theme.accent.opacity(0.18), radius: 16)
            VStack(spacing: Space.xs) {
                Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
