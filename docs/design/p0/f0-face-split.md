# F0 人脸拆分与复核（设计基线）

> 范围：D5「拆分 v1 仅未绑定簇；必须经 face_cluster_constraints 在重聚类后保持」的完整落地设计。
> 依赖：`docs/design/p0/README.md` D1–D10、`docs/design/p0/x0-contracts.md`（草案）。
> 代码基线：`FaceRepo+Members.swift` / `FaceRepo+Clusters.swift` / `FaceKwService+Clusters.swift` / `FaceKwService+Review.swift` / `FaceKwService+Analyze.swift`（recluster）/ `SchemaV1+DDL*.swift` / `FaceAPI.swift` / `FaceKeywording*`。

## 0. 结论先行

1. **拆分 v1 只允许未绑定簇**（判定真相是 `role_bindings` 是否存在，不是 `status` 或 `matched_person_id`）。已绑定簇直接拒绝（`FACE_CLUSTER_BOUND`），不自动解绑：解绑会撤销已写入的人脸关键词，必须由用户显式执行。
2. 拆出的新簇是一个正常未绑定簇，**立即可命名/绑定**；拆分无撤销入口，但「把两簇合并」会删除对应的 separate 约束并写入 together 约束，等价于可逆。
3. 约束用 **set-vs-set** 表达：`member_keys_json`（移动侧）+ `peer_keys_json`（原簇剩余侧）。这是 x0 单列草案无法表达的，必须加列（见 §10 冲突 1）。
4. 约束在**全量聚类提交事务内**、绑定迁移之后、写签名之前应用；增量路径只追加成员、不会重新合并已拆开的簇，因此不需要应用。
5. 复核队列需要**分页成员 + cohesion**，现有 `FaceClusterData.members` 只返回 12 条（`FaceKwService.swift:75`），无法支撑；新增 `face.review`（见 §10 冲突 2）。

## 1. 目标 / 非目标

- 目标：误聚的未绑定簇可在 3 次操作内拆开；拆分在 `recluster` 后保持；复核队列按「到簇质心的 cosine」排序，优先暴露可疑成员；绑定/合并/移除行为不回归。
- 非目标：已绑定簇拆分、拆分撤销、按成员指派人、自动重聚类、修改聚类算法阈值、跨会话簇合并。

## 2. 场景与主流程

**主流程（成功）**：审核步骤选中未绑定簇 → 打开「仅看待复核成员」→ 勾选 1..n-1 个成员 → 「拆分所选…」→ 确认（移动数/保留数/不可撤销）→ 事务提交 → 自动选中新簇并把焦点放到角色名 → 用户立即绑定或继续拆分。

**失败路径**：
- 簇已绑定：按钮禁用并提示先解绑；绕过 UI 调 API → `FACE_CLUSTER_BOUND`。
- 分析/重聚类进行中：`FKW_ANALYSIS_RUNNING`（与 `claimController` 同口径，见 `FaceKwService.swift:115-120`）。
- 选择为空/全选/含非本簇成员/重复 id → `FACE_SPLIT_EMPTY` / `FACE_SPLIT_KEEP_ONE` / `FACE_SPLIT_INVALID_MEMBER`。
- 成员缺 `observation_id`（旧库/未完成分析）→ `FACE_SPLIT_MEMBER_UNRESOLVED`，提示「重新分析后再拆」。
- 并发删除簇/成员：`FKW_CLUSTER_NOT_FOUND` / `FKW_CLUSTER_MEMBER_NOT_FOUND`，UI 重新加载。

新增错误文案（中文源 key，en 同 PR）：`FACE_CLUSTER_BOUND`「该簇已绑定角色，不能拆分；请先解除绑定（会撤销已写入该角色的人脸关键词）。」、`FACE_SPLIT_KEEP_ONE`「至少保留 1 个成员在原簇。」、`FACE_SPLIT_MEMBER_UNRESOLVED`「该簇包含旧版人脸样本，请重新分析后再拆分。」、`FACE_REVIEW_CURSOR_INVALID`「复核列表游标已失效，请刷新。」

## 3. 状态机与边界

| 状态 | 进入条件 | 允许拆分 | 退出 |
|---|---|---|---|
| unbound | 无 role_bindings | 是 | 拆分/绑定/合并/重聚类 |
| bound | 有 role_bindings（status 仅镜像） | 否 | 解绑后回到 unbound |
| analysisRunning | controller 非空 | 否 | job 终态 |
| splitting | 事务进行中 | 否（UI 禁按钮） | 成功/回滚 |
| splitDone | 新簇存在、约束已写 | 新簇可继续拆 | 绑定/合并/重聚类 |
| constraintConflict | together 与 separate 冲突 | 不适用 | separate 优先，日志记录 |

