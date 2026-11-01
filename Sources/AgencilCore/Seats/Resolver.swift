import Foundation

/// A target turned into a seat that can run now, or the reason it cannot (docs/AGENT-API.md "Resolution").
public struct Resolved: Sendable {
    public let seat: Seat
    public let route: Route
    /// Set when a fallback answers: `answered by <fallback>, fallback for <seat>: <reason>`.
    public let substituted: String?
    /// The harness executable; nil for a seat that is a request (ollama).
    public let executable: String?
    /// The reservation taken for this seat, when the caller admits candidates.
    public var admitted: Admitted?
}

public struct Refusal: Error, Equatable, Sendable {
    public let exit: Int
    public let message: String
}

/// What the resolver may ask the world; tests and the broker supply the real answers.
public struct ResolverWorld: Sendable {
    public var probe: @Sendable (String) -> HarnessProbe?
    /// Kinds whose catalog entry has no sign-in status command (their sign-in state is unknowable, and usable).
    public var statusless: Set<String>
    /// Nil when the endpoint answers and lists the model; else the reason.
    public var ollamaProblem: @Sendable (Seat) -> String?
    /// Nil when the seat has no fresh preflight standing or an `ok` one; else `<seat> preflight: <reason>` (docs/U25-SPEC.md).
    public var preflight: @Sendable (Seat) -> String? = { _ in nil }
}

public enum Resolver {
    /// Steps 1 to 5 of the contract. `admit` takes the reservation of one candidate seat (the primary, then each
    /// fallback in turn) and throws a refusal when it is not admitted.
    public static func resolve(config: SeatConfig, caller: String, alsoKnownAs kinds: [String] = [], target: String,
                               world: ResolverWorld, admit: (Seat, Route) throws -> Admitted? = { _, _ in nil }) throws -> Resolved {
        guard let route = config.route(from: [caller] + kinds, to: target) else {
            throw Refusal(exit: 3, message: "refused: no route from \(caller) to \(target)")
        }
        guard let seat = config.seat(named: config.resolveName(target)) else {
            throw Refusal(exit: 4, message: "failed: no seat or alias named \(target)")
        }
        let original: Refusal
        let reason: String
        switch usable(seat, world) {
        case .success(let executable):
            do {
                return Resolved(seat: seat, route: route, substituted: nil, executable: executable, admitted: try admit(seat, route))
            } catch let refusal as Refusal {
                original = refusal
                reason = String(refusal.message.dropFirst("refused: ".count))
            }
        case .failure(let first):
            original = Refusal(exit: 4, message: "failed: \(first.reason)")
            reason = first.reason
        }
        for name in route.fallbacks {
            guard let fallback = config.seat(named: name), case .success(let executable) = usable(fallback, world) else { continue }
            do {
                return Resolved(seat: fallback, route: route,
                                substituted: "answered by \(fallback.name), fallback for \(seat.name): \(reason)",
                                executable: executable, admitted: try admit(fallback, route))
            } catch is Refusal { continue }
        }
        throw original
    }

    /// Whether this one seat can run now: the executable path (or nil for a request), else why not.
    public static func usable(_ seat: Seat, _ world: ResolverWorld) -> Result<String?, Unusable> {
        let base = installed(seat, world)
        guard case .success = base else { return base }
        if let standing = world.preflight(seat) { return .failure(Unusable(reason: standing)) }
        return base
    }

    /// The install, pin and sign-in checks alone, without the preflight standing.
    static func installed(_ seat: Seat, _ world: ResolverWorld) -> Result<String?, Unusable> {
        switch seat.harness {
        case "ollama":
            guard seat.endpoint != nil else { return .failure(Unusable(reason: "seat \(seat.name) has no endpoint")) }
            if let problem = world.ollamaProblem(seat) { return .failure(Unusable(reason: problem)) }
            return .success(nil)
        case "gemini", "aider", "goose":
            return .failure(Unusable(reason: "\(seat.harness) has no adapter"))
        default:
            guard let probe = world.probe(seat.harness), let newest = probe.executable, let version = probe.version else {
                let known = world.probe(seat.harness)
                if known?.paths.isEmpty == false { return .failure(Unusable(reason: "\(seat.harness) could not be probed: \(known?.probeStatus.message ?? "unknown")")) }
                return .failure(Unusable(reason: "\(seat.harness) is not installed"))
            }
            // The pin picks the newest install that satisfies it; sign-in is the account's, probed on the newest.
            var executable = newest
            var signedIn = probe.signedIn
            if let pin = seat.pin, !satisfies(version, pin: pin) {
                let matching = probe.installs.filter { satisfies($0.version, pin: pin) }
                guard let chosen = matching.max(by: { HarnessDiscovery.isNewer($1.version, than: $0.version) }) else {
                    return .failure(Unusable(reason: "\(seat.harness) \(version) is outside the pin \(pin)"))
                }
                executable = chosen.executable
                signedIn = chosen.signedIn
            }
            switch signedIn {
            case .signedIn: return .success(executable.path)
            case .signedOut: return .failure(Unusable(reason: "\(seat.harness) not signed in"))
            case .unknown(let reason):
                if world.statusless.contains(seat.harness) { return .success(executable.path) }
                return .failure(Unusable(reason: "\(seat.harness) sign-in is unknown: \(reason)"))
            }
        }
    }

    public struct Unusable: Error, Equatable, Sendable { public let reason: String }

    /// `1.x` is any 1.*; `1.2` is 1.2 or 1.2.*; `1.2.3` is exactly that. Compared at dot boundaries.
    public static func satisfies(_ version: String, pin: String) -> Bool {
        let want = pin.split(separator: ".").map(String.init)
        let have = version.split(separator: ".").map(String.init)
        for (index, part) in want.enumerated() {
            if part == "x" || part == "*" { return true }
            guard index < have.count, have[index] == part else { return false }
        }
        return true
    }
}
