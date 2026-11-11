# 跨域结构性缺口（Lead 自证）

> 本文只收录"不属于单一功能域、但比单点功能更致命"的缺口，全部在仓库代码里复核过。
> 各功能域的明细见 10–50 号文件；综合结论见 `00-synthesis.md`。
> 证据写法：`相对路径:行号`（相对 `desktop/native/`）。标 `[待核实]` 的是需要在真机上确认的推断。

## 0. 参照系：Gather 到底在和谁比

Gather 不是 Capture One 的替代品，也不是 Adobe Bridge 的替代品。它是一条**窄而深**的"决策回路"：

```
Capture One（显影 + 变体 + 会话）  ──选中/文件夹──▶  Gather（挑片 + 相似度 + 人脸关键词 + 元数据写回）  ──XMP──▶  Capture One（重载元数据）
```

因此"功能残缺"要分三个参照系衡量，混在一起评会得出错误结论：

| 参照系 | 代表产品 | Gather 的目标关系 | 缺口的性质 |
| --- | --- | --- | --- |
| 挑片/审片 | Photo Mechanic Plus、FastRawViewer、Narrative Select | **同类竞品，直接对比速度与键盘** | 速度、全键盘、全屏、比较模式、AI 辅助 |
| 目录/组织 | Capture One（会话/目录）、Lightroom Classic、NeoFinder、Excire | **上游/下游邻居** | 目录模型、检索语言、标签体系、库级入口、交付 |
| 通用资产浏览 | Adobe Bridge | **"免费且已装"的默认替代品** | 格式广度、脚本自动化、Camera Raw 参数、输出面板 |

## 1. 模型层缺口

### 1.1 "工作区 = 一个根目录"与竞品的"会话/目录"不是一回事

`SessionAPI`（`gather-core/Sources/GatherProtocol/API/SessionAPI.swift:29-58`）把会话建模成"根目录 + 从该根目录导入的照片集合"，
`setSourceRoot` 是"为历史空根工作区修复根目录"。这带来两个竞品用户会立刻撞上的差异：

- **无法"打开一块盘/一个文件夹就开始看"**：Bridge / Photo Mechanic / FastRawViewer 是"浏览即读"，Gather 必须先建工作区（`NewSessionSheet`）。
  实拍场景"插卡/接盘，先扫一遍看看今天拍了什么"在 Gather 里是一次建模操作。
- **没有物理文件夹树**：全仓 grep `folderTree|physicalFolder` 0 命中；`RootShellSidebar` 的层级是工作区/页签，不是目录树。
  C1 的 System Folders、LR 的 Folders 面板、Bridge 的 Folder 面板都是"物理位置的真相"。Gather 只有工作区视角 + 跨区图库（`PhotoAPI.page_criteria`，`sessionId == nil` 即全局）。

结论：**这不是 bug，是产品取舍**，但对"我今天刚从卡里倒了一批图，先翻一遍"的入口缺一个轻量形态（例如"临时浏览"不落库、或"文件夹直读"模式）。

### 1.2 变体（Variant / Virtual Copy）在数据模型上不存在

- 逻辑资产（`PhotoFileTypes.rawExtensions` + `rawPairingExtensions`，`gather-core/Sources/GatherProtocol/Protocol/PhotoFileTypes.swift:25-36`）只表达"同一场景的 RAW 与 JPEG/HEIC/TIFF 是两个文件、折叠成一个资产"。
- `photos` 的一行对应一个物理文件；`PhotoRepo.preferredRowOrderSQL`（`.../Repositories/PhotoRepo.swift:183-185`）只决定"哪一行当代表"。
- 全仓没有"C1 Variant / LR Virtual Copy"的对应物：**同一个文件不能有多套评分/色标/关键词**。

这对 C1 用户是硬伤：C1 的核心工作方式就是"一个文件 → 多个变体（黑白/裁剪/客户版）→ 每个变体各自评级与出片"。
Gather 读完 XMP 只能看到"文件级的最后一次写入"，看不到"变体级的决策"。C1 的 Load Metadata 也是文件级，所以这条差异会一直存在，
除非 Gather 显式承认"只做文件级决策"并在 UI 上说清楚。

### 1.3 堆栈只能看不能建（API 有 / UI 无）

- `AlbumAPI` 有 `createStack/updateStack/deleteStack/addStackMembers/removeStackMembers/stackFolds`（`gather-core/Sources/GatherProtocol/API/AlbumAPI.swift`）。
- UI 侧只有 `Curation/StackFoldIndex.swift:1-20`（折叠徽标与索引）用到了 `stackFolds`；
  `createStack/``addStackMembers/``removeStackMembers/``updateStack/``deleteStack` 在 `gather-app/Sources/GatherUI` 里 **0 引用**（Lead 实测 grep）。
