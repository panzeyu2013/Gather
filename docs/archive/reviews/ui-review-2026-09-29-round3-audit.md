# 第三轮：同类问题发散审计（6 路 subagent）与修复

> 上一轮：[第二轮修复台账](ui-review-2026-09-29-round2-fixes.md)
> 触发：用户要求「按第二轮修复的记录，发散检查是否还存在类似问题」
> 方法：把第二轮暴露的问题抽象成 8 类，派 6 个**只读** subagent 分头扫全仓，父 agent 并行做最小宽度实测与修复。

---

## 0. 审计维度与结论概览

| 路 | 维度 | 新增确认问题 | 本轮已修 |
| --- | --- | --- | --- |
| A | 布局约束（最小宽度） | 4 项（1 高） | 2 |
| B | 几何/坐标换算 | 2 项确认 + 5 项疑似 | 0（已定位） |
| C | 派生状态失效 | 8 项确认 + 3 项疑似 | 0 |
| D | 页面状态/入口意图 | 1 P0 + 9 入口缺口 | 2 |
| E | 导航目标/主动作/文案 | 8 + 7 + 6 项 | 3 |
| F | AppKit/SwiftUI 冲突、通知契约 | 8 项（1 高） | 4 |
| G | 测试有效性 | 5 条 B/C 类测试、10 处覆盖缺口 | 0 |

**结论：第二轮修的是「点」，同类「面」上仍有大量同型缺陷。** 最集中的三类：
① 非滚动容器里的固定宽度横排（A/B 都有）；
② 派生结果缺少「输入指纹」（C，导出页是唯一修对的范式）；
③ 页面局部状态与入口意图（D，第二轮只覆盖了导出/人脸两个页面）。

### 本轮已落地的修复（12 项）

| # | 修复 | 位置 |
| --- | --- | --- |
| 1 | `infoBar` 由不可滚动 HStack 改为横向 ScrollView（Spacer 改固定分隔线） | CullingView.swift:2102 |
| 2 | 全局图库 inspector 列宽 320 → 260（与另两页对齐） | LibraryView.swift:103 |
| 3 | 深链角色过滤从 body 求值期改为页面 `.task` 消费（新增 `applyRoleFilterFromDeepLink`） | FaceKeywordingView.swift / RootView.swift |
| 4 | 导出入口意图改为**事件**语义（`applyRangeIntent` + 消费后清空），修掉「先去页签再点去导出失效」 | ExportView.swift / RootView.swift |
| 5 | ⌘Z / ⇧⌘Z 挂到可见撤销按钮（原先通知零发布者，快捷键从未生效） | CullingView.swift:1864 |
| 6 | 语言切换不再重装 AppKit 菜单（停止与 SwiftUI 抢 mainMenu），改由 App 层语言版本驱动 `.commands` | GatherAppDelegate.swift / GatherApp.swift / GatherAppCommands.swift |
| 7 | `GATHER_BOOTSTRAPPING` 收进 `GatherErrorCode` 并补文案（此前落「未知错误」） | Core.swift:334 / GatherLocalization.swift |
| 8 | C1 导入失败的错误载荷由英文诊断文本改为错误码 | GatherAppDelegate.swift:398 |
| 9 | 深链双投递（`.onOpenURL` + `application(_:open:)`）1 秒去重 | GatherAppDelegate.swift:197 |
| 10 | 全局图库工具栏 Picker 标签=首选项、硬编码「无色标」、导出目录占位过长 | LibraryView.swift / ExportView.swift |
| 11 | 预算阈值 700 → 680（真实可用宽度），删除 B 类「复述公式」测试，非法 bbox 补 `offset == .zero` 断言 | LayoutBudgetTests.swift / ReviewFixTests.swift |
| 12 | 修掉本轮新增测试的并行污染（留下带轮询的 VM 拖挂 SimilarityViewModel/GatherToast 时序断言） | LayoutBudgetTests.swift |

**验证**：`swift build` 通过；`swift test`（app）**251 项全绿**；`swift test`（core）951/952（1 项受构建沙箱限制）；两条门禁通过。

---

## 0.1 后续落地：P0/P1 修复（同日续做）

审计结束后，按 §8 的优先级继续修了以下 9 项（全部带测试）：

