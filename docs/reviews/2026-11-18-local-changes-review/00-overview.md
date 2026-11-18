# 2026-11-18 本地 vs 上游全量独立评审（16 commits / 220 files）

- **评审对象**：本地 `main`（HEAD `5ea5c38f`）相对上游 `origin/main`（`e5c54f37`）的全部 16 个提交、220 个文件、+9243/−949 行（四轮自驱优化：卫生/门禁/文档、core 性能、UI 性能、运行时/缓存性能）。
- **评审方式**：5 个独立 reviewer（review-core / review-app / review-tests / review-tooling / review-optimality，均非改动作者）分域只读复核；每人产出独立分册（同目录），lead 汇总并修复确认的 P1/P2。所有 reviewer 的"结论"都被当作假设，用自己的探针/门禁复跑验证。
- **环境与上限**：Linux Ubuntu 22.04，无 macOS/Xcode。**未编译、未运行 macOS target、未跑 swift test、无 Instruments/真机 UI**；评审证据 = 逐文件 `swiftc -parse`（168 个 Swift 改动文件 + 全仓语法）、Swift 6.2 Linux 独立探针（Observation/正则锁盒子/BatchRunner 取消/日期格式化/JSON 语义/页面索引对拍等）、Python SQLite pragma 探针、16/17 道 Linux 可跑门禁、以及 `git archive` scratch 副本里的门禁负向探针。macOS 绝对行为（编译/类型/严格并发/渲染/内存）仍需 CI/真机确认。
- **分册**：[R1-core.md](R1-core.md)、[R2-app.md](R2-app.md)、[R3-tests.md](R3-tests.md)、[R4-tooling.md](R4-tooling.md)、[R5-optimality.md](R5-optimality.md)。

## 1. 结论摘要

| 级别 | 数量 | 代表问题 | 处置 |
| --- | --- | --- | --- |
| P0（崩溃/数据丢失/编译中断/安全） | **0** | 无 | — |
| P1（很可能正确性回归/CI 红） | **3** | ① `navigationGroupSizeByPhotoID` 缓存命中路径丢 Observation 依赖（「组 N 张」可陈旧，与 round-3 selectionSummary 同型陷阱）；② `GalleryLayoutCache.rowIndex` 改映射后既有测试 `JustifiedLayoutTests` 直接写 `rows` ⇒ app 测试套件会红；③ `JSONValueCodingTests` 用「共享 encoder == 每次新建 encoder」的**裸字节** oracle，Foundation 不承诺对象键序稳定（Linux 实测 6 次中 5 次失败） | 全部已修（见 §2） |
| P2（风险/鲁棒性/最优性） | ~15 | applyImportedPicks 批前快照使 revision 冲突检测对"未触碰照片"变成恒等式（并发人工决策可能被 imported 覆盖）；Database.close 的 PRAGMA optimize 破坏只读 CLI 语义/耗时无界且收益≈0；NavigationService.LegacyWallDateParsers 无锁共享 DateFormatter；DateFormatting 锁外使用缓存 DateFormatter 且 mediumShort 键缺 calendar/timeZone；JobService 取消时 200ms 退避变 0（与旧语义不符）；Gallery Lightbox 命中下标不校验身份（瞬时错图）；preload await 后不校验页/当前照片（旧目标预热）；NSCache cost 修正后 512MB 上限的淘汰悬崖未实测；门禁完整性缺口（hygiene [b] 文件面窄、docs-facts 清单仅全文匹配、test-catalog ratchet 基线严重过期等） | 大部分已修；NSCache 实测/新增回归测试列入后续（§3） |
| P3（nit/加固） | ~40 | 缓存键、一次性标志顺序、打包截断、id 集合重复、启动计时口径、门禁可绕过路径、协议基线说明性字段等 | 高性价比项已批量收；其余列入后续 |

**总体判断**：四轮优化方向与绝大多数实现被独立复核为正确（DBStatementCache/mmap/page-index/布局缓存/LRU/throttle 属"合理且低复杂度"，不建议回退任何一项）；主要问题集中在「缓存 + Observation 依赖」「无 macOS 编译条件下的测试 oracle 假设」「门禁/文档与代码的同步」三类，均在本轮修复或明确记录。

## 2. 已修复项（本轮 review-fix）

修复提交：`6e940350`（代码/测试）、`9be6a000`（门禁/基线）、`0288ea8d`（本轮评审归档与文档修正；`33ef7313` 是 amend 前的旧对象，现为 dangling，不是父提交）。

