import Observation

/// Where the Settings window should open. The panel and the Settings scene are separate roots with no store in
/// common, so a seat row that wants its detail leaves the request here; `SettingsView` claims it once.
@MainActor @Observable final class SettingsRoute {
    static let shared = SettingsRoute()

    /// The seat whose row the Seats pane marks.
    private(set) var seat: String?
    /// True from `show(seat:)` until the window has claimed the request.
    private(set) var pending = false

    func show(seat name: String) {
        seat = name
        pending = true
    }

    /// Whether a request waits; asking consumes it, so a later open of Settings lands where the owner left it.
    func claim() -> Bool {
        defer { pending = false }
        return pending
    }
}
