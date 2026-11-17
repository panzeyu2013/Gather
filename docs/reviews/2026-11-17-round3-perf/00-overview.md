# 2026-11-17 第三轮性能专项加固审计（DB/查询 · 渲染 · 启动/内存 · 性能门禁）

- **日期**：2026-11-17（本地时区 CST/UTC+8）
- **基线**：`42a89e01`（前两轮共 10 个提交；远端 `origin/main` 仍为 `e5c54f37`，无新提交）
- **执行**：lead + 4 个 teammate（复用 perf-core / perf-ui / gate-smith，新增 perf-runtime；共享任务板 task-16…task-19）
- **环境与验证上限（重要）**：Linux / Ubuntu 22.04，**无 macOS/Xcode；未运行 `swift build` / `swift test` / Instruments / 真机 UI**。Swift 侧验证到：SwiftPM manifest 解析、`GatherProtocol` / `GatherPreviewData` 两个可移植 target 的 Linux 类型检查、全部 `.swift` 文件 `swiftc -parse`；另有大量独立 Linux Swift 探针（语义对拍 / 微基准 / 类型检查）与 Python SQLite 基准。macOS 上的绝对耗时、并发诊断与渲染行为仍需 CI / 真机复核。
- **分册**：`perf-db.md`、`perf-ui-round3.md`、`perf-runtime.md`、`gates-round3.md`（同目录）。

## 1. 结论摘要

| 维度 | 本轮增量 | 关键数字/证据 |
| --- | --- | --- |
| DB / 查询 | 证明并移除 gallery 主查询的冗余 `SELECT DISTINCT`；7 个热点的 `prepare` 从逐行/逐块改为复用（新增 internal `DBStatementCache`）；新增可复现 SQLite 基准工具 | gallery 查询 bench A/B **1.34–1.37x**（5k/20k 行）；AssetRepo 扫描 1 万张 ≈ **14 万次 prepare → 每 250 张批 ≤14 次（≈99.6%↓）**；prepare 成本微基准 ~2.0µs/次 |
| GatherUI 渲染 | `selectionSummary` O(1) 缓存（含 Observation 依赖修复）；`currentAsset` 同源 O(1) 页索引 helper 替换 11+ 处 O(page) 查找；Gallery 三套 O(1) 查询表 + 灯箱 O(1) 定位；预取磁盘探针移出主线程 | 500 张页 18 次查找 18.79µs → **0.71µs（≈26x）**；16 文件 +311/−94；800/600 组随机序列新旧对拍一致 |
| 启动 / 缓存 | 启动阶段唯一可证安全并行（语言播种 ∥ runtime.start）；新增 7 阶段启动计时日志；缩略图内存缓存 cost 改为真实位图像素；磁盘缓存启动后台 prune；关键词预览缓存行 500 条 SELECT → 1 条批量 | 300dpi 2048px 图旧 cost 低估 **17.4x**（512MB 上限失效）；关键词预览 500→1 次查询；启动计时一行/冷启动 |
| 性能门禁/仪表 | 新增 **gate #17 性能反模式 ratchet**（7 指标 + 基线 + CI）；`scripts/perf-sqlite-bench.py` 可复现 SQLite 基准（真实 DDL + 合成数据 + EXPLAIN + A/B，不进 CI）；report-baseline 增加性能基线输出 | 门禁 16→**17**；基线：raw DateFormatter 28 / ISO 30 / JSON enc 46 / dec 39 / regex 3 / byte 1 / blocking_sleep 1（均只降不升） |
| 文档 | 新增本轮总览 + 4 分册；docs 收尾同步门禁数/性能工作流/审计索引 | 文档事实门禁（round-2 引入）同步到 17 门禁后全绿 |

## 2. 方法与分工

1. **侦察定靶**：扫描残余 formatter/coder、`prepare`-in-loop（100+ 候选）、UI body O(n) 扫描、缓存上限、启动串行段；结合 round-2 分册的残余 P0/P1 清单切任务。
2. **4 路并行**：
   - `perf-core`（task-16）：Persistence 查询 + prepare 复用 + SQLite 基准工具 + Culling/Similarity/Face/Triage/Curation 服务批量化审计；
   - `perf-ui`（task-17）：Culling/Gallery 渲染路径 O(1) 化 + 预取主线程 I/O；
   - `perf-runtime`（task-18，新 teammate）：启动并行/计时 + 缓存/内存边界 + Metadata/Export/Delivery/Maintenance 服务批量审计；
   - `gate-smith`（task-19）：性能 anti-pattern ratchet 门禁 + 基线 + CI + report-baseline。
