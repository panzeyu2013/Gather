# SchemaV1 Cut 2 风险审计（R1 列级对账 / R2 用户数据 FK / R3 CHECK 漂移）

> 只读审计。产出物仅本文件；未改源码、脚本或其他文档，无 git commit。
> 基线：`docs/schema-v1-draft.md` §2（列清单）、§3（索引/FK）、§8（R1/R2/R3）；`docs/cleanup-backlog.md` §3。
> 口径：**当前 schema = `Schema.swift` + `Migrations.swift` 的迁移终点**（不是 `Schema.swift` 的 DDL 字面）；**V1 = `SchemaV1.swift`**（43 表/370 列/69 索引/62 FK，尚未接入 `Database.open`，见 `SchemaV1.swift:27`）。
> **后续变化（2026-10-22，Cut 5 / 5b-2b，D-152）——370 → 373 历史口径**：本审计写作时 V1 为 **43 表 / 370 列**；5b-2b 给 `similarity_cluster_meta` 补了 `algorithm_version` / `input_signature` / `state_digest` 3 列，**现行口径 = 43 表 / 373 列**（索引 69 / FK 62 不变），且 V1 已接入 `Database.open`（不兼容库重置重建）。文中所有 "370 列" 均按**历史快照**读，列级/行映射结论不受影响（新增 3 列不在本文的行映射清单内）。
> 扫描快照：2026-10-21 23:50–23:55 CST。扫描期间 Cut 2 S1/S2 正在并行落地（`SchemaV1.swift`、`DeliveryState.swift`、`DeliveryRepo.swift` 为未跟踪新文件；`AssetRepo.swift`/`PhotoRepo.swift` 在扫描期间被并发修改）。**行号会漂移，施工前请重新 grep 核对。**
> 路径简写：`Repo/` = `desktop/native/gather-core/Sources/GatherCore/Database/Repositories/`；`DB/` = `desktop/native/gather-core/Sources/GatherCore/Database/`；`Svc/` = `desktop/native/gather-core/Sources/GatherCore/Services/`；`Tests/` = `desktop/native/gather-core/Tests/GatherCoreTests/`。
> 计数口径：只统计**实际 SQL**，排除 Swift 注释与 SQL 注释。`gather-app/Sources` 无 SQL（0 处），故 Sources 面即 core Sources。

---

## 0. 结论摘要

| 指标 | 数值 | 说明 |
| --- | --- | --- |
| `SELECT *` 实际查询 | **41** | 40 Sources + 1 Tests。字面 grep 命中 44 行，其中 10 行不是语句（9 行 Swift 注释 + 1 行 SQL 注释） |
| 位置读取 | **40** | 32 处经 `Row.init(row:)`，8 处在内联闭包里 `row[i]/$0[i]`；另 1 处仅 `EXPLAIN QUERY PLAN`，不消费行 |
| 按列名读取 | **0** | `DBRow = [DBValue]`（`DB.swift:33`），`DBStatement.columns()` 直接丢弃列名（`DB.swift:352-371`），全仓无 `sqlite3_column_name` |
| Codable 行映射 | **0** | `DBRow` 不是 `Decodable`；Codable 只用于 DTO/JSON，不用于 DB 行 |
| V1 改变行形的 star 站点 | **11** | photos 1 + face_observations 1 + metadata_outbox 8 + writeback_items 1 |
| 用户数据表 FK | **18 条 / 11 表** | 审计时（23:50）6 条 V1 改语义、无 RESTRICT；23:58 复核已落 4 条保护型修复（3 RESTRICT + 1 SET NULL），剩 2 条 CASCADE + 1 条 SET NULL 状态不变量（§2.6） |
| R3 确认漂移 | **3（1 已修）** | `auto_raw_jpeg`（生产写，P0；23:58 CHECK 已含该值）、`indexed`（测试写，P1）、`clean`（enum 多值，P1） |
| 可执行清单 | **26 条** | P0 10 / P1 11 / P2 5（见 §4） |

**最大 3 个风险**

1. **R1（未修）**：`face_observations` 的 `SELECT *` 映射读 `row[18]`，V1 只有 17 列（`FaceRepo.swift:332` + `:40-62`）→ **数组越界崩溃**；`photos` 的 `PhotoRow` 守卫 `row.count >= 16` 在 V1 14 列下抛错（`PhotoRepo.swift:29`），图库/挑片全链路不可用；若只把守卫改小而不改下标，字段会静默归零。
2. **R1（未修）**：41 处 star 全部未改，其中 `FaceClusterRow` 的「只删 SELECT 的 thumbnail_base64、不改 mapper」会**静默把 matched_person_id 当缩略图路径**（`FaceRepo.swift:740-752`）；`SessionRow` 的 14→11 列投影若只改 guard，会出现 `row[11]` 越界或 writeback/import 字段串列（`SessionRepo.swift:52-78`）。
3. **R2 / R3（部分已修）**：23:58 复核后仍有 `person_embeddings.photo_id/session_id` CASCADE 静默删身份向量（`SchemaV1.swift:447-455`），以及 `face_clusters.matched_person_id` SET NULL 不更新 `status` 的不变量缺口（`SchemaV1.swift:344`）；`TemplateServiceTests` 仍以 `sessions.status='indexed'` 写库，V1 下该测试会红（`Tests/Services/TemplateServiceTests.swift:24-26`）。

---

## 1. R1 列级对账

### 1.1 先修正两个基线数字（否则验收会漏）

**（a）`SELECT *` 是 41 处，不是 42。**

```bash
grep -rn 'SELECT \*' --include='*.swift' desktop/native | wc -l   # 44 行
```

44 行里：9 行是 Swift 注释（`AnalysisJobRepo:25`、`CullingDecisionRepo:18`、`FaceRepo:17`、`MetadataCacheRepo:5`、`MetadataOutboxRepo:111`、`PersonRepo:33/45/78`、`MigrationTests:180`），1 行是 SQL 字符串内的注释（`Schema.swift:226` 的 `-- SELECT * 的 FaceObservationRow…`），剩 **34 条字面星号语句**（33 Sources + 1 Tests）；再加 **7 条限定星号**（`o.*`/`p.*`/`pp.*`/`dgm.*`），合计 **41 条实际查询**。

草案 §2.6/§8 R1 的 `42` = 34 条字面 + 7 条限定 + 1 条 SQL 注释（或把 Tests 计入了 Sources）。按 42 建验收清单会多算 1 条；按本文 41 条对齐更可靠。

**（b）§2.4 的“63 个旧列”与表内实际 66 列不一致。**

§2.4 表共 52 个数据行（`asset_file_metadata` 的 15 列折叠为 1 行），逐表求和 = **66**：
`sessions 3 + photos 2 + assets 1 + asset_backfill_state 2 + face_clusters 3 + face_observations 2 + person_embeddings 2 + asset_file_metadata 15 + schema_version 2 + metadata_outbox 16 + metadata_outbox_sessions 4 + writeback_items 14 = 66`。
与 §1 的 `396 − 51 − 15 + 3 + 37 = 370` 也一致（51 随表消失 + 15 保留表删列 = 66）。**若按 §2.4 的 63 行勾选，会少 3 列**（最可能是 `face_clusters` 的 3 列，但无论哪 3 列，验收口径都不可复算）。建议 R1 的勾选清单改成「66 列 / 52 行（含 1 行折叠 15 列）」并附复算脚本。

### 1.2 41 处 star 查询全量清单

> “V1 影响”只描述**行形/表存在性**；列序不变的表也必须改成显式列清单（理由见 1.4），但它们在 Cut 2 不会静默错位。

