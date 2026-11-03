import AppKit
import SwiftUI

/// Every number and size a view may use. Views name a token, never a literal (docs/DESIGN.md "Tokens").
struct HouseFont {
    let eyebrow = Font.system(size: 9.5, weight: .semibold)
    let badge = Font.system(size: 10.5, weight: .semibold).monospacedDigit()
    let meta = Font.system(size: 11)
    let control = Font.system(size: 12, weight: .semibold)
    let body = Font.system(size: 12.5)
    let rowTitle = Font.system(size: 13, weight: .medium)
    let header = Font.system(size: 15, weight: .semibold)
    let sectionTitle = Font.system(size: 18, weight: .semibold)
    let modalTitle = Font.system(size: 20, weight: .semibold)
    let paneTitle = Font.system(size: 24, weight: .semibold)
    let statSmall = Font.system(size: 17, weight: .semibold, design: .rounded)
    let statValue = Font.system(size: 26, weight: .semibold, design: .rounded)
    let mono = Font.system(size: 11.5, design: .monospaced)
    let metaStrong = Font.system(size: 11, weight: .semibold)
}

extension Font {
    static let house = HouseFont()
}

enum Radius {
    static let bezel: CGFloat = 3
    static let tile: CGFloat = 7
    static let row: CGFloat = 8
    static let control: CGFloat = 10
    static let smallCard: CGFloat = 14
    static let card: CGFloat = 16
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 22
    /// A button floating inside the bottom-trailing corner of a field.
    static let float: CGFloat = 10
    static let pane: CGFloat = 28
    /// Panel horizontal inset; the footer uses the same value.
    static let panelInset: CGFloat = 14
}

enum Size {
    /// Every interactive control that sits in a row: one height, fixed, measured by a test.
    static let control: CGFloat = 28
    static let iconButton: CGFloat = 28
    static let chip: CGFloat = 20
    static let tabIsland: CGFloat = 34
    /// The name column of a detail screen's facts, wide enough for "Response time".
    static let detailLabel: CGFloat = 96
    static let settingsRow: CGFloat = 34
    static let menuBarGlyph: CGFloat = 18
    static let panelWidth: CGFloat = 404
    static let panelMaxHeight: CGFloat = 780
    /// The open panel is this tall in every tab, like its sibling apps: the tallest that fits the screen, at most `panelMaxHeight`.
    static var panelHeight: CGFloat { min(panelMaxHeight, (NSScreen.main?.visibleFrame.height ?? 820) - 40) }
    static let settingsMin = CGSize(width: 760, height: 540)
    static let settingsSidebar: CGFloat = 196
    static let modalWidth: CGFloat = 520
    static let panelListLimit: CGFloat = 340
    /// Room kept under a scrolling list so the last row clears a floating action.
    static let floatingClearance: CGFloat = 64
    static let bentoSide: CGFloat = 140
    static let bentoRing: CGFloat = 96
    static let sidebarGlyph: CGFloat = 24
    /// A vendor's mark beside a seat name.
    static let vendorMark: CGFloat = 16
    /// The icon on a More apps card, and the one beside the About version line.
    static let paragraph: CGFloat = 360
    /// The wrapping text of a row that shares its line with a state chip and a button.
    static let rowText: CGFloat = 240
    /// The scrolling model table in Settings: tall enough to read a screenful, short enough to leave the card above it in view.
    static let priceTable: CGFloat = 380
    /// The Costs pane: the day bars' strip, the least a bar shows, and the share meter.
    static let barStrip: CGFloat = 72
    /// The follow-up box: half the height an open editor takes, and the tile of one attachment.
    static let followUpEditor: CGFloat = 112
    static let attachment: CGFloat = 44
    static let barMin: CGFloat = 3
    static let shareBar: CGFloat = 4
    static let shareBarMin: CGFloat = 2
    static let appIcon: CGFloat = 52
    static let aboutIcon: CGFloat = 64
}

/// Named opacities; literal opacities live only in `Kit/`.
struct HouseOpacity {
    let faint = 0.04
    let wash = 0.07
    let tint = 0.14
    let lift = 0.16
    let ring = 0.5
    let dim = 0.58
}

/// Springs only: nothing snaps or eases linearly.
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)
    /// `RiseIn` delay per index, capped at index 10.
    static let riseDelay = 0.035
    static let riseIndexCap = 10
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension View {
    /// Detail text wraps to every line it needs: a reason is never cut short.
    func detailLines() -> some View { fixedSize(horizontal: false, vertical: true) }

    /// A paragraph that wraps at `Size.paragraph` when nothing offers it a width, so a long text never sets the
    /// natural width of a pane; given a width it wraps at that width.
    func paragraph(ideal: CGFloat = Size.paragraph) -> some View {
        frame(idealWidth: ideal, maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
