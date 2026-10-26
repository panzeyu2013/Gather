#!/usr/bin/env bash
# SELECT * ratchet 门禁（Cut 2 / S4a，D-028 / D-032 / R1-10）。
#
# 口径：
#   - 只统计**实际 SQL** 中的 SELECT *（含 o.* / p.* / pp.* / dgm.* 等限定星号）；
#   - 排除 Swift 行注释 //、块注释 /* */（可嵌套）与 SQL 行注释 --；
#   - 一个查询命中一次（同一行多条按多条计）；
#   - Sources 基线：4（2026-10 实测：DuplicateGroupQuery 4 处——组 2 / 成员 1 /
#     成员 JOIN 1；TemplateService 的 2 处已展开为显式列；基线只减不增）；
#   - Tests 白名单：仅允许 AnalysisJobRepoTests.swift 的 1 处 EXPLAIN QUERY PLAN。
#
# 失败策略（D-032）：
#   - Sources > baseline → 违规；等于/低于 → 通过（低于时提示可收紧 baseline）；
#   - Tests 超出白名单（路径/数量）→ 违规；
#   - 默认 warning：打印 WARN，exit 0；--strict：exit 1。
#
# 用法：
#   ./scripts/check-select-star.sh
#   ./scripts/check-select-star.sh --strict
#   ./scripts/check-select-star.sh --strict --baseline 0    # 故意失败验证
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CORE_SRC="desktop/native/gather-core/Sources"
APP_SRC="desktop/native/gather-app/Sources"
CORE_TESTS="desktop/native/gather-core/Tests"
APP_TESTS="desktop/native/gather-app/Tests"

BASELINE=4
TESTS_BASELINE=1
TESTS_WHITELIST="desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/AnalysisJobRepoTests.swift"

for d in "$CORE_SRC" "$APP_SRC" "$CORE_TESTS" "$APP_TESTS"; do
  if [ ! -d "$d" ]; then
    echo "check-select-star: FAIL 缺少扫描根：$d" >&2
    exit 1
  fi
done
SWIFT_N=$(find "$CORE_SRC" "$APP_SRC" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
if [ "$SWIFT_N" -lt 300 ]; then
  echo "check-select-star: FAIL Sources 只扫到 ${SWIFT_N} 个 Swift 文件（<300）" >&2
  exit 1
fi

MODE=warning
while [ $# -gt 0 ]; do
  case "$1" in
    --strict)
      MODE=strict
      shift
      ;;
    --baseline)
      if [ $# -lt 2 ]; then
        echo "check-select-star: --baseline 缺少参数" >&2
        exit 2
      fi
      BASELINE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *)
      echo "check-select-star: 未知参数：$1" >&2
      exit 2
      ;;
  esac
done

case "$BASELINE" in
  ''|*[!0-9]*)
    echo "check-select-star: baseline 必须是非负整数：$BASELINE" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCE_HITS="$TMP/sources.txt"
TEST_HITS="$TMP/tests.txt"