3. **lead 兜底**：Observe 依赖与只读池资源边界两处 review 拦截（见 §4/§5），最终验证、总览与提交。

## 3. 数据库 / 查询（`perf-db.md`）

- **移除冗余 DISTINCT**：`PhotoFilterQuery.filterPhotos`（图库主查询）原 SQL 带 `SELECT DISTINCT` + `LEFT JOIN photo_metadata_cache`。证明：(a) `photo_metadata_cache.photo_id` 为 UNIQUE（1:1，不增殖行）；(b) `buildWhereClause` 只生成标量比较 / `EXISTS` / 相关子查询，person/keywords/collection/stack/has_face/volume/has_duplicates 全部 EXISTS，无乘行 JOIN。移除后集合语义恒等，EXPLAIN 少一次 `USE TEMP B-TREE FOR DISTINCT`；bench（`--compare`，warm+median×15）5k 行 3.163→2.310ms（**1.37x**）、20k 行 5.958→4.487ms（**1.34x**）。残余 ORDER BY 临时 B 树与 DISTINCT 无关，建议后续走 `PhotoRepo.getAssetPage` 游标路径（不建议为 filename 加索引）。
- **prepare 复用**：新增 internal `DBStatementCache`（按完整 SQL 文本缓存语句；`query/run/get` 自带 bind+reset）。7 个热点：AssetRepo+Scan 每照片 ~14 条 SQL（1 万张≈14 万次 prepare）→ 每 250 张批内 ≤14 次；另 6 处（PhotoRepo.getLookupByIds、CullingReadQuery.existingPhotoIds/clearCullingProjection、DeliveryRepo.getMany、GlobalDuplicateQuery.photos 分块 IN，及 createRawJpegCandidates）每块 1 次。prepare 成本微基准 ~2.0µs/次（1000 次 A/B 3.8x）。
- **只读池资源边界（lead review 落实）**：`readPoolSize == 2`，只读 SELECT 语句存活期占池连接；因此 `DBStatementCache` 默认 `limit=1`，仅 AssetRepo 的 per-photo 缓存 `limit=14` 且建在 batch **事务闭包内**（语句走写连接、0 池占用、闭包结束释放）；调用点/池占用表见分册 §3.2。
- **SQLite 基准工具** `scripts/perf-sqlite-bench.py`（python3 标准库，开发工具不进 CI）：从 `SchemaCurrent+DDL*` 按生产顺序抽取真实 DDL（校验 55 表/86 索引/81 FK），确定性合成数据（默认 5k 照片，支持 20k/100k），13 条热点查询 median ms + EXPLAIN QUERY PLAN，支持 `--compare` A/B / `--rows/--seed/--repeats/--json/--keep-db`。已实测 5k 与 20k `--compare`。
- **服务批量化审计**：Culling/Similarity/Face/Triage/Curation 19 处逐行仓库调用逐条复核，均为「逐张独立提交/低量读/逐次而非逐行」设计，无安全新增修复；残留建议见分册 §6（含 `triage_suggestions(session_id, photo_id)` 覆盖索引等 schema 级建议，需下次 user_version 迁移）。

## 4. GatherUI 渲染（`perf-ui-round3.md`）

