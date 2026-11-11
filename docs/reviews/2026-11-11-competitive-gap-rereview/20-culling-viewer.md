# 挑片 / 浏览 / 比较 / 看图 功能复核（2026-11-11，基线 50fea319）

> 域：挑片页「进页—过片—判读—标记—前进」主链，以及单图/对比/Survey/网格/第二屏的**看法**（不含写回、C1 脚本、导出/交付本体）。
> 方法：只读静态审计（read/grep），未 build、未跑测试、未实机点 GUI；行号以当前工作树（50fea319，工作树干净）为准。
> "已闭环"判据 = 有 UI 调用点（按钮/菜单/onKeyPress/onAppear），不只看 service/API 存在；历史教训（preload、第二屏、键位）逐条回查接线。
> 竞品事实沿用上轮 `20-culling-browse.md` §2 的链接；本轮补抓 FastRawViewer features 页（原文可引），Adobe 帮助页正文 JS 渲染/404 的细节一律标 [待核实]。
> 路径前缀：UI=`desktop/native/gather-app/Sources/GatherUI/`；Host=`desktop/native/gather-app/Sources/GatherHost/`；Core=`desktop/native/gather-core/Sources/`。
> **未验证**：`96-manual-acceptance.md` §5（翻片延迟/预取实测）、§5.1（专注/1:1/对比键位）、§2（第二屏）尚未执行（§12 记录表为空，96:269-294），故下文"已闭环"只代表代码/接线成立，**体验收益未实测**。

## 0. 结论速览

1. **本域剩余 P0 为 0**：上轮唯一 P0（翻片预取 + 加载期按键）已接线并有调用点（±1/±2 预取、单槽 pending commit、忙碌角标、目标快照丢弃），另 #1/#2/#3/#6/#7/#8/#11/#13 的主体能力也都落地。
2. **最重要的新缺口是"对比/Survey 的决策目标错位"（P1）**：为构造显式 2/3/4 图对比必须先在胶片条多选；多选一旦非空，P/X/星级/色标就**作用于全部选中格**，而不是"当前这张"。Survey 里若当前照片不在选择集内，按 X 会标掉"别人"、不标你正在看的那张。
3. **浏览连续性仍是最大残留**：切布局会改页大小（网格 200 / 其它 500）并整页重置，当前照片越过 200 张就被踢回第 1 张；进网格后也不 scrollTo 当前；上轮 #12（会话状态恢复）未闭环。
4. **看图专业档两条半闭环**：专注模式仍留顶部工具栏/信息条/浮层控件（PM/LR 全屏只剩图）；4 图及 Survey 只有"当前 + hover"格有可见区细节，2 图已全格清晰。
5. **参考对比（并排/分割/叠加）几何只在 fit 档成立**：参考图不套同一 zoom/offset，并排模式主图也没有缩半——放大后比对的是"不同区域/不同尺寸"，上轮把该能力记为 ✓ 属误判。
6. **RAW 侧仍无嵌入 JPEG 快档**：`RAWDecoder` 恒 `fromImageAlways` 整解；`embedded_fast_path` 是**元数据回写**开关，不是查看器解码。预取只覆盖查看器 ±1 显示档，首屏/网格滚动/跳转仍整解。
7. **键盘仍是"能用但不专业"**：裸 P/X/0-9/←→/H/F/R/C 有；但无视图模式键（LR 的 Loupe/Grid/Compare/Survey 类）、查看器无法用 ⌥1–7 设橙/粉/紫、键位不可自定义、两套映射仍分散。
8. **Wave2/3 新功能多为"入口在、参数/默认值/失败面不完整"**：Survey 默认只 2 格（要先多选 9 张才是 9 格）、第二屏不自动选屏/全屏、真实 AF 点仍是空表 + 人脸中心回退（上轮误记成 crs:AF 数据）。

### 0.1 本轮判定口径（三档状态怎么给）

- **已闭环**：主诉求有 UI 入口 + 执行路径 + 失败/取消路径；本次逐条回查过调用点（见 §1.0），不以"服务/API 存在"代替。
- **部分闭环**：主诉求的主干已通，但差"最后一步"——典型是全屏只隐藏一半 chrome、对比只清晰一半格、旗标只写进 C1 不写进 XMP。
- **未闭环**：代码层没有对应实现/接线，或实现与文案不一致（如 AF 点、参考对比几何）。
- 严重度：P0=核心工作流断链/数据不安全；P1=每个工作流撞一次的摩擦或能力缺失；P2=有更好、没有也能用。成本：S≤2 人日 / M≈1 周 / L>2 周。

