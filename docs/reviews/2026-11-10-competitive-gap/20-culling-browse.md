# 挑片 / 浏览 / 比较 / 速度 —— 竞品缺口评审

> 评审范围：Gather 挑片页（`desktop/native/gather-app/Sources/GatherUI/Culling/` 35 文件 / 9,436 行）在"过片—判读—标记—前进"这条主链上的**功能完整度**，对照 Photo Mechanic Plus、FastRawViewer、Narrative Select、Capture One、Lightroom Classic。
> 方法：Gather 侧只读静态审计（read / grep / wc），未 `swift build`、未跑测试、未实机点 GUI；行号基于当前工作树（2026-11-10）。竞品侧用 web_fetch 抓取厂商文档页核实，**凡抓不到原文的细节标 [待核实]**。
> 只评估"功能残缺"（用户真实工作流缺哪一步 / 必须换工具），不评估代码质量、不做性能 profiling。
> 已知内部审计 `docs/reviews/2026-10-30-interaction-audit/B-culling.md`、`F-display-infrastructure.md` 的结论被复用但未照抄：本文所有条目都重新在代码里定位过锚点。

---

## 0. 结论速览

1. **单图查看器的"看法"其实缺一层**：布局有 1/2/4/网格（`CullingGrid.swift:12-20`），缩放有 ⌘−/⌘0/⌘= 与滚轮（`CullingWorkbenchViewer.swift:136-152,769`），但**没有全屏 / 无干扰模式**（全屏按钮只存在于网格头部 `CullingGrid.swift:254-261`），也**没有真正的 1:1（100% 像素）档**——`scale` 是相对 fit 的 1..8 倍，"100%"胶囊在 fit 时也显示 100%（`:121`），⌘0 标着"实际大小"却执行 fit 复位（`:655-660`）。
2. **对比模式的"同步"做到了，"每格都清晰"没做到**：2/4 图共用一套 `scale`/`offset`（`:35,44,411-412`），所以同步缩放/平移天然成立；但**可见区域细节贴片与所有叠加层只贴/只画"当前格"**（`:444,471`），非当前格在高倍下是 2560px 基准位图放大 → "并排判合焦"这个对比的根本目的在 4× 以上不成立。
3. **速度链路上有一处"API 有 / UI 无"**：`PhotoAPI.preloadThumbnails / preloadPreviews / prioritizeThumbnail`（`gather-core/Sources/GatherProtocol/API/PhotoAPI.swift:46-52`）与 `ImagePreloadService`（`GatherApplication/Services/ImagePreloadService.swift:58-70`）都实现了，但 **GatherUI 里 0 个调用点**（grep "preload" 在 `Sources/GatherUI` 只命中注释）；图库灯箱自己写了 `prefetchAdjacent`（`Gallery/LightboxView.swift:313-335`），挑片页**没有**。翻片 = 每张现解。
4. **RAW 只有一条路径**：`RAWDecoder` 全部走 `kCGImageSourceCreateThumbnailFromImageAlways: true`（`gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift:258-263`）→ 缩略图/预览都整解 RAW，没有"嵌入 JPEG 快速档"开关；放大后才用 `CIRAWFilter` 做区域解码（`:193-204`）。而 C1 调完色的图在 C1 里，Gather 显示的是相机 RAW 的 ImageIO 渲染——两者不是同一张图。
5. **P0 一条：翻片速度链路**（无预取 + 逐张整解 RAW + 加载中按键被静默丢弃 `CullingViewModel+Actions.swift:342-343`）。除此之外没有"必须换工具"的硬阻断；其余多为 P1 摩擦。

---

## 1. Gather 该域已实现能力（清单 + 代码证据）

