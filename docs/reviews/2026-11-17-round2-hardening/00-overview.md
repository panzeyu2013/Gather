# 2026-11-17 第二轮全量加固审计（性能 / 测试 / 门禁 / 国际化 / 设计）

- **日期**：2026-11-17（本地时区 CST/UTC+8）
- **基线**：`4cb3228d`（第一轮质量加固的 5 个提交；远端 `origin/main` 仍为 `e5c54f37`，本轮未再拉取到新提交）
- **执行**：lead + 6 个子代理（复用第一轮同一批 teammate：gate-smith / perf-ui / perf-core / test-steward / ui-copy / design-tokens；共享任务板 task-9…task-14）
- **环境与验证上限（重要）**：Linux / Ubuntu 22.04，**无 macOS/Xcode，未运行 `swift build` / `swift test` / 真机 UI**。Swift 侧验证到：SwiftPM manifest 解析、`GatherProtocol` / `GatherPreviewData` 两个可移植 target 的 Linux 类型检查、全部 `.swift` 文件 `swiftc -parse`；另有若干独立 Linux Swift 探针用于 A/B 语义与性能对照（见各分册）。macOS 运行时行为、渲染与截图验证仍需 CI/真机。
- **分册**：`perf-core-round2.md`、`perf-ui-round2.md`、`test-hygiene-round2.md`、`design-empty-round2.md`（同目录）。

## 1. 结论摘要

| 维度 | 第二轮增量 | 关键数字/证据 |
| --- | --- | --- |
| 质量门禁 | 新增 **文档事实门禁**（gate #16）：文档基线数字必须与源码计算一致；卫生门禁新增 **本地化用法守卫** [g]（UI 文案 CJK 字面量必须走 l10n）；修正设计门禁 `theme.legacyAlias` 误报；新增 `.gitattributes`；CI gates job 接入 Docs facts | 门禁 15→**16**；卫生门禁 6→**7 节**；1,750 个 CJK 字面量全部已包裹 |
| 性能（core） | 2 处 N+1 批量化（Culling 导入判断、资产包人物解析）；3 组逐次正则编译改 `Synchronization.Mutex` 锁盒子缓存（Navigation 文件名序号、sidecar IPTC 读取/写回）；QualityService / ModelReview / LibraryPackage 逐行 formatter·coder 收口；Python sqlite3 查询计划审计 | 逐张查询数百~数千次/批 → 1 次批量；正则首次后 0 编译；查询计划 8 条 + 2 条索引建议 |
| 性能（UI） | `CullingViewModel.currentAsset` **O(page)→O(1)**（pageVersion 全量失效审计 + `didSet` 双保险，Linux 探针语义对拍）；`DisplayDateFormatters` 增加字节数/ISO 输出/固定 UTC 缓存并接入 8 处调用；Metadata 批量时间、WebDAV 到期时间、InfoBar 下标、Gallery 已加载 id 集合 hoist | 500 张页 currentAsset 命中 ~2.5µs vs 旧 18 次扫描 ~20.3µs（同环境 A/B）；ISO 输出 43.4µs→1.12µs；字节量级探针 10 例等价 |
| 测试卫生 | App 固定 sleep 等待改共享 `waitUntilAsync`；Core 三份重复 `Thread.sleep` 轮询 helper 合并为共享 async helper；墙钟上界容忍度修正；新增 2 个缓存回归测试文件 | sleep 站点 49→**32**（Thread.sleep 6→2）；App 固定等待 17→4（余下有意并注释）；重复 helper 4→0；@Test 3,255→**3,267**、@Suite 417→**419**、断言 14,911→**14,954** |
| 国际化 | 新增本地化用法守卫发现的 7 处硬编码 CJK 标点全部改为本地化格式键（en 用 ASCII 标点，zh 输出逐字不变） | 未包裹 7→0；en 键 2,680→**2,682** |
| 设计一致性 | 17 处**页面级**空态由系统 `ContentUnavailableView` 迁移为品牌 `GatherEmptyState`（3 处按策略保留：2 处 List 行内 + 1 处 `.search`）；设计文档校准（删除从未落地的 `GatherSection` 等虚构组件） | `empty.contentUnavailable` 28→**10**；`theme.legacyAlias` 5→**1**；设计 ratchet 基线收紧 |
| 文档 | 新增 `docs/reviews/README.md` 审计索引；`report-baseline.sh` 增加"门禁脚本数"事实；本轮总览 + 4 分册 | 索引 8 链接全部可解析 |

