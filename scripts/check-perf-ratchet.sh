#!/usr/bin/env bash
# 性能反模式 ratchet 门禁（2026-11-17 round-3，gate #17）。
#
# 为什么需要：下面这些类型的构造都是一次性昂贵配置（locale/format 解析、正则编译），
# 在**每次调用**（渲染、查询、写盘、日志）里 new 一个实例是 UI 卡顿与吞吐下降的常见根因。
# round-1/2 已实测过滚动掉帧与查询放大；round-3 起把「构造点数量」钉成基线：只许降不许涨，
# 新增热点必须走既有缓存/共享实例，而不是再造一个。
#
# round-4 增补（构造点被缓存后最常见的回潮形态）：
#   raw_json_encode_chain / raw_json_decode_chain —— 统计「JSONEncoder()/JSONDecoder() 之后
#   立即 .encode/.decode」的内联链。构造点指标（raw_json_encoder/decoder）可能因缓存化下降，
#   但新代码仍可能写成 JSONEncoder().encode(...) 的一次性链；单独计数才能把这类回潮钉住。
#
# 指标（Sources/**/*.swift 的「非纯注释行」匹配行数；整行首非空字符为 // 或 * 的行不计，
# 同一行多处只计 1 行 —— 与 scripts/check-cleanup-ratchet.sh 同口径）：
#   raw_date_formatter   DateFormatter()          → 用 DisplayDateFormatters / RepositoryDateFormatters
#   raw_iso_formatter    ISO8601DateFormatter()   → 用 DisplayDateFormatters 的共享 ISO 解析器
#   raw_json_encoder     JSONEncoder()            → 用 JSONValueCoding / RepoJSONCoding 等编解码器
#   raw_json_decoder     JSONDecoder()            → 同上
#   raw_json_encode_chain JSONEncoder().encode    → 内联链回潮守卫：改走 JSONValueCoding / 共享 coder
#   raw_json_decode_chain JSONDecoder().decode    → 同上
#   raw_regex_compile    NSRegularExpression(     → 用 Synchronization.Mutex 锁盒子缓存编译结果
#   raw_byte_formatter   ByteCountFormatter()     → 用 DisplayDateFormatters.fileSize
#   blocking_sleep       Thread.sleep(            → 目标 0（round-4 已把 JobService+Settle 的罕见错误路径
#                                                   同步重试改为 async，当前 Sources 实测 0；基线 0 即
#                                                   零容忍，任何新增阻塞睡眠都会 FAIL）。
#
# 扫描面与排除：
#   - desktop/native/gather-core/Sources + desktop/native/gather-app/Sources（Tests 不计：
#     测试夹具允许一次性构造；.build 不在跟踪面内）。
#   - 不设文件级排除：缓存实现自身（如 GatherUI/Support/DateFormatting.swift、
#     Support/JSONValueDecoding.swift）的构造点同样计入基线 —— 「扩缓存」也需要显式
#     改基线并记账，门禁不会因新增缓存文件而误报。
#   - 已知口径局限：这是**源码级行匹配**。字符串字面量/跨行构造同样会计入；注释整行不计但
#     行尾注释里的命中仍计入（与 cleanup ratchet 一致）。要更精确请单独立 AST 门禁。
#
# baseline: docs/perf-baseline.json
#   - 超过 baseline：FAIL（exit 1）
#   - 低于 baseline：提示收紧 baseline，不失败
#   - baseline 缺失/缺 key：FAIL（防止门禁静默失效）
#   - --write-baseline 只允许持平/收紧；确需扩张必须 --allow-growth 并在 docs/reviews/ 记账
#
# 用法：
#   ./scripts/check-perf-ratchet.sh
#   ./scripts/check-perf-ratchet.sh --write-baseline
#   ./scripts/check-perf-ratchet.sh --write-baseline --allow-growth
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CORE_SRC="desktop/native/gather-core/Sources"
APP_SRC="desktop/native/gather-app/Sources"
BASELINE="docs/perf-baseline.json"
METRICS="raw_date_formatter raw_iso_formatter raw_json_encoder raw_json_decoder raw_json_encode_chain raw_json_decode_chain raw_regex_compile raw_byte_formatter blocking_sleep"

for d in "$CORE_SRC" "$APP_SRC"; do
  if [ ! -d "$d" ]; then
    echo "check-perf-ratchet: FAIL 缺少扫描根：$d" >&2
    exit 1
  fi