| # | 能力 | 代码证据（相对路径:行号） | 说明 |
|---|---|---|---|
| 1 | 四种布局：单图 / 2 图 / 4 图 / 网格 | `GatherUI/Culling/CullingGrid.swift:12-20`；`CullingWorkbench.swift:37-52` | 网格是第 4 种布局而非独立页签；`setPageLimit` 网格 200 / 其它 500（`CullingView.swift:52`） |
| 2 | 对比选片规则（显式 2/4 张优先，否则当前 ±相邻） | `CullingComparison.swift:8-32` | 显式选择必须包含当前照片，否则退化为邻接取 |
| 3 | 对比**同步**缩放/平移 | `CullingWorkbenchViewer.swift:35,44`（单一 `scale`/`offset`）+ `:411-412`（每格各自 `scaleEffect/offset`） | 一套状态驱动全部单元格 → 天然同步；换布局/翻页/人脸对齐显式复位（`:286-294`） |
| 4 | 缩放输入：捏合、滚轮、⌘−/⌘0/⌘= | `:566-574`、`:746-773`、`:136-152` | 滚轮按窗口归属 + 代理视图 bounds 命中（`:761-773`）；范围 1..8，**相对 fit** |
| 5 | 放大后按可见区域解码（tiled detail） | `CullingWorkbenchViewer.swift:444-469`、`RAWDecoder.swift:130-185` | 150ms 去抖（`:662-689`）、按格数收窄预算（`:381`，`PhotoThumbnailView.swift:57-63`） |
| 6 | 裸键 P/X/U/空格/0-5/6-9 + ←→ | `CullingWorkbenchViewer.swift:212-271` | 带 ⌘/⌥ 组合一律让给系统（`:227-229`） |
| 7 | 查看器初始聚焦（修过"必须先点图片"） | `CullingWorkbenchViewer.swift:203-206`（`.focusable()`+`.focused()`+`.onAppear{viewerFocused=true}`） | 与网格布局互斥，不会互抢 |
| 8 | 直方图（预览口径）/ 合焦掩膜 / AF 点 / 只读裁剪框 / 参考对比（并排·分割·叠加） | `ViewerOverlays.swift:74-130,191-340`；查看器接线 `:299-333,471-503` | 直方图/合焦像素来自**已显示的预览位图**，不二次解码（`:786-829`）；按钮在缩放条右侧（`:156-190`） |
| 9 | 网格：justified 布局 + 键盘映射 + ⌘A 全选（走服务端 selection） | `CullingGrid.swift:89-125,331-365,392`；`CullingViewModel+Grid.swift:64-79` → `CullingAPI.selection`（`CullingAPI.swift:50-52`） | ⌥1-7 色标、裸6-9 红/黄/绿/蓝（`:98-117`） |
| 10 | 底部胶片条（100pt 缩略图 + 色标线 + 星级 + 决策点 + 文件名） | `CullingFilmstrip.swift:20-104,110-227` | 横向单 ScrollView；尾部 4 格自动 `loadMore`（`:75-81`）；当前照片自动滚动（`:96-102`） |
| 11 | 翻片：上一张/下一张 + 位置计数 + 统计 | `CullingInfoBar.swift:21-48`；`CullingViewModel+Actions.swift:533-573` | 到达已加载窗口末尾时后台 `loadMore` 后继续前进（`:542-556`） |
| 12 | 跨页选择与批量（服务端 hash 快照 + "仅当前可见"第二动作） | `CullingSelectionSnapshot.swift:1-28`；`CullingViewModel+Actions.swift:464-478`；确认链 `CullingView+DestructiveActions.swift:101-126` | 跨页批量不符则零写入并清空失效选择（`+Actions.swift:453-460`） |
| 13 | 撤销/重做（按操作、持久化、文本焦点让位） | `CullingViewModel+Actions.swift:71-78,575-627`；`Protocol/Culling.swift:389-403`；`CullingView.swift:162-179` | 一次 commit = 一条 `CullingHistoryOperation`（含逐张 before/after），存在 DB 里 |
| 14 | 淘汰 = 移动到 `_rejects`（不删除），按资产展开、按张 skipped | `CullingAPI.swift:46-48`；`RejectedMovePlanner.swift:13-70`；`CullingViewModel+Actions.swift:137-160` | 共享 .xmp 只在"实际会移动"的行上处理（`RejectedMovePlanner.swift:48-49`） |
| 15 | 写回只覆盖 rating / color_label / keyword | `GatherApplication/Services/Culling/CullingSyncService.swift:341-375` | **保留/淘汰标旗不进 XMP**（C1 也没有对应 XMP 字段），见缺口表 #10 |
| 16 | 状态记忆（部分） | `CullingView.swift:36-40`（layout/gridDensity/sort）、`:66`（inspector）、`Support/SessionStore.swift:23-50`（内存 workspace） | 跨导航/新窗口保 layout/排序/检查器；筛选/范围/当前照片只在内存 |
| 17 | RAW 解码路径 | `GatherHost/RAWImageDecoder.swift:11-40` → `GatherAnalysis/Image/RAWDecoder.swift:111-119,236-270` | 缩略图/预览 = ImageIO 整解（`:258-263`）；区域解码 = `CIRAWFilter`（`:198-203`） |
| 18 | 客户校样（导出 HTML + 回收 selection.json） | `CullingAPI.swift:44-45`（`importClientSelection`）；`GatherApplication/Services/Output/ProofFeedbackService.swift:239,364-368` | 与 Narrative 的"客户评审"同类，但走文件往返 |

**已达标、无需补的**（避免误报）：破坏性动作的类型门控（`Confirmed<T>` 只能从确认分支构造）、影响面先于确认（相似组/跨页批量）、跨页选择不清空、撤销栈持久化、缩略图并发闸门与磁盘缓存键含 mtime。这些在同类工具里也属上游水平。

### 1.1 一次典型挑片会话在 Gather 里的实际路径（代码走查）

以"打开会话 → 挑完 500 张 → 淘汰件移出 → 回 Capture One 剪"为主线，逐段看代码是怎么接的：