## 1. 上轮缺口状态核对

### 1.0 回查过的 UI 调用点（防"API 有 / UI 无"）

| 能力 | UI 调用点（本轮实际读到的） | 结论 |
|---|---|---|
| 邻张预取 | 查看器 `onAppear/onChange(currentPhotoId)/pageSignature` → `scheduleNeighborPreload`（`CullingWorkbenchViewer.swift:495,522,535`）；页面可见补一次（`CullingViewModel.swift:408-410`） | 有接线，非 API 空转 |
| 专注模式 | 查看器按钮 `CullingWorkbenchViewer.swift:350-358` + 「显示」菜单 `GatherAppCommands.swift:59-71` + ⇧F `CullingViewerParts.swift:115` | 有入口 |
| 真 1:1 | 可见按钮 ⌘1（`:276-281`）+ onKeyPress ⌘⌥0（`:410-417`）+ 快捷键菜单（`:330-346`） | 有入口 |
| H/F/R/C | onKeyPress 分发（`CullingWorkbenchViewer.swift:424-443`）→ 叠加层状态机（`ViewerOverlays.swift:98-141`） | 有分发 |
| 第二屏 | 查看器 display 按钮（`CullingWorkbenchViewer.swift:369-373`）+ 独立 Window 场景（`GatherApp.swift:127-147`） | 有入口 |
| 4 图贴片 | `CullingDetailTilePolicy`（`CullingViewerParts.swift:91-96`）被查看器 `:700-705` 与调度 `:995-1007` 实际引用 | 有策略 |
| 加载期按键 | `commit` 链 + 单槽 pending + flush（`CullingViewModel+Actions.swift:363-406`；`+Load.swift:308-314`） | 有路径 |
| 移出确认 | 检查器按钮 → `confirmationDialog`（`CullingInspector.swift:149-161,436-444`） | 有弹窗（影响面不足） |

### 1.1 P0 / P1（上轮 #1–#5、#8、#10–#13、#20、#21）

