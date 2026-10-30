# F · 显示基建审计：DesignSystem / 缩略图与媒体 / 本地化 / 无障碍 / 设置

- 审计对象：worktree `interaction` 的 `desktop/native/gather-app/Sources/GatherUI`：`DesignSystem/`（16 文件 1609 行）、`Support/PhotoThumbnailView.swift`（782 行）及缩略图管线、`Support/L10n.swift` + 本地化资源、`Settings/`（20 文件 2688 行）
- 方式：只读静态审计（read / grep / python 统计），未运行 swift build / swift test，未在真机测帧率与对比度
- 行号基于当前工作树（2026-10-30）

---

## 结论

1. **设计系统的"覆盖率"是幻觉**：`check-design-system.sh` 只锁 8 个指标，真正决定观感的裸字号是 **193 处 `.font(.`**，其中 104 处（`.caption` 54、`.caption2` 11、`.system(size:)` 15 之外还有 `.title3` 6 …）完全不在 ratchet 视野里。后果是同一条检查器里 EXIF 行 11pt、其它分区 12pt；Settings 页自己也直接写 `.font(.callout)`。
2. **缩略图管线工程完成度很高，但缺最后一环：失效**。`PhotoThumbnailCache` 没有任何 remove / invalidate 入口，内存键不含 mtime（磁盘键含）。对"Capture One 伴侣"这个产品意味着 **在 C1 里改完图回到 Gather，网格里仍是旧图，只有重启才刷新**——这是本模块最像"功能坏了"的显示缺陷。
3. **键盘路径比鼠标路径弱一档**：Gallery 方向键每次移动都 `clearSelection()` 并丢弃多选；游标 id 只写不渲染、也没有 ScrollViewReader 跟随，等于"盲选"。选 30 张后按一下方向键只剩 1 张。
4. **本地化静态与动态覆盖都干净**：en 表 1862 键、动态码表 209 + 7 + 8 + 26 + 86 条全部命中、en value 里 0 处残留中文、plural 的 8 条 `#one` 与 15 个 `plural()` 调用点（去重 8 个 key）一一对齐。真正的问题是**格式化没跟随 app 语言**（日期/字节数仍走系统 locale）与**术语分叉**（工作区 223 处 vs 会话 234 处，同一句里两个词并存）。
5. **无障碍不是"缺 106 处标签"，而是"关键状态没进语义"**：页签与空态有标签，但网格卡片可见的 `放弃 / 保留 / 3★ / RAW+JPEG` 角标一个都没进 `accessibilityValue`；`reduceMotion` 覆盖 18 处主要动效（这点做得好）。

---

## 发现

### P1

#### P1-1 缩略图内存缓存永不失效：C1 改图后 Gather 显示旧图

- 位置：`Support/PhotoThumbnailView.swift:281-283`、`238-244`、`760-782`；对照 `Support/ThumbnailDiskCache.swift:69-74`
- 代码：

`
281:     private var cacheKey: String {
282:         PhotoThumbnailCache.key(path: path, size: size, preview: preview)
283:     }
...
762:     public static func key(path: String, size: Int, preview: Bool) -> String {
763:         "\(preview ? "preview" : "thumb"):\(path)#\(size)"
764:     }
`

  磁盘缓存键带 mtime + size（`ThumbnailDiskCache.swift:73` 的 `Int64(mtime.timeIntervalSince1970 * 1000)`），但视图**先查内存**（`PhotoThumbnailView.swift:238`），内存键只有 path + size。全仓 grep 不到任何 `PhotoThumbnailCache.removeAllObjects` / `remove(for:)`：这个缓存只有 set，没有 delete。
- 现象：源文件被外部替换 / 重写（C1 导出覆盖、重新导入同名文件、像素级改动）后，只要该格子当次运行内被加载过，就永远显示旧位图；磁盘缓存虽然键变了，但根本走不到。
- 用户影响：伴侣工作流的信任崩塌——用户在 C1 调完色回来看挑片页"没变"，会怀疑写回失败或图库没刷新；唯一解法是重启 app（没人会想到）。同理影响"重新导入 / 替换照片"。
- 修复建议：给 `PhotoThumbnailCache` 加 `invalidate(path:)`（按 path 前缀遍历键）与 `removeAll()`；在 `refreshOnDomainEvents([.metadata, .session])` 与写回完成的 job terminal 回调里对受影响路径失效；内存键也带 mtime（或维护 path → mtime 表，命中前比对一次 stat，约 0.2µs）。

#### P1-2 Gallery 方向键清空多选，游标不可见、不滚动

- 位置：`Gallery/GalleryView+Content.swift:325-337`、`Gallery/GalleryGrid.swift:53-59`、`Gallery/GalleryView.swift:78`
- 代码：

`
325:     func moveGalleryCursor(by delta: Int) {
...
332:         let next = min(max(0, start + delta), photos.count - 1)
333:         let id = photos[next].id
334:         keyboardCursorId = id
335:         viewModel.clearSelection()      // ← 多选在此被静默丢弃
336:         viewModel.toggleSelection(id)
`

