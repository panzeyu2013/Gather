# Adobe Bridge 与专用组织软件横切：功能复核（2026-11-11，基线 50fea319）

> 域：Bridge / Photo Mechanic(Plus) / NeoFinder / Peakto / Excire / Lightroom 的**组织与通用浏览**横切面。上轮分册为 `docs/reviews/2026-11-10-competitive-gap/05-cross-cutting.md`（Lead 自证），并交叉核对 40/10 册本域条目与 `96-manual-acceptance.md` §9。
> 纪律：只读 grep/read；行号以当前工作树（HEAD `50fea319`）为准；未改源码、未跑 build/test、未实机点 GUI。
> 路径简写：`core/` = `desktop/native/gather-core/Sources/`；`app/` = `desktop/native/gather-app/Sources/`；`docs/` = 仓库 `docs/`。`docs/ROADMAP.md:67-73` 为七不做原文。
> 上轮严重度说明：05 册未逐条标级，下表按 `00-synthesis.md` 的合并口径回填（HEIC/PSD=P0；堆栈/自动化/文件夹树=P1；变体=P2）；40/10 册条目沿用原级。与 40 域（元数据/检索）重叠处已标注去重。
> 严重度：P0=功能性坏掉/数据不安全/核心工作流断链；P1=每个工作流撞一次的摩擦或能力缺失；P2=有更好、没有也能用。成本：S≤2 人日 / M≈1 周 / L>2 周。

## 0. 结论速览（8 条）

1. **上轮三条「意图内缺口」已全部闭环**（且有 UI 调用点，不是只有 service）：HEIC/HEIF/PSD 解码、堆栈新建、卷重连。本报告不再把它们当缺口报。
2. **自动化面是「部分闭环」**：从 1 条深链扩到 4 条深链 + 4 个 Shortcuts 动作 + 打包元数据脚本 + 导出后命令钩子；但仍无 CLI / AppleScript 字典 / JS 插件，也**不能用脚本查询照片清单或写评级/决策**（只能导入、导出、写回、查状态）。
3. **格式广度进入第二层缺口**：HEIC/PSD 修好后，解码白名单（22 种 RAW）比**摄取/索引白名单（10 种 RAW）**宽：`.iiq/.3fr/.x3f/.mrw` 等可解码却在「导入文件夹/整卡摄取」时被**静默跳过**；GIF/BMP/AVIF/JP2/PSB 完全不支持。
4. **组织容器仍是「工作区级」**：手动集合与堆栈的 `session_id` 都是 NOT NULL；跨工作区只有规则型「智能相册」，而它又不能限定工作区。Bridge/LR/PM Plus 的 catalog 级集合/堆栈在 Gather 不存在。
5. **保存查询/检索「能用但分裂」**：Gallery 是 17 字段搜索 + 会话级保存查询；Library 是 10 字段搜索 + 全局智能相册 + 规则编辑器。两套表、两套入口、字段与 facet 覆盖面都不一致。
6. **物理面最缺**：无文件夹树（「浏览即读」必须先建工作区）、无导入后批量重命名、无移动/复制/删除（只有淘汰移出 `_rejects`）；「监视文件夹」只是工作区根的 FSEvents 增量重扫，没有自动摄取。
7. **堆栈/虚拟副本**：堆栈只能手动建且只在图库折叠（挑片页不识别）；虚拟副本/版本组仍不存在，而「Gather 只做文件级决策」这一边界至今没有 UI/README 声明。
8. **明确边界**：视频/PDF/AI/EPS、地图、云同步、C1 `.cos`/LR `.lrcat` 解析按 ROADMAP 不做；GPS 编辑/反查地名归 40 域复核，本域只把「坐标范围检索/地点 facet」留作 P2。

### 0.1 竞品能力对照（只列本域，Gather 列均为当前工作树复核结果）

| 能力 | Bridge 14 | PM / PM Plus | NeoFinder / LR | Gather 现状 |
|---|---|---|---|---|
| 文件夹/整卷 catalog（不复制原片） | Content 面板按文件夹浏览（默认入口） | Ingest 后开 contact sheet；Plus 有 Catalog | NeoFinder 拖文件夹/整卷即 catalog（官方页正文）；LR Folders 面板[待核实] | **必须建工作区**；无文件夹树（`RootShellSidebar.swift:27,50,54`） |
| 导入后批量重命名 | 有（官方帮助页存在） | Rename 工具（官方 KB） | NeoFinder 多文件顺序改名（官方页正文） | **无**；仅摄取时模板（`IngestSheet.swift:20,77`） |
| catalog 级集合/集合集 | Collections 面板（免费功能） | PM Plus Collections | LR Collection Set | 手动集合是 **session 级**；全局只有规则型 smart_album |
| 堆栈 / 自动堆叠 | Stack files + HDR/pano 自动堆叠 | contact sheet 分组 | LR 按拍摄时间自动堆叠[待核实] | 手动堆栈（`GalleryStackActions.swift`）；自动堆叠 0 命中 |
| 虚拟副本 / 版本组 | —（不在 Bridge 定位） | — | LR Virtual Copy[待核实] | **无**；文件级决策，未声明 |
| Find / 保存查询 | Search 面板 | PM Plus Catalog 搜索 | LR Smart Collection | Gallery 会话级保存查询 + Library 全局智能相册（两套） |
| 关键词库 / 同义词 / 层级 | Keywords 面板 | Structured Keywords | LR keyword list | **已闭环**：词库/同义词/`lr:hierarchicalSubject`（见 §1） |
| GPS / 地点 | 元数据面板只读 | PM 可套 GPS 轨迹[待核实] | LR Map 模块 | 只读显示；地图按 ROADMAP 不做 |
| 脚本自动化 | JS 启动脚本 + 批处理工作流 | — | LR 插件 SDK / C1 AppleScript[待核实] | 4 深链 + 4 Shortcuts；**无 CLI / AppleScript / 插件** |
| 监视文件夹 / 自动摄取 | Photo Downloader（相机导入） | Auto Ingest（官方 KB） | LR Auto Import[待核实] | **无**；只有工作区根 FSEvents 重扫 |

