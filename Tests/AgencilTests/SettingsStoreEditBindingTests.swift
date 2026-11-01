import AgencilCore
import Foundation
import Testing
@testable import Agencil

/// An Edit press opens the row that was shown or nothing: a file that was reordered, shortened or edited under the
/// list sets `configProblem` and opens no sheet.
@MainActor @Suite(.serialized) struct SettingsStoreEditBindingTests {
    @MainActor private struct Rig {
        let directory: URL
        let config: ConfigStore
        let store: SettingsStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("agencil-edit-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            config = ConfigStore(directory: directory)
            try config.update { $0 = Rig.values(seats: ["a", "b", "c"], councils: ["one", "two"], routes: [Rig.route("owner", "one"), Rig.route("maya", "two")]) }
            store = SettingsStore(directory: directory, environment: ["AGENCIL_HOME": directory.path])
            store.reload()
        }

        static func seat(_ name: String) -> [String: Any] {
            ["name": name, "harness": "codex", "model": "test-model", "role": "answerer", "hardening": [], "cap": ["seconds": 20, "tokens": 37]]
        }
        static func route(_ caller: String, _ target: String) -> [String: Any] {
            ["callers": [caller], "target": target, "hop_limit": 2, "fallbacks": []]
        }
        static func values(seats: [String], councils: [String], routes: [[String: Any]]) -> [String: String] {
            func text(_ object: Any) -> String {
                String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            }
            return ["seats": text(seats.map(seat)), "aliases": "{}", "routes": text(routes), "triggers": "[]",
                    "councils": text(councils.map { ["name": $0, "seats": ["a"]] as [String: Any] })]
        }
        func write(_ change: @escaping (inout [String: String]) -> Void) throws { try config.update(change) }
        func remove(_ directory: Bool = true) { try? FileManager.default.removeItem(at: self.directory) }
    }

    @Test func aSeatRemovedUnderTheListOpensNothing() throws {
        let rig = try Rig(); defer { rig.remove() }
        try rig.write { $0 = Rig.values(seats: ["b", "c"], councils: [], routes: []) }
        rig.store.startEdit(.seat, index: 0)
        #expect(rig.store.editing == nil && rig.store.presenting == nil)
        #expect(rig.store.configProblem != nil)
        #expect(rig.store.seatNames == ["b", "c"])
    }

    @Test func aReorderedSeatListOpensTheSeatThatWasShownOrNothing() throws {
        let rig = try Rig(); defer { rig.remove() }
        try rig.write { $0 = Rig.values(seats: ["c", "b", "a"], councils: ["one", "two"], routes: []) }
        rig.store.startEdit(.seat, index: 0)   // the row shown at 0 was "a"
        if case .seat(let was)? = rig.store.editing { #expect(was.name == "a" && rig.store.seatForm.name == "a") }
        else { #expect(rig.store.editing == nil && rig.store.presenting == nil && rig.store.configProblem != nil) }
        #expect(rig.store.seatForm.name != "c")
    }

    @Test func aCouncilRemovedOrRenamedUnderTheListOpensNothing() throws {
        let rig = try Rig(); defer { rig.remove() }
        try rig.write { $0 = Rig.values(seats: ["a", "b", "c"], councils: ["two"], routes: []) }
        rig.store.startEdit(.council, index: 0)
        #expect(rig.store.editing == nil && rig.store.presenting == nil && rig.store.configProblem != nil)
    }

    @Test func aRouteChangedOrReorderedUnderTheListOpensNothing() throws {
        let rig = try Rig(); defer { rig.remove() }
        try rig.write { $0 = Rig.values(seats: ["a", "b", "c"], councils: ["one", "two"], routes: [Rig.route("maya", "two"), Rig.route("owner", "one")]) }
        rig.store.startEdit(.route, index: 0)
        #expect(rig.store.editing == nil && rig.store.presenting == nil && rig.store.configProblem != nil)
    }

    @Test func aRouteWithAChangedFallbackOpensNothing() throws {
        let rig = try Rig(); defer { rig.remove() }
        var changed = Rig.route("owner", "one"); changed["fallbacks"] = ["b"]
        try rig.write { $0 = Rig.values(seats: ["a", "b", "c"], councils: ["one", "two"], routes: [changed, Rig.route("maya", "two")]) }
        rig.store.startEdit(.route, index: 0)
        #expect(rig.store.editing == nil && rig.store.presenting == nil && rig.store.configProblem != nil)
    }

    @Test func anUnchangedFileOpensTheShownRows() throws {
        let rig = try Rig(); defer { rig.remove() }
        rig.store.startEdit(.seat, index: 1)
        if case .seat(let was)? = rig.store.editing { #expect(was.name == "b") } else { Issue.record("seat sheet did not open") }
        #expect(rig.store.presenting == .seat && rig.store.configProblem == nil)
        rig.store.startEdit(.council, index: 1)
        if case .council(let was)? = rig.store.editing { #expect(was.name == "two") } else { Issue.record("council sheet did not open") }
        rig.store.startEdit(.route, index: 1)
        if case .route(let index, let was)? = rig.store.editing { #expect(index == 1 && was.callers == ["maya"] && was.target == "two") }
        else { Issue.record("route sheet did not open") }
    }
}