- 现象：① 已选 30 张 → 按 ↑/↓/←/→ → 只剩 1 张，没有提示也没有撤销（挑片页有自建 undo 栈，图库页没有）；② `keyboardCursorId` 全仓只有 3 处读，都在这个函数家族里，**没有任何视图渲染它**——所谓游标其实就是"单选最后一张"，没有 focus ring；③ Gallery 模块 0 处 `ScrollViewReader`（对比 `Culling/CullingGrid.swift:188` 有），连按 12 次方向键后选中项滚出视口，用户继续按空格就在给看不见的照片打标；④ ↑/↓ 与 ←/→ 完全等价（都是 ±1），justified 网格里"上一行"永远到不了。
- 用户影响：键盘用户会意外丢掉整批选择，然后在"看不见的选中项"上执行批量动作——会被当成 bug 报。空格切换、回车开灯箱都建在同一个不稳的游标上。
- 修复建议：游标与选择分离（方向键只移动 focus ring，不碰 selection），空格切换、⌘A 全选、⇧+方向键扩展区间；`gridView` 包 `ScrollViewReader` 并对行 id `scrollTo(anchor: .center)`；↑/↓ 至少按"上一行 / 下一行的同列索引"跳。

#### P1-3 最小窗口 860×560 下 7 段页签退化成下拉菜单

- 位置：`Interaction/GatherSessionPage.swift:115-123`（阈值 620）、`127-128`（padding 32）、`94-96`（返回按钮 26 + spacing 8）
- 代码：

`
115:             GeometryReader { proxy in
116:                 if proxy.size.width >= 620 {
117:                     tabBar
118:                         .fixedSize()
119:                 } else {
120:                     compactMenu
121:                         .fixedSize()
122:                 }
123:             }
`

- 现象：860 最小窗 − 侧栏 180 = 680 内容宽；减页签行 padding 32 → 648；减返回按钮 26 + 8 → **614 < 620**，最小窗口永远走 `compactMenu`。而中文标签条的固有宽度约 360pt（7 个 2–4 字标签 + 20pt 内边距），英文约 500pt——**阈值比实际需要高 100–250pt**。更外层还有 `fixedSize()`：一旦标签条超过 620，它不会压缩而是溢出 GeometryReader（不裁剪），压到工具栏区域。
- 用户影响：窗口拉到最小（或恢复尺寸为 860 打开）时，7 个页面只剩"当前页 + chevron"的下拉，新用户看不到这个会话里还有相似度 / 控制中心 / 人脸 / 重复 / 挑片 / 导出——可达性直接掉一档；下拉里当前页也没有选中标记（`Button(l10n(page.titleKey))` 无 checkmark）。
- 修复建议：阈值降到实测固有宽度（或用 `ViewThatFits`），最小窗下优先水平滚动而不是折叠；compactMenu 用 `Picker` 语义或给当前项 checkmark。

#### P1-4 「恢复默认」把破坏性动作设成默认键

- 位置：`Settings/ResetImpactSheet.swift:14-22`、`62-71`
- 代码：

`
14:     @State private var resetPreferences = true      // 默认就勾上
...
64:                 Button(role: resetUserContent ? .destructive : nil) {
65:                     onConfirm(resetPreferences, resetUserContent, resetLanguage)
66:                     dismiss()
67:                 } label: { Text(l10n("恢复默认")) }
70:                 .keyboardShortcut(.defaultAction)      // ← Return 直接清空
71:                 .disabled(!canConfirm)
`

- 现象：弹层一出现，"偏好设置"已被勾选、`canConfirm == true`、确认按钮是 `.defaultAction`。按 Return（弹层里"确认"的肌肉记忆，但这里是清空全部偏好）即完成重置；"取消"反而是 `.cancelAction`（Esc）。macOS HIG 要求破坏性面板的默认按钮是安全动作。
- 用户影响：一次误触 = 全部偏好（并发数、写回策略、备份设置）被重置；弹层里只写"偏好设置（N 项）"，没有列出会被重置的键，事后也没有回执。
- 修复建议：`.defaultAction` 给"取消"，确认按钮不加默认键（或二次确认）；默认不勾选任何范围；确认后在设置页顶部给一条可展开的重置清单 notice。

#### P1-5 设置页没有加载态：空值 / 未加载 / 加载失败三者同形

- 位置：`Settings/SettingsView+Fields.swift:47-52`、`78-88`；`Settings/SettingsViewModel+Loading.swift:14-24`；`SettingsView.swift:78-93`
- 代码：

`
47:     private func fieldBinding(_ field: SettingField) -> Binding<String> {
48:         Binding(
49:             get: { viewModel.edits[field.key] ?? viewModel.values[field.key] ?? "" },
50:             set: { viewModel.edits[field.key] = $0 }
51:         )
52:     }
`

