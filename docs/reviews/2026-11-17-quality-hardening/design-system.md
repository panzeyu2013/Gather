# GatherUI 设计令牌迁移：精确等价字体 / 间距 / 主题别名 + ratchet 收紧（task-8 / design-tokens）

- 日期：2026-11-16（评审目录 2026-11-17-quality-hardening）
- 范围：`desktop/native/gather-app/Sources/GatherUI/**` 的令牌调用点；另含 [`scripts/design-system-baseline.json`](../../../scripts/design-system-baseline.json) 与本文。排除 token 定义文件 `DesignSystem/Tokens/**`（`GatherStyle.swift` / `GatherTheme.swift` / `GatherChromeMetrics.swift` / `GatherGlass.swift`）、`Support/L10n.swift`、`Support/GatherLocalization.swift`、`Resources/en.lproj/**`。
- 边界（重要）：Linux 主机，**无 macOS/Xcode**；本轮**没有编译、没有运行、没有截图/pixel diff**。零视觉变化的依据是**源码级证明**：替换后的常量定义与原字面量逐字符同值（§1），再加上 Swift 6.2 `swiftc -parse` 语法检查与仓库门禁。等价性没有经过运行时渲染验证。
- 行为约束：只做设计值替换——不改布局/逻辑/状态/API/用户可见文案；不新增 `@unchecked Sendable`；其他队友的未提交改动原样保留（逐文件备份后仅做精确字符串替换，校验见 §5）。

## 0. 结论摘要

| 项 | 结果 |
|---|---|
| 替换处数 | **116 处**（字体 104 / 间距 2 / 主题色 10） |
| 代码 diff | **43 个 Swift 文件，+114/−114 行**（FaceClusterCard、DuplicatesGroupCardView 各有 1 行内 2 处替换） |
| ratchet 基线 | font.callout 86→**0**；spacing.literalSpacing 89→**86**；theme.legacyAlias 15→**5**；其余指标不变 |
| 门禁 | `check-design-system.sh` PASS（新基线）、`check-preview-surface.sh --strict` PASS（14/12/2210 不变）、`check-repo-hygiene.sh` PASS |
| 语法 | 43/43 文件 `swiftc -parse -enable-bare-slash-regex` 通过（无输出、exit 0） |
| 用户可见变化 | **0**：所有替换都是同一 `Font` 值 / 同一 `Color` 值 / 同一 `CGFloat` 值 |

## 1. 精确等价依据（token 定义原文）

字体角色定义在 [`GatherStyle.swift`](../../../desktop/native/gather-app/Sources/GatherUI/DesignSystem/Tokens/GatherStyle.swift)：

| 角色 | 定义（行号） |
|---|---|
| `GatherFont.secondary` | L24 `static let secondary = Font.callout` |
| `GatherFont.secondaryStrong` | L25 `static let secondaryStrong = Font.callout.weight(.semibold)` |
| `GatherFont.mono` | L32 `static let mono = Font.callout.monospacedDigit()` |
| `GatherFont.cardTitle` | L19 `static let cardTitle = Font.headline` |
| `GatherFont.body` | L21 `static let body = Font.body` |
| `GatherFont.bodyStrong` | L22 `static let bodyStrong = Font.body.weight(.semibold)` |
| `GatherFont.eyebrow` | L13 `static let eyebrow = Font.subheadline.weight(.semibold)` |
| `GatherFont.labelRegular` | L28 `static let labelRegular = Font.subheadline` |
| `GatherFont.heroSubtitle` | L11 `static let heroSubtitle = Font.title3` |
| `GatherFont.sectionTitle` | L17 `static let sectionTitle = Font.title3.weight(.semibold)` |
| `GatherFont.pageTitle` | L15 `static let pageTitle = Font.title2.weight(.semibold)` |

间距令牌：L37 `xxs = 2`、L38 `xs = 4`、L40 `controlGap = 6`、L41 `s = 8`、L42 `m = 12`、L43 `l = 16`、L44 `xl = 24`、L45 `xxl = 32`。

主题色别名定义在 [`GatherTheme.swift`](../../../desktop/native/gather-app/Sources/GatherUI/DesignSystem/Tokens/GatherTheme.swift)：