## 1. 上轮缺口状态核对（05 全部 P0/P1 + 本域相关 40/10 册与 96 §9）

| 上轮编号 | 缺口（一句话） | 上轮严重度 | 当前状态 | 当前证据（路径:行号） | 剩余差 |
|---|---|---|---|---|---|
| 05 §1.1 = 40 #13 | 无物理文件夹树；「浏览即读」必须先建工作区（工作区 = 一个根目录） | P1 | **未闭环** | `app/GatherUI/Shell/RootShellSidebar.swift:27,50,54`（只有工作台/最近工作区/资料库/人物）；`core/GatherProtocol/API/SessionAPI.swift:18-47` 单一 sourcePath（`setSourceRoot` 只修根）；物理维度只剩 `app/GatherUI/Library/LibraryView+Filters.swift:178` 目录前缀过滤 | M：目录树或只读「快速浏览」模式 |
| 05 §1.2 = 40 #20 | 变体（Variant / Virtual Copy）在数据模型上不存在 | P2 | **未闭环** | 全仓 `virtualCopy/versionSet` 0 命中；`photos` 一行 = 一个物理文件（`core/GatherProtocol/Protocol/PhotoFileTypes.swift:17-35` 只表达 RAW/JPEG 折叠）；C1 variant 仅在 30 册写回通道 | 先写清「文件级决策」边界（S），模型另立项（L） |
| 05 §1.3 | 堆栈 API 有 / UI 无（能折叠不能新建） | P1 | **已闭环** | `app/GatherUI/Gallery/GalleryStackActions.swift:34-79`（新建/加入/移出/改名/取消 + 破坏性确认）；入口 `app/GatherUI/Gallery/GalleryGrid.swift:190-192`；VM `GalleryViewModel+Load.swift:90-159`；表 `SchemaCurrent+DDLWorkbench.swift:45-54` | 无（自动堆叠/挑片页识别另计 P2） |
| 05 §1.4 | 卷重连「API 有 / UI 无」（上轮已更正，原判有误） | P1 | **已闭环** | `app/GatherUI/Library/LibraryView+Support.swift:260-315`（离线卷卡 + 重连按钮 + 确认文案）；结果横幅 `app/GatherUI/Library/LibraryView.swift:97-106,134-138`；`LibraryViewModel+Load.swift:161-170` | 无 |
| 05 §2 | 对外自动化只有 `gather://import?file=` 一个入口 | P1 | **部分闭环** | 4 深链 `app/GatherHost/Automation/GatherDeepLinkRoute.swift:15-21`；4 动作 `app/GatherApp/GatherAutomationIntents.swift:20,52,81,106`；打包 `desktop/native/build.sh:611-620` + `scripts/check-appintents.sh`；仍无 CLI/`.sdef`（`core/Package.swift:55-60` 仅开发工具） | 缺「拉」的能力：查询照片、写评级/决策、触发分析 |
| 05 §3.1 | HEIC/HEIF/PSD 能导入、能计数，但解不出缩略图 | P0 | **已闭环** | `core/GatherAnalysis/Image/RAWDecoder.swift:82-96` 白名单 + 合成兜底、`:266-276` 整图兜底；UI 路径 `app/GatherUI/Support/PhotoThumbnailView.swift:558-563` ← `app/GatherHost/AppBootstrap.swift:216` 注册 `RAWImageDecoder` | PSD 只取合成扁平图（已知边界，不算缺口） |
| 05 §3.2 | 输出格式只有 original/jpeg/tiff（无色彩空间/DPI/锐化） | P0（40 #2） | **已闭环（40 域）** | 色彩空间/DPI/输出锐化 Wave1 落地；格式三选一属导出域 | 归 40/导出域，本域不重复 |
| 05 §3.3 | 无视频、无 PDF/AI/EPS/矢量/音频 | — | **非缺口** | `docs/ROADMAP.md:69-70`；`RAWDecoder` 与 `PhotoFileTypes` 全静态图 | 不补；UI/文档写清「仅静态图」即可 |
| 05 §4/§5/§6/§7 | 幻灯片、第二屏、拖放、色彩管理、打印、托管交付、性能门、平台生态 | P0/P1（20/40 域） | **不重复** | 第二屏/打印/交付分享已由 Wave3 收口（20/40 册复核）；性能门 ROADMAP:55-59 未验证；平台边界 ROADMAP:69-73 | 见 20/40 分册 |
| 40 #4 | 导入无预设（结构模板 + 第二目的地 + 去重策略无法存成一套复用） | P1 | **未闭环** | 重复策略三选一 + 预检已补（这是另一件事：`app/GatherUI/Culling/IngestSheet.swift:103-130,168-186`）；预设仍无：模板 `@State`（`:20,77`）、全仓 `ImportPreset/ingestPreset` 0 命中、`SettingsKey` 无 ingest 键 | 导入配置存 settings + 面板回填（S；与 30 号 A4 同一条） |
| 40 #8 = 96 §8 | 集合无层级、无跨工作区集合 | P1 | **部分闭环** | 层级 = 命名路径：`docs/README.md:33-35`、`core/GatherApplication/Services/CurationPath.swift`、`CurationService.swift:163-220`、`app/GatherUI/Curation/CollectionTree.swift`；跨区集合仍缺：`collections.session_id NOT NULL`（`SchemaCurrent+DDLWorkbench.swift:23-30`） | 跨区手动集合（或明确不做）+ 拖拽挂父级 |
| 40 #9 = 96 §9 | 无集合运算/NOT/相对日期 | P1 | **已闭环** | `core/GatherProtocol/Protocol/Filter.swift:348-380`；`AlbumAPI.combineCollections`；编辑入口 `app/GatherUI/Filtering/FilterRuleEditor.swift:190-240` | 无 |
| 40 #14 | 无目录导出/导入/合并（迁移、团队合并） | P1 | **部分闭环（Gather 包）** | 单工作区 `.gatherlib.json` 包 + 三冲突策略：`MigrationCenterCard.swift`、`LibraryPackageService.swift`；但包只带 session/collections/photos（`MaintenanceAPI.swift:259-358`），堆栈/智能相册/保存查询/人物绑定不在包内 | 补齐组织资产段（30 号 A3）；`.lrcat/.cos` 属边界（§5） |
| 40 #16 | 无导入后的批量重命名（只有摄取那一刻能改名） | P1 | **未闭环** | 摄取模板 `app/GatherUI/Culling/IngestSheet.swift:20,77` + `core/.../Ingest/IngestService.swift:20,144,158,466`；全仓 `batchRename/renamePhotos` 0 命中 | M：见 §2 |
| 96 #1 | App Intents 发现性（SwiftPM 不生成元数据） | 已知 | **已闭环** | `desktop/native/build.sh:611-620` 调用 `scripts/build-appintents-metadata.sh`；`scripts/check-appintents.sh`（4 intent 缺一 exit 1） | 需真实 `.app`（build.sh） |
| 96 #9/#10/#11 | NOT/集合/相对日期编辑入口、模板侧变量、导出后钩子 | 已知 | **已闭环** | `FilterRuleEditor.swift:190-240`；`MetadataTemplateVariables.swift`（10 域复核）；`SettingsKey.swift:96-97` + `Services/Export/ExportPostCommandRunner.swift` | #11 仅整套交付路径（已知边界） |
| 10 册 关键词库/同义词 | 无关键词库/受控词表/同义词语义 | P1 | **已闭环** | 协议 `MetadataAPI.swift:100-118`；UI `KeywordLibrarySheet.swift:57,204-262`（树/新建/改名/合并/同义词/级联删除）；表 `SchemaCurrent+DDLWorkbench.swift:71-87`；XMP `KeywordPath.swift:120-159`、`SidecarXMPProvider+Patching.swift:124-150` | 词表导入导出/同义词进检索归 40 域 |
| 10 册 检索覆盖 | 检索只覆盖 11/32、搜索串 5 字段 | P1 | **已闭环** | `jsonFields` 31 项（`PhotoFilterQuery.swift:73-107`）；Gallery 搜索 17 字段（`GalleryViewModel+Filters.swift:79-89`）；规则目录 49 项（`FilterRuleEditor.swift:41-96`） | Library 与 Gallery 口径未统一（见 §2） |
| 10 册 GPS | GPS 只读、无反向地理编码 | P1 | **归 40 域** | 本域只确认：读 `ImageMetadataProviders.swift:32-65,99`、显示 `MetadataDisplayRows.swift:57-60`、查询列 `PhotoFilterQuery.swift:65-69`；无 MapKit（grep 0） | 地图按 ROADMAP 不做；编辑/反查见 40 册 |

