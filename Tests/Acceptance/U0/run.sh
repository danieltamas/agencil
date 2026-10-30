#!/usr/bin/env bash
# Run through RMJ on the owner's Mac: rmj run -- Tests/Acceptance/U0/run.sh [--fast]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
fast=0
case ${1:-} in
  --fast) fast=1; shift ;;
  '') ;;
  *) echo 'usage: run.sh [--fast]' >&2; exit 2 ;;
esac
[[ $# == 0 ]] || { echo 'usage: run.sh [--fast]' >&2; exit 2; }
failed=0
for test in "$HERE"/test_*.sh; do
  name=${test##*/}
  if ((fast)) && [[ $name == *_slow.sh ]]; then
    echo "SKIP $name (slow)"
    continue
  fi
  if bash "$test"; then echo "PASS $name"; else echo "FAIL $name"; failed=1; fi
done
echo 'SKIP CI execution (requires GitHub; workflow files checked locally)'
exit "$failed"
