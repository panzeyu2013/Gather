# 摄取 / 导出 / 组织 / 交付：竞品功能缺口评审

- 域：Ingest（摄取）· Export / Output（导出与成套交付）· Organize（集合/堆栈/智能相册/目录）· Deliver（发布、客户审片、打印、目录备份与迁移）
- 日期：2026-11-10
- 仓库基线：/Users/panzeyu2013/Desktop/code/develop/Gather（Swift 6.2 / SwiftUI，gather-core + gather-app）
- 证据口径：Gather 结论一律落到代码行号（相对仓库根，形如 `desktop/native/.../Export.swift:81`）。协议/服务存在但界面未接线，写「API 有 / UI 无」；服务内部支持但协议未暴露，写「实现有 / 协议无」。
- 竞品口径：本次会话 `web_search` 不可用（返回 401，属宿主配置问题），改用 `web_fetch` 直接抓官方文档与权威教程；抓不到的站点（Capture One 帮助中心 Cloudflare 403、Pixieset 403、SmugMug 502、Adobe 正文为 JS 渲染）只保留官方链接并标 **[待核实]**，不还原版本细节。
- 本次只评「功能残缺」：真实交付工作流里缺哪一步、必须退出 Gather 去用 C1/Lightroom/Bridge/PM/交付平台才能完成。不评代码质量、不做性能剖析。

## 1. Gather 该域已实现能力（清单 + 代码证据）

### 1.1 摄取（存储卡 / 目录 → 工作区）

- **入口与参数**：摄取是「复制/重命名/校验 → 登记」的一步，输入 6 个字段（含 `sessionId`）：`sourcePaths`、`destinationRoot`、`renameTemplate`、`secondDestinationRoot`、`verifyChecksum`（`desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SessionIngestInputs.swift:9-35`）。
- **重命名 token 体系**：`{yyyy} {MM} {dd} {HH} {mm} {ss} {orig} {ext} {seq[:N]} {camera}`，未知 token 原样保留；模板里可以写 `/` 从而生成日期子目录（`.../GatherApplication/Services/Ingest/IngestService.swift:20-62`；界面提示同集 `desktop/native/gather-app/Sources/GatherUI/Culling/IngestSheet.swift:76`）。
- **模板只在界面状态里**：默认模板硬编码在 `@State`，关闭 sheet 即丢（`IngestSheet.swift:20`），没有「导入预设」概念。
- **去重与跳过**：按会话内已有照片的 SHA-256 命中跳过（先按 size 预筛）（`.../Ingest/SessionIngestRunner.swift:84-92` → `IngestService.swift:329-335`）；目标同名且内容一致 → 记 `alreadyPresent` 并照样登记（`IngestService.swift:377-388`）；同名异内容 → `conflict`，整组（同 stem 兄弟）都不落地（`IngestService.swift:400-411`）。
- **校验和**：主副本走 `.gather-part` 临时文件 → 复制/移动 → 校验 → rename（`IngestService.swift:620-666`）。
- **第二目的地**：按相对主目的地的路径镜像复制，且必须与主目的地、会话根都不重叠（`SessionIngestRunner.swift:63-82`、`IngestService.swift:486-520`）；崩溃恢复场景还会为 `alreadyPresent` 的主副本补拷第二份，补拷失败会进 `failed` 而不是静默成功（`IngestService.swift:573-610`）。
- **可观测与可取消**：进度从 job 500ms 轮询而来（`IngestSheet.swift:248-262`）；取消按 session 找活跃 ingest job（`IngestSheet.swift:217-246`）。
- **限制**：目标必须在会话 sourcePath 之内（`SessionIngestRunner.swift:59-62`），因此默认落点是 `<source>/_ingest`（`IngestSheet.swift:159-162`）。
- **实现有 / 协议无**：`IngestOptions.moveInsteadOfCopy` 支持「移动而非复制」（`IngestService.swift:130`），但 `SessionIngestInput` 没有该字段、UI 没有开关 —— 卡内文件只能复制，不能导入即移走。
- **无导入前预览**：`SessionAPI` 只有 `ingest`，没有 plan/preview 方法（`.../GatherProtocol/API/SessionAPI.swift:37-38`），界面上按「开始摄取」才知道会复制多少、跳过多少、冲突多少。
- **失败呈现**：结果只渲染 `result.failed.first`（`IngestSheet.swift:125-131`），DTO 里的 `code`/`retryable` 没有「只重试这些」入口。

### 1.2 导出（单次）与成套交付（配方）