| # | 站点（文件:行） | 表 | 行消费方式 | V1 影响 |
| --- | --- | --- | --- | --- |
| 1 | `Repo/AnalysisJobRepo.swift:158/172/178/189/206/216/250` | analysis_jobs | `AnalysisJobRow.init(row:)` 位置 0–23（`:52-77`） | 无（V1 仍 24 列、同序） |
| 2 | `Repo/AssetRepo.swift:1061/1070` | asset_files | 内联 `$0[0]`/`$0[3]`（`:1065`/`:1072`） | 无（14 列同序） |
| 3 | `Repo/CullingDecisionRepo.swift:90/97/125` | culling_decisions | `CullingDecisionRow.init(row:)` 位置 0–10（`:34-46`） | 无（11 列同序） |
| 4 | `Repo/FaceRepo.swift:332` | face_observations | `FaceObservationRow.init(row:)` 位置 0–18（`:40-62`） | **行形变化**：19 → 17，见 1.3-A |
| 5 | `Repo/FaceRepo.swift:779` | role_bindings | `RoleBindingRow.init(row:)` 只用 0–4（`:131-137`） | 无（7 列同序） |
| 6 | `Repo/MetadataCacheRepo.swift:183/195` | photo_metadata_cache | `MetadataCacheRow.init(row:)` 位置 0–21（`:30-53`） | 无（22 列同序） |
| 7 | `Repo/MetadataOutboxRepo.swift:243/250/296/315/328/702/721` | metadata_outbox | `MetadataOutboxRow.init(row:)` 位置 0–15（`:132-150`） | **表替换**：V1 无此表，映射器必须随旧 Repo 删除 |
| 8 | `Repo/PersonRepo.swift:231/265` | persons | `PersonRow.init(row:)` 位置 0–7，`:265` 多 1 列 thumbnail_path（`:49-62`） | 无（8 列同序） |
| 9 | `Repo/PersonRepo.swift:237` | persons（`p.*` + 3 子查询列） | `PersonWithCountsRow` 位置 0–10（`:71-75`） | 无（8 + 3 同序） |
| 10 | `Repo/PersonRepo.swift:795` | person_photos（`pp.*` + 3 JOIN 列） | `PersonPhotoDetail` 位置 0–9（`:110-115`） | 无（7 + 3 同序） |
| 11 | `Repo/PhotoRepo.swift:195` | photos | `PhotoRow.init(row:)` 位置 0–15（`:28-46`） | **行形变化**：16 → 14，见 1.3-B |
| 12 | `Repo/SimilarityResultRepo.swift:55/64` | similarity_results | `SimilarityResultRow.init(row:)` 位置 0–6（`:15-24`） | 无（7 列同序） |
| 13 | `Repo/SmartAlbumRepo.swift:80/85` | smart_albums | `SmartAlbumRow.init(row:)` 位置 0–9（`:18-30`） | 仅改名列（`schema_version`→`filter_schema_version`，位置 1 不变）；**写入点** `:95` 会 prepare 失败 |
| 14 | `Repo/WritebackRepo.swift:99` | writeback_items | `WritebackItemRow.init(row:)` 位置 0–12（`:25-40`） | **表替换**：V1 无此表 |
| 15 | `Svc/CullingService.swift:1638` | metadata_outbox（`o.*`） | `MetadataOutboxRow`（`:1643`） | **表替换** |
| 16 | `Svc/DuplicateService.swift:522/542/751/764` | duplicate_groups ×3、duplicate_group_members ×1（`dgm.*` + 2） | 全内联：`:527`、`:554/564/569/572`、`:772-781`、`:788-797` | 无（两表 8/8 列同序） |
| 17 | `Svc/TemplateService.swift:72/80` | workflow_templates | 内联 `row[0..5]`（`:168-184`） | 无（6 列同序） |
| 18 | `Tests/Database/Repositories/AnalysisJobRepoTests.swift:64` | analysis_jobs | 仅 `EXPLAIN QUERY PLAN`，不消费行 | 无（但保留星号会掩盖未来列变） |

统计：41 处中 **32 处经 Row 结构体**、**8 处内联**（AssetRepo 2、DuplicateService 4、TemplateService 2）、**1 处 EXPLAIN**。位置下标表达式在 `Database/Repositories` 有 414 处、`Services` 有 195 处（粗计 609 处 `row[i]/$0[i]`），说明“改一处映射器”远远不够。

### 1.3 位置读取的“当前列序 → V1 新列序”差异

#### A. `face_observations`（`FaceRepo.swift:332`，`FaceObservationRow`）

| 列 | 当前 index | V1 index | 差异 |
| --- | --- | --- | --- |
| id / photo_id / session_id / bbox_x..h / embedding / confidence | 0–8 | 0–8 | 不变 |
| source_file_size | 9 | — | **删除** |
| source_file_mtime_ms | 10 | — | **删除** |
| analysis_signature | 11 | 9 | −2 |
| created_at | 12 | 16 | **+4（移到列尾）** |
| quality | 13 | 10 | −3 |
| face_size_px | 14 | 11 | −3 |
| roll_degrees | 15 | 12 | −3 |
| model_id | 16 | 13 | −3 |
| model_version | 17 | 14 | −3 |
| embedding_dim | 18 | 15 | −3 |

后果：`FaceObservationRow` 无列数守卫，`row[18]`（`:61`）在 17 列数组上 **越界 trap（崩溃，不是可捕获错误）**；即使加守卫，`row[13]` 也会把 `model_id` 读成 `quality`（TEXT→`doubleValue` 为 nil → 0.0），`row[9]` 把 `analysis_signature` 读成 `sourceFileSize`（TEXT→`intValue` 为 nil → 0）。爆炸半径：`FaceKwService.swift:678/750/1022/1307/1653`（fkw.analyze 主路径）。

#### B. `photos`（`PhotoRepo.swift:195`，`PhotoRow`）

| 列 | 当前 index | V1 index | 差异 |
| --- | --- | --- | --- |
| id … status | 0–7 | 0–7 | 不变 |
| metadata | 8 | — | **删除** |
| result | 9 | — | **删除** |
| asset_id | 10 | 8 | −2 |
| asset_file_id | 11 | 9 | −2 |
| width | 12 | 10 | −2 |
| height | 13 | 11 | −2 |
| created_at | 14 | 12 | −2 |
| updated_at | 15 | 13 | −2 |

后果：`guard row.count >= 16`（`:29`）在 V1 14 列下抛 `PhotoRow 列数不足: 14`——**响亮失败**，但影响图库/挑片全部读取（`CullingService.swift:360/1009/1112/2157`）。危险的是“局部修复”：若把守卫改成 14 却保留旧下标，`assetId=row[10]` 读到 `width`（INTEGER→`textValue` nil）、`width=row[12]` 读到 `created_at`（TEXT→`intValue` nil→0），**字段静默归零/变空**。正确做法见 1.4 的 `PhotoRow.columns`（与 V1 同序）和命名解码。

#### C. `face_clusters`（不是 `SELECT *`，但同为位置映射：`FaceRepo.swift:740-752`）

当前查询显式 9 列：`id(0), session_id(1), label(2), COUNT(*) AS member_count(3), status(4), thumbnail_base64(5), thumbnail_path(6), matched_person_id(7), match_confidence(8)`。
V1 的 `face_clusters` 删掉 `thumbnail_base64` 与 `member_count`（`SchemaV1.swift:338-348`）。**若只从 SELECT 里删 `c.thumbnail_base64` 而不改 mapper**：

