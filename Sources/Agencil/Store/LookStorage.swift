import AgencilCore
import Foundation

/// The look lives in `config.json` key `look`, written through the config store; nothing else keeps a copy.
enum LookStorage {
    static let key = "look"

    static func persistence(store: ConfigStore) -> LookPersistence {
        LookPersistence(
            load: { (try? store.read())?.values[key] },
            save: { value in _ = try store.update { $0[key] = value } }
        )
    }
}

/// Wires the saved look into `Appearance` once at launch. A home that cannot be opened leaves the default look.
@MainActor
enum LookLaunch {
    static func attach() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil")
        guard let home = try? AgencilHome(directory: fallback, environment: ProcessInfo.processInfo.environment) else { return }
        Appearance.shared.attach(LookStorage.persistence(store: ConfigStore(directory: home.directory)))
    }
}
