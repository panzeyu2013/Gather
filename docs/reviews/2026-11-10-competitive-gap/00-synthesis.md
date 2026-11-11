# Gather 功能缺口评审：对照 Capture One / Adobe Bridge / 专用挑片与组织软件

> 评审日期：2026-11-10｜仓库基线：`88568372`（2026-11-05）
> 输入：六份分册（本目录 `05`、`10`、`20`、`30`、`40`、`50`），共约 105 条缺口、约 1,250 行证据。
> 方法：Gather 侧全部落到 `grep/read` 的 `相对路径:行号`；竞品侧以厂商官方页 `web_fetch` + 本机安装版（C1 `16.7.8.16` sdef、Bridge `14.0`、C1 Plugin SDK `1.0.1`）为准。
> 边界：**只谈功能残缺**（真实工作流缺哪一步、必须换工具去做），不评代码质量、不做性能 profiling、未跑 build/test、未实机点 GUI。
> 已知取证限制：本会话 `web_search` 端点 401、C1 帮助中心 Cloudflare 403、Adobe Help 正文超抓取上限、Camera Bits 文档站为 JS 壳 —— 相关竞品细节一律标 `[待核实]`，不据此下缺口结论。

---

## 0. 执行摘要（10 条）

1. **Gather 不是"功能少"，而是"回路没闭合"**。它在"决策→写盘→回传"这一段做了大量可靠性工程（`Confirmed<T>` 破坏性门控、持久化撤销栈、交付队列与冲突裁决、跨页选择快照、`_rejects` 物理隔离），这部分比多数竞品更严谨；断链几乎全部落在**跨软件、跨视角、跨阶段**的缝上。
2. **最硬的 3 条 P0 全在 Capture One 桥接上**（`30` 册 G1/G2/G3）：AppleScript 与 C1 16.7 字典**对象归属不符**（`selected variants` 属 application、variant 无 `path`）且 `on error` 吞错；`reload metadata` 传 document 而字典要求 variant，失败后**没有写 ack 的出口**→ `confirm/finalize` 永久 `XMP_CONFIRM_REQUIRES_SYNC` 死锁；读不到 C1 catalog/变体里的评级、色标、pick、关键词，导入已挑过的片等于从零开始。**"Capture One 伴侣"这个定位目前不成立。**
3. **唯一"必然导致换工具"的体验缺口是翻片速度链路**（`20` 册 #4）：`preloadThumbnails/preloadPreviews/prioritizeThumbnail` 与 `ImagePreloadService` 全部实现，但 **GatherUI 里 0 调用**；`RAWDecoder` 恒定 `kCGImageSourceCreateThumbnailFromImageAlways` 整解 RAW；`commit` 在 `isLoading` 时静默丢键。三者叠加 = "按 X 没反应 + 每张等一次 RAW 解码"。
4. **交付侧两处断层**（`40` 册 P0）：导出不能指定**色彩空间/ICC、DPI、输出锐化**，交付配方除名字与格式外**全部不可编辑**；客户交付**没有托管链接/口令/到期强制**，必须自备 WebDAV。这两条决定"Gather 能不能交付"，不只是"好不好用"。
5. **看图能力缺一层"专业看法"**（`20` 册）：单图无全屏/无干扰模式、无真 1:1（`scale` 是 fit 的 1..8 倍，⌘0 名不副实）、对比模式**只有当前格清晰**、无 Survey（>4 同屏）、无第二显示器/第二窗口。
6. **AI 是"半条链路"**（`50` 册）：判定信号（EAR 眼睛、微笑几何、人脸合焦、审美、512px 技术质量）与建议契约（20 个理由码 + 三档置信 + why popover + 整批 undo + 阈值校准）都在，但**"导入即初审"没有默认路径**（自动生成只活在挑片页 VM），`motion_blur` 实为"全局梯度<0.12"、`exposure` 只是灰度均值，全部判定跑 512/1280 缩略图；语义检索现实是 **Vision 英文标签子串匹配**（`labels` 分支 API 有 / UI 无，自然语言 UI 被 ROADMAP 显式排除）。
7. **元数据是"合格写入端，不是工作台"**（`10` 册）：32 个 IPTC 字段、XMP+IIM 双写、模板 preview/apply/undo、C1 映射都通；但**关键词库/受控词表/同义词无入口**（表与 `KeywordRepo` 都在、协议无方法）、**无变量/代码替换**、模板不能导入导出、GPS 只读、批量直改只能绕模板、检索只覆盖 11/32 字段。
8. **有三个"意图内的实现缺口"**（`05` 册）：HEIC/HEIF/PSD 可导入可计数但**解不出缩略图**（解码白名单缺它们、无 NSImage 兜底）；堆栈 **API 有 / UI 无**（能折叠不能新建）；资产候选/卷重连 **API 有 / UI 无**。
9. **组织能力对齐的是"工作区"，不是"目录"**（`05`/`40` 册）：无物理文件夹树、无目录导入/合并/迁移、集合无层级与集合运算、无虚拟副本/版本组、导入去重只在当前会话内生效。这是 C1 用户会立刻感知的模型差。
10. **不要误判的取舍**：无 RAW 显影、无视频、无云同步、无 Windows/移动端、不做自然语言 UI —— 这些是 ROADMAP 的明确决策，**不是缺口**。把精力投到第 2–4 条上，比补这些收益高一个数量级。

