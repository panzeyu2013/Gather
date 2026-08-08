# 无障碍全局审计报告 / Global Accessibility Audit

> 状态：P1（design_improvements.md 第 5.3 节）。P0（Dialog 焦点管理、相似组键盘语义）已完成；C-4 / F-1 / F-2 / F-3 / F-5 / F-6 已修复（见 §5 表格与各节记录）。
> 方法：CSS 色板 WCAG AA 对比度计算（正文 4.5:1 / 大文本 3:1）、`:focus-visible` 全站扫描、jest-axe 组件回归（jsdom）、VoiceOver 手工走查清单。
> 约束：与 i18n 迁移 / 新 UI 并行，未改任何页面/组件 TSX/TS 文件；只改全局 CSS 与新增测试文件。

## 1. 对比度审计（WCAG AA 1.4.3）

### 1.1 修复前色板（`desktop/src/renderer/styles/global.css` + `variables.module.css` 双文件同源）

| 色板对（文本/背景） | 实际用途 | 修复前 | 结论 |
|--------------------|----------|--------|------|
| `--color-text` #3d3833 / `--color-bg` #f5f0eb | 正文 | 10.24:1 | ✅ |
| `--color-text` / `--color-surface` #faf7f2 | 卡片正文 | 10.85:1 | ✅ |
| `--color-text-secondary` #8c857d / bg | 次级正文、`<p>`、12–14px 元信息 | 3.22:1 | ❌ <4.5 |
| `--color-text-secondary` / `--color-bg-secondary` #ede6dc | Badge/面板上文本 | 2.94:1 | ❌ <4.5 |
| `#fff`（`--color-text-inverse`）/ `--color-primary` #c9754f | 主按钮（新建工作区、确认、提交等 13–14px 正文） | 3.42:1 | ❌ <4.5 |
| `#fff` / `--color-primary-hover` #b8653f | 按钮 hover 态 | 4.22:1 | ❌ <4.5 |
| `--color-primary` / bg | 链接、激活态文本 | 3.02:1 | ❌ <4.5 |
| `--color-info` #5b9bd5 / bg | 提示文本、chips（FilterBuilder） | 2.61:1 | ❌ <4.5 |
| `--color-success` #7fb779 / bg | 成功文本（Dashboard/WritebackReport） | 2.07:1 | ❌ <4.5 |
| `--color-error` #d4605f / bg | 错误文本、删除态 | 3.29:1 | ❌ <4.5 |
| `--color-warning` #d4944f / bg | 警告文本（Settings） | 2.28:1 | ❌ <4.5 |
| `#fff` / info、success、error | Toast、破坏性按钮、chips | 2.96 / 2.35 / 3.72:1 | ❌ <4.5 |
| `--color-primary` / `--color-primary-soft` | （模板选中卡片实际用 `--color-text` 作为文本色） | 2.66:1 | 未用于文本，不修 |
| `--color-text-secondary` / `--color-border` | 边框非文本背景 | 2.58:1 | 非文本对，不修 |

### 1.2 修复（仅改全局 token，两文件同步；全站无 `prefers-color-scheme` 深色模式查询，改动无暗色冲突）

| Token | 修复前 → 修复后 | 修复后关键比值 |
|-------|-----------------|----------------|
| `--color-primary` | #c9754f → **#a54d2a** | #fff on primary **5.68:1**；链接 on bg **5.02:1** |
| `--color-primary-hover` | #b8653f → **#9e4525** | #fff on hover **6.30:1**；on bg **5.57:1** |
| `--color-text-secondary` | #8c857d → **#6b655d** | on bg **5.09:1**；on bg-secondary **4.65:1**；on surface 5.39:1 |
| `--color-info` | #5b9bd5 → **#2d6ba1** | on bg 4.97:1；on bg2 4.55:1；#fff on info 5.63:1 |
| `--color-success` | #7fb779 → **#31723d** | on bg 5.14:1；on bg2 4.70:1；#fff on success 5.83:1 |
| `--color-error` | #d4605f → **#b3403f** | on bg 4.98:1；on bg2 4.55:1；#fff on error 5.64:1 |
| `--color-warning` | **不改**（见 1.3） | on bg 2.28:1（遗留） |

