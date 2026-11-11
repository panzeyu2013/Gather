# 元数据 / IPTC / 关键词 / 标注 —— 竞品缺口评审

> 评审对象：Gather（macOS Swift/SwiftUI，面向 Capture One 的本地优先挑片/目录协作工具）。
> 评审范围：元数据读写、IPTC 字段与模板、层级关键词/词库、评分与色标的 XMP 映射、元数据检索、批量编辑与冲突呈现、模板分发。
> 证据口径：Gather 现状一律落到仓库代码（`相对路径:行号`）；竞品现状用 `web_fetch` 直连厂商页/标准页核实并给链接。
> 抓取限制（影响结论强度）：本机 `web_search` 端点 401，只能直连 URL；Capture One 帮助中心被 Cloudflare 403；Adobe Help 正文在 100KB 抓取上限之外，只能取到页面标题与 `meta description`；Camera Bits 文档站为 JS 壳站。凡未读到正文的细节一律标 **[待核实]**，不凭印象补版本细节。
> 不在本域：挑片浏览/对比（见 `20-culling-browse.md`）、C1 桥接协议（见 `30-c1-bridge.md`）、导出/交付（见 pipeline 域）。本域只在与元数据直接相关处交叉引用。

## 0. 结论速览

- **Gather 已经是一条合格的"元数据写入端"**：32 个 IPTC Core/Extension 字段、联系人 8 成员、XMP+IPTC-IIM 双写、JPEG 内嵌写回、三态字段语义、模板 preview→apply→undo、交付队列 + 冲突裁决 + 同步生命周期，都有代码与 UI 闭环。
- **但它不是"元数据工作台"**：关键词库只是数据库里的半成品、模板不能导入导出、没有变量/代码替换、GPS 只读、批量编辑只能绕模板、检索只覆盖 11/32 个描述性字段。
- 用户最容易被竞品对比打穿的三个场景：**每次新客户/新场地要重建词表（Lr/Bridge 的 keyword list+synonyms 是现成的）**；**给一批图批量填 {client}/{序号}/版权年（PM 的变量与 Code Replacement 是现成的）**；**从 32 个字段里反查（Bridge Find / Lr Metadata Filters 是现成的）**。
- 严重度分布：本域没有 P0（基础写入可用），有 8 条 P1、若干 P2。理由见 §3。

## 1. Gather 该域已实现能力（清单 + 代码证据）

### 1.1 字段模型与三态语义

- 32 个描述性字段（IPTC Core + Extension）+ 8 个联系人成员：`desktop/native/gather-core/Sources/GatherProtocol/Protocol/DescriptiveMetadata.swift:24-33`（字段枚举）、`:143-176`（XMP 限定名/形状表，顺序即 UI 展示顺序）、`:68-103`（`CreatorContactInfo` 8 成员）。
- 三态语义是模板与批量的基石：**nil = 不触碰；空串/空数组 = 显式清空；有值 = 写入**（`DescriptiveMetadata.swift:212-217` 注释；`:351-403` `set`；`:431-441` `clear`；`:406-422` 模板合并 `applying`）。
- 值形状覆盖 `text/alt/bag/seq/structure` 五种（`DescriptiveMetadata.swift:15-21`），读侧按表驱动收集（`GatherMetadataIO/IPTCXMLDelegate` 与 `DescriptiveMetadata.swift:178-186` 的 `byField`）。

### 1.2 写盘内核（XMP sidecar + JPEG 内嵌 + IPTC-IIM）

- **sidecar**：补丁器 insert-or-replace、保留未知命名空间、命名空间补声明、写后重读校验、原子写、大小写路径回退（`GatherMetadataIO/SidecarXMPProvider.swift:1-21` 契约注释、`:159-191` 写入、`:186-191` 写后校验、`:239-250` 大小写回退）。
- **JPEG 内嵌**：XMP（APP1）+ IPTC-IIM（APP13/0x0404）双写，scan 逐字节不动（`GatherMetadataIO/JPEGMetadataWriter.swift:1-12,119-124`；IIM 映射 `GatherMetadataIO/IPTCIIM.swift:164-210`，只写 IIM 真实存在的 dataset，XMP-only 字段不编造 dataset 号 `:160-163`）。
- **写目标策略**：RAW 一律 sidecar；JPEG 有 sidecar 就用 sidecar，否则 auto/embedded 写内嵌；RAW+JPEG 同资产时 JPEG 兄弟跟随 sidecar（`GatherProtocol/Protocol/MetadataTarget.swift:28-43`；`GatherMetadataIO/MetadataWriteRouter.swift:48-66,56-61`）。
- **读侧合成**：sidecar 覆盖内嵌、逐字段合并（`GatherMetadataIO/MetadataWriteRouter.swift:216-248`；`GatherProtocol/Protocol/MetadataAttributes.swift:18-58` 合并、`:61-107` 内嵌解析含 rating 回退、`:109-170` 内嵌 IPTC 字段表）。
- 编辑初值必须读盘、读不到就禁用保存（fail-closed），只提交改过的字段，空白 = 显式清空（`gather-app/Sources/GatherUI/Metadata/MetadataEditorSheet.swift:32-41,170-197`；`Metadata/MetadataEditorDraft.swift:33-70`）。
- 一个已文档化的内嵌限制：JPEG 已有 sidecar 时只改 sidecar，**Bridge/C1 写进 APP13 的旧 IPTC 清不掉**，会明确报 `JPEG_EMBEDDED_CLEAR_UNSUPPORTED`（`GatherApplication/Services/Metadata/MetadataAttributeWriter.swift:325-397`；编辑器文案 `MetadataEditorSheet.swift:39-41`）。

### 1.3 面板、模板、批次与生命周期

- 只读元数据面板：EXIF + IPTC Core（22）+ IPTC Extension（10）+ 文件/写入目标，三处 inspector 共用（`Metadata/MetadataSections.swift:20-52,55-64`；GPS 只读展示 `Metadata/MetadataDisplayRows.swift:50-60`）。
- 单张编辑器：32 字段 + 联系人 8 成员，`applyDescriptive`（批次 id = `inline`）提交、失败留在面板并重新读盘（`Metadata/MetadataEditorSheet.swift:35-56,103-122,199-237`；协议入口 `GatherProtocol/API/MetadataAPI.swift:50-58`）。
  - **注意**：`MetadataInlineApplyInput` 本身支持 `photoIds` 数组（`MetadataAPI.swift:52`），但 UI 只传 `[photoId]`（`MetadataEditorSheet.swift:209-213`）→ **API 有 / UI 无（批量直改）**。
