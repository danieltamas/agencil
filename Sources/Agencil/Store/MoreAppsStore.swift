import AgencilCore
import AppKit
import Observation
import SwiftUI

/// A Mac app from Settings > More apps that Launch Services knows on this Mac.
struct InstalledCopy: Equatable {
    let url: URL
    /// Nil when there is no release version to compare: shown as installed, compared with nothing.
    let version: String?
    /// The `git describe` a build from a checkout stamps (BtonSource, RMJSource).
    var source: String?

    init(url: URL, info: NSDictionary?, sourceKey: String?) {
        self.url = url
        source = sourceKey.flatMap { info?[$0] as? String }
        version = InstalledVersion.comparable(shortVersion: info?["CFBundleShortVersionString"] as? String, sourceStamp: source)
    }

    init(url: URL, version: String?, source: String? = nil) {
        self.url = url
        self.version = version
        self.source = source
    }
}

extension RegistryApp {
    /// The card accent: the registry's dark hue, or its deeper partner on a light canvas where the bright one washes out.
    @MainActor var hue: Color { Color(hex: Theme.scheme == .light ? light : dark) }

    /// The same app with another release: the screenshots' made-up versions.
    func with(latest: Release?) -> RegistryApp {
        RegistryApp(id: id, name: name, kind: kind, platform: platform, pitch: pitch, detail: detail, repo: repo, site: site,
                    icon: icon, iconShape: iconShape, install: install, mac: mac, dark: dark, light: light, latest: latest)
    }
}

/// Settings > More apps' live part. The list comes from the owner's registry: the bundled copy first, then the last one
/// read into `~/.agencil/registry`, then a fresh read when the pane opens (at most hourly) or on the refresh button.
/// A read that fails or is refused changes nothing on the cards; the header says why.
@MainActor @Observable final class MoreAppsStore {
    private(set) var registry: AppRegistry?
    /// When the list shown was read; nil for the bundled copy, which goes by the registry's own update time.
    private(set) var readAt: Date?
    private(set) var icons: [String: NSImage] = [:]
    private(set) var installed: [String: InstalledCopy] = [:]
    private(set) var checking = false
    private(set) var problem: String?

    @ObservationIgnored private let store: RegistryStore?
    @ObservationIgnored private let userAgent = "Agencil/" + AgencilVersion.current()

    /// An inert store: no registry directory, no network. `demo()` and the tests use it.
    init(directory: URL? = nil) {
        store = directory.map { RegistryStore(directory: $0.appendingPathComponent("registry", isDirectory: true)) }
        guard store != nil else { return }
        if let stored = store?.load(), case let .accepted(registry) = RegistryDecoder.read(stored.data) {
            show(registry, readAt: stored.readAt)
        } else if let registry = Self.bundled() {
            show(registry, readAt: nil)
        } else {
            problem = "This copy of Agencil has no app list. Refresh to read it."
        }
    }

    /// The bundled app list with made-up versions that show every state a card has: behind, built from source with no
    /// release yet, released, and a refresh that failed.
    static func demo(now: Date) -> MoreAppsStore {
        let demo = MoreAppsStore()
        let versions: [String: (String, Double)?] = ["macmax": ("0.3.1", 1), "bton": ("2.4.0", 3), "rmj": nil, "axon": ("1.6.1", 0.5),
                                                     "rundev": ("0.9.3", 12), "cloak": ("1.2.0", 40)]
        guard let bundled = bundled() else { return demo }
        let apps = bundled.apps.map { app in
            guard let made = versions[app.id] else { return app }
            return app.with(latest: made.map { version, daysAgo in
                RegistryApp.Release(version: version, tag: "v\(version)", publishedAt: now.addingTimeInterval(-86_400 * daysAgo),
                                    url: URL(string: "https://github.com/\(app.repo)/releases/tag/v\(version)")!)
            })
        }
        demo.show(AppRegistry(updated: now.addingTimeInterval(-3_600), apps: apps, leftOut: 0), readAt: now.addingTimeInterval(-240))
        demo.installed = ["ro.danieltamas.bton": InstalledCopy(url: URL(fileURLWithPath: "/Applications/Bton.app"), version: "2.3.2"),
                          "ro.danieltamas.rmj": InstalledCopy(url: URL(fileURLWithPath: "/Applications/RMJ.app"), version: nil, source: "a1b2c3d-dirty")]
        demo.problem = "The app list could not be refreshed: GitHub could not be reached."
        return demo
    }

