import SwiftUI

/// What a signal means, in every look. Views pass one of these, never a colour.
enum Signal: CaseIterable {
    case ok, warn, crit, unknown, running
}

/// The design tokens of the look chosen under General (`Looks.swift`).
@MainActor
enum Theme {
    private static var palette: Palette { Appearance.shared.look.palette }

    static let opacity = HouseOpacity()

    static var canvas: Color { palette.canvas }
    static var canvasLift: Color { palette.canvasLift }
    static var shell: Color { palette.shell }
    static var hairline: Color { palette.hairline }
    static var core: Color { palette.core }
    static var coreHover: Color { palette.coreHover }
    static var highlight: Color { palette.highlight }
    static var finish: Finish { palette.finish }
    static var lit: Bool { palette.lit }
    static var scheme: ColorScheme { palette.scheme }
    static var wash: Color { palette.wash }
    static var paneInner: Color { palette.paneInner }
    static var paneEdge: Color { palette.paneEdge }
    static var paneShade: Color { palette.paneShade }

    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var textTertiary: Color { palette.textTertiary }

    static var accent: Color { palette.accent }
    static var accent2: Color { palette.accent2 }
    static var brand: LinearGradient { palette.brand }

    static var ok: Color { palette.ok }
    static var warn: Color { palette.warn }
    static var crit: Color { palette.crit }
    static var unknown: Color { palette.unknown }
    static var running: Color { palette.accent }

    static func color(for signal: Signal) -> Color {
        switch signal {
        case .ok: ok
        case .warn: warn
        case .crit: crit
        case .unknown: unknown
        case .running: running
        }
    }

    /// Council types pick one of eight fixed hues in their editor, never a free hex.
    static let councilHueCount = 8

    static func councilHue(_ index: Int) -> Color {
        let hues: [(dark: UInt32, light: UInt32)] = [
            (0xA98BFF, 0x6A45D1), (0x54D2A4, 0x008760), (0xF5C451, 0xB07A00), (0xFF9BD2, 0xB8307F),
            (0x6FB7FF, 0x0A68C4), (0xFF9F43, 0xD87400), (0x7BE0A0, 0x0A924B), (0xFF6B6B, 0xC62828),
        ]
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return Color(hex: scheme == .light ? hue.light : hue.dark)
    }
}

/// The canvas every Agencil surface sits on, with two lights bleeding in from the top in a look that has them.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.canvas
            if Theme.lit {
                RadialGradient(colors: [Theme.accent.opacity(Theme.opacity.lift), .clear],
                               center: .init(x: 0.1, y: -0.05), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Theme.accent2.opacity(Theme.opacity.wash), .clear],
                               center: .init(x: 0.95, y: 0.02), startRadius: 0, endRadius: 220)
            }
        }
        .ignoresSafeArea()
    }
}
