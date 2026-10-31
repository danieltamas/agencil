#!/usr/bin/env bash
# council-wrapper.sh <repo_dir> <in_repo_brief_relpath> [out_dir]
# The council.sh interface over Agencil: one sitting through `agencil wake`, one report file per seat in out_dir.
# Env: COUNCIL_CAP        per-seat seconds (default 1200), passed as `wake --cap` (it only shortens a configured cap)
#      COUNCIL_SEATS      space list of "label:harness:model"; the labels are Agencil seat names and narrow the council (`wake --seats`)
#      COUNCIL_NAME       the council to wake (default review)
#      COUNCIL_CHANGE_KIND  the brief's change kind (default other)
#      COUNCIL_DIFF       diff range, required when the kind is code
#      COUNCIL_PROBE_ONLY=1  list the seats whose harness Agencil finds installed (`agencil harnesses --probe`), exit 0
# Exit: 0 every seat gave a valid answer; 2 brief missing, or the sitting is still pending at the cap; 3 degraded council,
#       refused, or no broker; a verdict BLOCK is reported but exits 0 here, as the old script never judged findings.
set -uo pipefail

REPO="${1:?usage: council-wrapper.sh <repo_dir> <in_repo_brief_relpath> [out_dir]}"
BRIEF_REL="${2:?in-repo brief path}"
OUT="${3:-/tmp/council-run}"
CAP="${COUNCIL_CAP:-1200}"
COUNCIL="${COUNCIL_NAME:-review}"
SEATS="${COUNCIL_SEATS:-}"

[ -f "$REPO/$BRIEF_REL" ] || { echo "FATAL: brief not in-repo at $REPO/$BRIEF_REL"; exit 2; }
mkdir -p "$OUT"

labels() { for s in $SEATS; do echo "${s%%:*}"; done; }

if [ "${COUNCIL_PROBE_ONLY:-0}" = 1 ]; then
  probes="$(agencil harnesses --probe --json)" || { echo "FATAL: agencil harnesses failed"; exit 3; }
  live=""
  for s in $SEATS; do
    rest="${s#*:}"; harness="${rest%%:*}"
    if printf '%s' "$probes" | jq -e --arg h "$harness" '.data.harnesses[] | select(.kind == $h and .found)' >/dev/null; then
      live="$live $s"
    else
      echo "=== ! seat ${s%%:*} ($harness) is not installed - seat dropped ==="
    fi
  done
  echo "=== live seats: ${live# } ==="
  exit 0
fi

brief="$(mktemp "${TMPDIR:-/tmp}/council-brief.XXXXXX")"
trap 'rm -f "$brief"' EXIT
{
  echo "change_kind: ${COUNCIL_CHANGE_KIND:-other}"
  echo "question: Carry out exactly the review described in ./$BRIEF_REL against this repository."
} > "$brief"

args=(wake "$COUNCIL" --brief "$brief" --repo "$REPO" --wait "$CAP" --cap "$CAP" --json)
[ -n "$SEATS" ] && args+=(--seats "$(labels | paste -sd, -)")
[ -n "${COUNCIL_DIFF:-}" ] && args+=(--diff "$COUNCIL_DIFF")

echo "=== Council over $REPO | brief ./$BRIEF_REL | cap ${CAP}s/seat | out $OUT ==="
reply="$(agencil "${args[@]}")"; code=$?
if [ -z "$reply" ]; then echo "=== agencil refused or failed (exit $code) ==="; exit 3; fi
printf '%s\n' "$reply" > "$OUT/sitting.json"
state="$(printf '%s' "$reply" | jq -r '.data.state // ""')"
if [ "$state" != done ]; then
  echo "=== sitting $(printf '%s' "$reply" | jq -r '.data.sitting // "?"') is $state: $(printf '%s' "$reply" | jq -r '.data.reason // "not finished at the cap"') ==="
  exit 2
fi
echo "=== Seats: $(printf '%s' "$reply" | jq -r '[.data.votes[].seat] | join(" ")') ==="

total=0; ok=0
while IFS= read -r seat; do
  total=$((total + 1))
  file="$OUT/$seat.md"
  valid="$(printf '%s' "$reply" | jq -r --arg s "$seat" '.data.votes[] | select(.seat == $s) | .valid')"
  {
    echo "# $seat"
    printf '%s' "$reply" | jq -r --arg s "$seat" '
      "vote: \((.data.votes[] | select(.seat == $s) | .vote // "none"))", "",
      (.data.claims[] | select(.seat == $s)
        | "- [\(.severity)] \(.kind) \(.file // "-"):\(.line // 0) - \(.evidence // "")")'
  } > "$file"
  lines=$(wc -l < "$file" | tr -d ' ')
  refs=$(grep -cE ' [^ ]+:[0-9]+ - ' "$file" || true)
  echo "[$seat] DONE lines=$lines file:line-refs=$refs -> $file"
  [ "$valid" = true ] && ok=$((ok + 1))
done < <(printf '%s' "$reply" | jq -r '.data.votes[].seat')

echo "=== COUNCIL SEATS ==="
printf '%s' "$reply" | jq -r '.data.votes[] | "  \(.seat)  \(if .valid then "ok" else "EMPTY/THIN" end)  \(.state)"'
if [ "$ok" -lt "$total" ]; then
  echo "=== ! DEGRADED COUNCIL: only $ok/$total seats gave a valid answer. Do NOT treat this as a full cross-vendor result;"
  echo "        rerun, or verify the findings against the code before trusting them. ==="
  exit 3
fi
echo "=== COUNCIL COMPLETE: $ok/$total seats (verdict $(printf '%s' "$reply" | jq -r '.data.verdict')) ==="
