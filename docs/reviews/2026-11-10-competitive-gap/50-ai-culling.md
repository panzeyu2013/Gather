# AI 挑片 / 人脸 / 相似 / 检索 —— 竞品缺口评审

- 日期：2026-11-10；评审对象：Gather（本地优先、面向 Capture One 的挑片/目录协作工具，macOS 原生）
- 域范围：AI/模型辅助的**判定**（闭眼/表情/对焦/曝光/最佳帧）、**分组与去重**（相似、视觉重复、场景）、**检索**（语义/标签/人物/组合筛选）、**AI 建议的可解释/可撤销/可校准/学习偏好**、**判定所用的像素分辨率与模型资产**
- 不在范围：看图速度、全屏 1:1、对比视图（见同批 `20-culling-browse.md`）、写盘可靠性、代码质量、性能 profiling
- 方法：只读 `grep`/`read` 取代码证据（路径:行号均为当前工作树实测）；竞品只用厂商官方页 `web_fetch` 取证。抓取限制：本机 `web_search` 端点 401（host 配置问题，非仓库问题），imagen / Apple / Adobe 产品页为 JS 渲染或被 Cloudflare 挡回，相关条目标 **[待核实]**

---

## 0. 结论速览

1. **Gather 的 AI 域不是"没有"，而是"半条链路"**：判定信号（眼睛几何/微笑/人脸合焦/审美/工具图/技术质量）与建议契约（`TriageSuggestion` + 理由码 + 置信度 + apply/undo）都在，**但触发靠人手点、语义索引默认关、场景标签采而不写不筛、自然语言检索被产品显式排除**。
2. 与 Aftershoot / Narrative Select 相比，最大差距不在"判得准"，而在**"导入完成即出建议"的默认路径**：Gather 的自动初审只挂在挑片页 ViewModel 且需两个设置开关，关掉挑片页就不生成（`CullingViewModel.swift:541`）。
3. 与 Excire 相比，最大差距在**"标签能不能用来找照片"**：Gather 已经用 Vision 采到 top-8 标签并落库 `photo_semantics`（`SemanticIndex.swift:627-678`），但没有标签→关键词写回、没有场景 facet、没有按场景/事件过滤；场景分组函数 `sceneGroups` **应用层有 / 协议与 UI 无**（`SemanticIndex.swift:398-451`，全仓无消费者）。
4. **"半实现会被用户当成坏实现"的两处**：`motion_blur` 警告实际只是"全局梯度锐度 < 0.12"（`QualityService.swift:302`），`exposure` 实际只是"灰度均值离 128 多远"（`:82`）——没有运动模糊/失焦/高光溢出/欠曝/白平衡的区分；而全部判定跑在 512px 缩略图与 1280px 预览上（`QualityService.swift:249`、`ModelReviewService.swift:46-47`）。
5. 与 Aftershoot"N+1 次点击越用越准"相比，Gather 只学到**三个全局置信度阈值**（`TriageCalibrationService.swift:1-16`），不学"你在同组里会挑哪张"——这是本域两个需要新模型/新管线的缺口之一（另一个是感知级去重，见 §3 #8）。

---

## 1. Gather 该域已实现能力（清单 + 代码证据）

### 1.1 人脸检测 + 身份嵌入 + 聚类（本地模型资产）
- 人脸域协议 15 个方法（clusters/bind/merge/removeMember/analyze/recluster/cancel/unbind/preview/writeback/confirmSync/cleanup/modelsStatus/split/review）：`desktop/native/gather-core/Sources/GatherProtocol/API/FaceAPI.swift:19-37`。
- 内置 **SFace** 身份模型（112×112 对齐输入、128 维、CoreML MLProgram、约 37MB）：`desktop/native/gather-core/Sources/GatherAnalysis/Resources/FaceModels/manifest.json`（`dimension: 128`）与同目录 `SFace.mlpackage`（`du -sh` = 37M）。**模型随包分发、零云依赖**，与 Aftershoot"文件不离开本机"（`https://aftershoot.com/`）同一档本地化承诺。
- 人脸质量连续分（capture 0.4 + size 0.4 + roll 0.2，显式对标 PhotoPrism/Immich 硬门槛）：`desktop/native/gather-core/Sources/GatherAnalysis/Face/FaceQuality.swift:1-16`（文件头写明对标来源）。
- 聚类/向量索引在 `GatherAnalysis/Face/{Clusterer,VectorIndex,Matcher}.swift`；人物库 8 个方法（含 `searchPhotos`）：`GatherProtocol/API/PersonAPI.swift:18-30`。

### 1.2 模型级初审信号（眼睛睁开 / 微笑 / 人脸合焦 / 审美 / 工具图）
- 契约：`FaceReviewSignal`（每条人脸 `captureQuality/eyeOpenScore/smileScore/focusScore/isPrimary`）与 `ModelReviewResult`（照片级 `eyesOpenScore/smileScore/faceFocusScore/aestheticScore/isUtilityImage` + 稳定警告码）：`GatherProtocol/Protocol/ModelReview.swift:14-53`、`:55-108`（警告码枚举在 `:67-69`）。
- 眼睛：Vision 眼部轮廓 6 点算 **EAR**（上下眼睑距离/眼宽），按脸框长宽比换算后线性映射 0…1，闭眼阈值 `closedEAR=0.10`、睁眼 `openEAR=0.28`：`ModelReview.swift:115-141`（注释 `:112-114` 明确"几何单调分、不是概率、只做相对比较"）。
- 微笑：outerLips 归一化 → 嘴宽/脸宽主信号（权重 0.75）+ 张口 0.25：`ModelReview.swift:143-166`。
- 运行条件：**一次 1280px 预览解码**同时做人脸关键点、人脸框合焦、审美；只用系统 Vision/CoreGraphics，不引入第二份模型资产：`GatherApplication/Services/ModelReview/ModelReviewService.swift:2-13`、`:46-50`（`previewMaxDimension=1280`、`minimumFocusFacePx=96`）。
- 触发：作为 `quality.score` job 的第二段执行（第一段技术质量成功后，按 `triage_model_review` 开关跑模型段；模型段失败不拖垮技术质量）：`GatherApplication/Services/Workflows/WorkflowRegistry.swift:196-229`。
- UI 呈现：检查器"模型信号"chips（眼睛睁开/主体闭眼/半闭、人脸合焦 %.2f、面带微笑、截图或文档、审美 %.2f）：`desktop/native/gather-app/Sources/GatherUI/Culling/CullingTriageCard.swift:246-272`。