- **导出选项字段**：`scope`（selected/filtered/session）、`variantPolicy`（preferred/raw/jpeg/all）、`format`（original/jpeg/tiff）、`quality`、`maxDimension`、`tiffCompression`、`watermark`、`naming`、`includeXmp`、`destination`（`.../GatherProtocol/Protocol/Export.swift:81-119`）。**没有**色彩空间/ICC、DPI/PPI、输出锐化、每配方子目录规则字段。
- **水印**：协议有 `text`/`image` 两种类型与三种位置（`Export.swift:37-48`），实现里 `image` 直接抛 `watermarkTypeUnsupported`（`.../Services/Export/ExportService+Plan.swift:299`），UI 只有文字水印四行（`desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Options.swift:88-125`）—— **协议有 / 实现拒 / UI 无**。
- **命名 token**：`{date} {time} {counter} {original} {filename} {session}`（`ExportService+Plan.swift:483-493`；UI placeholder 见 `ExportView+Options.swift:67-77`）。命名结果只当**文件名**用：重名唯一化在单一目录的快照上做（`ExportService+Plan.swift:49-73`），执行时只创建顶层目标目录（`.../Services/Export/ExportService+Run.swift:123`）—— 没有「按客户/日期/事件分目录」的规则。
- **编码参数**：JPEG 只写 `kCGImageDestinationLossyCompressionQuality`，TIFF 只写压缩方式（`ExportService+Run.swift:263-278`）；不写 DPI，也不做色彩空间转换/ICC 选择。
- **导出预检与报告**：`ExportPreview` 同时给「照片数 / XMP 数 / 物理文件数 / 源问题数」，供确认文案使用（`Export.swift:185-219`）；结果可导出 CSV / Markdown 报告（`.../Services/Export/ExportService+Report.swift`；UI `ExportView+Result.swift:35-51`）。
- **导出计划**：预览与执行共用 `buildPlan`，能区分「将写出」与「续跑跳过」（`willSkip`）（`.../Protocol/Export.swift:126-182`）。
- **配方（OutputRecipe）**：一套导出参数 + 产物清单（photos/contactSheet/gallery/manifest），持久化到 settings 键 `output.recipes`（`.../GatherProtocol/Protocol/Output.swift:43-81`；`desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Delivery.swift:4, 143`）。
- **配方参数不可编辑**：界面每行只有「配方名 + 格式」两个可写控件，其余（最长边、含联系表）是只读文本（`.../GatherUI/Export/ExportView+Delivery.swift:170-215`）；「添加配方」硬编码 `quality: 85, maxDimension: 2048`（`ExportViewModel+Delivery.swift:91-92`），默认两条配方也是硬编码 82/2048 与 TIFF 原尺寸（`ExportViewModel+Delivery.swift:101-108`）。
- **进度/取消/续跑**：job checkpoint 记录 `completedPhotoIds`、`destinations`、`recipeFingerprint`（`Output.swift:167-187`）；指纹纳入命名求值输入与源内容摘要，改参数即开新交付身份（`ExportService+Plan.swift:342-379`）。
- **失败/取消语义**：取消按 runId 精确到一次执行（`ExportService+Run.swift:115-118`）。

### 1.3 交付、Web 与客户校样

- **静态 Web 画廊**：一次交付可产出 `index.html / gallery.css / gallery.js / data.json` + `thumbs/`（长边 480）+ `large/`（长边 1600）+ `proof.html / proof.js`，本地目录、不联网、不需要服务器（`.../GatherApplication/Services/Output/GalleryBuilder.swift:1-16`）。
- **客户校样闭环**：proof.js 用 localStorage 存「勾选 + 星级 + 色标 + 评论」，客户下载 `selection.json`，用户在导出页「导入客户反馈…」回填（`ExportView+Delivery.swift:108-133`；DTO 见 `.../GatherProtocol/Protocol/ProofShare.swift:7-57`），冲突以 `ProofFeedbackConflict` 主动上报。
- **联系表**：交付按配方 `artifacts` 生成联系表 PDF（`.../Services/Export/ContactSheetRenderer.swift:58` 固定 A4@72dpi 版面）；**参数在界面里不可调**：`columns: 4, rows: 5` 写死在 `ExportViewModel+Delivery.swift:399-402`，画廊标题/尺寸也写死（`ExportViewModel+Delivery.swift:403-406`），界面只有「包含联系表 / 包含 Web 画廊与客户校样」两个开关（`ExportView+Delivery.swift:48-53`）。
- **打印**：只有「联系表 PDF → 系统打印面板」这一条路，且按钮挂在**一次成功交付的结果行**里（`ExportView+Delivery.swift:315-322`；`PrintSupport.swift:8-34`）。
- **交付预检**：确认 sheet 冻结一份 `OutputRunInput`，按配方逐条 preview 汇总「预计文件数/体积/可用空间/源文件问题/失败配方」，空间不足或全部配方失败时禁用开始（`ExportViewModel+Delivery.swift:11-27, 299-345`；`DeliveryConfirmSheet.swift:19-22, 55-69`）。这是本域做得比竞品更细的一处：把「空间不足 / 源文件缺失 / 配方必然失败」放在确认前而不是写盘后。
- **WebDAV 发布**：`WebDAVPublishInput`（baseURL / username / remoteFolder / includePrefixes / share）（`Output.swift:288-314`），入口在交付成功后，发布白名单按 manifest 精确收窄（`ExportView+Delivery.swift:134-159, 264-296`）。
- **分享策略**：`allowDownload`、`expiresAt`（注释明确是 advisory + 到期撤销 job）、`remoteSubfolder`（`ProofShare.swift:59-74`）。除 WebDAV 外没有别的发布端点，也没有账号/口令/访客管理。

### 1.4 组织：集合 / 堆栈 / 智能相册 / 保存查询