1. **进页**：`CullingView` 从 `SessionWorkspace` 取 VM（`CullingView.swift:76-80`），`loadNavigation`+`loadPage` 取第一页（`CullingViewModel+Load.swift`），布局默认 `.single`（`CullingView.swift:36`）。
2. **看第一张**：`CullingWorkbench` 判定布局后挂查看器（`CullingWorkbench.swift:44-52`），查看器 `onAppear` 抢焦点（`:206`），`PhotoThumbnailView` 以 `size: 2560`（`PhotoDetailTier.baseDimension`）当场解 RAW；此时**没有任何预取**，先出现占位底色再出图。
3. **标记**：按 P/X → `onKeyPress`（`:212-271`）→ `commit(patch:shouldAdvance:true)` → `culling.update`（`CullingAPI.swift:23`）→ 服务端写 `culling_decisions` + `photo_metadata_cache` 镜像（`CullingService+Commands.swift:143-174`）→ 返回 `states` 就地回显 + `refreshSilently`（`+Actions.swift:451-452`）。**这一步是同步等待**：`isLoading` 期间下一次按键被 `guard !isLoading` 丢掉（`:342-343`）。
4. **翻片**：`advanceCurrent` 只改 `currentPhotoId`（`:533-560`），到已加载窗口末尾才 `loadMore`（`:542-556`）；每次变更触发 `resetTransform`（`CullingWorkbenchViewer.swift:292-294`）与新的整图解码。
5. **横向比较**：切 `compare2/compare4` → `CullingComparison.assets` 选 2/4 张（`CullingComparison.swift:8-32`）→ 共用的 `scale/offset` 同步缩放（`:411-412`）→ 但只有当前格有贴片（`:444`）。
6. **批量**：网格里 ⌘A → `selectAllInScope` → `culling.selection`（`CullingGrid.swift:392`、`CullingViewModel+Grid.swift:64-79`）→ 跨页批量走 `CullingSelectionSnapshot` + hash 校验的确认弹窗（`CullingView+DestructiveActions.swift:101-126`）。
7. **淘汰移出**：`moveRejected`（`CullingAPI.swift:46-48`）→ `RejectedMovePlanner.plan` 按资产展开、按张 skipped（`RejectedMovePlanner.swift:50-70`）→ 文件进 `<sessionRoot>/_rejects`，**不删除**。
8. **写回**：`writeback` → `buildCullingWritebackPlan` 只生成 rating/label/keyword 三类属性（`CullingSyncService.swift:341-375`）→ 写 `.xmp` sidecar（`GatherMetadataIO/SidecarXMPProvider+Patching.swift:161-183`）→ C1 侧人工 Load Metadata。
9. **离开**：layout/sort/检查器留 `@SceneStorage`（`CullingView.swift:36-66`），筛选/范围/当前照片随内存 workspace 蒸发（`Support/SessionStore.swift:23-50`）。

缺口就分布在这条链的第 2、3、4、5、8、9 步上：**第 2/4 步慢、第 3 步丢输入、第 5 步对比不清晰、第 8 步旗标不落地、第 9 步回不到上次**。


---

## 2. 竞品基线（按产品分节）

> 抓取限制：本机 `web_search` 端点返回 401（host 配置问题，非本仓库问题），只能用 `web_fetch` 直连厂商页；**Capture One 帮助中心被 Cloudflare 挡回 403**，其条目细节标 [待核实]。

### 2.1 Photo Mechanic Plus（Camera Bits）
- **Ingest**：拷卡即重命名/加变量/写入 IPTC，可同时落两个目的地；**Contact Sheet** 是它的主界面（缩略图 + 排序 + 星级 + 色标 + Tag），**Preview 窗口**支持全屏、fit/100%、拖拽平移、2–4 图 Compare 与同步缩放。见厂商产品页与帮助中心：<https://home.camerabits.com/products/>、<https://docs.camerabits.com/>。变量（`{seqn}` 等）与"结构性拖拽"（把缩略图拖到文件夹/收藏夹完成归类）是它把"挑片"和"归档"压在同一步的核心，[待核实] 具体菜单路径。**速度**是它的定位：缩略图渲染优先于完整解码。
- 对 Gather 的意义：Gather 的"胶片条 + 网格 + 单图"结构与之同源，但 PM 的**全屏 Preview + 100% 切换 + 2–4 图同步对比**是一套完整闭环，Gather 目前各缺一半。

### 2.2 FastRawViewer（LibRaw）
- 定位原文："The Only Real **WYSIWYG Raw Viewer**…see RAW exactly as a converter will see it"，并明确对比 **embedded JPEG 预览 + JPEG 直方图 vs RAW 数据直方图**的差异；功能面含 **Grid Mode / 高光检查（Highlight Inspection）/ 屏幕锐化**，主打"extremely fast and reliable culling"。<https://www.fastrawviewer.com/>、<https://www.fastrawviewer.com/features>
- 对 Gather 的意义：Gather 的直方图取自 8bit 预览位图并显式标注"基于预览、不能当曝光工具"（`ViewerOverlays.swift:191-195`，`GatherAnalysis/Preview/PreviewAnalysis.swift:8-9`）——同一件事 FRV 用它当**卖点**（RAW 口径直方图 + 过曝/死黑提示），Gather 诚实地承认做不到。这是"功能残缺被文档化"的典型。

### 2.3 Narrative Select
- **AI 辅助挑片**：Scenes View（场景分组）、Close-Ups Panel（近景/人眼面板）、**Face Assessments**（失焦、闭眼判定）；导入 RAW/HEIC "几乎立刻"可开始审核（页面原文 "Start reviewing images almost instantly…Import thousands of RAWs in seconds. No wait times, no converting."）；核心交互沿用摄影师熟悉的快捷键/布局，并含 ingest、重命名、裁剪。产品还分 Select / Edit / Publish 三件套，客户评审属 Publish 一侧 [待核实]。<https://narrative.so/select>
- 对 Gather 的意义：Narrative 把"AI 先过一遍 + 人在可信的快速翻片器上复核"做成默认路径；Gather 有技术质量建议（`CullingAPI.generateTriage/applyTriage` `CullingAPI.swift:30-33`）与 CullingTriageCard，但**翻片器本身的判读能力（1:1/全屏/预取）弱于 AI 输出的可信度要求**。

### 2.4 Capture One
- **Viewer + Compare Variant + 星级/色标/Filters** 是 C1 的挑片台；Sessions 概念（Capture/Select/Output/Trash）让"淘汰"有物理归宿；官方 features 页引用的摄影师原话直接提到挑片体验："it's a great tool when **culling through a large amount of photos. Previews load quickly** and smart folders make the whole process a lot more pain free."<https://www.captureone.com/en/features>
- Compare Variant（并排比两张变体）、Viewer 的 fit/100%/平移、以及"移到 Trash"在 C1 的**具体菜单与快捷键**未能从厂商帮助中心核实（Cloudflare 403），标 [待核实]。
- 对 Gather 的意义：Gather 的定位就是 C1 伴侣，所以"C1 里怎么看、Gather 里就该怎么看"是用户预期基线；Gather 现在缺的正是 C1 Viewer 的"全屏 + 100% + 对比变体"三件套。
- 关于 C1 的 **culling 工具**是否含"曝光提示/对焦区域"叠加：[待核实]。