### 1.3 技术质量（锐度 / 曝光 / 主体锐度 / 闭合眼风险启发式）
- 指标是**灰度网格上的平均梯度 + 平均亮度**：`GatherApplication/Services/QualityService.swift:68-84`（`sharpness = Σ|Δx|+|Δy| / ((w-1)(h-1)·510)`，`exposure = 1 - |mean-128|/128`）。
- 输入是 **512px 缩略图**（`imageProvider(photo.filepath, 512)`）：`QualityService.swift:249`；默认实现走 `RAWDecoder.getThumbnail`：`:175-180`。
- 主体锐度 = 人脸框区域同函数重算（`QualityService.swift:252-296`）；闭眼风险 = `1 - 眼部区域锐度/(主体锐度·1.15)`（"眼部梯度塌陷"代理）：`:296`。
- 警告码只三种：`motion_blur`（锐度<0.12）、`exposure_issue`（曝光<0.3）、`closed_eye_risk_heuristic`（风险>0.72）：`QualityService.swift:302-304`。
- **合焦叠加层（focus peaking）已有，但不参与判定**：预览像素 → 3×3 局部方差 → 归一化合焦图 → 阈值二值掩膜（默认 `threshold 0.55`、覆盖层最长边 320），查看器以叠加层渲染：`GatherAnalysis/Preview/PreviewAnalysis.swift:84-186`、契约 `GatherProtocol/Protocol/Curation.swift:445-490`、UI `GatherUI/Culling/CullingWorkbenchViewer.swift:67-72`、`:472`。局限：它只给人看，`QualityService` 不引用 `FocusMap`，理由码也不引用它。
- 汇总分：`0.6·焦点分 + 0.15·全图锐度 + 0.2·曝光 + 0.05·(1-闭眼风险)`：`QualityService.swift:313-319`。
- 契约字段含 `subjectSharpness/faceQuality/closedEyeRisk/closedEyeProbability/relativeRank`：`GatherProtocol/Protocol/Quality.swift:26-44`。

### 1.4 相似 / 重复 / 连拍分组
- **dHash 64 位**（9×8 灰度逐行比较）是唯一的感知指纹：`GatherAnalysis/Similarity/Hash.swift:1-12`（文件头：从 TS 逐位移植）、`:20`（`bitCount = 64`）。
- 视觉重复 = 256px 缩略图 → dHash → 汉明距离聚类，默认阈值 **4**（`visualThreshold ?? 4`）：`GatherApplication/Services/DuplicateService.swift:94-113`（`computeVisualHashes` 里 `thumbnailProvider(photo.filepath, 256)`）、`:270`。精确重复走独立通道（文件级），两通道在 `DuplicateService` 内合并成组，决策有 `resolve/resolveMember/resetGroup` 与 `Confirmed` 门控：`GatherProtocol/API/DuplicateAPI.swift:20-25`。
- 相似度分析（同 dHash 域、阈值档 T±4/T±8 预计算）+ 聚类 + 写回 XMP 十件套：`GatherProtocol/API/SimilarityAPI.swift:21-30`。
- **连拍（burst）与场景（scene）组**由 `NavigationService` 生成：同机、文件名序号差 1..3（无数字视为连续）、汉明 ≤14、时间差 ≤ burstGap（默认 2s）；scene 组需同目录 + 汉明 ≤24：`GatherApplication/Services/NavigationService.swift:5-11`（行为契约注释）。
- 组内 lead（"最佳帧"）= `qualityScore + rating·0.08 - 闭眼惩罚 0.25` 降序：`NavigationService.swift:17`、`:327-334`。

### 1.5 技术质量建议（Triage，Beta）：判定不是孤立分数，而是"建议 + 理由 + 置信度"
- 结论只有 keep/reject/review 三种，理由码 20 个（含 `group_best / weaker_than_group_best / motion_blur / exposure_low / closed_eye_suspected / eyes_closed / face_out_of_focus / utility_image / duplicate_exact / duplicate_visual / multi_face_low_confidence / small_face / manual_override`）：`GatherProtocol/Protocol/Triage.swift:16-40`。
- 判定顺序（设计文档 §3.2）：P0 人工排除 → P1 未分析 → P2 无替代 → P3 精确重复 → P4 硬技术失败 → P5 组内最佳 → P6 明显较弱 → P7 并列 → P8 兜底 → P9 review；组源优先级 exact > similarity > visual duplicate > burst/scene：`GatherApplication/Services/Triage/TriageEvaluator.swift:1-9`、组优先级 `:164-172`。
- "组内平手"时按**采集质量 → 微笑**决胜（v2 才启用）：`TriageEvaluator.swift:247-257`、`:700`；工具图（截图/文档）排除在组内比较外，避免它凭超高锐度占住 best 误杀整组：`:212`、`:695-696`。
- 精确重复组"最佳"= 像素数 → 文件字节 → 导入序：`:221-244`；且 best 必须在"已分析"成员里选（防"分辨率最高但无质量行"占位）：`:231-234`。
- 应用/撤销：`applyTriage(Confirmed<TriageApplyInput>)` 只写 culling 决策、不写 XMP，返回 `applied*/skippedManual/skippedConflict/historyOperationId`：`Triage.swift:137-195`；UI 应用前有确认 sheet 并写明"不会写入 XMP，可在挑片页撤销"：`CullingTriageCard.swift:345-385`。

### 1.6 可解释 / 可校准（这块是对 Aftershoot 的"黑盒建议"少数占优处）
- "为什么"popover：裸置信度 + "置信度来自规则打分，不是概率" + 全部理由码 + 该置信区间的历史精确率（样本≥5 才显示）：`CullingTriageCard.swift:189-226`。
- 置信度三档（高/中/低），阈值由校准模型给出：`CullingTriageCard.swift:134-186`。
- 阈值校准：只取**人工决定**（AI 自动应用不算用户同意）→ 按置信度 10 桶算 keep 精确率 → 给"保精确率 90/95/98% → 阈值 X"候选 → 用户点"应用"才写三个设置键：`GatherApplication/Services/Triage/TriageCalibrationService.swift:1-16`；样本查询与 `triage_feedback` 表：`GatherPersistence/Database/Repositories/TriageFeedbackRepo.swift:1-2`、`Schema/SchemaCurrent+DDLWorkbench.swift:125-138`；UI 校准面板 `CullingTriageCard.swift:387-427`。
- 建议写回 XMP 后的**整批撤销**：`CullingViewModel+Triage.swift:196-232`（`undoTriageWriteback`，回读失败也保留撤销入口 `:202-204`）。

