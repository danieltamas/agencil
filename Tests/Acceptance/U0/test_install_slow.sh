#!/usr/bin/env bash
# SLOW: builds and installs a real bundle, with a disposable HOME and install root.
source "$(dirname "$0")/helpers.bash"
macos
# MacMax's uninstall checks /Applications too. Refuse to touch a real installation.
[[ ! -e /Applications/Agencil.app && ! -L /Applications/Agencil.app ]] \
  || fail 'isolation prerequisite: /Applications/Agencil.app already exists'
workspace
require_exec install.sh
bundle
export HOME=$WORK/home
export AGENCIL_HOME=$HOME/.agencil
export AGENCIL_INSTALL_ROOT=$HOME/Applications
export TMPDIR=$WORK/tmp
mkdir -p "$HOME" "$TMPDIR" "$AGENCIL_INSTALL_ROOT"
# The install-root override is part of the sibling installer contract.
grep -F 'AGENCIL_INSTALL_ROOT' install.sh >/dev/null || fail 'missing documented install-root override'
# If an assertion fails after launch, quit and uninstall the disposable app before cleanup.
cleanup_install() {
  status=$?
  trap - EXIT
  if [[ -d $AGENCIL_INSTALL_ROOT/Agencil.app ]]; then
    ./install.sh --uninstall || true
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup_install EXIT
./install.sh --app "$APP"
require_exec "$AGENCIL_INSTALL_ROOT/Agencil.app/Contents/MacOS/Agencil"
require_exec "$HOME/.local/bin/agencil"
version=$("$HOME/.local/bin/agencil" version)
echo "$version"
printf '%s\n' "$version" | grep -Eq '(^|[^0-9.])0\.0\.1([^0-9.]|$)' || fail 'installed CLI version is not 0.0.1'
./install.sh --uninstall
[[ ! -e $AGENCIL_INSTALL_ROOT/Agencil.app && ! -L $AGENCIL_INSTALL_ROOT/Agencil.app ]] || fail 'app remains after uninstall'
[[ ! -e $HOME/.local/bin/agencil && ! -L $HOME/.local/bin/agencil ]] || fail 'CLI remains after uninstall'
