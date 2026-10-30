#!/bin/bash
# Regenerates Sources/AgencilCore/Harness/CatalogData.swift from catalog.json (the installed CLI is one file,
# so the catalog travels inside it). `--check` only compares and fails when they differ.
set -euo pipefail
cd "$(dirname "$0")/.."
json=Sources/AgencilCore/Harness/catalog.json
out=Sources/AgencilCore/Harness/CatalogData.swift
temp=$(mktemp)
{
  echo '// Generated from catalog.json by scripts/sync-catalog.sh; scripts/check.sh fails when the two differ.'
  echo 'enum CatalogData {'
  echo '    static let json = #"""'
  cat "$json"
  echo '"""#'
  echo '}'
} > "$temp"
if [[ ${1:-} == --check ]]; then
  diff -q "$temp" "$out" >/dev/null || { rm -f "$temp"; echo "catalog: CatalogData.swift is stale, run scripts/sync-catalog.sh" >&2; exit 1; }
  rm -f "$temp"
else
  mv "$temp" "$out"
fi
