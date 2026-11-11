# 摄取 / 导出 / 打印 / 组织 / 交付 / 迁移 功能复核（2026-11-11，基线 50fea319）

> 域：导入（摄取）· 导出规格 · 打印 · 组织（集合/智能相册）· 客户交付与分享 · 库包迁移 · 任务与报告。
> 上轮分册：`docs/reviews/2026-11-10-competitive-gap/40-ingest-export-organize.md`（22 条：#1–#3 P0、#4–#17 P1、#18–#22 P2）。
> 基线：`50fea319`（Wave1–4c 修复后，工作树干净）；行号取当前工作树。方法：上轮 17 条 P0/P1 逐条回核，判"已闭环"必须有 UI 调用点；再挖 Wave2/3 半成品与竞品真实工作流缺口。
> 纪律：只读代码；未跑 build/test；打印 / 发布 / 迁移未在真机点验（96 号 §3/§7/§8 仍未执行）。
> 交叉边界：堆栈 / 虚拟副本 / 卷重连归 05 号；导入元数据预置 / 模板变量归 40-metadata-search（本文只在"导入配置"处交叉引用，不重复计缺口）。
> 竞品口径：复用上轮 §2 已核链接；本轮新增 AWS 预签名官方页（HTTP 200）。Pixieset / Adobe 帮助正文仍 403 或 JS 渲染 → 相关细节标 [待核实]。

## 0. 结论速览

- **上轮 3 条 P0 全部闭环**：交付分享（WebDAV/S3 + 前端口令/到期，按 97 号 §11 边界）、导出色彩空间 / DPI / 锐化、交付配方全字段可编辑。
- **上轮 14 条 P1：6 条闭环、4 条部分、4 条未闭环**（其中"库完整性检查"按影响降为 P2）。闭环的 6 条：图片水印、打印、集合层级（命名路径约定）、集合运算 / 智能集合字段、跨会话导入去重、第二目的地校验。
- **本域无新增 P0**；最接近 P0 的是 **S3 通道交付件客户打不开**——对象默认私有、无预签名、无公开读，发布完成也不给链接。若把 S3 当一等交付通道，这属"假成功"。
- **Wave2/3 的交付链只做到"上传"**：无发布记录 / 历史、不能只发增量、无链接可复制、发布目标（endpoint / 桶 / 远端目录）不持久、发布入口只挂在"本次交付成功"的内存结果上（`ExportView+Delivery.swift:134-159`）。
- **迁移包只带"照片 + 手动集合"**：堆栈 / 智能相册 / 保存查询 / 人物-人脸绑定不在包结构里（`MaintenanceAPI.swift:259-358`），UI 也未声明，换机会静默丢组织资产。
- **导入仍是"每次重填 + 结果半可见"**：无导入预设（`IngestSheet.swift:18-24`）、模板非法 token 不拦截、失败只显示第一条、第二目的地成功 / 校验不可见。
- **组织面**：集合层级 / 并交差 / 相册规则已可用；仍缺物理文件夹树（Bridge / LR 的"按目录找片"），且集合（Library 侧栏）、智能相册（Library 检查器）、保存查询（Gallery 筛选条）分散三处。
- **"API 有 / UI 无"复检四处**：移动式摄取、`preloadThumbnails`、`export_post_command` 设置、person/keyword 报告类型——均确认仍无 UI 调用点。

## 1. 上轮缺口状态核对