### 1.7 语义索引与检索（本域最关键、也最容易被误读的一块）
- 能力面（文件头自述）：`VNGenerateImageFeaturePrintRequest`（~2048 维）+ `VNClassifyImageRequest` top-N 标签；Float16 压缩存储 `photo_semantics`；图搜图 = 余弦 top-N；**文搜 = 标签文本匹配，不做 CLIP 文本编码**：`GatherApplication/Services/Semantic/SemanticIndex.swift:1-10`、`ImageSemanticsExtractor` `:627-678`（`maxLabels=8` `:631`、标签置信度下限 0.05 `:633`）。
- 标签匹配实现是"查询词被某个标签包含（大小写不敏感）+ Jaccard 排序"，且 hit 的 `similarity` 显式为 nil（"不用 Jaccard 冒充相似度"）：`SemanticIndex.swift:348-392`。
- 图搜图默认余弦下限 0.92、场景分组 0.92/标签 Jaccard 0.5、单次最多比较 2 万行/512 行一块：`SemanticIndex.swift:267-281`、流式实现 `:528-562`。
- 采集时机：跟随 `model.review` 的 1280 解码"顺手"采，默认关闭（`semantic_index_enabled=0`）；开启后只补缺失行：`ModelReviewService.swift:10-13`、`GatherProtocol/Settings/SettingsKey.swift:94`、`:182`；设置项文案与开关：`GatherUI/Settings/SettingsViewModel+Catalog.swift:246-252`。
- 协议入口：`PhotoAPI.semanticSearch(_:)`：`GatherProtocol/API/PhotoAPI.swift:69-70`；未接线替身返回 `unavailableReason="语义索引未接线"`（`:98-104`）。
- **UI 只有"图搜图"一条入口**：检查器按钮"查找相似照片…" → `SemanticSearchPanel` → `semanticSearch(SemanticSearchQuery(sessionId:photoId:))`，从不传 `labels`：`GatherUI/Gallery/GalleryInspector.swift:138`、`:158-169`；`GatherUI/Gallery/SemanticSearchPanel.swift:84-95`。即 **标签检索 API 有 / UI 无**。
- 场景分组函数 `sceneGroups`（标签 Jaccard ≥0.5 或余弦 ≥0.92，贪心并组，返回组内共享前 3 标签做 explanation）存在：`SemanticIndex.swift:396-451`；但**全仓无生产消费者**（`grep -rn SemanticSceneGroup` 只命中该文件与测试），因此 **应用层有 / 协议与 UI 无**。

### 1.8 检索面（"找照片"实际能做什么）
- 图库/收藏夹筛选支持的字段：simple（filename/filepath/checksum/status/created_at）、metadata（date_taken/camera_make/camera_model/lens_model/focal_length/f_number/exposure_time/iso/rating/gps/width/height/file_size/label）、JSON 投影（title/description/headline/creator/copyright/city/state/country/country_code/location/person_in_image），以及特殊字段 `has_face`、`person`、`keywords`、`keyword_path`、`directory`、`volume`、`has_duplicates`：`GatherPersistence/Database/Queries/PhotoFilterQuery.swift:61-90`（字段清单）、`:456-514`（特殊字段 switch）。
- `person` 条件 = `EXISTS(person_photos JOIN persons WHERE per.name = ?)`（eq/contains/neq/any/in 均支持）：`:459`、`:759-790`。
- 自由文本搜索是**多字段 LIKE 的 OR 子组**（filename/title/description/headline/creator/copyright…），不是语义检索：`GatherUI/Library/LibraryViewModel.swift:60-110`（含 `person` 文本字段 `:108-110`）。
- facet 维度只有 `camera/lens/iso/year/label/keyword`（**无 person、无 scene、无 AI 质量维**）：`GatherProtocol/API/Inputs/FacetInputs.swift:10-13`。
- 排序：`filter.photos` 的 sortBy 只能落 simple/metadata 列（无 qualityScore、无 eyesOpen、无 similarity）：`PhotoFilterQuery.swift:815-818`；分页接口 `PhotoPageQuery.sortBy` 的白名单只有 `rowid`：`GatherProtocol/API/Inputs/PhotoInputs.swift:30`。
- 挑片页内部有"按建议 verdict 筛选"与"质量状态筛选"：`GatherUI/Culling/CullingFilterState.swift:12-24`、`GatherPersistence/Database/Queries/CullingAssetPageQuery.swift:55-59`。

### 1.9 建议/判定实际跑在什么像素上（"分辨率账"）

| 判定 | 输入 | 证据 |
|---|---|---|
| 技术质量（锐度/曝光/主体锐度/闭眼风险） | **512px 缩略图**灰度 | `QualityService.swift:249`、`:175-180` |
| 眼睛/微笑/人脸合焦/审美/工具图 | **1280px 预览**（人脸短边 <96px 不做合焦） | `ModelReviewService.swift:46-50` |
| 语义标签 / FeaturePrint | 同一次 1280px 预览解码 | `ModelReviewService.swift:10-13`、`SemanticIndex.swift:627-678` |
| dHash 视觉指纹 | **256px 缩略图** → 9×8 灰度 | `DuplicateService.swift:94-113` |
| 全分辨率 / RAW 原生数据判定 | **无**（`RAWDecoder` 只出缩略图与预览，见 `GatherAnalysis/Image/RAWDecoder.swift:111-117`） | 同左 |

> 结论：Gather 的任何 AI 判定都**没有**在 RAW 全分辨率上做过；"轻微失焦/微糊"这类只有 1:1 才能看出的问题，判定链路从结构上就看不到。

---

## 2. 竞品基线（按产品分节）

> 取证说明：只用厂商官方页；`web_search` 在本机 401（host 配置），imagen/Apple/Adobe 页面为 JS 渲染或被 Cloudflare 挡回 → 标 [待核实]。

