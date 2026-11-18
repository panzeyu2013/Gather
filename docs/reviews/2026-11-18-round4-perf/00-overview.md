# 2026-11-18 第四轮性能专项审计（SQLite/查询 · 渲染缓存 · 任务/内存/元数据 · 性能门禁）

- **日期**：2026-11-18（本地时区 CST/UTC+8）
- **基线**：`2521c00b`（前三轮共 13 个提交；远端 `origin/main` 仍为 `e5c54f37`，无新提交）
- **执行**：lead + 4 个 teammate（perf-core / perf-ui / perf-runtime / gate-smith；共享任务板 task-21…task-24）
- **环境与验证上限（重要）**：Linux / Ubuntu 22.04，**无 macOS/Xcode；未运行 `swift build` / `swift test` / Instruments / 真机 UI**。Swift 侧验证到：SwiftPM manifest 解析、`GatherProtocol` / `GatherPreviewData` 两个可移植 target 的 Linux 类型检查、全部 `.swift` 文件 `swiftc -parse`；另有独立 Linux Swift 探针（语义对拍/编译级校验）与 Python SQLite 基准。macOS 绝对耗时、并发诊断、AppKit/ImageIO 行为仍需 CI 与真机复核。
- **分册**：`perf-db4.md`、`perf-ui-round4.md`、`perf-runtime4.md`、`gates-round4.md`（同目录）。

## 1. 结论摘要

| 维度 | 本轮增量 | 关键数字/证据 |
| --- | --- | --- |
| SQLite / 查询 | 新增 `PRAGMA mmap_size=256MB`（读写连接 + 只读池 + 备份校验连接）；关闭时 `PRAGMA optimize`（**评审 CORE-02 后移除**，见 §3）；再修 6 处 prepare 热点；bench 工具支持文件库/PRAGMA A-B/排序/facet 查询 | mmap A/B（20k 合成库）：metadata 批读 **1.37x**、sort rating **1.39x**、asset_page CTE 1.20x、list_page 1.12x；点查无回归；`PRAGMA optimize` 无 schema 变更 |
| GatherUI 渲染 | Culling 页索引在 state-only 更新时复用；网格布局缓存同几何复用；导航组大小/选择排序/相似组资产缓存；零分配 `activeFilterCount`；ForEach 去掉 `Array(enumerated)`；Gallery item→row O(1) | 决策帧 **155.5µs → 44.5µs**（200 帧仅 1 次重建）；网格 relayout **23.9µs → 0.4µs/决策**；9 文件 +250/−47 |
| 运行时 / 任务 / 内存 | `JobService` 终态写重试改 async（阻塞睡眠清零）；磁盘缩略图缓存 mtime 触碰节流（1h 窗口）；EmbeddingModel provider 缓存 LRU 上限 4；Metadata 冲突读盘有界并发；外部元数据迁移 decoder 复用；图片主线程惰性解码给了完整落地设计与延期理由 | 性能 ratchet：`blocking_sleep 1→0`、`try_optional 256/257`（评审修复后新增 1 处 detached sleep 的 try?，基线钉到 257/257）、`raw_json_decode_chain 23→22`；模型缓存由无界→4；冲突读盘并发 4 且取消安全 |
| 性能门禁/仪表 | 性能 ratchet 7→**9 指标**（新增内联 JSON 编解码链），基线收紧；`report-baseline` 同步 9 指标输出；本轮修复 lead 侧 `JSONValueDecoding` 逐次 coder | 基线：DateFormatter 28 / ISO 30 / JSON enc 45 / dec 38 / enc-chain 20 / dec-chain 22 / regex 3 / byte 1 / blocking_sleep 0 |
| 文档 | 新增本轮总览 + 4 分册；docs 收尾同步 9 指标与审计索引 | 文档事实门禁（17 门禁）保持绿 |

## 2. 方法与分工

1. **侦察定靶**：沿 round-3 分册的残余 P0–P2 清单 + 新一轮扫描（SQLite PRAGMA 现状、图片管线、无界缓存、剩余 N+1、Job 轮询/重试、Gallery 长会话增长、排序/ facet 查询计划）。
2. **4 路并行**：
   - `perf-core`（task-21）：SQLite PRAGMA（mmap/optimize）、bench 工具扩展、查询审计、Persistence prepare 热点；
   - `perf-ui`（task-22）：Culling 索引/布局缓存复用、Gallery 渲染审计；
   - `perf-runtime`（task-23）：图片解码/磁盘缓存、Job async 重试、模型 LRU、Metadata 并发/解码；
   - `gate-smith`（task-24）：perf ratchet 扩展 + 基线收紧 + 台账。
