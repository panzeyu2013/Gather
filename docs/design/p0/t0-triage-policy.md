# T0 技术质量初筛（Triage v1）设计

> 范围：`CullingAPI.generateTriage/applyTriage`、`triage_suggestions`、建议卡与复核队列。
> 依赖：`docs/design/p0/README.md` D1–D10、`docs/design/p0/x0-contracts.md`。
> 结论：v1 是**保守的技术质量分诊**，不是审美判断；只写 Gather 决策，绝不自动写 XMP。

## 0. 结论先行

1. 三分类 `keep` / `reject` / `review`；**只有 keep/reject 可应用**，review 永不产生决策。
2. 五条铁律：人工决策不生成/不覆盖；单张或无替代不淘汰；未分析/分析失败只复核；闭眼只“疑似”；并列/差距不足只复核。
3. `confidence` 是**可执行置信度**（不是准确率）：keep 需 ≥0.60，reject 需 ≥0.75；低于 `triage_min_executable_confidence`（0.55）一律 review；review 存“最高可执行置信度”，可为 0（未分析）到 0.8（策略保护），不是固定 0。
4. 组内最佳由 Triage 自己按 `qualityScore` 排名；`relativeRank` 只在 `QualityService.get` 内存重算，未可靠落库，不能当真相源。
5. 失效用输入指纹（quality/similarity/duplicate/navigation/policy），读时判 stale，用户手动重生；20k < 2s。复核队列契约：`CullingFilters.triageVerdicts` + `CullingSort.triageConfidenceAsc`。

## 1. 目标 / 非目标

目标（可验收）：3000 张首轮挑片，建议覆盖率（keep+reject）/总数 ≥ 65%，建议淘汰误杀 < 1%，复核率 ≤ 35%；可解释、可撤销、可重算；20k 生成 < 2s。
非目标：审美/构图/表情判断；自动应用；自动写 XMP；替换人工；跨会话 triage；embedding（Roadmap 2.x）。

## 2. 场景与状态机

主流程：技术质量分析（已有 `QualityService`）→ `generateTriage` → 建议卡 → review 队列逐张确认 → `applyTriage`（只写决策）→ 挑片页照常写回。

| 状态 | 进入 | UI | 可执行 |
|---|---|---|---|
| empty | 无照片 | 空态 | 生成禁用 |
| partial | 质量覆盖 <100% | “已分析 X/Y” | 生成允许，未分析项 review |
| ready | 指纹匹配且有行 | 建议卡 + 徽标 | 应用/复核 |
| stale | 指纹/策略不匹配 | “建议已过期” | 仅重新生成 |
| applying | 应用事务中 | 进度/禁用 | 禁用 |
| error | DB/策略错误 | 错误码文案 | 重试 |

失败路径：`TRIAGE_NOT_READY`（未生成/无质量）、`TRIAGE_STALE`（过期）、`TRIAGE_POLICY_INVALID`（策略/设置非法）。并发生成由 `BEGIN IMMEDIATE` 串行化；应用前重算指纹，过期即拒。

## 3. 规则：verdict、阈值、覆盖

### 3.1 信号

| 信号 | 来源 | 用途 |
|---|---|---|
| `qualityScore/sharpness/exposure/subjectSharpness/closedEyeRisk/warnings` | `QualityResult`（`technical-quality@2`） | 主判据；`focus = subjectSharpness ?? sharpness` |
| `relativeRank` | `QualityService.applyRelativeRanks` | **不用**；Triage 自算 |
| 相似组 | `similarity_results` 最新结果 | 组内最佳/比较 |
| 重复组 | `duplicate_groups`（exact/visual） | 完全重复优先；近似重复作组 |
| 导航组 | `navigation_groups`（burst/scene） | 无相似组时兜底；lead 仅并列决胜 |
| 人脸数/最大框面积 | `face_observations`（**只统计逻辑资产代表行**，不跨 RAW/JPEG 变体累加） | 主体判断、闭眼/多脸保护；同一张脸两份变体观测会误判多人 |
| 人工决策 | `culling_decisions.decision_source='manual'` | 排除/跳过 |

### 3.2 决策优先级（自高到低，先命中先返回）

