# Gather 功能性与易用性整改设计方案

- 版本：v1（2026-10-29）
- 输入：[功能性与易用性全量评审](../reviews/functional-usability-review-2026-10-29.md)（9 P1 / 14 组 P2 / 10 P3）
- 对象：features 分支 HEAD c77c3a57
- 性质：**设计提案，未改源码**。文中的类型名、API 名、文件路径均为拟新增/拟修改，不是现状。
- 目标读者：实现者、评审者、发布负责人。

---

## 0. 一页设计摘要

这套方案不追求“每条评审都加一个按钮”，而是先建立 **5 个不变量**，让同类问题不再复发：

1. **作用域显式**：任何批量/破坏性命令都必须携带一个可展示、可校验的作用域（当前张 / 显式集合 / 整个筛选结果），UI 显示的数量与服务端实际作用的对象必须同源。
2. **先预览、后提交**：所有写元数据的操作都产生带指纹的预览；提交时服务端重新计算指纹，不一致就拒绝，而不是“按旧预览写新数据”。
3. **根目录先于摄取**：任何“往工作区里加文件”的操作，都必须先有一个经过校验的工作区根目录；没有根就修复根，不允许把用户引向必然失败的路径。
4. **重置分级**：设置分为“偏好 / 用户内容 / 运行时 / 语言”，恢复默认只重置选中的级别；每个已知键必须被分类，漏分类的测试直接失败。
5. **长任务可观察、可中止、可恢复**：超过阈值的批量操作必须有进度、取消与可恢复的检查点；取消/失败必须留下“已完成什么”的记录。

在这 5 个不变量之上，方案分 7 条工作流（导入/摄取、选择/批量、预览/写回、设置、导出/交付、长任务、体验/DX），共 **不新增数据库表/列**、新增 **4 个协议方法**、**9 个新错误码（其余复用既有码）**、**2 个 Job 类型**，其余都是现有 API 的语义收口与 UI 重构。

---

## 1. 设计目标与约束

### 1.1 目标

- G1：修掉全部 9 个 P1，且每条都有可自动化的回归测试。
- G2：14 组 P2 按“同一交互模型”成组修，而不是逐页打补丁。
- G3：不引入 schema 变更；已有 user_version = 1 的库必须能直接打开。
- G4：继续遵守类型化 API（16 域 / 134 方法）、Confirmed<T>、无字符串命令、UI 不 import 持久化层。
- G5：中英文都可读；新增文案、错误码、复数形式一次做对。
- G6：性能目标明确：20k 选择批量 p95 < 4s；2k 张摄取有稳定进度；预览令牌 < 5ms。
- G7：开发者能在 30 分钟内“跑起来、看到 UI、找到 API 入口”，文档数字可被门禁验证。
- G8：所有变更可按 PR 独立回滚，不需要数据迁移或停机。

### 1.2 非目标

- 不做多根目录 / 多卷工作区（留给 schema v2）。
- 不重写导出/交付服务；只统一 UI 信息架构与确认流程。
- 不引入第三方依赖、不做 Web 端、不做云同步。
- 不在本轮实现真实照片集质量评估与 Capture One 实机验收。
- 不为了“设计完整”把 P3 全排进本轮；P3 进 backlog。

### 1.3 硬约束

- macOS 26+ / Swift 6.2+ / Swift 6 语言模式；UI 只依赖 GatherProtocol。
- 破坏性操作只接收 Confirmed<T>；API 实现不解析 Bool。
- 数据库 schema 不新增表/列；不引入迁移链。
- 新 API 方法必须走 check-protocol-surface.sh --allow-growth 并在台账记账。
- 新错误码必须同时补 GatherErrorCode、中文文案、en 文案、docs/README.md 计数；check-docs --strict 必须绿。
- 新 UI 文案必须补 en 表；计数文案必须支持单数。

---

## 2. 总体方案

### 2.1 五个不变量

| 编号 | 不变量 | 违反时的表现 | 强制手段 |
|---|---|---|---|
| INV-1 | 批量命令的作用域显式且与服务端同源 | “已选 5000，实际改 200” | BatchCommandPlan + expectedScopeHash，服务端拒绝不一致 |
| INV-2 | 写元数据前有带指纹的预览，提交时复算 | 解绑后旧关键词被写回 | PreviewToken + 模块 preview-stale 码 |
| INV-3 | 摄取/扫描前有校验过的工作区根 | 主 CTA 建出永远不能加照片的工作区 | WorkspaceRoot + setSourceRoot + 扫描 scope |
| INV-4 | 恢复默认只影响选中的设置级别 | 一次 reset 清空模板/配方/历史 | 设置键分类表 + 穷尽性测试 |
| INV-5 | 长任务有进度、取消、检查点 | 大卡导入像卡死、无法中止 | OperationCenter + Job checkpoint |

### 2.2 组件图

    GatherUI
      CullingSelectionModel / BatchCommandRouter / OperationBanner
      GallerySelectionModel / NoticeCenter / ExportHubView
      SourceRootBanner / PreviewPanel / ResetImpactSheet
        |
        | typed APIs (GatherProtocol)
        v
    GatherHost: Live*API + AppImport + SourceRootResolver
      setSourceRoot / updateSelection / previewReset / preflight
        |
        v
    GatherApplication: CullingService / SessionService / SettingsService
      scope hash / preview token / reset policy / job executors
        |
        v
    Persistence (schema unchanged) + Delivery + Analysis + Jobs

### 2.3 变更总览

| 工作流 | 主要变更 | 新增 API | 新增类型 | 覆盖 |
|---|---|---|---|---|
| 导入/摄取 | 目录导入走根；失败可见；摄取任务化 | SessionAPI.setSourceRoot | WorkspaceRoot, IngestJobCheckpoint | P1-1/2/3、P2-10 |
| 选择/批量 | 选择状态机、作用域哈希、跨页批量 | CullingAPI.updateSelection | CullingSelectionSnapshot, BatchCommandPlan | P1-6/7/8/9、P2-3/4 |
| 预览/写回 | 预览令牌、失效规则 | 无（输入加字段） | PreviewToken, WritebackPreview.previewToken | P1-4、P2-9 |
| 设置 | 分级 reset、影响面预览 | SettingsAPI.previewReset、reset(Confirmed) | SettingsResetPolicy, SettingsResetImpact | P1-5 |
| 导出/交付 | 范围 selected、交付预检、统一结果 | ExportAPI.preflightRun（可选） | ExportSelection, OutputRunPreflight | P2-1 |
| 长任务 | Job 扩展 + OperationCenter | 无（JobAPI 已有） | OperationState, OperationProgress | P1-3、P2-10 |
| 体验/DX | 通知类型、术语、复数、API 索引、日志 | PhotoAPI.select（可选） | Notice, SettingScope | P2-2/6/7/8/11-14、§6 |

### 2.4 为什么不需要 schema 变更

- 工作区根：复用 sessions.source_path；修复入口只 UPDATE 既有列，新增 SessionRepo.updateSourcePath。
- 选择/批量：选择快照是 UI 内存状态；服务端只接收 scope + filters + expectedHash 并重算，不需要持久化。
- 预览令牌：确定性哈希，不落库。
- 重置分级：设置键分类是代码常量，不落库。
- 导出所选：ExportOptions 增加可选 selectedPhotoIds，JSON 字段，不改表。
- 长任务：analysis_jobs 已是通用表，新增 job type 只是文本枚举 + executor；checkpoint 是 JSON。
- 结论：本方案可以在 user_version = 1 上完成；唯一需要“数据修复”的是历史空根工作区，走 UI 显式修复，不自动改库。

---

## 3. 横向基础设计

> 先做 §3.1–§3.4，P1 的大部分实现只是接线；否则会变成九处各自打补丁。

### 3.1 选择作用域与批量执行（INV-1）

#### 3.1.1 现状问题

- CullingViewModel 用两个独立状态 currentPhotoId 与 selectedPhotoIds，普通点击只改前者；commit 优先选后者（P1-6）。
- selectAllInScope 把 20k ID 放进 selectedPhotoIds，batchUpdate 再与已加载页求交（P1-7）。
- 相似组标题用已加载子集计数，服务端按完整组执行（P1-8）。
- 同一套裸键在 viewer / grid / 按钮三处各写一遍，U 的前进语义已经分叉（P2-3）。

#### 3.1.2 目标模型

拟新增 GatherUI/Culling/CullingSelectionModel.swift（@MainActor @Observable）：

    enum CullingSelectionMode: Equatable {
        case single(photoId: String)
        case explicit(ids: Set<String>, anchor: String?)
        case scope(CullingScopeSnapshot)
    }

    struct CullingScopeSnapshot: Equatable {
        let scope: CullingScope          // .all / .filtered / .similarityGroup
        let filters: CullingFilters?     // 仅 .filtered
        let groupId: String?             // 仅 .similarityGroup
        let ids: [String]                // 服务端返回的完整选择
        let idsHash: String              // 排序后 SHA-256
        let truncated: Bool              // 命中 20k 上限
        let loadGeneration: Int          // 页面代数；筛选/scope 变化即失效
    }

    struct CullingBatchPlan: Equatable {
        let target: BatchTarget          // .current / .explicit / .scope
        let total: Int
        let visibleCount: Int
        var requiresConfirmation: Bool { total > visibleCount }
    }

规则（必须与测试同名）：

1. 普通点击（无修饰键）→ mode = .single(id)，currentPhotoId = id；不再存在“当前照片之外还留着旧多选”。
2. Command/Ctrl 点击 → explicit 切换；anchor = 点击项。
3. Shift 点击 → 从 anchor 到目标的范围；网格与胶片条同一实现（当前胶片条 Shift 被当成切换，要改）。
4. Command-A → 调用服务端 selection；成功则 mode = .scope(snapshot)；截断时提示“仅前 20,000”。
5. 任何 scope/filters/sort/重新加载 → loadGeneration += 1，selection 清空；迟到的 selection 响应因 generation 不匹配被丢弃。
6. 决策键（P/X/U/0-5）统一走 BatchCommandRouter：
   - target = current：单张 update；
   - target = explicit：≤20k 直接 batchUpdate；>10k 走 scope 批量（理论上不会发生）；
   - target = scope：调用 updateSelection；
   - 若 total > visibleCount，先弹确认：“将把 P 应用到 5,000 张（其中 4,800 张不在当前视图）”，按钮 [应用到全部] [仅当前可见] [取消]；默认每次提醒，可选“本次会话不再提醒”。
7. 批量执行完成后保留选择，刷新状态；结果条显示“已应用 N 张 / 跳过 M 张 / 失败 K 张”，并提供撤销（历史操作 id）。

#### 3.1.3 服务端契约

拟新增（GatherProtocol/API/CullingAPI.swift + Inputs/CullingSelectionInputs.swift）：

    struct CullingSelectionUpdateInput {
        let sessionId: String
        let scope: CullingScope
        let filters: CullingFilters?
        let groupId: String?
        let expectedIdsHash: String
        let expectedCount: Int
        let limit: Int?              // 默认 20000；与 selection 同值
        let patch: CullingUpdatePatch
    }

    struct CullingSelectionUpdateResult {
        let requested: Int
        let applied: Int
        let skipped: [CullingBatchSkip]   // photoId, reason
        let failed: [CullingBatchFailure] // photoId, code, detail
        let historyOperationIds: [Int]    // 每个分块一个
        let truncated: Bool               // 命中 selection 上限（只处理前 N 张）
    }