### 2.5 Lightroom Classic
- 帮助中心明确覆盖：**Loupe / Grid / Compare / Survey** 四种浏览视图、**辅助挑片（Assisted Culling，导入时或事后）**、**堆栈（stacks）**、**旗标/色标/星级**、**第二显示器显示图库**、**查看对焦点**、**色彩管理**、**保存元数据到 XMP sidecar**。见 <https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html>；关联条目 <https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-focus-points-in-photos.html>（对焦点）、帮助中心导航中的 "Display the Library on a second monitor"（第二显示器）、"Select best images while importing with Assisted Culling"、"Group photos into stacks"、"Color management"。
- 对 Gather 的意义：**Survey 模式**（N 张同屏，可超过 4）与**第二显示器**是 Lightroom 挑片的两条"工作台级"能力，Gather 都没有（见缺口表 #6、#12）。

### 2.6 能力矩阵（本域口径，✓=具备 / △=部分 / ✗=缺 / ?=[待核实]）

| 能力 | Gather | PM Plus | FastRawViewer | Narrative Select | Capture One | Lightroom Classic |
|---|---|---|---|---|---|---|
| 全屏/无干扰单图 | ✗ | ✓ | ✓ | ✓ | ✓ | ✓（Loupe） |
| 真 1:1（100%）档 | ✗（fit 相对 1..8×） | ✓ | ✓（WYSIWYG） | ✓ | ✓ | ✓ |
| 2 图对比 + 同步缩放 | ✓ | ✓ | ✗（主打单图过片） | ✗（以 AI 判读替代） | ✓（Compare Variant） | ✓（Compare） |
| 4 图对比 | △（仅当前格清晰） | ✓ | ✗ | ? | ? | △（Survey 替代） |
| Survey / N>4 同屏 | ✗ | ✓（Contact Sheet 大图模式） | ✓（Grid Mode） | ✓（Scenes/Close-ups 面板） | ? | ✓（Survey） |
| 嵌入 JPEG 快速档 | ✗ | ✓ | ✓（并明确反对用它） | ✓（"秒开 RAW"） | ✓（预览缓存） | ✓（智能预览） |
| 预取 / 翻片零等待 | ✗（API 有 / UI 无） | ✓ | ✓ | ✓ | ✓ | ✓ |
| RAW 口径直方图 | ✗（预览口径，已标注） | ✗ | ✓ | ? | ✓ | ✗ |
| 过曝/死黑图像提示 | ✗（仅直方图百分比） | ? | ✓ | ? | ✓ | ✓（直方图 clipping） |
| 对焦点提示 | ✓（AF 点叠加） | ? | ✗ | ✓（eye/focus assessments） | ? | ✓（View focus points） |
| 第二显示器 | ✗（单窗口） | ?（多窗口） | ? | ? | ? | ✓ |
| 旗标/星级/色标 | ✓（旗标仅本地） | ✓ | ✓（星级/色标） | ✓ | ✓ | ✓ |
| 淘汰物理隔离 | ✓（`_rejects`，不删除） | ✓（移到子目录/回收站） | ✓ | ? | ✓（Session Trash） | △（从目录移除） |
| 撤销 | ✓（持久化历史栈） | ? | ? | ? | ✓ | △（部分操作） |
| 客户评审闭环 | △（导出 HTML + 回收 JSON） | ✗ | ✗ | ✓（Publish/Client） | △（Capture One Live） | △（Web 共享） |
| 快捷键可自定义 | ✗ | ? | ? | ? | ? | ✗（基本固定） |

矩阵用途：判断"Gather 是不是必须补"，而不是给竞品打分。结论是 Gather 的**优势集中在"决策→写盘→C1 回传"可靠性**（旗标/批量/确认/撤销/物理隔离），**劣势集中在"看图与过片"这一段**——恰好是竞品最成熟、也最容易被用户拿来对比的一段。

---

## 3. 功能缺口表

> 严重度：P0 = 不补就用不起来 / 必须换工具；P1 = 日常明显摩擦；P2 = 锦上添花。成本：S（≤2 人日）/ M（1 周级）/ L（2–4 周）/ XL（>1 月）。

