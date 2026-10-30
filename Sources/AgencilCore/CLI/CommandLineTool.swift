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
        "ask": Spec(positionals: 2...2, valued: ["--file", "--thread", "--wait", "--as"]),
        "result": Spec(positionals: 1...1, valued: ["--wait"], switches: ["--json", "--full"]),
        "wake": Spec(positionals: 1...1, valued: ["--brief", "--repo", "--diff", "--wait"]),
        "status": Spec(positionals: 1...1), "stop": Spec(positionals: 1...1),
        "seats": Spec(positionals: 0...0), "councils": Spec(positionals: 0...0), "routes": Spec(positionals: 0...0),
        "harnesses": Spec(positionals: 0...0, switches: ["--json", "--probe"]), "models": Spec(positionals: 0...0),
        "findings": Spec(positionals: 0...0, switches: ["--json", "--open"]),
        "dispose": Spec(positionals: 2...2), "leaderboard": Spec(positionals: 1...1),
        "mcp": Spec(positionals: 0...0, valued: ["--caller"]),
        "install-mcp": Spec(positionals: 1...1, valued: ["--caller"], switches: ["--json", "--dry-run", "--uninstall"]),
        "serve": Spec(positionals: 0...0), "run-seat": Spec(positionals: 1...1),
    ]

    private let environment: [String: String]

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
        default:
            return try ask(verb, parsed, json: json)
        }
    }

    private func ask(_ verb: String, _ parsed: Parsed, json: Bool) throws -> Int32 {
        var request: [String: Any] = ["op": verb]
        if let wait = parsed.value("--wait") {
            guard let seconds = Int(wait), (0...3600).contains(seconds) else { throw Usage(message: "--wait takes whole seconds") }
            request["wait_seconds"] = seconds
        }
        for (flag, key) in [("--thread", "thread"), ("--as", "as")] {
            if let value = parsed.value(flag) { request[key] = value }
        }
        if let files = parsed.options["--file"] { request["files"] = files }
        for flag in ["--full", "--probe", "--open"] where parsed.flags.contains(flag) { request[String(flag.dropFirst(2))] = true }
        switch verb {
        case "ask":
            request["target"] = parsed.positionals[0]; request["question"] = parsed.positionals[1]
        case "wake":
            request["council"] = parsed.positionals[0]
            request.merge(try Self.brief(parsed)) { _, new in new }
        case "result", "status", "stop":
            request["id"] = parsed.positionals[0]
        case "dispose":
            guard ["confirm", "dismiss", "will-fix"].contains(parsed.positionals[1]) else {
                throw Usage(message: "dispose takes confirm, dismiss or will-fix")
            }
            request["id"] = parsed.positionals[0]; request["disposition"] = parsed.positionals[1]
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
        return 0
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
        return ["change_kind": kind, "question": question, "diff": diff ?? NSNull(), "repo": parsed.value("--repo") ?? NSNull()]
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

    private func home() throws -> AgencilHome {
        try AgencilHome(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agencil"),
                        environment: environment)
    }

    private static func human(_ data: Any) -> String {
        if let object = data as? [String: Any], object.count == 1, let list = object.values.first as? [Any], list.isEmpty {
            return "none configured"
        }
        return Envelope.text(["data": data])
    }

    private static func report(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("agencil: \(message)\n".utf8))
        return code
    }
}
