# gather-core DB 性能审计 R3：gallery DISTINCT / prepare hoisting / sqlite bench（task-16）

- **日期**：2026-11-17（基线：git HEAD `42a89e01` + round-3 工作区改动）
- **执行**：perf-core（子代理；写作用域 `Sources/GatherPersistence/**`、
  `Services/{Culling,Similarity,Face,Triage,Curation}/**`、`scripts/perf-sqlite-bench.py`、本文档）
- **约束遵守**：无 schema DDL/fingerprint 变更、无公开 API 变更（新增 `DBStatementCache` 为
  internal）、无行为/输出/错误语义变更、无新 `@unchecked Sendable`（ratchet 60/60）、
  无测试改动、未 commit、未回退 peers 改动。
- **改动面**：7 个 Swift 文件（+64/−26 左右；其中新增 `DBStatementCache.swift` 1 文件）
  + 新增 `scripts/perf-sqlite-bench.py`。

## 1. 结论摘要

| # | 交付 | 结果 |
|---|------|------|
| D1 | `PhotoFilterQuery.filterPhotos` 的 `SELECT DISTINCT` | **证明冗余后移除**（无增殖 JOIN + `photo_metadata_cache.photo_id UNIQUE`）；bench A/B：5k ≈ **1.37x**、20k ≈ **1.34x**，EXPLAIN 少一次 `TEMP B-TREE FOR DISTINCT` |
| D2 | prepare hoisting | **7 个同 SQL-in-loop 热点**：per-photo 14 条（AssetRepo+Scan）从 ~10k×14 ≈ 14 万次 prepare 降到每 250 张一批 ≤14 次（≈ 99.6%↓）；6 处分块 IN/写入循环每块 1 次 → 满块 1 次 + 末块现场 |
| D3 | `scripts/perf-sqlite-bench.py` | 真实 DDL（55 表/86 索引/81 FK 校验）+ 确定性合成数据 + 热点查询 median/EXPLAIN + `--compare` A/B + `--rows/--json/--keep-db`；已跑通 5k/20k；**不进 CI** |
| D4 | 5 个 service 子目录批量化审计 | 逐行仓库调用 19 处全部复核：均属「逐张独立提交/低量」设计或已批量化；本轮无「明显安全」的新修复，残留见 §5 |
| D5 | `DBStatementCache` 只读池资源边界 | 默认 `limit=1`（readPoolSize=2）；缓存多语句仅允许事务内写连接场景（AssetRepo+Scan `limit=14`，0 条池连接占用）；call-site 表见 §3.2 |

## 2. D1：gallery `SELECT DISTINCT` 分析（verdict + bench）

`PhotoFilterQuery.filterPhotos`（`:135-176`）原 SQL：
`SELECT DISTINCT p.id, … FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
 WHERE p.session_id = ? AND (<criteria>) AND p.archived_at IS NULL [ORDER BY …]`。

**证明 DISTINCT 冗余**：
1. `photo_metadata_cache.photo_id` 在 DDL 中是 `UNIQUE`（1:1），LEFT JOIN 不会增殖行；
2. `buildWhereClause`（`:458-499`）只拼「标量比较 / EXISTS / 相关子查询」—— person、keywords、
   keyword_path、collection/stack、has_face、volume、has_duplicates 全部是 `EXISTS (...)` 或
   标量子查询（`:691-1170`），**没有任何会乘行的顶层 JOIN**；
3. 因此每张照片至多返回一行，`DISTINCT` 不改变结果集、顺序、错误语义。

**处理**：移除 `SELECT DISTINCT` → `SELECT`（`:145-156`，附证明注释）。唯一可观察差异是计划里
少了 `USE TEMP B-TREE FOR DISTINCT`；输出行/顺序完全一致（等价性论证见上，属集合语义恒等）。

**Bench A/B（`scripts/perf-sqlite-bench.py --compare`，2 个会话 × 2500/5000 张，warm+median 15 次）**：

| 数据集 | A: DISTINCT（改前） | B: 无 DISTINCT（改后） | 加速比 |
|---|---|---|---|
| 5k 行 | 3.163 ms | 2.310 ms | **1.37x** |
| 20k 行 | 5.958 ms | 4.487 ms | **1.34x** |
| 5k 行、无 ORDER BY（隔离 DISTINCT 自身成本） | 3.152 ms | 2.432 ms | **1.30x** |

