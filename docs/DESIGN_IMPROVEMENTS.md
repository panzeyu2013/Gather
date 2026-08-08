# Gather 产品设计短板：设计、最佳实践与解决方案

> 版本：2.0 · 状态：主体已实施（2026-08；原为提案）
> 适用范围：desktop 桌面应用（Electron + React + SQLite）
> 说明：本文档由原设计文档与最佳实践复核文档合并而成。每个问题包含：现状分析 → 最佳实践基线（权威资料 + 第一性原理）→ 最终设计（含判定记录）→ 落地路径。判定记录中明确标注哪些设计元素被保留（✅）、被简化或删除（✂️，即过度设计）与被补充（➕，即遗漏）。
>
> **实施状态（2026-08）**：五项问题的核心设计均已按判定记录落地，明细与剩余项见 [ROADMAP.md](ROADMAP.md) §3.5，决策背景见 [ADR.md](ADR.md) ADR-012~018：
> - 问题一：`analysis_runs` + `sessions.index_seq`（迁移 v30）、`WorkspaceStatusService` + `workspace.status` + `useWorkspaceStatus`、Control Center（阶段条 + Action Inbox + 推荐动作）、离线复核 TTL ≥5 分钟 — ✅ 全部落地
> - 问题二：`c1:health` 四层预检、`CaptureOneSyncState` 会话级聚合 + `reload_acked_at`（迁移 v31）重启重推导、协调器事件接线与转换日志、按钮状态机驱动、健康胶囊/面板与导入预检 — ✅ 全部落地
> - 问题三：`ScanResult` 元数据 + `truncated_import`（迁移 v29）、`session.create_from_directory` 一跳化、Dashboard "≥"/"扫描中"文案规范、`indexProgress.ts` 头部索引进度 — ✅ 全部落地
> - 问题四：i18n P1（i18next + 类型化 key、832 key/语言、`GatherErrorCode`/阶段码 + `translateError`/`translatePhase`、术语表 docs/i18n-glossary.md）✅；P2（eslint 守护 + 菜单本地化）✅ 已落地（工作区，见 ADR-019）；语言切换 UI ✅ 已落地（P2 收尾：设置覆盖 > --lang > 系统语言，见 ADR-020）
> - 问题五：Dialog 焦点管理（portal + inert + `initialFocus`/`descriptionId`）、相似组键盘语义、jest-axe 回归、对比度修复 ✅；VoiceOver 手工走查 ⏳ 待执行（docs/a11y-audit.md）

本文档针对以下五项已确认的产品设计短板：

1. 模块中心而非任务中心（缺少 Workspace Control Center / Action Inbox）
2. Capture One 集成的人工接缝（缺少连接预检与同步状态机）
3. 首次扫描 50,000 文件上限导致数量不透明
4. 无 i18n 体系（数百处硬编码中英文混杂）
5. 无障碍只有局部处理（Dialog 焦点、相似组键盘语义）

---

## 0. 总览与参考资料

### 0.1 问题总览

| # | 问题 | 现状证据 | 影响 | 解决方案摘要 | 预估工作量 |
|---|------|----------|------|--------------|-----------|
| 1 | 模块中心、无任务中心 | `SessionDetail/index.tsx:51-70` 六个并列页签 | 用户不知道"进行到哪一步、下一步做什么" | Workspace Control Center + Action Inbox + 推荐下一步 | 2 周 |
| 2 | C1 集成人工接缝 | `capture-one.ts` 仅两个原语；同步协调器 6 种行状态 | 用户需理解 XMP / Load Metadata / Confirm Sync / Cleanup 等内部概念 | 连接预检 + 同步状态机 + 健康胶囊 | 1.5 周 |
| 3 | 扫描上限不透明 | `main/index.ts:384-417` `MAX_SCANNED_FILES = 50_000` 静默截断 | 首次导入数量阶段性不完整、无说明 | 一跳化扫描落库 + 扫描元数据 + 进度事件 | 5 天 |
| 4 | 无 i18n | 27 个 renderer 文件、137+ 行含硬编码中文 | 中英混杂、无法扩展语言 | i18n 层 + 类型化 key + 页面级迁移 + 静态守护 | 2 周（含迁移） |
| 5 | 无障碍局部化 | `Dialog.tsx` 无焦点陷阱；`Similarity/index.tsx:316` 可点击 div | 键盘与读屏用户无法使用 | 焦点管理 + 键盘语义 + 全局审计 | 1 周 + 持续 |

合计约 **6–7 周**（按阶段 A/B/C 交付，见第 6 章）。

### 0.2 参考资料清单

| # | 资料 | 用途 |
|---|------|------|
| 1 | W3C WAI-ARIA APG — Dialog (Modal) Pattern<br>https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/ | 问题五 Dialog 的规范基线 |
| 2 | W3C WAI-ARIA APG — Grid Pattern<br>https://www.w3.org/WAI/ARIA/apg/patterns/grid/ | 问题五 列表键盘交互（判定其适用范围） |
| 3 | a11y-dialog（Kitty Giraudel，1.6KB，APG 全实现参考）<br>https://a11y-dialog.netlify.app/ | 问题五 最小自研实现的对照 |
| 4 | i18next 官方文档 — Essentials<br>https://www.i18next.com/translation-function/essentials | 问题四 插值/复数/回退/错误码映射 |
| 5 | Apple Mac 使用手册 — "允许 App 控制其他 App"（自动化权限 TCC）<br>https://support.apple.com/guide/mac-help/allow-apps-to-control-other-apps-on-mac-mchl9d30bf14/mac | 问题二 TCC 预检 |
| 6 | AppleScript 语言指南 — Apple Events 错误表（-1743 = not authorized） | 问题二 权限拒绝判定 |
| 7 | Electron 官方文档 — `app.getLocale()` / `--lang` 开关 | 问题四 语言来源 |
| 8 | Adobe XMP 规范 Part 1/2（sidecar 与 embedded 双写冲突模型）；Lightroom"自动写入 XMP"工作流 | 问题二 状态机语义来源 |
| 9 | NNGroup — 任务导向导航原则（feature-oriented 导航的缺点） | 问题一 模块降为工具的依据 |
| 10 | VS Code "Problems" 面板、GitHub Notifications Inbox 先例 | 问题一 Action Inbox 形态 |

---

## 1. 问题一：从"模块中心"到"任务中心"——Workspace Control Center + Action Inbox

### 1.1 现状分析

`SessionDetail/index.tsx` 把六个能力（浏览、相似度、人脸、重复、挑片、导出）渲染为等权的并列页签，`/sessions/:id` 的 index 路由直接重定向到 gallery：

```
<Route index element={<Navigate to="gallery" replace />} />   // line 83
```

用户进入工作区时，界面无法回答五个核心问题：

