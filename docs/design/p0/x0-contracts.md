# X0 契约冻结 v1（2026-10-24 设计评审通过）

> 跨工作流唯一契约。设计细节见同目录 `g0-grid-cull.md`、`t0-triage-policy.md`、
> `t0-g0-data-contracts.md`、`k0-keywords.md`、`f0-face-split.md`、`b0-backup-diagnostics.md`。
> 实现以本文件 + 设计文档为准；任何变更必须升 v2 并同步 `protocol-surface-baseline.json`。

## 0. 冻结决议

| ID | 决议 |
|---|---|
| R1 | Schema **V3 纯增量**：`triage_suggestions`（10 列）+ `face_cluster_constraints`（**6 列，含 peer_keys_json**）。44 表 / 383 列 / 72 索引 / 65 外键；`user_version 2→3`。 |
| R2 | 协议面 **16 协议 / 112 方法**：Culling +2、Metadata +3、Face +2、Maintenance +4（110 + 11）。 |
| R3 | T0：三分类，仅 keep/reject 可应用；keep ≥0.60、reject ≥0.75；`triage_min_executable_confidence` 默认 0.55；review 的 confidence 保留 `max(cKeep,cReject)`；组源优先级 **exact > similarity > visual > navigation**；人工已决策不生成行。 |
| R4 | K0：`keywords_mode=delta`（`(disk ∪ added) − removed`），只读 preview 不建 pending；生成词删除报 `KEYWORD_OWNED_BY_SOURCE`；手动词不写 origins。 |
| R5 | F0：v1 仅未绑定簇可拆；约束 set-vs-set（member/peer）在重聚类后保持；绑定簇拒绝；`face.review` 分页复核 + cohesion。 |
| R6 | B0：备份走独立连接 `VACUUM INTO`；恢复**跨进程**（journal + 下次启动 swap）；诊断包默认不含绝对路径；MaintenanceAPI 独立第 16 协议。 |
| R7 | G0：Grid 是挑片页第 4 种布局；typed cursor + `nextCursor`；非 import 排序仅 `.all`/`.filtered`。 |

## 1. API Delta

| 协议 | 变更 | 签名 |
|---|---|---|
| CullingAPI | 变更 | `page(_ query: CullingPageQuery)`：+ `sort`、typed `cursor`；`CullingPage` + `nextCursor` |
| CullingAPI | 新增 | `generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary` |
| CullingAPI | 新增 | `applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult` |
| CullingAPI | 载荷 | `CullingSummary.triage: TriageSummary?`、`CullingAsset.triage: TriageSuggestion?`、`CullingFilters.triageVerdicts: [TriageVerdict]?` |
| MetadataAPI | 新增 | `preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview` |
| MetadataAPI | 新增 | `applyKeywords(_ input: Confirmed<MetadataKeywordApplyInput>) async throws -> MetadataKeywordApplyResult` |
| MetadataAPI | 新增 | `retryKeywordWriteback(_ input: Confirmed<SessionReference>) async throws -> MetadataKeywordApplyResult` |
| FaceAPI | 新增 | `split(_ input: Confirmed<FaceSplitInput>) async throws -> FaceSplitResult` |
| FaceAPI | 新增 | `review(_ input: FaceReviewInput) async throws -> FaceReviewPage` |
| MaintenanceAPI | **新协议** | `backup` / `listBackups` / `restore` / `exportDiagnostics`（4 方法） |

**方法计数**：110 + 2（Culling）+ 3（Metadata）+ 2（Face）+ 4（Maintenance）= **121**。
**协议计数**：16 + 1（Maintenance）= **17**。

### 1.1 G0 游标（冻结）

```swift
public enum CullingSort: String, Codable, CaseIterable, Sendable {
    case importOrder = "import"
    case captureDesc = "capture_desc"
    case captureAsc = "capture_asc"
    case ratingDesc = "rating_desc"
    case triageConfidenceAsc = "triage_confidence_asc"
}

public struct CullingPageCursor: Codable, Equatable, Sendable {
    public var sort: CullingSort
    public var dateKey: String?   // capture：归一后的 date_taken；空串参与排序
    public var numberKey: Double? // rating / triage confidence
    public var rowId: Int64       // 资产组 first_rowid，决胜
}
```

