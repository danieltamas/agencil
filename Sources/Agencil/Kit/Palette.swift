import SwiftUI

/// The looks Agencil can wear. Each one is a palette and a finish; the meaning of a colour (a verdict, a seat
/// state) is the same in every look.
enum Look: String, CaseIterable, Identifiable {
    case agencil
    case solidGlass
    case solidGlassLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agencil: "Agencil"
        case .solidGlass: "Solid Glass"
        case .solidGlassLight: "Solid Glass Light"
        }
    }

    var palette: Palette {
        switch self {
        case .agencil: .agencil
        case .solidGlass: .solidGlass
        case .solidGlassLight: .solidGlassLight
        }
    }
}

/// How a card is made.
enum Finish {
    /// A glass shell holding a machined core.
    case bezel
    /// One thick pane of smoky glass, its finish at the edge.
    case pane
}

struct Palette {
    let scheme: ColorScheme
    let canvas, canvasLift, shell, hairline, core, coreHover, highlight: Color
    /// What a control or a hover is tinted with: toward the text, so it shows on the canvas.
    let wash: Color
    let textPrimary, textSecondary, textTertiary: Color
    /// `accent` is the solid brand hue; `accent2` only tints the backdrop, never a control or a status:
    /// amber on a control would read as warn.
    let accent, accent2: Color
    let brand: LinearGradient
    let ok, warn, crit, unknown: Color
    /// The two backdrop lights; off, the canvas is even.
    let lit: Bool
    let finish: Finish
    /// A pane's second line inside its edge, its hairline outside, and the shadow it stands on.
    let paneInner, paneEdge, paneShade: Color

    static let agencil = Palette(
        scheme: .dark,
        canvas: Color(hex: 0x090A12), canvasLift: Color(hex: 0x0F1020), shell: .white.opacity(0.035),
        hairline: .white.opacity(0.075), core: Color(hex: 0x14152A), coreHover: Color(hex: 0x1A1C35),
        highlight: .white.opacity(0.11), wash: .white,
        textPrimary: .white.opacity(0.94), textSecondary: .white.opacity(0.58), textTertiary: .white.opacity(0.36),
        accent: Color(hex: 0xA98BFF), accent2: Color(hex: 0xF5C451),
        brand: LinearGradient(colors: [Color(hex: 0x6E56F8), Color(hex: 0xA98BFF), Color(hex: 0xFF9BD2)],
                              startPoint: .bottomLeading, endPoint: .topTrailing),
        ok: Color(hex: 0x3EE0A8), warn: Color(hex: 0xFF9F43), crit: Color(hex: 0xFF6B6B),
        unknown: Color(hex: 0x8A97AD), lit: true, finish: .bezel,
        paneInner: .white.opacity(0.04), paneEdge: .white.opacity(0.06), paneShade: .black.opacity(0.45)
    )

    static let solidGlass = Palette(
        scheme: .dark,
        canvas: Color(hex: 0x0D0D0D), canvasLift: Color(hex: 0x141414), shell: .clear,
        hairline: .white.opacity(0.11), core: Color(hex: 0x1D1D1D), coreHover: Color(hex: 0x242424),
        highlight: .white.opacity(0.16), wash: .white,
        textPrimary: Color(hex: 0xFAFAFA), textSecondary: Color(hex: 0xA4A4A4), textTertiary: .white.opacity(0.42),
        accent: Color(hex: 0xB9A2FF), accent2: Color(hex: 0x449DF0),
        brand: LinearGradient(colors: [Color(hex: 0xEBEBEB)], startPoint: .top, endPoint: .bottom),
        ok: Color(hex: 0x4AC777), warn: Color(hex: 0xF79C40), crit: Color(hex: 0xFF6467),
        unknown: Color(hex: 0x868686), lit: false, finish: .pane,
        paneInner: .white.opacity(0.04), paneEdge: .white.opacity(0.06), paneShade: .black.opacity(0.45)
    )

    static let solidGlassLight = Palette(
        scheme: .light,
        canvas: Color(hex: 0xE4E6EB), canvasLift: Color(hex: 0xDBDEE3), shell: .clear,
        hairline: Color(hex: 0x292E38, opacity: 0.13), core: Color(hex: 0xEFF1F5), coreHover: Color(hex: 0xF6F7FA),
        highlight: .white.opacity(0.9), wash: Color(hex: 0x292E38),
        textPrimary: Color(hex: 0x0D0D0D), textSecondary: Color(hex: 0x5B5B5B), textTertiary: Color(hex: 0x868686),
        accent: Color(hex: 0x6A45D1), accent2: Color(hex: 0xB07A00),
        brand: LinearGradient(colors: [Color(hex: 0x161616)], startPoint: .top, endPoint: .bottom),
        ok: Color(hex: 0x0A924B), warn: Color(hex: 0xD87400), crit: Color(hex: 0xE7000B),
        unknown: Color(hex: 0x6F7278), lit: false, finish: .pane,
        paneInner: .white.opacity(0.35), paneEdge: Color(hex: 0x3B4253, opacity: 0.14),
        paneShade: Color(hex: 0x1F2D4C, opacity: 0.14)
    )
}