- L108–109 `/// 分组内容 / 卡片底色（兼容旧名，语义已指向 surface）` + `public static let contentBackground = GatherTheme.surface`
- L110–111 `/// 次级分组底色（兼容旧名，语义已指向 surfaceMuted）` + `public static let secondaryContentBackground = GatherTheme.surfaceMuted`

两个旧名是**直接别名**（不是近似色），因此调用点换成新名后 Color 表达式完全相同。

## 2. 替换映射与逐项计数

| # | 原字面量 | 替换为 | 处数 | 等价说明 |
|---|---|---|---:|---|
| 1 | `.font(.callout)` | `.font(GatherFont.secondary)` | 69 | 同一 `Font.callout` |
| 2 | `.font(.callout.weight(.semibold))` | `.font(GatherFont.secondaryStrong)` | 5 | 同一 `Font.callout.weight(.semibold)` |
| 3 | `.font(.callout.monospacedDigit())` | `.font(GatherFont.mono)` | 8 | 同一 `Font.callout.monospacedDigit()` |
| 4 | `.font(.callout.monospaced())` | `.font(GatherFont.secondary.monospaced())` | 1 | 无专用角色；基角色 + 原 modifier，Font 值逐位相同 |
| 5 | `.font(.callout.weight(.medium))` | `.font(GatherFont.secondary.weight(.medium))` | 1 | `GatherFont.label` 是 `subheadline.weight(.medium)`（字号不同），不能套用；用基角色 + 原 modifier |
| 6 | `.font(.headline)` | `.font(GatherFont.cardTitle)` | 5 | 同一 `Font.headline` |
| 7 | `.font(.body)` | `.font(GatherFont.body)` | 2 | 同一 `Font.body` |
| 8 | `.font(.body.weight(.semibold))` | `.font(GatherFont.bodyStrong)` | 1 | 同一 `Font.body.weight(.semibold)` |
| 9 | `.font(.body.monospaced())` | `.font(GatherFont.body.monospaced())` | 3 | 无专用角色；基角色 + 原 modifier |
| 10 | `.font(.subheadline.weight(.semibold))` | `.font(GatherFont.eyebrow)` | 2 | 同一 `Font.subheadline.weight(.semibold)`；本仓没有裸 `.font(.subheadline)`，需求里的裸形式为 0 处 |
| 11 | `.font(.title3)` | `.font(GatherFont.heroSubtitle)` | 3 | 同一 `Font.title3` |
| 12 | `.font(.title3.weight(.semibold))` | `.font(GatherFont.sectionTitle)` | 2 | 同一 `Font.title3.weight(.semibold)` |
| 13 | `.font(.title3.monospacedDigit())` | `.font(GatherFont.heroSubtitle.monospacedDigit())` | 1 | 无专用角色；基角色 + 原 modifier |
| 14 | `.font(.title2.weight(.semibold))` | `.font(GatherFont.pageTitle)` | 1 | 同一 `Font.title2.weight(.semibold)` |
| 15 | `HStack(spacing: 4)` | `HStack(spacing: GatherMetrics.Space.xs)` | 1 | `xs = 4` |
| 16 | `.padding(.vertical, 2)` | `.padding(.vertical, GatherMetrics.Space.xxs)` | 1 | `xxs = 2` |
| 17 | `GatherTheme.secondaryContentBackground` | `GatherTheme.surfaceMuted` | 6 | 直接别名 |
| 18 | `GatherTheme.contentBackground` | `GatherTheme.surface` | 4 | 直接别名 |

合计 **116 处**。字体按原始风格分组：callout 族 84、headline 5、body 族 6、subheadline 族 2、title3 族 6、title2 族 1。

## 3. ratchet 基线：迁移前 → 迁移后

`scripts/check-design-system.sh` 的计数含注释（工具设计如此，见脚本头注释），下表同时给“旧基线 / 迁移前工作树实测 / 迁移后=新基线”：