服务端流程（CullingService+Commands.swift）：

1. 用与 selection 完全相同的查询与同一个 limit 重算 ID；排序后计算 hash。
2. hash != expectedIdsHash 或 count != expectedCount → 抛 CULLING_SELECTION_CHANGED，不写任何行；命中 limit 时结果 truncated = true（只处理返回的 N 张，UI 必须提前说明）。
3. 按 10,000/块切分（单事务上限），逐块调用现有 updateState/历史记录；每块提交后写 checkpoint（如果走 Job）或直接返回。
4. 任一块失败：停止后续块，返回已完成块 + 失败块；UI 显示“已应用 8,000/10,000，第 2 块失败”，保留可重试入口。
5. 历史：每块一个 history operation；撤销需要逐块（UI 显示“撤销本次批量（2 步）”），避免单条 20k entries 撑爆历史和长事务。

为什么不是“客户端分页调用 batchUpdate”：

- 客户端无法保证两次调用之间筛选/组没有变化，会出现“前 8k 改了、后 2k 基于新筛选”。
- 失败语义会变成“部分成功且无法解释”。
- 服务端重算 + 哈希校验能把“承诺/执行”绑在同一次请求里。

为什么不是“一次性 20k 单事务”：

- culling_history 会一次写 20k entries，undo 体验与 DB 体积都差。
- 长事务阻塞写入；10k/块是现有 batchUpdate 上限，风险最低。

#### 3.1.4 UI 改动

- CullingViewModel 删除 selectedPhotoIds 的公开读写，改为 selection: CullingSelectionModel；所有调用点通过 selection.ids/plan。
- CullingFilmstrip 普通点击 → selection.selectSingle(id)；Command/Shift 走统一手势处理器。
- CullingGrid 的键盘映射抽到 CullingKeyCommand + CullingKeyDispatcher；grid/viewer 共用，U 统一 shouldAdvance = false。
- 检查器“选择管理”增加：
  - “选择全部筛选结果（N）”按钮（仅 scope != all 或筛选非空时）。
  - 当前作用域 chip：“当前视图 200 / 已选 5,000”。
  - “仅保留可见选择”按钮。
- 多选时星级/色标显示混合态：SelectionSummary 计算 selected 的 rating/label 集合；若多值显示“混合”，点击写入全部；若用户只想改当前，提供“仅当前”切换。这样 P2-5 的“显示当前、写入批量”不再存在。

#### 3.1.5 边界与测试

- 跨页选择：200 已加载 + 4,800 未加载 → 确认 → updateSelection → 5,000 全落库；撤销两次。
- 筛选变化：确认框打开时筛选被改 → expectedHash 不匹配 → 无写入 + 可读提示。
- 20k 截断：选择返回 truncated → 只能对 20k 执行，界面明示。
- 单张：普通点击后按 X 只写一张。
- 网格/单图/检查器三处 U 行为一致：不前进。
- 性能：10k 块 p95 < 2s（本机 M 系列，Debug 允许 2 倍）；20k 两块 < 4s。

### 3.2 预览令牌（INV-2）

#### 3.2.1 现状问题

- WritebackPreview 只有 items/totalCount/affectedPhotos；没有身份。
- FaceWritebackInput 直接传 preview.items；绑定变化后旧 items 仍可提交（P1-4）。
- 相似度在分析中仍可基于旧 result 生成预览并写回（P2-9）。

#### 3.2.2 类型设计

拟扩展共享类型（Protocol/Core.swift，可选字段，向后兼容）：

    struct WritebackPreview {
        var items: [WritebackItem]
        var totalCount: Int
        var affectedPhotos: Int
        var previewToken: String?   // NEW：nil 仅兼容旧调用
        var generatedAt: String?    // NEW：诊断
    }

各写回输入增加：

    struct FaceWritebackInput {
        ...
        var expectedPreviewToken: String? // NEW
    }
    struct SimilarityWritebackInput { ...; var expectedPreviewToken: String? }
    struct MetadataApplyInput   { ...; var expectedPreviewToken: String? }

#### 3.2.3 令牌算法

PreviewTokenBuilder（GatherApplication，纯函数）：

    token = SHA256(canonicalJSON([
      module, sessionId,
      // face
      sortedClusters.map { [id, binding.roleName, sorted(binding.keywords), sorted(memberPhotoIds)] },
      options,
      // similarity: 不能只用 resultId（recluster 可能复用行 id）
      resultFingerprint = hash(resultId, createdAt, stats, sorted(groupIds+memberIds)),
      sorted(selectedGroupIds), sorted(keywords),
      // metadata
      templateId, fieldsHash, sorted(photoIds), policy
    ]))

- canonicalJSON 用 JSONEncoder.outputFormatting = [.sortedKeys]，与导出指纹同一套规范化纪律。
- 令牌只依赖“会改变写回结果”的输入；不依赖时间、UI 状态。
- preview() 返回 token；writeback() 在服务端重建当前状态并复算：
  - 不相等 → 抛模块对应的 preview-stale 码（FKW_PREVIEW_STALE / SIM_PREVIEW_STALE / METADATA_PREVIEW_STALE）。
  - 相等 → 正常执行。
- 兼容：旧客户端不传 token 时允许执行（记录日志）；新 UI 永远传。CI 加一条“所有 UI writeback 调用点必须传 token”的测试，防止回归。

#### 3.2.4 失效规则

- 人脸：bind/unbind/merge/split/removeMember 成功后 invalidatePreview()（preview = nil, writebackResult = nil, token = nil），并刷新；reload() 若 cluster generation 变化也清。
- 相似度：analysis/recluster 开始即 invalidatePreview()；结果 resultFingerprint（resultId + createdAt + stats + 成员集合）变化清；不能用 resultId 单值，recluster 可能复用行 id。
- 元数据：模板选择/字段编辑/目标照片集变化清；markWritebackDraftChanged 已有，统一到同一入口。
- 确认框：打开时冻结 PreviewSnapshot { token, itemCount, affectedPhotos, clusterCount }；执行只使用快照；若服务端返回 stale，关闭结果、提示“预览已过期，请重新生成”，不自动重试。

#### 3.2.5 测试

- 绑定 A → 预览 → 解绑 A → 提交旧 token → 必须 FKW_PREVIEW_STALE，XMP 不变。
- 预览 → 修改关键词 → 提交 → stale。
- 预览 → 无变化 → 提交成功。
- 令牌稳定性：同一状态两次预览 token 相同；不同状态 token 不同（property test）。
- 相似度：分析中 canPreviewWriteback == false；旧 token 提交 stale。

### 3.3 长任务：OperationCenter + Job 扩展（INV-5）

#### 3.3.1 分类原则

| 操作 | 是否落 Job | 理由 |
|---|---|---|
| 摄取 | 是（ingest.run） | 文件搬移、耗时长、崩溃后需要知道完成了哪些 |
| 模板套用 | 是（metadata.applyTemplate） | 可能几千张、写 XMP、需要进度与可撤销 |
| 人脸重聚类 | 是（复用 face.analyze + checkpoint operation=recluster） | 2 万人脸、CPU 重活、需要取消 |
| triage 生成 | 是（triage.generate，Wave 2 可选） | 20k 候选、CPU 重活 |
| 人脸写回 | 否（OperationCenter） | 走 delivery 队列、通常分钟级；先补进度/取消，不落 job |
| 相似度写回 | 否（OperationCenter） | 同上 |

写回类操作的进度来源：如果服务已有逐项回调（或能按 delivery items 计数）→ 确定性进度；否则用不确定进度（spinner + 已处理计数），并在每项之间检查 Task.isCancelled。需要确定性进度时，给 WritebackService.execute / FaceKwService.writeback 增加 onProgress 回调（可选参数，默认 nil），不新开 job。
| 元数据单张/小批 | 否 | 秒级；只补错误呈现 |

#### 3.3.2 统一 UI 模型

    enum OperationState: Equatable {
        case idle
        case running(OperationProgress)
        case succeeded(OperationSummary)
        case failed(CommandError)
        case cancelled(OperationSummary)
    }

    struct OperationProgress: Equatable {
        var current: Int
        var total: Int
        var phase: String       // 本地化 key
        var message: String?    // 仅诊断
    }

    protocol OperationHandle: AnyObject {
        var id: String { get }
        var state: OperationState { get }
        func cancel() async
    }

SwiftUI 只有一个 OperationBanner（进度条 + 当前/总数 + 阶段 + 取消 + 结果/重试），所有页面复用；不再各自用 isBusy = true 把整页变灰。

#### 3.3.3 Job 扩展

AnalysisJobType 不新增取值：analysis_jobs.type 带 CHECK 约束（见 SchemaCurrent+DDLCore），
新增 type 需要 schema 变更，与本设计的硬约束冲突。落地方式改为复用 checksum.backfill 载体：

- 摄取：type=checksum.backfill + checkpoint.operation="ingest"，dedupeKey="ingest.run:<session>:<请求指纹>"；
  展示层统一按 dedupeKey 前缀判定（AnalysisJobData.isIngestRun）。
- 模板批量应用仍走现有批量链路，未 Job 化。

旧 job 行不受影响。

ExecutorRegistry 新增两个 executor：

1. ingest.run：
   - checkpoint：sourcePaths、destinationRoot、renameTemplate、secondDestinationRoot、verifyChecksum、completed: [sourcePath]、failed: [{source, code, detail}]、phase。
   - 流程：plan → 逐项复制/校验 → 每完成 100 项写 checkpoint → 定期 onProgress。
   - 取消：每项前检查 isCancelled；返回 IngestResult 的部分结果，job 状态 cancelled（不是 failed）。
   - 恢复：completed 里的源路径直接跳过；目标已存在且 checksum 相同 → 跳过复制但仍执行登记；不同 → conflict。
   - checkpoint 在“复制+登记”都完成后才记 completed；崩溃在复制后/登记前 → 恢复时按目标存在 + checksum 相同走“只登记”分支，避免重复复制或漏登记。
   - 结果：SessionIngestResult 扩展 failures: [IngestFailureDTO]（sourcePath/destPath/code/detail/retryable）。
2. metadata.applyTemplate：
   - checkpoint：templateId、photoIds、applied: [photoId]、failed: [{photoId, code}]、batchId、policy。
   - 流程：逐张调用现有 MetadataTemplateService.applyFields（内部已是 8 并发 + 交付队列）；每完成一批写 checkpoint。
   - batch 语义：job 开始时创建 batchId；executor 按“已确认 applied 列表”增量追加 batch entry（新增 applyFields 的 resumeApplied/append 参数），确保取消/崩溃后 batch 记录与实际写入一致。
   - 取消：停止后续；已写部分保留，batch 记录只含 applied；UI 显示“已应用 X/N，可撤销”。
   - 恢复：applied 跳过；失败重试；batch 不重复追加已 applied 项。
3. face.analyze 的 recluster 分支：
   - FaceReclusterInput 在 executor 里通过 checkpoint operation=recluster 区分；progress 来自 FaceKwService.recluster(onProgress:)（新增参数，当前是 nil）。
   - 取消走 jobService.cancelScope(type: .faceAnalyze, scopeId: session)。

#### 3.3.4 取消语义

