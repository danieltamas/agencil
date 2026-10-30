import SwiftUI

/// How far a date is from now, in days, hours and minutes, redrawn once a minute. SwiftUI's relative style
/// counts seconds under an hour, so every row with a date would redraw every second.
struct RelativeTime: View {
    let date: Date
    var format: (String) -> String = { $0 }
    @Environment(\.demoNow) private var demoNow

    var body: some View {
        TimelineView(.everyMinute) { context in Text(format(Self.text(date, now: demoNow ?? context.date))) }
    }

    static func text(_ date: Date, now: Date) -> String {
        let seconds = abs(now.timeIntervalSince(date))
        return seconds < 60 ? "under a minute" : formatter.string(from: seconds) ?? ""
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .short
        return formatter
    }()
}
