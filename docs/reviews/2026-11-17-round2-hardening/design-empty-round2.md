# Round-2 设计：页面级空态采用品牌组件 + 设计文档校准（task-14）

- **日期**：2026-11-17（基线 git HEAD `4cb3228d` + round-2 peers 未提交改动）
- **执行**：design-tokens（子代理；写作用域 = 8 个空态文件 + [`docs/design/appearance-interaction.md`](../../design/appearance-interaction.md) + [`scripts/design-system-baseline.json`](../../../scripts/design-system-baseline.json) + 本文）
- **约束遵守**：零用户可见文案改动（l10n key / 图标 / 按钮全部保留）、无逻辑/布局语义/状态/API 变更、未新增 `@unchecked Sendable`、未回退 peers 的未提交改动、未 commit；未触碰 en.lproj / L10n / perf-ui 正在编辑的文件。
- **改动面**：8 个 Swift 文件 `git diff --stat` = **8 files, +87 / −99**；baseline 2 个 metric；设计文档 7 处；本文。
- **验证环境**：Linux（无 macOS/Xcode）→ 本轮**没有编译、没有运行、没有截图**；验证 = Swift 6.2 `swiftc -parse` + 仓库门禁（见 §5）。

## 0. 结论摘要

| 项 | 结果 |
|---|---|
| `ContentUnavailableView` 站点分类 | **20 处**：17 处页面级 → 迁移 `GatherEmptyState`；3 处保留（2 处 List Section 内联 + 1 处 `.search`） |
| ratchet 指标 | `empty.contentUnavailable` 28 → **10**（−18 = 17 处代码 + 1 处过期文档注释）；`theme.legacyAlias` 5 → **1**（收编 gate-smith 的正则修复）；`font.callout` **0** 保持 |
| 设计文档 | 7 处过期/不准确陈述校准 + 空态 metric 度量说明（§4） |
| 文案零变化 | 8 个文件与 HEAD 对比，**字符串字面量多重集合完全一致**（脚本校验） |
| 门禁 | design-system PASS（新基线）、preview-surface `--strict` PASS、repo-hygiene **7 节 PASS**（shellcheck 0 finding）、`git diff --check` clean |
| 语法 | 8/8 改动文件 `swiftc -parse -enable-bare-slash-regex` 通过（无输出、exit 0） |

## 1. 空态站点分类（20 处）

口径：`docs/design/appearance-interaction.md` §空态——**页面级空态用品牌 `GatherEmptyState`**；**List Section 行内（行高约束）继续用系统 `ContentUnavailableView`**，不强行塞入。行号为迁移后现状（迁移前有变化的在括号内注旧行号）。