> 判定口径：所有「已闭环」都要求 UI 调用点（菜单/按钮/视图）存在；仅 service/API 存在不算。上表现状 = 上轮条文在 HEAD 50fea319 的真实状态。
> 与 40 域去重：GPS 编辑/反查、关键词词表导入导出、同义词进检索、拍摄时间改写、导入元数据预置已由 `40-metadata-search.md` 覆盖，本报告只在「组织语义」层面引用，不重复计缺口。
> 05 的 P2 条目（变体/导出三选一/幻灯片/拖放等）已按 40/20 域归并、或列入 §5 边界，不逐条展开。
> 与 30 号（摄取/导出/交付）重叠三条：物理文件夹树、导入后批量重命名、导入预设——两文均判未闭环；这三条以 30 号的取证为主线，本报告补的是 Bridge/NeoFinder 组织视角与「格式链/自动化/监视目录/检索分裂」四条独有发现。

### 1.1 三条「已闭环」的 UI 证据（防 API 有/UI 无的旧病复发）

- **堆栈**：`GalleryGrid.swift:190-192` 的右键菜单 + `GalleryStackActions.swift:73-80` 的选择栏「堆栈」菜单 → `GalleryViewModel+Load.swift:90-159` 的 create/add/remove/rename/dissolve 命令；不是只有 `AlbumAPI`。
- **卷重连**：`LibraryView+Support.swift:260-315` 的「重新关联此目录」按钮 + 确认 sheet，结果经 `LibraryView.swift:97-106,134-138` 的横幅显示 N 个/0 个；`assetAPI.relinkRoot` 由 `LiveLibraryDataProvider.swift:105-142` 接到 UI 端口。
- **HEIC/PSD**：`PhotoThumbnailView.swift:558-563`（网格/查看器解码）→ `ImageDecodingRegistry`（`ImageDecoderPort.swift:68`）→ `RAWImageDecoder`（`AppBootstrap.swift:216` 注册）→ `RAWDecoder` 白名单兜底；不是只改了 Analysis 层。


