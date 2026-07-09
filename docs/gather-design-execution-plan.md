# Gather 统一设计与执行计划

日期：2026-07-09

## 文档定位

本文件合并并取代原有两个设计文档：

- `docs/functional-design-plan.md`
- `docs/frontend-visual-design-execution-plan.md`

合并后的目标不是把两个文档机械拼接，而是把功能工作流计划和前端视觉计划放到同一条执行线上：先保证写回、安全、状态和数据契约可靠，再在同一套 UI 结构上做视觉工作台化，避免 API 层和 UI 层互相返工。

## 当前实现状态

### 已实现

- Session 已支持导入来源：`import_source` 已进入 shared protocol、数据库迁移、session model 和 Dashboard badge 生成逻辑。
- Dashboard 已支持 Capture One 导入和本地文件导入。
- Dashboard 已有批量删除入口，并使用 `typedConfirmDialog()` 做强确认。
- Similarity 已有 `preview_writeback`、`writeback_items`、`retry_failed_writeback` 的后端/协议/API 基础。
- Similarity 执行写回前已经调用 preview，并用 dialog 做继续确认。
- `writeback_items` 表已存在，并包含 `module`、`attempt_count`、`last_attempt_at` 等共享审计字段。
- Face KW 已有 `preview_writeback`、`confirm_sync`、`cleanup`、`confirm_cleanup` 等命令基础。
- Face KW 已把确认同步和 cleanup 拆成两个 UI 动作。
- Similarity 和 Face KW 都已有取消分析按钮和取消反馈。
- 前端已有 Dashboard、Similarity、Face KW、dialog、dom、toast 等 Jest 测试基础。

### 部分实现

- 统一 XMP writeback lifecycle 已有后端雏形，但 Face KW 和 Similarity 的 UI 流程、命令命名、失败详情、retry 体验仍不一致。
- Dashboard session health 已有 `failed_writeback_count`，但还没有完整健康状态、失败详情入口、cleanup deferred 状态。
- Import source awareness 已有数据字段和 badge 生成，但 badge CSS 缺失导致视觉上没有完整落地。
- Similarity writeback preview 已进入执行前确认，但还不是完整 preview table / warning review。
- Face KW 已有五步流程和基础批量能力雏形，但仍是 wizard 型界面，不是高效 review workspace。
- CSP inline style 问题已被注释识别，但实际 renderer 仍大量使用 inline style。

### 未实现

- Packaged app runtime 策略尚未定稿：开发者工具模式还是面向摄影师的打包应用模式仍需产品决策。
- `engine.health` / startup health check 尚未形成完整用户可见诊断。
- cleanup deferral 未实现：没有 `cleanup_status`、`cleanup_deferred_at` 或可恢复的 deferred cleanup UI。
- Face KW 缺少与 Similarity 对齐的 `writeback_items` / `retry_failed_writeback` 用户路径。
- Dashboard 没有完整 session health 工作台。
- 全局视觉系统仍是旧版深蓝 + 红色 accent + wizard/stepper 风格。
- 主导航仍被建模为 wizard，而不是 app shell。
- Dashboard、Similarity、Face KW 的照片优先工作台界面尚未完成。
- 响应式视觉 QA 尚未系统执行。

## 合并后的执行原则

1. 功能计划优先定义 API、数据状态和生命周期，视觉计划随后承接 UI 表达。
2. Dashboard、Similarity、Face KW 的 UI 改造必须复用同一套状态、badge、toolbar、dialog、writeback preview 组件。
3. 不再维护独立的“功能路线图”和“视觉路线图”，避免同一页面被两个计划以不同顺序反复改造。
4. 不把 CSP `unsafe-inline` 消除误判为小任务；先减少关键入口和共享组件 inline style，再逐页迁移。
5. Face KW review workspace 是高风险重构，必须拆成视觉结构和交互效率两阶段。

## P0：基础一致性与真实 bug 修复

### Phase 0.1：修复 Dashboard badge 样式缺失

状态：未实现，真实 bug。

