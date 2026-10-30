#!/usr/bin/env bash
# SLOW: full clean-tree build and test gate, not only the lint subset.
source "$(dirname "$0")/helpers.bash"
macos
workspace
require_exec scripts/check.sh
scripts/check.sh --scratch "$WORK/scratch"
