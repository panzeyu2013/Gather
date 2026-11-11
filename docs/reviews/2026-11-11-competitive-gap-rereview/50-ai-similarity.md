# AI 初审 / 人脸 / 相似度 / 语义检索 功能复核（2026-11-11，基线 50fea319）

> 复核对象：Wave1–4c 修复后的当前工作树（HEAD `50fea319`，工作树干净）。上轮分册：`docs/reviews/2026-11-10-competitive-gap/50-ai-culling.md`（下称"上轮"）。
> 方法：只读 `grep`/`read`（行号为本工作树实测）+ 竞品官方页 `web_fetch`（2026-11-11 实取）；判"已闭环"必须有 UI 调用点，不接受"service/API 存在"。build/test 未跑（红线）。
> 口径：P0=功能性坏掉/数据不安全/核心链路断；P1=每个工作流撞一次；P2=有更好、没有也能用。成本 S≤2 人日 / M≈1 周 / L>2 周。

## 0. 结论速览

1. **上轮 15 条缺口（P1×10 + P2×5）没有一条真正闭环**：场景写回、标签检索、scene/person facet 三处补了 API+UI，但都停在"能力存在"，没有进入默认路径或主界面（§1）。
2. **自动初审已接线，但主入口/默认路径仍不成立**：`AITriageAutoPipeline` 只挂在菜单/Finder/C1 文件导入的 `afterCreate`；Dashboard「新建工作区」（主 UI 路径）与"加入已有工作区"没有钩子；`triage_enabled`/`triage_auto_generate` 默认全 0；两条 5 分钟轮询上限到点还会**主动取消** quality job（§2 P1-1、§3-A/B）。
3. **人脸分析是 AI 初审的隐式前置（新发现，P1）**：eyes/smile/faceFocus 与 small_face/multi_face 规则读 `face_observations`，该表只由手动 `face.analyze` 写入；没跑人脸分析时"闭眼/微笑/人脸合焦"静默缺失，UI 无任何提示（§3-C）。
4. **分组分析不随初审跑**：三类分组来自 similarity_results / duplicate_groups / navigation_groups，三者都要人手点分析；导入即初审后仍只有"硬技术失败/待复核"，best-of-burst 不生效（§3-D）。
5. **People Filter 差距仍在**：Library 已有 person+scene facet（person 用 exact eq），但**挑片页与 Gallery 没有人物筛选**；Gallery 只能筛"有人脸/无人脸"（§1 #4、§2 P1-6）。
6. **场景标签闭环仍是半成品**：写回/撤销/facet/label 检索都有，但入口在 Beta 建议卡内的二级 sheet；标签是英文 Vision 原串，无中文映射/词表；`sceneGroups` 全仓仍无消费者；无自动关键词（§2 P1-7）。
7. **判定分辨率与"名不副实"未变**：技术质量仍 512px 缩略图、模型信号仍 1280px 预览；`motion_blur` 警告仍=全局梯度<0.12，曝光仍单值；v2 只在 triage 理由码层面做了 eyes_closed/face_out_of_focus 区分（§2 P1-4）。
8. **感知级相似仍未立项**：评估工具/规范/自检已完成（`similarity-eval`），但无标注集、无决策结论；产品仍 64 位 dHash（§2 P1-9）。

## 1. 上轮缺口状态核对

> 覆盖上轮全部 P1；P2 汇总在表末。状态判定只认 UI 调用点；"部分"= 能力有、产品化差一步。行号均在当前工作树。

