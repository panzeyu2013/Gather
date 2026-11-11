# Capture One 桥接与互操作缺口

> 评审范围：Gather ↔ Capture One（下称 C1）的双向数据流、C1 插件能力面、以 Adobe Bridge 为代表的"外部中转"工作流。
> 仓库基线：`88568372`（2026-11-05）。本机环境：Capture One `16.7.8.16`（`/Applications/Capture One.app`）、仓库内 C1 Plugin SDK `1.0.1`、Adobe Bridge `14.0`。
> 方法："Gather 现状"全部落到仓库 `grep/read`（`相对路径:行号`）；C1 能力以本机安装版 `CaptureOne.sdef` 与应用内字符串为准；Bridge 以本机安装版 + 官方帮助页为准。`web_search` 本会话不可用（401），改用 `web_fetch`/curl 直取官方页；C1 帮助中心被 Cloudflare 403，故只靠 KB 的细节标 `[待核实]`。
> 纪律：只谈"功能残缺"（真实工作流缺哪一步、必须换工具），不评代码质量、不做性能 profiling、未跑 build/test。
> 与其他分册的分工：`docs/reviews/2026-11-10-competitive-gap/20-culling-browse.md`（挑片/浏览）、`40-ingest-export-organize.md`（摄取/导出/组织）、`05-cross-cutting.md`（变体/自动化总论）已有交叉；本册只从**桥接与互操作**视角展开，重叠项只在需要闭环时点到。

---

## 0. 结论速览

- **一句话**：Gather 的 C1 集成目前是"文件级 XMP + 三条 AppleScript"的**单向快照**，不是"会话/变体级双向桥"；离"在别处挑完、C1 立刻可见"还差两层：脚本契约（G1/G2）与元数据通道（G3/G5）。
- **最硬的两条**：① C1→Gather 的选中读取脚本与 16.7 字典对象归属不一致，且错误被吞（G1）；② reload ack 只能由脚本成功写入，"手动 Load Metadata"没有写 ack 的入口，reload 失败即 confirm/finalize 死锁（G2）。
- **最容易被误判为"已实现"的三条**：写回确实落了 XMP 且 UI 有"同步…"菜单；但 C1 不主动读 XMP（G8）、metadata/template 模块没有 reload 通道（G9）、"在 C1 中显示"只有 API 没有 UI（G10）。
- **结构性缺失**：C1 的判断数据（rating/色标/pick/keywords/album/variant）默认在 catalog DB；Gather 不解析 DB/.cos，也不使用 C1 本就提供的可写 `variant.rating/color tag/pick` AppleScript 面（G3–G5）。
- **插件**：只有一个 Open With action、忽略 role、没有 Edit/Publish 插件、没有安装入口（G7/G14）；"往返"实际靠用户手动搬文件。
- **严重度分布**：P0 ×3（G1/G2/G3）、P1 ×7（G4–G10）、P2 ×4（G11–G14）。补齐顺序建议见 §4。

---

## 1. Gather 该域已实现能力（清单 + 代码证据）

### 1.0 一条完整链路的现状时序（按代码走查）

| 阶段 | 触发 | 实现 | 证据 |
| --- | --- | --- | --- |
| ① 从 C1 取"选中" | 菜单 ⌘⇧I / 工作台 C1 来源 / 插件深链 | AppleScript 读选中变体路径 → 以文件建新工作区（source=capture-one） | `GatherAppCommands.swift:54`；`MenuCopy.swift:39,50`；`GatherAppDelegate.swift:197-232`；`DashboardViewModel+Actions.swift:39-95`；`AppBootstrap.swift:515-531` |
| ② 在 Gather 判断 | 挑片页 | 星级/色标/keep/reject 落库（`photo_metadata_cache` 为真相源） | `CullingService+Commands.swift:139-155,615-630`；`CullingSharedRules.swift:16-25` |
| ③ 写盘 | 「写回 XMP…」/ 立即写入 | RAW→sidecar；JPEG auto→内嵌，有 RAW 兄弟则强制 sidecar；写 rating/label/keywords | `MetadataWriteRouter.swift:48-80`；`SidecarXMPProvider+Patching.swift:140-194`；`CullingSyncService.swift:341-375` |
| ④ 让 C1 读 | 手动按钮 / 自动协调器 | osascript `reload metadata of current document` → sleep 500ms → 写 durable ack | `CullingSyncControls.swift:33-40`；`CullingViewModel+Writeback.swift:141-163`；`C1RoundTripCoordinator.swift:203-221,325-370`；`CaptureOneBridge.swift:89-95,516-522` |
| ⑤ 收口 | 「已在 Capture One 加载」/「保留 XMP 并结束」 | confirm/finalize 受 `sessions.reload_acked_at` 门禁 | `DeliveryCoordinator.swift:422-459`；`CullingSyncService.swift:281-283,300-323`；`CullingSyncFlow.swift:29-52` |
| ⑥ 清理 | 「恢复原 XMP」/ 备份清理 | 只处理 synced 交付；外部改动标 conflict | `CullingSyncService.swift:285-340` |

这条链路有两个断点，全部在"跨软件"处：②之前（C1 的判断在 catalog DB，Gather 看不到）与④之后（C1 必须被显式通知才重读，且 ack 需要脚本成功）。见 §3 G1–G9。

### 1.1 C1 → Gather：两条入口，本质都是"一次性文件快照"

