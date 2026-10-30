// A real second address space for ConfigStore's interprocess locking acceptance test.
import Foundation
import Darwin
import AgencilCore

let args = CommandLine.arguments
guard args.count == 3 else { exit(64) }
let directory = URL(fileURLWithPath: args[1]), key = args[2]
do {
    try Data().write(to: directory.appendingPathComponent(key + ".ready"))
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
        guard ContinuousClock.now < deadline else { exit(75) }
        usleep(1_000)
    }
    let store = ConfigStore(directory: directory)
    for index in 0..<100 {
        _ = try store.update { values in
            // Hold the read-modify-write window open to expose a missing flock.
            usleep(1_000)
            values["\(key).\(index)"] = String(index)
        }
    }
} catch {
    FileHandle.standardError.write(Data("Config writer failed: \(error)\n".utf8))
    exit(1)
}
