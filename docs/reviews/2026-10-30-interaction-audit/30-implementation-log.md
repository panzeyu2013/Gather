# 整改实施记录 · 第一版（2026-10-30）

> 依据：`10-synthesis.md`（缺陷与优先级）+ `20-hci-review.md`（习惯与节拍）。
> 口径：只做**低风险、可静态验证**的部分；涉及产品立场的取舍一律不动，列在 §4。
> 验证：`swift build` ✅ / `swift test` 796 例 90 套 ✅ / 5 个仓库门禁 ✅。

---

## 1. 改动清单（17 文件，+99 / −19）

| # | 位置 | 改动 | 动机 | 风险 |
| --- | --- | --- | --- | --- |
| 1 | `DesignSystem/Components/GatherToast.swift` | 去掉容器 `.allowsHitTesting(false)`、去掉子按钮上无效的 `true`，改为**只让图标/文字不参与命中** | SwiftUI 命中测试自祖先向下收敛，子节点无法重开 → toast 的「×」「重试」点不动，导入失败唯一恢复入口失效 | 低 |
| 2 | `Gallery/GalleryViewModel+Load.swift` | 新增 `refresh()`：有内容时走 `refreshOnEvent()`（就地重取、不切 loading、不动选择），首屏失败才回退 `load()` | 「刷新」不再等于「清屏 + 清选择 + 回顶」；与浏览器/访达的心智一致 | 低 |
| 3 | `Gallery/GalleryToolbar.swift` | 刷新按钮/⌘R 改接 `refresh()` | 同上 | 低 |
| 4 | `Culling/CullingViewModel.swift` + `+Actions.swift` | `commit` 串行化：先等上一拍落地再执行，`performCommit` 在执行时才取 `currentAsset` | 挑片 2–3 拍/秒，旧实现并发提交同一张 + 过期 `expectedRevision` → 冲突横幅。串行后「连按」自然翻译成「处理下一张」 | 中（核心路径，已有 796 例回归） |
| 5 | `Culling/CullingInspector.swift` | 去掉与分区标题重复的「当前照片」行；只在 `count > 1` 时显示「批量 N 张」 | 首屏第一眼是两行同义文案；单选显示「批量 1 张」也不对 | 低 |
| 6 | `Settings/ResetImpactSheet.swift` | 破坏性「恢复默认」不再绑 `.defaultAction` | 影响面 sheet 里按 Return 会直接清空偏好（且偏好默认勾选） | 低 |
| 7 | `Interaction/GatherSessionPage.swift` | 页签阈值 620 → **按语言取 430 / 560**；选中页签：品牌色文字 + 品牌色 0.45 描边 | 620 让 860 最小窗在中文下也永远退化成菜单；原选中态只靠 ~8% 亮度差，提高对比度下会消失 | 低 |
| 8 | `ControlCenter/SessionControlView.swift` | 整页转圈只在「还没有任何快照」时出现 | 索引活跃期 3s 一轮，每轮替换内容会清掉滚动与阅读上下文 | 低 |
| 9 | `Gallery / Library / Dashboard / Culling` 四处错误横幅 | 传 `onDismiss`，清除对应 `actionError/errorMessage` | 28 处横幅只有 8 处可关；红色错误条会永久挂着 | 低 |
| 10 | `DesignSystem/Components/NativeBanner.swift` | `.accessibilityElement(children: .combine)` → `.contain` | combine 会把「关闭」并进文本元素，VoiceOver 读不到也点不到 | 低 |
| 11 | `CullingInspector / CullingToolbar / C1StatusCapsule` | 3 处 `.font(.callout)` → `.font(GatherFont.secondary)` | 同值替换（`GatherFont.secondary = Font.callout`），把设计系统债务往下压 | 无（视觉等价） |
| 12 | `Culling/CullingWorkbenchViewer.swift` | 查看器加 `@FocusState` + `.focused` + `onAppear` 取焦点 | P/X/U、0–9、←/→ 都挂在该视图的 `onKeyPress` 上；旧实现无任何聚焦请求，进页面必须先点一下图裸键才生效 | 中 |
| 13 | 同文件 | 新增 6–9 = 红/黄/绿/蓝色标（不触发自动前进） | 对齐 Lightroom 的色标习惯；此前按 7 什么都不会发生 | 低 |