| 上轮# | 缺口一句话 | 上轮 | 当前状态 | 当前证据（路径:行号） | 剩余差 |
| --- | --- | --- | --- | --- | --- |
| 1 | 无托管式分享 / 链接 / 口令 / 到期 | P0 | 已闭环 | 传输选择 + 口令 + 到期：UI `WebDAVPublishSheet.swift:141-216`；S3 通道 `S3ShareTransport.swift:296-320`；边界见 97 号 §11 | 客户可访问性 / 链接 / 发布状态 → §2 A1/A2（不是"没有托管"的重复） |
| 2 | 导出无 ICC / DPI / 输出锐化 | P0 | 已闭环 | 协议字段 `Export.swift:41-62,262-268`；单导出 UI `ExportView+Options.swift:120-158`；执行 `ExportService+Run.swift:280-335` | — |
| 3 | 交付配方参数不可编辑 | P0 | 已闭环 | 配方编辑器全字段 `ExportView+Delivery.swift:322-760`；默认值 `ExportViewModel+Delivery.swift:140-161`；契约 `Output.swift:43-119` | — |
| 4 | 导入没有预设（模板 / 第二目的地 / 去重策略不可复用） | P1 | 未闭环 | 模板仍是 `@State`：`IngestSheet.swift:18-24`；全仓 grep `ImportPreset/ingestPreset` 0 命中；`SettingsKey.swift` 无 ingest 键 | 全套导入配置一次性保存 / 复用 |
| 5 | 图片水印（logo PNG）不可用 | P1 | 已闭环 | 协议 `Export.swift:82-113`；UI `ExportView+Options.swift:169-247`；实现 `ExportService+Run.swift:434-529` | — |
| 6 | 联系表 / 画廊参数不可配 | P1 | 部分 | 行列 / 边距 / caption / 字段 / 尺寸已可编辑：`ExportView+Delivery.swift:784-855`、`Output.swift:122-164` | 纸张尺寸 / 横竖版 / 每格缩略图仍写死 A4（`ContactSheetRenderer.swift:39,58`）；画廊字段 UI 只有 3 个 |
| 7 | 打印只有"联系表 PDF" | P1 | 已闭环 | 单图 / 多页 / 纸张 / 边距 / 页眉页脚：`PrintOptionsSheet.swift:99-252`；入口 `CullingWorkbenchViewer.swift:362-368`；联系表打印仍可直接打 PDF `ExportView+Delivery.swift:268-275` | 无横向、无打印预设持久化（P2） |
| 8 | 集合没有层级 / 跨工作区集合 | P1 | 已闭环 | 命名路径树 + 重命名即移动：`CollectionSidebar.swift:191-223,584-690`、`CollectionTree.swift`；取舍文档 `docs/README.md:33-35` | schema `parent_id` 是文档化取舍；跨工作区集合仍不可用（P2） |
| 9 | 集合无运算 / 智能集合字段不足 | P1 | 已闭环 | 并 / 交 / 差 + 被减数：`CollectionSidebar.swift:240-320`、`AlbumAPI.swift:49-51`；NOT / 集合 / 堆栈 / 相对日期规则：`FilterRuleEditor.swift:51-59` | 集合 / 堆栈规则仍手填 UUID（P2，已在 UI 说明） |
| 10 | 导入去重只在当前会话 | P1 | 已闭环 | 策略 DTO `SessionIngestInputs.swift:13-21`；面板三选一 + 预检 `IngestSheet.swift:104-146`；全库去重 `SessionIngestRunner.swift:121-140` | — |
| 11 | 第二目的地不校验和 | P1 | 已闭环 | 第二份也走同一校验开关：`IngestService.swift:648,665` | 结果不显示"双份已复制 / 已校验"（P2） |
| 12 | 导入前无法预览 | P1 | 部分 | 四类计数 + 重复样例：`SessionIngestRunner.swift:121-140`、`SessionIngestInputs.swift:33-45`、`IngestSheet.swift:127-146` | 无目标路径预览、无冲突清单（只报计数） |
| 13 | 无物理文件夹视图 / 目录树 | P1 | 未闭环 | 侧栏只有工作台 + 最近工作区 + 全局图库：`RootShellSidebar.swift:14-19`；物理维度只剩 `directory` 前缀筛选 `FilterRuleEditor.swift:54`（05 号 §1.1 同判） | 目录树浏览 / 按目录建工作区 |
| 14 | 无目录导出 / 导入 / 合并 | P1 | 部分 | 单工作区 `.gatherlib.json` 包 + 三冲突策略：`MaintenanceAPI.swift:15-23,31-42,76-101`；入口 `MigrationCenterCard.swift:79-100` | 包内缺堆栈 / 智能相册 / 人物（§2 A3）；整库批量与 .lrcat/.cos 导入属 ROADMAP 边界（§5） |
| 15 | 无完整性检查 / 修复 | P1 | 未闭环 | `MaintenanceAPI.swift:6-10` 仍只有 backup/list/restore/diagnostics（+迁移三方法） | 降 P2：每日自动备份 + fail-closed 兜底，缺的是提前发现 / 修复 |
| 16 | 无导入后的批量重命名 | P1 | 未闭环 | API 层 grep 无照片改名方法（只有 `renameTemplate`：`SessionIngestInputs.swift:101` 与集合 / 关键词改名） | 批量改名 + 写盘 + 回绑库路径 |
| 17 | 无发布端点扩展（只有 WebDAV） | P1 | 部分 | 通道枚举只 `webdav/s3`：`ProofShare.swift:59-64`；S3 已接 `WebDAVPublishSheet.swift:160-184` | 无 FTP / SFTP / Dropbox / Drive（P2） |