## 2. 方法与分工

1. **先同步与侦察**：`git fetch`（远端无新提交）→ 静态扫描（残余 formatter/coder、`NSRegularExpression`、测试 sleep、空态站点、本地化裸字面量、COPY 启发式）→ 按第一轮分册的残余 P0/P1 清单切任务。
2. **复用第一轮 teammate**（保留上下文与作用域纪律），6 个任务并行/串行混合：
   - 并行：`gate-smith`（task-9 门禁/文档事实/.gitattributes/索引）、`perf-ui`（task-10 UI 性能）、`perf-core`（task-11 core 性能/查询计划）、`test-steward`（task-12 测试卫生）、`ui-copy`（task-13 i18n 标点修复）；
   - 串行：`design-tokens`（task-14 空态迁移，等 ui-perf 收尾避免同一文件并发写）。
3. **lead 兜底**：4 处过期的文件头注释修正、跨分册事实校核（FK 索引口径更正）、总览与验证、提交。

## 3. 质量门禁（本轮新增/加固）

- **`scripts/check-docs-facts.sh`（gate #16）**：从源码计算 targets（13/5/18，functional 9）、域 API（16 协议 / 195 方法需求）、本地化 en/zh key 数、schema expected*（55/451/86/81）、门禁脚本数（`scripts/check-*.sh` − `check-appintents.sh`），再校验 README / docs/README / docs/DEVELOPMENT 的断言与门禁清单；不一致时打印「期望值 + 文档现状 + file:line」。已接入 CI gates job；源码或文档任一侧漂移都会 FAIL。
- **卫生门禁 [g] 本地化用法守卫**：对 GatherUI 全部 UI 文案调用做括号平衡解析，要求 CJK 字面量必须处于 l10n/`l`/LocalizedText/Notice/CommandError.localized 等包裹内；跳过注释、#Preview 与 PreviewSupport 样例数据。当前 272 文件 / 2,264 UI 调用 / 1,718 CJK 字面量 **全部已包裹**。
- **设计门禁误报修正**：`theme.legacyAlias` 正则加 `\b`，不再把 `GatherTheme.primaryText` 前缀命中为 legacy 别名（5→1 为真实值）。
- **`.gitattributes`**：`* text=auto eol=lf` + 显式文本/二进制规则（CoreML 包、图片、PDF、SQLite、归档）；ratchet baseline JSON 标 `linguist-generated`。
- **`docs/reviews/README.md`**：评审目录索引（轮次/主题/状态/入口文档链接），并约定"基线变动必须记账"。

## 4. 性能：gather-core（`perf-core-round2.md`）

- **N+1 批量化**：
  - `CullingService+Commands.applyImportedPicks`：旧实现逐 photoId `getDecision` + 逐兄弟变体点查（几百张勾选≈上千次单行查询）→ 先按「勾选 ∪ 资产变体」并集一次 `getByPhotoIds`（800 分块）；本批已写过的照片/资产回退实时读，**revision/人工保护/结果顺序/失败计数与逐张实现一致**。
  - `LibraryPackageService` 导入：逐 binding `personsRepo.get(id:)`（数千次）→ 复用已加载的人群列表建 `knownPersonIDs` 集合；新 id 并入集合；三级身份解析顺序不变。
- **逐次正则编译 → 锁盒子缓存**：实测 Swift `Regex` 在 Swift 6.2 下**非 Sendable** 且 `\d` 语义与 ICU 不等价（5,000 随机串差分 1,412 处），故不采用静态 Swift Regex；改用 `Synchronization.Mutex` 锁盒子缓存 `NSRegularExpression`（不新增 `@unchecked Sendable`，ratchet 60/60）：`NavigationService.filenameSequence`（逐行路径 + burst/scene 两 pass 预计算上提）、sidecar IPTC 读取（decl/tag/rdf:li/xml:lang）。
- **formatter/coder 收口**：`QualityService`（1 万张≈2 万次 encoder→0）、`ModelReviewService`（逐条 decoder/encoder）、`LibraryPackageService`（逐照片 JSON 解码）改用实例/共享 coder；其余 per-call 站点已分类并记录"为何不修"。
- **查询计划审计（Python sqlite3）**：按真实 DDL 重放（55 表 / 86 索引 / 81 FK 与 expected* 一致），8 条热点查询 EXPLAIN QUERY PLAN：多数索引良好；建议 ① `triage_suggestions` 载入加 `(session_id, photo_id)` 覆盖索引（当前有 TEMP B-TREE FOR ORDER BY）；② `photo.list_page` 的 DISTINCT+ORDER BY 临时 B 树建议走既有游标 API（不为该查询加索引）。生产无 ANALYZE，结论仅供参考；schema 变更需 `user_version` 迁移 + 指纹同步，本轮不动 schema。
- **更正第一轮总览的一处口径**：用 `PRAGMA foreign_key_list/index_list` 逐列核对（含 PK/UNIQUE 自动索引）后，真正缺前导索引的 FK 子列只有 **1 个**（`session_assets.display_file_id`，且源码无按该列过滤的查询）；只计显式 `CREATE INDEX` 时才为 19。第一轮总览写的"10 个"不准确，已在本轮文档与第一轮总览中更正。