- 重入：同一请求重放时成员已不在原簇 → `FACE_SPLIT_INVALID_MEMBER`；UI 以 reload 为准。
- 拆分不改 `sessions.index_seq`，不触发索引失效；只更新簇 `updated_at`。
- 分析进行中禁止拆分，避免 C 阶段 `deleteClustersBySession`（`FaceKwService+Clusters.swift:382`）与用户写并发。

## 4. 交互/视觉规格

| 区域 | 规格 |
|---|---|
| 簇卡片 | 右上角 `GatherBadge("N 待复核", tone: .warning)`；N=0 不显示；不改卡片点击行为 |
| 详情头 | `label` + 样本数 + `仅看待复核成员` Toggle（默认开）+ `拆分所选（N）` 按钮；新簇 label=`Person N`，命名/绑定走既有绑定面板（角色名+关键词） |
| 成员行 | 复选框（40pt 行高，≥24pt 命中）+ 人脸裁切 + 文件名 + `相似度 0.42` + 低质量/小脸/未解析徽标 + 移除按钮 |
| 禁用 | 已绑定：按钮禁用 + help「先解除绑定（会撤销已写入关键词）」；分析中：禁用 + 「分析进行中」 |
| 确认 | `PendingFaceSplit` + `gatherDestructiveConfirm`；文案见下 |
| 空态 | 无待复核成员：`ContentUnavailableView`「未发现待复核成员」+「显示全部成员」 |
| 键盘 | Space 切换勾选；⌘A 全选（至少留 1 个，超出时提示）；Esc 清空；Tab 顺序 = 列表 → 拆分按钮 → 编辑区 |
| 焦点 | 拆分成功后自动选中新簇，`@FocusState` 聚焦角色名输入 |
| a11y | 复选框 label「选择成员 %@，与簇中心相似度 %@」；徽标 label「%lld 个待复核成员」；拆分按钮 hint「把所选成员移到一个新簇」 |

成员行用 `FaceReviewItem` 驱动（新增 `FaceReviewMemberRowView`，替换只吃 `ClusterMember` 的 `MemberRowView`；后者如无其它调用点则删除，避免死代码门禁）。VM 新增状态与方法（stored 属性必须在 `FaceKeywordingViewModel.swift` 主文件）：

```swift
public internal(set) var reviewItems: [FaceReviewItem] = []
public internal(set) var reviewSummaries: [FaceReviewClusterSummary] = []
public internal(set) var reviewNextCursor: String?
public internal(set) var reviewTotal = 0
public internal(set) var reviewSuspectTotal = 0
public internal(set) var selectedMemberIds: Set<Int> = []
public internal(set) var isSplitting = false

public func loadReview(clusterId: Int? = nil, reset: Bool = true) async
public func loadMoreReview() async
public func toggleMemberSelection(_ memberId: Int)
public func clearMemberSelection()
public func splitSelectedMembers(from cluster: FaceClusterData, confirmed: Bool) async
```

确认上下文：`PendingFaceSplit { cluster: FaceClusterData; members: [FaceReviewItem] }`，`scopeText` 使用上文「将把…」模板；成功后 `reload()` → `select(newCluster)` → `loadReview()`。

与 remove/merge 的关系：remove = 丢弃垃圾或非人脸样本（不新建簇）；split = 另一个人的脸（新建簇并持久化）；merge = 合并且持久化（写 together、删 separate）。三者不能互相替代。

中文源 key（en 同 PR 补齐）：`拆分所选…`、`拆分为新簇`、`仅看待复核成员`、`未发现待复核成员`、`显示全部成员`、`待复核`、`低质量`、`小脸`、`与簇中心相似度 %@`、`已绑定「%@」；先解除绑定再拆分（会撤销已写入该角色的人脸关键词）。`、`将把 %lld 个成员拆到新簇「%@」，原簇保留 %lld 个成员。拆分会在重新聚类后保持，此操作不可撤销。`、`已拆分出簇 #%lld（%lld 个成员），可立即绑定。`

## 5. 数据 / DDL / SQL

### 5.1 Schema V3（纯增量；与 T0 共表）

