#!/usr/bin/env bash
# P3-5：Sources 严格告警门禁。
# 只构建 Sources（lib/exec）；测试 target 的告警不在此门禁内。
# 用法：./scripts/check-warnings.sh [core|app|all]（默认 all）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-all}"
case "$TARGET" in
    core|app|all) ;;
    *) echo "check-warnings: 未知目标 ${TARGET}（core|app|all）" >&2; exit 2 ;;
esac

if [ "$TARGET" = "core" ] || [ "$TARGET" = "all" ]; then
    echo "== gather-core：Sources -warnings-as-errors"
    swift build --package-path desktop/native/gather-core --disable-sandbox \
        -Xswiftc -warnings-as-errors \
        --explicit-target-dependency-import-check error
fi

if [ "$TARGET" = "app" ] || [ "$TARGET" = "all" ]; then
    echo "== gather-app：Sources -warnings-as-errors"
    swift build --package-path desktop/native/gather-app --disable-sandbox \
        -Xswiftc -warnings-as-errors \
        --explicit-target-dependency-import-check error
fi

echo "check-warnings: PASS"