# Perl 词法扫描：保留字符串内容，抹掉 Swift 注释；再按行抹掉 SQL -- 注释。
# 只在字符串/多行字符串中匹配 SELECT [DISTINCT] [qualifier.]*，避免把 Swift
# 文档/普通注释里的示例算进来（R1 的 44 行字面命中里 10 行不是语句）。
PERL_PROGRAM=$(cat <<'PERL'
use strict;
use warnings;

for my $path (@ARGV) {
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    my $out = '';
    my $i = 0;
    my $n = length($src);
    my $state = 'code';    # code | string | mlstring

    while ($i < $n) {
        my $c = substr($src, $i, 1);

        if ($state eq 'code') {
            my $two = substr($src, $i, 2);
            if ($two eq '//') {
                while ($i < $n && substr($src, $i, 1) ne "\n") {
                    $out .= ' ';
                    $i++;
                }
                next;
            }
            if ($two eq '/*') {
                my $depth = 1;
                $out .= '  ';
                $i += 2;
                while ($i < $n && $depth > 0) {
                    my $t = substr($src, $i, 2);
                    if ($t eq '/*') {
                        $depth++;
                        $out .= '  ';
                        $i += 2;
                    } elsif ($t eq '*/') {
                        $depth--;
                        $out .= '  ';
                        $i += 2;
                    } else {
                        my $ch = substr($src, $i, 1);
                        $out .= ($ch eq "\n" ? "\n" : ' ');
                        $i++;
                    }
                }
                next;
            }
            if (substr($src, $i, 3) eq '"""') {
                $state = 'mlstring';
                $out .= '"""';
                $i += 3;
                next;
            }
            if ($c eq '"') {
                $state = 'string';
                $out .= '"';
                $i++;
                next;
            }
            $out .= $c;
            $i++;
            next;
        }

        # 字符串内：保留内容（转义跳过下一个字符），SQL 注释稍后按行剔除。
        if ($c eq '\\') {
            $out .= $c;
            $i++;
            if ($i < $n) {
                $out .= substr($src, $i, 1);
                $i++;
            }
            next;
        }
        if ($state eq 'string' && $c eq '"') {
            $state = 'code';
            $out .= '"';
            $i++;
            next;
        }
        if ($state eq 'mlstring' && substr($src, $i, 3) eq '"""') {
            $state = 'code';
            $out .= '"""';
            $i += 3;
            next;
        }
        $out .= $c;
        $i++;
    }

    my $clean = '';
    for my $line (split /(?<=\n)/, $out, -1) {
        $line =~ s/--.*$//;    # SQL 行注释（含 Schema.swift 的 -- SELECT * 示例）
        $clean .= $line;
    }

    while ($clean =~ /(?i)\bSELECT\s+(?:DISTINCT\s+)?(?:[A-Za-z_][A-Za-z0-9_]*\.)?\*/g) {
        my $line = 1 + (substr($clean, 0, $-[0]) =~ tr/\n//);
        print "$path:$line\n";
    }
}
PERL
)

find "$CORE_SRC" "$APP_SRC" -type f -name '*.swift' -not -path '*/.build/*' -print0 \
  | xargs -0 perl -e "$PERL_PROGRAM" | sort > "$SOURCE_HITS"
find "$CORE_TESTS" "$APP_TESTS" -type f -name '*.swift' -not -path '*/.build/*' -print0 \
  | xargs -0 perl -e "$PERL_PROGRAM" | sort > "$TEST_HITS"

SOURCE_COUNT=$(wc -l < "$SOURCE_HITS" | tr -d ' ')
TEST_COUNT=$(wc -l < "$TEST_HITS" | tr -d ' ')
SOURCE_FILES=$(awk -F: '{print $1}' "$SOURCE_HITS" | sort -u | wc -l | tr -d ' ')
TEST_FILES=$(awk -F: '{print $1}' "$TEST_HITS" | sort -u | wc -l | tr -d ' ')

violations=0
warning() {
  echo "WARN   $*"
  violations=1
}

echo "check-select-star: Sources $SOURCE_COUNT 处 / $SOURCE_FILES 文件 (baseline $BASELINE)"
if [ "$SOURCE_FILES" -gt 0 ]; then
  awk -F: '{print $1}' "$SOURCE_HITS" | sort | uniq -c | sort -rn \
    | while read -r count file; do
        printf '        %3d  %s\n' "$count" "$file"
      done
fi

if [ "$SOURCE_COUNT" -gt "$BASELINE" ]; then
  warning "Sources SELECT * 超过 baseline：$SOURCE_COUNT > $BASELINE (S5 只能减少，不能新增)"
  sed 's/^/        - /' "$SOURCE_HITS"
elif [ "$SOURCE_COUNT" -lt "$BASELINE" ]; then
  echo "note   Sources 低于 baseline: $SOURCE_COUNT < $BASELINE; 可下调 --baseline 收紧 ratchet。"
fi

echo "check-select-star: Tests $TEST_COUNT 处 / $TEST_FILES 文件（白名单 $TESTS_BASELINE 处）"
if [ "$TEST_COUNT" -gt "$TESTS_BASELINE" ]; then
  warning "Tests SELECT * 超过白名单数量：$TEST_COUNT > $TESTS_BASELINE"
  sed 's/^/        - /' "$TEST_HITS"
fi
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=$(printf '%s\n' "$hit" | cut -d: -f1)
  if [ "$file" != "$TESTS_WHITELIST" ]; then
    warning "Tests SELECT * 不在白名单：$hit"
  fi
done < "$TEST_HITS"

echo "----"
if [ "$violations" -ne 0 ]; then
  if [ "$MODE" = "strict" ]; then
    echo "check-select-star: FAILED（--strict）" >&2
    exit 1
  fi
  echo "check-select-star: WARN（warning 模式，未硬失败；CI/验收请加 --strict）"
  exit 0
fi
echo "check-select-star: OK"
