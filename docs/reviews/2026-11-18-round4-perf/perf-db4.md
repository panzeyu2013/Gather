# gather-core DB 性能审计 R4：SQLite PRAGMA（mmap/optimize）、bench 扩展与查询审计（task-21）

- **日期**：2026-11-18（基线：git HEAD `2521c00b` + round-4 工作区改动）
- **执行**：perf-core（子代理；写作用域 `Sources/GatherPersistence/**`、`scripts/perf-sqlite-bench.py`、本文档）
- **约束遵守**：无 schema DDL/fingerprint 变更、无公开 API 变更、无行为/输出/错误语义变更、
  无新 `@unchecked Sendable`（ratchet 60/60）、无测试改动、未 commit；未触碰其他 agent 作用域
  （MetadataDispositionService / MetadataTemplateService 由 perf-runtime 负责，本轮未动）。
- **改动面**：5 个 Swift 文件（+51/−11）+ `scripts/perf-sqlite-bench.py` 扩展 + 本文档。

## 1. 结论摘要

| # | 交付 | 结论 |
|---|------|------|
| P1 | `PRAGMA mmap_size` | **采纳**：读写连接 + 只读池连接统一设 256MB 上限（internal 常量）。Linux 20k 合成库实测读/排序/facet 查询 **1.1–1.39x**，点查不变；失败只记 warn 并回退（SQLite 语义）。 |
| P2 | 关闭时 `PRAGMA optimize` | **采纳（best-effort）**：`Database.close()` 关闭前执行一次，失败只记日志；执行前把 busy_timeout 临时收紧到 250ms，避免外部进程持写锁时拖慢关闭。无 schema 变更、close 的幂等/不抛错语义不变。 |
| P3 | bench 工具扩展 | 新增 gallery 排序模式（filename / date_taken 表达式 / rating）、facet 查询（camera / keyword / person，与 FacetQuery 同构）、`--file-db` / `--pragma` / `--pragma-ab`。默认 5k 与 `--rows 20000` 均 exit 0；纯标准库、确定性、不进 CI。 |
| P4 | 查询审计 | 三种 gallery 排序全部 `TEMP B-TREE FOR ORDER BY`（filename 无索引 / date_taken 是 CASE 表达式 / rating 在 JOIN 侧）；facet 有 GROUP BY + count(DISTINCT) 临时 B 树；list_page 5.0ms vs 游标资产页 2.45ms（20k）。建议：排序走游标/未来 user_version 加索引，本轮不改 schema。 |
| P5 | 剩余 Persistence prepare 热点 | 再修 6 处（CollectionRepo×2、StackRepo×3、FaceRepo+Observations×1），分块循环 prepare 降到「满块 1 次 + 末块现场」/ 事务内固定语句集一次。 |

## 2. P1：`PRAGMA mmap_size`（decision + 证据）

### 2.1 实现

- [DB.swift:13-19](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/DB.swift)：
  新增 `static let mmapSizeBytes: Int = 256 * 1024 * 1024`（internal 常量，一处可调）。
- [DB.swift:132-138](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/DB.swift)：`open()` 在
  读写/只读两种模式下、各连接级 PRAGMA 之后对**文件库**执行 `PRAGMA mmap_size = <256MB>`；
  `:memory:` 跳过。只读池连接（`ReadConnectionPool` → `DBConnection(.readOnly)`）与备份校验连接
  走同一 `open()`，因此同样生效，无需改构造签名/公开 API。
- 失败路径：复用既有 `applyPragma`（do/catch + warn 日志，保留 SQLite 当前值），不改变打开语义。

### 2.2 安全/适用范围分析

- SQLite 的 mmap 只影响 **main db 文件**的读页路径（WAL 仍走普通 WAL 读），对写路径/事务语义、
  并发（WAL 单写者）无影响；`PRAGMA mmap_size` 只是单连接映射窗口上限，超出部分自动回退普通 pager。
- 本地磁盘有效：macOS/Linux 均支持；**网络卷/SMB 上 mmap 可能不可靠或变慢** —— SQLite 遇到不支持
  的映射会回退（PRAGMA 不报错），最坏情况等价于未开启。产品口径：Gather 工作区默认本地磁盘；
  若将来支持网络卷，可在打开时按卷类型传 0（常量集中在一处即可扩展）。
- 256MB 是上限而非预分配：按实际访问的页按需映射，不会一次性占 256MB 物理内存/虚拟地址空间
  由 OS 管理；对 2–50 万张照片级库（百 MB 级）覆盖大部分读页。

### 2.3 测量（bench `--file-db --pragma-ab mmap_size=268435456`，20k 照片 / 文件库）