- 现象：`values` 初始为空字典，首帧所有 TextField 渲染成空串（无 placeholder、无骨架、无 spinner）；`load()` 失败只把 `errorMessage` 塞进顶部 banner，字段依旧空白且**可编辑**（失焦即保存，`onChange(of: focusedFieldKey)` 就在旁边）。`Settings/*.swift` 全目录 grep 不到 `isLoading` 之类的加载状态。
- 用户影响：慢盘 / 首次启动时看到一屏空设置，会以为"我的配置丢了"；此时点进任一字段再离开，若该键默认值本身为空（如 `face_embedding_model_path`）就真的写空值；数值字段则弹"「X」必须是数字"。加载失败时用户也不知道唯一出口是工具栏的"刷新"。
- 修复建议：加 `isLoading`，加载中用 `redacted(reason: .placeholder)` 或整页 ProgressView 并禁用提交；失败时把"重试"放进 banner（`NativeBanner` 已有 `onDismiss`，可扩一个 action 位）。

### P2

#### P2-1 网格卡片：可见的状态角标没有一条进无障碍

- 位置：`Gallery/GalleryCellView.swift:22-31`、`43-59`；`Gallery/GalleryGrid.swift:168-183`
- 代码：

`
174:     private func cellAccessibilityValue(_ photo: GalleryPhotoData) -> String {
175:         var parts = ["\(photo.width) × \(photo.height)"]
176:         if photo.faceCount > 0 { parts.append("\(l10n("人脸")) \(photo.faceCount)") }
179:         if photo.status == "missing" { parts.append(l10n("离线")) }
182:         return parts.joined(separator: "，")          // 中文逗号，英文界面也是全角
`

- 现象：格子上画了"离线"、"RAW+JPEG · 3"、批注回显（`保留 / 放弃 / 3★`），但 `accessibilityValue` 只有尺寸、人脸数、离线；挑片状态与星级完全读不出。`selectionCheck` 被 `accessibilityHidden(true)`（这没问题，traits 里有 `.isSelected`），但"当前批次已标为放弃"这种**会影响后续写回**的状态对 VoiceOver 不可见。另有硬编码中文逗号，英文界面读作 "1024 × 683，Faces 2"。
- 用户影响：VoiceOver 用户无法在网格里核对刚批量写入的结果（这正是图库页存在的理由之一），只能进检查器逐张确认。
- 修复建议：把 `batchCullingChip` 的文案并入 value，逗号随语言（`ListFormatter` 或 l10n 提供的分隔符）。

#### P2-2 字号体系只锁了一种：193 处裸字号里 104 处在监管外

- 分布（按行统计，见债务表）：`Metadata` 模块 33 处裸字号里 32 处是 `.caption` / `.caption2`；`Culling` 22、`Dashboard` 9、`Library` 7。
- 位置（抽样）：`Metadata/MetadataSections.swift:40,48,60,70,87,91`；`Metadata/MetadataEditorSheet.swift:40,49,59,65,69,74,104,109,125,149`；`Settings/SettingsView+Sections.swift:43,63`；`Settings/SettingsView+MaintenanceSection.swift:148`
- 代码：

`
// Metadata/MetadataSections.swift:58-62（同一检查器里紧邻的下一段）
60:             Text(l10n.format("%lld / %lld 已填写", filled, fields.count))
61:                 .font(.caption2)                    // 10pt
...
40:                             .font(.caption)         // EXIF 行 11pt
`

  对比同在检查器里的 `GatherInspectorSection`（标题 13pt、副标题 12pt `GatherFont.secondary`）。Metadata 面板是**唯一的 11pt / 10pt 文本面板**。
- 现象：同一个检查器列，"拍摄参数 / IPTC / 文件"三段的正文是 caption(11pt)，而 Culling / Gallery 检查器同层级用 callout(12pt)；`.caption2` 更是 10pt，在 220pt 宽检查器里阅读吃力。ratchet 只统计 `.font(.callout`，看不见 caption / caption2 / title3 的增长，"债务只降不升"覆盖不到 54% 的字号调用。
- 用户影响：跨页签看同一张照片的元数据时字号跳变；低视力用户在 Metadata 面板最吃力（而那里正是小字密集区）。
- 修复建议：`GatherFont` 补齐 caption / captionStrong 两个角色（或明确"检查器正文只能用 secondary"）；ratchet 加 `font.rawOther` 指标（正则 `\.font\(\.(caption2?|headline|subheadline|title[23]?|footnote|body|system)`，当前 104）。

#### P2-3 Library facet 栏 56pt 标签列在英文下截断，未知维度直接上英文 slug

- 位置：`Library/LibraryFacetBar.swift:23-25`、`54-61`
- 代码：

`
23:                     Text(title(group.dimension))
24:                         .font(.caption)
25:                         .frame(width: 56, alignment: .leading)
...
59:         default: l10n(dimension)        // 未识别维度 → 原始英文 slug 直接上屏
`

