import Darwin
import Foundation

/// `agencil run-seat <nonce>`: the process a seat's harness is exec'd from. It reports its identity to the
/// broker and waits for `go`; no harness code runs before the ledger holds that identity.
public enum Launcher {
    /// Returns only on failure (the exit code); on success the process image is replaced.
    public static func run(nonce: String, home: AgencilHome) -> Int32 {
        setpgid(0, 0)
        let socketPath = home.socketPath
        guard let descriptor = try? UnixSocket.connect(to: socketPath) else { return fail("the broker is not reachable") }
        let request: [String: Any] = ["op": "register", "nonce": nonce, "pid": Int(getpid()), "pgid": Int(getpgrp())]
        guard UnixSocket.write(descriptor, line: UnixSocket.json(request)) else { return fail("cannot register with the broker") }
        // EOF before `go` (the broker died or refused): the harness never starts.
        guard case .line(let data) = UnixSocket.Reader(descriptor: descriptor).next(),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              reply["go"] as? Bool == true,
              let argv = reply["argv"] as? [String], let program = argv.first,
              let env = reply["env"] as? [String: String] else { return fail("the broker did not release this seat") }
        close(descriptor)
        if let cwd = reply["cwd"] as? String, chdir(cwd) != 0 { return fail("cannot enter \(cwd)") }
        if let output = reply["stdout"] as? String {
            let file = open(output, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
            guard file >= 0, dup2(file, 1) == 1 else { return fail("cannot open the answer file \(output)") }
            close(file)
        }
        guard let executable = resolve(program, path: env["PATH"] ?? "/usr/bin:/bin") else { return fail("\(program) not found") }
        // The broker ignores these while it serves, and an ignored signal stays ignored across exec.
        for number in [SIGTERM, SIGINT, SIGPIPE] { signal(number, SIG_DFL) }
        let argvC = argv.map { strdup($0) } + [nil]
        let envC = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(executable, argvC, envC)
        return fail("cannot exec \(executable): \(String(cString: strerror(errno)))", code: 127)
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("agencil: \(message)\n".utf8))
        return code
    }

    private static func resolve(_ program: String, path: String) -> String? {
        if program.contains("/") { return program }
        return path.split(separator: ":").map { "\($0)/\(program)" }.first { access($0, X_OK) == 0 }
    }
}