同一合成库上先测默认（mmap=0），再设 256MB 测、恢复默认后复测，取 min(两次默认) 对比：

| 查询 | 默认 ms | mmap 256MB ms | 加速比 |
|---|---|---|---|
| photo.list_page（无 DISTINCT） | 5.004 | 4.481 | **1.12x** |
| photo.list_page（DISTINCT 旧口径） | 6.562 | 5.934 | 1.11x |
| photo.asset_page CTE | 2.453 | 2.040 | **1.20x** |
| metadata.cache_by_session（20k 行批读） | 4.480 | 3.280 | **1.37x** |
| gallery.sort filename | 5.666 | 4.768 | **1.19x** |
| gallery.sort date_taken（表达式） | 4.366 | 3.502 | **1.25x** |
| gallery.sort rating | 2.992 | 2.147 | **1.39x** |
| facet.camera | 5.436 | 4.511 | **1.21x** |
| facet.keyword_top | 11.314 | 10.606 | 1.07x（分组 CPU 主导） |
| facet.person | 2.627 | 2.120 | **1.24x** |
| job.queue_poll / delivery.getMany / photo.lookup_by_ids / FK 点查 | ≈0.005–0.51 | 基本不变（0.97–1.01x） | 无收益（小结果集/索引点查） |

**结论**：扫描/排序/facet 类读查询稳定 1.1–1.4x，点查无变化、无回归 ⇒ 采纳。
注：Linux 上为热页缓存下的相对 A/B；macOS 缓存冷启动/首次查询收益通常更明显，**最终以 macOS CI/
Instruments 复核为准**。可用 `python3 scripts/perf-sqlite-bench.py --rows 20000 --file-db
--pragma-ab mmap_size=268435456` 复现（含完整 EXPLAIN）。

## 3. P2：关闭时 `PRAGMA optimize`（best-effort）

- SQLite 官方建议：应用**关闭连接前/周期性**跑 `PRAGMA optimize`，让查询规划器利用最新统计；
  统计已新鲜时成本很低，不需要改 schema（不产生 user_version/fingerprint 变化）。
- 实现 [Database.swift:325-342](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Database.swift)：
  `Database.close()` 在 `connection.close()` 之前执行：
  ```swift
  BestEffort.attempt("PRAGMA optimize before close") {
      try connection.exec("PRAGMA busy_timeout = 250;")
      try connection.exec("PRAGMA optimize;")
  }
  ```
  - 用 `BestEffort.attempt`（do/catch + warn 日志）而**不是 `try?`**：cleanup-ratchet 的
    `try_optional` 基线不允许增长（本轮实测 256 ≤ 257，未新增）；失败不改变 close 的
    「幂等 + 不抛错 + 关闭后稳定抛 .closed」语义；
  - 关闭在即，先把 busy_timeout 收紧到 250ms：避免外部进程/备份持有写锁时，`optimize` 的
    ANALYZE 写事务把关闭拖到默认 5s（连接随后关闭，无需恢复原值）；
  - 没有放在 `checkpoint()`：checkpoint 语义是纯 WAL 收尾（read 作用域），optimize 是写统计；
    混入会改变 checkpoint 的耗时/失败语义。
- 测试影响：测试大量创建/关闭小库，`optimize` 在空/小库上是亚毫秒级 no-op；对 in-memory 库同样
  低成本。close 仍不 throws，现有 close 语义测试不受影响（无需改 Tests，本轮未改）。

## 4. P3：bench 工具扩展（`scripts/perf-sqlite-bench.py`）

新增能力（保持 python3 标准库 / 确定性 seed / 不进 CI）：

| 新开关/内容 | 用途 |
|---|---|
| `--file-db` | 用临时**文件库**代替 `:memory:`（mmap/PRAGMA 实验必须）；默认仍内存库 |
| `--pragma NAME=VALUE` | 应用到基准连接（可重复），打印读回值；用于单点验证 |
| `--pragma-ab NAME=VALUE` | 同库 A/B：默认 → 设定 → 恢复默认重测，逐查询输出 baseline/set/加速比（抵消冷热偏差） |
| gallery 排序查询×3 | `ORDER BY p.filename` / `date_taken` CASE 表达式 / `pmc.rating`，LIMIT 200 |
| facet 查询×3 | camera（ROW_NUMBER 代表行 CTE）、keyword 顶级桶（COUNT DISTINCT 资产）、person 桶，与 `FacetQuery` 同构 |
| 新 seed 表 | `persons` / `person_photos`（每 3 张一个绑定）/ `photo_keywords`（每张 3 条，顶级桶 Places/People/Scenes） |