**上轮 P2 汇总（5 条）**：#18 导出子目录规则 → 已闭环（`Export.swift:115-235`、`ExportView+Delivery.swift:707-760`）；#19 缩略图预缓存 → 未闭环（API 有 / UI 无：`PhotoAPI.swift:49`）；#20 虚拟副本 / 版本组 → 归 05 号，本文不评；#21 移动式摄取 → 未闭环（实现有 / 协议无：`IngestService.swift:147` vs `SessionIngestInputs.swift:95-125`）；#22 交付审计 → 部分（相对路径已补 `OutputService.swift:185,428-434`；校验和 / 客户版清单 / 失败明细仍缺）。

### 1.1 96 号 §9 内与本域相关的已知项

- **旧配方 artifacts 迁移**：已闭环（task-23；`Output.swift:79`、`ExportViewModel+Delivery.swift:81-111`）。
- **集合 schema parent_id**：未做，但已有可见层级（命名路径约定），属文档化取舍，不再当缺口。
- **NOT / 集合 / 相对日期编辑入口**：已闭环（`FilterRuleEditor.swift:26-59,341-345`）。
- **导出后命令钩子只挂整套交付**：仍成立（`LiveExportAPI.swift:331-370` 只在 runRecipes 后执行）；且设置键无 UI（§3 N4）。
- **打印 / 第二屏纳入状态**：本轮已合并（打印见 #7；第二屏归 20 号）。

## 2. 剩余缺口表

> 严重度口径：P0=功能性坏掉/数据不安全/核心工作流断链；P1=每个工作流撞一次的摩擦或能力缺失；P2=有更好、没有也能用。成本 S≤2 人日 / M≈1 周 / L>2 周。链接沿用上轮 §2；新链接标 `*本轮核实`。

### 2.1 P1

| 严重度 | 缺口 | 竞品做法 + 链接 | Gather 证据 | 成本 | 修法一句话 |
| --- | --- | --- | --- | --- | --- |
| A1 | **S3 交付件客户不可访问**：对象私有、不写 ACL、无预签名；发布"成功"但客户没有可打开的地址 | AWS 官方做法=预签名 URL（限时访问私有桶对象）`https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html`* | `S3ShareTransport.swift:5-6`（只 PUT/DELETE、对象默认私有）；UI 明说"不开启公开读" `WebDAVPublishSheet.swift:181`；全仓无 presign | M | 发布时为 gallery 入口 / 文件生成限时预签名 URL，或给显式"公开只读"开关并把风险写清 |
| A2 | **发布无状态 / 无历史 / 不能增量 / 无链接**：换机或重开应用后不能再次发布；每次全量重传；发布目标每次重填 | LR Publish Services 以"发布集合"跟踪已发布/待重发 [官方目录核实；细节待核实] `https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-hard-drive-using-publish.html` | 发布入口只在内存 result 上：`ExportView+Delivery.swift:134-159`（`deliverySummary` 仅内存 `ExportViewModel.swift:76`）；`WebDAVPublishInput` 无 photoIds / 版本（`Output.swift:374-421`）；发布器只 PUT/MKCOL 无 HEAD/差分（`WebDAVPublisher.swift:28-29`）；endpoint/桶是 sheet 内 `@State`（`WebDAVPublishSheet.swift:20-28`） | M | 持久化发布记录（远端 + photoId + 版本）+ 远端 HEAD/ETag 差分 + 结果区展示可复制链接；发布改为独立一等入口 |
| A3 | **迁移包丢组织资产**：只带照片 + 手动集合；堆栈 / 智能相册 / 保存查询 / 人物-人脸绑定 / 重复组都不在包里 | LR 合并目录承载完整目录内容（集合 / 智能集合 / 堆栈）[合并流程正文已核，具体包含项待核实]（`https://www.lightroomqueen.com/merge-catalogs/`）；PM 目录含 Collections [上轮已核]（`https://docs.camerabits.com/support/solutions/articles/48001078321-collections-in-photo-mechanic-plus`） | `LibraryPackage` 只有 session/collections/photos（`MaintenanceAPI.swift:259-358`）；导出只查 `CollectionRepo`（`LibraryPackageService.swift:51-87`），导入只重建集合（`:285-296`）；UI 文案只说"不含原图" | M | 包格式加 stacks / smartAlbums / savedQueries / personBindings 段（有则导出、导入按名/ID 映射），并在 UI 明示"带走哪些组织信息" |
| A4 | **导入没有预设**：改名模板 / 第二目的地 / 校验开关 / 重复策略每次手填 | LR Import Preset [官方目录核实；细节待核实]（`https://helpx.adobe.com/lightroom-classic/desktop/import-photos/photo-video-import-options.html`）；PM Ingest + Metadata Template + Incremental（`https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos`，正文已核） | 模板在 `@State`（`IngestSheet.swift:18-24`）；无 `ImportPreset` 类型、无 settings 键（grep 0 / `SettingsKey.swift` 无 ingest） | S | settings 存"导入预设"数组（模板+第二目的地+校验+去重策略），面板顶部下拉 + 保存当前配置 |
| A5 | **无物理文件夹树**：Bridge / LR 的"按目录找片"在 Gather 不存在，只能建工作区或按路径前缀筛选 | LR Folders 面板 / Bridge Folders 面板 [待核实]（上轮 Bridge 目录 `https://helpx.adobe.com/bridge/user-guide.html`） | 侧栏无目录树（`RootShellSidebar.swift:14-19`）；唯一物理维度=`directory` 规则字段（`FilterRuleEditor.swift:54`） | M | 只读目录树面板（工作区 sourcePath 为根 + 外部盘），右键"在此新建工作区 / 摄取到当前工作区" |
| A6 | **无导入后批量重命名**：改名只能回 Finder，之后库里旧路径变 missing / 新路径待索引 | Bridge Batch Rename（`https://helpx.adobe.com/bridge/using/batch-rename-files.html` [正文待核实]）；PM Rename 工具（`https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool`，正文已核） | 协议无照片改名方法（只有 ingest `renameTemplate` `SessionIngestInputs.swift:101`）；UI 无入口 | M | 选中照片→批量改名（沿用 ingest token 引擎 + 预演 + 冲突策略），写盘后更新 photo.filepath / 缩略图缓存 |