- **菜单「从 Capture One 导入」⌘⇧I**：`GatherAppCommands.swift:54` → `MenuCopy.swift:39,50` → `GatherAppDelegate.swift:197-232` → `AppBootstrap.swift:529-531`（`selectedPhotoPaths`）→ `AppImport.importFiles(source: "capture-one")`（`AppImport.swift:46-113`）。
- **读选中变体**：脚本 `selected variants of current document` + `path of img`，过滤"存在且绝对路径"（`CaptureOneBridge.swift:80-87`、脚本 `:421-436`）。
- **工作台「新建工作区」来源=C1**：四层预检通过后才读选中照片（`DashboardViewModel+Actions.swift:47-63`），建会话时 `source: SessionSource.captureOne`（`:77-81`）；预检 UI 在 `NewSessionSheet.swift:57-60,138-160,241-296`。
- **C1 插件「Send to Gather」**：只实现 `COOpenWithPlugin`，把 `task.files` 拼成 `gather://import?file=…` 交给 LaunchServices（`desktop/coplugin/GatherLink/GatherLink.swift:4-9,11-34,43-56`）；app 侧深链解析 `GatherAppDelegate.swift:17-45,141-154`，落地仍走 `AppImport` 文件分支并**新建会话**（`AppBootstrap.swift:515-527`）。
- **结论**：C1→Gather 只搬文件路径，不带 C1 的 rating/色标/pick/keywords/variant id/所在 collection，也不记录 C1 document（Session/Catalog）身份——会话行只有一个字符串来源标记（`AppImport.swift:73-76`）。这是快照，不是连接。
- **数据流定性**：没有"C1 session/catalog 文件夹解析"这一层——Gather 只按用户选定/插件传入的**文件集合**建会话；C1→Gather 是 AppleEvent 读一次选中 + 文件路径导入；Gather→C1 是 XMP 写盘 + AppleEvent reload（失败则退回 C1 菜单的 Load Metadata）。两者都不是持续同步。

### 1.2 Gather → C1：写 XMP（sidecar/内嵌）+ 手动或半自动 reload + ack 门禁

- **写哪里**：RAW 只能 sidecar；JPEG 在 auto 模式走内嵌，但同名 RAW 兄弟存在时强制 sidecar（`MetadataWriteRouter.swift:48-80`，尤其 `:59-61`）。
- **写什么**：`xmp:Rating`、`xmp:Label`（并维护 `photoshop:Urgency`）、`dc:subject`/`lr:hierarchicalSubject`（`SidecarXMPProvider+Patching.swift:140-194`）；挑片写回计划只有 rating/colorLabel/keyword 三种目标（`CullingSyncService.swift:341-375`）。
- **收口按钮**：「在 Capture One 中加载元数据」→ reload；「已在 Capture One 加载」→ confirmSync；「保留 XMP 并结束」→ finalize（`CullingSyncControls.swift:33-40,65`；文案 `GatherUI/Resources/en.lproj/Localizable.strings:179-196,431,443-444`）。
- **手动 reload**：`CaptureOneBridge.reloadMetadata`（osascript 成功后 **sleep 500ms** 再写 durable ack，`CaptureOneBridge.swift:89-95`）；脚本为 `reload metadata of current document`（`:516-522`）。
- **自动 reload**：协调器按会话合并、debounce 1.5s、串行、失败抑制（`C1RoundTripCoordinator.swift:203-221,325-370`）；手动与自动共用同一串行队列（`:279-295`）；失败发 `c1AutoReloadFailed`，UI 转非阻塞提示（`:366-367`；`CullingViewModel+Writeback.swift:167-176`）。
- **ack 门禁**：C1 已装时 confirm/finalize 必须已有 `sessions.reload_acked_at`（`DeliveryCoordinator.swift:422-459`；映射 `CullingSyncService.swift:281-283,300-323`）；按钮可用性由 `syncState+acked` 派生（`CullingSyncFlow.swift:29-52`）。
- **是否需要重启 C1**：不需要重启——XMP 写盘后 C1 只需读一次源文件元数据（菜单 Load Metadata 或 AppleScript `reload metadata`）；但"立即看到"依赖这一次读，自动 reload 失败时没有第二条可见路径（除非用户手动在 C1 执行菜单命令），见 G2/G8。
- **未装 C1 降级**：安装判定 `Composition/Core.swift:419-470`；自动 reload 短路（`C1RoundTripCoordinator.swift:203-216,328-331`；`AppBootstrap.swift:358-370`）；门禁随 `c1Required` 关闭（`DeliveryCoordinator.swift:444-448`）。但菜单项不因"未装 C1"置灰（`GatherAppCommands.swift:82-104` 只看 handler），点击后才报 `C1_NOT_RUNNING`。

### 1.3 预检、权限、插件分发

- 四层预检（可达/运行/自动化授权/文档打开）：`CaptureOneBridge.preflight`（`CaptureOneBridge.swift:247-294`；System Events 探针 `:404-405`、document 探针 `:409-415`）；工作台预检 `DashboardViewModel.swift:120-186`；设置页健康检查 `SettingsViewModel+C1Health.swift:1-120`。
- 错误码归一 `GatherProtocol/Protocol/C1.swift:44-62`；协议面 `:64-80`。
- 权限：`desktop/native/Gather.entitlements:5-8`（automation apple-events）、`GatherUI/Support/Info.plist:40-41`（NSAppleEventsUsageDescription）、深链 scheme `:42-52`。
- 插件分发：手工安装到 `~/Library/Application Support/Capture One/Plug-ins`（`desktop/coplugin/Makefile:41-47`，无 codesign 步骤）；release 内置到 app 的 `Contents/PlugIns/GatherLink.coplugin`（`desktop/native/build.sh:536-538`），删除构建机相对 rpath（`:544-565`）、无 Developer ID 时补 ad-hoc 签名（`:584-589`）。**app 内没有"安装 C1 插件"入口**（`gather-app/Sources` 搜 `coplugin|Plug-ins|插件` = 0）。
- 插件 Info：bundle id `com.gather.capture-one-link`、action id `com.gather.capture-one-link.importAction`、源 Info.plist 版本 1.0.0（`desktop/coplugin/GatherLink/Info.plist:11-22`；`GatherLink.swift:45`；release 版由 `build.sh:566-583` 注入 app 版本）；SDK 1.0.1 的框架路径与架构由 `desktop/coplugin/Makefile:1-15` 决定。

