# Round-3 性能反模式 ratchet（gate #17）验收记录（2026-11-17）

- 门禁：scripts/check-perf-ratchet.sh（CI gates job 的 "Perf ratchet" step，位于 Docs facts 之后）
- 基线：docs/perf-baseline.json（唯一事实源；本文件是设计/验收记账，不参与机读）
- 结论：**PASS**（2026-11-17 round-3 收尾实测：Sources 750 个 Swift 文件，7 项指标均不超过基线）

## 1. 动机

DateFormatter / ISO8601DateFormatter / JSONEncoder / JSONDecoder / NSRegularExpression /
ByteCountFormatter 的构造都是一次性昂贵配置（locale/format 解析、正则编译）。在**每次调用**
（渲染、查询、写盘、日志）里新建实例是 UI 抖动与吞吐下降的常见根因。round-1/2 已引入共享缓存
（DisplayDateFormatters、JSONValueCoding、RepoJSONCoding、RepositoryDateFormatters、
Synchronization.Mutex 锁盒子等）；round-3 起把「构造点数量」钉成只降不升的 ratchet，
防止新代码回潮。

## 2. 指标与口径

| 指标 | 匹配模式 | 首选替代 |
| --- | --- | --- |
| raw_date_formatter | DateFormatter() | DisplayDateFormatters / RepositoryDateFormatters |
| raw_iso_formatter | ISO8601DateFormatter() | DisplayDateFormatters 的共享 ISO 解析器 |
| raw_json_encoder | JSONEncoder() | JSONValueCoding / RepoJSONCoding 等编解码器 |
| raw_json_decoder | JSONDecoder() | 同上 |
| raw_regex_compile | NSRegularExpression( | Synchronization.Mutex 锁盒子缓存编译结果 |
| raw_byte_formatter | ByteCountFormatter() | DisplayDateFormatters.fileSize |
| blocking_sleep | Thread.sleep( | 禁止在 Sources 里阻塞睡眠（目标 0） |

- 扫描面：desktop/native/*/Sources/**/*.swift（Tests 不计：测试夹具允许一次性构造；
  .build 不在跟踪面内；当前 750 个文件，守卫下限 600 失败即 FAIL）。
- 计数：非纯注释行匹配行数 —— 整行首非空字符为 // 或 * 的行不计，同一行多处只计 1；
  与 scripts/check-cleanup-ratchet.sh 同口径。
- 文件级排除：无。缓存实现自身的构造点也计入基线，「扩缓存」同样要显式改基线并记账。
- 基线语义：超过 baseline → FAIL（exit 1）；低于 → 提示收紧；缺 key → FAIL；
  --write-baseline 只允许持平/收紧，确需扩张必须 --allow-growth 并在 docs/reviews/ 记账。

## 3. 当前基线（2026-11-17 round-3 收尾；gate PASS）

| 指标 | current | baseline | 说明（剩余构造点分布） |
| --- | --- | --- | --- |
| raw_date_formatter | 28 | 28 | 大部分是 GatherUI/Support/DateFormatting.swift 的 per-locale 缓存构点（L66/96/107/118 等），其余在 GatherHost/UI 的 parse/display helper |
| raw_iso_formatter | 30 | 30 | DateFormatting.swift 的 ISO 缓存（L46/49）+ GatherHost AppBootstrap/C1RoundTrip + core Maintenance（BackupStore / DiagnosticsCollector / MaintenanceService） |
| raw_json_encoder | 46 | 46 | GatherHost Live*API 的响应编码、GatherUI 状态/传输 helper、core CullingService+Paging / ExportPostCommandRunner |
| raw_json_decoder | 39 | 39 | 同侧解码（Live*API、GatherUI stores/helpers、core ExportPostCommandRunner / SessionIngestRunner / BackupStore 等） |
| raw_regex_compile | 3 | 3 | NavigationService:470 与 SidecarXMPProvider+IPTCReading:31 都在锁盒子缓存内；OutputPostCommandRedaction:30 为按规则表一次性构造 |
| raw_byte_formatter | 1 | 1 | GatherUI/Support/DateFormatting.swift:137（per-locale 缓存构点） |
| blocking_sleep | 1 | 1 | 唯一在册例外：GatherApplication/Services/Job/JobService+Settle.swift:210 的 Thread.sleep(forTimeInterval: 0.2) —— 罕见错误路径（瞬时 DB 错误）的终态写重试，位于同步 helper。目标 0，待未来轮次改为 async 重试后归零；基线钉实测值只防新增（理由同 docs/perf-baseline.json 的 notes 字段） |

基线非 0 的原因：允许的共享缓存构造点（DateFormatting.swift 的 formatter 缓存、
Support/JSONValueDecoding.swift 的 encoder/decoder、RepoJSONCoding / RepositoryDateFormatters、
锁盒子正则缓存）计入基线；ratchet 的承诺是「不再新增构造点」，不是「今天全部归零」。

已知 follow-up（下一轮可继续收敛）：Support/JSONValueDecoding.swift:64-65 的 transcode helper
每次调用仍新建 JSONEncoder/JSONDecoder（中央 helper，当前计入基线）；如需再降，可在该 helper
内做锁盒子缓存后 --write-baseline 收紧。

## 4. 如何收紧 / 重生成

~~~bash
./scripts/check-perf-ratchet.sh                                   # 校验（CI 口径）
./scripts/check-perf-ratchet.sh --write-baseline                  # 收紧基线（只允许持平/收紧）
./scripts/check-perf-ratchet.sh --write-baseline --allow-growth   # 确需扩张（须在本目录记账）
~~~

- 收敛热点后重跑 --write-baseline 把基线钉到新值；CI 只读基线。
- docs-facts gate 要求文档同步门禁数（本轮 16→17）与 docs/DEVELOPMENT 门禁清单，
  否则 CI 的 Docs facts step 会 FAIL（由 docs-steward 在收尾时更新）。

## 5. 验证证据（2026-11-17）

- bash -n scripts/check-perf-ratchet.sh：无输出；shellcheck 0.10.0 -S warning：0 findings。
- ./scripts/check-perf-ratchet.sh：OK，rc=0；连续两次运行 stdout 逐字节一致（确定性）。
- ./scripts/report-baseline.sh：rc=0，输出「性能 ratchet」节（baseline + 当前实测对照）。
- .github/workflows/ci.yml：PyYAML 解析 OK；gates job 15 个 run step；CI 唯一门禁脚本 17 个
  （与门禁数一致）。
- ./scripts/check-repo-hygiene.sh：7/7 节 PASS（新脚本在提交前未被 tracked 扫描，已按同一规则
  手工校验：LF / UTF-8 / 无行尾空白 / 末尾换行 / 可执行位）。
- 负向测试：临时把 baseline 某指标 −1 → --write-baseline REFUSED（rc=1）；临时 +3 →
  gate 显示 "improved" 且 PASS；恢复后 md5 一致。

## 6. 局限

- 源码级行匹配而非 AST：字符串字面量里的命中、行尾注释里的命中会计入（与 cleanup ratchet
  一致）；跨行构造、自定义 wrapper/子类别名不单独识别。
- 构造点数量 ≠ 运行时开销本身：共享实例若每帧重新 configure 仍可能慢；需配合 perf 审计与
  真机 profile（本轮环境为 Linux，无 macOS 构建/运行）。
- Tests 不计：测试夹具允许一次性构造。
