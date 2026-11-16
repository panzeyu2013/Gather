# Gather 功能残缺复核（2026-11-11）：对照 Capture One / Adobe Bridge / 专用挑片与组织软件

> 复核对象：HEAD `50fea319`（2026-11-11，Wave1–4c 修复后，工作树干净）。
> 输入：本目录 6 份分册（`05`、`10`、`20`、`30`、`40`、`50`，约 950 行），对照上轮 `docs/reviews/2026-11-10-competitive-gap/`（约 105 条缺口）与 96 号真机验收清单。
> 方法：6 名域评审员只读审计 + Lead 交叉复核；「已闭环」必须有 UI 调用点（按钮/菜单/onKeyPress/onAppear），不接受 service/API 存在；所有行号以当前工作树为准。
> 边界：**只谈功能残缺**（真实工作流缺哪一步、必须换工具），不评代码质量、不做性能 profiling；未跑 build/test、未实机点 GUI。
> 取证限制：本机 `web_search` 401、Capture One 帮助中心 Cloudflare 403、Adobe 帮助正文 JS 渲染 —— 竞品细节凡未取到正文的一律标 [待核实]，不据此下缺口结论。C1 侧以本机 16.7.8.16 的 `CaptureOne.sdef` 文本为准；Bridge 14.0 本机安装。

---

## 0. 执行摘要（10 条）

1. **P0 收敛**：上轮 8 条 P0 现在是 **6 条闭环 / 2 条部分闭环 / 0 条完全未闭环**；本轮静态复核**没有新增已确认 P0**。但残留 2 条 **P0 级风险**：S3 通道交付件客户打不开（发布"成功"但无可用链接）、C1 多变体写回可能改错 variant。
2. **P1 漏斗**：五个主域共 52 条 P1，复核为 **13 条闭环 / 23 条部分闭环 / 16 条未闭环**（25% / 44% / 31%）。「部分闭环」占最大头，说明 Wave1–4 把**能力**做出来了，但大量能力还停在"API+UI 存在，没进默认路径、主界面或批量"。
3. **C1 伴侣定位从"不成立"变成"条件成立"**：选中读取、变体级读写、reload 后 ack、Session 三目录、在 C1 中显示都已闭环（静态级）；但写回作用域是 C1 **当前集合**、变体目标靠启发式、判断只从"选中导入"一条路进来——**跨集合/目录导入/多变体时仍会断**。
4. **挑片"看图这一半"基本补齐**：预取、加载期按键、真 1:1、全屏专注、Survey/3 图、第二屏、直方图/合焦键位都有 UI 调用点；但出现一个新的**判读正确性**缺口：2/4 图对比与 Survey 里多选是"构造对比"的手段，却同时成为 P/X/星级/色标的**批量写入目标**，Survey 中当前照片未选中时按 X 会标掉别人。
5. **AI 仍是"半条产品链路"**：判定信号、理由码、三档置信、整批撤销都在，但导入主入口（Dashboard 新建/加照片/摄取）没接自动初审、两个开关默认关、5 分钟轮询超时会主动取消 quality job、人脸分析没跑时闭眼/微笑/人脸合焦静默缺失；「导入即出建议」的默认路径仍不成立。
6. **交付只完成"上传"**：WebDAV/S3 发布 + 前端口令/到期 + 客户 selection.json 回收已可用；但 S3 对象默认私有、不写 ACL、无预签名、发布完成不给链接（`S3ShareTransport.swift:5-6`、`WebDAVPublishSheet.swift:181`），也没有发布记录/历史/增量。把 S3 当一等通道时，这是"发布成功但客户打不开"。
7. **组织模型仍与竞品不同构**：Gather 只有"工作区（一个根目录）"这一层；无物理文件夹树、必须建工作区才能浏览、集合是会话级（跨工作区集合不可用）、无虚拟副本/版本组、无批量重命名/文件移动、无跨工具目录导入（`.lrcat/.cos` 按边界不解析）。
8. **元数据从"合格写入端"往"工作台"走了一半**：关键词库/同义词/补全、模板变量、批量直改、31/32 字段检索、保存查询都已落地；但 IPTC 字段表仍缺 8 项、受控值全是自由文本、GPS 只读、模板/词库不能导入导出、同义词**不参与检索**（UI 却宣称参与）、JPEG 有 sidecar 时内嵌 IPTC 清不掉。
9. **自动化/格式进入第二层缺口**：自动化从 1 条深链扩到 4 深链 + 4 个 Shortcuts + 导出后钩子，但**不能被脚本"用"**（查询照片、写评级/决策、触发分析）；Bridge 有 JS/批处理，Gather 无 CLI、无 AppleScript 字典、无插件 SDK。格式上 HEIC/PSD 已修，但**解码白名单 28 种（RAW 20）> 索引/摄取白名单 20/19 种（RAW 10）**——`.iiq/.3fr/.x3f/.mrw` 等"能解但进不了库"，且静默跳过。
10. **验证缺口是最大的发布风险**：96 号 C1-1..C1-10、第二屏、打印、Shortcuts、翻片延迟矩阵**仍未执行**（§12 记录表为空）；本轮所有"C1 已闭环"只是与本机 sdef 的文本级一致。发布前不跑真机，等于把 8 条 P0 的"已修"建立在静态断言上。

