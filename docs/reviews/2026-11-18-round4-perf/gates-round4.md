# Round-4 性能反模式 ratchet 扩展与基线校准（2026-11-18）

- 门禁：scripts/check-perf-ratchet.sh（gate #17，CI gates job 的 "Perf ratchet" step；门禁总数仍为 17）
- 基线：docs/perf-baseline.json（唯一事实源；本文件为设计/验收记账）
- 结论：**PASS**（对 round-4 最终工作树 --write-baseline 后实测：Sources 750 个 Swift 文件，
  9 项指标全部等于基线；baseline 的 generated_at 见 docs/perf-baseline.json）

## 1. 本轮改动

1. 指标从 7 项扩到 9 项，新增两个「内联 JSON 编解码链」回归守卫：
   - raw_json_encode_chain：JSONEncoder() 后立即 .encode 的内联链
   - raw_json_decode_chain：JSONDecoder() 后立即 .decode 的内联链
   动机：构造点指标（raw_json_encoder/decoder）在缓存化之后可能下降，但新代码仍可能写成
   JSONEncoder().encode(...) 的一次性链；两道指标互补，把「构造即用」的回潮钉住。
2. 基线按 round-4 最终工作树重生成；blocking_sleep 由 1 归零（perf-runtime 把
   JobService+Settle 的同步重试改成 async），notes 更新为「0 即零容忍」。
3. 未新增第三项指标（评估过）：iso_chain（ISO8601DateFormatter().date/string 内联链）当前
   15 处但与 raw_iso_formatter 的构造点高度重叠；JSONSerialization 13 处属于 legacy 面
   （check-no-legacy 管辖）而非分配热点；FileManager.default 258 处范围过宽、不是单点反模式。
   保持指标集最小可解释。

## 2. Round-3 → Round-4 指标对照（baseline）

| 指标 | round-3 baseline | round-4 baseline | 变化 | 说明 |
| --- | --- | --- | --- | --- |
| raw_date_formatter | 28 | 28 | 0 | 基本是 DisplayDateFormatters 的 per-locale 缓存构点 |
| raw_iso_formatter | 30 | 30 | 0 | DateFormatting.swift 缓存 + GatherHost/core Maintenance |
| raw_json_encoder | 46 | 45 | −1 | lead 修 Support/JSONValueDecoding.swift：改为 JSONValueCoding 共享编解码器 |
| raw_json_decoder | 39 | 38 | −1 | 同上 |
| raw_json_encode_chain | —（round-4 新增） | 20 | new | 内联 encode 链回潮守卫 |
| raw_json_decode_chain | —（round-4 新增） | 22 | new | 内联 decode 链回潮守卫（收尾时另有一处被 perf-ui 收敛） |
| raw_regex_compile | 3 | 3 | 0 | 2 处已在锁盒子缓存内，1 处按规则表一次性构造 |
| raw_byte_formatter | 1 | 1 | 0 | DateFormatting.swift 的 per-locale 缓存构点 |
| blocking_sleep | 1 | 0 | −1 | perf-runtime：JobService+Settle 的罕见错误路径重试改为 async；0 即零容忍 |

本轮基线收紧（--write-baseline 取最终值，interim 中间态不保留）：
raw_json_encoder 46→45、raw_json_decoder 39→38（lead 的 JSONValueCoding 共享编解码器修复）；
blocking_sleep 1→0（perf-runtime：同步重试改 async）；raw_json_decode_chain 收尾期间 23→22
（perf-ui 收敛一处内联解码链）。raw_json_encode_chain 为 round-4 新增指标，最终 20。

基线字段：schema=1、metrics 9 项、notes（blocking_sleep / caches / json_chains）、scopes 9 项。

## 3. 口径与语义（与 round-3 一致）

- 扫描面：desktop/native/*/Sources/**/*.swift（Tests 不计；.build 不在跟踪面内；当前 750 文件，
  守卫下限 600，路径异常即 FAIL）。
- 计数：非纯注释行匹配行数（整行首非空字符为 // 或 * 的行不计；同一行多处计 1）；
  与 scripts/check-cleanup-ratchet.sh 同口径；词边界用 (^|[^A-Za-z0-9_])，避免
  ISO8601DateFormatter() 被误计入 DateFormatter()。
- 基线语义：超 baseline FAIL；低于提示收紧；缺 key FAIL；--write-baseline 只允许持平/收紧，
  确需扩张必须 --allow-growth 并在 docs/reviews/ 记账。

## 4. 收紧 / 重生成流程

~~~bash
./scripts/check-perf-ratchet.sh                                   # 校验（CI 口径）
./scripts/check-perf-ratchet.sh --write-baseline                  # 收紧基线（只允许持平/收紧）
./scripts/check-perf-ratchet.sh --write-baseline --allow-growth   # 确需扩张（须记账）
~~~

- 收敛热点后重跑 --write-baseline 把基线钉到新值；CI 只读基线。
- 文档同步（docs-steward）：docs/DEVELOPMENT.md 的「7 类/7 指标」需改为「9 类/9 指标」并补
  两个新指标名；门禁总数不变（仍 17）。
- report-baseline：其「性能 ratchet」节当前硬编码 7 项指标清单（scripts/report-baseline.sh:422），
  本轮 baseline 已有 9 项；如需报表同步展示新指标，需要在 scripts/report-baseline.sh 的
  PERF_METRICS 列表补两行（本轮 write scope 未包含该文件，作为 follow-up 报告给 lead）。
- 集成说明：本文件所在审计目录在集成时由 2026-11-18-round4-perf 改名为
  2026-11-18-round4-perf；正文不引用自身目录路径，改名不影响内容/链接。

## 5. 验证证据（round-4 收尾工作树；baseline generated_at 见 docs/perf-baseline.json）

- bash -n scripts/check-perf-ratchet.sh：无输出；shellcheck 0.10.0 -S warning：0 findings。
- ./scripts/check-perf-ratchet.sh：9 项全 ok，OK，rc=0；连续两次运行 stdout 逐字节一致。
- ./scripts/report-baseline.sh：rc=0（性能节输出 baseline 元信息 + 现有 7 项 current/baseline；
  新指标展示见 §4 的 follow-up）。
- .github/workflows/ci.yml：无需改动（"Perf ratchet" step 已在，PyYAML 解析 OK）。
- ./scripts/check-repo-hygiene.sh：7/7 节 PASS。
- 负向测试（round-3 已做，本轮复用同一逻辑）：baseline 指标临时 −1 → --write-baseline REFUSED；
  临时 +3 → gate 显示 improved 且 PASS；恢复后 md5 一致。
- 新/改文件（提交前未 tracked）按 hygiene 同规则手工校验：LF / UTF-8 / 无行尾空白 / 末尾换行 /
  可执行位（.sh）/ bash -n / shellcheck。

## 6. 局限

- 源码级行匹配而非 AST：字符串字面量、行尾注释里的命中会计入（与 cleanup ratchet 一致）；
  跨行构造、自定义 wrapper/子类别名不单独识别。
- chain 指标与构造点指标在「JSONEncoder().encode(...)」这种同一行写法上重叠：这是刻意的互补
  视角（构造点看分配，chain 看内联使用），不是重复计数错误；两者都只降不升。
- 构造点数量 ≠ 运行时开销本身：共享实例若每帧重新 configure 仍可能慢；需配合 perf 审计与
  真机 profile（本轮环境 Linux，无 macOS 构建/运行）。
- Tests 不计：测试夹具允许一次性构造。
