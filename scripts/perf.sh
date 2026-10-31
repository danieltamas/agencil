#!/usr/bin/env bash
# CPU budgets of the visual layer (docs/DESIGN.md "Visual layer", Budget).
#   perf.sh                         build release, run every scenario, fail when one is over budget
#   perf.sh --scenarios             list the scenarios
#   perf.sh --verdict <name> <cpu>  exit 0 when <cpu> (mean percent) is strictly under the budget of <name>
set -euo pipefail
cd "$(dirname "$0")/.."

scenarios=(closed open live menubar)
warmup=30
samples=60

budget() {
  case $1 in
    closed) echo 0.3 ;;
    open) echo 1 ;;
    live) echo 6 ;;
    menubar) echo 1.5 ;;
    *) return 1 ;;
  esac
}

# Strict: a mean equal to the budget fails. Unknown scenario, negative or non-numeric input fails too.
verdict() {
  local limit
  limit=$(budget "$1") || { echo "perf: unknown scenario $1" >&2; return 1; }
  [[ $2 =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "perf: not a CPU percentage: $2" >&2; return 1; }
  awk -v mean="$2" -v limit="$limit" 'BEGIN { exit !(mean < limit) }'
}

case ${1:-run} in
  --scenarios) printf '%s\n' "${scenarios[@]}"; exit 0 ;;
  --verdict)
    [[ $# -eq 3 ]] || { echo "usage: perf.sh --verdict <scenario> <mean-cpu-percent>" >&2; exit 2; }
    verdict "$2" "$3"; exit $? ;;
  run) ;;
  *) echo "usage: perf.sh [--scenarios | --verdict <scenario> <cpu>]" >&2; exit 2 ;;
esac

swift build -c release --product Agencil >&2
binary=$(swift build -c release --show-bin-path)/Agencil
echo "model: $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.model))"
failed=0
for scenario in "${scenarios[@]}"; do
  AGENCIL_PERF=$scenario "$binary" --perf >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
  sleep "$warmup"
  total=0
  for _ in $(seq 1 "$samples"); do
    cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')
    total=$(awk -v a="$total" -v b="${cpu:-0}" 'BEGIN { print a + b }')
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  mean=$(awk -v t="$total" -v n="$samples" 'BEGIN { printf "%.6f", t / n }')
  if verdict "$scenario" "$mean" 2>/dev/null; then status=ok; else status=FAIL; failed=1; fi
  echo "$scenario: mean $(awk -v m="$mean" 'BEGIN { printf "%.2f", m }')% budget $(budget "$scenario")% $status"
done
exit "$failed"
