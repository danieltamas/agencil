import AgencilCore
import AppKit
import SwiftUI

/// Settings > About: who made Agencil and why, its repo, and which build this is.
struct AboutPane: View {
    let store: SettingsStore
    private var update: UpdateStore { store.update }
    private static let repo = URL(string: "https://github.com/danieltamas/agencil")!
    private static let site = URL(string: "https://danieltamas.com")!
    private static let owner = URL(string: "https://github.com/danieltamas")!

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            Bezel {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(alignment: .center, spacing: Space.xl) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: Size.aboutIcon, height: Size.aboutIcon)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Agencil").font(.house.header).foregroundStyle(Theme.textPrimary)
                            Text(update.versionLine).font(.house.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            Text(standingText).font(.house.meta).foregroundStyle(standingColor).paragraph()
                        }
                        Spacer()
                    }
                    if let note = updateNote { Text(note).font(.house.meta).foregroundStyle(Theme.warn).paragraph() }
                    HStack(spacing: Space.m) {
                        if let version = update.updateVersion {
                            let updating = update.state.isUpdating
                            AsyncPillButton(title: updating ? "Updating..." : "Update to \(version)", symbol: "arrow.down.circle",
                                            disabled: updating, id: "update:install", action: update.installAction())
                        }
                        AsyncPillButton(title: "Check again", symbol: "arrow.clockwise", prominent: false,
                                        disabled: update.check == .loading, id: "update:check", action: update.checkAction())
                    }
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCard(title: "Why it exists") {
                Text("""
                    One coding agent's answer is a guess; several that argue are a review. Agencil convenes councils of \
                    coding agents: each seat, a harness plus a model, answers the same question on its own, they argue, and \
                    the verdict is recorded. Every answer and every later outcome is kept on this Mac, so you can see \
                    which seat is right on which kind of change. Nothing leaves it unless you turn it on.
                    """)
                    .font(.house.body).foregroundStyle(Theme.textSecondary).paragraph()
            }
            SettingsCard(title: "Made by Daniel Tamas", detail: "Open source under the MIT license.") {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        link("Repository", Self.repo)
                        link("Report an issue", Self.repo.appendingPathComponent("issues"))
                    }
                    HStack(spacing: Space.m) {
                        link("danieltamas.com", Self.site)
                        link("Daniel on GitHub", Self.owner)
                    }
                }
            }
        }
    }

    private var standingText: String {
        if update.check == .loading { return "Checking for updates..." }
        if case let .failed(reason) = update.check { return reason }
        guard let latest = update.latest else { return "No release has been published yet." }
        switch update.standing {
        case .behind: return "Agencil \(latest.version) is available."
        case .latest: return "This is the latest release."
        case .ahead: return "Newer than the latest release (\(latest.version))."
        case .unknown: return "Could not compare this build with \(latest.version)."
        }
    }

    private var standingColor: some ShapeStyle {
        if case .failed = update.check { return Theme.warn }
        return update.standing == .behind ? Theme.accent : Theme.textTertiary
    }

    /// Why Update is not offered, or why the last one did not finish.
    private var updateNote: String? {
        if case let .failed(message) = update.state { return "The update did not start: \(message)" }
        if update.newerRelease, update.updateVersion == nil {
            return "This copy is not in Applications, so it cannot update itself. Install the new version from the release page."
        }
        return nil
    }

    private func link(_ title: String, _ url: URL) -> some View {
        PillButton(title: title, symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(url) }
    }
}

private extension UpdateState {
    var isUpdating: Bool {
        if case .updating = self { return true }
        return false
    }
}
