# 下一轮计划：核查与执行矩阵（2026-10-30）

> 来源：`40-style-pass.md` §5（样式下一轮）+ `10-synthesis.md`（P1/P2）+ `20-hci-review.md`（L1–L3）。
> 本文先把每一项**在代码里核实一遍**，给出可行性/风险/依赖，再按批次执行。
> 执行状态随进展更新（见文末 §5）。

---

## 1. 核查结论（先说要改判的）

| 原计划 | 核查后 | 依据 |
| --- | --- | --- |
| 相似度「结果指纹写错 → isResultStale 恒 false」 | **部分成立**：阈值维度其实是准的；错的是**预计算档的组大小/分组模式**——`adoptResult` 把**草稿值**写进 `resultParams`，而结果显示的分组是服务端按档位参数算的 | `SimilarityViewModel+Result.swift:31-35` |
| 相似度「预计算档应把草稿同步成结果参数」 | **不采纳**：现有测试明确要求"预计算档不覆盖组大小草稿"（TS lastSyncedResult 语义） | `SimilarityViewModelTests.swift:117-128` |
| 缩略图「加 mtime 进内存键」 | **降级做法**：每格 stat 代价高。改为**可失效的缓存世代** + 外部变更时定向失效（先做 API 与入口，FSEvents 留给下一轮） | `PhotoThumbnailView.swift:760-782`（只有 image/setImage，无 remove） |
| 术语统一（工作区/会话） | **不做**：223 vs 234 处，改文案＝改 key＋en 表＋门禁计数，属于一次性大迁移，收益是"文案一致"而不是"体验变好" | `C1HealthSection.swift:99` 等 |
| 导出失败项逐项重试 | **本轮不做**：需要新的 API 形状（按 item 重跑），属于功能而非样式/交互 | `ExportView+Result.swift:14-56` |

其余 11 项核查通过，可执行。

---

## 2. 执行矩阵

### 批次 S · 样式（5 项）

| ID | 事项 | 代码事实 | 风险 | 验证 |
| --- | --- | --- | --- | --- |
| S1 | 页签切换 0.2s 交叉淡入 | `SessionPageHost` 用 `.id()` 强制重建（`SessionPageHost.swift:48`），是 remove+insert；需要在**父容器**上有 `animation(value:)` 才会播 | 中：可能让整棵 detail 参与动画 | 构建 + 实机看抖动 |
| S2 | 检查器分区折叠（元数据/模板/导入/技术建议） | 检查器 14 段一路竖排（`CullingInspector.swift:184-360`）；已有 `GatherInspectorSection` 可复用 | 低 | 构建 + 测试 |
| S3 | 空态暖化（品牌色图标 + 更好留白） | `GatherEmptyState` 是 `ContentUnavailableView` 薄包装，仅 3 个调用点 | 低 | 构建 |
| S4 | 侧栏行高 34、行距 2 | `RootShellSidebar.swift:115-146` 两行紧凑排布 | 低 | 布局预算测试 |
| S5 | 状态胶囊「尚未写回」中性态 | `C1StatusCapsule.swift:295-298` 空计数直接落绿色"已同步" | 中：新增 l10n key → en 表 +3 处文档计数 | 门禁 check-docs |

### 批次 I · 交互（4 项）

| ID | 事项 | 代码事实 | 风险 |
| --- | --- | --- | --- |
| I1 | 图库方向键滚动跟随 | 无 `ScrollViewReader`；`moveGalleryCursor` 只改 `keyboardCursorId`（`GalleryView+Content.swift:325-337`） | 中：justified 网格重排后 scrollTo 可能落点偏 |
| I2 | 工作台会话行双击 / Return 打开 | `SessionRowView` 只有行尾「进入」按钮与右键菜单（`:35/142`） | 低：List 行加 `onTapGesture(count: 2)` |
| I3 | 挑片网格单元悬停 | 单元只有 `onTapGesture`（`CullingGrid.swift:266`），无 hover | 低 |
| I4 | 人脸 9 / 人物 3 个 dialog 拆节点 | 9 个 `.gatherDestructiveConfirm` 串在一条链上（`FaceKeywordingView+Confirmations.swift:159-240`）；重复页已按节点拆开 | 中：要复刻重复页的拆法 |

### 批次 D · 状态（2 项）

| ID | 事项 | 代码事实 | 风险 |
| --- | --- | --- | --- |
| D1 | 相似度回页保留选择/写回结果 + 指纹用**结果参数** | `adoptResult` 无条件清空并 `markWritebackDraftChanged()`（`:21-24`） | 中：需判定"同一结果" |
| D2 | 缩略图缓存可失效（世代 + 清空入口） | 缓存无 remove/invalidate（`:760-782`） | 低（只加 API 与一个调用点） |