- **手动集合**：会话级、扁平、可重排；成员 position 步长 1024，支持单行拖拽（`.../GatherProtocol/Protocol/Curation.swift:6-73`；`.../API/AlbumAPI.swift:31-48`；DDL `.../GatherPersistence/Database/Schema/SchemaCurrent+DDLWorkbench.swift:23-45`）。**表里没有 parent 字段**，即没有 Collection Set 层级，也没有跨会话集合。
- **集合 UI**：侧栏建集合（`CollectionSidebar.swift:189, 278-286`）、集合内上移/下移/移出/在访达显示（`.../GatherUI/Curation/CollectionView.swift:57-116, 319-328, 571`）；成员来自图库批量的 `addCollectionItems`（`.../GatherUI/Gallery/GalleryViewModel+Load.swift:70`）。集合视图没有「从集合导出/批量动作」入口。
- **堆栈**：会话级手动堆栈 + 封面 + gallery 折叠徽标（`AlbumAPI.swift:50-60`；`.../GatherUI/Gallery/GalleryViewModel+Load.swift:81-90`；`.../Gallery/GalleryGrid.swift:191`）；另有时间维度的 burst/scene 导航组（`.../Protocol/Navigation.swift:9-12`；`.../API/NavigationAPI.swift:14-19`）。没有虚拟副本/版本组概念。
- **智能相册**：`AlbumCreateParams.criteria` 是递归 `FilterGroup`（AND/OR 可嵌套），操作符 13 种（eq/neq/gt/lt/between/in/contains/contains_any/contains_all/starts_with/exists）（`.../Protocol/Filter.swift:55-120`）；界面支持「创建」与「用当前筛选更新」（`.../GatherUI/Library/LibraryView+Support.swift:39-102`）。
- **可过滤字段是白名单**：`filename/filepath/checksum/status/created_at` + 16 个元数据字段 + 11 个 IPTC JSON 字段 + `keywords`/`keyword_path`（`.../GatherPersistence/Database/Queries/PhotoFilterQuery.swift:61-88`）。没有「是否属于某集合/堆栈」「相对日期」「卷/目录」这类字段。
- **跨工作区重复（只读）**：精确 checksum 分组 + 视觉 hash 桶内汉明比较，界面在策展侧栏（`.../API/DuplicateAPI.swift:33-42`；`.../GatherUI/Curation/CollectionView.swift:358`）；只读、不做跨库删除。
- **保存查询**：全局 + 会话两档，UI 在画廊筛选条（`.../GatherUI/Gallery/GalleryViewModel+Filters.swift:167-180`；`.../Gallery/GalleryView+Content.swift:68`）。

### 1.5 库维护：备份 / 恢复 / 离线卷 / 库形状

- **备份/恢复/诊断**：`MaintenanceAPI` 4 方法（backup / listBackups / restore / exportDiagnostics）（`.../GatherProtocol/API/MaintenanceAPI.swift:5-9`）；备份产物是**目录库单文件** `base.sqlite` + 同名 `.sqlite.json` 元数据（`.../Services/Maintenance/BackupStore.swift:51-72`），带 sha256/verified/触发源（`.../Protocol/Maintenance.swift:12-38`）；自动触发为启动一次 + 每日一次（`.../Services/Maintenance/MaintenanceService.swift:432-493`）。
- **设置页接线**：备份清单/恢复/诊断在设置「维护」分区（`.../GatherUI/Settings/SettingsViewModel+Maintenance.swift:22, 50-64`；`SettingsView+MaintenanceSection.swift`）。
- **离线卷重连**：图库检查器「离线存储卷」按 `offlineFiles` 列出，确认后把 `oldRoot` 改写为 `newRoot` 并重索引（`.../GatherUI/Library/LibraryView+Support.swift:261-320`；API `.../GatherProtocol/API/AssetAPI.swift:17,20`；视图模型 `LibraryViewModel+Load.swift:157-166`）。
- **离线可见性**：照片状态 `missing`，图库有「在线/离线」筛选与离线角标（`.../GatherUI/Library/LibraryView+Filters.swift:35`；`.../Gallery/GalleryCellView.swift:47-49`）。
- **备份可信度**：备份完成后有独立校验器（`.../GatherPersistence/Database/Backup/BackupVerifier.swift`）与保留策略 prune（`BackupStore.swift:125-133`），记录 sha256 与 verified 标志（`Maintenance.swift:12-38`）。
- **库形状 fail-closed**：schema 形状不符默认归档重建，不自动迁移（`docs/README.md:15-16`）。
- **预览缓存**：`PhotoAPI.preloadThumbnails` 存在（`.../GatherProtocol/API/PhotoAPI.swift:49`），但**没有 UI 调用点**（全仓仅 Live 实现引用）—— API 有 / UI 无。

### 1.6 「有 API 没 UI / 有实现没协议」速查

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| 图片水印（logo PNG） | 协议有枚举、实现拒绝、UI 无 | `Export.swift:37-41` / `ExportService+Plan.swift:299` / `ExportView+Options.swift:88-125` |
| 摄取「移动而非复制」 | 实现有、协议无、UI 无 | `IngestService.swift:130` vs `SessionIngestInputs.swift:9-35` |
| 导入前预览（plan/dry-run） | 服务有 `plan()`、协议无 | `IngestService.swift:285` vs `SessionAPI.swift:37-38` |
| 缩略图预加载 | API 有、UI 无 | `PhotoAPI.swift:49` |
| 跨工作区重复（只读） | 已接线 | 协议 `.../API/DuplicateAPI.swift:33-42`；UI `.../GatherUI/Curation/CollectionView.swift:358` |
| 到期撤销发布 | 仅 advisory 字段 | `ProofShare.swift:59-74` |
| 联系表/画廊参数 | 协议有完整 DTO、UI 写死 | `Output.swift:16-121` vs `ExportViewModel+Delivery.swift:399-406` |

## 2. 竞品基线（按产品）

### 2.0 按工作流步骤的对照速览