涉及位置：

- `desktop/src/renderer/pages/dashboard.ts`
- `desktop/src/renderer/styles/style.css`
- `desktop/src/renderer/pages/dashboard.test.ts`

问题：

`dashboard.ts` 生成了以下 badge：

- `badge--source`
- `badge--analyzed`
- `badge--writeback-done`
- `badge--writeback-partial`
- `badge--cleaned`
- `badge--failed`

但 `style.css` 目前主要定义的是：

- `badge--draft`
- `badge--analyzing`
- `badge--review`
- `badge--photos_loaded`
- `badge--completed`

两者不匹配，导致 Dashboard 中多个真实状态 badge 处于无语义样式状态。

目标修改：

- 补齐 Dashboard 实际生成的 badge class。
- 将 source、analysis、writeback、failure 分成不同语义颜色。
- 红色只用于 failed/danger，不用于普通 primary。
- 给 `dashboard.test.ts` 增加至少一个覆盖 source/analyzed/writeback/failed badge 的断言。

预期收益：

- 修复当前用户可见 UI bug。
- 为 Dashboard session health 后续落地打基础。

验收：

- Dashboard 中所有 `statusBadge()` 生成的 class 都能在 CSS 中找到。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run typecheck`
- `npm --prefix desktop run lint`
- `npm --prefix desktop run build`

### Phase 0.2：视觉 token、基础状态组件和 app shell 类名一次落地

状态：未实现。

涉及位置：

- `desktop/src/renderer/styles/style.css`
- `desktop/src/renderer/index.html`
- `desktop/src/renderer/app.ts`
- `desktop/src/renderer/components/dialog.ts`

问题：

原视觉计划把 token/基础组件和导航 app shell 拆成两个 phase，但两者都要修改 `style.css` 和 `index.html`。如果先保留 `.wizard` / `.stepper`，后续还要返工。

目标修改：

- 重建全局 token：surface、text、border、accent、danger、success、warning、focus。
- 主色从警示红调整为更适合照片工作台的低饱和蓝绿/中性蓝。
- 红色仅用于删除、失败、危险操作。
- 在 Phase 0.2 就落地类名规划：
  - `.app-shell`
  - `.app-sidebar`
  - `.app-main`
  - `.app-nav`
  - `.app-nav-item`
  - `.app-nav-item--active`
  - `.app-nav-item--disabled`
- 建立共享状态组件：
  - `.state-panel`
  - `.state-panel__icon`
  - `.state-panel__title`
  - `.state-panel__body`
  - `.app-loading`
  - `.app-error`
- `index.html` 的 loading/error inline style 迁移为 class。
- `dialog.ts` 的 typed confirm input inline style 迁移为 class。

预期收益：

- 视觉底座和导航命名一次成型，避免 Phase 1/2 返工。
- 启动、错误、空状态更像完整产品。
- 后续页面可以直接复用 app shell 和 state-panel。

边界：

- 本阶段不承诺彻底移除 CSP `unsafe-inline`。
- 不大改 Dashboard、Similarity、Face KW 页面结构。

验收：

- 主界面不再依赖 `.wizard` 作为 app shell 命名。
- 启动中、preload 不可用、引擎超时、页面加载失败都使用统一状态组件。
- 现有导航行为不变：无 session 时 Similarity / Face KW 仍不可进入。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run typecheck`
- `npm --prefix desktop run lint`
- `npm --prefix desktop run build`

## P1：写回生命周期和 Dashboard 工作台

### Phase 1.1：统一 XMP writeback lifecycle 的剩余 API/数据契约

状态：部分实现。

涉及位置：

- `packages/shared/src/protocol.ts`
- `desktop/engine/engine.py`
- `shared/db.py`
- `shared/session_manager.py`
- `face_keywording/service.py`
- `similarity/service.py`
- `desktop/src/renderer/api.ts`

已实现基础：

- `writeback_items` 表已存在。
- Similarity 已有 preview/items/retry。
- Face KW 已有 preview/confirm/cleanup。
- Session 已有 `writeback_status` 和 `failed_writeback_count`。

