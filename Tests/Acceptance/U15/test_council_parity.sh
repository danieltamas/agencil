#!/bin/bash
# test_council_parity.sh [council-script]: replays the council scenarios against the script (default: the owner's
# council.sh, or the Agencil wrapper when COUNCIL_SCRIPT is set) and fails on any difference from the committed
# fixtures in Tests/Fixtures/council-script/. Capture them from the old script with: --capture <old-script>.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fixtures=$here/../../Fixtures/council-script
if [[ ${1:-} == --capture ]]; then
  bash "$here/council-scenarios.sh" "$2" "$fixtures"
  exit $?
fi
script=${1:-${COUNCIL_SCRIPT:-}}
[[ -f $script ]] || { echo "usage: $0 <council-script> | --capture <old-script>" >&2; exit 64; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
bash "$here/council-scenarios.sh" "$script" "$work"
diff -r "$fixtures" "$work" --exclude=stubs && echo "council parity: ok"