| 编号 | 修复 | 关键实现 | 测试 |
| --- | --- | --- | --- |
| B-C1 | 人脸对齐公式改为按 fit 显示尺寸并乘 zoom | 新增纯函数 `FaceAlign.offset(imageSize:cellSize:face:zoom:)`（CullingView.swift） | `faceAlignCentersBoundingBox`（竖构图 × zoom 2/4/8 不变量）＋**变异守卫**（旧公式必须失败）＋边界用例 |
| B-C2 | 拖拽平移改为累积（挑片查看器 + 图库灯箱） | `PanOffset.apply(start:translation:)` + `dragStartOffset` 基线，`resetTransform` 一并清零 | `panOffsetAccumulatesAcrossGestures`（两次 +50/+30 → 100/60） |
| D-P0 | 挑片 / 重复页 VM 纳入 SessionDraftCache | 两个页面新增注入式 init + RootView 工厂 `cullingViewModel(for:)` / `duplicatesViewModel(for:)` | 现有 259 项回归；跨页签保留为结构性保证 |
| E-P0 | 返回回到**真实来源**（工作台 / 全局图库 / 人脸库 / 图库） | `RootNavigation.SessionOrigin` + `backFromSession` / `backFromGallery`；会话内部切页签不覆盖来源 | `backReturnsToRecordedOrigin` / `galleryBackReturnsToOrigin` |
| E-P0b | 7 处返回按钮文案由「返回图库/返回工作台」改为「返回」（不再撒谎） | 7 个页面的 toolbar 标签 + 本地化条目 | 文案与行为一致，可静态核对 |
| C-#7 | 改阈值/预设后旧扫描结果标记过期 | `scannedThreshold` + `isScanResultStale`，视图显示「当前匹配强度为 X，上面的结果来自 Y；请重新扫描」 | `duplicateScanResultGoesStale` |
| C-#1 | `load()` 重选同一簇不再冲掉未提交的角色名/关键字草稿 | `select(_:)` 仅在 clusterId 变化时重置编辑字段 | `faceDraftSurvivesReloadOfSameCluster` |
| C-#3 | 换筛选/搜索后清空选择集（旧选择含已被筛掉的照片） | `reload()` 中 `selectedIds = []` | 结构性保证（与挑片 formIntersection 同旨） |
| E-重复动作 | 相似度空态不再复制主按钮；全局图库空库给「导入文件夹」出口而不是禁用按钮 | SimilarityView.emptyGroupsState / LibraryView.emptyState | 视图层改动 |

### 0.2 第三批落地（同日续做二）

| 编号 | 修复 | 位置 |
| --- | --- | --- |
| F-事件总线 | `GatherEventCenter.wire` 由「一次性」改为**按实例幂等**：bootstrap 重试拿到新 JobService 后重新接线，进度/终态帧不再静默消失 | GatherEventCenter.swift:86 |
| F-阻塞面板 | Dashboaord「选择文件夹」与全局图库「选择新目录」两处 `runModal()` 改为非阻塞 `await begin()` | DashboardView.swift:808 / LibraryViewModel.swift:476 |
| G-同步文案 | 挑片信息条的 `syncStatusText` 不再在 items 为空时**无条件**宣称「XMP 已同步」（计数非零时会给出相反结论）；改为二者一致 | CullingView.swift:2599 |
| E-丢目标 ① | 人物库「关联照片」网格可点击 → 直达该照片的图库查看器 | PersonsView.swift:318 |
| E-丢目标 ② | 相似度成员单元格「查看照片」+ 单击打开（原先只有「在 Finder 中显示」） | SimilarityView.swift:878 |
| E-丢目标 ③ | 重复成员卡「查看照片」（原先只有保留/丢弃，看不到照片本体） | DuplicatesView.swift:707 |
| E-通道 | 图库跳转支持**按 filepath 匹配**（相似度成员只有路径没有 photoId） | RootView（pendingGalleryPhotoPath）+ GalleryView（initialPhotoPath） |
| D-状态 | 相似度页 `onAppear` 不再无条件清空展开态并滚回顶部（结果替换已有 onChange 覆盖），从其它页签回来保留浏览位置 | SimilarityView.swift:258 |
| A2 | 人脸页 HSplitView 两栏最小宽度 320/280 → **280/240**，并用带簇的桩把「审核分支」纳入布局预算测试 | FaceKeywordingView.swift:1456 + LayoutBudgetTests |

**验证**：`swift build` 通过；`swift test`（app）**259 项全绿**；布局预算实测 12 个页面/分支全部 ≤576pt（含人脸页审核分支）。