| 用户问题 | 现状 |
|----------|------|
| 工作区完成到哪一步？ | 无阶段概念，六个页签无进度表达 |
| 哪些分析过期？ | 相似度/人脸结果存于 DB，但与索引增量之间无版本化关系 |
| 哪些 XMP 待处理/冲突？ | 数据已存在（`metadata-sync-coordinator.ts` 的 `pending/writing/failed/conflict/synced` 六状态、`conflict_count` 汇总），但只在元数据面板内暴露，无工作区级聚合 |
| 哪些照片离线？ | `similarity.service.ts:221` 已有 `missing on disk` 标记能力，无聚合入口 |
| 下一步推荐动作是什么？ | 无推荐逻辑 |

根本原因：**缺少一个工作区级别的领域模型（阶段 + 健康度 + 待办聚合）**，模块各自为政。

### 1.2 最佳实践基线

- **任务导向导航**（NNGroup）：导航应按用户任务组织而非按功能组织——用户的目标是"完成一次选片交付"，模块只是手段。Lightroom 的 Library→Develop→Export 是同类先例。
- **聚合型待办面板**（VS Code Problems、GitHub Notifications Inbox）：把分散的异常集中为"可执行条目列表"，每条可跳转/执行，是桌面工具的标准形态。
- **第一性原理**：用户需要的三个问题——"我在哪一步 / 什么坏了 / 下一步做什么"——所需数据**全部已存在于 SQLite**（photos/similarity/analysis 状态、协调器六状态、jobs 失败记录）。因此本方案本质是构建一个**只读聚合模型（read model）**，不引入新的权威数据源。这是其不过度的根本原因：CQRS 式的"派生状态集中呈现"。

### 1.3 目标体验

把首页升级为 **Workspace Control Center**（工作区控制中心）：

```
┌───────────────────────────────────────────────────────────────┐
│ ← 工作台  婚礼跟拍 2026-06  📍 12,847 张照片 · 98% 已索引     │
│                                                               │
│ [1 导入] ──[2 索引] ──[3 分析] ──[4 挑片] ──[5 导出]  (进度条) │
│                                                               │
│  ⚠ Action Inbox（按优先级排序）                                │
│    • 相似度分析过期：新增 312 张照片未参与分组        [重新分析] │
│    • 3 个 XMP 冲突待裁决                                   [查看] │
│    • 24 张照片离线（源文件不可读）                          [查看] │
│    • 导出任务 "Web 小图" 失败 2 项                             [重试] │
│                                                               │
│  推荐下一步：重新运行相似度分析，合并剩余重复项后再导出        │
│                                                               │
│  [浏览] [相似度] [人脸] [重复] [挑片] [导出]  ← 模块降为工具   │
└───────────────────────────────────────────────────────────────┘
```

- **阶段进度**：导入 → 索引 → 分析 → 挑片 → 导出 五步横向进度条。
- **模块降为工具**：页签保留，但从"首屏"变为"工具箱"；Control Center 成为 `/sessions/:id` 的 index 路由。
- **Action Inbox**：异常与待办集中、按严重度排序、每条可一键跳转或执行。

### 1.4 最终设计

#### 1.4.1 阶段模型（复核后：三硬阶段 + 两软标记）

判定记录：原稿的"culled / exported"两阶段没有客观完成条件（挑几张算挑完？成功一次算导出完？），会产生虚假确定性，故 **✂️ 降级为软标记**；只保留三个有客观判定的**硬阶段**：

```
imported ──► indexed ──► analyzed
   │            │            │
   └────────────┴────────────┴── 任一阶段可回退（新增文件 → 退回 indexed）
```

| 阶段 | 判定条件（SQL/服务查询） | 数据来源 |
|------|--------------------------|----------|
| imported | session 存在且 photos 表非空 | `PhotoRepository` |
| indexed | **最近一次索引 job（`index.scan`）成功结束且此后无待处理变更**（以 jobs 表记录为准） | `IndexService` / `JobService` |
| analyzed | 相似度结果存在 **且未过期**（见 1.4.2） | `similarity` 表 + 版本号 |

软标记（仅用于推荐下一步，不进入进度条状态）：culled（存在已写回的挑片决策）、exported（存在成功导出的 job 记录）。

#### 1.4.2 分析过期检测（Staleness）

判定记录：**✅ 保留**。这是**最小正确解**——一张表 + 一个计数器。对比"照片数 COUNT 不一致"方案：照片被删除时 COUNT 变小但分析结果并不过期，`index_seq` 只随索引提交自增，语义精确，不是过度设计。

方案：**分析运行记录（analysis run）**：

```sql
CREATE TABLE IF NOT EXISTS analysis_runs (
  id            INTEGER PRIMARY KEY,
  session_id    INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,            -- 'similarity' | 'face'
  photo_count   INTEGER NOT NULL,         -- 运行时的照片总数
  index_seq     INTEGER NOT NULL,         -- 运行时索引序号（见下）
  started_at    TEXT NOT NULL,
  finished_at   TEXT NOT NULL,
  params        TEXT NOT NULL,            -- 阈值/分组模式等参数快照
  status        TEXT NOT NULL             -- 'running' | 'ok' | 'failed'
);
```

**索引序号（index_seq）**：`IndexService` 每次全量/增量索引提交后自增 `sessions.index_seq`（`sessions` 表加一列），分析服务开始时读取并写入 run 记录。

**过期判定**：`analysis_runs.finished_at` 之后的 `index_seq` 是否增长：

```
stale = last_ok_run.index_seq < session.index_seq
```

实施顺序：先在 `similarity.service.ts` 的 `analyze` 入口写入 run；人脸分析复用同一模式；`indexer` 的提交点（`index.service.ts` 中 photo upsert 事务后）自增 `index_seq`。

#### 1.4.3 Action Inbox 聚合

**统一查询服务** `WorkspaceStatusService`（主进程只读聚合，不引入新权威数据源）：

| 动作类型 | 判定 | 推荐动作 | 优先级 |
|----------|------|----------|--------|
| scan_incomplete | 1.4.4 的截断标记（索引未完成） | 查看索引进度 | 信息型（置顶） |
| analysis_stale | 1.4.2 的 stale 判定 | 重新分析 | P1 |
| xmp_conflict | 协调器 `conflict` 行（已有 `conflict_count`） | 逐条裁决 | P1 |
| xmp_pending | `pending/failed` 行（已有 `pending_count`） | 重试/检查 C1 | P2 |
| offline_photos | `photos.status = 'missing'`（**TTL 缓存 ≥5 分钟，见 1.4.5**） | 检查源磁盘/重新扫描 | P2 |
| job_failed | jobs 表 `failed` 状态 | 查看日志/重试 | P2 |
| export_pending | 有选中但未导出的照片组 | 进入导出 | P3 |

主进程新 IPC `workspace.status`，一次返回：

