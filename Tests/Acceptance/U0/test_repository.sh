#!/usr/bin/env bash
source "$(dirname "$0")/helpers.bash"
cd "$ROOT"
for file in LICENSE SECURITY.md CONTRIBUTING.md LOG.md README.md .release.json \
  .github/workflows/ci.yml .github/workflows/release-verify.yml \
  Support/Info.plist Support/toolchain; do
  require_file "$file"
done
grep -F 'MIT License' LICENSE >/dev/null || fail 'LICENSE is not MIT'
grep -F 'Permission is hereby granted, free of charge' LICENSE >/dev/null || fail 'MIT grant missing'
[[ $(head -n 1 LOG.md) == '## Unreleased' ]] || fail 'LOG.md must start with ## Unreleased'
[[ -d .github/ISSUE_TEMPLATE ]] || fail 'missing ISSUE_TEMPLATE directory'
[[ -n $(find .github/ISSUE_TEMPLATE -type f -print) ]] || fail 'empty ISSUE_TEMPLATE'
[[ -f .github/pull_request_template.md || -f .github/PULL_REQUEST_TEMPLATE.md \
  || -f .github/PULL_REQUEST_TEMPLATE ]] || fail 'missing pull request template'
# Read committed blobs, not just the worktree. NUL-bearing files are binary.
python3 - <<'PYTHON'
import subprocess
paths = subprocess.check_output(['git', 'ls-tree', '-r', '-z', 'HEAD']).split(b'\0')
bad = []
for entry in paths:
    if not entry:
        continue
    metadata, path = entry.split(b'\t', 1)
    mode, kind, oid = metadata.split()
    if kind != b'blob':
        continue
    data = subprocess.check_output(['git', 'cat-file', 'blob', oid])
    if b'\0' not in data and any(byte > 127 for byte in data):
        bad.append(path.decode('utf-8', 'backslashreplace'))
if bad:
    raise SystemExit('non-ASCII committed text: ' + ', '.join(bad))
PYTHON