仍未处理（按审计 §8 的优先级）：D 报告的入口意图四件套（xmp 冲突筛选、离线预筛选、重新分析提示、faceOnly 直达分析）、E 报告的其余 5 处「丢目标」（人物库照片网格、冲突面板定位、重复/相似度成员查看、工作台任务行）、
F 报告的 `NSEvent.modifierFlags` 误路由 / `runModal` 阻塞 / `GatherEventCenter` 一次性接线、A2 的 FaceKw HSplitView 最小宽度、G 报告的余下测试改造。

---

## 0.3 深度审查（D01–D12）修复台账

> 触发：外部深度审查报告（12 项：P1×3 + P2×9）。修复按「先交付真实性 → 再异步数据边界 → 再选择与目标 → 再输出描述与宿主」推进。

### 已修（13 项：D01–D07、D08、D09、D10、D11、D12）

| 编号 | 问题 | 修复 | 回归 |
| --- | --- | --- | --- |
| **D01** | 新一次导出继承上次完成记录：改命名/开 XMP 后返回 exported=1，却既没有新名字的文件也没有 .xmp | 交付身份 = **完整输出参数 + 参与照片集合的规范化指纹**（ExportService.deliveryFingerprint，JSONEncoder .sortedKeys 保证稳定）进 dedupeKey；执行器再按 checkpoint 里的 fingerprint 兜底校验，不一致就清空继承的 destinations/completedPhotoIds | deliveryFingerprintSeparatesNewDeliveriesFromResumes（同请求稳定 + 命名/XMP/格式/目录/照片集合变化各自产生新身份） |
| **D02** | 全部导出失败仍记成功任务 + 工作区「已导出」 | ①执行器把交付摘要（exported/failed/skipped/totalFiles）写入 checkpoint；②零成功且有失败 → 抛 EXPORT_ALL_FAILED（JobService 记 failed，与写回「结清时不得谎报成功」同约定）；③WorkspaceStatusService.hasSuccessfulExport 读摘要，exported>0 才算交付完成（无摘要的历史记录按原语义）；④结果提示区分部分失败 | 核心契约测试（错误码 175 + 固定清单）+ EXPORT_ALL_FAILED 文案 |
| **D03** | 确认弹窗把旧文件数与新目录/范围混在一起 | exportConfirmation 先冻结**完整请求快照**再预览；预览返回后校验计划指纹未变（变了作废并提示）；ExportConfirmation 携带冻结请求，确认后执行的就是它；新增 isConfirming 互斥 | 结构保证（确认 → 执行同一快照） |
| **D04** | 取下一页时切变体：首页被清空、旧响应仍写入 | 数据代数 fetchGeneration（reload/提交各 +1）；响应返回后代数不符整份丢弃；在途标记由全局 Bool 改为**按代数记账**，新首页不再被旧请求的 busy 标记拒绝 | stalePageResponseIsDropped（悬挂请求 + 切变体 → 仍是单页 200 张） |
| **D05** | 筛选链式分页遇错无限重试 | 链式循环检查返回值与页数进展，任一失败/无进展立即终止（保留已加载结果，重试交回用户） | chainFetchStopsOnFailure（失败后尝试数不再增长） |
| **D06** | 全局图库旧筛选响应覆盖新筛选 | 同一套代数校验覆盖筛选提交、相册切换与分页；响应无条件替换前先验代数 | 与 D04 同型（结构性） |
| **D07** | 清空选择没接入普通搜索/筛选路径 | 抽出 clearSelectionForNewQuery()，在 commitSearch()（普通搜索/筛选/变体提交的真实入口）与 reload 都调用 | searchCommitClearsSelection |
| **D10**（部分） | 待办只传目标页，不传要处理的问题 | 新增 InboxAction.reviewXmpConflicts + onReviewXmpConflicts 回调 → RootView 记录「只看 XMP 冲突」意图 → 挑片页 .task 消费（事件语义，消费后清空） | todoActionsCarryIntent |
| **D11** | 文件/编辑菜单在运行态缺失（⌘N/⌘O 无响应） | 不再假设「单一构建方」：ensureStandardMenus() **按缺失项幂等补齐**（主菜单没有「文件」/「编辑」就补一份，动作复用同一批通知/selector），在启动、窗口成为 key、语言切换三处调用；已补项在语言切换前先撤再补 | 结构保证（两种假设下都不重复、不缺失） |
| **D12** | 人物库「在当前工作区复核」实际去关联照片第一项的工作区 | PersonDetailView 接收当前工作区：有该工作区的照片就用它，否则按钮文案改为「在「工作区名」复核人脸」（不再撒谎） | 结构保证（文案与目标同源） |

