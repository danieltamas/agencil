import Foundation

/// Who holds a place among the seats this broker runs. A seat is a process or a model request; a seat that has
/// asked another seat and waits for the answer is parked: it holds no "seats at once" place, but its process
/// still counts against the process cap.
final class Capacity: @unchecked Sendable {
    private struct Entry {
        var parent: String?
        var isProcess: Bool
        var active = false
        var parked = 0
        /// Set once this entry's own seat took a place, which is what parks the parent.
        var parksParent = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Exchange key ("<thread>-<seq>") to the admission id that holds its place.
    private var exchanges: [String: String] = [:]

    /// Takes a place against the process cap; false means the cap is reached. Never waits.
    /// `orphans` are seat processes of a dead broker that are still alive; they hold places too.
    func enter(_ id: String, parentExchange: String?, isProcess: Bool, limits: Limits, orphans: Int) -> Bool {
        lock.withLock {
            let processes = entries.values.filter(\.isProcess).count + orphans
            if isProcess, processes >= limits.processCap { return false }
            entries[id] = Entry(parent: parentExchange.flatMap { exchanges[$0] }, isProcess: isProcess)
            return true
        }
    }

    /// Takes one of the "seats at once" places when one is free. A child takes the place its parent gives up by
    /// waiting for it, and only from that moment: a child that is refused or times out never parks its parent.
    func activate(_ id: String, limits: Limits, orphans: Int) -> Bool {
        lock.withLock {
            guard let entry = entries[id] else { return false }
            var running = entries.values.filter { $0.active && $0.parked == 0 }.count + orphans
            if let parent = entry.parent, let held = entries[parent], held.active, held.parked == 0 { running -= 1 }
            guard running < limits.seatsAtOnce else { return false }
            entries[id]?.active = true
            if let parent = entry.parent, entries[parent] != nil {
                entries[parent]?.parked += 1
                entries[id]?.parksParent = true
            }
            return true
        }
    }

    func bind(_ id: String, exchange: String) {
        lock.withLock { if entries[id] != nil { exchanges[exchange] = id } }
    }

    /// Frees the place of an admission, and unparks its parent.
    func leave(_ id: String) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return }
            if entry.parksParent, let parent = entry.parent { entries[parent]?.parked -= 1 }
            exchanges = exchanges.filter { $0.value != id }
        }
    }

    func leave(exchange: String) {
        let id = lock.withLock { exchanges[exchange] }
        if let id { leave(id) }
    }
}
