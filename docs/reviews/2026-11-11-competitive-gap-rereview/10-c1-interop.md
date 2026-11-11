# Capture One 互操作 功能复核（2026-11-11，基线 50fea319）

> 域：Gather ↔ Capture One（C1）互操作，含"外部中转"对照（Adobe Bridge）。
> 上轮分册：`docs/reviews/2026-11-10-competitive-gap/30-c1-bridge.md`（G1–G14）。
> 基线：`50fea319`（Wave1–4c 修复后，工作树干净），行号取当前工作树。
> 本机 C1 `16.7.8.16`，字典 `/Applications/Capture One.app/Contents/Resources/CaptureOne.sdef`（下称 sdef）。
> 方法：上轮 14 条逐条回核；判"已闭环"要求 **UI 调用点或测试钉子**，不接受"协议/服务存在"。
> 再挖 Wave2/3 新功能的半成品，以及竞品真实工作流里 Gather 完全不支持的那一步。
> 纪律：只读代码与本机字典，未跑 build/test、未在真机点 C1。脚本语义只能与 sdef 文本比对，
> **真机矩阵（96 号 §1 C1-1..C1-10）本轮仍未执行**。竞品事实复用上轮已核链接，本次复验 2 条官方页为 200；
> C1 帮助中心被 Cloudflare 403，相关细节标 `[待核实]`。

## 0. 结论速览

- **上轮 P0 的 G1/G2 已闭环**：选中读取改为 application 级 `selected variants` + `parent image.path`，
  且不再 `on error` 吞错（`CaptureOneBridge.swift:567-591`）；reload 改为 per-variant、无选中报
  `C1_NO_SELECTED_PHOTOS`（`:167-180`）；"手动 Load Metadata"有了写 durable ack 的唯一出口
  （`CullingSyncControls.swift:51-57`、`MetadataSyncBar.swift:184-190`）。**静态层面未发现新增 P0。**
- **G3 只闭环了约三分之一**：判断数据现在能在"菜单 ⌘⇧I 从 C1 导入"这一条路上随导入落库
  （`AppBootstrap.swift:744-769` → `C1ImportJudgementService.swift:220-304`），但**新建工作区（source=C1）、
  C1 插件深链、Session/目录导入三条入口都不带判断**（`DashboardViewModel+Actions.swift:59`、
  `GatherAppDelegate.swift:233-238`、`AppBootstrap.swift:421-430`）。
- **剩余最硬的三类断点**：
  ①写回/选中/"在 C1 中显示"的作用域是 **C1 当前集合**（sdef:325、:736），Gather 从不用 `browse`（sdef:678）
  → 跨集合一律 notFound 且无补救；
  ②变体写回目标靠启发式（已 pick 否则 variant 1，`CaptureOneBridge.swift:981-998`），而读取按 max/OR 合并
  （`C1ImportJudgementService.swift:65-94`）= 多 variant 时不可逆，可能改错变体（96 号 §10 判 P0）；
  ③判断只有"选中导入"一条通道（R4）。
- **Wave2/3 新功能是"主干成立、收尾不足"**：变体写回无变体展示/选择、无写后回读、无分批、写 catalog 不写 XMP
  （`CaptureOneBridge.swift:898-906`）；判断读取只认当前选中、最长等扫描 10 分钟、pending 只存内存
  （`C1PendingJudgementReplay.swift:13-14`）；"在 C1 中显示"只加选不减选（`deselect` sdef:1967 未用）、无快捷键。
- **上轮 G7/G11/G14 仍完全未动**：`GatherLink.swift:4-9` 依旧 `pluginRole _` 且只实现 Open With；
  `hasAdjustments` 仍无 UI 消费；app 内 grep `coplugin|Plug-ins` = 0（无插件安装/兼容产品面）。
- **竞品对照**：C1 的判断在 variant、组织在 collection、交换靠 Load/Sync metadata + 大 AppleScript 面；
  Bridge 是"任意文件夹直接读写 XMP、无 variant 歧义"
  （[label-and-rate-files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html)，
  本次 200 复验）。Gather 两条路都只走到一半：XMP 路要 C1 手动 Load；AppleScript 路受
  "当前集合 / 单文档 / 单选启发式"三项限制。
- **口径**：本域无新增 P0；剩余 = **P1×6、P2×10**（含上轮遗留）。建议按 §4 顺序补 3 件事（S + S/M + M），
  并在发布前跑完 96 号真机矩阵——否则本域全部结论仍是"文本级一致"。