| **D08** | 「查看照片」只等自然分页：目标在第 200 张之后只打开图库不定位；只带路径的入口不走清筛选分支 | GalleryViewModel.locatePendingPhoto(photoId:photoPath:) 主动向后取页直到命中（上限 50 页/1 万张，避免为一次跳转拉满大图库），失败给出可见反馈；入口任务把「清筛选」判断扩到 path-only，并新增入口筛选意图 | locateTargetBeyondFirstPage / locateTargetByPath / locateMissingTargetReportsFailure / locateStopsWhenPagingFails（4 条） |
| **D09** | 导出「计划」是源文件清单，未描述真正输出；照片数/文件数/字节混为一谈 | ExportService.outputPlan 成为预览与执行的**同一份计划来源**：输出名（含重名改名）、格式、是否附 XMP sidecar、逐项可执行性诊断（EXPORT_SOURCE_MISSING / _UNREADABLE）、体积按 original/转码区分是否为估算；预览新增 photoCount / sidecarCount / physicalFileCount / issueCount，确认文案改用物理文件数，清单改为展示输出名 + sidecar + 问题标记 | previewDescribesOutputsNotSourceList + 跨端键集合契约测试 |
| **D10** | 待办只传目标页（冲突、离线、分析过期三件） | 三个待办各自携带意图：reviewXmpConflicts（只看 XMP 冲突）/ reviewOfflinePhotos（图库新增「离线」筛选枚举 + 入口筛选意图）/ reviewStaleAnalysis（人脸页直达分析步骤）；全部按事件语义消费 | todoActionsCarryIntent / staleAnalysisNavigation / offlinePhotos 动作断言 |

### 0.4 审计后加固（D09 单源化 + 空范围口径 + 回归补齐）

| 项 | 改动 | 理由 |
| --- | --- | --- |
| D09 单源化 | 抽出 ExportService.buildPlan(...)，**预览与执行调用同一份命名/重名/sidecar/诊断实现**；execute 改为消费该计划（此前 execute 内联一套命名循环、preview 另抄一份，两处规则可能漂移）；preview / outputPlan 新增 resumedNames / completedPhotoIds 参数 | 「统一输出计划」必须真的同源，否则只是两份实现看起来一样 |
| 续跑预览一致性 | 新增 AnalysisJobRepo.latestTerminalCheckpoint(dedupeKey:) + JobService.latestTerminalCheckpoint，路由的 export.preview 分支按同一交付指纹取终态 checkpoint，把 destinations/completedPhotoIds 作为续跑基线传给预览 | 断点续跑会复用旧名，预览若按「全新交付」算会显示 _2 后缀，与实际写出不符 |
| 空范围口径 | 导出结果为 0 项时提示「当前范围没有可导出的照片，未写入任何文件」而不是「导出任务已完成」 | 零项交付说「已完成」等于谎报 |
| 回归补齐 | previewMatchesResumedDeliveryNames（续跑预览与执行同名）、allFailedExportDoesNotMarkWorkspaceExported / successfulExportWithDeliveriesMarksWorkspaceExported / legacyExportWithoutDeliverySummaryKeepsOldSemantics（工作区「已导出」按交付摘要） | D02/D09 此前只有结构性保证，缺少直接断言 |

### 0.5 五路审计（正确性/完整性/最优性）与修复

> 触发：用户要求「派出 subagents 检查以上所有修复的正确性、完整性、最优性」。
> 方法：5 路只读并行审计（D01–D03 交付真实性 / D04–D08 图库异步 / D09 输出计划 / D10–D12 入口与宿主 / 跨轮次一致性与测试有效性），各自带快照哈希与 file:line 证据，并区分【已确认】与【疑似】。

#### 审计确认并已修

