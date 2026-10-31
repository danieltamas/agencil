# U13 contract: data retention and memory export

`docs/PLAN.md` U13 owns the rules. Testable surface in `AgencilCore` (`Sources/AgencilCore/Data/`), all public; tests use
`import AgencilCore`, `Ledger(directory:)`, `ConfigStore(directory:)` and seed rows by SQLite like the U11/U12 tests. Dates are injected.

## Schema
A new migration adds `sittings.repo TEXT` (the absolute repository path the sitting was woken for, NULL when unknown). A real sitting
fills it from its snapshot. The repo path stays in the local ledger and is never read by the leaderboard export.

## Retention

```swift
public struct RetentionReport: Equatable, Sendable { public let filesDeleted: Int; public let bytesFreed: Int64; public let exchangesCleared: Int }
public struct LedgerSize: Equatable, Sendable { public let database: Int64; public let rawOutputs: Int64; public var total: Int64 { get } }

public final class Retention: @unchecked Sendable {
    public static let defaultDays = 90
    public init(ledger: Ledger, directory: URL)              // directory holds config.json, agencil.sqlite and runs/
    public func days() throws -> Int                         // config key "retention_raw_days"; absent -> 90; a whole number 1...3650, else throws
    public func prune(now: Date) throws -> RetentionReport
    public func size() throws -> LedgerSize
}
```

- Raw seat outputs are (a) regular files under `<directory>/runs/` (recursive) whose modification time is older than `now - days`,
  and (b) the `question` and `answer` of exchanges that are `answered` or `failed` and were created before the cutoff:
  `answer` becomes NULL and `question` becomes the empty string (state, reason, chain and launch id stay).
  Files newer than the cutoff, files that are not regular files (a symlink is neither followed nor deleted), exchanges still `asking`
  and everything outside `runs/` are never touched. Directories under `runs/` left empty by the pruning are removed; `runs/` itself stays.
- Claims, evidence, assessments, verdicts, outcomes, briefs, snapshots, sittings and seat runs are kept: the pruning never touches them
  (their tables are append-only; the test compares row counts and a content hash before and after).
- `exchangesCleared` counts only exchanges that changed, so a second `prune` at the same `now` reports zeros.
- `size()` returns the byte size of `agencil.sqlite` (plus its `-wal` and `-shm` files when present) and of all regular files under `runs/`.
- `prune` throws on an invalid `retention_raw_days` and then deletes nothing.

## Memory export

```swift
public struct MemoryTarget: Equatable, Sendable { public let repo: String; public let folder: String; public let enabled: Bool; public init(repo: String, folder: String, enabled: Bool) }
public struct ExportReport: Equatable, Sendable { public let written: Int; public let unchanged: Int; public let skipped: Int }

public final class MemoryExport: @unchecked Sendable {
    public init(ledger: Ledger, directory: URL)
    public func targets() throws -> [MemoryTarget]           // config key "memory_export": JSON list of {"repo","folder","enabled"}; absent -> []; a present value that is empty or malformed throws
    public func save(_ targets: [MemoryTarget]) throws       // validates, then one ConfigStore.update
    public static func fileName(number: Int) -> String      // "agencil-sitting-0042.md" (number zero-padded to 4 digits, wider numbers keep all digits)
    public func run(now: Date) throws -> ExportReport
}
```

- Off by default: with no target, or a target with `enabled: false`, `run` writes nothing and creates nothing.
- Validation (`save`, and `targets()` when reading): `repo` and `folder` are absolute paths without `..` components; the same repo twice is refused;
  a malformed `memory_export` value throws.
- For each enabled target, every sitting whose `repo` equals the target's `repo` and whose state is not `running` is written to
  `<folder>/agencil-sitting-NNNN.md` (NNNN = the sitting number). Sittings of other repos, with no repo, or still running are not written
  (`skipped` counts sittings of enabled repos that are still running). The folder is created (mode 0700) when missing; a file is created with mode 0600.
- The Markdown is a pure function of the ledger and `now`: the title `# Sitting <no>: <council>`, then the state, the opened time,
  the verdict (when one exists) with its minority report and independence flags, then one section per claim with its id, seat,
  kind, severity, file and line, its status from `OutcomeBook.status(of:now:)` and the claim's stored text. Claim and verdict text come from seat
  output and repo text, so they are untrusted: each is placed inside a fenced code block whose fence is longer than any run of backticks in the text, so nothing in
  it can open a heading, a list or front matter at the start of a line outside a fence.
- Idempotent: a file whose bytes already equal the new content is not rewritten (`unchanged`, modification time kept). A changed ledger
  (a new outcome label) rewrites the file (`written`). Files are written to a temporary name in the folder and renamed, so a symlink at the
  final path is replaced, never followed, and a failure leaves the old file whole.
- The memory folder must be owned by the current user and not writable by group or others (refused otherwise); it is opened once and every later step is relative to that open directory. `runs/` is opened without following a symlink and walked the same way; an unreadable part of the tree throws instead of being skipped. Entries of `runs/` that belong to an exchange still asking, or to a launch still holding its reservation, are never deleted.
- Seat-supplied metadata (seat, kind, severity, file, line) is written inside a fence too; only ledger-minted identifiers (council, state, time, claim id, status) appear outside one, restricted to ASCII letters, digits and `._-:`.
- Files the export did not write, and files of sittings no longer in the ledger, are never deleted.

## Acceptance
As PLAN U13 (one test each), plus: default 90 days, a configured value, invalid value throws and deletes nothing; a file one second inside the window stays and one second
outside goes; symlink under `runs/` is left alone; exchanges `asking` untouched; claims/verdicts/outcomes row counts and content equal after prune; second prune reports zeros;
size readout adds the database and the runs; export writes only for enabled repos, one file per finished sitting with the exact file name, nothing for running or other-repo sittings;
second run writes nothing and keeps the modification time; a new outcome rewrites only that sitting's file; a claim text containing a heading, a backtick run and `---` stays inside a fence;
a symlink at the target path is replaced and its destination untouched; relative paths, `..` and duplicate repos are refused by `save`.

## Accepted limits
- The Settings pane (path and on/off per repo, retention days, size readout) and the weekly scheduler for `prune` and `run` are wiring on top of this API and land with the settings and integration work.
- The sitting-time caller that fills `sittings.repo` is part of this unit (`SittingStore.open`); older sittings have no repo and are never exported.