---

## 1. 复核口径与统计

### 1.1 五个主域（上轮逐条回核）

| 分册 | 上轮缺口 | 已闭环 | 部分闭环 | 未闭环 | 本轮 P0 | 本轮 P1 剩余 |
| --- | --- | --- | --- | --- | --- | --- |
| `10` C1 互操作 | 14 | 5 | 6 | 3 | 0（P0：2 闭环 + 1 部分） | 6 |
| `20` 挑片/看图 | 22 | 6 | 5 | 11 | 0（P0 已闭环） | 5（2 新 + 3 遗留） |
| `30` 摄取/导出/交付 | 22 | 10 | 5 | 6（1 条归他域） | 0（P0：2 闭环 + 1 部分） | 6 |
| `40` 元数据/检索 | 17 | 2 | 5 | 9（1 条非缺口） | 0 | 8 |
| `50` AI/相似/语义 | 15 | 0 | 8 | 7 | 0 | 9 |
| **合计** | **90**（88 可归类 + 2 条归他域/非缺口） | **23** | **29** | **36** | — | **34** |
| `05` Bridge/组织横切 | 16（不重复计） | 5 | 2 | 9 | 0 | 4 |

> 口径说明：表中 90 为上轮五个主域清单总数（含 P2）；其中 88 条可归类，2 条分别为"归 05 域"与"非缺口"。P0/P1 漏斗为 8 条 P0 + 52 条 P1 = 60，与 90 不可直接相加；P1 精确值为 **13 闭环 / 23 部分 / 16 未闭环（52 条）**。05 册只做横切复核，其条目与 10/20/30/40 重叠处已去重，故单列不计入漏斗。

### 1.2 复核判据

- **已闭环**：该能力在当前工作树有 UI 入口，且主路径可走通（失败路径/边界可以不完美，但要能报错、能退出）。
- **部分闭环**：能力存在，但缺默认路径、缺批量、缺入口、缺失败出口，或只覆盖一个入口/一种格式。
- **未闭环**：上轮缺口原样存在。
- 严重度沿用上轮口径：P0 = 功能性坏掉/数据不安全/核心工作流断链；P1 = 每个工作流撞一次；P2 = 有更好、没有也能用。成本 S≤2 人日 / M≈1 周 / L>2 周。

---

## 2. 上轮 8 条 P0 的现状

| 上轮 | 缺口 | 现状 | 当前证据 | 剩余 |
| --- | --- | --- | --- | --- |
| P0-1 | C1 选中读取脚本对象归属错、on error 吞错 | **闭环** | `GatherHost/CaptureOneBridge.swift:567-591`（application 级 selected variants + parent image.path，失败上浮） | 真机未验；16.7 该属性 hidden，仅回退单选 |
| P0-2 | reload 传 document 而非 variant → ack 死锁；无手动 Load 出口 | **闭环** | `CaptureOneBridge.swift:167-180`（per-variant、无选中报码、仅 reloaded>0 写 ack）；`UI/Metadata/MetadataSyncBar.swift:184-190`（手动 ack 按钮） | 仍盲发 + 固定 500ms sleep，不验证 C1 真读到 |
| P0-3 | 读不到 C1 catalog 判断（rating/色标/pick/关键词） | **部分** | `GatherHost/AppBootstrap.swift:744-769` → `C1ImportJudgementService.swift:220-304`（仅"菜单 ⌘⇧I 从 C1 导入"） | 新建工作区/插件深链/自动化三入口不带判断；等 scan 最长 10 分钟 |
| P0-4 | 翻片：预取 API 全实现但 UI 0 调用 + 加载丢键 | **闭环** | `UI/Culling/CullingViewModel+Preload.swift:138-202`；调用点 `CullingWorkbenchViewer.swift:495,522,535`；排队 `CullingViewModel+Actions.swift:363-406` | 预取收益未实测；首屏/网格滚动仍整解 RAW |
| P0-5 | 导出无色彩空间/ICC、DPI、输出锐化 | **闭环** | `GatherProtocol/Protocol/Export.swift:262-268`；UI `UI/Export/ExportView+Options.swift:120-158`；执行 `ExportService+Run.swift:280-335` | — |
| P0-6 | 交付配方除名字/格式外全不可编辑 | **闭环** | `UI/Export/ExportView+Delivery.swift:322-760`（全字段）；默认值 `ExportViewModel+Delivery.swift:140-161` | — |
| P0-7 | 客户交付无托管链接/口令/到期强制 | **部分** | WebDAV/S3 传输 + 前端口令/到期：`UI/Export/WebDAVPublishSheet.swift:141-216`；边界见 97 号 §11 | **S3 对象私有且无预签名/链接**（"发布成功客户打不开"）；WebDAV 依赖用户自备服务器 |
| P0-8 | HEIC/HEIF/PSD 可导入却解不出缩略图 | **闭环** | `GatherAnalysis/Image/RAWDecoder.swift:82-96`（白名单 + 合成兜底） | PSD 只取合成扁平图（已知边界） |