| 上轮# | 缺口（一句话） | 上轮严重度 | 当前状态 | 当前证据（当前工作树） | 剩余差 |
|---|---|---|---|---|---|
| 1 | 导入后不自动初审 | P1 | **部分** | 管线存在并接线：`GatherHost/AppBootstrap.swift:686-691`（菜单/Finder）、`:717-721`（C1 文件）；设置门 `:967-975`；编排 `GatherApplication/Services/Quality/AITriageAutoPipeline.swift:126-205` | 主入口缺（Dashboard 新建 `DashboardViewModel+Actions.swift:13-29`；加照片 `AppImport.swift:133-181`）；两开关默认 0（`SettingsKey.swift:157/162`）；5 分钟上限+超时取消（`:117-121,166-176`）；无 UI/job 可见性 |
| 2 | 场景/事件标签只采不写、不筛、不分组 | P1 | **部分** | 写回/撤销：`Semantic/SemanticKeywordService.swift:178-271`；UI `SemanticSearch/SemanticSearchSheet.swift:200-239` + `SemanticSearchSheetModel.swift:147-205`；scene facet `FacetQuery.swift:31-41,111-120`；Library 请求 `LibraryViewModel.swift:318` | 全手动且入口在 Beta 建议卡（`CullingTriageCard.swift:328-339`）；英文标签直写；无自动关键词；`SemanticIndex.sceneGroups`（`:498-508`）仍无消费者；事件标签不存在 |
| 3 | 自然语言/中文语义检索不可用 | P1 | **部分** | labels 分支已接 UI：`SemanticSearchSheet.swift:121-135`、`SemanticSearchSheetModel.swift:102-117`；匹配是标签子串 `SemanticIndex.swift:450-491` | 自然语言=ROADMAP 明确不做（`docs/ROADMAP.md:70`）；中文用户仍须猜英文标签，无映射表/词表（代码注释 `:451` 称"UI 负责本地化显示"，UI 实际直出英文） |
| 4 | 无"人物×事件/场景"组合成品筛选 | P1 | **部分** | Library 有 scene/person facet 与精确 person：`Library/LibraryFacetBar.swift:43-63`、`LibraryViewModel.swift:125-139`；桶值 `FacetQuery.swift:189` 起 | Gallery 请求维度不含 scene/person（`GalleryViewModel+Filters.swift:121-123`，`activeCriteria` `:34-60` 也无 case）；挑片页完全无人物/场景筛选；人物库仍是独立页 |
| 5 | 模糊/对焦/曝光只有"一个数" | P1 | **部分** | v2 理由码区分真闭眼/人脸失焦：`Triage/TriageEvaluator.swift:670-693`；但质量警告仍是全局梯度：`QualityService.swift:302-304`、指标 `:68-84` | 曝光仍单值（无高光/暗部溢出、无白平衡）；无"运动模糊 vs 失焦"分型；512px 输入未变 |
| 6 | 判定分辨率 512/1280，微糊漏检 | P1 | **未闭环** | 质量 512：`QualityService.swift:249`；模型 1280：`ModelReview/ModelReviewService.swift:47,257` | 无 RAW/全分辨率判定；无按需 2048 复判 |
| 7 | 最佳帧依据单薄 + 分组易碎 + 无"折叠其余" | P1 | **未闭环** | lead 仍 `qualityScore+rating*0.08-闭眼0.25`：`NavigationService.swift:17,327-334`；burst 仍要求文件名序号 1..3 + 汉明≤14（`:5-11`）；分组只由手动按钮触发 `CullingFilterControls.swift:75-93` | 无场景内排序/折叠 UI；组内 lead 只显示为下拉里的"推荐 N"（`:95-124`）；无构图/全员睁眼信号 |
| 8 | 感知级重复检测缺失（只有 dHash） | P1 | **部分** | 评估物齐：`GatherTriageEval/main.swift:331-336`、`docs/reviews/2026-11-10-competitive-gap/95-similarity-eval-design.md`；产品仍 dHash+汉明 4 | 无标注集/无决策结论（`docs/ROADMAP.md:14,26`）；上线管线（A1）未做 |
| 9 | 闭眼只到"单帧静态"：无眨眼序列/全员睁眼 | P2 | **未闭环** | 眼睛分只取主脸（`ModelReviewService.swift:288-291`）；triage 只用 `eyesOpenScore` 单值（`TriageEvaluator.swift:670-682`） | 无多脸聚合、无组内挑"全员睁眼"、无眨眼序列 |
| 10 | 表情/情绪只有"微笑"一个维度 | P2 | **未闭环** | `ModelReview.swift:143-166` 只有 smileScore；无表情/年龄/活动标签与检索 | 无大笑/皱眉/侧脸/哭闹；无表情检索 |
| 11 | 不学"你会挑哪张"（只学阈值） | P1 | **未闭环** | 仍只有置信度分桶+阈值候选：`Triage/TriageCalibrationService.swift:20-21,143-162`；反馈只进 `triage_feedback` 校准 | 无逐图偏好/风格模型；无"你更爱选哪类"的排序修正 |
| 12 | 相似照片入口只有"单张" | P2 | **部分** | 多选种子：`Semantics.swift:28-56`、`SemanticSearchSheetModel.swift:84-100`；旧入口仍单张 `Gallery/SemanticSearchPanel.swift:86-87` | 只在 Beta 卡内；命中只能逐张点，无结果集/批量/收藏 |
| 13 | 语义索引按 session 建，跨会话语义检索不存在 | P1 | **部分（建议降 P2）** | 向量仍强制 sessionId：`SemanticIndex.swift:292,309,452`；但场景关键词写回后 Library 全局关键词/人物 facet 可跨会话检索（`LibraryViewModel.swift:310-329`） | 跨会话"找相似/自然语言"仍不可用；矢量检索不跨库 |
| 14 | 相似/重复分组"推荐"无判据 | P2 | **未闭环** | 推荐=文件最大+最新：`DuplicatesViewModel.swift:436-450`；徽章 `DuplicatesGroupCardView.swift:94` | 无理由展示，且推荐不看 AI 质量分 |
| 15 | AI 结果不进主检索面 | P2 | **未闭环** | `GalleryViewModel.swift:149-156` 只有 all/hasFace/noFace/offline；无质量/睁眼排序 | 图库/挑片不能按质量分或睁眼筛排 |