EXPLAIN QUERY PLAN 差异（其余部分相同）：
```text
A（DISTINCT）: SEARCH p USING INDEX idx_photos_asset_group (session_id=?)
              CORRELATED SCALAR SUBQUERY / SEARCH fo USING INDEX idx_face_observations_photo
              USE TEMP B-TREE FOR DISTINCT        ← 消失
              USE TEMP B-TREE FOR ORDER BY
B（无 DISTINCT）: 同前两行 + USE TEMP B-TREE FOR ORDER BY
```
残余 `TEMP B-TREE FOR ORDER BY` 由 `ORDER BY <sort>` 决定（与 DISTINCT 无关）；若要再优化应走
`PhotoRepo.getAssetPage` 的游标分页（按 rowid 排序），而不是继续加索引（见 §6）。

## 3. D2：prepare hoisting（7 个热点站点）

新增 [DBStatementCache.swift](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/DBStatementCache.swift)
（internal，按完整 SQL 文本缓存 `DBStatement`；`query/run/get` 自带 bind+reset，可安全复用）。

| # | 站点 | Before | After | 说明 |
|---|------|--------|-------|------|
| 1 | `AssetRepo+Scan.backfillSession/ensurePhoto`（`:56-62, 195-355`） | 每张照片重新 prepare ~14 条 SQL（1 万张 ≈ 14 万次） | 每个 250 张 batch 事务内 ≤14 次（≈ 99.6%↓） | 缓存在**事务闭包内**创建（语句全部走写连接、非只读池），batch 结束 deinit；不跨事务复用。`limit=14` 仅因非池化 |
| 2 | `AssetRepo+Scan.createRawJpegCandidates`（`:103, 177`） | 每对 RAW/JPEG 重新 prepare 一条 INSERT | 循环外 prepare 1 次 | INSERT 走写连接，无池占用 |
| 3 | `PhotoRepo.getLookupByIds`（`:397-416`） | 每 800 块 prepare 1 次 | 满块复用 1 条（`limit=1`），末块现场 prepare | 元数据/写回批量查 id 热路径 |
| 4 | `CullingReadQuery.existingPhotoIds`（`:265-278`） | 每块 prepare 1 次 | 同上 | 20k 会话 ≈ 25 块/次调用 |
| 5 | `CullingReadQuery.clearCullingProjection`（`:325-337`） | 每块 prepare 1 条 UPDATE | 满块复用 1 条 | reset 时 20k 张 ≈ 25 块 |
| 6 | `DeliveryRepo+Read.getMany`（`:14-32`） | 每 400 块 prepare 1 次 | 满块复用 1 条 | 交付批量读 |
| 7 | `GlobalDuplicateQuery.photos`（`:117-137`） | 每 400 块 prepare 1 次 | 满块复用 1 条 | 跨会话重复检测 |

**prepare 成本量级（bench `--compare` 微基准，SQL 文本唯一以绕过 Python 语句缓存）**：
~**2.0 µs/次**（A 2.72ms vs B 0.71ms / 1000 次，3.8x；真实 Swift `sqlite3_prepare_v2` 为
纯 C 调用，量级相当或更低；复杂 IN/UPDATE 更高）。据此估算站点 1 在 1 万张扫描中省
~0.2–0.5s+（复杂 SQL 实际更高），站点 3–7 每次调用省 10–100µs。

### 3.1 等价性/行为保持

- 预编译语句的绑定参数/重置由 `DBStatement.query/run/get` 的 bind+reset 完成（`DB.swift`），
  同 SQL 复用对调用方完全透明；SQL 文本（含占位符数量）逐字节相同才命中，末块不同 SQL
  走现场 prepare，行为与旧实现一致。
- 失败语义相同：prepare 失败在首次使用处抛 `DBError`（旧实现每轮都会抛，现在首个循环抛出），
  query/step 失败路径不变。
- 顺序：行顺序由 SQL 的 ORDER BY 决定，与语句复用无关。

### 3.2 只读池资源边界（lead review 反馈，已落实）

`DBConnection.prepare` 只在**事务外**（`threadTransactionDepth == 0`）把只读 SELECT 路由到只读池
（`Database.Options.default.readPoolSize == 2`），语句存活期间占用池连接（deinit 归还）。因此：