**结论**：8 条里 6 条闭环、2 条部分；两条"部分"都不是"没做"，而是**只在一个通道上成立**（C1 判断只覆盖选中导入；交付只覆盖 WebDAV 路径）。它们仍是本轮最该收口的 P0 尾巴。


## 3. 剩余缺口（去重合并后）

### 3.1 P0 级：0 条确认 + 2 条风险（发布前必须决断）

| # | 风险 | 判据/证据 | 为什么是 P0 级 | 成本 |
| --- | --- | --- | --- | --- |
| X1 | **C1 变体写回可能改错 variant** | 写回脚本从 image 的 variants 里挑"pick 为 true 的，否则 variant 1"（`CaptureOneBridge.swift:981-998`）；读取侧却按 max/OR 合并（`C1ImportJudgementService.swift:65-94`）→ 读合并、写单变体，多 variant 时不可逆 | 96 号 §10 把"写错 variant"列为 P0 判据；C1 用户一图多 variant 是常态 | S/M |
| X2 | **S3 交付件客户不可访问** | 发布器明示"只 PUT/DELETE、不预签名、对象默认私有"（`S3ShareTransport.swift:5-6`）；UI 也提示"不开启公开读"（`WebDAVPublishSheet.swift:181`）；全仓无 presign/ACL | 若把 S3 当一等交付通道，用户会认为"发布成功但客户打不开 = 软件坏了" | M |

> 两条都不满足"已确认坏掉"（X1 需真机+多变体素材复现；X2 需产品决定 S3 是否一等通道），所以本轮不把它们计入 P0 计数，但发布前必须给出结论。

### 3.2 P1：22 条合并清单

**A. C1 最后一公里（4 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| A1 | **写回/选中/「在 C1 中显示」作用域 = C1 当前集合**：从不切换集合（`browse` 未用），跨集合 notFound 无补救；"在 C1 显示"只加选不减选 | `CaptureOneBridge.swift:612`（只在 targetDoc 内匹配）、`CullingSyncControls.swift:34-38` | C1 有 `browse`（sdef:678-684）；Bridge 无集合概念 | S/M |
| A2 | **判断数据只有"选中导入"一条通道**：新建工作区/插件深链/自动化导入都不带判断；三入口能力不一致（来源标/命名/判断） | `AppBootstrap.swift:744-769` vs `DashboardViewModel+Actions.swift:59`、`GatherAppDelegate.swift:233-238` | Bridge 对任意文件夹直接读写 XMP | M |
| A3 | **淘汰/关键词语义不闭合**：reject 不写（C1 无 reject 位）；XMP 关键词通道仍写 `culling:keep/reject` 污染 C1 词库；关键词未用 C1 `apply keyword` | `C1.swift:287-297`（keep-only）；`CullingSyncService.swift:341-377`（写 `culling:<decision>`）；`CaptureOneBridge.swift:893-896` | C1 有 Trash 集合、`move inside`、`apply keyword`（sdef:1795-1893） | M |
| A4 | **变体级写回不可控**：无变体列表/目标选择/写后回读/分批/撤销；写 catalog 不写 XMP，C1 手动 Load 会覆盖 | `CaptureOneBridge.swift:973-1018`（启发式目标）；`:898-906`（只 catalog） | C1 判断在 variant，写哪一个是显式参数（sdef:262） | S/M |

**B. 挑片判读（4 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| B1 | **对比/Survey 决策目标错位**：多选是构造 2/3/4 图/Survey 的手段，却同时成为 P/X/星级/色标的批量目标；Survey 当前照片未选中时按 X 标掉别人 | `CullingComparison.swift:17-23,52-61`；`CullingViewModel+Actions.swift:408-455`（commit 用 selectedPhotoIds） | LR Compare/Survey 以活动照片为决策对象 | S–M |
| B2 | **浏览连续性**：切布局改页大小（200/500）并整页 reset，当前照片越过 200 张即回第 1 张；进网格不 scrollTo 当前；筛选/当前照片/参考槽不落盘（上轮 #12） | `CullingView.swift:57-64` → `CullingViewModel+Grid.swift:27-34` → `CullingViewModel+Load.swift:213-225`；`CullingView.swift:46-50` | PM/LR 保持视图切换的位置与选择 | S |
| B3 | **无嵌入 JPEG 快档**：缩略图/预览仍恒 `kCGImageSourceCreateThumbnailFromImageAlways` 整解 RAW；预取只覆盖查看器 ±1，首屏/网格滚动/跳页仍整解 | `RAWDecoder.swift:256-299`；无解码路径设置（`SettingsKey.swift:54-55`） | FRV/PM/Narrative 都以缩略图/嵌入预览优先 | M |
| B4 | **C1 已调色预览无提示**：查看器按 RAW 渲染，看不见 C1 调整，无任何标记 | `RAWDecoder.swift:199-224`；`CaptureOneBridge.swift:344`（不解析 .cos）；无 UI 引用 | C1 是真相源；PM/FRV 不做编辑 | L（只做标记则 S） |