### 2.2 P2

| 严重度 | 缺口 | 竞品做法 + 链接 | Gather 证据 | 成本 | 修法一句话 |
| --- | --- | --- | --- | --- | --- |
| B1 | 联系表纸张固定 A4 / 无横向 / 每格缩略图尺寸不可调（实现有 pageSize，协议与 UI 没暴露） | LR Print 的 Page Setup / Layout（`https://www.lightroomqueen.com/print-from-classic/`，上轮已核） | `ContactSheetRenderer.swift:39,58`（pageSize 默认 595×842，映射处不传 `OutputService.swift:449-456`）；`OutputContactSheetOptions` 无 pageSize（`Output.swift:122-164`） | S | `OutputContactSheetOptions` 加 pageSize/orientation，配方编辑器给纸张下拉 |
| B2 | 画廊展示字段只有星 / 色标 / 取舍；caption 固定文件名，标题 / 关键词 / 拍摄时间不展示 | LR Web 画廊模板可配标题 / 说明 / 元数据 [官方目录核实]（`https://helpx.adobe.com/lightroom-classic/desktop/web-galleries/web-gallery-templates-settings.html`） | UI 只有 3 个开关 `ExportView+Delivery.swift:846-853`；`GalleryBuilder.swift:309` caption 只取文件名 / 成片名 | S | 画廊字段扩到与联系表同表驱动；caption 模板复用 `CaptionFormatter` |
| B3 | 导入结果 / 预检"只到计数"：无目标路径清单、失败只显示首条、第二目的地成功数不可见 | PM 摄取完在目标开 contact sheet 并列出结果（`https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos`） | 预检 DTO 只有计数 + 重复样例（`SessionIngestInputs.swift:33-45`）；失败只取 `failed.first`（`IngestSheet.swift:196-202`）；结果字段只有 `secondDestinationSkipped`（`SessionIngestInputs.swift:148-164`） | S | 预检加"目标目录前 N 个路径 + 冲突清单"；失败列表全量展开 + "只重试失败项"；结果加"第二份已复制 / 已校验 N 张" |
| B4 | 摄取模板非法 token 不拦截：错拼 `{yyyyy}` 原样进文件名；只有路径穿越被挡 | LR Filename Template Editor 从 token 列表选择（`https://helpx.adobe.com/lightroom-classic/desktop/import-photos/filename-template-editor-text-template.html` [官方目录核实]） | 注释即"未知占位符原样保留"（`IngestService.swift:20-22`）；只挡 `isWithin`（`:470-475`） | S | 摄取前做模板静态校验（unclosed / unknownToken 中文提示，按子目录规则同一口径） |
| B5 | 移动式摄取（导入即移走卡内文件）不可用 | LR Import Move / PM 摄取后卸载源盘（PM 页正文已核） | 服务层有 `moveInsteadOfCopy`（`IngestService.swift:147`），但协议输入无字段（`SessionIngestInputs.swift:95-125`）、UI 无开关 | S | 输入加 `move` + 面板勾选（默认关；确认文案写"源文件将被移走"） |
| B6 | 导入后缩略图预缓存仍不可用（API 有 / UI 无） | LR 导入即建预览 [待核实] | `PhotoAPI.swift:49` 仅 Live 实现 / 测试引用，无 UI 调用 | S | 摄取成功/新建工作区后自动入队 `thumbnail.build`（已有 job 类型 `Jobs.swift:11`） |
| B7 | 无库完整性检查 / 优化入口 | LR 完整性检查 / 优化目录（`https://www.lightroomqueen.com/disaster-strikes-corrupted-catalog/`，上轮已核）；PM re-index（`https://docs.camerabits.com/support/solutions/articles/48001157497-re-indexing-a-catalog`） | `MaintenanceAPI.swift:6-10` 无 integrity / vacuum 方法 | M | 加 `integrityCheck`（SQLite integrity_check + 外键 / 计数对账）与 `optimize`（VACUUM / ANALYZE），结果只报告不自动改 |
| B8 | 交付审计弱：manifest 只有 name+bytes（无校验和）、失败只显示首条、无脱敏客户清单 | 本行无直接竞品对标（LR/C1 也不导出交付校验和 [待核实]） | manifest 条目 `Output.swift:236-243`、写入 `OutputService.swift:507-516`；失败只 `errors.first`（`ExportView+Delivery.swift:283-288`）；脱敏清单被明确留作后续（`:210-214`） | S | manifest 计 sha256；结果区全量失败 + 重试；生成"客户版清单"（张数/规格/校验和，不含本机路径） |
| B9 | 单次导出无预设；打印选项不持久 | LR Export Preset（`https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html` [官方目录核实]）；LR Print 保存打印设置 [待核实] | 只有 `output.recipes` 持久化（`SettingsKey.swift:67`）；单导出 UI 无保存/载入；`PrintOptionsSheet` 全是 `@State` | S | 复用 `OutputRecipe` 存一份"单导出预设"；打印设置键落 settings |
| B10 | 报告 / 钩子"API 有 / UI 无"：person / keyword 报告类型不可选，CSV 只有 filename/path/status；`export_post_command` 无设置 UI、结果不上屏 | 本行无直接竞品对标；导出后脚本是 Bridge / LR 插件生态的核心能力（上轮 §2.4 / §2.1） | 服务支持三类报告 `ExportService+Report.swift:18-56`，UI 硬编码 `session_summary`（`ExportViewModel+Report.swift:11`）；设置键存在（`SettingsKey.swift:96-97`）但 UI grep 0；钩子结果只在 manifest（`Output.swift:344-346`） | S | 报告类型/列可配；设置页加导出后命令 + 结果行展示 outcome |
| B11 | 组织概念分散 + 跨工作区集合不可用 + 集合/堆栈规则手填 UUID | LR 的 Folders / Collections / Smart Collections 在同一面板（`https://www.lightroomqueen.com/create-collections/`，上轮已核） | 集合在 Library 侧栏（`CollectionSidebar`）；智能相册在 Library 检查器（`LibraryView+Support.swift:39-101`）；保存查询在 Gallery 筛选条（`GalleryView+Filters.swift:54-100`）；集合必带 sessionId（`Curation.swift:55-63`）；UUID 手填（`FilterRuleEditor.swift:400`） | M | 统一"组织"侧栏（集合树 + 智能相册 + 保存查询），集合/堆栈规则给候选下拉 |
| B12 | 客户画廊只能回传 selection.json：没有成片下载 / ZIP；交付元数据无"移除 GPS / 精简"开关 | Pixieset / SmugMug 客户画廊支持收藏 + 下载 [待核实]（`https://www.pixieset.com/features/` 403）；LR 导出 Metadata 可裁剪位置信息 [待核实] | proof 页唯一按钮=下载 selection.json（`GalleryBuilder.swift:402`）；导出保留 EXIF/GPS/IPTC（`ExportService+Run.swift:313-335`），无裁剪选项 | S/M | proof 页加"下载所选成片 / ZIP"（allowDownload 时）；导出加"移除 GPS / 精简元数据"开关 |
| B13 | 迁移收尾：导入后不自动重索引；无进度 / 取消；入口埋在控制中心"分析与索引"卡片 | PM 支持从 LR 目录导入（`https://docs.camerabits.com/support/solutions/articles/48001164127-importing-catalogs-from-adobe-lightroom-`，上轮已核）；LR 合并目录后照片直接可用（`https://www.lightroomqueen.com/merge-catalogs/`） | 缺失文件登记 pending，"下次索引扫描"才更新（`LibraryPackageService.swift:211`）；卡片只有 `isBusy`（`MigrationCenterCard.swift:61-69`）；入口在 `SessionControlView+Toolbox.swift:37` | S/M | 导入成功后自动入队 metadata.scan；导入走 job（可取消 / 有进度）；控制中心顶部给迁移入口 |
| B14 | 发布端点只有 WebDAV / S3 | LR Publish Services 第三方插件生态（Flickr / SmugMug 等）[插件清单待核实] | `ProofShare.swift:59-64` 两枚举；无 FTP/SFTP/网盘 | L | 先加 SFTP + 一个网盘（Dropbox/Drive）适配器（复用 `OutputShareTransport` 抽象） |

