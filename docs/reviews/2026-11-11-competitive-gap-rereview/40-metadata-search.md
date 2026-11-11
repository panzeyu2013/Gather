# 元数据 / IPTC / 关键词 / 模板 / 检索 功能复核（2026-11-11，基线 50fea319）

> 范围：元数据读写与冲突、IPTC 字段与受控值、层级关键词/词库/同义词、模板与变量、批量直改、检索字段与保存查询/facet、GPS/位置、导入预置、XMP·IIM 与 sidecar、人脸关键词互通。
> 方法：上轮分册 `docs/reviews/2026-11-10-competitive-gap/10-metadata-annotation.md` → `90-wave-ledger.md`（Wave1–4c 修复台账）→ `97-post-implementation-review.md`（§3.4 元数据 P1）逐条回当前代码核对。**判「已闭环」必须给 UI 调用点**，不只看 service/API 存在。
> 竞品事实：复用上轮 §2 已核实链接；本轮补抓 Camera Bits 产品导览页（2026-11-11 HTTP 200，正文含 Adjust Capture dates and times … synchronized … second shooters、Variables、Code Replacements、GPS … automatically add city, state and country names）。Adobe 帮助正文仍不可达（只到标题/导航），C1 帮助中心仍 Cloudflare 403；未读到正文的细节一律标 **[待核实]**。
> 不在本域：C1 桥协议（30 册）、导出/交付（40 册）、挑片与看图（20 册）、AI 语义（50 册）；只在交叉处引用。

## 0. 结论速览

1. **上轮 10 条 P1 复核结果：2 条闭环（#2 补全、#5 检索覆盖）、3 条部分（#1 词库、#3 变量、#6 批量直改）、5 条未闭环（#4 GPS、#7 模板导入导出、#8 IPTC 字段、#9 受控值、#10 JPEG 内嵌）。** P2 里 #11 部分闭环、#15 部分闭环、#13 维持「不做」，其余 4 条（#12/#14/#16/#17）仍在。
2. **Wave2 task-13/task-22 这一批不是「API 有/UI 无」**：词库树、同义词、补全、`<mixed>` 批量直改、17 字段搜索串、保存查询都有 UI 调用点（`CullingKeywordPanel.swift:379`、`MetadataTemplateSheet.swift:80,220-222`、`GalleryView+Filters.swift:67-108`）。这是本域自 11-10 以来最大的实质进展。
3. **但「能用 ≠ 好用」**：批量直改藏在「套用模板」的二级 sheet 里（3 层入口）；词库只能手工敲，没有导入导出；词库改名/合并只改索引、不重写 XMP，也没有「整库写回」入口；模板 apply 的预检仍只报 3 个合计数字。
4. **真正挡交付的两条 P1 都是「填不进去/写不合法」**：字段表仍 32 个（缺 Instructions、Event Identifier、Release ID、Image Creator、Location Created/Shown、Accessibility、ArtworkOrObject），受控值（country code / scene / subject code / 释放状态）仍全是自由文本 → 新闻/商业交付必须回 Bridge。IPTC 标准字段表见 <https://www.iptc.org/std/photometadata/documentation/userguide/>。
5. **GPS/位置至今未动**：只读展示（`MetadataDisplayRows.swift:57-60`），写入槽位 `latitude/longitude` 至今没有调用方；PM 能套 GPS 轨迹并自动填 city/state/country，Lr 有 Map 模块自动标注。
6. **新发现 5 条（上轮未列）**：导入时不能预置元数据（IngestSheet 自述「不改元数据」）；全仓没有「改拍摄时间」（PM/C1 的标准多机位对齐能力）；**同义词只在补全生效、检索完全不展开，而 UI 明确宣称「参与补全与检索」**；无「从磁盘重读元数据」入口（外部/Bridge 写入后只能等重建索引）；人脸写回的 4 个选项（createAlbums/addPrefix/markUngrouped/writeIPTC）是死代码，人物关键词一律扁平裸名。
7. **「写了但竞品看不见」的风险簇**：JPEG 一旦存在 .xmp 就只写 sidecar（内嵌 IPTC 清不掉）、非 JPEG（TIFF/PSD/PNG/HEIC）只写 sidecar、sidecar 与内嵌不同值时读侧静默取 sidecar —— 三条都会让用户在 Gather 里「改成功」，在 Bridge/Lr 里看不到。
8. **建议投入顺序**：IPTC 字段+受控值（一次关掉两条 P1，M）> 导入元数据预置 + 改拍摄时间（每项目一次的硬需求，S–M）> GPS 编辑与反向地理编码（M）；词库导入导出 + 同义词检索（S）可随手带上。

## 1. 上轮缺口状态核对