仍需补齐：

- Face KW 对齐 Similarity 的 `writeback_items` 和 `retry_failed_writeback` 用户路径。
- 统一 preview response shape，至少稳定 summary、items、warnings。
- cleanup deferral 状态：
  - `cleanup_status`
  - `cleanup_deferred_at`
  - `last_writeback_module`
- 写回失败详情要能从 Dashboard 进入模块详情。
- `confirm_cleanup` 只能作为兼容 wrapper，UI 应使用 confirm sync + cleanup/defer。

目标 lifecycle：

1. Plan
2. Preview
3. Execute
4. Review Failures
5. Retry
6. Confirm Sync
7. Cleanup or Defer

预期收益：

- Face KW 和 Similarity 对“写入元数据”使用同一套词汇和恢复模型。
- Dashboard health 可以从同一张审计表读取状态。
- UI 改造不会被后端状态缺口卡住。

验收：

- Similarity 和 Face KW 都能查询 file-level writeback items。
- 失败项 retry 不会重复处理成功项。
- cleanup 可延后，并能从 session 状态恢复入口。
- Python 单测覆盖 preview/execute/retry/cleanup 状态。
- `uv run pytest`
- `npm --prefix desktop test -- --runInBand`

### Phase 1.2：Dashboard 工作台化与 session health

状态：部分实现。

涉及位置：

- `desktop/src/renderer/pages/dashboard.ts`
- `desktop/src/renderer/styles/style.css`
- `desktop/src/renderer/pages/dashboard.test.ts`
- `shared/session_service.py`
- `shared/session_manager.py`

已实现基础：

- Session list。
- Capture One / local files 导入。
- Source badge 生成逻辑。
- `failed_writeback_count`。
- needs-review / completed filter。
- 强确认批量删除。

仍需补齐：

- Dashboard 不应像 landing hero，应改为工作台。
- 增加 session summary：总数、待处理、失败、清理待处理。
- Session row 明确展示来源、照片数、分析状态、写回状态、失败数、cleanup 状态。
- 失败状态提供进入详情/重试路径。
- Delete All 降低视觉权重，避免抢主操作。
- Filter 改为通用 segmented control。

预期收益：

- 用户打开应用即可知道哪些 session 需要继续处理。
- 写回生命周期的状态能被 Dashboard 承接。
- 首页从介绍页变为真实工作台。

验收：

- 空状态、加载失败、有 session、导入后刷新四种状态视觉一致。
- 所有 badge 有样式和测试覆盖。
- Dashboard tests 覆盖 filters、source badge、failed count、bulk delete。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run build`

## P1：Similarity 照片优先审阅与 writeback preview

### Phase 2：Similarity review surface

状态：部分实现。

涉及位置：

- `desktop/src/renderer/pages/similarity.ts`
- `desktop/src/renderer/styles/style.css`
- `similarity/service.py`
- `desktop/src/renderer/api.ts`

已实现基础：

- 分析、取消、recluster、结果展示。
- 选择组、写回 options。
- 执行前调用 `previewWriteback()`。
- 写回后 modal report。
- Similarity 后端已有 writeback items 和 retry。

仍需补齐：

- Preview UI 从 dialog 文本升级为可审阅的 preview panel/table。
- Group card 改为照片优先：代表图更大，文件路径降权。
- 控件收束为 review toolbar。
- Writeback action footer 展示已选组数、影响照片数、将执行动作、warning 数。
- Select all / deselect all 改为明确控件，不使用文字链接加竖线。
- 失败详情和 retry 入口接入 shared writeback_items。

功能计划协调：

- API 层 preview/items/retry 优先稳定。
- UI 层再做 photo-first review surface，避免 preview schema 变化导致 UI 重做。

预期收益：

- 相似分组质量判断更快。
- 写回前可见影响范围和风险。
- 与统一 writeback lifecycle 对齐。

验收：

- 分析前、分析中、结果为空、结果多组、preview warning、写回失败都可视化。
- 缩略图失败有稳定占位。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run typecheck`
- `npm --prefix desktop run lint`
- `npm --prefix desktop run build`