---

## 2. 样式层面单独说明

用户要求"连同前端样式一起推进"。本版在样式上做了四件事，都是**语义层**而不是重绘：

1. **选中态不再只靠亮度差**（#7）：页签选中改为品牌色文字 + 0.45 描边。理由：原实现是「白片 + 0.5pt 70% 描边 + 阴影」，在提高对比度模式下三者几乎同时失效，只剩文字粗细。
2. **页签在最小窗口保住七个入口**（#7）：阈值按语言取，中文 430、英文 560。这是"样式即可达性"——退化菜单不是样式问题，是让用户多点一次。
3. **重复信息清掉**（#5）：检查器不再把分区标题重复一遍。信息密度靠"减法"提升，不靠字号。
4. **字体令牌替换**（#11）：三处裸 `.callout` 换成 `GatherFont.secondary`（同值），并把 ratchet 基线从 89 锁到 86——样式债只能降，不能悄悄涨。

没有做视觉重绘（颜色/圆角/阴影/布局大改）：这类改动必须逐页截图比对，而本环境无法运行 GUI，改了等于把风险留给用户。

---

## 3. 验证

```text
swift build   ✅ Build complete
swift test    ✅ Test run with 796 tests in 90 suites passed
check-design-system  ✅ PASS（font.callout 89 → 86，基线已锁）
check-layering       ✅ OK
check-duplicate-symbols ✅ PASS
check-no-legacy      ✅ OK
check-warnings       ✅ PASS（全量重建 19.96s，无新告警）
check-docs           ✅ PASS（错误码 209 / en 1862 键 / schema 44-386-72-65）
```

**未验证（需实机）**：
- toast 的「×/重试」是否真的可点（本版按 SwiftUI 命中测试规则修正，逻辑上成立）；
- 查看器初始焦点是否按预期抢到（若 macOS 已有初始 first responder，本改动是幂等的）；
- 860×560 下页签是否稳定显示为标签条（中文）；
- 连按 P 的节拍是否真的不再出冲突横幅。

---

## 4. 刻意没动（等决策或等实机）

| 项 | 为什么不动 |
| --- | --- |
| Space 双义（挑片=保留 / 浏览=切选） | 纯产品立场，两种改法都会让一批用户误操作，必须你来定 |
| 返回箭头语义 | 删/改名/保留是三种产品形态，不是 bug 修复 |
| 刷新「硬重载」档（⌥⌘R） | 需要先确认用户是否需要"清空重来"的逃生口 |
| 页签上移工具栏 | 布局重排，必须截图比对 |
| 人脸 9 / 人物 3 个 dialog 同节点 | 先实机验一次；若只弹最后一个，按重复页拆节点 |
| 方向键滚动跟随（ScrollViewReader） | 需要 Grid 锚点与 justified 重排一起改，属于下一批 |
| 人物草稿自动保存 | 涉及"切走即保存"的写路径，得配撤销 |
| 路由/页签重启恢复 | 需要 `@SceneStorage` 序列化 `AppRoute`，且要定"恢复到哪一页"的产品规则 |
| 撤销替代可逆确认 | 要为重复/人物/元数据各建一套撤销栈，工作量大，先做确认减负 |

---

## 5. 下一批建议（按 L1→L3）

**L1（每天）**
1. 方向键滚动跟随 + 游标可见（Gallery）：`ScrollViewReader` + 网格锚点。
2. 工作台/dev 网格的 Return / 双击打开。
3. 键盘作用域：文本框 opt-out，其余页面级常驻（替代"焦点环"思路）。

**L2（每周）**
4. 完成态保留 + 过期标记（相似度/导出）。
5. 缩略图 mtime 进键 + FSEvents 失效。
6. 交付/导出失败项的逐项重试。

**L3（低频）**
7. 错误通道分层：需要动作的错误 → 页内常驻；瞬时 → toast。
8. 弹窗按节点拆分（人脸/人物）。
9. 术语与日期 locale 收敛。
