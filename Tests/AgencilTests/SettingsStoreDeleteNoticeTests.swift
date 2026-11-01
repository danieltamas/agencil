import AgencilCore
import Foundation
import Testing
@testable import Agencil

/// The first Delete press of a seat names the councils the delete also takes the seat out of.
@MainActor @Suite(.serialized) struct SettingsStoreDeleteNoticeTests {
    private func store(_ home: URL) throws -> SettingsStore {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func text(_ object: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let seats = ["a", "b", "c", "d"].map { name -> [String: Any] in
            ["name": name, "harness": "codex", "model": "test-model", "role": "answerer", "hardening": [], "cap": ["seconds": 20, "tokens": 37]]
        }
        let councils: [[String: Any]] = [["name": "one", "seats": ["a", "b"]], ["name": "two", "seats": ["c"], "spare": ["a"]],
                                         ["name": "three", "seats": ["c"]]]
        try ConfigStore(directory: home).update {
            $0 = ["seats": text(seats), "aliases": "{}", "routes": "[]", "triggers": "[]", "councils": text(councils)]
        }
        let store = SettingsStore(directory: home, environment: ["AGENCIL_HOME": home.path])
        store.reload()
        return store
    }

    private func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("agencil-notice-" + UUID().uuidString) }

    @Test func aSeatInTwoCouncilsNamesBoth() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try store(home)
        store.startEdit(.seat, index: 0)
        store.askDelete(.seat)
        #expect(store.confirmingDelete)
        #expect(store.deleteNotice.contains("one") && store.deleteNotice.contains("two"))
        #expect(!store.deleteNotice.contains("three"))
    }

    @Test func aSeatInOneCouncilNamesThatCouncil() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try store(home)
        store.startEdit(.seat, index: 1)   // b: council one only
        store.askDelete(.seat)
        #expect(store.confirmingDelete)
        #expect(store.deleteNotice.contains("one") && !store.deleteNotice.contains("two"))
    }

    @Test func aSeatInNoCouncilHasNoNoticeButStillAsks() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try store(home)
        store.startEdit(.seat, index: 3)   // d: in no council
        store.askDelete(.seat)
        #expect(store.confirmingDelete)
        #expect(store.deleteNotice.isEmpty)
    }

    @Test func theNoticeBelongsToTheSeatBeingAskedAbout() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try store(home)
        store.startEdit(.seat, index: 0)
        store.askDelete(.seat)
        #expect(!store.deleteNotice.isEmpty)
        store.startEdit(.seat, index: 3)
        store.askDelete(.seat)
        #expect(store.deleteNotice.isEmpty)
    }

    @Test func aCouncilDeleteCarriesNoSeatNotice() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try store(home)
        store.startEdit(.council, index: 0)
        store.askDelete(.council)
        #expect(store.confirmingDelete && store.deleteNotice.isEmpty)
    }
}