done
# 扫描量守卫：路径/检出异常时不得静默 0 命中（当前 ~749 个 Swift 源文件）。
SWIFT_N=$(find "$CORE_SRC" "$APP_SRC" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
if [ "$SWIFT_N" -lt 600 ]; then
  echo "check-perf-ratchet: FAIL Sources 只扫到 $SWIFT_N 个 Swift 文件（<600），疑似根路径错误" >&2
  exit 1
fi

WRITE=0
ALLOW_GROWTH=0
for arg in "$@"; do
  case "$arg" in
    --write-baseline) WRITE=1 ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
    -h|--help)
      sed -n '2,43p' "$0"
      exit 0
      ;;
    *)
      echo "check-perf-ratchet: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# count_matches <ERE> <path...>
# 只统计非纯注释行；同一行多次匹配按 1 计（与 check-cleanup-ratchet.sh 一致）。
count_matches() {
  local re="$1"
  shift
  local total=0 f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(grep -E "$re" "$f" 2>/dev/null | grep -vE '^[[:space:]]*(//|\*)' | wc -l | tr -d ' ')
    total=$((total + n))
  done < <(find "$@" -type f -name '*.swift' -not -path '*/.build/*' 2>/dev/null | sort)
  echo "$total"
}

# 词边界用 (^|[^A-Za-z0-9_]) 表达（BSD/GNU grep -E 都安全；\b 不是 POSIX ERE）。
metric() {
  case "$1" in
    raw_date_formatter) count_matches '(^|[^A-Za-z0-9_])DateFormatter\(\)' "$CORE_SRC" "$APP_SRC" ;;
    raw_iso_formatter)  count_matches '(^|[^A-Za-z0-9_])ISO8601DateFormatter\(\)' "$CORE_SRC" "$APP_SRC" ;;
    raw_json_encoder)   count_matches '(^|[^A-Za-z0-9_])JSONEncoder\(\)' "$CORE_SRC" "$APP_SRC" ;;
    raw_json_decoder)   count_matches '(^|[^A-Za-z0-9_])JSONDecoder\(\)' "$CORE_SRC" "$APP_SRC" ;;
    raw_json_encode_chain) count_matches '(^|[^A-Za-z0-9_])JSONEncoder\(\)[[:space:]]*\.[[:space:]]*encode' "$CORE_SRC" "$APP_SRC" ;;
    raw_json_decode_chain) count_matches '(^|[^A-Za-z0-9_])JSONDecoder\(\)[[:space:]]*\.[[:space:]]*decode' "$CORE_SRC" "$APP_SRC" ;;
    raw_regex_compile)  count_matches '(^|[^A-Za-z0-9_])NSRegularExpression\(' "$CORE_SRC" "$APP_SRC" ;;
    raw_byte_formatter) count_matches '(^|[^A-Za-z0-9_])ByteCountFormatter\(\)' "$CORE_SRC" "$APP_SRC" ;;
    blocking_sleep)     count_matches '(^|[^A-Za-z0-9_])Thread\.sleep\(' "$CORE_SRC" "$APP_SRC" ;;
    *) echo "0" ;;
  esac
}