- `CullingPageQuery`：`sort` + `cursor`；`afterRowId` 保留 deprecated（仅 import 序）；
  两者同时非空 → `CULLING_CURSOR_INVALID`。
- 校验：`cursor.sort == query.sort`、对应 key 非空、`rowId >= 1`。
- 排序键：`COALESCE(strftime(...), '')` / `COALESCE(rating,0)` / `COALESCE(confidence,2.0)`（无建议排最后）；并列 `first_rowid`。
- `sort != importOrder` 仅 `.all`/`.filtered`；`.similarityGroup` 非 import → `CULLING_CURSOR_INVALID`。
- `triageVerdicts` 仅 `.filtered` 生效；用于其他 scope → `CULLING_FILTER_INVALID`。
- 筛选变化 UI 重置分页；v1 不把筛选指纹放进游标。
- 分页大小按布局：网格 200/页，查看器/胶片条沿用 500；UI 只读 `nextCursor`，`nextRowId` 仅兼容期读取。
- sort rawValue 固定：`import` / `capture_desc` / `capture_asc` / `rating_desc` / `triage_confidence_asc`。

### 1.2 T0 类型（冻结）

```swift
public enum TriageVerdict: String, Codable, CaseIterable, Sendable { case keep, reject, review }

public enum TriageReasonCode: String, Codable, CaseIterable, Sendable {
    case groupBest = "group_best"
    case weakerThanGroupBest = "weaker_than_group_best"
    case motionBlur = "motion_blur"
    case exposureLow = "exposure_low"
    case closedEyeSuspect = "closed_eye_suspect"
    case closeCall = "close_call"
    case tieWithGroup = "tie_with_group"
    case singleShot = "single_shot"
    case noAlternative = "no_alternative"
    case lowTechnical = "low_technical"
    case qualityMissing = "quality_missing"
    case analysisFailed = "analysis_failed"
    case duplicateExact = "duplicate_exact"
    case duplicateVisual = "duplicate_visual"
    case multiFaceLowConfidence = "multi_face_low_confidence"
    case smallFace = "small_face"
    case manualOverride = "manual_override"
}

public struct TriageReason: Codable, Equatable, Sendable { public var code: TriageReasonCode; public var value: Double? }
public struct TriageSuggestion: Codable, Equatable, Sendable {
    public var photoId: String; public var verdict: TriageVerdict
    public var score: Double; public var confidence: Double
    public var reasons: [TriageReason]; public var groupId: String?
    public var policyVersion: String; public var inputFingerprint: String; public var computedAt: String
}
public struct TriageCounts: Codable, Equatable, Sendable { public var keep, reject, review, total: Int; public var coverage: Double }
public struct TriageSummary: Codable, Equatable, Sendable {
    public var counts: TriageCounts; public var stale: Bool
    public var policyVersion: String; public var inputFingerprint: String; public var generatedAt: String
}
public struct TriageGenerateInput: Decodable, Sendable, Equatable { public var sessionId: String; public var force: Bool }
public struct TriageApplyInput: Decodable, Sendable, Equatable {
    public var sessionId: String; public var verdicts: [TriageVerdict]   // 仅 keep/reject
    public var minConfidence: Double?; public var fingerprint: String    // 64 hex
    public var photoIds: [String]?                                       // nil = 全部
}
public struct TriageApplyResult: Codable, Equatable, Sendable {
    public var appliedAssets: Int; public var appliedPhotos: Int
    public var appliedKeep: Int; public var appliedReject: Int   // v1.1：按方向回显（只增字段）
    public var skippedManual: Int; public var skippedLowConfidence: Int
    public var skippedMissing: Int; public var skippedConflict: Int   // v1.1：并发 revision 变化
    public var historyOperationId: Int?
}
```