| 指标 | 旧基线 | 迁移前实测 | 迁移后 = 新基线 |
|---|---:|---:|---:|
| font.callout | 86 | 84 | **0** |
| font.systemSize | 15 | 15 | 15 |
| spacing.literalPadding | 5 | 5 | 5 |
| spacing.literalSpacing | 89 | 87 | **86** |
| empty.contentUnavailable | 28 | 28 | 28 |
| container.groupBox | 0 | 0 | 0 |
| theme.legacyAlias | 15 | 15 | **5** |
| radius.legacyAlias | 15 | 15 | 15 |

说明：旧基线与迁移前工作树之间的 -2/−2 差额来自其他任务已提交/未提交的改动（不是本任务）；本任务自身的增量是 font.callout −84、literalSpacing −1、theme.legacyAlias −10。新基线由 `./scripts/check-design-system.sh --update` 写入（拒绝膨胀逻辑生效，只降不升）。

## 4. 触及文件（43 个 Swift 文件）

按目录（括号内为替换处数）：

- `ControlCenter/`：SessionControlJobRow(1)、SessionControlView+IndexHeader(1)、SessionControlView+Recommendation(1)、SessionControlView+Stages(1)、SessionControlView+Toolbox(2)
- `Culling/`：CullingConflictPanel(9)、CullingToolbar(1)、CullingViewerParts(1)、IngestSheet(2)
- `Dashboard/`：DashboardFirstRunView(1)、DashboardView(1)、JobRowView(3)、NewSessionSheet(2)、SessionRowView(4)
- `Duplicates/`：DuplicatesGroupCardView(2)
- `Export/`：ExportView+FieldError(1)、ExportView+Options(2)、ExportView+Preview(4)、ExportView+Progress(1)、ExportView+Range(4)、ExportView+Result(3)
- `FaceKeywording/`：FaceAnalyzeStep(3)、FaceClusterCard(2)、FaceWritebackStep(2)
- `Gallery/`：GalleryCellView(1)、GalleryView+Content(4)
- `Library/`：FolderTreePanel(1)、LibraryCardView(1)、LibraryView+Content(6)、LibraryView+Filters(3)
- `Metadata/`：MetadataTemplateSheet(1)
- `Persons/`：PersonsView(7)
- `PreviewSupport/`：PreviewShellViews(2)
- `Settings/`：SettingsView+C1HealthSection(1)、SettingsView+FaceAnalysis(1)、SettingsView+Fields(1)、SettingsView+Model(6)、SettingsView+Sections(2)
- `Similarity/`：SimilarityView+Content(4)、SimilarityView+Writeback(14)
- `Support/`：FaceClusterMontage(2)、SliderInputView(2)、WritebackReportCard(3)

其中 `CullingConflictPanel` / `PersonsView` / `SimilarityView+Writeback` 等文件同时含其他队友的未提交改动（perf-ui 的渲染优化、ui-copy 的 a11y 文案）；本任务在其工作树版本之上只改令牌行，diff 校验见 §6.1。

## 5. 刻意未替换的项及原因

| 项 | 处数 | 不替换原因 |
|---|---:|---|
| `.font(.title2)`（FaceReviewStep.swift:235） | 1 | `GatherFont` 无裸 title2 角色（`pageTitle`/`stat` 都带 `.weight(.semibold)`）。换成任一角色都会改变字重 → 非精确等价 |
| `.font(.system(size: …))` | 15 | 无对应字体角色（GatherFont 全部基于系统语义字号），无法精确映射 |
| 非令牌间距 `spacing:` | 86 | 剩余值 10(34)/0(29)/3(7)/5(5)/14(5)/20(2)/1(2)/9(1)/7(1) 都不等于任何 `GatherMetrics.Space` 令牌（2/4/6/8/12/16/24/32），按任务要求保留 |
| 非令牌数值 padding | 5 | `.padding(10)`×3、`.padding(9)`、`.padding(3)`：10/9/3 不是 Space 令牌（9 仅是 `GatherChromeMetrics.fieldHorizontalPadding`，语义是“字段横向内边距”，这些调用点不是字段，套用会误导） |
| 轴向内边距非令牌值 | 34 | `.padding(.horizontal/.vertical, 1/3/5/9/10/14/20/36/40/52/60)` 均不等于 Space 令牌（分布：10×12、14×5、1×4、9/40/36/3/20 各 ×2、5/52/60 各 ×1） |
| `GatherTheme.windowBackground / primary / primarySoft / background / border` | 0 | GatherUI 内不存在真实调用点（仅在 `GatherTheme` 内部/历史文档出现过，已随旧名清理） |
| `GatherTheme.primaryText` | 4 | **不是** legacy 别名；只是 ratchet 正则 `GatherTheme\.(…|primary|…)` 按前缀也命中了 `primaryText`。属门禁计数假阳性，未改动 |
| `GatherTheme.contentBackground`（GatherGlass.swift:21 文档注释） | 1 | token 定义文件里的 doc comment，按任务约束（跳过注释与 token 定义文件）未改，因此 theme.legacyAlias 残留 1 |
| `GatherTheme.Radius.panel` | 15 | `Radius.panel = 8` 是**独立定义**，不是别的令牌的别名；唯一同值令牌 `Radius.media = 8` 语义是“照片媒体面”，换成它会改变语义（非“已证明的精确别名”）。按任务要求保留并报告 |
| `empty.contentUnavailable` (28) / `container.groupBox` (0) | 28/0 | 不属本任务范围（需要独立组件化改造，且 0 处 GroupBox 已达标） |