---

## 1. 分册口径与统计

| 分册 | 域 | 行数 | 缺口 | P0 | P1 | P2 | 最该补的 3 件事 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [05](05-cross-cutting.md) | 跨域结构性（Lead 自证） | 131 | ≈16 | 1（HEIC/PSD 解码） | 5 | 10 | — |
| [10](10-metadata-annotation.md) | 元数据 / IPTC / 关键词 | 226 | 17 | 0 | 10 | 7 | 关键词库+词表、批量直改+检索覆盖、IPTC 补齐+变量 |
| [20](20-culling-browse.md) | 挑片 / 浏览 / 比较 / 速度 | 221 | 22 | 1 | 11 | 10 | 预取接线、无干扰单图+1:1、对比每格清晰 |
| [30](30-c1-bridge.md) | C1 桥接与互操作 | 221 | 14 | 3 | 7 | 4 | 脚本契约+ack 兜底、变体级元数据通道、插件往返+可安装 |
| [40](40-ingest-export-organize.md) | 摄取 / 导出 / 组织 / 交付 | 216 | 22 | 3 | 14 | 5 | 交付规格闭环、托管式交付、导入一次配置 |
| [50](50-ai-culling.md) | AI 挑片 / 人脸 / 相似 / 检索 | 235 | 15 | 0 | 10 | 5 | AI 初审进导入、场景标签闭环、判定可信度分级 |

> 口径差异说明：各分册独立判级，同一条缺口在域内与跨域（`05`）的严重度可能差一档；本文件的 P0 清单以"用户会不会认为软件坏了 / 必须换工具"为准绳做过一次统一。

---

## 2. P0 / P1 合并清单（跨域去重后）

### 2.1 P0：不修就等于"这个软件是坏的"（8 条）

