# E · 输入输出与编排：导出 / 元数据 / 摄取 / 控制中心

- 日期：2026-10-30
- 范围：Export/（18 文件 2329 行）、Metadata/（7 文件 1229 行）、Culling/IngestSheet.swift（309 行）、ControlCenter/（14 文件 1420 行），合计约 5.3k 行，逐文件读完
- 方法：只读静态审计（read/grep/wc），未编译、未跑测试、未实机；布局数字由 token 推算（GatherMetrics.Layout.pageGutter=24、gatherCard padding=16、Space.l=16）
- 基线：docs/reviews/functional-usability-remediation-2026-10-30.md（已随 main `76db8e41` 删除，见 git 历史）的残余 P2（inline apply 无 preview 阶段）在当前代码里**仍然如此**，本报告只补它造成的 UI 后果，不重复记账

## 结论

1. **四个模块都有「任务能启动、能看见，但停不下来 / 败了没法只重试失败项」的断点**：导出没有按项重试（重跑会给重名文件改名，产生副本），交付失败/取消后部分成片的结果被丢弃（deliverySummary=nil），控制中心对 running 任务没有任何取消入口，摄取只把第一条失败摊平成一句红字且完全忽略 DTO 里新增的 retryable。这不是「缺一个按钮」，而是三条长任务链路的收尾段没设计。
2. **校验时序统一到「提交时」，而且错误落点与字段脱节**：导出/摄取/元数据的字段级校验都只在「预览 / 开始导出 / 开始摄取 / 应用」那一刻跑；ExportFieldError 只有 4 个槽（目录/质量/最长边/水印），命名模式这类必填项根本没有行内槽位，错误只能落到页顶横幅或「导出范围」段里。用户改对了字段，红字也不会消失（只有选目录 / 拖放才清），因为错误状态与输入没有绑定。
3. **同屏数字自相矛盾**：导出范围区写「本次将导出 N 个文件」（totalFiles 其实是**照片数**），预览区写「N 张照片 + N 个 XMP，共 2N 个文件」，确认弹窗写「写入 2N 个文件」。复制 XMP 默认开启，所以只要用户做过一次写回，首屏就会出现 12 / 24 两个不同的承诺 —— D09 修的是确认弹窗，没修屏幕上另外两处标签。
4. **控制中心把「加载态」当成「刷新态」用**：load() 每次进来就 isLoading = true，而页面在 isLoading 时把整叠卡片换成居中转圈。索引进度活跃期 3s 一轮、加事件触发，等于每隔几秒整页闪白一次；这页恰恰是「盯着看长任务」的页面。
5. **错误呈现两套皮**：导出页与控制中心用 NativeBanner（图标 + 语义色底 + 主题色），元数据 4 个 sheet 与摄取全用 .font(.caption) + .foregroundStyle(.red/.orange) 字面量（仅靠颜色、无图标、贴在 sheet 底部远离出错字段）。同一类「写入失败」在两处长得完全不像，高对比度/深色下也没有走 GatherTheme.errorText。

## 发现

### P1

**P1-1 · 控制中心每轮轮询把整页替换成「加载中…」**

- 位置：ControlCenter/SessionControlViewModel.swift:160-167（load() 无条件 isLoading = true）、ControlCenter/SessionControlView.swift:135-141（if viewModel.isLoading { ProgressView("加载中…") }）、SessionControlViewModel.swift:120-135（3s/15s 轮询）
- 现象：load() 的 isLoading 没有区分首载与刷新；body 用同一个标志做**全内容替换**。

~~~swift
public func load() async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true          // ← 每次轮询都置真
~~~

- 用户影响：索引活跃期每 3 秒（外加 jobTerminal / c1SyncStatus / 三个 domain 事件触发）整叠卡片消失、换成转圈，再回填；ScrollView 内容被换掉，滚动位置回到顶部，用户在「待处理事项」里刚滚到的行会被弹回。对「最长任务的可观测页」是致命体验。
- 修复建议：拆 isLoading（仅首载）与 isRefreshing（行内小 spinner / 顶部进度条），刷新期间保留旧快照；或至少 guard workspaceStatus == nil else { 不置 isLoading }。

**P1-2 · 取消导出后同屏出现「已请求取消导出」（绿）+「操作失败：发生未知错误」（红）**

- 位置：Export/ExportViewModel+Execute.swift:79-103（await run { ... execute ... }，无取消分支）、Export/ExportViewModel.swift:408-423（catch 一律写 errorMessage）、ExportViewModel+Execute.swift:105-116（notice =「已请求取消导出」，且没设 noticeKind）、Support/L10n.swift:140,268-270（未知码回退「发生未知错误，请稍后重试」）、Support/GatherLocalization.swift（错误码表里没有 CANCELLED）