```sql
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

- `separate`：`member_keys` 中任一成员不得与 `peer_keys` 中任一成员处于同一簇；`together`：`member_keys` 必须同簇，`peer_keys` 恒为 `[]`。
- 键格式（JSON 数组元素）：`{"observationId":123,"photoId":"ph_...","bbox":[x,y,w,h]}`。畸形 JSON、bbox 非 4 个有限数、observationId ≤ 0 → 该行跳过并记日志（不阻断分析）。
- 为什么存 photoId+bbox：重推理会删除并重建 `face_observations`（新 id），只存 observationId 会让约束在下次分析后全部失效。
- 为什么是 set-vs-set：把 40 人簇拆 3 人只需 1 行；逐对存储是 3×37 行，且无法表达「任一侧」语义。
- V3 计数（与 x0 的 triage 表共同）：表 43→45；列 373+6+10=**389**；显式索引 69+1+2=**72**；外键 62+1+2=**65**。若 T0 改动 triage DDL，必须同步重算。
- `SchemaV3.ddl = SchemaV1.ddl + "\n" + additions`；`SchemaV3.requiredColumns` 追加两张新表的关键列；`SchemaV3.shape` 的 `fingerprint` 由真实 V3 空库回填（禁止自动计算旧库）；`SchemaVersion.v3`、`SchemaCatalog.production`（current=.v3、快照 v1/v2/v3、迁移 V1→V2、V2→V3）、`Schema.swift` 的 `currentSchemaVersion = 3` 同步。
- `MigrationV2ToV3.apply` 只执行 `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`（幂等、不写 PRAGMA）；迁移前 `SchemaBackup` 已由 `Database.open` 负责。
- `clearOnEmpty` 路径（`FaceKwService+Clusters.swift:358-363`）在清空成员/未绑定簇时，同事务 `deleteConstraints(sessionId:)`；失败/取消不清。

### 5.2 仓储接口（新增）

```swift
public enum FaceClusterConstraintKind: String, Codable, Sendable { case separate, together }

public struct FaceClusterConstraintKey: Codable, Equatable, Sendable {
    public let observationId: Int64
    public let photoId: String
    public let bbox: [Double]
}

public struct FaceClusterConstraintRow: Sendable {
    public let id: Int64
    public let sessionId: String
    public let kind: FaceClusterConstraintKind
    public let memberKeys: [FaceClusterConstraintKey]
    public let peerKeys: [FaceClusterConstraintKey]
    public let createdAt: String
}

public struct FaceReviewMemberRow: Sendable {
    public let clusterId: Int64
    public let clusterLabel: String
    public let memberId: Int64
    public let photoId: String
    public let photoPath: String
    public let bbox: [Double]
    public let confidence: Double
    public let observationId: Int64?
    public let embedding: [Float]
    public let quality: Double
    public let faceSizePx: Double
    public let modelId: String
    public let modelVersion: String
}
```

`FaceRepository` 增：`isClusterBound(clusterId:)`、`createCluster(sessionId:label:)`、`moveClusterMembers(memberIds:toClusterId:sessionId:)`、`insertConstraint(sessionId:kind:memberKeys:peerKeys:)`、`getConstraints(sessionId:)`、`deleteConstraint(id:)`、`deleteConstraints(sessionId:)`、`getReviewMembers(sessionId:clusterIds:)`。

关键 SQL：

```sql
-- 绑定真相
SELECT 1 FROM role_bindings WHERE cluster_id = ? LIMIT 1;

-- 新簇（label 由服务层算：Person <max+1>）
INSERT INTO face_clusters (session_id, label, status, thumbnail_path, created_at, updated_at)
VALUES (?, ?, 'unbound', '', ?, ?);

-- 迁移成员（校验 rowcount == memberIds.count）
UPDATE face_cluster_members SET cluster_id = ?
WHERE id IN (...) AND session_id = ?;

-- 约束
SELECT id, session_id, kind, member_keys_json, peer_keys_json, created_at
FROM face_cluster_constraints WHERE session_id = ? ORDER BY id;

INSERT INTO face_cluster_constraints
(session_id, kind, member_keys_json, peer_keys_json, created_at)
VALUES (?, ?, ?, ?, ?);

-- 复核成员（按簇分块，≤200 簇/次；不加载无关照片）
SELECT fm.cluster_id, fc.label, fm.id, fm.photo_id, COALESCE(p.filepath,''),
       fm.bbox, fm.confidence, fo.id, fo.embedding, fo.quality, fo.face_size_px,
       fo.model_id, fo.model_version
