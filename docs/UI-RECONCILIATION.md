# UI/交互对账总览（React main → SwiftUI refactor）

> 用途：逐页逐组件的样式与交互逻辑对账，作为原生版补齐工作的唯一依据。
> 方法：7 个分析 agent 并行对比 `main` 分支 Electron+React 源码与 `refactor` 分支工作区 SwiftUI 源码；两轮分析报告（`ui-recon-0{1..7}` / `fresh/0{1..7}`）为中间产物，结论已全部汇总至本文，报告目录已随清理移除。
> 约定：px 与 pt 按 1:1 换算。
> 状态：✅ 已补齐（2026-08-12 二轮：三栏工作台还原 + 外壳双语 + 8 项子域收尾）；⏳ 待办；— 决策后不做。

## 一、总览结论

- **功能骨架已 1:1 复刻**：页面齐全、IPC 命令（含 `confirmed` 二次确认）全部接线、服务端对齐度高。
- **视觉语言整体迁移**：暖橙品牌主题（primary #a54d2a / 背景 #f5f0eb）→ 系统原生外观（accent 蓝 / windowBackgroundColor）。
- **交互损失集中在三处**：① 工作区查看器快捷键连击流；② 公共页签栏与 C1 状态胶囊；③ hover/选中态反馈与 Toast 接线。
- **部分旧代码为死代码**（FilterBar/FilterBuilder/MetadataPanel/TemplatePicker 无调用方），无回退必要，已标注。

## 二、逐页差异摘要

| 页面 | 对齐度 | 关键差异 | 详见 |
|---|---|---|---|
| 外壳/导航 | 中 | 侧栏 76px 图标栏→200px 图标+文字；无"当前会话"项；无 C1 胶囊；缺编辑/窗口菜单、Cmd+W；页签行仅 Gallery 页有且"浏览"硬编码 active；品牌令牌整体切换 | 01 |
| Dashboard | 高 | 新增 summaryBar（旧无）；卡片 hover/整卡点击丢失；任务中心与 Jobs 页双实现不一致；Dashboard 丢进度帧（仅事件驱动，idle 期滞后 30s）；时间格式不同 | 02 |
| Jobs | 中 | 缺「尝试 N 次」「工作区·」前缀、历史不折叠、空态插画/quietState；进度格式与 Dashboard 不一致；状态色全变 accent | 02 |
| Library | 高 | 卡片点击进会话（旧版不可点击，新行为待确认）；候选"查看全部"丢失；缩略图占位尺寸防跳动 | 03 |
| Gallery | 高 | justified 参数与 TS 完全一致（220/8）；无虚拟滚动（10 万级风险）；单元格圆角 10→2、无 hover；选中条实底→淡底；哨兵触发更晚 | 03 |
| Lightbox | 中 | 缺滚轮缩放/←→键/相邻预加载；sheet 非全屏 | 03 |
| ControlCenter | 高 | 阶段条/Inbox/推荐对齐；C1 胶囊消失；索引进度降级为页内；页面 860px 居中→全宽 | 04 |
| Culling | 低 | **最大回退**：三栏工作台→单列卡流；查看器无 0-5/P/X/U 快捷键、4 张一行非 2x2、无滚轮缩放/双击复位、无位置计数 N/M、决策后不自动续页；同步按钮状态机与禁用 hint 丢失；新版多出 5 个 confirmationDialog（旧无） | 04 |
| Duplicates | 高 | 预设三档保留；滑块→Stepper；排除态视觉降权丢失；推荐徽章颜色不同；无 loading UI | 05 |
| Export | 高 | 进度条丢文件名/百分比；sticky 操作栏丢失；新增报告生成（增益）；Banner 替代行内错误 | 05 |
| FaceKeywording | 低 | **三步向导→单页四卡**；eps/minSamples 变 Stepper 丢数字输入；合并目标改自由文本；置信度%丢失；模型缺失横幅无跳转 | 06 |
| Similarity | 高 | 阈值滑块丢数字输入；1s 轮询替代事件推送；缩略图 64→56；全选位置变化；高度 70vh→520pt 固定 | 06 |
| Persons | 高 | 列表→master-detail；详情无头像、时间戳未本地化、无返回链接 | 07 |
| Settings | 中 | 手风琴→平铺卡；逐字段保存；**模型下载/安装横幅缺失**（P0）；C1 健康面板队列 6 格未接线（P0） | 07 |
| 通用组件 | 中 | Toast API 存在但仅 2 处接线；Dialog/ConfirmDialog 无通用实现（sheet 替代）；Badge 12 态缺失；Loading/ProgressBar 退化系统样式 | 07 |

