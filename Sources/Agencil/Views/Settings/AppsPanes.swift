import AgencilCore
import AppKit
import SwiftUI

/// Settings > More apps: the registry's cards, as MacMax shows them.
struct MoreAppsPane: View {
    let store: SettingsStore
    private var apps: MoreAppsStore { store.apps }

    /// Every app in the registry but Agencil itself, in the registry's order.
    private var listed: [RegistryApp] { apps.registry?.shown(excluding: "agencil") ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            checkRow
            group("In the menu bar", .menuBar)
            group("In the terminal", .terminal)
        }
        .onAppear { apps.appear() }
    }

    @ViewBuilder private var checkRow: some View {
        if apps.checking {
            OperationProgress(text: "Reading the latest app list...")
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    // The time of the list shown: the last good read, or for the bundled copy the registry's own update.
                    if let read = apps.readAt {
                        RelativeTime(date: read) { "Latest releases, checked \($0) ago." }
                            .font(.house.meta).foregroundStyle(Theme.textTertiary)
                    } else if let updated = apps.registry?.updated {
                        RelativeTime(date: updated) { "Latest releases as of \($0) ago." }
                            .font(.house.meta).foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Latest releases.").font(.house.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    AsyncIconButton(symbol: "arrow.clockwise", help: "Read the app list again", id: "apps:refresh", action: apps.refreshAction())
                }
                if let leftOut = apps.registry?.leftOut, leftOut > 0 {
                    Text(leftOut == 1 ? "1 app needs a newer Agencil to show." : "\(leftOut) apps need a newer Agencil to show.")
                        .font(.house.meta).foregroundStyle(Theme.textTertiary)
                }
                if let problem = apps.problem { ProblemText(text: problem) }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ kind: RegistryApp.Kind) -> some View {
        let members = listed.filter { app in app.kind == kind }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: Space.l) {
                Eyebrow(text: title).padding(.leading, Space.xs)
                ForEach(members) { app in
                    MoreAppCard(app: app, icon: apps.icons[app.icon], installed: app.mac.flatMap { mac in apps.installed[mac.bundleID] })
                }
            }
        }
    }
}

private struct MoreAppCard: View {
    let app: RegistryApp
    let icon: NSImage?
    let installed: InstalledCopy?

    var body: some View {
        Bezel(glow: app.hue) {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.l) {
                    MoreAppIcon(app: app, image: icon)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            Text(app.name).font(.house.header).foregroundStyle(Theme.textPrimary).lineLimit(1).fixedSize()
                            Chip(text: app.platform, color: app.hue)
                            Spacer(minLength: Space.m)
                            if let installed { LinkChip(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(installed.url) } }
                            if let site = app.site { LinkChip(title: "Website", url: site) }
                            LinkChip(title: "GitHub", url: app.repoURL)
                        }
                        Text(app.pitch).font(.house.body).foregroundStyle(Theme.textSecondary).paragraph()
                        Text(app.detail).font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph()
                        statusLine
                    }
                }
                // Full width, so a curl line reads whole instead of cut in the middle. Only once there is a release:
                // a command that fails is worse than none.
                if app.latest != nil { InstallLine(command: app.install) }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The latest release and when it came out, and how the copy on this Mac compares with it.
    private var statusLine: some View {
        HStack(spacing: Space.s) {
            if let latest = app.latest {
                Chip(text: "v\(latest.version)", color: app.hue, style: .outline).help("The latest release on GitHub")
            } else {
                Chip(text: "In development", color: Theme.textTertiary, style: .dashed).help("No release on GitHub yet")
            }
            if let installed {
                installedChip(installed, InstalledStanding.compare(isInstalled: true, installedVersion: installed.version,
                                                                   latestTag: app.latest?.tag))
            }
            if let published = app.latest?.publishedAt {
                RelativeTime(date: published) { "Released \($0) ago" }.font(.house.meta).foregroundStyle(Theme.textTertiary)
            } else if installed == nil {
                Text("No release yet: watch the repository for the first one.").font(.house.meta).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, Space.xxs)
    }

    @ViewBuilder private func installedChip(_ installed: InstalledCopy, _ standing: InstalledStanding) -> some View {
        let version = installed.version.map { " \($0)" } ?? ""
        if installed.version == nil, let source = installed.source {
            Chip(text: "Built from source", color: Theme.unknown, style: .outline)
                .help("\(source): not a release, so Agencil makes no claim about updates.")
        } else if installed.version == nil {
            Chip(text: "Installed, version unknown", color: Theme.unknown, style: .outline)
                .help("Its Info.plist names no version Agencil could read.")
        } else {
            versionedChip(version, standing)
        }
    }

    @ViewBuilder private func versionedChip(_ version: String, _ standing: InstalledStanding) -> some View {
        switch standing {
        case .current: Chip(text: "Installed\(version), up to date", symbol: "checkmark", color: Theme.ok)
        case let .behind(latest): Chip(text: "Installed\(version), \(latest) is out", symbol: "arrow.down.circle", color: Theme.warn)
        case .ahead, .unknown, .notInstalled: Chip(text: "Installed\(version)", color: Theme.unknown)
        }
    }
}

/// The app's icon (fetched from the registry or bundled), or a glyph in its hue when there is none.
private struct MoreAppIcon: View {
    let app: RegistryApp
    let image: NSImage?

    var body: some View {
        if let image {
            AppIconTile(image: image, fullBleed: app.iconShape == .fullBleed, glow: app.hue, size: Size.appIcon)
        } else {
            GlyphDisc(symbol: app.kind == .menuBar ? "menubar.rectangle" : "terminal", color: app.hue, size: Size.appIcon)
        }
    }
}
