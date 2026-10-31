import Foundation

/// `agencil access` and `agencil install-instructions`: file-only verbs, no broker (docs/U17-SPEC.md).
extension CommandLineTool {
    func access(json: Bool) throws -> Int32 {
        let directory = try home().directory
        let values = (try? ConfigStore(directory: directory).read().values) ?? [:]
        let wiring = AgentAccess(home: directory, environment: environment).audit(values: values)
        if json {
            let rows: [[String: Any]] = wiring.map { row in
                ["harness": row.harness, "server": row.mcp.installed, "instructions": row.instruction.rawValue,
                 "caller": row.caller, "routes": row.routes, "drift": row.drift]
            }
            print(Envelope.text(Envelope.make(data: ["access": values["agent_access"] == "on" ? "on" : "off", "harnesses": rows],
                                              note: Broker.note)))
            return 0
        }
        for row in wiring {
            print("\(row.harness)  server \(row.mcp.installed ? "installed" : "absent")  instructions \(row.instruction.rawValue)  routes: \(row.routes.count)")
            for line in row.drift { print("  \(line)") }
        }
        return 0
    }

    func installInstructions(_ harness: String, dryRun: Bool, uninstall: Bool, json: Bool) throws -> Int32 {
        guard ["claude", "codex", "opencode"].contains(harness) else {
            throw Usage(message: "install-instructions supports claude, codex and opencode")
        }
        let instruction = AgentInstruction(environment: environment)
        let path = instruction.path(harness).path
        var result: [String: Any] = ["harness": harness, "path": path]
        if dryRun {
            result["dry_run"] = true
            if !uninstall { result["block"] = AgentInstruction.text }
        } else {
            do { uninstall ? try instruction.remove(harness) : try instruction.install(harness) }
            catch let failure as AccessError { return Self.report(failure.message, 3) }
            result["state"] = instruction.state(harness).rawValue
        }
        if json { print(Envelope.text(Envelope.make(data: result, note: Broker.note))) }
        else if dryRun { print(path + (uninstall ? "\n(would remove the agencil block)" : "\n" + AgentInstruction.text)) }
        else { print("agencil: \(uninstall ? "removed the agencil block from" : "installed the agencil block in") \(path)") }
        return 0
    }
}