## 三、P0 补齐清单（功能/交互缺口）

1. ✅ **Culling 查看器快捷键**：0-5/P/X/U + 2x2 对比 + 滚轮缩放/双击复位 + 位置计数 N/M + 决策后自动续页（CullingView.swift，+350 行）。
2. ✅ **公共页签栏**：SessionTabBar 组件（Support/SessionTabBar.swift），control/faceKw/duplicates/culling/export/similarity 全部复用，active 由 destination 驱动，修复"浏览"硬编码。
3. ✅ **C1 状态胶囊**：C1StatusCapsule + Host 包装（Support/C1StatusCapsule.swift）：状态点/队列计数/12s 轮询 + 事件刷新 + 点击跳设置；挂载于全部工作区页头部。
4. ✅ **Dashboard 进度实时性**：订阅 jobProgress 事件逐帧更新任务中心与卡片计数（DashboardViewModel.applyJobEvent）。
5. ✅ **FaceKeywording 三步向导**：分析→审核→写回（胶囊步骤指示器、审核左簇右详情 340pt、合并下拉、置信度%、滑块+数字输入、模型缺失跳设置）。
6. ✅ **Settings**：模型下载/安装横幅（ModelInstaller 流式下载+解压+重查 ml_status）；C1 健康面板接线 culling.sync_status + 12s 轮询 + 最近同步时间；模型参数表补全。
7. ✅ **应用菜单**：编辑菜单（Cmd+Z/X/C/V/A）、Cmd+W、窗口菜单（最小化/缩放/置前）；切语言重建菜单（settings.set_language → languageChanged 通知）。
8. ⏳ **Toast 接线**：Persons 已接（成功/失败）；其余页面成功/失败走 NativeBanner/notice 横幅（页内可见反馈，按产品决策保留；两通道语义已在代码注释中明确）。
9. ✅ **Similarity**：阈值/组大小滑块+数字输入、缩略图 64pt/圆角 10、成员 92px、高度 70vh 自适应、进度百分比、hover。

## 四、P1 补齐清单（样式/反馈）

1. ✅ 卡片 hover 态、侧栏 hover/选中指示条（4px 竖条）、"当前会话"侧栏项、品牌徽标渐变。
2. ✅ 品牌令牌层（Support/GatherTheme.swift：primary #a54d2a、bg #f5f0eb、surface #faf7f2、语义色、动态深色适配）；根视图 .tint(GatherTheme.primary) 全站生效（按产品决策：控件保持原生形态）。
3. ✅ Jobs 双实现统一：删除独立 JobsView，Dashboard 任务中心对齐旧版字段（尝试 N 次/工作区·前缀/`N% phase` 内嵌进度/状态色徽标/空态插画/历史折叠）。
4. ✅ Export 进度条补文件名+百分比（8px 自绘条）+ sticky 毛玻璃操作栏 + 行内字段错误定位。
5. ✅ Badge 12 态胶囊（Support/GatherBadge.swift：任务状态→语义色）。
6. ✅ Lightbox：滚轮缩放 [0.5,5] ±0.2、←/→ 方向键、相邻 2 张预加载、双击复位、缩放>1 拖拽平移（sheet 形态保留）。
7. ✅ Duplicates 排除态视觉降权（60% 透明+红/绿边框）+ 0-10 滑块 + loading UI + 推荐徽章主题色。
8. ✅ 写回报告统一组件（Support/WritebackReportCard.swift：三色统计卡 + 失败项明细，FaceKw/Similarity 已替换复用；Culling 数据形态为 MetadataSyncSummary，保留 syncCard 五格计数）。
9. ✅ Persons 详情头像 80×80 + 时间戳本地化 + 返回链接；Settings 手风琴折叠按产品决策保留平铺。
10. ✅ 页面切换滚动位置：RootView opacity 常驻方案保留（滚动位置保留为既有行为）；Library 缩略图占位固定 + 候选"查看全部"。
11. ✅ 细节收尾：控制中心阶段圆点 18px + 连接线撑满、C1 预检失败引导恢复红色、会话页遗留 accentColor 由 .tint 统一接管。

## 五、P2（死代码清理，已完成 ✅）

