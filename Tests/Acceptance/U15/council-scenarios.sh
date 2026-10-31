#!/bin/bash
# council-scenarios.sh <council-script> <out-dir>
# Runs a council script (the old council.sh, or the Agencil wrapper) against stub codex/opencode/claude binaries over a
# fixed set of scenarios and writes, per scenario, what Tests/Fixtures/council-script/ records: argv of every stub
# call (sorted, seats run in parallel), the files the run wrote with their line counts, stdout and the exit code.
# Parallel seats finish in any order, so stdout is compared sorted with runs of spaces squeezed.
# Paths are normalized and the output is ASCII, so the same run on any Mac produces the same bytes.
set -uo pipefail
script=$1 results=$2
here=$(cd "$(dirname "$0")" && pwd)
stubs=$(cd "$here/../../Fixtures/council-script/stubs" && pwd)
mkdir -p "$results"


scenario() { # name, then VAR=value pairs ending with "--" and the script arguments
  local name=$1; shift
  local env=() args=()
  while [[ $# -gt 0 && $1 != -- ]]; do env+=("$1"); shift; done
  shift; args=("$@")
  local work repo out log code
  work=$(mktemp -d); repo=$work/repo; out=$work/out; log=$work/stub.log
  mkdir -p "$repo"; : > "$log"
  printf '# Review\nReview the change.\n' > "$repo/brief.md"
  local resolved=()
  for a in "${args[@]}"; do resolved+=("${a//@REPO@/$repo}"); done
  resolved=("${resolved[@]//@OUT@/$out}")
  (cd "$repo" && env ${env[@]+"${env[@]}"} STUB_LOG="$log" COUNCIL_PROBE_CAP=${COUNCIL_PROBE_CAP:-2} PATH="$stubs:$PATH" \
      bash "$script" "${resolved[@]}" > "$work/stdout.raw" 2>&1; echo $? > "$work/exit.raw")
  local dest=$results/$name; mkdir -p "$dest"
  perl -CSD -pe 'BEGIN{($r,$o,$s)=splice(@ARGV,0,3)} s/\Q$o\E/<OUT>/g; s/\Q$r\E/<REPO>/g; s/\Q$s\E/<STUBS>/g;
    s/\x{26A0}/!/g; s/\x{2014}/-/g; s/\x{2192}/->/g; s/\x{2260}/!=/g; s/\x{2013}/-/g; s/[^\x00-\x7f]/?/g' \
    "$repo" "$out" "$stubs" "$work/stdout.raw" | grep -v "Terminated: 15" | tr -s " " | LC_ALL=C sort > "$dest/stdout.txt"
  cp "$work/exit.raw" "$dest/exit.txt"
  perl -pe 'BEGIN{($r,$o,$s)=splice(@ARGV,0,3)} s/\Q$o\E/<OUT>/g; s/\Q$r\E/<REPO>/g; s/\Q$s\E/<STUBS>/g' \
    "$repo" "$out" "$stubs" "$log" | LC_ALL=C sort > "$dest/argv.txt"
  if [[ -d $out ]]; then
    (cd "$out" && find . -type f ! -name '.opencode-serve.log' | LC_ALL=C sort | while read -r f; do
       case $f in *.md) printf '%s %s lines\n' "$f" "$(wc -l < "$f" | tr -d ' ')" ;; *) echo "$f" ;; esac
     done) > "$dest/files.txt"
  else : > "$dest/files.txt"; fi
  rm -rf "$work"
}

scenario default -- @REPO@ brief.md @OUT@
scenario override COUNCIL_SEATS="alpha:claude:opus beta:codex:-" COUNCIL_CAP=30 -- @REPO@ brief.md @OUT@
scenario degraded COUNCIL_CAP=30 STUB_THIN_MODELS=opencode/longcat-2.5-preview-free -- @REPO@ brief.md @OUT@
scenario probe-spare COUNCIL_PROBE_ONLY=1 STUB_DEAD_MODELS=opencode/nemotron-3-ultra-free -- @REPO@ brief.md @OUT@
scenario probe-all-dead COUNCIL_PROBE_ONLY=1 "STUB_DEAD_MODELS=opencode/nemotron-3-ultra-free opencode/longcat-2.5-preview-free opencode/muse-spark-1.3-contributor-free opencode/ling-3.1-flash-free opencode/mimo-v2.6-flash-free opencode/ling-3.0-flash-fin-free" -- @REPO@ brief.md @OUT@
scenario codex-limit STUB_CODEX_LIMIT=1 -- @REPO@ brief.md @OUT@
scenario no-brief -- @REPO@ missing.md @OUT@