```ts
interface WorkspaceStatus {
  sessionId: string
  stage: 'imported' | 'indexed' | 'analyzed'           // 三硬阶段
  softFlags: { culled: boolean; exported: boolean }    // 软标记
  indexing: { total: number; done: number; percent: number }
  staleAnalyses: Array<{ kind: 'similarity' | 'face'; lastRunAt: string }>
  xmp: { pending: number; conflict: number }
  offlinePhotos: number
  failedJobs: Array<{ id: number; type: string; message: string }>
  recommendedNext: { action: string; target: string } | null
  generatedAt: string
}
```

**推荐动作（recommendedNext）**：判定记录 **✂️ 删除规则引擎**——为一行推荐文案引入"考虑 C1 状态、磁盘空间"的规则引擎是过度设计。最终实现为**固定优先级序列表 + 布尔门控**（~10 行 if-else）：

```
1. scan_incomplete 时 → 推荐等待/查看索引
2. xmp_conflict > 0  → 裁决冲突（P1 优先于一切）
3. analysis_stale    → 重新分析
4. job_failed        → 重试失败任务
5. 全部正常          → 推进流程（软标记未满足的下一步：culling → export）
C1 连接状态仅作为布尔门控：C1 不可达则不推写回/清理类动作。
```

#### 1.4.4 扫描透明（与问题三联动）

`scan_incomplete` 条目指向 3.3 的进度呈现；索引完成、`sessions.photo_total` 精确值落定后自动消失。

#### 1.4.5 性能约束（➕ 补充）

- **离线照片复核 TTL ≥ 5 分钟**：`photos.status='missing'` 是惰性检测的，Inbox 每次刷新不能全盘 stat 文件。写入服务契约：Inbox 每 5 分钟最多触发一次离线复核，其余时间用缓存值。否则 Action Inbox 会退化为性能陷阱。

### 1.5 判定记录汇总

| 原设计元素 | 判定 | 理由 |
|------------|------|------|
| Control Center 为 index 路由、模块降为工具 | ✅ | 任务导向导航原则；Lightroom 同构先例 |
| 五阶段进度条 | ✂️ | culled/exported 无客观完成条件 → 降为软标记；仅保留三硬阶段 |
| `analysis_runs` + `index_seq` | ✅ | 最小正确解；比 COUNT 方案语义精确 |
| `WorkspaceStatusService` 统一 IPC | ✅ | 读模型集中呈现，正是现状病根的解药 |
| Action Inbox 七类动作 + 优先级 | ✅ | 与 VS Code Problems / GitHub Inbox 同构 |
| 推荐规则引擎（C1 状态/磁盘空间为输入） | ✂️ | 过度设计 → 固定优先级序列表 + 布尔门控 |
| 轮询 30s/3s + 事件推送 | ✅ | 简单可靠，推送做即时刷新、轮询做兜底 |
| 离线照片复核 | ➕ | 必须 TTL 缓存，否则 Inbox 成为性能陷阱 |

### 1.6 落地路径

| 步骤 | 内容 | 依赖 |
|------|------|------|
| P0-1 | DB：`sessions.index_seq` 列 + `analysis_runs` 表迁移 | 无 |
| P0-2 | IndexService 提交点自增 `index_seq`；相似度/人脸入口写 run | P0-1 |
| P0-3 | `WorkspaceStatusService` + IPC + 渲染层 hook（含离线 TTL） | P0-2 |
| P1-1 | Control Center 页面（阶段条 + Inbox + 推荐动作） | P0-3 |
| P1-2 | Inbox 动作跳转/执行接线 | P1-1 |

---

## 2. 问题二：Capture One 集成——连接预检与同步状态机

### 2.1 现状分析

`capture-one.ts` 只暴露两个原语：

- `getSelectedPhotos()`：取选中照片路径（失败时错误信息要求"用户理解 Capture One 已运行且有文档打开"）。
- `reloadMetadata()`：发送 `reload metadata of current document`（`buildReloadMetadataScript`）。

底层状态其实已经很完整——`metadata-sync-coordinator.ts` 维护每行 XMP 的 `pending → writing → written → synced`，以及 `failed / conflict`，并有 `pending_count / conflict_count` 聚合（`metadata-sync-coordinator.ts:149-168`）。但：

1. **没有连接预检**：Capture One 是否运行？文档是否打开？是否有选中项？Apple Events 自动化权限（TCC Automation）是否授权？——全部靠调用失败后的错误文本推断。
2. **没有同步健康度**：重试次数、脚本延迟、超时配置（`c1_retries / c1_timeout_ms / c1_reload_delay_ms`）都不可见。
3. **缺少端到端状态机**：用户需要自行理解"Gather 已写入 XMP → Capture One 是否已读取 → 是否可安全清理"。注释已承认这是关键风险（`capture-one.ts:106-108`："false success can cause Gather to restore XMP that Capture One never loaded"），但状态只存在于协调器内部，UI 未呈现。

### 2.2 最佳实践基线

- **平台事实**（Apple 文档）：自动化权限位于 系统设置 → 隐私与安全性 → 自动化，由 TCC 按"发送方 App × 接收方 App"授权；被拒时 osascript 报 Apple Events 错误 **-1743 (not authorized)**。据此预检设计成立：对 C1 发一次无害探测即可判定权限状态，无需读系统数据库。
- **领域先例**：Adobe XMP 规范确立 sidecar 与 embedded 双写模型；Lightroom"自动写入 XMP"同样面临"何时安全"问题。本方案的三相（Gather 已写入 → C1 已读取 → 可安全清理）正是该领域的标准答案。
- **第一性原理**：目标有二——(a) 消除用户对 XMP / Load Metadata / Confirm Sync / Cleanup 内部概念的认知负担；(b) 防数据丢失（C1 尚未 reload 时清理 XMP，C1 会用旧元数据覆盖新值）。`safeToCleanup` 门控是**正确性**问题而非体验问题。

### 2.3 最终设计

#### 2.3.1 同步状态机

```
                        ┌──────────────┐
                        │ disconnected │ ← 启动时/连接失败
                        └──────┬───────┘
                预检通过(运行中+文档已开+权限已授权)
                        ┌──────▼───────┐
                        │   connected  │ ← C1 可访问，无选中项
                        └──────┬───────┘
                选中 ≥1 个 variant（getSelectedPhotos 成功）
                        ┌──────▼───────┐
                        │  syncing     │
                        │  (gather     │
                        │   writing…)  │
                        └──────┬───────┘
                写回协调器全部 → written
                        ┌──────▼───────┐
                        │ c1Read       │ ← Gather 已写入，
                        │  (awaiting   │   C1 尚未 reload
                        │   load)      │
                        └──────┬───────┘
                用户点击 Load Metadata（或自动），
                reloadMetadata() 成功 + 延迟窗口已过
                        ┌──────▼───────┐
                        │ safeToCleanup │ ← C1 已读取，
                        │               │   清理 XMP 安全
                        └──────┬───────┘
                cleanup 完成，写回协调器 synced
                        ┌──────▼───────┐
                        │    synced    │
                        └──────────────┘
```