- **main 分支**：删除确认无引用的 4 个 React 组件（10 个文件，2026-08-12 于独立 worktree 清理，未提交）：
  - `components/FilterBar/`（index.tsx + module.css + filter-constants.ts）——仅被死组件 FilterBuilder 引用
  - `components/FilterBuilder/`（index.tsx + module.css）——renderer 零引用
  - `components/MetadataPanel/`（index.tsx + EditableField.tsx + module.css）——renderer 零引用
  - `components/TemplatePicker/`（index.tsx + module.css）——renderer 零引用
  - 保留：后端 `filter.ipc.ts`、`filter-engine` 服务与测试（filter.photos_global 仍被 Library 使用）、契约层命令（template.*/filter.*/metadata.*/album.* 在 IPC_CONTRACT.md 定义、gather-core 服务测试覆盖，为未来回收预留）
- **refactor 分支审计**：118/118 路由命令全部有非测试调用；顶层类型零死代码；编译零警告。
- **测试补齐（2026-08-12）**：新增 6 个测试文件、42 个用例（96 → 138 / 16 套件），对齐旧版 vitest 基线——`CullingSyncFlowTests`（c1-sync-controls 8 组门控矩阵 + 状态推导，15 例）、`IndexHeaderCopyTests`（index-progress 全用例，9 例）、`C1PreflightTests`（四层门控/guidance 优先级/超时格/失败兜底，5 例）、`FaceKeywordingViewModelTests`（会话过滤/终态跳转/回点，8 例）、`WorkspaceStageMarksTests`（deriveStageMarks，5 例）、`Support/StubCommandRouter.swift`（共享测试基础设施）。配套生产改动：`CullingSyncFlow.deriveControls` 抽为纯函数（对齐 TS 签名）、`IndexHeaderCopy`/`StageMark`/推导去 private 参数化、**修复真实 bug**：索引进度百分比钳制 0...100（旧版 `Math.min(100, round())`）。
- 剩余未迁移测试（低价值/无等价物）：`api-client`（协议包装）、`settings-locale`、`session-paths`、`dashboard-card-index`（部分被 DashboardViewModelTests 覆盖）、`a11y-*`/`design-system`/`lint`/`architecture-invariants`（React/Electron 专属）、`e2e`（Playwright，无 Swift 等价框架）。
- **测试收口（2026-08-12 二轮）**：
  - 补齐：`NativeCommandClientTests`（api-client 等价：成功/失败/空响应/错误翻译，4 例）、`InboxItemsTests`（workspace-view 的 deriveInboxItems：7 类优先级/截断导入/失败任务≤3 行/export_pending 条件，8 例）；配套把 `InboxKind`/`InboxAction`/`InboxItem`/`inboxItems(status:truncatedImport:)` 去 private 参数化。gather-app 测试 96 → 150（18 套件）全绿。
  - 确认无价值并**移除**（main 分支 worktree `git rm`，未提交）：23 个 TS 测试文件——10 个已有 Swift 等价（api-client/c1-preflight/c1-sync-controls/dashboard-card-index/face-keywording-store/index-progress/jobs-clearable/justified-layout/session-paths/use-event/workspace-view）、3 个 React a11y 专属、design-system（CSS 令牌）、settings-locale、lint/no-hardcoded-text（i18n lint）、shared/protocol.test.ts（Protocol/*ContractTests 等价）、shared/architecture-invariants（TS 架构约束）、e2e 4 个（Playwright 无 Swift 等价框架，行为已由 Swift 服务/VM 测试覆盖）。
  - 保留：`core-reliability-*`、`db/*`、服务层 78 个测试（main 分支基线），fixtures 数据。
- 修复：工作区页"浏览"页签跳转目标错误（曾跳控制中心 → 改为跳图库，旧版语义）。

## 六、待产品确认的决策点

1. ✅ **主题方向**：整体暖橙 vibe + 控件原生（折中方案已实施）。
2. ✅ **Library 卡片点击**：保留新版点击进入。
3. ✅ **FaceKeywording 结构**：还原三步向导。
4. ✅ **Jobs 去重**：统一到 Dashboard 内嵌，JobsView 已删除。
5. ⏳ Toast vs NativeBanner 反馈通道统一（当前混合，均可见；Persons 用 Toast，其余页面用横幅）。

## 七、二轮复核与补齐（2026-08-12）

### 决策
1. ✅ **Culling 三栏工作台还原**：214px 工具列 | 查看器+infoBar | 196px 胶片条（对齐 Culling.module.css:10-19 网格）。
2. ✅ **确认弹窗收敛**：移除写回/组决策/完成同步 3 个高频确认（对齐旧版零弹窗，由 confirmed:true 承担），仅保留重置挑片/清理备份两个破坏性确认。
3. ✅ **本地化范围**：外壳层（侧栏/页签/胶囊/Toast 关闭/导入提示）+ 错误参数插值双语；页面深层文案维持中文。

### 已修复（逐页）
| 页面 | 修复项 |
|---|---|
| 外壳 | 侧栏 hover 全项降透明 bug；Toast 滑入/淡出动画；`{{expected}}/{{field}}` 参数插值（revisionConflict/fieldUnknown 在路由层回填）；会话切换 `.id(sessionId)` 守卫（直连 control(A)→control(B) 强制重建）；工作区页签双语；`languageChanged` 驱动外壳重渲染 |
| C1 胶囊 | 还原 8 态 tone 映射（conflict/failed 红、syncing/c1Read 黄、safeToCleanup/synced 绿、检测中灰）；队列公式改回 pending+writing+written；动态 tooltip（详情+队列+最近同步）；队列徽标 + 最近同步时间（路由层 culling.sync_status 附回 reloadAckedAt） |
| 导入 | C1 导入还原 `capture-one` 来源标记 + 「C1 导入 M/D H:mm」命名 + 「N 张照片已导入；来源读取失败：示例、… 等 N 个」失败提示；落点改回浏览页 |
| Dashboard | 创建后跳转新工作区；卡片 Button 键盘可达；删除文案对齐；导入通知转 Toast 自动消失；jobs 错误态与空态分离；Badge 12 态 pastel 配色（photosLoaded teal/review indigo 等）；日期跟随应用语言；jobTerminal 状态机检测（GatherEventCenter，测试覆盖） |
| Gallery/Lightbox | 索引头（正在索引 N/M（x%）内联百分比、已索引 N 张、≥ 前缀、扫描中…、索引失败+重试）；设置链接；哨兵提前（剩 20 项预加载）；选中条实底白字+右对齐清除；事件刷新保留已加载页数与滚动；候选人全部直出；孤立 XMP 错误码翻译；rangeText total=0；选中态改 2px 描边；文件名渐变条；Lightbox 照片消失不关闭；变体胶囊按钮 |
| 控制中心 | 索引活跃期 3s 快速轮询（空闲 15s）；offline_photos「查看」改跳图库页签；未达阶段圆点实线边框 |
| Culling | 三栏工作台（工具列决策条 ✓保留 P/×淘汰 X/○未处理 U + 0-5 星级 + 8 色圆钮 + 相似组决策；查看器 1/2/4 对比 + 滚轮缩放 + 任意缩放拖拽平移 + 双击复位 + 字幕（文件名/来源/星级）+ 保留/淘汰/无脸/质量徽标；infoBar 位置计数 + 保留/淘汰/未处理 + linkedNotice + syncLabel + 逐按钮禁用 hint + 常驻引导行；胶片条 122pt 缩略图 + 色标线 + 决策圆点 + ⌘/Ctrl 点选多选 + 自动续页）；冲突浮动面板 |
| Duplicates/Export | 阈值滑块不锁预设；「视觉相似阈值: N」+ 范围提示 + 扫描说明；保留/丢弃文案；推荐徽标回右上；方形缩略图；标题/描述/目录警告提示；预览期禁取消、预览不锁导出；最长边 min=1 + 「不限制」占位；水印字号 8–200 钳制；空闲空间未知隐藏行 |
| FaceKeywording/Similarity | Similarity 加载/轮询失败可见（错误态+重试）、结果采纳后重置展开与滚动；「处理中…」不定进度标签；FaceKw 一键写回（自动预览）、报告操作行预览后即显示（清理按钮同步确认后隐藏）、移除成员免确认、审核步骤行内错误、initialRoleFilter 深链（Persons 详情→人脸审核预筛选角色，RootView 已接线） |
| Persons/Settings | 「复核人脸」携带角色+会话深链；列表头像圆形；「返回人脸库」；创建时间仅日期；C1 最近同步优先 reloadAckedAt；模型安装相位提示（下载中/解压中）；「请选择」占位 select |

### 已知保留（决策/文档化）
- Lightbox 保持 sheet（非全屏遮罩）；Toast 与 NativeBanner 双通道并存；Settings 手风琴/自动保存保留平铺+显式保存；共享 Loading/ProgressBar 组件以系统控件近似（页面级占位已对齐文案）；Settings C1 队列源为最近工作区（无会话 store 链接）；FaceKw 缩略图源固定 128（未跟随 thumbnail_size 设置）。