| 上轮 # | 缺口一句话 | 上轮严重度 | 当前状态 | 当前证据（路径:行号） | 剩余差 |
|---|---|---|---|---|---|
| 1 | 词库/受控词表/同义词无管理入口 | P1 | **部分** | 协议 7 方法（`MetadataAPI.swift:97-118`）；服务（`KeywordLibraryService.swift:31-115`）；UI 树/新建/改名/合并/删除/同义词（`KeywordLibrarySheet.swift:1-13,359-370`），入口（`CullingKeywordPanel.swift:379`）；`keywords` 为全局表（`SchemaCurrent+DDLWorkbench.swift:70-79`） | 无词表导入/导出（协议无 import/export，sheet 无按钮）；改名/合并只改索引、不重写 XMP，且无「把词库变更写回照片」入口（`KeywordLibraryService.swift:12-13` 自认） |
| 2 | 补全只用本会话词、不展开同义词 | P1 | **已闭环** | 词库前缀+同义词补全（`MetadataAPI.swift:102-103`）；面板调 `keywordSuggestions` 并标注「同义词 %@」来源（`CullingKeywordPanel.swift:190-224,297-304`）；会话词降为兜底（`:284-289`） | 无（「同义词参与检索」是另一件事，见 §3-N3） |
| 3 | 元数据字段无变量/代码替换 | P1 | **部分** | 引擎 9 个 token（`MetadataVariables.swift:110-115`）；批量面板变量提示+未解析阻断（`MetadataBatchEditorSheet.swift:207-213,274-291`）；模板侧同源（`MetadataTemplateVariables.swift:41-101`、`MetadataTemplateService.swift:213,392`）；client 输入（`MetadataTemplateSheet.swift:93-104`） | 无用户自定义替换表（PM Code Replacement：短码→整段文案）；token 仅 9 个，无 {focalLength}/{iso}/{serial}/{title}；PM 可把任意 EXIF 字段写进 caption/keywords |
| 4 | GPS/位置只读，不能编辑、不能反查地名 | P1 | **未闭环** | 只读展示（`MetadataDisplayRows.swift:57-60`）；`GatherApplication` 内 `latitude:` 仅 extraction（`MetadataExtractionService.swift:154`）；编辑器无 GPS 行（`MetadataEditorSheet.swift:103-122`） | 全部：无坐标编辑、无 GPS 轨迹导入、无反向地理编码写 city/state/country |
| 5 | 检索只覆盖 11/32、搜索串 5 字段 | P1 | **已闭环** | `jsonFields` 31 项（`PhotoFilterQuery.swift:73-107`，= 32 字段 − contactInfo）；数组字段语义（`:112-114`）；搜索串 17 字段（`GalleryViewModel+Filters.swift:79-89`）；规则编辑器目录 49 项（`FilterRuleEditor.swift:41-96`）；保存查询（`GalleryViewModel+Filters.swift:177-221`、`GalleryView+Filters.swift:67-108`） | Library 页搜索仍只搜文件名（`LibraryView+Filters.swift:43-48`）；联系人 8 成员不可查 |
| 6 | 不能多选直改字段；模板预检看不到「哪张哪字段」 | P1 | **部分** | 批量直改：`<mixed>`+变量+逐张预检（`MetadataBatchEditorSheet.swift:1-11,241-265,299-311`）、入口（`MetadataTemplateSheet.swift:80,220-222`）；D3 幻影冲突已修（`MetadataAPI.swift:57-59,184-192`） | 入口在「套用模板」二级 sheet（检查器→模板→批量编辑）；**模板** apply 预览仍只有合计，`MetadataPhotoImpact.fields` 明细仍未上屏（`MetadataTemplateSheet.swift:120-137`）；批量面板不含联系人（`MetadataBatchEditorSheet.swift:127`） |
| 7 | 模板不能导入/导出/共享 | P1 | **未闭环** | 模板仍只存 settings 单键 JSON，仅 list/get/save/delete（`MetadataTemplateStore.swift:1-6,63-99`）；协议文件全文无 import/export | 全部 |
| 8 | IPTC 字段覆盖不全 | P1 | **未闭环** | 仍 32 字段（`DescriptiveMetadata.swift:26-32`；注释自认未含 Accessibility/ArtworkOrObject `:9-10`）；IIM 映射只覆盖其中子集 | 全部；新增字段必须同步 `jsonFields`+规则目录，否则「填得进搜不出」 |
| 9 | 受控值字段无词表选择器/校验 | P1 | **未闭环** | 编辑器仍全 `TextField`（`MetadataEditorSheet.swift:114-118`）；list 字段仍「、」或逗号分隔文本（`MetadataEditorDraft.swift:48`）；服务端无 CV 约束 | 全部（country_code/scene/subject_code/model·property release status/digital_source_type） |
| 10 | JPEG 已有 sidecar 时只写 sidecar，内嵌 IPTC 清不掉 | P1 | **未闭环** | 目标解析「有 sidecar 就走 sidecar」（`MetadataTarget.swift:30-44`）；清空失败码（`MetadataAttributeWriter.swift:336-386`）；文案仍让用户「先在 Bridge/C1 清空」（`GatherLocalization.swift:104`、`MetadataEditorSheet.swift:39-41`） | 全部；且读侧 sidecar 覆盖内嵌无「两源不一致」提示（`MetadataAttributes.swift:18-34`） |
| 11 | 模板/批量 2000 上限 UI 不提示 | P2 | **部分** | 批量面板 200 上限有明确警告（`MetadataBatchEditorSheet.swift:26,383`）；模板面 2000 仍无提示（`MetadataTemplateInputs.swift:70,99`，超限只回 `INVALID_PARAM`） | 模板路径的提示与分批引导 |
| 12 | 长文本只有单行 | P2 | **未闭环** | `MetadataEditorSheet.swift:114-118`、`MetadataBatchEditorSheet.swift:241-251` 仍是单行 `TextField` | caption/description/usageTerms 无多行编辑区 |
| 13 | 字段级元数据历史/快照 | P2 | **不做** | 批次撤销 20 批（`MetadataApplyBatchStore`）；竞品同样无字段级快照 | 非缺口，见 §5 |
| 14 | 面板无「仅显示已填写/按字段组过滤」 | P2 | **未闭环** | 固定渲染 22+10 行，空值显示「尚未填写」（`MetadataSections.swift:68,79`） | 无过滤/折叠 |
| 15 | personInImage 自由文本、与人脸/Persons 脱节 | P2 | **部分** | person facet 与 persons 检索已加（`FacetInputs.swift:10-16`；97 册 E3 已修）；但人脸写回仍 `writeIPTC:false` 且不构造层级（`FaceKeywordingViewModel+Writeback.swift:14-19`、`FaceKwService+Writeback.swift:262-280`） | 见 §3-N5（4 个选项是死代码） |
| 16 | `keyword_dc_style` 无设置 UI | P2 | **未闭环** | 设置键在（`SettingsKey.swift:89`）、组合根已注入（`Composition/Core.swift:106`），设置页仍只暴露 `metadata_write_mode`（`SettingsViewModel+Catalog.swift:155-165`） | 全部 |
| 17 | 无 city/country/creator 等元数据 facet | P2 | **未闭环** | facet 维度 6→8（camera/lens/iso/year/label/keyword/scene/person，`FacetInputs.swift:10-16`），仍无 city/country/creator | 全部 |

