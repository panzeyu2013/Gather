# 交互审计 D：相似度 / 重复 / 人脸关键词 / 人物库（2026-10-30）

- 范围：`Similarity/`(14 文件 2176 行)、`Duplicates/`(4 文件 1056 行)、`FaceKeywording/`(15 文件 2660 行)、`Persons/`(2 文件 927 行)
- 方式：只读静态审计（read/grep/统计），未构建、未实机
- 路径简写：**`G/` = `desktop/native/gather-app/Sources/GatherUI/`**（例：`G/Similarity/SimilarityView.swift:94`）
- 基线：三轮评审收口 `docs/reviews/functional-usability-remediation-2026-10-30.md` 的残余 P2（人物多 dialog）在本轮复核仍然成立，行号见 P2-1。

---

## 结论

1. **四个模块都有"参数 → 运行中 → 结果审阅 → 写回"的四段骨架，但"完成态"是易失的。** 相似度把"页面每次进入时的结果刷新"当成"结果被替换"：`.task` → `load()` → `adoptResult()` 无条件清空选择、展开态、写回预览/报告与 C1 收尾面板。写回 XMP 之后切到图库再回来，`确认同步/清理` 两个按钮永久消失，而页面指引仍在叫用户点它们（P1-1）。
2. **相似度的"拖阈值自动采纳预计算档"会用草稿参数重写结果指纹**：采纳的档位由`上一次分析时`的 minGroupSize/groupingMode 生成，但指纹记的是当前草稿值，于是屏幕上的"顺序分组 / 最小组大小 8"可以和实际分组不符，且过期黄条不再出现（P1-2）。
3. **人物库的编辑没有脏状态**：切换人物、被 `.persons` 域事件触发 `load()`、离开页面，都会静默丢弃未保存的名称/备注，无提示、无自动保存、无二次确认（P1-3）。
4. **确认弹窗叠层问题仍在**：人脸 9 个 `.gatherDestructiveConfirm` 全部挂在同一个 body 节点（`G/FaceKeywording/FaceKeywordingView+Confirmations.swift:163/171/179/189/198/207/216/228/240`），人物 3 个挂在同一 `PersonDetailView`（`G/Persons/PersonsView.swift:486/515/541`）。重复页已刻意拆到不同视图节点（`G/Duplicates/DuplicatesView.swift:149-150` 的注释），可作为范式。**若实机确认"只弹最后一个"，人脸页升 P0（写回确认弹不出来）。**
5. **反馈通道三套并行、可回看性不同**：相似度的 `notice` 是**裸文本**（`G/Similarity/SimilarityView+Writeback.swift:72-75`）、重复/人脸是**不可关闭的常驻横幅**、人物是**5s 后自动消失的 toast 且立刻 `clearActionError()`**。同一类事件（取消/成功/失败）在四个模块里的呈现与留存完全不同。

---

## 发现

### P0

无。四个模块的写命令都经 `Confirmed(source: .userDialog)` 门控，未发现"无确认即破坏"的路径。

### P1

#### P1-1 · 相似度：离开页面再回来，选择/展开/写回报告/C1 收尾入口全部被清空

**位置**
- `G/Similarity/SimilarityView.swift:94-100`（`.task(id: viewModel.sessionId)` → `load()`）
- `G/Similarity/SimilarityViewModel+Load.swift:22-24`（`load` 无条件 `adoptResult`）
- `G/Similarity/SimilarityViewModel+Result.swift:15-24`
- `G/Similarity/SimilarityView+Writeback.swift:83-85`、`:178-188`

```swift
// SimilarityViewModel+Result.swift:15-24
func adoptResult(_ newResult: SimilarityResult, syncThreshold: Bool) {
    guard syncThreshold else { return }
    resultRequestID += 1
    result = newResult
    markWritebackDraftChanged()      // writebackPreview / writebackResult / syncView = nil
    selectedGroupIds = []
    expandedGroupIds = []
    showAllMemberGroupIds = []
}
```

**现象**：页面按目的地条件构建，离开即销毁；回来时 `.task` 重跑 `load()`，只要库里有结果就再次 `adoptResult`（即使是**同一份**结果，没有等值判断）。于是：
1. 勾好的 10 个分组回到页面就没了；
2. C-1 审计特意搬进 VM 的"跨页签保留展开态"（`G/Similarity/SimilarityViewModel.swift:234-242`）被这行清掉，**文档宣称的行为实际不成立**；
3. `writebackResult` 被清 → `writebackReport` 整块不渲染 → `确认同步/清理` 两个**唯一入口**消失（全仓 grep 只有 `G/Similarity/SimilarityView.swift:144-145` 的确认弹窗和写回面板里的按钮会调 `confirmSync()/cleanupKeywordWriteback()`）。而上方指引 `G/Similarity/SimilarityView+Writeback.swift:69` 还在说"再点击「确认同步」和「清理」"。

