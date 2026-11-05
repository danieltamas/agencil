import Foundation

/// The `agencil` verbs. Everything but version, serve, mcp, install-mcp and run-seat is a thin client of the broker.
public struct CommandLineTool: Sendable {
    struct Usage: Error { let message: String }

    private struct Parsed {
        var positionals: [String] = []
        var options: [String: [String]] = [:]
        var flags: Set<String> = []
        func value(_ name: String) -> String? { options[name]?.last }
    }

    private struct Spec {
        let positionals: ClosedRange<Int>
        var valued: Set<String> = []
        var switches: Set<String> = ["--json"]
    }

    private static let specs: [String: Spec] = [
        "version": Spec(positionals: 0...0),
        "ask": Spec(positionals: 2...2, valued: ["--file", "--thread", "--wait", "--as", "--repo"]),
        "result": Spec(positionals: 1...1, valued: ["--wait"], switches: ["--json", "--full"]),
        "wake": Spec(positionals: 1...1, valued: ["--brief", "--file", "--repo", "--diff", "--wait", "--author-vendor", "--seats", "--cap"],
                     switches: ["--json", "--synthesize"]),
        "status": Spec(positionals: 1...1), "stop": Spec(positionals: 1...1),
        "budgets": Spec(positionals: 0...0),
        "seats": Spec(positionals: 0...2, valued: ["--preset"]), "councils": Spec(positionals: 0...0), "triggers": Spec(positionals: 0...0),
        "panel": Spec(positionals: 0...0), "detail": Spec(positionals: 1...1), "routes": Spec(positionals: 0...0),
        "harnesses": Spec(positionals: 0...0, switches: ["--json", "--probe"]), "models": Spec(positionals: 0...0),
        "preflight": Spec(positionals: 0...0, valued: ["--seats"], switches: ["--json", "--probe"]),
        "data": Spec(positionals: 0...0), "prune": Spec(positionals: 0...0),
        "findings": Spec(positionals: 0...0, switches: ["--json", "--open"]),
        "dispose": Spec(positionals: 2...2), "leaderboard": Spec(positionals: 1...1),
        "proposals": Spec(positionals: 0...0, switches: ["--json", "--all"]), "learn": Spec(positionals: 1...2, valued: ["--wait"]),
        "adjudicate": Spec(positionals: 1...1, valued: ["--wait"]),
        "mcp": Spec(positionals: 0...0, valued: ["--caller"]),
        "install-mcp": Spec(positionals: 1...1, valued: ["--caller"], switches: ["--json", "--dry-run", "--uninstall"]),
        "access": Spec(positionals: 0...0),
        "install-instructions": Spec(positionals: 1...1, switches: ["--json", "--dry-run", "--uninstall"]),
        "serve": Spec(positionals: 0...0), "run-seat": Spec(positionals: 1...1),
    ]

    let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    /// Runs one invocation and returns the process exit code (docs/AGENT-API.md).
    public func run(_ arguments: [String]) -> Int32 {
        do {
            guard let verb = arguments.first else { throw Usage(message: "usage: agencil <verb> [options] (see docs/AGENT-API.md)") }
            guard let spec = Self.specs[verb] else { throw Usage(message: "unknown verb \(verb)") }
            let parsed = try Self.parse(Array(arguments.dropFirst()), spec)
            return try dispatch(verb, parsed)
        } catch let usage as Usage {
            return Self.report(usage.message, 64)
        } catch let failure as BrokerClient.Failure {
            return Self.report(failure.message, failure.exit)
        } catch let failure as Broker.Failure {
            return Self.report(failure.message, 1)
        } catch {
            return Self.report(error.localizedDescription, 70)
        }
    }

    private func dispatch(_ verb: String, _ parsed: Parsed) throws -> Int32 {
        let json = parsed.flags.contains("--json")
        switch verb {
        case "version":
            print("agencil \(AgencilVersion.current())")
            return 0
        case "serve":
            try Broker(home: try home(), environment: environment).serve()
        case "run-seat":
            return Launcher.run(nonce: parsed.positionals[0], home: try home())
        case "mcp":
            return MCPServer(home: try home(), caller: parsed.value("--caller") ?? "unknown").run()
        case "install-mcp":
            return try McpInstaller(home: try home(), environment: environment).run(
                harness: parsed.positionals[0], caller: parsed.value("--caller"),
                dryRun: parsed.flags.contains("--dry-run"), uninstall: parsed.flags.contains("--uninstall"))
        case "access":
            return try access(json: json)
        case "seats" where !parsed.positionals.isEmpty:
            return try presets(parsed)
        case "install-instructions":
            return try installInstructions(parsed.positionals[0], dryRun: parsed.flags.contains("--dry-run"),
                                           uninstall: parsed.flags.contains("--uninstall"), json: json)
        default:
            return try ask(verb, parsed, json: json)
        }
    }

