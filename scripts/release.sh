#!/usr/bin/env bash
# Builds the release zip for a tag: Agencil-X.Y.Z-adhoc.zip, universal and ad hoc signed, the same bytes every
# time (like Bton and RMJ; no certificate is involved). Writes it and dist/SHA256SUMS; publishing is the owner's step.
#   release.sh <X.Y.Z> [--verify] [--adhoc-only] [--out <dir>] [--scratch <dir>] [--ref <rev>]
#   --verify   builds a second time somewhere else and fails if one byte of the zip differs
#   --adhoc-only  accepted and ignored: ad hoc is the only way a release is signed
#   --out      where the zip and SHA256SUMS go (default dist/)
#   --scratch  where the build trees go (default $HOME/.cache/agencil-release; never inside the repo)
#   --ref      build this revision instead of the tag vX.Y.Z (a trial run: the output says it is not a release)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"

fail() { echo "release: $*" >&2; exit 1; }

version=${1:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: release.sh <X.Y.Z> [--verify] [--out <dir>] [--scratch <dir>] [--ref <rev>]"
shift
verify=0
out=$repo/dist
scratch=$HOME/.cache/agencil-release
ref=v$version
while (($#)); do
  case $1 in
    --verify) verify=1 ;;
    --adhoc-only) ;;
    --out) out=$2; shift ;;
    --scratch) scratch=$2; shift ;;
    --ref) ref=$2; shift ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

[[ -z $(git status --porcelain) ]] || fail "the working tree is not clean"
[[ $(git rev-parse --is-shallow-repository) == false ]] || fail "a shallow clone gives another build number: fetch the full history"
commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null) || fail "$ref does not exist"
[[ $commit == "$(git rev-parse HEAD)" ]] || fail "HEAD is not $ref: check out the revision to release"
pin=$(awk '$1 == "xcode-build" { print $2 }' Support/toolchain)
have=$(xcodebuild -version | awk '/^Build version/ { print $3 }')
[[ -n $pin && $pin == "$have" ]] || fail "Xcode build is '$have', this release is pinned to '$pin' (Support/toolchain)"

epoch=$(git log -1 --format=%ct "$commit")
number=$(git rev-list --count "$commit")
stamp=$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)

# Fixed modes, no extended attributes, the tag's time on every file, then a zip with sorted entries, no extra
# attributes and no directory entries: the same input gives the same zip. $1 the app, $2 the zip.
pack() {
  local app=$1 zip=$2
  # Each step is checked: pack runs as the condition of an `||`, where errexit is off.
  chmod -R u=rwX,go=rX "$app" || return 1
  xattr -cr "$app" || return 1
  find "$app" -print0 | TZ=UTC xargs -0 touch -h -t "$stamp" || return 1
  rm -f "$zip" || return 1
  (cd "$(dirname "$app")" && find Agencil.app | LC_ALL=C sort | TZ=UTC zip -q -X -D -y "$zip" -@)
}

# One build from a clean export of the revision, in $1. Prints the zip path.
build_zip() {
  local dir=$1 app zip
  rm -rf "$dir"
  mkdir -p "$dir/src"
  git archive "$commit" | tar -x -C "$dir/src"
  app=$(cd "$dir/src" && SOURCE_DATE_EPOCH=$epoch scripts/bundle.sh --universal --version "$version" --build "$number" \
    --source "$ref" --scratch "$dir/scratch" --out "$dir/out") || fail "the build failed"
  [[ -d $app ]] || fail "the build produced no app"
  zip=$dir/Agencil-$version-adhoc.zip
  pack "$app" "$zip" || fail "could not pack $zip"
  [[ -s $zip ]] || fail "$zip is empty"
  echo "$zip"
}

first=$(build_zip "$scratch/a")
if ((verify)); then
  second=$(build_zip "$scratch/b")
  cmp "$first" "$second" || fail "two builds of $ref differ: the release is not reproducible"
  echo "release: two builds are identical"
fi

mkdir -p "$out"
cp "$first" "$out/Agencil-$version-adhoc.zip"
(cd "$out" && shasum -a 256 "Agencil-$version-adhoc.zip" > SHA256SUMS)
echo "release: $out/Agencil-$version-adhoc.zip (reproducible)"
cat "$out/SHA256SUMS"
[[ $ref == "v$version" ]] || echo "release: NOT A RELEASE: built from $ref, not the tag v$version" >&2