全部改动值同时写入 `styles/global.css` 与 `styles/variables.module.css`（两文件为重复定义，需保持同步）。`variables.module.css` 无任何引用，已确认为遗留文件并在 F-6 中删除（全仓 grep 无 import；`--color-warning-text` 新增 token 仅写入 `global.css`）。

### 1.3 遗留对比度问题（需组件级改动，超出本工作流范围）

- **`--color-warning` 双角色冲突 → 已修复（C-4）**：新增 `--color-warning-text` token（#9c5e28，`styles/global.css`）供警告**文本**使用；`--color-warning` 保留作**背景**角色（Toast 警告底色 + `#111` 深色文本，7.33:1 不变，无回归）。三处警告文本全部切换到新 token：
  - `pages/Settings/Settings.module.css` `.dirtyHint`（on `--color-bg`，修复前 2.28:1 → **4.58:1** ✅）
  - `pages/SessionDetail/Culling.module.css` `.linkedNotice`（on `--color-surface`，修复前 2.28:1 → **4.86:1** ✅）
  - `pages/FaceKeywording/StepWriteback.module.css` `.statValueWarning`（on `--color-surface` → **4.86:1** ✅）
  - 背景类用途未改：`Toast.module.css` `.warning`、`C1StatusCapsule.module.css`、`Settings.module.css` 边框/背景混合、`StepAnalyze.module.css` 边框/背景混合（非文本对，不适用 4.5:1）。
  - 注：`--color-warning-text` on `--color-bg-secondary` 为 4.19:1（不足 4.5），但当前无警告文本落在 bg-secondary 上；如未来使用需再评估。
- 修复后 `--color-info/success` 在 `--color-bg-secondary` 上为 4.55/4.70:1（✅ 已达标）；其余非文本色对（边框、渐变）未评估，非 WCAG 文本要求。

## 2. 焦点可见性审计（:focus-visible）

### 2.1 全局样式

`styles/global.css` 已有统一规则（P0 交付）：

```css
:focus-visible {
  outline: 2px solid color-mix(in srgb, var(--color-primary) 78%, white);
  outline-offset: 2px;
}
```

色板加深后 outline 对比度随之提升。未删除任何既有样式。

### 2.2 `outline: none` 全站扫描结果（18 处，6 文件）

**无替代方案的 6 处 → 已在本文件补 `:focus-visible` 规则（同值 outline，修复完成）：**

| 文件 | 选择器 | 处置 |
|------|--------|------|
| `pages/SessionDetail/Gallery.module.css` | `.filterSelect` | 已补 `.filterSelect:focus-visible` |
| `pages/SessionDetail/Export.module.css` | `.inputSm`、`.slider` | 已补两条 |
| `pages/SessionDetail/Duplicates.module.css` | `.slider` | 已补 |
| `pages/Similarity/Similarity.module.css` | `.slider` | 已补 |
| `components/SliderInput/SliderInput.module.css` | `.slider` | 已补 |
| `pages/SessionDetail/Export.module.css` | `.slider` | 已补（同上文件） |

**有 `:focus` 边框色替代的 12 处 → 已达标，不改代码，记录如下：**（`border-color: var(--color-primary)` 为可见焦点指示，满足 WCAG 2.4.7 AA）

- `Gallery.module.css:31` `.searchInput:focus`
- `Export.module.css:88` `.select:focus`、`:105` `.input:focus`
- `Persons.module.css:54` `.searchInput:focus`、`:184` `.input:focus`
- `PersonDetail.module.css:231` `.input:focus`、`:249` `.textarea:focus`
- `MetadataPanel.module.css:71` `.fieldInput:focus`
- `Dashboard.module.css:177` `.input:focus`
- `SliderInput.module.css:60` `.number:focus`
- `Settings.module.css:137` `.input:focus`、`:318` `.pathInput:focus`

**建议（非阻断，UI 工作流）**：上述 1px 边框变色满足 AA，但 2.4.11 Focus Appearance（非 AA 必选）推荐统一改为 `:focus-visible` outline，与全局规则一致。

## 3. jest-axe 回归（新测试文件，全部通过）