### 1.1 三条真实工作流走查（把缺口落回用户动作）

1. **婚礼 5000 张导入 → 等 AI 初审**：菜单/Finder 导入能触发 pipeline，但默认双开关关着 → 直接不跑；用户开两个开关后，Dashboard「新建工作区」又不触发；即便从菜单导，5 分钟上限很可能在 scan/quality 未完成时到达 → 主动取消 quality job、日志之外无提示。**结论：目标素材量下仍会退化为手工点"生成建议"。**
2. **客户要"女儿在仪式上的照片"**：Library 能组合 person（精确）+ scene（关键词子树）+ 年份，但 scene 桶要先手动在挑片 Beta 卡里写回场景标签；挑片页（真正在挑的场景）没有人物/场景筛选，只能回 Library 再回挑片手动对时间。**结论：组合筛选"能做但不在工作区里"。**
3. **"再给我几张和这 3 张类似的"**：挑片页多选 3 张 → 场景标签 sheet → 找相似（0.82 阈值），命中只能逐张点回网格，不能"全选加入选择集/导出"；Gallery 的"查找相似照片…"是单张且阈值 0.6。**结论：入口与结果动作都不完整。**

## 2. 剩余缺口表

> 含上轮未闭环 + 本轮新发现。P0 无（没有数据损坏/主链路断）；下列按"用户可见影响"排序。