- 现象：中文 2 字标签（相机 / 镜头 / 年份 / 色标）在 56pt 里舒服；en 表把这些翻成 "Camera" / "Lens" / "Year" / **"Color Label"**——后者在 11pt 下约 68pt，被截成 "Color L…"。default 分支还会把协议里的新维度（如 `iso_hi`）原样显示成英文标识符。
- 用户影响：英文界面里筛选维度标题读不全，新增维度会暴露内部字段名。
- 修复建议：标签列改 `.frame(minWidth: 56, idealWidth: 72)` 或用 `Grid(alignment: .leading)` 自适应列宽；default 分支至少 `localizedCapitalized` 并加 tooltip。

#### P2-4 术语分叉：同一个东西叫「工作区」也叫「会话」

- 位置（抽样）：`Settings/SettingsView+C1HealthSection.swift:99`、`Interaction/GatherSessionPage.swift:160,201`（"工作区页面"）、`Persons/PersonsView.swift:261,345`（"个工作区"）
- 代码：

`
// Settings/SettingsView+C1HealthSection.swift:99
99:             Text(l10n("无工作区，写回队列来自当前会话"))
`

- 现象：一句话里两个词指同一实体（session）。全仓中文字符串里"工作区"223 次、"会话"234 次；en 表 "workspace" 65 条、"session" 15 条——英文用户看到的主导词是 workspace，而代码 / 路由 / 页签无障碍标签（"工作区页面"）与页内文案（"会话"）并不统一。
- 用户影响：新用户不确定侧栏里的"会话"和提示里的"工作区"是不是同一层容器；错误文案（"会话不存在" vs "无工作区"）会让人以为丢了两种东西。
- 修复建议：定一个词（建议"会话 / Session"，与 SessionPage / AppRoute 一致），"工作区"只留给目录概念；en 表同步分流 workspace / session。

#### P2-5 日期与字节格式不跟随应用语言

- 位置：`Settings/SettingsView+MaintenanceSection.swift:235-250`、`Support/C1StatusCapsule.swift:323-330`、`Persons/PersonsView.swift:605`；对照 `Support/DateFormatting.swift:42-52`
- 代码：

`
239:     private func dateText(_ iso: String) -> String {
240:         let formatter = ISO8601DateFormatter()
...
247:             return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
`

- 现象：`DateFormatter.localizedString` 用**系统 locale**，忽略 `LanguageStore` 选的界面语言。仓库里已有正确实现（`DisplayDateFormatters.shared.mediumShort(date, locale:)`，`DateFormatting.swift:43`），但只有 Dashboard 在用；`ByteCountFormatter` 同理（单位词不随语言）。
- 用户影响：界面切英文后，备份列表 / 最近同步时间 / 人物页仍显示 "2026年10月30日 09:46"，与整页英文正文混排——最容易被截图吐槽的那类不彻底本地化。
- 修复建议：维护区与 C1 状态胶囊统一走 `DisplayDateFormatters` 并传 `l10n.locale`；字节数用 `MeasurementFormatter(locale:)` 或自建本地化单位。

#### P2-6 缩略图失败态没有重试出口

- 位置：`Support/PhotoThumbnailView.swift:200-213`、`273-277`
- 代码：

`
200:             } else if failed {
202:                 ZStack {
205:                         Image(systemName: "exclamationmark.triangle")
207:                         Text((path as NSString).lastPathComponent)
...
273:         } catch {
275:             guard !Task.isCancelled, key == activeLoadKey else { return }
276:             failed = true
`

- 现象：失败只写 `failed = true`，没有超时重试、没有点击重试；`failed` 只有 `task(id: cacheKey)` 会重置，而失败后 cacheKey 不变，任务不会重跑。启动早期解码器尚未注册（`ImageDecodingRegistry.current()` 抛 `decoderUnavailable`）、外接盘瞬时不可读、RAW 解码偶发失败，都会把单元格钉在"文件名 + 三角形"上，直到被 LazyVStack 回收重建（要滚出很远再回来）。
- 用户影响：坏掉的格子看起来像"文件损坏"，用户会去检查素材盘；实际点进去（灯箱 / 详情）多半能正常解码，观感自相矛盾。
- 修复建议：失败态叠一个小"重试"图标按钮（带 `help`），点击时清该键缓存并重启任务；对 `decoderUnavailable` 做一次延迟自动重试（bootstrap 完成后通常就好）。

#### P2-7 每个在飞缩略图都挂一个 50ms 轮询探针

- 位置：`Support/PhotoThumbnailView.swift:602-614`
- 代码：

`
602:     private static func awaitShared(_ box: PhotoDecodeTaskBox) async throws -> Data {
603:         try await withThrowingTaskGroup(of: Data.self) { group in
604:             group.addTask { try await box.task.value }
605:             group.addTask {
606:                 // 取消时 Task.sleep 抛出；正常路径由 group.next() 先拿到结果后 cancelAll。
607:                 while true { try await Task.sleep(for: .milliseconds(50)) }
`

