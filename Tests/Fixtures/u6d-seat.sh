#!/bin/sh
kind=${0##*/}
if [ "$1" = --version ]; then echo "$kind 0.9.4"; exit 0; fi
if [ "$1 $2" = 'login status' ]; then
    case "$STUB_MODE" in *codex-out*) echo 'Not logged in'; exit 1;; esac
    echo 'Logged in using test'; exit 0
fi
if [ "$1 $2" = 'auth status' ]; then echo '{"loggedIn":true}'; exit 0; fi
output=
prompt=
previous=
for arg in "$@"; do
    if [ "$previous" = -o ]; then output=$arg; fi
    previous=$arg
    prompt=$arg
done
if [ "$kind" = claude ]; then prompt=$2; fi
record=$STUB_RECORD
case "$PWD" in
    */runs/*/copy) record=${PWD%/copy}/u6d;;
    */runs/*) if [ "$kind" = opencode ]; then record=$PWD/u6d; fi;;
esac
printf '%s\n' "$PWD" > "$record.cwd"
printf '%s\n' "$@" > "$record.argv"
printf '%s\n' "$#" > "$record.argc"
printf '%s' "$prompt" > "$record.prompt"
/usr/bin/find . -type f -o -type l | /usr/bin/sort > "$record.tree"
if [ -f README ]; then /bin/cat README > "$record.readme"; fi
if [ -d .agencil/briefs ]; then /bin/cat .agencil/briefs/* > "$record.briefs"; fi
if [ "$STUB_MODE" = probe ]; then
    for path in "$HOME/.ssh/id_ed25519" "../../outside" "home-link/.ssh/id_ed25519" ".git/config" "$STUB_REAL_REPO/README"; do
        if /bin/cat "$path" > "$record.read" 2>/dev/null; then
            printf 'ALLOWED %s\n' "$path" >> "$record.probes"
            /bin/cat "$record.read" >> "$record.probes"
        else printf 'DENIED %s\n' "$path" >> "$record.probes"; fi
    done
    /bin/cat "$HOME/.codex/config.toml" > "$record.config" 2>/dev/null
fi
if [ "$STUB_MODE" = fail ]; then exit 17; fi
if [ -n "$output" ]; then printf 'u6a answer' > "$output"; else printf 'u6a answer'; fi