- 取消是“协作式”：服务在每项/每批前检查；已开始的文件操作不强行中断（避免半写文件）。
- 取消后 job 状态 cancelled，结果保留；UI 用中性色提示“已取消：完成 X/N”。
- 取消不能把已完成项回滚（除非用户显式撤销）；这是“可恢复”而非“原子”。

#### 3.3.5 测试

- 取消在 50%：已完成项保留，checkpoint 可续；重启后 job 续跑不重复登记。
- 崩溃在写 checkpoint 前：最多重复一项；靠 checksum/skip 幂等。
- 两个 ingest job 同 destination：dedupeKey 合并；第二个返回已有 job。
- 模板取消：batch 只含 applied；撤销不回滚未应用项。
- 取消 UI：不显示成功色；有“重试/查看已完成”入口。

### 3.4 工作区根目录（INV-3）

#### 3.4.1 现状问题

sessions.source_path 同时承担“扫描根”和“工作区边界”；文件导入把它留空，导致：

- 整目录重扫 noSourcePath；
- 摄取目标必须在 sourcePath 内 → 必然失败；
- 目录监听不启动。

#### 3.4.2 目标语义

- sourcePath 定义为工作区根目录：一个真实存在、已校验、包含工作区所有照片的目录。
- metadata.scan 的 requestedPaths 定义本次扫描范围；初始文件导入仍是显式路径列表，不因根目录而全树扫描。
- 两者分离后：根用于“能不能加文件/监听”，requestedPaths 用于“这次扫什么”。

#### 3.4.3 创建流程

| 入口 | 行为 |
|---|---|
| Command-N 新建工作区（目录） | root = 所选目录；扫描 scope = directory |
| 首屏/Command-O“导入文件夹” | 面板返回 .directory（不再枚举成 files）；root = 目录 |
| 文件多选导入 | 计算公共父目录；若存在且不是 forbidden root → root = 公共父目录；若公共父目录是 forbidden root 或文件跨卷 → 弹“选择工作区根目录”sheet；用户取消/无法选根时，显式创建 **path-scope** 工作区（sourcePath 为空）并显示“无根”banner，不静默 |
| 单文件导入 | root = 文件父目录；若父目录 forbidden → 弹根选择器；取消则显式 path-scope |
| Capture One 导入 | root = 选中照片的公共父目录；同样校验；否则让用户选根或显式 path-scope |

AppImport 的 SessionCreateInput 使用 sourcePath（已有字段）：能确定安全根时始终传根；文件列表仍走 filepaths。LiveSessionAPI.createWithFilepaths 改为“根 + 显式扫描集合”，无法确定根时走显式 path-scope 分支：

    createWithFilepaths:
      if let root = resolveSafeRoot(sourceRoot, filepaths) {   // 非空、包含全部文件、非 forbidden
          session.source_path = root
          job = metadataScan(sessionId, requestedPaths: filepaths, scopeKind: "paths")
      } else {
          session.source_path = ""
          job = metadataScan(sessionId, requestedPaths: filepaths, scopeKind: "paths")
          // UI 派生：sourcePath 为空 + 有照片 = path-scope（不需要新增列）
      }

sanitizeSessionSourcePath 从“只在恰好一个目录时保留”改为“校验根包含全部文件”；不允许静默返回空串——空串只能来自用户取消选根后的显式 path-scope。path-scope 工作区可以浏览/挑片，但摄取与整目录重扫入口禁用，并显示“设置根目录”修复入口。

#### 3.4.4 修复入口（历史空根工作区）

拟新增：

    struct SessionSetSourceRootInput { let sessionId: String; let sourceRoot: String }
    protocol SessionAPI {
        func setSourceRoot(_ input: Confirmed<SessionSetSourceRootInput>) async throws -> SessionData
    }

服务端校验：

1. 绝对路径、存在、是目录、canonical（ScanPath.canonical + symlink resolve）。
2. 不是 /、home 及其祖先（ScanPath.isForbiddenRoot）。
3. 不落在应用支持/缓存目录内（防把缓存当照片根）。
4. 工作区所有可见照片的 filepath 都在根内；否则拒绝并返回 WORKSPACE_ROOT_EXCLUDES_PHOTOS: count。
5. 更新 sessions.source_path，不触发扫描；UI 随后可“扫描整个根”。

为什么 Confirmed：改变根会改变后续扫描/摄取/监听范围，属于范围性变更；确认文案说明“将把 X 设为工作区根，之后可摄取/重扫；不会移动文件”。

#### 3.4.5 UI

- 无根会话：控制中心/图库顶部常驻 warning banner：“此工作区没有根目录，无法摄取或重扫。” + [设置根目录…]；摄取入口禁用并显示原因。
- 有根：显示根路径（可复制、可在 Finder 打开）。
- 修复成功后：提示“已设置根目录；现在可以摄取或扫描整个目录”，刷新状态，并对当前 workspace 调用 SessionDirectoryMonitor.start（构造时 root 为空不会启动；修复后必须补启动）。
- 扫描菜单拆成：
  - “扫描新增/变更”（使用保存的 scope：paths 或 directory）。
  - “扫描整个工作区根…”（显式，显示根路径 + 预计范围；确认后 requestedPaths = nil）。

#### 3.4.6 扫描 checkpoint

JobCreateParams.metadataScan 增加可选 scopeKind：

    checkpoint = [
      "scopeKind": "directory" | "paths",
      "requestedPaths": [...] // paths 时
    ]

- 旧 job 无 scopeKind：requestedPaths 非空 → paths；否则 directory（兼容）。
- “重试索引”读取最近 job 的 scopeKind，不再一律 nil。
- SessionDirectoryMonitor 只在 root 非空且存在时启动；事件入队时用 directory 范围（因为根已定义工作区）。
- **默认策略**：目录导入的工作区默认开启监听；文件导入派生根 / path-scope 的工作区默认**关闭**监听（避免把公共父目录里的无关照片吸进来），UI 提供“监听此根目录”开关与说明。修复根成功后也不自动开启，除非用户明确勾选。
- 如果用户不希望全树扫描，可在设置里关闭监听。

#### 3.4.7 边界

- 卷离线：根存在性检查失败 → banner “根目录不可用”，禁用摄取/扫描，保留数据。
- 根被移动/改名：照片离线；提供“重新定位根目录”留作 backlog（schema v2 或多根）。
- 符号链接：根用 resolvingSymlinksInPath；照片路径必须 canonical within root；防止逃逸。
- 根与另一工作区重叠：允许但警告；扫描/摄取仍以本工作区为准。

### 3.5 通知与错误模型

#### 3.5.1 问题

- 取消写成 success 色；notice 常驻；错误文案有 raw String(describing:)；CommandError 在不同页面各自 parse。

#### 3.5.2 设计

    enum NoticeKind { case success, info, warning, error }

    struct Notice: Equatable {
        var text: LocalizedText
        var kind: NoticeKind
        var timeout: Duration?   // success/info 4s；error nil
        var action: NoticeAction? // retry / reveal / openLog
    }

- 现有 CullingNotice/FaceNotice/SimilarityNotice 保留为 typealias/构造器，内部带 kind；新增文案默认 .info。
- NativeBanner 按 kind 取色/图标；success/info 可自动消失；error/warning 常驻并提供 action。
- 所有 String(describing: error) 改 CommandErrorText.resolve(error, with: l10n)；原始 detail 只进 .help 与日志。
- 新增 CommandError 的“恢复动作”字段（可选）：recovery: RecoveryAction?（retry / openSettings / chooseRoot / regeneratePreview / reveal）。UI 渲染按钮；服务端错误只给 code，UI 映射。

### 3.6 本地化、复数与术语

#### 3.6.1 复数

- 所有“数量 + 名词”的 UI 文案统一走 l10n.plural(key, count:)；en 表补 #one。
- 新增测试 PluralCoverageTests：
  - 扫描 UI 源码里 format(".*%lld.*") 且 key 含计数名词的调用点，若不在 plural 白名单 → 失败。
  - 扫描 en 表：含 %lld/%d 且名词可数的 key 必须有 #one（allowlist 记录“星级/百分比”等不可数）。
- 修复现有 “1 items / 1 photos / 1 XMP conflicts”。

#### 3.6.2 术语

- 用户文案统一“工作区/Workspace”；代码保留 Session。
- 新增 docs/TERMINOLOGY.md（用户术语 vs 代码术语 vs 英文），并在 LocalizationParityTests 里加一条：含“会话”的新 key 必须命中 allowlist（历史兼容），新增默认失败。
- 导航组改称“连拍分组 / 场景分组”，Burst/Scene 只在英文技术说明中出现；入口从筛选区移到“分组”section，附一句解释。

#### 3.6.3 本地化门禁

- 新错误码 → 自动检查 en/zh 成对。
- 新文案 → en 表必须存在。
- 新增 check-ui-copy.sh：检测 Text("...Han...") 未走 l10n 的新增行（allowlist 旧代码）。

---

## 4. P1 详细设计

> 每条按“现状 → 目标 → 改动 → 边界 → 测试 → 验收”展开；复用 §3 的能力只写差异。

### 4.1 P1-1：导入文件夹必须建出有根工作区

**目标行为**：用户从首屏/Command-O 选择一个目录，得到一份“目录工作区”（root = 该目录），可以重扫、监听、摄取；与 Command-N 完全一致。

**改动**

1. GatherAppDelegate.chooseImportFolder：目录选择始终返回 .directory(directory)；删除“枚举出照片就返回 files”的分支。文件级导入只保留给 Finder 拖入/打开文件/deep-link。
2. AppImport.importFiles：文件列表路径必须同时计算并校验 root（§3.4.3）；无法得到安全 root 时，弹出“选择工作区根目录”sheet；用户取消则显式进入 path-scope（sourcePath 为空 + 无根 banner），而不是静默建“看起来正常”的空根。目录导入（首屏/⌘O）永远走目录分支，不需要这一步。
3. SessionService.createFromDirectory：行为不变；createWithFilepaths 改为“root + explicit paths”。
4. SessionWorkspaceFactory：root 非空才启动目录监听；空根会话显示修复 banner。
5. SessionRepo 新增 updateSourcePath(id:path:)；SessionService.setSourceRoot 实现 §3.4.4。
6. SessionAPI.setSourceRoot 新增；LiveSessionAPI 实现；AppServices 暴露；UI 调用。

**边界**

- 目录包含 0 张支持照片：仍建 root；若扫不到照片，显示“未发现支持的照片”，让用户换目录；避免“空目录被当成新建表单”的歧义。
- 目录是 forbidden root（/、home）：拒绝并提示选择子目录。
- 卷离线：建库可以，但 root 检查失败 → 工作区标记“根不可用”，不删数据。

**测试**

- 目录导入 → session.sourcePath == dir；metadata.scan checkpoint scopeKind=directory。
- 文件多选导入 → source_path 为空（path-scope）；初始扫描只扫所选文件，不全树；显式设置根后 root = 该目录。
- 无根历史会话 → 设置根成功/失败（照片在根外）两条路径。
- 首屏 CTA → 控制中心“扫描”不报 noSourcePath；摄取默认目标可执行。

**验收**：见评审 P1-1 的复现路径。

### 4.2 P1-2：导入失败必须可见

**目标**：任何导入入口失败都有 toast/banner，带可读原因与恢复动作。

**改动**