### 2.1 Aftershoot（culling + edit + retouch + galleries 一体）
- 官网定位："You shoot. Aftershoot handles the rest. Cull, edit, retouch, and deliver — one complete platform"；**"Works Offline — No Internet needed and your files never leave your machine"**；含 Face Detection、AI Profiles"learns your style"：`https://aftershoot.com/`。
- 挑片页原文：**"works through your entire album, picks out the keepers, groups duplicates, and flags blurry photos using 30+ factors"**；"**groups duplicates, flags closed eyes and blur, and surfaces your strongest images ranked by quality, with your shooting style factored in**"；页标题 "AI Photo Culling Software that **Learns Your Eye**"：`https://aftershoot.com/selects/`。
- **People Filters**：输入名字即可在 Cull / Edit / Retouch 任意页面定位同一个人（"Just search a name and find them wherever you're working"）：同页。
- 对 Gather 的意义：把"闭眼 + 模糊 + 重复"三件事**合成一次全自动通读**，且默认路径是"导入即通读"——这正是 Gather 缺的那一段（见缺口 #1/#5/#9）。

### 2.2 Narrative Select（AI 辅助挑片 + AI 预设编辑）
- **Face Assessments**：按人脸给"对焦/睁眼闭眼"判定；**Close-Ups Panel** 放大每张脸上所有人脸（没脸时锁定关键元素）；**Scenes View**："Every image in a scene ranked by sharpness… **The best frame surfaces first**"；**People Filter**；"Import thousands of RAWs in seconds"：`https://narrative.so/select`。
- 学习偏好："The AI Preset **learns from your work and improves over time**"：`https://narrative.so/`。
- 对 Gather 的意义：Narrative 把"最佳帧"做成**场景内按锐度排序 + 首帧即最佳**的产品动作；Gather 有 burst 组和组内 lead，但没把它显式变成"这是这组的最佳帧，其余折叠"的默认界面行为（组内 lead 只用于判定与导航）。

### 2.3 Excire Foto / Excire Search（本地 AI 检索与自动关键词，最接近 Gather 的语义缺口）
- "Retrieve photos in seconds — Search for **content, faces, scenes, text, and moods** — without manual tagging"；"**automatic keywording**"；"Check **sharpness at a glance with intelligent detection and focus peaking**"；"Group photos automatically by **people, scene, sequence, content, or capture date**"；"identify best shots by analyzing **aesthetics, sharpness, and facial expressions**"；**"Everything runs locally, your photos stay on your computer"**、一次性买断；Lightroom Classic 插件版同样本地：`https://excire.com/en/excire-foto/`、`https://excire.com/en/`。
- 对 Gather 的意义：**能力矩阵上 Gather 已具备 60%（Vision 标签、人脸、锐度、场景/连拍分组、审美分），缺的是"把它们接成可检索"**——Excire 的卖点正是"标签即检索面"。

### 2.4 Lightroom / Lightroom Classic（Sensei 人脸 + AI 增强）
- 已核实（同批报告取证）：Loupe/Grid/Compare/Survey、Assisted Culling、堆栈、**View focus points**、XMP sidecar：`https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html`、`https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-focus-points-in-photos.html`。
- **People 视图人脸聚类、Sensei 关键词/文本搜索、AI Denoise、Select Subject/Sky 蒙版：本机无法取得可读官方页（产品页 JS 渲染、帮助页 404），全部标 [待核实]**。请勿把版本细节当既成事实引用：`https://www.adobe.com/products/photoshop-lightroom/features.html`。
- 对 Gather 的意义（仅就"功能面"）：Lightroom 的 AI 是"判定辅助 + 后期增强"，**不是"替你挑片"**；Gather 与它的差距主要在 AI 后期与关键词自动生成，不在挑片骨架。

### 2.5 Photo Mechanic Plus（Catalog 检索 + 极速 ingest）
- 官方定位：极速 ingest + 边拷边筛 + 元数据（caption/keyword/copyright）快速录入："Ingest, cull, rate, and organize for a quicker, more efficient workflow"：`https://home.camerabits.com/`。
- **Catalog 与跨 catalog 检索的具体形态**（Plus 的 Catalog 面板、复合检索语法）：产品页为 JS 渲染，未能取证 → **[待核实]**（`https://home.camerabits.com/products/photo-mechanic-plus/`）。
- 对 Gather 的意义：PM Plus 的"检索"是**结构化元数据检索**，没有 AI 语义；Gather 的 trait 与之重叠（rating/label/keyword/IPTC/person 字段），因此 Gather 的差异化只能来自 AI 侧——这抬高了 #3/#4 的优先级。

### 2.6 Peakto（CYME，local-first 聚合目录）
- "a **lightweight, local-first alternative to DAMs**"；"AI-Powered Tools to Manage Your Photos and Videos… help creators **find, tag and organize**"；有 Specio（野生动物物种识别打标）、Avalanche（跨应用目录迁移）、**Lightroom / Capture One 搜索插件**（跨 session/catalog 找同一批照片）：`https://cyme.io/`。
- 对 Gather 的意义：Peakto 把"C1 会话 + LR 目录 + 其他来源"聚合成一个可搜索索引；Gather 的会话模型天然更窄（本会话），跨会话/跨工作区检索只有 `filter.photos_global` 与只读跨工作区重复（`PhotoAPI.swift:29-33`），语义索引本身是**按 sessionId 建**（`SemanticIndex.swift:292`），跨会话语义检索不存在 → 缺口 #13。

### 2.7 Apple Photos（Memories）与 imagen
- 两者均**未能取得可读官方页**（Apple 产品页重定向、imagen 被 Cloudflare 403）。按纪律不下结论，相关对比内容标 **[待核实]**：`https://www.apple.com/iphone/photos/`、`https://imagen-ai.com/`。
- 已知需核实的点（供下轮补）：Memories 是否按人脸/场景/事件自动成片；imagen 的 culling 是否含"闭眼/重复/最佳帧"与本地处理承诺。

### 2.8 能力矩阵（本域口径：✓ 具备 / △ 部分 / ✗ 缺 / ?[待核实]）

