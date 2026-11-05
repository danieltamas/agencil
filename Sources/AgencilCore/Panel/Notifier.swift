import Foundation

/// Which notifications the owner turned on: `config.json` key `notify`, a JSON list of kinds; absent means all.
public struct NotifySettings: Sendable, Equatable {
    public static let kinds: Set<String> = ["verdict", "block", "seat", "budget", "thread"]

    public let notify: Set<String>

    public init(values: [String: String]) throws {
        guard let text = values["notify"] else { notify = Self.kinds; return }
        func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "notify", problem: problem) }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw fail("not valid JSON") }
        guard let list = parsed as? [String] else { throw fail("expected a list of kinds") }
        guard list.allSatisfy(Self.kinds.contains) else { throw fail("kinds are verdict, block, seat, budget and thread") }
        notify = Set(list)
    }
}

public enum PanelEvent: Equatable, Sendable {
    case verdict(sitting: String, verdict: String)
    case block(sitting: String)
    case seatDied(seat: String)
    case budget(percent: Double)
    case threadFailed(thread: String)
}

/// Turns two consecutive reads into the notifications between them (docs/U8-SPEC.md "Notifications").
public enum Notifier {
    private static let threshold = 80.0

    public static func events(previous: PanelData?, current: PanelData, settings: NotifySettings) -> [PanelEvent] {
        guard let previous else { return [] }
        var events: [PanelEvent] = []
        let before = Dictionary(previous.sittings.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for sitting in current.sittings where before[sitting.id] == "running" {
            switch sitting.state {
            case "PASS", "INCOMPLETE", "AGREED", "SPLIT", "ANSWERED": events.append(.verdict(sitting: sitting.id, verdict: sitting.state))
            case "BLOCK": events.append(.block(sitting: sitting.id))
            default: break
            }
        }
        let up = Dictionary(previous.seats.items.map { ($0.name, $0.up) }, uniquingKeysWith: { first, _ in first })
        for seat in current.seats.items where up[seat.name] == true && !seat.up { events.append(.seatDied(seat: seat.name)) }
        if let was = share(previous), let now = share(current), was < threshold, now >= threshold { events.append(.budget(percent: now)) }
        let threads = Dictionary(previous.threads.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for thread in current.threads where thread.state == "failed" && threads[thread.id] != "failed" {
            events.append(.threadFailed(thread: thread.id))
        }
        return events.filter { settings.notify.contains(kind(of: $0)) }
    }

    private static func share(_ data: PanelData) -> Double? {
        guard let budget = data.week.budgetUSD, budget > 0 else { return nil }
        return data.week.spendUSD / budget * 100
    }

    private static func kind(of event: PanelEvent) -> String {
        switch event {
        case .verdict: "verdict"
        case .block: "block"
        case .seatDied: "seat"
        case .budget: "budget"
        case .threadFailed: "thread"
        }
    }
}