1. 新增通知 GatherAppNotification.importFailed，userInfo 携带 CommandError 的 code/params 或 LocalizedText。
2. AppImport.importFiles catch 里 post；RootShellOverlay 监听并显示 Notice(kind: .error, action: .retryImport)。
3. RootShellDependencies.importFiles 保留 fire-and-forget；通知是唯一出口，避免改调用方签名。
4. 成功但 0 张：importCompleted 增加 addedCount == 0 分支，toast “未导入照片（不支持的格式/目录为空）”。
5. 失败 toast 提供 [重试]（重放同一文件列表）与 [导出诊断包]。

**测试**：注入 fail 的 SessionAPI.create → 通知发出；UI 显示 error notice；重试按钮再次调用。

### 4.3 P1-3：摄取面板的完整重做

**目标**：可见进度/取消；错误可读；面板不阻塞；无根时不给死路。

**改动**

1. 入口：从 CullingInspector 的“摄取照片…”上移到文件菜单/工作台（“从存储卡摄取…”），挑片页保留快捷入口；无根时禁用并显示“先设置工作区根目录”。
2. IngestSheet 重构：
   - 用 OperationState 显示进度/取消。
   - 源/目标/模板/第二目的地/校验五块，默认目标 <root>/_ingest。
   - 三个面板改 panel.begin（或 await panel.begin()）。
   - 错误走 CommandErrorText.resolve。
   - 结果分三组：已登记 / 跳过（含原因）/ 失败（含 code/detail/retry），可滚动、可复制、可在 Finder 显示。
   - 关闭时若任务运行 → 确认“取消摄取？”。
3. 服务端：ingest.run job（§3.3.3）；SessionIngestResult 增加 failures；IngestFailureDTO。
4. 无根：IngestSheet 打开时若 session.sourcePath.isEmpty，显示“先设置根目录” action，直接打开根选择器；不显示手选目标的空输入。

**边界**

- 同名冲突：不覆盖；结果标 conflict，用户可改模板后重试。
- 第二目的地失败：主副本保留，单张回滚第二副本；结果说明。
- 取消：已复制项保留并登记？设计：取消后只登记已完成且校验通过的项，job 结果标注“部分”；未登记项留在 _ingest，重试时按 checksum 去重。

**测试**：1000 项进度/取消；目标冲突；第二目的地失败；无根；checkpoint 恢复。

### 4.4 P1-4：人脸写回预览失效

**改动**

1. §3.2 的 token；FaceKwService.preview 计算 token；writeback 校验。
2. FaceKeywordingViewModel：
   - invalidatePreview()。
   - bind/unbind/merge/split/removeMember 成功后调用。
   - reload() 比较 cluster generation（新增 clusterRevision 由 service 返回或本地 hash）后清。
   - 确认框使用 PreviewSnapshot，显示 token 对应的 itemCount/affectedPhotos。
3. UI：预览区显示“预览于 HH:mm · N 项”；若用户修改绑定，预览区立即消失并显示“绑定已变化，请重新生成预览”。
4. 错误：FKW_PREVIEW_STALE 文案“预览已过期（绑定或关键词已变化）。请重新生成预览后再写回。”；UI 清预览并聚焦“生成预览”。

**测试**：见 §3.2.5；另加“解绑后预览面板消失”。

### 4.5 P1-5：恢复默认分级

**改动**

1. SettingScope 分类表（§5.7）：
   - .preference：模型路径、阈值、缓存、并发、db、write mode、grid、triage 参数等。
   - .userContent：metadata.templates、metadata.applyBatches、output.recipes、output.deliveryRoot、backup_dir。
   - .runtime：watch.lastEventIDs、*.corrupt。
   - .language：ui_language。
   - .secretRef：WebDAV 凭据（不在 settings，reset 不触碰）。
2. SettingsAPI.previewReset() -> SettingsResetImpact：count templates/batches/recipes；不读 secret。
3. SettingsAPI.reset(_ input: Confirmed<SettingsResetInput>) -> SettingsResetResult；旧无参 reset() 删除或标 deprecated（内部调用默认 .preference）。
4. SettingsService.reset(scopes:)：只写选中 scope 的 keys；.runtime 总是清理；返回 reset/preserved。整个 reset 必须在**单个 SettingsRepository 事务**内完成（或先算出全部写入再批量提交），任一步失败回滚，避免“偏好重置了、用户内容没清”的半状态。
5. UI：
   - “恢复默认”打开 ResetImpactSheet：
     - [x] 偏好设置（N 项）
     - [ ] 用户内容（M 个模板 / K 条批次 / R 个配方）——默认不勾选，勾选后二次确认
     - [ ] 界面语言（默认保留）
   - 确认按钮文案随选择变化；用户内容勾选时红色 destructive + “不可恢复”。
   - 提供 [先导出用户内容…]：把模板/配方/批次历史导出为 JSON（复用导出报告/诊断包的写文件路径），导出成功后才允许勾选清除；不强制，但默认引导。
6. 语言：若勾选重置语言，applyResetSettings 先 languageStore.set，再重载；否则保留。
7. 测试：SettingScopeCoverageTests 断言每个 knownSettingKeys 恰有一个 scope；reset(preference) 后模板/配方/批次仍在；reset(userContent) 只清这些；language 行为。

### 4.6 P1-6：胶片条普通点击清空多选

**改动**

- §3.1 的 CullingSelectionModel；CullingFilmstrip 普通点击 → selectSingle；Command/Shift 走统一处理器。
- 删除 selectCurrent 只改 current 的旁路；所有“当前照片”变更都通过 selection model，保证 current ∈ single 或 explicit（显式取消选择除外）。
- 检查器/查看器显示“当前 / 批量 N”状态；批量时决策按钮文案带“应用到 N 张”。

**测试**：Command 选 3 → 单击第 4 → X → 只有第 4 张变；头部选择数 1；撤销恢复。

### 4.7 P1-7：跨页全选批量

**改动**

- §3.1 的 updateSelection + 确认 + 分块 + 结果。
- selectAllInScope 返回 CullingScopeSnapshot（含 hash/truncated）；UI 选择状态显示“整个筛选结果”。
- 批量决策不再与 page.assets 求交；如果服务端返回 CULLING_SELECTION_CHANGED，清选择并提示。
- 历史：每块一个 operation；结果条“撤销本次批量（2 步）”。

**测试**：3 页 5,000 张全选 → P → 5,000 落库；中间筛选变化 → 无写入；截断 20k → 提示；每块失败 → 部分结果。

### 4.8 P1-8：相似组决策的真实影响面

**改动**

1. CullingInspector 的组标题改用 similarityGroups 的完整成员数；若未加载，打开组决策时先 loadSimilarityGroupsIfNeeded(force: true)；显示“相似组 · 30 张（当前视图 2 张）”。
2. 新增 PendingCullingAction.resolveGroup(group, keepIds, totalCount)；确认文案列出保留 1 / 淘汰 N-1，并显示前 3 个被淘汰文件名。
3. keepInGroupRejectRest 只在确认后调用；keepValid 用完整组计数。
4. 组只剩 1 张可见时，入口仍显示（用完整组计数判断），不消失。

**测试**：跨页组 30 张/可见 2 张 → 标题 30；点击 → 确认显示淘汰 29；取消无写入；确认后服务端 30 张落库。

### 4.9 P1-9：布局无关的同步入口

**改动**

1. 抽 CullingSyncControls（菜单：立即写入 / 写回评分/色标/关键词 / 加载元数据 / 已加载 / 重试失败 / 保留 XMP / 恢复原 XMP）+“重置挑片”按钮。
2. 放到 CullingToolbar 的 overflow/同步按钮；CullingInfoBar 只保留计数/翻页/状态，不再承载动作；网格布局也显示同一 toolbar。
3. 冲突面板/失败清单仍浮在右下，任何布局可见。
4. 菜单项禁用态由 syncStatus 驱动（已存在）。

**测试**：三种布局（单图/对比/网格）都能打开同步菜单并执行写回；截图验收。

---

## 5. P2 设计

### 5.1 导出与整套交付（P2-1）

**信息架构**

- 页面顶部 Segmented：“快速导出” / “整套交付”。
  - 快速导出 = 现有计划导出（范围/格式/命名/水印/XMP/预览/结果）。
  - 整套交付 = 配方/联系表/画廊/WebDAV；共享“范围”选择器（同一 ExportRangeSelection）。
- 两模式不能同时运行；开始一个时另一个禁用并说明。

**范围**

- ExportOptions 增加 selectedPhotoIds: [String]?。
- OutputRunInput 同样增加 selectedPhotoIds: [String]?（整套交付与快速导出共享范围）；OutputService 逐配方构造 ExportOptions 时必须透传，否则交付会忽略 selected。
- 两个输入的字段都参与交付指纹；范围/选择变化 → 新交付身份，不继承旧完成清单。
- UI 增加“所选照片（N）”；进入导出页时若携带选择意图（图库/挑片选中）→ 默认 .selected；否则保留片 >0 → .filtered；否则 .session。
- ExportService.filteredPhotos 的 .selected 分支：校验 ID 属于 session/可见/≤20k；指纹包含 IDs。
- 错误复用 EXPORT_PARAMS_INVALID（field=selectedPhotoIds）：空/越界/不属于会话。

**交付预检**

- OutputService.preflight(input) -> OutputRunPreflight：解析配方目标、统计每配方照片数/预计文件数/空间/冲突，不写文件。
- 确认 sheet 显示：配方数、总照片、物理文件、预计空间、联系表/画廊、目标目录、将跳过项；Confirmed<OutputRunInput> 只在确认分支构造。
- 预检 = 计算型操作，放 OperationCenter（可取消）。

**结果与 notice**

- 统一 DeliveryResultView：成功/失败/跳过总数；失败清单分页；[重试失败项] [在 Finder 显示] [导出 CSV 报告]。
- notice 动作开始时清空；取消用 .info/warning；成功/失败用对应色；瞬态 notice 自动消失。

**测试**

- 10 张选择 → 导出页默认 selected → 只写 10 张；预览/确认/实际数量一致。
- 交付无确认不能执行；确认后的快照与执行一致；取消显示部分结果。
- 两个模式互斥。

### 5.2 图库键盘与多选（P2-2）

**选择模型**

- GallerySelectionModel：ids, anchor, mode（single/explicit/scope）。
- 网格加 @FocusState + onKeyPress：方向键移动、Space 切换、Return 打开灯箱、Command-A 全选、Esc 清空。
- 选择栏常显（有照片时）：已选 N + 全选/取消 + 批量动作。
- 全选语义：
  - 新增 PhotoAPI.select(PhotoSelectionQuery) -> PhotoSelectionIds（20k 上限 + hash）；“全选筛选结果”用它。
  - 若暂不新增：文案改“全选已加载（N）”，并禁止“全选全部”的误导。
- 批量动作（至少）：导出所选（.selected）、在灯箱中比较、批量元数据（打开 MetadataBatchSheet 并带 selected ids）、在 Finder 显示。
- 2 张以上时检查器显示“已选 N 张”摘要与批量动作，不显示单张元数据。

**测试**：键盘导航/选择；零选中可见全选；全选跨页（若 API）或文案准确；导出所选只导所选。

### 5.3 挑片交互一致性（P2-3/4/5）