FROM face_cluster_members fm
JOIN face_clusters fc ON fc.id = fm.cluster_id
LEFT JOIN photos p ON p.id = fm.photo_id
LEFT JOIN face_observations fo ON fo.id = fm.observation_id
WHERE fm.session_id = ? AND fm.cluster_id IN (...)
ORDER BY fm.cluster_id, fm.id;

-- 其余写入/清理
SELECT cluster_id FROM role_bindings WHERE cluster_id IN (...);
DELETE FROM face_clusters
 WHERE session_id = ? AND id IN (...)
   AND NOT EXISTS (SELECT 1 FROM face_cluster_members m WHERE m.cluster_id = face_clusters.id)
   AND NOT EXISTS (SELECT 1 FROM role_bindings rb WHERE rb.cluster_id = face_clusters.id);
UPDATE face_clusters SET updated_at = ? WHERE id IN (...);
UPDATE face_clusters SET status = 'unbound', updated_at = ? WHERE id IN (...);
DELETE FROM face_cluster_constraints WHERE id = ?;
DELETE FROM face_cluster_constraints WHERE session_id = ?;
SELECT label FROM face_clusters WHERE session_id = ?;
```

## 6. 算法

### 6.1 成员键解析

从当前簇成员建两个索引：`observationId -> member`、`photoId -> [member]`。解析顺序：直接命中原 observationId；否则同 photoId 中 `FaceIdentityPolicy.overlap(key.bbox, member.bbox) >= 0.5` 取最大值（并列取最小 memberId）；否则该键**剪除**。剪除后：separate 任一侧为空、together 少于 2 键 → 删除整行约束；其余保留并记日志。x0 的「缺失即跳过整条」会让移除一个成员就永久失效，故改为剪除（见 §10）。

### 6.2 约束应用（全量聚类事务内）

入口 `applyClusterConstraints(sessionId:) -> ClusterConstraintReport`，在 `commitFullClusters` 的绑定迁移/孤儿绑定之后、`upsertClusterSignature` 之前调用（`FaceKwService+Clusters.swift:396-423`）。报告类型（`FaceKwService+Types.swift`）：

```swift
struct ClusterConstraintReport: Sendable {
    var separateApplied = 0
    var togetherApplied = 0
    var skippedBound = 0
    var skippedUnresolved = 0
    var deletedConstraints = 0
}
```

步骤：

1. 读约束 + 当前簇/成员 + 绑定集合；解析键。
2. **separate**（按约束 id 升序）：找到 A、B 两侧同处的簇 C。若 C 有绑定 → 跳过并计数（不拆用户身份）。否则比较 `|A∩C|` 与 `|B∩C|`：移动**较小一侧**到新簇；相等时保留 `min(observationId)` 较小的一侧，移动另一侧（确定性）。若两侧在同簇的数量都为 0/仅一侧，跳过。
3. **together**：组内键落在多个簇时，选**最小 clusterId** 为目标（确定性）；任一涉及簇有绑定 → 跳过；若合并会违反任何 separate（两侧有禁同对）→ 跳过 together（separate 优先），记日志。移动全部成员，删除空的未绑定源簇。
4. 更新内存映射，最多 3 轮直到无违规；仍违规则记 `face_constraint_conflict`，分析仍提交（不因陈旧约束丢新簇）。
5. 性能：2k 观测 <150ms，10k <600ms；约束数通常 <20，移动语句按 400 分块。

**为什么绑定簇跳过**：全量聚类已用 `face_identity_feedback` 把已确认身份放进独立 manual 簇（`FaceKwService+Clusters.swift:184-198`），绑定成员不会与自动簇混合；跳过只兜异常数据，且绝不拆用户身份投影（role_bindings/person_photos/person_embeddings）。

**增量路径**：`commitIncrementalClusters`（`FaceKwService+Clusters.swift:500-619`）只追加/建新簇，不会把两个既有簇合并，已拆开的簇不会被合回；因此不跑应用。

**合并联动**：`mergeClusters`（`FaceKwService+Review.swift:163-182`）合并后删除跨越 merged 成员的 separate 约束；若源/目标均未绑定，再写一条 together 约束（成员键取自合并后 target；缺 observationId 的成员跳过，少于 2 键不写）。这样「拆分→合并」等价撤销，重聚类不会再次拆开。

约束新建的簇不加入 C2 的跨库匹配候选（避免自动建议改变用户拆分意图）；用户绑定后走既有 `bindCluster` 路径。

**删除/移除联动**：`removeMemberFromCluster` 不改约束；下次应用剪除失效键（§6.1）。`deleteClustersBySession` 仅会话删除时由外键 CASCADE 清理约束。

### 6.3 拆分事务

```swift
public func splitCluster(sessionId: String, clusterId: Int64, memberIds: [Int64]) throws -> FaceSplitResult
```

1. 守卫：controller 非空 → `.analysisRunning`；簇归属校验；`isClusterBound` → `.clusterBound`。
2. 读簇成员（全量，非 12 条预览）；校验：非空、真子集、全部属于该簇、无重复、两侧成员都有 `observationId`。
3. 计算 `label = Person <max+1>`（解析 session 内 `Person N` 数字最大值）。
4. 单事务：二次绑定检查 → `createCluster` → `moveClusterMembers`（rowcount 必须相等）→ 两簇 `status='unbound'`、清空 `matched_person_id/match_confidence`（建议值已过期）→ `insertConstraint(separate, member=所选, peer=剩余)` → 删除跨两侧的 together 约束。
5. 不调用 `personRepo.reconcileSession`：未绑定簇没有 person 投影；解绑路径已负责清理。任一步失败整事务回滚（无文件操作，无半套簇）。
6. 返回 `FaceSplitResult(newClusterId:movedCount:remainingCount:label:)`；UI 重新加载簇与复核页。

一致性：

| 表/对象 | 拆分影响 |
|---|---|
| role_bindings | 不写；存在即拒绝 |
| person_photos / person_embeddings | 不变（未绑定；不调用 reconcileSession） |
| face_identity_feedback | 不写（无 person） |
| face_cluster_members | 选中行 cluster_id 迁到新簇；rowcount 必须相等 |
| face_clusters | 新建 unbound；源/新簇 updated_at、status='unbound'；两簇 matched_person_id/match_confidence 清空 |
| face_cluster_state | 不变（签名只描述聚类参数） |
| face_cluster_constraints | 新增 separate；删除跨两侧的 together |
| 缩略图/计数 | 新簇 thumbnail_path=''（蒙太奇用成员裁切）；member_count 是实时 COUNT，不写列；无文件删除/移动 |

删除语义：拆分不删除源簇；最后成员被移除且无绑定时才由现有 `removeMemberFromCluster` 删除簇；无独立「删除簇」API。

### 6.4 复核 cohesion

- 输入：每簇成员向量（`face_observations.embedding`，Float32 blob）、quality、face_size_px、model；纯函数 `FaceReviewEngine`（`FaceReviewEngine.swift`）便于单测：

```swift
enum FaceReviewEngine {
    struct Thresholds { let cohesionFloor: Double; let madMultiplier: Double; let minQuality: Double; let minFaceSize: Double }
    struct ClusterInput { let clusterId: Int64; let label: String; let members: [FaceReviewMemberRow] }
    static func evaluate(_ clusters: [ClusterInput], thresholds: Thresholds)
        -> (items: [FaceReviewItem], summaries: [FaceReviewClusterSummary])
}
```
- 合格样本：observation 存在、向量非空、quality ≥ `face_review_min_quality`（默认 0.35）、model 与簇众数一致；不合格仍展示但打 `lowQuality/smallFace/unresolvedObservation/incompatibleModel` 标记，不参与质心。
- 质心 `c = normalize(mean(normalize(v_i)))`；n≥4 的成员 `cohesion_i = dot(normalize(v_i), c)`；n≤3 的成员 `cohesion_i = min_{j≠i} dot(normalize(v_i), normalize(v_j))`（质心会被不同脸拉高，故小簇改用两两最小值，UI 数字与徽标同源）。
- 可疑判据：n=1 不标；n=2..3 的成员 `cohesion < floor` 标 suspect；n≥4 的成员 `cohesion < max(floor, median - k*MAD)`（n≥5 才启用相对项）。
- 默认 floor=0.35、k=2.5；**suspect 只在合格样本上判定**；quality < `face_review_min_quality` 只打 `lowQuality`，observation 缺失/向量为空只打 `unresolvedObservation`，均不标 suspect；小于 `face_review_face_size_min` 打 `smallFace`，仍参与判据并展示。设置键（D7 注册 `SettingsService.getDefaults()`）：`face_review_cohesion_floor`（0.20...0.80，0.35）、`face_review_relative_mad`（1...5，2.5）、`face_review_min_quality`（0...1，0.35）、`face_review_face_size_min`（0...1024，48）。
- 同一张照片多张脸按 observation 独立成行（文件名重复、bbox 区分），不按 photo 去重；成员行用 bbox 裁切。
- 簇概要：`cohesion = median(合格成员 cohesion)`、`suspectCount`、`reviewCount`（有任一标记的成员数）；按 `reviewCount` 降序。
- 返回范围：`clusterId` 非 nil 时只返回该簇 items 与单独 summary；nil 时 summaries 覆盖全部簇，items 按复核优先级分页。
- 复核筛选：`includeResolved=false` 返回 `suspect || lowQuality || smallFace || unresolvedObservation || incompatibleModel` 的成员（低质量/小脸也值得看，不只是 suspect）；`total` = 该筛选数量，`suspectTotal` 只统计 suspect。
- 排序：suspect 优先 → 其他标记 → cohesion 升序 → memberId 升序；未解析成员 cohesion 记为 -1 排最前。游标 `v1:<cohesion>:<memberId>`，服务端解析，非法 → `FACE_REVIEW_CURSOR_INVALID`。
- 缓存：`FaceKwService` 内 `[sessionId: ReviewCacheEntry]` + NSLock；版本 = `max(cluster.updated_at) | max(constraint.id) | count(constraints) | 阈值设置`，60s TTL；拆分/合并/移除/重聚类都会改变版本。增量追加不改簇 `updated_at`，因此 `analyze`/`recluster`/增量提交后显式 `invalidateReviewCache(sessionId:)`。10k 观测按簇分块流式计算，峰值内存 <100MB。

```swift
private struct ReviewCacheEntry {
    let version: String
    let generatedAt: Date
    let items: [FaceReviewItem]
    let summaries: [FaceReviewClusterSummary]
}
```

- 模型众数：按 `(modelId, modelVersion)` 计数取最多者；并列取最小 memberId。向量长度与簇众数不同者标 `incompatibleModel`，不参与质心。

## 7. API

```swift
public protocol FaceAPI: Sendable {
    // ... 现有 13 个方法不变
    func split(_ input: Confirmed<FaceSplitInput>) async throws -> FaceSplitResult
    func review(_ input: FaceReviewInput) async throws -> FaceReviewPage
}