| 严重度 | 缺口 | 竞品做法 + 链接 | Gather 证据 | 成本 | 修法一句话 |
|---|---|---|---|---|---|
| P1 | **自动初审端到端仍不成立**：主入口缺、双开关默认关、5 分钟上限到点取消 quality job、无失败/完成可见性 | Aftershoot："Step 2 AI Culls"导入即分析（<https://aftershoot.com/selects/>）；Narrative "AI First Pass"（<https://narrative.so/select>） | `AppBootstrap.swift:644-651,677-694,715-742,967-975`；`AITriageAutoPipeline.swift:117-121,166-176,281-322`；`DashboardViewModel+Actions.swift:13-29`；`AppImport.swift:133-181` | M | pipeline 接全部导入入口；首次导入推荐开启；超时只停止等待不取消 job；控制中心显示"初审：已生成 N 条" |
| P1 | **人脸分析未编排进初审**（新）：闭眼/微笑/人脸合焦/小脸/多脸规则全部依赖 `face_observations`；该表只由手动 face.analyze 写 | Aftershoot 把闭眼/模糊作为通读因子（同上）；Narrative Face Assessments（同上） | `ModelReviewService.swift:57,68,120`（faceBoxes 注入）、`Core.swift:325-337`；`FaceRepo+Observations.swift:171-199`；手动入口 `FaceAnalyzeStep.swift:68`、`FaceKeywordingViewModel+Analysis.swift:25-36`；triage 依赖 `TriageRepo.swift:552-561` | M | pipeline 先跑增量 face.analyze；或模型段没有 face 行时用 Vision 在 1280 预览上补人脸框；缺人脸分析要有可见提示 |
| P1 | **导入即初审不跑分组分析**（新/上轮#7 根因）：无 similarity/duplicate/navigation 组时只能出硬技术失败 | Narrative 场景内按锐度排序、最佳帧浮顶（同上）；Aftershoot 自动分组重复（同上） | 组来源 `TriageRepo.swift:640-721`；三处分析均为手动：`SimilarityView+Analysis.swift:61-62`、`DuplicatesView+Sections.swift:87-89`、`CullingFilterControls.swift:75-93`；pipeline 无这些 enqueue | M | 初审前自动跑 duplicate.scan + navigation.analyze（dHash 便宜）；similarity.analyze 作为可选第二段 |
| P1 | **无场景/连拍"最佳帧"成品视图**：lead 算出来了，但界面不排序不折叠 | Narrative："Every image in a scene ranked by sharpness… best frame surfaces first"（同上） | `NavigationService.swift:327-334`；`CullingFilterControls.swift:95-124`；`CullingGrid.swift` 无组折叠；`TriageEvaluator.swift` 的 group_best 只进建议 | M | 挑片页加"按场景/连拍组折叠 + 组内按 quality 排序"，首帧=lead，一键"保留最佳、淘汰其余"（复用 `decideSimilarityGroup`） |
| P1 | **人物筛选未进挑片页/Gallery**：People Filter 只在 Library 可用 | Aftershoot People Filters 在 Cull/Edit/Retouch 任意页面（同上）；Narrative People Filter（同上） | Library 已有（`LibraryViewModel.swift:310-329`）；Gallery 维度 `GalleryViewModel+Filters.swift:121-123`、filter 枚举 `GalleryViewModel.swift:149-156`；挑片筛选 `CullingFilterState.swift:12-24` 无 person | S/M | Gallery facet 加 person；挑片页筛选加人物选择（复用 `FacetQuery.personBuckets` + person eq 规则） |
| P1 | **场景标签产品化剩余**：全手动、入口深、英文原串、无自动关键词、scene 分组未接 | Excire 自动关键词 + 按 scene 分组 + 内容检索（<https://excire.com/en/excire-foto/>） | 入口 `CullingTriageCard.swift:328-339`（需先 triage_enabled+已生成）；标签英文 `SemanticKeywordService.swift:62-74`；`sceneGroups` 无消费者 `SemanticIndex.swift:498-508` | M | 入口上移到图库/筛选区；加中文标签映射表 + 标签建议；场景标签写回做成可选自动；sceneGroups 接"场景视图"（与"最佳帧"合并交付） |
| P1 | **判定分辨率 512/1280** | Narrative RAW 原件 + Close-Ups（同上）；Excire sharpness/focus peaking（同上） | `QualityService.swift:249`；`ModelReviewService.swift:47,257` | M | 复核队列/1:1 停留时用 2048 预览按需复判脸部与主体，写回并清指纹 |
| P1 | **不学用户挑片偏好** | Aftershoot "Learns Your Eye"/AI Profiles（同上）；Narrative "AI Preset learns from your work"（<https://narrative.so/>） | `TriageCalibrationService.swift:20-21,143-162` 只有阈值；无偏好表/排序修正 | L | 先把"人工改判"记成组内 pair 偏好，用于 group lead 重排（先不训练模型） |
| P1 | **感知级相似未立项/未产品化** | Aftershoot "true duplicates vs creative variations"（同上）；Excire 去重+序列（同上） | `Similarity/Hash.swift:20`；`DuplicateService.swift:94-113,270`；`docs/ROADMAP.md:14,26` | L | 先跑 2–3 人日标注评估定决策 A；通过后复用 `SemanticIndex` Float16 向量 + `VectorIndex` 做 A1 通道 |
| P2 | **Cull to Target 缺失**（新）：不能"按交付张数反推保留" | Aftershoot："Set your target count… builds the selection around that number"（同上） | 全仓无按交付张数配平的入口（grep `targetCount/keepCount` 仅组计数） | M | 用现有 triage 分数做"取前 N + 场景覆盖"配额分配，先在挑片页试点 |
| P2 | **相似检索半成品**（新）：阈值 0.6（协议默认/图库旧面板）/0.82（挑片 sheet）/0.92（索引默认）三套；结果只能逐张点、不能批量/成集 | Excire 检索后生成结果集、按 scene 分组（同上） | `Semantics.swift:47-48`；`SemanticSearchSheetModel.swift:91-94`；`SemanticIndex.swift:270,309`；旧面板 `Gallery/SemanticSearchPanel.swift:86-87` | S | 统一阈值来源 + UI 可调；结果面板加"全选→加入选择集/集合" |
| P2 | **多脸/表情维度缺失**：闭眼只看主脸，无"全员睁眼"聚合；表情只有 smileScore | Narrative Close-Ups 逐脸判读（同上)；Excire 按表情/年龄检索（同上） | `ModelReviewService.swift:288-291`（primary only）；`TriageEvaluator.swift:700-706`；`ModelReview.swift:143-166` | M | 组内加"所有脸 eyes 均开"聚合；Close-Ups 式多脸特写条 |
| P2 | **Narrative Close-Ups 类多脸特写缺失**（新）：只有"人脸对齐"单主脸缩放到 2× | Close-Ups Panel：所有脸逐个放大，无脸时锁关键元素（同上） | `CullingWorkbenchViewer.swift:204-206,628,795,1018-1050`；无多脸面板 | S/M | 查看器加"人脸条"：每张脸一个裁片，按睁眼/合焦着色 |
| P2 | **语义索引不可管理**（新）：无状态/覆盖率、无清空入口；开关藏在"技术质量建议(Beta)"组，采集实际依赖 `triage_model_review=1` | Excire 有索引/清理；Peakto local-first 管理（<https://cyme.io/>） | `SettingsViewModel+Catalog.swift:246-252`；`PhotoSemanticsRepo.swift:84-88,190-195` 无 UI 调用点；采集门控 `WorkflowRegistry.swift:210-213` | S | 控制中心显示"语义索引 N/M 张"；设置加清空；语义开关与模型信号解耦 |
| P2 | **推荐判据缺失**（上轮#14）：重复页"推荐保留"= 文件最大+最新，无理由 | Aftershoot/Excire 给评分理由（同上） | `DuplicatesViewModel.swift:436-450`；徽章 `DuplicatesGroupCardView.swift:94` | S | 推荐改用 qualityScore/eyes 并显示 why popover |
| P2 | **AI 结果不进主检索面**（上轮#15）：图库/挑片不能按质量/睁眼筛选排序 | Excire 按 aesthetics/sharpness 挑片（同上） | `GalleryViewModel.swift:149-156`；`CullingFilterState.swift:12-24` 有质量/verdict 但无 eyes/quality 排序 | M | Gallery facet 加"质量档"；Library 加 AI 质量排序 |
| P2 | **应用建议只能全会话**（新）：`photoIds` 契约支持但 UI 不传，不能"只应用选中" | —（产品粒度问题，无直接竞品对照） | `Triage.swift:145-146`；`CullingViewModel+Triage.swift:113-118` 未传 photoIds | S | 应用弹窗加"全部/仅选中" |
| P2 | **其它竞品能力差**：图中文字检索（Excire 2027 smart text recognition）、按年龄/表情/活动检索（Excire） | <https://excire.com/en/excire-foto/> | 全仓无 OCR 管线；`ModelReview` 只有 smile | L（OCR 用 Vision 可 S） | OCR 用 `VNRecognizeTextRequest` 起一版；表情检索依赖新标签体系，暂缓 |