| 步骤 | Lightroom Classic | Capture One | Photo Mechanic | Gather |
| --- | --- | --- | --- | --- |
| 插卡导入 | Import 对话框：第二副本、疑似重复、Apply During Import、Destination 组织、Filename Template [官方目录核实] | Import + 备份目标 [待核实] | Ingest：Primary/Secondary Destination、Source Directory Structure、Incremental Ingest、Metadata Template、Unmount [正文核实] | 只有 6 个参数、模板不持久、无预演、无库级去重 |
| 导入后整理 | Folders 面板 + 集合/集合集 + 智能集合 | Session / Album [待核实] | Contact sheet + 结构化关键词 + Catalog | 工作区 + 卷 facet + 集合（扁平）+ 智能相册 + 保存查询 |
| 交付规格 | 导出预设：色彩空间 /尺寸+ppi / 输出锐化 / 文字或图形水印 [正文核实] | Process Recipe 多规格 [待核实] | Rename 工具 + Metadata Template | 配方可存不可改；无色彩/DPI/锐化；水印仅文字 |
| 打印 | Print 模块（单图/联系表/Package）[正文核实] | 打印 [待核实] | 联系表 + 打印 | 仅「联系表 PDF → 系统打印」，入口在交付结果里 |
| 客户交付 | Publish Services + Web 模块上传 [官方目录核实] | 导出 + 第三方 [待核实] | 导出 + 上传工具 | 静态画廊（本地）+ WebDAV + selection.json 回传 |
| 目录维护 | 备份/恢复、完整性检查、合并目录、查找丢失 [正文核实] | Catalog 备份 [待核实] | Catalog、离线/缺失媒体、重索引、导入 LR 目录 [正文核实] | 整库备份/恢复、整根 relink、fail-closed 重建 |

### 2.1 Lightroom Classic（导入 / 组织 / 导出 / 打印 / 发布 / 目录）

- **导入**：官方 Import 选项页含 File Handling（Copy/Move/Add、`Make a Second Copy To`、`Don't import suspected duplicates`）、Apply During Import、Destination 组织方式、以及 Filename Template Editor 的重命名 token（目录条目已核实：<https://helpx.adobe.com/lightroom-classic/desktop/import-photos/photo-video-import-options.html>、<https://helpx.adobe.com/lightroom-classic/desktop/import-photos/filename-template-editor-text-template.html>）。**正文为 JS 渲染，本次只核实到官方目录条目，细节标 [待核实]**。Destination 面板按拍摄日期建子目录（正文核实）：<https://www.lightroomqueen.com/import-create-dated-folders/>。
- **组织**：Collection Set 是可嵌套的集合层级，「和文件夹一样」把集合拖进集合集（正文核实）：<https://www.lightroomqueen.com/create-collections/>；Smart Collection 有官方规则页（目录核实）：<https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/smart-collections-criteria-in-lightroom-classic.html>。目录级「查找丢失照片 → 临时集合 → 整文件夹 relink」（正文核实）：<https://www.lightroomqueen.com/check-catalog-missing-files/>。
- **导出**：Color Space（sRGB / AdobeRGB / ProPhoto）、Image Size（像素或「尺寸 + ppi」）、Output Sharpening（Screen / Print）、Watermark、Resolution/PPI（正文核实）：<https://www.lightroomqueen.com/export-from-classic/>、<https://www.lightroomqueen.com/ppi-setting-enter-export-dialog/>；图形水印选 PNG/JPG（正文核实）：<https://www.lightroomqueen.com/add-graphical-watermark/>。导出预设可保存复用并「Export with Preset」（官方目录核实）：<https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html>。
- **打印**：Print 模块有 Layout Style（Single Image / Contact Sheet / Picture Package）、Layout/Image Settings/Print Job 面板（正文核实）：<https://www.lightroomqueen.com/print-from-classic/>。
- **发布 / Web**：Publish Services（官方目录核实）：<https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-hard-drive-using-publish.html>；Web 模块 + 上传（官方目录核实）：<https://helpx.adobe.com/lightroom-classic/desktop/web-galleries/web-gallery-templates-settings.html>、<https://helpx.adobe.com/lightroom-classic/desktop/web-galleries/preview-export-upload-web-photo.html>。
- **目录**：备份/恢复（正文核实，含「损坏目录怎么办」）：<https://www.lightroomqueen.com/how-do-i-restore-a-lightroom-backup/>、<https://www.lightroomqueen.com/disaster-strikes-corrupted-catalog/>；合并多个目录的完整工作流（正文核实）：<https://www.lightroomqueen.com/merge-catalogs/>；「备份只备份 catalog 不备份照片」[待核实，页面标题已核实]：<https://www.lightroomqueen.com/does-lightrooms-backup-back-up-my-photos/>。

### 2.2 Capture One（Session / 导入 / 输出配方 / 批量队列）

- 官方产品页已核实：主打 Session 工作流与联机拍摄（页面正文出现 `session`/`tether`）：<https://www.captureone.com/en/products/capture-one-pro>。
- 已知的同类能力（Process Recipe / Output Recipe 多规格一次输出、Import 的二次备份目标、批量处理队列、Album/Smart Album、Session 模板、Tethering）：帮助中心 <https://support.captureone.com/hc/en-us> 本次抓取被 Cloudflare 403 拦截，**具体选项名与版本行为一律标 [待核实]**。本报告不使用未核实的 C1 细节作为缺口依据。

### 2.3 Photo Mechanic（摄取 / 结构化关键词 / Catalog）

以下均为官方 Knowledge Base 正文核实：