    static func bundled() -> AppRegistry? {
        guard let url = Bundle.main.url(forResource: "apps", withExtension: "json", subdirectory: "Registry"),
              let data = try? Data(contentsOf: url), case let .accepted(registry) = RegistryDecoder.read(data) else { return nil }
        return registry
    }

    /// The bundle's icon for a registry path, for an app whose icon was never fetched (or failed to).
    static func bundledIcon(_ path: String) -> NSImage? {
        guard AppRegistry.iconURL(path) != nil else { return nil }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Registry").appendingPathComponent(path)
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private func show(_ registry: AppRegistry, readAt: Date?) {
        self.registry = registry
        self.readAt = readAt
        for app in registry.apps where icons[app.icon] == nil {
            icons[app.icon] = store?.icon(path: app.icon).flatMap(NSImage.init(data:)) ?? Self.bundledIcon(app.icon)
        }
    }

    /// Called when the pane opens: scans this Mac, and reads the list when it is due.
    func appear() {
        Task { await refresh(byPress: false) }
    }

    /// The refresh button's press: reads even when the last read is under an hour old.
    func refreshAction() -> () async -> Void {
        { [self] in await refresh(byPress: true) }
    }

    func refresh(byPress: Bool) async {
        guard store != nil else { return }
        readInstalled()
        guard !checking, RegistryRefresh.isDue(lastRead: readAt, now: Date(), byPress: byPress) else { return }
        checking = true
        defer { checking = false }
        await read()
    }

    private func read() async {
        let answer = await RegistryDownload.get(AppRegistry.fileURL, userAgent: userAgent, maxBytes: RegistryDecoder.maxBytes)
        guard case let .data(data) = answer else {
            if case let .failed(reason) = answer { problem = "The app list could not be refreshed: \(reason)" }
            return
        }
        switch RegistryDecoder.read(data) {
        case let .accepted(registry):
            let now = Date()
            do {
                try store?.save(data, readAt: now)
                problem = nil
            } catch {
                problem = "The app list was read but could not be saved, so the next launch reads it again."
            }
            show(registry, readAt: now)
            // An app new to the list may already be on this Mac: the scan before the read only knew the old list.
            readInstalled()
            await fetchIcons(registry.apps)
        case .newerSchema:
            problem = "This version of Agencil can't read the newer app list. Update Agencil to see it."
        case let .refused(reason):
            problem = "The app list could not be used: \(reason)"
        }
    }

    /// Icons the store does not hold yet. A changed icon always has a new path, so a stored one is never read again;
    /// a failed one keeps the bundle's or the fallback glyph.
    private func fetchIcons(_ apps: [RegistryApp]) async {
        guard let store else { return }
        for app in apps where store.icon(path: app.icon) == nil {
            guard let url = AppRegistry.iconURL(app.icon),
                  case let .data(data) = await RegistryDownload.get(url, userAgent: userAgent, maxBytes: RegistryIcon.maxBytes),
                  RegistryIcon.accepts(data), let image = NSImage(data: data) else { continue }
            try? store.saveIcon(data, path: app.icon)
            icons[app.icon] = image
        }
    }

    private func readInstalled() {
        var found: [String: InstalledCopy] = [:]
        for app in registry?.apps ?? [] {
            guard let mac = app.mac, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mac.bundleID) else { continue }
            // Read from disk each time: Bundle caches its Info.plist, so an update made while Agencil runs would not show.
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            found[mac.bundleID] = InstalledCopy(url: url, info: info, sourceKey: mac.sourceKey)
        }
        installed = found
    }
}
