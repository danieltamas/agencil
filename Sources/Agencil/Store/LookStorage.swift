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
