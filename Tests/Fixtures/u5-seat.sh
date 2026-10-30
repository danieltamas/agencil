#!/bin/sh
# Perl supplies subsecond wall time; the shell's PID remains the launcher's exec PID.
stamp=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
if [ "$1" = stubborn ]; then
    /bin/sh -c 'trap "" TERM; echo ready > "$CHILD_READY"; exec /bin/sleep 120' &
else
    /bin/sleep 120 &
fi
child=$!
if [ "$1" = stubborn ]; then
    while [ ! -f "$CHILD_READY" ]; do /bin/sleep 0.01; done
fi
printf '%s %s %s\n' "$$" "$stamp" "$child" > "$MARKER"
if [ "$1" = orphan ]; then exit 0; fi
wait "$child"