### 1.4 "API 有 / UI 无"清单（本域最典型的假完成）

| 能力 | API/实现侧证据 | UI 侧现状 |
| --- | --- | --- |
| 在 C1 中选中/显示这些照片 | `CaptureOneBridge.selectVariants`（`CaptureOneBridge.swift:111-185`，脚本 `:445-469`）；端口 `C1RoundTripPorts.swift:37-39`；组合根已接线 `AppBootstrap.swift:371-373` | **无 UI 调用点**：`gather-app/Sources` 中 `selectVariants` 只出现在协议/实现/测试；设计里的"在 C1 中显示 ⌘⇧O"（`docs/design/p1-next/plan-2026-10-30.md:889-896`）未落地 |
| "预览可能不含 C1 调整"提示 | `adjustmentHints`（`CaptureOneBridge.swift:228-230`）+ DTO `hasAdjustments/attributeNames`（`C1RoundTripPorts.swift:111-143`）+ API `LiveCullingAPI.swift:266-275` | 只用 `cropRect/angle` 画裁剪叠层（`CullingWorkbenchViewer.swift:334-345,854-856`）；`hasAdjustments/attributeNames` 无 UI 消费（与 `docs/reviews/2026-11-10-competitive-gap/20-culling-browse.md` 的预览问题同源） |
| C1 插件安装/检测/版本提示 | 插件内置在 app、`C1Installation` 可判 C1 是否安装 | 无设置页入口、无"插件未安装"提示、无文档指引 |
| 元数据/模板写回后的 C1 reload | `CaptureOneBridging.reloadMetadata` 端口存在 | `MetadataSyncBar` 只有确认/结束（`MetadataSyncBar.swift:202-227`），不调 reload；自动 reload 只由挑片页事件触发（`CullingViewModel.swift:431-447`） |

### 1.5 明确不存在的 C1 语义（代码/注释证据）

- **不解析 C1 catalog/session 数据库**：`CaptureOneBridge.swift:223-227` 明说不解析 `.cos`；全仓无 `.cocatalog`/`.cosdb` 读取实现（grep 0）。
- **不识别 Session 目录结构**：`Selects/Trash/Capture` 在 `gather-core/Sources` 0 命中；导入只分目录/文件（`AppImport.swift:20-28`），C1 session 根目录会被当普通目录递归。
- **不识别 Album/Project/Group/Smart Album**：C1 `collectionType`（`CaptureOne.sdef:685-692`）在 Gather 侧无映射；Gather 集合（Curation）不写回 C1（写盘只到 XMP）。
- **不识别 Variant**：Gather 逻辑资产是文件（`GatherApplication/Services/PhotoAssets.swift:3`：RAW/JPEG 折叠为一个逻辑资产），C1 的 variant/position/pick 无映射。
- **pick/reject 无写回表示**：`WritebackAttributes` 只有 `keywords/rating/label`（`GatherProtocol/Protocol/Core.swift:421-424`），`PickState` 只在 Gather 内部（`GatherProtocol/Protocol/Culling.swift:15`）。
- **不订阅 C1 选中变化**：C1 提供 application 级 `selection changed script`（`CaptureOne.sdef:240`），Gather 未使用（只有一次性读取）。

### 1.6 互操作矩阵（Gather 视角，本域口径）

| 动作 | Gather 支持 | 通道 | 备注 |
| --- | --- | --- | --- |
| 取 C1 当前选中项 | △ | AppleScript 一次性读 | 脚本对象归属有静态风险（G1） |
| 取 C1 选中项的评级/色标/pick/关键词 | ✗ | 无 | 只读已落盘 XMP（G3） |
| 把 C1 选中项放进已有工作区 | ✗ | 只能新建工作区 | 插件/菜单/深链三条入口都新建会话（`AppImport.swift:56-80`） |
| 把评级/色标写回并让 C1 立即看到 | △ | XMP + 手动/半自动 reload | C1 必须执行 Load Metadata（G2/G8） |
| 把 pick/reject 写回 | ✗ | 无 | 只写 `culling:keep` 一类关键词（G4） |
| 变体级读写 | ✗ | 无 | XMP 是文件级（G5） |
| C1 Session/Album 结构双向 | ✗ | 无 | 不识别（G6） |
| 从 Gather 回到 C1 定位照片 | ✗（API 有/UI 无） | AppleScript select | G10 |
| 插件往返（结果回 C1） | ✗ | 仅 Open With 单向 | G7 |
| 插件自动安装/更新/兼容检查 | ✗ | 手工/内置 | G14 |

---

## 2. 竞品基线

### 2.1 Capture One 16.7.8 自身（本机安装版字典/字符串 + 官网）

