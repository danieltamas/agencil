import Foundation

/// The "Star on GitHub" offer in the panel footer. It asks GitHub once whether the owner's `gh` account has starred
/// Agencil, remembers a yes in `config.json` (`starred_repo`) and never asks again. Starring is the owner's click
/// and nothing else: the call goes through their own logged-in `gh`, and nothing is sent anywhere else.
public struct RepoStar: Sendable {
    public enum Standing: Equatable, Sendable { case starred, notStarred, unknown }

    /// Runs `gh` with arguments and returns its exit status and standard output.
    public typealias GH = @Sendable ([String]) async -> (status: Int32, output: String)

    public static let repo = "danieltamas/agencil"
    static let key = "starred_repo"

    private let store: ConfigStore
    private let gh: GH

    public init(directory: URL, gh: @escaping GH = RepoStar.realGH) {
        store = ConfigStore(directory: directory)
        self.gh = gh
    }

    /// Whether the footer may offer the star, read from disk only. A config that cannot be read is unknown: no offer.
    public func shouldOffer() -> Bool {
        guard let snapshot = try? store.read() else { return false }
        return snapshot.values[Self.key] != "true"
    }

    /// Asks GitHub once; a yes is remembered. No `gh`, no login or no answer is `unknown`: nothing is offered then.
    public func refresh() async -> Standing {
        guard let snapshot = try? store.read() else { return .unknown }
        if snapshot.values[Self.key] == "true" { return .starred }
        let answer = await gh(["api", "-i", "user/starred/\(Self.repo)"])
        switch Self.httpStatus(answer.output) {
        case 204:
            remember()
            return .starred
        case 404: return .notStarred
        default: return .unknown
        }
    }

    /// Stars the repository for the owner's `gh` account. True when GitHub said so (204), and then it is remembered;
    /// a save that fails only means the next launch asks GitHub again.
    public func star() async -> Bool {
        let answer = await gh(["api", "-i", "-X", "PUT", "user/starred/\(Self.repo)"])
        guard Self.httpStatus(answer.output) == 204 else { return false }
        remember()
        return true
    }

    private func remember() { _ = try? store.update { $0[Self.key] = "true" } }

    /// The status code on `gh api -i`'s first line ("HTTP/2.0 204 No Content"); nil when there is none.
    static func httpStatus(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix("HTTP/") else { return nil }
        return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }

    /// `GH_HOST` is pinned: an inherited one would send the question to a GitHub Enterprise server instead.
    public static let realGH: GH = { arguments in
        guard let output = try? await ProcessRunner().run(["gh"] + arguments, environment: ["GH_HOST": "github.com"],
                                                          timeout: .seconds(30), gracePeriod: .seconds(2)) else { return (1, "") }
        return (output.status, String(decoding: output.stdout, as: UTF8.self))
    }
}