示例：
```text
python3 scripts/perf-sqlite-bench.py                                  # 默认 5k（exit 0）
python3 scripts/perf-sqlite-bench.py --rows 20000                     # 20k（exit 0）
python3 scripts/perf-sqlite-bench.py --rows 20000 --file-db --pragma-ab mmap_size=268435456
python3 scripts/perf-sqlite-bench.py --file-db --pragma cache_size=-131072
```

## 5. P4：查询审计（PhotoFilterQuery 排序 / FacetQuery / list_page vs cursor）

### 5.1 gallery 排序模式（20k 文件库，bench EXPLAIN + 实测）

| 排序 | SQL 关键路径 | EXPLAIN | 20k 实测 | 根因/建议 |
|---|---|---|---|---|
| `ORDER BY p.filename` | `p.session_id=?` 走 `idx_photos_asset_group`，LEFT JOIN pmc 1:1 | `SEARCH p` + `SEARCH pmc` + **USE TEMP B-TREE FOR ORDER BY** | 5.99 ms | 没有 `(session_id, filename)` 索引；未来 user_version 可评估该索引（注意 pmc JOIN 与 DISTINCT 已移除，仍需 join 取 metadata 字段） |
| `ORDER BY date_taken`（`normalizedDateTaken` CASE 表达式） | 同上 | **TEMP B-TREE FOR ORDER BY** | 4.48 ms | 表达式无法建普通索引；除非新增归一化列（schema 变更，不建议），否则建议走**游标分页**（按排序键 + rowid 复合游标） |
| `ORDER BY pmc.rating` | JOIN 侧列 | **TEMP B-TREE FOR ORDER BY** | 3.12 ms | `idx_metadata_cache_session_rating(session_id, rating)` 因排序键在 JOIN 侧、且排序在去重/连接后不可直接用；建议 cursor 化（(rating, rowid) 游标）或 session 内预排序缓存 |

### 5.2 list_page vs cursor 资产页

- `photo.list_page`（filterPhotos：LEFT JOIN pmc + face_count 相关子查询 + ORDER BY + LIMIT）：20k ≈ **5.0 ms**（无 DISTINCT）。
- `photo.asset_page` CTE（`getAssetPage`：rowid 游标 + GROUP BY 资产组）：20k ≈ **2.45 ms**；
  游标路径无「全量排序」阶段（ORDER BY MIN(rowid) 可走索引序），是 gallery 翻页的**推荐方向**。
- 结论：默认分页继续保留 filterPhotos（语义面广：任意 criteria/facet 联动）；对「纯选片/gallery 直翻」
  路径优先 cursor（已有 `getAssetPage`/`CullingAssetPageQuery` 实现），避免 filename/date/rating 三种排序的 TEMP B-TREE。

### 5.3 FacetQuery（20k 文件库）

| facet | 实测 | EXPLAIN 关键 | 观察/建议 |
|---|---|---|---|
| camera | 5.53 ms | `CO-ROUTINE ranked`（ROW_NUMBER 代表行）→ `SCAN` + **TEMP B-TREE FOR GROUP BY / ORDER BY** | 每维一次窗口扫描 + 分组；建议服务层按 (session, criteria 指纹) 缓存 facet 结果（UI 面板同屏多维，一次算多次用） |
| keyword 顶级桶 | 11.45 ms | `photo_keywords` 覆盖索引（PK）JOIN photos → **TEMP B-TREE ×3**（GROUP BY / count(DISTINCT) / ORDER BY） | 最贵；`COUNT(DISTINCT 资产)` 天然需要去重临时 B 树。未来评估 `photo_keywords(keyword_path, photo_id)` 已有；建议缓存 + 限制 limit/懒加载子级 |
| person | 2.66 ms | `person_photos` by photo + persons 点查 + 覆盖索引 pmc → TEMP B-TREE ×3 | 量级可接受；同上缓存策略 |

**本轮不改 schema**：以上候选索引（`photos(session_id, filename)`、facet 缓存）留到下次 `user_version` 迁移统一评估；
索引变更需同步 `expectedExplicitIndexCount`/`expectedShapeFingerprint` 并在 macOS 生成指纹。

## 6. P5：剩余 Persistence prepare 热点（6 处）

沿用 round-3 的 [DBStatementCache.swift](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/DBStatementCache.swift)
（默认 limit=1：只读 SELECT 每次作用域最多占 1 条池连接；事务内写语句可多条，调用点注释说明）：

