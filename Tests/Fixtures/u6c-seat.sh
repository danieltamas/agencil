#!/bin/sh
if [ "$1" = --version ]; then echo 'codex 0.9.4'; exit 0; fi
if [ "$1 $2" = 'login status' ]; then echo 'Logged in using test'; exit 0; fi
# Install before publishing the PID or ready record so recovery cannot race the trap.
if [ "$STUB_MODE" = hold-term ]; then trap '' TERM; fi
printf '%s\n' "$$" >> "$STUB_RECORD.allpids"
printf '%s\n' "$@" > "$STUB_RECORD"
output=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; output=$1; fi
    shift
done
case "$STUB_MODE" in
    hold|hold-term) while [ ! -f "$STUB_RECORD.release" ]; do /bin/sleep 0.02; done;;
    provider) printf '%s' '{"dollars":0.25,"tokens":11}' > "${output%/*}/usage.json";;
    fail) exit 17;;
esac
printf '%s' 'u6a answer' > "$output"