**判定记录 ✅ 保留**：状态机与 Adobe/Lightroom 的 XMP 双写模型同构；`safeToCleanup` 门控（reload 成功 + 延迟窗口）与现状注释的保守策略一致。

#### 2.3.2 会话级状态聚合规则（➕ 补充）

状态机是会话级，数据源是逐行。必须定义**确定性聚合**，否则 UI 状态与行状态漂移：

```
conflict 行 > 0        → conflict 态（Inbox P1）
否则 failed 行 > 0     → failed 态
否则 pending/writing   → syncing 态
全部 synced 且已 reload → safeToCleanup 态
```

#### 2.3.3 重启恢复（➕ 补充）

机器状态在内存，App 重启后丢失。**状态不落库，重启时从 DB 行状态重推导**（行是持久真相源，机器状态是派生值）；仅补一个持久标记：

```sql
ALTER TABLE sessions ADD COLUMN reload_acked_at TEXT;  -- C1 确认读取时间
```

- 行状态 + `reload_acked_at` 即可跨重启恢复 `safeToCleanup`，无需持久化整个状态机。
- `reload_acked_at` 只在 `reloadMetadata()` 成功后写入——保持"失败即回退、不清理"的保守策略。

#### 2.3.4 连接预检（Preflight）

新 IPC `c1:health`，主进程一次完成四层检查，返回结构化结果而非错误文本：

```ts
interface C1Health {
  reachable: boolean                    // osascript 能访问 System Events
  appRunning: boolean                   // 进程列表包含 "Capture One …"
  appName: string | null
  documentOpen: boolean                 // 试读 current document
  automationAuthorized: boolean         // TCC Apple Events 权限探测
  selectedCount: number                 // 当前选中 variants
  latencyMs: number                     // 最近一次脚本往返耗时
  lastError: string | null
  timestamp: string
}
```

- **自动化权限检测**：对 Capture One 执行一次无害 osascript（如 `get name of current document`），成功即视为已授权；失败且错误含 `not authorized / -1743` 时判定为权限被拒，UI 引导用户到 系统设置 → 隐私与安全性 → 自动化 授权 Gather。
- 预检结果决定状态机入口：`disconnected`（未运行）→ 引导启动；`connected`（已授权无文档）→ 提示打开文档；`ready`（全通过）→ 可导入/同步。

#### 2.3.5 UI 呈现

| 位置 | 内容 |
|------|------|
| 工作区头部胶囊 | 连接状态（绿/黄/红）+ 写回队列计数 + 最近同步时间 |
| 同步健康面板（Settings → Capture One） | 连接状态、队列计数（pending/written/synced/failed/conflict）、最近一次命令耗时（原始值，诊断超时配置用）、最近同步时间戳 |
| Load Metadata / Confirm Sync / Cleanup 按钮 | 可用性由状态机驱动，按钮旁显示状态文案（"Gather 已写入，等待 C1 读取" / "C1 已读取，可安全清理"） |
| **导入对话框**（➕ 补充） | Capture One 导入前先跑预检，显示四格检查结果再进入选择（现 `Dashboard/index.tsx:53-61` 直接 `getSelectedPhotos` 失败报错） |

判定记录：**✂️ 健康面板删除延迟均值/分位数统计**——对桌面单用户无决策价值，保留"最近一次命令耗时"一行原始值即可。

#### 2.3.6 错误码化（硬性依赖，与问题四联动）

`capture-one.ts` 的英文错误文本改为 `GatherErrorCode`（如 `C1_NOT_RUNNING` / `C1_NOT_AUTHORIZED` / `C1_NO_DOCUMENT`），渲染层经 i18n 映射。这是问题四的组成部分而非可选优化。

### 2.4 判定记录汇总

| 原设计元素 | 判定 | 理由 |
|------------|------|------|
| 四层预检 + `c1:health` 结构化返回 | ✅ | 每层有独立引导；-1743 判定有平台依据 |
| 七态状态机 + `safeToCleanup` 门控 | ✅ | 与 XMP 双写领域模型同构；正确性核心 |
| 按钮状态机驱动 | ✅ | 把状态还给 UI，消除认知负担 |
| 健康面板延迟均值统计 | ✂️ | 无决策价值 → 仅保留最近一次耗时原始值 |
| 会话级聚合规则 | ➕ | 不定义则 UI 状态与行状态漂移 |
| 重启恢复（重推导 + `reload_acked_at`） | ➕ | 机器状态易失，行状态是真相源 |
| 导入对话框预检接线 | ➕ | 现导入流程直接失败报错 |
| 错误码化 | ➕ | 与 i18n 联动，硬性依赖 |

### 2.5 落地路径

| 步骤 | 内容 |
|------|------|
| P0 | `c1:health` IPC + 四层预检；`CaptureOneSyncState` 模块 + 聚合规则 + 重启重推导 |
| P1 | 状态机接入写回协调器事件；Load/Cleanup 按钮状态化；导入对话框预检 |
| P2 | 健康胶囊 + Settings 面板 UI + Inbox 动作接线 |

---

## 3. 问题三：首次扫描上限——数量透明与一跳化修复

### 3.1 现状

`main/index.ts:384-417`：`app:scan-directory` 深度遍历，`MAX_SCANNED_FILES = 50_000` 时**静默截断**返回（`files.length >= MAX_SCANNED_FILES` 即 return），调用方无从得知截断：

- 渲染层 `Dashboard/index.tsx:50` 拿到截断后的 `files` 直接 `sessionApi.create(...)`。
- 进入工作区后 `SessionDetail/index.tsx:31-36` 触发 `indexerApi.scan`（后台索引补齐），但此时首屏数量已是"阶段性不完整"且无任何提示。

### 3.2 最佳实践基线（第一性原理）

**根本约束**：50k 上限是**内存/IPC 载荷**的上限（结构化克隆 5 万条字符串路径的开销），不是产品上限。真正的问题不是"上限"而是**数据流形状**：

```
现状（两跳，路径数组两次过 IPC）：
renderer ── scan-directory(≤50k 条路径) ──▶ main ── 返回路径数组 ──▶ renderer
renderer ── session.create(files) ──▶ main ── 写入 DB

正确形状（一跳，主进程内流式扫描 + 直接落库）：
renderer ── session.create(sourcePath) ──▶ main（fs.opendir 流式遍历 + 分批写 SQLite）
```

索引器已用 `fs.opendir` 流式遍历（`index.service.ts`），主进程内扫描天然无内存风险。**路径数组不再跨 IPC 后，50k 上限在数据层消失**，只作为"首次 UI 计数展示上限"存在。

