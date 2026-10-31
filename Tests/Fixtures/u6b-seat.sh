#!/bin/sh
kind=${0##*/}
if [ "$1" = --version ]; then echo "$kind 0.9.4"; exit 0; fi
if [ "$1 $2" = 'login status' ]; then echo 'Logged in using test'; exit 0; fi
if [ "$1 $2" = 'auth status' ]; then echo '{"loggedIn":true}'; exit 0; fi
eval 'plan=$STUB_PLAN_'"$kind"
record=$STUB_RECORD.$kind
printf '%s\n' "$$" >> "$STUB_RECORD.pids"
printf '%s' "$AGENCIL_CAP" > "$record.cap"
printf '%s\n' "$kind" >> "$STUB_RECORD.events"
set -- "$@"
answer_file=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then shift; answer_file=$1; break; fi
    shift
done
mode=${plan%%:*}
target=${plan#*:}
# A detached root may reach this seat again; do not detach indefinitely.
if [ "$mode" = detached ] && ! /bin/mkdir "$record.once" 2>/dev/null; then mode=leaf; fi
case "$mode" in
    hold)
        while [ ! -f "$STUB_RECORD.release" ]; do /bin/sleep 0.02; done
        ;;
    leaf) ;;
    *)
        if [ "$mode" = replace ]; then
            n=0
            while [ ! -s "$STUB_RECORD.hermes.cap" ] && [ "$n" -lt 500 ]; do
                /bin/sleep 0.02; n=$((n + 1))
            done
            AGENCIL_CAP=$(/bin/cat "$STUB_RECORD.hermes.cap")
            export AGENCIL_CAP
        fi
        if [ "$mode" = mcp ]; then
            {
                printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stub","version":"1"}}}'
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
                printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{"target":"%s","question":"nested","wait_seconds":10}}}\n' "$target"
            } | "$STUB_CLI" mcp --caller owner > "$record.out" 2> "$record.err"
        elif [ "$mode" = detached ]; then
            # Same-user limit: a reparented process without a cap is a new root.
            /usr/bin/perl -MPOSIX -e '
                exit if fork; POSIX::setsid(); exit if fork;
                delete $ENV{AGENCIL_CAP};
                open STDOUT, ">", "$ENV{STUB_RECORD}.detached.out" or die;
                open STDERR, ">", "$ENV{STUB_RECORD}.detached.err" or die;
                open P, ">", "$ENV{STUB_RECORD}.detached.pid" or die;
                print P "$$\n"; close P;
                sleep 1;
                system($ENV{STUB_CLI}, "ask", $ARGV[0], "detached", "--wait", "10", "--json");
                open E, ">", "$ENV{STUB_RECORD}.detached.exit" or die;
                print E ($? >> 8); close E;
            ' "$target"
            echo detached > "$record.out"
        elif [ "$mode" = stripped ]; then
            /usr/bin/env -i AGENCIL_HOME="$AGENCIL_HOME" "$STUB_CLI" ask "$target" nested --wait 10 --json > "$record.out" 2> "$record.err"
        else
            "$STUB_CLI" ask "$target" nested --as owner --wait 10 --json > "$record.out" 2> "$record.err"
        fi
        code=$?
        printf '%s' "$code" > "$record.exit"
        if [ "$mode" = followup ] && [ "$code" = 0 ]; then
            thread=$(/usr/bin/plutil -extract data.thread raw -o - "$record.out")
            "$STUB_CLI" ask "$target" followup --thread "$thread" --wait 10 --json > "$record.followup.out" 2> "$record.followup.err"
            printf '%s' "$?" > "$record.followup.exit"
        fi
        ;;
esac
answer="u6b $kind"
if [ -f "$record.out" ]; then answer="$answer exit=$(/bin/cat "$record.exit") $(/bin/cat "$record.out") $(/bin/cat "$record.err")"; fi
if [ -f "$record.followup.out" ]; then answer="$answer $(/bin/cat "$record.followup.out")"; fi
if [ -n "$answer_file" ]; then printf '%s' "$answer" > "$answer_file"; else printf '%s' "$answer"; fi
