import AgencilCore
import Foundation
import UserNotifications

/// Tells the owner what changed between two reads. Never on the first read, and only the kinds turned on in General.
@MainActor final class PanelNotifier {
    private let settings: () -> NotifySettings?
    private var asked = false

    init(settings: @escaping () -> NotifySettings?) { self.settings = settings }

    func deliver(previous: PanelData?, current: PanelData) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard let enabled = settings() else { return }
        let events = Notifier.events(previous: previous, current: current, settings: enabled)
        guard !events.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        for event in events {
            let content = UNMutableNotificationContent()
            (content.title, content.body) = Self.text(event)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func text(_ event: PanelEvent) -> (String, String) {
        switch event {
        case .verdict(let sitting, let verdict): ("Verdict: \(verdict)", "Sitting \(sitting) has a verdict.")
        case .block(let sitting): ("BLOCK", "Sitting \(sitting) blocked the change.")
        case .seatDied(let seat): ("Seat down", "\(seat) is no longer reachable.")
        case .budget(let percent): ("Budget at \(Int(percent))%", "This week's spend passed the alert line.")
        case .threadFailed(let thread): ("Thread failed", "Thread \(thread) did not get an answer.")
        }
    }
}