- **`selectionSummary` O(1) 缓存**：旧实现 `CullingInspector` body 每帧 2 次 O(page) filter + 2 个 Set。新增 `SelectionSummaryCache`，键 = `pageVersion` + `selectionVersion`（`selectedPhotoIds.didSet` 自增，Set 的 insert/remove/removeAll/formIntersection/subtract 均触发，已用 Swift 6.2 探针验证）。**lead review 拦截的 Observation 坑已修**：缓存命中路径也必须无条件读 `selectedPhotoIds`，否则 SwiftUI 不会在“只改选择集”时重算摘要（探针 A/B：修复前 onChange 不触发、修复后触发）；`page.didSet` 同时清两套缓存。800 组随机操作序列新旧对拍一致。
- **O(1) 页索引**：复用 round-2 的 `PageAssetIndex`，暴露 `pageIndex(ofPhotoId:)` / `pageAsset(forPhotoId:)` / `currentPageIndex()`，替换 `SecondDisplay/WorkbenchViewer/InfoBar/Inspector/Navigation/Grid/Actions/Preload` 共 11+ 处逐帧/逐键 O(page) 查找；nil/0 回退语义逐案保持（Linux 语义探针 + 500 张页 18 次查找 **18.79µs → 0.71µs**）。
- **Gallery O(1) 查询表**：新增 `GalleryLoadedPhotoLookup`（ids/filepaths/variantIDs/variantFilepaths/filenamesByID，与 `pagesGeneration` 同代懒构建）与 `filteredCache` 的 `indexByID`；替换滚动取页循环 contains、面板 nameFor、键盘游标、灯箱打开与 `LightboxView` 逐帧 O(n)×2 定位（600 组随机照片集对拍一致）。
- **预取主线程 I/O**：把预取“缓存命中探测”（磁盘 stat + 读整张 2560 预览 + touch mtime，一次翻片最多 5 条）移到 `Task.detached(priority: .utility)`；主线程不再同步 I/O，预热顺序/结果语义不变。
- **图片管线审计残余**（分册 §4.3，部分归其他 agent 后续）：`NSImage(data:)` 惰性解码可能主线程首绘解压；磁盘探针 stat+读整文件；`PhotoThumbnailCache.key` 每帧取锁、磁盘原子写/prune 在协作线程；Gallery 网格 1024 桶过解码等。

## 5. 启动 / 缓存 / 内存（`perf-runtime.md`）

- **启动**：round-2 已把 `Database.open` 与 `runtime.start` detach；本轮找到并落实**唯一可证安全**的并行——语言播种（settings 单条 SELECT + MainActor `LanguageStore.seed`，不广播）∥ `runtime.start`（executor/JobService/delivery 回放），await 顺序仍「语言先、start 后」以保持失败文案语言；四条安全性论证见分册 §1.3（无共享可变内存 / DB 锁语义 / 可观测顺序 / 取消与优先级）。其余（组合根同步装配、embedding 一次性迁移、恢复 journal）明确不并行。
- **启动计时**：新增 `StartupPhaseTimings`（单调时钟、MainActor 局部、无锁），冷启动成功/失败各 **1 行**日志：`restore / dbOpen / composition / languageSeed / runtimeStart / embeddingPrep / wire + firstScene / total`，为 macOS 实测提供数据入口（无逐帧成本）。
- **缩略图内存缓存计量**：`PhotoThumbnailCache` 的 NSCache cost 由 `NSImage.size`（点）改为 `NSImageRep.pixelsWide/High`（真实位图像素，取最大 rep）。由 JPEG data 构造的 NSImage 会按 DPI 折算 size：300dpi 的 2048px 图旧 cost 0.77MB vs 实际 13.4MB（**低估 17.4x**，512MB 上限形同虚设）；72dpi 相机直出两者相等，故旧值“看起来对”。
- **磁盘缩略图缓存启动 prune**：旧实现只有“下一次 store”才检查 512MB 上限，枚举成本落在首屏解码线程；新增 `pruneAtStartupIfNeeded()` 启动时丢到 `Task.detached(utility)`，进程内至多一次、仅删 thumb-cache 内缓存 JPEG。
- **服务批量**：`MetadataKeywordWriter` 关键词预览缓存行读取从循环内逐张 `get`（500 张=500 条 SELECT）→ 循环前一次 `getBatch`（800/块 IN）；失败整批按无缓存行处理，与逐张 catch→nil 的可观测语义一致。`BackupStore.list()` 的 `JSONDecoder` 与兜底 `ISO8601DateFormatter` 从逐文件构造提到循环外（≤20 文件）。
- **缓存审计结论**：已审无需改的有 NSCache 键（模式+path+size+epoch）、PhotoDecodeGate 在飞表归零、WatermarkLogoCache maxEntries=8、L10n 4096 整清、AF 机型表生产恒空、toast 上限 3、日志 5MB×5、模板撤销 retention=20 等；**记录未改**的需求决策项：人脸 `EmbeddingModel` provider 缓存无上限（建议 LRU 2–4）、控制中心 `jobs` 全量 list、图库 pages/loadedPhotos 长会话无上限（需 macOS 验证后窗口化）、MetadataDispositionService 冲突列表 N+1（需扩 public 端口）。

