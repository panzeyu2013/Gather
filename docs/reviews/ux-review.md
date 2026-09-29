# Gather 用户体验评审（用户视角）

> 方法：4 个只读审查代理分别以"真实用户"视角走查 挑片/浏览、相似/重复、素材库/人物/人脸关键词、外壳/设置/导出/控制中心，逐条给出 `文件:行号` 证据；编排者汇总、去重、排优先级。**未运行 GUI**，结论来自代码路径与状态机；标注"推测"处需实跑确认。
> 证据基线：core `855 tests / 119 suites`、app `199 tests / 24 suites`（2026-09-28）。

## 0. 结论先说

产品**能力密度很高**（挑片键盘流、写回影响面清单、同步状态机、本地化覆盖度都达到或超过同类桌面工具），但存在**三类系统性体验缺陷**：

1. **承诺与实现脱节**：tooltip 写「撤销（⌘Z）」但通知无人 post；文案写"可拆分人物"但没有 `fkw.split`；设置页提示打内部 key。
2. **批量与规模不成立**：重复页 230 组要点击 ~690 次；人物簇成员被后端截断为前 4 个（第 5 个之后**永远删不掉**）；万张库筛选会链式拉满整库。
3. **失败与回滚无回路**：取消分析后槽位仍占用、冲突裁决面板不在本页、写回回滚被"先同步才能清理"的顺序锁死、初始化失败只进 stdout。

## 1. 主线路径上的摩擦（按用户旅程）

| 旅程 | 摩擦 | 证据 |
| --- | --- | --- |
| 打开会话 → 浏览 | 挑片后回到浏览页**零痕迹**（行不含 `rating/colorLabel/pickState`，网格不画星级/色标） | `Host/SessionCommandRouter.swift:2603-2627`、`Sources/GatherApp/Gallery/GalleryView.swift:479-563` |
| 浏览 → 挑片 | 切图先 `image = nil` → **灰屏闪一下**（2560px 预览、并发闸门 4、解码 100–800ms） | `Sources/GatherApp/Support/PhotoThumbnailView.swift:79-82`、`Culling/CullingView.swift:2915`、`:117-127` |
| 挑片决策 | **⌘Z 撤销不可达**：菜单挂 `Selector("undo:")`，页面却等 `.gatherMenuUndo` 通知，全仓无 `post` | `Host/GatherAppDelegate.swift:215`、`Culling/CullingView.swift:1475,3137`（tooltip 见 `:1829`） |
| 批量挑片 | Shift 点击只切换单张，无范围选/全选/按状态选；批量数只在左栏小字 | `Culling/CullingView.swift:2685,1899` |
| 自动前进 | 胶片到第 500 张时 `nextPhotoId` 返回 nil 而 `commit` 不触发 `loadMore` → **静默卡住** | `Culling/CullingView.swift:1019-1023` vs `:1031-1042` |
| 相似/重复 → 裁决 | 重复页**零批量**：每组"菜单→保留最佳→弹窗"三步，230 组 ≈ 690 次点击，无键盘、无自动前进 | `Duplicates/DuplicatesView.swift:633-636,443-455` |
| 重复裁决 → 可信度 | "推荐"= `fileSize*1000 + mtimeMs`（mtime 毫秒 ~1.7e12 压倒 size ⇒ 实为"最近修改者胜"），界面**不显示**分辨率/时间/依据 | `Duplicates/DuplicatesView.swift:339-341`、`core/Services/DuplicateService.swift:547-559` |
| 相似 → 写回 | 预览上限 50 不可展开；改关键词/切阈值即清空预览与选择 ⇒ 大批量等于盲签 | `Similarity/SimilarityView.swift:411-419,225-234`、`SimilarityViewModel.swift:666-676,718-722` |
| 相似 → 取消 | 取消不等终态且丢弃返回值：界面立刻"未分析"，服务端槽位仍占用 → 立刻重分析报占用 | `SimilarityViewModel.swift:507-518`、`core/Services/SimilarityService.swift:153` |
| 冲突裁决 | 冲突只禁用按钮提示"请先裁决"，**本页无入口**（面板只在挑片页） | `SimilarityViewModel.swift:955-956,986`、`Culling/CullingView.swift:2268-2360` |
| 人脸 → 审核 | 成员列表**后端硬截断为前 4**（`maxPreviewMembers=4`），标题却写"300 名成员"；无取全量成员的接口 | `core/Services/FaceKwService.swift:890`、`FaceKeywording/FaceKeywordingView.swift:1400-1412` |
| 人脸 → 判断是谁 | 成员行**没有头像**、蒙太奇是整图缩略图（`bbox` 可用却不用）⇒ 只能靠文件名判断 | `FaceKeywordingView.swift:1698-1720,1344`、`core/Face/Face.swift:206` |
| 人脸 → 绑定 | 核心已算好的 `matchedPersonName/matchConfidence` 入库但 **UI 零引用**；所有簇都叫 "Person 1/2/3…" | `core/Services/FaceKwService.swift:888-891,1147` |
| 人脸 → 重聚类 | "仅重新聚类"**无确认即删库重建**，人工绑定/合并全部还原；无撤销 | `FaceKeywordingView.swift:1030-1033`、`FaceKwService.swift:1178-1188` |
| 人脸 → 回滚 | 写回回滚只有 `fkw.cleanup`，却被 `isSyncConfirmed` 门控 ⇒ 想撤销错误关键词，得先让 C1 把错数据加载进来 | `FaceKeywordingView.swift:1680-1686` |
| 设置 | 无自动保存/脏标记，**离开页面即静默丢弃**（保存提示已改用界面标签，不再打内部 key；见附录） | `Settings/SettingsView.swift:97,265`、`Sources/GatherApp/RootView.swift:196` |
| 导出 | 未点"预览"直接导出，确认框写「写入 0 个文件」；失败无重试/无"在访达中显示" | `Export/ExportView.swift:174,458,758-784` |
| 控制中心 | 索引中 Inbox 反而显示「全部正常」（`scanIncomplete` 被 filter）；同步卡"请先处理"无按钮；工具箱承诺"可取消"但无取消按钮 | `ControlCenter/SessionControlView.swift:496-503,758-793,745` vs `:803-824` |
| 启动 | 首屏只有纯文字「初始化中…」无 spinner；初始化/导入失败只写 stdout（Finder 启动不可见） | `Sources/GatherApp/GatherApp.swift:49-52,139-145,274-276`、`core/Logging/Logger.swift:24` |