- 多选混合态（§3.1.4）。
- 对比：优先 selection.explicit 的 2/4 张；否则当前 ± 相邻；显示“主图/对比对象”。
- U：统一不前进；CullingKeyCommand 单源。
- 紧凑工具栏：加入取消（与完整档同一 action）。
- 查看器焦点：@FocusState + .focused + onAppear；工具栏动作后 viewerFocus = true；手工验收。
- 筛选 scope：离开 filtered 时清空 filters 并显示“已清除 2 项筛选”；空态加 [清除筛选]；检查器显示 active filter chip。
- 质量分析：isBusy 拆成 isPageLoading 与 isQualityRunning；质量运行时保留决策/撤销；开始按钮用 qualityJob 活跃态禁用，避免重复建单；紧凑档取消。

### 5.4 元数据、人物、重复、相似度（P2-6/7/8/9）

- 元数据草稿：MetadataEditorDraft 已有 changedCount；关闭时 dirty → 确认；草稿留在 workspace（按 photoId）直到保存/丢弃；模板字段同。
- 错误：统一 CommandErrorText；批量错误列表可滚动 + 复制。
- 批次列表：一行名称（triage 用“技术建议写回 · 原名”）；日期走 DisplayDateFormatters + l10n.locale。
- 人物：合并 sheet（目标 + 影响计数 + 确认）；照片格“移除此照片”；复用现有 API。
- 重复：resolveMember 事务内 syncGroupResolutions；新增 resetGroup（resolution=NULL, isKept=1）与 [恢复未处理]；UI 刷新 groups。
- 相似度：分析/聚类中禁用写回；preview token（§3.2）；结果代际变化清预览。

### 5.5 长任务（P2-10）

- §3.3：ingest/template/face recluster 任务化；OperationBanner。
- 摄取去重：photoChecksums(sessionId:sourceSizes:) 只对 size 匹配的存量照片哈希；结果回填 photos.checksum；哈希失败作为失败项上报。
- import_concurrency：用 withTaskGroup 做 bounded 并发（默认 8，1...32）；NaN/∞ → 1 + warn；进度回调。
- 模板套用：进度 + 取消；batch 只含 applied。

### 5.6 设置、C1 预检、帮助、首跑（P2-11/12）

- C1 预检：四层分别显示（可达/运行/文档/自动化），每层失败给 next action；lastError 进 tooltip/复制诊断；[打开系统设置 → 隐私与安全性 → 自动化] 按钮。
- 帮助菜单：新增“快捷键与手势”“故障排查”“打开日志/诊断包”；GitHub 保留。
- 首跑：C1 卡片动作改 captureOneImport；若 C1 不可用 → 预检 sheet + “去设置”；或 hero 加第三 CTA。
- 导航组：改“连拍分组 / 场景分组”，移到工具栏“分组”菜单，加一句解释；保留 Burst/Scene 作为英文技术副标题。

### 5.7 本地化与术语（P2-14）

- §3.6。
- 配方默认名：l10n.format("配方 %lld", index)；默认配方 Web 2048/Print TIFF 可保留为产品名，但加中文说明。
- 取消/警告 notice 用 kind。
- 英文单复数全量修复；新增复数 lint。

---

## 6. 开发者体验设计

### 6.1 API 索引与文档

- 新增 scripts/generate-api-index.sh：解析 *API.swift 的 protocol + ///，生成 docs/api-index.md（域/方法/一句话/错误码）。
- check-protocol-surface.sh 增两件事：
  1. 校验每个 *API.swift 头注释的方法数与实际一致。
  2. 校验 docs/api-index.md 与源码同步（生成后 diff 为空）。
- 新增 check-api-docs.sh：统计 134 个方法的紧邻 /// 覆盖率，基线 39，只许升不许降；新增方法必须带 doc。
- 删/改过期头注释（110/21/4 → 实际）；APIContractIndex 由生成脚本维护，不再手写数字。

### 6.2 Confirmed 与返回值

- SettingsAPI.reset 改为 reset(_ input: Confirmed<SettingsResetInput>)；VM 只接受 Confirmed。
- 新增 DestructiveAPIInventoryTests：枚举所有破坏性方法名/输入，断言签名包含 Confirmed；新增遗漏即失败。
- Bool → 显式结果：
  - JobAPI.retry/cancel → JobMutationOutcome { accepted, outcome: retried/cancelled/notFound/notRetryable }。
  - ExportAPI.cancel → CancelOutcome { cancelledJobs }。
  - 其余 10 个 Bool 至少 @discardableResult + 文档 + 调用点处理 false（假成功修复）。
- UI 文案改为“已请求重试”，并在 false 时给“任务已不存在/不可重试”。

### 6.3 错误码与批量语义

新增错误码（预设 9 个；其余复用既有码）：

- CULLING_SELECTION_CHANGED
- FKW_PREVIEW_STALE / METADATA_PREVIEW_STALE（相似度复用既有 SIM_PREVIEW_STALE）
- WORKSPACE_ROOT_EXCLUDES_PHOTOS（根无效复用 SESSION_SOURCE_NOT_DIR / SESSION_SOURCE_ROOT_FORBIDDEN）
- TEMPLATE_NOT_FOUND / TEMPLATE_BATCH_NOT_FOUND / TEMPLATE_BATCH_ALREADY_UNDONE
- DUP_GROUP_NOT_FOUND / DUP_MEMBER_NOT_FOUND

导出 selected 的非法参数复用 EXPORT_PARAMS_INVALID；取消不新增码（Job 状态 + CancellationError/JobCancelledError）。每加一个同步 195→N、en 表、docs。

- 域错误实现 CodedError；API 边界只允许 GatherError；check-coded-errors 加“协议方法实现不得抛裸 Error”的测试。
- 批量语义统一：
  - BatchOutcome { requested, applied, skipped, failed }。
  - 文档标注 atomic（culling batchUpdate）vs partial（template/ingest）。
  - UI 必须展示 skipped/failed 明细。

### 6.4 构建、运行、文档

- 新增 scripts/run.sh：CONFIGURATION=debug ./desktop/native/build.sh && open release/Gather.app；README Quick start 加“Run the app”。
- 修 README：129→134、15→16、V5→v1、CONFIGURATION 默认 release 的表述。
- 修 DEVELOPMENT：测试命令路径（根目录执行）；加“新增 API/错误码/文案”的清单。
- 功能文档：WebDAV、联系表/打印、客户校样、水印、智能相册、导航分组、备份/恢复/诊断各一节；ROADMAP 更新到当前 Cut。
- check-docs 增加：方法数/target 数/schema 版本号的模式校验，失败给文件:行号。

### 6.5 日志与可观测性

- GATHER_LOG_LEVEL 环境变量/defaults 键；启动读取；设置页加“显示日志”“打开日志文件夹”。
- 日志路径写入 README/DEVELOPMENT 与诊断包 manifest。
- 20 处 debug 日志在 info 下不输出：加“日志级别”设置后可开；或把关键链路升为 info。

### 6.6 死面与政策

- 模型下载器：二选一——删掉 ModelInstaller/确认/VM（约 300 行），或加“下载模型”按钮 + SHA256 校验 + 取消。推荐删掉，模型随包分发已满足。
- Persons merge/removePhoto：加 UI（§5.4）。
- runModal：全部改异步 panel（Ingest/Maintenance）。
- DecisionButtonView.key 死参数删除；菜单 Undo 状态用 undoOperation != nil && !isBusy。
- check-design-system / check-cleanup-ratchet 的 baseline 写入加“上涨需 --allow-growth”守卫。

---

## 7. 正确性 review

### 7.1 不变量与强制点

| 不变量 | 服务端强制 | UI 强制 | 测试 |
|---|---|---|---|
| INV-1 作用域 | expectedHash/count 不符拒绝 | 确认框显示真实数量 | 选择变化/跨页/截断 |
| INV-2 预览 | token 复算不符抛 stale | 变更即清预览 | 解绑/改关键词/分析中 |
| INV-3 根 | 根校验 + 照片包含校验 | 无根 banner/禁用入口 | 目录/多文件/修复/越界 |
| INV-4 重置 | scope 白名单 | 分级确认 | 穷尽分类/保留/清空 |
| INV-5 长任务 | job checkpoint + cancel | 进度/取消/部分结果 | 50% 取消/重启恢复 |

### 7.2 并发与竞态

- 选择 vs 执行：expectedHash 在服务端重算；不匹配 → 0 写入。
- 预览 vs 绑定：token 在服务端重算；不匹配 → 0 写入。
- 两批 ingest 同目标：job dedupeKey + 目标文件 O_EXCL/临时 rename；已存在且不同 checksum → conflict，不覆盖。
- reset vs set：SettingsService.lock 串行；reset 返回实际写/保留键；UI 重载。
- 批量 vs 单张：revision/expectedRevision 冲突 → 该块失败，返回失败列表；不静默重试。
- Job cancel vs complete：first-wins 终态（现有）；取消后迟到结果丢弃。

### 7.3 失败矩阵

| 场景 | 期望 | 禁止 |
|---|---|---|
| 选根时卷离线 | 可读错误 + 保留工作区 | 清空 sourcePath |
| 摄取中途磁盘满 | 已完成项保留 + 失败项 code | 回滚已完成文件 |
| 模板取消 | 已应用项可撤销 | 把未应用项写进 batch |
| 交付预检失败 | 不启动 job，显示原因 | 半启动后报错 |
| 写回 token 过期 | 清预览，要求重生成 | 自动用旧 items 重试 |
| 全选跨页时筛选变化 | 拒绝并提示重新选择 | 按旧选择写入 |

### 7.4 安全

- 所有根/目标路径：canonical + symlink resolve + isForbiddenRoot + isWithin；拒绝 /、home、应用支持、缓存。
- 摄取目标必须在根内；第二目的地不得与根/目标重叠。
- 导出 selected IDs 必须属于 session 且 visible；防止任意 photoId 读取。
- WebDAV 凭据仍只进 Keychain；日志/诊断不输出密码。
- 预览 token 不包含敏感信息（只 hash）。

### 7.5 兼容性

- WritebackPreview.previewToken/输入 expectedPreviewToken 为可选字段：旧调用可解码；新服务端遇到 nil 允许（记录），新 UI 必须传。
- ExportOptions.selectedPhotoIds 可选：旧 JSON 解码为 nil。
- metadataScan checkpoint 新键可选：旧 job 无 scopeKind 按 requestedPaths 推断。
- 新 job type 是文本：旧版本遇到未知 type 时，AnalysisJobType 解码会失败。设计说明：本方案假设单版本升级；若需双版本兼容，先给 enum 加 unknown(String)（较大改动，另行评估）。
- 设置 reset 签名变化：仅内部协议，无外部客户端。

---

## 8. 完整性 review

### 8.1 评审项 → 设计章节

