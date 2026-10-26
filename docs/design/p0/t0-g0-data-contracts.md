# T0/G0 数据与契约设计（V3 · 排序分页 · Triage 读写）

> 文档：`docs/design/p0/t0-g0-data-contracts.md` · 负责人：T0/G0 数据与契约 · 状态：draft
> 上游：`docs/design/p0/README.md`（D1–D10）、`docs/design/p0/x0-contracts.md` §1.1（已采纳 typed cursor）
> 范围：Schema V3、排序分页、Triage 写入/查询/失效、Culling/Metadata/Maintenance 契约。
> 非范围：T0 规则与 UI、F0 拆分实现、B0 备份实现、K0 关键词交互。

## 结论先行

1. **V3 只做增量**：新增 `triage_suggestions`、`face_cluster_constraints`（F0 定稿，**6 列含 `peer_keys_json`**）+ 3 个索引；45 表 / **389 列** / 72 索引 / 65 外键，`user_version 2→3`，不改既有表。
2. **排序**：`CullingPageQuery` 增 `sort` 与 **typed `CullingPageCursor`**（`sort/dateKey/numberKey/rowId`）；`afterRowId` 仅 import 序（deprecated）；非 import 排序仅支持 `.all`/`.filtered`。
3. **Triage**：表以“逻辑资产首选行”为粒度；失效用**读时 `input_fingerprint`**，不挂写时钩子；`applyTriage` 走 `Confirmed` + 指纹校验，只写 `pickState`、`decision_source='ai'`、单条 history、跳过人工。
4. **协议增量**：Culling +2、Metadata +3（K0 定稿：preview/apply/retry）、Face +2（split/review）、Maintenance +4；16→17 协议、110→**121** 方法。
5. **估算 17 PD**；最大风险是 50k 排序临时 B-tree 与 20k triage 生成。

## 1. 目标 / 非目标

| 项 | 内容 |
|---|---|
| 目标 | 可直接落地的 V3 DDL/迁移；三 scope 的精确 keyset SQL；triage 读写/失效；API 签名与 20k/50k 预算 |
| 非目标 | triage 规则细节（`t0-triage-policy.md`）、Grid UI、F0 约束应用、B0 恢复流程、K0 关键词面板 |
| 硬约束 | D2 只增量；D4 不自动写 XMP；D7 基线/设置键；D9 性能预算；X0 §1.1 typed cursor |

## 2. Schema V3：DDL、迁移、备份、回滚

### 2.1 完整 DDL（V3 delta）

```sql
-- triage_suggestions：逻辑资产首选行一条；photo_id = 首选行
CREATE TABLE triage_suggestions (
  photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  verdict TEXT NOT NULL CHECK (verdict IN ('keep','reject','review')),
  score REAL NOT NULL DEFAULT 0,
  confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
  reasons_json TEXT NOT NULL DEFAULT '[]',
  group_id TEXT,
  policy_version TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  computed_at TEXT NOT NULL
);
CREATE INDEX idx_triage_session_verdict
  ON triage_suggestions(session_id, verdict, confidence);
CREATE INDEX idx_triage_session_confidence
  ON triage_suggestions(session_id, confidence);

-- F0 定稿：set-vs-set（member/peer）；6 列
CREATE TABLE face_cluster_constraints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('separate','together')),
  member_keys_json TEXT NOT NULL DEFAULT '[]',
  peer_keys_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_face_cluster_constraints_session
  ON face_cluster_constraints(session_id, kind);
```

计数依据：43+2=45 表；373+10+6=**389** 列；69+3=72 显式索引；62+3=65 外键。
`face_cluster_constraints` 与 triage **无共享列/索引/外键**，两工作流只在同一 V3 迁移中合并。

### 2.2 版本与迁移

```swift
public enum SchemaV3 {
    public static let version = SchemaVersion.v3
    public static let delta: String = """
    /* 2.1 的完整 SQL（F0 合并后保持字节稳定） */
    """
    public static let ddl: String = SchemaV1.ddl + "\n" + delta
    public static let shape = SchemaShapeExpectation(
        tableCount: 45, columnCount: 389,
        explicitIndexCount: 72, foreignKeyCount: 65,
        requiredColumns: SchemaV1.requiredTableColumns.merging([
            "triage_suggestions": ["photo_id","session_id","verdict","confidence",
                                   "input_fingerprint","policy_version"],
            "face_cluster_constraints": ["id","session_id","kind","member_keys_json","peer_keys_json"],
        ]) { $1 },
        fingerprint: "<V3 正确库实测值，禁止手算>"
    )
}

struct MigrationV2ToV3: SchemaMigration {
    let from: SchemaVersion = .v2
    let to: SchemaVersion = .v3
    let name = "v3-triage-and-face-constraints"
    func apply(_ connection: DBConnection) throws {
        try connection.exec(SchemaV3.delta)
    }
}
```

注册：`SchemaVersion.v3`；`SchemaCatalog.production` 的 `current = .v3`，snapshots 增 `.v3`，migrations 增 `MigrationV2ToV3()`；`SchemaSQL.currentSchemaVersion = 3`。V1/V2 快照与计数保持冻结。

迁移链（`Database.open` 已有逻辑，不新增分支）：

| 步骤 | 行为 | 文件 |
|---|---|---|
| 1 | 识别 `.older(.v2)`，先 `VACUUM INTO` 备份并只读校验 | `Database.swift:226`、`SchemaBackup.swift:21` |
| 2 | `BEGIN IMMEDIATE` 执行 V2→V3 delta → 写 `user_version=3` → `foreign_key_check` → 目标 shape 校验 | `SchemaMigrator.swift:38` |
| 3 | 提交；恢复 `PRAGMA foreign_keys=ON`；`assertReady` 复核 | `Database.swift:465` |
| 4 | 新库直接按 `SchemaV3.ddl + PRAGMA user_version=3` 一次建齐 | `SchemaSnapshot.createSQL` |

### 2.3 备份、失败、回滚

