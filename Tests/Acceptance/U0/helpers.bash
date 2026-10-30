#!/usr/bin/env bash
# Shared test support. All mutations and build products stay in a disposable copy.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
fail() { echo "FAIL: $*" >&2; exit 1; }
require_file() { [[ -f $1 ]] || fail "missing file: $1"; }
require_exec() { [[ -x $1 ]] || fail "missing executable: $1"; }
workspace() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/agencil-u0.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/repo"
  tar -C "$ROOT" --exclude=.git --exclude=.build --exclude=build --exclude=dist \
    --exclude=.local -cf - . | tar -C "$WORK/repo" -xf -
  cd "$WORK/repo"
  # Source stamping and release exports need a real, clean repository snapshot.
  git init -q
  git add .
  git -c user.name='Acceptance Test' -c user.email='test@example.invalid' \
    -c commit.gpgsign=false commit -qm 'test: candidate snapshot'
  git tag v0.0.1
}
macos() { [[ $(uname -s) == Darwin ]] || fail 'requires macOS'; }
bundle() {
  require_exec scripts/bundle.sh
  scripts/bundle.sh --identity - --version 0.0.1 --build 1 \
    --scratch "$WORK/scratch" --out "$WORK/bundle"
  APP=$WORK/bundle/Agencil.app
  [[ -d $APP ]] || fail 'bundle.sh produced no Agencil.app'
}