    private func ask(_ verb: String, _ parsed: Parsed, json: Bool) throws -> Int32 {
        var request: [String: Any] = ["op": verb, "caller": "owner"]
        // A seat's capability, when this process was started by one; the broker judges it against the process tree.
        if let capability = environment["AGENCIL_CAP"], !capability.isEmpty { request["cap"] = capability }
        if verb == "ask" || verb == "wake", let project = ProjectLabel.label(cwd: FileManager.default.currentDirectoryPath) { request["project"] = project }
        if let wait = parsed.value("--wait") {
            guard let seconds = Int(wait), (0...3600).contains(seconds) else { throw Usage(message: "--wait takes whole seconds") }
            request["wait_seconds"] = seconds
        }
        for (flag, key) in [("--thread", "thread"), ("--as", "as"), ("--repo", "repo")] {
            if let value = parsed.value(flag) { request[key] = value }
        }
        if let files = parsed.options["--file"] {
            // The broker runs elsewhere, so a relative path would resolve against the wrong directory.
            request["files"] = files.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        for flag in ["--full", "--probe", "--open", "--all"] where parsed.flags.contains(flag) { request[String(flag.dropFirst(2))] = true }
        switch verb {
        case "ask":
            request["target"] = parsed.positionals[0]; request["question"] = parsed.positionals[1]
        case "wake", "preflight":
            if verb == "wake" {
                request["council"] = parsed.positionals[0]
                request.merge(try Self.brief(parsed)) { _, new in new }
                if parsed.flags.contains("--synthesize") { request["synthesize"] = true }
            }
            if let seats = parsed.value("--seats") {
                let names = seats.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard names.allSatisfy({ !$0.isEmpty }) else { throw Usage(message: "--seats takes a comma-separated list of seat names") }
                request["seats"] = names
            }
            if let cap = parsed.value("--cap") {
                guard let seconds = Int(cap) else { throw Usage(message: "--cap takes a whole number of seconds") }
                request["cap_seconds"] = seconds
            }
        case "result", "status", "stop", "adjudicate", "detail":
            request["id"] = parsed.positionals[0]
        case "dispose":
            guard ["confirm", "dismiss", "will-fix"].contains(parsed.positionals[1]) else {
                throw Usage(message: "dispose takes confirm, dismiss or will-fix")
            }
            request["id"] = parsed.positionals[0]; request["disposition"] = parsed.positionals[1]
        case "learn":
            let action = parsed.positionals[0]
            guard ["approve", "reject", "review", "rollback"].contains(action),
                  parsed.positionals.count == (action == "rollback" ? 1 : 2) else {
                throw Usage(message: "learn takes approve <id>, reject <id>, review <id> or rollback")
            }
            request["action"] = action
            if parsed.positionals.count == 2 { request["id"] = parsed.positionals[1] }
        case "leaderboard":
            guard ["preview", "publish"].contains(parsed.positionals[0]) else { throw Usage(message: "leaderboard takes preview or publish") }
            request["action"] = parsed.positionals[0]
        default: break
        }
        let reply = try BrokerClient(home: try home()).send(request)
        guard reply["ok"] as? Bool == true else {
            return Self.report(reply["error"] as? String ?? "request failed", Int32(reply["exit"] as? Int ?? 70))
        }
        let data = reply["data"] ?? reply.filter { $0.key != "ok" }
        print(json ? Envelope.text(Envelope.make(data: data, note: reply["data_note"] as? String ?? Broker.note))
                   : Self.human(data))
        // Preflight exits by the panel's standing: 0 when every listed seat is ok, else 4.
        if verb == "preflight", let rows = (data as? [String: Any])?["seats"] as? [[String: Any]] {
            return rows.allSatisfy { $0["reason"] as? String == "ok" } ? 0 : 4
        }
        // A sitting that reached a verdict exits by it: PASS 0, BLOCK 1, INCOMPLETE 2; a consult's AGREED, SPLIT and ANSWERED 0.
        switch (data as? [String: Any])?["verdict"] as? String {
        case "BLOCK": return 1
        case "INCOMPLETE": return 2
        default: break
        }
        switch (data as? [String: Any])?["state"] as? String {
        case "pending": return 2
        case "failed": return 4
        default: return 0
        }
    }

    /// A brief names a change kind and a question, and for code a diff range; anything less is a usage error.
    private static func brief(_ parsed: Parsed) throws -> [String: Any] {
        guard let path = parsed.value("--brief") else { throw Usage(message: "wake needs --brief <file>") }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw Usage(message: "cannot read the brief \(path)") }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let kind = fields["change_kind"], !kind.isEmpty else { throw Usage(message: "the brief must name a change_kind") }
        guard let question = fields["question"], !question.isEmpty else { throw Usage(message: "the brief must carry a question") }
        let diff = parsed.value("--diff") ?? fields["diff"]
        if kind == "code" && (diff ?? "").isEmpty { throw Usage(message: "a code brief needs a diff range (--diff)") }
        var brief: [String: Any] = ["change_kind": kind, "question": question, "diff": diff ?? NSNull(),
                                    "repo": parsed.value("--repo") ?? fields["repo"] ?? NSNull(),
                                    "uncommitted": fields["uncommitted"]?.lowercased() == "true"]
        if let author = parsed.value("--author-vendor") ?? fields["author_vendor"] { brief["author_vendor"] = author }
        return brief
    }