public struct FaceSplitInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int
    public let memberIds: [Int]
    public init(sessionId: String, clusterId: Int, memberIds: [Int]) throws
}

public struct FaceSplitResult: Codable, Equatable, Sendable {
    public let newClusterId: Int
    public let movedCount: Int
    public let remainingCount: Int
    public let label: String
}

public struct FaceReviewInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int?      // nil = 全部簇
    public let cursor: String?
    public let limit: Int           // 1...200，默认 50
    public let includeResolved: Bool // false = 只看待复核
    public init(sessionId: String, clusterId: Int? = nil, cursor: String? = nil,
                limit: Int? = nil, includeResolved: Bool = false) throws
}

public enum FaceReviewFlag: String, Codable, CaseIterable, Sendable {
    case suspect, lowQuality = "low_quality", smallFace = "small_face"
    case unresolvedObservation = "unresolved_observation", incompatibleModel = "incompatible_model"
}

public struct FaceReviewItem: Codable, Equatable, Sendable {
    public let clusterId: Int
    public let clusterLabel: String
    public let memberId: Int
    public let photoId: String
    public let photoPath: String
    public let filename: String
    public let bbox: [Double]
    public let confidence: Double
    public let quality: Double
    public let faceSizePx: Double
    public let cohesion: Double     // 未解析 = -1；n≤3 时为两两最小值
    public let flags: [FaceReviewFlag]
}