| P | 规则 | 触发 | verdict | 备注 |
|---|---|---|---|---|
| 0 | 人工已决策 | source=manual 且 decision≠pending | 排除 | 不写建议行；UI 显示“已人工决策” |
| 1 | 未分析/失败 | 无结果、status=failed、analysis_failed | review | conf=0；reason 区分 |
| 2 | 无替代 | 无 ≥2 人的可用组 | keep 若 q≥0.60 且无硬警告，否则 review | **永不 reject** |
| 3 | 完全重复 | exact 组 ≥2 | 最佳 keep，其余 reject | conf 0.95；最佳按分辨率→文件大小→导入序 |
| 4 | 硬技术失败 | focus<0.12 或 exposure<0.30，且组内有技术合格替代，且自身非最佳 | reject | 最佳也失败→全组 review |
| 5 | 组内最佳 | rank=1、与第二差 ≥0.06、无硬警告 | keep | 不满足 margin/有警告→review |
| 6 | 明确较弱 | 与最佳分差 ≥0.12，无保护 | reject | 受 §3.4 修饰 |
| 7 | 并列/接近 | 分差 <0.02，或最佳 margin <0.06 | review | 不猜 |
| 8 | 兜底 | q≥0.60 且无硬警告 | keep | 单张/无可比组 |
| 9 | 其余 | — | review | 低质量无替代也不淘汰 |

覆盖关系：P0 最高；P1 阻断一切建议；P2 阻断 reject；P3 独立于质量且**先于 P5**（exact 组优先于 similarity 组）；P4 要求“有合格替代”；P5/P6/P7 互斥；P8 只在无组或组无可用替代时生效。闭眼/多脸/小脸是**修饰器**：闭眼→强制 review（不参与 P4/P6）；多脸（≥3）→排名型 reject 降为 review，硬技术失败仍可 reject；小脸（<0.01）→眼部信号忽略、排名型 reject 降为 review。

### 3.3 阈值表（policy v1）

| 参数 | 值 | 来源/说明 |
|---|---:|---|
| keepScoreMin | 0.60 | policy 常量 |
| groupKeepMargin | 0.06 | policy 常量 |
| groupRejectMargin | 0.12 | policy 常量 |
| tieEpsilon | 0.02 | policy 常量 |
| blurSharpnessMax | 0.12 | 对 `focus`（有主体取 subjectSharpness）；对齐 `motion_blur` 警告 |
| exposureMin | 0.30 | 对齐 `exposure_issue` |
| closedEyeSuspectMin | 0.72 | 对齐 `closed_eye_risk_heuristic` |
| facePrimaryAreaMin | 0.03 | 人脸框面积/画幅 |
| faceSmallAreaMax | 0.01 | 小于此忽略眼部 |
| multiFaceCount | 3 | ≥3 视为合影 |
| keepConfidenceMin | 0.60 | policy 常量；低于此不 keep |
| rejectConfidenceMin | 0.75 | 设置 `triage_reject_confidence_min` |
| minExecutableConfidence | 0.55 | 设置 `triage_min_executable_confidence`；低于此绝不执行（review 可 >0.55） |

P0 只暴露两个置信度设置 + `triage_enabled` + `triage_policy`；其余阈值改动用 **policy_version 升版**，不进设置页。

### 3.4 保护条件

| 保护 | 规则 |
|---|---|
| 单张/无替代 | 永不 reject；好则 keep，否则 review |
| 未分析 | review，reason `quality_missing`，conf=0 |
| 分析失败 | review，reason `analysis_failed`，conf=0 |
| 人工已决策 | 不生成、不覆盖；应用计入 skippedManual |
| RAW/JPEG 逻辑资产 | 按 `PhotoAssets.collapse` 代表行（RAW 优先）**一个建议**；绝不拿变体互相比 |
| 无脸 | 忽略闭眼；用全局锐度/曝光 |
| 单人脸 | 闭眼只 review；排名型 reject 可保留 |
| 多人脸≥3 | 排名/眼部型 reject→review；硬技术失败可 reject |
| 小脸<0.01 | 眼部信号不可靠；排名型 reject→review |
| 并列/接近 | review；不猜“最佳” |
| 组跨页 | 全会话计算，分页只影响展示；组 id 落库 |
| 组内未分析 | 只与已分析成员比；可用替代 <1 按“无替代” |

## 4. confidence 与 reasons

### 4.1 定义与公式（v1）

`confidence ∈ [0,1]` 表示**证据支持自动 keep/reject 的强度**，不是“判断准确率”，也不是“建议正确概率”。现有 `QualityResult.confidence` 是 `face != nil ? 0.6 : 0.55` 的常量，**不参与** Triage 门槛或排序；Triage 分别计算两个方向：