3. **lead 兜底**：修复 `Support/JSONValueDecoding` 的逐次 coder（改为共享 `JSONValueCoding`）；补 `report-baseline` 的两条新指标（并修正 POSIX 与 Python 正则差异）；审计目录改名为 `2026-11-18-round4-perf`；最终验证、总览与提交。

## 3. SQLite / 查询（`perf-db4.md`）

- **`PRAGMA mmap_size = 256MB`（采纳）**：`DBConnection.open()` 对文件库（读写连接、只读池、备份校验连接）统一设置，`:memory:` 跳过；失败走既有 `applyPragma`（warn + 保留 SQLite 值）。bench A/B（`--file-db --pragma-ab mmap_size=...`，20k 合成库，默认↔设定↔恢复复测、取 min 基线）：list_page 5.00→4.48ms（**1.12x**）、metadata 批读 4.48→3.28ms（**1.37x**）、asset_page CTE 2.45→2.04ms（**1.20x**）、sort filename 1.19x、sort rating **1.39x**、facet.camera 1.21x、facet.person 1.24x；点查/小结果集 0.97–1.01x 无回归。语义：mmap 只影响 DB 文件读页（WAL/写/事务不变）；256MB 是单连接映射上限非预分配；网络卷上 SQLite 自动回退普通 pager。
- **~~`PRAGMA optimize`（关闭时 best-effort）~~（评审 CORE-02 后移除）**：2026-11-18 独立评审指出三点：① `PRAGMA optimize` 可能写 `sqlite_stat1`（ANALYZE），使文档声明「只读」的 CLI（`gather-triage-eval`）在退出时写库；② 首次 ANALYZE 耗时无上界且发生在 close 持有 `Database.stateLock` 的退出路径；③ 收益接近零（统计通常已新）。已从 `Database.close()` 移除；如需刷新统计应在维护流程里显式执行（当前无自动任务）。
- **prepare 复用再扩 6 处**（沿用 round-3 `DBStatementCache`）：`CollectionRepo.existingPhotoIds/removeItems`、`StackRepo.stackIdsByPhoto/removeMembers/detachPhotos`、`FaceRepo+Observations.invalidateDerivedResults`（每块 5 条写语句，10k 照片≈125 次 prepare → 事务内复用）。只读池边界同 round-3（SELECT 缓存默认 limit=1）。
- **bench 工具扩展**（`scripts/perf-sqlite-bench.py`，仍为开发工具不进 CI）：新增 `--file-db`（PRAGMA 实验必需）、`--pragma NAME=VALUE`、`--pragma-ab NAME=VALUE`（默认↔设定↔恢复逐查询 A/B）、gallery 排序模式 ×3（filename/date_taken CASE/rating）、facet 查询 ×3（camera ROW_NUMBER 代表行、keyword 顶级桶、person 桶，SQL 与 `FacetQuery` 同构），新增 persons/person_photos/photo_keywords 合成数据；默认 5k 与 20k 均跑通。
- **查询审计（无 schema 改动）**：三种 gallery 排序全部 `USE TEMP B-TREE FOR ORDER BY`（filename 无复合索引；date_taken 为 CASE 表达式不可普通索引；rating 在 JOIN 侧）；20k 实测 filterPhotos≈5.0ms vs `asset_page` 游标 CTE≈2.45ms ⇒ 纯翻页/选片路径推荐走已有 cursor 实现；facet 实测 camera 5.53ms / keyword 11.45ms / person 2.66ms，建议服务层按（session, criteria 指纹）缓存、关键字维懒加载/限 limit；候选索引（如 `photos(session_id, filename)`）留待下次 `user_version` 迁移统一评估并同步指纹。

## 4. GatherUI 渲染（`perf-ui-round4.md`）

