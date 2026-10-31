#!/bin/sh
# Extend the real U6d confinement only for the fixture control directory.
if [ "$1" = -f ]; then
    STUB_DIR=$(cd "$STUB_DIR" && pwd -P) || exit 1
    profile=$(/bin/cat "$2") || exit 1
    shift 2
    exec /usr/bin/sandbox-exec -p "$profile
(allow file-read* file-write* (subpath \"$STUB_DIR\"))" "$@"
fi
if [ "$1" = -p ]; then
    STUB_DIR=$(cd "$STUB_DIR" && pwd -P) || exit 1
    profile=$2
    shift 2
    exec /usr/bin/sandbox-exec -p "$profile
(allow file-read* file-write* (subpath \"$STUB_DIR\"))" "$@"
fi
exec /usr/bin/sandbox-exec "$@"