**C. 交付与迁移（3 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| C1 | **交付发布闭环**：S3 私有不可访问 + 无预签名/公开读；无链接/发布记录/历史/增量；发布目标每次重填；入口只挂本次交付内存结果 | `S3ShareTransport.swift:5-6`；`WebDAVPublishSheet.swift:20-28,181`；`ExportView+Delivery.swift:134-159` | LR Publish Services（发布集合/已发布状态）；AWS 预签名 URL 官方做法 | M |
| C2 | **迁移包丢组织资产**：包结构只有 session/collections/photos；堆栈/智能相册/保存查询/人物-人脸绑定/重复组都不在 | `MaintenanceAPI.swift:259-358`；`LibraryPackageService.swift:51-87,285-296` | LR 合并目录承载完整目录内容 | M |
| C3 | **导入不是"一次配置"**：重命名模板/第二目的地/校验/去重策略全是 `State`，关 sheet 即丢；非法 token 不拦截；失败只显示首条；第二目的地成功/校验不可见 | `IngestSheet.swift:18-24`；`IngestService.swift:20-22,470-475`；`IngestSheet.swift:196-202` | LR Import Preset；PM Ingest + Metadata Template + Incremental | S–M |

**D. 元数据（3 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| D1 | **交付级字段与受控值**：IPTC 仍 32 字段，缺 Instructions/Event Identifier/Release ID/Image Creator/Location Created·Shown/Accessibility/ArtworkOrObject；country code/scene/subject code/release status 全自由文本 | `DescriptiveMetadata.swift:26-32`；`MetadataEditorSheet.swift:114-118`；无 CV 约束 | IPTC 标准字段表；Bridge/PM 的 IPTC 面板 | M |
| D2 | **位置与时间**：GPS 只读，无坐标编辑/轨迹导入/反向地理编码填 city/state/country；全仓无"改拍摄时间"（多机位对齐） | `MetadataDisplayRows.swift:57-60`；无写入调用方；无时间写入 API | PM 套 GPS 轨迹 + 自动填地名；C1 23 起可改拍摄时间 | M |
| D3 | **元数据互换与双源**：模板/词库不能导入导出；**同义词不参与检索**（UI 却宣称参与）；JPEG 有 sidecar 时内嵌 IPTC 清不掉；非 JPEG 只写 sidecar；双源不同值静默取 sidecar | `MetadataTemplateStore.swift:63-99`；`PhotoFilterQuery.swift:773-870`（无 synonym）；`MetadataTarget.swift:30-44`；`MetadataAttributes.swift:18-34` | LR/Bridge 模板与关键字 CSV 导入导出；Bridge 双源语义 | M（拆分 S+M） |

**E. AI（4 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| E1 | **AI 初审端到端不成立**：主入口（Dashboard 新建/加照片/摄取）未接 pipeline；两开关默认 0；5 分钟轮询超时会主动取消 quality job；无 job/进度/结果可见性 | `AppBootstrap.swift:686-691,717-721,967-975`；`AITriageAutoPipeline.swift:117-121,166-176`；`DashboardViewModel+Actions.swift:13-29` | Aftershoot "Step 2 AI Culls"、Narrative "AI First Pass" 都是导入即出建议 | M |
| E2 | **人脸是隐式前置**：eyes/smile/faceFocus/small_face/multi_face 读 `face_observations`，该表只由手动 `face.analyze` 写；没跑时信号静默缺失且 UI 不提示 | `ModelReviewService.swift:57,68,120`；`TriageRepo.swift:552-561`；`CullingTriageCard.swift:264-289` | Aftershoot/Narrative 把闭眼/失焦作为通读因子 | M |
| E3 | **分组分析不随初审跑**：similarity/duplicate/navigation 三组都要手动点；导入即初审后只有"硬技术失败/待复核"，best-of-burst 不生效 | `TriageRepo.swift:640-721`；`SimilarityView+Analysis.swift:61-62`、`DuplicatesView+Sections.swift:87-89` | Aftershoot 自动分组重复；Narrative 场景内排序 | M |
| E4 | **场景/最佳帧产品化不足**：无组折叠/组内按 quality 排序/一键保留最佳；场景标签入口在 Beta 建议卡二级 sheet、英文原串、无自动关键词；People Filter 不在挑片页/Gallery | `CullingFilterControls.swift:95-124`；`CullingTriageCard.swift:328-339`；`GalleryViewModel+Filters.swift:121-123`；`SemanticIndex.swift:450-451,498-508` | Narrative Scenes View/Close-Ups；Excire 自动关键词/人物筛选 | M |