- 模板：从当前照片存模板、命名/删除、从模板编辑字段与「清空」标记（`Metadata/MetadataTemplateSheet.swift:222-250`；`Metadata/MetadataTemplateFieldsSheet.swift:1-90`）；预览（逐字段 write/clear/conflict）→ 应用 → 撤销（`Metadata/MetadataTemplateSheet.swift:269-323`；`GatherApplication/Services/Metadata/MetadataTemplatePlanner.swift:11-112`；`MetadataTemplatePreview.swift:10-36`；`MetadataTemplateService.swift:141-160,305`）。
  - 预检数据结构里有**逐照片逐字段明细** `MetadataPhotoImpact.fields`（`MetadataTemplatePlanner.swift:23-64`），UI 只渲染三个合计数字（`MetadataTemplateSheet.swift:92-111`）→ **DTO 有明细 / UI 无**。
- 批次与撤销：模板/内联/triage 写回都记批次，`recentBatches(limit: 20)` + 按批撤销（`MetadataAPI.swift:58-61`；`Metadata/MetadataBatchSheet.swift:93-100,114-142`；`GatherApplication/Services/Metadata/MetadataApplyBatchStore.swift:55-117`）。
- 冲突/孤儿：`conflicts/resolveConflict/orphans/resolveOrphan` 协议（`MetadataAPI.swift:26-29`）→ `MetadataDispositionService.swift:42-118` → 挑片冲突面板 `GatherUI/Culling/CullingConflictPanel.swift:117-129`（**已接线**，不是 API 有/UI 无）。
- 生命周期：`syncState/confirmSync/finalizeSync/cleanupRetention`（`MetadataAPI.swift:74-92`）→ `MetadataDeliveryService.swift:132-257` → 「同步与备份」状态条（`Metadata/MetadataSyncBar.swift:1-14,40-80,155-170`）；C1 未重载时保留备份、reload-ack 门禁在交付确认侧（`Protocol/MetadataDelivery.swift:38`；`MetadataAPI.swift:83,133`）。

### 1.4 关键词体系（层级已通、词库半成品）

- 层级路径 `A|B|C`（Lightroom 序列化）：`GatherProtocol/Protocol/KeywordPath.swift:11-66`；编解码 `KeywordCodec`（merge/leaf/path 两套列表、大小写宽度 NFC 归一）`:69-179`；`dc:subject` 写叶子还是全路径由设置 `keyword_dc_style` 决定（`:181-184`；读侧实现 `GatherMetadataIO/SidecarXMPProvider.swift:104-118`）。
- 写盘：`dc:subject`（Bag）+ `lr:hierarchicalSubject`（只写含层级路径）双写，并维护 `photoshop:Urgency` 独立元素（`GatherMetadataIO/SidecarXMPProvider+Patching.swift:124-150`）。
- 读盘：sidecar 合并两套列表去重（`SidecarXMPProvider.swift:122-125,271-275`）；JPEG 内嵌必须自读 XMP 才能拿回 `lr:`（`GatherMetadataIO/XMPPacketReader.swift:29-30,103-115`；`MetadataWriteRouter.swift:222-232`）。
- 编辑 UI：检查器关键词面板 = chips 草稿 → 只读预览 → 一次确认 → 写回 → 重试（`GatherUI/Culling/CullingKeywordPanel.swift:82-146,181-234,307-324,471-499`）；模型层 `GatherUI/Culling/CullingViewModel+Keywords.swift:260-305`。
- 补全来源：**只来自本会话照片缓存里的关键词**（`GatherPersistence/Database/Queries/PhotoFilterQuery.swift:390-425`；UI 走 `photoAPI.suggestions`，失败退化为当前页关键词 `CullingViewModel+Keywords.swift:263-305`）。没有用关键词库表，也没有同义词候选。
- 索引与检索：`keywords / keyword_synonyms / photo_keywords` 三表（`GatherPersistence/Database/Schema/SchemaCurrent+DDLWorkbench.swift:69-97`）；`KeywordIndexSync` 增量同步与回填（`GatherApplication/Services/Keyword/KeywordIndexSync.swift:75-139`）；keyword facet 下钻（`FacetQuery.swift:31-37`；`GatherUI/Filtering/FacetBar.swift:88-98`；`Filter.swift:312-336`）。
- **词库管理是"仓储有 / 无 API / 无 UI"**：`KeywordRepo` 提供 `all/children/prefixMatches/rename/merge/delete/setSynonyms/synonyms`（`KeywordRepo.swift:124,132,150,215,297,332,379,399`），但协议层没有任何关键词库方法（`MetadataAPI.swift` 全文无词库接口），GatherUI 也没有树/改名/合并/同义词入口；P1 计划明确写「词库管理（树/改名/合并/同义词）未提供 UI」（`docs/design/p1-next/plan-2026-10-30.md:1202`）。同义词表注释也写明「只用于检索展开，不写 XMP」（`SchemaCurrent+DDLWorkbench.swift:81-82`），当前没有任何检索路径展开它。

### 1.5 评分 / 色标 / 标旗的 XMP 映射与 C1 口径

- 挑片改动先写 `photo_metadata_cache`，同时把 rating/label 入元数据交付队列（`GatherApplication/Services/Culling/CullingService+Commands.swift:103-108,196-204,647-675`）。
- XMP 映射：`xmp:Rating` 元素、`xmp:Label` 元素 + `photoshop:Urgency`（C1 色标），无 C1 映射时删旧 Urgency（`SidecarXMPProvider+Patching.swift:163-191`；映射表 `:377-390`，读回反向表 `SidecarXMPProvider.swift:277-291`）。rating 数据库约束 0–5（`SchemaCurrent+DDLDomain.swift:94`）。
- C1 往返：宿主有 `C1RoundTripCoordinator` 自动 reload + 失败通知（`gather-app/Sources/GatherHost/C1RoundTripCoordinator.swift:1-9`；设置键 `c1_auto_reload` `SettingsKey.swift:92,180`）；状态条显示「待 C1 重载」并在确认后消失（`MetadataSyncBar.swift:59-66`）。
- 明确不写 XMP 的部分：**标旗（pick/reject）不在写回计划里**——写回目标只有 rating / colorLabel / keyword 三种（`CullingSyncService.swift:343-385`；`CullingUpdatePatchField` 即使含 `pickState`，写盘计划不处理）。→ 回 C1 只能看到星级/色标，看不到 Gather 的 pick/reject。

