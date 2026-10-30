#!/usr/bin/env bash
# Fast boundary probes use MacMax's documented --root and --lint-only flags.
source "$(dirname "$0")/helpers.bash"
workspace
require_exec scripts/check.sh
scripts/check.sh --lint-only
mkdir -p Sources docs
awk 'BEGIN { for (i=1; i<=501; i++) print "// acceptance line" }' > Sources/U0LineViolation.swift
if scripts/check.sh --lint-only > "$WORK/lines.log" 2>&1; then
  fail 'check.sh accepted a 501-line Swift file'
fi
cat "$WORK/lines.log"
grep -F 'U0LineViolation.swift' "$WORK/lines.log" || fail 'line violation did not name file'
rm Sources/U0LineViolation.swift
# Construct UTF-8 at runtime so the committed test itself stays ASCII.
printf '\342\200\234quote\n' > docs/U0QuoteViolation.md
if scripts/check.sh --lint-only > "$WORK/quote.log" 2>&1; then
  fail 'check.sh accepted a curly quote in docs/'
fi
cat "$WORK/quote.log"
grep -F 'U0QuoteViolation.md' "$WORK/quote.log" || fail 'quote violation did not name file'
rm docs/U0QuoteViolation.md
scripts/check.sh --lint-only
