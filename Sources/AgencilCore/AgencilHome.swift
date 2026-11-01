import Foundation

/// The directory all of Agencil's state lives in (`~/.agencil`, or `$AGENCIL_HOME`), always mode 0700.
public struct AgencilHome: Sendable {
    public let directory: URL

    /// A home that is already there: the app and its panes use this after the broker created it.
    init(existing directory: URL) { self.directory = directory }

    /// `AGENCIL_HOME` in `environment` wins over `directory`.
    public init(directory: URL, environment: [String: String]) throws {
        if let override = environment["AGENCIL_HOME"], !override.isEmpty {
            self.directory = URL(fileURLWithPath: override)
        } else {
            self.directory = directory
        }
        try FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its old mode through createDirectory.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }
}

extension AgencilHome {
    /// The Unix socket the broker serves and every `agencil` process connects to.
    public var socketPath: String { directory.appendingPathComponent("agencil.sock").path }
}
