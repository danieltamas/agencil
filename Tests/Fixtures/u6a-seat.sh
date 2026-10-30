#!/bin/sh
kind=${0##*/}
# Each installed copy can have a different literal version.
version=0.9.4
if [ "$1" = --version ]; then echo "$kind $version"; exit 0; fi
if [ "$1 $2" = 'login status' ]; then
    case "$STUB_MODE" in *codex-out*) echo 'Not logged in'; exit 1;; esac
    echo 'Logged in using test'; exit 0
fi
if [ "$1 $2" = 'auth status' ]; then
    case "$STUB_MODE" in *claude-out*) echo '{"loggedIn":false}'; exit 1;; esac
    echo '{"loggedIn":true}'; exit 0
fi
printf '%s\n' "$@" > "$STUB_RECORD"
printf '%s\n' "$#" > "$STUB_RECORD.argc"
printf '%s\n' "$kind" > "$STUB_RECORD.kind"
printf '%s\n' "$kind" >> "$STUB_RECORD.events"
printf '%s\n' "$0" > "$STUB_RECORD.exe"
printf '%s\n' "$PWD" > "$STUB_RECORD.cwd"
printf '%s\n' "$OPENCODE_CONFIG" > "$STUB_RECORD.config"
if [ -n "$OPENCODE_CONFIG" ]; then /bin/cat "$OPENCODE_CONFIG" > "$STUB_RECORD.policy"; fi
input=$(/bin/cat)
if [ -z "$input" ]; then echo empty-closed > "$STUB_RECORD.stdin"; else echo nonempty > "$STUB_RECORD.stdin"; fi
/bin/sleep 120 &
child=$!
printf '%s\n%s\n' "$$" "$child" > "$STUB_RECORD.pids"
printf '%s\n%s\n' "$$" "$child" >> "$STUB_RECORD.allpids"
case "$STUB_MODE" in
    *slow*) /bin/sleep 3;;
    *stop*) wait "$child";;
esac
case "$STUB_MODE" in *fail*) kill "$child"; wait "$child" 2>/dev/null; echo 'u6a deliberate failure' >&2; exit 17;; esac
answer='u6a answer'
if [ "$kind" = codex ]; then
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; printf '%s' "$answer" > "$1"; break; fi
        shift
    done
else
    printf '%s' "$answer"
fi
# Leave the group child for Agencil to reap on successful completion too.
exit 0