| # | 缺口 | 参照 | 现状（证据） | 修的形态 | 成本 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | C1 选中读取脚本与 16.7 字典对象归属不符，`on error` 吞错 → 用户选好片仍提示"请先选择照片" | C1 sdef；Bridge 无此问题 | `GatherHost/CaptureOneBridge.swift:421-436`；旧静态核对只查"存在"未查"归属"（`docs/validation/evidence/2026-10-31-v2-c1-static/conclusion.md:14-25`） | 改 application 级 `selected variants` + `parent image.path`；错误上浮不吞 | S |
| P0-2 | `reload metadata` 传 document（字典要求 variant）+ 手动 Load Metadata 无写 ack 入口 → `confirm/finalize` 永久死锁 | C1 是 per-variant；Bridge 由 C1 显式 Load 收口 | `CaptureOneBridge.swift:89-95,516-522`；门禁 `DeliveryCoordinator.swift:422-459`；确认不写 ack（`CullingViewModel+Writeback.swift:182-191`） | 按 variant 循环 reload；加"我已在 C1 Load"显式 ack；真机验收矩阵替代静态检查 | S/M |
| P0-3 | 读不到 C1 catalog/变体里的评级·色标·pick·关键词（不解析 DB/.cos，也不用 C1 已给的 `variant.rating/color tag/pick` 脚本面） | C1 sdef `:1071-1180`；Bridge 直读 XMP | 只读 XMP：`MetadataExtractionService` / `XMPProvider`；`CaptureOneBridge.swift:223-230` 明说不解析 `.cos` | 导入时用 AppleScript 读选中 variant 的 rating/色标/pick/keywords | M |
| P0-4 | 翻片链路：预取 API 全实现但 UI 0 调用 + 整解 RAW + 加载中按键静默丢弃 | PM/FRV/Narrative 都以"翻片零等待"为第一卖点 | `PhotoAPI.swift:46-52`；`ImagePreloadService.swift:58-70`；`RAWDecoder.swift:256-270`；`CullingViewModel+Actions.swift:342-343` | 三条接线：±2 预取、优先队列、单槽 pending commit + 忙碌指示 | S |
| P0-5 | 导出不能指定色彩空间/ICC、DPI、输出锐化；图片水印（logo PNG）协议有实现但 Plan 拒绝 | LR/C1/Bridge 的输出面板都是标配 | `Protocol/Export.swift:81-119`；`ExportService+Run.swift:263-278`；`ExportService+Plan.swift:299` | 扩 `ExportOptions` + 转换链 + UI 三控件 | M |
| P0-6 | 交付配方不可编辑（只有名字+格式；新建硬编码 85/2048），联系表/画廊参数不可配 | LR 导出预设 / C1 输出配方 / PM 模板 | `ExportView+Delivery.swift:170-215`；`ExportViewModel+Delivery.swift:91-92` | 配方编辑器（尺寸/质量/水印/命名/子目录） | M |
| P0-7 | 客户交付没有托管链接/口令/到期强制，只能自备 WebDAV；`expiresAt` 仅 advisory | Pixieset/SmugMug/Frame.io/LR Publish / C1 Live | `Output.swift:288-314`；`GatherProtocol/Protocol/ProofShare.swift:59-74`；`WebDAVPublisher.swift:1-12` | 最小：签名链接 + 到期 + 口令（可用对象存储/自建端，不必做平台） | L |
| P0-8 | HEIC/HEIF/PSD 可导入却解不出缩略图（解码白名单缺项、无兜底） | Bridge/PM/LR 全格式浏览 | `RAWDecoder.swift:77-84` vs `IndexerService.swift:67`/`IngestService.swift:290`/`PhotoFileTypes.swift:29-36`；无 NSImage 兜底（grep 0） | 白名单补 `.heic/.heif/.psd` + `CGImageSource` 直解兜底 | S |

> 这 8 条里 4 条是"S"（`≤2 人日`）——**两周内就能把"坏掉的观感"消掉**，这是本报告最重要的一条排期结论。

### 2.2 P1：日常每个工作流都撞一次（摘要，明细见各册）

- **看图/过片**：单图无全屏无干扰（`CullingGrid.swift:254-261` 只在网格）、无真 1:1、对比仅当前格清晰（`CullingWorkbenchViewer.swift:444,471`）、4 图预算被压到 4096、无 Survey、无 3 图布局、直方图/合焦/合焦掩膜无键位、"淘汰"确认框不写张数。
- **C1 回路**：pick/reject 不可往返（`culling:keep` 会污染词库）、变体模型不对齐、C1 Session 的 Capture/Selects/Trash 不识别（导入 session 根会把 Trash 淘汰件"复活"）、写回后 C1 是否看到靠盲发+500ms sleep、元数据/模板写回无 reload 通道却被 ack 门禁误伤、"在 C1 中显示"API 有/UI 无。
- **元数据**：无关键词库/同义词/受控词表 UI、补全不读词库、无变量/代码替换、模板不能导入导出、GPS 只读无反向地理编码、多选不能直改字段、检索 11/32 字段、受控值字段全是自由文本、JPEG 已有 .xmp 时内嵌 IPTC 清不掉、`personInImage` 与人脸流程脱节。
- **组织/交付**：集合无层级/无集合运算/无"属于某集合"字段、导入去重仅本会话、第二目的地不校验和、导入不可预演、无物理文件夹树、无目录导入/导出/合并、无导入后批量重命名、无子目录规则、无发布端点扩展、交付审计无校验和。
- **AI**：导入后不自动初审、场景/事件标签只采不写不筛（`SemanticIndex.swift:627-678` 有采集、`sceneGroups:396-451` 无消费者）、自然语言/中文语义检索不可用、无"人物×事件/场景"成品筛选、模糊/曝光不可解释不分型、判定分辨率上限 512/1280、最佳帧依据单薄且成组依赖文件名序号、感知级重复缺失、不学"你会挑哪张"、相似入口只有单张、语义索引按 session 建、AI 结果不进主检索面。