**用户影响**：写回 XMP 后为了在 C1 里核对而切到图库/挑片看一眼，回来就再也无法在相似度页把这次写回"结清"，临时 XMP 一直留着；页面还留着"已写入 N 项"的 notice 和一段指向空气的指引。唯一的绕行是在**挑片页**工具栏「同步… → 恢复原 XMP」（`G/Culling/CullingSyncControls.swift:46-50`），但相似度页没有任何提示指向它。

**修复建议**：`load()` 里对"服务端结果与当前 `result` 相同（stats+groups id 集合）"走"不 adopt"分支；或把 `markWritebackDraftChanged/selectedGroupIds` 的清理从 `adoptResult` 拆出来，只在**结果代变化**时调用。C1 收尾面板（`syncControls` 三按钮）与 `writebackResult` 解耦：只要有 `syncView.written > 0` 就应当可见，不应依赖本次页面会话里刚跑过写回。

#### P1-2 · 相似度：阈值档自动采纳后，"结果参数指纹"记的是草稿值，参数与分组可以不一致且不再提示过期

**位置**
- `G/Similarity/SimilarityView+Analysis.swift:36-48`（滑块 setter 调 `thresholdDraftChanged()`）
- `G/Similarity/SimilarityViewModel+Analysis.swift:29-45`（`adoptTier` 只按 threshold 查询）
- `G/Similarity/SimilarityViewModel+Result.swift:25-35`
- 服务端口径：`desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SimilarityInputs.swift:16-26`（`SimilarityResultQuery` 只有 `sessionId + threshold`）、`.../Similarity/SimilarityService+Hashes.swift:164-184`（档位用**分析时**的 `minGroupSize`/`groupingMode` 生成后写进同一 threshold 行）

```swift
// SimilarityViewModel+Result.swift:25-35
threshold = Int(newResult.stats.threshold)
if newResult.stats.precomputed != true {
    minGroupSize = newResult.stats.minGroupSize
    groupingMode = newResult.stats.groupingMode
}
resultParams = SimilarityResultParams(threshold: threshold,
                                      minGroupSize: minGroupSize,   // 草稿值，不是产结果的参数
                                      groupingMode: groupingMode)
```

**现象**：预计算档只由 threshold 索引，档内的 minGroupSize/groupingMode 来自**上一次分析**。UI 采纳时不同步这两个值，却把当前草稿值写进指纹 → `isResultStale`（`G/Similarity/SimilarityViewModel.swift:262-269`）恒为 false。
复现路径：高级参数把"最小组大小"从 2 改到 8 → 只拖"相似度阈值"滑块到某个有预计算档的档位（≥300ms 防抖后自动采纳）→ 网格换成**用 2 生成**的分组，界面写着"最小组大小 8"，没有黄条。分组范围同理（切到"顺序分组"后拖阈值 → 拿到全局分组的结果）。

**用户影响**：专业用户靠这两个参数控制分组粒度，屏幕给出的分组与参数矛盾且系统保证"没有过期"——比直接报错更伤信任；之后按这组分组写回关键词，等于把错误粒度固化进 XMP。