| 字段 | 当前 index | 删列后 index | 会读到的列 |
| --- | --- | --- | --- |
| thumbnailPath | 6 | 5 | `matched_person_id`（UUID 字符串）→ **缩略图路径变成 person id** |
| matchedPersonId | 7 | 6 | `match_confidence`（REAL）→ `textValue` nil → 身份丢失 |
| matchConfidence | 8 | 7 | `row.count > 8` 为 false → nil |

这是本审计里**唯一的“SELECT 列变了、mapper 不报错、UI 静默错”**路径（`FaceClusterRow.init` 无列数守卫，`:83-95`）。若同时删 `member_count`，索引 3 的 COUNT 别名仍在（查询要保留别名），不受影响。

#### D. `sessions`（不是 `SELECT *`，显式投影 + 位置映射：`SessionRepo.swift:52-78`、`:22-38`）

当前投影 14 列：`id(0), name(1), status(2), analysis_status(3，派生), writeback_status(4), import_source(5), source_path(6), truncated_import(7), reload_acked_at(8), index_seq(9), photo_count(10), failed_writeback_count(11), created_at(12), updated_at(13)`。
V1 物理 10 列 + 派生 `analysis_status` = 11 列：`id(0), name(1), status(2), analysis_status(3), source_path(4), truncated_import(5), reload_acked_at(6), index_seq(7), photo_count(8), created_at(9), updated_at(10)`。
删 `writeback_status/import_source/failed_writeback_count` 后，`source_path` 6→4 及其后全部 −2/+1。`guard row.count >= 14`（`:23`）会先抛；若只把 guard 降到 11 而保留旧字段顺序，`writebackStatus=row[4]` 会读 `source_path`、`sourcePath=row[6]` 会读 `reload_acked_at`、`failedWritebackCount=row[11]` **再次越界**。必须按 V1 顺序重写 `SessionRow`。

#### E. 被替换表：7 处 outbox + 1 处 writeback

`metadata_outbox`（16 列，实际列序是 v18 重建 + v27 追加 `source_module` 到列尾，见 `Migrations.swift:584-606/794`）与 `writeback_items`（14 列）在 V1 中整体消失，对应 7 + 1 个 star 站点**不能“调列序”，只能随旧 Repo 删除**。注意 `MetadataOutboxRow` 的 `sourceModule = row[15]`（`MetadataOutboxRepo.swift:149`）证明当前映射依赖的是**迁移终点列序**而非 `Schema.swift` 的 DDL 字面——这正是 R1 的根因，Cut 2 不应把这套映射平移到 `deliveries`。

#### F. `smart_albums`：改名不改序

`schema_version` → `filter_schema_version`（`SchemaV1.swift:534`），位置仍是 1，`SmartAlbumRow` 位置映射不会错位；但 `INSERT` 仍写旧列名（`SmartAlbumRepo.swift:95`）→ prepare 失败（响亮）。

#### G. 非 `SELECT *` 但同属列级对账的写入点（全部会“响亮失败”）

| 站点 | 被删/改名 | 后果 |
| --- | --- | --- |
| `Repo/PhotoRepo.swift:294` | `INSERT photos (…, metadata, result, …)` | prepare 失败（no such column） |
| `Repo/AssetRepo.swift:999/1126` | `INSERT assets (…, capture_fingerprint, …)` | prepare 失败 |
| `Repo/FaceRepo.swift:680/708/1004` | `face_clusters.member_count` / `thumbnail_base64` | prepare 失败（3 处） |
| `Repo/PersonRepo.swift:403-406/725` | `person_embeddings.face_bbox/quality` | prepare 失败（2 处） |
| `Repo/SessionRepo.swift:91` | `sessions.writeback_status/import_source/failed_writeback_count` | prepare 失败 |
| `Svc/SimilarityService.swift:854`、`Svc/FaceKwService.swift:1775` | `analysis_runs.params` → `params_json` | prepare 失败（2 处） |
| `Repo/SmartAlbumRepo.swift:95` | `smart_albums.schema_version` | prepare 失败 |

> 这些是“改就报错”的友好面；真正危险的是 1.3-A/B/C/D 四个位置映射。**Cut 2 的 PR 应把“prepare 失败”当门禁，而不是逐个运行期发现。**

### 1.4 修复建议

**分三层，按 Cut 2 的可用工期取舍：**

1. **立即（Cut 2 必做）**：把 4 个高风险映射（PhotoRow、FaceObservationRow、FaceClusterRow、SessionRow）改成「显式列清单 + 列名映射」；其余 30 处（含 2 处 smart_albums 改名但列序不变）至少改成显式列清单，禁止再新增 `SELECT *`。
2. **同 Cut 2（推荐）**：把 `DeliveryRepo` 已验证的模式上提到 DB 层：
   - 现状：`DeliveryRepo.swift:62-85` 的 `DeliveryColumnMap.index(columns:row:required:)` + `DeliveryRow.init(columns:row:)`（`:116-132`）已经做到“列名 → 值”，测试还用**乱序列清单**验证（`Tests/Database/DeliveryRepoTests.swift:540-601`）。这是全仓唯一不依赖列序的行映射实现。
   - 建议在 `DB.swift` 增加 `NamedRow` 与 `queryNamed`，让所有 Repo 共用，而不是每个 Repo 复制一份 `DeliveryColumnMap`。
3. **门禁（Cut 2 验收）**：
   - `SchemaV1Tests` 目前只断言**列数**（`Tests/Database/SchemaV1Tests.swift:430-440`；总列数 `:369-373`），**没有断言列名/列序/default/NOT NULL**——把 DDL 里两列对调，测试仍绿。必须补 `PRAGMA table_info` 的 `(name, type, notnull, dflt_value, pk)` 逐列快照（或 `docs/fixtures/schema-v1.snapshot.json`）。
   - 新增静态门禁 `scripts/check-select-star.sh`：Cut 2 后 `Sources` 的 `SELECT *` 必须为 0（Tests 允许 1 处 EXPLAIN，但建议一并改显式）。
   - 每个 Row 类型加单测：用乱序列清单构造 `NamedRow`，断言字段不串（仿 `DeliveryRepoTests.swift:540`）。

**`row.decoded(by:)` 的 API 草图（建议放 `DB.swift`）**

```swift
public protocol DBValueDecodable {
    init(dbValue: DBValue, column: String) throws
}
// String/Int/Int64/Double/Bool/Data 各自实现；类型不符时抛带列名的错误。

public struct NamedRow: Sendable {
    public let columns: [String]
    public let values: [DBValue]          // 与 columns 等长
    private let index: [String: Int]      // init 时构建

    public func decoded<T: DBValueDecodable>(by column: String) throws -> T {
        guard let i = index[column] else { throw DBError.message("缺失列: \(column)") }
        return try T(dbValue: values[i], column: column)
    }
    public func decodedIfPresent<T: DBValueDecodable>(by column: String) -> T? {
        guard let i = index[column] else { return nil }
        return try? T(dbValue: values[i], column: column)
    }
}

// DBStatement：prepare 后缓存 sqlite3_column_name(stmt, i)，queryNamed() 与 query() 共用
// 绑定/step/锁逻辑，只在 SQLITE_ROW 时组装 NamedRow。
```

**5 个改造示例（可直接照抄）**

示例 1：`PhotoRow` —— 列清单与 V1 同序，且复用现成的 `getBySessionProjection` 列清单（`PhotoRepo.swift:202` 已经是 V1 的 14 列）

