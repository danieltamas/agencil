import Foundation

/// The Stop press of a live sitting (docs/U8-SPEC.md "Stop"): `stopping` at once, one broker call, and back to idle
/// only once a read shows the sitting final. The broker ends the seat process groups; this type kills nothing.
@MainActor public final class StopControl {
    public enum State: Equatable, Sendable {
        case idle(reason: String?)
        case stopping
    }

    private let stop: @MainActor (String) async throws -> Void
    private var states: [String: State] = [:]
    private var delivered: Set<String> = []

    public init(stop: @escaping @MainActor (String) async throws -> Void) { self.stop = stop }

    public func state(for id: String) -> State { states[id] ?? .idle(reason: nil) }

    public func press(_ id: String) async {
        guard states[id] != .stopping else { return }
        states[id] = .stopping
        do {
            try await stop(id)
            delivered.insert(id)
        } catch {
            states[id] = .idle(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Feeds the control each fresh read: a delivered stop ends once its sitting is no longer running.
    public func observe(_ data: PanelData) {
        for id in delivered {
            let running = data.sittings.first { $0.id == id }?.state == "running"
            if !running {
                states[id] = .idle(reason: nil)
                delivered.remove(id)
            }
        }
    }
}