语义：`nil` 建议 = 未生成/已过期/已人工决策/无行；`confidence == 0` = 已生成但未分析。

> v1.1：`applyTriage` 除校验调用方指纹外，还必须校验**建议行自身**的 `input_fingerprint`
> 与 `policy_version`，任一行不一致整批返回 `TRIAGE_STALE`（不部分应用）。生成、应用、
> 摘要共用 `TriagePolicy.executionFloor(for:)`：低于 `max(方向下限, min_executable)` 的
> 置信度一律只能是 review。
review 的 confidence 可 >0.55，UI 不显示裸值。apply 前校验指纹，stale → `TRIAGE_STALE`。

### 1.3 K0 类型（冻结）

```swift
public struct MetadataPreviewInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]        // 1...500，去重
    public let addedKeywords: [String]   // 0...100
    public let removedKeywords: [String]
}
public struct MetadataKeywordApplyInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]; public let addedKeywords: [String]; public let removedKeywords: [String]
}
public struct MetadataKeywordApplyResult: Codable, Equatable, Sendable {
    public let result: WritebackResult; public let status: MetadataSyncSummary
}
```

- preview 只读，**不建 pending**；apply 每个 sidecar 一次 `keywords_mode=delta`；
  内部键 `keywords_added` / `keywords_remove` 落 `delivery_items.attributes_json`。
- 删除生成词 → `KEYWORD_OWNED_BY_SOURCE`（params: keyword/source）。
- 选择集可跨页累积到 500（CullingViewModel 单页 limit=500 + loadedPhotoIds）；预览不建 pending。
- 自动补全扩展 `PhotoAPI.suggestions`：`field="keyword"` + `field="camera_make"`，会话作用域。

### 1.4 F0 类型（冻结）

```swift
public struct FaceSplitInput: Decodable, Sendable, Equatable {
    public let sessionId: String; public let clusterId: Int; public let memberIds: [Int]
}
public struct FaceSplitResult: Codable, Equatable, Sendable {
    public let newClusterId: Int; public let movedCount: Int
    public let remainingCount: Int; public let label: String
}
public struct FaceReviewInput: Decodable, Sendable, Equatable {
    public let sessionId: String; public let clusterId: Int?
    public let cursor: String?; public let limit: Int; public let includeResolved: Bool
}
public enum FaceReviewFlag: String, Codable, CaseIterable, Sendable {
    case suspect, lowQuality = "low_quality", smallFace = "small_face"
    case unresolvedObservation = "unresolved_observation", incompatibleModel = "incompatible_model"
}
```

- `member_keys_json` / `peer_keys_json` 元素：`{"observationId":123,"photoId":"ph_...","bbox":[x,y,w,h]}`。
- 拆分仅未绑定簇；绑定 → `FACE_CLUSTER_BOUND`；空/全选/跨簇/重复 id → `FACE_SPLIT_EMPTY` /
  `FACE_SPLIT_KEEP_ONE` / `FACE_SPLIT_INVALID_MEMBER`；缺 observation → `FACE_SPLIT_MEMBER_UNRESOLVED`。
- `face.review` 游标非法 → `FACE_REVIEW_CURSOR_INVALID`。
- 约束键缺失时**剪除失效键**，语义为空才删约束（不整条跳过）；`together` 仅在未绑定簇 merge 时写入。

### 1.5 B0 类型（冻结）

```swift
public protocol MaintenanceAPI: Sendable {
    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord
    func listBackups() async throws -> MaintenanceInventory
    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt
    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult
}
```

- 恢复跨进程：`restore` 校验并写 journal，确认后退出；下次启动在 `Database.open` 前 swap；失败回滚旧库。
- 恢复成功后禁用一次 delivery 自动回放，避免旧 intent 覆盖较新 XMP；P0 保持 4 方法（不加取消/进度）。
- 备份 `VACUUM INTO` 到 `.partial`，只读校验后原子改名 + JSON sidecar；不新增表。
- 诊断包 20MB 上限，默认不含绝对路径，不含 DB/照片/XMP。

## 2. Schema V3（冻结）