| 编号 | 问题（审计确认） | 修复 |
| --- | --- | --- |
| **P0** en 占位符错位 | 英文确认弹窗 key 是 %@ %@ %lld，value 却是 %@ %lld %@ → String(format:) 把 Int 当对象指针（潜在崩溃） | 修正 2 处真实错位；新增全表占位符序列契约测试（先吃掉 %% 避免误判） |
| **P2** en 错误文案 | 4 条错误文案只有中文，其中 3 条还把错误码当 key（死条目） | 按中文模板补 4 条英文、删 3 条死条目；新增 englishTableCoversEveryErrorMessage |
| **P1-1** 图库 reload 未递增代数 | ⌘R/刷新与同代在途取页相撞 → 首页被拒 + 假空态，随后旧响应从 p200 写入 | reload 递增 fetchGeneration；phase 兜底改为「无在途请求才收尾」 |
| **P1-2** 事件刷新在代数体系之外 | 与 reload/切变体并发时整份覆盖 pages，也让定位误报未找到 | refreshOnEvent 绑定代数 + 写入前校验 + 可取消；选择集随刷新收敛；成功清 actionError |
| **P1-3** 清筛选提交杀掉定位 | 程序化改回默认值经绑定再提交一次 → 代数 +1 → 定位误报未找到 | commitSearch 先比较有效查询，未变直接 return |
| **P1** 筛选意图空态死路 | 「N 张离线 → 查看」在 reload 后不再链式拉满 → 停在「没有符合条件的照片」 | reload 在筛选态主动 chainFetchIfActive |
| **P1** 推荐去重被打破 | D10 改了待办动作但推荐侧仍旧动作 → 同屏两张同义卡 | 推荐动作复用同一批意图枚举；人脸推荐标题按真实落点生成 |
| **P1** D04 测试是假阴性 | 只断言行数（旧实现同样 200 行） | 追加数据集身份断言：首行必须是 p0、且不含 p200 |
| **P1** 指纹不覆盖命名求值输入/源内容 | 隔天用 {date}/{time} 同预设重导 → 同指纹 → 全部跳过却报成功 | 指纹纳入 sessionName + 未唯一化的解析输出名 + 照片行 checksum/size/mtime；stored 为空也视为不可信；预览基线要求 checkpoint 内指纹一致 |
| **P1** 全失败丢明细 | 抛错后 ExportResult 被丢弃，文案却说「见导出结果」 | 失败明细（截断 10 条）写入 checkpoint；终态事件文案按摘要计数生成，只在结果未落地时兜底改写 |
| **P1**（审计 3） | 共享 sidecar 多计物理文件数；目标 .xmp 内容不同时计划全绿而执行整批失败 | 按目标 sidecar 路径去重计数；目标 sidecar 三态判定，冲突写 EXPORT_XMP_CONFLICT 诊断；续跑跳过项标记 willSkip |
| **P2** 入口与宿主 | 冲突意图与旧筛选求交、分析意图被 seedInitialStep 回滚、图库/相似度不记来源、意图未消费就切走会残留、菜单探针按语言判定会重复注入 | 冲突意图改为「重置 + 只看冲突」；分析意图移到 load 之后；recordOrigin 补 .gallery/.similarity；新增 pruneIntents + 统一成对清理照片待定；菜单探针改语义判定 + 延迟一轮复核 |
| **P2** 其它 | Library 同代乱序回退翻页 + 刷新失败卡 loading、挑片 detached conflicts 无版本守卫、图库 workspace.status 乱序回退、图库索引头不可滚动、analysis_status 被任意 job 类型污染 | 请求序号最新胜出 + 失败回到 loaded；conflicts 加 pageVersion 守卫；status 加请求号；索引头改横向可滚动；analysis_status 只认 similarity/face 分析任务 |

#### 审计确认的后续修复（本批已落地）

| 编号 | 问题 | 修复 | 回归 |
| --- | --- | --- | --- |
| **C-1** | 相似度展开态/显示全部是页面 @State（条件构建即销毁）→「回来保留浏览位置」名不副实 | 两个集合搬进 VM（expandedGroupIds / showAllMemberGroupIds），结果替换时清空 | browseStateSurvivesPageRebuild / resultReplacementClearsBrowseState |
| **C-2** | SessionDraftCache 只增不减（每工作区 4 个 VM） | 加 LRU（最近 8 个工作区），淘汰时整批清理 VM 与意图 | 结构性（编译期 + 代码路径） |
| **B-2** | 相似度改「最小组合/分组范围」后旧分组仍显示为当前结果 | VM 记录 resultParams（阈值/最小组合/分组模式）+ isResultStale，视图给过期横幅 | resultGoesStaleOnGroupingParameterChange |
| **G-4** | 指纹进 dedupeKey 后执行器内的兜底校验是死代码 | 删除不可达分支，改为只兜「键内指纹缺失」（老版本/手工 checkpoint）；键已含指纹因此不会跨交付继承 | 结构性 |
| **P2-12** | buildPlan 逐名 fileExists（1 万张约 5 万次 syscall） | 目标目录**枚举一次**建 Set，uniqueName 与占用判定全部查表（保留实时回退路径） | 既有导出用例（命名/重名/续跑） |
| **D-2** | 预算常量与两处字面量各写一半；覆盖与真实分支有差距 | 抽出 RootShellMetrics 单点定义并让测试引用；人脸审核用例改为如实断言并**注明**它守不住两栏最小值（实测被 576pt 外壳压住） | LayoutBudgetTests |