## 6. 性能门禁与仪表（`gates-round3.md`）

- **gate #17 `scripts/check-perf-ratchet.sh`**：对 `desktop/native/*/Sources/**/*.swift`（Tests 排除）统计性能反模式构造点，基线 `docs/perf-baseline.json`：`raw_date_formatter 28 / raw_iso_formatter 30 / raw_json_encoder 46 / raw_json_decoder 39 / raw_regex_compile 3 / raw_byte_formatter 1 / blocking_sleep 1`。非注释行计数（同 cleanup-ratchet 口径）、只降不升、`--write-baseline`、扫描量守卫、确定性输出。允许的共享缓存构造点（DisplayDateFormatters / JSONValueCoding / RepoJSONCoding / RepositoryDateFormatters / Mutex 锁盒子）已注明；新增裸构造需显式改基线。`blocking_sleep = 1` 为 JobService 罕见错误路径的终态写同步重试（已记录目标归零，待 async 化）。
- **CI**：接入 `.github/workflows/ci.yml` gates job；门禁 16→17。
- **report-baseline**：增加「性能 ratchet 基线」只读输出（基线字段 + 当前实测计数）。
- **`scripts/perf-sqlite-bench.py`**：可复现 SQLite 基准（见 §3），为后续 schema/查询决策提供 A/B 证据。

## 7. 验证证据（2026-11-17 本地实跑）

```text
# SwiftPM manifest / 可移植 target（Linux Swift 6.2）
dump-package gather-core / gather-app → OK
swift build --target GatherProtocol → OK
swift build --target GatherPreviewData → OK
# 语法：1089/1089 Swift 文件 swiftc -parse → 0 failures
# 门禁（Linux 可执行 16/17；check-warnings 需 macOS SDK）
no-legacy / cleanup-ratchet / layering / domain-events / domain-writes /
duplicate-symbols --strict / test-catalog --strict / preview-surface --strict /
design-system / select-star --strict / protocol-surface --strict / coded-errors /
backlog-evidence / repo-hygiene（7 节）/ perf-ratchet（17th） → PASS
docs-facts → 文档同步到 17 门禁后 PASS
git diff --check → 干净
# 基准/探针
scripts/perf-sqlite-bench.py（5k/20k --compare）→ exit 0
currentAsset/pageIndex/selectionSummary/Gallery lookup 语义对拍 → OK
Observation 依赖 A/B、@Observable+didSet、SQLite prepare 微基准 → OK
```

## 8. 风险与后续建议

1. **未编译/未运行**：DB 的 DISTINCT 移除与语句复用、SwiftUI 的 O(1) 缓存、启动并行与缓存计量都需 macOS CI 首跑确认（重点：PhotoFilter 契约测试、Swift 6 并发诊断、SwiftUI 渲染/交互回归、`check-warnings --warnings-as-errors`）。
2. **性能数字**：DISTINCT/prepare 数字来自 Python SQLite（同引擎、非 Swift 封装）的相对 A/B；其余为 Linux 同环境 A/B 或成本模型推导。macOS 上建议先抓 `startup phases:` 日志与 Instruments 时间线，再决定下一刀（图库分页窗口化、决策流重建、缩略图解码）。
3. **schema 级**（需一次 user_version 迁移 + 指纹同步）：`triage_suggestions(session_id, photo_id)` 覆盖索引；`session_assets.display_file_id`（唯一缺前导索引 FK，当前无查询使用）。
4. **门禁维护**：perf-ratchet 基线已钉住构造点数量；若要新增共享缓存/改基线需同步 `docs/perf-baseline.json`，并在 macOS 上确认并发契约。
5. **待决策内存项**：人脸 provider 缓存 LRU、控制中心 jobs 全量列表、图库长会话 pages 窗口化（均需产品/真机验证后实施）。