| # | 缺口 | 竞品怎么做（产品+链接） | Gather 现状（代码/文档证据） | 用户影响场景 | 严重度 | 补齐成本 |
|---|---|---|---|---|---|---|
| 1 | **无全屏 / 无干扰查看**：单图布局没有任何全屏入口，全屏也不隐藏检查器/胶片条/信息条 | PM Preview 全屏看图；Lightroom Loupe 全屏（帮助页 "browse and compare photos"）；FRV 全屏窗口 | 全屏按钮只在网格头部 `CullingGrid.swift:254-261`；单图查看器无对应控件（`CullingWorkbenchViewer.swift` 全文无 `toggleFullScreen`）；`.inspector` 常驻可展开（`CullingView.swift:146-159`），胶片条只能手动折叠（`CullingFilmstrip.swift:50-60`）；主菜单只有 5 项、无"显示/全屏"（`Support/MenuCopy.swift:106-110`） | 13" 屏上判合焦要手动关检查器 + 折胶片条 + 再找系统绿灯；客户在旁边看片时无法一键进入专注模式 | P1 | S |
| 2 | **无真 1:1（100% 像素）档**：缩放是"fit 的 1..8 倍"，没有"缩放到 100% 并居中"的命令 | PM/LR/C1 均有 100% / fit 双档；FRV 以 1:1 WYSIWYG 为卖点 | `CullingWorkbenchViewer.swift:95`（`effectiveScale`）、`:121`（fit 时也显示 "100%"）、`:655-660`（⌘0 = 复位到 fit，但 help 文案写"实际大小（⌘0）" `:143-145`）、`:733-743`（±1.15 步进，无 1:1 锚点） | 判合焦只能"滚到看起来像"；每次都要重新找位置；跨图比对焦时缩放级不同 | P1 | S |
| 3 | **对比时只有"当前格"是清晰的**：细节贴片与所有叠加层只贴当前格 | PM/LR 对比视图每格独立高清 + 同步缩放 | 贴片条件 `cell.asset.photo.id == currentAsset?.photo.id`（`CullingWorkbenchViewer.swift:444`）；叠加层同条件（`:471`）；非当前格只有 `PhotoThumbnailView(size: detailBaseSize=2560)`（`:402-412`）；4 格预算被压到 4096（`:381` + `PhotoThumbnailView.swift:57-63`） | 4 图对比放大到 4× 以上，除当前格外都是糊的 → "并排判哪张更实"这个动作做不了，只能逐张单图放大再凭记忆比 | P1 | M |
| 4 | **挑片页无相邻预取；预取 API 有实现但 UI 零调用** | PM/FRV/Narrative 都以"翻片零等待"为第一卖点；Gather 自己的图库灯箱也预取 ±1/±2 | API：`GatherProtocol/API/PhotoAPI.swift:46-52`；实现：`GatherApplication/Services/ImagePreloadService.swift:58-70`、`GatherHost/APIs/LivePhotoAPI.swift:321-353`；**GatherUI 内 grep `preload`/0 命中**；灯箱侧自建 `prefetchAdjacent`（`Gallery/LightboxView.swift:313-335`） | 2000 张婚礼片逐张按 →：每张等一次 RAW 解码（`RAWDecoder.swift:258-263` 整解），没有任何预热 | **P0** | S |
| 5 | **所有缩略图/预览都整解 RAW，无"嵌入 JPEG 快速档"** | FRV 文档直接对比"embedded JPEG 预览"与 RAW 数据两条路径；PM/Narrative 均以缩略图优先渲染换速度 | `RAWDecoder.swift:256-270` 恒用 `kCGImageSourceCreateThumbnailFromImageAlways: true`；`getThumbnail/getPreview` 同一条 `decodeScaled`（`:111-119,236-254`）；设置里只有 `thumbnail_size/quality`（`GatherProtocol/Settings/SettingsKey.swift:54-55`），无解码路径键 | 50MP RAW 网格滚动即触发整解；外接盘/低速卡上尤其明显 | P1 | M |
| 6 | **无 Survey 模式（>4 张同屏）** | Lightroom Survey view（帮助页）；PM Contact Sheet 可一屏 N 张挑 | 布局只有 `single/compare2/compare4/grid`（`CullingGrid.swift:12-20`）；`groupCells` 固定 2 列（`CullingWorkbenchViewer.swift:592-605`） | 一场景 20 张连拍要"选出最好的一张"时只能在网格里看小图，进不了"大图并排" | P2 | M |
| 7 | **无 3 图对比布局** | PM Compare 支持 2–4；LR Compare 为 2 张、Survey 为 N 张 | `compareCount` 只在 2/4（`CullingGrid.swift:18-20`）；3 张时是 2+1 排（`:592-605`），只能靠"选 2 张"接近 | 三选一时构图不对称 | P2 | S |
| 8 | **直方图/合焦/AF 无键位**：状态机注释写着 (H)/(F)/(R)/(C)，实际只能点按钮 | FRV/PM/LR 直方图与过曝提示均有快捷键，挑片时不离键盘 | `ViewerOverlays.swift:75-78` 注释 "（H）/（F）"；查看器按钮区无 `.keyboardShortcut`（`CullingWorkbenchViewer.swift:156-190` 只有 help）；"键位表在 Interaction/" 的计划未落地——`Sources/GatherUI/Interaction` 内 grep `toggleHistogram|toggleFocusMask` = 0 命中 | 挑片全程在手放 P/X/→ 上，想看一眼直方图必须离开键盘去点按钮 | P1 | S |
| 9 | **无过曝/死黑图像提示与"曝光提示"叠加** | FRV 的 Highlight Inspection / 过曝提示；LR 直方图带溢出指示 | 只有直方图文字式 clipping 百分比（`ViewerOverlays.swift:248-252`），无图像面上的溢出遮罩；技术质量建议里 exposure 是标量（`Protocol/Culling.swift:212-249`） | 曝光失误的照片要看直方图数字才能发现，翻片节奏里没人看 | P2 | M |
| 10 | **保留/淘汰标旗不进 XMP，回 C1 不可见** | PM/LR 旗标也在各自目录内，但它们的挑片结果不依赖第二个软件；Gather 的场景是"挑完回 C1 剪" | 写回目标只有 `rating/color_label/keyword`（`CullingSyncService.swift:341-375`；`Protocol/Culling.swift:497-502`）；pickState 只在 `culling_decisions`（`CullingService+Commands.swift:143-157`） | 用户在 Gather 判"淘汰"，到 C1 里看不到任何标记，只能凭星级/色标判断；"淘汰"这一步无法在 C1 里延续 | P1 | M |
| 11 | **无第二显示器 / 第二窗口** | Lightroom 帮助页有独立条目 "Display the Library on a second monitor"；PM 可开多个 preview 窗口 | `GatherApp/GatherApp.swift:42` 用 `Window("Gather", id: main)` 单窗口（注释明说用 Window 而非 WindowGroup 排除第二个窗口）；`NSScreen` 全仓只用于取 `backingScaleFactor`（`CullingWorkbenchViewer.swift:460`、`PhotoThumbnailView.swift:103,143`） | 客户/艺术指导在第二块屏看 4 图对比、自己在主屏操作的基本工作流做不到 | P1 | L |
| 12 | **会话状态恢复只到布局层**：筛选/范围/当前照片/多选/参考槽不落盘 | PM 记住 contact sheet 的排序/筛选；LR 记住上次选中照片与来源 | `CullingView.swift:36-40,66` 只存 layout/density/sort/inspector；其余随内存 `SessionWorkspace`（`Support/SessionStore.swift:23-50`），进程退出即失；无 "上次浏览位置" 键（`SettingsKey.swift:54-94` 无对应项） | 隔天继续挑 3000 张的活：要从头重设筛选、滚动到上次位置、重选上一张 | P1 | S |
| 13 | **加载期间按键被静默丢弃（速度感）** | PM/FRV 翻片时输入不丢；Gather 自己的"自动前进"也依赖它 | `CullingViewModel+Actions.swift:342-343`：`commit` 在 `isLoading` 时直接 `return`，无 notice/队列；有数据时无任何 loading 视觉（`CullingView+Content.swift:67-75` 只在 `page == nil` 画进度条） | 20k 会话连按 5 次 X 只有 3 张变红，用户当成 bug | P1 | S |
| 14 | **缩放不以指针为中心** | FRV/PM/C1 滚轮缩放围绕光标位置，便于看边角合焦 | 滚轮只改 `scale`，不动 `offset`（`CullingWorkbenchViewer.swift:769-772`）；`scaleEffect` 绕单元格中心（`:411`） | 想看画面右下角的合焦要"先放大再拖"，每次多点两下 | P2 | S |
| 15 | **无"按住临时放大 / 按住看全图"** | LR 空格/Loupe 切换、PM 有 momentary zoom 习惯；Gather 双击=复位 | `onTapGesture(count:2)` 复位（`:586-588`），无按压态 | 判完细节要回全图时操作链更长 | P2 | S |
| 16 | **Rating/决策快捷键不可自定义，且无键位表** | C1 支持自定义键盘快捷键 [待核实]；PM 有快捷键偏好 [待核实]；LR 快捷键基本固定 | 裸键散落在查看器 `CullingWorkbenchViewer.swift:212-271` 与网格 `CullingGrid.swift:89-125` 两处；无任何 shortcut 设置键（`SettingsKey.swift:54-94`）、无 Interaction 键位表 | 从 PM/C1 迁来的用户肌肉记忆不同，无法适配；两处映射已开始漂移（查看器 8/9 = 绿/蓝，网格 ⌥7/8/9 = 橙/黄/绿，`:255-261` vs `CullingGrid.swift:99-102`） | P2 | M |
| 17 | **网格双击不进单图；单元不是按钮** | PM/LR 双击缩略图进大图 | `CullingGrid.swift:267-299` 只有 `onTapGesture`（单击）与右键"在单图中打开"（`:282-285`）；无 `count:2` | 鼠标用户第一次用时双击无效 | P2 | S |
| 18 | **挑片页无 ⌘R**，与其它 5 个会话页不一致 | 通用 | `CullingView.swift:128-143` 未传 `refreshKeyboardShortcut`（`Interaction/GatherSessionToolbar.swift:153-163` 默认关） | 外部改了 XMP 后想刷新的第一反应键失效 | P2 | S |
| 19 | **色彩管理只有系统默认**：无显示器 profile / 软打样 / 每屏 profile 选择；直方图在 DeviceRGB 里栅格化 | Lightroom 帮助页有独立 "Color management" 条目；C1 以 ICC/色彩精度为卖点 | `ViewerOverlays.swift:167`（`CGColorSpaceCreateDeviceRGB()` 画直方图输入）；预览走"解 RAW → JPEG 编码往返"（`RAWDecoder.swift:272-286`）；`SettingsKey.swift` 无色彩/显示相关键 | 广色域屏 + 打印校样场景下，Gather 的判断不能替代 C1 | P2 | M |
| 20 | **RAW 预览与 C1 编辑结果不一致且无提示** | （竞品不同问题：PM/FRV 本就不做编辑；C1 自己就是真相源） | 预览由 ImageIO/`CIRAWFilter` 渲染（`RAWDecoder.swift:193-204`），与 C1 的 .cos 调整无关；UI 无"该图在 C1 已有调整"的标记（全仓 grep `.cos` 解析只在 `CaptureOneBridge.swift:226` 明确"不解析 .cos"） | 用户在 C1 调完色回 Gather 挑片，看到的黑白平衡不同 → 误判曝光/色标 | P1 | L |
| 21 | **淘汰移出的确认框不写张数、对"没有淘汰件"也可点** | FRV/PM 的删除/移入回收站是一步动作但可撤销 | `CullingInspector.swift:144-155`（message 为常量，无 `l10n.format` 计数）、`:429-437`（启用条件只有 `!isBusy`） | 唯一会动磁盘的动作缺影响面信息；点错后要在 `_rejects` 里翻 | P1 | S |
| 22 | **对比/查看器无"锁定同步"开关** | LR Compare 与 C1 的对比默认同步缩放，但允许单独调整 [待核实] | 无独立开关：同步是"共享一套 `scale/offset`"的副作用（`:35`），无法只要同步缩放不要同步平移 | 对比不同构图的两张时，想各看各的做不到 | P2 | S |