### 3.3 最终设计

#### 3.3.1 根因修复：一跳化导入（P2，➕ 补充）

`session.create` 改为接受 `sourcePath`（或对 Capture One 来源接受文件列表，两者都无需扫描-返回-再提交两跳）：

- 主进程内流式扫描（复用 `IndexService` 的 walker）+ 分批写入 SQLite。
- 长任务复用现有 `JobService` 进度通道**分片上报**，避免 UI 长时间无反馈。
- 路径数组不再跨 IPC；`app:scan-directory` 保留（或删除）仅用于 UI 计数预览。

#### 3.3.2 扫描元数据（P0）

```ts
interface ScanResult {
  files: string[]
  truncated: boolean
  scannedTotal: number   // 实际遍历到的照片文件总数（即使被截断也计数）
  limit: number
}
```

- `scannedTotal` 持续累加，不因截断而停止计数。
- `truncated = scannedTotal > files.length`。
- IPC 契约同步更新（`IPC_CONTRACT.md`）；`sessions` 表加 `truncated_import` 标记列。

#### 3.3.3 精确总数与文案规范（P0/P1）

- **精确值**：索引完成后由 `IndexService` 用 SQL `COUNT(*)` 回写 `sessions.photo_total`，UI 优先显示精确值。
- **文案规范（➕ 补充，验收项）**：索引完成前，计数必须带"≥"前缀或显示"扫描中…"，**禁止把阶段计数当权威值**（"已导入 12,547 / ≥12,847"）。

#### 3.3.4 UI 呈现

- **Dashboard 创建时**：若 `truncated`，内联提示"目录超过 50,000 张照片，已导入前 50,000 张，剩余照片将在后台索引中补齐"。
- **工作区头部 / Control Center 索引卡片**：`已索引 12,547 / 12,847（98%）`，后台索引 job 运行时显示进度百分比，完成后自动消失。
- **进度事件**：复用 `gather:event` 的 `index:progress` 通道，渲染层订阅并常驻显示。

判定记录：**✂️ 删除"配置化上限（P2 设置项）"**——没有任何用户场景需要调整上限；一跳化后上限仅约束 UI 列表，调它无意义。**✅ 保留**透明性元数据与精确回填。

### 3.4 判定记录汇总

| 原设计元素 | 判定 | 理由 |
|------------|------|------|
| `ScanResult` 元数据 + `photo_total` 回写 | ✅ | 透明性正确；精确数来自索引后 COUNT |
| Dashboard 提示 + 头部进度 | ✅ | 与 Inbox scan_incomplete 联动 |
| 配置化上限设置项 | ✂️ | 过度设计，无用户场景 |
| 一跳化导入（主进程流式落库） | ➕ | 根因修复：消除 IPC 两跳，上限在数据层消失 |
| "≥"/"扫描中"文案规范 | ➕ | 防止阶段计数被误当权威值 |
| 分片上报进度 | ➕ | 长事务需复用 JobService 进度通道 |

### 3.5 落地路径

| 步骤 | 内容 |
|------|------|
| P0 | `ScanResult` 元数据 + IPC/契约更新 + Dashboard 提示 + 文案规范 |
| P1 | `sessions.photo_total` 精确值回写 + 头部进度条 |
| P2 | 一跳化：`session.create(sourcePath)` 主进程流式落库 + 分片进度 |

---

## 4. 问题四：i18n 体系

### 4.1 现状

- 27 个 renderer 文件含硬编码中文（`Culling.tsx` 137 处、`Settings/index.tsx` 81 处、`Similarity/index.tsx` 57 处…），另有英文硬编码（如 `Dialog.tsx:31` 的 `aria-label="Close"`、`main/index.ts:360` 的 `'Select photo directory'`）。
- 错误消息、按钮文案、菜单文案（Electron `Menu.buildFromTemplate`）、术语混杂。
- 无 i18n 层、无语言切换、无静态检查。

### 4.2 最佳实践基线（第一性原理）

目标分层：

1. 用户可见文本全部可翻译（正确性）；
2. 翻译缺失在编译/CI 期暴露而非运行期（可靠性）；
3. **主进程不负责文案，只负责错误码**（边界清晰）；
4. 语言来源单一（系统语言 + 设置覆盖）。

i18next 官方支持类型化 selector API（`t($ => $.key)`）、`count` 复数、插值，以及**多键回退**（`t(['error.404', 'error.unspecific'])`）——后者直接验证了"主进程抛错误码、渲染层映射文案"的写法：错误码正是动态 key 的典型场景。

### 4.3 方案选型

| 方案 | 结论 |
|------|------|
| i18next + react-i18next | ✅ 推荐。事实标准；本项目只是应用方，无理由自研（自研 t() 需重复实现插值/复数/回退） |
| 轻量自研 typed keys | 不采用：重复造轮子 |
| saveMissing / locize 后端 | ✂️ 明确排除：桌面应用无在线后端需求，saveMissing 会污染资源文件 |

### 4.4 最终设计

#### 4.4.1 目录与 Key 规范

```
desktop/src/renderer/locales/
├── zh-CN.json
├── en.json
└── index.ts            # 初始化 + useTranslation 导出
```

Key 规范（点分命名，按页面/域分组）：

```
workspace.stage.imported        "已导入"
workspace.stage.indexed         "已索引"
inbox.action.analyze            "重新分析"
c1.status.safeToCleanup         "C1 已读取，可安全清理"
culling.action.confirm          "确认"
error.import.folderEmpty        "所选文件夹没有可导入的照片"
```

#### 4.4.2 边界分工

- **错误消息策略**：主进程抛 `GatherErrorCode`（`C1_NOT_RUNNING`、`SCAN_LIMIT_REACHED`…），渲染层统一映射文案。禁止主进程返回拼接文案（现 `capture-one.ts` 的错误文本全部转为错误码）。
- **事件负载代码化（➕ 补充）**：`index:progress` 的 `progressMessage`、`models:download-progress` 等**事件推送**若含自然语言（现 `Similarity/index.tsx:271` 直接显示 `progressMessage`），主进程必须改为"阶段码 + 参数"，渲染层翻译。原方案只覆盖了 IPC 返回值，未覆盖事件推送。
- **Electron 菜单**：`appMenuTemplate` 按当前 locale 生成（`app.getLocale()`，支持 `--lang` 覆盖），语言切换后重建菜单。
- **数字/日期**：`Intl.NumberFormat / DateTimeFormat`，不手拼 "12,847 张照片"。
- **复数**（➕ 补充）：文案含数字的一律用 i18next `count` 参数而非字符串拼接（中文无复数形态，但英文需要 `1 conflict / 2 conflicts`，现在拼好避免返工）。

#### 4.4.3 迁移策略（复核后：eslint 守护先行 + 页面级人工迁移）