## 3. 新发现（上轮未列 / Wave2–3 半成品）

### N1 交付链"只完成上传"：最接近 P0 的一处

- **S3 通道不可用**：发布器明确"只做 PUT/DELETE、不做预签名、对象默认私有"（`S3ShareTransport.swift:5-6`），UI 也提示"不开启公开读"（`WebDAVPublishSheet.swift:181`）。客户端没有任何 URL/签名可用；除非用户自己去 AWS 控制台配桶策略。AWS 官方对"私有桶共享"的答案就是预签名 URL（本轮抓取 200）。
- **无链接输出**：发布完成只显示"已发布 N 个文件"（`ExportView+Delivery.swift:140-147`）；`WebDAVPublishSummary.remoteRoot` 从未上屏；客户端要自己拼 `server/folder/index.html`。
- **无状态 / 无增量**：`WebDAVPublishInput` 没有 photoIds / 版本（`Output.swift:374-421`），发布器也没有 HEAD/ETag 比对（`WebDAVPublisher.swift:28-29`）；一轮交付改一张，重发=全量重传。
- **入口只在本次交付结果里**：`if let summary = viewModel.deliverySummary` 才有发布按钮（`ExportView+Delivery.swift:134-159`），`deliverySummary` 仅内存（`ExportViewModel.swift:76`）。重启应用后"把上次那套画廊再发一次"在 UI 里不可达，尽管 `ExportAPI.publish` 接受任意 localPath（`ExportAPI.swift:25-28`）。
- **发布目标不持久**：endpoint / bucket / remoteFolder 是 sheet 内 `@State`（`WebDAVPublishSheet.swift:20-28`），凭据进了 Keychain，但界面不列出、不预填。