```swift
public struct PhotoRow: Equatable, Sendable {
    // 唯一列清单：SQL 与解码共用，顺序 = SchemaV1 photos 的物理列序
    public static let columns = [
        "id", "session_id", "filepath", "filename", "checksum",
        "checksum_file_size", "checksum_file_mtime_ms", "status",
        "asset_id", "asset_file_id", "width", "height", "created_at", "updated_at",
    ]

    init(row: NamedRow) throws {
        id = try row.decoded(by: "id")
        sessionId = try row.decoded(by: "session_id")
        filepath = try row.decoded(by: "filepath")
        filename = try row.decoded(by: "filename")
        checksum = try row.decoded(by: "checksum")
        checksumFileSize = try row.decoded(by: "checksum_file_size")
        checksumFileMtimeMs = try row.decoded(by: "checksum_file_mtime_ms")
        status = try row.decoded(by: "status")
        assetId = row.decodedIfPresent(by: "asset_id")
        assetFileId = row.decodedIfPresent(by: "asset_file_id")
        width = try row.decoded(by: "width")
        height = try row.decoded(by: "height")
        createdAt = try row.decoded(by: "created_at")
        updatedAt = try row.decoded(by: "updated_at")
    }
}

// Repo
let columns = PhotoRow.columns.joined(separator: ", ")
let sql = "SELECT \(columns) FROM photos WHERE session_id = ? ORDER BY rowid"
let rows = try connection.prepare(sql).queryNamed([.text(sessionId)])
return try rows.map { try PhotoRow(row: $0) }
```

`metadata/result` 字段直接删除；`CullingPhotoRow.init(row: PhotoRow)`（`CullingService.swift:205-214`）同步删两个字段。若不想动调用方，可先让 `getBySession` 返回 `PhotoProjectionRow`（`:202` 的列清单已是 V1 形状），再删 `PhotoRow`。

示例 2：`FaceObservationRow` —— 删两列、按名解码；`sourceFileSize/Mtime` 若仍需要，从 `face_analysis_state` JOIN（这本来就是陈旧判定的唯一真相源，`FaceRepo.swift:355-369`）

```swift
static let columns = [
    "id", "photo_id", "session_id",
    "bbox_x", "bbox_y", "bbox_w", "bbox_h",
    "embedding", "confidence", "analysis_signature",
    "quality", "face_size_px", "roll_degrees",
    "model_id", "model_version", "embedding_dim", "created_at",
]

init(row: NamedRow) throws {
    id = try row.decoded(by: "id")
    // …
    analysisSignature = try row.decoded(by: "analysis_signature")
    quality = try row.decoded(by: "quality")
    // …
}
```

示例 3：`FaceClusterRow` —— 显式保留 COUNT 别名，删 `thumbnail_base64`，按名解码

```swift
let sql = """
SELECT c.id, c.session_id, c.label,
       (SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = c.id) AS member_count,
       c.status, c.thumbnail_path, c.matched_person_id, c.match_confidence
FROM face_clusters c
WHERE c.session_id = ?
"""
// FaceClusterRow.init(row: NamedRow)：
// thumbnailPath = try row.decoded(by: "thumbnail_path")
// matchedPersonId = row.decodedIfPresent(by: "matched_person_id")
// matchConfidence = row.decodedIfPresent(by: "match_confidence")
```

示例 4：`SessionRow` —— 投影与 V1 的 10 列 + 派生列对齐，删 3 个字段

```swift
SELECT id, name, status,
       /* CASE … END */ AS analysis_status,
       source_path, truncated_import, reload_acked_at,
       index_seq, photo_count, created_at, updated_at
FROM sessions

// SessionRow：删 writebackStatus/importSource/failedWritebackCount；
// 其余全部 row.decoded(by:)，analysisStatus 也按名取（它是派生列，不是物理列）。
```

示例 5：`PhotoBackfillRow` —— 现在是 `SELECT rowid AS migration_rowid, *`（`AssetRepo.swift:144-151`），V1 下 `status` 恰好仍在 index 8，属于“侥幸不坏”；改成显式列清单 + 命名解码，避免下次加列就错位

```swift
SELECT rowid AS migration_rowid, id, session_id, filepath, filename, checksum, status
FROM photos
WHERE session_id = ? AND rowid > ? AND (asset_id IS NULL OR asset_file_id IS NULL)
ORDER BY rowid LIMIT 250

// init(row: NamedRow)：migrationRowid/id/sessionId/filepath/filename/checksum/status 全按名。
```

---

## 2. R2 用户数据 FK

### 2.1 范围与总账

审计 11 张“用户可感知/可产生”的表：`role_bindings`、`face_identity_feedback`、`person_photos`、`person_embeddings`、`face_clusters`、`persons`、`culling_decisions`、`culling_history`、`navigation_groups`、`smart_albums`、`workflow_templates`（另检查 `metadata_keyword_origins`：无 FK，但会被删除路径留下孤儿）。

共 **18 条 FK**。

- **审计时（23:50）**：6 条语义变化（5 条 NO ACTION → CASCADE + 1 条 NO ACTION → SET NULL），审计时 V1 无 RESTRICT、无 NO ACTION。
- **23:58 复核**：并发改动已落地 4 条保护型修复——`role_bindings.cluster_id` → RESTRICT（`SchemaV1.swift:371`）、`person_photos.photo_id/session_id` → RESTRICT（`:465-466`）、`face_identity_feedback.person_id` → SET NULL（`:319`）。V1 的 62 条 FK 现为 **52 CASCADE + 7 SET NULL + 3 RESTRICT**。
- **仍存（用户数据域）**：`person_embeddings.photo_id/session_id` CASCADE（`SchemaV1.swift:447-455`，删照片/会话静默删身份向量，可重建）；`face_clusters.matched_person_id` SET NULL 不改 `status`（`:344`，可留 bound+NULL）。

### 2.2 逐边表

> 旧动作来自 `DB/Schema.swift` 的 DDL（默认 = NO ACTION）；V1 动作来自 `DB/SchemaV1.swift`。表名后的行号是 DDL 起始行。

