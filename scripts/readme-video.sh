#!/usr/bin/env bash
# The README opens with the launch film, as MacMax, Bton and RMJ do: a github.com/user-attachments URL on its own
# line, the only form GitHub plays inline (it can only be made by dragging the mp4 into the GitHub editor). A release
# does not go out while the README lacks it, so the film is never forgotten. The film is brag-output/agencil.mp4
# (git-ignored; rebuilt by the brag workflow).
set -euo pipefail

readme=$(cd "$(dirname "$0")/.." && pwd)/README.md
if grep -qE '^https://github\.com/user-attachments/assets/[0-9a-f-]+$' "$readme"; then
  echo "readme-video: ok"
  exit 0
fi
echo "readme-video: README.md has no inline film. Drag brag-output/agencil.mp4 into the GitHub editor of README.md," >&2
echo "readme-video: paste the user-attachments URL on its own line where the poster link is, then release again." >&2
exit 1