> 文档滞后一处：`96-manual-acceptance.md` §9 第 10 条「模板侧变量未接」已在收尾批（task-22）闭环（`MetadataTemplateVariables.swift` + apply/preview 同源），该注记应删。

### 1.1 同日已修、本轮不应再当缺口报的项（供 Lead 去重）

| 已修项 | 证据（UI 调用点优先） | 说明 |
|---|---|---|
| 词库管理与同义词编辑 | `CullingKeywordPanel.swift:379` → `KeywordLibrarySheet.swift:359-370` | 树/新建/改名/合并/删除/同义词全通；`keywords` 全局表 |
| 词库补全 + 同义词命中提示 | `CullingKeywordPanel.swift:190-224,297-304` | 会话词降级为兜底 |
| 检索字段覆盖（31/32 + 搜索串 17 + 规则目录 49） | `PhotoFilterQuery.swift:73-107`、`GalleryViewModel+Filters.swift:79-89`、`FilterRuleEditor.swift:41-96` | 与上轮 #5 同一条 |
| 多选批量直改（`<mixed>` + 变量 + 逐张预检 + 分补丁批次） | `MetadataTemplateSheet.swift:80,220-222` → `MetadataBatchEditorSheet.swift:241-311` | 批次可在「历史与撤销」里回滚 |
| 模板侧变量展开（apply/preview 同源、未解析整批拒绝） | `MetadataTemplateService.swift:213,392` | 收尾批 task-22；96 册 §9 #10 已过时 |
| 97 册 D2/D3/D4（XMP 迁移 Rating=-1、批量盘态幻影冲突、preview×apply 不同源） | `MetadataAPI.swift:57-59,184-192`；`MetadataBatchEdit.swift` 盘态判定 | Wave4a 已修，带回归测试 |

## 2. 剩余缺口表（上轮未闭环 + 本轮新发现）