| 评审项 | 设计章节 | 覆盖方式 |
|---|---|---|
| P1-1 导入无根 | §4.1、§3.4 | 目录走根 + 修复 API |
| P1-2 导入静默 | §4.2、§3.5 | 失败通知 + toast |
| P1-3 摄取面板 | §4.3、§3.3 | 任务化 + UI 重做 |
| P1-4 人脸预览 | §4.4、§3.2 | token + 失效 |
| P1-5 reset | §4.5、§3.5 | 分级 + 影响面 |
| P1-6 胶片点击 | §4.6、§3.1 | 选择状态机 |
| P1-7 跨页全选 | §4.7、§3.1 | updateSelection |
| P1-8 相似组 | §4.8、§3.1 | 完整组计数 + 确认 |
| P1-9 网格无同步 | §4.9 | 布局无关工具栏 |
| P2-1 导出/交付 | §5.1 | 双 tab + 预检 + selected |
| P2-2 图库 | §5.2 | 键盘 + 批量动作 |
| P2-3 挑片交互 | §5.3 | 混合态/对比/U/焦点 |
| P2-4 筛选 scope | §5.3 | chip + 清除 |
| P2-5 多选显示 | §3.1.4、§5.3 | 混合态 |
| P2-6 元数据/模板 | §5.4 | 草稿 + 错误 + 日期 |
| P2-7 人物 | §5.4 | 合并/移除 |
| P2-8 重复 | §5.4 | sync + reset |
| P2-9 相似度写回 | §5.4、§3.2 | 禁用 + token |
| P2-10 长任务 | §3.3、§5.5 | job/operation |
| P2-11 C1 预检 | §5.6 | 分因 + 动作 |
| P2-12 帮助/首跑 | §5.6 | 帮助 sheet + C1 CTA |
| P2-13 导航组 | §5.6、§3.6 | 术语 + 位置 |
| P2-14 本地化 | §3.6、§5.7 | 复数/术语/颜色 |
| DX 1 API 文档 | §6.1 | 生成索引 + ratchet |
| DX 2 Confirmed/Bool | §6.2 | reset Confirmed + 结果类型 |
| DX 3 错误码 | §6.3 | 新码 + CodedError |
| DX 4 文档/构建 | §6.4 | run.sh + 数字修正 |
| DX 5 日志 | §6.5 | 级别/路径/入口 |
| DX 6 死面/政策 | §6.6 | 删除/接线 |

### 8.2 测试覆盖矩阵

| 层 | 新增测试 |
|---|---|
| 协议/输入 | CullingSelectionUpdateInputTests（hash/count/上限）、ExportSelectionTests、SettingsResetInputTests |
| 服务 | 选择重算/哈希不符、预览 token 复算、reset scope、根校验、ingest checkpoint、模板取消、duplicate sync |
| UI VM | 普通点击清多选、跨页确认、混合态、预览失效、reset impact、错误文案 |
| 集成 | 目录导入→扫描→摄取；文件导入→设根→摄取；20k 选择批量；取消/重启恢复 |
| 本地化 | 新错误码成对、复数 lint、术语 allowlist |
| 门禁 | API 索引同步、方法数/文档数 ratchet、docs 数字 |
| 手工 | 焦点/菜单/嵌套面板/三布局同步入口/导出双 tab |

### 8.3 覆盖边界（明确不做）

- 多根工作区、卷重定位、schema v2。
- 导出/交付服务合并（只统一 UI）。
- 图库批量元数据之外的批量动作（评分/色标等，若产品需要另立）。
- 模型下载器（删除或单独立项）。
- C1 实机行为（只按现有错误码设计 UI）。

---

## 9. 最优性 review

### 9.1 关键取舍

| 决策 | 备选 | 选择 | 理由 |
|---|---|---|---|
| 根目录 | 新增 session_roots 表 | 复用 source_path + 修复 API | 无 schema，覆盖 95% 场景；多根留 v2 |
| 跨页批量 | 客户端分页调用 | 服务端 updateSelection + hash | 避免选择漂移/部分失败；一次请求闭环 |
| 批量规模 | 单事务 20k | 10k/块 | 历史条目/长事务可控；每块可撤销 |
| 预览身份 | 持久化 preview 表 | 确定性 token | 无 schema、跨重启、无清理问题 |
| 长任务 | 全部 Job 化 | 文件/重活 Job，写回 Operation | 避免过度工程；写回已有 delivery 队列 |
| 导出 | 重写一套 | 双 tab + 共享范围 + 预检 | 保留现有能力，先修 IA；服务合并另立项 |
| 重置 | 全量 reset + 导出备份 | 分级 scope | 默认安全；用户内容需显式勾选 |
| API 文档 | 手写索引 | 生成 + ratchet | 防止再次漂移 |

### 9.2 复杂度预算

- 新增协议方法 4：SessionAPI.setSourceRoot、CullingAPI.updateSelection、SettingsAPI.previewReset、PhotoAPI.select（可选）。
- 新增错误码 9（其余复用既有码）；新增 Job 类型 2。
- 新增 UI 组件 6：SelectionModel、OperationBanner、SourceRootBanner、ResetImpactSheet、ExportRangeBar、NoticeCenter。
- 不新增数据库表/列；不新增第三方依赖。
- 预计代码量：1,800–2,500 行（含测试 1,200+），分 12–16 个 PR。

### 9.3 性能目标

| 场景 | 目标 | 备注 |
|---|---|---|
| 10k 批量更新 | p95 < 2s | Debug；Release 目标 < 1s |
| 20k 选择 | 两块 < 4s | 含历史 |
| 选择查询 | < 300ms | 现有 SQL + hash |
| 预览 token | < 5ms | 纯内存 |
| 2k 摄取 | 进度每 100 项 | 不整库哈希 |
| reset preview | < 100ms | COUNT 查询 |
| 导出 selected 10 张 | 预览/执行一致 | 不额外扫全库 |

### 9.4 维护性

- 单一选择模型、单一 Notice、单一 OperationBanner、单一 PreviewTokenBuilder、单一 SettingScope 表。
- 所有“数字”由脚本生成或校验；文档不再手写 129/110/21。
- 新增 job/错误码/文案有 checklist 与门禁，减少“下一条 review 再发现”的概率。

### 9.5 潜在过度设计

- OperationCenter 与 JobService 两套：只保留必要的两套；不引入第三套“任务总线”。
- PhotoAPI.select 若产品不打算做图库全选跨页，可砍掉，只保留“全选已加载”的诚实文案。
- ExportAPI.preflightRun 可先用现有 OutputService 的计算在 UI 层做（不新增 API），若性能不够再加 API。
- 预览 token 不引入签名/加密；SHA-256 足够防误用，不是安全边界。

### 9.6 对本设计的反向评审（发现 → 处置）

在定稿前对方案本身做了一轮“正确性 / 完整性 / 最优性”反向检查，发现的缺口与处置如下：

| 视角 | 发现 | 严重性 | 处置 |
|---|---|---|---|
| 正确性 | 选择命中 20k 上限时，UI 的 hash 与服务端重算的集合可能不一致；原设计没有把 limit 带进 updateSelection | P1（会导致大批量永远失败或只处理子集） | 输入增加 limit（与 selection 同值）+ 结果 truncated；UI 在截断时明确“只处理前 N 张” |
| 正确性 | 相似度只用 resultId 做 token；recluster 可能复用同一 result 行 id | P1（旧预览可通过校验） | token 改为 resultFingerprint（id + createdAt + stats + 成员集合） |
| 正确性 | reset 逐键写入，失败会留下半重置状态 | P1（用户内容清一半） | SettingsRepository 单事务或先算全量再批量提交；失败回滚 |
| 正确性 | 整套交付忽略 selected 范围（OutputRunInput 没有 selectedPhotoIds） | P1（选了 10 张却交付全库） | OutputRunInput 增加 selectedPhotoIds；OutputService 透传给 ExportOptions；指纹包含 |
| 正确性 | 模板 job 恢复时 batch 记录可能重复/缺项 | P1（撤销不完整） | job 开始时建 batchId；executor 增量追加 applied entry；恢复跳过已 applied |
| 正确性 | ingest 在“复制完成、登记前”崩溃会重复复制或漏登记 | P1（重复文件/丢登记） | checkpoint 只在复制+登记后记 completed；恢复时按目标存在 + checksum 走“只登记” |
| 正确性 | 修复根目录后，workspace 的目录监听不会自动启动（构造时 root 为空） | P2（修复后仍不加照片） | setSourceRoot 成功后显式 SessionDirectoryMonitor.start |
| 正确性 | “始终要求根”会拒绝跨卷/无公共父目录的合法文件导入 | P2（合法导入被阻断） | 目录导入强制根；文件导入可显式 path-scope（sourcePath 为空 + banner + 禁用摄取） |
| 完整性 | 新 Job 类型的 UI 标签、错误文案、stageEvidenceTypes、测试目录未逐项列出 | P2（加类型后漏改） | PR checklist 增加“job type 全链路”清单；枚举 case 编译期强制 switch |
| 完整性 | 新错误码与既有码有重叠（SIM_PREVIEW_STALE、SESSION_SOURCE_*、EXPORT_PARAMS_INVALID） | P2（重复码/文案漂移） | 复用既有码；只新增 9 个确实没有的码 |
| 完整性 | 导出 selected 只在快速导出定义，没有覆盖交付 | P1（见上） | OutputRunInput + OutputService + 预检 + 确认全部透传 |
| 最优性 | 20k 单事务会让 culling_history 一次写 20k entries | P2（undo 卡/库膨胀） | 10k/块；每块独立 history；UI 显示“本次批量 2 步” |
| 最优性 | OperationCenter 与 JobService 可能变成两套任务系统 | P2（维护成本） | 明确边界：文件/CPU 重活走 Job，写回/短操作走 Operation；共享同一 UI |
| 最优性 | PhotoAPI.select 可能为“图库全选”引入不必要的新 API | P3（范围膨胀） | 标记可选；若不实现，只保留“全选已加载（N）”的诚实文案 |
| 兼容性 | 新 AnalysisJobType case 会让旧二进制解码失败 | P2（双版本场景） | 本方案假设单版本升级；若需双版本，先加 unknown(String) 分支（另立项） |

结论：反向评审后，方案的主要风险从“功能没覆盖”收敛为“实现顺序与门禁同步”；最需要先落地的是 §3.1 的选择契约、§3.2 的 token、§3.4 的根模型，三者是其余 P1 的地基。

---

## 10. 实施计划

### Phase 0：基础（2–3 人日）

- Notice/NoticeKind、OperationState/OperationBanner、PreviewTokenBuilder、SettingScope 表。
- 新错误码 + 文案 + docs 计数；API 索引脚本骨架。
- 测试骨架：选择/预览/reset/根校验。

### Phase 1：P1（5–7 人日）

1. 根 + 导入（P1-1/2）——1.5d
2. 摄取 job + 面板（P1-3）——1.5d
3. 选择模型 + 批量 API（P1-6/7/8）——2d
4. 人脸 token（P1-4）——0.5d
5. reset 分级（P1-5）——0.5–1d
6. 同步入口（P1-9）——0.5d

### Phase 2：P2（6–8 人日）

- 导出双 tab/预检/selected：2d
- 图库键盘/批量：1.5d
- 挑片混合态/对比/U/焦点/筛选：1.5d
- 元数据/人物/重复/相似度：2d
- C1 预检/帮助/首跑/导航组：1d

### Phase 3：DX（3–4 人日）

- API 索引/文档/数字；run.sh；日志；死面；ratchet；warnings。

### PR 切分原则

- 每个 PR 只含一个不变量及其测试；不混 UI 重构与服务语义。
- 协议变更单独 PR（含 allow-growth 记账）；UI 适配单独 PR。
- 每个 P1 先合服务端 + 测试，再合 UI；避免“UI 先上、服务端没校验”。

### 回滚

