#!/bin/bash
# Regenerates Sources/AgencilCore/Leaderboard/PublicModelsData.swift from scripts/leaderboard/public-models.json and
# public-aliases.json (the app ships the lists CI validates against). `--check` only compares and fails when they differ.
set -euo pipefail
cd "$(dirname "$0")/.."
out=Sources/AgencilCore/Leaderboard/PublicModelsData.swift
temp=$(mktemp)
{
  echo '// Generated from scripts/leaderboard/*.json by scripts/sync-public-models.sh; scripts/check.sh fails when they differ.'
  echo 'enum PublicModelsData {'
  echo '    static let models: Set<String> = ['
  jq -r '.models[] | select(.publishable == true) | "        \"" + .id + "\","' scripts/leaderboard/public-models.json
  echo '    ]'
  echo '    static let aliases: Set<String> = ['
  jq -r '.aliases[] | "        \"" + . + "\","' scripts/leaderboard/public-aliases.json
  echo '    ]'
  echo '}'
} > "$temp"
if [[ ${1:-} == --check ]]; then
  diff -q "$temp" "$out" >/dev/null || { rm -f "$temp"; echo "public models: PublicModelsData.swift is stale, run scripts/sync-public-models.sh" >&2; exit 1; }
  rm -f "$temp"
else
  mv "$temp" "$out"
fi