---

## 4. 该域最该补的 3 件事

### ① 翻片速度链路：把已实现的预取 API 接到挑片页（P0，成本 S）
**理由**：这是唯一一条"补不上就必须换工具"的缺口——过片等待 + 输入丢失会直接把 2000 张级的活推回 Photo Mechanic / FastRawViewer。而底层能力已经存在（`ImagePreloadService`、`PhotoAPI.preloadPreviews/preloadThumbnails/prioritizeThumbnail`），只是 UI 没接线（GatherUI 内 0 命中），属于"接线型"补救，不是新造轮子。
**最小可行形态**：
1. `CullingViewModel` 在 `currentPhotoId` / `page.assets` 变化时，对 `index±2` 调 `cullingAPI` 之外的 `photoAPI.preloadPreviews(paths:maxDimension: 2560)`（直接复用宿主注入的 API，不新开接口）；
2. 查看器 `PhotoThumbnailView` 前调 `prioritizeThumbnail`（用户按 → 时把目标图排到闸门队首）；
3. `commit` 的 `isLoading` 早退改成"单槽 pending commit 队列"（加载完立刻执行最后一次），并在工作台右上角画 `isBusy` 细进度条。

### ② 无干扰单图：全屏 + 面板隐藏 + 真 1:1（P1，成本 S）
**理由**：挑片的两个动作——"看全图判构图"与"1:1 判合焦"——现在都要绕路：全屏只有网格有；1:1 只能滚到"看起来像"，而 ⌘0 的 help 还写着"实际大小"。这两处加起来构成"这个查看器不够专业"的第一印象，而且都是小改动。
**最小可行形态**：
1. 查看器新增"专注"模式：隐藏 `.inspector`（`CullingView.swift:146` 的 binding 置 false）、折叠胶片条（`isExpanded=false`）、`NSApp.keyWindow?.toggleFullScreen`；入口给 **F** 与「显示」菜单一项；
2. 新增 `zoomToActualPixels()`：按 `displayedImageRect` 的 fitScale 反算出 `scale = sourcePixels / fitPoints`（已有 `PhotoDetailTier.target` 的同一套算术），绑定 **1** / ⌘⌥0；
3. "100%" 胶囊只在 `scale != 1` 时显示，⌘0 的 help 改成"适配窗口（⌘0）"。