| # | 来源 | 修复 |
| --- | --- | --- |
| 1 | R2-A1 / R5-01（P1） | `navigationGroupSizeByPhotoID` 命中路径无条件读 `navigationGroups.count`；`similarGroupAssets` 同型防御读 `page` |
| 2 | R2-A0（P1） | `GalleryLayoutCache.rowIndex` 映射未命中时回退线性扫（修复既有测试直接写 `rows` 导致的 CI 红） |
| 3 | R3-T01 / R5-02（P1） | `JSONValueCodingTests` 改为值等价 oracle：对象比较解析后值，仅标量/数组/非对象比较字节；文件头与相关 docs 的"逐字节"论断修正 |
| 4 | R2-A2（P2） | `LightboxView.resolvedCurrentIndex` 命中后校验 `photos[index].id == currentID` 再回退线性 |
| 5 | CORE-01（P2/并发） | `applyImportedPicks` 未触碰照片恢复实时 `getDecision`（每张 1 次）；**round-3 评审 R3C-01 进一步整体回退该 N+1 优化**（变体人工保护窗口=整批不可接受），恢复上游逐张读语义 |
| 6 | CORE-02（P2） | 移除 `Database.close()` 的 PRAGMA optimize（写 ANALYZE/只读 CLI 语义/耗时无界/收益≈0）；docs 同步 |
| 7 | R5-03（P2） | `LegacyWallDateParsers` 改 `Synchronization.Mutex` 锁盒子，解析在锁内（DateFormatter 非线程安全） |
| 8 | R2-A4/A5 / R3-T03（P2） | `DisplayDateFormatters` 全部缓存 formatter 改为**持锁格式化**；`mediumShort` 缓存键补 calendar/timeZone |
| 9 | R5-04（P2） | `writeTerminal` 重试等待改用 detached 任务承载，任务被取消时仍等满 200ms（严格保持旧语义且不阻塞线程池） |
| 10 | R5-06（P2） | `runNeighborPreload` 在 await 前后校验 page 赋值代数/当前照片，过期计划直接放弃 |
| 11 | R3-T04（P2） | `ReviewFixTests` 两个负向窗口前先正向等待 `waiterStarted`（消除 false-green） |
| 12 | R2-A14 / A10 / A11 / A6（P3） | page.didSet 同步失效 keyword 目标索引；packedSize 先 clamp 到 UInt32；`loadedPhotoLookup` 复用 flatCache id 集合；prune 先判 isEnabled 再消费一次性标志 |
| 13 | CORE-05（P3） | `DBStatementCache` 记录语句所属连接，DEBUG 断言拦截跨连接复用 |
| 14 | R3-T05 / R4-F6（P2 门禁） | test-catalog 三个 ratchet 基线从 2502/283/11509 重钉到实测 3267/419/14954（原基线可静默删 765 用例/3445 断言） |
| 15 | R4-F22（P3，真实回归） | `check-protocol-surface.sh` 的 `xargs -I{} cat {}` 对含单引号路径回退 → 改 `while IFS= read -r` + 扫描量下限守卫 |
| 16 | R4-F3（P2 门禁） | hygiene [b] 文本文件面从硬编码 9 类扩到 plist/entitlements/modulemap/h/c/tsv/pbxproj/xcconfig/m/mm/Makefile/LICENSE/SHA256SUMS（实测 0 违规） |
| 17 | R4-F1/F2（P2 门禁） | docs-facts 门禁清单改为只校验「## 门禁」小节；新增 CI wiring 断言（17 道门禁必须出现在 ci.yml） |
| 18 | R4-F7/F8/F9/F11（P3） | design-system 基线 empty.contentUnavailable 10→6；cleanup try_optional 钉到 257；`.gitattributes` 补 `docs/perf-baseline.json linguist-generated`；protocol 基线说明性字段已更新（17177→17192，比较语义未改，见 §3.8） |
| 19 | 文档漂移 | round-1/2/3/4 审计文档的过时/错误论断修正（JSON 字节语义、close optimize、test-catalog/报告基线、NSCache 淘汰悬崖、采样日期/轮次、报告基线 9 项等）；docs/DEVELOPMENT/README/ROADMAP 同步 |

## 3. 未修复 / 后续建议（已记录，均需 macOS 或下一轮）

