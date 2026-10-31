# U15a contract: `agencil harnesses [--probe]`

Part of the council cutover (docs/U15-SPEC.md, blocker 3). The broker op `harnesses` stops returning an empty list.

- Request: `{"op":"harnesses"}` with optional `"probe": true` (the CLI already sends it for `--probe`).
- Reply: `{"ok":true,"data":{"harnesses":[...]},"data_note":...}`, one object per catalog entry in catalog order, with exactly:
  `kind`, `found` (bool), `path` (the probed executable path or null), `version` (string or null), `signed_in` (`"yes"`, `"no"` or `"unknown"`),
  `probe_status` (`"ok"`, `"timed out"` or `"failed"`), `chain` (`"supported"`, `"unsupported"` or `"untested"`) and `installs` (count of working installs).
  A harness that is not installed has `found:false`, null path and version, `signed_in:"unknown"`, `probe_status:"failed"` (the discovery reports "not installed" as a failed probe).
- Without `probe` the op serves the discovery cache (up to 10 minutes old); with `probe: true` it probes again first. Either way the cache is refreshed.
- Discovery honors the test seams the resolver already uses (`AGENCIL_TEST_SEAMS`, `AGENCIL_PATH_PREFIX`), so a stub directory decides what is found.
- The human CLI form prints one line per harness: `<kind>  <found|missing>  <version>  <signed in|signed out|unknown>`.
- Acceptance: with stub `claude` (signed in) and `codex` (signed out) found and every other harness missing, the reply lists every catalog kind once
  in catalog order with the fields above; `probe:true` after a stub is replaced reports the new version while a plain call right after a first call reports the cached one.