| 上轮# | 缺口一句话 | 上轮严重度 | 当前状态 | 当前证据（路径:行号） | 剩余差 |
|---|---|---|---|---|---|
| #4 | 挑片页无相邻预取，翻一张现解一次 RAW | **P0** | **已闭环** | `CullingViewModel+Preload.swift:138-202,238-260`（±1 同键预热/±2 宿主/下一张 prioritize）；调用点 `CullingWorkbenchViewer.swift:495,522,535`；可见性补发 `CullingViewModel.swift:408-410` | 收益未实测（96 §5 未跑）；网格滚动/首屏仍整解（见 #5） |
| #1 | 单图无全屏/无干扰 | P1 | **部分闭环** | `CullingView.swift:220-261`（enter/exit：隐藏检查器+折叠胶片条+窗口全屏）、查看器按钮 `CullingWorkbenchViewer.swift:350-358`、菜单 `GatherAppCommands.swift:59-71` | 工具栏/信息条/浮层控件仍在：`CullingWorkbench.swift:43-48,76`、`CullingWorkbenchViewer.swift:1386-1394`；胶片条只折叠仍留头部（`CullingFilmstrip.swift:37-66`） |
| #2 | 无真 1:1（fit 相对 1..8 倍） | P1 | **已闭环** | `CullingWorkbenchViewer.swift:19-105`（actualPixelsScale/pixelPercent）、`:276-281`（⌘1）、`:410-417`（⌘⌥0）、`:1109-1124`、`:1153-1163`（百分比胶囊）；⌘0 改为适配 `:267-272` | 无（当前格换算对同尺寸格通用） |
| #3 | 对比只有当前格清晰 | P1 | **部分闭环** | 策略 `CullingViewerParts.swift:91-96`；贴片条件 `CullingWorkbenchViewer.swift:700-705`；调度 `:995-1007` | 2 图已全格清晰；3/4/Survey 仍只当前+hover；叠加层（合焦/AF/裁剪/参考）仍只画当前格 `:733-767` |
| #5 | 所有缩略图/预览整解 RAW，无嵌入 JPEG 快档 | P1 | **未闭环** | `RAWDecoder.swift:256-299` 恒 `kCGImageSourceCreateThumbnailFromImageAlways:true`；`:123-131` 缩略图/预览同路径；`SettingsKey.swift:54-55` 只有 thumbnail_size/quality | 无解码路径设置；`embedded_fast_path`（`SettingsKey.swift:88,179`、`Core/GatherDelivery/Writeback/WritebackService.swift:85-90`）是**写回**快路径，不是预览解码 |
| #8 | 直方图/合焦/AF 无键位 | P1 | **已闭环** | 键位表 `CullingViewerParts.swift:103-120`；分发 `CullingWorkbenchViewer.swift:424-443`；H/F/R/C 菜单 `:330-346` | 无（键位表是只读菜单，自定义见 #16） |
| #10 | 保留/淘汰旗标不进 XMP，回 C1 不可见 | P1 | **部分闭环** | XMP 写回仍只 rating/label/keyword：`Core/GatherApplication/Services/Culling/CullingSyncService.swift:341-375`；新增 C1 变体级写回（keep→pick=true）：`CullingSyncControls.swift:39-44`、`CullingViewModel+Writeback.swift:311-383,391-412` | 淘汰无对应位（C1 只有布尔 pick）、XMP sidecar 仍无旗标、未处理不写；"回 C1 可见"只对 keep 成立 |
| #11 | 无第二显示器 | P1 | **已闭环（主体）** | 第二 Window `GatherApp.swift:127-147`；窗口内容 `CullingSecondDisplay.swift:89-315`；镜像贴片 `:326-365,371-515`；attach `CullingView.swift:137-148` | 不自动选屏/自动全屏（窗口只有 defaultSize，全仓无按 NSScreen 摆放窗口的逻辑）；只读镜像不能独立缩放（取舍，见 §5） |
| #12 | 会话状态只恢复布局层 | P1 | **未闭环** | 仅 `CullingView.swift:46-50,76` 的 layout/density/sort/inspector 进 SceneStorage；`SettingsKey.swift` 无"上次照片/筛选"键；其余随内存 SessionWorkspace | 筛选/范围/当前照片/多选/参考槽/胶片条展开都不落盘，隔天复挑要重来 |
| #13 | 加载期按键被静默丢弃 | P1 | **已闭环** | 单槽排队 + 目标快照 `CullingViewModel+Actions.swift:12-22,363-406`；flush `CullingViewModel+Load.swift:308-314`；忙碌角标 `CullingWorkbench.swift:34-39` | 无（"只重放最后一拍"是设计，且目标变了会丢弃并提示） |
| #20 | RAW 预览与 C1 调色结果不一致且无提示 | P1 | **未闭环** | 预览仍由 ImageIO/CIRAWFilter 渲染 RAW：`Core/GatherAnalysis/Image/RAWDecoder.swift:199-224`；`CaptureOneBridge.swift:344` 明确不解析 .cos；UI 无"该图 C1 有调整"标记 | 无任何提示/切口 |
| #21 | 淘汰移出确认框不写张数、无淘汰件也能点 | P1 | **部分闭环（残余 P2）** | `CullingInspector.swift:149-161` 标题/正文为常量；`:436-444` 仅 `isBusy` 禁用；服务端兜底报错 `CullingViewModel+Actions.swift:175,197` | 确认面仍无影响面（张数/文件名），按钮仍可在 0 张淘汰时点（会报错而非预检禁用） |

### 1.2 上轮 P2 汇总（10 条）