| 场景 | 结果 |
|---|---|
| 备份失败（磁盘满/权限/校验失败） | `DatabaseError.io`，**不迁移**，库仍 V2；备份名 `gather.sqlite.pre-v3-<ts>`，默认保留 3 份 |
| DDL/外键/形态校验失败 | 事务回滚，`user_version` 仍 2；备份保留；`open` 抛 `.migration`；下次启动可重试 |
| 迁移后 `assertReady` 失败 | 事务内失败，无“版本 3 + 形态 2”半成品 |
| 需要降级 | 无 down migration；退出应用，用 `.pre-v3-*` 覆盖主库并移除 `-wal/-shm`，再用旧构建启动（B0 文档写明） |
| V3 构建打开 V2 备份 | 正常走 V2→V3 迁移；不会静默丢数据 |

### 2.4 为什么不改既有表

- `culling_decisions.decision_source` 已含 `'ai'`（`SchemaV1+DDLDomain.swift:145`），applyTriage 不需要新列。
- `photo_metadata_cache.rating/date_taken` 已存在；排序用查询表达式，不新增归一列，避免改表触发重建。
- SQLite 修改 CHECK/默认值需重建表；V1/V2 快照与指纹必须保持可解释。
- `face_cluster_constraints` 独立成表，避免给 `face_clusters`/`role_bindings`（RESTRICT 外键）增加迁移风险。

## 3. CullingPageQuery：sort / typed cursor

### 3.1 精确类型（GatherProtocol）

```swift
public enum CullingSort: String, Codable, CaseIterable, Equatable, Sendable {
    case importOrder = "import"
    case captureDesc = "capture_desc"
    case captureAsc = "capture_asc"
    case ratingDesc = "rating_desc"
    case triageConfidenceAsc = "triage_confidence_asc"
}

public struct CullingPageCursor: Codable, Equatable, Sendable {
    public let sort: CullingSort
    public let dateKey: String?    // capture 系：规范文本；未知日期 = ""
    public let numberKey: Double?  // rating 0...5；triage 0...1
    public let rowId: Int64        // 组首选行 rowid

    public init(
        sort: CullingSort,
        dateKey: String? = nil,
        numberKey: Double? = nil,
        rowId: Int64
    ) throws {
        guard sort != .importOrder else { throw Self.invalid("importOrder uses afterRowId") }
        guard rowId >= 1 else { throw Self.invalid("rowId must be >= 1") }
        switch sort {
        case .captureDesc, .captureAsc:
            guard let dateKey, numberKey == nil else {
                throw Self.invalid("capture cursor requires dateKey only")
            }
            self.dateKey = dateKey
            self.numberKey = nil
        case .ratingDesc:
            guard let numberKey, dateKey == nil,
                  numberKey.rounded() == numberKey,
                  (0.0...5.0).contains(numberKey) else {
                throw Self.invalid("rating cursor requires integer numberKey 0...5")
            }
            self.dateKey = nil
            self.numberKey = numberKey
        case .triageConfidenceAsc:
            guard let numberKey, dateKey == nil, numberKey.isFinite,
                  (0.0...1.0).contains(numberKey) else {
                throw Self.invalid("triage cursor requires numberKey 0...1")
            }
            self.dateKey = nil
            self.numberKey = numberKey
        case .importOrder:
            throw Self.invalid("unreachable")
        }
        self.sort = sort
        self.rowId = rowId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sort: try c.decode(CullingSort.self, forKey: .sort),
            dateKey: try c.decodeIfPresent(String.self, forKey: .dateKey),
            numberKey: try c.decodeIfPresent(Double.self, forKey: .numberKey),
            rowId: try c.decode(Int64.self, forKey: .rowId)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sort, forKey: .sort)
        try c.encodeIfPresent(dateKey, forKey: .dateKey)
        try c.encodeIfPresent(numberKey, forKey: .numberKey)
        try c.encode(rowId, forKey: .rowId)
    }

    private static func invalid(_ reason: String) -> GatherError {
        GatherError(code: .CULLING_CURSOR_INVALID,
                    params: ["field": "cursor", "reason": reason])
    }

    private enum CodingKeys: String, CodingKey {
        case sort, dateKey, numberKey, rowId
    }
}

public struct CullingPageQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let scope: CullingScope
    public let filters: CullingFilters?
    public let groupId: String?
    public let sort: CullingSort?   // nil = importOrder
    public let cursor: CullingPageCursor?
    /// Deprecated（契约级）：仅 importOrder 兼容；新代码用 cursor。
    public let afterRowId: Int64?
    public let limit: Int

    public init(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        groupId: String? = nil,
        sort: CullingSort? = nil,
        cursor: CullingPageCursor? = nil,
        afterRowId: Int64? = nil,
        limit: Int? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.scope = scope
        if let filters {
            for (index, rating) in (filters.ratings ?? []).enumerated() {
                _ = try APIValidation.integer(rating, field: "filters.ratings[\(index)]", in: 0...5)
            }
            if let verdicts = filters.triageVerdicts, !verdicts.isEmpty, scope != .filtered {
                throw GatherError(code: .CULLING_FILTER_INVALID,
                                  params: ["field": "filters.triageVerdicts",
                                           "reason": "only filtered scope supports triage filter"])
            }
        }
        self.filters = filters
        self.groupId = groupId
        self.sort = sort
        let effectiveSort = sort ?? .importOrder
        if cursor != nil && afterRowId != nil {
            throw GatherError(code: .CULLING_CURSOR_INVALID,
                              params: ["field": "cursor",
                                       "reason": "cursor and afterRowId are mutually exclusive"])
        }
        if let cursor {
            guard cursor.sort == effectiveSort else {
                throw GatherError(code: .CULLING_CURSOR_INVALID,
                                  params: ["field": "cursor", "reason": "cursor sort mismatch"])
            }
            guard effectiveSort != .importOrder else {
                throw GatherError(code: .CULLING_CURSOR_INVALID,
                                  params: ["field": "cursor", "reason": "importOrder uses afterRowId"])
            }
        } else if afterRowId != nil {
            guard effectiveSort == .importOrder else {
                throw GatherError(code: .CULLING_CURSOR_INVALID,
                                  params: ["field": "afterRowId",
                                           "reason": "only importOrder supports afterRowId"])
            }
        }
        if effectiveSort != .importOrder && scope == .similarityGroup {
            throw GatherError(code: .CULLING_CURSOR_INVALID,
                              params: ["field": "sort",
                                       "reason": "non-import sort is not supported for similarityGroup"])
        }
        if let afterRowId, afterRowId < 1 {
            throw GatherError.invalidParameter(field: "afterRowId", reason: "must be a positive integer")
        }
        self.cursor = cursor
        self.afterRowId = afterRowId
        self.limit = try APIValidation.integerInRange(limit ?? 200, field: "limit", 1...2_000)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try c.decode(String.self, forKey: .sessionId),
            scope: try c.decode(CullingScope.self, forKey: .scope),
            filters: try c.decodeIfPresent(CullingFilters.self, forKey: .filters),
            groupId: try c.decodeIfPresent(String.self, forKey: .groupId),
            sort: try c.decodeIfPresent(CullingSort.self, forKey: .sort),
            cursor: try c.decodeIfPresent(CullingPageCursor.self, forKey: .cursor),
            afterRowId: try c.decodeIfPresent(Int64.self, forKey: .afterRowId),
            limit: try c.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, scope, filters, groupId, sort, cursor, afterRowId, limit
    }
}
```