- **Culling 页索引 state-only 复用（P0）**：`page.didSet` 自增 `pageAssignmentCount`（任何赋值路径，含不 bump pageVersion 的直接赋值）；索引按「赋值代数相同 → O(1) 命中；代数变化但 O(n) id 序列相同（决策回显只改 state）→ 复用位置索引；序列变化（重排/筛选/换页/追加）→ 重建」。返回资产始终从当前 page 现取（state 不过期）；`selectionSummary` 失效语义保持。Linux 探针（真实 DTO）对拍 10 类场景一致；500 张页决策帧 **155.5µs → 44.5µs**（200 帧仅 1 次重建）。
- **网格布局缓存同几何复用（P1）**：`CullingGrid` 布局缓存按「id 顺序 + 量化宽高 + 精确 width/rowHeight + count」快路径复用；决策回显不再每拍 relayout 500 张（探针 **23.9µs → 0.4µs/决策**）。
- **其它 O(n)/分配热点**：`navigationGroupSizeByPhotoID` 按 groups 赋值代数缓存（网格 body 每帧读→O(1)）；`activeFilterCount` 去掉每次读取的 7 元素数组+filter（零分配）；选择集排序快照缓存（Culling 复用 `selectionVersion`、Gallery 新增同机制；命中路径仍读选择集 count 保 Observation 依赖）；`currentGroupAssets` 按（页赋值代数, groupId）缓存；胶片条/两个网格的 `ForEach(Array(enumerated()))` 去掉每帧数组分配（身份仍 photo.id / Int 行号）；Gallery `GalleryLayoutCache` 建行时顺手建 item→row 映射，键盘游标定位 O(rows×items)→O(1)。
- **残余（需 macOS/真机）**：缩略图解码桶偏大（默认 1024 档 vs 单元格 160–300pt，改小属可见清晰度/设置语义变化）；`CullingComparison` 对比布局每帧 O(page) filter/firstIndex；组视图每 pageVersion 变化 O(n log n) projection；ForEach 数据集合类型变化属身份敏感项，需真机滚动/scrollTo 验证（可单点回退）。

## 5. 运行时 / 任务 / 内存 / 元数据（`perf-runtime4.md`）

- **JobService 终态写重试改 async**：`writeTerminal` 的瞬时 DB 写失败重试等待由同步 `Thread.sleep(0.2)` 改为 `Task.sleep(for:.milliseconds(200))`（`settle`/`writeTerminal` 改 async，调用点更新），不再阻塞协作线程池；重试次数/顺序/间隔/错误返回不变，取消时立即重试一次（与旧「至少重试一次」一致）。**perf ratchet `blocking_sleep` 1→0（零容忍）**。
- **缩略图磁盘缓存 mtime 触碰节流**：命中路径原来每次都 `setAttributes(mtime)`（读放大为 inode 元数据写）；改为 1h 窗口内跳过（stat 缓存文件判断），元数据写 ≤1 次/小时/文件；LRU 按 mtime 的粗粒度仍足够（只影响间隔 <1h 的相对顺序，目标是清真正冷缓存）。
- **EmbeddingModel provider 缓存 LRU**：无界字典（同路径换权重/指纹/computeUnits 会不断编译几十 MB 级 CoreML provider）→ `maxProviders=4` + 访问序 LRU，单飞（锁内编译）保留；驱逐只丢缓存引用，在飞推理持有强引用不受影响。
- **Metadata 冲突读盘有界并发**：`MetadataDispositionService.conflicts()` 逐条串行 `await xmp.readAttributes` → `batchAsync(concurrency: 4)`；DB items 仍串行（端口只有单行 API，不改公开协议）。**发现并修复取消坑**：`BatchRunner` 取消会在部分结果处返回，直接按下标对齐会错位/越界 → 用 `Task.detached` 隔离取消并保持与 rows 严格一一对应（对外签名/保序/try?-empty 语义不变）。
- **外部元数据迁移 decoder 复用**：`ExternalMetadataMigrationService` 逐候选 `JSONDecoder()` → 共享静态 decoder（透过多方式探针 + Swift 6 Sendable 校验），输出与失败回退语义不变。
- **图片主线程惰性解码（评估后延期，附落地方案）**：`NSImage(data:)` 在视图任务线程创建、首绘时惰性解码；直接改 `CGImageSource→NSImage(cgImage:size:)` 有三处 macOS-only 风险（DPI→点尺寸语义、EXIF Orientation 应用差异、NSImage 非 Sendable 的并发形状）。给出「DPI 存在且 dpiX==dpiY 且 orientation=1 子集 A/B + Instruments + 回退开关」的后续方案，本轮不改。
- **其它记录项**：模板预览 N+1（每张 2 条 SQL，需 MetadataService 批量 API/公开面扩张，暂记录）；sidecar 二次解析（同数据 2 次 XMLParser + normalize 往返，给出可证明等价的两步优化提案，文件在 GatherMetadataIO 写域外）；`PhotoDecodeGate.awaitShared` 的 50ms 轮询实现「取消即返回」（竞态敏感，建议用 continuation/cancellation handler 后续处理）。

