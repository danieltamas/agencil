import Observation

/// Where the Settings window should open. The panel and the Settings scene are separate roots with no store in
/// common, so a seat row that wants its detail leaves the request here; `SettingsView` claims it once.
@MainActor @Observable final class SettingsRoute {
    static let shared = SettingsRoute()

    /// The seat whose row the Seats pane marks.
    private(set) var seat: String?
    /// The thread or sitting the Costs pane asks the panel to open.
    private(set) var detail: String?

    /// True from `show(seat:)` until the window has claimed the request.
    private(set) var pending = false

    /// The pane the pending request opens: Seats for a seat, or the one `show(pane:)` named.
    private(set) var pane: SettingsPane = .seats

    func show(seat name: String) {
        seat = name
        pane = .seats
        pending = true
    }

    /// Asks the Settings window to open on `pane` (Setup's link to Agent access).
    func show(pane: SettingsPane) {
        self.pane = pane
        pending = true
    }

    func show(detail id: String) { detail = id }

    /// The detail the owner asked for in Settings, once: the panel opens it.
    func claimDetail() -> String? {
        defer { detail = nil }
        return detail
    }

    /// Whether a request waits; asking consumes it, so a later open of Settings lands where the owner left it.
    func claim() -> Bool {
        defer { pending = false }
        return pending
    }
}