`CullingPage`：`nextRowId: Int?` 契约级 deprecated（仅 importOrder 填值），新增 `nextCursor: CullingPageCursor?`；编码时 `nextRowId` 保持“键恒存在、nil→null”的旧形状，`nextCursor` 用 `encodeIfPresent`。

> deprecated 暂只做契约级标注（避免现有全仓调用产生 warning）；现有调用清理后再加 `@available(*, deprecated, ...)`，接口形状先按本文件实现。

### 3.2 校验矩阵

| 输入组合 | 结果 |
|---|---|
| `sort == .importOrder` + `afterRowId` | 合法（旧路径） |
| `sort == .importOrder` + `cursor` | `CULLING_CURSOR_INVALID` |
| `sort != .importOrder` + `afterRowId` | `CULLING_CURSOR_INVALID` |
| `cursor.sort != sort` / `rowId < 1` / key 与 sort 不匹配 | `CULLING_CURSOR_INVALID` |
| `cursor.dateKey`/`numberKey` 与 sort 不匹配（含 nil） | `CULLING_CURSOR_INVALID` |
| `sort != .importOrder` 且 `scope == .similarityGroup` | `CULLING_CURSOR_INVALID`（scope 不兼容） |
| `filters.triageVerdicts` 非空且 scope != .filtered | `CULLING_FILTER_INVALID` |
| triage 过滤/排序但会话无 fresh 结果 | 服务层 `TRIAGE_NOT_READY` |

> `triageConfidenceAsc` 允许 `.all`/`.filtered`（X0 规则）；`.all` 下未生成建议的资产 confidence 归一为 0，UI 实际只用 `.filtered` 复核队列。
> `sort == nil` 与 `.importOrder` 等价；cursor 仅当 effectiveSort != import 才合法。X0 的“key 非空”按**字段存在**解释：`dateKey` 可为 `""`（未知日期），`numberKey` 必须存在且落在值域。

### 3.3 载荷与读端口（精确增量）

```swift
// CullingPage：编码必须保留旧 nextRowId 形状（nil → null），新增字段 encodeIfPresent
public struct CullingPage: Codable, Equatable, Sendable {
    public var assets: [CullingAsset]
    public var nextRowId: Int?            // deprecated（契约级）：仅 importOrder
    public var nextCursor: CullingPageCursor?
    public var total: Int
    public var triage: TriageSummary?
}
// 仅列增量字段；其余字段/Conformance 不变
public struct CullingAsset {
    public var triage: CullingTriage?     // nil=未生成/过期/已人工决策/无行；confidence=0 表示已生成未分析
}
// 仅列增量字段
public struct CullingSummary {
    public var triage: TriageSummary?     // 未生成时 nil
}
// 仅列增量字段
public struct CullingFilters {
    public var triageVerdicts: [TriageVerdict]?
}

// Persistence 读端口（CullingAssetPageQuery 实现）
public struct CullingPageSlice: Sendable {
    public let rows: [PhotoPageRow]
    public let nextRowId: Int64?          // import 序
    public let nextCursor: CullingPageCursor?
}
public protocol CullingPageReading {
    func pageAll(sessionId: String, sort: CullingSort,
                 cursor: CullingPageCursor?, afterRowId: Int64?, limit: Int) throws -> CullingPageSlice
    func pageFiltered(sessionId: String, filter: CullingPageFilter, sort: CullingSort,
                      cursor: CullingPageCursor?, afterRowId: Int64?, limit: Int) throws -> CullingPageSlice
    func pageSimilarity(sessionId: String, similarity: CullingSimilarityScope,
                        afterRowId: Int64?, limit: Int) throws -> CullingPageSlice
    func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int
    func countSimilarity(sessionId: String, similarity: CullingSimilarityScope) throws -> Int
}
public struct CullingPageFilter {
    public var triageVerdicts: [String]?
    public var triageFingerprint: String?
}

// Application 读端口（TriageService 实现；CullingService 以 optional 注入，nil 时不影响旧测试）
public protocol TriageReading: Sendable {
    func summary(sessionId: String) throws -> TriageSummary?
    func fingerprint(sessionId: String) throws -> String
    func suggestions(sessionId: String, fingerprint: String) throws -> [String: CullingTriage]
}
```

`CullingService.listPage` 规则：
- `.similarityGroup` 只接受 import；否则 `CULLING_CURSOR_INVALID`。
- `sort == .triageConfidenceAsc` 或 `filters.triageVerdicts != nil`：`triage` 端口必须存在且 fingerprint 为 current；否则 `TRIAGE_NOT_READY`。
- `buildRichLookup(..., triageFingerprint:)` 只把 fingerprint 相等的建议放入 `CullingAsset.triage`；stale 资产不展示。
- `nextRowId` 只在 import 填；`nextCursor` 只在排序模式填。

## 4. 排序 keyset：精确 SQL

### 4.1 代表行与三种 sort key