- 无 schema 变更，回滚 = revert PR；设置 reset 行为变更可由配置/开关回退（如需）。
- 新 job type 的旧 job 行保留；回滚后旧版本可能不识别新 type（未发布场景可接受）。
- 根修复只 UPDATE 列；回滚不回退已设置的根（数据仍有效）。

---

## 11. 验收标准

### 11.1 每条 P1 的验收（摘要）

- P1-1：首屏导入目录 → sourcePath 非空；加文件能被监听/重扫；摄取可用。
- P1-2：注入失败 → 可见错误 + 重试。
- P1-3：1000 张摄取有进度/可取消；失败项有 code；无根不给死路。
- P1-4：解绑后旧预览不能写回；token stale 错误可读。
- P1-5：reset 默认不动模板/配方/批次；勾选后才清；语言一致。
- P1-6：多选后单击另一张 → P/X 只作用当前。
- P1-7：5000 张全选 → P → 5000 落库或明确“仅可见”；有确认。
- P1-8：跨页组显示完整张数；决策有确认；取消无写入。
- P1-9：三种布局都能写回/同步/重置。

### 11.2 全局验收

- swift test core/app 全绿；新增测试覆盖上述。
- 12 门禁 + 新增 check-api-docs/check-plural 全绿；docs 数字同步。
- 性能目标达成（§9.3）。
- 手工清单：GUI 焦点、三布局、导出双 tab、C1 预检、reset sheet。
- 中英文界面走查：无 “1 items”、无未翻译新增 key、无 raw 错误。

---

## 12. 风险与开放问题

1. 产品决策：reset 是否允许清用户内容。本设计默认“不清”；若产品要求“一键清空”，需要单独的二次确认与导出备份。
2. 导出双 tab 是否最终合并服务。本设计只统一 UI；若后续合并，需要迁移旧配方/设置，另立设计。
3. 图库多选的真实批量动作。若产品不需要“导出所选/批量元数据”，应直接移除多选，避免留下死胡同。
4. Job 类型向后兼容。若未来需要旧版本读新 job 行，AnalysisJobType 需要 unknown 分支；当前假设单版本升级。
5. 根目录修复的边界。若照片分布在多个根，本设计只能选一个包含全部照片的根；多根是 schema v2。
6. GUI 焦点/面板。查看器焦点、IngestSheet 嵌套 panel 必须实机验收；静态测试覆盖不了。
7. 20k 批量的历史体积。10k/块是保守值；需在真实库上测 undo 体验，必要时降到 5k。
8. 错误码增长。每加一个码都要同步 195→N、en 表、docs；否则 check-docs 红。
9. API 面增长。新方法需 --allow-growth 记账；若评审认为 PhotoAPI.select 不必要，可砍。
10. 旧空根工作区。修复入口只对新/手动修复生效；无法自动推断用户意图，必须保留 banner。

## 13. 实施进度（2026-10-29，本工作树）

### 已完成（有测试/门禁）

- **P1-1 目录导入**：`chooseImportFolder` 对目录始终返回 `.directory`；**文件导入保持 path-scope（source_path 为空）**，扫描范围由 metadata.scan 的 requestedPaths 承担，根只来自显式 setSourceRoot（含无根 banner 修复入口）。测试覆盖目录导入、多文件导入 sourcePath 为空、Dashboard file-import 的 requestedPaths。
- **P1-2 导入失败可见**：新增 `GatherAppNotification.importFailed` + `CommandError` 载荷 + RootView error toast（含 retryFiles 重试）；测试断言失败通知与 retryFiles。
- **P1-4 人脸预览失效（客户端 + 服务端）**：新增 `invalidateWritebackPreview()`，bind/unbind/merge/split/removeMember/analyze 成功后清预览；服务端新增 `previewToken`（簇 id/成员数/角色/关键词指纹），`FaceWritebackInput.expectedPreviewToken` 在写回时复算，不一致抛 `FKW_PREVIEW_STALE`。测试覆盖解绑后客户端预览为 nil + 服务端 stale 拒绝且不执行写回。
- **P1-5 分级 reset**：新增 `SettingsAPI.previewReset` + `reset(Confirmed<SettingsResetInput>)`；`SettingsService.reset(input:)` 按“偏好/用户内容/语言”三个 scope 选择，用户内容与语言默认保留，watch 游标始终清理；单次 batchUpsert 保持原子；UI 新增 `ResetImpactSheet`（模板/批次/配方计数、用户内容二次确认、语言开关）。旧 `reset()` 保留为 preferences+language 兼容入口。测试覆盖预览计数、scope 隔离、VM 参数透传。
- **P1-6 胶片条选择**：普通点击收敛为单选；Shift 从当前做范围选择；测试覆盖单选清多选与范围。
- **P1-8 相似组影响面**：新增 `CullingGroupDecisionPlan`，先加载完整组、确认弹窗展示完整组员数/当前视图数/淘汰样本，再执行；测试覆盖跨页组 3 张 vs 当前 2 张。
- **P1-9 网格同步入口**：新增 `CullingSyncControls`（同步/写回/重置），挂到 toolbar 全/紧凑两档，infoBar 只保留状态；三种布局共用。
- **P1-3 摄取 Job 化 + 根修复**：错误改 `CommandErrorText`；异步 `begin` 替换 3 处 `runModal`；新增 `SessionAPI.setSourceRoot` + 控制中心修复 banner；摄取改为 Job（复用 `checksum.backfill` 载体 + checkpoint.operation=ingest，因 analysis_jobs.type CHECK 不允许新 type 且不改 schema）；执行体与 Job 共用 `SessionIngestRunner`，支持文件边界取消、进度上报、控制中心可见；IngestSheet 增加取消按钮。**顺手修复单文件 plan 被 seenSources 自去重为 0 的 P1 级缺陷**。
- **P1-7 跨页批量**：`selection` 返回 `idsHash`；新增 `CullingAPI.updateSelection`，服务端按 scope/filters 重算并校验 hash/count，10k 分块调用 batchUpdate，每块一个 history operation；hash 不符抛 `CULLING_SELECTION_CHANGED` 且零写入。VM 保存全选快照，跨页 commit 先弹确认（全部/取消；VM 已支持仅可见），确认后走 updateSelection。测试覆盖服务端 hash 拒绝、整份应用、VM 确认与 hash 参数。

### 未开始 / 下一步

- P2 导出双 tab/selected/预检、图库键盘、元数据草稿、人物合并、重复 reset、相似度 token、C1 预检、帮助、复数/术语。
- DX：API 索引、Settings reset Confirmed、Bool 返回、文档/运行路径/日志。

### 验证

- `./scripts/test.sh all`（`--disable-sandbox`）：core / app 全量用例通过（用例数随分支变化，以脚本输出为准）。
- 13 个门禁全绿；en 键数 1,849、错误码 198（docs/README/ROADMAP/DEVELOPMENT 已同步）。
- Protocol 公开面按 `--allow-growth` 更新基线：344 类型 / 1,985 声明（P1 API + P2 selected/resetGroup/photo select + P3 includeFailed）；据此记账。
- 尚未做 GUI 实机验收：查看器焦点、三布局视觉、IngestSheet 嵌套面板。

## 14. P2 实施进度（2026-10-29，第一批）

### 已完成

- **P2-2 图库键盘/选择栏/批量动作（基础）**：选择栏常显；方向键移动单选、Space 切换、Return 打开灯箱、Esc 清空、⌘A 全选已加载；批量动作加“导出所选”“在灯箱中比较”“在 Finder 中显示”。未接服务端跨页全选/批量评分色标/批量元数据。
- **P2-2 服务端跨页全选**：新增 `PhotoAPI.select(PhotoSelectionQuery)`，按当前搜索/筛选返回 ID 集、SHA-256 hash、20k 截断标记；⌘A 与“全选筛选结果”走服务端，批量评分/色标按 10k 分块执行。
- **P2-2 图库批量评分/色标**：选择栏“批量操作”菜单支持保留/淘汰/0–5 星/色标，走 `CullingAPI.batchUpdate`。
- **P2-1 交付预检**：交付确认前逐配方 `export.preview` 汇总预计文件数/体积/可用空间/源文件问题/失败配方，并在 sheet 中显示；测试覆盖汇总与 selected 透传。
- **P2-8 恢复未处理**：新增 `DuplicateAPI.resetGroup(Confirmed<DuplicateResetGroupInput>)`；组/成员 resolution 清空、成员全部恢复保留、照片状态重算；卡片菜单“恢复未处理”经确认后执行。测试覆盖服务层与 VM 本地 patch。
- **P2-8 重复组一致性**：`resolveMember` 后调用 `syncGroupResolutions` 重算组行；组行 resolution 改为可空写，成员全部已决但保留数既非 1 也非全部时清空旧徽标；VM 本地 patch 同源重算。测试覆盖 keep_one → 逐张改回保留 → keep_all。恢复未处理 API/按钮已完成（见上一条）。
- **P2-7 人物合并/移除照片 UI**：人物详情新增“合并到…”菜单（目标人物列表 + 影响确认），关联照片右键“移除此照片”（只断绑定不删文件）；复用既有 `merge`/`removePhoto` API，成功/失败走 toast。
- **P2-9 相似度写回禁用**：分析/聚类进行中 `canPreviewWriteback` 为 false，预览/执行/重试均拒绝；开始分析/聚类清空旧预览；写回面板显示禁用提示。
- **P2-5 冲突批量（部分）**：冲突面板在 >1 个冲突时增加“全部采用外部值/全部保留 Gather”，经统一确认后逐项应用，失败项保留并汇总；失败清单仍只显示前 3 项。
- **P2-4 筛选范围（部分）**：离开“按筛选”范围时清空 filters 并提示“已清除筛选条件”；空态在有筛选时提供“清除筛选”按钮。
- **P2-3 对比与筛选 chip**：对比网格优先显式选中的 2/4 张，否则当前 ± 相邻（不再取列表开头）；工具栏/紧凑档增加可点击的“筛选 N”chip，点击清除筛选。
- **P2-3 一致性（部分）**：查看器 U 统一 `shouldAdvance:false`；紧凑工具栏补质量分析取消按钮；检查器多选星级/色标显示“混合”，不再把当前照片的值冒充批量值。
- **P2-1 结果动作**：导出结果错误默认 3 条，可展开全部；新增“在 Finder 中显示”导出目录。
- **P2-1 交付确认**：整套交付先 `prepareDeliveryInput()` 冻结目录/范围/配方（含 selected IDs），再弹确认 sheet；确认后 `executeDelivery(input)` 只执行冻结输入，不再重读界面。测试覆盖 selected 输入冻结。
- **P2-1 selected 范围（基础）**：`ExportOptions` / `OutputRunInput` 增加 `selectedPhotoIds`；`.selected` 服务端校验会话/可见/非 removed/≤20k；`ExportRangeIntent.selected(ids)` 进入导出页默认所选范围，UI 增加“所选照片（N 张）”；导出/交付逐配方透传。测试覆盖 selected 只导出所选、空/未知 ID 拒绝、VM 意图与 options。
- **P2-6 元数据/模板面板**：
  - `MetadataEditorSheet` 与 `MetadataTemplateFieldsSheet` 在关闭/取消时检测未保存改动，弹“放弃未保存的改动？”确认；`.interactiveDismissDisabled` 阻止绕过。
  - 模板字段面板跟踪初始值，`values != initialValues` 或存在“清空”勾选即视为 dirty。
  - `MetadataTemplateSheet` / `MetadataTemplateFieldsSheet` / `MetadataBatchSheet` 的 `String(describing: error)` 统一改为 `CommandErrorText.resolve(CommandError(error), with: l10n)`。
  - 批次行不再重复名称：triage 显示“技术建议写回 · 原名”，第二行只保留“N 张 · 日期”；日期 `DateFormatter.locale = l10n.locale`。

