# U40: the broker keeps serving, and confined OpenCode seats start

## Problem (observed 2026-11-23/24)

1. **Agents read "Agencil is not running" while the app runs.** The app process held 1203 pipe descriptors after 16
   hours. Each `Process` + `Pipe` call on a broker thread (`ProcessTable.psListing`, `RepoCopy.data`, `GhClient.run`)
   left the pipe's read end open: the `FileHandle` is autoreleased, and a detached broker thread never drains its pool.
   Measured: 100 calls of the `psListing` shape leave 100 descriptors open, and 0 with an explicit `close()`. At the
   descriptor limit `accept()` fails, and `Broker.acceptLoop` returned on any error but `EINTR`. The sockets stayed
   bound with no one accepting: connects then hung (`list_targets` ran past 120 s) or were refused
   (`ECONNREFUSED`, reported as "not running"), until the owner quit and reopened the app. `BrokerClient` also
   reported a connection that got no reply line as "not running".
2. **Every confined OpenCode seat crashed at start** (22 of 24 runs since 2026-11-22: `opencode exited with status 1:
   Bun ...`). OpenCode makes `~/.cache/opencode`, `~/.local/state/opencode` and `~/.local/share/opencode` at start; the
   profile let it read none of the first two and write none of the three, so Bun's `mkdir` failed with `EEXIST`.

## Changes

- Every `Process` + `Pipe` read in AgencilCore closes the read end it read, before `waitUntilExit`.
- `acceptLoop` ends only when the listener itself is gone (`EBADF`, `EINVAL`, `ENOTSOCK`). Any other failure waits
  100 ms and accepts again.
- `BrokerClient.send` keeps "not running" for a refused or absent socket, and says
  `Agencil took the request but gave no answer (try again; if it repeats, quit and reopen Agencil)` for a connection
  that ends without a reply line. Both exit 3.
- `SeatHome.prepare(harness: "opencode", ...)` returns `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME`, set to
  `<run>/home/data`, `<run>/home/state` and `<run>/home/cache` (each 0700). It copies two owner files in, if each is
  a regular file of at most 32 MiB: `~/.local/share/opencode/auth.json` to `data/opencode/auth.json` and
  `~/.cache/opencode/models.json` to `cache/opencode/models.json`, both 0600. A link, a missing file or a larger
  file copies nothing.
- The OpenCode profile no longer grants `~/.local/share/opencode`. It keeps `~/.config/opencode`, read-only.
- Seeds (and the Codex `auth.json`) are read by `SafeRead.ownerFile`: every folder from the home down is opened with
  `O_DIRECTORY | O_NOFOLLOW`, the file with `O_NOFOLLOW | O_NONBLOCK`, and the read stops at the limit, so a file that
  grows after `fstat` is not copied.
- Found in review: the unconfined broker read files the confined seat can replace (`answer.txt`, `events.jsonl`,
  `usage.json`) by path, following links. A seat could swap `answer.txt` for a link to an owner secret and get it back
  as its answer, or for a FIFO to hang the exchange. These reads now go through `SafeRead.file` (no link followed,
  regular files only, bounded: 16 MiB for answers and event streams, 4096 bytes for `usage.json`). A refused read is
  an empty answer, so the exchange fails with "answered nothing". The preflight probe reads its answer file the same
  way. `SafeRead` also opens the file's folder without following a link, since the seat may write its run directory's
  own entry and could swap the folder for a link. The failure reason reads only the last 64 KiB of the run's log
  (`SafeRead.tail`), which the seat fills through its stderr.

## Threat model

- **Who calls:** only the broker prepares a seat home, for a seat it is about to start confined. No socket op names
  the folders or the seeds.
- **Hostile party:** the seat, steered by repo text or the question. Before U40 it could read all of
  `~/.local/share/opencode` (the owner's session history, logs, `auth.json`). After U40 it reads only the copy of
  `auth.json` and the model catalog, and writes only inside its run directory. Nothing it writes is copied back, and
  `<run>/home` is removed with the run, as for Codex (docs/U34-SPEC.md).
- **Forged paths:** the seed paths are fixed in code under the owner's home. They are opened with `O_NOFOLLOW` and
  `O_NONBLOCK` and judged by `fstat`, so a link or a FIFO in their place copies nothing and cannot hang the ask.
- **Fail closed:** a failure to make a folder or write a seed fails the ask before launch. A missing seed means the
  seat runs without it and may fail; the real folders are never granted instead.
- **The accept loop:** retrying on a transient error accepts nothing that the connection limit, the door checks or
  the peer attribution would not judge as before.
- **Enforced at:** the broker (home preparation, profile generation); the kernel sandbox applies the profile.

## Acceptance

- `SeatHome.prepare(harness: "opencode", runDirectory: R, home: H)` returns exactly the three XDG variables above; each
  folder and `R/home` are 0700.
- With `H/.local/share/opencode/auth.json` and `H/.cache/opencode/models.json` present, the copies are byte-equal and
  0600. With either one a symbolic link, missing or over 32 MiB, it is not copied and `prepare` still succeeds.
- `prepare` for `claude` and `hermes` returns nil and creates nothing; for `codex` it is unchanged
  (docs/U34-SPEC.md).
- The profile for `harness: "opencode"` grants `H/.config/opencode` and no path under `H/.local/share/opencode`.
- Under the real sandbox (skipped where `sandbox-exec` cannot apply a profile), a confined process started with the
  prepared environment can create `$XDG_STATE_HOME/opencode` and `$XDG_CACHE_HOME/opencode/bin`, and cannot read
  `H/.local/share/opencode/auth.json`.
- A broker client that connects to a listener which accepts and closes without a reply fails with exit 3 and the
  "gave no answer" message; with no listener it fails with exit 3 and the "not running" message.
- `SeatHome.prepare(harness: "opencode", ...)` with `H/.local/share/opencode` a link to a folder holding `auth.json`
  copies no `auth.json`; the same for `codex` with `H/.codex` a link.
- `SafeRead.file` returns nil for a symbolic link (to a readable file), a FIFO (without blocking), a directory and a
  file one byte over the limit; it returns the bytes of a regular file at the limit.
- A confined-path ask whose stub seat replaces `answer.txt` with a link to a file outside the run directory and exits 0
  ends `failed` with "answered nothing", and the ledger's answer does not contain the linked file's text.
- `ProcessTable` and `RepoCopy.output` calls repeated 200 times on a detached thread leave the process's count of
  open descriptors unchanged (within 2).