## 5. 性能：GatherUI（`perf-ui-round2.md`）

- **P0 `currentAsset` O(page)→O(1)**：CullingInspector 一帧直接/间接读 ~18 次、页 500 张时每帧上万次 id 比较。实现：`@ObservationIgnored` 位置索引缓存（pageVersion 键）+ `page` 的 `didSet` 双保险；**7 处生产 `page` 赋值全部 bump pageVersion**（补上了 `sessionId 为空清页` 的遗漏点）；语义（nil/空页/未命中→页首、重复 id→首个）用真实 `CullingAsset/CullingPage` 的 Linux 探针对拍一致。`@Observable + didSet` 的 Observation 兼容性由 lead 独立探针验证（typecheck + 运行时 onChange/didSet 观测）。
- **formatter 缓存扩容**：`DisplayDateFormatters`（既有锁盒子）新增 `fileSize`（ByteCountFormatter，locale 变化重建）、ISO 输出、固定 UTC 解析/格式化；接入 CollectionView 成员行、MetadataSyncBar、备份列表、导出预览/交付确认、Metadata 批量时间偏移（65.5µs→23.0µs/次）、WebDAV 到期时间（43.4µs→1.12µs/次）。
- **body hoist**：`CullingInfoBar.currentIndex` 每帧 2 次 O(page) → 1 次；`GalleryInspector` 场景标签种子 O(n) `contains` ×2 → VM 维护的 `loadedPhotoIdSet`（与 flatCache 同 pagesGeneration 失效）。
- **诚实成本**：ByteCount 缓存在 Linux 上构造占比仅 ~1%，收益小、保留理由是输出等价 + 零行为风险；如 macOS 实测无收益可回退 5 处单行。

## 6. 测试卫生（`test-hygiene-round2.md`）

- **共享异步等待**：新增 `GatherTestSupport/AsyncWait.swift`（sync + async 条件等待，`ContinuousClock` 单调计时、`Task.isCancelled`、超时返回最后求值），core/app 测试共用；删除 app 侧私有 `waitUntilAsyncCondition` 副本与 core 三份 `Thread.sleep(0.02)` 轮询 helper（4→0）。
- **替换清单**：App 固定"等落定"等待 17→4（余下 4 处为有意的负向窗口/替身延迟，已注释并断言）；Core `ReadPoolTests`/`DirectoryWatcherTests` 的 deadline+sleep 轮询迁到共享 helper；sleep 站点 49→32、`Thread.sleep` 6→2。
- **墙钟容忍度**：`ReadPoolTests` 改 `ContinuousClock` + <1s；`ExportPostCommandTests` 子进程 5s→30s、上界 <10s；`CullingDecisionRepoTests` 删除 2ms 播种、改固定时间戳断言 ON CONFLICT **保留 created_at 且推进 updated_at**（比原断言更强且确定性）。
- **新增回归测试**：`DisplayDateFormattersTests`（6 个：缓存输出 vs 每次新建 oracle 逐字节、zh/en、两种 ISO 解析、fallback 语义）、`JSONValueCodingTests`（6 个：共享 coder vs 默认 coder 值等价/往返/损坏输入错误一致；原「逐字节」断言经 2026-11-18 评审 R3-T01/R5-02 修正——Foundation 不承诺对象键序字节稳定，已改为值等价 + 标量/数组字节断言）。@Test 3,255→3,267、@Suite 417→419、断言 14,911→14,954。

## 7. 国际化与设计一致性