### ③ 对比判读可信 + 3/多图（P1，成本 M）
**理由**：对比模式是 Gather 已经投入最多的部分（同步缩放/参考对比/分割叠加），但"非当前格只有 2560px 基准位图"让它在真正需要它的场景（4 张连拍挑最锐的）失效——投入与效果不匹配，且修复只需放开贴片条件与预算分配。
**最小可行形态**：
1. 贴片条件从"当前格"放宽到"所有 `compareCount <= 2` 的可见格"（2 图对比是判焦主战场）；4 图时给当前格 + hover 格；
2. `PhotoDetailTier.budget(forVisibleCells:)` 按"格数 × 是否 hover"动态分配，而不是固定 4096；
3. 布局枚举加 `compare3`（3 列）与 `survey(n)`（N 由当前选择集大小决定，上限 9），复用现有 `groupCells` 与共享 `scale/offset`，不新增状态机。

> 追加建议（不进 Top3，但应进同一批）：会话状态恢复（缺口 #12，成本 S）——把 scope/filters/currentPhotoId 写进 `@SceneStorage` 的 Json 快照或 settings 键，重启后能回到"上次那张"；这是"每天开工第一分钟"的体验，性价比高于任何新功能。

---

## 5. 必查问题逐项对照（自查清单）

| 必查项 | 结论 | 证据锚点 |
|---|---|---|
| 全屏 / 无干扰模式 | ✗ 仅网格有窗口全屏按钮；单图无；不隐藏面板；菜单无入口 | `CullingGrid.swift:254-261`；`MenuCopy.swift:106-110` |
| 单张 loupe 大图 | △ 有单图布局，但没有独立"loupe"语义（全屏 + 100% + 隐藏 chrome） | `CullingWorkbench.swift:44-52` |
| 100% / 适配缩放 / 平移 | △ fit 相对 1..8 倍 + 平移 + 双击复位；**无 1:1 锚点**，⌘0 名不副实 | `CullingWorkbenchViewer.swift:95,121,143-145,655-660` |
| 二/三/四图对比 | △ 2 图与 4 图（3 图为 2+1）；无 3 列布局 | `CullingGrid.swift:12-20`；`CullingWorkbenchViewer.swift:592-605` |
| 对比同步缩放/平移 | ✓ 共用一套 `scale/offset`；无"只同步缩放"开关 | `CullingWorkbenchViewer.swift:35,44,411-412` |
| Survey 模式（N>4 同屏） | ✗ 不存在 | 同上（布局枚举只有 4 项） |
| RAW 解码路径 | ✓ 真解 RAW（ImageIO `fromImageAlways`）+ 放大区 `CIRAWFilter` 区域解码；✗ 无嵌入 JPEG 快档 | `RAWDecoder.swift:193-204,256-270` |
| 直方图 / 曝光提示 | △ 有预览口径直方图（含 clipping 百分比），无图像面过曝提示，无按键 | `ViewerOverlays.swift:191-252`；`CullingWorkbenchViewer.swift:156-167` |
| 对焦区域提示 | △ 有 AF 点叠加 `ViewerAFPointOverlay`（来自 `adjustmentHint` 的 crs:AF 数据）；无"合焦区域高亮"以外的判读工具 | `CullingWorkbenchViewer.swift:485-491`；`CullingAPI.swift:36-37` |
| 预加载 / 按键延迟 | ✗ 挑片页零预取（API 有 / UI 无）；✗ 加载中按键被丢弃；✗ 无 loading 视觉 | `PhotoAPI.swift:46-52`；`+Actions.swift:342-343`；`CullingView+Content.swift:67-75` |
| 色彩管理 / 显示器 profile | ✗ 无 profile/软打样设置；直方图在 DeviceRGB 栅格化 | `ViewerOverlays.swift:167`；`SettingsKey.swift:54-94` |
| 双屏 | ✗ 单窗口 `Window`；`NSScreen` 只取 backingScaleFactor | `GatherApp.swift:42`；`CullingWorkbenchViewer.swift:460` |
| 撤销粒度 | ✓ 按操作（一次 commit 一条历史，含逐张 before/after，持久化） | `+Actions.swift:71-78,575-627`；`Protocol/Culling.swift:389-403` |
| Rating 快捷键可自定义 | ✗ 两处硬编码；无键位表、无设置键；两处映射已漂移 | `CullingWorkbenchViewer.swift:248-267` vs `CullingGrid.swift:98-117` |
| 多选跨页 | ✓ 服务端 selection + hash 快照 + "仅当前可见"第二动作 | `CullingAPI.swift:50-52`；`+Actions.swift:464-478` |
| 胶片条 | ✓ 底部横向、色标线/星级/决策点/文件名、自动滚动、自动续页 | `CullingFilmstrip.swift:68-104,110-227` |
| 前后张跳转 | ✓ ←→ + 末张自动续页；✗ 无"跳到他页/跳到未处理下一张" | `+Actions.swift:533-573` |
| 标旗保留/淘汰批量 | ✓ 批量与跨页批量都通；✗ 标旗不进 XMP（回 C1 不可见） | `CullingAPI.swift:24`；`CullingSyncService.swift:341-375` |
| 删除/拒绝物理隔离 | ✓ 移动到 `_rejects`、不删除、按资产展开、共享 XMP 保护 | `RejectedMovePlanner.swift:44-70` |
| 每次会话状态恢复 | △ 仅 layout/density/sort/inspector 进 SceneStorage；筛选/范围/当前照片不落盘 | `CullingView.swift:36-66`；`SessionStore.swift:23-50` |