- 代表行 = `PhotoRepo.preferredRowOrderSQL(alias:)`（RAW 优先、其次最小 rowid，`PhotoRepo.swift:179`）；`filteredWhere` 已含 `preferredRowPredicate()`（`CullingAssetPageQuery.swift:167`）。
- `first_rowid`：import 序沿用 `MIN(p.rowid)`；排序模式 = 代表行 `p.rowid`（游标与排序键同一行）。
- 三种 key 的归一（对应 X0 §1.1）：

| key | SQL 表达式 | 空值归一 | 游标字段 |
|---|---|---|---|
| capture | `COALESCE(strftime('%Y-%m-%d %H:%M:%S', CASE WHEN c.date_taken GLOB '????:??:??*' THEN replace(substr(c.date_taken,1,10),':','-') || substr(c.date_taken,11) ELSE c.date_taken END), '')` | `''`（未知日期） | `dateKey: String?` |
| rating | `COALESCE(c.rating, 0)` | `0` | `numberKey: Double?` |
| triage | `COALESCE(t.confidence, 2.0)` | `2.0` 哨兵（无建议） | `numberKey: Double?` |

`strftime` 把 EXIF `YYYY:MM:DD HH:MM:SS`（先归一）与 ISO `YYYY-MM-DDTHH:MM:SSZ` 统一成固定宽度文本，字典序即时间序；未知/非法日期为 `''`，ASC 时排最前、DESC 时排最后（SQLite BINARY collation），并列由 `first_rowid` 决胜。

triage 的 `2.0` 是**排序哨兵**（confidence 恒在 0...1）：ASC 时“未生成建议”排在所有有建议项之后；游标原样携带 2.0，payload 仍区分 nil 与 0。

### 4.2 filtered：capture keyset（DESC；ASC 反向）

```sql
SELECT gid, first_rowid, date_key FROM (
  SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
         p.rowid AS first_rowid,
         COALESCE(strftime('%Y-%m-%d %H:%M:%S',
           CASE WHEN c.date_taken GLOB '????:??:??*'
                THEN replace(substr(c.date_taken, 1, 10), ':', '-') || substr(c.date_taken, 11)
                ELSE c.date_taken END), '') AS date_key
  FROM photos p
  LEFT JOIN culling_decisions d
    ON d.session_id = p.session_id AND d.photo_id = p.id
  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
  /* triage 过滤/排序时追加 LEFT JOIN triage_suggestions + t.verdict IN */
  WHERE <filteredWhere（已含 preferredRowPredicate）>
) s
WHERE (date_key < ?) OR (date_key = ? AND first_rowid < ?)
ORDER BY date_key DESC, first_rowid DESC
LIMIT ?;
```

ASC：`(date_key > ?) OR (date_key = ? AND first_rowid > ?)`，`ORDER BY date_key ASC, first_rowid ASC`。

### 4.3 filtered：rating keyset（DESC）

```sql
SELECT gid, first_rowid, rating_key FROM (
  SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
         p.rowid AS first_rowid,
         COALESCE(c.rating, 0) AS rating_key
  FROM photos p
  LEFT JOIN culling_decisions d
    ON d.session_id = p.session_id AND d.photo_id = p.id
  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
  WHERE <filteredWhere（已含 preferredRowPredicate）>
) s
WHERE (rating_key < ?) OR (rating_key = ? AND first_rowid < ?)
ORDER BY rating_key DESC, first_rowid DESC
LIMIT ?;
```

`rating_key` 用 `.real` 绑定（0...5），不要用文本，避免 `10 < 2` 类问题。

### 4.4 filtered：triage confidence keyset（ASC）

```sql
SELECT gid, first_rowid, confidence_key FROM (
  SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
         p.rowid AS first_rowid,
         COALESCE(t.confidence, 2.0) AS confidence_key
  FROM photos p
  LEFT JOIN culling_decisions d
    ON d.session_id = p.session_id AND d.photo_id = p.id
  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
  LEFT JOIN triage_suggestions t
    ON t.photo_id = p.id AND t.session_id = p.session_id
   AND t.input_fingerprint = ?
  WHERE <filteredWhere> AND t.verdict IN (?, ?, ?)
) s
WHERE (confidence_key > ?) OR (confidence_key = ? AND first_rowid > ?)
ORDER BY confidence_key ASC, first_rowid ASC
LIMIT ?;
```

`t.confidence` 用 `.real`；`input_fingerprint` 必须等于当前 fingerprint（服务层先校验，避免 stale 行参与）。`t.verdict IN` 的占位符按实际 verdict 数量动态生成（1–3 个），不要写死三个。

### 4.5 all scope

```sql
WITH preferred AS (
  SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
         p.rowid AS first_rowid,
         <SORT_KEY_EXPR> AS sort_key
  FROM photos p
  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
  /* triage sort 时追加 LEFT JOIN triage_suggestions t ... input_fingerprint = ? */
  WHERE p.session_id = ?
    AND p.id = (
      SELECT p2.id FROM photos p2
      WHERE p2.session_id = p.session_id
        AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
          = COALESCE(NULLIF(p.asset_id, ''), p.id)
      ORDER BY <PhotoRepo.preferredRowOrderSQL(alias: "p2")>
      LIMIT 1
    )
)
SELECT gid, first_rowid, sort_key FROM preferred
WHERE <CURSOR_PREDICATE>   -- capture/rating DESC；triage ASC
ORDER BY sort_key <DIR>, first_rowid <DIR>
LIMIT ?;
```

`SORT_KEY_EXPR` 按 §4.1 替换；取回 gid 后仍用 `loadAssetRows` 加载全部变体（RAW+JPEG 永不分页）。import 序继续走既有 `PhotoRepo.getAssetPage`，不改旧路径。

### 4.6 并列、NULL 与切换

