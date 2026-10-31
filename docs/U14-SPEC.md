# U14 contract: the seat leaderboard

`docs/LEADERBOARD.md` owns the product rules and `docs/PLAN.md` U14 the acceptance lines; this file fixes the testable surface.
Three parts: the Mac side in `AgencilCore` (`Sources/AgencilCore/Leaderboard/`), the CI side in Python (`scripts/leaderboard/`,
stdlib only) and the workflow `.github/workflows/leaderboard.yml`. Swift tests use `import AgencilCore`, `Ledger(directory:)`,
`ConfigStore(directory:)` and seed rows by SQLite like the U11-U13 tests. Python tests are `unittest` files under `Tests/Leaderboard/`,
run as `python3 -I -m unittest discover -s Tests/Leaderboard`.

## Mac side (Swift, public)

```swift
public struct LeaderboardCell: Equatable, Sendable {
    public let model: String; public let harness: String; public let changeKind: String
    public let n: Int; public let confirmed: Int; public let refuted: Int; public let unresolved: Int
    public let confirmedShare: Double; public let confirmedShareCI: [Double]
    public let coverage: Double?; public let coverageCI: [Double]?
    public let goldenRecall: Double?; public let goldenN: Int
    public let medianSeconds: Double?; public let costPerConfirmedUSD: Double?
}
public struct LeaderboardData: Equatable, Sendable { public let generatedAt: String; public let from: String; public let to: String
    public let outcomesTotal: Int; public let minN: Int; public let cells: [LeaderboardCell] }

public enum PublicModels {                       // generated from scripts/leaderboard/public-models.json by scripts/sync-public-models.sh
    public static func isPublic(_ id: String) -> Bool    // listed and "publishable": true
    public static let pattern: String                    // ^[a-z0-9][a-z0-9._:-]{0,63}$
}

public enum LeaderboardExport {
    public static let schema = 1
    public static func build(ledger: Ledger, config: SeatConfig, aliases: [String: String], aliasesOnMain: Set<String>,
                             golden: [String: GoldenScore], minN: Int, now: Date) throws -> LeaderboardData
    public static func canonicalJSON(_ data: LeaderboardData) throws -> Data   // sorted keys, 2-space indent, "\n" at the end, ASCII
}

public enum LeaderboardValidator {
    public static func validate(_ json: Data, aliasesOnMain: Set<String>) throws     // throws LeaderboardError on anything off the allowlist
}

public struct GitHubResponse: Equatable, Sendable { public let status: Int; public let body: Data; public init(status: Int, body: Data) }
public protocol GitHubClient: Sendable {
    func get(_ path: String) throws -> GitHubResponse                 // path like "repos/o/r/contents/data.json?ref=leaderboard"
    func put(_ path: String, body: Data) throws -> GitHubResponse     // JSON body
    func dispatch(workflow: String, ref: String) throws               // gh workflow run <workflow> --ref <ref>
}
public struct GhClient: GitHubClient { public init(repo: String? = nil) }   // the real one, through `gh`; `repo` pins workflow dispatch

public final class LeaderboardPublisher: @unchecked Sendable {
    public init(ledger: Ledger, directory: URL, github: GitHubClient)
    public func preview(now: Date, golden: [String: GoldenScore]) throws -> Data     // exactly the bytes publish would send
    public func press(now: Date, golden: [String: GoldenScore]) throws                 // the owner's manual publish; also turns scheduled publishing on
    public func publishScheduled(now: Date, golden: [String: GoldenScore]) throws -> Bool   // false (and no request) until the first press
}
```

- Settings in `config.json` (all optional): `leaderboard_repo` (default `danieltamas/agencil`, must be `owner/name` of letters, digits, `.`, `_`, `-`),
  `leaderboard_min_n` (whole number, default 20, never below 10: a lower value is raised to 10), `leaderboard_aliases`
  (JSON object `{"<local model>": "<public name>"}`), `leaderboard_enabled` (`"1"` after the first press; any other value or absent = off).
  A malformed value throws. `leaderboard_aliases` values and `aliasesOnMain` members match the model pattern.
