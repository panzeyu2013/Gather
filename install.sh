#!/usr/bin/env bash
set -euo pipefail

# Gather v3.0 — Electron desktop app build & install.
# For end users: download the pre-built .dmg from releases.
# For developers: use this script to build from source.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="${SCRIPT_DIR}/desktop"

echo "=== Gather v3.0 Installer ==="
echo ""

if ! command -v npm &>/dev/null; then
  echo "ERROR: npm is required. Install Node.js from https://nodejs.org"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required."
  exit 1
fi

PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [ "$(python3 -c "import sys; print(1 if sys.version_info >= (3,10) else 0)")" != "1" ]; then
  echo "ERROR: Python >= 3.10 is required. Found: $PY_VERSION"
  exit 1
fi

if ! command -v uv &>/dev/null; then
  echo "ERROR: uv is required. Install from https://docs.astral.sh/uv/getting-started/installation/"
  exit 1
fi

echo "Installing Python dependencies..."
cd "${SCRIPT_DIR}"
uv sync --dev

echo ""
echo "Installing Node.js dependencies..."
cd "${SCRIPT_DIR}"
npm install

echo ""
echo "Building..."
npm run build --workspace=desktop

echo ""
echo "Done! To package as .dmg:"
echo "  npm run dist:mac --workspace=desktop"

echo "To start in development mode:"
echo "  cd desktop && npm run dev"
