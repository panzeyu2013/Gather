#!/usr/bin/env bash
set -euo pipefail

# bundle-python.sh
# Download a standalone Python + install production deps into desktop/engine/.venv
# for bundling into the Electron .dmg.
#
# Prerequisites: uv installed (https://docs.astral.sh/uv/getting-started/installation/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$PROJECT_ROOT/desktop/engine"
PYTHON_VERSION="3.12"

echo "=== Building bundled Python environment for Gather ==="

if ! command -v uv &>/dev/null; then
  echo "ERROR: uv is required. Install from https://docs.astral.sh/uv/getting-started/installation/"
  exit 1
fi

# Clean previous venv
rm -rf "$ENGINE_DIR/.venv"

# Download a standalone, relocatable Python (cached by uv for future builds)
echo "[1/4] Downloading standalone Python $PYTHON_VERSION..."
uv python install "$PYTHON_VERSION"

# Create venv with --copies so the Python binary is copied (not symlinked)
echo "[2/4] Creating venv with --copies..."
uv venv --python "$PYTHON_VERSION" --copies "$ENGINE_DIR/.venv"

# Install only production dependencies
echo "[3/4] Installing production dependencies..."
uv pip install \
  --python "$ENGINE_DIR/.venv/bin/python" \
  numpy scipy scikit-learn Pillow imagehash mediapipe lxml msgpack

# Patch pyvenv.cfg: remove absolute home path so the venv is relocatable
echo "[4/4] Patching pyvenv.cfg for relocatability..."
sed -i '' '/^home /d' "$ENGINE_DIR/.venv/pyvenv.cfg"

# Strip cache bloat to reduce bundle size
rm -rf "$ENGINE_DIR/.venv/lib/python3.*/site-packages/pip"
rm -rf "$ENGINE_DIR/.venv/lib/python3.*/site-packages/setuptools"
rm -rf "$ENGINE_DIR/.venv/lib/python3.*/site-packages/_distutils_hack"
find "$ENGINE_DIR/.venv" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$ENGINE_DIR/.venv" -name '*.pyc' -delete

echo ""
echo "=== Done ==="
echo "Python environment: $ENGINE_DIR/.venv"
echo "Size: $(du -sh "$ENGINE_DIR/.venv" | cut -f1)"
echo "Python: $("$ENGINE_DIR/.venv/bin/python" --version)"
echo ""
echo "Now run 'cd desktop && npm run dist:mac' to build the .dmg."