| # | 站点 | 语境 | 分类 | 处置 / 保留原因 |
|---|---|---|---|---|
| 1 | Culling/CullingView+Content.swift:71 | 挑片页首载失败（整页内容区） | 页面级 | 迁移（icon `exclamationmark.triangle` / 标题「载入挑片工作台失败」/ message=错误文案 / 「重试」primary） |
| 2 | Culling/CullingView+Content.swift:210（helper `emptyGuide`，调用点 28/43） | 「未打开工作区」整页、「当前范围没有照片」整页 | 页面级 | 迁移 helper（icon/title/message 透传，可选「清除筛选」secondary 保留；外层 frame 修饰符原样保留） |
| 3 | Similarity/SimilarityView+Content.swift:107 | 相似度页加载/轮询失败（页内容区） | 页面级 | 迁移（标题「加载结果失败」/ message「错误：%@」/「重试」primary） |
| 4 | Similarity/SimilarityView+Content.swift:253 | 当前参数无相似分组（页内容区） | 页面级 | 迁移（icon `square.stack.3d.up.slash` / 「重新聚类」secondary + disabled 条件原样） |
| 5 | Persons/PersonsView.swift:146 | 人物列表栏加载失败（HSplitView 左栏） | 页面级（整栏失败态） | 迁移（「重试」primary + help「重新读取人脸库」保留） |
| 6 | Persons/PersonsView.swift:209 | `ContentUnavailableView.search(text:)` | 系统「搜索无结果」语义 | **保留**：搜索空结果是系统搜索 UX 的一部分（策略明示例外）；换成品牌组件会丢系统语义 |
| 7 | Persons/PersonsView.swift:229 | 详情栏「人脸库还是空的」（HSplitView 右栏） | 页面级（详情栏占位） | 迁移（无动作；注：当前 body 门控下该分支不可达，迁移无视觉影响，仅统一写法） |
| 8 | Persons/PersonsView.swift:235 | 详情栏「未选择人物」（HSplitView 右栏） | 页面级（详情栏占位） | 迁移（无动作；同栏空态统一品牌化） |
| 9 | Duplicates/DuplicatesView+Sections.swift:149 | 重复页载入失败（页内容区） | 页面级 | 迁移（「重试」secondary + disabled 原样） |
| 10 | Duplicates/DuplicatesView+Sections.swift:162 | 尚未扫描（页内容区） | 页面级 | 迁移（icon `square.on.square` / 引导文案逐字保留） |
| 11 | Duplicates/DuplicatesView+Sections.swift:168 | 未发现完全重复（页内容区） | 页面级 | 迁移（原 `ContentUnavailableView(title,systemImage:,description:)` → icon/title/message） |
| 12 | Duplicates/DuplicatesView+Sections.swift:174 | 未发现视觉相似（页内容区） | 页面级 | 迁移（同上） |
| 13 | ControlCenter/SessionControlView.swift:160 | 工作区状态「暂无/加载失败」（页内容区） | 页面级 | 迁移（条件标题/条件 message/「刷新」primary + help 全保留） |
| 14 | FaceKeywording/FaceReviewStep.swift:16 | Step2 审核「暂无人脸簇」（整个步骤内容区） | 页面级 | 迁移（「前往分析」primary + help 保留） |
| 15 | FaceKeywording/FaceReviewStep.swift:157（旧 160） | 详情栏「未选择人脸簇」（HSplitView 右栏） | 页面级（详情栏占位） | 迁移（无动作） |
| 16 | Gallery/GalleryView+Content.swift:455 | 图库加载失败（页内容区） | 页面级 | 迁移（错误文案作为 title；「重试」primary；外层 `.frame(maxWidth: 520)` 等保留） |
| 17 | Gallery/GalleryView+Content.swift:484（旧 486） | 真空库「暂无照片」（页内容区） | 页面级 | 迁移（三条出口 primary/secondary/tertiary 原样） |
| 18 | Gallery/GalleryView+Content.swift:512（旧 514） | 搜索/筛选无结果（页内容区） | 页面级 | 迁移（「清除筛选」primary 原样） |
| 19 | Dashboard/DashboardView.swift:344 | 「暂无工作区」——位于 `List` 的 `Section` 内容槽 | List Section 内联 | **保留**：策略规定 Section 行内容继续用系统空态（行高/节排布约束，强塞品牌组件会撑行高） |
| 20 | Dashboard/DashboardView.swift:437 | 任务中心加载失败——位于 `List` 的 `Section` 内容槽 | List Section 内联 | **保留**：同上；错误出口（「重试」primary）不动 |

## 2. 映射规则（逐字保留内容）

- `Label(title, systemImage: icon)` → `icon:` + `title:`
- `description: Text(x)` → `message: x`（`l10n` / `l10n.format` 表达式原样搬移）
- 尾随 `actions:` 闭包 → `GatherEmptyState` 的 actions 闭包：按钮、`gatherButton` 角色、`.disabled`、`.help` 全部原样
- `ContentUnavailableView(title, systemImage:, description: Text(...))` 初始化器 → 同一映射
- 外层布局修饰符（`.frame` / `.padding`）**不改**，避免引入额外布局变化
- 设计值来源：品牌空态由 [`GatherEmptyState.swift`](../../../desktop/native/gather-app/Sources/GatherUI/DesignSystem/Components/GatherEmptyState.swift) 统一（accent 细线图标 44pt / sectionTitle / secondary / 24pt padding），页面不再自选字号/颜色