---

## 3. 三个参照系的结论

### 3.1 对照 Capture One：不是"差功能"，是"回路不成立"

Gather 的定位是 C1 的决策层，因此基线不是"功能数量"，而是**"在 Gather 做的决定，C1 立刻看得见"**。这条要求目前三处断裂：读不到（P0-3）、写回要手动 Load 且可能死锁（P0-2）、C1 的选中读取本身有静态缺陷（P0-1）。另外变体维度（image→variant）在 Gather 侧不存在，C1 用户"一个 RAW 三个变体各自评级"的工作方式无法表达（`05` §1.2、`30` G5）。
**结论**：P0-1/2/3 修完，Gather 才算"C1 伴侣"；变体级通道（`variant.rating/pick` 读写）决定它能不能成为"好用的伴侣"。

### 3.2 对照 Adobe Bridge：免费+通用+可编程的三重压力

Bridge 随 Creative Cloud 免费提供、原生 XMP、批量改名、Find/Collections、可跑 JS 脚本，并且能直接看 PSD/PDF/AI/视频。Gather 相对它缺的是三样：**格式广度**（HEIC/PSD 解不出来、无视频）、**自动化面**（只有一个 `gather://import` 深链，无 CLI/Shortcuts/AppleScript 字典/插件 SDK/导出后钩子）、**通用浏览**（无物理文件夹树、"浏览即读"要先建工作区）。Gather 的优势是"围绕挑片决策的深度"（相似度/人脸/写回可靠性）——这个优势只有在 P0-4 修好、翻片不比 Bridge 慢之后才成立。

### 3.3 对照专用挑片（Photo Mechanic / FastRawViewer / Narrative Select）：缺"看图这一半"

| 维度 | 竞品基线 | Gather |
| --- | --- | --- |
| 全屏 / 无干扰 | PM Preview、LR Loupe、FRV 全屏 | ✗ 仅网格有全屏按钮 |
| 真 1:1 | 全都有 | ✗ fit 相对 1..8×，⌘0 名不副实 |
| 对比清晰度 | 每格独立高清 + 同步缩放 | △ 同步 ✓ / 每格 ✗ |
| Survey（>4 同屏） | LR Survey、PM Contact Sheet | ✗ |
| 预取/零等待 | 三者第一卖点 | ✗ API 有 / UI 无 |
| RAW 口径直方图/过曝提示 | FRV 卖点、C1/LR 有 | ✗ 预览口径（已标注诚实） |
| AI 初审 | Narrative/Aftershoot 默认路径 | △ 有信号无默认路径 |
| 键盘可自定义 | 部分支持 `[待核实]` | ✗ 两处硬编码且已漂移 |

**结论**：Gather 在"判读"这一段落后一整代，而这一段恰好是用户拿来对比的第一印象。`20` 册的 Top3（预取接线 S、无干扰单图 S、对比每格清晰 M）是最划算的三件事。

### 3.4 对照 Lightroom（组织与交付的事实标准）

LR 是"组织+交付"的默认参照：色彩管理、Publish Services、打印模块、Survey、第二显示器、堆栈、智能集合、目录导入/合并、关键字库与同义词、变量与元数据模板 —— 这些在 Gather 侧**要么没有、要么是半成品**（`40` 册 22 条里 14 条 P1 都属于这一类）。Gather 无法也不需要复制 LR，但**导出规格、托管交付、集合运算、关键词库**这四项是"专业交付"的最低门槛。

---

## 4. 明确"不该补"的清单（防止把取舍当缺口）