#### 仍未处理（需要产品口径或真机验收）

- **A10/A11**：离线计数（行级）与列表（资产首选行）粒度不同；冲突计数（outbox 行）与「只看冲突」筛选（首选变体 filepath）粒度不同——需要产品决定「按行还是按资产」，不宜由实现单方面改。
- **F-2**：menuOpenSettings 订阅保留（在「AppKit 菜单可能胜出」的假设下它是唯一发布者）。
- **D-2 剩余**：SettingsView（独立窗口，自身 minWidth 580）与导出页有数据分支仍未纳入预算测试；重复页 tabSelector 的固定宽度未覆盖。
- **原生人工验收**：挑片连续导航/缩放、人脸真实裁剪、默认/最小窗口、深色/英文、键盘焦点与 VoiceOver。

### 仍未处理（下一轮）

- **原生验收**：挑片连续导航与缩放、人脸真实裁剪、默认/最小窗口、深色/英文、键盘焦点与 VoiceOver 仍待人工验收（本轮无法驱动 GUI）。
- **负载敏感测试已缓解**：SimilarityViewModelTests 的档位守卫用例（rapidThresholdChangesAdoptOnlyLatest / thresholdDraftWithoutTierKeepsDraft / thresholdBackToResultCancelsPendingTier）把 10ms 轮询拉到 1 小时——它们断言的是 tierRequestID 守卫而不是轮询刷新，10ms 轮询在并行重负载下会把 stub 默认结果写回来，造成「守卫失效」的假失败。DashboardViewModelTests.loadFailureSetsFailedPhase 属于 AppLanguageLock（进程级语言全局量）类的残余风险，仍建议后续改为不依赖全局语言的形式。
- **测试环境限制**：core 唯一失败用例「波浪号路径会被展开」需要写 home 目录，在构建沙箱下 Operation not permitted（与被测逻辑无关）。

---

## 1. A：布局约束（同类残留）

| 编号 | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| A1 | CullingView.swift:2102 `infoBar` | 不可滚动 HStack，最小宽度 = 子控件 + 长文本之和。同步失败文案 + 重试按钮 + 4~5 位计数**只在实际数据下出现**，现有预算测试喂空桩 → 最坏态零覆盖 | ✅ 已修：整行进横向 ScrollView（Spacer 改固定分隔线） |
| A2 | FaceKeywordingView.swift:1418 HSplitView | 两栏 min **相加**（320+280+分隔线）≈600+；该分支只在 clusters 非空时渲染，测试喂空桩从未测量 | ⏳ 待修 + 待补「有数据」测量 |
| A3 | LibraryView.swift:103 | inspector ideal 320（另两页已收到 260），理想列宽计入最小宽度 | ✅ 已修：220/260 |
| B1 | DuplicatesView.swift:591 `tabSelector` | 固定 `.frame(width: 300)` 在纵向 ScrollView 内 → 窄区被裁 | ⏳ 待修（min 220/max 300） |
| B2 | GalleryView.swift:456 `indexHeaderRow` | 非滚动 HStack：进度条固定 140 + 百分比 36 ≈380，叠加 inspector 260 → 贴边 | ⏳ 待修 |
| B3/B4 | CullingView 冲突行 / SettingsView 固定宽 | 截断/挤压（不崩） | ⏳ 优先级低 |

**实测（父 agent 本轮补齐）**：11 个页面/骨架的最小宽度全部 ≤576pt（预算 680pt）：
挑片 workbench 440 / 空态 365、控制中心·人脸·重复·导出·相似度·页签行 576、全局图库 510、工作区图库 365、人脸库 361。

---

## 2. B：几何/坐标（与 N02 同源）

