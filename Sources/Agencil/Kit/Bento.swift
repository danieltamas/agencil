import SwiftUI

/// One tile of the panel's bento: an eyebrow, a number, a line under it.
struct BentoTile<Footer: View>: View {
    let eyebrow: String
    let value: String
    var tint: Color = Theme.textPrimary
    var big = false
    @ViewBuilder let footer: Footer

    var body: some View {
        Bezel(radius: Radius.smallCard) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Eyebrow(text: eyebrow)
                Text(value).font(big ? .house.statValue : .house.statSmall).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                footer
                if big { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.l)
        }
    }
}

/// The three-tile block under the header: "Needs you" on the left, two small tiles stacked on the right.
struct Bento<Big: View, Top: View, Bottom: View>: View {
    @ViewBuilder let big: Big
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom

    static var height: CGFloat { 140 }

    var body: some View {
        HStack(spacing: Space.m) {
            big.frame(maxWidth: .infinity)
            VStack(spacing: Space.m) { top; bottom }.frame(width: 140)
        }
        .frame(height: Self.height)
    }
}