| 上轮# | 状态 | 证据 |
|---|---|---|
| #6 Survey（N>4 同屏）、#7 3 图布局 | **已闭环** | 布局 `CullingGrid.swift:12-24,40-47,77-85`；选片 `CullingComparison.swift:34-79`；查看器 `CullingWorkbenchViewer.swift:876-883` |
| #9 无图像面过曝/死黑提示 | 未闭环 | 仅直方图文字百分比 `ViewerOverlays.swift:248-252`，无遮罩 |
| #14 缩放不以指针为中心 | 未闭环 | 滚轮只改 scale：`CullingWorkbenchViewer.swift:1195-1209` |
| #15 无按住临时放大 | 未闭环 | 仅双击复位 `:850-852` |
| #16 键位不可自定义、两处映射 | 未闭环 | 无 settings 键；`CullingGrid.swift:153-194` vs `CullingViewerParts.swift:103-120`；查看器无 ⌥ 色标 |
| #17 网格双击不进单图 | 未闭环 | 单元仅单击 `CullingGrid.swift:340-343`；Enter 可进 `:423-425` |
| #18 挑片页无 ⌘R | 未闭环 | `CullingView.swift:154-169` 未传 `refreshKeyboardShortcut`（默认 false `GatherSessionToolbar.swift:35,154-163`），其它 4 页都传 true |
| #19 色彩管理仅系统默认 | 未闭环 | 直方图在 DeviceRGB 栅格化 `ViewerOverlays.swift:167`；无 ICC/软打样设置 |
| #22 无"只同步缩放/不同步平移"开关 | 未闭环 | 共享一套 `scale/offset`：`CullingWorkbenchViewer.swift:140-142,150,1017-1019` |

> Wave4b 收掉的挑片 P2（预取双通道整解、miss 不查磁盘、NSScreen 取错、1:1 resize 不重锚、pageVersion 饿死去抖、网格忙角标、打印 200 张静默截断）在代码里都有对应实现（如 `CullingViewModel+Preload.swift:126-130,206-235`、`CullingWorkbenchViewer.swift:1126-1139`、`CullingViewerParts.swift:82-89`），本轮不再报。

## 2. 剩余缺口表（上轮未闭环 + 新发现）

> 统计：P0×0；P1×5（新 2 / 上轮 3）；P2×11（新 5 / 上轮残余 6，最后一行合并 6 个零散项）。成本：S≤2 人日 / M≈1 周 / L>2 周。

