#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 was not found in PATH." >&2
  exit 1
fi

python3 -m venv .venv-build
. .venv-build/bin/activate
pip install --upgrade pip
pip install pyinstaller

pyinstaller \
  --onefile \
  --name lfe \
  --clean \
  --noconfirm \
  lfe

echo "Build complete: $ROOT_DIR/dist/lfe"
