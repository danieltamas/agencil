import Darwin
import Foundation

/// What the kernel says about processes, read through sysctl so identity never rests on a pid alone.
enum ProcessTable {
    struct Entry {
        let pid: Int32
        let pgid: Int32
        let startTime: Double
        var parent: Int32 = 0
    }

    enum Lookup { case found(Entry), gone, unreadable }

    /// One process by pid; `gone` when the kernel says no such process, `unreadable` when it could not be asked.
    static func lookup(_ pid: Int32) -> Lookup {
        guard let found = entries([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]) else { return .unreadable }
        return found.first { $0.pid == pid }.map(Lookup.found) ?? .gone
    }

    /// Every process in group `pgid`, zombies included: a zombie leader still holds the group. Nil when the
    /// kernel could not be asked, which is never the same as an empty group.
    static func members(ofGroup pgid: Int32) -> [Entry]? {
        entries([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid])?.filter { $0.pgid == pgid }
    }

    /// The start time of `pid`, or nil when no such process exists.
    static func startTime(of pid: Int32) -> Double? {
        entries([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid])?.first { $0.pid == pid }?.startTime
    }

    /// The environment `pid` was started with (same-user processes only), or nil when it cannot be read.
    static func environment(of pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: false)
        strings = Array(strings.drop { _ in false })
        // exec path, then padding NULs (empty pieces), then argc arguments, then the environment.
        var index = 1
        while index < strings.count, strings[index].isEmpty { index += 1 }
        index += argc
        var environment: [String: String] = [:]
        while index < strings.count, !strings[index].isEmpty {
            let entry = String(decoding: strings[index], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") { environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...]) }
            index += 1
        }
        // Protected system binaries expose no environment at all; that is "unknown", not "empty".
        return environment.isEmpty ? nil : environment
    }

    /// Launchers whose command line carries `run-seat <nonce>`: their identity never reached the ledger.
    /// Nil when the process list could not be read.
    static func launchers(nonce: String) -> [Entry]? {
        guard let listing = try? psListing() else { return nil }
        var unreadable = false
        let found = listing.split(separator: "\n").compactMap { line -> Entry? in
            guard line.contains("run-seat \(nonce)") else { return nil }
            let trimmed = line.drop { $0 == " " }
            guard let pid = trimmed.split(separator: " ").first.flatMap({ Int32($0) }) else { return nil }
            // Seen by ps but unreadable here: not proof that it is gone.
            unreadable = unreadable || startTime(of: pid) == nil
            return Entry(pid: pid, pgid: getpgid(pid), startTime: startTime(of: pid) ?? 0)
        }
        return unreadable ? nil : found
    }

    private static func psListing() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func entries(_ name: [Int32]) -> [Entry]? {
        var mib = name
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        guard size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = buffer.count * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.prefix(size / stride).map { info in
            let start = info.kp_proc.p_un.__p_starttime
            return Entry(pid: info.kp_proc.p_pid, pgid: info.kp_eproc.e_pgid,
                         startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000, parent: info.kp_eproc.e_ppid)
        }
    }
}

extension ProcessTable {
    /// The working directory the kernel reports for `pid`; nil when it cannot be read.
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
