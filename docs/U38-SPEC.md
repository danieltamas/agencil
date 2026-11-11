# U38: confined Codex seats that run commands

A Codex seat asked with a `repo` has never run a shell command. The broker starts it under `sandbox-exec`
(docs/U6-SPEC.md "Confinement") with `-s read-only`, and Codex then starts its own seatbelt sandbox for every command.
macOS refuses a sandbox inside a sandbox: `sandbox-exec -p '(version 1)(allow default)' sandbox-exec -p '(version 1)
(allow default)' /bin/echo x` fails with `sandbox_apply: Operation not permitted`, so no profile rule fixes it. The
seat's log shows `exec_command failed: CreateProcess { "Operation not permitted" }` and the seat answers that it could
read nothing. Both confined Codex runs kept on the owner's Mac failed this way.

The only way to let commands run is to switch Codex's own sandbox off when the broker confines it. Its commands then
inherit the broker's profile, which until now allowed all network (`(allow network*)`) and lets them read the run's
copy of the owner's Codex login. This unit therefore makes the broker's profile carry the `no_network_tools` promise
itself: a confined Codex seat reaches the network only through a loopback proxy the broker owns, and that proxy
connects only to the model vendor's hosts.

Measured with codex-cli 0.160.0 on the owner's Mac, under such a profile and with only `chatgpt.com` allowed: the
seat answered, `cat` of a file in the copy worked, `curl https://example.com` was refused by the proxy (403), and the
same `curl` with the proxy variables removed could not resolve the host.

Out of scope, reported separately: an exchange whose seat could read nothing is still stored as `answered`; the repo
copy has no `.git` and no uncommitted files. Claude, OpenCode and Hermes seats keep their current profile.

## Behaviour

1. **A confined Codex seat runs without its own sandbox.** When the broker confines a `codex` seat (an ask with a
   repo copy), the adapter's argv carries `-s danger-full-access` in place of `-s read-only`. An unconfined `codex`
   seat (no repo) and the availability probe keep `-s read-only`. No other argument changes.
2. **Its only network is the broker's proxy.** The profile of a confined `codex` seat has no `(allow network*)`. In
   its place it has exactly one network grant, `(allow network-outbound (remote tcp "localhost:<port>"))`, where
   `<port>` is the port of the broker's egress proxy. The two denials of the broker's own sockets stay.
3. **The proxy only tunnels to the vendor.** The egress proxy listens on `127.0.0.1` and on `::1`, on the same
   port, which the system picks: the profile's `localhost:<port>` covers both addresses, so both are held, or another
   local user could listen on the one left free. A proxy that cannot hold both does not start. It
   accepts `CONNECT <host>:<port>` and nothing else. It opens the tunnel only when `<host>` equals, ignoring case, one
   of the allowed hosts and `<port>` is the allowed port (443); it then answers `HTTP/1.1 200 Connection Established`
   and relays bytes both ways until either side closes. Any other host or port is answered `HTTP/1.1 403 Forbidden`,
   any other method `HTTP/1.1 405 Method Not Allowed`, and a request head longer than 8192 bytes (its blank line
   included) or not terminated within 10 seconds is closed. A refused request never causes a connection or a name
   lookup. At most 16 name lookups run at once; a tunnel asked for beyond that is answered `502`. A tunnel whose reader takes no bytes for 30 seconds, or that is silent both ways for 15 minutes, is closed.
4. **Allowed hosts for Codex:** `chatgpt.com` (subscription), `api.openai.com` (API key) and `auth.openai.com` (login
   refresh). The list is a constant in the broker; no config, caller or repo text can extend it.
5. **The seat is told about the proxy.** The confined Codex seat starts with `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`
   and their lower-case forms set to `http://127.0.0.1:<port>`, and `NO_PROXY` and `no_proxy` set to the empty string.
6. **The proxy outlives the broker.** The profile names a port, not a listener, and a seat (or a child that left its
   process group) can outlive the broker. If the port fell free then, any local user could listen on it and serve
   as an open proxy. So the proxy runs in a helper process of its own, `agencil egress-proxy <harness>`, started by
   the broker in its own session with none of the broker's descriptors. It ignores `SIGHUP`, `SIGINT`, `SIGTERM` and
   `SIGPIPE` and serves until its record (item 7) is removed, checking every 2 seconds; in practice until logout,
   restart or an uninstall. A killed or restarted broker changes nothing for it.
7. **A broker finds the running helper.** The helper writes `<Agencil home>/egress-<harness>.json` (mode 0600,
   written whole by rename): `pid`, `startTime` (its own process start time), `port` and `hosts` (sorted). On each
   confined Codex ask the broker reuses the helper when that record's `hosts` equal the wanted list and the process
   with that `pid` has that `startTime`; otherwise it starts a helper and waits up to 5 seconds for a record naming
   the new helper's pid. A helper whose record was replaced by a newer one keeps serving (seats started on its port
   may still run); only a missing record ends it. `install.sh --uninstall` and the cask's uninstall remove the record.