## P2：Face KW 视觉结构与响应式

### Phase 3a：Face KW review workspace 视觉结构

状态：未实现，高风险。

涉及位置：

- `desktop/src/renderer/pages/face-kw.ts`
- `desktop/src/renderer/styles/style.css`
- `desktop/src/renderer/api.ts`

风险说明：

Face KW 当前文件约 700 行以上，且五步 wizard 与状态、事件绑定、`renderClusters()`、`loadBind()`、preview/writeback 紧密耦合。把 cluster grid 和 bind form 合并为左右分栏，会实际影响 DOM 结构和事件绑定，不能当成普通 CSS 调整。

目标修改：

- 保留业务状态机，先做视觉结构重排。
- 将 Cluster Review + Bind 合并为 review workspace：
  - 左侧/中间：cluster grid。
  - 右侧：sticky detail panel，包含预览、人脸成员、角色名、关键词、skip/save/merge 操作。
- 五步 stepper 降级为轻量 workflow status：Analyze、Review、Writeback。
- Preview / Writeback 作为最终确认区或 drawer，不再与 review 等重量。
- `fkw-filter-btn` 迁移到通用 segmented control。

不做：

- 不在 3a 中新增快捷键。
- 不在 3a 中新增大批量操作。
- 不在 3a 中彻底重写 Face KW 状态机。

预期收益：

- 标注过程更像照片/人脸审阅工具，而不是五页表单。
- 降低频繁 Next/Back 的视觉负担。

验收：

