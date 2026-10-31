import Foundation

/// The model ids a leaderboard may name. The lists come from `scripts/leaderboard/` through `PublicModelsData`,
/// so the app and the CI validator agree on them.
public enum PublicModels {
    public static let pattern = "^[a-z0-9][a-z0-9._:-]{0,63}$"
    /// Aliases the owner approved on `main` as of this build.
    public static var approvedAliases: Set<String> { PublicModelsData.aliases }

    public static func isPublic(_ id: String) -> Bool { PublicModelsData.models.contains(id) }
    static func matchesPattern(_ id: String) -> Bool { id.range(of: pattern, options: .regularExpression) != nil }
}