- 现象：可取消等待用"每 50ms 醒一次"实现，每个等待者一个循环。40 个可见格子 + 4 槽闸门，最坏约 800 次 / 秒定时器唤醒，持续整个 RAW 解码窗口（100–800ms）。
- 用户影响：滚动时的能耗与后台 CPU（笔记本风扇 / 续航），不是视觉缺陷但属于基建级成本。
- 修复建议：用 `withTaskCancellationHandler` + 盒子内保存 continuation 数组（取消时 `resume(throwing:)`）实现"取消即返回"，或让等待者直接 `try await box.task.value` 并用 `addWaiter / removeWaiter` 兜底。

#### P2-8 模型下载：无取消、无进度持久、成功后状态常驻

- 位置：`Settings/SettingsViewModel+Download.swift:16-58`、`Settings/SettingsView+Model.swift:169-199`
- 现象：`startModelDownload()` 由 `Task { }` 起在视图外，关掉设置窗口 / 切页面都不会停；`isDownloading` 只用来 disable 按钮，没有"取消"；`downloadPhase = .done` 之后永久显示"人脸模型已安装"（`reconcileDownloadPhaseWithModelStatus` 只在模型缺失时才回落 `.idle`）；失败只留一条 `errorMessage` banner，没有"重试 / 换地址"入口（地址藏在高级设置里）。
- 用户影响：弱网下 280MB 下载卡住只能杀 app；下完再回来看，因为 VM 常驻，"已安装"可能与实际不一致（用户手动换了模型目录）。
- 修复建议：保留 Task 句柄 + 取消按钮；下载进度给一个跨页可见的出口；`.done` 显示成一次性 notice 而非常驻行；失败 banner 内联"重试"。

#### P2-9 设置页信息架构：单页 11 段，恢复默认藏在工具栏

- 位置：`Settings/SettingsView.swift:78-93`（Section 顺序）、`116-121`（恢复默认按钮）
- 现象：一个 Form 顺序堆 banners / saveRuleHint / language / c1Health / 5 个 primaryGroups / faceAnalysis / maintenance / advanced（约 11 段，含备份列表逐行 + 诊断）。"保存规则"提示条常驻占一行。危险动作"恢复默认"是工具栏里与"刷新"并排的图标按钮，且与弹层里的确认按钮同名（都叫"恢复默认"）。
- 用户影响：找一项设置要滚很久（macOS 设置窗口通常用标签页分组）；想重置的人找不到，找到的人容易在弹层里误触（见 P1-4）。
- 修复建议：拆 2–3 个标签页（通用 / Capture One / 数据与恢复），或至少把 maintenance + advanced 折进 DisclosureGroup；"恢复默认"移进"数据与恢复"分组并加红色文字；提示条改成一次性 tip。

#### P2-10 错误码回退依赖"是否含 CJK"判定本地文案

- 位置：`DesignSystem/Components/NativeBanner.swift:26-59`
- 代码：

`
29:         guard error.origin == .localValidation,
30:               localized == l10n(L10n.unknownErrorKey),
31:               isLocalCopy(error.code) else { return localized }
...
53:     private static func isLocalCopy(_ code: String) -> Bool {
54:         code.unicodeScalars.contains { scalar in
`

- 现象：VM 本地校验的文案 key 只有"含 CJK 标点 / 汉字"时才允许上屏。若某天某个本地校验用了英文 key，会静默退回"发生未知错误，请稍后重试"，用户丢掉真正的字段级原因（"「X」不能为空"）。
- 用户影响：偶发但难查的"点了保存 → 通用错误"；英文界面尤其不友好（英文 key 永远命中不了这个分支）。
- 修复建议：用显式标记（`origin == .localValidation` 已经足够）替代字符集嗅探，CJK 判定只留作最后兜底。

### 其他观察（不计级，供后续批次参考）

- `GatherEmptyState` 已有 actions 重载，但仍有 30 处内联 `ContentUnavailableView`（Duplicates 5、Gallery 5、Persons 4、Dashboard 3）。抽样质量不错（都带出口，见"亮点"），但空态的图标尺寸 / 间距 / 最大宽度仍由各页自负，48 处里至少 3 种排布。
- `PhotoOverlayChip` 26 行里同时写了 `.accessibilityElement(children: .combine)` 与 `.accessibilityLabel(text)`，图标语义（`iconColor` 表达的 失败 / 保留 / 淘汰）丢失；建议把图标语义并入 label（例如「离线」由 "exclamationmark.triangle.fill" 传来，读屏时应读成「离线，源文件不可读」而不是只读「离线」）。
- `GatherChromeMetrics.contentMinWidth` = 680 是"窗口最小宽 − 侧栏最小宽"，没有减检查器 220：Culling 页在 860 最小窗 + 展开检查器时内容只剩约 460。页面按 460 还是 680 设计没有统一声明（`GatherChromeMetrics.swift:16` 的注释只解释了 237pt 的来源）。
- 查看器常暗（`viewerBackground = Color(white: 0.05)`）是正确取舍（对齐 Photos / Preview）；浅色 + 提高对比度下查看器内次要文字 `viewerTextPrimary.opacity(0.72)`（`GatherTheme.swift:120`）相对 0.05 底约 9:1 可读，但用户明明开了"提高对比度"却看到最暗表面，且该 token 没有任何 `accessibilityHighContrast` 分支——建议高对比度下把 opacity 提到 0.85+。
- 硬编码色只有 9 处（不是 20 处）：`Culling/CullingDisplayFormat.swift:12-19` 的 7 个 C1 色标（数据色，合理）+ `C1StatusCapsule.swift:332` 的动态 NSColor。主题四态的绕过风险其实很低。

