#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WRAPPER="$ROOT/scripts/council-wrapper.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo with spaces"
export PATH="$TMP/bin:$PATH"
export WRAPPER_ARGV="$TMP/argv.jsonl" WRAPPER_BRIEF="$TMP/derived-brief"
export WRAPPER_STATE=done WRAPPER_VALID=true
unset COUNCIL_SEATS COUNCIL_CAP COUNCIL_NAME COUNCIL_CHANGE_KIND COUNCIL_DIFF COUNCIL_PROBE_ONLY
REPO="$TMP/repo with spaces"
printf 'Review the change.\n' > "$REPO/review.md"

cat > "$TMP/bin/agencil" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$WRAPPER_ARGV"
case "$1" in
  wake)
    shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --brief ]; then cp "$2" "$WRAPPER_BRIEF"; break; fi
      shift
    done
    jq -cn --arg state "$WRAPPER_STATE" --argjson valid "$WRAPPER_VALID" '
      {api:1,source:"agencil",data:{state:$state,verdict:"PASS",
        votes:[{seat:"alpha",vendor:"claude",state:"done",valid:true,vote:"PASS"},
               {seat:"beta",vendor:"codex",state:"done",valid:$valid,vote:"PASS"}],
        claims:[{seat:"alpha",severity:"P2",kind:"bug",file:"src/alpha.swift",line:12,evidence:"alpha evidence"},
                {seat:"beta",severity:"P1",kind:"risk",file:"src/beta.swift",line:34,evidence:"beta evidence"}]}}'
    ;;
  harnesses)
    printf '%s\n' '{"api":1,"source":"agencil","data":{"harnesses":[{"kind":"codex","found":true},{"kind":"claude","found":false}]}}'
    ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/agencil"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
run_case() {
  : > "$WRAPPER_ARGV"
  local expected="$1" brief="$2" out="$3" status=0
  bash "$WRAPPER" "$REPO" "$brief" "$out" > "$TMP/stdout" 2> "$TMP/stderr" || status=$?
  if [ "$status" -ne "$expected" ]; then
    cat "$TMP/stdout" "$TMP/stderr" >&2
    fail "expected exit $expected, got $status"
  fi
}

# Complete sitting: reports are keyed by vote seat and preserve claim details.
run_case 0 review.md "$TMP/complete"
contains "$TMP/stdout" '=== COUNCIL COMPLETE: 2/2 seats'
for seat in alpha beta; do
  [ -f "$TMP/complete/$seat.md" ] || fail "missing $seat report"
done
[ "$(find "$TMP/complete" -name '*.md' | wc -l | tr -d ' ')" = 2 ] || fail 'expected two reports'
contains "$TMP/complete/alpha.md" '- [P2] bug src/alpha.swift:12 - alpha evidence'
contains "$TMP/complete/beta.md" '- [P1] risk src/beta.swift:34 - beta evidence'
jq -es --arg repo "$REPO" '
  length == 1 and (.[0] | length == 11 and
    .[0:3] == ["wake","review","--brief"] and (.[3] | length > 0) and
    .[4:] == ["--repo",$repo,"--wait","1200","--cap","1200","--json"])
' "$WRAPPER_ARGV" >/dev/null || fail 'default wake argv'

# The stub captures the derived brief before the wrapper removes its temp file.
contains "$WRAPPER_BRIEF" 'change_kind: other'
contains "$WRAPPER_BRIEF" 'question: Carry out exactly the review described in ./review.md against this repository.'

export COUNCIL_SEATS='alpha:claude:opus beta:codex:-' COUNCIL_CAP=30
export COUNCIL_NAME=acceptance COUNCIL_CHANGE_KIND=docs
run_case 0 review.md "$TMP/overrides"
jq -es --arg repo "$REPO" '
  length == 1 and (.[0] | .[0:3] == ["wake","acceptance","--brief"] and
    .[4:] == ["--repo",$repo,"--wait","30","--cap","30","--json","--seats","alpha,beta"])
' "$WRAPPER_ARGV" >/dev/null || fail 'seat/cap overrides'
contains "$WRAPPER_BRIEF" 'change_kind: docs'

export WRAPPER_VALID=false
run_case 3 review.md "$TMP/degraded"
contains "$TMP/stdout" 'DEGRADED COUNCIL: only 1/2 seats'
export WRAPPER_VALID=true

run_case 2 missing.md "$TMP/missing"
contains "$TMP/stdout" 'FATAL: brief not in-repo'
[ ! -s "$WRAPPER_ARGV" ] || fail 'missing brief invoked agencil'

export WRAPPER_STATE=pending
run_case 2 review.md "$TMP/pending"
export WRAPPER_STATE=done

export COUNCIL_PROBE_ONLY=1
run_case 0 review.md "$TMP/probe"
contains "$TMP/stdout" '=== live seats: beta:codex:- ==='
jq -es '. == [["harnesses","--probe","--json"]]' "$WRAPPER_ARGV" >/dev/null || fail 'probe invoked wake or wrong probe arguments'

echo 'council wrapper: ok'
