/// Numbered migrations of agencil.sqlite. A migration is never edited once released; a change is a new entry.
/// Records are appended or superseded, never overwritten: the triggers refuse UPDATE and DELETE on the tables
/// that hold judgements, so a correction is a new row naming the one it supersedes.
enum LedgerSchema {
    /// Rows that record what was said, decided or configured. runs, seat_runs, requests and proposals keep
    /// lifecycle fields (status, end time, usage) that are updated as the work finishes.
    private static let immutable = ["briefs", "snapshots", "configs", "claims", "evidence", "assessments", "verdicts", "outcomes"]

    static let migrations: [String] = [
        """
        CREATE TABLE briefs (id TEXT PRIMARY KEY, created_at TEXT NOT NULL, author_vendor TEXT, body TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE snapshots (id TEXT PRIMARY KEY, brief_id TEXT REFERENCES briefs(id), commit_sha TEXT NOT NULL,
            diff_hash TEXT, context_manifest TEXT, created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE configs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, version INTEGER NOT NULL, hash TEXT NOT NULL,
            body TEXT NOT NULL, supersedes TEXT REFERENCES configs(id), created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE runs (id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('thread', 'sitting')),
            config_id TEXT REFERENCES configs(id), snapshot_id TEXT REFERENCES snapshots(id), status TEXT NOT NULL,
            started_at TEXT NOT NULL, ended_at TEXT);
        CREATE TABLE seat_runs (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), seat TEXT NOT NULL,
            harness TEXT NOT NULL, model_id TEXT, model_version TEXT, settings TEXT, started_at TEXT, ended_at TEXT,
            input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, exit_code INTEGER);
        CREATE TABLE requests (id TEXT PRIMARY KEY, caller TEXT NOT NULL, parent_id TEXT REFERENCES requests(id),
            chain TEXT, run_id TEXT REFERENCES runs(id), created_at TEXT NOT NULL);
        CREATE TABLE claims (id TEXT PRIMARY KEY, run_id TEXT REFERENCES runs(id),
            seat_run_id TEXT REFERENCES seat_runs(id), body TEXT NOT NULL, kind TEXT, severity TEXT, file TEXT,
            line INTEGER, supersedes TEXT REFERENCES claims(id), created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE evidence (id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), source TEXT NOT NULL,
            detail TEXT, created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE assessments (id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id),
            seat_run_id TEXT REFERENCES seat_runs(id), stance TEXT NOT NULL, reason TEXT, created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE verdicts (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), scope TEXT,
            verdict TEXT NOT NULL, validity TEXT, independence_flags TEXT, minority TEXT,
            snapshot_id TEXT REFERENCES snapshots(id), supersedes TEXT REFERENCES verdicts(id), created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE outcomes (id TEXT PRIMARY KEY, claim_id TEXT NOT NULL REFERENCES claims(id), source TEXT NOT NULL,
            adjudicator TEXT, certainty TEXT, label TEXT, detail TEXT, supersedes TEXT REFERENCES outcomes(id),
            created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE proposals (id TEXT PRIMARY KEY, kind TEXT NOT NULL, body TEXT NOT NULL, evidence TEXT,
            status TEXT NOT NULL, supersedes TEXT REFERENCES proposals(id), created_at TEXT NOT NULL);
        """ + immutable.map { table in
            """

            CREATE TRIGGER \(table)_no_update BEFORE UPDATE ON \(table)
            BEGIN SELECT RAISE(ABORT, '\(table) rows are never overwritten: append a superseding row'); END;
            CREATE TRIGGER \(table)_no_delete BEFORE DELETE ON \(table)
            BEGIN SELECT RAISE(ABORT, '\(table) rows are never deleted'); END;
            CREATE TRIGGER \(table)_no_replace BEFORE INSERT ON \(table)
            WHEN EXISTS (SELECT 1 FROM \(table) WHERE id = NEW.id)
            BEGIN SELECT RAISE(ABORT, '\(table) row already exists: INSERT OR REPLACE is refused'); END;
            """
        }.joined(),
        // Launches: the durable intent, identity and reservation of every process the broker starts. Mutable
        // lifecycle rows like runs; `reserved` is cleared only when no process remains in the process group.
        """
        CREATE TABLE launches (id TEXT PRIMARY KEY, nonce TEXT NOT NULL UNIQUE, argv TEXT NOT NULL, cwd TEXT NOT NULL,
            env TEXT NOT NULL, reserved_seconds INTEGER NOT NULL, state TEXT NOT NULL, reserved INTEGER NOT NULL,
            pid INTEGER, pgid INTEGER, start_time REAL, registered_at REAL, created_at REAL NOT NULL, ended_at REAL);
        """,
        // Asks: how a request ended, the leader's exit status, and threads with their exchanges. A thread is also
        // a `runs` row (kind 'thread'); its exchanges are the follow-ups, in order.
        """
        ALTER TABLE requests ADD COLUMN outcome TEXT;
        ALTER TABLE launches ADD COLUMN exit_status INTEGER;
        CREATE TABLE threads (id TEXT PRIMARY KEY, requested TEXT NOT NULL, seat TEXT NOT NULL, caller TEXT NOT NULL,
            substituted TEXT, created_at TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE exchanges (thread_id TEXT NOT NULL REFERENCES threads(id), seq INTEGER NOT NULL,
            question TEXT NOT NULL, answer TEXT, state TEXT NOT NULL, reason TEXT, launch_id TEXT,
            created_at TEXT NOT NULL, PRIMARY KEY (thread_id, seq)) WITHOUT ROWID;
        """,
    ]
}