```
m = clamp(margin / 0.30, 0, 1)          // reject: best-q；keep: q-second
agree = (signalsTrue + 1) / (signalsApplicable + 1)   // Laplace 平滑
faceFactor = 1.0 / 0.85 / 0.70          // 人脸面积 ≥0.03 / 0.01–0.03 / <0.01 或无脸
cKeep   = clamp(0.30 + 0.45*mKeep   + 0.20*agreeKeep*faceFactor   + 0.05, 0, 1)
cReject = clamp(0.30 + 0.45*mReject + 0.20*agreeReject*faceFactor + 0.05, 0, 1)
```

- 单张 keep：`cKeep = 0.45 + 0.30*qualityMargin + 0.10*agree + 0.05`，上限 0.80。
- 完全重复：非最佳 `cReject=0.95`、最佳 `cKeep=0.90`。
- 保护型（多人脸、闭眼、小脸）**只进 review**，展示置信度可截断 0.60/0.70；可执行的 `reject` 必须 `cReject ≥ 0.75`，不得用固定上限把“明确较弱”永久压到门槛以下。
- **reject 资格**：组 ≥2、自身非最佳、存在技术合格替代（`focus≥0.12 且 exposure≥0.30`）；否则 `cReject=0`（单张/无替代/全组都差时不可能淘汰）。exact 重复不受此限。
- 未分析/失败：review，`confidence=0`。
- 其他 review：`confidence = max(cKeep, cReject)`；该值可 >0.55（例如多人脸保护、闭眼保护），表示“证据够，但策略要求人看”，UI 用 reasons 区分“不确定”与“策略复核”。
- 判定：`keep` 需 cKeep≥0.60；`reject` 需 cReject≥0.75；cKeep/cReject 均低于 `minExecutableConfidence`（0.55）时绝不执行；其余 review。**门槛在每条分支返回前统一检查**；不足时保留 reasons 转 review，不能“先判 reject 再补置信度”。

**低置信度优先**：复核队列按 `confidence ASC, score ASC, photo rowid ASC` 排序；confidence 越低表示越缺乏可执行证据（未分析=0 最前），策略保护型复核（confidence 较高）靠后。`confidence` 高但 verdict=review 是有意为之：不是“不确定”，而是“规则不允许自动执行”。

`agree` 的适用信号：reject 看 blur/exposure/focus<0.30/rank>1/duplicateNonBest；keep 看无警告/rank=1/q≥0.60/exposure≥0.40/focus≥0.40；不可计算的不计入分母。

### 4.2 reasons 码表（`reasons_json` 为 `[{"code","value"}]`）

| code | 中文 | English | 触发 |
|---|---|---|---|
| group_best | 同组最佳 | Best in group | P5 |
| weaker_than_group_best | 同组中有更清晰/更稳的一张 | A stronger frame exists in this group | P4/P6，value=分差 |
| motion_blur | 疑似抖动模糊 | Possible motion blur | sharpness<0.12 |
| exposure_low | 曝光可能不准 | Exposure may be off | exposure<0.30 |
| closed_eye_suspect | 疑似闭眼，请人工确认 | Possible closed eyes — please review | risk≥0.72 且主体脸 |
| close_call | 差距不足以下结论 | Too close to call | 分差 <0.12 且未达 keep margin |
| tie_with_group | 与同组几乎一样 | Nearly tied with the group | 分差 <0.02 |
| single_shot | 单张，无替代 | Single frame, no alternative | 组大小 1 |
| no_alternative | 没有可比的替代片 | No comparable alternative | 组内可用 <2 |
| low_technical | 技术质量偏低 | Low technical quality | q<0.60 且无组 |
| quality_missing | 尚未做技术质量分析 | Not analyzed for technical quality | 无结果 |
| analysis_failed | 技术质量分析失败 | Technical quality analysis failed | status failed |
| duplicate_exact | 完全重复文件 | Exact duplicate file | exact 组 |
| duplicate_visual | 视觉近似重复 | Visually similar duplicate | visual 组 |
| multi_face_low_confidence | 多人脸，建议人工判断 | Multiple faces — review suggested | ≥3 脸 |
| small_face | 人脸过小，眼部信号不可靠 | Face too small for reliable eye signal | 面积 <0.01 |
| manual_override | 已有人工决策 | Manually decided | UI-only，不落库 |

reason 最多 3 条，按上表顺序；`value` 仅数值型。

## 5. 组内最佳