| 规则 | 实现 |
|---|---|
| 并列 | `(sort_key, first_rowid)` 复合比较；同 key 按 rowid 决胜，跨页稳定 |
| 未知日期 | `dateKey = ""`；ASC 最前、DESC 最后；不得用 nil 表示 |
| 未评级 | `ratingKey = 0`（与“0 星”同组），rowid 决胜 |
| 未生成/无建议 | `confidenceKey = 2.0`（仅 `.all` 可能出现；ASC 排最后；`.filtered` 由 verdict 过滤排除） |
| 切排序 | cursor.sort 必须等于 effectiveSort（query.sort ?? import）；UI 切排序清空 cursor |
| 数据插入 | keyset 只保证“游标之后”的新数据可见；游标之前的插入不补（标准行为） |
| 删除 | 被删组消失；cursor 不指向行内容，后续页不重不漏 |
| 末页判定 | 仅当本次返回 < limit 时 `nextCursor=nil`；恰好整页时允许下一次空页（与现有 keyset 一致，不做 +1 预读） |
| scope | 非 import 排序仅 `.all`/`.filtered`；`.similarityGroup` 直接报错 |

### 4.7 NULL/并列测试矩阵

| 数据集 | sort | 断言 |
|---|---|---|
| 1 张 NULL date、1 张 `''`、1 张 EXIF、1 张 ISO、1 张同秒 | capture_desc / capture_asc | `''` 组位置符合 §4.6；同秒按 rowid；20 页无重漏 |
| rating NULL、0、1、5，各 100 张 | rating_desc | NULL→0；全 0 组按 rowid 降序稳定；cursor 从 (0, rowId) 继续 |
| 无建议、confidence 0、0.5、0.55、1.0 | triage_confidence_asc | 有建议按 0/0.5/0.55/1.0 升序；无建议（2.0）最后；同值按 rowid 升序；verdict 过滤只留 review |
| RAW+JPEG 2/4 变体、同资产多行 | 全部 sort | 每页资产完整、变体齐全；first_rowid 取代表行 |
| 页大小 1/17/200/1000；20 页 | 全部 sort | 与 Swift 期望序逐项相等；末次非空页后允许一次空页并 `nextCursor=nil` |
| 跨 sort 复用 cursor、篡改 dateKey/numberKey/rowId | — | `CULLING_CURSOR_INVALID`，不返回半页 |

## 5. Triage 写入、查询、失效

### 5.1 写入（generate）

```sql
DELETE FROM triage_suggestions WHERE session_id = ?;
INSERT INTO triage_suggestions
  (photo_id, session_id, verdict, score, confidence, reasons_json,
   group_id, policy_version, input_fingerprint, computed_at)
VALUES (?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(photo_id) DO UPDATE SET
  session_id=excluded.session_id, verdict=excluded.verdict,
  score=excluded.score, confidence=excluded.confidence,
  reasons_json=excluded.reasons_json, group_id=excluded.group_id,
  policy_version=excluded.policy_version,
  input_fingerprint=excluded.input_fingerprint, computed_at=excluded.computed_at;
```

单事务（`BEGIN IMMEDIATE`）；20k 行准备一次语句批量执行。粒度=**逻辑资产首选行**（RAW 优先），apply 时展开到该资产全部变体。
- 生成前逐资产过滤：`decision_source='manual'` 且 `decision != 'pending'` 的资产**不建行**（X0 §1.3）；`pending` 仍可建议。
- `reasons_json` 与 API 同形：`[{"code":"...","value":0.83}]`，最多 3 条；`code` 由 T0 §4.2 码表定义。
- `group_id` 由 T0 按 exact > similarity > visual > navigation 选主组写入（`resultId:index` / `dup:<id>` / `nav:<id>`），仅作展示与分组，不参与游标。

### 5.2 input_fingerprint

```swift
let material = [
  "policy=\(policyVersion)", "session=\(indexSeq)",
  "quality=\(qualityCount):\(qualityMaxUpdatedAt)",
  "similarity=\(latestSimilarityResultId ?? 0)",
  "duplicate=\(latestDuplicateGroupId ?? 0)",
  "navigation=\(latestNavigationUpdatedAt ?? "")",
  "minExec=\(triageMinExecutableConfidence)",
  "rejectMin=\(triageRejectConfidenceMin)",
].joined(separator: "|")
let fingerprint = SHA256.hash(Data(material.utf8)).hex
```

变量映射：`triageMinExecutableConfidence` = settings `triage_min_executable_confidence`（默认 0.55），`triageRejectConfidenceMin` = settings `triage_reject_confidence_min`（默认 0.75）；keep 下限 0.60 是 policy v1 常量，不单独进 settings。

`navigation` 取 `MAX(navigation_groups.updated_at)`（无则空串）；`similarity` 取最新非预计算 result id；`duplicate` 取 `MAX(duplicate_groups.id)`。这些都是 X0 §1.3 指纹的输入，缺一项会让“重算后仍显示旧建议”。

质量聚合（20k 约 10–30ms）：
```sql
SELECT COUNT(*), COALESCE(MAX(aa.updated_at), '')
FROM asset_analysis aa
JOIN photos p ON p.asset_file_id = aa.asset_file_id
WHERE p.session_id = ? AND aa.analysis_type = 'technical_quality';
```

### 5.3 失效：读时判定

| 输入变化 | 处理 |
|---|---|
| quality/similarity/duplicate 完成、照片增删改、阈值/策略变更 | 不删行；fingerprint 变化 → 读时 `stale` |
| 人工决策（manual 且 decision ≠ pending） | **generate 不建行**；apply 跳过并计 `skippedManual`（任一变体 manual 即整资产跳过） |
| 人工置 pending（manual + pending） | 允许生成建议；apply 仍按“人工”跳过 |
| 读 | `summary` 比较 stored vs current；不一致 → `stale=true`、资产 `triage=nil` |
| nil vs 0 | `triage=nil` = 未生成/过期/已人工决策/无行；`confidence==0` = 已生成但未分析；UI 不得混同 |
| apply | `fingerprint` 必须等于 current，否则 `TRIAGE_STALE`（不部分应用） |
| 重算 | 只有显式 `generateTriage`；不后台自动跑 |

不挂写时钩子：钩子分散在 4 个服务且易漏；fingerprint 是唯一判据，读时比较一次即可。fingerprint 在服务内按 session 缓存 2s。

### 5.4 过滤 SQL

