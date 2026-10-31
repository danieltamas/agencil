#!/bin/sh
# A real executable boundary; responses and failures are controlled by fixture files.
printf '%s\n' "$PWD" > "$STUB_DIR/gh.cwd"
printf '%s\n' "$@" > "$STUB_DIR/gh.argv"
[ "$#" = 10 ] || exit 91
[ "$1 $2 $3 $4 $5" = 'pr list --state open --label' ] || exit 92
[ "$7 $8 $9" = '--json number,headRefOid --limit' ] || exit 93
[ "${10}" = 100 ] || exit 94
if [ -f "$STUB_DIR/gh.fail" ]; then exit 17; fi
if [ -f "$STUB_DIR/gh.garbage" ]; then printf 'not json\n'; exit 0; fi
exec /bin/cat "$STUB_DIR/gh.json"