---

## 设计系统债务分布表

ratchet 指标（`check-design-system.sh --warn-only` 实跑，与基线一致，PASS 无回归）：

| 指标 | 当前 | 基线 | 判定 |
|---|---|---|---|
| font.callout | 89 | 89 | ok（冻结的违规） |
| font.systemSize | 15 | 15 | ok（多在 DesignSystem 自己的组件与 Dashboard 首屏） |
| spacing.literalPadding | 175 | 175 | ok |
| spacing.literalSpacing | 257 | 257 | ok |
| empty.contentUnavailable | 30 | 30 | ok |
| container.groupBox | 0 | 0 | ok |
| theme.legacyAlias | 15 | 15 | ok |
| radius.legacyAlias | 15 | 15 | ok |

模块 × 违规类型（按**行**统计；callout 合计 89 与脚本口径一致；"其他裸字号"是脚本看不见的新口径）：

| 模块 | callout | 其他裸字号 | 字面 padding | 字面 spacing | 内联 CUV | legacy alias | 抽样行号 |
|---|---|---|---|---|---|---|---|
| Culling | 10 | 22 | 37 | 37 | 2 | 3 | CullingConflictPanel.swift:60,74,84；CullingWorkbenchViewer.swift:107,139,325 |
| Similarity | 16 | 2 | 6 | 24 | 3 | 0 | SimilarityView+Writeback.swift:33,38,70,74,97 |
| Export | 17 | 2 | 7 | 7 | 0 | 0 | ExportView+Options.swift:45,76,119；+Preview.swift:40,47 |
| Library | 7 | 7 | 18 | 33 | 2 | 1 | LibraryView+Content.swift:15,19,21,125 |
| Dashboard | 8 | 9 | 18 | 21 | 3 | 0 | SessionRowView.swift:62,87,104；DashboardFirstRunView.swift:159,274 |
| Gallery | 4 | 1 | 20 | 14 | 5 | 0 | GalleryView+Content.swift:206,216,228,238 |
| Persons | 6 | 2 | 8 | 10 | 4 | 2 | PersonsView.swift:287,346,397,441,643 |
| ControlCenter | 4 | 2 | 9 | 27 | 1 | 2 | SessionControlJobRow.swift:31；+Recommendation.swift:41 |
| **Metadata** | 1 | **32** | 1 | 6 | 0 | 0 | MetadataSections.swift:40,60,70；MetadataEditorSheet.swift:104,125 |
| FaceKeywording | 4 | 2 | 13 | 31 | 2 | 1 | FaceAnalyzeStep.swift:147,151,166 |
| Settings | 7 | 6 | 4 | 10 | 0 | 0 | SettingsView+Model.swift:157,181,188；+Sections.swift:43,63 |
| Support | 4 | 6 | 4 | 8 | 0 | 2 | C1StatusCapsule.swift:225；WritebackReportCard.swift:56,60 |
| Duplicates | 0 | 0 | 9 | 9 | 5 | 1 | DuplicatesGroupCardView.swift:95,105,129 |
| DesignSystem | 0 | 4 | 13 | 7 | 3 | 1 | GatherBadge.swift:53；NativeBanner.swift:116,120 |
| Interaction | 0 | 3 | 8 | 5 | 0 | 0 | GatherSessionPage.swift:97,173；GatherSessionToolbar.swift:133 |
| PreviewSupport | 1 | 2 | 0 | 2 | 0 | 0 | PreviewShellViews.swift:129,134 |
| Shell | 0 | 2 | 0 | 2 | 0 | 0 | RootShellSidebar.swift:116,117 |
| **合计** | **89** | **104** | **175** | **253\*** | **30** | **15\*** | |

\* spacing 的脚本口径是"出现次数"257，本表是"行数"253（4 行同一条语句里有两处 spacing:）；legacy alias 同理 15 vs 13 行。

**必要例外 vs 漏网**：

- 必要例外：`PhotoOverlayChip` / `GatherBadge` / `CullingViewerParts` 的字面 padding 与固定字号——它们是压在照片上的角标，必须在任意底图上给定像素尺寸，语义字体一放大就破坏构图（约 15 处）。
- 必要例外：`SimilarityView+Writeback` / `CullingConflictPanel` 的 callout 是两列并排的纯文对比面板，需要固定 12pt 保证行高对齐。
- 漏网：`Metadata` 32 处 caption / caption2（是正文不是角标）；`Settings` 6 处（设置页本应是设计系统样板页）；`Dashboard` 9 处 `.system(size:)`（hero 可商量，但 159 / 274 / 316 在列表行里）；`LibraryFacetBar` 的 caption / caption2 组合（正文级信息）。
- legacy alias 里 `GatherGlass.swift:21` 是**文档注释**提到 `contentBackground`（脚本连注释一起数，假阳性）；`CullingConflictPanel`(2)、`PersonsView`(2)、`FaceClusterMontage`(2) 是真在用的兼容别名，应与 surface / surfaceMuted 收口。

