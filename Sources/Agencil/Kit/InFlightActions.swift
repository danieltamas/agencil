import SwiftUI

/// The presses running now, by id: the one way a view runs an async action. A press holds its id until the
/// action returns or throws, and a second press with the same id meanwhile is nothing, so the button it came
/// from can show the press and refuse another.
@MainActor @Observable final class InFlightActions {
    private(set) var ids: Set<String> = []

    func isRunning(_ id: String) -> Bool { ids.contains(id) }

    /// Runs `action` unless `id` is already running (then false, and nothing runs). The id is removed when the
    /// action returns or throws; a thrown error reaches the caller.
    @discardableResult
    func perform(_ id: String, _ action: () async throws -> Void) async rethrows -> Bool {
        guard ids.insert(id).inserted else { return false }
        defer { ids.remove(id) }
        try await action()
        return true
    }
}

extension EnvironmentValues {
    /// Set once at the root from the store; a press outside any root still guards itself with a local set.
    @Entry var inFlight: InFlightActions?
}
