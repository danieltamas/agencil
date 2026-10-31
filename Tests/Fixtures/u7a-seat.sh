#!/bin/sh
# Only the test control directory and the seat's run directory are touched.
kind=${0##*/}
if [ "$1" = --version ]; then echo "$kind 0.9.4"; exit 0; fi
if [ "$1 $2" = 'login status' ] || [ "$1 $2" = 'auth status' ]; then
    if [ -f "$STUB_DIR/$kind.signed-out" ]; then
        if [ "$kind" = codex ]; then echo 'Not logged in'; else echo '{"loggedIn":false}'; fi
        exit 1
    fi
    if [ "$kind" = codex ]; then echo 'Logged in using test'; else echo '{"loggedIn":true}'; fi
    exit 0
fi
output= previous= prompt=
for arg in "$@"; do
    if [ "$previous" = -o ]; then output=$arg; fi
    previous=$arg
    prompt=$arg
done
if [ "$kind" = claude ]; then prompt=$2; fi
if [ "$kind" = hermes ]; then
    previous=
    for arg in "$@"; do
        if [ "$previous" = -q ]; then prompt=$arg; break; fi
        previous=$arg
    done
fi
seat=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^SEAT: //p' | /usr/bin/head -1)
round=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^ROUND: //p' | /usr/bin/head -1)
retry=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^RETRY: //p' | /usr/bin/head -1)
[ -n "$seat" ] || seat=$kind
[ -n "$round" ] || round=ask
key=$seat.$round
[ -z "$retry" ] || key=$key.retry
while ! /bin/mkdir "$STUB_DIR/lock" 2>/dev/null; do /bin/sleep 0.01; done
n=0
[ ! -f "$STUB_DIR/counter" ] || n=$(/bin/cat "$STUB_DIR/counter")
n=$((n + 1))
printf '%s' "$n" > "$STUB_DIR/counter"
record=$STUB_DIR/record.$n.$key
printf '%s' "$prompt" > "$record.prompt"
printf '%s\n' "$@" > "$record.argv"
printf '%s\n' "$PWD" > "$record.cwd"
printf '%s\n' "$$" > "$record.pid"
printf '%s\n' "$n start $$ $seat $round" >> "$STUB_DIR/events"
/bin/rmdir "$STUB_DIR/lock"
if [ "$round" = rebuttal ] && [ -n "$STUB_LEDGER" ]; then
    /usr/bin/sqlite3 -readonly "$STUB_LEDGER" 'SELECT id,run_id FROM claims;' > "$record.ledger"
fi
if [ -f "$STUB_DIR/$key.hold" ]; then
    while [ ! -f "$STUB_DIR/release" ]; do /bin/sleep 0.02; done
fi
/usr/bin/find . -type f -o -type l | /usr/bin/sort > "$record.tree"
[ ! -f README ] || /bin/cat README > "$record.readme"
if [ -f "$STUB_DIR/$key.child" ]; then
    "$STUB_CLI" wake panel --brief "$STUB_DIR/child.brief" --wait 15 --json > "$record.child" 2> "$record.child-error"
    printf '%s' "$?" > "$record.child-exit"
fi
if [ -f "$STUB_DIR/$key.silent" ]; then
    /bin/sleep 120 &
    printf '%s\n' "$!" > "$record.child-pid"
    wait
fi
if [ -f "$STUB_DIR/$key.delay" ]; then /bin/sleep "$(/bin/cat "$STUB_DIR/$key.delay")"; fi
if [ -f "$STUB_DIR/$key.fail" ]; then exit 17; fi
answer=$STUB_DIR/$key
if [ ! -f "$answer" ]; then echo "missing fixture $key" >&2; exit 18; fi
if [ -n "$output" ]; then /bin/cat "$answer" > "$output"; else /bin/cat "$answer"; fi
while ! /bin/mkdir "$STUB_DIR/lock" 2>/dev/null; do /bin/sleep 0.01; done
n=$(( $(/bin/cat "$STUB_DIR/counter") + 1 ))
printf '%s' "$n" > "$STUB_DIR/counter"
printf '%s\n' "$n end $$ $seat $round" >> "$STUB_DIR/events"
/bin/rmdir "$STUB_DIR/lock"