- `DBStatementCache` **默认 `limit=1`**，并新增 `init(limit:)`；文件头写明「只读池边界 +
  作用域约束（不跨线程/静态存储/事务边界）」；
- SELECT 分块循环只缓存**满块**这一条 SQL，占位符不同的末块现场 prepare（表达式结束即释放）；
- 唯一 `limit>1` 的调用点是 `AssetRepo+Scan` 的 per-photo 缓存（`limit=14`）：缓存建在
  batch 事务闭包内，14 条语句全部在事务内创建 → `prepare` 走写连接（非池化），**0 条只读池
  连接占用**；闭包结束释放，不跨事务复用。
- 作用域 sanity：所有 cache 均为同步函数局部变量；PhotoRepo/CullingRead/Delivery/GlobalDup
  的缓存在创建语句的同一事务深度内使用（方法内不开关事务），不会触发 `DBStatement` 的
  read-scope fail-closed；AssetRepo 的缓存在事务闭包内部创建与销毁。

## 4. D3：sqlite bench 工具

`scripts/perf-sqlite-bench.py`（python3 标准库；**开发工具，不接入 CI**）：

```text
用法: python3 scripts/perf-sqlite-bench.py [--rows N] [--seed S] [--repeats R]
                                        [--compare] [--json] [--keep-db PATH]

  --rows     合成照片数（默认 5000；支持 20k/100k 放大）
  --compare  A/B：DISTINCT 改前/改后（带/不带 ORDER BY 两组）+ prepare 成本微基准
  --json     输出 JSON（含每条查询 median ms、EXPLAIN 明细、A/B 数字）
  --keep-db  保留合成库文件（默认内存库，用完即弃）
```

- **真实 schema**：从 `SchemaCurrent+DDLCore/Domain/Indexes/Workbench.swift` +
  `SchemaCurrent.addendumDDL` 按生产拼接顺序（`ddlCore+ddlDomain+ddlIndexes+addendumDDL+workbenchDDL`）
  抽取 DDL，内存库重放并**校验 55 表 / 86 显式索引 / 81 外键**（不符 exit 2，防 schema 漂移）；
- **确定性数据**：`random.Random(seed=42)`；会话/资产（含 RAW/JPEG 对与 10% 无资产分支）/
  照片/元数据缓存/人脸观测/相似度哈希/挑片决策/历史/分析任务/triage 建议/交付与其 item；
- **热点查询集**（13 条）：photo.list_page（A/B × 带/不带 ORDER BY）、asset_page CTE、
  asset_page 块 IN、analysis_jobs 队列轮询、triage suggestions 整会话载入、deliveries IN、
  photo_metadata_cache 按会话、FK 子行点查（有索引/唯一缺索引）、photos IN 800 块；
  每条打印 warm+median ms 与 EXPLAIN QUERY PLAN；
- 实测：`--rows 5000` 约 0.3s 建库+运行；`--rows 20000 --compare` exit 0（见 §2 数字）。

## 5. D4：service 批量化审计（Culling/Similarity/Face/Triage/Curation）

对 19 处「循环内仓库调用」逐处复核，结论：**本轮无「明显安全」的新批量化修复**（前两轮已把
可安全批的 N+1 收掉）；分类如下（证据行号 = 当前 HEAD）：

| 类别 | 站点 | 结论 |
|---|---|---|
| 逐张独立提交（同一事务内写） | `CullingService+Commands.swift:152/671`（upsertState）、`FaceKwService+Analyze.swift:151`（deleteObservations）、`FaceKwService+Clusters.swift:344/411/419`、`Constraints.swift:50/95/120/155`、`Review.swift:326` | 写入语义=逐张失败隔离/历史合并，改成批量会改变事务与错误边界 ⇒ 不修 |
| 低量读（有文档口径） | `FaceKwService+Clusters.swift:251`（confirmed person 逐条 get，注释「通常个位数」）；`CullingService+Queries.swift:115-117`（只对 undo/redo 两个栈顶补读） | 量级 <5/次，批量化收益为负（list 全表） ⇒ 不修 |
| 逐 tier/逐批写 | `SimilarityService+Hashes.swift:176`（每阈值一条 replace，tier 数少） | 不修 |
| 逐次（非逐行）分配 | `CullingService+Paging.swift:178`（每页 1 个 JSONEncoder）、`SimilarityService+Analyze.swift:239`、`SimilarityService+Hashes.swift:101/104`、`FaceKwService+Analyze.swift:508`、`TriageService.swift:599` | 每次操作 1 次，非 per-row；改共享 coder 收益 <1%（且需 Application 层 coder 先例/风险） ⇒ 不修 |