public struct FaceReviewClusterSummary: Codable, Equatable, Sendable {
    public let clusterId: Int
    public let label: String
    public let size: Int
    public let suspectCount: Int
    public let reviewCount: Int
    public let cohesion: Double?
}

public struct FaceReviewPage: Codable, Equatable, Sendable {
    public let items: [FaceReviewItem]
    public let nextCursor: String?
    public let total: Int
    public let suspectTotal: Int
    public let clusters: [FaceReviewClusterSummary]
}
```

- **关于 `FaceClusterData` 增字段：本设计选择不新增**。`getClusters` 是 20k 首屏路径；若为每簇算 cohesion 需加载全部 embedding（约 30–60MB）并做 O(n) 计算，违反 D9。簇卡片徽标由 `face.review(clusterId: nil, limit: 1)` 的 `clusters` 概要提供（有缓存），首屏只多一次轻调用。
- 若评审坚持 DTO 内联：备选只加 `suspectMemberCount: Int?`（不加 cohesion），由 review 缓存填充；`clusters` 未命中缓存时返回 nil，UI 需要二次刷新，估值 +1 PD。推荐独立 review。
- 输入校验：`FaceSplitInput` 的 sessionId 非空、clusterId ≥ 0、memberIds 1...10000 且去重（空 → `FACE_SPLIT_EMPTY`，重复/越界 → `FACE_SPLIT_INVALID_MEMBER`）；`FaceReviewInput` 的 limit 1...200、clusterId ≥ 0、cursor ≤ 64 字符。所有 Input 按现有契约模式显式实现 `init(from:)`。
- 错误码：`FACE_CLUSTER_BOUND`、`FACE_SPLIT_EMPTY`、`FACE_SPLIT_INVALID_MEMBER`、`FACE_SPLIT_KEEP_ONE`、`FACE_SPLIT_MEMBER_UNRESOLVED`、`FACE_REVIEW_CURSOR_INVALID`；同步 `GatherErrorCode`、`FaceKwServiceError` + `gatherCode`、`GatherLocalization`、`en.lproj`。
- `LiveFaceAPI` 只做入参映射；`PreviewFaceAPI` 补两个 stub。**F0 只给 FaceAPI 增 2 个方法，协议数不变**（第 17 个协议由 B0 的 MaintenanceAPI 引入）；协议基线需更新方法数并记账。
- 所有输出类型（`FaceSplitResult` / `FaceReviewItem` / `FaceReviewPage` / `FaceReviewClusterSummary`）在 Protocol 模块提供 `public init`；持久层 `FaceClusterConstraintKey` / `FaceReviewMemberRow` 同样提供 `public init`（Application 跨模块构造）。
- `FaceKwServiceError` 新 case：`clusterBound` / `splitEmpty` / `splitInvalidMember` / `splitKeepOne` / `splitMemberUnresolved` / `reviewCursorInvalid`；`description` 返回对应码字符串，`gatherCode` 同步映射。

## 8. 测试矩阵

| 层 | 用例 | 断言 |
|---|---|---|
| Repo | create/move/constraint CRUD、跨会话 move | rowcount、事务、CASCADE |
| 解析 | 直接命中、photo+bbox 回退、键剪除、约束删除 | 剪除与日志、无半应用 |
| 应用 | separate 小侧移动、等大按最小 id、together 合并、绑定跳过、separate 优先、幂等 | 结果确定、重复跑无写 |
| 拆分 | 空/全选/重复/跨簇/缺 observation/绑定/分析中 | 对应错误码、零副作用 |
| 事务 | move rowcount 不符、约束插入失败 | 全部回滚，原簇不变 |
| 计数/缩略图 | 拆分后两簇 size、照片数、蒙太奇、thumbnail_path | 源簇减、新簇增；无文件操作 |
| 保持 | split → recluster（全量）→ 仍两簇；analyze 增量 → 不合并 | 成员集合不变 |
| 合并 | split → merge → recluster | separate 删除、together 生效、仍一簇 |
| 复核 | n=2/3/5、低质量、小脸、坏 observation、分页/游标/缓存过期 | cohesion/flags/排序/total/suspectTotal/reviewCount |
| 迁移 | V2→V3、新库、计数 45/389/72/65、指纹、备份 | 迁移后 open 成功 |
| 性能 | 2k/10k 观测、50/200 簇 | 应用 <150/600ms；复核 <300ms/1s |
| VM/UI | 多选、禁用、确认弹窗、拆分后焦点、a11y label | 状态/文案/焦点正确 |
| 回归 | 现有 bind/merge/remove/unbind/recluster/incremental 测试 | 全绿 |

## 9. 任务拆解（≤18 PD）

| ID | 任务 | 文件 | PD | 验收 |
|---|---|---|---:|---|
| F0-1 | 规格/文案/评审 | 本文档 + en.lproj 清单 | 1 | 评审通过，D5 一致 |
| F0-2 | V3 表/迁移/计数/指纹 | `Migration/SchemaV3.swift`、`Migration/MigrationV2ToV3.swift`、`SchemaCatalog.swift`、`SchemaVersion.swift`、`Schema.swift`、`README.md`（45/389/72/65）、`ADR.md`（ADR-031） | 2.5 | V2→V3 + 新库 + 计数门禁 |
| F0-3 | 约束仓库/解析/应用/合并联动 | `FaceRepo+Constraints.swift`、`FaceClusterConstraints.swift`、`FaceKwService+Clusters.swift`、`+Review.swift` | 3 | 拆分保持、合并删约束、together |
| F0-4 | 拆分事务/守卫/标签 | `FaceRepo+Members.swift`、`FaceKwService+Split.swift`、`+Types.swift` | 3 | 回滚/边界/绑定拒绝 |
| F0-5 | 复核队列/cohesion/缓存 | `FaceRepo+Review.swift`、`FaceReviewEngine.swift`、`FaceKwService+Review.swift` | 2.5 | 分页/阈值/2k/10k 预算 |
| F0-6 | API/类型/Live/Preview/错误码/基线 | `FaceAPI.swift`、`FaceInputs.swift`、`FaceOutputs.swift`、`LiveFaceAPI.swift`、`PreviewAPIs.swift`、`Core.swift`、`GatherLocalization.swift` | 2 | 契约测试 + strict 门禁 |
| F0-7 | UI/多选/确认/复核/设置/a11y | `FaceReviewStep.swift`、`FaceReviewMemberRowView.swift`、`FaceClusterCard.swift`、`FaceKeywordingViewModel(+Review).swift`、`+Confirmations.swift`、`SettingsViewModel+Catalog.swift` | 2 | 3 次操作完成拆分；键盘/VoiceOver |
| F0-8 | 单测/集成/迁移/性能/回归 | `FaceSplitTests`、`FaceReviewTests`、`FaceConstraintTests`、`FaceRepoTests`、`SchemaMigrationTests`、`APIFaceTests` | 2 | 全绿 + 预算记录 |
| **合计** | | | **18** | |

## 10. 未决问题与推荐选项

| # | 问题 | 推荐 | 理由 |
|---|---|---|---|
| 1 | x0 的 `face_cluster_constraints` 只有 `member_keys_json` | **加 `peer_keys_json`** | set-vs-set；否则 40 人簇拆 3 人要 111 行，或无法表达 |
| 2 | x0 的 FaceAPI delta 只有 `split` | **加 `review`** | 12 条预览无法复核 40 人簇；cohesion 必须服务端算 |
| 3 | x0「键缺失即跳过整条约束」 | **改为剪除失效键，语义为空才删** | 移除一个成员不应让整条拆分失效 |
| 4 | 错误码只列 3 个 | **补 KEEP_ONE / MEMBER_UNRESOLVED / CURSOR_INVALID** | 边界必须可区分，不能都落到 INVALID_MEMBER |
| 5 | cohesion floor 默认值 | **0.35 + MAD 2.5，设置可调** | 无真实标注前保守；F0-8 用 2k 真实集校准，不达标只影响可疑率 |
| 6 | together 的生产者 | **仅在未绑定簇 merge 时写入** | 让合并持久；绑定簇已由 feedback 保持，不重复 |
| 7 | 绑定簇遇到 separate 冲突 | **跳过 + 日志（不拆）** | 绝不拆用户身份投影；异常数据留待人工 |
| 8 | 拆分是否可撤销 | **v1 不提供；merge 删除 separate 约束** | 合并即有效撤销，且不会下次重聚类再拆开 |
| 9 | bbox 回退阈值 0.5 | **保留 0.5，记录命中率** | 与现有 feedback/匹配口径一致；重推理漂移需真实集验证 |
| 10 | 20k 规模复核耗时 | **分块 + 版本化缓存；>1.5s 再任务化** | 先守住 20k <1s 预算，不提前引入 job |

**与 x0-contracts 的冲突（明确）**：① 缺少 `peer_keys_json`；② FaceAPI 未列 `review`；③ 缺 3 个错误码；④ 键缺失语义由「跳过」改「剪除」。以上均已在 §10 给出推荐，需评审后回写 x0（本文件不改 x0）。

## 11. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| 重推理后 bbox 漂移，约束剪除 | 拆分在下次分析后失效 | 存 photo+bbox；0.5 IoU；F0-8 做 re-inference 夹具；日志统计 |
| 绑定簇跳过导致异常合簇保留 | 用户看到未拆开 | 只在异常数据发生；review 页可暴露低 cohesion；P1 增加「约束未应用」提示 |
| 拆分后立即合并的语义 | 约束抖动 | merge 删 separate、写 together；同事务 |
| 复核计算内存峰值 | 20k 卡顿 | 按簇分块、只留轻量 item、缓存上限 1 个版本 |
| 旧库成员无 observationId | 无法拆 | 明确报错并引导重新分析；不静默拆 |