### 2.1 能力矩阵（本域口径：✓ 具备 / △ 部分 / ✗ 缺）

| 能力 | Gather 当前 | Aftershoot | Narrative | Excire |
|---|---|---|---|---|
| 导入即出建议 | △（有管线但默认关/主入口缺） | ✓ | ✓ | ✓ |
| 闭眼/模糊通读 | △（依赖手动 face.analyze + 512px） | ✓ | ✓ | ✓ |
| 重复/相似分组 | △（dHash，手动分析） | ✓ | ✓ | ✓ |
| 场景内最佳帧排序/折叠 | ✗（lead 只在下拉里） | ✓（Highlights） | ✓（Scenes View） | ✓（Smart selection） |
| People Filter（挑片页内） | ✗（仅 Library facet） | ✓ | ✓ | ✓（人物搜索） |
| 自动关键词 | ✗（手动写回） | ? | ? | ✓ |
| 自然语言/内容检索 | △（英文标签子串） | △（People） | △（People） | ✓（content/scene/mood/text） |
| 学用户偏好 | ✗（只学阈值） | ✓ | ✓ | ? |
| 全本地零云 | ✓ | ✓ | ✓ | ✓ |

## 3. 新发现（上轮未列 / Wave2–3 半成品）

- **A. 5 分钟上限会主动取消 quality job**：`AITriageAutoPipeline` 扫描/质量各 600×0.5s 封顶（`:117-121,281-322`），质量超时即 `cancelQualityJob`（`:166-176`）。5000 张 RAW 的"scan+512/1280 双解码+Vision"大概率超 5 分钟（未实测，按现有两段解码成本推断）→ 导入即初审在目标场景上等于不跑，且日志之外用户无感知。
- **B. 自动初审没有 job 类型也没有 UI 面**：`AnalysisJobType` 只有 metadata/thumbnail/similarity/duplicate/face/quality/output/checksum（`Jobs.swift:9-18`），triage 生成是 actor 内直调（`AppBootstrap.swift:916-948`）；用户看不到"初审中/完成/失败"，失败只进 `GatherLogger`（`:1010-1026`）。
- **C. 无 face.analyze 时"AI 初审"只剩审美/工具图**：`ModelReviewService.evaluate` 逐脸算信号，但 `faces` 来自 DB 注入的 `faceBoxes`（`:120,265-269`）；triage 的 `faceCount/maxFaceAreaRatio` 同样来自 `face_observations`（`TriageRepo.swift:552-561`）。`CullingTriageCard` 的"模型信号"区（`:264-289`）对 nil 字段直接不渲染，**不提示缺人脸分析**。
- **D. 分组分析全是手动**：`similarity.analyze`、`duplicate.scan`、`navigation.analyze` 的 UI 入口分别是"开始分析/开始扫描/保存 Burst/Scene 分组"三个按钮；导入管线只串 `metadata.scan → quality.score`（`WorkflowRegistry.swift:196-291`），AI 初审生成时通常没有任何组可比较。
- **E. 场景标签入口深度 = Beta×生成建议×检查器**：`CullingTriageCard` 的"场景标签…"只出现在 `actions(summary:)`（`:328-339`），即：设置开 Beta → 生成建议成功 → 检查器 → 二级 sheet；Library/Gallery/菜单无任何入口。
- **F. 场景标签是英文原串，且注释与实现不符**：代码注释称"标签是英文原串，UI 负责本地化显示"（`SemanticIndex.swift:450-451`），实际 UI 直接展示 `matchedLabels`（`SemanticSearchSheet.swift:175-180`）与英文示例（`:123`）；写回根是 `AI|场景|<英文>`（`Semantics.swift:17-19`）。中文用户无法检索/阅读。
- **G. 相似阈值三套口径**：协议默认 0.6（`Semantics.swift:47-48`）、挑片 sheet 硬编码 0.82（`SemanticSearchSheetModel.swift:94`）、索引默认 0.92（`SemanticIndex.swift:270`）；图库旧面板走默认 0.6（`Gallery/SemanticSearchPanel.swift:86-87`）→ 同一"找相似"在不同入口结果质量不同且不可调。
- **H. 语义索引"API 有 / UI 无"（隐私/可维护性）**：`PhotoSemanticsRepo.deleteSession/deleteAll`（`:84-88,190-195`）注释写"设置页清空语义索引"，但全仓无 UI/协议调用点。另：语义采集实际受 `triage_model_review` 门控（`WorkflowRegistry.swift:210-213`），关掉模型信号会让"语义索引=开启"悄悄失效。
- **I. 场景分组函数仍是死代码**：`SemanticIndex.sceneGroups`（`:498-508`）只有测试调用；NavigationService 的 scene 组是"同目录+汉明≤24+30 分钟"的几何分组，不是语义场景。
- **J. Gallery 的 facet 维度声明与实际请求不一致**：`FacetBar` 已支持 scene/person 标题与图标（`FacetBar.swift:94-123`），但 Gallery 请求维度只有 camera/lens/iso/year/label/keyword（`GalleryViewModel+Filters.swift:121-123`）→ 同样的 FacetBar 在 Library 显示 scene/person、在 Gallery 不显示。
- **K. Narrative/Aftershoot 四个真实工作流步骤完全不支持**：Cull to Target（按交付张数配平）、Scenes View（场景内按锐度排名+最佳帧浮顶）、Close-Ups（多脸逐脸特写）、自动关键词（导入即写）。均见 §2 链接；Aftershoot 页面同时确认"groups duplicates, flags closed eyes and blur… with your shooting style factored in"。
- **L. 摄取路径（IngestSheet）只接质量不接初审**：`IngestSheet` 的 ingest 走 `WorkflowRegistry` 的 `autoQuality`（`:257-271,302-324`），只把照片接给 quality.score，没有 triage 生成；即"把新一批加进已有工作区"后仍要回挑片页手点生成。
- **M. 交付链可能混入英文 AI 关键词**：场景标签写回明确进 XMP/交付链（`SemanticSearchSheet.swift:70`），但根路径 `AI|场景|beach` 无"交付时忽略 AI 关键词"选项，客户交付的 sidecar 会带英文 AI 词。

