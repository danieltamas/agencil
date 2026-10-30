import Foundation

/// The harness kinds Agencil knows how to find, as data (`catalog.json`), so a new kind needs no code.
public struct HarnessCatalog: Decodable, Sendable {
    public struct Status: Decodable, Sendable {
        /// A non-interactive command: it must never prompt or open a browser.
        public let arguments: [String]
        public let signedInOutput: String
        public let signedInExitCode: Int32
        public let signedOutOutput: String
        public let signedOutExitCode: Int32
    }

    /// Launches `server` as a stdio MCP child of the harness, so the child's answer shows what environment it got.
    public struct ChainProbe: Decodable, Sendable {
        /// `{server}` is replaced with `server`.
        public let arguments: [String]
        public let server: String
    }

    public struct Entry: Decodable, Sendable {
        public let kind: String
        public let executable: String
        public let versionArguments: [String]
        /// Absent when the harness has no non-interactive status command: its sign-in state stays unknown.
        public let status: Status?
        public let chainNotes: String
        public let installHint: String
        public let chainProbe: ChainProbe?
    }

    public let entries: [Entry]

    /// The catalog compiled into the binary (`CatalogData.swift`, generated from catalog.json).
    public static func embedded() throws -> HarnessCatalog { try decode(Data(CatalogData.json.utf8)) }

    public static func decode(_ data: Data) throws -> HarnessCatalog {
        try JSONDecoder().decode(HarnessCatalog.self, from: data)
    }
}

public enum SignInState: Equatable, Sendable {
    case signedIn
    case signedOut
    case unknown(reason: String)
}

public enum ProbeStatus: Error, Equatable, Sendable {
    case ok
    case timedOut
    case failed(reason: String)

    public var message: String {
        switch self {
        case .ok: "ok"
        case .timedOut: "probe timed out"
        case .failed(let reason): reason
        }
    }
}

public enum ChainSupport: Equatable, Sendable {
    /// The stdio child received the harness's environment.
    case supported
    /// The harness started the child but scrubbed the environment.
    case unsupported
    case untested
}

public struct HarnessProbe: Equatable, Sendable {
    public let kind: String
    /// Every executable found, search path first, then the known install directories.
    public let paths: [URL]
    /// The executable that `version`, `signedIn` and `chainSupport` describe: the newest one found. Nil when none.
    public let executable: URL?
    public let version: String?
    public let signedIn: SignInState
    public let probeStatus: ProbeStatus
    public let chainSupport: ChainSupport
    /// Every install whose version command answered; a seat's pin picks among them.
    public var installs: [Install] = []

    public struct Install: Equatable, Sendable {
        public let executable: URL
        public let version: String
        public let signedIn: SignInState
        public init(executable: URL, version: String, signedIn: SignInState) {
            self.executable = executable; self.version = version; self.signedIn = signedIn
        }
    }
}