| 编号 | 位置 | 问题 | 状态 |
| --- | --- | --- | --- |
| C1 | CullingView.swift:3004 | 人脸对齐偏移用**单元格尺寸**而非 fit 后图像显示尺寸，且漏乘 zoom：`(0.5−face)·cell` 应为 `(0.5−face)·displayedFit·max(2,scale)`。竖构图两轴欠平移 1.6–2×，任何缩放级都不居中 | ⏳ 待修（建议抽纯函数 + 矩阵不变量测试） |
| C2 | CullingView.swift:3094 / GalleryView.swift:1011 | `offset = value.translation`：手势 translation 是**从起点累计**，新手势归零 → 平移不累积、松手再拖弹回 | ⏳ 待修（dragStartOffset + translation） |
| S1 | GalleryView.swift:642 | 行宽只扣 padding 未扣竖向滚动条宽 | ⏳ 待验证 |
| S2 | PhotoThumbnailView.swift:213 | 贴边人脸用「与图像求交后」的 box 中心 → 偏离中心（约 8pt）；与注释宣称不完全一致 | ⏳ 待定性（可接受则写清容差） |
| S3 | FaceKwService.swift:1293 | 缺 CullingService 那份「老库像素 bbox → 归一化」兼容换算 | ⏳ 待确认老库数据 |

---

## 3. C：派生状态失效（导出页是唯一修对的范式）

| # | 位置 | 后果 | 状态 |
| --- | --- | --- | --- |
| 7 | DuplicatesViewModel `scanResult` | 改阈值/预设后仍显示旧档位组数（N03 同类） | ⏳ 待修 |
| 3 | GalleryViewModel `selectedIds` | 换筛选后「选中 N 张」含已筛掉照片，批量动作作用于不可见项（Culling 已做 formIntersection） | ⏳ 待修 |
| 1 | FaceKeywordingViewModel 编辑态 | `load()`→`select()` 用服务端值重写未提交的角色名/关键字（bind/移除/合并后都调 load） | ⏳ 待修 |
| 2 | GalleryViewModel `chainFetchIfActive` | 见 `isFetchingNextPage` 直接早退 → 筛选结果只加载部分页 | ⏳ 待修 |
| 4 | GalleryViewModel `thumbnailSize` | 设置变更后回图库仍用旧尺寸，需 ⌘R | ⏳ 待修 |
| 5 | LibraryViewModel `sessions` | 工作区增删后「工作区」下拉不刷新 | ⏳ 待修 |
| 8 | ExportViewModel preview 清单 | 服务端 preview 只回源文件 filename/size → 选 JPEG 时清单仍显示 .NEF | ⏳ 待裁决（服务端语义） |
| 6/9/10/11 | Library rangeText / Similarity stats / 控制中心进度 / 相册模式 | 低 | ⏳ |

---

## 4. D：页面状态与入口意图

**P0（高频路径直接丢用户输入）**：挑片与重复页的 VM **没有**进 SessionDraftCache（第二轮只做了导出与人脸）→ 切一次页签即丢：挑片的筛选/范围/当前照片/多选/逐字段裁决草稿、重复页的扫描结果/阈值/展开/分页。
⏳ 待修（照 export/face 的范式加两个 VM 缓存）

**P1 入口意图缺口**（控制中心的动作落到目标页后，目标页不知道「为什么被打开」）：

| 动作 | 应传意图 | 现状 |
| --- | --- | --- |
| xmp 冲突「逐条裁决」→挑片 | 仅冲突筛选 + 聚焦冲突面板 | 只切页签 |
| 离线照片「查看」→图库 | 预筛选离线 | GalleryFilter 无语义可落 |
| 分析过期「重新分析」→相似度/人脸 | 提示「新增未参与」/直达分析步骤 | 无 |
| 「去导出」 | 保留片 | ✅ 已修（见 §6） |

**P1 其它**：人脸深链角色过滤只保留**已绑定**该角色的簇 → 未绑定簇（正是审核对象）被滤空且空态无解释；人物库「在当前工作区复核人脸」实际取 `photos.first.sessionId` → 可能跳到别的工作区；相似度 `onAppear` 无条件重置展开态。

---

## 5. E：导航目标 / 主动作 / 文案