**F. 组织、自动化与格式（4 条）**

| # | 缺口 | 当前证据 | 竞品对照 | 成本 |
| --- | --- | --- | --- | --- |
| F1 | **无物理文件夹树/浏览即读**：侧栏只有工作台/最近工作区/图库；浏览任意目录必须先建工作区；物理维度只剩目录前缀筛选 | `RootShellSidebar.swift:14-19`；`SessionAPI.swift:10-33`；`LibraryView+Filters.swift:178` | Bridge/NeoFinder/LR Folders 都以文件夹为默认入口 | M |
| F2 | **无导入后批量重命名/文件移动**：只有摄取那一刻能改名；无移动/复制/删除 API（只有淘汰移出 _rejects） | 全仓 `batchRename/renamePhotos` 0 命中；`FileOps/RejectedMover.swift` 唯一文件操作 | Bridge Batch Rename；PM Rename 工具；NeoFinder 顺序改名 | M |
| F3 | **自动化第二层缺失**：4 深链 + 4 Shortcuts + 导出后钩子，但**不能被脚本"用"**（查询照片、写 rating/keep、触发分析）；无 CLI/AppleScript 字典/插件 SDK；intents 参数全 String | `GatherDeepLinkRoute.swift:15-21`；`GatherAutomationIntents.swift:20,52,81,106`；无 `.sdef`；`Package.swift` 仅开发工具 | Bridge JS/批处理；LR 插件 SDK；C1 AppleScript | M–L |
| F4 | **格式白名单漂移**：解码 28 种 > 索引 20 种 / 摄取 19 种；`.iiq/.3fr/.x3f/.mrw/.srf/.fff` 等可解码却在导入/扫描时静默跳过；GIF/BMP/AVIF/JP2/PSB 全不支持 | `RAWDecoder.swift:82-90` vs `IndexerService.swift:66-70`、`IngestService.swift:338-341`；静默跳过 `IngestService.swift:383` | C1 用户 .iiq、Hasselblad .3fr；NeoFinder 支持面更广 | S |

### 3.3 P2 摘要（按主题，明细见各分册）

- **组织容器/检索**：跨工作区手动集合不可用（`collections.session_id NOT NULL`）；Gallery 会话级保存查询 vs Library 全局智能相册两套表/两套入口；集合/堆栈规则手填 UUID；Library 搜索 10 字段 vs Gallery 17 字段；`suggestions` API 无 UI；无 ⌘F Find 面板；堆栈只在图库折叠、无自动堆叠、挑片页不识别；虚拟副本/版本组不存在且"文件级决策"边界未声明。
- **挑片专业档**：专注模式 chrome 未清干净；3/4/Survey 非当前格只有 hover 清晰；参考对比几何只在 fit 档正确；Survey 默认只 2 格；AF 点空表 + 人脸中心回退；键位不可自定义/无视图模式键；无图像面过曝遮罩；缩放不以指针为中心、无按住临时放大；无色彩管理/软打样；第二屏不自动选屏；移出确认无张数；网格双击不进单图；挑片页无 ⌘R。
- **交付/打印**：联系表纸张固定 A4（渲染器有 pageSize，协议/UI 没暴露）、无横向；画廊字段仅 3 个；发布端点只有 WebDAV/S3（无 FTP/SFTP/网盘）；客户画廊无成片 ZIP 下载；导出无"移除 GPS/精简元数据"开关；交付 manifest 无校验和、失败只显示首条；无发布历史/报告中心。
- **元数据**：批量直改入口 3 层深、不含联系人；模板 2000 上限无提示；长文本单行；无字段过滤/折叠；`keyword_dc_style` 无设置 UI；无"从磁盘重读元数据"；人脸写回 4 个选项是死代码、人物关键词扁平且不写 `PersonInImage`；facet 缺 city/country/creator；非 JPEG 只写 sidecar。
- **AI**：相似阈值三套（0.6/0.82/0.92）；语义索引不可见/不可清空；"应用建议"只能全会话；无 Cull to Target；无多脸 Close-Ups；无 OCR；AI 结果不进主检索面；Gallery facet 声明 scene/person 但请求不含。
- **自动化/格式/迁移**：无监视目录 UI/自动摄取/相机导入；无通用外部编辑器移交；GIF/BMP/AVIF/JP2/PSB 静默丢；无库完整性检查/优化；迁移导入后不自动重索引；无幻灯片/多窗口/拖出到 Finder/PS；C1 插件无安装/版本/诊断面；500 张写回上限只提示不自动分批；无 C1 调整提示。


---