- 组源优先级：**exact duplicate（完全重复）> similarity（最新结果）> visual duplicate > navigation burst/scene**；完全重复是最确定的证据，因此 P3 先于 P5，只取一个“最佳组”，避免同一照片被两条规则打架。
- 成员先按逻辑资产去重（asset_id），再按 `qualityScore` 降序；同分按 leadPhotoId（导航组）→ 导入 rowid 升序，保证确定性。
- `relativeRank`：`QualityService.analyze` 先入库、后 `applyRelativeRanks`；`get` 每次内存重算，落库 JSON 不含排名。因此 Triage **不读** `relativeRank`，自己算 rank/best/second。
- 组大小：1→单张，只 keep/review；2→最佳 keep（margin≥0.06），另一张仅当分差≥0.12 且无保护才 reject；N≥3→最佳 keep，每张与最佳差≥0.12 才 reject，中间档 review；exact 重复不受 margin 限制。
- 跨页：groupId 形如 `sim:<resultId>:<groupIndex>`/`dup:<id>`/`nav:<id>`；分页不影响成员集合。

## 6. 指纹、失效、幂等

`policy_version="triage-v1"`；设置 `triage_policy=v1` 映射到该值，未知值→`TRIAGE_POLICY_INVALID`。任何阈值改动→`triage-v2`。

指纹（SHA-256）：quality_model_id/version | quality_count | quality_max_updated_at | similarity_latest_id | duplicate_count | duplicate_max_created_at | navigation_count | navigation_max_updated_at | policy_version | thresholds_hash。**不含 culling_decisions**（建议是决策前的；人工决策在应用时跳过）。`quality_count`/`quality_max_updated_at` 只数**逻辑资产代表行**，不数 RAW/JPEG 变体，否则指纹会随变体数量漂移。

`TriageRepository.currentFingerprint` 一条 SQL（`<preferredRowOrder>` 由 Swift 插入 `PhotoRepo.preferredRowOrderSQL(alias:"p")`，禁止另写 RAW 判断）：

```sql
WITH rep AS (
  SELECT p.id AS photo_id, p.asset_file_id,
         ROW_NUMBER() OVER (
           PARTITION BY COALESCE(p.asset_id, 'photo:' || p.id)
           ORDER BY <preferredRowOrder>
         ) AS rn
  FROM photos p
  WHERE p.session_id = :sid
),
q AS (
  SELECT rep.photo_id, aa.updated_at
  FROM rep
  JOIN asset_analysis aa ON aa.asset_file_id = rep.asset_file_id
  WHERE rep.rn = 1 AND aa.analysis_type = 'technical_quality'
)
SELECT
 (SELECT COUNT(DISTINCT photo_id) FROM q),
 (SELECT COALESCE(MAX(updated_at),'') FROM q),
 (SELECT COALESCE(MAX(id),0) FROM similarity_results WHERE session_id=:sid),
 (SELECT COUNT(*) FROM duplicate_groups WHERE session_id=:sid),
 (SELECT COALESCE(MAX(created_at),'') FROM duplicate_groups WHERE session_id=:sid),
 (SELECT COUNT(*) FROM navigation_groups WHERE session_id=:sid),
 (SELECT COALESCE(MAX(updated_at),'') FROM navigation_groups WHERE session_id=:sid);
```

- 读时判定：所有行 `MIN/MAX(input_fingerprint)` 一致且等于当前值、policy 一致→ready；否则 stale。不挂 job 钩子，避免质量/相似度任务各自失效造成竞态。
- 生成：`BEGIN IMMEDIATE`→删除该会话旧行→批量插入→提交；失败回滚保留旧建议。
- 幂等：候选按 photoId、组成员按 id、reasons 按码表序；分数/置信度四舍五入 3 位；同一指纹重复生成仅 `computed_at` 变化。`force=false` 且指纹匹配直接返回旧 summary。
- 并发：后到生成覆盖先到；应用前校验指纹，stale 即 `TRIAGE_STALE`。

## 7. DDL / API / 类型