| 项 | 依据 | 处理建议 |
| --- | --- | --- |
| RAW 显影/编辑、图层、曲线、局部调整 | `docs/ROADMAP.md` 七不做；`05` §8 | 不补。改为在 UI 明确"C1 是显影真相源"，并给"回 C1 看"的入口（`G10`） |
| 视频/PDF/AI/EPS | 同上 | 不补。若必须混装浏览，明确写"仅静态图" |
| 云同步、协作、多机 | 同上 | 不补。若要团队协作，只做"导出/合并"的最小形态（`40` #14） |
| Windows / 移动端 / Web 端 | ROADMAP 决策门 | 不补（评估另行立项） |
| 自然语言语义搜索 UI | ROADMAP 显式排除（CLIP 候选未落地） | 不补，但把已有 label 检索接到 UI（`50` #3 的一半是"API 有 / UI 无"） |
| 解析 C1 `.cos` / 写 catalog DB | `CaptureOneBridge.swift:223-230` 已立边界 | 不补；用 AppleScript 变体属性替代 |
| 与 C1 预览同色 | 同上 | 不补；改为显式提示"预览不含 C1 调整"（`G11`，UI 缺失） |

---

## 5. 补齐路线（按"两周见效"排）

### Wave 1（约 2 周，全 S）：把"坏掉的观感"消掉
1. C1 脚本契约 + ack 兜底（P0-1/P0-2）+ 真机验收矩阵替代静态字典检查。
2. 翻片接线（P0-4）：±2 预取、`prioritizeThumbnail`、单槽 pending commit、忙碌指示。
3. HEIC/HEIF/PSD 解码兜底（P0-8）。
4. 单图全屏/无干扰 + 真 1:1 + ⌘0 语义修正（`20` #1/#2）。
5. 顺手 5 件 S 级：堆栈新建入口（`05` §1.3）、卷重连接线（§1.4）、元数据页 reload 通道（`30` G9）、导入模板持久化（`40` #4）、"在 C1 中显示"接 UI（`30` G10）。

### Wave 2（约 4–6 周，M）：把"专业交付"补齐
6. 导出规格（P0-5）+ 配方编辑器（P0-6）+ 子目录规则 + 图片水印 + 联系表/画廊参数。
7. 对比每格清晰 + 3 图/Survey + 直方图/合焦键位（`20` #3/#6/#8）。
8. 关键词库/受控词表 + 变量/代码替换 + 批量直改 + 检索覆盖（`10` Top3）。
9. AI 初审接进导入 + 场景标签写回关键词 + scene/person facet（`50` Top3 前二）。
10. 集合层级与集合运算 + 跨会话导入去重（`40` #8/#9/#10）。

### Wave 3（L / 需立项）：决定"能不能替代"
11. 托管式客户交付（P0-7）：签名链接 + 口令 + 到期 + 通知。
12. 变体级 C1 通道（`variant.rating/pick/keywords` 读写）+ C1 Session 三目录识别。
13. 感知级相似/重复（embedding，需标注评估，ROADMAP 决策 A）+ AI 学习用户偏好。
14. 第二显示器/第二窗口、打印版面、目录导入/合并、自动化面（CLI/Shortcuts/AppleScript/插件 SDK）。

---

## 6. 证据与限制

- **已核实**：所有 Gather 现状均带 `相对路径:行号`，可在当前工作树复核；C1 能力面以本机 `Capture One 16.7.8.16` 的 `CaptureOne.sdef` 为准（`30` 册逐行标注 sdef 行号），这是本报告最强的外部证据。
- **未核实/受限**：`web_search` 401；C1 帮助中心 403；Adobe Help 正文只取到标题与 meta 摘要；Camera Bits 文档站为 JS 壳；Pixieset 403 / SmugMug 502。竞品细节已标 `[待核实]`，本报告不据此下缺口结论。
- **未做**：未 `swift build` / 未跑测试 / 未实机点 GUI / 未做性能测量。因此"翻片慢"是按代码事实判定（零预取 + 整解 RAW + 丢键），实测秒数待补。
- **待跟进**：`10` 册记录"Photo Mechanic Plus 已停售"（Camera Bits 博客 2026-03，`[待核实]`）——若成立，长期竞品对照应换成 Photo Mechanic 与 Aftershoot/Narrative 主战场。