- **N. 场景 facet 依赖"先写回"才出现**：scene 桶从 `photo_keywords` 的 `AI|场景` 子树取（`FacetQuery.swift:111-120`），空桶维在 FacetBar 被整体隐藏（`FacetBar.swift:81-82`）。不走 Beta 卡写回，场景维永远不出现——与 Excire"自动关键词后即可搜"差两跳。
- **O. 打开"语义索引"后必须重跑质量分析才建索引，设置文案没写**：采集在两段式 quality.score 的模型段（`ModelReviewService.swift:129-140,225-233`），设置说明只写"开启后质量分析在同一次预览解码上写向量"（`SettingsViewModel+Catalog.swift:251`）。用户开开关→检索仍空→以为功能坏；`SemanticKeywordService` 的 unavailableReason 只兜底提示"先开启并跑一次质量分析"（`:170-172`）。
- **P. 初审可能双跑且无 job 去重**：挑片页在 quality 成功后也会自动生成（`CullingViewModel.swift:575-578`），导入 pipeline 同时在跑（`AppBootstrap.swift:1008-1017`）；TriageService 只有 `serialize` 串行（`TriageService.swift:157-158`），没有 job/批次去重 → 同一会话可能生成两次、两套广播。属 Wave2 半成品的一致性问题。

