#!/usr/bin/env bash
# 命令面与单一真相源门禁（docs/reviews/functional-design-review.md §7、§8.1、§9）。
# 违规项：① 同一命令注册两次（P0-1 类）② UI 调用未注册命令 ③ 阻塞桥/双执行器复活
#        ④ 归一化口径分叉 ⑤ 硬编码假确认（仅统计，供人工裁决）
# 用法：./scripts/check-command-surface.sh        （只读，无副作用）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/desktop/native/gather-app"
CORE="$ROOT/desktop/native/gather-core"
ROUTER="$APP/Sources/GatherApp/Host/SessionCommandRouter.swift"
CULLING_VIEW="$APP/Culling/CullingView.swift"
UI_DIRS=("$APP/Sources/GatherApp" "$APP/Culling" "$APP/Settings" "$APP/Export" "$APP/Duplicates" "$APP/FaceKeywording" "$APP/ControlCenter")
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

grep -oE 'case "[a-z_]+\.[a-z_]+"' "$ROUTER" | sed 's/case //' | tr -d '"' | sort > "$TMP/all"
sort -u "$TMP/all" > "$TMP/unique"
sort "$TMP/all" | uniq -d > "$TMP/dup"

# UI 侧「提到过该命令」的判定放宽到任意字符串字面量：execute/executeAsync/enqueue/
# provider 变量分发都算（旧版只认 execute("…")，会把 executeAsync 误判为死命令）。
grep -rhoE '"[a-z_]+\.[a-z_]+"' "${UI_DIRS[@]}" --include='*.swift' 2>/dev/null \
  | tr -d '"' | sort -u > "$TMP/literals"
comm -12 "$TMP/literals" "$TMP/unique" > "$TMP/called"
# ②「UI 调用了未注册命令」：旧判据 `comm -23 called unique` 恒为空（called ⊆ unique），
# 是假门禁（终审发现）。判据改为**真实调用点**：execute/executeAsync/enqueue 的首个
# 字符串实参。不能用"字面量全集"——job 类型与阶段名（face.analyze、index.scanning、
# metadata.scan、quality.score…）与命令同形，会整片误报（试过，14 个假阳性）。
# 已知局限：变量分发的命令（provider 变量）不在判据内，由 §九·二 ③ 记录。
grep -rhoE 'execute(Async)?\( *"[a-z_]+\.[a-z_]+"|enqueue\( *"[a-z_]+\.[a-z_]+"' \
  "${UI_DIRS[@]}" --include='*.swift' 2>/dev/null \
  | grep -oE '"[a-z_]+\.[a-z_]+"' | tr -d '"' | sort -u > "$TMP/invoked"
comm -23 "$TMP/invoked" "$TMP/unique" > "$TMP/unregistered"
comm -13 "$TMP/called" "$TMP/unique" > "$TMP/uncalled"

echo "命令面：注册 $(( $(wc -l < "$TMP/all") )) 个 case 标签 / $(( $(wc -l < "$TMP/unique") )) 个唯一命令；UI 字面量提到 $(( $(wc -l < "$TMP/called") )) 个"
if [ -s "$TMP/dup" ]; then
  echo "✗ 重复注册（同一命令出现在两个 switch，P0-1 类缺陷）："; sed 's/^/    /' "$TMP/dup"; FAIL=1
fi
if [ -s "$TMP/unregistered" ]; then
  echo "✗ UI 调用了未注册命令："; sed 's/^/    /' "$TMP/unregistered"; FAIL=1
fi
echo "· 无 UI 字面量提及（需裁决：死命令 or 变量拼接）：$(( $(wc -l < "$TMP/uncalled") )) 个"
sed 's/^/    /' "$TMP/uncalled"

# ③ 阻塞桥与双执行器不得复活
BRIDGE="$(grep -rn 'awaitSync\|SyncAwaitBox' "$APP" "$CORE/Sources" --include='*.swift' 2>/dev/null | grep -v '^\s*[^:]*:[0-9]*:\s*//' | grep -v '///' || true)"
if [ -n "$BRIDGE" ]; then
  echo "✗ 阻塞桥/SyncAwaitBox 复活："; echo "$BRIDGE" | sed 's/^/    /' | head -5; FAIL=1
fi
if [ -f "$CORE/Sources/GatherCore/Services/JobScheduler.swift" ] || [ -f "$CORE/Sources/GatherCore/Services/AnalysisWorker.swift" ]; then
  echo "✗ 第二套调度器复活（JobScheduler/AnalysisWorker 应为单一执行器 JobService）"; FAIL=1