**GatherGlass 铁律核查**：`gatherFunctionalSurface` 仅 1 处真实调用（`GatherToast.swift:172`），另有 `glassEffect` 一处（`CullingWorkbenchViewer.swift:592` 的 `.clear` 胶囊，压在照片即媒体上，符合 Apple「clear 只用于媒体背景」的例外）。**内容层 0 违反**。但 `gatherPrimaryActionButton()`（`.glassProminent`，约 28 个调用点，全在内容区 / 空态 / sheet 里）属于"按钮算功能层"的灰色地带，建议在 appearance-interaction.md 里显式写明这个例外，否则下一个人会照抄到卡片上。

---

## 本地化风险清单

已核对：en.lproj 1862 键；zh-Hans 仅 9 键（key = value，等价留空）；源码静态 key 0 缺失。以下为**动态 key**（运行时变量）逐条核对：

| 动态 key 来源 | 键数 | 在 en 表 | 缺失后果 | 证据 |
|---|---|---|---|---|
| `errorMessages` → `l10n.errorText(code)` | 209 | 是 | 回退"发生未知错误"（已收录，英文可读） | GatherLocalization.swift:67；L10n.swift:263 |
| `jobStatusKeys` → `jobStatusText` | 7 | 是 | 原样显示状态码（`cancelling` 直接上屏） | L10n.swift:276-279 |
| `jobTypeKeys` → `jobTypeText` | 8 | 是 | 原样显示 `face.analyze` | L10n.swift:282-285 |
| `progressPhaseKeys` → `progressPhaseText` | 26 | 是 | 回退"正在处理…"（已收录） | L10n.swift:297-300 |
| `output.<i>/<n>` 合成相位 | 1 模板 | 是 | 缺则英文用户看到中文模板 | L10n.swift:291-296 |
| 设置字段 `zhLabel / zhDesc / titleZh / labelZh` | 86 | 是 | 英文界面显示中文标签（**最脆弱**：改一个字就静默回落） | SettingsModels.swift:28-36；SettingsView+Fields.swift:124 |
| `SelectOption.labelZh` | 含在上 86 | 是 | 下拉项回中文 | SettingsView+Fields.swift:116 |
| `CaptureOneColorLabel` → `CullingDisplayFormat.title` | 8 | 是 | 色名回中文 | CullingDisplayFormat.swift:23-35 |
| EXIF / IPTC 行标签 `l10n(label)` | 45 | 是（唯一"缺失"是注释） | 元数据行标签回中文 | MetadataDisplayRows.swift:41-61 |
| `l10n(dimension)` 兜底分支 | 5 已知 + 未知 | **否** | 新维度直接显示英文 slug（如 `iso_hi`） | LibraryFacetBar.swift:59 |
| `page.titleKey`（7 页签） | 7 | 是 | 页签回中文 | GatherSessionPage.swift:143,169,192 |
| `GatherAppMenuItem.titleKey`（菜单） | 5 | 是 | 菜单回中文 | MenuCopy.swift:106-110 |
| `LocalizedText(key, params)`（VM 提示） | 数百 | 是（静态扫描 0 缺） | key 原文（多为中文模板 + %@） | L10n.swift:322-334 |
| `CommandErrorText.resolve` 的英文诊断 | — | 设计如此 | 走"发生未知错误"，原文只进 tooltip / 日志 | NativeBanner.swift:26-49 |

其它本地化质量项：

- **en 值 0 处残留中文**（正则扫 CJK 区间，1862 条 value 全 0 命中）——比预期好。
- **占位符一致性**：唯一"数量不一致"的 `已分析 %lld%%` → `%lld%% analyzed` 是我的正则把 `% a` 误判；两侧实际都是 1 个 `%lld` + 1 个字面百分号，**不是问题**。
- **plural**：en 表 8 条 `#one`，`plural()` 调用 15 处去重后正好 8 个 key，一一对齐；`#one` 的占位符与 base 一致（如 `%@ · %lld 张照片` → `%@ · %lld photo`）。**但没走 plural 的计数串在英文下会说 "1 photos"**，抽样：`%lld 张人脸编码失败`、`%lld 张照片离线（源文件不可读）`、`≥%lld 张照片`、`XMP 写回预览 · 共 %lld 项 · %lld 张照片受影响`。
- **`l10n.format` 的百分号陷阱**：`L10n.render` 把 flags 里的空格也视为合法前缀（`-+ #0'`，`L10n.swift:456-459`），因此模板 "50% of photos" 里的 `% o` 会被解析成八进制转换符并**吃掉一个实参**（`L10n.swift:603-606`）。当前 en 表没有这种写法（字面百分号都写作 %%%），但这是下一个译者会踩的坑：建议要求 `%` 之后不允许前导空格。
- **术语**：见 P2-4。**日期 / 字节**：见 P2-5。