| # | 子表.列 | 父表 | 旧动作 | V1 动作（23:50 → 23:58） | 变化 | 用户数据风险 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `role_bindings.cluster_id` | face_clusters | 默认 | **CASCADE → RESTRICT（23:58）** | **改** | 删簇被 RESTRICT 拒绝，需先显式解绑（已修） |
| 2 | `role_bindings.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删绑定（既有） |
| 3 | `face_identity_feedback.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删人工确认/否决（既有） |
| 4 | `face_identity_feedback.photo_id` | photos | CASCADE | CASCADE | — | 删照片 → 删反馈（既有） |
| 5 | `face_identity_feedback.person_id` | persons | CASCADE | **CASCADE → SET NULL（23:58）** | **改** | 删身份 → 反馈保留、person_id 置空（已修） |
| 6 | `person_photos.person_id` | persons | CASCADE | CASCADE | — | 删身份 → 删身份-照片（既有） |
| 7 | `person_photos.photo_id` | photos | 默认 | **CASCADE → RESTRICT（23:58）** | **改** | 删照片被 RESTRICT 拒绝，需先 removePhoto（已修） |
| 8 | `person_photos.session_id` | sessions | 默认 | **CASCADE → RESTRICT（23:58）** | **改** | 删会话被 RESTRICT 拒绝（已修） |
| 9 | `person_embeddings.person_id` | persons | CASCADE | CASCADE | — | 删身份 → 删向量（既有，可重建） |
| 10 | `person_embeddings.photo_id` | photos | 默认 | **CASCADE** | **改** | 删照片 → 静默删向量（可重建） |
| 11 | `person_embeddings.session_id` | sessions | 默认 | **CASCADE** | **改** | 删会话 → 静默删向量 |
| 12 | `face_clusters.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删簇（既有） |
| 13 | `face_clusters.matched_person_id` | persons | 默认 | **SET NULL** | **改** | 删身份 → 静默解绑；**status 仍 'bound'**（P1，仍存） |
| 14 | `culling_decisions.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删挑片决策（既有） |
| 15 | `culling_decisions.photo_id` | photos | CASCADE | CASCADE | — | 删照片 → 删挑片决策（既有） |
| 16 | `culling_history.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删历史（既有） |
| 17 | `navigation_groups.session_id` | sessions | CASCADE | CASCADE | — | 删会话 → 删手动分组（既有） |
| 18 | `navigation_groups.lead_photo_id` | photos | SET NULL | SET NULL | — | 删照片 → lead 置空（既有） |

DDL 证据：
- 旧：`DB/Schema.swift:262-273`（face_clusters）、`:285-293`（role_bindings）、`:236-245`（feedback）、`:399-407`（person_photos）、`:379-397`（person_embeddings）、`:478-493`（culling_decisions）、`:495-501`（culling_history）、`:503-514`（navigation_groups）。
- V1（23:58 行号）：`DB/SchemaV1.swift:338-348`（face_clusters）、`:369-377`（role_bindings）、`:311-323`（feedback）、`:462-470`（person_photos）、`:447-455`（person_embeddings）、`:526-542`（culling_decisions）、`:547-553`（culling_history）、`:558-569`（navigation_groups）。

### 2.3 会静默删除用户数据的路径（代码级）

**路径 1（审计时 P0；23:58 已改 RESTRICT）：`DELETE FROM face_clusters` → `role_bindings`。**
审计时 V1 是 CASCADE，靠三处显式保护：
- `Repo/FaceRepo.swift:943-951` `deleteClustersBySession` 先 `:947` 删 `role_bindings`，再 `:948` 删簇；
- `Repo/FaceRepo.swift:989-1008` `removeMemberFromCluster` 在最后成员移除时先 `:1001` 删绑定，再 `:1002` 删簇；
- `Svc/FaceKwService.swift:1409-1410` 重聚类只删“不在 role_bindings 里”的簇（`id NOT IN (SELECT cluster_id FROM role_bindings)`）。

审计时 V1 CASCADE 会把这三处保护变成“可选的礼仪”：任何新代码直接 `DELETE FROM face_clusters WHERE session_id = ?` 就会静默带走绑定。绑定不是普通派生数据——`PersonRepo.swift:12-20` 明确它是“会被 upsertByName 按名认领”的用户身份凭据。**23:58 复核：`SchemaV1.swift:371` 已改 `ON DELETE RESTRICT`，删簇前必须先删绑定，静默删除路径关闭；上述三处保护仍保留为唯一解绑入口 + 回归基线。**

**路径 2：`DELETE FROM photos` → `person_photos/person_embeddings/face_identity_feedback/culling_decisions/duplicate_group_members`。**
- `Svc/IndexerService.swift:276-284` 清扫生成缓存照片时直接按 id 删 `photos`（`:282`）。V1 下 `person_photos.photo_id` 是 RESTRICT（23:58 已改），对已标记身份的照片会**报错**（必须先 `removePhoto`）；而 `person_embeddings`/`face_identity_feedback`/`culling_decisions` 仍 CASCADE，同一条 DELETE 对子表是“报错 + 静默删”两种结局，必须分别测试。
- `Repo/PhotoRepo.swift:322` `deleteBySession` 今天只在 `Svc/SessionService.swift:154-168` 的 6 步手工顺序**之后**调用；V1 后 `person_photos` RESTRICT 会让“顺序删漏”重新变成报错（这是好事），但 `person_embeddings` 仍会被级联静默清空。

**路径 3（审计时 P1；23:58 已改 SET NULL）：`DELETE FROM persons` → `face_identity_feedback`。**
审计时 `face_identity_feedback.person_id` 是 CASCADE，而 `Repo/PersonRepo.swift:484-501` 的 delete 事务只显式删 `role_bindings/person_photos/person_embeddings`，不删 feedback——人工确认/否决会随身份消失。**23:58 复核：`SchemaV1.swift:319` 已改 `ON DELETE SET NULL`，反馈行保留、`person_id` 置空；`PersonRepo.delete` 不需要再显式删 feedback。仍需业务规则处理 `decision='confirmed' AND person_id IS NULL` 的 UI 语义（谁被确认？），并加测试。**

**路径 4：`DELETE FROM sessions` → 全部会话域用户数据。**
`Svc/SessionService.swift:121-122/138-140` 删会话前调用 `deleteSessionDependencies`（`:154-168`）。V1 后这一步可收缩为一次 `DELETE FROM sessions`，但同一语句会级联删掉 `culling_decisions`、`culling_history`、`navigation_groups`（manual）、`role_bindings` 等**用户工作成果**。这些本来就是会话作用域，产品上可接受，但 UI 必须在删除会话前明确告知（当前是否告知未验证，标记【疑似】）。

**路径 5：`SET NULL` 不维护 `status`。**
`Repo/PersonRepo.swift:494-496` 在删身份时显式执行 `matched_person_id = NULL, match_confidence = NULL, status = 'unbound'`。V1 的 `ON DELETE SET NULL` 只会置空前两列，**不会改 `status`**；任何绕过 `applyIdentityTransition(.delete)` 的 `DELETE FROM persons` 都会留下 `status='bound' + matched_person_id IS NULL` 的不一致行，UI 的“已绑定”徽标会悬空。

### 2.4 建议：哪些必须 RESTRICT / SET NULL / CASCADE

| 边 | 建议 | 理由 |
| --- | --- | --- |
| `role_bindings.cluster_id` | **RESTRICT**（或保留 NO ACTION） | 用户数据 + XMP 关键词清理凭据；删簇必须显式解绑。恢复 `FaceRepo` 的三处保护为唯一入口 |
| `role_bindings.session_id` | CASCADE 可接受 | 会话删除是显式动作；但应在删除会话的确认框里列出“人物绑定将被删除” |
| `person_photos.photo_id / session_id` | **RESTRICT**（列 NOT NULL，不能 SET NULL） | 身份-照片是用户显式落库的桥接；照片/会话删除必须先走 `removePhoto` 或明确“解除身份关联” |
| `person_embeddings.photo_id / session_id` | CASCADE 可接受 | 派生向量，可从 `face_observations`/`person_photos` 重建；但需测试“删照片后向量不残留、不阻断” |
| `face_identity_feedback.person_id` | **SET NULL**（列可空）或显式删除 | 保留“否决/确认”证据；若 confirmed + NULL 语义不可接受，则在 `PersonRepo.delete` 里显式删 feedback 并记审计 |
| `face_identity_feedback.photo_id / session_id` | CASCADE 可接受 | 照片/会话不存在时，针对该脸的反馈已无锚点 |
| `face_clusters.matched_person_id` | SET NULL 可接受，但**必须同步 `status='unbound'`** | 触发器或保留 `PersonRepo` 的显式 UPDATE；否则出现 bound+NULL |
| `culling_decisions.photo_id / session_id` | CASCADE 可接受 | 决策以照片/会话为作用域；但须产品确认“删照片即删评分/挑片” |
| `culling_history.session_id` | CASCADE | 历史是会话审计，随会话消失 |
| `navigation_groups.session_id / lead_photo_id` | CASCADE / SET NULL 保留 | 分组是会话内派生+手动混合；lead 消失不删组 |
| `persons`、`smart_albums`、`workflow_templates` | 无 FK，天然安全 | 全局用户数据，不挂会话/照片 |
| `metadata_keyword_origins.xmp_path` | 无 FK（刻意） | 删除照片/会话后成孤儿，需要 cleanup 扫描（按 `xmp_path` 是否存在对应文件）而不是 FK |

### 2.5 测试缺口

- **审计时（23:50）**：`Tests/Database/SchemaV1Tests.swift:499-545` 的删除矩阵只覆盖 `sessions`/`assets`，没有 role_bindings、person_photos、person_embeddings、face_identity_feedback、face_clusters SET NULL。
- **23:58 复核**：已新增 `role_bindings` RESTRICT（`:564-586`）、`person_photos` 删照片/删会话 RESTRICT（`:631-679`）、`face_identity_feedback.person_id` SET NULL（`:682-704`）、`person_embeddings` 级联（`:706+`）用例。
- **仍缺**：`face_clusters.matched_person_id` SET NULL 后 `status` 仍为 `'bound'` 的不变量断言；`navigation_groups.lead_photo_id` SET NULL 用例；`PersonRepo.delete` 之后 `confirmed + NULL` 的 UI 语义测试。
- 建议把“用户数据删除矩阵”做成表驱动：6 个父表 × 每个子的期望行数/期望状态，放在 `SchemaV1Tests` 里，与 `:540-601` 的列映射测试并列。

### 2.6 审计后并发修复状态（23:58 复核）

> 本节记录审计落盘后（23:50–23:58）源码被并行修改的结果；`SchemaV1Tests` 与 `SchemaV1.swift` 的行号以 23:58 为准。

| 审计项 | 23:50 结论 | 23:58 状态 | 证据 |
| --- | --- | --- | --- |
| R2-01 `role_bindings.cluster_id` | CASCADE，静默删绑定（P0） | **已修**：RESTRICT | `SchemaV1.swift:371`；测试 `SchemaV1Tests.swift:564-586` |
| R2-02 `person_photos.photo_id/session_id` | CASCADE，静默删桥接（P0） | **已修**：RESTRICT | `SchemaV1.swift:465-466`；测试 `:631-679` |
| R2-03 `person_embeddings` | CASCADE 可接受 | **保留 CASCADE**，已加级联测试 | `SchemaV1.swift:447-455`；测试 `:706+` |
| R2-04 `face_identity_feedback.person_id` | CASCADE，删人工反馈（P1） | **已修**：SET NULL | `SchemaV1.swift:319`；测试 `:682-704` |
| R2-05 `face_clusters.matched_person_id` | SET NULL 不改 status（P1） | **未修**（仅注释提醒调用方） | `SchemaV1.swift:344`；`PersonRepo.swift:495` |
| R3-01 `auto_raw_jpeg` | CHECK 拒绝（P0） | **已修**：CHECK 含该值 + 正向测试 | `SchemaV1.swift:156`；测试 `SchemaV1Tests.swift:591-608` |
| R3-02 `sessions.status='indexed'` | V1 CHECK 拒绝测试写（P1） | **未修**：`TemplateServiceTests` 仍写 `indexed` | `Tests/Services/TemplateServiceTests.swift:24-26` |
| R3-03 `MetadataSyncStatus.clean` | enum 多值（P1） | **未修**：enum 仍 8 值 | `Protocol/Culling.swift:58-67` |

---

## 3. R3 CHECK 漂移

### 3.1 方法

逐个比对三份文本：
1. 代码里的 SQL 写入字面量（`INSERT/UPDATE ... 'value'`）；
2. Swift enum 的 `allCases`（若存在）；
3. `SchemaV1.swift` 的 CHECK 集合。

重点是“代码写入但 CHECK 拒绝”与“enum 与 CHECK 双份文本漂移”。V1 是新建库、旧库整体 reset（`SchemaV1.swift:16-21`），所以**旧值不需要迁移**；这也意味着 R3 的修复可以只改代码/DDL，不需要数据搬运。

### 3.2 确认的漂移

| # | 写入点 | 写入值 | 目标列 / V1 CHECK | 现状 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | `Repo/AssetRepo.swift:963`（`mergeFileAssets`，UPDATE） | `'auto_raw_jpeg'` | `asset_members.binding_source` / 审计时 CHECK 仅 `IN ('import','backfill','manual_split')` | **生产写**；被 `acceptCandidate`（`:558-570`）与 `reconcileRawJpegLinks`（`:588`）经 `mergeFileAssets`（`:941`）调用 | **审计时 P0；23:58 已修**：`SchemaV1.swift:156` 的 CHECK 已含 `auto_raw_jpeg`，测试见 `SchemaV1Tests.swift:591-608`；保留为回归用例 |
| 2 | `Tests/Services/TemplateServiceTests.swift:24-26`（UPDATE sessions） | `'indexed'` | `sessions.status` / 5 值（`SchemaV1.swift:66`） | 测试夹具用 `sessionStatus: "indexed"` 写库；断言在 `:166-176` | **V1 必拒绝（P1，测试红）**；`indexed` 是 `WorkspaceStage`（`Protocol/Workspace.swift:16`），不是 SessionStatus |
| 3 | 无当前写点（历史值） | `'clean'`/`'cleaned'` | `deliveries.status` / 7 值（`SchemaV1.swift:619`） | `MetadataSyncStatus` 有 8 值（`Protocol/Culling.swift:58-67`）；`MetadataOutboxRepo.swift:27/686-692` 明说 `clean` 是历史终态、当前不再产生 | **enum 多值（P1）**；若 CHECK 由 `allCases` 生成，`clean` 会被重新写进 DDL；旧库 reset 后无存量，删 case 即可 |
| 4 | `Repo/WritebackRepo.swift:116`（`updateStatus(status: String)`） | 任意字符串 | `writeback_items.xmp_status`（V1 由 `delivery_items.status` 4 值替代） | 调用方目前只传 `failed`/`written`（`Svc/WritebackService.swift:410/461/486/507/516`），但签名无约束 | **类型泄漏（P1/P2）**；Cut 2 应改用 `DeliveryItemStatus` |
| 5 | `Repo/SessionRepo.swift:139`（`updateStatus(status: String)`） | 任意字符串 | `sessions.status` | 生产只传 `photos_loaded`（`Svc/SessionService.swift:220`、`Svc/IndexerService.swift:737`）；测试直接 UPDATE 绕过 | **类型泄漏（P2）**；改 `SessionStatus` 签名可让 `indexed` 在编译期失败 |
| 6 | `Repo/PhotoRepo.swift:294/346`、`Svc/DuplicateService.swift:673/689/709` | pending/ready/removed/missing | `photos.status` / 4 值 | V1 允许；但**没有 PhotoStatus enum**（草案标“新建”） | 缺 enum（P2），不是当前拒绝点 |
| 7 | `Repo/AssetRepo.swift:135/188/195` | running/completed/failed | `asset_backfill_state.status` / 3 值 | V1 允许；无 enum | 缺 enum（P2） |
| 8 | `Repo/AssetRepo.swift:1202-1214`、`:1129/1155`、`Svc/SessionService.swift:125/142` | image/raw/unknown、online/offline、active/orphan/offline_unverified | V1 三处 CHECK | V1 允许；无 enum | 缺 enum（P2） |

补充：`analysis_runs.kind` 只写 `face`/`similarity`（`Svc/FaceKwService.swift:638-640`、`Svc/SimilarityService.swift:254-256`），V1 CHECK 允许；`analysis_runs.status` 只写 `running/ok/failed`（`:609/770/1006`、`:236/422`），V1 允许。`culling_decisions.decision/color_label/decision_source` 的 enum 值与 V1 CHECK 逐字一致（`Protocol/Culling.swift:24-48`），无漂移。

### 3.3 建议：加 enum case，还是迁移旧值？

- **`auto_raw_jpeg`：加 case，不迁移。** V1 是新建库，没有旧行；23:58 的 CHECK 已含该值（`SchemaV1.swift:156`）。若后续建 `AssetBindingSource` enum，必须包含 `case autoRawJpeg = "auto_raw_jpeg"`，否则 R3-05 的“由 enum 生成 CHECK”会把该值重新删掉；正向测试已存在（`SchemaV1Tests.swift:591-608`）。若产品认为“合并来源”不该进 binding_source，则改为写 `'backfill'` 或 `'import'`，但这会丢失“这是自动 RAW/JPEG 合并”的溯源，**不推荐**。注意 Swift 关键字：`case imported = "import"` 是合法写法（不能直接写 `case import`）。
- **`indexed`：不加 case，改测试。** `SessionStatus` 的 5 值是产品状态机；`indexed` 是 `WorkspaceStage` 的 UI 阶段。把 `TemplateServiceTests` 的 fixture 改成 `"completed"`（仍是 `apply` 拒绝的合法 DB 值），断言消息改成 `"completed"`；这样既保留“拒绝非 draft/photos_loaded”的测试意图，又不污染 enum。
- **`clean`：删 case，不迁移。** V1 reset 旧库，`clean` 行不会进入 V1；`MetadataSyncStatus` 收敛为 `DeliveryStatus` 的 7 值。若未来做旧库迁移（当前不做），再补 `clean → synced` 的映射。
- **类型化入口**：`WritebackRepo.updateStatus` 与 `SessionRepo.updateStatus` 改枚举参数，让非法值在编译期失败；这比运行期 CHECK 更早。
- **CHECK 生成**：草案 §4.1 要求 `enum.allCases.map(\.rawValue)` 生成 CHECK。当前 `SchemaV1.sql` 是静态字符串，建议在 DDL 里插值 `\(AssetBindingSource.checkList)` 这类静态片段，并用测试做**双向相等**断言（`Set(enum.allCases) == Set(CHECK 集合)`）。在这之前，先补齐缺失的 enum（PhotoStatus、AssetStatus、BackfillStatus、AssetBindingSource、AssetMediaType 等），否则“生成”无从谈起。

### 3.4 测试缺口

- 审计时 `SchemaV1Tests.swift:79-309` 的 28 个 CHECK 拒绝用例**没有** `asset_members.binding_source` 用例——这正是 `auto_raw_jpeg` 能漏网的原因。23:58 复核已补：正向（`SchemaV1Tests.swift:591-608`）与未登记值反向（`:255-261`）。
- 没有“enum allCases == CHECK 集合”的双向断言；也没有“扫描代码里的 SQL 字面量，凡落入状态列者必须在 CHECK 集合内”的静态门禁。建议新增脚本（只读、CI 运行）：提取 `INSERT/UPDATE` 中的状态字面量 → 与 `SchemaV1.swift` 的 CHECK 集合比对。

---

## 4. 可执行清单

> 风险级别：P0 = Cut 2 阻塞（静默丢数据或正常路径运行期失败）；P1 = Cut 2 应修（测试/边界路径失败或结构性风险）；P2 = Cut 3+ 跟进。
> 目标 Cut：「Cut 2」= 本次；「Cut 2 门禁」= 合并前必须绿；「Cut 3」= 后续。
> **状态（23:58）**：R2-01/R2-02/R2-03/R2-04 与 R3-01 已在并发改动中落地（证据见 §2.6/§3.2）；表中保留原始动作作为验收对照。

| ID | 文件:行 | 风险 | 修复动作 | 目标 Cut |
| --- | --- | --- | --- | --- |
| R1-01 | `Repo/PhotoRepo.swift:195`；`PhotoRow` `:28-46` | P0 | 改用 `PhotoRow.columns`（V1 14 列）+ `queryNamed`；删 metadata/result；同步 `Svc/CullingService.swift:205-214` | Cut 2 |
| R1-02 | `Repo/FaceRepo.swift:332`；`FaceObservationRow` `:40-62` | P0 | 17 列显式清单 + 命名解码；删 `sourceFileSize/Mtime`（需要则 JOIN `face_analysis_state`） | Cut 2 |
| R1-03 | `Repo/FaceRepo.swift:740-752`；`FaceClusterRow` `:83-95` | P0 | 删 `c.thumbnail_base64`；保留 COUNT 别名；按名解码 thumbnail_path/matched_person_id/match_confidence | Cut 2 |
| R1-04 | `Repo/SessionRepo.swift:52-78`、`:22-38` | P0 | 投影改为 11 列（10 物理 + analysis_status）；删 3 字段；按名解码 | Cut 2 |
| R1-05 | `Repo/MetadataOutboxRepo.swift:243/250/296/315/328/702/721`、`Repo/WritebackRepo.swift:99`、`Svc/CullingService.swift:1638` | P0 | 随旧表删除 `MetadataOutboxRow/WritebackItemRow` 及其全部读点；不得平移到 deliveries | Cut 2 |
| R1-06 | `Repo/PhotoRepo.swift:294`、`Repo/AssetRepo.swift:999/1126`、`Repo/FaceRepo.swift:680/708/1004`、`Repo/PersonRepo.swift:403-406/725`、`Repo/SessionRepo.swift:91`、`Svc/SimilarityService.swift:854`、`Svc/FaceKwService.swift:1775`、`Repo/SmartAlbumRepo.swift:95` | P0 | 删除/改名上述列级写入；每处加 `prepare` 冒烟测试 | Cut 2 |
| R1-07 | `Tests/Database/SchemaV1Tests.swift:430-440` | P0 | 增加 `PRAGMA table_info` 的列名/列序/NOT NULL/默认值快照断言（当前只断言列数） | Cut 2 门禁 |
| R1-08 | 其余 30 处 star（见 §1.2） | P1 | 改显式列清单；禁止新增 `SELECT *` | Cut 2 |
| R1-09 | `DB/DB.swift:33/241-371` | P1 | 新增 `NamedRow/queryNamed/decoded(by:)`；把 `DeliveryRepo` 的 `DeliveryColumnMap` 上提共用 | Cut 2 |
| R1-10 | 仓库门禁 | P1 | 新增 `scripts/check-select-star.sh`（Sources 0 命中）；Tests 允许白名单 | Cut 2 门禁 |
| R1-11 | `docs/schema-v1-draft.md` §2.4/§8 R1 | P2 | 修正 42→41、63→66，并附复算脚本 | Cut 2 文档 |
| R1-12 | `Repo/SmartAlbumRepo.swift:95` | P1 | `schema_version`→`filter_schema_version`；`SmartAlbumRow.schemaVersion` 字段同步改名 | Cut 2 |
| R2-01 | `DB/SchemaV1.swift:371`；`Repo/FaceRepo.swift:943-1008`；`Svc/FaceKwService.swift:1410` | P0 | **已落地 23:58**：`role_bindings.cluster_id` = RESTRICT；删簇必须先显式解绑；补回归测试（`:564-586`） | Cut 2 |
| R2-02 | `DB/SchemaV1.swift:465-466` | P0 | **已落地 23:58**：`person_photos.photo_id/session_id` = RESTRICT；照片/会话删除先显式 `removePhoto`；补 Indexer 路径测试（`:631-679`） | Cut 2 |
| R2-03 | `DB/SchemaV1.swift:404-405` | P1 | `person_embeddings` 保 CASCADE（派生可重建），补删除后无残留的测试 | Cut 2 |
| R2-04 | `DB/SchemaV1.swift:319`；`Repo/PersonRepo.swift:484-501` | P1 | **已落地 23:58**：`face_identity_feedback.person_id` = SET NULL；补 `confirmed + NULL` 的 UI 语义测试（`:682-704`） | Cut 2 |
| R2-05 | `DB/SchemaV1.swift:307`；`Repo/PersonRepo.swift:495` | P1 | `matched_person_id` SET NULL 时同步 `status='unbound'`（触发器或保留显式 UPDATE）+ 测试 | Cut 2 |
| R2-06 | `Tests/Database/SchemaV1Tests.swift:499-545` | P1 | 增加 role_bindings/person_photos/person_embeddings/feedback/face_clusters 的删除矩阵 | Cut 2 门禁 |
| R2-07 | `Svc/SessionService.swift:154-168` | P2 | FK 语义定稿后把 6 步手工删除收缩为一次 `DELETE sessions`；先加回归测试证明行为不变 | Cut 3 |
| R2-08 | `DB/SchemaV1.swift:514-523`（metadata_keyword_origins） | P2 | 增加 orphan 清理扫描（xmp_path 无对应文件）；不是 FK 能解决的 | Cut 3 |
| R3-01 | `Repo/AssetRepo.swift:963`；`DB/SchemaV1.swift:156` | P0 | **已落地 23:58**：CHECK 已含 `auto_raw_jpeg` + 正向测试；若后续建 `AssetBindingSource` enum，须含 `case autoRawJpeg = "auto_raw_jpeg"` | Cut 2 |
| R3-02 | `Tests/Services/TemplateServiceTests.swift:24-26/166-176` | P1 | fixture 改 `"completed"`；断言消息同步；不要把 `indexed` 加进 SessionStatus | Cut 2 |
| R3-03 | `Protocol/Culling.swift:58-67`；`DB/SchemaV1.swift:619` | P1 | 删除 `MetadataSyncStatus.clean`；收敛为 `DeliveryStatus`；无数据迁移（V1 reset） | Cut 2 |
| R3-04 | `Repo/WritebackRepo.swift:116`、`Repo/SessionRepo.swift:139` | P2 | 参数改 `DeliveryItemStatus`/`SessionStatus`；非法值编译期失败 | Cut 2/3 |
| R3-05 | `DB/SchemaV1.swift` 全部 CHECK | P1 | 由 `enum.allCases` 生成 CHECK 片段；加双向相等测试 + 状态字面量静态扫描 | Cut 2 门禁 |
| R3-06 | `Repo/AssetRepo.swift`、`Repo/PhotoRepo.swift`、`Repo/FaceRepo.swift` | P2 | 补齐 PhotoStatus/AssetStatus/BackfillStatus/AssetBindingSource 等 enum，作为 R3-05 的前置 | Cut 3 |

**Cut 2 合并前必须绿的门禁（建议顺序）**：
1. `SchemaV1Tests` 的列名/列序快照 + 删除矩阵（R1-07/R2-06）；
2. `SELECT *` 静态门禁（R1-10）；
3. `grep` 旧表/旧列引用清零（`metadata_outbox`、`writeback_items`、`metadata`/`result`/`capture_fingerprint`/`params`/`schema_version` 等）；
4. `binding_source='auto_raw_jpeg'` 的正向测试（R3-01）；
5. 全量 `swift test`（注意：本审计只读，未运行构建/测试）。

---

## 5. 复现命令（只读）

```bash
# 1) star 查询总量（44 行；扣掉注释后 41 条语句）
grep -rn 'SELECT \*' --include='*.swift' desktop/native | wc -l
grep -rn 'SELECT \*' --include='*.swift' desktop/native/gather-core/Sources | wc -l