## 4. 本域最该补的 3 件事

1. **自动初审端到端（P1，成本 M，建议拆三步各 S）**
   理由：判定信号、理由码、三档置信、整批撤销都已存在，唯一卡点是"触发点+默认路径+依赖编排"；不补则前面所有 AI 投入在默认使用中为零。竞品把"导入即出建议"当默认路径（Aftershoot Step 2 / Narrative AI First Pass）。
   最小形态：① pipeline 接全部导入入口（Dashboard/加照片/摄取）+ 控制中心显示 AI 初审进度/结果；② 超时只停止等待不取消 job（或按张数动态放宽）；③ 初审前自动跑增量 face.analyze + duplicate.scan + navigation.analyze（可用开关控制）；④ 首次导入推荐开启 Beta 组合开关。
2. **场景/连拍"最佳帧"视图（P1，成本 M）**
   理由：Gather 已经有 lead 算法与 group_best 理由码，但界面不排序不折叠；Narrative 的核心体验就是"场景内按锐度排序、最佳帧浮顶"，这是把已有数据变成可见产出的最短路径；且为后续 Cull to Target/场景分组提供 UI 骨架。
   最小形态：挑片页"组视图"= 组折叠 + 组内按 quality 排序 + 首帧 lead + 一键"保留最佳淘汰其余"（复用 `decideSimilarityGroup`），同时放宽 burst 成组对"重命名/跨卷"的容忍（文件名序号条件从硬要求改为时间+汉明为主）。
3. **人物×场景筛选 + 场景标签中文化/入口上移（P1，成本 S/M）**
   理由：Library 已经能"人+场景+日期"组合（person exact eq + scene keyword_path），但挑片页/Gallery 没有人物筛选，场景标签入口又深又英文；Aftershoot/Narrative 的 People Filter 在任意页面可用。这是每个婚礼/活动客户沟通场景都会撞一次的摩擦，成本却很低。
   最小形态：Gallery facet 加 person；挑片页筛选加人物选择；"场景标签"入口上移到图库筛选区；加中文标签映射表（Vision 英文标签→中文别名，写入关键词时保留英文原名做可逆映射）。

> 紧随其后（不进 Top3）：感知相似先花 **2–3 人日**跑标注集，把决策 A 从"待决策"变成"立项/不立项"（评估工具已就绪，见 95 号报告）；否则该缺口会一直悬空。Cull to Target 可与"最佳帧"同批做数据层（配额分配），UI 后置。

## 5. 明确不是缺口（边界/取舍，防误报）

- **自然语言/CLIP 文搜**：`docs/ROADMAP.md:70` 明确"不做语义搜索的自然语言 UI（除非 CLIP 候选落地）"；当前 labels 子串检索是该边界的合规替代。补中文**标签映射**不等于做自然语言，属可做范围。
- **云端 AI / 自训审美模型**：产品承诺本地零云（Aftershoot 也承诺 works offline），零模型资产约束下不立项自训美学/构图模型；现有 Vision 系统模型 + 内置 SFace 是既定路线。
- **跨会话自动合并相似组**：95 号评估明确"产品不该有跨会话合并"（误合并毁交付）；跨会话只保留"结构化检索"（Library 全局 facet），不做自动合并。
- **语义索引默认关闭**：大会话的磁盘/Vision 开销是真实成本，默认关是合理取舍；缺的是**可见性/引导/清理**（§3-H），不是默认值本身。
- **人脸模型可替换 + 本地 SFace**：已达标（`Resources/FaceModels/manifest.json`、37MB 随包、无云调用），不再列为缺口。
- **视频/地图/移动端、Windows、完整 DAM/目录迁移**：`docs/ROADMAP.md:67-73` 七不做，不在本域。
- **[待核实] 项**：Lightroom Sensei 关键词/文本检索、Apple Photos Memories 的人脸/场景成片、imagen 的挑片因子细目——本机 `web_search` 401、厂商页 JS/Cloudflare 拦截，按纪律不写版本细节。

## 6. 上轮分册事实校正（本轮重新核实）