- **Cells.** One cell per (model, harness, change kind): a seat's `model` and `harness` come from `config` (a seat no longer in the config
  is skipped); the change kind comes from the sitting's brief line `change_kind: <kind>` (a kind outside auth, schema, ui, refactor, infra, other,
  or no line, becomes `other`). The counts come from the same finding rules as `OutcomeBook.scoreboard`: a finding is credited once to
  each seat that raised it; `confirmed`, `refuted` and `unresolved` count findings, pending counts nowhere; `n = confirmed + refuted`;
  `confirmed_share = confirmed / n`; `coverage` is relative to the confirmed findings in sittings where the seat gave a valid answer (a seat run
  with exit code 0) and is omitted (nil) when that denominator is 0; intervals are Wilson 95% rounded to 2 decimals; `golden_recall` and
  `golden_n` come from `golden[seatName]` (seats of one cell are summed) and the recall is nil when `golden_n` is 0;
  `median_seconds` is the median seat-run duration and `cost_per_confirmed_usd` the cell's seat-run cost over `confirmed` (nil when 0 confirmed).
  Two seats of one model and harness share a cell.
- **Model names.** A seat's model is published as is when `PublicModels.isPublic(model)`. Otherwise it is published under `aliases[model]` when that
  alias exists and is in `aliasesOnMain`; otherwise its cells are dropped (a local model named `client-project` never appears).
- **Minimum.** A cell with `n < minN` is dropped (n 19 at 20 is absent, n 20 stays). `minN` below 10 is raised to 10.
- **Allowlist.** The export reads only aggregate columns; nothing like a repo name, path, claim text, brief, diff, prompt, person, host or
  endpoint is read into it. `canonicalJSON` emits exactly the keys of the schema in `docs/LEADERBOARD.md` (`schema`, `generated_at`, `window`
  `{from,to}`, `outcomes_total`, `min_n`, `cells[]` with `model, harness, change_kind, n, confirmed, refuted, unresolved, confirmed_share,
  confirmed_share_ci, coverage, coverage_ci, golden_recall, golden_n, median_seconds, cost_per_confirmed_usd`; an absent optional value omits its
  key). `window.from` and `window.to` are the earliest and latest claim time among decided findings (`to` is `now`), `outcomes_total` the number
  of distinct decided findings, `generated_at` is `now`. Times are `yyyy-MM-ddTHH:mm:ssZ`.