```sql
AND EXISTS (
  SELECT 1 FROM triage_suggestions t
  WHERE t.photo_id = p.id AND t.session_id = ?
    AND t.input_fingerprint = ? AND t.verdict IN (?, ?, ?)
)
```

排序 join 已在 §4.4；过滤与排序共用 join 时 `input_fingerprint` 只传一次，`verdict IN` 占位符按实际数量生成；`countFiltered` 复用同一谓词，保证 total 与页同口径。

### 5.5 applyTriage

```swift
public func applyTriage(
    sessionId: String, verdicts: [TriageVerdict],
    minConfidence: Double?, fingerprint: String
) throws -> TriageApplyResult
```

流程：校验指纹 → 读 suggestions → 过滤 `verdict ∈ {keep,reject}`、confidence、manual → 按资产展开全部变体 → 生成 `CullingHistoryApplyEntry(pickState:)` → **一次 `applyHistory(source: .ai)`**（单条 history、revision 校验、事务）。
- `minConfidence` 语义：`effectiveMin = max(input ?? 0, policyLowerBound(verdict))`，**不允许低于 verdict 安全线**（X0 §1.3：keep ≥0.60、reject ≥0.75、<0.55 绝不执行）。
- 不写 rating/label，不入 metadata 队列；D4 满足。
- `applyHistory` 的精确签名（默认值保持旧调用不变）：
```swift
public func applyHistory(
    sessionId: String,
    requestedEntries: [CullingHistoryApplyEntry],
    historyOperationId: Int? = nil,
    direction: CullingHistoryDirection? = nil,
    source: CullingDecisionSource = .manual
) throws -> [CullingUpdateResult]
```
  内部 `AssetCullingState(source: source)`、`CullingDecisionStateInput(..., source: source.rawValue)`；`CullingDecisionRepo.swift:56` 已支持 optional `source`（缺省 manual）。
- 结果：`appliedAssets`、`appliedPhotos`、`skippedManual`、`skippedLowConfidence`、`skippedMissing`、`historyOperationId`。

## 6. API delta

| 协议 | 变更 | 签名 |
|---|---|---|
| CullingAPI | 变更 | `page(_ query: CullingPageQuery)`（sort/typed cursor/nextCursor） |
| CullingAPI | 新增 | `generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary` |
| CullingAPI | 新增 | `applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult` |
| CullingAPI | 载荷 | `CullingSummary.triage`、`CullingAsset.triage`、`CullingPage.triage`、`CullingFilters.triageVerdicts` |
| MetadataAPI | 新增 | `preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview` |
| MaintenanceAPI | 新协议 | `backup / listBackups / restore / exportDiagnostics`（草案，B0 定稿） |

```swift
public enum TriageVerdict: String, Codable, CaseIterable, Equatable, Sendable {
    case keep, reject, review
}
// code 取值 ∈ T0 §4.2 码表（本文件不冻结具体码，避免两处分叉）
public struct TriageReasonItem: Codable, Equatable, Sendable {
    public var code: String
    public var value: Double?
}
public struct CullingTriage: Codable, Equatable, Sendable {
    public var verdict: TriageVerdict
    public var confidence: Double
    public var score: Double
    public var reasons: [TriageReasonItem]   // ≤3，与 reasons_json 同形
    public var policyVersion: String
}
public struct TriageSummary: Codable, Equatable, Sendable {
    public var keep: Int; public var reject: Int; public var review: Int
    public var stale: Bool; public var fingerprint: String
    public var policyVersion: String; public var generatedAt: String?
}
public struct TriageGenerateInput: Decodable, Sendable, Equatable {
    public let sessionId: String; public let policyVersion: String?; public let force: Bool
}
public struct TriageApplyInput: Decodable, Sendable, Equatable {
    public let sessionId: String; public let verdicts: [TriageVerdict] // keep/reject only
    public let minConfidence: Double?; public let fingerprint: String     // 64 hex
}
public struct TriageApplyResult: Codable, Equatable, Sendable {
    public let appliedAssets: Int; public let appliedPhotos: Int
    public let skippedManual: Int; public let skippedLowConfidence: Int
    public let skippedMissing: Int; public let historyOperationId: Int?
}
public struct MetadataPreviewInput: Decodable, Sendable, Equatable {
    public let updates: [MetadataBatchUpdate]   // 与 MetadataBatchSetInput 同形，≤10k
}
```

### 6.1 MaintenanceAPI 草案（B0 定稿；字段只增不删）

```swift
public protocol MaintenanceAPI: Sendable {
    func backup(_ input: MaintenanceBackupInput) async throws -> MaintenanceBackupResult
    func listBackups() async throws -> [MaintenanceBackupInfo]
    func restore(_ input: Confirmed<MaintenanceRestoreInput>) async throws -> MaintenanceRestoreResult
    func exportDiagnostics(_ input: MaintenanceDiagnosticsInput) async throws -> MaintenanceDiagnosticsResult
}
public struct MaintenanceBackupInput: Decodable, Sendable, Equatable {
    public let destination: String?   // nil = settings.backup_dir / 默认 Backups
}
public struct MaintenanceBackupResult: Codable, Equatable, Sendable {
    public let path: String; public let byteCount: Int64
    public let schemaVersion: Int; public let createdAt: String
}
public struct MaintenanceBackupInfo: Codable, Equatable, Sendable {
    public let path: String; public let byteCount: Int64
    public let schemaVersion: Int; public let createdAt: String; public let verified: Bool
}
public struct MaintenanceRestoreInput: Decodable, Sendable, Equatable { public let backupPath: String }
public struct MaintenanceRestoreResult: Codable, Equatable, Sendable {
    public let restoredFrom: String; public let schemaVersion: Int
    public let requiresRelaunch: Bool
}
public struct MaintenanceDiagnosticsInput: Decodable, Sendable, Equatable { public let includePaths: Bool }
public struct MaintenanceDiagnosticsResult: Codable, Equatable, Sendable {
    public let path: String; public let byteCount: Int64
}
```

