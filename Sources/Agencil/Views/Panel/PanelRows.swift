import SwiftUI

/// The rows of each tab. Each row is a `HoverCard`; text follows the 404 pt rules in docs/DESIGN.md.
struct ThreadRow: View {
    let thread: DemoPanel.Thread

    var body: some View {
        HoverCard(accent: thread.failed ? Theme.crit : thread.live ? Theme.running : nil, action: {}) {
            HStack(spacing: Space.l) {
                GlyphDisc(symbol: thread.failed ? "exclamationmark" : thread.live ? "ellipsis" : "checkmark",
                          color: thread.failed ? Theme.crit : thread.live ? Theme.running : Theme.ok)
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

    private var tone: Signal { sitting.state == "BLOCK" ? .crit : sitting.state == "PASS" ? .ok : .running }

    var body: some View {
        HoverCard(accent: Theme.councilHue(sitting.hue), action: open) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Chip(text: sitting.kind, color: Theme.councilHue(sitting.hue))
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

    private var tone: Signal { finding.severity == "P1" ? .crit : finding.severity == "P2" ? .warn : .unknown }

    var body: some View {
        HoverCard(accent: Theme.color(for: tone), action: nil) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Chip(text: finding.severity, color: Theme.color(for: tone))
                    Text(finding.place).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if finding.dissent > 0 { Chip(text: "minority", color: Theme.warn, style: .outline) }
                }
                Text(finding.claim).font(.house.body).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Text("\(finding.backers) back, \(finding.dissent) dissent").font(.house.meta).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    if let confirm, let dismiss {
                        AsyncPress(id: "dismiss:\(finding.id)", action: dismiss) { running, press in
                            ChipButton(title: running ? "..." : "Dismiss", action: press)
                        }
                        AsyncPress(id: "confirm:\(finding.id)", action: confirm) { running, press in
                            ChipButton(title: running ? "..." : "Confirm", action: press)
                        }
                    }
                }
            }
        }
    }
}

struct SeatScoreRow: View {
    let seat: DemoPanel.SeatRow

    var body: some View {
        HoverCard(accent: seat.up ? Theme.ok : Theme.crit, action: {}) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    PulseDot(color: seat.up ? Theme.ok : Theme.crit, live: false)
                    Text(seat.id).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(seat.model).font(.house.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
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