| 严重度 | 缺口 | 竞品做法 + 链接 | Gather 证据 | 成本 | 修法一句话 |
|---|---|---|---|---|---|
| P1 | IPTC 字段表仍 32：缺 Instructions、Event Identifier、Model/Property Release ID、Image Creator、Location Created/Shown、Accessibility、ArtworkOrObject | IPTC Photo Metadata 字段表；Bridge/PM 的 IPTC 面板覆盖（[IPTC 标准](https://www.iptc.org/std/photometadata/documentation/userguide/)、[Bridge 元数据面板](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/view-and-edit-metadata.html)） | `DescriptiveMetadata.swift:26-32`（32 个）；IIM 映射只到 32 字段子集 | M | 按 descriptor 表驱动加字段（含 IIM dataset、jsonFields、规则目录、编辑器行），先补 5 个交付高频字段 |
| P1 | 受控值字段全自由文本，无词表/校验 | IPTC 用 ISO 3166 / IPTC Scene·Subject Code / PLUS 释放状态；Lr·Bridge 给下拉或 CV 选择（[IPTC 标准](https://www.iptc.org/std/photometadata/documentation/userguide/)；Lr 字段行为[待核实]） | `MetadataEditorSheet.swift:114-118`；`MetadataEditorDraft.swift:48`；服务端无 CV 约束 | S–M | 加 CV 常量表 + Picker + 写入前校验（countryCode/scene/subjectCode/releaseStatus/digitalSourceType） |
| P1 | GPS 只读；无坐标编辑、无轨迹导入、无反向地理编码填地名 | PM：套 GPS 轨迹 + PM6 起用 GPS 自动填 city/state/country（[Camera Bits](https://home.camerabits.com/tour-photo-mechanic/)）；Lr：Map 模块 auto-tag GPS（[Lr Map](https://helpx.adobe.com/lightroom-classic/desktop/maps/maps-module.html)） | `MetadataDisplayRows.swift:57-60`；写入槽位无调用方；编辑器无 GPS 行 | M | 编辑器加经纬度输入 + 坐标/GPX → city/state/country（先离线地名表，再用系统反查） |
| P1 | 模板不能导入/导出/共享（词表导出另列 P2） | Bridge：Import metadata（替换现有或套用模板元数据）+ 模板创建/应用（[Bridge import](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/import-metadata.html)、[Bridge 模板](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/create-metadata-templates.html)）；Lr：Metadata > Export Keywords CSV（[Lightroom Queen](https://www.lightroomqueen.com/sync-keywords/)） | `MetadataTemplateStore.swift:1-6,63-99`；协议无 import/export；词库 sheet 无导入导出 | S | 模板与词表各加「导出 JSON / 导入并合并」两个动作（同源 Codable，不碰 schema） |
| P1 | JPEG 有 sidecar 时内嵌 IPTC 无法清空/覆盖；Bridge/PS 可能读不到修改 | Bridge 元数据存储说明；Bridge 帮助有「JPEG 元数据更新会生成 XMP」条目（触发条件[待核实]）（[Bridge about metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)） | `MetadataTarget.swift:30-44`；`MetadataAttributeWriter.swift:336-386`；`GatherLocalization.swift:104` | M | 提供「同时写内嵌（APP13 重写）」选项，或在检测到双源时给出「以谁为准」的显式提示 |
| P1 | **同义词不参与检索（与 UI 文案矛盾）** | Lr：同义词是 Edit Keyword Tag 的一等公民（[Lightroom Queen](https://www.lightroomqueen.com/sync-keywords/)） | 文案称「参与补全与检索」（`Localizable.strings:2338`；`MetadataAPI.swift:114`），但查询层不读 `keyword_synonyms`（`PhotoFilterQuery.swift:773-800,812-870`；Persistence/Application 的 synonym 命中只在 `KeywordRepo` 与 `KeywordLibraryService` 补全路径） | S | 关键词 filter 先把查询词按 `keyword_synonyms` 展开成路径集合，再拼 EXISTS |
| P1 | **导入时不支持元数据预置**（新） | PM：摄取同时自动做别的事、批量加 IPTC（[Camera Bits](https://home.camerabits.com/tour-photo-mechanic/)）；Lr 导入面板 Apply During Import → Metadata/Keywords [待核实] | `IngestSheet.swift:4`（自述「不改元数据」）；`SessionIngestInputs` 无模板/预置字段 | S–M | 摄取面板选模板 + afterCreate 复用 `applyDescriptive` 批次（漏做则交付缺版权，属每卡一次的摩擦） |
| P1 | **无「改拍摄时间」（多机位对齐）**（新） | PM：Adjust Capture dates and times … synchronized … wedding photographers with second shooters（[Camera Bits](https://home.camerabits.com/tour-photo-mechanic/)）；C1 23 起支持 Change capture time（[C1 23 访谈](https://www.captureone.com/blog/capture-one-23-eric-ronald-on-new-features)） | 全仓无该 API；拍摄时间只用于排序/展示（`CullingInspector.swift:312-313`、`MetadataDisplayRows.swift:57`） | M | 新增「时间偏移/设为指定时刻」批量动作；RAW 落 XMP `exif:DateTimeOriginal`，写完提示 C1 reload |
| P2 | 词库无导入导出（受控词表搬迁） | Lr：Metadata > Export Keywords CSV、可导入受控词表（[Lightroom Queen 词表](https://www.lightroomqueen.com/links/keyword-lists-controlled-vocabularies/)） | `KeywordLibrarySheet.swift` 全文无导入导出；`MetadataAPI.swift` 无对应方法 | S | 词库 CSV/JSON 导入导出（路径+同义词两列），导入走 `createKeyword`+`setKeywordSynonyms` |
| P2 | 词库改名/合并只改索引，不重写 XMP，也无「整库写回」入口 | Lr 改名后随保存/导出同步到文件（[Lightroom Queen](https://www.lightroomqueen.com/sync-keywords/)） | `KeywordLibraryService.swift:12-13` 自认；`KeywordLibrarySheet.swift:67` 文案提示「下次写回才进 XMP」 | M | 加「把受影响照片排入关键词写回」动作（复用 delivery 队列），或在改名后提示受影响张数 |
| P2 | 非 JPEG（TIFF/PSD/PNG/HEIC）只写 .xmp sidecar | Lr/Bridge 对非 RAW 写文件内元数据 [待核实 具体读取行为] | `MetadataTarget.swift:5-7,46-49`；路由（`MetadataWriteRouter.swift:48-66`） | M | 扩展内嵌写：TIFF/PNG 的 XMP packet 写入 + PSD 资源块；至少给出「该格式仅 sidecar」的显式提示 |
| P2 | sidecar 与内嵌 IPTC 不同值时静默取 sidecar | Bridge 有合并/冲突语义 [待核实] | `MetadataAttributes.swift:18-34`（sidecar 逐字段覆盖） | S | 读侧记录「双源差异字段」，面板给一枚提示徽标 |
| P2 | 批量直改不含联系人 8 成员 | Lr 可对多选批量改 Creator/Contact | `MetadataBatchEditorSheet.swift:127`（过滤掉 contactInfo） | S | 面板加联系人分组（模板路径已支持，照抄三态语义） |
| P2 | `keyword_dc_style` 无设置 UI | Lr 「Export Containing Keywords」有明确开关语义 [待核实 菜单名] | `SettingsKey.swift:89`；`Composition/Core.swift:106`；设置页（`SettingsViewModel+Catalog.swift:155-165`） | S | 元数据设置组加一个「dc:subject 写叶子/全路径」下拉 |
| P2 | 元数据面板无分组折叠/仅显示已填写；长文本单行 | Bridge 可隐藏空字段（[Bridge 元数据偏好](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/set-metadata-preferences.html)） | `MetadataSections.swift:68,79`；`MetadataEditorSheet.swift:114-118` | S | 空字段折叠 + 3 个长文本字段改 `TextEditor` |
| P2 | facet 仍无 city/country/creator | Lr：Metadata Filters 任意列 + Smart Collections（[Lr 帮助](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/metadata-filters-in-lightroom-classic.html)） | `FacetInputs.swift:10-16`（8 维） | M | 新增 3 维需 FacetQuery+白名单+UI 三处（`FacetInputs.swift:9` 注释已写明） |
| P2 | 模板 2000 上限无提示；批量 200 上限有警告 | 竞品无同等硬上限 | `MetadataTemplateInputs.swift:70,99` vs `MetadataBatchEditorSheet.swift:383` | S | 模板面板同款超限文案 + 「分批应用」引导 |
| P2 | 联系人成员（email/phone/url/address）不可检索 | Lr/Bridge 元数据检索覆盖联系人 | `PhotoFilterQuery.swift:73-107` 无 contact 成员键；`FilterRuleEditor.swift:41-96` 无对应项 | S | jsonFields 加 4 个 contact 成员（`json_extract` 路径 `contactInfo.*`） |
| P2 | 人脸写回 4 个选项是死代码；人物关键词扁平裸名，无层级、不写 IPTC PersonInImage | Lr：People/Face 与关键词协同（[Lr 人脸](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/face-recognition.html)） | `FaceKeywordingViewModel+Writeback.swift:14-19`（恒 false）；DTO（`FaceKwService+Types.swift:210-221`）→ `GatherDelivery` 全文无 4 选项引用（grep 0）；`FaceKwService+Writeback.swift:262-280` | M | 先把 2 个选项接上（前缀层级 + PersonInImage），或删掉死选项避免误导 |
| P2 | 无「从磁盘重读元数据」（外部/Bridge 改 XMP 后只能等重建索引） | Lr：Metadata > Read Metadata from File [待核实 菜单名] | 「重试索引」只在索引失败态出现（`GalleryView+Content.swift:226-240`）；`diskDescriptive` 只服务编辑器初值（`MetadataAPI.swift:54-56`） | S | 加「从磁盘刷新所选照片元数据」动作（复用 metadata.scan 的 requestedPaths） |

## 3. 新发现（上轮未列 / Wave2 引入的半成品）

### N1 导入链路完全不带元数据预置
`IngestSheet.swift:4` 明写「只做搬进来并登记这一件事：不选片、不改元数据」，`SessionIngestInputs` 里也没有模板/预置字段。结果是「每开一张卡 → 导入 → 全选 → 检查器 → 套用模板/批量编辑」这套动作必须由人记住；漏做的那批照片就带着空版权/空客户名进交付。PM 的 Ingest 是 automating other tasks at the same time，Lr 导入面板有 Apply During Import 的元数据/关键词项 [待核实]。成本 S–M：摄取面板加模板下拉，导入 `afterCreate` 后复用 `applyDescriptive`（批次可撤销）。

### N2 没有「改拍摄时间/多机位对齐」
全仓无任何时间写入 API（grep `dateTaken` 只命中排序/展示与变量取年月日）。婚礼/活动第二机位时钟差、旅行跨时区相机，只能回 PM（Adjust Capture dates and times … second shooters）或 C1 23（Change capture time）。这是与元数据直接相关、且 Gather 有完整写盘设施（XMP/内嵌双写 + 批次撤销）却没做的一步，成本 M。注意：写 `exif:DateTimeOriginal` 后 C1/Lr 的读取行为需实机验证 [待核实]。

### N3 同义词对检索完全无效，而 UI/注释宣称参与检索
`Localizable.strings:2338` 的字段说明是「同义词（逗号分隔；参与补全与检索，不写 XMP）」，`MetadataAPI.swift:114` 的注释同样写「同义词参与补全与检索」。实际只有 `KeywordLibraryService.suggestions`（`KeywordLibraryService.swift:53-68`）读 `synonymMatches`；检索侧 `PhotoFilterQuery` 的 keywords/keyword_path 分支（`:773-800,812-870`）只查 `photo_metadata_cache.keywords` 与 `photo_keywords`；Persistence/Application 两侧的 `synonym` 命中全部落在 `KeywordRepo` 与 `KeywordLibraryService`（补全/CRUD），没有任何检索路径读同义词表。用户输入 Gugong 搜不到标了「故宫」（同义词指向它）的照片 → 会认为检索坏了。成本 S。

### N4 词库改名/合并是「索引级」操作，没有把变更送到文件的路径
`KeywordLibraryService.swift:12-13` 自认「不改写盘上文件；下次显式写回才写进 dc:subject/lr:hierarchicalSubject」，`KeywordLibrarySheet.swift:67` 也提示用户。这本身是可接受的设计，缺的是「受影响照片批量排入关键词写回」的入口 —— 用户改完一个父词，只能在挑片页重新选那批照片再点一次关键词写回。成本 M（直接复用既有 delivery 队列）。

### N5 人脸写回的 4 个选项是死代码，人物关键词是扁平裸名
`FaceKwWritebackOptions` 声明了 createAlbums/addPrefix/markUngrouped/writeIPTC（`FaceKwService+Types.swift:210-221`），`FaceKwWritebackBridge.swift:40-45` 逐字透传，但 `GatherDelivery` 内对 4 个键的引用 **0 命中**；UI 侧 `FaceKeywordingViewModel+Writeback.swift:14-19` 恒传 false。`FaceKwService+Writeback.swift:262-280` 把 `binding.roleName` 直接当关键词加进去，没有「人物|张三」层级，也不写 `Iptc4xmpExt:PersonInImage`。后果：人物词与题材词混在同一层；交付方按「画面人物」字段查不到。这与旧 #15 同源但更具体（旧报告只说「不读 person_photos」，没发现选项全死）。

### N6「双源」静默：sidecar 覆盖内嵌，且非 JPEG 一律 sidecar
读侧 `MetadataAttributes.mergeAttributes` 的规则是 sidecar 逐字段覆盖内嵌（`MetadataAttributes.swift:18-34`），写侧 `MetadataTargetPolicy` 只有 JPEG 可能写内嵌（`MetadataTarget.swift:5-7,46-49`）。于是 TIFF/PSD/PNG/HEIC 的元数据只会进 .xmp —— 在 Bridge/Lr（对非 RAW 读文件内元数据）里可能完全看不到；JPEG 一旦被外部工具建过 sidecar，Gather 也永远写 sidecar，用户遇到的就是旧 #10。这两条应一起做成「显式告知 + 可选写内嵌」。

### N7 没有「从磁盘重读元数据」
`diskDescriptive` 只为编辑器取初值（`MetadataAPI.swift:54-56`），不更新缓存；缓存刷新靠 `metadata.scan` 任务，而「重试」按钮只在索引失败态渲染（`GalleryView+Content.swift:226-240`，实现在 `GalleryViewModel+Index.swift:106-122`）。外部软件（Bridge/C1/Lr）改过 XMP 后，图库/面板会一直显示旧值，直到用户重建索引或重导入。Lr 有 Read Metadata from File [待核实 菜单名]。成本 S（复用 requestedPaths）。

### N8 Wave2 半成品的「入口深/上限」小结（不算新能力，但影响可发现性）
- 批量直改入口是「检查器 → 元数据模板(折叠区) → 套用模板 sheet → 批量编辑字段…」（`CullingInspector.swift:198-209`、`MetadataTemplateSheet.swift:80`），且「套用模板…」在无当前照片时被禁用（`:203`）；
- 批量面板 200 张上限有警告是对的（`MetadataBatchEditorSheet.swift:383`），但模板路径 2000 上限仍只回通用错误；
- 词库只有一个入口：关键词面板右下「词库…」（`CullingKeywordPanel.swift:379`），Library/设置里都没有入口。

## 4. 本域最该补的 3 件事

1. **IPTC 字段表 + 受控值（M，约 1 周）**
   为什么第一：一条改动同时关掉两条 P1（#8/#9），且属于「表驱动低风险扩展」——descriptor、IIM 映射、jsonFields、规则目录、编辑器行都是既有结构；不补则新闻/商业交付的 Instructions、Release ID、Image Creator 永远要回 Bridge，受控值手打出错还会写进 XMP 被交付方系统拒收。验收：给 100 张商品图填 Instructions + Model Release ID，然后按这两个字段反查出来。

2. **导入元数据预置 + 改拍摄时间（S–M）**
   为什么第二：都是「每项目/每张卡一次」的确定性摩擦，且都有现成设施可复用（模板 + 批次、XMP/内嵌写盘 + C1 reload 提示）。导入预置解决「忘记写版权」，拍摄时间解决「双机位时钟差」——后者目前只能开 PM/C1，是明确的换工具点。验收：导入时勾模板 → 首批照片自带版权/客户；对 60 张第二机位照片 +2 分钟偏移后按拍摄时间排序正确且 C1 能读到。

3. **GPS 编辑 + 反向地理编码（M）**
   为什么第三：旧 #4 至今零改动，而这是 PM/Lr 的成熟能力、「地点」字段在 Gather 里永远靠手打；补齐后 city/state/country_code 三个字段与 facet/检索天然串起来。成本略高（要地名数据源），所以排第三。验收：给一批无 GPS 的手机照片贴一个坐标，自动填出「北京 / 中国 / CN」，再用 city facet 筛出来。

> 顺手项（S，可与上面并行）：词库/模板导入导出 + 同义词参与检索 + `keyword_dc_style` 设置 UI —— 三项都只动协议与 UI，不动 schema。

### 4.1 手测验收脚本（建议进 Wave5，自动化测不到的部分）

- **字段/受控值**：给 20 张图填 `instructions`+`modelReleaseID`+`countryCode=CN`，重启应用后仍在；按 `instructions contains 仅限一次` 能搜出；手填 `cn` 被拦或自动规范为 `CN`。
- **导入预置**：新建"客户A"模板 → 摄取面板勾选 → 导入 12 张 → 检查文件旁 .xmp 里有版权/客户名，且「历史与撤销」出现该批次。
- **拍摄时间**：同一场景两台机位，第二组 +2 分钟偏移 → 按"拍摄时间（旧→新）"排序两台机位交错正确；C1 reload 后看 `DateTimeOriginal` 生效。
- **GPS**：无 GPS 的 iPhone 照片填 39.9042/116.4074 → city/country_code 自动填出 → city facet 出现"北京"桶。
- **双源**：用 Bridge 给一张 JPEG 建 sidecar 并写内嵌 IPTC → 在 Gather 里清空该字段 → 观察是否给出"内嵌无法清空 + 双源"提示而不是仅报错。
- **同义词**：给"故宫"加同义词 Gugong → 在 Gallery 搜索框输入 Gugong → 应命中照片（当前不会命中，作为修复验收点）。

## 5. 明确不是缺口（防误报）

- **字段级元数据历史/快照**：Lr/Bridge/PM 都没有；Gather 的「最近 20 批可撤销 + 逐张预检 + 冲突策略」在误覆盖场景里更实用。维持上轮 P2 判断，不作为落后项。
- **元数据批量上限 200 / 2000 本身**：上限是必要的（批次快照写 settings）；缺的是提示，不是取消上限。
- **模板变量只有 `{client}` 一个共享作用域**：够覆盖「客户/项目名」这一主场景；PM 的 Code Replacement 替换表是另一层能力（见 §2 P2/上轮 #3 剩余差），不应强求在本轮做。
- **词库是全局（跨会话）而非按会话隔离**：`keywords` 表无 session_id、补全跨会话共享，符合「一个摄影师一套词表」的预期，是正确设计，不是缺口。
- **XMP + IPTC-IIM 双写、`xmp:Rating`/`xmp:Label` ↔ `photoshop:Urgency` 映射、C1 reload-ack 门禁**：均已闭环（Wave1 task-6 / 上轮 §1.5），别再报。
- **JPEG 内嵌字段「清空失败」的错误呈现**：错误码、字段列表、中文文案齐备（`GatherLocalization.swift:104`），属「能力缺」不是「交互坏」，不要当 bug 修文案。
- **联系人 8 成员编辑**：单张编辑器与模板都能改（模板从当前照片保存即带 contactInfo）；批量面板不含联系人是便利性缺口（§2 P2），不是功能断链。
- **不让 Gather 承担地图模块 / 云端同步 / RAW 编辑 / 语义搜索自然语言 UI**：`ROADMAP.md` §七不做；GPS 缺口只要求「能填字段、能反查地名」，不要求内置地图浏览。

## 6. 边界与交叉引用

- **C1 桥（30 册）**：本域只说"写到哪个文件、C1 能否看见"；reload 触发、ack 门禁、变体级写回细节不在本域。
- **导出/交付（40 册）**：联系表/画廊里的元数据字段选择、命名模板 token 属导出域；本域的变量引擎（9 token）与导出子目录 token 是两套实现，不要合并评估。
- **挑片看图（20 册）**：评级/色标的键盘工作流不在本域；本文只复核它们写进 XMP 的映射。
- **AI 语义（50 册）**：场景标签写关键词、person facet 的语义来源在人脸/语义域；本域只复核"写进关键词索引后能否被检索/词库管理"。

## 附 证据索引（本次实际读取）

- 文档：`docs/ROADMAP.md`（七不做）、`docs/reviews/2026-11-10-competitive-gap/10-metadata-annotation.md`、`90-wave-ledger.md`（§7 task-13/22、§10 收尾批、§12–13 Wave4）、`97-post-implementation-review.md`（§3.4 D1–D4、§4 P2、§11 取舍）、`96-manual-acceptance.md` §9。
- 协议：`GatherProtocol/API/MetadataAPI.swift`、`API/Inputs/KeywordInputs.swift`、`MetadataTemplateInputs.swift`、`API/Inputs/FacetInputs.swift`、`API/PhotoAPI.swift`、`Protocol/KeywordLibrary.swift`、`Protocol/DescriptiveMetadata.swift`、`Protocol/MetadataVariables.swift`、`Protocol/MetadataTarget.swift`、`Protocol/MetadataAttributes.swift`。
- 服务：`GatherApplication/Services/Keyword/KeywordLibraryService.swift`、`Services/Metadata/MetadataTemplateStore.swift`、`MetadataTemplateVariables.swift`、`MetadataTemplateService.swift`、`MetadataAttributeWriter.swift`、`Services/Face/FaceKwService+Writeback.swift`、`Services/Face/FaceKwService+Types.swift`、`GatherDelivery/Writeback/*`。
- UI：`GatherUI/Metadata/{MetadataEditorSheet,MetadataSections,MetadataEditorDraft,MetadataTemplateSheet,MetadataBatchEditorSheet,MetadataBatchSheet,KeywordLibrarySheet,MetadataDisplayRows}.swift`、`Culling/{CullingKeywordPanel,CullingInspector}.swift`、`Filtering/FilterRuleEditor.swift`、`Gallery/{GalleryViewModel+Filters,GalleryView+Filters,GalleryView+Content,GalleryViewModel+Index}.swift`、`Library/LibraryView+Filters.swift`、`FaceKeywording/FaceKeywordingViewModel+Writeback.swift`、`Host/APIs/LiveMetadataAPI.swift`、`Host/FaceKwWritebackBridge.swift`、`Composition/Core.swift`、`Settings/{SettingsKey,SettingsViewModel+Catalog}.swift`。
- 持久化：`Persistence/Database/Queries/PhotoFilterQuery.swift`、`Schema/SchemaCurrent+DDLWorkbench.swift`、`Repositories/KeywordRepo.swift`、`GatherPersistence/Ports/KeywordIndexStore.swift`。
- 本地化：`Localizable.strings`（2338 同义词说明）、`GatherLocalization.swift:104`。
- 竞品（本轮抓取）：<https://home.camerabits.com/tour-photo-mechanic/>（HTTP 200，正文核实 Ingest/Variables/Code Replacements/GPS 反查地名/Adjust Capture dates and times）；Adobe 与 C1 帮助正文不可达，相关细节标 [待核实]；其余链接沿用上轮分册 §2。