- 即：用户能看到折叠效果（如果库里有堆栈数据），但没有任何入口造出一个堆栈。竞品（Bridge 的 Stack、LR 的 Stacking）都是"选中→堆叠"一步。

### 1.4 资产候选/卷重连：接线在 Host 提供者，UI 侧只缺结果可见性（**2026-11-11 更正**）

`AssetAPI` 声明 `candidates/volumes/accept/reject/relinkRoot`（`.../API/AssetAPI.swift:1-20`），
**并非未接线**：GatherHost 的 `Providers/LiveLibraryDataProvider.swift:105-142` 已经把四个能力接到 UI 的 Library 数据提供者端口上，
UI 侧 `Library/LibraryViewModel.swift:171` 的注释只是历史残留。原判"UI 0 调用"来自只扫 `gather-app/Sources/GatherUI` 的字面量 grep，漏掉了 provider 端口这一层。
**真实缺口只是"结果不可见"**：relink 返回的改写文件数被丢弃（0 个匹配也静默成功），已在 Wave 1 修复（`LibraryViewModel+Load.swift` 捕获结果、`LibraryView.swift` 用成功横幅区分 N 个与 0 个）。
Bridge / LR 的"卷离线→重连→重新映射"是移动硬盘工作流的必备面；Gather 现在的形态是"能力有、可见性刚补"，仍缺"离线资产"的独立视图入口。

## 2. 自动化与集成面缺口（最被低估的一条）

**Gather 对外只有一个入口：`gather://import?file=…`。**

- `GatherUI/Support/Info.plist:42-51` 注册 URL scheme `gather`；`GatherHost/GatherAppDelegate.swift:16-46` 只解析 `host == "import"`。
- 无 CLI 子命令、无 AppleScript 字典（`sdef`）、无 Shortcuts/App Intents、无第三方插件 SDK、无"导出后执行命令/脚本"钩子。
- 对照面：Bridge 有 JavaScript/ExtendScript 脚本 + Batch 命令；Lightroom 有插件 SDK（LrExport/发布服务生态）；C1 有 AppleScript 能力面（Gather 自己就在用 `osascript` 反过来驱动 C1，见 `GatherHost/CaptureOneBridge.swift:316-318`）。

影响：专业用户的流水线是"脚本串起来的"（导入后跑命名/上传/备份/发客户）。Gather 只能被脚本"推"（导入），不能被脚本"用"（查询状态、批量决策、触发导出/写回）。
对一个"决策层"工具来说，这是把集成能力全部让给了下游。

## 3. 格式与解码缺口（有明确的用户可感知失效）

### 3.1 HEIC / HEIF / PSD 能导入，但解不出缩略图

- 索引与导入接受 `.heic .heif .psd`：`GatherApplication/Services/IndexerService.swift:67`、`Services/Ingest/IngestService.swift:290`、`GatherProtocol/Protocol/PhotoFileTypes.swift:29-36`。
- 但唯一的解码器白名单里没有它们：`GatherAnalysis/Image/RAWDecoder.swift:77-84` 只到 `.jpg .jpeg .png .tif .tiff .webp` + RAW 清单。
- UI 解码只经 `ImageDecodingRegistry` → `RAWImageDecoder` → `RAWDecoder`（`gather-app/Sources/GatherHost/RAWImageDecoder.swift:14-32`），**没有 NSImage/CGImageSource 兜底**（Lead grep `NSImage(contentsOf` 0 命中）。
- 结果：**iPhone 的 HEIC、修图交付的 PSD 会进库、能被统计，但网格/灯箱是空白占位符**。
  而 `rawPairingExtensions` 明确把 HEIC 当"RAW 配对侧"（`PhotoFileTypes.swift:34-35`），说明产品意图是支持 HEIC 的 —— 这是意图与实现的缺口，不是"不做"。

### 3.2 输出格式只有三种

`ExportFormat` = `original | jpeg | tiff`（`GatherProtocol/Protocol/Export.swift:23-28`），TIFF 压缩三选一。
没有 PNG / PSD / AVIF / JPEG XL / DNG 转换，也没有"仅元数据导出"独立形态（`includeMetadata` 是导出配方里的开关）。

### 3.3 无视频、无 PDF/AI/EPS/矢量、无音频

`RAWDecoder` 与 `PhotoFileTypes` 全为静态图；全仓 grep `video|Movie` 0 命中。
Bridge 的定位优势正是在这里（混装素材目录照常浏览）。Gather 是纯静态图工具，取舍明确。

