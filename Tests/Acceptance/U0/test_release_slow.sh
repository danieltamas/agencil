#!/usr/bin/env bash
# SLOW: two independent universal release builds, with real ad hoc signatures.
source "$(dirname "$0")/helpers.bash"
macos
workspace
require_exec scripts/release.sh
scripts/release.sh 0.0.1 --verify --adhoc-only --scratch "$WORK/release" --out "$WORK/dist"
first=$WORK/release/a/Agencil-0.0.1-adhoc.zip
second=$WORK/release/b/Agencil-0.0.1-adhoc.zip
require_file "$first"
require_file "$second"
cmp "$first" "$second"
cmp "$first" "$WORK/dist/Agencil-0.0.1-adhoc.zip"
(cd "$WORK/dist" && shasum -a 256 -c SHA256SUMS)
for side in a b; do
  mkdir "$WORK/unpacked-$side"
  ditto -x -k "$WORK/release/$side/Agencil-0.0.1-adhoc.zip" "$WORK/unpacked-$side"
  app=$WORK/unpacked-$side/Agencil.app
  for signed in "$app/Contents/Resources/agencil" "$app"; do
    codesign --verify --strict "$signed"
    codesign -dvv "$signed" > "$WORK/signature.log" 2>&1
    grep -F 'Signature=adhoc' "$WORK/signature.log" || fail 'release is not ad hoc signed'
  done
done