## 2. 功能完整度

**达到或超过同类的地方（应保留）**
- 挑片页：1/2/4 图对比 + 1–8× 缩放 + 人脸对齐、六维筛选、P/X/U/空格/0–5/方向键、服务端撤销/重做、6 态同步机 + 逐条失败原因 + 冲突逐字段裁决 + 破坏性确认。
- 人脸关键词**写回预览是行业级"影响面清单"**：before→after、新建/更新 XMP、共享张数、外部冲突、示例路径（`FaceKeywordingView.swift:1604-1631,625-644`）——Lightroom/Immich/C1 都不给逐文件 diff。
- 本地化：人脸关键词 178/178 key 双语零缺失；挑片页 285 处 `l()` 仅 1 键缺 en。
- 长任务可取消、断点可恢复（人脸分析）。

**半成品 / 缺失**
| 能力 | 状态 | 证据 |
| --- | --- | --- |
| 人物拆分 | **承诺有、实际无**（无 `fkw.split`，只能逐条 `remove_member`） | `FaceKeywordingView.swift:999,333-348` |
| 人物合并 | 有命令无 UI（`person.merge`），人物页不能合并/删关联照片 | `Persons/PersonsViewModel.swift:7-14`、`Host/SessionCommandRouter.swift:1032` |
| 按人检索 | 有命令无 UI（`person.search_photos`） | `SessionCommandRouter.swift:1052` |
| 重复页批量/过滤/键盘 | 全无 | `Duplicates/DuplicatesView.swift`（无选择态） |
| 网格内看改星级/色标 | 无 | `Gallery/GalleryView.swift:479-563` |
| 1:1 像素检查 | 无 | `Culling/CullingView.swift` 缩放上限 5× |
| 帮助 | 仅外链 GitHub，无 "?" 面板 | `Host/GatherAppDelegate.swift:341-345` |
| 搜索/页面切换快捷键 | ⌘F、⌘1–6 均无 | grep 仅 ESC/Return/⌘+−0 |
| 存储面板（库位置/占用/清缓存/备份） | 仅 `disk_cache_dir` | `Settings/SettingsView.swift:609-617` |
| 导出预设/参数记忆 | 无（离开页签归零） | `Export/ExportView.swift:37-49` |

