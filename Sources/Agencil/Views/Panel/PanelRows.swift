import SwiftUI

/// The rows of each tab. Each row is a `HoverCard`; text follows the 404 pt rules in docs/DESIGN.md.
struct ThreadRow: View {
    let thread: DemoPanel.Thread
    var open: () -> Void = {}

    var body: some View {
        let tone = Theme.color(for: PanelTone.signal(state: thread.status))
        HoverCard(accent: tone, action: open) {
            HStack(alignment: .top, spacing: Space.m) {
                VendorMark(vendor: thread.vendor).padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.s) {
                        Text(thread.caller).font(.house.meta)
                        ArrowGlyph()
                        Text(thread.seat).metaStrong()
                    }
                    .foregroundStyle(Theme.textSecondary)
                    Text(thread.question).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).titleLines()
                    Text(thread.state).font(.house.meta).foregroundStyle(thread.failed ? Theme.crit : Theme.textTertiary).detailLines()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct SittingRow: View {
    let sitting: DemoPanel.Sitting
    var stopping = false
    var stop: (() async -> Void)?
    var open: () -> Void = {}

    private var tone: Signal { PanelTone.signal(state: sitting.state) }

    var body: some View {
        HoverCard(accent: Theme.color(for: tone), action: open) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Chip(text: sitting.kind, color: Theme.councilHue(sitting.hue))
                    HStack(spacing: Space.xs) { ForEach(Array(sitting.vendors.enumerated()), id: \.offset) { _, vendor in VendorMark(vendor: vendor) } }
                    Spacer(minLength: 0)
                    Chip(text: sitting.state, color: Theme.color(for: tone))
                }
                Text(sitting.target).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).titleLines()
                HStack(spacing: Space.s) {
                    if !sitting.wokenBy.isEmpty { Text("woken by \(sitting.wokenBy)").lineLimit(1); Text("-") }
                    if sitting.seats > 0 { Text("\(sitting.seats) seats"); Text("-") }
                    Text(sitting.elapsed)
                    Text("-"); Text(sitting.cost)
                    Spacer(minLength: 0)
                    if sitting.live {
                        AsyncPress(id: "stop:\(sitting.id)", action: stop ?? {}) { running, press in
                            ChipButton(title: running || stopping ? "Stopping..." : "Stop", destructive: true, action: press)
                        }
                    }
                }
                .font(.house.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct FindingRow: View {
    let finding: DemoPanel.Finding
    var confirm: (() async -> Void)?
    var dismiss: (() async -> Void)?
    var adjudicate: (() async -> Void)?
    var open: (() -> Void)?

    @State private var expanded = false

    private var tone: Signal { PanelTone.signal(severity: finding.severity) }

    var body: some View {
        HoverCard(accent: Theme.color(for: tone), action: open) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Chip(text: finding.severity, color: Theme.color(for: tone))
                    Text(finding.origin).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let confidence = finding.confidence { Text(confidence).font(.house.meta).foregroundStyle(Theme.textTertiary) }
                    if finding.dissent > 0 { Chip(text: "minority", color: Theme.warn, style: .outline) }
                }
                Text(finding.claim).font(.house.body).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix {
                    // Three lines are enough to judge a fix; the rest opens on demand so the buttons stay in view.
                    (Text("Suggested fix: ").foregroundStyle(Theme.textTertiary) + Text(fix).foregroundStyle(Theme.textPrimary))
                        .font(.house.body)
                        .lineLimit(expanded || fix.count <= Size.clampChars ? nil : Size.clampLines)
                        .fixedSize(horizontal: false, vertical: true)
                    if fix.count > Size.clampChars {
                        ChipButton(title: expanded ? "Show less" : "Show more") { expanded.toggle() }
                    }
                }
                HStack(spacing: Space.s) {
                    Text(finding.voices ?? "\(finding.backers) back, \(finding.dissent) dissent").font(.house.meta).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let confirm, let dismiss {
                        if let adjudicate {
                            AsyncPress(id: "adjudicate:\(finding.id)", action: adjudicate) { running, press in
                                ChipButton(title: running ? "Asking..." : "Ask a seat", action: press)
                            }
                        }
                        AsyncPress(id: "dismiss:\(finding.id)", action: dismiss) { running, press in
                            ChipButton(title: running ? "..." : "Dismiss", action: press)
                        }
                        AsyncPress(id: "confirm:\(finding.id)", action: confirm) { running, press in
                            ChipButton(title: running ? "..." : "Confirm", prominent: true, action: press)
                        }
                    }
                }
            }
        }
    }
}

struct SeatScoreRow: View {
    let seat: DemoPanel.SeatRow
    var open: () -> Void = {}

    var body: some View {
        // The band is the one health signal: ok while the seat can sit, crit with the reason underneath when not.
        HoverCard(accent: seat.up ? Theme.ok : Theme.crit, action: open) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .top, spacing: Space.m) {
                    VendorMark(vendor: seat.vendor).padding(.top, Space.xxs)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(seat.id).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        // The whole model id: it wraps, it is never cut in the middle.
                        Text(seat.model).font(.house.mono).foregroundStyle(Theme.textSecondary).detailLines()
                        if !seat.meta.isEmpty { Text(seat.meta).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines() }
                        if !seat.up { Text(seat.reason).font(.house.meta).foregroundStyle(Theme.crit).detailLines() }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Space.l) {
                    stat("Confirmed", seat.confirmed)
                    stat("Coverage", seat.coverage)
                    stat("Per find", seat.cost)
                    stat("Median", seat.median)
                }
                Text(seat.overlap).font(.house.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Eyebrow(text: name)
            Text(value).metaStrong().foregroundStyle(seat.enough ? Theme.textPrimary : Theme.textTertiary).lineLimit(1)
        }
    }
}
