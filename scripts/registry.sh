#!/usr/bin/env bash
# Makes sure danieltamas/registry lists Agencil before the release pings it: when apps.json has no entry for
# danieltamas/agencil, the reviewed entry (scripts/registry-entry.json) and its icon (Brand/registry-icon.png)
# are committed to the registry's main after scripts/validate.py accepts them. An existing entry is never touched;
# the version is not written here, the registry's refresh reads it from the GitHub release.
#   scripts/registry.sh [--registry <dir>]
set -euo pipefail

fail() { echo "registry: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
dir=${AGENCIL_REGISTRY_DIR:-${TMPDIR:-/tmp}/agencil-registry}
while (($#)); do
  case $1 in
    --registry) dir=$2; shift ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

if [[ -d $dir/.git ]]; then
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || fail "$dir has no origin remote"
  case $url in
    https://github.com/danieltamas/registry|https://github.com/danieltamas/registry.git|git@github.com:danieltamas/registry.git) ;;
    *) fail "$dir is not a checkout of danieltamas/registry ($url): not resetting it" ;;
  esac
  [[ -z $(git -C "$dir" status --porcelain) ]] || fail "$dir has uncommitted changes: commit or discard them first"
  git -C "$dir" fetch -q origin main || fail "cannot fetch the registry into $dir"
  git -C "$dir" merge-base --is-ancestor HEAD origin/main || fail "$dir has commits that are not on origin/main: not resetting it"
  git -C "$dir" reset -q --hard origin/main
else
  gh repo clone danieltamas/registry "$dir" -- -q
fi

if jq -e '.apps[] | select(.repo == "danieltamas/agencil")' "$dir/apps.json" >/dev/null; then
  echo "registry: agencil already listed"
  exit 0
fi

jq --slurpfile entry "$here/scripts/registry-entry.json" '.apps += [$entry[0] + {latest: null}]' "$dir/apps.json" > "$dir/apps.json.new" \
  || fail "cannot add the entry"
mv "$dir/apps.json.new" "$dir/apps.json"
cp "$here/Brand/registry-icon.png" "$dir/icons/agencil.png"
(cd "$dir" && python3 scripts/validate.py) || fail "the registry's validate.py refused the entry"
git -C "$dir" add apps.json icons/agencil.png
git -C "$dir" commit -q -m "feat: list Agencil" --author "Daniel Tamas <hello@danieltamas.ro>"
git -C "$dir" push -q origin main
echo "registry: listed agencil"