1. **macOS 首跑必查**：本轮全部 Swift 改动（尤其 Observation 依赖、DateFormatter 锁、Lightbox 身份校验、applyImportedPicks 实时读、JobService detached 等待、DBStatementCache assert）只经过语法解析 + Linux 逻辑探针；需要 `swift build/test`、`check-warnings`、UI/Instruments 验证。R1/R2/R3/R5 各自给出了建议的优先复验清单。
2. **高风险改动缺回归测试（CORE-03）**：DBStatementCache、applyImportedPicks revision 语义、JobService async 重试、EmbeddingModel LRU、Database.close 语义都没有新增测试（本轮只修了既有 flaky/false-green 测试）；建议下一轮在 macOS 可运行的 target 里补。
3. **门禁加固（F4/F5/F2 残余）**：hygiene [c] 未剥离 HTML 注释（误报）、reference-style/title 链接漏检；[g] 插值内嵌 CJK 漏检、`Text(verbatim:)` 误报；可继续做（均为 fail-closed 方向，当前仓库 0 违规）。
4. ~~**NSCache 淘汰悬崖（R2-A3/R5-05）**~~ → **round-2 复评审证伪前提**：缓存 NSImage 来自 App 自编码预览 JPEG（无 DPI），点≈像素，cost 差异消失；真实残余是 512MB 对 2560 预览容量有限（约 24 张量级），需真机实测后决定预算/分桶。
5. ~~**CORE-04**：`SidecarRegexCache.withRegex<T: Sendable>` 依赖 Darwin `NSRange` 的 Sendable 声明~~ → **round-2 已修**：去掉 `T: Sendable` 约束（Linux 探针验证 `[NSRange]` 返回可编译），Darwin 编译风险解除。
6. **既有 P3 认知**：启动计时标签 runtimeStart 含并行 languageSeed 的"墙钟"口径建议改名；Gallery 光标锚点 O(k)；`ThumbnailDiskCache` 1h touch 粒度；report-baseline 与 perf-ratchet 双实现（已验 parity）；shellcheck 版本未 pin / 无 actionlint。
7. **CORE-01b（残余）**：applyImportedPicks 中「兄弟变体的人工决策保护」仍读批前快照（主照片已实时读）；批次窗口内新提交的人工决策仍可能被 imported 覆盖。彻底修复需每变体实时读（重新引入 N+1）或给 updateState 加 DB 级条件更新；建议下一轮评估。
8. **协议基线说明性字段**：`protocol_lines`（17177→17192）不参与比较；round-2 已用 `--write-baseline` 更新说明性字段（比较语义未改，避免对注释行过度敏感）。

## 4. 验证（2026-11-18 修复后实跑）

> **验证口径修正（round-2 复核）**：`-parse` 只证明语法，**不能证明可编译**——round-2 用真实 `-typecheck` 才发现本提交引入的 3 个 P0（见 round-2 归档）。本节「parse 0 失败」仅作语法证据，不代表可构建。

```text
SwiftPM manifest（core/app）→ OK
GatherProtocol / GatherPreviewData Linux 类型检查 → OK
swiftc -parse：168 个改动 Swift 文件 + 全仓 1090 文件 → 0 failures（reviewer 各自复跑）
16/17 道 Linux 可跑门禁 → 全 PASS（含 5 个 --strict、hygiene 7/7、docs-facts、9 指标 perf-ratchet）
git diff --check → 干净
```

## 5. 评审分册覆盖

- R1：core 44 个改动文件全量 diff + 探针（SQLite/Mutex/BatchRunner/正则/applyImportedPicks）。
- R2：gather-app 全部 331 个 source 文件 parse + page-index/selection/布局/Gallery/DateFormatting/AppBootstrap 探针对拍；含 P1 A0。
- R3：31 个改动测试文件 + 2 个 AsyncWait helper 逐字复制语义探针（13/13）+ 数字独立对账；含 P1 测试 oracle。
- R4：15 个 scripts + CI + .gitattributes + 4 个 baseline + docs 数字重算；26 条门禁可信度发现（6 P2/20 P3）。
- R5：21 条最优性/回归/并发 findings，mmap A/B、JSON 语义、Observation、BatchRunner 取消、page-index、日期格式化等独立复现。

> 说明：分册是各 reviewer 在修复前的独立快照，文中 file:line/结论对应修复前 HEAD；修复后以本总览与最终提交为准。关键探针源码在 reviewer 的 `.gather/` scratch（gitignored），本轮未入库。