## 4. 四个参照系的结论

### 4.1 对照 Capture One：从"回路不成立"到"条件成立，仍有三个断点"

- **成立的部分**：选中读取（application 级）、变体级读/写、reload + 手动 ack 出口、Session 三目录识别、在 C1 中显示、hot folder 边界提示、GatherLink 插件（C1 Open With → `gather://import`）、C1 裁剪框读取。这些在上轮全是 P0/P1，现在都有 UI 调用点。
- **仍断的三处**：① **作用域**——写回/选中只在 C1 当前集合内匹配，不用 `browse` 补作用域，跨集合批量 notFound；② **判断入口**——只有菜单"从 Capture One 导入"带判断数据，新建工作区/插件深链/自动化都不带；③ **变体目标**——写回挑"已 pick 否则 variant 1"，不展示变体、不选目标、写后不回读，多 variant 时可能改错。
- **竞品基线**：C1 的判断属于 variant、组织属于 collection、交换靠 Load/Sync metadata + AppleScript 面。Gather 的"伴侣"语义要求"在 Gather 做的决定，C1 立刻看得见"——现在**看得见但作用域/变体/入口都不完整**，且 XMP 关键词通道会往 C1 词库写 `culling:keep/reject`。
- **结论**：C1 伴侣可以作为**发布卖点**，但必须先把 A1–A4 修掉并跑真机矩阵；否则用户在多集合/多变体/整目录导入三个场景会退回 C1。

### 4.2 对照 Adobe Bridge：输在"通用浏览 + 可编程"，赢在"决策深度"

- **Bridge 的三重压力**：免费且已装、任意文件夹直接浏览/XMP 直读直写、JS 脚本 + 批处理 + 批量改名 + Stack/Collections/Find。
- **Gather 已补**：HEIC/PSD 解码、堆栈新建、关键词库、元数据模板、批量元数据、保存查询、4 Shortcuts + 4 深链 + 导出后钩子。
- **仍缺**：物理文件夹树/浏览即读（F1）、导入后批量重命名/文件移动（F2）、脚本"可编程"（F3）、格式白名单漂移（F4）、GIF/BMP/AVIF/JP2/PSB、无 ⌘F Find 面板、无外部编辑器移交、无监视/自动摄取。
- **结论**：如果用户的工作流是"插卡先翻一遍/按目录找片/脚本串流水线"，Gather 仍不能替代 Bridge；Gather 的优势是"围绕挑片决策的深度"（相似/人脸/写回可靠性/交付），这个优势只有在 F1/F2 补上、且翻片不比 Bridge 慢之后才成立。

### 4.3 对照专用挑片（PM / FastRawViewer / Narrative Select）：判读追到同代，速度与 AI 默认路径仍差

- **已补**：预取接线、加载期按键不丢、真 1:1、专注/全屏、Survey/3 图、第二屏镜像、直方图/合焦/AF 键位、2 图全格清晰、堆栈/色彩标/撤销/物理隔离。
- **仍差**：① **判读正确性**——对比/Survey 的批量写入目标错位（B1），这是唯一会写错用户判断的缺口；② **浏览连续性**（B2）——切布局丢当前照片/隔天不能续挑；③ **速度**——RAW 无嵌入 JPEG 快档（B3），预取收益没有实测（96 §5 未跑）；④ **专业细节**——键位不可自定义、专注 chrome 未清、4 图/Survey 贴片不足、参考对比几何只在 fit 档、AF 点空表；⑤ **AI 默认路径**——Narrative/Aftershoot 的"导入即初审 + 场景最佳帧 + People Filter"仍不成立（E1–E4）；⑥ 无 Cull to Target（按交付张数反推保留）。
- **结论**：作为"挑片器"已经从"落后一代"追到"同代但少专业细节"；但用户第一次对比的仍是"翻片快不快、按键丢不丢、放大清不清"——B1/B2/B3 决定这个第一印象，且都是 S/M 成本。

### 4.4 对照组织/交付软件（LR / NeoFinder / Peakto / Excire / Pixieset）：产品形态差，不是修 bug 能补

- **组织模型**：Gather 是"工作区（一个根目录）+ 会话级集合"；LR/PM Plus 是 catalog 级集合/集合集/智能集合，NeoFinder/Peakto 是"拖一个卷/一个目录即建档"。Gather 缺跨工作区手动集合、物理文件夹树、虚拟副本/版本组、catalog 导入（`.lrcat/.cos` 解析按 ROADMAP 边界）。
- **交付模型**：Gather 是"生成静态画廊 + 上传 + 客户回传 selection.json"；Pixieset/SmugMug/Frame.io/LR Publish 是"发布服务 + 链接 + 状态 + 增量 + 客户账号/评论"。Gather 现在有前端口令/到期/客户勾选/评论回传，但 S3 通道客户打不开、无链接、无发布记录/增量——**仍要自备 WebDAV 或退回专业交付平台**。
- **AI 组织**：Excire 的自动关键词/文本检索/场景分组、Aftershoot 的 Cull to Target/学习偏好，Gather 只有 dHash 聚类 + Vision 标签子串检索；感知级相似还在"评估工具已就绪、标注集未跑、决策 A 未立项"。
- **结论**：Gather 不需要变成 LR/Peakto，但如果目标是"C1 用户的组织/交付层"，**物理文件夹树、迁移包组织资产、发布链接/状态**是三个最低门槛；否则用户会把它当"挑片插件"，组织仍在 C1/LR、交付仍在 Pixieset。