```sql
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
CREATE INDEX idx_triage_session_verdict ON triage_suggestions(session_id, verdict, confidence);
CREATE INDEX idx_triage_session_confidence ON triage_suggestions(session_id, confidence);

CREATE TABLE face_cluster_constraints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('separate','together')),
  member_keys_json TEXT NOT NULL DEFAULT '[]',
  peer_keys_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_face_cluster_constraints_session ON face_cluster_constraints(session_id, kind);
```

- 计数：**44 表 / 383 列 / 72 索引 / 65 外键**；`user_version=3`。
- `SchemaV3.ddl = SchemaV2.ddl + "\n" + delta`；用 `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`，
  fresh/migrated 字节一致；指纹由真实 V3 空库回填。
- 当前：`SchemaCurrent` 是唯一 DDL（45→44 表，清理 Template 后 44/383/72/65）；
  V1/V2 迁移链已删除，旧库默认 fail-closed；`SchemaSQL.currentSchemaVersion = 3`。

## 3. 设置键（冻结）

| key | 默认 | 用途 |
|---|---|---|
| `triage_enabled` | `0` | Beta 开关 |
| `triage_auto_generate` | `0` | 分析完成后自动生成建议 |
| `triage_policy` | `triage-v1` | 规则版本 |
| `triage_keep_confidence_min` | `0.60` | 建议保留最低置信度 |
| `triage_reject_confidence_min` | `0.75` | 建议淘汰最低置信度 |
| `triage_min_executable_confidence` | `0.55` | 低于此值绝不执行（review 可高于） |
| `grid_default_sort` | `import` | import/capture_desc/capture_asc/rating_desc |
| `grid_density` | `m` | s/m/l |
| `backup_dir` | `` | 空 = `Application Support/Gather/Backups` |
| `backup_retention` | `5` | 保留份数 |
| `backup_auto` | `off` | off/daily/launch |
| `diagnostics_include_paths` | `0` | 诊断包是否含路径 |
| `face_review_cohesion_floor` | `0.35` | 复核可疑阈值 |
| `face_review_relative_mad` | `2.5` | 相对阈值 k |
| `face_review_min_quality` | `0.35` | 参与质心的最低质量 |
| `face_review_face_size_min` | `48` | 小脸标记像素 |

## 4. 错误码（冻结；进 GatherErrorCode + L10n + en）

`CULLING_CURSOR_INVALID`、`CULLING_FILTER_INVALID`；
`TRIAGE_STALE`、`TRIAGE_NOT_READY`、`TRIAGE_POLICY_INVALID`、`TRIAGE_APPLY_INVALID`；
`FACE_CLUSTER_BOUND`、`FACE_SPLIT_EMPTY`、`FACE_SPLIT_INVALID_MEMBER`、
`FACE_SPLIT_KEEP_ONE`、`FACE_SPLIT_MEMBER_UNRESOLVED`、`FACE_REVIEW_CURSOR_INVALID`；
`KEYWORD_OWNED_BY_SOURCE`；
`BACKUP_FAILED`、`BACKUP_VERIFY_FAILED`、`BACKUP_INSUFFICIENT_SPACE`、
`BACKUP_PERMISSION_DENIED`、`BACKUP_BUSY`；
`RESTORE_FAILED`、`RESTORE_VERIFY_FAILED`、`RESTORE_VERSION_UNSUPPORTED`、
`RESTORE_INSUFFICIENT_SPACE`、`RESTORE_PERMISSION_DENIED`、`RESTORE_BUSY`；
`DIAGNOSTICS_EXPORT_FAILED`。

## 5. 门禁与文档

- `scripts/check-protocol-surface.sh --strict` + baseline 重写 + 台账；
- `SettingsCatalogTests`（UI 键 ⊆ defaults）、L10n 覆盖、V2→V3 迁移测试、20k 基准；
- README “16 协议/110 方法” → **16/112**；ADR-031（V3）、ADR-032（Triage）、ADR-033（备份恢复）；
- 本文件变更必须升 v2 并同步 P0 计划。