### 1.6 检索面（facet / 规则 / 搜索串 / 保存查询）

- facet 维度 6 个：camera/lens/iso/year/label/keyword（`FacetQuery.swift:31-37`；标题本地化 `FacetBar.swift:88-98`）。
- 规则编辑器可选字段 22 个，含 title/description/headline/creator/copyright/city/state/country/country_code/location/person_in_image/keywords/keyword_path 等（`GatherUI/Filtering/FilterRuleEditor.swift:13-46`）。
- 服务端真正支持 JSON 语义查询的描述性字段只有 11 个：title/description(caption)/headline/creator/copyright/city/state/country/country_code/location/person_in_image（`PhotoFilterQuery.swift:63-88`，SQL 走 `json_extract(pmc.iptc_json, …)` `:508-520`）。
- 搜索串只 OR 5 个字段：filename/title/description/keywords/keyword_path（`GatherUI/Gallery/GalleryViewModel+Filters.swift:73-80`）；Library 页搜索框更窄，只有文件名（`GatherUI/Library/LibraryView+Filters.swift:45`）。
- 保存查询/智能相册：`applySavedSearch` 能把 criteria 拆回四档/facet/规则/搜索（`GalleryViewModel+Filters.swift:214-221`）。

### 1.7 设置与"API 有 / UI 无"汇总

- 设置页「元数据」组只暴露 `metadata_write_mode`（`SettingsViewModel+Catalog.swift:155-165`）；`keyword_dc_style` 有设置键与默认值（`SettingsKey.swift:89,177`）、组合根已注入（`GatherHost/Composition/Core.swift:103`），但**设置 UI 无** → 用户无法选择 `dc:subject` 写叶子还是全路径（C1/Lr 互操作时的关键开关）。
- 本域其他"实现深度 > 暴露程度"的项：批量直改（API 有/UI 无，§1.3）、模板预检明细（DTO 有/UI 无，§1.3）、关键词库（仓储有/无 API/无 UI，§1.4）。

## 2. 竞品基线（按产品分节）

> 抓取限制见文首。下列"能力存在"均有官方页面标题/摘要或第三方权威教程正文为证；具体菜单/字段行为未读到正文的，逐条标 **[待核实]**。

### 2.1 Capture One 23/24（Gather 的母软件，交互基线）

- 官方帮助中心 `https://support.captureone.com/hc/en-us` 本次抓取被 Cloudflare 403（返回 "Just a moment..."），C1 的 Metadata / Keywords 工具、关键词库、Token、批量元数据的具体菜单与字段行为无法核实，标 **[待核实]**；不凭印象断言版本细节。
- 可核实的一点：C1 23 的挑片/标注工作流（方向盘上下翻片、键盘给星级/色标）与「修改拍摄时间」在官方 23 特性访谈里明确描述（`https://www.captureone.com/blog/capture-one-23-eric-ronald-on-new-features`，正文含 "make your selections by applying a chosen color or star rating"、"Change capture time … in Capture One Pro 23"）。
- 对 Gather 的意义：C1 是评分/色标的最终消费方，Gather 已为它做了 **`xmp:Label` ↔ `photoshop:Urgency` 映射 + 写后自动 reload**（§1.5 证据），这是本域少有的"为竞品主动适配"的能力；但 C1 对层级关键词 `lr:hierarchicalSubject` 的导入行为，仓库文档自己标为待实机确认（`docs/design/p1-next/plan-2026-10-30.md:670-674`「C1 的导入行为需实机确认」）。

### 2.2 Adobe Bridge

官方帮助页（均抓到页面标题 + meta 摘要，正文超抓取上限）：
- **关键词**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/use-keywords.html> — "Create and manage keywords in Adobe Bridge"（摘要："create, apply, and manage keywords"）。层级关键词面板的具体交互 **[待核实]**。
- **元数据模板**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/create-metadata-templates.html> — "Create and apply metadata templates"（摘要："create, edit, and apply metadata templates"）。
- **导入元数据/套模板**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/import-metadata.html> — 摘要明确"including replacing existing metadata or applying template metadata"。
- **查看/编辑元数据**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/view-and-edit-metadata.html>（Metadata 面板 + File Info 对话框）。
- **查找**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/search-for-files-and-folders.html> — 摘要"using multiple criteria and create smart collections"。
- **批量重命名 / 评分色标 / 元数据总览（存储与类型）**：<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/batch-rename-files.html>、<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html>、<https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html>。
- sidecar 策略：Bridge 帮助导航中存在「XMP file created on Metadata update for JPEGs in Adobe Bridge」条目，说明 JPEG 元数据更新在某些条件下会产生 XMP sidecar；具体触发条件 **[待核实]**（正文不可达）。对 Gather 的直接含义见 §3 #10。

### 2.3 Lightroom Classic

- 官方帮助页（标题/摘要已抓到）："How to use keywords"（<https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/keywords.html>）、"Metadata basics and actions"（`…/metadata-basics-actions.html`）、"Save metadata to external sidecar files"（`…/create-xmp-acr-files.html`）、"Advanced metadata actions"、**"Metadata filters"**、**"Smart Collections criteria"**、"How to flag, label, and rate photos"，以及 **Map 模块**"auto-tag GPS coordinates to photos"（<https://helpx.adobe.com/lightroom-classic/desktop/maps/maps-module.html>）。
- 层级关键词、同义词与词表导入导出（Lightroom Queen 正文已核实）：
  - 关键字可建层级、拖拽成父子；Keywording 面板有 Keyword Suggestions / Keyword Sets（<https://www.lightroomqueen.com/how-keyword-photos/>）。
  - `Edit Keyword Tag` 含 **Include on Export / Export Containing Keywords / Export Synonyms**（<https://www.lightroomqueen.com/sync-keywords/>）→ 关键词同义词是**一等公民**。
  - **`Metadata > Export Keywords` 导出 CSV**，可在 Excel 里清洗后再导入（同上）→ 词库可迁移/批量整理。
  - 受控词表可下载后导入（<https://www.lightroomqueen.com/links/keyword-lists-controlled-vocabularies/>）。
- 批量与复制：Metadata 面板可对多选批量编辑，值不同时显示 `<mixed>`，有 Target Photo / Selected Photos 两种模式（<https://www.lightroomqueen.com/multiple-metadata-11-0/>）；**Sync Metadata** 可按字段把一张照片的元数据复制到其它照片（<https://www.lightroomqueen.com/copy-metadata-edits-photos/>）。
- 元数据预设：Library > Metadata 面板的 Preset 弹出菜单可 `Edit Metadata Presets`，含版权预设（<https://www.lightroomqueen.com/update-copyright/>）。
- 侧车/嵌入策略、Smart Collection 条件全集：官方页存在，正文 **[待核实]**。