## 6. 残留建议（排序）

1. **（高）macOS CI 首跑**：本轮 7 个 Swift 文件在 Linux 只能做语法解析 + 门禁（Persistence
   target 依赖 `os` 模块，Linux 不可 `swift build`）；预编译语句复用/DISTINCT 移除均需 macOS
   全套 `swift test` 复核（尤其 schema 形态测试、PhotoFilter 契约测试）。
2. **（中）schema 微优化（下次 user_version 迁移一次做）**：`triage_suggestions(session_id,
   photo_id)` 覆盖索引（bench 现计划 `USE TEMP B-TREE FOR ORDER BY`，5k 整会话 2.2ms）；
   `session_assets.display_file_id`（唯一缺前导索引的 FK 子列，当前无查询使用）；同步
   `expectedExplicitIndexCount`/`expectedShapeFingerprint`，需 macOS 生成指纹。
3. **（中）继续 prepare hoisting 的候选**（Persistence 内、需逐个确认事务作用域）：
   `AssetRepo+Relink.swift:136/154/684/733`（relink 逐文件块）、`IndexerRepo` 的 per-file
   语句（调用方在 IndexerService，属其他 agent 作用域，可通过 internal helper 后续做）、
   `FaceRepo+Observations.reuseObservationsForAssetFile` 的 800 块 SELECT（多数 1-2 块，
   收益低）、`PhotoFilterQuery.assetPage`/`CullingAssetPageQuery.loadAssetRows` 的块 IN
   （limit ≤800 时通常只有 1 块，本审计判定非热点、未改）。
4. **（低）gallery 排序**：`photo.list_page` 仍有 `ORDER BY` 临时 B 树；进一步优化应走
   `PhotoRepo.getAssetPage` 游标路径（rowid 顺序），不建议为 filename 排序加索引（写放大）。
5. **（信息）bench 工具可扩展**：如需回归对比，可在 CI 之外用 `--rows 20000 --json` 存历史
   数字（本任务明确不接 CI 门禁）。

## 7. 验证

```bash
# 每个改动的 Swift 文件（7/7 PASS，无输出）
$ .gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <7 files>
PARSE PASS=7 FAIL=0

# bench 工具（默认 5k clean run / 20k --compare / --json 均 exit 0）
$ python3 scripts/perf-sqlite-bench.py                        # exit 0
$ python3 scripts/perf-sqlite-bench.py --rows 20000 --compare # exit 0
$ python3 -m py_compile scripts/perf-sqlite-bench.py          # OK

# 仓库门禁（全 PASS）
check-protocol-surface.sh --strict  → OK
check-cleanup-ratchet.sh            → OK（unchecked_sendable 60=60、try_optional 257=257、
                                      nonisolated_unsafe 7=7、其余 0）
check-layering.sh                   → OK
check-select-star.sh --strict       → OK
check-coded-errors.sh               → OK
```

**Linux 验证上限**：`swift build --target GatherPersistence` 在本机报 `no such module 'os'`
（仅 GatherProtocol 可 Linux 类型检查），故 DB 层改动只有语法解析 + 门禁；运行时正确性
依赖 macOS CI。bench 工具不依赖 macOS（python sqlite3），是本轮唯一可本地实测的性能证据。

## 8. 改动文件清单

```text
新增 desktop/native/gather-core/Sources/GatherPersistence/Database/DBStatementCache.swift
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/PhotoFilterQuery.swift      (+8/−1)
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/CullingReadQuery.swift       (+8/−2)
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/GlobalDuplicateQuery.swift   (+4/−1)
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo+Scan.swift   (+34/−20)
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Read.swift (+4/−1)
修改 desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PhotoRepo.swift         (+6/−1)
新增 scripts/perf-sqlite-bench.py（可执行，开发工具，不进 CI）
```

未触碰：`Sources/GatherSchema/**`（schema）、`Tests/**`（其他 agent）、`Package.swift`、
`Services/{Metadata,Export,Delivery,Startup,UI}` 等他人作用域。