write_baseline() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$(dirname "$BASELINE")"
  cat > "$BASELINE" <<JSON
{
  "schema": 1,
  "generated_at": "$ts",
  "generated_by": "scripts/check-perf-ratchet.sh --write-baseline",
  "counting": "matching non-comment lines (lines whose first non-space chars are // or * are ignored; at most 1 per line)",
  "scope": "desktop/native/*/Sources/**/*.swift (Tests excluded; no file-level exclusions)",
  "metrics": {
    "raw_date_formatter": $(metric raw_date_formatter),
    "raw_iso_formatter": $(metric raw_iso_formatter),
    "raw_json_encoder": $(metric raw_json_encoder),
    "raw_json_decoder": $(metric raw_json_decoder),
    "raw_json_encode_chain": $(metric raw_json_encode_chain),
    "raw_json_decode_chain": $(metric raw_json_decode_chain),
    "raw_regex_compile": $(metric raw_regex_compile),
    "raw_byte_formatter": $(metric raw_byte_formatter),
    "blocking_sleep": $(metric blocking_sleep)
  },
  "notes": {
    "blocking_sleep": "round-4 起归零：GatherApplication/Services/Job/JobService+Settle.swift 的罕见错误路径（瞬时 DB 错误）终态写重试已从同步 Thread.sleep(0.2) 改为 async 重试，Sources 实测 0；基线 0 为零容忍，任何新增阻塞睡眠都会让门禁 FAIL。",
    "caches": "允许的共享缓存构造点（已计入基线）：GatherUI/Support/DateFormatting.swift（DateFormatter/ISO8601/ByteCountFormatter per-locale 缓存）、Support/JSONValueDecoding.swift（JSONValueCoding 共享编解码器）、GatherApplication 的 RepoJSONCoding / RepositoryDateFormatters、以及 Synchronization.Mutex 锁盒子内的 NSRegularExpression 缓存。扩缓存同样需要显式改基线。",
    "json_chains": "raw_json_encode_chain / raw_json_decode_chain 统计『JSONEncoder()/JSONDecoder() 后立即 .encode/.decode』的内联链（round-4 增补）：构造点指标被缓存化后，内联链是最常见的回潮形态；两道指标互补，新增代码应走 JSONValueCoding / 共享 coder。"
  },
  "scopes": {
    "raw_date_formatter": "desktop/native/*/Sources/**/*.swift",
    "raw_iso_formatter": "desktop/native/*/Sources/**/*.swift",
    "raw_json_encoder": "desktop/native/*/Sources/**/*.swift",
    "raw_json_decoder": "desktop/native/*/Sources/**/*.swift",
    "raw_json_encode_chain": "desktop/native/*/Sources/**/*.swift",
    "raw_json_decode_chain": "desktop/native/*/Sources/**/*.swift",
    "raw_regex_compile": "desktop/native/*/Sources/**/*.swift",
    "raw_byte_formatter": "desktop/native/*/Sources/**/*.swift",
    "blocking_sleep": "desktop/native/*/Sources/**/*.swift"
  }
}
JSON
}

if [ "$WRITE" -eq 1 ] && [ -f "$BASELINE" ] && [ "$ALLOW_GROWTH" -eq 0 ]; then
  grew=0
  for key in $METRICS; do
    cur=$(metric "$key")
    base=$(grep -E "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$BASELINE" 2>/dev/null | grep -oE '[0-9]+' | head -n 1 || true)
    [ -n "$base" ] || continue
    if [ "$cur" -gt "$base" ]; then
      echo "  涨：$key $base -> $cur" >&2
      grew=1
    fi
  done
  if [ "$grew" -ne 0 ]; then
    echo "check-perf-ratchet: REFUSED — 基线膨胀必须显式批准" >&2
    echo "  确需扩张时加 --allow-growth，并在 docs/reviews/ 台账记账。" >&2
    exit 1
  fi
fi

if [ "$WRITE" -eq 1 ]; then
  write_baseline
  echo "check-perf-ratchet: baseline 已写入 $BASELINE"
  for key in $METRICS; do
    printf '  %-22s %s\n' "$key" "$(metric "$key")"
  done
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "check-perf-ratchet: FAIL — 缺少 $BASELINE" >&2
  echo "  先运行：./scripts/check-perf-ratchet.sh --write-baseline" >&2
  exit 1
fi

baseline_value() {
  local key="$1" line val
  line=$(grep -E "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$BASELINE" 2>/dev/null | head -n 1 || true)
  val=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -n 1 || true)
  printf '%s' "$val"
}

fail=0
echo "check-perf-ratchet: Sources $SWIFT_N 个 Swift 文件"
printf '%-22s %8s %8s  %s\n' "metric" "current" "baseline" "status"
for key in $METRICS; do
  cur=$(metric "$key")
  base=$(baseline_value "$key")
  if [ -z "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "?" "FAIL (baseline 缺 key)"
    fail=1
    continue
  fi
  if [ "$cur" -gt "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "FAIL (+$((cur - base)))"
    fail=1
  elif [ "$cur" -lt "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "ok (improved $((base - cur)); 可收紧 baseline)"
  else
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "ok"
  fi
done

echo "----"
if [ "$fail" -ne 0 ]; then
  echo "check-perf-ratchet: FAILED — 性能反模式构造点不得高于 baseline" >&2
  echo "  修复方向：共享缓存/单例（DisplayDateFormatters / JSONValueCoding / RepoJSONCoding /" >&2
  echo "  RepositoryDateFormatters / Synchronization.Mutex 锁盒子），而不是每次调用新建实例。" >&2
  exit 1
fi
echo "check-perf-ratchet: OK（全部指标不超过 baseline）"