图例：✓ 已具备；△ 部分具备（够用但有明显摩擦）；✗ 缺失。

---

## 附：证据索引（供复核）

- 查看器：`desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer.swift`（956 行；缩放/手势 566-588、裸键 212-271、贴片 444-469、叠加层 299-333/471-503、滚轮 746-773）
- 对比选片：`.../Culling/CullingComparison.swift:8-32`
- 布局与网格：`.../Culling/CullingGrid.swift:12-20,89-125,245-265,331-365`
- 胶片条：`.../Culling/CullingFilmstrip.swift:20-104`
- 信息条：`.../Culling/CullingInfoBar.swift:21-48`
- 撤销/跨页/翻片：`.../Culling/CullingViewModel+Actions.swift:71-78,464-478,524-573,575-627`
- 叠加层状态与栅格化：`.../Culling/ViewerOverlays.swift:74-130,149-188,191-340`
- 协议面：`desktop/native/gather-core/Sources/GatherProtocol/API/CullingAPI.swift:19-63`、`Protocol/Culling.swift:15-19,135-176,298-312,389-403`
- RAW：`desktop/native/gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift:111-119,130-185,193-204,256-270`；`desktop/native/gather-app/Sources/GatherHost/RAWImageDecoder.swift:11-40`
- 预取（API 有 / UI 无）：`GatherProtocol/API/PhotoAPI.swift:46-52`；`GatherApplication/Services/ImagePreloadService.swift:58-70`；`GatherHost/APIs/LivePhotoAPI.swift:321-353`；`GatherUI/Gallery/LightboxView.swift:313-335`（唯一预取实现，且在灯箱）
- 写回与淘汰：`GatherApplication/Services/Culling/CullingSyncService.swift:341-375`；`.../Culling/RejectedMovePlanner.swift:13-70`
- 单窗口：`desktop/native/gather-app/Sources/GatherApp/GatherApp.swift:42`
- 内部审计（可交叉阅读）：`docs/reviews/2026-10-30-interaction-audit/B-culling.md`、`F-display-infrastructure.md`

**未验证与风险**
1. 全屏/焦点的实机行为未验证：`.onAppear { viewerFocused = true }`（`CullingWorkbenchViewer.swift:206`）是否在切换布局后必然生效，需实机确认；若成立，缺口 #8 的"按键无效"部分可降级。
2. 缺口 #4/#5 的"翻片有多慢"没有 profiling 数据（本文遵守不做性能评估的要求）；但"整解 RAW + 零预取"这两个事实本身已足以判定链路残缺，实机只需测"按 → 到清晰图出现"的秒数。
3. 竞品侧：PM 的变量/结构性拖拽具体路径、C1 Compare Variant 与 Trash 的菜单名、LR/C1 的快捷键自定义能力均未从厂商文档抓到原文，已在正文标 [待核实]；本节结论不建立在它们之上（缺口表每行都只用可核实到产品页级的内容）。