## 4. 浏览与呈现缺口

- **无幻灯片/放映**：全仓 grep `slideshow` 0 命中。C1 的 Presentation、LR 的 Slideshow、PM 的全屏放映，是客户当面看片的标准形态。
- **无双窗/多显示器**：`RootView` 单 `WindowGroup`，无"在新窗口打开"、无第二屏审查窗口。
- **拖放只有三个落点**：`NewSessionSheet.swift:200`（拖目录建工作区）、`CollectionView.swift:313`（拖照片进集合）、`ExportView+Options.swift:132`（拖目标目录），
  且**没有向外拖出**（全仓 `NSFilePromiseProvider` 0 命中，只有 `CollectionView.swift:312` 的内部 `.draggable(photoId)`）。
  竞品里"从网格把照片拖到 Finder/微信/邮件/PS"是日常动作。
- **无色彩管理与软打样**：预览链路是 ImageIO 解码 → JPEG 中间态 → 显示；全仓无 ICC profile 选择、无显示器 profile 处理、无 soft proofing（`CGColorSpace` 只在灰度分析/导出里出现）。
  对一个"判断曝光与色彩是否过关"的工具，看的是"未校色的一跳"。C1 用户可以放心把 Gather 的预览当"参考"，但不能当"准"。

## 5. 输出与交付缺口

- **打印只有联系表**：`GatherUI/Export/PrintSupport.swift:1-30` 只把已有 PDF 交给系统打印面板；
  版面在 `GatherApplication/Services/Export/ContactSheetRenderer.swift`。**无单张打印、无多页排版、无打印前微调**。
- **交付是"静态站 + 手动上传"**：`Services/Output/GalleryBuilder.swift:1-25` 生成 `index.html/data.json/thumbs/large/proof.html`，
  `WebDAVPublisher.swift:1-12` 用 MKCOL/PUT 上传到用户自备 WebDAV，客户在 `proof.html` 里勾选后下载 `selection.json`，
  再用 `CullingAPI.importClientSelection` 导回。**没有托管链接、没有通知、没有在线评论/实时状态**。
  对照 Narrative Select / Pixieset / C1 Live：客户交付是"发一个链接"。
- **无 Publish Services / 社媒直发**：Bridge/LR 的发布服务生态（Flickr/500px/SmugMug）在 Gather 里没有任何对应物。

## 6. 规模与性能：都是"门"，不是"已证"

`docs/ROADMAP.md` 五节把 Release 门定 2 万、Stretch 门 10 万，但同页"未验证"栏写着"真实素材导入耗时/峰值内存、10 万规模表现、真实照片吞吐与质量"。
挑片工具的用户体验是**以"每张图 0.2 秒"为单位的**：C1/PM/FastRawViewer 的竞争力就在翻片延迟。
Gather 有分页、预加载、磁盘缩略图缓存（`PhotoThumbnailView.swift:562-595`），但**没有任何对外承诺的翻片延迟指标**，
这在与 Photo Mechanic / FastRawViewer 的直接对比里是无法辩护的位置。

## 7. 平台与生态

- macOS 26+ 独占（`Info.plist: LSMinimumSystemVersion 26.0`）。C1 也只有 macOS/Win；但 Bridge/LR 有 Win，客户交付更是全平台。
- 无移动端/网页端看片，无"摄影师在 iPad 上先粗筛"的形态（Narrative Select、LR mobile 都有）。
- 无云端同步（ROADMAP 明示不做）——这意味着**没有多机协作、没有助理/修图师共享同一批评分**。
- 无插件/脚本生态（见 §2），第三方无法扩展。

## 8. 结论：三类缺口的性质完全不同

| 类别 | 代表缺口 | 性质 | 处理建议 |
| --- | --- | --- | --- |
| **意图内的实现缺口**（该做没做完） | HEIC/PSD 解码、堆栈建不了、卷重连未接线、C1 回路依赖手动 | 缺陷，会直接让用户认为"这软件坏了" | 优先修，成本多在 S–M |
| **取舍造成的功能缺口**（明确不做） | 无 RAW 显影、无视频、无云同步、无 Win | 定位，不该补 | 只要在 UI/文档里说清楚，就不是问题 |
| **竞争力缺口**（同类产品已标准化） | 全键盘工作流、全屏比较、翻片延迟承诺、客户端交付链接、脚本自动化、层级关键词库/变量 | 决定"专业用户会不会留下" | 按 ROI 排，先做键盘/比较/延迟三件（都是 M） |