| 能力 | Gather | Aftershoot | Narrative Select | Excire | Lightroom | PM Plus | Peakto |
|---|---|---|---|---|---|---|---|
| 自动通读（导入即出建议） | ✗（需手点 + 设置开关） | ✓ | ✓（AI First Pass） | ✓（Smart selection） | △（Assisted Culling 仅导入时） | ✗ | △ |
| 闭眼判定 | ✓（单帧几何） | ✓ | ✓ | ✓（表情/人脸） | ? | ✗ | ? |
| 微笑/表情 | △（只有 smileScore） | ? | ✓（Face Assessments 语境外） | ✓（expressions/emotions） | ? | ✗ | ? |
| 模糊/失焦判定 | △（判定只有全局/脸框梯度；peaking 叠加层有但不参与打分） | ✓（flags blur） | ✓（focus assessments） | ✓（sharpness + focus peaking） | ✓（对焦点查看） | ✗（人工 1:1） | ? |
| 曝光/白平衡自动判定 | △（仅均值亮度，无白平衡/溢出） | ✓（30+ 因子，[待核实] 细目） | ? | ✓（aesthetics+sharpness） | ✓（直方图 clipping） | ✗ | ? |
| 连拍最佳帧 | △（有 lead 算法，U 无"折叠其余"） | ✓（Highlights/最强帧） | ✓（场景内按锐度排序） | ✓（sequence 分组 + 智能挑选） | △（堆栈+人工） | ✗ | ? |
| 重复/相似判定 | △（dHash 64 位） | ✓（真重复 vs 创作变体） | ✓（Scenes 分组） | ✓（去重 + 序列） | △（堆栈/视觉相似 [待核实]） | ✗ | ✓（跨 catalog 重复 [待核实]） |
| 场景/事件自动标签 | △（采集有，写回/筛选无） | ? | △（Scenes 分组） | ✓（场景/情绪/文字，自动关键词） | ? | ✗ | ✓（AI 打标） |
| 自然语言/语义检索 | ✗（标签文本匹配 + 无 UI） | ✓（People/名字检索） | ✓（People Filter） | ✓（content/scene/mood/text） | ✓（Sensei [待核实]） | ✗（结构化元数据） | ✓ |
| 人物 × 事件组合筛选 | △（person 文本 + 日期，无 facet） | ✓（People Filter 全页面可用） | ✓ | ✓（人物+场景+表情） | ? | ✗ | △ |
| 建议可解释 | ✓（理由码 + why popover + 历史精确率） | △（打分/分组，黑盒） | △（face/eye 徽标） | ✓（分项评分） | ? | n/a | ? |
| 建议可撤销 | ✓（整批 undo + 历史栈） | ? | ? | ? | ✓（部分） | n/a | ? |
| 学用户偏好（不只阈值） | ✗（只学 3 个阈值） | ✓（AI Profiles，学你的挑片/风格） | ✓（AI Preset 越用越准） | ? | ? | ✗ | ? |
| 全本地 / 零云 | ✓（Vision + 内置 SFace） | ✓（Works Offline） | ✓（本地） | ✓（本地） | ✓（本地） | ✓ | ✓（local-first） |
| 判定分辨率 | 512 / 1280 预览 | ?（可能 RAW 原件，[待核实]） | ✓（RAW 原件 + 人脸近景） | ? | ✓（1:1 可用） | n/a（人工） | n/a |

---

## 3. 功能缺口表

> 严重度：**P0** = 不补就用不起来 / 必须换工具；**P1** = 日常明显摩擦；**P2** = 锦上添花。成本：**S** ≤2 人日 / **M** 1 周级 / **L** 2–4 周 / **XL** >1 月。

