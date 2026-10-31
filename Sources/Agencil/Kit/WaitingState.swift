import SwiftUI

/// A list that has not been read yet: one quiet line, never "nothing here" before the first read.
struct WaitingState: View {
    let title: String

    var body: some View {
        HStack(spacing: Space.m) {
            PulseDot(color: Theme.accent, live: false)
            Text(title).font(.house.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity)
    }
}
