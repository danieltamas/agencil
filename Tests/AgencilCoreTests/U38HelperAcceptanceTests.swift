@testable import AgencilCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U38HelperAcceptanceTests {
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func helperRecordSurvivesBrokerSIGKILLAndRestartUntilRemoved() throws {
        let rig = try U6dRig()
        let file = rig.home.url.appendingPathComponent("egress-codex.json")
        defer { try? FileManager.default.removeItem(at: file) }
        try rig.repository()
        _ = try rig.base.answered(rig.ask())
        let record = try JSONDecoder().decode(EgressHelper.Record.self, from: Data(contentsOf: file))
        let hosts: Set<String> = ["api.openai.com", "auth.openai.com", "chatgpt.com"]
        #expect(EgressHelper.recordFile(home: rig.home.url, harness: "codex") == file)
        #expect(record.hosts == hosts.sorted())
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try #require(record.pid > 1)
        try #require(brokerAlive(record.pid))
        #expect(record.startTime == (try U38HelperObservation.startTime(record.pid)))
        #expect(EgressHelper.running(home: rig.home.url, harness: "codex", hosts: hosts) == record)
        try U38HelperObservation.profiles(rig, port: record.port, count: 1)
        let broker = try #require(rig.base.broker)
        #expect(record.pid != broker.process.processIdentifier)
        broker.kill(SIGKILL)
        _ = try broker.finish(5)
        #expect(broker.process.terminationReason == .uncaughtSignal)
        #expect(broker.process.terminationStatus == SIGKILL)
        let observationTime = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < observationTime { usleep(10_000) }
        #expect(brokerAlive(record.pid))
        #expect(try U38HelperObservation.connectionError(record.port) == 0)

        // Preserve the fixture environment when starting another broker on the same home.
        let environment = try #require(broker.process.environment)
        rig.base.broker = try rig.home.serve(environment)
        _ = try rig.base.answered(rig.ask())
        try U38HelperObservation.profiles(rig, port: record.port, count: 2)
        let reused = try JSONDecoder().decode(EgressHelper.Record.self, from: Data(contentsOf: file))
        #expect(reused == record)
        #expect(try U38HelperObservation.connectionError(record.port) == 0)
        try #require(Darwin.kill(record.pid, SIGTERM) == 0)
        let termObservationTime = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < termObservationTime { usleep(10_000) }
        #expect(brokerAlive(record.pid))
        #expect(try U38HelperObservation.connectionError(record.port) == 0)

        try FileManager.default.removeItem(at: file)
        try brokerPoll(6) { !brokerAlive(record.pid) }
        #expect(try U38HelperObservation.connectionError(record.port) == ECONNREFUSED)
    }

    @Test func runningRejectsStaleDeadMismatchedAndMalformedRecords() throws {
        let home = try BrokerHome()
        let file = home.url.appendingPathComponent("egress-codex.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let hosts: Set<String> = ["api.openai.com", "auth.openai.com", "chatgpt.com"]
        let pid = getpid(), startTime = try U38HelperObservation.startTime(getpid())
        func writeRecord(pid: Int32, startTime: Double, hosts: [String]) throws {
            try JSONSerialization.data(withJSONObject: ["pid": pid, "startTime": startTime,
                "port": 4321, "hosts": hosts]).write(to: file, options: .atomic)
        }
        try writeRecord(pid: pid, startTime: startTime, hosts: hosts.sorted())
        let valid = try #require(EgressHelper.running(home: home.url, harness: "codex", hosts: hosts))
        #expect(valid.pid == pid)
        #expect(valid.startTime == startTime)
        #expect(valid.port == 4321)
        #expect(valid.hosts == hosts.sorted())
        try writeRecord(pid: pid, startTime: startTime + 1, hosts: hosts.sorted())
        #expect(EgressHelper.running(home: home.url, harness: "codex", hosts: hosts) == nil)

        let exited = try BrokerProcess([], home: home.url, executable: URL(fileURLWithPath: "/usr/bin/true"))
        _ = try exited.finish(5)
        let deadPID = exited.process.processIdentifier
        try #require(!brokerAlive(deadPID))
        try writeRecord(pid: deadPID, startTime: startTime, hosts: hosts.sorted())
        #expect(EgressHelper.running(home: home.url, harness: "codex", hosts: hosts) == nil)
        try writeRecord(pid: pid, startTime: startTime, hosts: ["localhost"])
        #expect(EgressHelper.running(home: home.url, harness: "codex", hosts: hosts) == nil)
        try Data("{not JSON".utf8).write(to: file, options: .atomic)
        #expect(EgressHelper.running(home: home.url, harness: "codex", hosts: hosts) == nil)
    }

    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedClaudeLeavesNoEgressRecord() throws {
        let rig = try U6dRig()
        try rig.configure([u6aSeat("primary", "claude")])
        try rig.repository()
        _ = try rig.base.answered(rig.ask())
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.home.url.path)
        #expect(!names.contains { $0.hasPrefix("egress-") && $0.hasSuffix(".json") })
    }
}

private enum U38HelperObservation {
    static func startTime(_ pid: Int32) throws -> Double {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try #require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    static func profiles(_ rig: U6dRig, port: Int, count: Int) throws {
        let files = FileManager.default.enumerator(at: rig.home.url.appendingPathComponent("runs"),
            includingPropertiesForKeys: nil)
        var profiles: [URL] = []
        while let file = files?.nextObject() as? URL {
            if file.lastPathComponent == "confine.sb" { profiles.append(file) }
        }
        #expect(profiles.count == count)
        for file in profiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("(allow network-outbound (remote tcp \"localhost:\(port)\"))"))
            #expect(!text.contains("(allow network*)"))
        }
    }

    static func connectionError(_ port: Int) throws -> Int32 {
        try #require((1...65535).contains(port))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFailure("socket failed") }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BrokerFailure("fcntl failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return 0 }
        let failure = errno
        if failure != EINPROGRESS { return failure }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 1000) > 0 else { throw BrokerFailure("connect deadline exceeded") }
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
            throw BrokerFailure("getsockopt failed")
        }
        return error
    }
}