### 7.1 DDL（严格按 x0）

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
```

### 7.2 Swift 类型（`GatherProtocol/Protocol/Triage.swift`）

```swift
public enum TriageVerdict: String, Codable, CaseIterable, Equatable, Sendable {
    case keep, reject, review
}
public enum TriageReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
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
public struct TriageReason: Codable, Equatable, Sendable {
    public var code: TriageReasonCode
    public var value: Double?
    public init(code: TriageReasonCode, value: Double? = nil)
}
public struct TriageSuggestion: Codable, Equatable, Sendable {
    public var photoId: String
    public var verdict: TriageVerdict
    public var score: Double
    /// 可执行置信度：keep/reject 为对应方向的置信度；review 为 max(cKeep,cReject)。
    public var confidence: Double
    public var reasons: [TriageReason]
    public var groupId: String?
    public var policyVersion: String
    public var inputFingerprint: String
    public var computedAt: String
}
public struct TriageCounts: Codable, Equatable, Sendable {
    public var keep: Int
    public var reject: Int
    public var review: Int
    public var total: Int
    public var coverage: Double               // 成功分析数 / total，0...1
}
public struct TriageSummary: Codable, Equatable, Sendable {
    public var counts: TriageCounts
    public var stale: Bool
    public var policyVersion: String
    public var inputFingerprint: String
    public var generatedAt: String
}
public struct TriageGenerateInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var force: Bool
}
public struct TriageApplyInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var verdicts: [TriageVerdict]      // 仅 keep/reject；含 review → TRIAGE_POLICY_INVALID
    public var minConfidence: Double?         // nil = 按 verdict 取 keep 0.60 / reject 0.75；非 nil 取 max(输入, 下限)
    public var photoIds: [String]?            // nil = 全部
}
public struct TriageApplyResult: Codable, Equatable, Sendable {
    public var appliedKeep: Int
    public var appliedReject: Int
    public var skippedManual: Int
    public var skippedLowConfidence: Int
    public var historyOperationId: Int?
}
```

### 7.3 API / 查询契约（X0 已确认）

```swift
func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary
func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult

// CullingFilters 新增
public var triageVerdicts: [TriageVerdict]?
// CullingSort 新增
case triageConfidenceAsc
```

`CullingAsset.triage: TriageSuggestion?`；`CullingSummary.triage: TriageSummary?`。在 G0 的资产分组查询里，令 `rep.photo_id` 为该逻辑资产代表行（RAW 优先），排序与筛选：

```sql
LEFT JOIN triage_suggestions ts ON ts.photo_id = rep.photo_id
WHERE (:hasTriageFilter = 0 OR EXISTS (
  SELECT 1 FROM triage_suggestions t
  WHERE t.photo_id = rep.photo_id AND t.verdict IN (/* triageVerdicts */)
))
ORDER BY (ts.confidence IS NULL) ASC,  -- 无建议排最后
         ts.confidence ASC,
         ts.score ASC,
         rep.rowid ASC