实现细节：`TriageGenerateInput` 需自定义 `init(from:)`，缺 `force` 时取 `false`、缺 `policyVersion` 时取 settings；`CullingPage.init(from:)` 对 `nextCursor/triage` 用 `decodeIfPresent`，编码对二者用 `encodeIfPresent`（`nextRowId` 仍 nil→null）。

输入校验（API 边界，统一 `GatherError`）：
- `TriageGenerateInput.force` 缺省 `false`（缺键按 false 解码）；`policyVersion` 非空 ≤32，缺省取 settings `triage_policy`。
- `TriageApplyInput.verdicts` 1...2 项且不得含 `.review`；`minConfidence` 0...1；`fingerprint` 64 位小写 hex。
- `MetadataPreviewInput.updates` 1...10,000 项、逐项 `photoId` 非空（与 `MetadataBatchSetInput` 同规则）。
- `CullingPageCursor.dateKey` 允许 `""`（未知日期）；`numberKey` 必须落在 `rating 0...5` / `triage 0...1`。

新增错误码：`CULLING_CURSOR_INVALID`（游标非法/与排序不一致/与 scope 不兼容，X0 §4 已列）、`CULLING_FILTER_INVALID`（triage 过滤用于非 filtered，待 X0 §1.2 评审）、`TRIAGE_NOT_READY`、`TRIAGE_STALE`、`TRIAGE_POLICY_INVALID`（X0 §4 已列）、`TRIAGE_APPLY_INVALID`（verdict 含 review / minConfidence 越界，待 X0 §1.2 评审）。

**基线**：预计 public 类型 +19、声明 +40；`docs/protocol-surface-baseline.json` 用 `--write-baseline` 重写并在台账记账；`zero_reference_types` 必须保持 0，`router_envelope_types` 保持 0。README「16 协议/110 方法」→「17/121」（Culling +2、Metadata +3、Face +2、Maintenance +4）。

## 7. 性能预算与 EXPLAIN 预期

| 路径 | 20k p95 | 50k p95 | 预期计划 | 索引 |
|---|---:|---:|---|---|
| filtered import 页 | 120ms | 250ms | `SEARCH p USING INDEX idx_photos_asset_group` + 代表行子查询 | 既有 |
| filtered capture 页 | 180ms | 400ms | 同上 + `USE TEMP B-TREE FOR ORDER BY`（strftime 表达式） | 既有 |
| filtered rating 页 | 150ms | 300ms | 同上 + 临时 B-tree | 既有 |
| filtered triage 页 | 150ms | 300ms | `SEARCH t USING INDEX sqlite_autoindex_triage_suggestions_1` + 临时 B-tree | 新增 |
| all 排序页 | 220ms | 500ms | `SEARCH p USING INDEX idx_photos_asset_group` + 相关子查询 + 临时 B-tree | 既有 |
| countFiltered | 80ms | 160ms | 分组计数 + 临时 B-tree | 既有 |
| triage generate 20k | 1500ms | — | `json_extract` 投影 + 20k upsert | 新增 2 索引 |
| triage summary | 10ms | 20ms | `COVERING INDEX idx_triage_session_verdict` | 新增 |
| apply 20k | 800ms | — | 读 20k + 单条 history | 既有 |

- EXPLAIN 断言：不出现 `SCAN p` / `SCAN triage_suggestions`；`USE TEMP B-TREE FOR ORDER BY` 属预期。测试前 `ANALYZE` 一次；生产按实际基准。
- 拍摄时间排序无法走索引（`strftime` 表达式）；20k/50k 预算内。若 50k >500ms，V4 加归一列/表，不在 P0 偷改。

索引是否足够：

| 索引 | 用途 | 结论 |
|---|---|---|
| `idx_photos_asset_group(session_id, COALESCE(...))` | 组查询/代表行 | 足够 |
| `idx_metadata_cache_session_date/rating` | 过滤 | 足够；排序仍临时 B-tree |
| `idx_triage_session_verdict` | verdict 过滤/计数 | 新增，必须 |
| `idx_triage_session_confidence` | 低置信度排序/复核队列 | 新增，必须 |

## 8. 测试计划

| 层 | 用例 | 验收 |
|---|---|---|
| 迁移 | 新库 V3；V2→V3；V1→V3；370 列旧 V1→V3；备份文件 V2 且可读；注入 DDL 失败；未知 V2 形态 | 45/388/72/65；`user_version=3`；失败后仍 V2 且备份在 |
| 分页/排序 | §4.7 矩阵；20 页 × 5 sort × 3 scope；页大小 1/17/200/1000 | 与 Swift 期望序完全一致；无重漏；变体齐全；允许一次尾部空页 |
| 游标 | typed cursor 编解码往返；sort/dateKey/numberKey/rowId 非法；跨 sort；scope 不兼容；dateKey="" 合法 | `CULLING_CURSOR_INVALID`，不变更数据 |
| Triage | 纯净规则夹具；无质量/部分质量；人工跳过；stale apply；幂等 generate；计数 | fingerprint 稳定；apply 不覆盖 manual；单条 history |
| 并发 | 并行 generate；generate vs apply；apply vs 手工 update；分页期间插入 | 无部分应用、无重复页、冲突显式报错 |
| 契约 | 旧 JSON（仅 afterRowId）解码；新字段编码；`Confirmed`；错误码 | 旧载荷零改动通过 |
| 性能 | 20k/50k 分页、triage 生成/查询、apply；EXPLAIN | 达 §7 预算 |

## 9. 任务拆解（17 PD）