~~~swift
public func cancelExport() async {
    _ = try await exportAPI.cancel(sessionId)
    notice = LocalizedText("已请求取消导出")   // noticeKind 仍是默认 .success
~~~

- 用户影响：用户自己按的「取消导出」，结果既有一条绿色成功提示，又有红色「操作失败：发生未知错误」。用户无法判断取消到底生效没有，也不知道「未知错误」是不是自己造成的。同页的交付路径（ExportViewModel+Delivery.swift:341-343）明确把取消当正常终态，两条路径口径相反。
- 修复建议：executeExport 的 catch 里复用 Self.isCancellation(error)，命中则 notice =「导出已取消；已写出的文件保留在导出目录」、noticeKind = .info、errorMessage = nil。

**P1-3 · 导出文件数三个数字互相打架（照片数被标成「文件」）**

- 位置：Export/ExportView+Range.swift:35-37、Export/ExportView+Preview.swift:17、Export/ExportView+Preview.swift:33-41、Export/ExportViewModel+Execute.swift:52（确认用 physicalFileCount）、GatherProtocol/Protocol/Export.swift:186-197（totalFiles 注释即「照片数（历史字段）」）

~~~swift
// 范围区
Text(l10n.format("%lld 个文件", preview.totalFiles))        // 12（其实是照片数）
// 预览区同一屏
LabeledContent(l10n("文件"), value: "\(preview.totalFiles)")  // 12
Text(l10n.format("将写入 %lld 张照片 + %lld 个 XMP 附属文件，共 %lld 个文件。",
                 preview.photoCount, preview.sidecarCount, preview.physicalFileCount))  // 24
~~~

- 用户影响：includeXmp 默认 true，只要照片已有 sidecar（做过一次挑片写回就有），首屏就同时出现「12 个文件」和「共 24 个文件」，点确认又变成「将写入 24 个文件」。用户会怀疑导出会写两遍或漏写；也会低估磁盘占用。
- 修复建议：范围摘要与预览区首行都换成 physicalFileCount 并改标签为「个文件（含 XMP）」，或改成「12 张照片 / 24 个文件」双值；给 ExportPreview.totalFiles 加 deprecated 注释避免再被当文件数用。

**P1-4 · 控制中心能看任务、不能停任务**

- 位置：ControlCenter/SessionControlJobRow.swift:14-48（仅 failed/interrupted/cancelled 出「重试」）、ControlCenter/SessionControlView+Jobs.swift:21-27（activeJobs 行同样只有进度，无动作）、全仓 jobAPI.cancel 只出现在 IngestSheet.swift:215、DuplicatesViewModel.swift:268、CullingViewModel.swift:635
- 现象：运行中（queued/running/cancelling）的行没有「停止 / 取消」，而工具箱（SessionControlView+Toolbox.swift:18-25）又能反复建 metadata.scan / quality.score。
- 用户影响：根目录选错、一次 2 万张的扫描误触后，用户在这页只能等；文档里承诺的「进度/取消」只兑现了进度（Toolbox.swift:14 的文案甚至写了「失败的任务可重试」，刻意回避了取消）。
- 修复建议：SessionControlJobRow 对 queued/running/cancelling 增加「停止」（jobAPI.cancel(job.id) + confirmationDialog），并在 running 时把行内进度换成「取消中…」。

**P1-5 · 元数据模板的 2000 张上限完全不可见，超限只报「参数无效，请检查输入。」**

- 位置：Metadata/MetadataTemplateSheet.swift:36-42,85-88（目标集合 = selectedPhotoIds，可到 2 万）、Metadata/MetadataTemplateSheet.swift:261-274（MetadataTemplatePreviewInput 直接构造）、GatherProtocol/API/Inputs/MetadataTemplateInputs.swift:52-58,80-95（maxPhotoIds = 2_000）、GatherProtocol/API/Core/Validation.swift:44-49（抛 INVALID_PARAM + reason "count must be at most 2000"）、Support/GatherLocalization.swift:77（模板「参数无效，请检查输入。」无占位符 → reason 丢失）
- 用户影响：模板 sheet 只写「目标：20000 张照片」，用户按「预览」得到一句「参数无效，请检查输入。」，既不知道是数量超限也不知道上限是多少；改啥都没用，只能猜。
- 修复建议：targetPhotoIds.count > 2000 时在「目标」行直接红字说明并禁用「预览/应用」；同时给 INVALID_PARAM 模板加 {{field}}/{{reason}} 或用错误码专用的 METADATA_TOO_MANY_PHOTOS。

**P1-6 · 摄取的目标目录/第二目的地校验只在提交后发生，且失败文案不含字段**

- 位置：Culling/IngestSheet.swift:59-65（目标可自由输入/任选目录）、:76-82（第二目的地同理）、GatherHost/SessionIngestRunner.swift:59-82（目标必须在会话 sourcePath 内、第二目的地不得重叠且必须在根本之外）
- 现象：UI 允许选任意目录；服务端用 GatherError.invalidParameter(field: "destinationRoot", reason: "must be inside the session source path") 拒绝，而 INVALID_PARAM 的文案没有字段占位符。
- 用户影响：选一个桌面目录 → 点「开始摄取」→ 底部红字「参数无效，请检查输入。」，用户不知道是目录位置问题；这正是 IngestSheet.swift:26 注释里想避免的「引导用户手选一个必败的目标目录」，但只修了「无根」这一种。
- 修复建议：选目录后立刻比对 session.sourcePath 前缀，不满足就地红字（「目标必须在工作区根目录 <path> 内」）；第二目的地同样校验重叠与绝对路径，并在行下给出当前根目录路径。

**P1-7 · 导出/交付失败后没有「只重试失败项」，重跑靠改名产生副本**

- 位置：Export/ExportView+Result.swift:14-56（只有「生成 CSV/Markdown 报告」「在 Finder 中显示」）、Export/ExportView.swift:148-153（确认文案「重名文件会自动改名，不会覆盖已有文件」）、ExportViewModel+Execute.swift:71-103（整批重跑）
- 用户影响：200 张里 5 张因源文件离线失败，用户看到「成功 195，失败 5」+ 前 3 条错误，唯一的动作是再点一次「开始导出」——于是 195 张以 -1 后缀重写一遍，目录里出现两套几乎相同的文件，磁盘翻倍，交付目录变脏。确认弹窗还提前告诉用户「不会覆盖」，更让人放心地按下去。
- 修复建议：结果区加「仅重试失败项」（把 result 里的失败 photoId 存下来，作为一次性 scope），或至少在执行前检测「目标已存在同名且内容一致 → 跳过」并显示「将跳过 195 个已完成文件」。

**P1-8 · 元数据/模板/历史/摄取四个入口被埋在 ~50 行只读字段之下**

- 位置：Culling/CullingInspector.swift:36-37（整块单 ScrollView）、:137-143（MetadataSections 先渲染）、:184-209（「编辑元数据…」「套用模板…」「历史与撤销…」「摄取照片…」全部在其后）、Metadata/MetadataSections.swift:20-52,55-64（22 + 10 个 IPTC 行 + 12 个 EXIF 行 + 4 个文件行，未填写也出行）、DesignSystem/Patterns/GatherInspectorSection.swift:31-52（无折叠）
- 用户影响：检查器 220–400pt 宽，MetadataSections 恒定输出约 48 行（多为「尚未填写」），四个动作入口被推到 3 屏之后。用户「找不到编辑元数据」不是没入口，是入口在墙后面；GatherInspectorSection 本身支持 subtitle，却没有任何折叠能力。
- 修复建议：把「编辑元数据…」提到 MetadataSections 之上（或标题行右侧放一个铅笔按钮）；IPTC 两组默认折叠为「已填 3 / 32」摘要，点开再全列。

### P2

**P2-1 · 每次键入后 300ms，预览段与张数摘要整块消失再出现** — Export/ExportViewModel+Plan.swift:48-53（进入即 preview = nil）、Export/ExportView+Preview.swift:15、Export/ExportView+Range.swift:34、Export/ExportView.swift:128-136（planSignature 含 namingPattern、watermarkText，键入即触发）。用户在「命名模式」里连打 6 个字符，预览段消失 →「正在计算本次导出的文件数…」→ 再出现，清单跳动 6 次。建议：refreshPlan 不清 preview，改为保留旧计划 + 标题挂「计算中」徽标。

**P2-2 · 错误位置不贴近字段：命名模式与派生错误全落在「导出范围」段** — Export/ExportViewModel.swift:81-86（ExportFieldError 只有 destination/quality/maxDimension/watermark）、Export/ExportView+Range.swift:53-57（planError 渲染在范围段）、ExportViewModel+Plan.swift:67-70。清空命名模式 → 范围区出现「无法计算导出计划：文件命名规则不能为空」，而输入框在下方两屏、旁边没有任何标记。建议：ExportFieldError 增加 .naming 并在命名行下挂 ExportFieldErrorText。

**P2-3 · 行内错误不会随输入清除（改对了还挂着红字）** — Export/ExportViewModel.swift:327-341（只有 chooseDestination / setDestinationPath 清 errorMessage+fieldError）、Export/ExportView+Options.swift:126-143（destination 是裸 Binding）。手输相对路径失败后改对，红字仍在，且页顶横幅被 fieldError != nil 抑制（ExportView.swift:59），没有第二条线索。建议：onChange(of: destination) 清错，横幅按字段匹配抑制。

**P2-4 · 空间不足只提示不阻断；0 个文件也能确认** — Export/ExportView+Preview.swift:23-30（仅 NativeBanner）、Export/ExportViewModel+Execute.swift:13-57（只看签名一致）、Export/ExportView.swift:148-153（照常承诺「将写入 0 个文件」）；对照 DeliveryConfirmSheet.swift:19-22,91-92（交付空间不足/全配方失败会禁用开始）。同一页两套标准。建议：spaceInsufficient 时不返回确认载荷；physicalFileCount == 0 时弹窗改为不可确认的空态说明。

**P2-5 · 任何参数变化都静默清空上一次的导出结果** — Export/ExportViewModel+Plan.swift:66（result = nil）、ExportViewModel+Preview.swift:33、Export/ExportView+Result.swift:15。一次部分失败后为了排查去改格式/范围，「结果」连同失败清单、报告按钮、Finder 入口一起消失且无提示。建议：result 记录生成时的 planSignature，仅在用户主动重跑时清空，或清空时给 notice。

**P2-6 · 导出进行中表单仍可编辑，页面计划与实际输出不再是同一份** — Export/ExportView.swift:88-101（Form 无 .disabled(isExporting)，只有按钮禁用 :179,190）、ExportViewModel+Execute.swift:17-24（确认时冻结快照）。导出中改目录 → 去抖后按新目录算出一份新计划，页面显示「→ 新目录」，文件却写向旧目录。建议：isExporting || isDelivering 时禁用参数区，并在进度段显示冻结的目录。

**P2-7 · notice 不会消失、没有关闭按钮，noticeKind 还会粘滞** — Export/ExportView.swift:67-76（NativeBanner 未传 onDismiss）、DesignSystem/Components/NativeBanner.swift:69,105-114（有 onDismiss 能力但没被用）、ExportViewModel.swift:51（默认 .success）、Execute.swift:91-99（失败汇总不设 kind）、Delivery.swift:342-343（设 .info）。先取消一次交付（kind=.info），再跑一次部分失败的导出 → 「导出完成：成功 N 张，失败 M 张」以灰色 info 呈现。建议：每次写 notice 显式带 kind，信息类可关闭或超时。

**P2-8 · 交付失败/取消后，已写出的成片在界面上「消失」** — ExportViewModel+Delivery.swift:329-348（先 deliverySummary = nil，catch 只写 notice/error）、Export/ExportView+Delivery.swift:113-135（结果与 WebDAV 入口都在 if let summary 内），而 :342 的文案本身承诺「已写出的成片仍在交付目录中」。建议：保留 partial summary，失败态也渲染路径行 + Finder 入口。

**P2-9 · 「配方」只能改名字和格式，其余参数既不可见也不可改** — Export/ExportView+Delivery.swift:146-191（行内只有 name + format，其余是只读「长边 2048」「含联系表」）、ExportViewModel+Delivery.swift:82-94（新增配方硬编码 quality 85 / maxDimension 2048）、:101-109。用户要「JPEG 长边 1600、质量 90」只能得到 2048/85；配方名可清空、可重名（只有 addDeliveryRecipe 保证默认名唯一）。建议：配方行展开 mini 表单，或明确降级文案「配方＝格式预设」，名称做非空 + 唯一校验。

**P2-10 · 「交付目录」留空会静默回落到导出目录** — Export/ExportViewModel+Delivery.swift:26-29（effectiveDeliveryRoot 空则用 destination）、Export/ExportView+Delivery.swift:22-32（只有 placeholder「交付目录」）。用户以为留空＝未设置，实际会写进当前导出目录，两套产物混在一个文件夹；只有确认 sheet 才露出真实落点。建议：placeholder 改「留空＝使用导出目录」或行下显示解析后的实际路径。

**P2-11 · 交付进度条只会被「终态事件帧」清掉，离开页面再回来残留冻结进度** — Export/ExportViewModel.swift:255-272（deliveryProgress = nil 只在 event.isTerminal 分支）、Export/ExportView.swift:137-140（事件消费在 View 的 onReceive，页面销毁即无消费者）、Delivery.swift:329-348（executeDelivery 的 defer 不清 deliveryProgress）。跑到一半切页签再回来：结果卡在、进度条停在 37/120。建议：executeDelivery 的 defer 清 deliveryProgress/deliveryPhase（与 executeExport:101-102 对齐），渲染加 isDelivering 守卫。

**P2-12 · WebDAV 发布：入口受限、口令语义不可见、「停止发布」点了没反应** — Export/ExportView+Delivery.swift:113-134（.sheet 只在 if let summary 内 → 必须先在本页成功跑完一次交付）、WebDAVPublishSheet.swift:41-44（SecureField("密码") 无提示）、ExportViewModel+Delivery.swift:185-189（空密码＝沿用 Keychain，代码注释写了 UI 没写）、WebDAVPublishSheet.swift:72-74（停止发布只 publishTask?.cancel()，不改任何状态）。建议：入口提到交付区顶部并允许对任意目录发布；密码行注明「留空沿用已保存凭据」；停止进入 cancelling 态；进度改 ProgressView(value:)。

**P2-13 · 元数据编辑器把长文本塞进单行 TextField，32 个字段平铺无分区** — Metadata/MetadataEditorSheet.swift:46-56（单 ScrollView + maxHeight 460）、:101-120（section() 一律 TextField().textFieldStyle(.roundedBorder)）、:112、Metadata/MetadataDisplayRows.swift:152-187（32 个标题）。说明/标题是典型多行字段，单行输入框只能横向滚动看一两个词，粘贴一段文案后无法复核。建议：长文本换 TextEditor（3–5 行）或 lineLimit(1...3)，两组 IPTC 可折叠，顶部加「仅显示已填写」过滤。

**P2-14 · 编辑器 Esc 无反应；页面被销毁时草稿静默丢失** — Metadata/MetadataEditorSheet.swift:77-79（只有「取消」按钮触发放弃确认）、:88（interactiveDismissDisabled(changedFieldCount > 0)）、:89-98。改了 3 个字段按 Esc：什么都不发生（拦了 dismiss 却没接到放弃确认），用户以为键盘失效；反之若宿主页被切换导致 sheet 被动消失，保护不生效、草稿无提示丢失。建议：把 Esc（.cancelAction）接到同一个 showDiscardConfirm。

**P2-15 · 模板 sheet：预览过期后按钮仍可点、重复失败；「应用到选中照片」在单张时名不副实** — Metadata/MetadataTemplateSheet.swift:276-301（catch 只写 errorText，不清 preview）、:124-125（仅以 preview != nil 门控）、:36-42（目标回落到 currentAsset）。命中 METADATA_PREVIEW_STALE 后按钮依旧亮着，再点还是同一个错；单张场景按钮写「选中照片」但只写当前照片。建议：预览类错误命中即清 preview 并自动重跑，按钮标题按目标集动态。

**P2-16 · 摄取：重命名模板无校验无示例，失败只报第一条，retryable 被完全忽略** — Culling/IngestSheet.swift:67-74（没有 namingPreview 式示例）、:106-127（只渲染 result.failed.first）、:120-126（CommandError(apiText: code, diagnostic: message)）、SessionIngestInputs.swift:55-71 + MetadataTemplateInputs.swift:206-221（DTO 有 code/retryable）。模板漏 {ext} 跑完才发现；失败 200 张只看到 1 条、不知道能否重试。建议：模板行下加实时示例 + 非法占位符红字；失败区可展开、按 retryable 给「重试这些文件」；0 张补一句「未找到可摄取的受支持文件」。

**P2-17 · 待处理事项的 7 类里，第一类永远不会显示** — ControlCenter/SessionControlView+Inbox.swift:20-25（.filter { $0.kind != .scanIncomplete }）、:71-77（scanIncomplete 是推导出来的最高优先级项）、SessionControlView+Recommendation.swift:19-24（去重时同样过滤）。deriveInboxItems 的注释与测试覆盖 7 类，界面恒定 6 类；truncatedImport && stage == .imported（张数是「≥」）这一状态在待办里彻底不可见，只有上方索引行显示「已索引 ≥N 张照片」，没有动作。建议：删掉这个 kind 并同步测试，或并入索引行解释「为何是 ≥」并给重新统计动作。

**P2-18 · 同一个失败任务在待办与当前任务里各有一行「重试」，且来源不同** — SessionControlView+Inbox.swift:118-139（来源 status.failedJobs.prefix(3)）、SessionControlView+Jobs.swift:24-27（来源 attentionJobs = jobs 里 failed+interrupted，也 prefix(3)）、SessionControlJobRow.swift:40-45（又一个重试）。失败 5 个时两处各截 3 条但集合可能不同；interrupted 只在下面出现、failed 上下都有。建议：待办里的 jobFailed 改为「去当前任务看」，重试收敛到任务行一处。

**P2-19 · 轮询开销：摄取 sheet 每 500ms 拉全量任务列表，控制中心 3s 三次 IPC + 全量任务** — Culling/IngestSheet.swift:237-251、ControlCenter/SessionControlViewModel.swift:160-193。摄取 5000 张 = 每秒两次全表任务查询；控制中心索引进度活跃期每 3s 一轮四次 IPC，与 P1-1 的闪白叠加。建议：摄取进度改 jobProgress 事件 + 1s 兜底；控制中心刷新复用 session/syncStatus，只刷 status。

**P2-20 · 错误呈现两套皮肤（banner vs 纯色 caption）** — Metadata/MetadataEditorSheet.swift:66,69、MetadataBatchSheet.swift:60、MetadataTemplateSheet.swift:118、MetadataTemplateFieldsSheet.swift:88（.font(.caption).foregroundStyle(.red)）、Culling/IngestSheet.swift:41,104,113,118,125（.red/.orange 字面量）；对照 Export/ExportView.swift:59-66、ControlCenter/SessionControlView.swift:119-131（NativeBanner + GatherTheme.error）。同类失败在导出页是带图标横幅，在元数据面板是 11pt 红字贴按钮上方、离出错字段两屏；绕过 GatherTheme，深色/高对比度不一致，且只靠颜色（无图标、无 accessibilityLabel）。建议：sheet 内统一 SheetErrorBanner，颜色改主题色并补无障碍标签。

**P2-21 · 阶段条没有「进行中」，current 分支除 created 外不可达** — ControlCenter/SessionControlView+Stages.swift:44-52（reached 与 current 可同时为真）、:98-114（stageDot 先判 reached → 当前阶段也画绿勾）、:116-120（无障碍值同样先报「已完成」）。stage == .indexed 时看到「已导入 ✓ 已索引 ✓ 已分析 ○」，没有任何「分析中」。建议：stageDot 先判 current，或把 reached 收窄为「严格早于当前阶段」。

**P2-22 · 设计系统禁止项：导出页 17 处直接写 .font(.callout)** — Export/ExportView+Progress.swift:27、+Preview.swift:40,47,69,73、+Range.swift:41,46,51,55、+FieldError.swift:15、+Options.swift:45,76,119,142、+Result.swift:18,24,51；规则见 docs/design/appearance-interaction.md:147。不直接可见，但这是同层级文字在导出页与其他页大小不一致的来源；check-design-system.py 的 font.callout 基线把它计入存量，新代码会照抄。建议：替换为 GatherFont.secondary/labelRegular 并下调基线。

**P2-23 · 打印联系表的入口只在「交付成功后的配方行」里** — Export/ExportView+Delivery.swift:268-275（if let sheet = recipe.contactSheetPath 才出现）、Export/PrintSupport.swift:12-33（唯一消费者）。想要打印必须：打开导出页 → 配好交付 → 成功跑完一次整套交付 → 才能点；已存在的联系表 PDF 无法从图库/导出页直接打印。失败时 NSSound.beep() 与页面横幅双重反馈。建议：结果行常驻「打印联系表…」，或提供「打印上次联系表」。

**P2-24 · 三个 sheet 的关闭按钮用词不一致（取消 / 关闭），且与「取消任务」同词** — Culling/IngestSheet.swift:131（取消）、:95（取消摄取）、Metadata/MetadataTemplateSheet.swift:143（关闭）、MetadataBatchSheet.swift:65（关闭）、MetadataEditorSheet.swift:77（取消 → 放弃确认）。摄取面板里「取消」与「取消摄取」含义相反；编辑器「取消」是放弃改动，模板面板同样动作叫「关闭」。建议：关闭一律「关闭」，破坏性放弃用「放弃改动」，中止任务用「停止摄取」。

### 表单校验时序问题清单

| # | 字段/表单 | 何时校验 | 错误落在哪 | 问题 |
|---|---|---|---|---|
| 1 | 导出 · 导出目录（必填） | 提交时（exportOptions），去抖计划也触发 | 行内 ExportFieldErrorText + 抑制页顶横幅 | 输入修正后不清除（P2-3）；只有选目录/拖放才清 |
| 2 | 导出 · 命名模式 | 提交时 / 服务端 preview | **无行内槽位** → 页顶横幅，或 planError 落进「导出范围」段 | 位置错（P2-2）；空值/非法字符无即时反馈 |
| 3 | 导出 · 最长边 | 失焦/回车归一（commitMaxDimension），校验在提交时 | 行内（maxDimension） | 非数字前缀保持原值不改，用户看到自己的 abc 毫不知情，直到提交 |
| 4 | 导出 · 水印字号 | 失焦/回车归一（commitWatermarkFontSize） | 行内（watermark） | 非数字**静默改成 24**，无任何提示（数据被悄悄改写） |
| 5 | 导出 · JPEG 质量 | 滑块只有 1…100，无文本输入 | 行内（quality） | EXPORT_JPEG_QUALITY_INVALID 路径不可达（死校验），却仍占一个字段枚举 |
| 6 | 导出 · 空间/文件数 | 计划返回时（只警告） | 预览段横幅 | 不阻断确认（P2-4） |
| 7 | 摄取 · 重命名模板 | 仅 nonBlank + ≤256（输入 DTO），其余全在服务端 | sheet 底部一行红字 | 无示例、无占位符校验、失败在跑完之后 |
| 8 | 摄取 · 目标/第二目的地 | 全在服务端（SessionIngestRunner） | 底部一行「参数无效，请检查输入。」 | 字段名与原因被 INVALID_PARAM 模板吞掉（P1-6） |
| 9 | WebDAV · 服务器地址 | 实时（isURLValid，仅前缀） | 字段下方红字 | ✅ 本范围内唯一「输入即校验」的正面样本；用户名/密码/远端目录无任何校验 |
| 10 | 元数据 · 32 字段 | 提交时（服务端） | sheet 底部一行红字 | 无逐字段错误定位；日期/URL/邮箱无本地格式校验 |
| 11 | 元数据模板 · 目标集 | 提交时（maxPhotoIds 2000） | 底部红字「参数无效」 | 上限不可见（P1-5）；超限后无任何可操作建议 |
| 12 | 整套交付 · 目录/配方 | 点击时（prepareDeliveryInput） | **页顶横幅**，不在交付区内 | 用户点了交付区的按钮，红字出现在页面最上方（表单已滚动两屏） |

### 任务生命周期断点清单

**单张导出**
1. 提交：确认弹窗冻结参数 ✅；但 0 文件 / 空间不足不阻断（P2-4）。
2. 进度：事件只在页面存活时消费（ExportView.swift:137），离开页面即停更，回来靠下一帧续上（可接受）；进度条 + 百分比 + 文件名 ✅。
3. 取消：唯一入口在工具栏，离开页面即消失；取消后红绿并存的错误反馈（P1-2）。
4. 失败：只列前 3 条 + 展开 ✅；**没有按项重试**，重跑靠改名（P1-7）。
5. 结果去留：改任何参数即静默清空（P2-5）；进行中仍可改参数（P2-6）。

**整套交付**
1. 提交：预检（逐配方 export.preview，串行、无进度、不可取消）+ 确认 sheet 拦空间/全失败 ✅。
2. 进度：deliveryProgress + 相位文案 ✅；离开页面回来可能残留冻结进度（P2-11）。
3. 取消：cancelDelivery → exportAPI.cancel(sessionId)；取消后 deliverySummary=nil，部分产物无出口（P2-8）。
4. 失败：同上，且 notice 承诺「成片仍在目录中」却不给路径/入口。
5. 重试：只能整批重跑，无按配方重试。
6. 发布：仅成功后可发布（P2-12），停止发布无反馈。

**摄取**
1. 提交：无确认、无张数/体积预估（对比导出与交付都有确认）。
2. 进度：500ms 轮询任务表；小批量可能全程看不到进度（job 还没入表就跑完）；取消依赖「能否 list 到活跃 job」，找不到时报「没有进行中的摄取任务」（与真实状态可能相反）。
3. 取消：JobCancellationMarker 分支给文案 ✅；取消前已登记的保留 ✅。
4. 失败：只显示第一条 + 忽略 retryable + 无「重试这些」入口（P2-16）。
5. 结束：结果无「在 Finder 中显示」，0 张无下一步。

**控制中心任务**
1. 观察：索引行 / 阶段条 / 当前任务 / 待办 四处各说一部分（P2-17、P2-18），且每轮刷新整页闪白（P1-1）。
2. 取消：**不存在**（P1-4）。
3. 重试：终结态可重试（failed/interrupted/cancelled）；批量重试 retryFailedJobs 只重试 status.failedJobs，与任务表可能不一致。
4. 失败可见性：失败任务最多 3 行（两处各自截断），第 4 个以后只能进「已完成任务」折叠区，而 historyJobs 只含 succeeded/cancelled（SessionControlViewModel.swift:219-221）→ **第 4 个失败任务在控制中心无处可见**。

## 亮点

1. **确认载荷与执行参数同源**：ExportConfirmation 冻结整份 ExportOptions + planSignature，执行前签名变化就丢弃并提示（ExportViewModel+Execute.swift:13-57、ExportConfirmation.swift:15-26）。把「用户确认的那份」与「真正执行的那份」绑死的正确做法。
2. **计划请求带代次 + 去抖 + pending 占位**：planGeneration 丢弃过期响应（ExportViewModel+Plan.swift:55-65），去抖窗口内仍有「正在计算…」文案（ExportView+Range.swift:48-52），没有让摘要行整行消失。
3. **字段级错误 + 横幅抑制**避免同源重复提示（ExportView.swift:57-66），ExportFieldErrorText 只在对应字段命中时渲染。
4. **预览描述的是输出而不是源**：outputName / +XMP / ≈ 估算标记 / issue 逐项诊断（ExportView+Preview.swift:50-70），并把「空间不足」从彩色正文改成原生提示条（:23-30）。
5. **交付确认不是红字拦截而是真禁用**：canStart 同时看空间与「全部配方失败」（DeliveryConfirmSheet.swift:19-22,91-92），红字只解释原因。
6. **摄取的无根 fail-closed + 运行中禁止关闭**：rootMissing 提供唯一修复入口（IngestSheet.swift:37-46），interactiveDismissDisabled(isRunning)（:140）避免「任务在后台跑但用户以为取消了」；取消走 job 而非局部 Task（:205-235）。
7. **元数据编辑器的三态语义与 fail-closed**：初值必须读盘、读不到就禁用保存（MetadataEditorSheet.swift:32-33,63-67,168-195）；只提交改动字段、空白＝显式清空、clearedContactMembers 单独识别（MetadataEditorDraft.swift:33-70）；「将写入 N 个字段」实时计数让禁用原因可见（:73）。
8. **撤销入口只在真的有快照时出现**（appliedBatchId = result.undoAvailable ? result.batchId : nil，MetadataTemplateSheet.swift:292-294），部分撤销失败保留入口可重试（:310-317）。
9. **控制中心的「同一动作只说一次」**：推荐卡按 InboxAction 枚举与待办去重（SessionControlView+Recommendation.swift:16-25），并为此把推荐动作统一到同一枚举。
10. **索引头「≥」语义 + 百分比钳制 + 无障碍值**：IndexHeaderCopy 把「扫描中/失败/计数」三态与 ≥ 截断语义收成纯函数（SessionControlView+IndexHeader.swift:54-79），阶段条等宽列 + accessibilityValue（+Stages.swift:59-86,116-120）。

## 未验证与风险

1. **全部结论为静态推断**：未 swift build、未起 App、未截图。所有「首屏能放几张卡」「96pt 标签会不会换行」「860×560 下工具栏会不会溢出」都是按 token 推算（pageGutter 24 / gatherCard padding 16 / Space.l 16 / 页签 40），不是实测。
2. **P1-1 的「整页闪白 + 滚动回顶」是结构推断**：ScrollView 内分支从卡片栈切成单个 ProgressView，内容高度骤降；SwiftUI 是否保留 offset 我无法静态证明，**需实机确认**（索引活跃期把光标停在待办列表上观察 10 秒）。
3. **isLoading 是否真的每轮都置真**依赖 pollTask 持续运行；startPolling 有 isVisible 与 pollTask == nil 双重守卫，若页面 onDisappear 未触发（例如被 sheet 覆盖但未销毁）行为可能不同，需实测。
4. **取消导出真的抛 JobCancelledError** 已由 JobService+Settle.swift:25-28 证实；但 ExportService 侧是否存在「取消了却返回部分 result」的路径未验证，若有，P1-2 的表现会变成静默成功而非红字，仍需实测。
5. **.sheet / .confirmationDialog 挂在 Button / Section 内部**（ExportView+Delivery.swift:66、MetadataTemplateSheet.swift:130）：macOS 26 上按钮 label 随状态变化（正在预检…）时是否稳定呈现未验证；这是已知 SwiftUI 脆弱点，建议实机点三次确认。
6. **MetadataEditorSheet 的草稿丢失路径**（P2-14）需要验证「sheet 打开时能否用 ⌘/菜单快捷键切页」：若菜单命令被 sheet 拦截，则丢失路径不成立，只剩「Esc 无反应」。
7. **INVALID_PARAM 文案是否真的丢失 field/reason**：依据 GatherLocalization.swift:77 模板无占位符 + L10n.interpolate 行为推断；若 en.lproj 对该码有带 {{field}} 的译文，英文环境会显示字段名（中英不一致本身也是问题），**需查 en 表确认**。
8. **2000 张上限是否还有更早的服务端拦截**（MetadataTemplateService 自己的批量上限）未查；若上限不同，P1-5 的文案建议需改数字。
9. **控制中心「第 4 个失败任务无处可见」**：historyJobs 只含 succeeded/cancelled（SessionControlViewModel.swift:219-221），attentionJobs 在 UI 上被 prefix(3) 截断；我没找到任何「查看全部失败任务」入口，但也可能由 Dashboard 的 JobRowView 兜住 —— 属跨模块，建议与 A 报告交叉确认。
10. **.font(.callout) 的 17 处是否有意为之**：导出页迁移注释声称「逐字搬移」，可能与设计规则冲突属历史遗留；基线未下降说明门禁接受存量，是否本轮修需产品决策。
11. **英文（en.lproj 1862 键）下的长文案**未验证：LabeledContent 标签、摄取 520pt、模板 560pt 宽度在英文下更易截断；本次所有文案评估都按中文。
