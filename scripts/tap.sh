#!/usr/bin/env bash
# Points the Homebrew cask (danieltamas/homebrew-tap, Casks/agencil.rb, created from scripts/agencil.cask.rb on the first release) at a published release:
# version and sha256 from dist/SHA256SUMS, checked against the bytes GitHub serves before anything
# is committed, one commit on the tap's main, then `brew fetch` proves the cask installs from the
# tap. Runs from the release's verify step (docs/RELEASE.md).
#   scripts/tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>]
set -euo pipefail

fail() { echo "tap: $*" >&2; exit 1; }

version=${1:-}; shift || true
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>]"
sums=dist/SHA256SUMS
tap=${AGENCIL_TAP_DIR:-${TMPDIR:-/tmp}/agencil-tap}
while (($#)); do
  case $1 in
    --sums) sums=$2; shift ;;
    --tap) tap=$2; shift ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

asset=Agencil-$version-adhoc.zip
url=https://github.com/danieltamas/agencil/releases/download/v$version/$asset
sha=$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")
[[ $sha =~ ^[0-9a-f]{64}$ ]] || fail "no checksum for $asset in $sums"

# The pin is checked against what GitHub serves, not against the local build: a replaced asset or a
# stale SHA256SUMS must stop here, before the tap changes.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agencil-tap-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/$asset" "$url" || fail "cannot download $url; publish the release first"
served=$(shasum -a 256 "$scratch/$asset" | awk '{ print $1 }')
[[ $served == "$sha" ]] || fail "$asset served by GitHub has sha256 $served, SHA256SUMS says $sha: not pinning"

# A hard reset only on a checkout that is the tap and has nothing uncommitted to lose.
sync_to_origin() {
  local dir=$1 url status
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || fail "$dir has no origin remote: not resetting it"
  case $url in
    https://github.com/danieltamas/homebrew-tap|https://github.com/danieltamas/homebrew-tap.git|git@github.com:danieltamas/homebrew-tap.git) ;;
    *) fail "$dir is not a checkout of danieltamas/homebrew-tap ($url): not resetting it" ;;
  esac
  status=$(git -C "$dir" status --porcelain) || fail "cannot read the state of $dir: not resetting it"
  [[ -z $status ]] || fail "$dir has uncommitted changes: commit or discard them first"
  git -C "$dir" fetch -q origin main || fail "cannot fetch the tap into $dir"
  # Commits that are not on origin/main would vanish with the reset.
  git -C "$dir" merge-base --is-ancestor HEAD origin/main || fail "$dir has commits that are not on origin/main: not resetting it"
  git -C "$dir" reset -q --hard origin/main
}

if [[ -d $tap/.git ]]; then
  sync_to_origin "$tap"
else
  gh repo clone danieltamas/homebrew-tap "$tap" -- -q
fi
cask=$tap/Casks/agencil.rb
# The first release creates the cask from the reviewed template; later ones only move the pins.
if [[ ! -f $cask ]]; then
  mkdir -p "$tap/Casks"
  cp "$(dirname "$0")/agencil.cask.rb" "$cask"
fi
# Only the two pinned lines change; the stanza order, comments and steps stay as reviewed.
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sha\"" "$cask" || fail "the cask did not take the new pins"

if git -C "$tap" diff --quiet; then
  echo "tap: agencil $version already pinned"
else
  git -C "$tap" commit -q -am "agencil $version" --author "Daniel Tamas <hello@danieltamas.ro>"
  git -C "$tap" push -q origin main
  echo "tap: pushed agencil $version ($sha)"
fi

# What a user's Homebrew does with the pushed cask. Homebrew 7 loads a third-party cask outside
# `install` only once it is trusted; this is our own tap.
command -v brew >/dev/null || fail "brew is not installed here, so the cask was pushed but not fetched through Homebrew"
brew tap -q danieltamas/tap >/dev/null
# The local tap checkout is moved to the pushed commit itself: a stale checkout would make
# `brew fetch` validate the previous cask and call it a pass.
tapped=$(brew --repository danieltamas/tap)
sync_to_origin "$tapped" \
  || fail "could not update Homebrew's checkout of the tap at $tapped"
grep -q "sha256 \"$sha\"" "$tapped/Casks/agencil.rb" || fail "Homebrew's checkout of the tap does not carry the pushed pin"
brew trust --cask danieltamas/tap/agencil >/dev/null
brew fetch -q --cask danieltamas/tap/agencil >/dev/null || fail "brew fetch rejected the pushed cask"
echo "tap: brew fetch ok: brew install --cask danieltamas/tap/agencil"