判定记录：**✂️ 删除 AST codemod**——对 JSX 文本、模板字符串、插值混合场景错误率高，且生成的无上下文占位 key 仍需全部人工复查，省不了审校时间，是"看起来自动化的手动工作"。机器只做检测，不做改写。

| 步骤 | 内容 | 方法 |
|------|------|------|
| P0 | 建立 i18n 框架、zh-CN/en 双文件、类型化 key 推导；**术语表先行**（浏览/Gallery、挑片/Culling、写回/Writeback、冲突/Conflict…），冻结后再迁移 | 手写 |
| P1 | 按页面人工迁移：7 个页面 + 10 个组件，**每个 PR 一个页面**，迁移中完成 key 命名审校 | 人工 |
| P2 | 静态守护：eslint 规则禁止 JSX 文本节点与 `aria-label` 中出现非 i18n 字符串（或 CI 扫描含 CJK/英文句子的 JSX 文本） | CI |

预计迁移规模：~500–700 处；页面级人工迁移 + 审校约 2 周（无 codemod 反而更快，因为无返工）。

### 4.5 判定记录汇总

| 原设计元素 | 判定 | 理由 |
|------------|------|------|
| i18next + react-i18next + 类型化 key | ✅ | 事实标准；类型化 + 多键回退验证错误码映射 |
| 主进程只抛错误码 | ✅ | 本地化在边缘原则 |
| zh-CN/en 双文件 + 点分 key | ✅ | key 即契约 |
| 菜单按 locale 重建 | ✅ | `app.getLocale()` + `Menu.setApplicationMenu` |
| 数字/日期用 Intl | ✅ | 正确分工（i18next 不负责数字） |
| AST codemod 机械迁移 | ✂️ | 过度设计 + 高风险 → eslint 守护先行 + 页面级人工迁移 |
| saveMissing / locize | ✂️ | 无在线后端需求 |
| 事件负载（progressMessage 等）代码化 | ➕ | 原方案遗漏事件推送通道 |
| 术语表先行 | ➕ | 防止两语言文件各自翻译同一术语 |
| count 参数化 | ➕ | 中文无复数但英文有，避免返工 |

### 4.6 落地路径

| 步骤 | 内容 |
|------|------|
| P0 | 框架 + 双语文案 + 类型化 key + 术语表 |
| P1 | 页面级迁移（7 页面 + 10 组件，PR 粒度）+ 事件负载代码化 + 主进程错误码化 |
| P2 | eslint 守护 + 审校 + 菜单本地化 |

---

## 5. 问题五：无障碍

### 5.1 Dialog 焦点管理（P0）

`Dialog.tsx` 现状：Escape 关闭、`role="dialog" aria-modal="true"` 已有基础，但**无焦点陷阱、无打开时聚焦、无关闭后焦点恢复、无 `aria-labelledby`**（目前用 `aria-label`，标题不是 id 引用）、背景无 `inert`。

**最佳实践基线**（W3C ARIA APG Dialog 模式，硬性要求）：

1. 打开时焦点移入对话框内元素；**初始焦点按内容选择：不可逆操作聚焦"最不具破坏性的动作"**；
2. Tab / Shift+Tab 在对话框内循环（焦点陷阱）；
3. Esc 关闭；
4. **关闭后焦点返回触发元素**（除非该元素已消失）；
5. `aria-modal="true"`，且代码层面阻止与外部内容交互（`inert` 是现代表达）；
6. `aria-labelledby` 引用可见标题（优于 aria-label）；
7. `aria-describedby` **仅在描述简单时使用**——内容含列表/段落等语义结构时应省略；
8. 对话框内必须有可见关闭按钮。

目标实现（组件自包含，参考 a11y-dialog 的成熟模式）：

```tsx
interface DialogProps {
  open: boolean
  onClose: () => void
  title: string
  children: React.ReactNode
  /** ➕ 补充：APG 要求不可逆操作初始聚焦"最不具破坏性的动作"（如删除确认的"取消"） */
  initialFocus?: React.RefObject<HTMLElement | null>
  /** ➕ 补充：仅当正文是简单描述时提供；复杂内容（列表/报表）必须省略 */
  descriptionId?: string
}

export default function Dialog({ open, onClose, title, children, initialFocus, descriptionId }: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const restoreRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return
    restoreRef.current = document.activeElement as HTMLElement      // 记录触发元素
    const panel = panelRef.current
    const focusTarget = initialFocus?.current
      ?? panel?.querySelector<HTMLElement>('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')
    focusTarget?.focus()
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'Tab') return
      const focusables = Array.from(
        panel!.querySelectorAll<HTMLElement>('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'),
      ).filter((el) => !el.disabled)
      if (focusables.length === 0) { e.preventDefault(); return }   // 边界：焦点未进入也不逃逸
      const first = focusables[0]
      const last = focusables[focusables.length - 1]
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus() }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      restoreRef.current?.focus()                                    // 关闭后恢复焦点
      restoreRef.current = null
    }
  }, [open, initialFocus, onClose])

  if (!open) return null
  return (
    <div className={styles.overlay}>
      <div
        className={styles.dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby="dialog-title"
        aria-describedby={descriptionId}                             // 复杂内容时传 undefined（自动省略）
        ref={panelRef}
      >
        <h2 className={styles.title} id="dialog-title">{title}</h2>
        …
      </div>
    </div>
  )
}
```

补充：打开时给背景容器（`Layout` 主区域）加 `inert` 属性（或维护 `aria-hidden`），阻止读屏越界；`ConfirmDialog`（继承自 Dialog）自动获得相同能力，并为删除/不可逆操作传入 `initialFocus`（取消按钮）。

**可选优化（P1，非必须）**：原生 `<dialog>.showModal()`（Chromium 内置，自动焦点陷阱 + `::backdrop` + 背景 inert）可消除自研陷阱代码，但要求 Dialog 从"条件渲染"改为"常驻挂载 + showModal"，改动面略大。二选一即可，两者皆符合 APG。

### 5.2 相似度组件的键盘语义（P0）

`Similarity/index.tsx:316`：`groupHeader` 是 `div onClick`，键盘/读屏不可达。

判定记录：**✂️ 不采用 roving tabindex（APG grid 模式）**。APG Grid 的价值是压缩**长/虚拟化列表**的 tab 停留数；相似组列表是 ≤100 个按钮的自然 Tab 顺序即可访问的静态列表，实现 role=grid + gridcell + 方向键漫游的复杂度远超收益，是最典型的"照着模式手册过度实现"。仅当将来列表虚拟化/超过数百项再引入，留注释。

最终设计：组头为语义化按钮 + checkbox 独立并列（HTML 禁止 button 嵌套 input）：