# 2) 限定星号（o.*/p.*/pp.*/dgm.*）
grep -rnE 'SELECT[[:space:]]+[a-zA-Z_]+[[:space:]]*\.[[:space:]]*\*' --include='*.swift' desktop/native/gather-core/Sources

# 3) 行映射器清单（init(row:)）
grep -rn 'init(row: DBRow)' --include='*.swift' desktop/native/gather-core/Sources

# 4) 用户数据表 FK（旧 vs V1）
python3 - <<'PY'
import re
tables = ["role_bindings","face_identity_feedback","person_photos","person_embeddings",
          "face_clusters","persons","culling_decisions","culling_history",
          "navigation_groups","smart_albums","workflow_templates","metadata_keyword_origins"]
for path,label in [("desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift","OLD"),
                   ("desktop/native/gather-core/Sources/GatherCore/Database/SchemaV1.swift","V1")]:
    s=open(path).read()
    print("=====",label)
    for t in tables:
        m=re.search(r'CREATE TABLE(?: IF NOT EXISTS)? '+t+r' \((.*?)\n    \);', s, re.S)
        if not m: continue
        for line in m.group(1).splitlines():
            if 'REFERENCES' in line or 'FOREIGN KEY' in line: print(t, line.strip())
PY

# 5) 状态写入点（示例：binding_source / sessions.status）
grep -rn "binding_source" desktop/native/gather-core/Sources --include='*.swift'
grep -rn "UPDATE sessions SET status" desktop/native --include='*.swift'