| # | 缺口 | 竞品怎么做（产品+链接） | Gather 现状（代码/文档证据） | 用户影响场景 | 严重度 | 补齐成本 |
|---|---|---|---|---|---|---|
| 1 | **导入后不自动初审**：AI 判定要人手点，且"自动生成"只活在挑片页 | Aftershoot：导入即通读、30+ 因子出建议（<https://aftershoot.com/selects/>）；Narrative：Import 后 AI First Pass（<https://narrative.so/select>） | `WorkflowRegistry.swift:196-229` 只把模型段挂在 `quality.score` job 内；`IngestService.swift` 全文件无 quality/triage/model 调用（grep 0 命中）；自动生成只在挑片页 VM：`CullingViewModel.swift:541`；开关 `triage_auto_generate` 默认 0（`SettingsViewModel+Catalog.swift:215-223`） | 婚礼 5000 张导入后，用户必须记得去控制中心点"分析质量"、再进挑片页"生成建议"，中途关页面就不生成 | P1 | S |
| 2 | **场景/事件标签只采不写、不筛、不分组** | Excire：自动关键词 + content/scene/mood 检索 + 按 scene 分组（<https://excire.com/en/excire-foto/>）；Peakto：AI 打标后可搜（<https://cyme.io/>） | 采集与落库有：`SemanticIndex.swift:627-678`（Vision top-8）；场景分组函数有：`:396-451`，但**全仓无消费者**（应用层有 / 协议与 UI 无）；标签不写回关键词（`Metadata/`、`Keyword/` 无 `photo_semantics` 引用）；facet 无 scene 维（`FacetInputs.swift:10-13`） | 客户要"接亲/仪式/敬酒"各挑 20 张——Gather 里只能人工打关键词或用目录/时间猜 | P1 | M |
| 3 | **自然语言 / 中文语义检索不可用**（现实是标签英文词匹配，且无 UI） | Excire：按内容/场景/情绪/文字搜索（同上）；Lightroom Sensei 文本检索 [待核实] | 协议支持 `labels` 但 UI 只传 `photoId`：`SemanticSearchPanel.swift:84-95`、`GalleryInspector.swift:138`；标签匹配是英文子串包含：`SemanticIndex.swift:348-392`；显式"不做 CLIP 文本编码"：`:8`、`:350-352`；ROADMAP 明列不做："不做语义搜索的自然语言 UI（除非 CLIP 候选落地）"：`docs/ROADMAP.md:70` | 用户想"找海边逆光的婚纱照"、"找有蛋糕的照片"——Gather 给不出结果，只能靠文件名/关键词 | P1 | L（需新模型资产） |
| 4 | **没有"人物 × 事件/场景"组合的成品筛选入口** | Aftershoot People Filters 在任意页面按名字找人（<https://aftershoot.com/selects/>）；Narrative People Filter（<https://narrative.so/select>） | 底层有：`person` 过滤条件（`PhotoFilterQuery.swift:459,759-790`）、人物库 `searchPhotos`（`PersonAPI.swift:18-30`）；但 facet 无 person 维（`FacetInputs.swift:10-13`）、高级规则编辑器字段只有 IPTC `person_in_image`（`FilterRuleEditor.swift:34`）、图库只有自由文本"人物"框（`LibraryView+Filters.swift:176-178`）；人物库与图库/挑片页是两套页面 | 客户说"再多给几张我女儿在仪式上的"——得先进人物库找照片，再回挑片页手动对时间，无法在一个网格里"人 + 当天 + 场景"筛 | P1 | S |
| 5 | **模糊/对焦/曝光只有"一个数"，不可解释也不分型** | Aftershoot 明确"flags blur / closed eyes"（<https://aftershoot.com/selects/>）；Excire 有 sharpness 检测 + focus peaking（<https://excire.com/en/excire-foto/>）；Narrative focus assessments（<https://narrative.so/select>） | `motion_blur` 实为"全局梯度 <0.12"（`QualityService.swift:302` + `:68-84`），无法区分运动模糊/失焦/景深太浅；`exposure` = 灰度均值偏离 128（`:82`），不区分高光溢出/欠曝/白平衡偏色；无白平衡判定（白平衡只在 EXIF 元数据）；合焦叠加层有（`PreviewAnalysis.swift:84-186`）但只是给人看的 peaking，不产出理由（全仓 grep `peaking` 0 命中） | 暗光婚礼连拍里"糊了"与"暗了"给出同一类警告，用户仍要回 C1 用 1:1 逐张确认，AI 建议不可信 | P1 | M |
| 6 | **判定分辨率上限 512/1280，微糊漏检**（"缩略图判定"） | Narrative 以 RAW 原件 + 人脸近景面板支撑 eye/focus assessment（<https://narrative.so/select>）；Aftershoot 宣称文件不出本机（原件处理，细目 [待核实]，<https://aftershoot.com/>） | 技术质量 512 缩略图（`QualityService.swift:249`）；模型信号 1280 预览（`ModelReviewService.swift:46-47`）；RAW 全分辨率判定不存在（`RAWDecoder.swift:111-117` 只出缩略图/预览） | 大光圈人像"眼睫毛糊了"在 512px 上看不出来；AI 判"合格"，客户交付前才发现 | P1 | M |
| 7 | **最佳帧（best-of-burst）依据单薄 + 分组易碎** | Narrative："场景内每张按锐度排序，最佳帧浮到第一"（<https://narrative.so/select>）；Aftershoot 按质量排序并"结合你的拍摄风格"（<https://aftershoot.com/selects/>） | lead 排序只有 `qualityScore + rating*0.08 - 闭眼*0.25`（`NavigationService.swift:17,327-334`）；组内平手按"采集质量→微笑"（`TriageEvaluator.swift:253-257`）；burst 成组要求**文件名序号连续 1..3 + 汉明≤14 + 同机 + 2s 内**（`NavigationService.swift:5-11`） | C1 重命名过的序列、跨卡分卷的连拍会被拆成多个"单张"组，最佳帧机制静默失效；且排序不看构图，用户仍要人工比 | P1 | M |
| 8 | **感知级重复检测缺失**（只有 64 位 dHash） | Aftershoot："separating **true duplicates from creative variations**"（<https://aftershoot.com/selects/>）；Excire 去重 + 序列分组（<https://excire.com/en/excire-foto/>） | dHash 64 位 + 汉明默认 4（`Similarity/Hash.swift:19`、`DuplicateService.swift:94-113,270`）；同场景不同焦距/裁切/调色版不视为重复；ROADMAP 自认"找相似只能找到连拍"（`docs/ROADMAP.md:14`），embedding 方案因缺标注数据未立项（`:26`） | 同一构图拍了 40 张（其中 3 张出了一点构图差异）——Gather 只合并视觉近重复，"同场景不同裁切"仍要人工过 | P1 | L |
| 9 | **闭眼只到"单帧静态"**：没有眨眼序列、没有"全员睁眼"聚合 | Aftershoot 把 closed eyes 作为通读因子（同上）；Narrative 按人脸给 eye assessment（同上）；Excire 按 expressions 检索（<https://excire.com/en/excire-foto/>） | 眼睛分 = `min(左,右)` EAR（`ModelReview.swift:60-61,115-141`），人脸 <96px 直接不给分（`ModelReviewService.swift:50`）；组内只惩罚 lead 排序，不做"这组里第 3 张所有人睁眼" | 合影 8 人：1 人闭眼就整张 review，但 Gather 不会告诉你"下一张全员睁眼"；婚礼合影仍要逐张放大看 | P2 | M |
| 10 | **表情/情绪只有"微笑"一个维度** | Excire：按表情/情绪/活动检索（laughter/hugs 等，<https://excire.com/en/excire-foto/>）；Narrative Face Assessments 覆盖人脸近景判读（<https://narrative.so/select>） | 只有 `smileScore`（嘴宽几何，`ModelReview.swift:143-166`），无大笑/皱眉/侧脸/哭闹；无 age/expression 检索 | 客户要"笑开的那几张"、"抓拍情绪片"——只能人工翻 | P2 | L |
| 11 | **不学"你会挑哪张"**（只学阈值） | Aftershoot "Learns Your Eye"/AI Profiles（<https://aftershoot.com/selects/>、<https://aftershoot.com/>）；Narrative "AI Preset learns from your work"（<https://narrative.so/>） | 反馈表只取人工决定、只用来算 10 桶精确率与 3 个阈值：`TriageCalibrationService.swift:1-16`、`TriageFeedbackRepo.swift:1-2`；无逐图偏好模型、无"你更爱选 +0.3EV/更宽那张" | 用了半年，建议仍是全局一刀切；摄影师要的风格化取舍（构图/表情/光线偏好）学不到 | P1 | L |
| 12 | **相似照片入口只有"单张"**，无法从选择集/人物出发生成"相似结果集" | Excire 支持人脸/场景检索生成结果集（同上）；Peakto 跨目录搜（<https://cyme.io/>） | `semanticSearch` 的 `photoId` 单张入口（`SemanticSearchPanel.swift:84-95`）；无"用选中 N 张的平均向量搜"、无"按人搜相似" | 客户发了 3 张参考图，想找"类似这 3 张的"——只能一张一张搜、手动合并结果 | P2 | S |
| 13 | **语义索引按 session 建，跨会话/跨工作区语义检索不存在** | Peakto 聚合多目录可搜索（<https://cyme.io/>）；Excire Foto 单一库内全库检索（<https://excire.com/en/excire-foto/>） | `SemanticIndex.vectors/search(sessionId:)` 全按 session（`SemanticIndex.swift:292,352`）；`semanticSearch` 入参强制 sessionId（`Semantics.swift:9-32`）；另有两个隐患：索引默认关（`SettingsKey.swift:182`）、只能靠 `quality.score` 触发采集（无独立"建索引"入口，`WorkflowRegistry.swift:196-229`） | 同一个客户三次拍摄分三个会话，问"上次那张海边照"——语义检索只覆盖当前会话 | P1 | M |
| 14 | **相似/重复分组的"推荐"没有判据说明**（同批审计已列 P2） | Aftershoot 给出评分与分组理由（同上）；Excire 分项评分（同上） | 挑片建议有理由码与 why popover（`CullingTriageCard.swift:189-226`），但相似度/重复页的"推荐"徽章无判据：审计 `docs/reviews/2026-10-30-interaction-audit/D-similarity-duplicates-face-persons.md:203-208`（P2-11） | 用户不信"推荐保留这张"，仍全人工复核，AI 省时效果打折 | P2 | S |
| 15 | **AI 结果不进主检索面**：不能"按质量分排序/筛掉低质量/只看睁眼" | Excire 可按 aesthetics/sharpness 评估挑片（<https://excire.com/en/excire-foto/>）；Lightroom 可按星级/旗标筛 [待核实] | 图库筛选字段无质量维（`PhotoFilterQuery.swift:61-90`）；sortBy 只能落 simple/metadata（`:815-818`）；只有挑片页内部可按"质量状态/建议 verdict"过滤（`CullingFilterState.swift:12-24`、`CullingAssetPageQuery.swift:55-59`） | 在图库/收藏夹里想说"按 AI 质量从高到低看一眼"——做不到，只能回挑片页 | P2 | M |