```tsx
<article className={styles.groupCard}>
  <div className={styles.groupHeaderRow}>
    <input
      type="checkbox"
      checked={selected}
      onChange={(event) => onSelectedChange(event.target.checked)}
      aria-label={`选择 ${group.label}`}
      className={styles.groupCheckbox}
    />
    <button
      type="button"
      className={styles.groupExpand}
      onClick={() => setExpanded(!expanded)}
      aria-expanded={expanded}
    >
      <ThumbnailImage path={rep.path} className={styles.groupThumb} />
      <span className={styles.groupInfo}>
        <span className={styles.groupLabel}>{group.label}</span>    {/* 不能用 h3：button 只允许 phrasing 内容 */}
        <span className={styles.groupCount}>{group.count} 张照片</span>
      </span>
      <span aria-hidden="true" className={styles.expandIcon}>{expanded ? '▾' : '▸'}</span>
    </button>
  </div>
  {expanded && <div className={styles.groupMembers}>…</div>}
</article>
```

注意点：
- 展开状态由 `aria-expanded` 表达；展开区由 DOM 存在性控制，无需额外 aria-hidden。
- `GroupGrid` 的缩略图若可点击，需同为 button/链接。
- 过滤逻辑的可点击 div/span（如状态筛选条）同样改为按钮/分段控件。

### 5.3 全局无障碍审计（P1）

| 项目 | 范围 | 方法 |
|------|------|------|
| 对比度 | 全站 | CSS 变量色板做 WCAG AA（4.5:1 正文 / 3:1 大文本）检查 |
| 焦点可见性 | 全站 | 统一 `:focus-visible` 样式，禁止 `outline: none` 无替代 |
| 语义化 | 全站 | 可点击元素全部 `button/a`；aria-label 全部 i18n 化（承接第 4 章） |
| 读屏冒烟 | 关键流程 | VoiceOver 走查：创建工作区 → 导入 → 分析 → 导出 |
| 回归 | CI | `jest-axe` 组件测试（Dialog、Similarity、Dashboard 关键路径），含焦点陷阱边界用例 |

### 5.4 判定记录汇总

| 原设计元素 | 判定 | 理由 |
|------------|------|------|
| 焦点陷阱 + 恢复 + aria-labelledby + inert | ✅ | 与 APG 1–6 完全对齐 |
| 相似组 roving tabindex（grid 模式） | ✂️ | 静态 ≤100 项列表无需 grid；虚拟化时再引入 |
| 全局审计（对比度/focus-visible/jest-axe/VoiceOver） | ✅ | 最低成本正确性保障 |
| 自研 Dialog（无第三方依赖） | ✅ | a11y-dialog（1.6KB）是验证过的同构参考；原生 `<dialog>` 为 P1 可选 |
| `initialFocus` prop | ➕ | APG：不可逆操作聚焦最不具破坏性动作 |
| `descriptionId` 可选 prop | ➕ | APG：复杂内容省略 describedby |

### 5.5 落地路径

| 步骤 | 内容 |
|------|------|
| P0 | Dialog 焦点管理（含 initialFocus/descriptionId）+ Similarity 键盘语义 |
| P1 | 全站审计 + jest-axe + VoiceOver 冒烟；（可选）原生 `<dialog>` 评估 |

---

## 6. 总体实施路线图

```
阶段 A（第 1–2 周）：地基
  ├─ i18n P0（框架 + 双语文案文件 + 类型化 key + 术语表）
  ├─ 无障碍 P0（Dialog 焦点管理 + Similarity 键盘语义）
  └─ 扫描元数据 P0（ScanResult + 契约 + Dashboard 提示 + 文案规范）

阶段 B（第 3–5 周）：任务中心与 C1 状态机
  ├─ analysis_runs / index_seq（DB 迁移 + 写入点）
  ├─ WorkspaceStatusService + IPC + useWorkspaceStatus（含离线 TTL）
  ├─ Workspace Control Center UI（阶段条 + Action Inbox + 推荐动作）
  ├─ c1:health 预检 + CaptureOneSyncState 状态机（聚合规则 + 重启重推导）
  ├─ i18n P1 开始（页面级 PR 迁移 + 事件负载代码化 + 主进程错误码化）
  └─ 扫描根因修复：session.create(sourcePath) 一跳化（可分拆）

阶段 C（第 6–7 周）：打磨与收口
  ├─ C1 健康胶囊/面板 UI + 导入对话框预检 + Inbox 接线
  ├─ i18n P2（eslint 守护 + 审校 + 菜单本地化）
  ├─ 无障碍 P1（全站审计 + jest-axe）
  └─ 文档同步（IPC_CONTRACT.md、ROADMAP.md、ADR 记录）

每阶段独立可交付，不阻塞后续版本发布；验收标准见第 7 章。
```

## 7. 验收标准

> 复核记录（2026-08-08）：19/20 项通过代码/单测验证；唯一未勾选项为 VoiceOver 手工走查（人工执行，清单见 docs/a11y-audit.md §4）。证据为 file:line 指针；全套 `npm run typecheck` / `npm run lint --workspace=desktop` / `npm run test:vitest`（91 文件 558 用例）绿。

**问题一（任务中心）**
- [x] 新用户进入工作区 5 秒内能说出"当前阶段 + 最多 3 条待办 + 推荐下一步"（ControlCenter/index.tsx:90-159 阶段条+Inbox+推荐；SessionDetail/index.tsx:191 index 路由 = Control Center；Dashboard/index.tsx:218,323 跳转 /sessions/:id）
- [x] 索引新增照片后，Inbox 在 ≤30s 内出现"分析过期"条目（index.service.ts:946-947 提交点 bump index_seq；similarity.service.ts:198/face-kw.service.ts:109 分析入口写 analysis_runs；workspace-status.service.ts:87-94 过期判定；useWorkspaceStatus.ts:10,27-46 轮询 30s + jobs:progress/culling:sync-status 事件失效）
- [x] Inbox 每条动作可一键跳转对应模块（workspace-view.ts:66-152 deriveInboxItems 的 navigate/retry-job 动作目标；ControlCenter/index.tsx:130-137 动作按钮）
- [x] "indexed"阶段判定以索引 job 成功记录为准（自动化测试）（workspace-status.service.ts:80 `scanJob.status==='succeeded'`；tests/unit/services/workspace/workspace-status.test.ts:158-171 含活跃 job 回退用例）
- [x] 离线照片复核受 TTL（≥5 分钟）约束（workspace-status.service.ts:23 OFFLINE_PHOTOS_TTL_MS=5min + 缓存判定 :249-262；workspace-status.test.ts:267-284 假时钟 TTL 测试）