| 文件 | 覆盖 | 断言 |
|------|------|------|
| `tests/unit/renderer/a11y-dialog.test.tsx` | Dialog 打开态（含可聚焦内容）、零可聚焦边界（仅文本）、关闭后（未挂载） | `toHaveNoViolations`；另含故意违规用例（无标签 checkbox → `label` 规则触发），证明 matcher 可用 |
| `tests/unit/renderer/a11y-similarity.test.tsx` | Similarity 全页（mock react-router/react-query/api/hooks/WritebackReport），组头区域（checkbox + aria-expanded 按钮） | 组头区域与全页扫描均 `toHaveNoViolations`（F-2 修复后两个 range slider 已 label 关联，固定集 `[]`；另含结构断言：两个 slider 均有 id + `label[for]`） |
| `tests/unit/renderer/a11y-dashboard.test.tsx` | Dashboard 创建对话框打开（mock window.gather）、C1 预检块（c1:health 全通过 → 四格检查渲染） | 预检块与整个对话框均 `toHaveNoViolations`（F-1/F-3 修复后固定集 `['select-name']` → `[]`）；另含结构断言：`<select>` 有 id + `label[for]` |

测试约定：不依赖任何文案字符串（i18n 迁移并行）；结构查询（role/aria/class 前缀）；jsdom 环境补齐 `document.documentElement.lang` 与 `document.title`（否则 axe 环境规则误报）；`label` 规则对 placeholder-only input 不触发（axe 已知假阴性，见 §5 手工项）。无跳过/禁用规则——所有"带违规"断言均为固定已知发现集，新违规即失败。

## 4. VoiceOver 手工走查清单（关键流程，未自动化）

> 方法：`系统设置 → 辅助功能 → 旁白` 开启；每步记录预期结果，阻断性问题（无法到达/无法操作）标记 ✗。

### 4.1 创建工作区（Dashboard）

- [ ] 启动应用，焦点落在导航栏；Tab 可到达"新建工作区"按钮，聚焦可见（outline）。
- [ ] 按 Enter 打开对话框：焦点移入对话框内首个可聚焦元素（名称输入框）。
- [ ] VoiceOver 读出对话框标题（aria-labelledby 引用 h2）、输入框标签。
- [ ] 切换"导入来源"下拉（select 目前无程序化标签 → 预期 VoiceOver 只读 "pop up button"，**已知发现 F-1**，修复前记录）。
- [ ] Tab 循环不逃逸（最后一项 → 回到第一项）；Shift+Tab 反向。
- [ ] Esc 关闭，焦点恢复到"新建工作区"按钮。
- [ ] 背景 `<main>` 在对话框打开时 inert，VoiceOver 无法穿越到背景内容。

### 4.2 导入（本地文件夹）

- [ ] 打开对话框 → 选择文件夹按钮可 Tab 到达；触发系统目录选择。
- [ ] 名称自动填充后，提交按钮可用；Enter 提交，焦点随路由进入工作区。
- [ ] 若为 Capture One 来源：预检四格检查结果由 VoiceOver 朗读（aria-live="polite" 区域）；失败时引导文案可读，按钮状态（禁用/启用）有读出。

### 4.3 分析（相似度）

- [ ] 相似度页签可 Tab 到达；开始分析按钮聚焦可见、Space/Enter 触发。
- [ ] 分析中：进度条有等价文本（ProgressBar label），取消按钮可到达。
- [ ] 分组结果：组头 checkbox 可勾选（aria-label），展开按钮可到达，VoiceOver 读出展开/收起状态（aria-expanded）。
- [ ] 阈值/最小组大小滑块可用方向键调整（label 关联问题见 F-2，修复前 VoiceOver 只读 "slider" 无名称）。
- [ ] 写回区域：关键词输入框可输入；预览/写入按钮可操作；状态消息（同步状态）由 live 区域朗读。

### 4.4 导出

- [ ] 导出页签可到达；数量/格式控件有标签；执行导出按钮可 Tab 到达并有可见焦点。
- [ ] 导出进行中/完成后有文本反馈（非仅颜色）。
- [ ] 错误提示（如失败计数）为文本而非仅图标。

## 5. 发现汇总表（rule / file / severity / current state / fix / owner）