---

## 5. 明确不是缺口（防止把取舍当缺陷）

| 项 | 依据 | 处理建议 |
| --- | --- | --- |
| RAW 显影/编辑、图层、曲线、局部调整、色彩编辑 | `docs/ROADMAP.md` §七；C1 是显影真相源 | 不补；UI 明确"预览不含 C1 调整"（B4 只做标记） |
| 视频 / PDF / AI / EPS / 音频 / 混装素材目录 | ROADMAP §七 | 不补；README/UI 写清"仅静态图" |
| 云同步、多人共享目录、实时协作、客户账号体系 | ROADMAP §七 | 不补；团队协作只保留库包导出/导入 |
| Windows / 移动端 / Web 端 / 其他跨平台框架 | ROADMAP §七 | 不补（独立决策门） |
| 自然语言/CLIP 语义搜索 UI | ROADMAP §七；当前 labels 子串检索是合规替代 | 不补；补中文标签映射不算自然语言 |
| 解析 C1 `.cos` / LR `.lrcat` / 完整 DAM / 跨工具目录迁移 | 05/40 册已立边界 | 不补；迁移中心只做 Gather 包 + XMP |
| 服务端托管的客户交付平台（Pixieset 形态） | 97 号 §11 已文档化 | 不补平台；但 S3/WebDAV 的"可用链接/发布状态"是缺口（C1） |
| 服务端强制到期/口令 | 前端口令门已明示边界 | 取舍；若客户交付要可审计，需服务端，属立项 |
| 集合层级 schema `parent_id` | `docs/README.md:33-35` 已把命名路径写成产品决策 | 取舍；长期需一次 `user_version` 迁移 |
| 第二屏只读镜像、淘汰移到 _rejects 不删除 | 20/05 册明示设计取舍 | 不补；只报"不自动选屏/确认无张数"等体验项 |
| 预览直方图基于 8bit 预览 | UI 已显式标注"基于预览" | 诚实边界；RAW 口径另立项（FRV 卖点） |
| 抓拍/联机拍摄 | Gather 是 C1 下游决策层，不是采集器 | 不补；采集在 C1 |
| AI 修图/retouch（Aftershoot Edit） | 定位是挑片/元数据，不做修图 | 不补；若未来做，属独立产品线 |
| C1 hot folder 无接口可检测 | C1 不暴露（sdef 无术语），已提示 | 取舍；只能提示不能检测 |

---

## 6. 建议路线

### Wave 5（约 2 周；目标：把"已做的"变成"默认可用/不写错"）

1. **C1 写回正确性（A1–A4 + X1）**：写前回读变体数/当前值，多变体让用户选目标或强制走 XMP；notFound 时 `browse` 到父目录重试；select 前 deselect；XMP 关键词不再写 `culling:*`；判断读取下沉到统一导入入口。S/M。
2. **挑片判读正确性（B1）**：compare*/survey 布局下键盘/按钮只作用于 current，批量写入显式给"作用于全部选中 N 张"开关并回显。S–M。
3. **浏览连续性（B2）**：布局切换不重置当前照片/游标续页；网格 `onAppear scrollTo(current)`；按 session 落盘 scope/filters/current/参考槽。S。
4. **交付发布闭环（C1）**：S3 预签名 URL（或显式公开只读开关）+ 可复制链接 + 发布记录（远端/photoId/版本）+ HEAD 差分 + 发布提升为一等入口。M。
5. **AI 初审接主入口（E1–E3）**：pipeline 接 Dashboard/加照片/摄取；默认引导开启；超时只停止等待不取消 job；初审前自动跑增量 face.analyze + duplicate.scan + navigation.analyze；控制中心显示"初审中/已生成 N 条/失败原因"。M（拆三步 S）。
6. **导入一次配置（C3）**：settings 存导入预设（模板/第二目的地/校验/去重/元数据模板）+ 模板静态校验 + 预检目标路径/冲突清单 + 失败全量/只重试失败项 + 第二目的地计数。S–M。
7. **格式白名单收敛（F4）**：三处收敛到 `PhotoFileTypes` 单一白名单，摄取/扫描结果显示"不支持格式 N 个（按扩展名）"。S。
8. **元数据高频交付字段（D1 + D3 的一半）**：先补 5 个 IPTC 高频字段 + 5 个受控值 Picker + 同义词检索展开。M。
9. **发布前真机矩阵**：跑完 96 号 C1-1..C1-10、第二屏、打印、Shortcuts、翻片延迟；否则上面"已闭环"不算数。S（执行成本）。