**问题二（C1 状态机）**
- [x] 未运行 C1 / 未授权自动化（-1743）/ 未打开文档 三种失败都有专属预检结果与引导（c1-health.ts:76-133 四层逐层降级 + isAutomationDeniedMessage :38；c1-preflight.ts:66-85 分键引导文案；tests/unit/renderer/c1-preflight.test.ts 10 用例）
- [x] 导入对话框先预检后进入选择（Dashboard/index.tsx:254-262 handleCreate 预检不过直接 return，不调 getSelectedPhotos；:447-473 四格内联渲染）
- [x] 会话级聚合规则（conflict > failed > pending > synced）有单测覆盖（sync-state.ts:56-86 aggregateSessionState；tests/unit/services/capture-one/sync-state.test.ts:19-104 九用例含 clean/cleaned 与未知态保守处理）
- [x] 重启后状态从 DB 行重推导；`reload_acked_at` 写入后才可恢复 `safeToCleanup`（sync-state.ts:98-115 deriveSessionState 从 outbox+ack 重推导；capture-one.ts:149-151 reloadMetadata 成功后才写 ack；sync-state.test.ts:49-58 ack 门控用例；migration-31.test.ts 持久化）
- [x] 状态机转换全部可观测（日志 + 健康胶囊）（sync-state.ts:145-155 reportTransition 初始/转换日志；C1StatusCapsule.tsx 头部胶囊 + Settings/C1HealthPanel.tsx）

**问题三（扫描透明）**
- [x] >50,000 张目录导入时，创建流程明示截断与后台补齐；计数带"≥"/"扫描中"前缀（scan-directory.ts:54 ScanResult{truncated,scannedTotal,limit}；Dashboard/index.tsx:209 truncatedToast；:353 photoCountLabel ≥ 前缀/scanning 文案）
- [x] 工作区头部索引进度实时可见，完成后显示精确总数（SessionDetail/index.tsx:148-178 头部进度条/错误重试/精确计数；indexProgress.ts 完成态仅 succeeded 后呈现精确值；index.service.ts:944-945 COUNT(*) 回写 photo_count）
- [x] `session.create(sourcePath)` 一跳化后路径数组不跨 IPC（回归测试）（packages/shared/src/protocol/session.ts:17-20 参数仅 {name?,sourcePath}；tests/unit/services/session-create-from-directory.test.ts:98-107 expectTypeOf 编译期守卫）

**问题四（i18n）**
- [x] renderer 无硬编码界面文案（CI 扫描零告警）（`rg CJK renderer` 0 非注释命中；eslint.config.js:67,76 `gather/no-hardcoded-text` 规则 'error' 接线 + desktop/eslint/no-hardcoded-text.cjs 单测；`npm run lint --workspace=desktop` 通过）
- [x] zh-CN / en 双语可一键切换，菜单/错误/按钮/事件推送文案全覆盖（Settings/index.tsx:111,184,546-551 语言选择器（label[htmlFor] 关联）+ setLanguage→initI18n 即时切换；settings.ipc.ts:33-40 `settings.set_language` 持久化 ui_language + setAppLocale 重建菜单；menu.ts 双语言 label + rebuild/setAppLocale（tests/unit/services/menu-localization.test.ts 覆盖 zh/en 构建与切换重建）；utils/errors.ts translateError 错误码映射；utils/progress.ts translatePhase 事件阶段码映射）
- [x] 主进程无自然语言文案（只含错误码/阶段码）（`rg CJK main` 仅 report.service.ts/export.service.ts 文档内容（ADR-017 例外）+ menu.ts 双语言 label 表 + 注释；metadata-sync-coordinator.ts 已全部转为 XMP_* 错误码；残留英文 throw 为内部不变量/运维诊断，不经 translateError 面向用户。观察项：sync-state.ts:150,152 console.log 含中文，为开发日志非 UI 文案）
- [x] 术语表冻结后两语言文件术语一致（抽查）（docs/i18n-glossary.md 已冻结；程序化 key 奇偶校验 zh-CN.json/en.json 各 1063 key、0 差异）

**问题五（无障碍）**
- [x] 键盘可完整操作：Dialog 打开聚焦、Tab 循环、Esc 关闭、关闭恢复焦点；删除确认初始聚焦"取消"（Dialog.tsx:42-77 聚焦/陷阱/恢复 + :20-25 inert；ConfirmDialog.tsx:34 destructive→initialFocus 取消按钮；tests/unit/renderer/dialog.test.tsx 10 用例含零可聚焦边界）
- [x] 相似组可 Tab 到达、Space/Enter 展开、可勾选；aria-expanded 正确（Similarity/index.tsx:328-347 并列 checkbox + aria-expanded 按钮；tests/unit/renderer/a11y-similarity.test.tsx 组头区零违规）
- [ ] VoiceOver 走查关键流程无阻断性问题；jest-axe 全绿（含焦点陷阱边界用例）（jest-axe ✅：a11y-dialog/a11y-similarity/a11y-dashboard 8 用例全绿，F-1/F-2 修复后改为零违规断言，含焦点陷阱边界；**VoiceOver ⏳ 人工待执行**——docs/a11y-audit.md §4 清单（4.1-4.4 共 19 项）尚未勾选，须人工在 macOS 上执行）

## 8. 风险与注意事项

| 风险 | 说明 | 缓解 |
|------|------|------|
| index_seq 与多任务并发写 | 并发索引与并发分析可能竞争计数 | `index_seq` 更新走单写事务；分析读取用事务快照 |
| 状态机误判导致 XMP 清理事故 | 最严重的正确性风险 | 保持"失败即回退、不清理"的保守策略；默认不自动 reload，由用户确认；`reload_acked_at` 仅在 reload 成功后写入 |
| i18n 迁移期间中英混杂 | 页面级迁移可能引入上下文错误 | 分页面迁移 PR；术语表先行；每 PR 附审校清单 |
| TCC 权限探测可能弹系统弹窗 | 首次探测 osascript 会触发授权弹窗 | 探测前 UI 明确告知原因；用户拒绝时降级为"手动确认"模式 |
| 一跳化导入重构回归 | `session.create` 改动触及 Dashboard 导入主流程 | 复用现有 JobService 进度通道；导入流程回归测试先行 |
| 无障碍改造影响现有测试 | Similarity/Dialog 改动会触及既有快照/交互测试 | 同步更新 `tests/` 下相关用例 |
| 原生 `<dialog>` 评估（可选） | 若采纳，需迁移 Dialog 挂载方式 | 作为独立 PR 评估，可随时回退 |

---

## 附：变更记录

- **v2.0（合并复核结论）**：与复核文档合并；删除 4 项过度设计（推荐规则引擎、culled/exported 硬阶段、配置化扫描上限、AST codemod、相似组 roving tabindex、健康面板延迟均值、saveMissing/locize）；新增 14 项补充（indexed 判定、离线 TTL、C1 聚合规则、重启重推导、导入预检、错误码化、一跳化导入、"≥"文案规范、事件负载代码化、术语表先行、count 参数化、initialFocus、descriptionId、分片上报）；工作量 8 周 → 6–7 周。
