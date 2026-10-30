import AppKit
import SwiftUI

/// Where the chosen look is kept. The kit knows only these two closures; the store wires them to `config.json`
/// key `look`, the single place the look lives.
struct LookPersistence: Sendable {
    var load: @Sendable () -> String?
    var save: @Sendable (String) throws -> Void

    static let none = LookPersistence(load: { nil }, save: { _ in })
}

/// The look this Mac chose. Every view that reads a `Theme` token reads it through here, so a new choice
/// redraws them all.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance(persistence: .none)

    /// Set directly only for drawing that must not touch the saved choice (screenshots).
    var look: Look {
        didSet { applyToApp() }
    }

    private var persistence: LookPersistence

    init(persistence: LookPersistence) {
        self.persistence = persistence
        look = persistence.load().flatMap(Look.init) ?? .agencil
        applyToApp()
    }

    /// Called once at launch by the store, with the config-backed persistence.
    func attach(_ persistence: LookPersistence) {
        self.persistence = persistence
        look = persistence.load().flatMap(Look.init) ?? .agencil
    }

    /// AppKit draws a text field's placeholder and its other controls from the window's appearance, which the
    /// menu bar panel does not take from SwiftUI's colour scheme.
    private func applyToApp() {
        NSApplication.shared.appearance = NSAppearance(named: look.palette.scheme == .light ? .aqua : .darkAqua)
    }

    /// A failed write leaves the look unchanged and is thrown to the caller.
    func choose(_ look: Look) throws {
        try persistence.save(look.rawValue)
        self.look = look
    }
}
