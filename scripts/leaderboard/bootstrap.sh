#!/bin/bash
# bootstrap.sh <dir>: creates a local repository whose only branch is an orphan `leaderboard` with an empty data.json
# and the rendered placeholder card. It never pushes; it prints the one command the owner runs.
set -euo pipefail
dir=$1
here=$(cd "$(dirname "$0")" && pwd)
repo=${AGENCIL_LEADERBOARD_REPO:-danieltamas/agencil}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$dir"
git -C "$dir" init -q -b leaderboard
cat > "$dir/data.json" <<JSON
{
  "cells": [],
  "generated_at": "$now",
  "min_n": 20,
  "outcomes_total": 0,
  "schema": 1,
  "window": {
    "from": "$now",
    "to": "$now"
  }
}
JSON
python3 -I -B "$here/validate.py" "$dir/data.json" >/dev/null
python3 -I -B "$here/render.py" --data "$dir/data.json" --out "$dir" --today "${now%%T*}"
git -C "$dir" add -A
git -C "$dir" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "chore: bootstrap the leaderboard branch"
echo "Created $dir on branch leaderboard (not pushed). To publish it once, run:"
echo "cd $dir && git push https://github.com/$repo.git leaderboard"