- **Ingest**：先选 Source（Disks/文件夹）与 Primary/Secondary Destination；`Source Directory Structure` + `Copy Photos` 决定目标里生成哪些子目录；`Rename Ingested Photos As` 用变量重命名；`Apply Metadata Template on Ingest`（local/global）；`Incremental Ingest` 保留「源里哪些已摄取」的历史、只拷新增；`Auto Ingest` 插卡即开始；摄取完成后可 `Unmount Source Disk(s)`；摄取是后台任务，完成即在目标开 contact sheet。「keeping track of which images have already been copied」：<https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos>。变量体系：<https://docs.camerabits.com/support/solutions/articles/48000207639-introduction-to-variables-in-photo-mechanic>；独立 Rename 工具：<https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool>。
- **结构化关键词 / 元数据**：Structured Keywords 面板与 IPTC/XMP 首选项、Metadata（IPTC）Template：<https://docs.camerabits.com/support/solutions/articles/48001144666-adding-keyword-metadata-to-photos>、<https://docs.camerabits.com/support/solutions/articles/48001142222-removing-structured-keywords>、<https://docs.camerabits.com/support/solutions/articles/48001146198-iptc-xmp-preferences>。
- **Catalog（PM Plus）**：Catalog 概念与 Collections、离线/缺失媒体、从 Lightroom 导入目录、重新索引、多人共享目录：<https://docs.camerabits.com/support/solutions/articles/48001078324-introduction-to-catalogs-in-photo-mechanic-plus>、<https://docs.camerabits.com/support/solutions/articles/48001078321-collections-in-photo-mechanic-plus>、<https://docs.camerabits.com/support/solutions/articles/48001162818-offline-or-missing-media>、<https://docs.camerabits.com/support/solutions/articles/48001164127-importing-catalogs-from-adobe-lightroom->、<https://docs.camerabits.com/support/solutions/articles/48001157497-re-indexing-a-catalog>、<https://docs.camerabits.com/support/solutions/articles/48001159649-sharing-a-catalog-with-other-users>。
- **未核实**：摄取是否有显式「逐文件校验和验证」勾选项（正文只出现「摄取完成后再拔卡」的操作提示），标 [待核实]。

### 2.4 Photoshop / Bridge

- Bridge 承担「批量重命名 + File Info（IPTC/XMP 模板）+ 批处理交给 Photoshop Action/脚本」的桥接角色；Batch Rename 官方文档页存在，但本次 curl 403、web_fetch 正文未取到 → **Batch Rename 具体模板项标 [待核实]**：<https://helpx.adobe.com/bridge/using/batch-rename-files.html>、<https://helpx.adobe.com/bridge/user-guide.html>。
- 结论层面只写一点（不需要细节即可成立）：Gather 没有任何「动作/脚本/批处理」扩展点，任何需要 PS 的动作链必须整段留在 Bridge/PS 里。

### 2.5 交付类：SmugMug / Pixieset / Frame.io

- Frame.io：官方 `Review & Approvals` 功能页存在（正文导航核实，时间线/版本对比细节 [待核实]）：<https://frame.io/features/review-and-approval>。
- Pixieset / SmugMug：客户画廊 + 收藏（favorite）+ 下载权限的产品定位明确，但本次抓取被 403/502 拦截，**全部标 [待核实]**：<https://www.pixieset.com/features/>、<https://help.smugmug.com/>。
- 对本域有意义的事实（不依赖版本细节）：这类平台的交付物是「一条可分享的链接 + 访客/口令/到期/下载权限」，而 Gather 的交付物是「本地目录 + 可选 WebDAV 上传」。

### 2.6 目录 / 索引管理：NeoFinder / Peakto

- NeoFinder：把文件夹或整块卷拖进 LIBRARY 即建 catalog（生成缩略图 + 读全量元数据），支持「Image Capture」式摄取并顺带重命名/写元数据（正文核实）：<https://www.cdfinder.de/photo-organizer.html>；使用手册入口：<https://www.cdfinder.de/guide/>。
- Peakto：定位为「聚合多个目录/编辑器的 catalog 索引器」，本次站点为 JS 渲染、正文未取到，标 [待核实]：<https://cyme.io/peakto/>。

## 3. 功能缺口表

严重度：P0 = 不补就用不起来 / 必须换工具；P1 = 日常明显摩擦；P2 = 锦上添花。成本：S/M/L/XL。
表共 22 条，其中 P0 3 条（全部落在交付侧）、P1 14 条、P2 5 条；成本 XL 1 条（目录合并/迁移），其余多为 S–M。