## 1. 上轮缺口状态核对

> 覆盖上轮全部 P0/P1（G1–G10）；P2（G11–G14）逐条列后汇总。状态只有三种：已闭环 / 部分 / 未闭环。

| 上轮 | 缺口一句话 | 上轮 | 当前状态 | 当前证据（路径:行号） | 剩余差 |
| --- | --- | --- | --- | --- | --- |
| G1 | 选中读取脚本对象归属错（`selected variants of current document`、variant 无 `path`），错误被 `on error` 吞成"没选中" | P0 | **已闭环** | `CaptureOneBridge.swift:567-591`（application 级 `:574`、`path of parent image` `:585-586`）、`:116-123` 解析；失败上浮；UI 两入口 `GatherAppDelegate.swift:327-362`、`NewSessionSheet.swift:340-356`；测试 `C1BridgeWave1Tests.swift` | 真机未验（96 号 C1-1）；`selected variants` 在 16.7 为 hidden/deprecated，脚本只回退到单选 `primary variant`（`:576-582`） |
| G2 | reload 传 document 而字典要求 variant → ack 死锁；手动 Load 无写 ack 出口 | P0 | **已闭环** | `:167-180`（per-variant、无选中抛 `.noSelection`、仅 `reloaded>0` 才 `recordReloadAck`）、脚本 `:688-710`；UI 出口 `CullingSyncControls.swift:51-57`、`MetadataSyncBar.swift:184-190`、`LiveCullingAPI.swift:499`；门禁 `CullingSyncFlow.swift:35-52` | 仍盲发 + 固定 500ms sleep（`:178`），不验证 C1 真读到（R4/R9） |
| G3 | 读不到 C1 catalog 的判断（rating/色标/pick/关键词/album） | P0 | **部分** | 选中导入已带：`AppBootstrap.swift:744-769` → `C1ImportJudgementService.swift:220-304`，映射/合并 `:27-119`；pending 可见 `C1PendingJudgementNotice.swift:47-78` | ①只有"选中导入"一条入口（R4/R5）；②只读当前文档当前集合的选中项；③album/project 归属仍无；④等扫描最长 10 分钟且 pending 不持久化 |
| G4 | pick/reject 不可往返 | P1 | **部分** | keep 可写：`C1.swift:287-297`（keep-only）、`CaptureOneBridge.swift:996-998`；reject 一律不写（sdef:1084 无 reject 位）；测试 `C1BridgeWave3Tests.swift:50` | 淘汰在 C1 侧完全不可见；未用容器动作替代（`move inside` sdef:1805-1814 在 Sources 0 命中）→ R6；**XMP 关键词通道仍写 `culling:<decision>`**（`CullingSyncService.swift:373-377`）→ C1 Load 后会进它自己的词库 → R13 |
| G5 | Variant 模型不对齐（文件级 vs variant 级） | P1 | **部分** | 只改目标 variant、不覆盖同 image 其它 variant：`CaptureOneBridge.swift:973-1018`（目标 :985-989）；测试 `C1BridgeWave3Tests.swift:22,33` | 目标=启发式（已 pick 否则 variant 1），无 UI 选变体/显示变体数；读取 max 合并 vs 写单变体不可逆（R1） |
| G6 | Session/Album 结构不识别、不双向 | P1 | **部分** | 三目录：`C1.swift:385-457`；重定向 `NewSessionSheet.swift:191-201`、`AppBootstrap.swift:1108-1131`；信息条 `CullingInfoBar.swift:67-97`（Selects 边界 `:84`） | ①Selects 不同名文件不导入（已明示仍缺）；②重定向只覆盖 2 个 GUI 入口（R2）；③Album/Project/Smart Album 无映射 |
| G7 | 插件只 Open With、忽略 role、无法回传 C1 | P1 | **未闭环** | `desktop/coplugin/GatherLink/GatherLink.swift:4-9`（`pluginRole _`）、`:16-21`（只拼 `gather://import`） | 无 Edit/Publish 插件、role 不区分、无 variant id/集合回传 |
| G8 | 写回后 C1 是否"立刻看到"不可靠；盲发；缩略图不失效 | P1 | **部分** | 先 select 写盘照片再 reload：`CaptureOneBridge.swift:189-212`；失败上浮 + 手动 ack + 门禁按"ack 缺失"：`MetadataSyncBar.swift:246-259` | 仍固定 500ms 等；C1 改动不失效 Gather 缩略图（`CullingView.swift:165` 仅手动刷新 `invalidateAll`；FSEvents 只做 metadata 增量扫描 `SessionDirectoryMonitor.swift:1-10`，跨 20 册） |
| G9 | 元数据/模板模块无 reload 通道却受 ack 门禁 | P1 | **已闭环** | `MetadataSyncBar.swift:22-25,51-60,83-90,178-190,192-218`（复用 `CullingViewModel+Writeback.swift:204-210`）；测试 `C1BridgeWave4bTests.swift:208-209` | 自动 reload 仍只由挑片页事件驱动（`C1RoundTripCoordinator.swift:216-221`）→ R9 |
| G10 | "在 C1 中显示" API 有 / UI 无 | P1 | **已闭环** | `CullingSyncControls.swift:34-38` → `CullingViewModel+Writeback.swift:243-275` → `CaptureOneBridge.swift:229-303`；open -a 兜底语义已区分（`:267-271`）；C7 分支 `:275-283` | 无快捷键（原设计 ⌘⇧O，`plan-2026-10-30.md:889-896`）；跨集合无 browse（R3）；只加选不减选（R12） |
| G11 | 预览不含 C1 调整的提示无 UI | P2 | **未闭环** | `C1RoundTripPorts.swift:112-136`（`hasAdjustments`/`attributeNames`）；唯一消费是 `cropRect`（`LiveCullingAPI.swift:266-277`）；全 UI 无 `C1AdjustmentHint` 引用 | 用户仍不知道预览缺 C1 色彩/曲线/局部 |
| G12 | Hot Folder 无协同/无检测 | P2 | **已闭环（按边界）** | `C1.swift:459-472`（`canDetect=false`）；`C1HotFolderNotice.swift:10-21`；gate `CullingInspector.swift:445-449`、`IngestSheet.swift:95-98`；sdef grep `hot folder` = 0 | 检测能力客观不存在（C1 不暴露）——属正确取舍 |
| G13 | 未装 C1 / 多版本降级粗糙 | P2 | **部分** | `C1.swift:120-122`（`c1Installed`）；协调器没装即短路、不触发 TCC 弹窗 `C1RoundTripCoordinator.swift:179-192` | 菜单不置灰（`AppCommandCenter.swift:29-43` 只看 handler 是否安装）；安装判定仍固定 bundle id/路径（`Composition/Core.swift:434`） |
| G14 | 插件无安装/发现/兼容产品面 | P2 | **未闭环** | 手工装 `desktop/coplugin/Makefile:41-47`；release 仅内置 `desktop/native/build.sh:539-541`；app Sources grep `coplugin\|Plug-ins` = 0 | 无设置页安装/更新、无版本/兼容检查、无"插件未装"提示 |