### N2 迁移包的组织资产断层（静默）

`LibraryPackage` 的段只有 `formatVersion/app/exportedAt/session/collections/photos`（`MaintenanceAPI.swift:259-358`）；导出只读 `CollectionRepo`（`LibraryPackageService.swift:51-87`）。因此换机/合并后：**堆栈、智能相册（criteria）、保存查询、人物与 face cluster 绑定都不在**。UI 只写"目录包不含原图"（`MigrationCenterCard.swift:75`），没有"组织信息只带手动集合"的说明——用户会以为整套工作区都过去了。这不是 ROADMAP"不做完整 DAM / 目录迁移"（那指跨工具目录导入），是自有格式包的完整性问题。

### N3 导入"一次配置"仍不存在，且结果半可见

- 面板所有配置都是 `@State`（`IngestSheet.swift:18-24`），关掉 sheet 即丢；`ImportPreset` 全仓 0 命中。
- 模板未知 token 原样保留（`IngestService.swift:20-22`），错拼会落成带花括号的文件名；只有路径穿越被 `isWithin` 挡下（`:470-475`）。
- 预检给了四类计数与最多 3 条重复样例（`IngestSheet.swift:129-144`），但不预览"会落到哪些目录"、不列冲突文件；失败只显示第一条（`:196-202`）；第二目的地只报"跳过 N 张"（`:185-190`），成功与校验结果不上屏。
- 仍不能 move（B5），也仍无"自定义摄取后元数据模板"（归 40 号 N1，不重复）。

### N4 "API 有 / UI 无"四处（历史教训复检）