| # | 缺口 | 竞品怎么做（产品 + 链接） | Gather 现状（代码/文档证据） | 用户影响场景 | 严重度 | 补齐成本 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 交付没有「托管式分享」：无链接/口令/访客/到期强制，必须自备 WebDAV 服务器 | Lightroom Publish Services + Web 模块上传（<https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-hard-drive-using-publish.html>）；Frame.io 审片链接（<https://frame.io/features/review-and-approval>）；Pixieset/SmugMug 客户画廊 [待核实] | 只有 `WebDAVPublishInput`（`Output.swift:288-314`）+ 静态画廊（`GalleryBuilder.swift:1-16`）；`expiresAt` 仅 advisory（`ProofShare.swift:59-74`）；发布入口在「交付成功」之后（`ExportView+Delivery.swift:134-159`） | 拍完一场婚礼要发客户审片：要么自己有 WebDAV/网盘，要么退回 Pixieset/SmugMug/Frame.io | P0 | L |
| 2 | 导出不能指定色彩空间/ICC、DPI、输出锐化 | LR Export 有 Color Space / Image Size+ppi / Output Sharpening（<https://www.lightroomqueen.com/export-from-classic/>）；C1 输出配方 [待核实] | `ExportOptions` 无这些字段（`Export.swift:81-119`）；编码只写质量/压缩（`ExportService+Run.swift:263-278`） | 给印厂/杂志交 JPEG/TIFF 必须换 LR/C1 转一次；Gather 出的 TIFF 不能直接印 | P0 | M |
| 3 | 交付配方参数不可编辑：只有名字+格式可改，尺寸/质量/水印/命名全不可设 | LR 导出预设可保存可编辑（<https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html>） | 配方行仅 name/format（`ExportView+Delivery.swift:170-215`）；新建配方硬编码 85/2048（`ExportViewModel+Delivery.swift:91-92`） | 「给客户 1600px、质量 90、带水印」这种最常见交付规格做不到，只能交付 2048/85 或原图 | P0 | S |
| 4 | 导入没有「预设」：结构模板 + 元数据模板 + 去重策略无法存成一套复用 | LR Import Preset（导入对话框内保存，含 Copy/Move、重命名、Destination、Apply During Import）[官方目录核实；细节待核实]（<https://helpx.adobe.com/lightroom-classic/desktop/import-photos/photo-video-import-options.html>）；PM 的 Incremental Ingest + Metadata Template + Source Directory Structure（<https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos>） | 模板硬编码在 sheet 的 `@State`（`IngestSheet.swift:20`）；目标必须落在会话根内（`SessionIngestRunner.swift:59-62`）；无任何 settings 持久化 | 每周 3 场拍摄，每场都要重填模板；写错一个 token 就整批命名错，且无法回滚 | P1 | S |
| 5 | 图片水印（logo PNG）不可用 | LR Watermark 支持 Graphic（PNG/JPG，可透明）（<https://www.lightroomqueen.com/add-graphical-watermark/>） | 协议有 `image` 枚举但实现抛错（`ExportService+Plan.swift:299`），UI 只有文字水印（`ExportView+Options.swift:88-125`） | 给客户样片加水印必须换 LR/C1 | P1 | S |
| 6 | 联系表/画廊参数不可配（行列、字段、caption 模板、边距、缩略图尺寸） | LR Print 的 Layout/Image Settings/Print Job 面板（<https://www.lightroomqueen.com/print-from-classic/>） | `OutputContactSheetOptions`/`OutputGalleryOptions` DTO 完整（`Output.swift:16-121`），界面只有两个开关、参数写死 4×5 与 480/1600（`ExportViewModel+Delivery.swift:399-406`） | 想打一张 3×4、带标题/关键词的联系表给客户签字，做不到 | P1 | S |
| 7 | 打印工作流只有「联系表 PDF」，无单图/版面/打印预设 | LR Print 模块（Single Image / Contact Sheet / Picture Package） | 打印唯一入口是结果行的「打印联系表」（`ExportView+Delivery.swift:315-322`；`PrintSupport.swift:8-34`） | 要打 6 寸样片/装框大图，只能导出后去预览.app/PS 打 | P1 | M |
| 8 | 集合没有层级（无 Collection Set），也没有跨工作区集合 | LR Collection Set 可嵌套（<https://www.lightroomqueen.com/create-collections/>） | `collections` 表无 parent 列（`SchemaCurrent+DDLWorkbench.swift:23-45`）、DTO 无 parent（`Curation.swift:6-32`）、集合必须带 sessionId（`AlbumAPI.swift:34-38`） | 一年 40 个工作区、上百个集合时无法分组，只能靠命名前缀硬排序 | P1 | M |
| 9 | 集合/智能集合没有集合运算：无并/交/差、无 NOT 组、无「属于某集合/堆栈」字段、无相对日期 | LR Smart Collection 规则页（<https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/smart-collections-criteria-in-lightroom-classic.html>）[规则细节待核实] | 只有 AND/OR 递归组（`Filter.swift:84-120`）；字段白名单无集合成员/相对日期（`PhotoFilterQuery.swift:61-88`） | 「已选 + 未交付 − 已淘汰」这类交付清单只能手工做 | P1 | M |
| 10 | 导入去重只在**当前会话**内有效，跨工作区重复占盘 | LR 目录级 `Don't import suspected duplicates` [官方目录核实；细节待核实]；PM Incremental Ingest 记来源历史 | `photoChecksums(sessionId:matchingSizes:)` 只查本会话（`SessionIngestRunner.swift:84-92`） | 同一张卡先导入 A 工作区、再导入 B 工作区，磁盘上出现两份原片，还不知道 | P1 | M |
| 11 | 第二目的地副本不校验和（备份不可信） | LR `Make a Second Copy To`（官方目录核实）；PM Secondary Destination | 主副本验证（`IngestService.swift:455-457`），副目的地 `verify: false`（`IngestService.swift:498`；补拷同 `:584`） | 用户以为「已双备份」，实际第二份只保证「rename 成功」，坏卡/坏线导致的静默损坏查不出来 | P1 | S |
| 12 | 导入前无法预览（将复制/跳过/冲突各多少、落到哪些目录） | LR 导入对话框先显示缩略图与计数、再点 Import [待核实具体交互]；PM 摄取完成即开 contact sheet | `SessionAPI` 只有 `ingest`（`SessionAPI.swift:37-38`），服务端 `plan()` 未暴露（`IngestService.swift:285`） | 5000 张卡按下去才发现目标目录写错/模板错，只能等跑完再清理 | P1 | M |
| 13 | 没有物理文件夹视图（目录树），只有工作区 + 卷 facet | LR Folders 面板（层级目录树）[待核实]；PM 摄取后 contact sheet 直接对应目录 | 导航只有工作台/资料库/工作区页面（`RootShellSidebar.swift:6,18,26`）；物理维度只有卷筛选（`LibraryView+Filters.swift:184`） | 「按目录找昨天的片子」只能开 Finder；C1 里改过目录结构后无法核对 | P1 | M |
| 14 | 无目录导出/导入/合并（迁移、团队合并做不到） | LR 合并 catalog 完整工作流（<https://www.lightroomqueen.com/merge-catalogs/>）；PM 从 Lightroom 导入目录（<https://docs.camerabits.com/support/solutions/articles/48001164127-importing-catalogs-from-adobe-lightroom->） | 只有整库备份/恢复（`BackupStore.swift:51-72`），无「导出某工作区/合并两个库」入口；协议层无该域 | 两个助理各挑一半、要合并成一份交付库；或把旧库搬到新机器只带部分工作区 | P1 | XL |
| 15 | 库损坏只有「整库恢复」，没有完整性检查/修复入口 | LR 有完整性检查 + 优化目录（<https://www.lightroomqueen.com/disaster-strikes-corrupted-catalog/>）；PM 有 re-index（<https://docs.camerabits.com/support/solutions/articles/48001157497-re-indexing-a-catalog>） | `MaintenanceAPI` 只有 backup/restore/diagnostics（`MaintenanceAPI.swift:5-9`）；坏库默认 fail-closed 归档重建（`docs/README.md:15-16`） | 索引/元数据表轻微损坏 → 只能回滚到昨天的备份，丢掉今天的挑片决策 | P1 | M |
| 16 | 无导入后的批量重命名（只有摄取那一刻能改名） | Bridge Batch Rename（<https://helpx.adobe.com/bridge/using/batch-rename-files.html> [正文待核实]）；PM Rename 工具（<https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool>） | 全仓 rename 只出现在摄取面板（`IngestSheet.swift:20,72,190`） | 客户改口要换命名规范/统一后缀，只能放弃库内标记回 Finder 改，改完还要重扫 | P1 | M |
| 17 | 没有发布端点扩展机制（Publish Services 那类插件），只有 WebDAV 一种出口 | LR Publish Services（含第三方插件）[插件清单待核实] | `WebDAVPublishInput` 是唯一发布输入类型（`Output.swift:288-314`） | 客户用 Dropbox/Google Drive/自有 CDN，交付仍要人工搬 | P1 | L |
| 18 | 导出没有子目录规则（按客户/日期/事件分目录） | LR Destination 组织（Dated folders 正文核实：<https://www.lightroomqueen.com/import-create-dated-folders/>）；C1 输出位置 [待核实] | 命名只产出文件名（`ExportService+Plan.swift:49-73`），只创建顶层目标目录（`ExportService+Run.swift:123`），`destination` 是单一绝对路径（`Export.swift:93`） | 一次交付要按客户分子目录，只能先导出再手工搬 | P2 | M |
| 19 | 导入后的缩略图预缓存不可用（API 有 / UI 无） | LR 导入即建预览（标准预览/智能预览）[待核实具体选项] | `PhotoAPI.preloadThumbnails`（`PhotoAPI.swift:49`）无 UI 调用 | 大卡导入后第一遍翻片要现场解码，像「没导进来」 | P2 | S |
| 20 | 没有虚拟副本/版本组 | LR Virtual Copy [待核实]；C1 Variants [待核实] | 只有物理 RAW/JPEG 资产（`.../Protocol/Session.swift:63-76`）+ 手动堆栈 + burst/scene 组（`Navigation.swift:9-12`） | 「同一张出三版调色/两种裁切」只能靠文件复制，库里变成三张互不相关的照片 | P2 | L |
| 21 | 摄取不能「移动卡内文件」 | PM 摄取后自动 Unmount 源盘（<https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos>）；LR 支持 Move | `moveInsteadOfCopy` 只在服务层（`IngestService.swift:130`），输入 DTO 无字段（`SessionIngestInputs.swift:9-35`） | 卡容量不够、想边导边清卡时做不到，只能导完手动删 | P2 | S |
| 22 | 交付审计不完整：manifest 只有文件名+字节数（无校验和），结果区无「仅重试失败项」 | 本行无直接竞品对标（LR/C1 也不导出交付清单校验和 [待核实]） | manifest 条目 `name/bytes`（`Output.swift:189-198`）；结果区只有报告/Finder（`ExportView+Result.swift:35-51`） | 客户说「少了 3 张」时无法证明交付内容一致；200 张里 5 张失败只能整批重跑 | P2 | S |