# 6) 列级写入点（被删/改名）
grep -rn "capture_fingerprint\|metadata, result\|face_bbox, quality\|params, status\|schema_version" \
  desktop/native/gather-core/Sources --include='*.swift' | grep -v 'Schema.swift\|Migrations.swift\|SchemaV1.swift'
```

> 复现口径提醒：V1 的 `SchemaV1.sql` 与草案 §7.1 逐字一致（本审计已抽查 43 表/370 列/69 索引/62 FK 与 `SchemaV1Tests` 的期望值）；但 `SchemaV1.swift` 尚未接入 `Database.open`，所以上述行映射在**当前运行期**仍按旧 44 表 schema 工作，V1 切换那一次才会集中爆发。

---

### 审计边界

- 本审计只做静态读取；未运行 `swift build/test`（仓库正在并行改动，跑测试会与其他 Cut 的改动竞争）。
- 未验证 `EXPLAIN QUERY PLAN`、未做 10k 导入基准（属 §3.3/§8 R6，不在 R1/R2/R3 范围）。
- “会静默删除”的判定基于 `PRAGMA foreign_keys = ON`（`DB.swift:82`）与 V1 的 FK 动作；若运行时 FK 被关闭，行为会退化为孤儿行而不是级联删除——两者都需要测试，不能假设。
- 行号来自 2026-10-21 23:50–23:55 的静态扫描；`AssetRepo` 在扫描期间已漂移 +2 行，引用前请重新 `grep`。

---

## 6. 后续修正（2026-10-22，审计后）

- **R3-02 已修**：TemplateServiceTests 的 fixture 已从 sessions.status='indexed' 改为 'completed'，断言同步；TemplateServiceTests 11 tests 绿。正文中“仍写 indexed / 测试会红”为审计时快照，以此条为准。
- **R2-05 待接线**：face_clusters.matched_person_id 为 SET NULL，删 person 后会留 bound+NULL；不用触发器，Cut 2 S5 由服务显式 UPDATE status='unbound' 并加测试（D-034）。
- **R2-03 接受**：person_embeddings.photo_id/session_id 保留 CASCADE（派生向量可重建），补删除后无残留测试。
- **R1 未动**：41 处 SELECT * 仍由 Cut 2 S5 处理，是当前最大阻塞。
