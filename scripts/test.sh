#!/usr/bin/env bash
# The Swift test step: the suite once, in parallel; on a failure, only the suites that failed are run again,
# one at a time. A suite that fails under the parallel run's load and passes alone (a timing bound, a port, a
# lock) costs its own minutes, not the whole suite's. A failure that survives the serial rerun is real.
#   test.sh --scratch <dir> [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

scratch=${SCRATCH:-$HOME/.cache/agencil-build}
extra=()
while (($#)); do
  case $1 in
    --scratch) scratch=$2; shift ;;
    --skip-build) extra+=(--skip-build) ;;
    *) echo "usage: test.sh [--scratch <dir>] [--skip-build]" >&2; exit 2 ;;
  esac
  shift
done
log="$scratch/last-run.log"
mkdir -p "$scratch"

if swift test "${extra[@]}" --scratch-path "$scratch" 2>&1 | tee "$log"; then
  exit 0
fi

# A runner killed by a signal is a defect, not load: no test teardown ran, so every live test broker is orphaned.
# A serial rerun that passes would hide it, so the gate fails here.
# SwiftPM's line can be glued to the end of a test's line, so it is matched anywhere, not at a line start.
if crash=$(grep -m1 -oE 'error: Exited with unexpected signal code [0-9]+' "$log"); then
  echo "test.sh: the test runner was killed by a signal ($crash); not rerunning" >&2
  exit 1
fi

# "Suite Name failed after ..." names what to run again. A suite with a display name is printed in quotes and
# filtered by its type, the struct under its @Suite line. A suite whose type is not found, or none named at all
# (a build error), runs the whole suite again serially.
names=$(sed -nE 's/.*Suite "([^"]+)" failed after.*/\1/p; s/.*Suite ([A-Za-z0-9_]+) failed after.*/\1/p' "$log" | sort -u)
suites=()
while IFS= read -r name; do
  [[ -n $name ]] || continue
  if [[ $name =~ ^[A-Za-z0-9_]+$ ]]; then
    suites+=("$name")
  else
    type=$(grep -rh -A1 -F "@Suite(\"$name\"" Tests | sed -nE 's/^(final )?(struct|class|actor|enum) ([A-Za-z0-9_]+).*/\3/p' | head -1)
    if [[ -z $type ]]; then
      echo "test.sh: no type found for suite \"$name\", running the suite again serially" >&2
      exec swift test --skip-build --no-parallel --scratch-path "$scratch"
    fi
    suites+=("$type")
  fi
done <<< "$names"
if [[ ${#suites[@]} -eq 0 ]]; then
  echo "test.sh: no failed suite named in the log, running the suite again serially" >&2
  exec swift test --skip-build --no-parallel --scratch-path "$scratch"
fi

filter=$(IFS='|'; echo "${suites[*]}")
echo "test.sh: running again serially: ${suites[*]}" >&2
exec swift test --skip-build --no-parallel --scratch-path "$scratch" --filter "$filter"