### 2.4 Photo Mechanic Plus（Camera Bits）

- Camera Bits 官方产品导览页正文已核实（<https://home.camerabits.com/tour-photo-mechanic/>）：
  - **Structured Keyword lists**："add related keywords fast"；
  - **Variables**："Automatically add EXIF camera data to your images like focal length, serial number, or ISO to **metadata fields like captions or keywords**"；
  - **Batch Editing**："copy, delete, tag, watermark, rename, resize, and **add IPTC metadata to lots of photos at once**"；
  - **Code Replacements**："A few keystrokes can add entire sentences to your captions"；
  - **GPS Coordinates**："applying your saved GPS tracking logs to your photos"、PM6 起 "Use GPS data to automatically add city, state and country names to your metadata"；
  - 还可调整拍摄时间（多机位对齐）。
- IPTC Stationery Pad 的确切入口名与字段集在文档站（`https://docs.camerabits.com/`，JS 壳站）无法抓取正文，标 **[待核实]**；但"批量加 IPTC、变量、代码替换、GPS 反查地名"四项能力已被产品页正文证实。
- 目录（catalog）：Photo Mechanic Plus 的 catalog 能力本次未能抓到官方描述，**[待核实]**；另注意 Camera Bits 博客 2026-03 有「Photo Mechanic Plus is No Longer Available for Purchase」公告（<https://home.camerabits.com/blog/page/2/>），做长期路线对比时需要把"PM Plus 已停售"纳入考量。

### 2.5 能力矩阵（本域口径：✓=具备 / △=部分 / ✗=缺 / ?=[待核实]）

| 能力 | Gather | Capture One 23/24 | Bridge | Lightroom Classic | Photo Mechanic(Plus) |
|---|---|---|---|---|---|
| 32+ IPTC 字段编辑 | ✓（32） | ? | ✓（Metadata 面板/File Info） | ✓（Metadata 面板） | ✓（批量 IPTC） |
| 联系人结构 / 权利与使用条款字段 | ✓（contact 8 成员、usageTerms/webStatement/releaseStatus） | ? | ✓ | ✓（预设/字段） | ✓ |
| 元数据模板批量套用 | ✓（preview/apply/undo） | ? | ✓（create/edit/apply） | ✓（Metadata Presets） | ✓（IPTC Stationery） |
| 模板导入/导出/共享 | ✗ | ? | ✓（Import metadata / 模板） | △（预设可迁移，[待核实] 文件级） | ? |
| 变量 / 代码替换（{seq}/{client}） | ✗（仅导入重命名有 {seq}） | ? | △（Batch Rename 有令牌，[待核实]） | ✗（元数据字段无变量，[待核实]） | ✓（Variables / Code Replacements） |
| 层级关键词读写（lr:hierarchicalSubject） | ✓ | ? | ✓（面板，[待核实] 细节） | ✓ | ✓（Structured Keyword list） |
| 关键词库/同义词/受控词表管理 | ✗（表在、UI/API 无） | ? | ✓（keywords 面板，[待核实] 层级/同义词细节） | ✓（Keyword List + Synonyms + CSV 导入导出） | ✓（Structured list） |
| 关键词补全（词库 + 同义词） | △（只用本会话照片词，无同义词） | ? | ✓ | ✓（Suggestions / Sets） | ✓ |
| 多选直接编辑字段（非模板） | ✗（API 支持、UI 单张） | ? | ✓（多选 + Metadata 面板） | ✓（Selected Photos + <mixed>） | ✓（批量编辑） |
| 元数据检索字段覆盖 | △（11/32 + 搜索串 5 字段 + 6 facet） | ? | ✓（Find 多条件） | ✓（Metadata Filters，任意字段） | ✓（IPTC 检索） |
| GPS 编辑 / 反向地理编码 | ✗（只读显示） | ? | ? | ✓（Map 模块 auto-tag GPS） | ✓（GPS 日志 + 自动地名） |
| 批量编辑冲突提示 | △（交付冲突有面板；模板预检只有合计） | ? | ? | ✓（<mixed> + 逐字段 Sync） | ? |
| 元数据历史/快照 | △（批次撤销 20 批，无字段级历史） | ? | ? | ✗（无元数据快照） | ? |
| 写入 C1 的评分/色标 | ✓（xmp:Rating/Label/Urgency + 自动 reload） | —（消费方） | — | — | — |

## 3. 功能缺口表

> 严重度：P0 = 不补就用不起来 / 必须换工具；P1 = 日常明显摩擦；P2 = 锦上添花。成本：S（≤2 人日）/ M（1 周级）/ L（2–4 周）/ XL（>1 月）。
> 本域没有 P0：32 字段编辑 + 模板 + 撤销已能完成"基础元数据交付"；下列 P1 都是"能绕，但绕得很痛/必须开 Lr/Bridge/PM"的缺口。