- **Validator** (`LeaderboardValidator`, the same rules as `validate.py`): the top level, `window` and each cell have exactly the allowed
  keys (an unknown key, or a missing required key, throws); `schema == 1`; `model` matches the pattern and is public or in `aliasesOnMain`;
  `harness` is a catalog harness kind; `change_kind` is one of the six; counts are non-negative integers with `n == confirmed + refuted`;
  shares and recalls are in [0,1]; intervals have two ordered numbers in [0,1]; `n >= min_n` and `min_n >= 10`; no string contains a `/`,
  a `\`, a control character or a character outside printable ASCII except in `model`/`harness` patterns already checked.
- **Publisher.** `preview` = `canonicalJSON(build(...))` after validation. `press`/`publishScheduled`:
  1. validate; a validation failure sends nothing;
  2. `GET repos/<repo>/contents/data.json?ref=leaderboard` -> `sha` from the JSON body (status 404 = no file, so no `sha`);
  3. `PUT repos/<repo>/contents/data.json` with a JSON body holding exactly `branch: "leaderboard"`, `message`, base64 `content` of the preview bytes
     and `sha` (when the file exists); no request ever names another branch or file path;
  4. a 409 or 422 on the PUT re-reads once (step 2) and retries the PUT once; a second failure throws and starts no workflow;
  5. after a successful PUT: `dispatch(workflow: "leaderboard.yml", ref: "main")`.
  A status outside 200-201 on the PUT throws. `publishScheduled` returns false and sends no request while `leaderboard_enabled` is not `"1"`;
  `press` sets it to `"1"` only after the PUT succeeded. Two publishes in a row each read the sha again.

## CI side (Python, stdlib only)

`scripts/leaderboard/public-models.json`: `{"models": [{"id": "...", "provider": "...", "publishable": true}]}` (the exact ids are the owner's to extend).
`scripts/leaderboard/public-aliases.json`: `{"aliases": ["..."]}` (empty at first). `scripts/leaderboard/harnesses.json`: `{"harnesses": [...]}` (the catalog kinds).

- `validate.py <data.json> [--models F] [--aliases F] [--harnesses F]`: exit 0 and print `ok`, or exit 1 and print each problem on a line. Same rules as the Swift
  validator. Rejects an unknown key, a bad model string (pattern or not public/alias), a low-n cell (`n < min_n`), `n != confirmed + refuted`, a bad change kind.
- `render.py --data F --out DIR --today YYYY-MM-DD`: writes `DIR/leaderboard-dark.svg`, `DIR/leaderboard-light.svg`, `DIR/LEADERBOARD.md` and
  `DIR/history/<today>.json` (a copy of data.json). Deterministic: the same inputs give identical bytes (no clock, no randomness, sorted iteration).
  Card 880 x 360, ASCII only, the top 8 cells by the lower bound of the confirmed-share interval, text "updated <date>, <N> outcomes", the date drawn with the class
  `warn` when `generated_at` is more than 7 days before `--today`. `LEADERBOARD.md` lists every cell, the method and the caveat
  "Self-reported from one owner's councils on their own repositories. Not a general benchmark." and says unresolved findings count in no rate.
  History files older than 365 days before `--today` are removed.
- `scripts/leaderboard/run-render.sh <main_dir> <data_dir> <today>`: validate `data_dir/data.json` with the scripts in `main_dir`, then render into `data_dir`.
  A failed validation exits non-zero and writes nothing in either directory. It never writes under `main_dir`.
- `.github/workflows/leaderboard.yml` (on `main`): triggers `workflow_dispatch` and a nightly `schedule`, no `push` or `pull_request`; `concurrency: leaderboard`
  with `cancel-in-progress: false`; `permissions: contents: write` only; checks out `main` and `leaderboard` into separate paths; every `uses:` pinned to a 40-hex SHA;
  runs `scripts/leaderboard/run-render.sh` and commits only on the `leaderboard` checkout as `github-actions[bot]`; the commit step is skipped when nothing changed.
- `scripts/leaderboard/bootstrap.sh <dir>`: creates a local repository with an orphan `leaderboard` branch holding an empty-cells `data.json`, a placeholder card and `LEADERBOARD.md`
  rendered by `render.py`; prints the one `git push` command the owner runs; never pushes.

## Acceptance
As PLAN U14, one test each: preview prints only allowlisted fields and a fixture ledger with a repo name, a path and claim text yields a `data.json` containing none of them (grep);
a seat on model `client-project` is absent; the PUT body carries `branch: leaderboard`, base64 `content`, `message` and the expected `sha` (recorded request) and nothing touches the default branch;
the render workflow's script run on a fixture produces the SVGs and `LEADERBOARD.md` in the data checkout and changes nothing in the main checkout, and the workflow file has the
concurrency group; n 19 at `min_n` 20 is absent (n 20 present); `validate.py` rejects an unknown key, a bad model string and a low-n cell; `render.py` is deterministic; a stale sha
(409) re-reads and retries once, a second failure throws and starts no workflow; publishing is off until the first manual press. Plus: aliases only when on main; coverage/golden omitted rather than 0;
recall never appears outside golden; unresolved counts in no rate; validation failure sends no request; Swift and Python validators agree on the same fixtures.

## Accepted limits
- The Settings > Leaderboard pane (preview, Publish now, alias approval), the broker schedule (daily 06:00 and after 10 new outcomes) and the `agencil leaderboard preview|publish` command are wiring on top of this API and land with the integration work.
- The vendor mark column of the card is drawn as the harness name until `Brand/vendors/` exists. The orphan branch is created by `bootstrap.sh` on the owner's push; the app never pushes.
- Vendor terms per provider (decision D9) are the owner's check before the first press; `publishable: false` in `public-models.json` excludes a model.