---

## 亮点

1. **空态 / 失败态"必有出口"比多数 macOS app 好**：图库真空库给三条（导入文件夹 / 前往控制中心 / 刷新，`GalleryView+Content.swift:473-497`）；筛选无结果给"清除筛选"；加载失败给"重试"+ 说明（`441-455`）；重复页区分"未扫描 / 无完全重复 / 无视觉相似"三种语义（`DuplicatesView+Sections.swift:147-175`），注释里还写了"不再放第二个同权按钮"的取舍。
2. **玻璃铁律真的守住了**：`GatherGlass.swift:12-25` 把 HIG 原文与"内容层不用玻璃"写进类型注释，全仓只有 toast 与一处媒体胶囊用 `glassEffect`。
3. **缩略图管线的并发模型是对的**：actor 闸门（整图 4 槽、区域解码独立 2 槽）、单次 actor 事务内 check-then-create 去重、等待者归零即取消在飞任务、磁盘缓存键含 mtime + size、512MB 上限 + 字节阈值 prune（`PhotoThumbnailView.swift:490-540,562-595`；`ThumbnailDiskCache.swift:102-120`）。"不闪、不重复解码、不涨内存"的功夫到位——缺的只是失效与失败重试。
4. **Toast 有真正的无障碍通道**：`show` 里 `NSAccessibility.post(element:notification:.announcementRequested)`（`GatherToast.swift:82-84`），关闭按钮有 `help` 文案。
5. **reduceMotion 覆盖主要动效**：18 处（toast 过渡、胶片条滚动、相似度悬停、首屏 hero、面板展开、页签悬停），且逐处选择"降级成 opacity"而不是全局一刀切。
6. **动态错误文案的渲染期解析**（`CommandErrorText.resolve` + `LocalizedText`）避免了把本地化字符串存进 VM 的经典 bug，切语言不必重建视图树。
7. **本地化工程指标健康**：1862 键、0 静态缺失、0 动态缺失、0 中文残留、plural 规则对齐——这一块可以直接标"已收口"。

---

## 未验证与风险

1. **`GatherToast.swift:126` 的 `.allowsHitTesting(false)` + 子按钮 `.allowsHitTesting(true)`（`156`、`164`）**：SwiftUI 里祖先的 false 通常会覆盖后代的 true（命中测试自顶向下计算），若成立则 toast 的"关闭"与"重试 / 清除筛选"按钮**全部点不动**。这是本轮最需要实机确认的一条——静态代码看不出结论；我在"亮点 4"里只肯定了它的无障碍通道，没有肯定命中测试。请以实机点 toast 的 × 为准，若按钮真死则升级为 P0。
2. **P1-3 的 614pt** 是静态推算（860 − 180 − 32 − 34）。NavigationSplitView 可能另有内部 inset 或最小列宽行为，真机可能在 600–640 之间；6pt 余量下"最小窗走下拉"成立，但若实测 > 620 则性质从 P1 降为 P2。**建议 860×560 下截图确认一次**。
3. **`ModelInstaller` 下载的 ONNX 是否被当前 provider 消费未验证**：`ModelInstaller.swift:12-15` 注释说 "Vision provider 不需要模型资产"，而 `LiveFaceAPI.swift:126-128` 仍把 `detector_model_path` / `encoder_model_path` 传进 job checkpoint。若下游忽略，"下载人脸模型"就是一个**误导性的修复入口**（用户等 280MB，问题没解决）——需跑一次人脸分析看日志才能定级，暂不列为发现。
4. **`glassProminent` 在浅色 + 提高对比度下的实际渲染**（对比度、半透明白字）无法静态判定，28 个主 CTA 都押在它上面。
5. **`PhotoDecodeGate.acquire()` 用退避轮询而非 FIFO 队列**（`PhotoThumbnailView.swift:506-521`）：理论上后到的请求可能连续抢到名额，在"滚回顶部"场景下新格子排在旧请求之后。未用 Instruments 观测，未证伪。
6. 未覆盖：`SliderInputView` / `FaceClusterMontage` 的交互细节、`C1StatusCapsule` 六格队列在窄检查器下的换行、`LanguageStore` 切语言时的整树重建开销（属其他批次主题）。

---

附：统计口径

- 模块归属 = `Sources/GatherUI/<第一层目录>`。
- "其他裸字号" = 对 `.font(.caption` / `.font(.caption2` / `.font(.headline` / `.font(.subheadline` / `.font(.title2` / `.font(.title3` / `.font(.footnote` / `.font(.body` / `.font(.system` 逐行命中求和 = 104，与 `font.callout` 89 + `font.systemSize` 15 合计 193 处 `.font(.`，与全仓 grep 一致。
- ratchet 脚本连注释一起计数（`check-design-system.py:38-47` 的注释已声明这一点），因此 `GatherGlass.swift:21` 这类文档注释会虚增 1。
