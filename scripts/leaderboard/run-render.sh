#!/bin/bash
# run-render.sh <main_dir> <data_dir> <today>: validates data_dir/data.json with the trusted scripts of main_dir, then
# renders the card, LEADERBOARD.md and the history copy into data_dir. Nothing is written when validation fails,
# and nothing is ever written under main_dir.
set -euo pipefail
main=$1 data=$2 today=$3
scripts="$main/scripts/leaderboard"
python3 -I -B "$scripts/validate.py" "$data/data.json" \
  --models "$scripts/public-models.json" --aliases "$scripts/public-aliases.json" --harnesses "$scripts/harnesses.json"
python3 -I -B "$scripts/render.py" --data "$data/data.json" --out "$data" --today "$today"