    private static func parse(_ arguments: [String], _ spec: Spec) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if spec.valued.contains(argument) {
                guard index + 1 < arguments.count else { throw Usage(message: "\(argument) needs a value") }
                parsed.options[argument, default: []].append(arguments[index + 1])
                index += 2
            } else if spec.switches.contains(argument) {
                parsed.flags.insert(argument); index += 1
            } else if argument.hasPrefix("--") {
                throw Usage(message: "unknown option \(argument)")
            } else { parsed.positionals.append(argument); index += 1 }
        }
        guard spec.positionals.contains(parsed.positionals.count) else {
            throw Usage(message: "wrong number of arguments (expected \(spec.positionals.lowerBound)...\(spec.positionals.upperBound))")
        }
        return parsed
    }

    func home() throws -> AgencilHome {
        try AgencilHome(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil"),
                        environment: environment)
    }

    /// `seats presets` lists the catalog; `seats add --preset <name>` writes one through the validated config path.
    private func presets(_ parsed: Parsed) throws -> Int32 {
        switch parsed.positionals {
        case ["presets"]:
            print(SeatPreset.all.map(\.line).joined(separator: "\n"))
            return 0
        case ["add"]:
            guard let name = parsed.value("--preset") else { throw Usage(message: "seats add takes --preset <name>") }
            guard let preset = SeatPreset.named(name) else { throw Usage(message: "unknown preset \(name)") }
            do { try ConfigEditor(directory: try home().directory).add(preset.draft) } catch let refused as SheetProblems {
                return Self.report(refused.fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "), 4)
            }
            print("added \(preset.name)")
            return 0
        default:
            throw Usage(message: "seats takes no arguments, presets, or add --preset <name>")
        }
    }

    private static func human(_ data: Any) -> String {
        if let object = data as? [String: Any], let answer = object["answer"] as? String {
            return [object["substituted"] as? String, answer].compactMap { $0 }.joined(separator: "\n\n")
        }
        if let object = data as? [String: Any], let rows = object["seats"] as? [[String: Any]], rows.first?["reason"] != nil {
            return rows.map { row in
                ["name", "reason", "detail"].map { row[$0] as? String ?? "" }.filter { !$0.isEmpty }.joined(separator: "  ")
            }.joined(separator: "\n")
        }
        if let object = data as? [String: Any], let rows = object["harnesses"] as? [[String: Any]], !rows.isEmpty {
            return rows.map { row in
                let signedIn = ["yes": "signed in", "no": "signed out"][row["signed_in"] as? String ?? ""] ?? "unknown"
                return "\(row["kind"] as? String ?? "?")  \(row["found"] as? Bool == true ? "found" : "missing")  "
                    + "\(row["version"] as? String ?? "-")  \(signedIn)"
            }.joined(separator: "\n")
        }
        if let object = data as? [String: Any], object.count == 1, let list = object.values.first as? [Any], list.isEmpty {
            return "none configured"
        }
        return Envelope.text(["data": data])
    }

    static func report(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("agencil: \(message)\n".utf8))
        return code
    }
}