| 站点 | Before → After |
|---|---|
| [CollectionRepo.existingPhotoIds:309-329](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CollectionRepo.swift) | 每 400 块 SELECT prepare → 满块复用 1 条（末块现场） |
| [CollectionRepo.removeItems:369-390](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CollectionRepo.swift) | 每块 DELETE prepare → 满块复用 1 条（事务内写连接） |
| [StackRepo.stackIdsByPhoto:183-207](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/StackRepo.swift) | 每 400 块 SELECT → 满块复用 1 条 |
| [StackRepo.removeMembers:315-338](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/StackRepo.swift) | 每块 DELETE → 满块复用 1 条 |
| [StackRepo.detachPhotos:337-375](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/StackRepo.swift) | 每块 SELECT+DELETE 各 prepare → limit=2 复用（事务内写连接） |
| [FaceRepo+Observations.invalidateDerivedResults:490-525](../../../desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Observations.swift) | 每块 5 条写语句 prepare（10k 照片≈25 块×5=125 次）→ limit=5 事务内复用 |

等价性同 round-3：SQL 文本逐字节相同才命中、末块不同 SQL 现场 prepare、`query/run/get` 自带 bind+reset；
失败/顺序/错误语义不变。只读池资源边界：SELECT 缓存最多 1 条池连接，其余站点均在事务内写连接（非池化）。

### 6.1 复查后仍未改的 Persistence 热点（残余）

- `AssetRepo+Relink` 重链接逐 change 的 `UPDATE asset_files`（:136）与 affected-session 循环（:153-175）：
  外层有新语句且包裹多个 helper（`relocateMetadataState`/`retargetPhotosPath`/`relocateSidecarBinding` 内部也有
  prepare）；需先把 helper 语句集收口，属中型重构，留待下一轮（当前发生频率=重链接操作，非逐张扫描）。
- `IndexerRepo` 的 per-file `updateIndexedFile` 等语句：调用方在 `IndexerService`（其他 agent 作用域），
  需跨层传入 internal 语句缓存，本轮不动。
- `FaceRepo+Observations.reuseObservationsForAssetFile` 的 800 块 SELECT（多数 1–2 块，收益低）。
- `PhotoFilterQuery.loadAssetPage` / `CullingAssetPageQuery.loadAssetRows` 块 IN（limit ≤800 时通常 1 块，非热点）。

## 7. 验证

```bash
# 改动的 Swift 文件（5/5 PARSE PASS，无输出）
$ .gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <5 files>

# bench：默认 5k 与 20k 均 exit 0；新 flag 均验证
$ python3 scripts/perf-sqlite-bench.py                    # exit 0
$ python3 scripts/perf-sqlite-bench.py --rows 20000       # exit 0
$ python3 scripts/perf-sqlite-bench.py --rows 20000 --file-db --pragma-ab mmap_size=268435456  # exit 0
$ python3 -m py_compile scripts/perf-sqlite-bench.py      # OK

# 门禁（全 PASS）
check-protocol-surface.sh --strict  → OK（public 面未变：297/2128 等逐模块持平）
check-cleanup-ratchet.sh            → OK（unchecked_sendable 60=60、try_optional 256≤257、
                                       nonisolated_unsafe 7=7、其余 0）
check-layering.sh                   → OK
check-select-star.sh --strict       → OK
check-coded-errors.sh               → OK
check-perf-ratchet.sh               → OK（raw formatter/coder/regex 计数不增）
```

**Linux 验证上限**：Persistence target 依赖 `os` 模块，Linux 不可 `swift build`（仅 GatherProtocol 可类型检查），
因此 PRAGMA/prepare 改动只有语法解析 + 门禁；行为正确性（尤其 close 时 optimize 与 mmap 的 macOS
表现、读写连接/只读池）需 **macOS CI** 首跑复核（DatabasePragmaTests / close 语义 / WAL checkpoint 测试）。

## 8. 改动文件清单

```text
desktop/native/gather-core/Sources/GatherPersistence/Database/DB.swift                         (+13/−0)
desktop/native/gather-core/Sources/GatherPersistence/Database/Database.swift                   (+10/−0)
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CollectionRepo.swift (+7/−2)
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/StackRepo.swift     (+11/−4)
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Observations.swift (+10/−5)
scripts/perf-sqlite-bench.py（扩展：--file-db/--pragma/--pragma-ab + gallery 排序/facet 查询 + seed 表）
docs/reviews/2026-11-18-round4-perf/perf-db4.md（本文件）
```

未触碰：`Sources/GatherSchema/**`（schema）、`Tests/**`、`Package.swift`、
`Services/Metadata/**`（含 perf-runtime 负责的 MetadataDispositionService/MetadataTemplateService）及其他 agent 作用域。