### 未开始

- P2-1 双 tab 信息架构（selected + 确认 + 结果动作 + 预检已完成）
- P2-2 批量元数据（跨页全选/评分色标已接；Finder/灯箱/导出已接）
- P2-3 混合态/U/对比对象/筛选 chip 已接；冲突批量已接
- P2-10~14 未开始
- P2-10 摄取去重 size 预筛 / import 并发 / 模板套用进度取消
- P2-11/12/13/14 C1 分层预检、帮助、导航组术语、单复数与取消色

### 验证

- app / core 全量用例通过（用例数见 `scripts/test.sh` 输出）。
- 13 门禁全绿；en 键数 1,849。
- 未做 GUI 实机验收：交付确认、图库键盘、混合态、筛选 chip、结果展开。

## 15. P3 实施进度（2026-10-29，第一批）

### 已完成

- **P3-1 “保留已选 K 张”占位**：空选择时隐藏该按钮，不再显示字面 K；删除对应 en 条目。
- **P3-3 报表参数校验**：未知 `reportType` 或 `format` 抛 `EXPORT_PARAMS_INVALID`（field=reportType/format），不再空内容成功；测试覆盖。
- **P3-4 清空失败任务**：`ClearCompletedInput.includeFailed`；默认清 succeeded，`includeFailed` 清 succeeded + failed/interrupted/cancelled（“包含”而非“替换”）；Dashboard 增加“清理失败记录”（阶段证据仍保留），只剩失败任务时该行也渲染。
- **P3-8 过期设计文档**：`docs/design/appearance-interaction.md` 目录树改为实际分目录，菜单命令迁移状态改为 Phase 4 已完成（installed 驱动置灰）。
- **P3-5 Sources 严格告警**：新增 `scripts/check-warnings.sh`，core/app Sources 用 `-warnings-as-errors` 构建；CI 两个 job 都执行；修复 2 处冗余 `internal(set)`。
- **P3-6 ratchet 基线保护**：cleanup/design-system 的 `--write-baseline`/`--update` 在有指标上涨时拒绝，必须显式 `--allow-growth`；与 protocol-surface 同口径。
- **P3-7 串行测试自动推导**：`scripts/test.sh` 扫描 core 测试中 `GatherLogger`/`slowTransaction`，自动生成串行 filter；名单为空直接失败。
- **P3-9 模型下载器可达**：模型缺失横幅新增“下载人脸模型”按钮，经覆盖确认后调用 `startModelDownload`；不再是无入口死面。
- **P3-10 runModal**：Settings 备份目录/诊断导出改用 `NSOpenPanel.begin` / `NSSavePanel.begin`，不再阻塞主线程；全仓 Sources 已无 `runModal`。
- **评审后修复**：图库服务端全选改用 `has_face` 并按 500/页累积到 20k；图库批量动作先确认再写、按实际 states 计数并广播 culling；导出 selected 上限与图库统一 20k、服务端排序；无入口意图时清除旧的“所选照片”范围；设置 reset 后使导出配方缓存失效；摄取 cancellation 显示“已取消”并刷新，dedupeKey 带请求指纹；重复组恢复入口对部分成员决策可见；清理失败记录只清失败/中断/取消。

### 未开始

- P3-2 已由 P2-6 合并，不单列；P3 其余项已完成。

### 验证

- app / core 全量用例通过（用例数见 `scripts/test.sh` 输出）。
- 12 个既有硬门禁 + 新增 `check-warnings.sh` 全绿（共 13）；en 键数 1,849。
- 未做 GUI 实机验收：清理失败记录、模型下载入口、报表错误提示、设置面板异步化。

---



## 16. 全量评审后的修复（本轮）

> 修复记录只写“做了什么/为什么”，不重复计数（计数以 docs/README.md 与脚本输出为准）。

- **P0 导出配方**：settingsChanged 只作废缓存并原地重读；persistDeliveryRecipes 增加“已载入”守卫；
  invalidateDeliveryRecipes 不再先清空数组（清空会被 onChange 落盘成 []）。
- **P1 挑片自动前进**：update 成功后同步 selectedPhotoIds，连续 P/X 不再重写同一张。
- **P1 跨页批量显示**：updateSelection 成功后 refreshSilently(forcePage: true)。
- **P1 导入根**：文件导入不派生 source_path（path-scope），根只来自目录导入或显式 setSourceRoot；
  回归测试断言多文件导入后 sourcePath 为空。
- **P2 批量语义**：确认框增加「仅当前可见」；手动跨页选择也先确认；提交按 10k 分块；
  skipped/失败/截断都有可见计数；失败码改为稳定码值；截断文案不再同义反复。
- **P2 摄取**：无根会话提供「设置根目录…」；取消找不到任务时给反馈；运行中禁止关闭并显示 N/M。
- **P2 设置**：空串语言 = 跟随系统（不再强制 zh-CN）；reset 只写被重置的键；影响面文案补充
  交付目录/备份目录。
- **P2 图库**：⌘A 的服务端全范围选择不再被刷新裁回已加载页；键盘游标只落在当前可见集合。
- **P2 任务/导出/重复/人脸**：摄取任务标签按 dedupeKey 统一（三个面板同源）；看板只剩失败任务
  时也能清理；空间不足或全部配方预检失败时阻断交付确认；missing 状态不被重复组重算覆盖；
  有写回项时必须带预览令牌（省略即 FKW_PREVIEW_STALE）。
- **工程/文档**：ci.yml 采用 main 的串行 + 看门狗并保留 Sources 告警门禁；补齐协议方法数、
  en 键数与设计文档记账；删除无调用者的旧 reset/runDelivery。

**有意未做**：idsHash 收敛为单一公共实现、10k 上限单点化、CullingSelectionIds.idsHash 改非可选、
图库确认弹窗改用统一组件——这些会扩大协议公开面或需要单独回归批次，留到下一轮。

## 17. 第二轮修复（2026-10-30）

> 只记本轮实际改动；未做的明确留到下一轮，不再写成“已完成”。

- **选择锚点**：新增 `selectionAnchorId`；普通/⌘ 点击更新锚点，⇧ 只移动 current，连续 ⇧ 不再丢掉第一段范围。补“连续 Shift”用例。
- **根修复监听**：监听重建收口到 `LiveSessionAPI.setSourceRoot` 唯一写路径（控制中心/摄取面板都经过），根修复后 stop+start；无根时索引失败行的“重试”也门控。
- **摄取恢复第二目的地**：`alreadyPresent` 主副本已在时，`execute` 校验并补拷第二目的地（主文件 + sidecar）；补拷失败进 `failed`，不再静默成功。
- **符号链接根**：同时用词汇路径与 resolved 路径校验 forbidden/contains，保留用户选择的词汇路径，避免合法链接根被误拒。
- **导入 0 张提示**：`importCompleted` 带 `directoryImport`；任一目录作用域（单目录/目录+文件）都不再用 `addedCount == 0` 推断空目录。
- **批量错误**：普通批量首块失败（applied=0）保留原始 `CommandError`；快照批量首块失败保留服务端 `failure.detail`。只有部分成功才改写为“已应用 N、其余未执行”。
- **reset scope 穷尽**：新增内部 `SettingsService.ResetScope` 分类、显式 `preferenceKeys` 白名单与 `resetScope(for:)`；新增键未登记时返回 nil（默认 reset 保留），测试断言每个 known key 恰有显式分类。
- **同步态键**：`syncByXmp` 与 `getMany` 统一用 `TSPath.normalize`，避免 filepath 非标准形时静默退化。

### 明确未做（下一轮）

- 相似度/元数据写回的 `expectedPreviewToken` 与服务端复算；`METADATA_PREVIEW_STALE` 未落地（当前只有人脸 token；UI 侧分析中禁用相似度写回）。
- `TEMPLATE_*` / `DUP_GROUP_NOT_FOUND` / `DUP_MEMBER_NOT_FOUND` 错误码与域错误映射。
- 摄取失败 `code/retryable` DTO；`PhotoAPI.select` 的 ids-only 单查询；摄取去重按 size/mtime 预筛。
- 交付 notice 的 `NoticeKind`、预检忙碌态/取消；人物多 dialog 同节点与合并目标计数。
- GUI 实机验收（焦点、三布局、FSEvents stop→start、符号链接根、面板交互）。

## 附录 A：拟新增/修改的 API

| 域 | 变更 | 类型 |
|---|---|---|
| Session | 新增 setSourceRoot(Confirmed<SessionSetSourceRootInput>) | 输入/输出 |
| Culling | 新增 updateSelection(Confirmed<CullingSelectionUpdateInput>) | 输入/输出 |
| Culling | CullingSelectionIds 增加可选 idsHash | 输出 |
| Settings | previewReset()；reset(Confirmed<SettingsResetInput>) | 输入/输出 |
| Export | ExportOptions.selectedPhotoIds；OutputRunInput.selectedPhotoIds | 输入 |
| Export | 可选 preflightRun | 输入/输出 |
| Photo | 可选 select(PhotoSelectionQuery) | 输入/输出 |
| Face/Similarity/Metadata | 写回输入增加 expectedPreviewToken；WritebackPreview.previewToken | 输入/输出 |
| Job | 可选 JobMutationOutcome 返回 | 输出 |
| 所有 | 新错误码 | 错误 |

## 附录 B：新增错误码（建议）

- CULLING_SELECTION_CHANGED
- FKW_PREVIEW_STALE、METADATA_PREVIEW_STALE（相似度复用 SIM_PREVIEW_STALE）
- WORKSPACE_ROOT_EXCLUDES_PHOTOS（根无效复用 SESSION_SOURCE_NOT_DIR / SESSION_SOURCE_ROOT_FORBIDDEN）
- TEMPLATE_NOT_FOUND、TEMPLATE_BATCH_NOT_FOUND、TEMPLATE_BATCH_ALREADY_UNDONE
- DUP_GROUP_NOT_FOUND、DUP_MEMBER_NOT_FOUND
- 复用：EXPORT_PARAMS_INVALID（selected 非法）、CULLING_EMPTY_SELECTION、INDEX_SESSION_NO_SOURCE、OUTPUT_ROOT_INVALID

## 附录 C：PR 检查清单

- [ ] 新 API 有输入校验、错误码、Live 实现、契约测试、api-index 更新。
- [ ] 新文案有 en 条目；计数文案有 #one。
- [ ] 新错误码有 zh/en 文案；docs 计数更新；check-docs --strict 绿。
- [ ] 破坏性输入用 Confirmed；确认文案说明影响面。
- [ ] 批量/长任务有进度、取消、部分结果；取消不显示 success。
- [ ] 预览类操作有 token；变更即失效。
- [ ] 根/路径操作有 canonical + forbidden root + within 校验。
- [ ] 测试覆盖“失败/取消/过期/跨页”四条负路径。
- [ ] 文档/README 数字与代码一致。