## 6. 性能门禁与仪表（`gates-round4.md`）

- **perf ratchet 指标 7→9**：新增 `raw_json_encode_chain`（内联 `JSONEncoder().encode`）与 `raw_json_decode_chain`（内联 `JSONDecoder().decode`）——round-4 修复了逐次 coder 的 transcode 出口，新增内联链是最可能的回潮方式。当前基线：DateFormatter 28 / ISO 30 / JSONEncoder 45 / JSONDecoder 38 / encode-chain 20 / decode-chain 22 / NSRegularExpression 3 / ByteCountFormatter 1 / **blocking_sleep 0（零容忍）**。
- **基线收紧**：encoder 46→45、decoder 39→38（lead 修复 `JSONValueDecoding` 的共享 coder）、decode_chain 23→22、blocking_sleep 1→0；门禁仍为 **17 道**（无新增脚本），CI 不变。
- **report-baseline 同步 9 指标**：性能 ratchet 段现在输出 9 项 current/baseline/status（本轮修复了该脚本中 POSIX 与 Python 正则差异导致的 2 项恒 0 问题）。
- 保持：允许的共享缓存构造点（DisplayDateFormatters/JSONValueCoding/RepoJSONCoding/RepositoryDateFormatters/Mutex 锁盒子）已注明；新增裸构造需显式改基线。

## 7. 验证证据（2026-11-18 本地实跑）

```text
# SwiftPM manifest / 可移植 target（Linux Swift 6.2）
dump-package gather-core / gather-app → OK
swift build --target GatherProtocol    → OK
swift build --target GatherPreviewData → OK
# 语法：全部 Swift 文件 swiftc -parse → 0 failures
# 门禁（Linux 可执行 16/17；check-warnings 需 macOS SDK）
no-legacy / cleanup-ratchet / layering / domain-events / domain-writes /
duplicate-symbols --strict / test-catalog --strict / preview-surface --strict /
design-system / select-star --strict / protocol-surface --strict / coded-errors /
backlog-evidence / repo-hygiene（7 节）/ perf-ratchet（9 指标）/ docs-facts → PASS
git diff --check → 干净
# 基准/探针
scripts/perf-sqlite-bench.py（5k/20k，--pragma-ab mmap_size）→ exit 0
pageIndex/grid-layout/caches/OCR? 语义对拍 → OK
LRU/retry/throttle/conflicts 探针（Swift 6 -warnings-as-errors 编译级）→ OK
```

## 8. 风险与后续建议

1. **未编译/未运行**：mmap（close optimize 已移除）、prepare 复用、SwiftUI 缓存、Job async、模型 LRU、Metadata 并发都需 macOS CI 首跑确认（重点：DatabasePragmaTests、close 语义/WAL、并发诊断、UI 渲染/交互回归、check-warnings）。
2. **性能数字**：Python SQLite（同引擎非 Swift 封装）相对 A/B + Linux 同环境探针/成本模型；mmap 在 macOS 冷启动通常更明显，最终以 macOS 复核。
3. **schema 级建议（下次 user_version 迁移）**：`photos(session_id, filename)` 与 `triage_suggestions(session_id, photo_id)` 索引、facet 查询缓存/懒加载；需同步 `expectedExplicitIndexCount`/指纹。
4. **需 macOS 才能推进的项**：NSImage 惰性解码（方案已备）、ForEach 身份类型变化类改动、缩略图解码桶调优、模板预览批量 API（需公开面扩张）、sidecar 单次解析。
5. **门禁维护**：perf ratchet 9 指标基线已收紧，新增共享缓存/改基线需同步 `docs/perf-baseline.json` 并在 macOS 确认并发契约。
