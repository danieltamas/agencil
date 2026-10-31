import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U6cStressAcceptanceTests {
    @Test func simultaneousAdmissionsAtomicallyReserveOnlyOneAcrossFreshBudgets() throws {
        let server = try U6cHTTP(); server.usage = false; defer { server.stop() }
        let rig = try U6cRig()
        for iteration in 0..<6 {
            // Exact prompt size is learned from a budget-free exchange, not guessed.
            try rig.configure([server.seat()])
            let d = try rig.base.data(rig.base.ask())
            let reservation = try #require(d["reserved"] as? [String: Any])
            let tokens = Int(try u6cNumber(reservation, "tokens"))
            try rig.configure([server.seat()], budgets: [u6cBudget("race-\(iteration)", tokens: tokens)])
            let results = U6cResults(), gate = DispatchSemaphore(value: 0), group = DispatchGroup()
            for _ in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }; gate.wait()
                    results.append { try rig.base.ask() }
                }
            }
            gate.signal(); gate.signal()
            #expect(group.wait(timeout: .now() + 12) == .success)
            #expect(results.errors.isEmpty)
            #expect(results.replies.filter { $0["ok"] as? Bool == true }.count == 1)
            #expect(results.replies.filter { $0["error"] as? String == "refused: budget" && $0["exit"] as? Int == 3 }.count == 1)
            try u6cWithinLimits(rig.budgets())
        }
    }

    @Test func thousandSeededRandomAsksNeverExceedOverlappingHardBudgetsAndChargeUnreportedInFull() throws {
        let server = try U6cHTTP(); defer { server.stop() }
        let rig = try U6cRig()
        var seed: UInt64 = 0x6c2026
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        // Vary caps per seat; all request choices and prompt lengths are seed-derived.
        var seats: [[String: Any]] = [], routes: [[String: Any]] = []
        for i in 0..<12 {
            let name = "seat-\(i)"
            let model = i % 4 == 0 ? "fail" : (i % 3 == 0 ? "unreported" : "reported")
            let cap = Int((next() >> 33) % 512) + 16 + (i % 4 == 0 ? 1024 : 0)
            seats.append(server.seat(name, cap: cap, model: model))
            routes.append(u6aRoute(name, fallbacks: i % 4 == 0 ? ["seat-1"] : []))
        }
        var budgets = [u6cBudget("root", scope: "root", key: "owner", dollars: 0.1, tokens: 70000),
                       u6cBudget("vendor", scope: "vendor", key: "ollama", dollars: 0.09, tokens: 65000)]
        for i in 0..<12 {
            budgets.append(u6cBudget("route-\(i)", key: "seat-\(i)", dollars: 0.02,
                                     tokens: i % 4 == 0 ? 3000 : 10000))
        }
        try rig.configure(seats, budgets: budgets, limits: ["seats_at_once": 8, "process_cap": 16], routes: routes)
        #expect(try rig.budgets().count == budgets.count)
        let jobs = (0..<1000).map { _ in (Int((next() >> 33) % 12), Int((next() >> 33) % 600) + 1) }
        #expect(Set(jobs.map { $0.0 }).count == seats.count)
        let results = U6cResults(), sampleErrors = U6cResults(), group = DispatchGroup()
        let start = Date()
        for worker in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for index in stride(from: worker, to: jobs.count, by: 8) {
                    let job = jobs[index]
                    results.append { try rig.base.ask("seat-\(job.0)", question: String(repeating: "x", count: job.1)) }
                }
            }
        }
        var samples = 0
        while group.wait(timeout: .now() + 0.02) == .timedOut {
            sampleErrors.append { try u6cWithinLimits(rig.budgets()); return [:] }
            samples += 1
            if Date().timeIntervalSince(start) > 60 { Issue.record("1000 asks exceeded 60 seconds"); break }
        }
        #expect(group.wait(timeout: .now() + 12) == .success)
        #expect(samples > 0); #expect(sampleErrors.errors.isEmpty); #expect(results.errors.isEmpty)
        #expect(results.replies.count == 1000)
        var unreported = 0, provider = 0, refused = 0
        for reply in results.replies {
            if reply["error"] as? String == "refused: budget" { refused += 1; continue }
            guard let d = reply["data"] as? [String: Any], let cost = d["cost"] as? [String: Any] else { continue }
            let r = try #require(d["reserved"] as? [String: Any])
            if cost["basis"] as? String == "reserved" {
                unreported += 1
                #expect(try u6cNumber(cost, "tokens") == u6cNumber(r, "tokens"))
                #expect(try u6cNumber(cost, "dollars") == u6cNumber(r, "dollars"))
            } else { provider += 1; #expect(cost["basis"] as? String == "provider") }
        }
        #expect(unreported > 0); #expect(provider > 0); #expect(refused > 0)
        let final = try rig.budgets(); try u6cWithinLimits(final)
        for b in final {
            #expect(try u6cNumber(b, "reserved_tokens") == 0)
            #expect(try u6cNumber(b, "reserved_dollars") == 0)
        }
        #expect(server.requests().contains { $0["model"] as? String == "fail" })
        #expect(results.replies.contains { ($0["data"] as? [String: Any])?["substituted"] is String })
        #expect(Date().timeIntervalSince(start) < 60)
    }
}