## 2. 剩余缺口表（上轮未闭环 + 新发现；已与 30/40 域交叉标注）

| 级别 | 缺口 | 竞品做法 + 链接 | Gather 证据 | 成本 | 修法一句话 |
|---|---|---|---|---|---|
| P1 | **RAW 导入/索引白名单落后解码白名单**：`.iiq/.3fr/.x3f/.mrw` 等 12 种可解码，但目录扫描/整卡摄取直接跳过且无提示 | C1 用户的 Phase One `.iiq`、Hasselblad `.3fr`；NeoFinder 官方明确列出对 Nikon/Canon/Leica/Leaf/Hasselblad/Phase One 等支持，并可拖文件夹或整卷 catalog：[NeoFinder Photo Organizer](https://www.cdfinder.de/photo-organizer.html) | `RAWDecoder.swift:82-90`（22 RAW）vs `IndexerService.swift:66-70`、`IngestService.swift:338-341`（10 RAW）；静默 `IngestService.swift:383`、`IndexerService+Scan.swift:415` | S | 三处收敛到 `PhotoFileTypes` 单一白名单 + 摄取/扫描报告「不支持的扩展名 N 个」 |
| P1 | **无物理文件夹树 / 不建工作区不能浏览**（05 §1.1） | Bridge 以文件夹（Content）为默认入口（[Sort and filter files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/sort-and-filter-files-and-folders.html)）；NeoFinder 拖入文件夹/整卷即 catalog（同上）；LR Folders 面板[待核实] | `RootShellSidebar.swift:27,50,54`；`SessionAPI.swift:18-47`；物理维度只有目录前缀过滤（`LibraryView+Filters.swift:178`） | M | 只读「查看文件夹」模式（读文件树 + 直读缩略图，不落库） |
| P1 | **导入后批量重命名缺失**（40 #16） | Bridge [Batch rename files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/batch-rename-files.html)；NeoFinder「rename multiple files at once in sequence」（同上）；PM [Rename Photos 工具](https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool) | 仅摄取时模板；全仓无批量改名入口（grep 0） | M | 选中所选→模板→磁盘改名 + 更新 `photos.filepath`/sidecar/XMP + 发领域事件 |
| P1 | **自动化面第二层缺失**（05 §2）：只能被脚本「推」，不能被脚本「用」 | Bridge 有 JS 启动脚本与批处理工作流（[Startup Script 排障页](https://helpx.adobe.com/bridge/desktop/troubleshoot/startup-script-not-found.html)、[Create workflows](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/create-workflows.html)）；LR 插件 SDK、C1 AppleScript[待核实] | 4 深链 + 4 intents（见 §1）；无 `.sdef`（`find *.sdef` 0）；无用户 CLI（`core/Package.swift:55-60`）；自动化写回只到「整工作区」粒度 | M–L | 先开放「查询照片/设置 rating·keep/触发分析」三类只读+写命令，再谈插件 SDK |
| P2 | **常见位图/交付格式缺口**：GIF/BMP/AVIF/JP2/PSB 不在任何白名单，导入时静默丢弃 | Bridge 定位「preview, organize ... multiple creative assets」（[产品页](https://www.adobe.com/products/bridge.html)），帮助目录含动态媒体预览页；具体格式清单[待核实] | `RAWDecoder.swift:82-90` 白名单外直接 `unsupportedExtension`；摄取/索引同样静默 | S | 用 UTType 驱动（ImageIO 能解就收），或至少输出「跳过 N 个不支持格式」 |
| P2 | **无监视文件夹/自动摄取/相机导入**：只有工作区根的 FSEvents 增量重扫 | Bridge [Import photos from camera（Photo Downloader）](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/import-photos.html)；PM Auto Ingest（[Camera Bits Ingest KB](https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos)，40 册正文核实）；LR Auto Import[待核实] | `SessionDirectoryMonitor.swift:2-6,213-216`；仅持久化 `SettingsKey.swift:80 watch.lastEventIDs`；无配置/无状态 UI | M | 可配置「监视目录→目标工作区 + 模板 + 第二目的地」，或先暴露监听状态与失败原因 |
| P2 | **跨工作区手动集合缺失；智能相册不能限定工作区** | LR Collections/Collection Set 是 catalog 级（[Lightroom Queen](https://www.lightroomqueen.com/create-collections/)）；PM Plus Collections（[KB](https://docs.camerabits.com/support/solutions/articles/48001078321-collections-in-photo-mechanic-plus)） | `collections.session_id NOT NULL`（`SchemaCurrent+DDLWorkbench.swift:23-30`）；`smart_albums` 无 session 且 criteria 不含会话过滤（`LibraryViewModel.swift:79-130`、`LibraryViewModel+Load.swift:57-70`） | M | `collections.session_id` 可空 + Library 建集合入口；或明确「跨区只用智能相册」 |
| P2 | **堆栈只能手动、只在图库折叠** | Bridge [Stack files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/stack-files.html)、[Stack HDR and panoramic images](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/automatically-stack-hdr-and-panoramic-images.html)；LR 按拍摄时间自动堆叠[待核实] | 手动菜单 `GalleryStackActions.swift:34-79`；挑片页 stack 引用 0（grep）；`autoStack` 0 命中 | S–M | 「按拍摄间隔/包围曝光自动堆栈」+ 挑片页显示堆栈折叠 |
| P2 | **虚拟副本/版本组不存在，且「文件级决策」边界未声明**（05 §1.2） | LR Virtual Copy、C1 Variants[待核实] | 全仓 0；C1 变体只作为写回目标（30 册）；无 README/UI 明示 | 文案 S；模型 L | 先写清「Gather 文件级决策，变体归 C1」，模型另立项 |
| P2 | **保存查询/检索口径分裂**：Gallery 会话级 17 字段 vs Library 全局 10 字段；两套表/两套入口；`suggestions` API 无 UI；Library 占位仍写「搜索文件名」 | Bridge [Search files and folders](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/search-for-files-and-folders.html)；LR Smart Collection（[帮助](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/smart-collections-criteria-in-lightroom-classic.html)） | `saved_searches`（`DDLWorkbench.swift:11-19`）vs `smart_albums`（`DDLDomain.swift:200-211`）；字段 `GalleryViewModel+Filters.swift:79-89` vs `LibraryViewModel.swift:86-102`；facets 6 vs 7（`:121-123` vs `:318`）；`PhotoAPI.swift:35-36` + `LivePhotoAPI.swift:310` 无 UI；占位 `LibraryView+Filters.swift:43-48` | S–M | 统一字段/facet 表；保存查询加「全局/本会话」；接 suggestions；修占位文案 |
| P2 | **摄取预设不持久**（重命名模板/重复策略每次重填） | PM Ingest 模板与增量摄取（同上 KB）；LR Import Preset（[官方导入选项](https://helpx.adobe.com/lightroom-classic/desktop/import-photos/photo-video-import-options.html)，细节[待核实]） | `IngestSheet.swift:20,77` @State；`SettingsKey` 无 ingest 键 | S | 三件套存 settings + 摄取面板回填 |
| P2 | **无通用外部编辑器移交** | Bridge [Open files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/open-files.html)（Camera Raw/Photoshop/默认应用） | 只有 C1：`CullingSyncControls.swift:36`；其余是 Finder 显示（`GalleryGrid.swift:195-199` 等） | S | 加「用…打开」（记忆每类格式的应用） |
| P2 | **文件级移动/复制/删除入口缺失** | Bridge [Copy, move, and delete files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/cut-copy-and-move-files-and-folders.html) | 只有淘汰移出 `_rejects`：`core/.../Services/FileOps/RejectedMover.swift:1-10`；无移动/复制/删除 API | S–M | 先做「移动所选到文件夹」（复用 relocate 事务），删除保持不做 |

> 级别分布：P1×4（格式链、文件夹树、批量重命名、自动化第二层），P2×9（另有 3 条 P2 观察归入 §3 入口深/半成品，不重复计）。没有 P0：上轮 P0 已修完，本轮新发现的「静默跳过」按 P1 处理（不丢数据、非破坏，但会让人以为软件坏了）。

## 3. 新发现（上轮未列 / Wave2–3 半成品）

**N1 修复后的白名单漂移（Wave1 P0-8 只补了解码侧）**：P0-8 在 `RAWDecoder.swift:82-90` 补了 `.heic/.heif/.psd`，但没有同步 `IndexerService.swift:66-70` 与 `IngestService.swift:338-341` 的 RAW 清单——三张表本来就不一致，现在「能解 but 不能进」的差集更大。用户表现是「卡里 800 张，只进来 760 张，没有任何提示」。这是实现缺口，不是取舍。

**N2 集合层级是命名约定（Wave2/3 半成品）**：`docs/README.md:33-35` 自认「不是数据库父子关系」；侧栏树由 `CollectionTree.swift` 从 `A/B/C` 名字组装，改父级只能走「重命名/移动…」sheet（`CollectionSidebar.swift:586-593`），没有拖拽改父级；`CurationPath` 有段长 80/总长 200 的硬限制。对 40 个工作区、上百集合的库，名字即结构会带来「改一个父名=批量迁移」与「冲突只能改名解决」两个长期问题。

**N3 两套「保存容器」同构不同源**：`saved_searches`（`DDLWorkbench.swift:11-19`，session 可空）与 `smart_albums`（`DDLDomain.swift:200-211`，全局）都存 `FilterGroup` JSON，但 Gallery 只读写前者（且 UI 固定传 `sessionId`，`GalleryViewModel+Filters.swift:192-208`），Library 只读写后者；两边互不可见、不可互转。用户「在 Gallery 存了一个筛选，到资料库找不到」是必然的。

**N4 Wave3 自动化是「命令面」不是「查询面」**：4 个 intent 的参数全是 `String`（工作区 ID 要用户手填，无选择器/无「当前选中」），动作只有新建/导出/写回/查状态（`GatherAutomationIntents.swift:20,52,81,106`）；深链只有 open/import（`GatherDeepLinkRoute.swift:15-21`）；导出后钩子只挂整套交付（`SettingsKey.swift:96-97`）。Bridge 的脚本可以遍历目录、写元数据、跑批处理——Gather 目前做不到。

**N5 迁移中心半成品**：`MigrationCenterCard` 只做「Gather 库包」与「XMP 三字段（rating/label/keyword）」；库包导入不触发重索引（90 ledger「遗留（Wave 3 第二批）」第 8 条）；不读 LR `.lrcat`/C1 `.cos`（边界）。入口在控制中心「分析与索引」卡片（深）。

**N6 目录监视「有实现无界面」**：`SessionDirectoryMonitor.swift:2-6` 明确「外部改动 → 增量 metadata.scan」，扫描 dedupeKey 带 `:watch`（`:213-216`）；失败退避、停止、事件 id 只进日志与 `watch.lastEventIDs`（`SettingsKey.swift:80`）。用户无法知道「为什么我拖进去的照片没出现」，也无法主动暂停/限定目录。

**N7 搜索补全 API 有 / UI 无 + 无 ⌘F Find 面板**：`PhotoAPI.suggestions`（`PhotoAPI.swift:35-36`）与 Host 实现（`LivePhotoAPI.swift:310-312`）在 GatherUI 内 **0 调用**（与 preload/堆栈的历史教训同类）；Bridge/PM 有独立 Find 面板与字段补全，Gather 只有页面内搜索框，没有全局查找入口或 ⌘F。

**N8 三个组织入口都深**：智能相册在「资料库 → 右侧 inspector → 资料库卡」（`LibraryView+Support.swift:39-67`）；保存查询在 Gallery 搜索框右侧菜单（`GalleryView+Filters.swift:59-92`）；关键词库在「挑片 → 关键词面板 → 词库…」sheet（`CullingKeywordPanel.swift:153`）。没有侧栏/一级面板入口——Bridge 的 Collections/Keywords 都是常驻面板。

**N9 堆栈不在挑片页生效**：`GatherUI/Culling/` 下 stack 相关引用 0（grep）；折叠索引只在 Gallery（`GalleryViewModel+Stacks.swift`、`GalleryViewModel+Load.swift:36-43`）。Bridge/LR 的堆栈是全视图折叠，Gather 用户在图库折好堆栈后进挑片页会重新看到全部成员。

**N10 摄取模板 @State 不持久**：`IngestSheet.swift:20` 每次打开回落默认 `{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}`；与 40 #4「导入预设」同源，工程上只需 settings 键 + 回填，却是「每卡一次」的摩擦。

## 4. 本域最该补的 3 件事（排序 + 理由 + 成本）

**1）统一「可解码 = 可导入 = 可索引」白名单 + 失败可见（S，≤2 人日）**
理由：这是当前唯一会让用户「以为丢图」的缺口，且 `.iiq/.3fr` 正好命中 C1/Phase One 用户（Gather 的最近邻用户群）。修法只动一张表 + 两处报告，风险极低；先在摄取/扫描结果里加「不支持格式 N 个（按扩展名分组）」，再逐步把 ImageIO 能解的格式并入。验收：目录含 `.iiq`+`.3fr`+`.gif` 时，导入张数与「跳过」明细一致且可展开。

**2）物理文件夹树 / 只读「浏览即读」模式（M，约 1 周）**
理由：Bridge/NeoFinder/LR 的默认入口是文件夹；Gather 的「先建工作区」是一个建模动作，插卡先翻一遍、核对 C1 目录结构都得多一步。只读模式可以不落库、不建工作区（复用 `RAWDecoder` + 现有缩略图缓存），与「窄而深决策层」定位不冲突。验收：不建工作区，选中一个目录即可网格浏览/全屏/查看 EXIF，且不产生库行。

**3）导入后批量重命名（M，约 1 周）**
理由：Bridge/PM/NeoFinder 三个参照系都有；摄影工作流里「客户改命名规范/统一后缀」每个项目至少撞一次，现在只能 Finder 改完再重扫（库内路径断链）。复用 `IngestRenameTemplate` + `RejectedMover` 的 relocate 事务（同事务改 `photos.filepath`/sidecar/XMP 绑定）就能落地。验收：选 100 张 → 模板 → 磁盘改名，库内路径、sidecar、XMP 绑定一致，`_rejects` 与已写回标记不丢。

> 第 4 件（不列 Top3 但建议排进下一波）：自动化第二层——先给「查询照片（按工作区/评分/关键词返回 ID）+ 写 rating/keep」两条只读/写命令（URL scheme + Shortcuts 即可），Bridge 用户迁移过来时「脚本可编程」这一条才有对标物。成本 M–L。

### 4.1 建议的真机/手工验收点（自动化测不到）

- **格式链**：一个目录放 `.nef/.cr3/.iiq/.3fr/.gif` 各 1 张 → 走「导入文件夹」与「整卡摄取」两条入口，报告里的「已登记/跳过」之和应等于文件数，且跳过可按扩展名展开；不支持的格式不得静默消失。
- **文件夹浏览**：不建工作区，菜单「导入文件夹」改为「浏览文件夹」入口（若第 2 件落地）→ 网格出现原目录文件名与缩略图，退出后库内 sessions 数不变。
- **批量重命名**：100 张带 RAW+JPEG 配对 + 1 个 sidecar → 模板改名后，图库路径、配对数、XMP 绑定、已写回状态与 `_rejects` 记录均保持；中途拔盘应给出失败项而不是静默部分成功。
- **监视目录**：在 Finder 往工作区根拖 3 张新图 → 不重启应用，图库在 10 秒内出现这 3 张（当前逻辑应成立，但无状态提示）；再模拟 FSEvents 启动失败（只读挂载/权限），应能在 UI 看到「监听不可用」。

## 5. 明确不是缺口（ROADMAP 取舍 / 本域边界，防误报）

- **视频 / PDF / AI / EPS / 音频、混装素材目录**：`docs/ROADMAP.md:69-70` 七不做；Bridge 的「通用资产浏览」优势不在 Gather 目标里。建议 UI/README 明示「仅静态图」。
- **地图 / 移动端**：`docs/ROADMAP.md:69` 短期不做；GPS 数据已读、已在检查器显示，本域只把「坐标范围检索/地点 facet」留 P2，不要求地图。
- **云同步 / 多人共享目录 / 实时协作**：`docs/ROADMAP.md:71`；PM Plus 的共享 catalog、Peakto 的跨目录聚合都不追，团队协作只保留「库包导出/导入」最小形态。
- **RAW 显影 / 图层 / Camera Raw 参数**：Gather 定位是 C1 下游决策层，不做显影；Bridge 的「Open in Camera Raw」不构成缺口。
- **解析 C1 `.cos` / LR `.lrcat`**：05/40 已立边界，Wave3 迁移中心只做 Gather 包 + XMP；Peakto 式「聚合多个编辑器目录」不在路线内。
- **集合层级 schema 化（`parent_id`）**：`docs/README.md:33-35` 已把命名路径写成产品决策；真正迁移需 `user_version` 决策，属「已知取舍」而不是本轮新缺陷。
- **虚拟副本「不建」本身可接受**（C1 上游有 Variants），缺的是「文件级决策」没有在 UI/README 写清；这条只在 §2 以 P2 文案级保留。
- **第二屏 / 打印 / 交付分享 / 精修预览**：Wave3 已由 20/40 域闭环，本域不重复报；性能门（2 万/10 万）是实测门不在此报告判定。

## 附 证据索引（本次实际 read/grep 的文件与竞品链接）

**Gather 代码（已读/已 grep）**
- 格式与解码：`core/GatherAnalysis/Image/RAWDecoder.swift`、`core/GatherProtocol/Protocol/PhotoFileTypes.swift`、`core/GatherApplication/Services/IndexerService.swift`、`core/GatherApplication/Services/Indexer/IndexerService+Scan.swift`、`core/GatherApplication/Services/Ingest/IngestService.swift`、`app/GatherHost/RAWImageDecoder.swift`、`app/GatherUI/Support/PhotoThumbnailView.swift`。
- 组织容器：`core/GatherProtocol/API/AlbumAPI.swift`、`core/GatherProtocol/Protocol/Filter.swift`、`core/GatherPersistence/Database/Schema/SchemaCurrent+DDLWorkbench.swift`、`SchemaCurrent+DDLDomain.swift`、`app/GatherUI/Curation/CollectionSidebar.swift`、`CollectionTree.swift`、`app/GatherUI/Gallery/GalleryStackActions.swift`、`GalleryGrid.swift`、`GalleryViewModel+Load.swift`、`GalleryViewModel+Stacks.swift`、`GalleryView+Filters.swift`、`GalleryViewModel+Filters.swift`。
- 资料库/检索：`app/GatherUI/Library/LibraryView+Filters.swift`、`LibraryView+Support.swift`、`LibraryView.swift`、`LibraryViewModel.swift`、`LibraryViewModel+Load.swift`、`LibraryViewModel+Filter.swift`、`app/GatherUI/Filtering/FilterRuleEditor.swift`、`core/GatherPersistence/Database/Queries/PhotoFilterQuery.swift`、`core/GatherProtocol/API/PhotoAPI.swift`、`app/GatherHost/APIs/LivePhotoAPI.swift`。
- 自动化：`app/GatherHost/Automation/GatherDeepLinkRoute.swift`、`GatherAutomationRuntime.swift`、`app/GatherApp/GatherAutomationIntents.swift`、`app/GatherHost/GatherAppDelegate.swift`、`app/GatherHost/AppBootstrap.swift`、`desktop/native/build.sh`、`core/Package.swift`、`app/GatherUI/Support/Info.plist`、`scripts/build-appintents-metadata.sh`、`scripts/check-appintents.sh`。
- 监视/迁移/物理面：`app/GatherHost/SessionDirectoryMonitor.swift`、`core/GatherApplication/Services/Ingest/DirectoryWatcher.swift`、`app/GatherHost/SessionWorkspaceFactory.swift`、`app/GatherUI/ControlCenter/MigrationCenterCard.swift`、`core/GatherApplication/Services/FileOps/RejectedMover.swift`、`app/GatherUI/Culling/IngestSheet.swift`。
- 关键词/GPS：`core/GatherProtocol/API/MetadataAPI.swift`、`core/GatherProtocol/Protocol/KeywordPath.swift`、`core/GatherApplication/Services/Keyword/KeywordLibraryService.swift`、`core/GatherPersistence/Database/Repositories/SavedSearchRepo.swift`、`core/GatherMetadataIO/SidecarXMPProvider+Patching.swift`、`app/GatherUI/Metadata/KeywordLibrarySheet.swift`、`app/GatherUI/Metadata/MetadataDisplayRows.swift`、`core/GatherAnalysis/Image/ImageMetadataProviders.swift`、`core/GatherProtocol/Settings/SettingsKey.swift`。
- 文档：`docs/ROADMAP.md`、`docs/README.md`、`docs/reviews/2026-11-10-competitive-gap/05-cross-cutting.md`、`40-ingest-export-organize.md`、`90-wave-ledger.md`、`96-manual-acceptance.md`、`97-post-implementation-review.md`、`00-synthesis.md`。

**竞品（本轮 web_fetch 核实标题/存在性；正文 JS 渲染处只到标题级）**
- Adobe Bridge 14.0（本机已装）：[Sort and filter files and folders](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/sort-and-filter-files-and-folders.html)、[Batch rename files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/batch-rename-files.html)、[Search files and folders](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/search-for-files-and-folders.html)、[Stack files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/stack-files.html)、[Stack HDR and panoramic images](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/automatically-stack-hdr-and-panoramic-images.html)、[Open files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/open-files.html)、[Copy, move, and delete files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/cut-copy-and-move-files-and-folders.html)、[Import photos from camera](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/import-photos.html)、[Preview images and edit capture time](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/preview-images-and-edit-capture-time.html)、[Create workflows](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/create-workflows.html)、[Use keywords](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/use-keywords.html)、[Startup Script 排障页](https://helpx.adobe.com/bridge/desktop/troubleshoot/startup-script-not-found.html)。
- NeoFinder：官方 photo organizer 页正文（拖文件夹/整卷即 catalog、多文件重命名、GPS、支持 Phase One/Hasselblad/Leaf）：<https://www.cdfinder.de/photo-organizer.html>。
- Photo Mechanic：Ingest（Auto Ingest/增量/模板）<https://docs.camerabits.com/support/solutions/articles/48000207409-ingesting-photos>；Rename 工具 <https://docs.camerabits.com/support/solutions/articles/48001141415--rename-photos-tool>；PM Plus Catalog/Collections <https://docs.camerabits.com/support/solutions/articles/48001078324-introduction-to-catalogs-in-photo-mechanic-plus>、<https://docs.camerabits.com/support/solutions/articles/48001078321-collections-in-photo-mechanic-plus>（正文为 JS 壳，细节以 40 册核实为准）。
- Lightroom Classic：[Import 选项](https://helpx.adobe.com/lightroom-classic/desktop/import-photos/photo-video-import-options.html)、[Collections](https://www.lightroomqueen.com/create-collections/)、[Smart Collections](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/smart-collections-criteria-in-lightroom-classic.html)、Virtual Copy/Auto Import/Auto Stack 细节[待核实]。
- Peakto / Excire：产品页存在（<https://cyme.io/peakto/>、<https://excire.com/en/>），跨目录聚合/AI 组织细节为 JS 渲染 → 全部[待核实]，不作为缺口依据。


**本轮重核但未改判的旧结论**
- 05 §1.4 原判「卷重连 API 有/UI 无」是漏看 Host provider 层的历史误判；本轮确认能力与可见性都在，只保留「离线卷卡在右侧 inspector」这一入口深度观察（P2 已在 N8 归入入口深，不单列）。
- 05 §1.3 堆栈「API 有/UI 无」已按 Wave1 修复；本轮只追加「自动堆叠/挑片页识别」两个**新增**缺口，不再把「堆栈建不了」计为缺口。
- 上轮 `96 §9` 的 12 条中，落在本域的 #1/#8/#9/#10/#11 已逐条核对：除 #8（集合层级 schema）留部分外，其余均闭环；#8 在 `docs/README.md:33-35` 已被写成产品决策，不再作为新缺陷重复计。

**本轮限制**：未 `swift build` / 未跑测试 / 未实机点 GUI；`web_search` 本机 401（未重试）；Adobe Help 正文为 JS 渲染，只核实到页面标题与目录；凡标 [待核实] 者不用于下缺口结论。