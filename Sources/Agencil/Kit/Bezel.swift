import SwiftUI

/// Every card sits in one, so nothing lies flat on the canvas: a double bezel, or a pane in a look whose finish
/// is one. Both take the same room.
struct Bezel<Content: View>: View {
    var radius: CGFloat = Radius.card
    var fill: Color = Theme.core
    var glow: Color?
    @ViewBuilder let content: Content

    /// Only what is drawn round the content changes with the finish: the content keeps its identity, and with
    /// it the state of an editor open inside.
    var body: some View {
        let core = RoundedRectangle(cornerRadius: radius - Radius.bezel, style: .continuous)
        content
            .background {
                if Theme.finish == .bezel { core.fill(fill) }
            }
            .overlay {
                // The core's top edge catches the light; the sides fade out.
                if Theme.finish == .bezel {
                    core.strokeBorder(LinearGradient(colors: [Theme.highlight, .clear, .clear],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .padding(Radius.bezel)
            .background {
                switch Theme.finish {
                case .bezel: shell
                case .pane: pane
                }
            }
    }

    private var shell: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.shell)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.35 : 0.25), radius: 18, y: 8)
    }

    /// One thick pane whose face stays flat: a line of light along its top edge, a faint second line inside the
    /// edge, a hairline outside it, and the shadow it stands on.
    private var pane: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(fill.shadow(.inner(color: Theme.highlight, radius: 0, y: 1)))
            .overlay(shape.strokeBorder(Theme.paneInner, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: radius + 0.5, style: .continuous)
                .stroke(Theme.paneEdge, lineWidth: 1).padding(-0.5))
            .shadow(color: Theme.paneShade.opacity(0.22), radius: 1, y: 1)
            .shadow(color: glow?.opacity(0.25) ?? Theme.paneShade, radius: 14, y: 10)
    }
}

/// A capsule's outline as a ring to fill even-odd: a stroked one drew with a gap in its bottom edge.
struct CapsuleRing: Shape {
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Capsule().path(in: rect)
        path.addPath(Capsule().path(in: rect.insetBy(dx: width, dy: width)))
        return path
    }
}