| 级别 | 缺口 | 竞品做法+链接 | Gather 证据 | 成本 | 修法一句话 |
|---|---|---|---|---|---|
| **P1（新）** | 对比/Survey 的决策目标错位：多选是"构造对比"的手段，却同时变成"批量写入"的目标 | LR 的 Compare/Survey 以"活动照片"为决策对象（[browse-compare](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html)，具体语义 [待核实]） | 显式 2/3/4 图要求 `selected.count == compareCount`（`CullingComparison.swift:17-23`）；Survey 会把未被选中的当前照片塞进画面（`:52-61`）；按键走 `commit`→选择集分支批量（`CullingWorkbenchViewer.swift:444-484`；`CullingViewModel+Actions.swift:408-455`，该分支还忽略 shouldAdvance） | S–M | compare*/survey 布局下键盘/按钮决策只作用于 current；要批量时显式给"作用于全部选中 N 张"开关并回显 |
| **P1（新）** | 切布局重置分页并丢当前照片；进网格不定位当前 | LR/PM 切换视图保持同一选择与位置（[待核实原文]） | layout 绑定 → `setPageLimit(200/500)`（`CullingView.swift:57-64`）→ 整页 reset（`CullingViewModel+Grid.swift:27-34`）→ 当前不在新页即回第一张（`CullingViewModel+Load.swift:213-225`）；网格只在 onChange 滚动、无初始定位（`CullingGrid.swift:293-298`） | S | 页大小变化不触发 reset（或按 current 游标续页）；网格 onAppear 时 scrollTo(current) |
| **P1（上轮#12）** | 筛选/范围/当前照片/参考槽不落盘 | PM/LR 记住上次浏览位置与筛选（帮助页 [browse-compare](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html)，具体范围 [待核实]） | `CullingView.swift:46-50,76` 只有 4 个 SceneStorage 键；无 settings 键（`SettingsKey.swift`） | S | 按 session 落盘 scope/filters/currentPhotoId/参考 id，进页恢复 |
| **P1（上轮#5）** | 无嵌入 JPEG 快档，预览/缩略图都整解 RAW | FRV 明说"嵌入式 JPEG 预览 + JPEG 直方图会骗人"，并把 RAW 数据路径当卖点（[features](https://www.fastrawviewer.com/features)）；PM/Narrative 以缩略图优先渲染换速度（[PM](https://home.camerabits.com/products/)、[Narrative](https://narrative.so/select)） | `RAWDecoder.swift:256-299`；无解码路径设置（`SettingsKey.swift:54-55`） | M | 加 "embedded-first"：maxPixel≤2560 先试内嵌 JPEG，放大/1:1 再走 RAW/CIRAWFilter；设置键可回退并标注"预览口径" |
| **P1（上轮#20）** | C1 已调色的图在 Gather 里看不出差异 | C1 自身是真相源；PM/FRV 不做编辑（[C1 features](https://www.captureone.com/en/features)，细节 [待核实]） | `RAWDecoder.swift:199-224`（按 RAW 渲染）；`CaptureOneBridge.swift:344` 不解析 .cos；无 UI 标记 | L | 只做"该图在 C1 已有调整"标记（.cos 存在/mtime 对不上时提示），不渲染 C1 look |
| P2（上轮#3 残余） | 4 图/9 图非当前格只有 2560 基准位图，需 hover 才清晰；叠加层只画当前格 | PM/LR 对比每格独立高清 + 同步缩放（[PM](https://home.camerabits.com/products/)） | `CullingViewerParts.swift:91-96`；`CullingWorkbenchViewer.swift:700-705,733-767` | M | 3/4/Survey 允许 2 块并发贴片（当前 + 最后交互格），hover 只作加速 |
| P2（上轮#1 残余） | 专注模式未清干净：工具栏/信息条/浮层仍在，胶片条留头 | PM Preview / LR Loupe 全屏只剩图（同上） | `CullingWorkbench.swift:43-48,76`；`CullingWorkbenchViewer.swift:1386-1394`；`CullingFilmstrip.swift:37-66` | S | isFocusMode 时隐藏 toolbar/infoBar/浮层，只留 1s 淡出的 ESC 提示 |
| P2（新） | 参考对比几何不随缩放/平移；并排模式主图不缩半 | PM/LR/C1 的对比在任意缩放下对齐（[C1 features](https://www.captureone.com/en/features)） | 并排：`CullingWorkbenchViewer.swift:670-693`（参考固定 `size:1024`、主图未缩半）；分割/叠加：`:755-766` 外层用 imageRect，内层 `ViewerOverlays.swift:487-497` 用 cellSize | M | 参考层套同一 `scaleEffect/offset`；并排改成两列各 fit 一半（各自贴片） |
| P2（新） | Survey 默认只 2 格，必须先多选 2–9 张 | LR Survey 一屏 N 张（[browse-compare](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html)） | `CullingGrid.swift:40-47`（无选择→2）；`CullingComparison.swift:49-79` | S | 无显式选择时用"当前 + 后续邻接"填到窗口可容张数（默认 9） |
| P2（新） | 无真实对焦点：机型表空、afIndex 恒 nil → 永远人脸中心；AF 框点击声称 100% 实际 fit | LR "View focus points"（[帮助页](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-focus-points-in-photos.html)） | `PreviewAnalysis.swift:277-284,318-336`（空表出厂）；`CullingWorkbenchViewer.swift:1297-1303`（afIndex:nil）、`:1347-1364`（scale=1）；文案 `ViewerOverlays.swift:446` | M | 补 EXIF AF 区域解析；无数据不标 "AF"；AF 点击改为 zoomToActualPixels + 居中 |
| P2（上轮#9 残余） | 无图像面过曝/死黑遮罩；直方图仍是 8bit 预览口径 | FRV Highlight Inspection + RAW 直方图（[features](https://www.fastrawviewer.com/features)） | 仅文字百分比 `ViewerOverlays.swift:248-252`；像素来源预览位图 `:145-189`、`PreviewAnalysis.swift:29-74` | M | 直方图裁剪升级为图像面遮罩（三通道溢出）；RAW 口径单独立项 |
| P2（新） | 键位覆盖缺口：视图模式无键、查看器无 ⌥1–7、不可自定义 | LR 四视图（Loupe/Grid/Compare/Survey）+ PM 键盘中心（[LR](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html)、[PM](https://docs.camerabits.com/)） | 无模式键：`CullingGrid.swift:153-194`、`CullingViewerParts.swift:103-120`；无 settings 键 | S | 加 G/E/C/N 类模式键；单一 keymap 表 + 设置页可改 |
| P2（新） | 网格筛选入口深：检查器第 6 段、默认折叠；排序缺文件名/色标/保留 | LR 图库筛选条 / Bridge Filter 面板（入口细节 [待核实]） | `CullingInspector.swift:18,365-383`；排序仅 4+1 档 `:306-321`；筛选维度 `CullingFilterControls.swift:16-67` | S | 网格头加筛选条 + "仅未处理"开关；排序补文件名/色标/保留状态 |
| P2（上轮#11 残余） | 第二屏不自动选屏/自动全屏 | LR 第二屏（帮助中心 "Display the Library on a second monitor"，正文 [待核实]） | `GatherApp.swift:147` 仅 defaultSize；`CullingSecondDisplay.swift` 全文件无 NSScreen | M | openWindow 前按 NSScreen 选非主屏，窗口默认 fullscreen |
| P2（上轮#21 残余） | 移出确认框无张数/影响面，0 张淘汰也可点 | FRV/PM 删除/移出是一步动作（[PM](https://docs.camerabits.com/)） | `CullingInspector.swift:149-161,436-444` | S | 确认框写"移出 N 张（列出前 3 个文件名）"；0 张时禁用 |
| P2（上轮#14/#15/#17/#18/#19/#22 残余） | 缩放不以指针为中心；无按住临时放大；网格双击不进单图；挑片页无 ⌘R；无色彩管理；无同步锁 | 通用（LR/PM 惯例） | `CullingWorkbenchViewer.swift:140-142,850-852,1195-1209`；`CullingGrid.swift:340-343`；`CullingView.swift:154-169`；`ViewerOverlays.swift:167` | S–M | 逐项小修（指针锚定缩放/长按 1:1/双击进单图/⌘R/profiles 设置/同步锁） |

### 2.1 需要真机确认的假设（本轮无法静态判定）

1. 预取收益：按 → 到清晰图的中位/最大耗时（96 §5 三轮实测未跑），决定 #4 是否算"体验闭环"。
2. 专注模式的 AppKit 互操作：全屏进入/退出、ESC 与 `didExitFullScreen` 的时序（`CullingView.swift:208-210,231-253`）。
3. 第二屏真机：单屏同窗、双屏跨屏拖动、主窗关闭后重开恢复（96 §2）。
4. 裸键在焦点迁移后的可用性：查看器 `.focusable()` 与检查器控件点击后的第一响应者归属（需实机；若不成立，P/X 会间歇失效）。
5. ⌘⌥0 / ⇧F 是否被 AppKit 或输入法吞（96 §5.1 的判定项）。
6. 4 图贴片在真实 50MP RAW 下的内存峰值与 hover 命中延迟（预算 4096/5120 的体感）。

## 3. 新发现（上轮未列 / Wave2–3 半成品）

1. **对比模式的"决策目标"没有独立概念（本域最高风险）**。为看两张非相邻片要 ⌘ 选 2 张，此后按 X 是"批量淘汰 2 张"；Survey 选 9 张后按 P 会写 9 张。更糟的是 Survey 的当前照片若未被选中：`CullingComparison.surveyAssets` 会把它插到首位给你看（`CullingComparison.swift:52-61`），但 `commit` 的目标仍是 `selectedPhotoIds`（`CullingViewModel+Actions.swift:422-455`）——你盯着 A 按 X，写的是 B…I。建议在布局为 compare/survey 时把决策收窄到 current，或在提示条明示"将写入 N 张"。
2. **切布局丢进度比"翻片慢"更容易被当成 bug**。单图在第 300 张切网格 = 页大小 500→200 + 整页 reset + current 不在新页 → 回第 1 张（链路见 §2 P1-2）；即使 current 在第 1 页内，网格也没有 `onAppear scrollTo`，看到的是顶部。与 #12 一起构成"浏览连续性"这一条产品债。
3. **参考对比只在 fit 档正确**（§2 P2）。放大后主图 zoom/offset、参考图固定 fit 尺寸、分割线按 cellSize 算却贴在 imageRect 上；"并排"实际是"左半 = 当前图左半，右半 = 参考图整张"。上轮把它算作"参考对比 ✓"是误判，本条纠正。
4. **Survey 半成品**：无选择时 `effectiveCompareCount` 夹到 2（`CullingGrid.swift:40-47`），"多图对比"点进去只有两张；要 9 格得先在胶片条多选 9 张——而这又触发第 1 条批量写入。默认 N 与决策目标应一起改。
5. **AF 点能力名不副实**：机型表"空表出厂"（`PreviewAnalysis.swift:277-284`），查看器又传 `afIndex: nil`（`CullingWorkbenchViewer.swift:1297-1303`），所以永远只画"人脸中心"；AF 框 help 写"以对焦点 100% 查看"（`ViewerOverlays.swift:446`），实现却是 `scale=1`（`CullingWorkbenchViewer.swift:1347-1364`）。上轮 §5 把它记成"来自 adjustmentHint 的 crs:AF 数据"，应以本条为准。
6. **键位仍散落且能力不齐**：网格有 ⌥1–7 七色（`CullingGrid.swift:162-167`），查看器只收裸键、⌥ 组合一律让给系统（`CullingWorkbenchViewer.swift:418-420`），所以单图里橙/粉/紫只能点检查器菜单；视图模式（单图/2/3/4/Survey/网格）没有任何键位。键位表目前是只读菜单（`:330-346`），不是可配置表。
7. **半成品小项**：网格"大图"密度的缩略图档仍是 1024，与"中图"相同（`CullingGrid.swift:122-128`）；胶片条只有展开/折叠两档高度、固定底部，没有位置/尺寸选项（`CullingFilmstrip.swift:20-35`）。都属"有更好"。
8. **预取只覆盖查看器布局**：`scheduleNeighborPreload` 只在查看器 onAppear/翻片/页变化触发（`CullingWorkbenchViewer.swift:495,522,535`；`CullingViewModel+Preload.swift:138-202`），网格滚动仍是逐格整解（`CullingGrid.swift:476` 的 `PhotoThumbnailView`）——与 #5 同因，补解码快档后自然缓解。
9. **Wave3 功能的"存在"与"体验"差距**：第二屏、打印、自动化入口都在且有只读/失败路径设计，但 96 §2/§5/§5.1 未实机跑；本域所有"已闭环"结论都只到代码级。

## 4. 本域最该补的 3 件事

1. **对比/Survey 的决策目标语义（P1，成本 S–M）**——理由：这是唯一会**写错用户判断**的缺口，且落在本域最核心的"2 图/多图挑片"路径上；一次误标 2–9 张虽然可撤销，但会立刻摧毁"这个工具懂挑片"的信任。最小改法：布局为 compare*/survey 时键盘/按钮只作用于 current（并在信息条回显目标），批量写入保留给网格/检查器。
2. **浏览连续性：布局切换 + 会话恢复（P1，成本 S）**——理由：切网格/回单图是每小时十几次的动作，每次越过 200 张就回第一张，比任何画质问题都更像"软件坏了"；#12 又让隔天无法继续。两件事共用"把 current/scope/filters 变成会话级持久状态"的实现，ROI 最高。
3. **RAW 解码快档 + 预取实测（P1，成本 M）**——理由：预取已把"按 → 出图"的等待盖住，但首屏、网格滚动、跳页仍整解 RAW，且 96 §5 的三轮实测没跑；补"embedded-first"档是竞品（PM/FRV/Narrative）的默认做法，也是本域唯一还能拉开"翻片速度"感知的杠杆。

> 追加（不进 Top3，建议同批）：专注模式 chrome 清干净（S）、视图模式键位 + keymap 单一来源（S）、4 图两格并发贴片（M）。这三项都是小改动，但决定"专业感"。

## 5. 明确不是缺口（ROADMAP 取舍 / 本域边界，防误报）

- **淘汰 = 移到 `_rejects` 不删除**：设计选择（可找回、共享 XMP 保护），不按"没有删除"报缺口。
- **第二屏是只读镜像、不能独立选择/标记**：刻意取舍（避免双写与双轮询），只报"不自动选屏"这一体验项。
- **不做 RAW 编辑**（ROADMAP §七）：所以 #20 只要求"该图在 C1 已调整"的**可见标记**，不要求 Gather 渲染 C1 的 look；调色/软打样/色彩管理（#19）不在产品目标内，属可延后 P2。
- **不做云同步/托管式客户交付、不做 Windows/其它框架**（ROADMAP §七）：与本域无关，不报。
- **检查器承载筛选/排序（options-in-panel）**：Bridge/C1 同范式，属取舍；只报"入口深/默认折叠"。
- **网格不自绘筛选条、胶片条固定底部**：同上，属布局取舍，不算能力缺失。
- **预览直方图"基于预览"的自我标注**：诚实边界，RAW 口径另立项，不按"说谎"报。
- **相似组 + Burst/Scene 导航组已覆盖 Narrative 的 Scenes 分组**：不报"没有场景分组"。
- **Wave2 的 embedded_fast_path 设置**：属元数据写回优化，不要误读成查看器解码快档（§2 P1-4 已按此判）。

## 附：证据索引（本次读过的文件）

- 上轮分册：`docs/reviews/2026-11-10-competitive-gap/20-culling-browse.md`；台账 `90-wave-ledger.md` §6/§9/§12；验收 `96-manual-acceptance.md` §5/§5.1/§9/§12；实现后评审 `97-post-implementation-review.md` §3.2/§4。
- 查看器：`UI/Culling/CullingWorkbenchViewer.swift`（1-105 缩放口径；209-601 布局/键位/叠加；607-854 单元格/参考并排/贴片；876-1057 对比选片/打印/贴片调度；1069-1209 1:1/滚轮；1223-1364 叠加分析/AF）。
- 零件：`UI/Culling/CullingViewerParts.swift:12-121`（贴片策略/裸键表）；`UI/Culling/ViewerOverlays.swift:191-532`（直方图/合焦/裁剪/AF/参考）。
- 布局：`UI/Culling/CullingGrid.swift:12-137,245-462`；`UI/Culling/CullingComparison.swift:8-79`；`UI/Culling/CullingWorkbench.swift:34-116`。
- 页面/状态：`UI/Culling/CullingView.swift:36-77,131-261`；`UI/Culling/CullingView+Content.swift:87-136`；`UI/Culling/CullingToolbar.swift:25-142`；`UI/Culling/CullingFilterControls.swift:16-124`；`UI/Culling/CullingInspector.swift:18,149-161,306-383,436-444`；`UI/Culling/CullingFilmstrip.swift:20-227`；`UI/Culling/CullingInfoBar.swift:21-70`。
- VM：`UI/Culling/CullingViewModel+Preload.swift:52-298`；`+Actions.swift:12-22,154-209,363-455,573-633`；`+Load.swift:183-340`；`+Grid.swift:10-34`；`+Writeback.swift:308-419`。
- 第二屏/菜单：`UI/Culling/CullingSecondDisplay.swift:34-515`；`GatherApp/GatherApp.swift:96-147`；`UI/Interaction/CullingFocusModeActions.swift:12-40`；`GatherApp/GatherAppCommands.swift:59-71`；`UI/Interaction/GatherSessionToolbar.swift:35,154-163`。
- 解码/分析：`Core/GatherAnalysis/Image/RAWDecoder.swift:123-131,142-224,256-299`；`Core/GatherAnalysis/Preview/PreviewAnalysis.swift:29-74,277-336`。
- 写回/协议/设置：`Core/GatherApplication/Services/Culling/CullingSyncService.swift:341-375`；`Core/GatherProtocol/Settings/SettingsKey.swift:54-55,64-65,88,179`；`Core/GatherDelivery/Writeback/WritebackService.swift:85-90`；`Host/Composition/Core.swift:164-168`；`Host/CaptureOneBridge.swift:344,907`；`UI/Culling/CullingSyncControls.swift:21-75`。
- 竞品（本轮补抓）：<https://www.fastrawviewer.com/features>（"The Only Real Raw Viewer"、embedded JPEG 预览 vs RAW 直方图、Grid Mode / Highlight Inspection）；<https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html>（LR 四视图，正文 JS 渲染 [待核实]）；<https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-focus-points-in-photos.html>（对焦点）；其余沿用上轮 §2（PM / Narrative / C1）。
- 未验证：`96-manual-acceptance.md` §5/§5.1（翻片延迟、专注/1:1/对比键位）与 §2（第二屏）未执行；本报告全部结论为静态代码级。