---

## 4. 该域"最该补的 3 件事"

### ① 把"Ai 初审"接进导入流水线（P1，成本 S）
- **理由**：判定能力已经齐（技术质量 + 模型信号 + triage 规则 + 可解释 + undo），唯一障碍是**触发点错位**——自动生成活在挑片页 ViewModel（`CullingViewModel.swift:541`），离开页面即失效；`IngestService.swift` 完全不碰分析。竞品把这件事当默认路径（Aftershoot 导入即通读、Narrative AI First Pass），这是"AI 挑片"能否成立的开关。
- **最小可行形态**：在 `WorkflowRegistry` 增加 `analysis.pipeline` job（ingest 收尾入队）：先跑 `quality.score`（含模型段）→ 再跑 `triage.generate`；沿用现有 JobService 的持久化/取消/进度，设置键复用 `triage_auto_generate`（默认仍 0，文案改为"导入后自动初审"）。控制中心"分析与索引"卡加一个"为当前会话跑 AI 初审"按钮（现在只有"分析质量"）。**不要**新增协议方法（`TriageGenerateInput` 已够）。

### ② 让"场景/事件标签"成为可检索面（标签→关键词写回 + scene facet + 相似入口扩到选择集）（P1，成本 M）
- **理由**：Vision 采集与 `photo_semantics` 存储已存在（`SemanticIndex.swift:627-678`），但结果是"死数据"：不写回关键词、不进 facet、不进过滤、场景分组函数无消费者（`:396-451`）。Excire 的全部卖点就是"这些标签能被搜到"；Gather 是"采了但用户永远看不到"。
- **最小可行形态**（三小步，都可独立交付）：
  1. **写回**：`photo_semantics.labels_json` → 层级关键词（如 `AI/场景/beach`），走已有 `MetadataKeywordWriter` + `Confirmed` 批量预览/撤销（复用 `CullingViewModel+Triage` 的 undo 模式），默认关闭；
  2. **facet**：`PhotoFacetInput.allowedDimensions` 加 `scene`、`person`（服务端按`photo_semantics`/`person_photos` COUNT），图库 facet 条即出现"场景/人物"两维；
  3. **入口**：`SemanticSearchPanel` 支持多选种子（取平均向量）与"从当前筛选结果找相似"，替代单张 `photoId`。
- **明确不做**：CLIP/中文文搜（ROADMAP §七已排除，且需新模型资产）——先用"标签关键字 + 中文映射表"把可用性做出来。

### ③ 判定可信度分级：把"一个数"变成"分型证据 + 低可信进复核"（P1，成本 M）
- **理由**：当前 `motion_blur` / `exposure_issue` 的命名与算法不符（`QualityService.swift:302` vs `:68-84`），且所有判定只看 512/1280 预览（`QualityService.swift:249`、`ModelReviewService.swift:46-47`）。用户一旦发现"AI 说糊但其实不糊"，就会整体不信任建议——比"少判一张"更伤。
- **最小可行形态**：
  1. **分型**：把单一 `sharpness` 拆成 `globalGradient / faceRegionGradient / edgeDensity`，理由码改名 `soft_focus_suspected`（不再冒充 motion_blur）；曝光拆成 `meanLuma / highlightClip / shadowClip`（直方图已有，只需 8bit 上算比例）；把不成立的判断降级为 `review` 而不是 `reject`；
  2. **按需复判**：复核队列里的照片（或用户在 1:1 停留 >1s 的那张）用 `RAWDecoder` 取 2048 长边预览，对脸部 bbox 重算一次梯度，结果写回并清指纹（复用 `inputFingerprint` 失效机制，`QualityService` 已具备）；
  3. **UI 说清口径**：模型信号 chips 已标"不是概率"（`CullingTriageCard.swift:194-198`），继续沿用同一诚实口径，把"分辨率：1280 预览"写进 why popover。

---

## 附 A：必查问题逐项回填（自查表）