## 4. 该域「最该补的 3 件事」

### 4.1 交付规格闭环：把配方做成真正可编辑的预设（覆盖缺口 2/3/5/6）

- 理由：这是唯一「不补就每单都要换工具」的技术性缺口。目前用户能交付的唯一规格是「JPEG 2048 / 质量 82-85 / 原始色彩 / 无锐化」，任何偏离（1600px、90 质量、sRGB、屏幕锐化、PNG logo）都必须去 LR/C1 重做一遍 —— 而交付规格是**每一单**都会用到的参数。
- 最小可行形态（S–M）：
  1. `ExportOptions` 增加 `colorSpace`（sRGB / Display P3 / 原样）、`dpi`、`outputSharpening`（none/screen/print）、`watermark.type == .image` 的 `imagePath`；`ExportService+Run.convert` 用 `CGImageDestination` 写 `kCGImagePropertyDPIWidth/Height` 与目标色彩空间。
  2. 把 `ExportView+Delivery` 的配方行展开成 mini 表单（尺寸/质量/水印/命名/includeXmp），字段直接绑 `OutputRecipe`；「添加配方」不再硬编码 85/2048。
  3. 单次导出页增加「保存为预设 / 载入预设」（复用 `output.recipes` 的持久化机制即可，无需新表）。