| 能力 | 协议 / 实现 | UI 现状 |
| --- | --- | --- |
| 移动式摄取 | `IngestService.swift:147`（`moveInsteadOfCopy`） | `SessionIngestInputs.swift:95-125` 无字段；`IngestSheet` 无开关 |
| 缩略图预缓存 | `PhotoAPI.swift:49` + `LivePhotoAPI.swift:378` + `thumbnail.build` job（`Jobs.swift:11`） | 仅测试 / 注释引用，0 个 UI 调用 |
| 导出后命令 | `SettingsKey.swift:96-97` + `ExportPostCommandRunner` + `LiveExportAPI.swift:356-370` | 无设置 UI；结果只在 manifest，不上屏 |
| person / keyword 报告 | `ExportService+Report.swift:34-56` | UI 恒发 `session_summary`（`ExportViewModel+Report.swift:11`） |

### N5 Wave2/3 版式半成品

- 联系表：行列 / 边距 / caption / 字段都可配了，但页面固定 A4 竖向；渲染器本身有 `pageSize`（`ContactSheetRenderer.swift:39,58`），只是协议 DTO 没这个字段（`Output.swift:122-164`），映射处也不传（`OutputService.swift:449-456`）——典型"实现有 / 协议无"。
- 画廊：字段开关只有星 / 色标 / 取舍（`ExportView+Delivery.swift:846-853`），而 `ContactSheetFields` 支持 8 种；caption 固定文件名（`GalleryBuilder.swift:309`）。
- 打印：栏位齐全，但无横向（UI 已明说"选更宽的纸"，`PrintOptionsSheet.swift:162-165`），选项不持久（B9）；库 / 图库网格里没有打印入口（只在挑片查看器 `CullingWorkbenchViewer.swift:362-368` 与交付结果行）。

### N6 组织 / 报告中心未成形

- 三种"容器"分处三页：集合（Library 侧栏）、智能相册（Library 检查器）、保存查询（Gallery 筛选条）；没有 LR 那种统一 Collections/Smart Collections 面板，也没有"交付集合 / 客户端相册"概念。
- 没有交付历史 / 报告中心：报告只有 session_summary（filename/path/status，`ExportService+Report.swift:41-56`）；交付清单 manifest 只在磁盘（`OutputService.swift:95-109`）；`output.run` 虽走 job（`LiveExportAPI.swift:331-370`），但任务行只有状态/进度，未见“回看某次交付内容”的入口。

## 4. 本域最该补的 3 件事

1. **交付发布闭环（A1 + A2，M）**
   理由：这是上轮 P0 的唯一残留面。S3 通道现在"发布成功但客户打不开"，且没有链接、没有发布记录、不能增量——用户仍然要退回 Pixieset/网盘。修法：预签名 URL（或显式公开只读开关）+ 发布记录（远端/photoId/版本）+ HEAD 差分 + 结果区可复制链接 + 发布提到一等入口。验收：不装服务器、用 S3 桶发出一个客户能直接打开的链接，改一张后只重传这一张。
2. **导入一次配置 + 结果完整可见（A4 + B3 + B4，S–M）**
   理由：导入是每天重复且不可逆的一步；现在要重填模板、错 token 静默落盘、失败只看到一条。修法：settings 存导入预设、模板静态校验前置、预检给目标路径/冲突清单、结果给全量失败 + 只重试失败项 + 第二目的地成功数。验收：插卡 → 选预设 → 看 plan → 一键导入 → 结果明确写"新增 N / 跳过 M / 冲突 K / 双份已校验 N"。
3. **物理文件夹树（A5，M；顺手 A6 同批）**
   理由：Bridge 的第一性功能就是"任意文件夹直接看"，LR/PM 也都有 Folders / contact sheet；Gather 目前只能"先建工作区"。补一个只读目录树 + 右键"建工作区 / 摄取"，再顺手把批量重命名接进同一选择集，就能覆盖"按目录找片 + 统一改名"两类真实动作。验收：接一块新盘 → 目录树翻到 DCIM/100CANON → 直接摄取或建工作区，无需先在 Finder 里选。

## 5. 明确不是缺口（ROADMAP 取舍 / 已文档化边界）