| ID | 任务 | 文件 | PD | 验收 |
|---|---|---|---:|---|
| G0-2a | `CullingSort`/typed `CullingPageCursor` 类型与校验 | `Protocol/Culling.swift`、`API/Inputs/CullingInputs.swift` | 1.5 | 编解码/非法用例 |
| G0-2b | Query/Page 字段、互斥、deprecated 兼容 | 同上 | 1.0 | 旧 JSON 兼容 |
| G0-3a | `CullingPageSlice` 与仓储协议 | `Persistence/Ports/CullingRepository.swift` | 0.5 | 编译/三 scope |
| G0-3b | filtered capture/rating/triage keyset SQL | `Queries/CullingAssetPageQuery.swift` | 2.5 | 20 页矩阵 |
| G0-3c | all 排序 SQL（preferred CTE） | 同上 | 1.5 | 20 页矩阵 |
| G0-3d | 游标/NULL/并列/scope 错误 | 同上 | 1.0 | 篡改/跨 sort |
| G0-4 | CullingService 接入 + triage 读端口 | `CullingService+Paging.swift`、`CullingService.swift` | 1.5 | 三 scope + 汇总 |
| T0-2a | SchemaV3 + Migration + Catalog | `SchemaV3.swift`、`MigrationV2ToV3.swift`、`SchemaCatalog.swift` | 2.0 | V1→V3 |
| T0-2b | 计数/指纹/版本镜像/门禁 | `SchemaV3.swift`、`Schema.swift` | 1.0 | shape 测试 |
| T0-4a | Triage 类型与 API 输入输出 | `Protocol/Triage.swift`、`API/Inputs/TriageInputs.swift` | 1.5 | 契约测试 |
| T0-4b | CullingAPI 两方法 + 错误码 + apply 源 | `CullingAPI.swift`、`Core.swift`、`CullingService+Commands.swift` | 1.0 | 契约/apply |
| 共用 | 夹具、EXPLAIN、20k/50k 脚本 | `Tests` | 2.0 | 预算记录 |
| | **合计** | | **17.0** | |

## 10. 未决问题与推荐

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| 1 | 未知日期在排序中的位置 | A. `''`：ASC 最前/DESC 最后；B. 用 `created_at` 兜底参与排序；C. UI 过滤未知日期 | **A**（与 X0 COALESCE 空串一致）；要按导入时间参与排序时用 B，需改 SQL 与 cursor 取值 |
| 2 | `dateKey` 文本归一 | A. `strftime` 归一（EXIF/ISO 统一）；B. 原样 `date_taken`；C. V4 归一列 | **A**；50k 超预算再 C，P0 不改表 |
| 3 | triage 失效 | A. 读时 fingerprint；B. 写时删行 | **A**；B 作为优化后续加，避免 4 处钩子漏删 |
| 4 | apply 默认范围 | A. 按 verdict 安全线（keep≥0.60/reject≥0.75）；B. 全部非 review；C. 固定 0.75 | **A**（X0 §1.3）；UI 提高 `minConfidence` 不得低于安全线 |
| 5 | `face_cluster_constraints` 是否加 UNIQUE | A. 不加，服务层幂等；B. `UNIQUE(session_id,kind,member_keys_json)` | **A**；保持 72 索引；若 F0 要 B，V3 计数/指纹重算 |
| 6 | Triage 粒度 | A. 逻辑资产首选行；B. 每照片 | **A**；与 rating/label/代表行口径一致，apply 展开变体 |
| 7 | fingerprint 缓存 | A. 2s 会话缓存；B. 每页重算 | **A**；缓存只存 derived，失效靠输入变化 |
| 8 | `.all` 下 triageConfidenceAsc | A. 允许，未生成=0；B. 仅 `.filtered` | **B 作为 UI 约束**，API 按 X0 允许 A；若评审要强约束，改为 B 并报 `CULLING_CURSOR_INVALID` |

## 11. 与 x0-contracts 的对齐 / 剩余差异

| X0 条款 | 本文 | 处理 |
|---|---|---|
| §1.1 typed cursor：sort/dateKey/numberKey/rowId | 已对齐，严格四字段，不额外加 version | 无差异 |
| §1.1 `CullingPage.nextCursor`、`nextRowId` 兼容 | 已对齐；`nextRowId` 契约级 deprecated | 无差异 |
| §1.1 `CullingSort` 命名 `captureDesc/captureAsc/ratingDesc/triageConfidenceAsc` | 已对齐（此前名不同） | 无差异 |
| §1.1 `sort: CullingSort?`（nil=import） | 已对齐；cursor 与 effectiveSort 比较 | 无差异 |
| §1.1 “对应 sort 的 key 非空” | 按字段存在解释：`dateKey` 可为 `""`（未知日期），`numberKey` 必须在值域 | 建议 X0 注明，避免被误读为字符串非空 |
| §1.1 `CULLING_CURSOR_INVALID` 覆盖非法/不一致/scope | 已对齐；另增 `CULLING_FILTER_INVALID`（triage 过滤用于非 filtered） | X0 §4 待评审后补 |
| §1.1 排序键 COALESCE 空串/0/0 | 已对齐；capture 先 `strftime` 归一为固定宽度文本 | 无差异 |
| §1.1 非 import 排序仅 `.all`/`.filtered` | 已对齐；`.similarityGroup` 非 import 报错 | 无差异 |
| §1.1 筛选变化 UI 重置分页、游标不含筛选指纹 | 已对齐；triage fingerprint 走查询参数，不进 cursor | 无差异 |
| §1.3 人工已决策不生成建议行 | 已对齐：generate 跳过、apply 计 skippedManual | 无差异 |
| §1.3 `reasons_json=[{"code","value"}]` ≤3 | 已对齐：`TriageReasonItem` | 无差异 |
| §1.3 指纹含 navigation | 已对齐：material 增 navigation | 无差异 |
| §1.3 minConfidence 不低于 verdict 下限 | 已对齐：effectiveMin=max(input, 下限) | 无差异 |
| §3 `triage_reject_confidence_min` / `triage_min_executable_confidence` | 已对齐（fingerprint 使用两键） | 无差异 |
| §1 110→约 118 方法 | 已按定稿修正为 121（Culling+2 / Metadata+3 / Face+2 / Maintenance+4） | X0 已冻结 121 |
| §1 `TriageGenerateInput`/`TriageApplyInput` 未定 | 本文给出精确字段 | X0 补签名 |
| §2 `face_cluster_constraints` 无 UNIQUE | 本文保持无 UNIQUE | 一致 |
| §1 `TriageSummary` 未定字段 | 本文给出 stale/fingerprint/policyVersion | X0 补字段 |
| §4 错误码表 | 本文另增 `TRIAGE_APPLY_INVALID`（verdict 含 review / minConfidence 越界） | X0 §1.2 待评审后补 |