## 3. 交互与反馈（系统性问题）

1. **确认过重、撤销过轻**：非破坏动作也逐组强制弹窗（重复页），而真正需要的"批量应用+一次确认+可撤销"没有；全 App 除挑片页外**无 undo 栈**。
2. **状态不可见**：相似页滑块草稿与统计条结果阈值可分离且无"未应用"标识；重复页改阈值不重算也无"结果已过期"；重复页扫描中仍渲染旧列表且组菜单未禁用（**可对陈旧结果裁决**，`DuplicatesView.swift:405-420,633-636`）。
3. **键盘覆盖不均**：挑片页有完整键盘流，重复/人脸/人物页几乎为零；全局 `.nonFocusable()` 让 Tab 全键盘不可达（`Culling/CullingView.swift:3172`）。
4. **错误不可行动**：未知码一律兜底「发生未知错误，请稍后重试」；Toast 有 `actionTitle` 能力但**全项目无人使用**（⇒ 错误不能一键重试）。
5. **取消语义不安全**：相似页取消后槽位仍占用；重复页 `cancelScan` 无 jobId 静默返回；以英文 `"cancelled"` 子串识别取消态（本地化后易失效，`DuplicatesView.swift:177-183`）。

## 4. 信息架构与页面设计

- 侧栏 5 项 + 会话内 6 页签，层级清楚（`Support/SessionTabBar.swift:23-44`）✅
- **设置页约 30 个控件堆在一张卡**，无搜索/锚点；`select` 描述重复键值（`SettingsView.swift:1338-1354,625/668/696/709`）。
- **命名不统一**：挑片/保留/淘汰/未处理/写回 混用；簇名 `Person N` 无意义且重排。
- **计数与内容不一致**：人脸页标题按 `visibleClusters.count` 报"1500 组"，网格只渲染前 100（`FaceKeywordingView.swift:1205,1213`）；预览静默截断 50 项、因成员≤4 永不显示"还有 N 名成员"（`:1588,1558-1564`）。
- **头像质量**：取"最近关联的那张整图"，非人脸裁切、不可选（`core/Database/Repositories/PersonRepo.swift:237`）。

## 5. 空态 / 加载 / 错误态

- 空态组件齐、部分带 CTA ✅；但**首页空态无 CTA**（`Dashboard/DashboardView.swift:252-257`）、首屏无 spinner。
- 挑片页 0 张新会话仍提示"切换范围或清除筛选"（误导，`Culling/CullingView.swift:1435-1440`）。
- 相似页 `result == nil` 且非加载时只剩分析卡，**无引导**。
- 浏览页分页失败只挂顶部横幅，哨兵失败后可能不再触发 ⇒ **无限滚动静默中断**（`GalleryViewModel.swift:539-546`）。

## 6. 无障碍与本地化

- 挑片页胶片/决策/色标/星级都有 `accessibilityLabel` ✅；**重复页零 a11y 标注、零 `.help`**。
- 人物行 `.accessibilityLabel(person.name)` **覆盖子内容**，VoiceOver 丢掉"N 张照片·M 个工作区"（`Persons/PersonsView.swift:166`）；"移除"按钮标签恒为"移除"，文件名只在 `.help` ⇒ 一串无差别"移除"（`FaceKeywordingView.swift:1711-1719`）；缩略图无任何标注（`PhotoThumbnailView.swift:34-68`）。
- 英文表 1172 条，但**约 20 条 `l()` 无 en 条目**（导出确认、初始化失败、Library 多条）⇒ 英文界面下弹窗回退中文（`Export/ExportView.swift:455/459`、`GatherApp.swift:40`）。
- 静态 `presets` 首次访问定稿 ⇒ **运行时切语言后不跟随**，需重启（`FaceKeywordingView.swift:68-72`）。

## 7. 性能感知（大库）

| 现象 | 证据 | 影响 |
| --- | --- | --- |
| `filteredPhotos` 每次 body 重建数组并参与 `.onChange` 深比较；布局 key 对全量求 hash 和 | `Gallery/GalleryView.swift:98,376,416` | 万张库每次交互 CPU 抖动 |
| 点筛选以 1000/页**链式拉满整库入内存**，只有 12pt 转圈 | `GalleryView.swift:326`、`GalleryViewModel.swift:503-516` | 无进度、无取消、内存峰值 |
| 挑片页每按一次 P/X 静默重取 500 行 + 5 个辅助查询 | `Culling/CullingView.swift:645-714,950` | 决策延迟与抖动 |
| 查看器解码 2560px、并发 4、切图先清空 | `PhotoThumbnailView.swift:79-82,117-127` | 按 P/→ 全程闪灰 |