## 6. 验证证据（可复现）

1. **逐文件精确替换校验**（替换前备份 vs 替换后）：43/43 文件满足“当前内容 == 备份内容按 §2 规则替换后的结果”，0 mismatch；每个文件行数不变（无增删行、无格式改动）。备份与报告在 gitignored 的 `.gather/design-tokens-2026-11-17/`（不入库）。
2. **语法检查**：对 43 个改动文件逐个执行
   `.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>` → `PARSE_OK files=43/43`（无输出、exit 0）。
3. **设计系统 ratchet**：`./scripts/check-design-system.sh` → `PASS: no regression`（见 §3；新基线 font.callout 已收紧到 0，任何新增裸 `.font(.callout)` 都会让门禁失败）。
4. **预览面**：`./scripts/check-preview-surface.sh --strict` → `PASS: #Preview=14, preview files=12, lines=2210`（与迁移前完全一致；本次没有增删预览）。
5. **仓库卫生**：`./scripts/check-repo-hygiene.sh` → 五节全 PASS（脚本语法/shebang/CRLF、editorconfig、Markdown 链接、本地化表、scripts 无构建产物）。
6. **残留扫描**：GatherUI 内 `.font(.callout` = 0、`.font(.headline` = 0、`.font(.body` = 0、`.font(.subheadline` = 0、`.font(.title3` = 0；`GatherTheme.contentBackground` 仅剩 GatherGlass doc comment 1 处；token 定义文件未改。

## 7. 验证上限与残余风险

- **没有编译/运行/渲染对比**（Linux 无 Xcode）：等价性是“同一 `Font` / `Color` / `CGFloat` 值”的源码级论证，不是像素级验证。minor 风险：若未来有人改 `GatherStyle.swift` 的角色定义，全部调用点会一起变（这是令牌化的预期收益，不是本次风险）。
- `GatherFont.secondary.monospaced()` / `GatherFont.secondary.weight(.medium)` / `GatherFont.body.monospaced()` / `GatherFont.heroSubtitle.monospacedDigit()` 这 6 处是“基角色 + 原 modifier”，没有新增专用角色；若团队希望零组合写法，可在 `GatherStyle.swift` 补 4 个角色（本轮按“不改令牌定义文件”的约束未做）。
- ratchet 残留 `theme.legacyAlias = 5` 全部是假阳性/注释（4× `primaryText` 前缀误命中 + 1× GatherGlass 注释）。建议后续（非本任务）：给 `scripts/check-design-system.py` 的 `theme.legacyAlias` 正则加词边界（如 `primary\b`）并把 GatherGlass 注释里的旧名改成 `GatherTheme.surface`，两项都做后基线有望收紧到 0。
- `radius.legacyAlias = 15` 仍是 `Radius.panel`；没有“已证明的精确别名”，保留基线 15，后续若要清掉需先定义 `panel` 的替代语义角色。
- 迁移落在其他队友未提交改动之上（`PersonsView`、`CullingConflictPanel` 等）；本任务未回退任何他人改动，最终合并时以 lead 的 diff 审查为准。