fi

# ④ 归一化口径必须唯一：ScanPath 不得同时存在两个归一化入口
INDEXER="$CORE/Sources/GatherCore/Services/IndexerService.swift"
CANON="$(grep -c 'public static func canonical' "$INDEXER" || true)"
NORM="$(grep -c 'public static func normalized' "$INDEXER" || true)"
if [ "$CANON" -gt 0 ] && [ "$NORM" -gt 0 ]; then
  echo "✗ 归一化口径分叉：ScanPath 同时定义 canonical 与 normalized"; FAIL=1
fi

# ⑥ 同步/异步注册错配（P0-1 的核心类别）：
#   executeAsync 对同步注册的命令有后台队列回退（安全）；但 execute 调用**只在
#   异步 switch 注册**的命令会走 default → NOT_IMPLEMENTED。UI 侧任何 execute("x")
#   命中异步注册集合都是运行时失败，必须在合并前挡住。
ASYNC_START="$(grep -n 'public func executeAsync(' "$ROUTER" | head -1 | cut -d: -f1)"
if [ -n "$ASYNC_START" ]; then
  awk -v s="$ASYNC_START" 'NR>s' "$ROUTER" | grep -oE 'case "[a-z_]+\.[a-z_]+"' | sed 's/case //' | tr -d '"' | sort -u > "$TMP/async_reg"
  grep -rhoE 'execute[A-Za-z]*\([[:space:]]*"[a-z_]+\.[a-z_]+"' "${UI_DIRS[@]}" --include='*.swift' 2>/dev/null \
    | grep -v 'executeAsync' | sed -E 's/.*"([a-z_]+\.[a-z_]+)"/\1/' | sort -u > "$TMP/sync_calls"
  comm -12 "$TMP/sync_calls" "$TMP/async_reg" > "$TMP/bridge_mismatch"
  echo "· 异步注册 $(( $(wc -l < "$TMP/async_reg") )) 条 / UI 同步 execute 调用 $(( $(wc -l < "$TMP/sync_calls") )) 条"
  if [ -s "$TMP/bridge_mismatch" ]; then
    echo "✗ UI 用同步 execute 调用仅在 async 注册的命令（会 NOT_IMPLEMENTED）："
    sed 's/^/    /' "$TMP/bridge_mismatch"; FAIL=1
  fi
fi

# ⑤ 假确认。两类写法语义不同，判据也不同：
#    (a) 载荷形：`params["confirmed"] = .bool(true)` / `"confirmed": .bool(true)`
#        —— UI 自己向命令**声明**已确认，等价于绕过门禁。强制要求该文件内存在
#        共享确认弹窗 `gatherDestructiveConfirm`；否则是伪造确认（终审发现
#        `Export/ExportView.swift` 正是此类：无任何弹窗却无条件置 true）。
#    (b) 实参形：`confirmed: true` —— Swift 调用实参。合法写法是"只出现在确认
#        闭包/确认动作内"，静态无法判定闭包归属，故只统计并列出文件供人工裁决。
PAYLOAD_LINES="$(grep -rnE '\["confirmed"\] *= *\.bool\(true\)|"confirmed": *\.bool\(true\)' "${UI_DIRS[@]}" --include='*.swift' 2>/dev/null | grep -v Tests || true)"
PAYLOAD_COUNT="$(printf '%s\n' "$PAYLOAD_LINES" | grep -c . || true)"
ARG_COUNT="$(grep -rnE 'confirmed: *true' "${UI_DIRS[@]}" --include='*.swift' 2>/dev/null | grep -v Tests | grep -c . || true)"
echo "· 确认载荷硬编码处数：$PAYLOAD_COUNT（目标 0；出现即必须伴随真实确认弹窗）／confirmed: true 实参处数：$ARG_COUNT（只统计，供人工裁决）"
if [ -n "$PAYLOAD_LINES" ]; then
  PAYLOAD_FILES="$(printf '%s\n' "$PAYLOAD_LINES" | cut -d: -f1 | sort -u)"
  BAD_FILES=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    grep -q 'gatherDestructiveConfirm' "$f" || BAD_FILES="$BAD_FILES$f"$'\n'
  done <<< "$PAYLOAD_FILES"
  if [ -n "$BAD_FILES" ]; then
    echo "✗ 伪造确认（文件内直接置确认载荷，却没有任何确认弹窗）："
    printf '%s' "$BAD_FILES" | sed 's/^/    /'
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "✓ 命令面与单一真相源门禁通过"