## 8. 优先级修复清单

**P0（数据/信任受损，或按当前实现无法完成任务）**
1. 人脸簇成员可见性：新增 `fkw.members`（分页 + 低置信度优先），否则**第 5 个之后的误聚成员永远删不掉**，且无 split ⇒ 误聚类不可修。后端：`FaceKwService.swift:890,1400-1412`。
2. 「仅重新聚类」加破坏性确认（写明"重建 N 簇、丢失 M 处人工修订"）或改增量；`FaceKeywordingView.swift:1030-1033`。
3. ⌘Z 撤销接线（菜单 action post `.gatherMenuUndo/.gatherMenuRedo`，或 `NSUndoManager` + Toast 撤销）；`GatherAppDelegate.swift:215`、`Culling/CullingView.swift:1475`。
4. 写回回滚顺序反了：`fkw.cleanup` 不应被 `isSyncConfirmed` 前置门控（回滚路径必须始终可用）。

**P1（高频路径效率）**
5. 重复页批量：多选 + "应用推荐（限定类型/阈值/仅未处理）" + 页级一次确认 + 可撤销。
6. 重复页显示判据：分辨率/文件大小/拍摄时间 + "推荐依据"tooltip，策略可选（最早拍摄/最高分辨率）。
7. "已处理 X/N" + 仅未处理 + 裁决后自动前进；扫描中禁用陈旧结果裁决。
8. 相似页写回预览可展开/导出、草稿与选择持久化。
9. 设置页：自动保存或脏标记 + 离开拦截（提示改用 `zhLabel` **已修**，见附录）。
10. 导出：无预览时不要显示「写入 0 个文件」；失败项加"重试/在访达中显示"。
11. 浏览网格显示决策（星级/色条/旗标），行补 `rating/colorLabel/pickState`。
12. 人脸审核：用 `bbox` 裁人脸头像、显示 `matchedPersonName`+置信度并一键采纳、簇名改"首成员文件名 + 人数"或可重命名。
13. 取消语义：`cancelAnalysis` 等终态并回传结果，失败/占用给可见提示；重复页取消改用 jobId + 稳定错误码（别靠英文子串）。

**P2（打磨与规模化）**
14. 翻页/切图保留上一帧 + 预取 ±1/±2（Gallery 灯箱已有实现可复用）。
15. 万张库：筛选下沉服务端或持久 id 列表 + 进度/取消；避免每次 body 重建。
16. 键盘与焦点：重复页/人物页补键盘流（复用挑片页模式）、去掉 `.nonFocusable()`、补 ⌘F/⌘1–6/"? 帮助"。
17. a11y：重复页补标注；人物行标签合并子信息；"移除"带文件名。
18. 补齐 en 文案缺口；语言切换即时生效（勿在静态初始化时定稿文案）。
19. 控制中心：索引中显示"索引进行中"而非"全部正常"；"请先处理"给按钮；任务行给取消。
20. 首屏 spinner + 失败横幅（含"打开日志/重试"）；日志落盘。

## 9. 值得学的产品模式

| 学谁 | 模式 | 我们的落地成本 |
| --- | --- | --- |
| Apple Photos | "合并重复项"一次合并 + 撤销；缩略图保持上一帧/模糊占位而非灰框 | 低（已有 `status` 标记与 history 表） |
| Lightroom | 网格内直接星级/旗标/色标并即时可见；导出预设记忆；整栈应用 | 中（需行补字段 + 预设持久化） |
| Capture One | 对比模式明确主图指示、各格独立/同步缩放、色标数字键；撤销贯穿评级 | 低-中（键盘层已有） |
| Immich | 乐观更新 + "已淘汰 12 张·撤销" Toast；人物页合并/隐藏/生日 | 低（Toast 已支持 action） |

## 附录：算法改造轮次顺带修复（2026-09-28）

人脸算法对标改造（ADR-029）落地时顺手修掉的三条设置页缺陷——它们的共同点是"旋钮存在但用户碰不到或改不回"：