8. **Fail closed.** When the proxy cannot be started the ask fails before anything is launched, with
   `failed: confinement unavailable`. A confined Codex seat is never started with `(allow network*)`, and never
   started with `-s danger-full-access` outside the broker's profile.
9. Other harnesses keep `(allow network*)`, get no proxy variables and start no helper.

## Threat model

- **Who acts:** the confined seat process and, new in this unit, every shell command it runs, all steered by the repo
  copy and the prompt (assume hostile). They share one profile; the kernel cannot tell Codex from its children.
- **What a command can reach (new):** read, everything the profile already let Codex read: the repo copy, the run
  directory including `home/.codex/auth.json` (the copy of the owner's Codex login), the harness package and the
  system paths. Write, the run directory only, as before. Network, the proxy's port only.
- **What the proxy gives:** a TLS tunnel to the three vendor hosts on port 443, to anyone who can connect to the
  loopback port. That is every process of every local user, so the proxy must never be useful beyond those hosts:
  exact host match, one port, `CONNECT` only, no plain HTTP forwarding, no way to add a host at run time.
- **Forged input:** the `CONNECT` line is hostile text. The host is compared as a string against the constant list
  before any lookup, so an IP literal, a trailing dot, a user-info or a longer name that merely contains an allowed
  one is refused. The profile's port comes from the broker's own listener, never from a caller.
- **Residual risk, accepted:** a steered command can send what it can read (the copy, the login copy) to the vendor's
  own hosts. The vendor already receives the copy as the seat's prompt and already issued the login; the remaining
  channel is a different account at the same vendor (for example an API key planted in the repo text). The tunnel is
  opaque, so a request that names another site on the vendor's front end inside TLS is not seen by the proxy.
  `(allow mach-lookup)` is unchanged, so a system service that fetches on a caller's behalf stays reachable as it was.
- **No DNS channel:** name lookups from the seat fail (measured); the proxy resolves only allowed names.
- **A squatted port:** the port is a number any local user may bind once it is free, and the seat would gladly talk
  to whoever holds it. It therefore stays held: by a helper that does not depend on the broker (Behaviour 6), that
  the seat cannot signal (`signal (target self)`) and whose port the seat cannot bind (the profile grants outbound
  only). Killing seats when the broker dies was tried and refused in review: a child can leave the process group,
  and a kill is never atomic with the port falling free.
- **TCP only:** the grant is `remote tcp`, not `remote ip`. Measured: under `remote ip "localhost:<port>"` a
  sandboxed process sent a UDP datagram to that port, which any local user could have been listening on; under
  `remote tcp` the send fails.
- **Residual risk, accepted by the owner (2026-11-11): another account on the same Mac.** The sandbox's `localhost`
  is every address of this Mac, not only `127.0.0.1` and `::1` (measured: a sandboxed process connected to the LAN
  address on the granted port). The helper holds the two loopback addresses; a second user account can still listen
  on `<LAN address>:<port>` and relay for a seat steered by repo text. Closing it means listening on every address,
  which exposes a port to the network and to the firewall prompt, and was refused for that reason. It needs a
  hostile account on the owner's Mac together with hostile repo text.
- **The record** is trusted because the Agencil home is mode 0700 and outside every seat's writable run directory:
  only the owner can write or remove it. A stale record (a dead helper, a reused pid) fails the start-time check.
- **Residual risk, accepted:** a helper that crashes, or that the owner's own user kills, frees the port while a seat
  may run. A process of the owner's user is outside this model (it already reads everything a seat could send); a
  crash needs a fault in the proxy, which is why its input handling is small and bounded. A change to the proxy's
  code reaches a running helper only after logout or restart, unless the host list changed.
- **Fail closed:** see Behaviour 8. A proxy that is gone leaves the seat without network, which ends the run as a failure.
- **Enforced at:** the broker (argv, profile, proxy, environment); the kernel sandbox applies the profile. Nothing is
  enforced by Codex.

## Interfaces (fixed so tests can be written before the code)

- `Adapter.command(seat:executable:prompt:answerFile:runDirectory:reportUsage:images:ownSandbox:)`: the new last
  parameter `ownSandbox: Bool = true`. For `codex`, `false` gives `-s danger-full-access`; other harnesses ignore it.
- `Confinement.profile(copy:runDirectory:executable:harness:home:brokerHome:egressPort:)`: the new last parameter
  `egressPort: Int? = nil`. Nil keeps `(allow network*)`; a port gives the single grant of Behaviour 2.
- `enum Egress` in `Sources/AgencilCore/Seats/Egress.swift`:
  - `static func hosts(for harness: String) -> Set<String>?`: the allowed hosts; nil for a harness that is not proxied.
  - `static func environment(port: Int) -> [String: String]`: the variables of Behaviour 5.
- `final class EgressProxy` in `Sources/AgencilCore/Seats/EgressProxy.swift`:
  - `init(allowedHosts: Set<String>, allowedPort: Int = 443) throws`: binds and starts serving, or throws.
  - `let port: Int`: the loopback port it listens on.
  - `func stop()`: closes the listener and every open tunnel.
- `Broker.egressPort(for harness: String) throws -> Int?`: nil for a harness that is not proxied; otherwise the port of
  that harness's helper, reused or started now. Throws `Refusal(exit: 4, message: "failed: confinement unavailable")`
  when no helper can be had.
- `enum EgressHelper` in `Sources/AgencilCore/Seats/EgressHelper.swift`:
  - `struct Record: Codable, Equatable { pid: Int32, startTime: Double, port: Int, hosts: [String] }`.
  - `static func recordFile(home: URL, harness: String) -> URL`: `<home>/egress-<harness>.json`.
  - `static func running(home: URL, harness: String, hosts: Set<String>) -> Record?`: the record, when Behaviour 7
    says it may be reused.
  - `public static func run(harness: String, home: AgencilHome) -> Int32`: the helper's body
    (`agencil egress-proxy <harness>`); exit 1 for a harness that is not proxied.

## Acceptance

- `Adapter.command` for a `codex` seat with `ownSandbox: false` has `-s` followed by `danger-full-access` and no
  `read-only`; with the default it has `-s` followed by `read-only`; apart from that one value both argv are equal.
  For `claude` and `opencode` the argv does not depend on `ownSandbox`.
- `Confinement.profile` with `egressPort: 4321` contains `(allow network-outbound (remote tcp "localhost:4321"))`,
  does not contain `(allow network*)`, and still contains both `deny network*` lines for the broker home; with no
  `egressPort` it contains `(allow network*)` and no `network-outbound` grant.
- `Egress.hosts(for: "codex")` is exactly `chatgpt.com`, `api.openai.com`, `auth.openai.com`; it is nil for `claude`,
  `opencode`, `hermes` and `ollama`. `Egress.environment(port: 9)` has the six proxy variables set to
  `http://127.0.0.1:9` and `NO_PROXY` and `no_proxy` set to `""`.
- An `EgressProxy(allowedHosts: ["localhost"], allowedPort: <port of a local echo server>)`: `CONNECT localhost:<port>`
  is answered with a `200` line and bytes sent afterwards come back echoed; `CONNECT LOCALHOST:<port>` is also tunnelled;
  `CONNECT 127.0.0.1:<port>`, `CONNECT localhost.:<port>`, `CONNECT localhost:<other port>` and
  `CONNECT evil.example:<port>` are each answered `403` and the echo server sees no connection for them;
  `GET http://localhost:<port>/ HTTP/1.1` is answered `405`; a head of 9000 bytes with no blank line is closed without
  a `200`. The proxy listens on `127.0.0.1` and on `::1` with the same port and on
  no other address: a `CONNECT` sent to `[::1]:<port>` is tunnelled the same way, and while the proxy runs a bind of
  another socket to `[::1]:<port>` or to `127.0.0.1:<port>` fails with `EADDRINUSE`.
- After `stop()` a new connection to the port is refused and an open tunnel is closed.
- Under the real sandbox (skipped where `sandbox-exec` cannot apply a profile), a process started under a profile
  with `egressPort` set to a proxy's port connects to that port, and cannot connect to a second listener on another
  loopback port.
- A confined `codex` ask through the broker (stub harness, with a repo): the launched argv has `danger-full-access`,
  the run's `confine.sb` has the `localhost:<port>` grant and no `(allow network*)`, the stub's environment has
  `HTTPS_PROXY=http://127.0.0.1:<port>` with the same port, and that port accepts a connection. A second confined
  `codex` ask gets the same port. A `codex` ask with no repo has `read-only` and no `HTTPS_PROXY`.
- A head whose `CONNECT` line is valid but whose bytes up to and including the blank line number more than 8192 gets
  no `200`, whether the blank line arrives in the same write or a later one.
- `stop()` while a client has connected and sent only part of a head closes that client's connection.
- After a confined `codex` ask through a test broker, `egress-codex.json` in the broker's home holds the port of the
  run's profile, the three hosts sorted, and the pid of a live process whose start time matches. When the broker
  process is killed with `SIGKILL`, that port still accepts a connection 2 seconds later and the helper's pid is
  still alive; a new broker on the same home then gives a confined `codex` ask the same port and the record's pid
  is unchanged. The helper ignores `SIGTERM`. Once the record file is removed the helper's process is gone within
  6 seconds and the port refuses connections (the test removes the record in its cleanup either way).
- `EgressHelper.running` returns nil for a record whose `startTime` differs from the process's, whose pid is not
  alive, whose `hosts` differ from the wanted set, or that is not valid JSON.
- A confined `claude` ask through a test broker leaves no `egress-*.json` in the broker's home.
- A confined `claude` ask through the broker keeps `(allow network*)` in its `confine.sb` and has no `HTTPS_PROXY`.