- **丢目标（6 处）**：人物库「关联照片」网格无点击动作；挑片冲突面板只有 XMP 文件名、照片不可达；重复/相似度成员无「查看照片」；工作台任务行的 工作区名不可点；**返回目标全线写死**（5 个会话页都「返回图库」，从工作台/人脸库深链进来也落图库）。
- **重复动作（7 处）**：相似度在 groups 为空时同屏两个「开始分析」；控制中心失败任务行与待办行各带一个「重试」；挑片同步菜单与失败块各一个「重试失败项」；工作台「进入」vs 右键「打开」；控制中心「打开挑片/打开人脸」与页签重复；图库右键两个同名「取消选择」；全局图库空态唯一按钮在无筛选时禁用（空库死路）。
- **已修**：全局图库工具栏 Picker 标签=首选项（重复「全部工作区」）、硬编码 `"无色标"`、导出目录占位过长与脚注重复。
- **待统一术语**：工作区/当前会话/工作台；色标/颜色标签/标记/颜色；「在 Capture One 中加载元数据」vs「Capture One 重新加载」；人脸样本 vs 名成员。

---

## 6. F：AppKit/SwiftUI 冲突与通知契约（已修 4 项）

| 问题 | 说明 | 状态 |
| --- | --- | --- |
| ⌘Z / ⇧⌘Z 链路断开 | 宿主菜单的 `undo:` 走 NSUndoManager，挑片撤销是自建栈，只认 `gatherMenuUndo/Redo`——这两个通知**全仓零发布者**，tooltip 承诺的快捷键从未生效 | ✅ 快捷键挂到可见按钮 |
| rebuildMenu 抢占菜单 | 语言切换时再 `installMenu()` → 从 SwiftUI 手里抢回 NSApp.mainMenu，菜单在两套定义间跳变 | ✅ 不再重装；改由 App 层语言版本驱动 `.commands` 重建 |
| GATHER_BOOTSTRAPPING 无文案 | 启动早期触发 C1 导入会发这个码，不在文案表 → 用户看到「未知错误」 | ✅ 已补文案 |
| 深链双投递 | `.onOpenURL` 与 `application(_:open:)` 对同一次打开都回调，导入非幂等 → 可能建两个工作区 | ✅ 同 URL 1 秒去重 |
| `menuOpenSettings` 订阅悬空 | 唯一发布者是死菜单项 | ⏳ 待清理 |
| `NSEvent.modifierFlags` 当次事件修饰键 | 图库/挑片在 Button action 里读硬件当前态 → ⌘/⇧ 多选误路由 | ⏳ 待修 |
| `runModal()` 阻塞 | DashboardView/LibraryViewModel 仍用嵌套 runloop（其余已改 begin） | ⏳ 待修 |
| GatherEventCenter wire-once | bootstrap 重试后 progressSink 不再接，进度静默消失 | ⏳ 待修 |

---

## 7. G：测试有效性（含对我自己新增测试的批评）

- `ReviewFixTests.faceCropCentersBoundingBox` 属**B 类（复述实现）**：它抄了居中公式，把 ZStack 改成 `.topLeading` 仍然绿 → 应删除或改为位图质心断言（真实像素用例已是 A 类，应保留并收紧容差）。
- `LayoutBudgetTests` 预算 700 > 真实可用 680（RootView minWidth 860 − 侧栏 180）→ 应改 680；四个会话页用空桩 → 只测到空态分支。
- `invalidBoundingBoxFallsBackToWholeImage`、`margin=0`、`planSignature` 属弱断言；`InboxItemsTests` 等只测纯推导，**动作接线 0 测试**。
- 覆盖缺口与 N01–N10 一一对应（N04 草稿缓存、N05 接线、N06 失焦提交、N07 照片消费、N08 菜单、N09 标签、N10 空态均无测试）。
- 另发现：`CullingView.syncStatusText`(:2566) 是 `SessionControlView.syncStatusText` 的**第二份私有实现**，口径不一致（items 为空先返回「XMP 已同步」、pending+writing 合并）→ 应抽共享函数。

**本轮已修**：新增的全局页面测量测试会留下带轮询的 VM，把并行运行的 SimilarityViewModel / GatherToast 时序断言拖挂 → 改为不 pump（只测加载态骨架）并显式停轮询。

---

## 8. 下一步建议（按用户损失排序）

1. **P0**：挑片 / 重复页 VM 纳入 SessionDraftCache；返回来源栈（记录从哪来、按钮文案随来源）。
2. **P0**：C1 人脸对齐公式（同 N02 家族）+ C2 拖拽累积；两者都要**纯函数 + 不变量测试**。
3. **P1**：C 报告 #1/#3/#7（编辑草稿被 load 覆盖、选择集不收敛、阈值不失效）；D 报告的入口意图四件套。
4. **P1**：E 报告的丢目标 6 处与重复主动作 7 处。
5. **P2**：G 报告的测试改造（预算 680、B 类断言换质心、N03–N10 接线测试）与术语统一。