| 缺陷 | 症状 | 修法 | 守它的测试 |
| --- | --- | --- | --- |
| 保存提示打内部 key | `已保存 thumbnail_size`，用户无法确认改的是哪一项 | `SettingsViewModel.label(for:)` 查表取 `zhLabel`（找不到才退回键名） | `SettingsSaveSemanticsTests.noticeUsesHumanLabel` |
| 文本键一律禁止清空 | 填错专用人脸模型路径后**再也退不回内置特征**（清空被判非法） | 只有"默认值本身为空"的键允许清空（`defaultValueIsEmpty`），其余仍拒绝 | `SettingsSaveSemanticsTests.clearing*` |
| 算法参数"只存在于数据库" | 质量门槛/二遍阈值/margin/模型路径/增量开关无法从界面设置 | 设置页新增 3 个滑杆 + 「人脸模型」分组；键必须注册进 `SettingsService.getDefaults()` | `SettingsCatalogTests`（UI 键 ⊆ 默认表、滑杆默认值一致、算法参数已暴露） |
| 错误配置潜伏到分析时才炸 | 错误的专用模型路径保存成功，直到下次分析才失败，且只显示"发生未知错误" | 保存模型路径时**当场校验**（展开 `~`/解析软链/存在性/扩展名），失败直接拒绝并显示与 core 逐字一致的中文原因 | `SettingsSaveSemanticsTests.unloadableModelPathIsRejectedOnSave` 等 |
| 保存校验把界面卡死 | 第一版"当场校验"会**同步加载模型并整包哈希**（256 MiB 实测 48.4s，跑在 `@MainActor` 上）| 保存只做廉价校验，不加载/不哈希；"能否真正加载"交给分析路径（`fkw.analyze` 的错误现在能上屏） | `SettingsSaveSemanticsTests.廉价校验*`（垃圾包放行、`~` 展开、扩展名拒绝、空目录拒绝、软链放行） |
| 模型错误对用户不可读 | 分析失败只显示"发生未知错误"——**加路由分支并不够**：分析页把消息交给 `GatherLocalization.errorText`，非错误码文案一律回落通用提示（对抗验证 V1 探针 F 实测四类文案全被吞） | 显示路径改为三段判定：①已知错误码 → 本地化模板；②原文含中日韩字符（core 的 `FaceEmbeddingError.description` 这类已经是人话）→ 原样上屏；③其余（英文 NSError 散文）→ 通用文案 + 原文进 tooltip | `ErrorLocalizationCoverageTests`（中文原因必须原样出现、英文 NSError 必须不出现） |
| 部分失败伪装成"分析完成" | 1 张脸编码失败 + 1 张成功 → 状态是 `done`，界面显示"人脸分析完成"，用户不知道有脸没被处理 | 成功后检查 `encodingFailures`：>0 时改为可见警示（"N 张脸编码失败，下次分析会自动重试"），不显示完成文案 | `FaceKeywordingViewModelTests`「部分失败可见…」与「零编码失败：警示清除…」 |
| 重新聚类无确认 | 「仅重新聚类」会重建全部簇并还原人工绑定与合并，一键即不可撤销 | 弹破坏性确认，文案陈述真实影响面（簇总数/已绑定数）并指向保留绑定的「开始分析」增量入口 | `FaceReclusterConfirmTests`（影响面计数、文案含两个计数与增量指引、取消写可见文案） |
| 簇卡片成员过少 | 审核时只能看到前 4 张成员，难以判断"这个簇是不是同一个人" | 预览成员上限 4 → 12（仅载荷裁剪，仓库层本就取全量；约 3 KB/簇） | `FaceKeywordingServiceTests.truncatesMembersAndMapsBinding` |

配置了专用模型却加载失败时，分析会**直接报错**而不是退回内置 Vision 特征——两套向量空间混进同一列会让此后所有阈值静默失效（见 [ADR-029](docs/ADR.md)）。

**未修（属 UX 轨，需要产品决策）**：设置页**没有自动保存/脏标记**——编辑后直接离开页面即丢失（本页所有输入都要点"保存"）。这是 P1 #9 的根因，修它要改保存语义（影响面超出算法改造轮次）。

---

*本文档由 4 份只读审查报告汇总；所有结论附 `文件:行号`，未标注"推测"处均可在代码中复核。*