1. 上轮"语义检索 UI 只有图搜图"已过时：labels 分支已接 UI（但入口深，见 §3-E），且多选种子已实现。
2. 上轮"scene facet 应用层有 / 协议与 UI 无"已过时：Library 已请求 scene/person 两维；但 Gallery 仍未请求（§3-J），挑片页无（§1 #4）。
3. 上轮"导入即初审完全缺失"已过时：pipeline 已存在并接线，但默认/入口/依赖/超时四项未闭环（§1 #1）。
4. 上轮"建议写回整批撤销"确认仍成立且有 UI（`CullingInspector.swift:246-281`）；三档置信+why popover+20 理由码仍成立（`CullingTriageCard.swift:152-236`、`Triage.swift:16-40`）。
5. 上轮"全部判定跑 512/1280"确认仍成立；v2 理由码新增 eyes_closed/face_out_of_focus 属"命名分型"，不改变输入分辨率。

## 7. 未验证 / 残余风险

- 未跑 build/test，纯静态核对；§3-A 的"5000 张超 5 分钟"是按现有 512/1280 双解码与 Vision 两段成本的推断（未实测），但常数上限（600×0.5s）与超时取消行为是代码事实。
- "face_observations 唯一写入路径"基于 grep：仅 `FaceKwService`/`face.analyze` 管线写该表；若后续新增外部写入，§3-C 的依赖结论需复核。
- 竞品因子细目（Aftershoot "30+ factors"、Excire Smart selection 的具体排序）未取证，只作能力方向，不当版本事实。
- 建议真机按 `96-manual-acceptance.md` 增补一条"导入即初审时延/是否被取消"，并补一条"未跑人脸分析时的建议质量"对照。
- Lightroom/Apple Photos/imagen 的 AI 细节仍 [待核实]（见 §5）。

## 附 证据索引（本次实际 grep/read 的文件）

- 协议：`GatherProtocol/Protocol/{Triage,Semantics,ModelReview,Quality}.swift`；`API/Inputs/FacetInputs.swift`；`Settings/SettingsKey.swift`；`Protocol/Jobs.swift`
- 应用层：`GatherApplication/Services/Quality/AITriageAutoPipeline.swift`；`Semantic/{SemanticIndex,SemanticKeywordService}.swift`；`ModelReview/ModelReviewService.swift`；`QualityService.swift`；`Triage/{TriageEvaluator,TriageService,TriageCalibrationService}.swift`；`NavigationService.swift`；`Workflows/WorkflowRegistry.swift`；`DuplicateService.swift`；`GatherAnalysis/Similarity/Hash.swift`
- 持久化：`Queries/{FacetQuery,PhotoFilterQuery}.swift`；`Repositories/{TriageRepo,FaceRepo+Observations,PhotoSemanticsRepo}.swift`
- UI：`GatherUI/Culling/{CullingTriageCard,CullingInspector,CullingFilterControls,CullingFilterState,CullingViewModel+Triage,CullingViewModel+Navigation,CullingWorkbenchViewer,CullingGrid,IngestSheet}.swift`；`GatherUI/SemanticSearch/{SemanticSearchSheet,SemanticSearchSheetModel,SemanticKeywordBatchStore}.swift`；`GatherUI/Gallery/{GalleryInspector,SemanticSearchPanel,GalleryViewModel+Filters,GalleryViewModel}.swift`；`GatherUI/Filtering/FacetBar.swift`；`GatherUI/Library/{LibraryFacetBar,LibraryViewModel}.swift`；`GatherUI/Settings/SettingsViewModel+Catalog.swift`；`GatherUI/FaceKeywording/{FaceAnalyzeStep,FaceKeywordingViewModel+Analysis}.swift`；`GatherUI/Duplicates/{DuplicatesViewModel,DuplicatesView+Sections,DuplicatesGroupCardView}.swift`；`GatherUI/Similarity/SimilarityView+Analysis.swift`
- 宿主/组合：`GatherHost/{AppBootstrap,AppImport,Composition/Core,Composition/Runtime,APIs/LivePhotoAPI}.swift`；`GatherUI/Dashboard/{DashboardViewModel+Actions,NewSessionSheet}.swift`
- 工具/文档：`GatherTriageEval/main.swift`；`docs/ROADMAP.md`；`docs/reviews/2026-11-10-competitive-gap/{50-ai-culling,95-similarity-eval-design,90-wave-ledger,96-manual-acceptance,97-post-implementation-review}.md`
- 竞品（2026-11-11 `web_fetch` 实取）：aftershoot.com/selects/、narrative.so/select、excire.com/en/excire-foto/；aftershoot.com、narrative.so、cyme.io 复用上轮实取。
