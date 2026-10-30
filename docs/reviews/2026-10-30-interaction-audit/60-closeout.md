# 收尾检查报告（2026-10-30）

> 范围：本轮全部改动（审计 → 实施 → 样式 → 计划全量执行）+ 工作树状态 + 13 个仓库门禁 + 两套测试。
> 结论：**可交付**。13/13 门禁通过、core 1459 + app 796 全绿、`git diff --check` 干净；
> 3 项暂缓（各有明确前置条件），8 项需实机确认（不影响代码质量门禁）。

---

## 1. 验证矩阵

| 项 | 结果 |
| --- | --- |
| `swift build`（gather-app） | ✅ Build complete |
| `swift test`（gather-app） | ✅ **796 tests / 90 suites** |
| `swift test --no-parallel`（gather-core） | ✅ **1,459 tests / 217 suites** |
| `git diff --check` | ✅ 无空白错误 |
| check-design-system | ✅ PASS（font.callout 86 / empty 30→29 / 其余持平） |
| check-docs | ✅ PASS（ADR 26 / 链接 269 / 错误码 209 / en **1,865** 键 / schema 44-386-72-65） |
| check-coded-errors | ✅ PASS |
| check-layering | ✅ PASS |
| check-duplicate-symbols | ✅ PASS |
| check-no-legacy | ✅ PASS |
| check-select-star | ✅ PASS |
| check-preview-surface | ✅ PASS |
| check-protocol-surface | ✅ PASS（公开面未变） |
| check-test-catalog | ✅ PASS |
| check-backlog-evidence | ✅ PASS |
| check-cleanup-ratchet | ✅ PASS |
| check-warnings | ✅ PASS（全量重建无新告警） |

**13/13 门禁 + 2 套测试全绿。**

---

## 2. 工作树状态

```text
41 个已修改文件（+370 / −145）
 3 个未跟踪项：GatherPresence.swift、GatherCollapsibleSection.swift、docs/reviews/2026-10-30-interaction-audit/
 0 个调试残留（无 print/TODO/force-unwrap 新增）
 0 个误改：gather-core / GatherProtocol 未动（protocol-surface 门禁自证）
```

未提交。建议提交信息：

```text
feat(ui): 交互与样式整改（三批）——焦点/串行化/刷新语义 + 去工具感样式

- 交互：toast 命中、挑片决策串行化、图库软刷新与方向键跟随、会话行双击、
  查看器初始焦点、色标 6–9、错误横幅可关闭、重置确认不吃 Return
- 状态：相似度回页保留完成态、指纹改用结果参数、缩略图缓存可失效
- 样式：页签阈值与选中态、检查器四段折叠、空态暖化、媒体圆角统一 8、
  库卡片悬停、元数据字号 10–11 → 12、页签/横幅过渡
- 文档：en 1,865 键、设计约定同步、7 份审计/实施文档
```

---

## 3. 一致性核查

| 检查 | 结果 |
| --- | --- |
| 新增 l10n key 是否都在 en 表 | ✅ 3 条（展开 / 尚未写回 / 尚未写回详情） |
| en 表是否有重复 key | ✅ 无 |
| 文档声明的 en 键数 | ✅ 三处（DEVELOPMENT / README / ROADMAP）已同步 1,865 |
| 文档声明的测试数 | ✅ docs/README 由 794 修正为 796，采样日期更新 |
| 新 token 是否有使用者 | ✅ `Radius.media` 6 处；`Radius.thumbnail` 仍有 8 处（小控件） |
| 新组件是否有使用者 | ✅ `GatherCollapsibleSection` 4 处、`gatherAnimatePresence` 6 处 |
| 是否有死代码 | ✅ 无新增未使用符号（duplicate-symbols 通过） |
| 是否改动公开协议面 | ✅ 未改（Protocol 冻结） |

---

## 4. 未完成项（3 条，均非"忘了"）

| 项 | 前置条件 | 为什么现在不做 |
| --- | --- | --- |
| 人脸 9 / 人物 3 个 `confirmationDialog` 拆节点 | **需实机点一次**确认是否只弹最后一个 | 若并不冲突，拆它纯属重构；若冲突则是 P0，但盲改 9 条写回流程风险更高 |
| 错误通道按类型分层 | 需要先定"哪些错误必须常驻"的信息架构 | 目前只做到"可关闭 + 不自动消失"，再往下是产品决定 |
| 导出失败项逐项重试 | 需要新的 API 形状（按 item 重跑） | 属功能开发，不该混在交互/样式批次里 |

另有两项判定为**不做**：工作区/会话术语统一（223 vs 234 处，改 key+en 表，收益是文案一致而非体验）、挑片网格悬停（与"选中/当前"双层描边打架）。

---

## 5. 需实机确认的 8 项（代码已就绪）

1. toast 的「×/重试」是否可点（本版按 SwiftUI 命中测试规则修正）。
2. 860×560 下页签是否稳定显示为标签条（中文阈值 430）。
3. 挑片页**不点图直接按 P/X** 是否生效（新增初始焦点）。
4. **连按 P** 是否还出冲突横幅（提交已串行化）。
5. 横幅淡入是否有"抖一下"（`.transition(.opacity)` + 0.18s）。
6. 深色模式下库卡片 4% 悬停叠底是否够明显。
7. 折叠后的检查器首屏是否只剩"当前照片"决策。
8. 状态胶囊在"从未写回"时是否显示中性「尚未写回」。

---

## 6. 交付物索引（7 份，3,113 行）

| 文件 | 用途 |
| --- | --- |
| `00-macro-overview.md` | 宏观：形态、五条结论、跨页一致性抽查 |
| `A–F-*.md`（6 份） | 分模块证据库（1,970 行原始发现） |
| `10-synthesis.md` | 合并结论：交叉验证、P0/P1/P2 |
| `20-hci-review.md` | HCI 视角再审 + 对计划的反思 |
| `30-implementation-log.md` | 第一批实施记录（17 文件） |
| `40-style-pass.md` | 样式诊断与"去工具感"8 项 |
| `50-next-batch-plan.md` | 计划核查矩阵 + 全量执行记录 |
| `60-closeout.md`（本文） | 收尾检查 |

---

## 7. 残留风险

1. **未实机**：本环境不能运行 GUI，所有视觉/焦点类判断都基于代码与既有截图；上表 8 项是唯一需要人眼的部分。
2. **相似度预计算档的语义**：把"结果参数"写进指纹后，切预计算档若其组大小与草稿不同，会立即显示"过期"。这是**真实状态**，但如果产品希望"预计算档 = 成套参数"，则应改为同步草稿（会与现有测试冲突，需要产品决定）。
3. **缩略图失效只在"刷新"时触发**：外部改图后不按刷新的用户仍会看到旧图。FSEvents 定向失效是正解，留待下一轮。
4. **删除风险**：本轮没有删除任何文件或公开符号，回滚只需 `git checkout .`（新增两文件需手动删）。
