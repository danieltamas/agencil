#!/usr/bin/env bash
source "$(dirname "$0")/helpers.bash"
workspace
for name in perf acceptance e2e live-smoke; do
  script=scripts/$name.sh
  require_exec "$script"
  if "$script" > "$WORK/$name.log" 2>&1; then
    fail "$script returned success before implementation"
  fi
  cat "$WORK/$name.log"
  grep -iF 'not implemented' "$WORK/$name.log" || fail "$script did not say not implemented"
done