| # | 规则 | 文件 | 严重度 | 现状 | 推荐修复 | Owner |
|---|------|------|--------|------|----------|-------|
| C-1 | color-contrast（次级文本） | `styles/global.css` 等 | High | **已修复**（3.22→5.09 on bg；2.94→4.65 on bg2） | — | 已关闭 |
| C-2 | color-contrast（白字/主色按钮） | `styles/global.css` 等 | High | **已修复**（3.42→5.68） | — | 已关闭 |
| C-3 | color-contrast（info/success/error 文本与白字） | `styles/global.css` 等 | High | **已修复**（info 2.61→4.97、success 2.07→5.14、error 3.29→4.98；白字 2.96/2.35/3.72 → 5.63/5.83/5.64） | — | 已关闭 |
| C-4 | color-contrast（warning 双角色） | `styles/global.css` + `Settings.module.css`/`Culling.module.css`/`StepWriteback.module.css` + `Toast.module.css` | Medium | **已修复**：新增 `--color-warning-text` #9c5e28（on bg 4.58:1、on surface 4.86:1）；三处警告文本改用新 token；Toast 背景角色不变（`#111` 深字 7.33:1 无回归） | — | 已关闭 |
| F-1 | select-name | `pages/Dashboard/index.tsx` + `Dashboard.module.css` | Critical | **已修复**：`<select id="dashboard-new-source">` + `<label htmlFor>`（复用可见文案 key `dashboard.importSource`）；jest-axe 固定集 `['select-name']` → `[]` | — | 已关闭 |
| F-2 | label（range slider） | `pages/Similarity/index.tsx` | Serious | **已修复**：两个 slider 加 `id="similarity-threshold"` / `id="similarity-min-group-size"` + `<label htmlFor>`（复用 `similarity.thresholdLabel` / `similarity.minGroupSizeLabel`）；全页扫描 `[]` | — | 已关闭 |
| F-3 | label（placeholder-only，axe 假阴性） | `Similarity` 关键词输入框、`Dashboard` 名称/文件夹输入框 | Medium | **已修复**：Dashboard 三个输入（名称/来源/文件夹）均 `label[for]` 关联（复用 `dashboard.workspaceName` / `dashboard.importSource` / `dashboard.folderLocation`）；Similarity 关键词输入加 `aria-label={t('similarity.keywordLabel')}`（新 key，zh/en 双文件同步） | — | 已关闭 |
| F-4 | focus-appearance（1px 边框替代） | 12 处 `:focus` border-color（§2.2 列表） | Low | 已达标 AA；2.4.11 建议统一 outline | 与全局 `:focus-visible` 对齐 | UI 工作流（可缓） |
| F-5 | 语义化（可点击 div/span） | 各页（过滤条等） | Medium | **已修复**：FilterBuilder 逻辑徽章 span→`<button type="button">`（+aria-pressed）；Persons 卡片 div→`<button>`（内部 div/p 全部改 span，CSS 补 `display:block`/`text-align:left`/`padding:0`）；Gallery 缩略图格子 div→`<button>`（含 GalleryThumbnail 内部 span 化）。**记录不转换**：Dialog/Lightbox 遮罩层点击关闭（Esc 等价，APG 惯例非控件）；Lightbox 图片平移/缩放视口（拖拽面，非控件；缩放另有滚轮） | — | 已关闭 |
| F-6 | 文档/维护 | `styles/variables.module.css` | Low | **已修复**：全仓 grep 确认无引用后删除文件；`global.css` 为唯一 token 来源 | — | 已关闭 |

## 6. 范围说明与验证

- 未提交任何 git commit。本工作流（修复 C-4/F-1/F-2/F-3/F-5/F-6）改动：`styles/global.css`（新增 `--color-warning-text`）、3 个页面/组件的警告文本色、`pages/Dashboard/index.tsx`、`pages/Similarity/index.tsx`、`components/FilterBuilder/index.tsx`、`pages/Persons/index.tsx`、`pages/SessionDetail/Gallery.tsx`（F-5 语义化）、删除 `styles/variables.module.css`（F-6）、`locales/zh-CN.json` + `en.json`（新增 `similarity.keywordLabel`，双文件 key 集一致）、3 个 a11y 测试文件的固定集更新。未触碰：`Settings/index.tsx`、ControlCenter/C1StatusCapsule、主进程文件。
- 验证：`npm run typecheck`、`npm run lint --workspace=desktop`、`npm run test:vitest`（a11y 3 文件 8 用例全绿，固定集已更新为 `[]`）通过。
- 对比度计算脚本复现：色对按 WCAG 相对亮度公式计算（与 §1.2/1.3 表一致）；`--color-warning-text` #9c5e28：on `--color-bg` 4.58:1、on `--color-surface` 4.86:1；Toast `#111` on `--color-warning` #d4944f 7.33:1（未改动）。
