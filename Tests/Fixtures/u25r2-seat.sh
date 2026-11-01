#!/bin/sh
# All observations stay in the per-test control directory.
kind=${0##*/}
printf '%s\n' "$kind $*" >> "$STUB_DIR/invocations"
if [ "$1" = --version ]; then echo "$kind 0.9.4"; exit 0; fi
if [ "$1 $2" = 'login status' ] || [ "$1 $2" = 'auth status' ]; then
    if [ -f "$STUB_DIR/$kind.signed-out" ]; then
        if [ "$kind" = codex ]; then echo 'Not logged in'; else echo '{"loggedIn":false}'; fi
        exit 1
    fi
    if [ "$kind" = codex ]; then echo 'Logged in using test'; else echo '{"loggedIn":true}'; fi
    exit 0
fi
if [ "$1" = models ]; then
    if [ "$kind" = opencode ] && [ -f "$STUB_DIR/opencode.models" ]; then
        /bin/cat "$STUB_DIR/opencode.models"
    fi
    exit 0
fi
output= previous= prompt= model=
for arg in "$@"; do
    if [ "$previous" = -o ]; then output=$arg; fi
    if [ "$previous" = --model ] || [ "$previous" = -m ]; then model=$arg; fi
    prompt=$arg
    previous=$arg
done
if [ "$kind" = claude ] || [ "$kind" = hermes ]; then
    previous=
    for arg in "$@"; do
        if [ "$previous" = -p ] || [ "$previous" = -q ]; then prompt=$arg; break; fi
        previous=$arg
    done
fi
seat=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^SEAT: //p' | /usr/bin/head -1)
round=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^ROUND: //p' | /usr/bin/head -1)
retry=$(printf '%s\n' "$prompt" | /usr/bin/sed -n 's/^RETRY: //p' | /usr/bin/head -1)
[ -n "$seat" ] || seat=$kind
[ -n "$round" ] || round=ask
if [ "$prompt" = 'Reply with exactly: OK' ]; then round=probe; fi
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
printf '%s\n' "$output" > "$record.output"
printf '%s\n' "$$" > "$record.pid"
/bin/date +%s > "$record.start"
/bin/rmdir "$STUB_DIR/lock"
trap '/bin/date +%s > "$record.end"' 0
input=$(/bin/cat)
if [ -z "$input" ]; then echo empty-closed > "$record.stdin"; else echo nonempty > "$record.stdin"; fi
if [ -f "$STUB_DIR/$key.child" ]; then
    "$STUB_CLI" wake panel --brief "$STUB_DIR/child.brief" --wait 15 --json > "$record.child" 2> "$record.child-error"
    printf '%s' "$?" > "$record.child-exit"
fi
mode=answer
[ "$round" != probe ] || mode=ok
if [ -f "$STUB_DIR/$seat.mode" ]; then mode=$(/bin/cat "$STUB_DIR/$seat.mode"); fi
modelkey=$(printf '%s' "$model" | /usr/bin/tr / _)
if [ -f "$STUB_DIR/model.$modelkey.mode" ]; then mode=$(/bin/cat "$STUB_DIR/model.$modelkey.mode"); fi
case "$mode" in
    usage-limit) echo "You've hit your usage limit. Visit settings to purchase more credits or try again at Oct 9" >&2; exit 1;;
    no-credit) echo 'Insufficient balance' >&2; exit 1;;
    model-gone) echo '{"name":"UnknownError","data":{"message":"Unexpected server error."}}' >&2; exit 1;;
    busy) echo 'database is locked' >&2; exit 1;;
    hang) /bin/sleep 120; exit 1;;
    secret) echo 'sk-abcdefghijklmnopqrstuvwx' >&2; exit 1;;
    ok) answer=OK;;
    answer)
        if [ -f "$STUB_DIR/$seat.$round.delay" ]; then
            /bin/sleep "$(/bin/cat "$STUB_DIR/$seat.$round.delay")"
        fi
        if [ -f "$STUB_DIR/$seat.$round.child-preflight" ]; then
            /bin/cat "$STUB_DIR/counter" > "$record.before-child"
            "$STUB_CLI" preflight --probe --json > "$record.child" 2> "$record.child-error"
            printf '%s' "$?" > "$record.child-exit"
            /bin/cat "$STUB_DIR/counter" > "$record.after-child"
        fi
        file=$STUB_DIR/$key
        [ -f "$file" ] || file=$STUB_DIR/$seat.$round
        if [ ! -f "$file" ]; then echo 'missing answer fixture' >&2; exit 18; fi
        answer=$(/bin/cat "$file");;
    *) echo 'unknown fixture mode' >&2; exit 18;;
esac
if [ "$kind" = codex ] && [ -n "$output" ]; then printf '%s' "$answer" > "$output"; fi
printf '%s\n' "$answer"
