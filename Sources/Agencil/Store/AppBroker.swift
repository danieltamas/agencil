import AgencilCore
import Foundation

/// The broker lives in the app: opening Agencil is what lets the CLI and MCP clients reach it. A headless
/// `agencil serve` already holding the lock is fine - the app simply does not start a second one.
enum AppBroker {
    private static let holder = Holder()

    private final class Holder: @unchecked Sendable { var broker: Broker? }

    static func start() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let home = try AgencilHome(
                directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil"),
                environment: environment)
            // Seats are launched through the bundled CLI, never through the app binary.
            let cli = Bundle.main.resourceURL?.appendingPathComponent("agencil").path
            let broker = try Broker(home: home, environment: environment, launcherExecutable: cli)
            try broker.start()
            holder.broker = broker
        } catch {
            FileHandle.standardError.write(Data("agencil: broker not started: \(error.localizedDescription)\n".utf8))
        }
    }
}