**文案零变化证据**：对 8 个文件分别取 `git show HEAD:<file>` 与工作区的全部双引号字符串字面量做多重集比较 → 完全一致（0 增 0 删）；`check-repo-hygiene` 的 [g] 本地化用法检查亦 PASS（1718 处 CJK 字面量全部已包裹）。

## 3. ratchet 指标 before / after

| 指标 | round-2 起点基线 | 迁移前实测 | 迁移后 = 新基线 | 说明 |
|---|---:|---:|---:|---|
| empty.contentUnavailable | 28 | 28 | **10** | −18：17 处页面级站点迁移 + 1 处过期文档注释（DuplicatesEmptyState 头注释）同步改写 |
| theme.legacyAlias | 5 | 1 | **1** | 迁移前已是 1（gate-smith 给 `primary` 加 `\b` 后，4 处 `primaryText` 假阳性消失）；本轮 `--update` 把该改进收进基线 |
| font.callout | 0 | 0 | **0** | round-1 已清 0，保持 |
| font.systemSize / spacing.literalPadding / spacing.literalSpacing / container.groupBox / radius.legacyAlias | 15 / 5 / 86 / 0 / 15 | 同左 | 15 / 5 / 86 / 0 / 15 | 本轮无变化 |

新基线由 `./scripts/check-design-system.sh --update` 写入 [`scripts/design-system-baseline.json`](../../../scripts/design-system-baseline.json)（2 行变更；--update 的拒绝膨胀逻辑未触发）。

**残留 10 的分解**（metric 统计 `ContentUnavailableView` 出现次数、含注释）：
- 代码 3 处 = 上面保留的 3 个站点（Dashboard ×2 Section 内联 + Persons `.search`）；
- 注释 7 处 = Dashboard 头注释（保留的 Section 内联规则说明）、`GatherEmptyState.swift` 组件历史注释（"不再是 ContentUnavailableView 包装"）、`Gallery/LightboxView.swift:272`（恒暗查看器保留系统文字色说明，仍准确），以及 4 个**本轮写作用域之外**的过期头注释（见 §6-2）。

## 4. 设计文档校准（docs/design/appearance-interaction.md，7 处）

| 行号 | 类型 | 变更 |
|---|---|---|
| 15–17 | 结构图不准 | `Components/` 列表改为实际组件（Badge/Banner/Button/EmptyState/MenuField/SearchField/Toast）；`Patterns/` 补 `GatherInspectorSection` / `GatherCollapsibleSection`；`Modifiers/` 补 `gatherPresence` |
| 44–47 | 过期别名 | 删除 "两套名字" 中已不存在的 `GatherTheme.windowBackground`；补充 `contentBackground` / `secondaryContentBackground` 仅为 `surface` / `surfaceMuted` 兼容别名、新代码勿用，并注明 metric `theme.legacyAlias` 只降不升 |
| 111–126 | 过期配方 | 原文 `GatherSection(...)` **组件从未落地**（全仓 0 处定义）→ 改为实际的系统 `Section { } header: { }` 配方，并写明"没有通用 GatherSection"；检查器指引从"后续的 GatherInspectorSection"改为"已落地：GatherInspectorSection / GatherCollapsibleSection" |
| 139–146 | 策略补全 + 度量 | §空态明确"页面级加载失败/错误态同样用 GatherEmptyState（必须保留重试/清除筛选出口）"；新增"采纳进度由 metric `empty.contentUnavailable` 度量"的说明 |
| 243–244 | 门禁说明 | `./scripts/check-design-system.sh` 命令旁注明基线含空态采纳指标 `empty.contentUnavailable` |
| 271、278 | 迁移状态表 | 从 `GatherPage / GatherSection / …` 行删掉不存在的 `GatherSection`；`GatherInspectorSection` 状态从"下一阶段"改为 ✅ Phase 5（Metadata / Gallery / Library / Culling 检查器已迁移，实测 4 个文件引用） |

