#!/usr/bin/env bash
# Design-system token ratchet. See scripts/check-design-system.py.
set -euo pipefail
exec python3 "$(dirname "$0")/check-design-system.py" "$@"