## 6. 实施顺序（硬依赖）

```
X0: Schema V3 + 迁移 + 契约类型（当前）
  ├─ G0: 排序/游标/网格
  ├─ T0: 计算/API/建议卡/复核
  ├─ K0: preview/delta/关键词面板
  ├─ F0: 约束/拆分/复核
  └─ B0: 备份/恢复/诊断
```

## 7. 非阻塞未决

1. `CullingPage.triage` 是否需要页级摘要（当前只在 `CullingSummary`）。
2. triage 的 `photoIds` 子集应用是否在 P0 UI 暴露（API 已支持）。
3. 备份错误码 12 个是否合并为操作级（当前保留细分）。

## 8. v1.1 修订（2026-10-26，第三轮 review 实现对齐）

本节记录与 v1 冻结文本的差异，均已在代码/测试落地；下一次契约变更按 §5 升 v2。

| 项 | v1 | v1.1（实现） | 原因 |
|---|---|---|---|
| T0 指纹输入 | 未含 photos / faces，明确不含 culling_decisions | 仍**不含 culling_decisions**；额外纳入 photos 计数/max(rowid)/资产数与 faces 计数/max(id) | 照片增删、重推理必须失效，否则旧建议会被当作新鲜 |
| T0 指纹触发 | generate 只比指纹 | generate 先删除“人工已决策资产”的建议行，再判指纹 | “人工决策不建行”必须落地，不能只靠读时过滤 |
| T0 摘要 stale | 空行 = stale | 空行且存在可生成候选才算 stale | 全人工/无质量会话不再永久“已过期” |
| T0 应用 | 校验调用方指纹 | 同时校验建议行指纹 + 策略版本，整批拒绝 | 防旧质量/旧组结果被应用 |
| T0 门限 | keep/reject/minExec 各自比较 | 统一 `executionFloor(for:) = max(方向下限, minExecutable)` | 设置项必须有真实安全效果 |
| T0 组内最佳 | 按 qualityScore | 只在技术合格成员中选 best；全组无合格者一律 review | 防高总分但糊/欠曝的照片占 best、把合格照片判 reject |
| T0 exact 最佳 | 未定义 | 分辨率 → 文件大小 → 导入序 → photoId（候选携带 width/height/file_size） | 完全重复保留信息量最大的一份 |
| T0 apply 并发 | 无 | 事务内按变体 revision 复核，变化则整条资产跳过并计 `skippedConflict` | 不覆盖人工/另一端刚写的决策 |
| F0 复核分页 | 每页 O(n) 扫描 | 缓存 memberId→位置索引，翻页 O(limit) | 10k 复核页不再每页整表扫描 |
| B0 pre-restore | 保留 2 份 | 按“套”（db + -wal + -shm）保留最近 2 套 | 按文件数淘汰会先删主库，只留孤儿 sidecar |
| B0 恢复异常 | 回滚后继续 | 新库/旧库副本双缺失时 `.unrecoverable` → 启动 fail-closed | 空库重建会掩盖数据丢失 |
| B0 备份 prune | 无保护 | 待执行恢复引用的备份文件名永不淘汰 | 防恢复因备份被清而失败 |
| K0 delta | 未规定既有词处理 | 盘上既有词原样保留（fold 只用于比较） | 加一个词不得改写/删除未触碰的词 |
| G0 设置键 | `grid_default_sort` / `grid_density` | 两键进 defaults + 设置页；VM 首次读取，SceneStorage 覆盖 | 冻结键必须可用 |

ratchet 台账：新增 3 个显式 `init(from:)` 校验与 T0 候选/结果的公开字段，`public_declarations` 1545→**1551**、Protocol 行 7520→**7574**，已多次 `--write-baseline` 重写（类型 293 / 零引用 0 不变）；本轮新增 `CullingApplyHistoryInput.source` 与受守卫的 `moveClusterMembers` 重载。

错误码口径：全仓 **184**，P0 新增 **25**（2 Culling / 4 Triage / 1 Keyword / 6 Face / 12 Maintenance）。