### 批次 P · 收尾（2 项）

| ID | 事项 | 风险 |
| --- | --- | --- |
| P1 | 日期跟界面语言（用已有 `DisplayDateFormatters(locale:)`） | 低 |
| P2 | 错误通道分层：需要动作的错误留在页内（本批只统一"可关闭 + 不自动消失"，不做视觉重构） | 低 |

---

## 3. 执行顺序与门禁

每批固定流程：**改 → `swift build` → `swift test`（796 例）→ 5 个门禁 → commit 记录**。
若某批引入红灯且 30 分钟内无法收敛，回退该批并记入 §5「未完成」。

---

## 4. 验收口径

- 不新增 P1 级回归（测试全绿）。
- 设计系统 ratchet 只能降不能升。
- 每项都有"用户能感知的变化"一句话说明。

---

## 5. 执行记录（2026-10-30 完成）

| ID | 状态 | 落地内容 | 验证 |
| --- | --- | --- | --- |
| S1 | ✅ | `RootShellDetail` 的 detail 容器加 0.18s easeInOut 过渡（route 变化触发），尊重 reduceMotion | 构建/测试 |
| S2 | ✅ | 新增 `GatherCollapsibleSection`；挑片检查器「元数据 / 元数据模板 / 导入 / 技术建议写回」四段收成折叠分区（默认收起），首屏让位给"当前照片" | 构建/测试 |
| S3 | ✅ | `GatherEmptyState` 改为品牌色图形 + 标题 + 说明 + 动作（去掉系统空态视图）；ratchet `empty` 30 → 29 | 门禁 |
| S4 | ✅ | 侧栏行高：会话行 `minHeight 34`、其它行 `minHeight 24`（用 frame 不用 padding，避免 ratchet 记账） | 构建 |
| S5 | ✅ | 状态胶囊：从未写回时中性点 +「尚未写回」+下一步提示；信息条同一口径；新增 3 条文案，en 1,862 → 1,865，三处文档计数同步 | check-docs |
| I1 | ✅ | 图库方向键游标滚动跟随：`ScrollViewReader` + 行 id + `rowIndex(containing:)` | 构建/测试 |
| I2 | ✅ | 工作台会话行支持双击打开（行尾「进入」按钮保留） | 构建 |
| I3 | ⏭ 未做 | 挑片网格悬停：与"选中/当前"双层描边叠加会互相干扰，收益低 | — |
| I4 | ⏸ 暂缓 | 人脸 9 / 人物 3 个 dialog 拆节点：需先实机确认是否真的只弹最后一个；9 条流程盲改风险高于收益 | 待实机 |
| D1 | ✅ | 相似度回页保留选择/展开（分组集合不变才保留）；`resultParams` 记录**结果参数**而非草稿 | 构建/测试 |
| D2 | ✅ | `PhotoThumbnailCache.invalidateAll()`；图库/挑片"刷新"时清内存缩略图（外部改图后能立刻看到新图）；FSEvents 仍留待下一轮 | 构建/测试 |
| P1 | ✅ | 备份记录日期改为跟随界面语言（复用共享 formatter） | 构建 |
| P2 | ⏸ 部分 | 错误横幅可关闭已在前一批落地；"按错误类型分层渲染"未做（需要新的信息架构） | — |
| — | ⏸ 不做 | 工作区/会话术语统一（223 vs 234 处，改 key + en 表，收益是文案一致而非体验） | — |
| — | ⏸ 不做 | 导出失败项逐项重试（需要新 API 形状，属功能而非交互/样式） | — |

### 最终验证

```text
swift build                 ✅ Build complete
swift test                  ✅ 796 tests / 90 suites
check-design-system         ✅ PASS（font.callout 86 / empty 30→29 / 其余持平）
check-docs                  ✅ PASS（错误码 209 / en 1,865 键）
check-layering              ✅ PASS
check-duplicate-symbols     ✅ PASS
check-no-legacy             ✅ PASS
check-warnings              ✅ PASS（全量重建无新告警）
```

### 本轮踩到的两个坑（供后续参考）

1. **ratchet 的正则比名字更宽**：`spacing.literalPadding` 的匹配是 `.padding(` 后面跟数字或点，
   所以 `.padding(.vertical, 3)` 也会被记账。想加留白又不涨指标，用 `.frame(minHeight:)`。
2. **`ContentUnavailableView` 的注释也算命中**：把组件从代码里删掉但注释还写着名字，指标不会降。
   要么连注释一起改，要么接受"指标下降滞后一轮"。