> **P2 汇总**：G11 未闭环、G14 未闭环、G13 部分、G12 按边界闭合。
> **口径漂移**（不影响功能判断）：`90-wave-ledger.md:157` 仍写"reject→pick=false"，实际代码是 keep-only
> （`C1.swift:287-297`，Wave4a A3 后改）；复核以代码为准。

## 2. 剩余缺口表

> 读法：P1 = 每条工作流都会撞一次的能力缺失/摩擦；P2 = 有更好、没有也能用。
> 上轮已闭环项（G1/G2/G9/G10/G12）不在此表。R1–R12 与 §1 的"剩余差"一一对应。

| 级别 | 缺口 | 竞品怎么做（产品+链接） | Gather 现状（证据） | 成本 | 修法一句话 |
| --- | --- | --- | --- | --- | --- |
| P1 | **R1** 变体写回目标靠启发式，且"读 max 合并 / 写单变体"不可逆 | C1 的判断属于 variant，并注明"AppleScript 必须显式指定 variant"（sdef:262）；Bridge 走文件级 XMP，无 variant 歧义 | `CaptureOneBridge.swift:981-998`（已 pick→否则 `variant 1 of theImage`）；合并 `C1ImportJudgementService.swift:65-94`（rating=max、pick=OR） | S/M | 写前回读每个 image 的 variant 数与当前值：多 variant 让用户选目标（或只对单 variant 写 catalog、其余强制走 XMP），写后回读校验 |
| P1 | **R2** C1 Session 重定向只覆盖 2 个 GUI 入口，自动化/深链把 Session 根当普通目录 → Trash 淘汰件被导入 | C1 以 Session 三目录组织（[features](https://www.captureone.com/en/features)，本次 200 复验）；Bridge 无此问题 | 重定向仅 `AppBootstrap.swift:528`、`NewSessionSheet.swift:191-201`；自动化直连 `SessionCreateInput(filepaths:)` `AppBootstrap.swift:421-430`；通用导入 `:677-694` + `AppImport.swift:63-83`（单目录=sourcePath 全树扫描） | S | 把 `C1SessionDirectoryResolver.importPlan` 下沉到 `AppImport`/`GatherAutomationRuntime` 唯一入口，Session 根一律重定向到 Capture 并提示 Selects |
| P1 | **R3** 写回/选中/"在 C1 中显示"的作用域 = C1 当前集合；Gather 从不切换集合 | C1 有 `browse`（"Change the folder being browsed"，sdef:678-684）；Bridge 无库、无集合概念 | sdef:325（document 的 image/variant 元素=当前集合）、:736；匹配只在 `targetDoc` 内 `CaptureOneBridge.swift:612`；0 行 → notFound `:287-298`；UI 只报数 `CullingViewModel+Writeback.swift:262-266` | S/M | notFound>0 时用 `browse to path` 指向目标父目录后重试一次（或询问"让 C1 切到该目录"），再报 notFound |
| P1 | **R4** 判断数据只有"选中导入"通道：Session/目录/批量导入读不到 C1 判断 | Bridge 任意文件夹直接读写 XMP（[about-metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)）；C1 可对整批 Load Metadata（菜单串在应用内，帮助页细节 `[待核实]`） | 只有 `AppBootstrap.swift:744-769` 走 `selectedVariantSnapshot`；脚本只读 `selected variants` `CaptureOneBridge.swift:736-785`；目录导入无判断钩子（`AppImport.swift:51-95` 无 afterCreate） | M | 目录导入时按路径集合批量读（`every image of targetDoc whose path is "…"`，或先 `select` 再读），失败仍降级为仅文件导入 |
| P1 | **R5** C1→Gather 三入口能力不一致（判断/来源标/命名） | 无对应（C1/Bridge 都是单一入口） | 菜单：判断 + `source=capture-one`（`AppBootstrap.swift:744-769`、`AppImport.swift:31-35`）；新建工作区：只读路径（`DashboardViewModel+Actions.swift:59`）；插件/深链：通用 `onImportFiles` → `source=local`、无判断（`GatherAppDelegate.swift:233-238`、`AppBootstrap.swift:677-694`） | S | 把 snapshot+pending 上移到 `AppImport` 统一入口，三条 C1 入口共用同一套"判断+来源"语义 |
| P1 | **R6** 淘汰无法在 C1 表达（reject 不写；也无容器动作替代） | C1 有 Trash 集合与 `move inside`/`add inside`（sdef:1805-1814、:1795-1804），UI 有 Move to Trash（应用内菜单串） | `C1PickMapping` 只写 keep（`C1.swift:287-297`）；写回只写 rating/color tag/pick（`CaptureOneBridge.swift:991-998`）；`move inside`/`add inside` 在 Sources 0 命中 | M | 给"淘汰"一个显式 C1 动作：移入 Trash collection（或色标约定），UI 明示"不可逆、C1 无 reject 位" |
| P2 | **R7** 关键词无在线通道（`apply keyword` 未用），只能 XMP + 手动 Load | C1 `apply keyword`（sdef:1886-1893） | 写回明确不写关键词（`CaptureOneBridge.swift:893-896` 注释、:991-998 脚本）；关键词写回计划仍只有 XMP（`CullingSyncService.swift:341-375`） | S/M | 关键词写回时对选中 variant 调 `apply keyword`，与 XMP 通道二选一并说明差异 |
| P2 | **R8** 500 张上限只提示、不自动分批；跨页只写当前页 | 无对应（Bridge 无批量上限概念） | `maxVariantWritebackItems = 500` `CaptureOneBridge.swift:886,924-927`；UI 提示 `CullingViewModel+Writeback.swift:344-358`；items 只取当前页 `:391-419` | S | 500 自动分批 + 进度/取消；跨页按 selection 全量取路径，而不是只取 page assets |
| P2 | **R9** 自动 reload 只在挑片页在场时触发（元数据页写回后不会自动 reload） | 无对应 | `C1RoundTripCoordinator.swift:216-221`（"唯一事件源"）；订阅点 `CullingView+Content.swift:120-125`；全局广播点 `Composition/Core.swift:134-140` 只发 `c1-sync-status` | S | `deliveryEventSink` 里同时调 `noteDeliveryStateChanged`，任何页面的写回收敛都能触发 auto reload |
| P2 | **R10** 无 C1 桥诊断出口（C1 版本/sdef/插件安装/最近脚本错误） | C1 自带日志/支持包（帮助页 403，入口 `[待核实]`） | 诊断包是通用内容 `DiagnosticsCollector.swift:52-67`（manifest/tables/jobs/settings/logs）；C1 只散在日志（如 `CaptureOneBridge.swift:194-211`） | S | 诊断包加 `c1.json`：C1 版本+app 路径、sdef 摘要、插件是否安装、最近 N 次错误码与 stderr 摘要 |
| P2 | **R11** 未绑定 C1 文档身份（多文档/多 catalog 时写回目标不可辨） | C1 有 `document.id`/`name`/`documentType`（sdef:325-334、:308-310） | 会话只存 source 字符串（`AppImport.swift:78-82`）；bridge 从不读 document id | S/M | 导入时记录 `document.id + documentType`，写回/重载前比对，不一致要求确认 |
| P2 | **R12** "在 C1 中显示"只加选不减选（`deselect` 未用） | C1 select/deselect 成对（sdef:1956、:1967） | 脚本只 `select targetDoc variants …`（`CaptureOneBridge.swift:621`）；提示"已在 C1 中显示 N 张"与 C1 实际选中（旧选中+N）不符 | S | select 前先 deselect 当前集合的选中，或提示"追加选中" |
| P2 | **R13** XMP 写回仍把判断塞成 `culling:keep/reject` 关键词，C1 Load 后污染它自己的词库 | C1 的判断位是 variant.rating/color tag/pick（sdef:1084-1097），不该用关键词承载判断 | `buildCullingWritebackPlan` 的 `.keyword` 分支：`CullingSyncService.swift:373-377`（`["culling:\(decision.decision)"]`）；旧 G4 只修了变体级通道不写关键词 | S | 关键词写回只写用户关键词；判断用 variant 属性或显式白名单词，不再生成 `culling:*` |

## 3. 新发现（上轮未列 / Wave2–3 半成品）

1. **N1 变体级写回"能写但不可控"**：无变体列表、无法指定目标、无写后回读校验、无分批、无撤销。
   写的是 catalog 权威值（`CaptureOneBridge.swift:898-906`），选错变体只能去 C1 手工改回；
   而 96 号 §10 明确把"C1 写错 variant"列为 P0 判据。→ 归入 §4 第 1 项。
2. **N2 判断读取"只在一条路上"**：除三入口不一致（R5）与只认当前集合（R4）外，落库要等
   `metadata.scan` 终态（最长 10 分钟，`C1ImportJudgementService.swift:220-254`），pending 只在进程内
   （`C1PendingJudgementReplay.swift:13-14`）；状态条只有"重试同步"，**没有"重新从 C1 读取判断"**的入口。
3. **N3 "在 C1 中显示"是半成品**：只加选不减选（R12）、跨集合无 browse（R3）、无快捷键；
   兜底 `open -a` 仍可能触发一次真实导入（文案已标"可能触发导入"，但用户没有"仅 AppleScript"选项）。
4. **N4 插件深链退化为"通用导入"**：`gather://import` 走 `onImportFiles` → `source=local`、无
   `capture-one` 来源标、无判断（`GatherAppDelegate.swift:233-238` + `AppBootstrap.swift:677-694`）。
   插件与 C1 SDK 的 ABI 匹配仍只是静态比对（上轮 `[待核实]`），且无安装/版本提示（G14）。
5. **N5 判断来源不可见、不可撤销**：`CullingDecisionSource.imported` 无任何 UI 呈现
   （`GatherUI` 中 grep `decisionSource` = 0）。用户不知道哪些星级/keep 来自 C1，也不能
   "撤销这批导入判断"重来——这是"信任"层面的缺口，成本 S（加来源标 + 按 session 撤销）。
6. **N6 catalog 与磁盘 XMP 分叉**：变体级写回**只写 catalog、不写 XMP**（`CaptureOneBridge.swift:903-906` 明示），
   而其余写回写 XMP，C1 侧还有"Load Metadata"这个肌肉记忆动作（sdef:1852）。用户若在 C1 手动 Load，
   刚写进 catalog 的判断会被盘上旧 XMP 覆盖。建议：写回成功后把同一批值也写进 XMP（复用既有 writeback 队列），
   或在 UI 明确"不要再 Load Metadata"。

## 4. 本域最该补的 3 件事

### 4.1 写回正确性闭环（R1 + R3 + R12）—— S/M

- **理由**：本域唯一可能造成 C1 数据损坏的一类（写错 variant / 跨集合静默 notFound / 选中项与提示不符），
  且 96 号 §10 已把"写错 variant"定为 P0。目前唯一防线是一段启发式脚本，没有回读校验。
- **最小形态**：notFound>0 时先 `browse to path` 重试一次；写前回读每个 image 的 variant 数与当前值，
  多 variant 时提示并由用户选目标（或降级为只写 XMP）；写后回读校验并在状态条报告；
  `select` 前先 `deselect`。
- **验收**：C1 中一个 RAW 有 3 个 variant（1★/3★/5★）→ Gather 写 4★ → 只有用户指定/唯一 variant 变化，
  其余不动；C1 当前集合不在该文件夹时，点"写回"能自动切过去或明确给出可执行下一步。

### 4.2 入口一致性（R5 + R2 + R4）—— S/M

- **理由**：G3 的"导入即带判断"只在菜单生效；用户从主界面"新建工作区（Capture One）"（`NewSessionSheet.swift:355`）
  进来拿不到任何 C1 判断，等于半个功能；自动化入口还会把 Session 根当普通目录，把 Trash 扫进工作区。
- **最小形态**：把"读 C1 判断（失败降级）+ C1 Session 重定向"下沉到 `AppImport`/`GatherAutomationRuntime`
  的单一入口，菜单/工作台/插件深链/Shortcuts 四条路共用。
- **验收**：四条入口各导一次同一批 C1 选中照片 → 星级/色标/keep 一致；通过 Shortcuts 传 C1 Session 根
  → 只导入 Capture，Trash 不出现，信息条明示 Selects 边界。

### 4.3 判断回传完整性（R6 + R7）—— M

- **理由**：Gather 现在能往 C1 写 rating/color tag/keep，**淘汰与关键词两个核心判断出不去**；
  C1 的 `move inside`（Trash 集合）与 `apply keyword` 都是现成能力（sdef:1805、:1886），只差接线。
- **最小形态**：淘汰 = 显式"移入 C1 Trash 集合"动作（或在设置里选色标约定），UI 明示不可逆；
  关键词写回时对选中 variant 调 `apply keyword`，与 XMP 通道二选一并说明差异。
- **验收**：Gather 淘汰 3 张 → C1 中这 3 张出现在 Trash 集合；关键词库批量套一个词 → 写回后 C1 词库可见
  （不需要 Load Metadata）；再导回 Gather 时淘汰仍是"已淘汰/需要用户确认"而非自动复活。

## 5. 明确不是缺口（ROADMAP 取舍与域边界，防误报）

- **不解析 `.cos` / 不写 catalog DB**（`docs/ROADMAP.md:69-71` 不做 DAM 迁移；`CaptureOneBridge.swift:223-227`
  边界注释）。替代方案就是 AppleScript 变体通道，本轮已落地，不再作为缺口。
- **变体级写回后不再 reload** 是 2026-11-11 的批准口径（`CaptureOneBridge.swift:898-906`，"catalog 已是权威"），
  不报为缺口；真实风险是 N6 的 XMP 分叉（已按"建议"记录）。
- **Hot Folder 不检测**：sdef 全文无 hot folder 术语（grep 0），提示即正确行为（G12 已按边界闭合）。
- **Selects 中不同名文件不导入**：已确认边界并在信息条明示（`CullingInfoBar.swift:84`）；本报告只在
  "入口覆盖不全"（R2）与"无判断通道"（R4）上算缺口。
- **reject 不写 `pick=false`**：C1 16.7 只有布尔 pick（sdef:1084），写 false 是不可逆的破坏性动作，
  keep-only 是刻意设计（A3）。真正缺口是"没有替代表达"（R6），不是"没写 false"。
- **不做 C1 双向自动同步 / 不订阅 selection changed**：ROADMAP §四 4.1 明确"待做"未承诺
  （`docs/ROADMAP.md:51`）；因此"在 C1 里换选中 Gather 无感知""C1 改图不自动重载"不作为缺口。
- **不做 C1 配方/批处理/导出/重命名**：属 40 册导出交付域（sdef:2034 `batch rename`、:1765 `process`
  存在但不属本域缺口）。
- **不承诺预览含 C1 色彩**：本域只读 XMP 的 `crs:` 叠层（`CaptureOneBridge.swift:1044-1159`），预览语义归 20 册。

## 附 证据索引（本次读过的文件）

- 上轮/背景：`docs/reviews/2026-11-10-competitive-gap/30-c1-bridge.md`、`96-manual-acceptance.md`
  （§1 C1-1..C1-10、§9 已知未闭环、§12 记录表）、`90-wave-ledger.md`、
  `97-post-implementation-review.md`（§3.1 C1 A1–A5、§4 P2 列表）、`docs/ROADMAP.md`
- 协议/服务：`gather-core/.../GatherProtocol/Protocol/C1.swift`、`C1SyncState.swift`、`Core.swift`（错误码）、
  `API/CullingAPI.swift`、`API/MetadataAPI.swift`；`GatherApplication/Services/C1/C1ImportJudgementService.swift`、
  `C1PendingJudgementReplay.swift`、`C1ScanJobSelection.swift`
- 宿主/桥：`GatherHost/CaptureOneBridge.swift`、`C1RoundTripCoordinator.swift`、`AppBootstrap.swift`、
  `GatherAppDelegate.swift`、`AppImport.swift`、`APIs/LiveCullingAPI.swift`、`Composition/Core.swift`、
  `SessionDirectoryMonitor.swift`、`SessionWorkspaceFactory.swift`
- UI：`GatherUI/Culling/CullingSyncControls.swift`、`CullingViewModel+Writeback.swift`、`CullingSyncFlow.swift`、
  `C1RoundTripPorts.swift`、`CullingInfoBar.swift`、`C1HotFolderNotice.swift`、`CullingInspector.swift`、
  `CullingToolbar.swift`、`CullingView.swift`、`CullingView+Content.swift`、`IngestSheet.swift`、
  `Metadata/MetadataSyncBar.swift`、`Metadata/C1PendingJudgementNotice.swift`、`Support/C1StatusCapsule.swift`、
  `Dashboard/DashboardViewModel+Actions.swift`、`Dashboard/NewSessionSheet.swift`、
  `Settings/SettingsView+C1HealthSection.swift`、`Settings/SettingsViewModel+C1Health.swift`、
  `Shell/RootShellOverlay.swift`、`Interaction/AppCommandCenter.swift`
- 维护/诊断：`GatherApplication/Services/Maintenance/DiagnosticsCollector.swift`
- 插件/构建：`desktop/coplugin/GatherLink/GatherLink.swift`、`GatherLink/Info.plist`、`desktop/coplugin/Makefile`、
  `desktop/native/build.sh`（插件段 539-604）
- 测试钉子：`Tests/GatherAppTests/C1BridgeWave1Tests.swift`、`C1BridgeWave2Tests.swift`、
  `C1BridgeWave3Tests.swift`、`C1BridgeWave4Tests.swift`、`C1BridgeWave4bTests.swift`
- 本机 C1 字典（16.7.8.16）：sdef `:195`（current document）、`:240`（selection changed script）、
  `:244-253`（selected variants / primary variant）、`:262`（edit all selected variants 对 AppleScript 无效）、
  `:308-310`（documentType）、`:325-334`（document 元素/属性）、`:678-684`（browse）、
  `:685-692`（collectionType）、`:713`（collection）、`:736`（document.images=当前集合）、
  `:1071-1097`（variant：pick/position/color tag/rating）、`:1538-1541`（image/path）、
  `:1805-1814`（move inside）、`:1852-1858`（reload/sync metadata per variant）、
  `:1886-1893`（apply keyword）、`:1956-1977`（select/deselect）、`:1986-1996`（import）、
  `:2034-2048`（batch rename/synchronize）；grep `hot folder` = 0
- 竞品（本次复验 200）：[captureone.com/features](https://www.captureone.com/en/features)、
  [Bridge label-and-rate-files](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/label-and-rate-files.html)；
  复用上轮已核：[about-metadata](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html)、
  [C1 plug-ins](https://www.captureone.com/en/partnerships/plug-ins)