```

无建议 = `triage_suggestions` 无行 = `CullingAsset.triage == nil`；**不把 nil 强转成 0**。0 是“已生成建议、未分析/无证据”的 review 行，两者 UI 文案不同；`triageConfidenceAsc` 在无 triage 过滤时也合法，只是 nil 排最后。

### 7.4 纯函数（`TriageEvaluator.swift`）

```swift
public struct TriagePolicy: Equatable, Sendable {
    public var version: String
    public var keepScoreMin, groupKeepMargin, groupRejectMargin, tieEpsilon: Double
    public var blurSharpnessMax, exposureMin, closedEyeSuspectMin: Double
    public var facePrimaryAreaMin, faceSmallAreaMax: Double
    public var multiFaceCount: Int
    public var keepConfidenceMin, rejectConfidenceMin, minExecutableConfidence: Double
    public var maxReasons: Int
    public static let v1: TriagePolicy
}
public struct TriageGroupRef: Equatable, Sendable {
    public enum Kind: String, Sendable { case similarity, exactDuplicate, visualDuplicate, burst, scene }
    public var kind: Kind
    public var groupId: String
    public var memberPhotoIds: [String]
    public var leadPhotoId: String?
}
public struct TriageCandidate: Equatable, Sendable {
    public var photoId: String
    public var quality: QualityResult?
    public var faceCount: Int
    public var maxFaceAreaRatio: Double
    public var groups: [TriageGroupRef]
    public var manualDecision: CullingDecisionValue?
    public var decisionSource: CullingDecisionSource?
}
public struct TriageResult: Equatable, Sendable {
    public var photoId: String
    public var verdict: TriageVerdict
    public var score: Double
    public var confidence: Double
    public var reasons: [TriageReason]
    public var groupId: String?
}
public enum TriageEvaluation: Equatable, Sendable {
    case suggestion(TriageResult)
    case excluded(TriageReasonCode)
}
public func evaluateTriage(
    candidates: [TriageCandidate],
    policy: TriagePolicy
) -> [TriageEvaluation]
```

不变量：纯函数、无 I/O；候选与成员排序后计算；manual 必返回 `.excluded(.manualOverride)`；同输入同输出（computedAt 由服务层补）。

## 8. UI、文案与复核队列

| 位置 | 呈现 |
|---|---|
| 建议卡 | “已分析 X/Y · 建议保留 A · 建议淘汰 B · 待复核 C”；“技术质量建议（Beta）· 不含审美判断” |
| 网格徽标 | 建议保留/建议淘汰/待复核（图标+文字+颜色 token，不单靠颜色） |
| 理由 | 最多 2 条 chips，展开显示 score/sharpness/exposure/face area |
| 复核队列 | **仅 verdict=review**，`triageConfidenceAsc` 排序；组内对照最佳；键盘 P/X/U/0–5/←→；review 行不显示裸 confidence，只显示“不确定/策略复核” |
| 应用 | 确认 sheet：应用 A 保留/B 淘汰；跳过 C 人工决策；**不会写入 XMP**；可撤销 |
| 过期 | 横幅“建议已过期，请重新生成”；禁止应用 |
| 空/部分 | 无建议=“未生成/已人工决策”；review+confidence 0=“未分析” |

**复核队列只显示 `review`**：v1 的 keep 已要求 ≥0.60、reject ≥0.75，低置信 keep/reject 在生成时已转 review，因此队列不需要混入可执行项。需要看全部建议时用 `triageVerdicts=[keep,reject,review]`；“仅看低置信”属于 P1，用 `triageConfidenceMax` 另开过滤，不改变 v1 语义。

**非建议照片与 confidence**：

| 场景 | `CullingAsset.triage` | confidence |
|---|---|---|
| 未生成/已过期/已人工决策/无行 | nil | 不适用（不是 0） |
| 已生成、未分析 | review 行 | 0 |
| 已生成、判 review（接近/保护/无替代） | review 行 | max(cKeep,cReject)，0–1，可 >0.55（“可执行置信度”而非“review 置信度”） |
| keep/reject | 对应行 | keep ≥0.60 / reject ≥0.75 |

SQL 排序 nulls last；UI 对 nil 显示“未生成/已人工决策”，对 0 显示“未分析”，绝不把 nil 当 0。`triage_suggestions` 行内 `confidence` 永不为 null。

**排序与 policy_version**：排序只读已落库的 `confidence`，不重算；所有行必须同一 `policy_version`/指纹。若 `stale`，UI 禁用队列与应用，先重新生成；重新生成会先删旧行，绝不跨版本混排。policy 升版（v1→v2）后旧行即过期，排序结果不再具有产品意义。

原则：建议永远是建议，不自动应用；不覆盖人工；不把 score 说成“成片率”；中英同 PR；视觉只用 DesignSystem token。**绝不自动写 XMP**：`applyTriage` 只写 `culling_decisions`（source=ai），XMP 仍走用户显式写回。

## 9. 性能与风险

| 项 | 预算 | 方法 |
|---|---:|---|
| 20k 读取（quality/groups/faces/decisions） | ≤0.6s | 6 条 SQL，无 N+1；quality 用窗口函数取最新 |
| 20k 纯函数 | ≤0.1s | O(n log n)，组内排序；无两两比较 |
| 20k 写入 | ≤0.5s | 单事务批量 insert |
| 总计 | **<2s** | 同步；超 2s 降级 Job（P1） |
| 500 张应用 | <1s | 复用 `CullingService` 批量事务 |

风险：闭眼是“眼部区域锐度代理”，不是 EAR；不同相机/ISO 的绝对锐度阈值漂移；浅景深背景虚化会拉低全局 sharpness；relativeRank 未落库；组数据过期；20k JSON 解码；用户把建议当结论；复核疲劳。对策：闭眼只 review；模糊用 focus 而非全局 sharpness；以组内相对差为主、绝对阈值只抓明显模糊；指纹 stale；按题材/相机分层评测；Beta 标识；复核率进 Go/No-Go。

## 10. 评估协议

- 数据：**真实照片** 400 张（dev 200 / test 200），4 层各 100：婚礼/活动、人像、体育/动作、商品/风光（无脸）。2 名摄影师独立标 keep/reject/unsure，争议由第 3 人裁决；报告 Cohen's κ（≥0.6）。
- 指标：误杀率（true keep 被 reject / true keep）≤1%；reject precision ≥99%；keep precision ≥98%；复核率 ≤35%；覆盖率 ≥65%；净节省=不需人工复核比例；分题材/相机/人脸面积分层。
- 防自证：合成数据只做单测（确定性/边界），**不进入验收指标**；标注者盲于输出；test 集不参与调参；报告 Wilson 区间；不把 T0 结论外推为 embedding/语义相似结论（Roadmap §八 是另一项假设）。
- Go/No-Go：四项主指标 + 分题材无单层误杀 >2%；否则保持 Beta，不对外承诺“初筛”。

## 11. 20 张样例（policy v1，期望输出）

| # | 场景 | q | 组/规模 | 人脸 | verdict | conf | reasons |
|---|---|---:|---|---|---|---:|---|
| P01 | 相似组最佳 | .86 | sim/3 | 1 | keep | .67 | group_best |
| P02 | 组内第二，差距小 | .78 | sim/3 | 1 | review | .55 | close_call, weaker_than_group_best(.08) |
| P03 | 组内模糊 | .52 | sim/3 | 1 | reject | .96 | motion_blur, weaker_than_group_best(.34) |
| P04 | 并列 A | .80 | sim/2 | 0 | review | ≈.51 | tie_with_group |
| P05 | 并列 B | .79 | sim/2 | 0 | review | ≈.42 | tie_with_group |
| P06 | 完全重复最佳 | .70 | exact/3 | 0 | keep | .90 | duplicate_exact, group_best |
| P07 | 完全重复次 | .70 | exact/3 | 0 | reject | .95 | duplicate_exact |
| P08 | 完全重复次 | .70 | exact/3 | 0 | reject | .95 | duplicate_exact |
| P09 | 单张好片 | .82 | 1 | 0 | keep | .77 | single_shot |
| P10 | 单张低质 | .40 | 1 | 0 | review | .56 | no_alternative, low_technical |
| P11 | 合影最佳 | .88 | sim/3 | 4 | keep | .70 | group_best |
| P12 | 合影第二 | .70 | sim/3 | 4 | review | .60 | multi_face_low_confidence, weaker_than_group_best(.18) |
| P13 | 合影模糊 | .46 | sim/3 | 4 | reject | 1.00 | motion_blur, low_technical |
| P14 | 未分析 | — | 1 | 0 | review | 0 | quality_missing |
| P15 | 分析失败 | — | 1 | 0 | review | 0 | analysis_failed |
| P16 | 人工已保留 | .90 | sim/3 | 1 | — | — | 不生成（manual_override） |
| P17 | 人工已淘汰 | .50 | sim/3 | 1 | — | — | 不生成（manual_override） |
| P18 | 小脸最佳 | .74 | sim/2 | 1 | keep | .70 | group_best, small_face |
| P19 | 小脸第二 | .62 | sim/2 | 1 | review | .61 | small_face, close_call |
| P20 | RAW/JPEG 单资产 | .70 | 1 | 0 | keep | .68 | single_shot |

P16/P17 不落库；P14/P15 的 score=0；review 的 conf 是 max(cKeep,cReject)，可高于 0.55（如 P12），用于区分“不确定”与“策略保护”。P06 走 exact 组（最高优先级），P01 才是 similarity 组最佳；样例表不改变“exact > similarity > visual > navigation”。表内 confidence 是 §4.1 公式的近似值，不是验收断言；测试只锁 verdict/理由/排序。

## 12. 任务拆解（T0-1..T0-9，24 PD）

| 任务 | 关键文件 | PD | 验收 |
|---|---|---:|---|
| T0-1 策略/文案规格 | 本文件、`x0-contracts.md`、`docs/ADR.md` | 1.5 | 规则/阈值/reasons 中英评审通过 |
| T0-2 Schema V3 | `SchemaV3.swift`、`MigrationV2ToV3.swift`、`SchemaCatalog.swift`、`SchemaVersion.swift`、`Schema.swift`、`SchemaV1+DDLDomain.swift` | 2 | V2→V3 迁移/回滚/形态测试；user_version=3 |
| T0-3 计算服务 | `Services/Triage/TriageService.swift`、`TriageEvaluator.swift`、`TriagePolicy.swift`、`Ports/TriageRepository.swift`、`Database/Repositories/TriageRepo.swift` | 4 | 纯函数 golden；确定性；20k<2s |
| T0-4 API | `Protocol/Triage.swift`、`API/Inputs/CullingInputs.swift`、`API/Outputs/CullingOutputs.swift`、`CullingAPI.swift`、`LiveCullingAPI.swift`、`AppServices.swift`、`FeatureAPIs.swift`、`PreviewAPIs.swift` | 3 | 契约测试；protocol strict + baseline |
| T0-5 建议卡 | `CullingTriageCard.swift`、`CullingToolbar.swift`、`CullingViewModel+Triage.swift` | 3 | 生成/应用/撤销/过期横幅 |
| T0-6 复核队列 | `CullingGrid.swift`、`CullingFilterControls.swift`、`CullingViewModel+Triage.swift` | 3 | review+confidenceAsc、键盘流、组内对照 |
| T0-7 安全 | `CullingService+Commands.swift`、`CullingService+Triage.swift`、确认 sheet、Beta 开关 | 1.5 | 不覆盖人工；不自动写盘；可撤销 |
| T0-8 评估 | `scripts/triage-eval/`、`docs/reviews/triage-eval-*.md` | 3 | 400 张标注、分层指标、Go/No-Go |
| T0-9 测试 | `gather-core/Tests/.../Triage*`、`gather-app/Tests/.../Triage*` | 3 | 边界/失效/幂等/性能/UI |
| **合计** | | **24** | |

## 13. 未决问题与推荐

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| 1 | 组内保留张数 | 只留最佳 1 / 留 2 / 可配置 | v1 只留最佳 1，其余 review；K 留 P1 |
| 2 | 相似/重复/导航优先级 | 相似优先 / 重复优先 / 质量优先 | 完全重复 > 相似 > 视觉重复 > 导航；同图只入一个最佳组 |
| 3 | 合影排名淘汰 | 允许 / 降为 review | 降为 review；硬技术失败仍可 reject |
| 4 | RAW/JPEG 代表 | RAW 优先 / 最高质量变体 | RAW 优先（与 Culling 代表行一致）；**v1 质量只取代表行，不回退变体**（代表行未分析→review）；P1 再评估回退 |
| 5 | 应用是否含 keep | 只 reject / keep+reject | 默认 keep+reject；提供“仅高置信度” |
| 6 | 指纹是否含人工决策 | 含 / 不含 | 不含；应用时跳过，避免建议过期循环 |
| 7 | 复核队列是否含低置信 keep/reject | 含 / 只 review | 只 review；低置信项已在生成时转 review |
| 8 | 闭眼升级 EAR | P0 / P1 | P0 只疑似；P1 用 Vision 眼部关键点（`Alignment.swift` 已有 leftEye/rightEye） |
| 9 | triage_enabled 默认 | 0 / 1 | 0（Beta）；内部构建可开 |
| 10 | 20k 超预算 | 优化 / 转 Job | 先优化 SQL；>2s 转 Job 并保留同步小样本 |
| 11 | review 行 confidence 是否截断到 0.55 | 截断 / 保留 max(cKeep,cReject) | 保留（可区分“不确定”与“策略保护”），UI 不显示裸值；若契约坚持 review≤0.55 则截断并接受排序粒度下降 |

## 14. 与 x0-contracts 的对齐与差异

已对齐（父代理确认）：`CullingSort.triageConfidenceAsc`、`CullingFilters.triageVerdicts` 已纳入契约；本文件按此实现。

需同步：
1. **TriageSummary 语义**：x0 只写返回类型名；本文定义 counts/stale/policyVersion/inputFingerprint/generatedAt，属细化，不冲突。
2. **policy_version**：x0 设置 `triage_policy=v1`；本文落库 `triage-v1`，映射写入 TriageService，不新增设置键。
3. **reasons_json**：x0 未定义结构；本文用 `[{"code","value"}]`，向后兼容空数组。
4. **人工决策排除**：x0 只说 apply 跳过；本文进一步“不生成建议行”，属超集，需在 x0 注明。
5. **review 的 confidence 语义**：x0 未定义；本文定义为“最高可执行置信度”，可 >0.55，需在 x0 与 UI 文案同步（否则会被误读为“低置信度”）。
6. **设置键改名**：`triage_review_confidence_max` → `triage_min_executable_confidence`（默认 0.55）；语义是“低于此值绝不执行”，review 可 >0.55。x0 草案与 `SettingsService.getDefaults()` 需同步改名，避免命名误导。
7. **无 TRIAGE_BUSY**：并发用事务串行化，不新增错误码。