**修复建议**：`adoptResult` 对 precomputed 档也同步 `resultParams` 用**服务端返回的 stats`**（而不是草稿），并让 `isResultStale` 比"服务端 stats vs 草稿"；或干脆禁止在 minGroupSize/groupingMode 与上次分析不同的时候走自动采纳，改为只提示"参数已变，请重新聚类"。

#### P1-3 · 人物库：编辑草稿无脏检查，切人/刷新/离页静默丢弃

**位置**
- `G/Persons/PersonsView.swift:365-391`（`Form` 里 `@State name/notes` + 唯一的"保存"）
- `:478-485`（`.onAppear` / `.onChange(of: person.id)` 用服务端值覆盖本地草稿）
- `:212-215`（`phase != .loaded` → `Color.clear`，详情视图被销毁）
- `G/Persons/PersonsViewModel.swift:55-56`（`load()` 先置 `.loading`）
- `:92-101`（`.refreshOnDomainEvents([.persons])` → `load()`）

**现象**：`name/notes` 是 `PersonDetailView` 的 `@State`，没有任何 isDirty 标记、自动保存或离开前确认。以下任一动作都会把用户刚输入的内容换回服务端旧值：点列表里的另一个人（`onChange(of: person.id)`）；任何 `.persons` 域写路径广播（例如在别的工作区绑定人脸簇会 `publishChange(.faceKeywording, .persons)`，`G/FaceKeywording/FaceKeywordingViewModel+Review.swift:25`）触发 `load()` → `phase=.loading` → 详情视图销毁重建；离开页面再回来。

**用户影响**：改一个 15 字的人名后顺手点另一个人核对，15 字白打；系统没有任何"未保存"信号。

**修复建议**：`PersonDetailView` 上加 `isDirty`（`name != person.name || notes != person.notes`）→ 保存按钮旁显示"未保存"，`onChange(of: person.id)` 时若 dirty 弹一个"放弃修改？"三选（保存/放弃/取消）；`load()` 的 `.loading` 分支不要销毁详情（保留视图，只在列表上出 loading）。

### P2

#### P2-1 · 确认弹窗同节点叠挂（残留 P2 仍在，给出当前行号）

- 人脸：`G/FaceKeywording/FaceKeywordingView+Confirmations.swift:163,171,179,189,198,207,216,228,240` —— **9 个** `.gatherDestructiveConfirm` 全部链在 `confirmationChrome(_:)` 的同一个 `content` 上；文件头注释写"8 个"，实际 9 个（拆分是后加的）。
- 人物：`G/Persons/PersonsView.swift:486`（合并人物）、`:515`（移除此照片）两个 `.confirmationDialog` + `:541` 一个 `.alert`，同一 `PersonDetailView` 节点。
- 对照：重复页刻意分节点并在注释里写明原因 `G/Duplicates/DuplicatesView.swift:127/151/176` + `:149-150`。
**影响（条件性）**：若 macOS 26 上同一节点的多个 presentation 只保留最后一个，人脸页"确认写回/清理/确认同步"这些最关键的确认会弹不出来——症状是**点按钮完全没反应**（pending 被写成非 nil，但没有任何 sheet 出现，再点也不会有第二次）。未实机验证，故按既有口径记 P2；一旦实机复现即 P0。
**建议**：照重复页的写法，把人脸 9 个按"步骤内容节点"拆开（写回/清理 → `stepWriteback` 节点；拆分/移除/合并/解绑 → `detailPane` 节点），人物把 `.alert` 与两个 dialog 分挂到不同子节点。

#### P2-2 · 重复：每一张的"保留/丢弃"都要过一次全页弹窗

- `G/Duplicates/DuplicatesGroupCardView.swift:121-123`（成员按钮）→ `G/Duplicates/DuplicatesView.swift:151-167`（`pendingMemberDecision` 弹窗）
- 弹窗文案自己承认可逆：`G/Duplicates/DuplicatesViewModel.swift:70-71`"保留/丢弃都只改数据库标记（不删文件、可反向操作），不使用红色破坏性语义"，`confirmRole` 也是 `nil`。
**现象**：组内核心操作是"把留下的改回保留、把要删的标丢弃"。12 人组调整 3 张 = 3 次点击 + 3 次弹窗，每次都盖住整页、打断视觉比对；而"保留最佳/保留全部"这种真正影响一批的操作反而只弹一次。
**影响**：裁决速度被拖慢，用户会退化成只用"保留最佳"（放弃人工微调），或干脆不敢点。
**建议**：成员级保留/丢弃改为**即时生效 + 底部/行内撤销**（服务端已支持反向命令），或提供"批量设为保留/丢弃（已选 N 张）"一次确认；保留"保留最佳/全部保留/恢复未处理"的弹窗。

#### P2-3 · 重复：头部计数与分段 Tab 计数是两个数据源，扫描后 `load()` 失败会自相矛盾

- 头部：`G/Duplicates/DuplicatesView.swift:85` 用 `scanResult.exactGroups.count / visualGroups.count / totalDuplicates`
- Tab 与空态：`G/Duplicates/DuplicatesView+Sections.swift:127-128`（`viewModel.exactGroupCount / visualGroupCount`，来自 `groups`）、`:165-177`
- 赋值顺序：`G/Duplicates/DuplicatesViewModel.swift:219-223`（先 `scanResult = ...` 再 `await load()`），`load()` 失败时 `groups` 保持旧值/空（`:198-203`）
**现象**：扫描成功但紧接着的 `groups` 拉取失败时，页面同时出现"完全重复：3 组 … 总计重复：7 张"和 Tab"完全重复 · 0"以及"未发现完全重复的照片"。
**建议**：单一真源——Tab 计数与头部都从 `groups` 派生（`scanResult` 只用于"是否扫描过"），或让 `scan()` 复用返回体里的分组而不额外 `load()`。

#### P2-4 · 相似度：`确认同步`/`清理` 的禁用理由只写在 `.help` 里（禁用按钮不显示 tooltip）

- `G/Similarity/SimilarityView+Writeback.swift:181-188`
```swift
Button(l10n("确认同步")) { ... }
    .disabled(viewModel.isSyncBusy || !controls.canConfirmSync)
    .help(controls.confirmHint.map { l10n.resolve($0) } ?? "")   // 禁用时不可见
Button(l10n("清理"), role: .destructive) { ... }
    .disabled(viewModel.isSyncBusy || !controls.canCleanup)
    .help(controls.cleanupHint.map { l10n.resolve($0) } ?? "")