**核对后未改（仍准确）**：表面 token 名 `canvas/surface/surfaceMuted/viewerBackground/hairline` 与 `GatherTheme.swift` 一致；圆角指引与 `GatherTheme.Radius`（panel/media=8、card=12…）一致；`GatherEmptyState` "自绘、非 ContentUnavailableView 包装"与组件注释一致；文字角色表与 `GatherTextRole` 的 10 个 case 一致；会话页/工具栏/导航 environment 示例与 `GatherSessionPage` / `GatherSessionToolbar` 签名一致（`onRefresh:` 参数存在）。

## 5. 验证证据（可复现）

1. **语法**：8 个改动文件逐个 `.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>` → **PARSE_OK 8/8**（无输出、exit 0）。
2. **design-system**：`./scripts/check-design-system.sh` → **PASS: no regression**（8 metric 全 ok；新基线见 §3）。
3. **预览面**：`./scripts/check-preview-surface.sh --strict` → **PASS: #Preview=14, preview files=12, lines=2210**（与迁移前一致，无预览面改动）。
4. **仓库卫生**：`PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh` → **[a]–[g] 7 节全 PASS**（shellcheck 0.10.0：24 个 tracked .sh / 0 finding；本地化用法 [g]：272 文件 / 2264 处调用 / 1718 处 CJK 字面量全部已包裹）。
5. **diff 卫生**：`git diff --check` → clean（无行尾空白/冲突标记）。
6. **文案零变化**：§2 的字符串字面量多重集比较脚本 → 8/8 文件 0 差异。
7. **写作用域**：`git status` 中本任务只改 8 个 Swift 文件 + 设计文档 + baseline（+ 本文）；perf-ui 的 12 个文件、en.lproj、L10n 等均未触碰。

## 6. 未迁移项、残余与风险

1. **保留的 3 个站点**（理由见 §1）：Dashboard 2 处 `List Section` 内联（行高/节排布约束，按策略保留系统空态）；Persons `.search(text:)`（系统搜索无结果语义）。若后续要统一 Section 内空态视觉，需要先设计"行内品牌空态"变体（撑行高风险），不在本轮范围。
2. **写作用域之外的过期头注释（未改，交 lead / 后续轮）**：
   - `Gallery/GalleryView.swift:21`「空态 / 无结果 / 加载失败改 ContentUnavailableView」——其 `+Content` 文件本轮已全部品牌化，该句变过期；
   - `Similarity/SimilarityView.swift:16`「空态/错误态 → ContentUnavailableView」——同上过期；
   - `Library/LibraryView.swift:11` 与 `Library/LibraryView+Content.swift:117`——在本轮之前就已过期（代码已用 GatherEmptyState）；
   这 4 个文件不在本任务 write scope，故只记录不改。
3. **PersonsView.emptyState（人物页整页空库卡片）**：不是 `ContentUnavailableView` 站点（自绘 VStack + hero 圆角 + 阴影），本轮按任务范围未动；它和品牌空态是两种视觉语言，建议后续统一。
4. **Culling `emptyGuide` 的嵌套 padding**：helper 外层保留 `.padding(.vertical, GatherMetrics.Space.xxxl)`（48pt），`GatherEmptyState` 自带 24pt padding → 双层内边距；为不改变调用点布局刻意保留，居中结果不变，但需 macOS 截图复验。
5. **验证上限**：无 macOS 构建/运行/截图；空态品牌化本身是**有意的视觉变化**（不是零视觉改动），本报告只保证"内容（文案/图标/动作/禁用态）与 HEAD 等价 + 语法与仓库门禁通过"，**没有像素级验证**。两块 split-pane 详情栏（Persons / FaceReview）换品牌空态后的视觉层级、以及 `GatherEmptyState` 在 ScrollView 内的 `maxHeight` 行为，建议由 macOS owner 截图复验。
6. 未新增 `@unchecked Sendable`、未改 public API、未 commit。