### Wave 6（约 4–6 周；目标：把"专业工作台"补齐）

10. **物理文件夹树 + 浏览即读（F1）**；同批 **批量重命名 + 文件移动（F2）**。M。
11. **场景/连拍最佳帧视图（E4）**：组折叠 + 组内按 quality 排序 + 一键保留最佳/淘汰其余；People Filter 进挑片页/Gallery；场景标签中文化 + 入口上移。M。
12. **RAW 嵌入 JPEG 快档（B3）** + 96 §5 翻片延迟实测。M。
13. **迁移包补组织资产（C2）** + 导入后自动重索引。M。
14. **自动化第二层（F3）**：先给"查询照片（按工作区/评分/关键词返回 ID）+ 写 rating/keep"两条命令（URL scheme + Shortcuts），再谈 CLI/AppleScript。M–L。
15. **位置/时间/互换（D2 + D3 剩余）**：GPS 编辑/GPX 反查；改拍摄时间（多机位对齐）；模板/词库导入导出；JPEG 内嵌重写或双源提示。M。

### 立项/观察（不承诺本次）

16. **感知级相似**：2–3 人日人工标注评估，把 ROADMAP 决策 A 从"待决策"变成"立项/不立项"（评估工具已就绪，见 95 号）。
17. **托管交付平台 / 发布服务**：若要替代 Pixieset/LR Publish（链接、账号、增量、状态、服务端强制）。
18. **虚拟副本/版本组 + 跨工作区集合 + catalog 级容器**：需要 schema/产品决策。
19. **色彩管理/软打样预览、幻灯片、多窗口、拖出、外部编辑器**：专业外设与集成层，决定"客户当面看片"和"与 PS/C1 协作"的体验。
20. **C1/LR catalog 导入**：若目标是"替代 LR 组织"则需重开 ROADMAP 边界。

---

## 7. 验证缺口与文档对账

1. **96 号真机矩阵未执行**：§12 记录表为空；C1-1..C1-10、第二屏、打印、Shortcuts、翻片延迟全部"未验"。本轮所有 C1 "已闭环"只是与本机 sdef 的文本级一致，**发布前必须跑**；尤其是 C1-3（变体写回）、C1-9（reject 往返）、§5（翻片延迟）。
2. **96 号 §9 已过时**：第 10 条"模板侧变量未接"已被收尾批（task-22）闭环；第 1 条 App Intents 元数据已由 `build.sh` + `check-appintents.sh` 闭环；第 9 条 NOT/集合/相对日期入口已闭环。建议下次维护时删除/改写。
3. **90 号台账口径漂移**：`90-wave-ledger.md:157` 仍写"reject→pick=false"，实际代码已改 keep-only（`C1.swift:287-297`，Wave4a A3）；以代码为准。
4. **竞品取证限制**：C1 帮助中心 403、Adobe 帮助正文 JS 渲染、Pixieset 403 —— 相关细节已标 [待核实]，本轮不用未核实细节下缺口结论。
5. **静态评审边界**：未 build/test、未实机 GUI、未做性能测量；"翻片慢/快"仍无实测秒数。

---

## 8. 分册索引

| 文件 | 域 | 一句话结论 |
| --- | --- | --- |
| `05-bridge-organize.md` | Bridge/组织横切 | 三条意图内缺口全闭环；剩格式链、文件夹树、批量重命名、自动化第二层 4 条 P1 |
| `10-c1-interop.md` | C1 互操作 | G1/G2 闭环、G3 只闭环 1/3；剩 P1×6（作用域/变体目标/判断入口/淘汰语义） |
| `20-culling-viewer.md` | 挑片/看图 | P0 全闭；最强新缺口是对比/Survey 批量写入目标错位 + 浏览连续性 + RAW 快档 |
| `30-ingest-export-delivery.md` | 摄取/导出/交付 | 3 条 P0 全闭；S3 交付件打不开（P0 风险）+ 发布无状态/增量 + 迁移丢组织资产 |
| `40-metadata-search.md` | 元数据/检索 | 2 闭环/3 部分/5 未闭；交付级 IPTC/CV、GPS、拍摄时间、同义词检索是硬缺口 |
| `50-ai-similarity.md` | AI/相似/语义 | 15 条无一条真正闭环；自动初审端到端/人脸前置/分组/最佳帧是主缺口 |

> 上轮评审：`docs/reviews/2026-11-10-competitive-gap/`（00 合成 + 7 分册 + 台账/验收/评估）。实现后独立评审：`97-post-implementation-review.md`。真机验收清单：`96-manual-acceptance.md`。
> 本轮全部新增文档仅在本目录；未改源码、未跑 build/test、未 commit。
