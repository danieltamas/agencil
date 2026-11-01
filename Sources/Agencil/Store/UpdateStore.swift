import AgencilCore
import AppKit
import Observation

/// The shared release check and the one installer run. About reads this store; nothing else asks GitHub.
@MainActor @Observable final class UpdateStore {
    enum Check: Equatable {
        case ready
        case loading
        case failed(String)
    }

    static let repo = "danieltamas/agencil"

    private(set) var latest: ReleaseInfo?
    private(set) var check = Check.ready
    private(set) var state = UpdateState.idle
    let runningVersion: String
    let buildSource: String?
    /// `v0.1.0 + 3 commits (abc1234), built from source`: what About shows for this build.
    let versionLine: String
    private let bundlePath: String

    @ObservationIgnored private let home: AgencilHome?
    @ObservationIgnored private var schedule = ReleaseCheckSchedule(now: Date())
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private lazy var coordinator: UpdateCoordinator = {
        let stopped: @Sendable (String) -> Void = { [weak self] reason in
            Task { @MainActor in await self?.installerStopped(reason: reason) }
        }
        let root = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
        let home = home
        return UpdateCoordinator { version in
            try Self.launchInstaller(version: version, home: home, root: root, stopped: stopped)
        }
    }()

    /// `home` nil is an inert store (the screenshots): it never asks GitHub and never launches the installer.
    init(home: AgencilHome?, infoDictionary: [String: Any]? = Bundle.main.infoDictionary, bundlePath: String = Bundle.main.bundlePath) {
        self.home = home
        self.bundlePath = bundlePath
        runningVersion = AgencilVersion.current(infoDictionary: infoDictionary)
        buildSource = AgencilVersion.source(infoDictionary: infoDictionary)
        versionLine = AgencilVersion.line(infoDictionary: infoDictionary)
    }

    /// The store of the running app, started once at launch and shared by every Settings window.
    static let shared: UpdateStore = {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil")
        return UpdateStore(home: try? AgencilHome(directory: fallback, environment: ProcessInfo.processInfo.environment))
    }()

    /// The made-up states of the screenshots: a build from source, four commits past v0.3.0, with v0.4.0 out.
    static func demo(now: Date) -> UpdateStore {
        let demo = UpdateStore(home: nil, infoDictionary: ["CFBundleShortVersionString": "0.3.0", AgencilVersion.sourceKey: "v0.3.0-4-g3f9a2c1"],
                               bundlePath: "/Applications/Agencil.app")
        demo.latest = ReleaseInfo(tag: "v0.4.0", version: "0.4.0", htmlURL: nil, publishedAt: now.addingTimeInterval(-86_400 * 2))
        return demo
    }

    var standing: Standing { AgencilRelease.standing(version: runningVersion, source: buildSource, latestTag: latest?.tag) }

    /// The version Update would install; nil unless this is the installed app and it is behind a valid release.
    var updateVersion: String? {
        UpdateOffer.version(standing: standing, installed: UpdateOffer.isInstalledLocation(
            bundlePath: bundlePath, home: FileManager.default.homeDirectoryForCurrentUser.path), latestTag: latest?.tag)
    }

    /// A newer release exists, even when this copy cannot update itself (a build folder).
    var newerRelease: Bool { standing == .behind }

    /// At launch and every 24 hours; a "Check again" press skips the 15-minute floor but still waits out a GitHub pause.
    func start() {
        guard home != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if schedule.nextAutomatic <= Date() { await refresh(byPress: false) }
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    /// "Check again": the owner is asking, so the 15-minute floor does not apply.
    func checkAction() -> () async -> Void {
        { [self] in await refresh(byPress: true) }
    }

    func installAction() -> () async -> Void {
        { [self] in await install() }
    }

    func refresh(byPress: Bool) async {
        let now = Date()
        guard home != nil, check != .loading else { return }
        guard byPress ? schedule.mayCheckByPress(at: now) : schedule.mayCheck(at: now) else {
            if byPress { fail("GitHub asked Agencil to wait before checking again.") }
            return
        }
        schedule.recordAttempt(at: now)
        check = .loading
        switch await GitHubReleases.latest(repo: Self.repo, userAgent: "Agencil/\(runningVersion)") {
        case let .release(info):
            schedule.recordSuccess(at: Date())
            latest = info
            check = .ready
        case .none:
            // No release published yet: the honest answer is "none", not a failure.
            schedule.recordSuccess(at: Date())
            latest = nil
            check = .ready
        case let .rateLimited(retryAfter):
            schedule.recordRateLimit(at: Date(), retryAfter: retryAfter)
            fail("GitHub asked Agencil to wait before checking again.")
        case let .failed(reason): fail(reason)
        }
    }

    /// A failed check is not "still the same release": no update is offered from the earlier answer.
    private func fail(_ reason: String) {
        latest = nil
        check = .failed(reason)
    }

    func install() async {
        guard home != nil, let version = updateVersion else { return }
        state = .updating(version)
        state = await coordinator.start(version: version)
    }

    /// The bundled installer, outliving this app: it stops Agencil, swaps the copy and opens the new one.
    private func installerStopped(reason: String) async {
        state = await coordinator.installerStopped(reason: reason)
    }

    private nonisolated static func launchInstaller(
        version: String, home: AgencilHome?, root: String, stopped: @escaping @Sendable (String) -> Void
    ) throws {
        guard let home, let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            throw UpdateLog.Failure(reason: "The installer is not part of this build.")
        }
        let log = try UpdateLog.open(at: home.directory.appendingPathComponent("update.log"))
        let handle = FileHandle(fileDescriptor: log, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = [
            "AGENCIL_VERSION": version, "AGENCIL_INSTALL_ROOT": root, "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        // A successful install quits this app, so reaching here with the installer gone means it failed.
        process.terminationHandler = { _ in
            stopped(lastLogLine(home: home) ?? "The installer stopped without saying why.")
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    /// Why the last update did not finish, from the log.
    private nonisolated static func lastLogLine(home: AgencilHome) -> String? {
        guard let data = try? Data(contentsOf: home.directory.appendingPathComponent("update.log")) else { return nil }
        return UpdateLog.lastLine(of: String(decoding: data.suffix(4_000), as: UTF8.self))
    }
}