- **文档模型：Session vs Catalog**。`documentType` = session/catalog（`CaptureOne.sdef:308-310`），`document.kind`（`:368`）；Session 有 Capture/Selects/Trash 物理目录（`:393-405`）；Catalog 的容器为 favorite / catalog folder / album / group / project / smart album（`collectionType`，`:685-692`），文件夹型 collection 可用 `synchronize` 与磁盘对齐（`:2041-2050`）。官网把"session and catalog tools"列为核心能力（[features](https://www.captureone.com/en/features)）。
- **Variant 是第一类对象**：image→variants（`CaptureOne.sdef:1538-1542`）；variant 自带 `pick`（`:1084`）、`position`（`:1085`）、`color tag`（`:1096`）、`rating`（`:1097`）、`crop`/`adjustments`/关键字（`:1071-1180`），并支持 `add variant`/`clone variant`（`:1786-1790,1830-1836`）。**关键**：`rating/color tag/pick` 均为可写属性，且 `apply keyword` 以 variant 为目标（`:1886-1895`）——C1 自己的脚本面就能做"变体级"读写，不需要 XMP。
- **批量重命名**：`batch rename` 命令（`:2034-2040`）+ `batch rename options`（`:1595-1615`）+ 菜单 `COMMAND_BATCH_RENAME`（`en.lproj/COLocalizedStrings.strings:1568-1571`）。
- **输出配方（Process Recipe）**：recipe 类含输出格式/位深/JPEG 质量/ICC/缩放/裁剪/关键词库/评级/版权/GPS/水印/输出命名 token（`:821-900+`）；`process` 命令按 recipe 名批量出图（`:1765-1785`）。
- **Hot Folder**（C1 自己的"看文件夹自动导入"）：`COMMAND_HOT_FOLDER`/`COMMAND_HOT_FOLDER_PATH`，tooltip 明说"Automatically import the photos added to the selected Capture Folder or Hot Folder"（`COLocalizedStrings.strings:1622-1623,2312,3641-3644`）。
- **元数据的进/出是两个显式动作**：菜单 `Load Metadata`/`Sync Metadata`（`strings:1690-1691,2541-2542`）；AppleScript `reload metadata`（读源文件）/ `sync metadata`（写回源文件）都以 variant 为对象（`sdef:1852-1859`）；另有"自动应用来自文件或 sidecar XMP 的裁剪"偏好（`strings:5877-5878`）。
- **AppleScript 面远大于 Gather 用到的 3 条**：`select`/`deselect`/`change selection`（`:1956-1985,2137-2150`）、`import`（`:1986-1996`）、`export originals`（`:1997-2005`）、`batch rename`、`process`、`apply keyword`、`browse`（`:678-684`）等。
- **插件体系**：Open With 三角色——OpenOriginal（Open With 菜单）、PostProcessInDocument（Edit With 菜单）、PostProcessOutput（配方输出下拉）（SDK `Docs/html/Constants/COOpenWithPluginRole.html`）；另有 Editing/Publishing/VariantProcessing 协议。C1 16.7.8 自带 `CaptureOnePlugins.framework` 为 `1.0.1`；仓库 SDK 包为 1.0.1（其 framework Info.plist 记 1.0.0）——ABI 静态匹配，未实机加载验证 `[待核实]`。插件跑在独立 `COPluginHost` XPC 进程（本机存在 `COPluginHostApple.xpc`/`COPluginHostIntel.xpc`；SDK `Readme.md:11`），拿不到 C1 内部状态。官方插件页：[C1 plug-ins](https://www.captureone.com/en/partnerships/plug-ins)。

### 2.2 Adobe Bridge 14.0：C1/PS 之间的"无库 XMP 中转层"

本机安装 `/Applications/Adobe Bridge 2024/Adobe Bridge 2024.app`（`CFBundleShortVersionString=14.0`）。官方帮助目录（本会话逐页 200）证明其工作方式：

- **无需入库即可浏览任意文件夹**，元数据面板直接读写 XMP（[about-metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)、[view-and-edit-metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/view-and-edit-metadata.html)）；JPEG 的元数据更新会生成 XMP sidecar——官方排障页标题即"XMP file created on Metadata update for JPEGs in Adobe Bridge"（[链接](https://helpx.adobe.com/bridge/desktop/troubleshoot/xmp-file-jpeg.html)）。
- **评级/色标/关键词是母语**：[label-and-rate-files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html)、[use-keywords](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/use-keywords.html)、[metadata templates](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/create-metadata-templates.html)。
- **批量动作/改名**：[batch-rename-files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/batch-rename-files.html)；跨应用批量任务用 [create-workflows](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/create-workflows.html)/[run-workflows](https://helpx.adobe.com/bridge/desktop/fix-and-prep-photos/run-workflows.html)。
- **组织**：[use collections](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/use-collections.html)；**打开/往返**：[open files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/open-files.html)、Camera Raw/Photoshop 集成（[Camera Raw 排障页](https://helpx.adobe.com/bridge/desktop/troubleshoot/bridge-crashes-on-opening-image-in-camera-raw.html) 从侧面证明 Bridge→ACR 是常规路径）。
- 边界：Adobe 帮助页正文由脚本渲染，本会话只取到官方目录/页面标题；能力名可证，逐字行为 `[待核实]`。

### 2.3 为什么用户会在 C1 与挑片工具之间来回

1. **C1 是"重"的一端**：Catalog 越大浏览越慢；变体、配方、批量重命名、Tether、输出都在 C1。快速过 1 万张/连拍对比/跨卡批筛，用户会换更快的挑片器（内部审计承认产品定位是 C1 伴侣、用户肌肉记忆来自 C1/Lr/PM/Bridge/访达：`docs/reviews/2026-10-30-interaction-audit/20-hci-review.md:18`）。
2. **C1 的"判断"默认不落盘**：rating/色标/pick/keywords/所属 album 在 catalog 数据库；跨软件只能靠 XMP，而 C1 交换判断数据的常规入口是显式的 Load/Sync Metadata（`strings:1690-1691,2541-2542`；AppleScript `sdef:1852-1859`；另有"自动应用 sidecar XMP 裁剪"偏好 `strings:5877-5878`）。任何"在别处挑片"的方案都绕不开这一步。
3. **C1 是流程的终点**：变体（多版本）、Process Recipe、批量重命名、Hot Folder/Tether 只存在于 C1；挑片工具负责前端判断，最终仍要回 C1 出图（`sdef:821-900,2034-2050`；Hot Folder `strings:3641-3644`）。
4. **Bridge 是另一条"中间层"路径**：不建库、直接浏览文件夹、读写 XMP，再把文件送进 Camera Raw/Photoshop；专业流程常见"C1 导出 → Bridge 评级/加关键词 → ACR/PS → 回 XMP → C1 Load Metadata"。Gather 目前在两条路径上都只占"文件级 XMP"这一小段。

### 2.4 三者分工定位（本域视角）

| 环节 | C1 | Bridge | Gather（现状） |
| --- | --- | --- | --- |
| 浏览/挑片 | 重但完整（variant/album） | 轻量、无库 | 快（本仓库主战场） |
| 判断数据存放 | catalog DB（+可选 sidecar） | XMP sidecar | 自有 SQLite + XMP 投影 |
| 组织容器 | Session/Album/Project/Smart Album | Collections/工作区 | 工作区 + 集合（不出库） |
| 输出规格 | Process Recipe / 批量重命名 | 导出预设 / 批处理工作流 | 单次导出（配方化不足，见 40 册） |
| 与外部交换 | AppleScript + 插件 + XMP Load/Sync | XMP + ACR/PS 直连 | XMP + 少量 AppleScript |

---

## 3. 功能缺口表

> 读法：严重度 P0=不补就用不起来/必须换工具；P1=日常明显摩擦；P2=锦上添花。补齐成本 S/M/L/XL。

| # | 缺口 | 竞品怎么做（产品+链接） | Gather 现状（代码/文档证据） | 用户影响场景 | 严重度 | 补齐成本 |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | C1→Gather 的 AppleScript 与 C1 16.7 字典**对象归属不一致**：`selected variants` 是 application 属性，脚本却写 `of current document`；variant 无 `path`（`path` 属于 image）；`select v` 又把 variant 当直接参数（字典要求 document + variant）。失败被 `on error` 一律吞成空串 | C1 自带脚本面：`selected variants`（application，`sdef:244-247`）、`parent image`/`file`（`:1071-1081`）、`image.path`（`:1538-1542`）、`select`（`:1956-1985`） | 脚本 `CaptureOneBridge.swift:421-436,445-469`；静态比对 `docs/validation/evidence/2026-10-31-v2-c1-static/conclusion.md:14-17,19-25`（做了"存在"核对，未核对归属）；ROADMAP 亦承认"C1 人工 Load-Metadata 矩阵"未接通（`docs/ROADMAP.md:40`） | 明明选了 30 张，菜单提示"请先在 Capture One 中选择至少一张照片"（`GatherAppDelegate.swift:211-215`）；只能改用 Finder/拖拽 | **P0** | S |
| G2 | 写回收口依赖 reload ack，但 reload 脚本传的是 document，而字典的 `reload metadata` 直接参数是 **variant**（`sdef:1852-1855`，仅 variant 响应 `:1176`）；失败后"手动在 C1 Load Metadata"**没有任何入口写 ack** | C1 明确是 per-variant：`reload metadata <variant>`；Bridge 场景由 C1 显式 Load 收口 | `CaptureOneBridge.swift:89-95,516-522`；ack 门禁 `DeliveryCoordinator.swift:422-459`；UI 需 `acked && hasWritten` 才可确认（`CullingSyncFlow.swift:29-52`）；confirm 不写 ack（`CullingViewModel+Writeback.swift:182-191`） | reload 失败时 confirm/finalize 永远报 `XMP_CONFIRM_REQUIRES_SYNC`，备份与交付行无法清理；用户只能手工作业或等另一模块触发一次成功 reload | **P0** | S/M |
| G3 | 读不到 C1 Catalog/Session 里的评级、色标、关键词、pick、所属 album：不解析 catalog DB/.cos，只能读已落盘 XMP；而 C1 默认存 DB（是否自动写 sidecar 未验证） | Bridge 直接读 XMP 显示 rating/label/keywords（[label-and-rate](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html)、[about-metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)）；C1 脚本可读 `variant.rating/color tag/pick/keywords`（`sdef:1071-1180`、`:1886-1895`） | 只读 XMP：`MetadataExtractionService.swift:161-182,212-224`；不解析 `.cos`（`CaptureOneBridge.swift:223-227`）；catalog DB 读取实现 0 命中 | C1 里已挑好的片导入 Gather 后星级/色标/关键词全空，必须先在 C1 执行 Sync Metadata；用户在两个软件里重复挑片 | **P0** | L（或 M：AppleScript 读 variant 元数据） |
| G4 | pick/reject 不可往返：写回只有 rating/label/keyword；`culling:keep` 作为关键词写入会污染 C1 词库；C1 的 `variant.pick` 无法表达 | C1：`variant.pick` 可写（`sdef:1084`），"Move to Selects"（`strings:1307-1308,1644-1646`）；Bridge：用 rating/标签组合表达淘汰 | 计划 `CullingSyncService.swift:341-375`；`WritebackAttributes` 无 pick（`Core.swift:421-424`）；`PickState` 仅内部（`Culling.swift:15`） | 用户淘汰 200 张后 C1 看不出任何痕迹，回 C1 需重做 | **P1** | M |
| G5 | Variant 模型不对齐：Gather 逻辑资产=文件（RAW/JPEG 按 stem 折叠），C1 的 image→variant 是另一维度（同一 image 的多版本）；写回按文件、读也按文件，XMP 本身是文件级 | C1：image→variants（`sdef:1538-1542`），`position/pick/rating` 在 variant（`:1071-1097`）；reload/sync metadata 也 per-variant（`:1852-1859`）；可用 AppleScript 直接写 variant 属性 | `PhotoAssets.swift:3`；写回目标 `MetadataWriteRouter.swift:48-80`；`selectVariants` 按 path 匹配（`CaptureOneBridge.swift:445-469`），无 variant 身份 | 同一 RAW 的 3 个变体在 C1 里被写成同一评级；变体级取舍被抹平（与 05 册 §1.2 同源） | **P1** | L |
| G6 | 会话/项目/相册不双向：C1 Session 的 Capture/Selects/Trash、Catalog 的 album/project/smart album 在 Gather 无对应物；导入 session 根目录会把 Selects/Trash 当普通目录 | C1：三目录（`sdef:393-405`）、容器（`:685-692`）、folder collection `synchronize`（`:2041-2050`）；Bridge 的 collections 只服务自身 | 导入只分目录/文件（`AppImport.swift:20-28`）；`Selects/Trash` 在 core 源码 0 命中；Gather 集合不写回 C1（写盘只到 XMP） | 从 C1 session 根导入：Selects 内容被当普通资产扫入、Trash 淘汰件"复活"，Album/Project 结构丢失 | **P1** | M |
| G7 | C1 插件能力面过窄且语义不区分：只实现 Open With 一个 action、忽略 `pluginRole`（也会出现在 Edit With/配方输出菜单）；无 Editing/Publishing 插件 → 无法把结果回传 C1；回调只有文件路径 | C1 插件三角色（`COOpenWithPluginRole`），另有 `COEditingPlugin`（Edit With，结果回 C1）/`COPublishingPlugin`；官方[插件页](https://www.captureone.com/en/partnerships/plug-ins) | `GatherLink.swift:4-9`（`pluginRole _`）、`:11-34`；SDK `Docs/html/Protocols/COEditingPlugin.html`、`COPublishingPlugin.html`、`Constants/COOpenWithPluginRole.html` | 在 C1 "Edit With" 里点 Gather，C1 会先处理成 TIFF/JPEG 再交给 Gather（新建衍生文件工作区），不是原 RAW；Gather 挑完无法一键"回 C1" | **P1** | M/L |
| G8 | 写回后 C1 是否"立刻看到"要手动 Load Metadata；自动 reload 是盲发 + 固定 sleep，不验证 C1 已读；C1 改图后 Gather 缩略图不失效 | C1 的 Load/Sync Metadata 菜单与 AppleScript；Bridge 改 XMP 后由 C1 Load 收口 | `CaptureOneBridge.swift:89-95`（500ms 后写 ack）；`MetadataSyncBar.swift:42-53`；缩略图缓存不失效（`F-display-infrastructure.md:23-40`） | 双方状态不一致：Gather 显示"已同步"，C1 里仍是旧星级；C1 调完色回 Gather 看图没变，误以为写回失败 | **P1** | M |
| G9 | 元数据/模板写回没有 C1 reload 通道，但同样受 ack 门禁：状态条显示"待 C1 重载"，点"确认同步"会撞 `XMP_CONFIRM_REQUIRES_SYNC` | Bridge/ACR 无此门禁概念；C1 用显式 Load 收口 | `MetadataSyncBar.swift:42-53,202-219` 只 confirm/finalize；reload 调用点仅 Culling/Face/Similarity + 协调器；门禁 `DeliveryCoordinator.swift:430-459`；自动 reload 只由挑片页事件触发（`CullingViewModel.swift:431-447`） | 只做 IPTC/模板写回的用户卡在"无法确认/无法清理"，须先去挑片页触发一次成功 reload | **P1** | S |
| G10 | 没有"在 C1 中显示/选中"的 UI（API 有/UI 无），也没有"让 C1 打开某目录/会话"；C1 的选中变化也不订阅 | Bridge 打开文件到 ACR/PS 是显式菜单动作；C1 有 `select`（`sdef:1956-1985`）与 `browse`（`:678-684`）、`selection changed script`（`:240`） | API：`CaptureOneBridge.swift:111-185`、端口 `C1RoundTripPorts.swift:37-39`、接线 `AppBootstrap.swift:371-373`；UI 0 调用点；目标见 `plan-2026-10-30.md:889-896` | 在 Gather 挑完想回 C1 看大图/调色，只能自己回忆文件名去 C1 里找 | **P1** | S |
| G11 | 预览不含 C1 调整（色彩/曲线/局部），只有 `crs:Crop*` 叠层；"预览可能不含 C1 调整"的提示没做 UI（与 20 册重叠，本册只记桥接侧） | C1 自身预览=渲染结果；Bridge 走 ACR 渲染 | `CaptureOneBridge.swift:223-230`；叠层 `LiveCullingAPI.swift:266-275` + `CullingWorkbenchViewer.swift:334-345`；`hasAdjustments` 无 UI 消费 | 用户在 Gather 判断"可出片"，回 C1 发现是另一张效果，挑片结论不可靠 | **P2** | M（或明确承诺边界） |
| G12 | C1 Hot Folder / Capture 目录与 Gather 的 ingest/淘汰移动无协同：Gather 摄取目的地必须在会话 source 内、淘汰移到 `<root>/_rejects`；若该目录被 C1 设为 Hot Folder 会重复导入 | C1 Hot Folder 自动导入新文件（`strings:1622-1623,3641-3644`）；folder collection 可 `synchronize`（`sdef:2041-2050`） | `SessionIngestRunner.swift:55-62`（目的地必须 source 内）；`IngestService.swift:125-141`；`RejectedMover.swift:2,52`（`_rejects`）；Gather 无 Hot Folder 检测/提示（grep 0） | Gather 摄卡与 C1 Hot Folder 同时开启，同一批照片在 C1 出现两份；淘汰件被 C1 重新导回 | **P2** | S |
| G13 | C1 未安装/多版本降级粗糙：菜单不置灰、点击才报错；安装判定只靠 bundle id/固定路径；脚本无版本能力矩阵 | C1 菜单随文档类型显隐；Bridge 无此问题 | `GatherAppCommands.swift:82-104`；`C1Installation`（`Composition/Core.swift:419-470`，bundle id 仅 15/16/17 + 两个旧 id，路径仅 3 个）；`CaptureOneBridge.swift:417-419`（app 名正则） | 非 C1 用户看到菜单以为可用；C1 装在非常规路径时 ack 门禁被误关（当作没装） | **P2** | S |
| G14 | C1 插件安装/发现/兼容无产品面：内置在 app 但无入口、无版本/兼容检查、无更新；ad-hoc 签名 + 相对 rpath 依赖构建脚本清理 | C1 官方 Plugin Manager / 双击安装 `coplugin`（SDK `Readme.md:15-17`）；官方插件页可分发 | `build.sh:536-597`（内置 + 清 rpath + ad-hoc 重签）；`Makefile:41-47`（手工 install）；app/Sources 无插件入口；SDK 1.0.1 vs 本机 C1 framework 1.0.1（仅静态匹配，旧/新版本 `[待核实]`） | 用户不知道插件存在；从 app 包内翻 PlugIns 目录安装几乎不可发现；升级 C1 后插件是否仍加载无提示 | **P2** | S/M |

### 3.1 四条真实场景里的断点（把缺口串起来看）

1. **婚礼摄影：C1 拍完 → 想快速挑 3000 张**。用户大概率直接在 C1 里给星级/色标（catalog DB），然后打开 Gather 想用相似度/人脸关键词。现实：Gather 只能读到"已 Sync Metadata 落盘的 XMP"（G3），且"从 C1 导入"脚本本身有静态风险（G1）；即使导入成功，variant/album 结构也丢了（G5/G6）。→ 用户要么先在 C1 全选 Sync Metadata 再导入（多一步且可能很慢），要么放弃 Gather。
2. **Gather 里挑完 → 回 C1 出图**。用户在 Gather 标了 3 星/淘汰，点"写回 XMP"成功；回到 C1 却看不到变化（G8），点"在 Capture One 中加载元数据"若脚本失败，就永远无法"确认同步/清理"（G2），备份 XMP 越积越多。淘汰决策在 C1 完全不可见（G4）。→ "伴侣"体验退化成"两个软件各挑一遍"。
3. **只做 IPTC/关键词模板的批量写回**。用户在元数据页批量套模板 → 写盘成功 → 状态条显示"待 C1 重载"，但该页没有 reload 通道（G9），"确认同步"撞 `XMP_CONFIRM_REQUIRES_SYNC`；用户不知道要先去挑片页触发一次成功的 C1 reload。→ 非挑片类工作流被 C1 门禁误伤。
4. **（插件路径）C1 里右键 Send to Gather**。插件把路径拼成 `gather://import`，每次都新建工作区（`AppImport.swift:56-80`），无法"加入已有工作区"；在 Edit With 菜单里点它，拿到的是 C1 处理后的衍生文件而不是 RAW（G7）；装插件本身还要用户自己去 app 包里找（G14）。

---

## 4. 该域"最该补的 3 件事"

### 4.1 先把 AppleScript 契约在真机跑通，并给"手动 Load Metadata"一条写 ack 的出口（P0，S/M）

- **理由**：G1/G2 是"要么能用、要么全废"的两条主链路（导入选中项、写回收口）。两者都卡在 C1 16.7 的 sdef 契约上，且失败被 `on error` 吞掉（`CaptureOneBridge.swift:421-436`），用户看到的是"你没选照片/请先 Load Metadata"，而不是"桥接坏了"。若 reload 失败，`XMP_CONFIRM_REQUIRES_SYNC` 会把 confirm/finalize 永久锁死。
- **最小可行形态**：
  1. 选中读取改为 application 级 `selected variants`，路径用 `parent image` 的 `path`（或 `file of v` 转 POSIX）；
  2. `reload metadata`/`sync metadata` 改为对选中 variant 循环调用；`select` 改为 document + variant 参数形式；
  3. 去掉 `on error return ""`，让 `C1_SCRIPT_FAILED` 上浮到 UI（现有错误码已具备，`GatherProtocol/Protocol/C1.swift:44-62`）；
  4. 新增"我已在 C1 手动 Load Metadata"的显式 ack 入口（写 `sessions.reload_acked_at`），让门禁有兜底；
  5. 把 ROADMAP 的"C1 人工 Load-Metadata 矩阵"（`docs/ROADMAP.md:40`）落成一台真机验收清单（导入/写回/确认/清理各一次），替代"静态字典检查"。
- **验收**：C1 16.7 真机上，选 10 张 → 导入成功 10 张；写回 10 张 → 自动/手动 reload 后 C1 星级变化可见；断网/未授权/无文档三种失败都有明确错误码且不阻塞 confirm 兜底。

### 4.2 把"元数据通道"升级为变体级、可免手动（P0/P1，M/L）

- **理由**：G3/G4/G5/G9 的根因是 Gather 把 XMP 当唯一通道，而 C1 的判断数据主要在 catalog DB、且以 variant 为单位。C1 脚本面其实已提供可写的 `variant.rating/color tag/pick/keywords`（`sdef:1084-1097,1886-1895`）——这是不用解析 `.cos` 也能做的变体级读写。只要用户先在 C1 里挑过片，Gather 现在等于从零开始。
- **最小可行形态**（不承诺解析 `.cos`、不写 catalog DB）：
  1. 导入时通过 AppleScript 读选中 variant 的 `rating`/`color tag`/`pick`/`keywords`/parent image 路径，落成 Gather 的 culling decisions 与 keyword 索引；
  2. 写回时按 variant 展开（同一文件多 variant 不互相覆盖）；pick/reject 用 `variant.pick` 或 rating/色标可逆约定，不要用 `culling:keep` 污染词库；
  3. 识别 C1 Session 目录（Capture/Selects/Trash）为特殊目录：Selects 不重复导入、Trash 不扫描或标"已淘汰"；ingest/淘汰移动时提示 Hot Folder 冲突；
  4. 给 metadata/template 模块一个"最小 reload + ack"出口（或明确该模块不参与 C1 门禁）。
- **验收**：C1 里 3 个 variant 分别 3 星/5 星/未评级 → 导入 Gather 后按 variant 显示；在 Gather 改为 1 星后写回 → C1 三个变体只有目标那个变化；淘汰件在 C1 显示为 pick=false。

### 4.3 插件从"单向发送"升级为"往返 + 可安装"（P1，M）

- **理由**：G7/G10/G14 说明插件现在只是把 C1 菜单接到 `gather://import`，既不能回传结果，也不区分 Open With/Edit With 语义；同时用户根本发现不了它（内置但无入口）。C1 插件体系本来就提供 Edit With/Publish 两种"结果回到 C1"的路径。
- **最小可行形态**：
  1. 设置页加"安装/更新 Capture One 插件"（拷贝到 `~/Library/Application Support/Capture One/Plug-ins`，提示重启 C1，显示已装版本）；同时按 `pluginRole` 过滤，避免在 Edit With/配方输出里误现；
  2. 插件动作增加参数（新建会话 vs 加入现有会话），URL 带 `sessionId`/`collection`/`variant id`，让 Gather 能把结果对回 C1；
  3. 方向反过来：Gather 侧提供"在 C1 中显示"（复用已存在的 `selectVariants`，G10），作为往返闭环的最小一环；
  4. 文档写清"C1 Load/Sync Metadata 是必要动作"，并给"已加载/已同步"的对账步骤（配合 4.1 的 ack 兜底）。
- **验收**：设置页一键装插件 → C1 重启后 Open With 出现 Send to Gather；Gather 挑完点"在 C1 中显示" → C1 前台并选中对应照片；插件升级版本后 app 能发现并提示更新。

### 4.4 本域明确"不做/不承诺"（避免制造新的假缺口）

- 不解析 `.cos`/不写 C1 catalog DB/不承诺"预览含 C1 色彩"：仓库已把它写成边界（`CaptureOneBridge.swift:223-227`；`docs/design/p1-next/plan-2026-10-30.md:900-905`）。可行的替代是用 AppleScript 让 C1 导出临时渲染图（计划里已有默认关闭的 `c1_rendered_preview` 方案，`plan-2026-10-30.md:905`）。
- 不为了"自动 reload"绕过 TCC：`Gather.entitlements:5-8` 与 `Info.plist:40-41` 已声明自动化权限，失败必须显式报错而不是静默重试。
- 不把 XMP 当唯一通道：C1 在线时用 AppleScript 做变体级读写，XMP 只做"C1 未运行/批处理"的离线兜底与 Bridge 互通。

### 4.5 落地顺序与依赖（建议给 Lead 的排期口径）

| 顺序 | 事项 | 依赖 | 估算 | 可验证结果 |
| --- | --- | --- | --- | --- |
| 1 | C1 16.7 真机脚本矩阵 + 修 G1 脚本 + "手动 Load" ack 入口（§4.1） | 一台装 C1 16.7 的机器 + TCC 授权 | S–M | 导入/写回/确认/清理四条链路各跑通一次，失败可复现可上报 |
| 2 | 元数据模块的 reload/ack 出口（G9）与 C1 状态真实性（G8 的 ack 语义） | 1 | S | 只做 IPTC 模板也能走完 confirm/finalize；"已同步"不再依赖盲发 |
| 3 | 导入时读 variant 元数据 + variant 级写回（§4.2，G3–G5） | 1 | M–L | C1 里已有的星级/色标/pick 在 Gather 首屏可见；写回按 variant 落地 |
| 4 | 插件安装入口 + role 过滤 + "在 C1 中显示"（§4.3，G7/G10/G14） | 1（需要脚本 select 可用） | M | 设置页一键装；C1 选中/前台可见；插件菜单语义正确 |
| 5 | Session 目录识别与 Hot Folder 冲突提示（G6/G12） | 3 | M | C1 session 根导入不重复、不复活淘汰件；ingest 前有冲突提示 |

> 不建议在 1/2 之前做 3/4/5：脚本契约没跑通时，任何"变体级读写/插件往返"都建立在一段**可能根本调不通的 AppleScript** 上，验收无法区分"功能没做"与"脚本被字典拒了"。