| # | 缺口 | 竞品怎么做（产品+链接） | Gather 现状（代码/文档证据） | 用户影响场景 | 严重度 | 补齐成本 |
|---|---|---|---|---|---|---|
| 1 | **关键词库 / 受控词表 / 同义词无管理入口**：不能建树、改名、合并、编辑同义词，也不能把词表写回/导出 | Lr Classic：Keyword List 层级 + Edit Keyword Tag（Export Synonyms）+ Metadata > Export Keywords CSV（[Lightroom Queen](https://www.lightroomqueen.com/sync-keywords/)、[Lr 帮助](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/keywords.html)）；Bridge：Create and manage keywords（[官方页](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/use-keywords.html)）；PM：Structured Keyword lists（[Camera Bits](https://home.camerabits.com/tour-photo-mechanic/)） | 表与仓储都在：`keywords/keyword_synonyms/photo_keywords`（`SchemaCurrent+DDLWorkbench.swift:69-97`），`KeywordRepo` 有 `rename/merge/delete/setSynonyms/prefixMatches`（`KeywordRepo.swift:150-399`），但**协议无方法、UI 无入口**（`MetadataAPI.swift` 全文无词库接口；`docs/design/p1-next/plan-2026-10-30.md:1202`「词库管理未做」） | 婚礼/活动/商业每个客户一套词表；跨会话同义词（"故宫/Gugong/Palace Museum"）只能各写各的；换工具或交给客户前无法导出词表统一 | P1 | M |
| 2 | **关键词补全只来自"本会话已有关键词"，且不展开同义词** | Lr：Keyword Suggestions / Keyword Sets / 同义词参与搜索；PM：Structured Keyword list 一键加相关词（均见上） | 建议来自 `photo_metadata_cache.keywords` 的前缀匹配（`PhotoFilterQuery.swift:390-425`），失败退化为当前页词（`CullingViewModel+Keywords.swift:263-305`）；`keyword_synonyms` 表注释写明"只用于检索展开"（`SchemaCurrent+DDLWorkbench.swift:81-82`），但没有任何检索/补全路径读它（全仓仅仓储内部使用） | 新会话第一张图没有补全可用；输入"故宫"找不到"Gugong"；同一场景多语言词无法收敛 | P1 | S |
| 3 | **元数据字段没有变量 / 代码替换**：不能把 {seq}/{client}/{year}/{filename}/{camera} 写进说明、版权、标题 | PM：Variables 把 EXIF 自动写进 caption/keywords；Code Replacements 用短码替换长句（[Camera Bits 产品页](https://home.camerabits.com/tour-photo-mechanic/)） | 模板只存字面值：`MetadataTemplate` 只有 `fields: DescriptiveMetadata`（`MetadataTemplateStore.swift:12-27`），应用是逐字段字面比较（`MetadataTemplatePlanner.swift:66-112`）；`{seq}` 等占位符只存在于**导入重命名**（`IngestService.swift:60-65`；`SessionIngestInputs.swift:23`），元数据服务中 0 命中 | 交付给客户的一批图要写"©2026 StudioName / 第 001 张"只能逐张改；活动名/客户名每个项目重填一遍；说明文字只能复制粘贴 | P1 | M |
| 4 | **GPS / 位置只读，不能编辑、不能由 GPS 反查地名** | PM：套用 GPS 轨迹日志、用 GPS 自动填 city/state/country（[Camera Bits](https://home.camerabits.com/tour-photo-mechanic/)）；Lr：Map 模块 "auto-tag GPS coordinates to photos"（[Lr Map](https://helpx.adobe.com/lightroom-classic/desktop/maps/maps-module.html)） | `MetadataWriteAttributes` 有 latitude/longitude 槽位（`Protocol/XMPProvider.swift:12-34`），但没有任何写入调用者；UI 只读展示"位置 43.xxx, -79.xxx"（`MetadataDisplayRows.swift:50-60`）；编辑器只列 `DescriptiveField`（`MetadataEditorSheet.swift:51-54,103-122`），无 GPS 行 | 手机/无人机照片缺 GPS 时无法补；旅行/地产/活动照片要把 GPS 写成 City/Country 只能开 PM 或 Lr；Gather 里的地点字段永远靠手打 | P1 | M |
| 5 | **元数据检索只覆盖 11/32 描述性字段**，搜索串只 OR 5 个字段 | Bridge：Find 多条件 + smart collections（[官方页](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/search-for-files-and-folders.html)）；Lr：Metadata Filters + Smart Collections（[Lr 帮助](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/metadata-filters-in-lightroom-classic.html)） | 服务端 JSON 字段表只有 11 个（`PhotoFilterQuery.swift:63-88`），event/sublocation/creator_job_title/credit/source/job_identifier/usage_terms/world_region/province_state/model_release_status/date_created 等 21 个字段不可查；搜索串只 5 字段（`GalleryViewModel+Filters.swift:73-80`）；Library 搜索只搜文件名（`LibraryView+Filters.swift:45`）；facet 只有 6 维（`FacetQuery.swift:31-37`） | 客户问"上次给 XX 品牌拍的那组、署名是某摄影师、使用条款是内部评审的"——这些字段 Gather 填得进去却搜不出来；只能回 Bridge/Lr 反查 | P1 | S–M |
| 6 | **不能多选直接改字段（必须绕模板），且模板预检看不到"哪张哪字段"** | Lr：多选批量编辑 + `<mixed>` + Target/Selected 模式（[Lightroom Queen](https://www.lightroomqueen.com/multiple-metadata-11-0/)）；Sync Metadata 按字段复制（[Lr Queen](https://www.lightroomqueen.com/copy-metadata-edits-photos/)）；Bridge：多选 + Metadata 面板 | `applyDescriptive` 支持 `photoIds` 数组（`MetadataAPI.swift:52`），但编辑器只传单张（`MetadataEditorSheet.swift:209-213`）；模板预检的 `MetadataPhotoImpact.fields` 有逐字段 action/current/template/disk（`MetadataTemplatePlanner.swift:23-64`），UI 只显示"将写 X 张 / Y 个字段 / Z 处冲突"（`MetadataTemplateSheet.swift:92-111`） | 给 60 张图统一改客户名/版权行，要么先"从一张存模板"再套用（字段被模板三态语义绑死，无法只改一个字段）；预检看不到具体哪些照片的版权会被覆盖，只能赌 keepExternal | P1 | S–M |
| 7 | **元数据模板不能导入/导出/共享** | Bridge：Import metadata（可"替换现有元数据"或"套用模板元数据"，[官方页](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/import-metadata.html)）+ 模板创建/应用（[官方页](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/create-metadata-templates.html)）；Lr：Metadata Presets（[Lightroom Queen](https://www.lightroomqueen.com/update-copyright/)） | 模板只存 settings 单键 JSON，只有 `list/get/save/delete`（`MetadataTemplateStore.swift:5-8,42-104`；键 `metadata.templates` `SettingsKey.swift:76`）；`MetadataAPI` 无 import/export 方法（`MetadataAPI.swift:35-48`） | 团队里 A 建好的版权/客户模板，B 只能重敲；迁移机器/交接项目时模板无法带走；和 C1/Bridge 的模板体系完全隔离 | P1 | S |
| 8 | **IPTC 字段覆盖不全**：Instructions、Event Identifier、Model/Property Release Id、Image Creator、Location Created/Shown、Accessibility、ArtworkOrObject 等缺失 | IPTC 标准字段表（[IPTC Photo Metadata User Guide](https://www.iptc.org/std/photometadata/documentation/userguide/)）明确列出 Instructions(Core)、Event Identifier(Ext)、Model Release Id / Property Release Id(Ext)、Image Creator/Rating、Location Created/Shown、Accessibility、EERE 等；Bridge/PM 的 IPTC 面板覆盖这些字段 | `DescriptiveField` 只有 32 个（`DescriptiveMetadata.swift:24-33`），注释自认"未纳入 ArtworkOrObject 结构数组、Accessibility，留 P2"（`:9-10`）；Instructions 连枚举都没有；`IPTCIIMMapping.key(for:)` 也只映射 32 字段中有 IIM 对应的子集（`IPTCIIM.swift:186-210`） | 新闻/商业交付要求的 Instructions（"仅限一次使用"）、模特/财产释放编号、事件 ID 填不了 → 必须回 Bridge/PM；客户验收表要查这些字段时 Gather 面板不显示 | P1 | M |
| 9 | **受控值字段没有词表选择器/校验**：CountryCode、Scene、SubjectCode、ModelReleaseStatus、DigitalSourceType、Event 全是自由文本 | IPTC 用受控词表（ISO 3166 国家码、IPTC Scene/Subject Code、PLUS 释放状态）；Lr/Bridge/PM 给下拉或 CV 选择 | 编辑器所有字段一律 `TextField`（`MetadataEditorSheet.swift:114-118`）；list 字段用"、"或逗号分隔的纯文本（`MetadataEditorDraft.swift:47-51`）；服务端只校验长度/非空，无 CV 校验（`DescriptiveMetadata.swift` 无枚举约束） | 手打 `CN`/`China`/`cn` 三种写法国标不认；释放状态拼错写进 XMP，交付方系统读不到合法值；事后无法按"有模特释放"筛选 | P1 | S–M |
| 10 | **JPEG 已有 .xmp 时只写 sidecar，内嵌 IPTC 清不掉**（Bridge/PS 对 JPEG 默认读内嵌，可能看不到修改） | Bridge：元数据存/取说明（[Adobe 官方](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)）；Bridge 帮助导航有「XMP file created on Metadata update for JPEGs」条目（触发条件[待核实]） | 目标解析：JPEG 只要存在 sidecar 就返回 sidecar（`MetadataTarget.swift:36-42`；`MetadataWriteRouter.swift:49-66`）；清空失败会报 `JPEG_EMBEDDED_CLEAR_UNSUPPORTED`（`MetadataAttributeWriter.swift:325-397`），编辑器文案明说"JPEG 内嵌字段无法在此清空，需先在原软件中清空"（`MetadataEditorSheet.swift:39-41`） | C1 或 Bridge 曾给 JPEG 写过 sidecar 后，Gather 改标题/版权在 Bridge 里看不到；删字段时 Gather 报"清空失败"而用户不知道去哪清 | P1 | M |
| 11 | **模板/内联批量有 2000 张上限，但 UI 不提示** | （竞品无同等硬上限或上限可见） | 协议硬上限 `maxPhotoIds = 2_000`（`GatherProtocol/API/Inputs/MetadataTemplateInputs.swift:53,58,82,92`）；模板面板直接把 `selectedPhotoIds` 全量当目标（`MetadataTemplateSheet.swift:36-42`），超限只回 `INVALID_PARAM` 通用文案（既有审计已记录：`docs/reviews/2026-10-30-interaction-audit/E-export-metadata-ingest-controlcenter.md:71-75`） | 2 万张工作区里选"全部"套模板，只得到"参数无效，请检查输入"，不知道要分批 | P2 | S |
| 12 | **长文本字段只有单行输入、32 字段平铺无折叠** | Lr/Bridge 的 caption/description 是多行编辑区；PM 的 IPTC 面板 caption 为多行 | 编辑器 `TextField` 一律单行（`MetadataEditorSheet.swift:114-118`）；两组 IPTC 全量平铺（`:46-56,103-122`）；既有审计记录 P2-13（`E-export-metadata-ingest-controlcenter.md:122`） | 写 200 字说明只能横向滚动复读；粘贴多段文案后无法检查断行/错字 | P2 | S |
| 13 | **元数据"历史/快照"只有批次级撤销（20 批），无字段级历史** | Lr/Bridge/PM 也没有字段级元数据快照（Lr 的 History 只针对 Develop）；这项 Gather 的批次撤销反而更实用 | 批次存储 `MetadataApplyBatchStore` 只按批 `list/latest/get` + `markUndone`（`MetadataApplyBatchStore.swift:55-117`）；UI 只读最近 20 批（`MetadataBatchSheet.swift:95`） | 昨天误覆盖 30 张的版权，今天只能整批回滚；无法单张回滚/对比某字段历次值。**竞品同样没有**，因此不算落后项 | P2 | M |
| 14 | **元数据面板没有"仅显示已填写/按字段组过滤"，32 字段看一半是"尚未填写"** | Bridge：Metadata 面板偏好可隐藏空字段（[官方页](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/set-metadata-preferences.html)："Customize the Metadata panel display and hide empty fields"） | 面板固定渲染全部 22+10 行（`MetadataSections.swift:55-64`），空值显示"尚未填写"（`:78-81`）；无过滤/折叠开关 | 检查器纵向要滚 3 屏才看到"编辑元数据"入口（既有审计 P1-8，`E-export-metadata-ingest-controlcenter.md:90-94`） | P2 | S |
| 15 | **关系型人物/事件字段与 Persons/人脸流程脱节**：`personInImage` 只是自由文本，不读 `person_photos`，也不由人脸写回；`event` 是单值 alt，不是 IPTC Ext 事件结构 | Lr：Face Recognition / People 与关键词协同（[Lr 帮助](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/face-recognition.html)）；PM：批量 IPTC + 结构化词表 | `personInImage` 为 list 文本（`DescriptiveMetadata.swift:166`），UI 只作为文本字段显示（`MetadataDisplayRows.swift:176`）；Persons 仓库只记"写进 XMP 的关键词凭据"（`PersonRepo.swift:9`）与 `person_photos` 桥接，人脸写回走关键词而非 `Iptc4xmpExt:PersonInImage`（`FaceKeywordingViewModel+Writeback.swift:13-20` 的 `writeIPTC: false`）；`event` 映射为 `Iptc4xmpExt:Event` alt（`DescriptiveMetadata.swift:167`），而 IPTC Ext 的事件是含 Event Identifier 的结构（[IPTC 字段表](https://www.iptc.org/std/photometadata/documentation/userguide/)）[待核实 具体读取行为] | 人脸/人物库标完 1000 张，到交付要按"画面人物"字段筛选/给客户时是空的；事件名/事件 ID 只能手打；不同软件对 Event 的写法可能只读到文本 | P2 | M |
| 16 | **`keyword_dc_style` 设置无 UI**：用户无法选择 `dc:subject` 写叶子还是全路径 | Lr/Bridge 有明确的 "Export Containing Keywords" 类开关语义 | 设置键与默认值在（`SettingsKey.swift:89,177`），组合根已注入（`Composition/Core.swift:103`），设置页只暴露 `metadata_write_mode`（`SettingsViewModel+Catalog.swift:155-165`） | 用户想"dc:subject 也写全路径方便 Bridge 看层级"或"只写叶子避免重复"，只能在代码里改 | P2 | S |
| 17 | **无关键词 facet 之外的元数据 facet**（作者/城市/国家/年份之外；year 有，city/country/creator 无） | Lr：Metadata Filters 可按任意元数据列过滤；Bridge：Find 多条件 | `FacetDimension` 只有 6 维（`FacetQuery.swift:31-37`）；新增维度需要 FacetQuery+白名单+UI 三处（`FacetInputs.swift:9`） | 按城市/作者/国家做浏览式筛选得回规则编辑器手写 contains；与 Lr 的"点一下 X 城市"体验差距明显 | P2 | M |

## 4. 该域"最该补的 3 件事"

### ① 关键词库/受控词表：把已有半成品接上 UI 与补全（理由：数据层已存在，竞品最成熟，重复成本最高）

- 为什么排第一：Gather 已经花成本建了 `keywords/keyword_synonyms/photo_keywords` 与仓储的 `rename/merge/setSynonyms/prefixMatches`，但用户在 UI 里**一个字都用不到**；而 Lr 的同义词/关键词导出、Bridge 的 keywords 面板、PM 的 Structured Keyword lists 都是各自产品的默认能力。对"每个项目一套词表"的摄影工作流，这是每天都在发生的返工。
- 最小可行形态（M）：
  1. 新增 `KeywordLibraryAPI`（tree/rename/merge/setSynonyms/suggest），用 `KeywordRepo` 现有方法（`KeywordRepo.swift:124-399`），不改表结构；
  2. Library 侧栏加"关键词"树面板：计数来自 `keywords.usage_count`/photo_keywords，改名与合并走事务级联（仓储已实现），同义词编辑后**检索与补全都展开同义词**；
  3. 挑片关键词面板的补全改走词库 `prefixMatches`（`KeywordRepo.swift:150`），保留"当前页词"作为离线回退；
  4. 顺手把 `keyword_dc_style` 放进设置页（`SettingsViewModel+Catalog.swift:155-165` 的元数据组）。
- 验收场景：新建"客户/地点/项目"三棵常用树；把"故宫"标为"Gugong"的同义词后，输入任一写法都能补全出层级路径；重命名一个父词，所有照片的 `photo_keywords` 与 XMP 下次写回一致。

### ② 元数据"批量直改 + 全覆盖检索"：把已有 API/JSON 基础设施暴露出来（理由：数据结构已就绪，成本最低、收益最直接）

- 为什么排第二：`applyDescriptive` 已支持 `photoIds` 数组（`MetadataAPI.swift:52`）、模板预检已有逐字段明细（`MetadataTemplatePlanner.swift:23-64`）、服务端 `json_extract` 已能查 11 个字段（`PhotoFilterQuery.swift:63-88,508-520`）；缺的只是"多选入口 + 明细上屏 + 字段表扩到 32"。
- 最小可行形态（S–M）：
  1. 元数据编辑器支持多选：初值取"主文件 + 各字段混合值"（参考 Lr 的 `<mixed>` 语义），提交走 `MetadataInlineApplyInput(photoIds:)`（`MetadataAPI.swift:50-52`），冲突仍由既有 policy/冲突面板兜底；
  2. 模板预检把 `MetadataPhotoImpact.fields` 接到 UI：至少"逐照片 N 字段将覆盖/清空/冲突"可展开，避免"只显示合计"；
  3. `PhotoFilterQuery.jsonFields` 按 `DescriptiveField` 全量补齐（字段名对齐 UI 目录），搜索串扩到 headline/creator/city/person_in_image（与 FP-2 的 11 字段一致即可），Library 搜索也走同一 `searchCriteria`。
- 验收场景：全选 60 张 → 一次改版权行；预检能看到"其中 3 张版权冲突将保留"；按"故宫"或某摄影师署名搜出对应照片。

### ③ IPTC 字段补齐 + 变量/代码替换：把"交付级"字段与批量文案补上（理由：竞品的专业交付字段/变量是硬需求；成本可控）

- 为什么排第三：32 字段的字段表已经系统化（表驱动 descriptor + 三态 + IIM 映射），**加字段是低风险扩展**；变量替换是纯函数（在 planner 里对模板字面值做一次展开），不依赖 IO。竞品里 PM 的 Variables/Code Replacement、Bridge 的 IPTC 模板导入都直接打在这个点上。
- 最小可行形态（M–L）：
  1. 第一批补 5 个最高频字段：`instructions`（Core）、`eventIdentifier`、`modelReleaseID`、`propertyReleaseID`、`imageCreator`；`locationCreated/locationShown` 先做扁平文本映射，结构与 CV 放第二批（标准字段表见 [IPTC User Guide](https://www.iptc.org/std/photometadata/documentation/userguide/)）；
  2. 模板字段支持受限变量：`{filename}` `{seq}` `{seq:3}` `{year}` `{month}` `{day}` `{camera}` `{client}`（`{client}` 来自模板级变量表），展开在 `MetadataTemplatePlanner.plan` 之前做纯函数（`MetadataTemplatePlanner.swift:66-112`），预览即显示展开后的值；
  3. 受控值字段（countryCode/scene/subjectCode/modelReleaseStatus/digitalSourceType）改为下拉 + CV 常量表，写入前校验（成本合并进 1）；
  4. 给模板加 JSON 导入/导出（与模板存储同源，`MetadataTemplateStore.swift:42-104`），顺带解决缺口 #7。
- 验收场景：给 300 张活动照套模板，caption 自动变成 "ACME 2026 发布会 - IMG_0142"；交付表里的 Instructions/Release ID 不再需要回 Bridge 填。

## 5. 必查问题逐项对照（自查）

| # | 必查问题 | 结论 | 证据 |
|---|---|---|---|
| 1 | 层级关键词库/受控词表补全 | **半实现**：层级读写 + facet + 索引已通；词库管理/同义词/受控词表 UI 缺；补全不读词库 | §1.4；`KeywordRepo.swift:150-399`；`PhotoFilterQuery.swift:390-425`；`plan-2026-10-30.md:1202` |
| 2 | 变量与代码替换（{seq}/{client}） | **缺**：只有导入重命名支持 `{seq}/{yyyy}/{orig}`；元数据字段/模板无变量 | `IngestService.swift:60-65`；`MetadataTemplateStore.swift:12-27`；`MetadataTemplatePlanner.swift:66-112` |
| 3 | 裁切/关键字同义 | **同义词无 UI、不参与检索**；裁切属 C1 develop 域，Gather 不解析 .cos 也不做 RAW 编辑（Roadmap 七不做：不做 RAW 编辑，`docs/ROADMAP.md` 第七节） | `SchemaCurrent+DDLWorkbench.swift:81-82`；`KeywordRepo.swift:379-405`；`docs/ROADMAP.md` 七不做 |
| 4 | GPS/位置编辑 | **只读**：显示 GPS，无编辑、无反向地理编码 | `MetadataDisplayRows.swift:50-60`；`MetadataEditorSheet.swift:51-54`；`Protocol/XMPProvider.swift:12-34`（槽位无写入方） |
| 5 | 版权/权利/使用条款模板 | **字段+模板已覆盖**（copyrightNotice/usageTerms/webStatement/releaseStatus 都能进模板），缺模板分发/导入导出与 CV 校验 | `DescriptiveMetadata.swift:26-29`；`MetadataTemplateSheet.swift:222-250`；缺口 #7/#9 |
| 6 | 人物/事件/地点结构化字段 | **字段有、结构化无**：personInImage 自由文本、不接 Persons/人脸；event 单值；地点字段无 CV/反查 | `DescriptiveMetadata.swift:166-175`；`PersonRepo.swift:9`；`FaceKeywordingViewModel+Writeback.swift:13-20` |
| 7 | 评级的 XMP 映射与 C1 兼容性 | **已实现**：`xmp:Rating`/`xmp:Label`/`photoshop:Urgency` 双向 + C1 自动 reload；**pick/reject 不进 XMP**；C1 层级关键词导入未实机验证 | `SidecarXMPProvider+Patching.swift:163-191,377-390`；`CullingSyncService.swift:343-385`；`C1RoundTripCoordinator.swift:1-9`；`plan-2026-10-30.md:670-674` |
| 8 | 批量编辑冲突提示 | **部分**：交付冲突有逐字段裁决面板；模板预检只有合计、无逐张明细；无多选直改 | `MetadataTemplatePlanner.swift:23-64` vs `MetadataTemplateSheet.swift:92-111`；`CullingConflictPanel.swift:117-129` |
| 9 | 元数据模板导入导出 | **缺**（模板只在 settings JSON，API 无 import/export） | `MetadataAPI.swift:35-48`；`MetadataTemplateStore.swift:5-8,42-104` |
| 10 | 历史/快照 | **批次级撤销有（20 批），字段级历史无**；竞品同样无，因此不算落后 | `MetadataApplyBatchStore.swift:55-117`；`MetadataBatchSheet.swift:95` |
| 11 | 搜索可用字段 | **11/32 描述性字段 + 5 字段搜索串 + 6 facet**；竞品可查任意元数据字段 | `PhotoFilterQuery.swift:63-88`；`GalleryViewModel+Filters.swift:73-80`；`FacetQuery.swift:31-37` |

## 附 A. 关键证据索引

- 协议：`desktop/native/gather-core/Sources/GatherProtocol/API/MetadataAPI.swift`（20+ 方法）、`GatherProtocol/Protocol/DescriptiveMetadata.swift`、`KeywordPath.swift`、`MetadataAttributes.swift`、`Settings/SettingsKey.swift`
- 写盘：`GatherMetadataIO/SidecarXMPProvider.swift` / `+Patching.swift` / `+IPTC.swift`、`JPEGMetadataWriter.swift`、`IPTCIIM.swift`、`MetadataWriteRouter.swift`、`XMPPacketReader.swift`
- 服务：`GatherApplication/Services/Metadata/*.swift`（Template/Planner/Preview/Service/Store/ApplyBatchStore/Delivery/AttributeWriter/Disposition）、`Services/Keyword/KeywordIndexSync.swift`、`Services/Culling/CullingSyncService.swift`
- UI：`gather-app/Sources/GatherUI/Metadata/*.swift`、`Culling/CullingKeywordPanel.swift`、`Culling/CullingConflictPanel.swift`、`Filtering/FilterRuleEditor.swift`、`Filtering/FacetBar.swift`
- 持久化：`GatherPersistence/Database/Schema/SchemaCurrent+DDLWorkbench.swift`、`Queries/PhotoFilterQuery.swift`、`Queries/FacetQuery.swift`、`Repositories/KeywordRepo.swift`
- 文档：`README.md:48`（元数据能力口径）、`docs/ROADMAP.md`（4.2 模板/批量关键词 UX 待做；七不做含"不做 RAW 编辑"）、`docs/design/p1-next/plan-2026-10-30.md` §1.5/§3.6/§1202、`docs/reviews/2026-10-30-interaction-audit/E-export-metadata-ingest-controlcenter.md`（P1-5/P1-8/P2-13/P2-16 已知缺口）

## 附 B. 未验证风险与本报告的边界

1. **Capture One 23/24 细节不可核实**：帮助中心 Cloudflare 403，本报告不写 C1 的 Metadata/Keywords 菜单、Token、关键词库实现细节；C1 相关结论要么来自 Gather 侧代码（`xmp:Label`↔`photoshop:Urgency`、reload-ack），要么来自官方 23 特性访谈（评级/色标/改拍摄时间），其余一律 [待核实]。
2. **Adobe Help 正文不可达**：只取到页面标题与 meta 摘要，Bridge 的"关键词层级交互、模板导入细节"、Lr 的"侧车/嵌入触发规则、Smart Collection 条件全集"未读正文，标 [待核实]。
3. **Camera Bits 文档站是 JS 壳**：IPTC Stationery Pad 的字段清单与界面路径未核实；PM 的能力结论以产品导览页正文为准。另：**Photo Mechanic Plus 官方公告已停售**（Camera Bits 博客 2026-03），长期竞品对比需把这一点纳入。
4. **与 bridge 域的边界**：C1 自动 reload/写回确认、C1 侧车/内嵌读写差异，主责在 `30-c1-bridge.md`；本域只在"元数据写到哪、C1 能不能看见"处交叉引用，不重复评估桥接协议。
5. 本报告只评估功能残缺（真实工作流缺哪一步），不评代码质量、不做性能 profiling。