- 验收：一张图从 Gather 直接产出「长边 1600 / q90 / sRGB / 屏幕锐化 / logo 水印」且参数在重启后可复用。

### 4.2 让客户交付不需要自建服务器（覆盖缺口 1/17/22）

- 理由：交付是这条链路的终点，也是当前唯一**必须换工具**的产品级缺口。现在客户审片的前提是「摄影师自己有一台 WebDAV」，这在个人摄影师里几乎不成立；而静态画廊本体（`GalleryBuilder`）其实已经做完了，缺的是「怎么让客户打开它」。
- 最小可行形态（M–L，可分两步）：
  1. **近端（M）**：把「发布」从「交付成功后的附加动作」提到一等入口 —— 对任意画廊目录都能发布；发布产物加一份带校验和的脱敏 manifest（shasum + 张数 + 规格），并在 proof 页显示「共 N 张 / 已交付规格」。
  2. **远端（L）**：接一个托管后端（或直接给 S3/Cloudflare R2 的签名直传），产出「链接 + 可选口令 + 到期时间（服务端强制）」，把 `OutputShareOptions.expiresAt` 从 advisory 变成执行。
- 验收：不装任何服务器，30 分钟内把一场拍摄的校样链接发到客户微信，客户勾选后 selection.json 能一键导回。

### 4.3 导入变成「一次配置、每次一键」（覆盖缺口 4/10/11/12）

- 理由：导入是每天重复、且**错误不可逆**（文件已落盘、命名已生效）的一步。当前三个短板叠加：模板不持久、去重只看本会话、副目的地不校验 —— 用户既省不掉重填，也无法信任结果。
- 最小可行形态（M）：
  1. 新增 `ImportPreset`（结构模板 + 重命名模板 + 第二目的地 + 校验开关 + 是否跨库去重），存 settings；`IngestSheet` 顶部一个预设下拉。
  2. `SessionAPI` 增 `planIngest`（复用 `IngestService.plan`，只读）：显示「将复制 N / 已存在跳过 M / 冲突 K / 目标前 3 个路径」。
  3. 去重扩到库级（`photoChecksums` 去掉 sessionId 限定或加 `libraryWide` 选项）；副目的地复制走 `verify: true` 并在结果里显示「双份已校验」。
- 验收：插卡 → 选预设 → 看到 plan 计数 → 一键导入 → 结果明确写「N 张双份已校验，M 张库内已存在已跳过」。

## 5. 一句话总结

Gather 在「挑片 → 元数据 → 集合/堆栈 → 静态校样」这一段已经能独立闭环，甚至比 Lightroom 更省服务器；但**交付规格（色彩/DPI/锐化/可编辑配方）与交付触达（托管链接/口令/到期）两处仍是必须换工具的断层**，导入侧则是「可用但不省事、不可预演、备份不可信」。这三块补齐后，本域才谈得上「替代 C1 + Lightroom 的交付环节」。

## 附录. 证据索引（按文件，便于复核）

| 文件 | 本报告用到的主张 |
| --- | --- |
| `GatherProtocol/API/Inputs/SessionIngestInputs.swift` | 摄取只有 6 个参数、无 move、结果字段语义 |
| `GatherProtocol/API/SessionAPI.swift` | 无 plan/preview 方法（37-38） |
| `GatherApplication/Services/Ingest/IngestService.swift` | token 体系、去重/冲突、副目的地 verify:false、moveInsteadOfCopy、校验落地 |
| `GatherApplication/Services/Ingest/SessionIngestRunner.swift` | 目标必须在会话根内、去重只在会话内、登记路径 |
| `GatherProtocol/Protocol/Export.swift` | 导出字段集合（无色彩/DPI/锐化）、命名 token 契约、预览三计数 |
| `GatherApplication/Services/Export/ExportService+Plan.swift` | token 求值、单目录唯一化、水印 image 拒收、交付指纹 |
| `GatherApplication/Services/Export/ExportService+Run.swift` | 只建顶层目录、只写质量/压缩、Watermark 合成 |
| `GatherProtocol/Protocol/Output.swift` | 配方/联系表/画廊/manifest/WebDAV 契约 |
| `GatherProtocol/Protocol/ProofShare.swift` | 校样回传 v2、分享策略（allowDownload/expiresAt advisory） |
| `GatherApplication/Services/Output/GalleryBuilder.swift` | 静态画廊与 proof.html 产物清单 |
| `GatherProtocol/Protocol/Curation.swift` + `SchemaCurrent+DDLWorkbench.swift` | 集合无 parent、堆栈表结构 |
| `GatherProtocol/Protocol/Filter.swift` + `Database/Queries/PhotoFilterQuery.swift` | 智能相册表达式能力与字段白名单 |
| `GatherProtocol/API/MaintenanceAPI.swift` + `Services/Maintenance/BackupStore.swift` | 备份/恢复只有单文件 sqlite、无完整性检查入口 |
| `GatherUI/Export/ExportView+Delivery.swift` / `ExportViewModel+Delivery.swift` | 配方行只有 name/format、联系表参数写死、发布入口位置、预检 |
| `GatherUI/Export/ExportView+Options.swift` | 单次导出界面的全部可写字段（含水印仅文字） |
| `GatherUI/Culling/IngestSheet.swift` | 模板 @State、进度轮询、只显示第一条失败 |
| `GatherUI/Library/LibraryView+Support.swift` | 智能相册创建/更新、离线卷 relink 交互 |
| `GatherUI/Curation/CollectionView.swift` | 集合内动作（无导出/批量动作） |