| # | 必查问题 | 结论 | 证据 |
|---|---|---|---|
| 1 | 闭眼/眨眼检测 | **有**（EAR 几何，单帧、取 min(左,右)）；**无**眨眼序列 / 全员睁眼聚合 / 眨眼前后选帧 | `ModelReview.swift:115-141`；`TriageReasonCode.eyesClosed` `Triage.swift:23` |
| 2 | 表情/笑容检测 | **部分**（只有 smileScore，嘴宽几何）；无大笑/皱眉/侧脸/哭 | `ModelReview.swift:143-166`；UI `CullingTriageCard.swift:260-262` |
| 3 | 对焦/运动模糊自动判定 + 可解释理由 | **判定弱**：一个全局梯度阈值；理由码名不副实；peaking 叠加层存在但不参与判定 | `QualityService.swift:68-84,302`；理由码 `Triage.swift:19`；peaking `PreviewAnalysis.swift:84-186` |
| 4 | 曝光自动判定 | **弱**：灰度均值偏离 128；无高光/暗部溢出、无分区曝光 | `QualityService.swift:82` |
| 5 | 白平衡自动判定 | **无**（全仓无白平衡判定计算；`whiteBalance` 只是 EXIF 元数据字符串） | `GatherProtocol/Protocol/Metadata.swift:129`（仅字段）；判定侧 grep 0 命中 |
| 6 | 连拍最佳帧（best-of-burst） | **有骨架**：burst 组 + lead 打分 + triage 组内最佳 + `group_best` 理由；**弱在**排序信号（无构图/全员睁眼/风格）与成组条件（文件名序号） | `NavigationService.swift:5-11,17,327-334`；`TriageEvaluator.swift:164-172,247-257` |
| 7 | 主体/场景/事件自动标签 | **采集有、产品化无**：Vision top-8 落库但无写回/无 facet/无筛选/无 UI 展示；scene 分组函数无消费者 | `SemanticIndex.swift:627-678,396-451`；`FacetInputs.swift:10-13` |
| 8 | 自然语言检索 | **无**（标签英文子串匹配；`labels` 检索 API 有 / UI 无；ROADMAP 显式不做） | `SemanticIndex.swift:348-392,8`；`SemanticSearchPanel.swift:84-95`；`ROADMAP.md:70` |
| 9 | 按人物+事件组合筛选 | **底层有 / 成品无**：person 过滤 + 日期 + 关键词可组合（SQL 层），但无 person/scene facet、无图库人物选择器、人物库是独立页面 | `PhotoFilterQuery.swift:459,759-790`；`FilterRuleEditor.swift:34`；`LibraryView+Filters.swift:176-178` |
| 10 | AI 建议可解释与可撤销 | **有（本域最强项）**：理由码 + 三档置信 + why popover（含历史精确率）+ 整批 undo + 校准面板 | `CullingTriageCard.swift:134-226,387-427`；`CullingViewModel+Triage.swift:196-232` |
| 11 | 模型本地化与体积 | **已达标**：Vision 系统模型零体积 + 内置 SFace 37MB（128 维）；无云调用 | `Resources/FaceModels/manifest.json`；`SFace.mlpackage`；`ModelReviewService.swift:5-8` |
| 12 | 跨会话学习用户偏好 | **只学阈值**：3 个置信度设置键 + 分桶/分机型精确率；不学逐图偏好；语义索引不跨会话 | `TriageCalibrationService.swift:1-16`；`TriageCalibration.swift:1-5`；`SemanticIndex.swift:292,352` |
| 13 | 重复检测是否感知级（非 dHash） | **不是**：64 位 dHash（256px）+ 汉明阈值 4；embedding 方案未立项 | `Similarity/Hash.swift:20`；`DuplicateService.swift:94-113,270`；`ROADMAP.md:14,26` |
| 14 | RAW 全分辨率还是缩略图判定 | **缩略图/预览**：质量 512、模型 1280、dHash 256；无全分辨率判定路径 | 见 §1.9 表；`RAWDecoder.swift:111-117` |

## 附 B：证据索引（本次实际 grep/read 过的文件）

- 协议：`GatherProtocol/Protocol/{Semantics,ModelReview,Quality,Triage,TriageCalibration,Filter}.swift`；`GatherProtocol/API/{PhotoAPI,FaceAPI,PersonAPI,CullingAPI,SimilarityAPI,DuplicateAPI,QualityAPI}.swift`；`GatherProtocol/API/Inputs/{FacetInputs,PhotoInputs}.swift`；`GatherProtocol/Settings/SettingsKey.swift`
- 应用层：`GatherApplication/Services/{Semantic/SemanticIndex,ModelReview/ModelReviewService,QualityService,Triage/TriageEvaluator,NavigationService,DuplicateService,SimilarityService,Workflows/WorkflowRegistry}.swift`；`Triage/TriageCalibrationService.swift`
- 分析层：`GatherAnalysis/Similarity/Hash.swift`；`GatherAnalysis/Face/{FaceQuality,Clusterer,VectorIndex}.swift`；`GatherAnalysis/Resources/FaceModels/*`；`GatherAnalysis/Image/RAWDecoder.swift`
- 持久化：`GatherPersistence/Database/Queries/{PhotoFilterQuery,CullingAssetPageQuery}.swift`；`Database/Repositories/TriageFeedbackRepo.swift`；`Database/Schema/SchemaCurrent+DDLWorkbench.swift`
- UI：`GatherUI/Culling/{CullingTriageCard,CullingViewModel,CullingViewModel+Triage,CullingFilterState,CullingGrid}.swift`；`GatherUI/Gallery/{GalleryInspector,SemanticSearchPanel}.swift`；`GatherUI/Filtering/FilterRuleEditor.swift`；`GatherUI/Library/{LibraryViewModel,LibraryView+Filters}.swift`；`GatherUI/Persons/PersonsViewModel.swift`；`GatherUI/Settings/SettingsViewModel+Catalog.swift`
- 宿主/组合：`GatherHost/Composition/{Core,FeatureAPIs}.swift`；`GatherHost/APIs/LivePhotoAPI.swift`；`GatherHost/SessionWorkspaceFactory.swift`；`GatherHost/Composition/Runtime.swift`
- 文档：`docs/ROADMAP.md`（§一 #5、§二 决策 A、§七 不做清单）；`docs/design/p1-next/plan-2026-10-30.md`（§1.10、§3.11.1–3.11.5）；`docs/reviews/2026-10-30-interaction-audit/D-similarity-duplicates-face-persons.md`（P2-11）
- 竞品（本机 web_fetch 实取）：aftershoot.com、aftershoot.com/selects/、narrative.so、narrative.so/select、excire.com/en/、excire.com/en/excire-foto/、cyme.io、home.camerabits.com

## 附 C：本轮未验证 / 风险
- Lightroom（People/Sensei/Denoise/Select Subject）、Apple Photos Memories、imagen 的 AI 细节均 **[待核实]**：本机 `web_search` 401，厂商页 JS 渲染或 Cloudflare 403，按纪律不脑补。
- Aftershoot/Excire 的"30+ 因子""全 RAW 原件判定"等营销表述，只作能力方向参考，具体算法与分辨率 **[待核实]**。
- 代码行号会随提交漂移：本文件所有 `路径:行号` 取自当前工作树（`grep -n` 实测），复用前请复核。