- Analyze、cancel、filter、select cluster、bind、skip、merge、preview、writeback 都能走通。
- 现有 Face KW 行为不退化。
- 增加必要 renderer tests 或手动 smoke checklist。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run build`

### Phase 3b：响应式和视觉 QA

状态：未实现。

涉及位置：

- `desktop/src/renderer/styles/style.css`
- `desktop/src/renderer/pages/dashboard.ts`
- `desktop/src/renderer/pages/similarity.ts`
- `desktop/src/renderer/pages/face-kw.ts`

目标修改：

- 为 page header、toolbar、review grid、action footer、modal、toast 增加稳定 responsive constraints。
- 检查 Electron 窗口缩窄时的布局。
- 不使用 viewport width 缩放字体。
- 长按钮文案在窄宽度下换行或降级为紧凑布局。

验收尺寸：

- 1280x800
- 1024x768
- 800x700
- 560x700

验收：

- Dashboard、Similarity、Face KW、modal、toast、loading/error 状态无明显重叠。
- 图片网格和 action footer 不互相遮挡。
- `npm --prefix desktop test -- --runInBand`
- `npm --prefix desktop run build`
- 有条件时运行 renderer dev server 并截图检查。

## P3：Face KW 高效交互与打包运行时

### Phase 4a：Face KW 高效交互

状态：未实现。

对齐原功能计划：Milestone 4 High-Volume Workflow。

涉及位置：

- `desktop/src/renderer/pages/face-kw.ts`
- `face_keywording/service.py`
- `packages/shared/src/protocol.ts`

目标修改：

- 快捷键：保存并下一个、跳过、聚焦关键词、返回 cluster grid。
- 批量操作：批量跳过、批量命名、批量合并候选。
- 更清楚的 multi-face / low-confidence 提示。
- 失败项 retry 与 Dashboard health 打通。

预期收益：

- 面向大量人脸照片时操作效率提升。
- 与功能计划中的 Face Keywording Batch Efficiency 对齐。

验收：

- 快捷键有可测试逻辑或 smoke checklist。
- 批量操作有明确确认与撤销/恢复策略。
- 不破坏 Phase 3a 的 review workspace。

### Phase 4b：Packaged app runtime strategy

状态：未实现，需产品决策。

涉及位置：

- `desktop/src/main`
- `desktop/engine`
- `packages/shared/src/protocol.ts`
- `electron-builder.yml`
- `README_CN.md`

决策选项：

- Developer/Internal Mode：保留本地 Python 依赖，但启动页和文档明确说明。
- End-User Packaged Mode：打包 Python runtime 和依赖，面向摄影师发布。

推荐：

如果 Gather 面向非开发者摄影师，应选择 End-User Packaged Mode；否则不要让 `dist:mac` 看起来像完整最终用户安装包。

目标修改：

- 定义 `EngineReadyPayload` 和 `EngineHealthResponse`。
- 增加 `engine.health`。
- 启动页展示 Python runtime、依赖、DB path、可写目录、可选功能状态。
- packaged build 明确 runtime resolution。

验收：

- 缺 Python、缺依赖、engine script 缺失、版本不匹配时有明确用户提示。
- README 只描述一个当前支持的安装路径。

## CSP 和 inline style 策略

当前事实：

- `index.html` 有多处 inline style。
- `dialog.ts` 有 typed confirm inline style。
- `dashboard.ts` 约 5 处 inline style。
- `similarity.ts` 约 7 处 inline style。
- `face-kw.ts` 约 26 处 inline style。
- CSP 仍需要 `style-src 'unsafe-inline'`。

结论：

彻底移除 `unsafe-inline` 不是 Phase 0 的小任务，它要求 renderer 从 template literal + inline style 逐步迁移到 class-based rendering。工作量约为原视觉 Phase 1 描述的 3-5 倍。

执行策略：

1. P0 只清理 `index.html` 和 shared components 中最影响启动/错误态的 inline style。
2. P1 清理 Dashboard 和 Similarity 页面级 inline style。
3. P2 清理 Face KW review workspace 改造触达的 inline style。
4. 全部页面迁移完成后，再移除 CSP `unsafe-inline`。

验收：

- 每个 phase 使用 `rg "style=|\\.style\\." desktop/src/renderer` 记录剩余数量。
- 只有剩余数量接近 0 且动态样式都有 class 替代时，才调整 CSP。

## 测试与回归要求

每个涉及前端 DOM/CSS class 的 phase 至少运行：

```bash
npm --prefix desktop test -- --runInBand
npm --prefix desktop run typecheck
npm --prefix desktop run lint
npm --prefix desktop run build
```

涉及 Python service、DB migration、writeback lifecycle 的 phase 还需运行：

```bash
uv run pytest
uv run ruff check .
```

原因：

- 当前项目已有 renderer Jest 测试，CSS class 迁移可能破坏 DOM selector 和行为断言。
- writeback lifecycle 涉及 Python service、DB、shared protocol，不能只靠前端 build 验收。
- 视觉改造若触达导航类名，如 `.stepper-step--active` 到 `.app-nav-item--active`，必须同步更新测试。

## 最终优先级

P0：

- Phase 0.1：Dashboard badge 样式缺失修复。
- Phase 0.2：视觉 token、状态组件、app shell 类名一次落地。

P1：

- Phase 1.1：统一 XMP writeback lifecycle 的剩余 API/数据契约。
- Phase 1.2：Dashboard 工作台化与 session health。
- Phase 2：Similarity 照片优先审阅与 writeback preview。

P2：

- Phase 3a：Face KW review workspace 视觉结构。
- Phase 3b：响应式和视觉 QA。

P3：

- Phase 4a：Face KW 高效交互。
- Phase 4b：Packaged app runtime strategy。

## 不建议现在做

- 不建议引入 React、Tailwind 或新的 UI 框架。
- 不建议把 Face KW review workspace 和快捷键/批量操作一次做完。
- 不建议在 inline style 清理未完成前移除 CSP `unsafe-inline`。
- 不建议 UI 层先大改 writeback preview，再回头改 API shape。
- 不建议让 Dashboard health、Similarity preview、Face KW retry 各自定义状态模型。

## 一句话方向

先把 Gather 的写回生命周期、状态和导航骨架收束成可靠的桌面工具底座，再把三个核心页面改造成照片优先、状态清晰、操作可恢复的专业工作台。