- **RAW 编辑 / 完整 DAM 与跨工具目录迁移 / 云同步 / 地图 / 视频 / 移动端 / Windows**：ROADMAP §七不做（`docs/ROADMAP.md:67-73`）。本文只要求"自有格式包迁移完整"，不要求导入 .lrcat/.cos。
- **服务端托管 + 服务端强制口令 / 到期 + 访客账号 / 通知**：97 号 §11 已文档化的边界（`97-post-implementation-review.md:176-182`）；前端口令/到期页已明示"非加密、无服务端强制"。本文只在"客户可访问性 / 链接"上报缺陷，不要求自建托管。
- **虚拟副本 / 版本组**：归 05 号（同文件多套评分的模型缺口），本域不重复。
- **集合 schema parent_id**：命名路径约定已满足可见层级（`docs/README.md:33-35`），数据库层级另行决策，不算残缺。
- **客户反馈必须靠文件回传**：没有服务端就没有上传端点，属边界；selection.json 回路本身完好（`GalleryBuilder.swift:402` + `ExportView+Delivery.swift:108-133`），只要不要求客户端在线评论/实时状态。
- **导入元数据预置 / 批量改拍摄时间**：归 40-metadata-search 的 N1 / Top2，本域不重复计缺口（本文 A4 只涵盖"导入参数"层面）。
- **PM Incremental Ingest 的"记住已拷过"**：全库 SHA-256 去重 + skip 策略已等价覆盖（`SessionIngestRunner.swift:200-226`）；插卡自动摄取 / 摄取后卸载属 P2 便利项，不单列。
- **导出格式只有 original / JPEG / TIFF**：属 05 号 §3.2 的跨域格式取舍，本域只关心交付规格是否闭环（已闭环）。
- **摄取目标必须在工作区 sourcePath 内**：工作区=根目录的模型决定（`SessionIngestRunner.swift:160-167`），不是缺陷；外部备份由第二目的地承担。
- **联系表 / 画廊参数"整体不可调"**：本轮已不成立，只剩纸张/字段的子项（B1/B2），不要按上轮 #6 整条重报。

## 附 证据索引（本次实际读取）

- 文档：`docs/ROADMAP.md`（§七）、`docs/README.md:33-35`（集合层级约定）、`docs/reviews/2026-11-10-competitive-gap/40-ingest-export-organize.md`、`90-wave-ledger.md:7-11,59-65,99-106,153-160,194-201,238-245,347-353`、`96-manual-acceptance.md:117-140,185-251,296-308`、`97-post-implementation-review.md:63-70,105-113,166-183`。
- 协议：`GatherProtocol/Protocol/{Export,Output,ProofShare,Curation,Filter,Jobs}.swift`、`API/{SessionAPI,ExportAPI,AlbumAPI,MaintenanceAPI}.swift`、`API/Inputs/SessionIngestInputs.swift`、`Settings/SettingsKey.swift`。
- 服务：`GatherApplication/Services/Ingest/{IngestService,SessionIngestRunner}.swift`、`Services/Export/{ExportService+Run,ExportService+Report,ContactSheetRenderer,PrintLayout,PrintDocumentRenderer,ExportPostCommandRunner}.swift`、`Services/Output/{OutputService,GalleryBuilder,WebDAVPublisher,S3ShareTransport}.swift`、`Services/Maintenance/LibraryPackageService.swift`、`Services/CurationPath.swift`、`Services/IndexerService.swift`。
- UI：`GatherUI/Culling/{IngestSheet,CullingWorkbenchViewer}.swift`、`GatherUI/Export/{ExportView+Options,ExportView+Delivery,ExportView+Result,ExportView+Range,ExportViewModel+Delivery,ExportViewModel+Report,WebDAVPublishSheet,PrintOptionsSheet}.swift`、`GatherUI/Curation/{CollectionSidebar,CollectionTree,CollectionView}.swift`、`GatherUI/Filtering/FilterRuleEditor.swift`、`GatherUI/Library/LibraryView+Support.swift`、`GatherUI/Gallery/GalleryView+Filters.swift`、`GatherUI/ControlCenter/{MigrationCenterCard,SessionControlView+Toolbox}.swift`、`GatherUI/Shell/RootShellSidebar.swift`、`GatherUI/Settings`。
- 竞品 / 平台：AWS 预签名 `https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html`（本轮 200）；其余沿用上轮 40 号 §2 链接（LR Import / Filename Template / Export / Print / Publish / Web gallery / Merge catalogs / Corrupted catalog；PM Ingest / Rename / Catalog / Re-index；Bridge Batch Rename；Pixieset/Frame.io）。Pixieset 403、C1 帮助中心 403 → 相关细节标 [待核实]。
- 未做：build/test；真机打印、S3/WebDAV 实际发布、迁移导入报告均未实跑（96 号 §3/§7/§8 仍待验）。