```
- 反证：同仓库自己写下了这条规律 —— `G/FaceKeywording/FaceWritebackStep.swift:41`"前置条件写在可见文案里：.help 在禁用按钮上不会显示"，并在 `:240-244` 用可见文案补了清理的前置条件。
**影响**：`confirmHint` 的四个分支（已完成/未加载元数据/等待写入/处理失败）用户一条也看不到，只剩状态行"同步状态：…"和一段通用操作说明；而"加载元数据"按钮却把 hint 写成了可见文本（`:197-201`）——同一行三个按钮两种待遇。
**建议**：把 `confirmHint/cleanupHint` 在按钮下方渲染成 `GatherFont.secondary` 的可见一行（与"加载元数据"同款），`.help` 保留。

#### P2-5 · 相似度：`取消分析`没有结束反馈，且丢弃服务端返回值

- `G/Similarity/SimilarityViewModel+Analysis.swift:110-121`
```swift
public func cancelAnalysis() async {
    isCanceling = true; defer { isCanceling = false }
    isAnalyzing = false
    stopProgressPolling()
    do { _ = try await similarity.cancelAnalysis(sessionId) }      // Bool 被丢弃
    catch { actionError = CommandError(error) }
}
```
**影响**：点了"取消分析"，进度区直接消失，没有"已取消"提示（重复页 `DuplicatesViewModel.swift:227-229` 与人脸 `FaceKeywordingViewModel+Analysis.swift:72-79` 都会写 notice）；若服务端返回 false（没有可取消的任务）界面同样当作已停，之后任务真正完成也不会刷新（结果轮询未启动）。
**建议**：成功分支写 notice"已取消相似度分析"；`cancelAnalysis` 返回 false 时改为"未找到进行中的分析，已刷新状态"并触发一次 `refreshResult()`。

#### P2-6 · 相似度：`开始分析`与`重新聚类`可并发；分析中 ⌘R 会把分析成果丢弃

- `G/Similarity/SimilarityView+Analysis.swift:62-73`（`开始分析` 只 `.disabled(isAnalyzing)`，不看 `isReclustering`）
- `G/Similarity/SimilarityViewModel+Analysis.swift:64-65`（`startAnalyze` 只 guard `!isAnalyzing`）、`:125-126`
- `G/Similarity/SimilarityViewModel+Analysis.swift:83`+`:93`（`runAnalysis` 用 `resultRequestID` 做代次守卫）
- `G/Similarity/SimilarityView+Toolbar.swift:15`（`refreshKeyboardShortcut: true`，未传 `refreshDisabled`）
**影响**：重新聚类进行中点"开始分析"→ 两个写路径同时跑；分析进行中按 ⌘R 触发 `load()` → `adoptResult` 让 `resultRequestID` +1 → 分析结束时 `guard requestID == resultRequestID else { return }` 直接 return，**新结果被静默丢弃**，页面停在旧分组且没有任何提示。重复页对同样场景传了 `refreshDisabled: viewModel.isLoading || isScanning`（`G/Duplicates/DuplicatesView.swift:200`）。
**建议**：两个按钮互斥禁用；分析中 `refreshDisabled = true`（或 `load()` 在 `isAnalyzing` 时只刷同步状态不 adopt 结果）。

#### P2-7 · 相似度：写回面板排在结果之前、宽度与页面不一致

- `G/Similarity/SimilarityView+Content.swift:25-58` 顺序是 `analysisPanel → writebackPanel → progress → result/grid`；写回面板需要用户先在**下面**的网格里勾组。
- 宽度：分析卡 `.frame(maxWidth: 760)`（`G/Similarity/SimilarityView+Analysis.swift:77`），页面 `maxReadingWidth 1100`（`G/DesignSystem/Tokens/GatherStyle.swift:56`），写回卡与网格无上限 → 宽窗下右边缘三级参差。
**影响**：勾选时"已选 N 组"在视口外；写回动作在结果之前，读者顺序与任务顺序相反。最小窗（860，侧栏 260）内容约 552pt 时三块同宽，问题不显；宽屏/全屏时明显。
**建议**：写回面板移到结果之后（或做成结果区的吸底操作条），三块统一宽度上限；"已选 N 组"在网格顶部统计条上再显示一次。

#### P2-8 · 相似度：分组勾选框的无障碍标签缺少"是哪一组"

- `G/Similarity/SimilarityGroupCardView.swift:47-52`
```swift
Toggle(isOn: selectionBinding) {
    Text(l10n.format("选择分组 %lld 张", group.count))   // 只有张数
}
.toggleStyle(.checkbox)
.help(l10n("选择分组"))
```
**影响**：VoiceOver 顺序经过 N 张卡片时会读出 N 个"选择分组 3 张"（同计数分组完全无法区分），必须回头靠组号/标签推理。
**建议**：标签带上 `group.label`（"选择分组 3 张 · 2024-05-01 连拍"），`.help` 保留。

#### P2-9 · 相似度：`representative` 对空成员组会数组越界

- `G/Similarity/SimilarityGroupCardView.swift:129-131`
```swift
private var representative: SimilarityImage {
    group.images.first { $0.representative == true } ?? group.images[0]   // 空数组崩溃
}
```
**影响**：服务端返回 0 成员的组（或分组 JSON 残缺）会让整页崩溃而不是显示空组——分析和写回都会连带失效。
**建议**：返回可选，空组渲染占位并禁用勾选。

#### P2-10 · 重复：扫描中离开再回来，进度数字冻结

- 进度只靠页内 `.onReceive(GatherEventCenter.jobProgress)`（`G/Duplicates/DuplicatesView.swift:170-173`），VM 里没有 jobs.list 恢复
- 回来只跑 `.task { await viewModel.load() }`（`:169`），不会重新对齐 `scanProgressCurrent/Total`
**影响**：离开页签 30s 再回来，指示器仍显示 12/200 与旧阶段，而扫描其实已经推进（或已结束）；`isScanning` 为真期间按钮全灰，用户无法判断是否卡死。
**建议**：照人脸的 `recoverAnalysis()`（`G/FaceKeywording/FaceKeywordingViewModel.swift:332-355`）在 `load()` 里补一次活跃 `duplicateScan` job 的进度回填。

#### P2-11 · 重复："推荐"徽章没有判据说明

- 算法：`G/Duplicates/DuplicatesViewModel.swift:430-448` 注释写明 `score = fileSize*1000 + mtime`；UI 只有 `G/Duplicates/DuplicatesGroupCardView.swift:92-97` 的一个 `GatherBadge("推荐")`，无 `.help`、无图例，确认弹窗也只是一句"仅保留推荐「x」"（`DuplicatesViewModel.swift:36-40`）。
**影响**：用户不知道"推荐"是按**文件最大 + 修改时间最新**选的（与画面质量无关）。在 RAW/导出 TIFF 混放的组里，推荐很可能是最不该留的那张，用户却倾向于信任它。
**建议**：徽章加 `.help("按文件大小与修改时间综合排序（越大越新优先），不代表画质") `，并在卡片头/组菜单里放一个"推荐依据"说明。

#### P2-12 · 重复：切 Tab 清空展开态、宽窗无阅读宽度约束、取消无"取消中"

- `G/Duplicates/DuplicatesView+Sections.swift:134-136`（切 Tab → `resetPagination()`，内部同时 `expandedGroupIds.removeAll()`，`G/Duplicates/DuplicatesViewModel.swift:385-388`）→ 用户在两栏来回比对时展开态反复丢。
- `G/Duplicates/DuplicatesView.swift:145-147` 只有 `pageGutter + maxWidth .infinity`，没有 `maxReadingWidth`：宽窗下分组卡被拉满整屏（相似度 1100、人脸 900）。
- 取消：`G/Duplicates/DuplicatesView+Sections.swift:30-34` 没有 `isCancelling`，可连点重复发 `jobs.cancel`；`G/Duplicates/DuplicatesViewModel.swift:258-273` 也没有"正在取消"状态。
**建议**：切 Tab 只重置分页不清展开；补 `maxReadingWidth`；取消按钮点击后置 `isCancelling` 并显示"正在取消…"。

#### P2-13 · 人脸：写回前就能"重新加载/确认同步"，清理入口只在本次运行内存在

- `G/FaceKeywording/FaceWritebackStep.swift:212-246` 的 `reportActionsRow` 在 `preview != nil` 即渲染（`:26`/`:48-54`），此时 `writebackResult == nil` 也可点：
  - `：224` "Capture One 重新加载"（没有任何已写内容）
  - `：227` "确认同步"（无写回也能把 `isSyncConfirmed` 置真，`G/FaceKeywording/FaceKeywordingViewModel+Writeback.swift:126-135`）
  - 之后 `：230` 的"清理备份"出现，`writtenCount` 取 `writebackResult?.written ?? 0` → 弹窗写"0 个"
- 反向：`isSyncConfirmed` 是纯内存布尔（`G/FaceKeywording/FaceKeywordingViewModel.swift:78`），App 重启或 workspace 被 LRU 淘汰（容量 6，`G/Support/SessionStore.swift:16`）后，即使服务端已是 `safeToCleanup`，**清理备份入口也不会再出现**；成功清理后也不复位，按钮仍在（`+Writeback.swift:139-154`）。
**对照**：相似度是从服务端 `writeback_items` 聚合 `state` 推导三个按钮（`G/Similarity/SimilarityViewModel+Sync.swift:35-55`、`:59-104`）。
**建议**：`reloadCaptureOne/确认同步` 至少要求 `writebackResult != nil`（否则改成可见说明）；清理入口改为按服务端同步状态推导，成功后复位。

#### P2-14 · 人脸：`拆分所选` 是页面最显眼的按钮但通常禁用，理由只在 tooltip；详情栏最小宽度下头部放不下

- `G/FaceKeywording/FaceReviewStep.swift:191-199`：`.buttonStyle(.borderedProminent)`（设计规范要求主 CTA 用 `.gatherPrimaryActionButton()`，`docs/design/appearance-interaction.md:139`），与下方 `绑定`（`:315` 的 `gatherPrimaryActionButton`）在同一栏里**两个主按钮**；禁用理由 `splitHelp` 只挂在 `.help`（`:199`），而 `.help` 在禁用态不显示。
- 同一头部 HStack（`：173-200`）在 240pt 最小详情宽度下估算约需 300pt（"仅看待复核成员"复选框 ~120 + "已选 N 个" ~60 + "拆分所选（N）" ~115 + 间距），`HSplitView` 又给了 `minWidth: 240`（`：45-47`）→ 最小窗口下按钮/文案会被压缩截断（**估算，未实机**）。
- 全选只有 ⌘A（`:287-292`），列表上方没有任何"全选"可见入口；且只选**当前已加载的一页**（`G/FaceKeywording/FaceKeywordingViewModel+SplitReview.swift:135-137`），200 人的簇里会自动选中前 50 个。
**建议**：拆分改次要按钮样式，理由写成可见一行（"先勾选要移出的成员，且至少保留 1 个"）；头部改两行；补"全选本页"复选框并说明范围。

#### P2-15 · 人脸：同角色深链不跳步；示例状态"取消"后仍显示"分析中"

- `G/FaceKeywording/FaceKeywordingViewModel.swift:299-304`：`applyRoleFilterFromDeepLink` 在 `roleFilter == role` 时直接 return，不执行 `if analysisDone { step = .review }`。从人物库对**同一个角色**再点一次"前往人脸审核"，页面停在 VM 上次的步骤（可能是写回/分析），与按钮承诺的"按角色复核"不符。
- `G/FaceKeywording/FaceKeywordingViewModel+Analysis.swift:117-149`：`applyJobEvent` 的非终态分支无条件 `analysisPhase = .running`；而 `recoverAnalysis`（`FaceKeywordingViewModel.swift:339-350`）在无活跃 job 时会把 `.running` 复位成 done/idle —— 用户在分析开始瞬间按 ⌘R（`:16` 的 `reload`）有机会把徽标从"分析中"翻回"未开始/已完成"，取消按钮随之消失。
**建议**：深链无论是否同角色都强制 `step = .review`（`analysisDone` 时）；`reload()` 不要覆盖本地 `.running`（以"本进程发起的分析"为准）。

#### P2-16 · 人物：`⌘` 取消选择无效 → "未选择人物"态不可达；搜索时详情可显示不在结果里的人

- `G/Persons/PersonsView.swift:124-134`：`selectionBinding` 的 setter `guard let newValue else { return }`，注释却写"⌘ 取消选中交给 List" → 取消后 VM 仍持旧 id，系统选中会弹回；`:234-240` 的"未选择人物"空态因此实际上不可达（`load()` 有列表时总会自动选中第一个，`G/Persons/PersonsViewModel.swift:62-66`）。
- `filteredPersons`（`PersonsViewModel.swift:44-48`）只过滤列表；右栏读 `viewModel.selected`（`PersonsView.swift:216`）→ 搜索"张"之后，右栏仍显示上一个（可能不匹配的）人物的完整详情，容易误以为搜索结果就是这个人的资料。
**建议**：允许 nil 选择并渲染"未选择人物"；搜索词非空且当前选中项不在 `filteredPersons` 时，右栏改为"该人物不在搜索结果中（显示全部/清除搜索）"或自动切到第一个命中项。

#### P2-17 · 人物：新建人物后没有"下一步"；移除照片只藏在右键菜单

- `G/Persons/PersonsView.swift:400-412`：`前往人脸审核` 只在 `reviewTarget != nil`（即 `person.photos` 非空）时渲染；`:314-321` 的 `reviewTarget` 依赖照片所属工作区。刚建的人物没有照片 → 详情里**没有任何**把人脸簇绑到它的入口或说明，只能自己猜到"去某个工作区的人脸页手输角色名"。
- `:452-456`："移除此照片"只在缩略图 `contextMenu` 里，界面上没有任何可见入口（对比"删除人物"有独立按钮）。
**建议**：`photos.isEmpty` 时把按钮换成禁用态 + 可见说明"先在工作区的人脸页把簇绑定到「该人物」，这里才会出现照片"；移除照片的入口提到照片标题行或悬停按钮。

#### P2-18 · 人物：三处破坏性动作的"取消"反馈不一致

- `G/Persons/PersonsView.swift:541-567`（删除人物）取消会 `GatherToastCenter.show(.info, "已取消删除…")`；`:486-514`（合并）、`:515-540`（移除照片）的取消按钮只是 `pendingX = nil`，无任何提示。
- 结果反馈也分层：保存/合并/移除/删除的成功与失败都是 5s toast，且失败后立刻 `clearActionError()`（`:380-386`、`:499-506`、`:528-535`、`:545-557`）→ 错误在 5 秒后彻底消失，没有留存记录；页面级红条（`:47-54`）只覆盖 create 之外的一小部分路径。
**建议**：三个弹窗的取消统一给一句 info toast（或统一都不给）；写操作失败改为可关闭的常驻横幅（与相似度/重复/人脸一致），toast 只用于成功。

#### P2-19 · 跨模块：术语、内容宽度、字号 token、空态实现四处不一致

| 维度 | 相似度 | 重复 | 人脸 | 人物 |
|---|---|---|---|---|
| 对象命名 | **分组** / "分组关键字写回" vs 字段"**关键词**"（`G/Similarity/SimilarityView+Writeback.swift:28` vs `:45`） | 组 / **保留·丢弃** | **簇** / **角色**（绑定=角色名）/ "关键字"（`G/FaceKeywording/FaceReviewStep.swift:306`） | **人物**，但页面标题与侧栏都是"**人脸库**"（`G/Persons/PersonsView.swift:71`、`G/Shell/RootShellNavigation.swift:25`） |
| 内容宽度 | 760 / 1100 / 无上限 | 760 / 无上限 | 900 | Form 自适应 |
| 页面空态 | **无**（无结果时只有分析卡） | `ContentUnavailableView` | `ContentUnavailableView` | 自绘圆角卡 + 阴影（`G/Persons/PersonsView.swift:175-205`），未用规范里的 `GatherEmptyState` |
| 直接 `.font(.callout)`（规范禁止，`docs/design/appearance-interaction.md:147`） | 16 处 | 0 处 | 4 处 | 6 处（+1 处 `.font(.system(size:42))`） |

**影响**："关键词/关键字""人脸库/人物""簇/角色/分组"这些词在同一个会话的 7 个页签之间来回切换时反复变化；同类页面宽度不一，宽窗下四页的右边缘各不相同。
**建议**：先在文案表里定三个名词（人物 / 人脸簇 / 角色），"关键词"统一；内容宽度统一到 900–1000 一个值；字号全部回到 `GatherFont` 角色。

---

## 状态机表

### 相似度（`Similarity`）

| 阶段 | 用户可做的事 | 不可用时的提示 |
|---|---|---|
| idle（无结果） | 改分组范围/预设/高级参数；`开始分析`；切页签离开 | 写回面板不渲染；结果区**无空态**，页面下半部空白 |
| running | 看百分比 + 阶段文案；`取消分析`；离开页面（VM/Task 继续）；改分组选择 | `开始分析`→"处理中…"且禁用；`重新聚类`禁用；写回区有可见文案"相似度分析/聚类进行中，写回已暂时禁用"（`G/Similarity/SimilarityView+Writeback.swift:40-44`） |
| result | 勾选/全选、展开成员、打开照片、预览、写入 XMP、C1 三按钮、重新聚类 | `确认同步/清理` 的禁用理由只在 `.help`（P2-4）；参数变更→黄条"请重新聚类" |
| stale | `重新聚类` | 黄条提示（`G/Similarity/SimilarityView+Content.swift:45-51`），但**写回仍可用**且确认弹窗不提参数已变 |
| error | 页级`重试`；操作级错误条 | 页级 `ContentUnavailableView`；操作级红条（无关闭） |
| 离开→回来 | 结果保留，**选择/展开/写回报告/C1 收尾全部清空** | 无任何提示（P1-1） |

### 重复（`Duplicates`）

| 阶段 | 用户可做的事 | 不可用时的提示 |
|---|---|---|
| 未扫描 | 预设/高级阈值；`开始扫描` | 空态"尚未扫描"+ 指向上方按钮（不重复主按钮，`G/Duplicates/DuplicatesView+Sections.swift:158-164`） |
| 扫描中 | 看阶段 + n/N；`取消`；离开页面 | 预设/阈值/扫描全部禁用（按钮变"扫描中…"，无理由文案）；可重复点取消（P2-12） |
| 有结果 | 切 Tab、展开/收起、保留最佳/全部、逐张保留/丢弃、恢复未处理、查看照片、加载更多 | 阈值变→"当前匹配强度为 N，上面的结果来自 M；请重新扫描"（`G/Duplicates/DuplicatesView.swift:90-97`） |
| 失败 | `重试`（仅 `scanResult == nil`） | 顶部红条 + 空态重试；有旧结果时只有红条 |
| 离开→回来 | 展开/分页保留（`load` 只换 groups） | 进度不重同步（P2-10） |

### 人脸（`FaceKeywording`）

| 阶段 | 用户可做的事 | 不可用时的提示 |
|---|---|---|
| 分析 idle | 预设/高级参数、`开始分析`、模型缺失→`前往设置` | 步骤条前进被拦：可见文案"请先完成人脸分析，再进入后续步骤。"（`G/FaceKeywording/FaceKeywordingView+Steps.swift:106-118`） |
| running | 看进度/阶段、`取消` | 参数/预设禁用；`取消` 无"正在取消"，可重复点 |
| done | 自动落到审核；回分析可`仅重新聚类`（先确认影响面） | `仅重新聚类` 恒为分析页唯一主按钮 |
| failed / cancelled | `开始分析` 重试 | 徽标 + 红条；原文只在 `.help` |
| 审核 | 选簇、按角色筛选、勾选成员、拆分、绑定/更新绑定、解绑、合并、移除成员 | 已绑定簇不渲染合并面板；`拆分` 禁用理由只在 `.help`（P2-14）；已绑定簇无"查看成员"以外的提示 |
| 写回 | 生成预览、确认写回、重试失败项、C1 重新加载、确认同步、清理备份 | 未完成分析→可见文案"请先完成人脸分析…"（`G/FaceKeywording/FaceWritebackStep.swift:40-45`）；清理需 `isSyncConfirmed`；写回前也能点确认同步（P2-13） |

### 人物（`Persons`）

| 阶段 | 用户可做的事 | 不可用时的提示 |
|---|---|---|
| loading | — | 左栏 `ProgressView`，右栏 `Color.clear`（**详情直接消失**，草稿随之丢失） |
| failed | `重试` | `ContentUnavailableView` + 重试 |
| 空库 | `新建人物`（工具栏 ⌘⇧N + 空态 CTA） | 右栏第二空态；两处文案不同但都指向"新建" |
| 有列表 | 搜索、选人、改名称/备注、保存、合并、移除照片、删除 | `保存` 仅空名禁用（无理由，语义明显）；`⌘`取消选择无效（P2-16） |
| 新建 sheet | 输入、回车=创建、失败时 sheet 不关并显示错误 | 空名禁用"创建"；Esc/取消关闭 |

---

## 亮点

1. **写回安全链是完整的**：预览令牌（`expectedPreviewToken`）+ `Confirmed(source: .userDialog)` + 服务端 `SIM_PREVIEW_STALE/FKW_PREVIEW_STALE` 复核（`G/Similarity/SimilarityViewModel+Writeback.swift:96-138`、`G/FaceKeywording/FaceKeywordingViewModel+Writeback.swift:60-90`），`Confirmed` 只在确认分支构造。
2. **重复页的局部 patch 与服务端口径对齐**：`recommendation` 与服务端同公式且 mtime 非法时为 NaN 永不中选（`G/Duplicates/DuplicatesViewModel.swift:430-475`），成员改动后组徽标同源重算（`:360-371`）——避免了"成员改回保留、徽标仍显示保留最佳"。
3. **人脸页对"部分失败"不粉饰**：`encodingFailures > 0` 时不出"分析完成"而是常驻 warning 横幅（`G/FaceKeywording/FaceKeywordingViewModel+Analysis.swift:11-23`）；`select()` 只在真正换簇时重置编辑字段，不冲掉未提交草稿（`G/FaceKeywording/FaceKeywordingViewModel.swift:262-276`）。
4. **分析状态可跨页签恢复**：相似度/人脸都从 `jobs.list` 恢复进行中的任务并续接进度（`G/Similarity/SimilarityViewModel+Load.swift:38-49`、`G/FaceKeywording/FaceKeywordingViewModel+Analysis.swift:339-355`），且分析代次守卫能防旧结果覆盖新结果。
5. **确认宿主连坐问题已被识别**：弹窗按钮全部 `.disabled(false)` 防"页面隐藏时 isActive 连接"（`G/DesignSystem/Components/GatherCommonViews.swift:210-219`、`G/Persons/PersonsView.swift:560/567`），重复页把两个弹窗拆到不同节点。
6. **状态文案全部延迟本地化**（`LocalizedText` + 渲染期 `l10n.resolve`），切语言不会残留旧语言片段；`Notice` 连"取消动作名"都存 key+参数（`G/Similarity/SimilarityViewModel.swift:93-122`）。

---

## 未验证与风险

1. **多个 `.confirmationDialog` 挂同一节点的真实行为**未实机：若 macOS 26 只保留最后一个 presentation，人脸页写回/清理确认会完全无反应（P0 级），人物页合并/移除同理。这是本轮最该先验证的一条。
2. **相似度预计算档的取数口径**：我读的是 `predecessor` 代码（`SimilarityService+Hashes.swift:164-184` 用分析时的 minGroupSize/groupingMode 建档并 `replaceForThreshold`），若运行时有额外的档位失效/重建逻辑（例如每次 `result(threshold:)` 都现算），P1-2 的触发条件会变窄；需以实际 DB 行为确认。
3. **取消是否真能取消**：相似度/人脸的 `cancelAnalysis(sessionId)` 与重复的 `jobs.cancel(jobId)` 是两套语义；`JobService.waitForResult` 在 cancelled 时抛 `JobCancelledError`（`desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Settle.swift:25-28`），人脸靠字符串 `contains("cancelled")` 判定（`FaceKeywordingViewModel+Analysis.swift:60`）——若 `GatherError` 映射丢了码，会把"取消"显示成"失败 + 发生未知错误"。需实机点一次取消并看横幅。
4. **最小窗口 860×560 的布局结论全部是估算**（人脸详情栏头部约需 300pt vs 240pt 下限、相似度统计条），未截图；`HSplitView` 的压缩优先级可能与我假设不同。
5. **`DuplicateGroup.members` 是否可能为空/被截断**未确认：若后端有成员上限，P2-9 的越界和"推荐"判定都会受影响；同理 `group.count`（照片数）与 `members.count` 是否一致未知，`选择分组 %lld 张` 的计数单位没有断言。
6. **人物合并/移除的服务端是否幂等**未验证：`PersonDetailView` 的弹窗 action 里先 `pendingX = nil` 再取 target（`G/Persons/PersonsView.swift:493-498`），若某系统版本先执行 dismiss 再执行 action，`guard let` 会失败→"点了没反应"。属结构性风险，非已证实缺陷。
7. 未读测试与 `GatherSessionPage` 之外的 RootView 生命周期细节，未对 UI 测试覆盖度下结论。