- **i18n 标点本地化**：卫生门禁 [g] 首次运行报出 7 处裸 CJK 标点（`、`、`：`、`，`、`（）` 位于动态拼接/分隔符）→ 改为本地化格式键（新增 2 个 en 键、复用 2 个既有键），English 输出改 ASCII 标点；用 Linux Swift 运行时探针验证 zh 输出与旧插值逐字一致、en 输出正确。en 键 2,680→2,682。
- **空态品牌化**：按 `docs/design/appearance-interaction.md` §空态策略（页面级用 `GatherEmptyState`；List Section 行内保留系统空态），20 处 `ContentUnavailableView` 站点中 **17 处页面级迁移**、3 处保留并记录原因（Dashboard 两处 List Section 行内、Persons `.search`）。字符串字面量多重集与 HEAD 完全一致（文案零变化），图标/动作/禁用态保持；设计 ratchet `empty.contentUnavailable` 28→10。
- **设计文档校准**：`appearance-interaction.md` 修正 7 处过期内容（含 **`GatherSection` 组件从未落地** → 分区配方改为系统 `Section`；删除已不存在的 `windowBackground`；空态度量说明；迁移状态表）。
- **残余**：Persons 整页"空库"仍是自绘 hero 卡片（非 CUV 站点），与品牌空态两种视觉语言，建议后续统一；Culling `emptyGuide` 外层 48pt padding 与组件内 24pt 形成双层内边距（布局刻意保留，需截图复验）。

## 8. 文档与索引

- `docs/reviews/README.md` 新增评审索引（4 个既有轮次 + 本轮 + 单篇台账），约定入口文档与 ratchet 记账规则；本轮目录 `2026-11-17-round2-hardening/` 含总览 + 4 份分册。
- `scripts/report-baseline.sh` 增加"门禁脚本（docs 口径）"事实输出（门禁数 16 + 清单 + 排除 check-appintents 说明），docs-facts 与文档校准同一口径。
- 第一轮总览的 FK 索引口径已按本轮查询计划分析更正（见 §4）。

## 9. 验证证据（2026-11-17 本地实跑）

```text
# SwiftPM manifest / 可移植 target（Linux Swift 6.2）
dump-package gather-core / gather-app → OK
swift build --target GatherProtocol    → OK
swift build --target GatherPreviewData → OK
# 语法：全部 Swift 文件 swiftc -parse → 0 failures
# 门禁（Linux 可执行 15/16；check-warnings 需 macOS SDK）
no-legacy / cleanup-ratchet / layering / domain-events / domain-writes /
duplicate-symbols --strict / test-catalog --strict / preview-surface --strict /
design-system / select-star --strict / protocol-surface --strict / coded-errors /
backlog-evidence / repo-hygiene（7 节含 shellcheck + l10n 守卫） → PASS
docs-facts → 文档同步后 PASS（本目录合入前由 docs 收尾）
git diff --check → 干净
# 独立 Linux 探针（A/B）
currentAsset 语义对拍、@Observable+didSet 观测、NSRegularExpression-vs-Regex 差分、
DisplayDateFormatters 输出等价、ByteCount/ISO/批量时间 A/B、i18n zh 逐字一致
```

## 10. 风险与后续建议

1. **未编译/未运行**：所有 Swift 改动（N+1、锁盒子正则缓存、pageVersion 失效、空态迁移、异步测试迁移、新测试）最终需 macOS CI 首跑确认：`check-warnings`、core/app 全量测试、SwiftUI 渲染截图（空态品牌化是**有意视觉变化**）。
2. **性能收益**：全部为构造次数/复杂度与 Linux 同环境 A/B 推导，非 macOS Instruments 实测；建议复测 `currentAsset` 路径、Metadata 批量时间偏移、导航分组。
3. **schema 性能项**：唯一真正缺前导索引的 FK 子列是 `session_assets.display_file_id`（当前无查询使用）；若未来加索引需 `user_version` 迁移 + 指纹/计数同步。
4. **测试运行时**：新增 12 个测试与 async 迁移需 macOS 全量跑一遍确认耗时与稳定性；负向窗口（500/80/40ms）仍是有界墙钟窗口。
5. **门禁维护**：docs-facts 会把"数字漂移"变成红灯——文档侧改了措辞/数字需同步 `report-baseline.sh` 口径；shellcheck 版本由 CI ubuntu-latest 自带，仍存在版本漂移风险。
6. **设计收尾**：Persons 空库 hero 卡与品牌空态并存、Culling `emptyGuide` 双层 padding 待截图复验；`font.systemSize` 14 处为固定尺寸 chrome/品牌数字，按动态字号语义不强行 token 化（已记录理由）。
