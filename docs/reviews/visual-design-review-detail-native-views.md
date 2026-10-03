> 本文件是 [视觉设计评审主报告](visual-design-review.md) 的**分区明细**：设置 / 人脸关键词 / 控制中心 / 人物库四个区域的逐条源码审查明细（不重复主报告的结论与截图）。

# Gather macOS — Visual, Page & Interaction Design Audit

**Areas audited:** Settings · Face Keywording workbench · Session Control Center · People library
**Files:** desktop/native/gather-app/Settings/SettingsView.swift (View layer, L990-1532), desktop/native/gather-app/FaceKeywording/FaceKeywordingView.swift (1-1885), desktop/native/gather-app/ControlCenter/SessionControlView.swift (1-829), desktop/native/gather-app/Sources/GatherApp/Persons/PersonsView.swift (1-500). Context read: GatherTheme.swift, RootView.swift, GatherApp.swift, and all Support/* components.

**Method / limits.** Source-only review (all four files read end-to-end, Settings from L990 as instructed). Contrast ratios below were computed with the WCAG relative-luminance formula from the literal theme hex values. I did not run the app myself (the orchestrator captured the runtime screenshots for the main report), so there is no rendered-pixel verification in this appendix — the geometry claims (alignment, nested scroll) are static-analysis claims; everything else is verifiable in source.

**Deployment target:** macOS 14 (Package.swift:15), so every fix below is annotated; macOS 15/26+ APIs need an availability guard or a fallback.

---

## 0. Cross-cutting root causes (they explain most per-page findings)

**C1 — No window-level chrome contract.** GatherApp has one WindowGroup and no Settings scene (GatherApp.swift:26, 61); the window title is one value (RootView.swift:266, 406-413) that resolves to "Gather" on the Settings and Persons pages; the app never calls .toolbar. Every page therefore invents its own header, back button, tab bar, refresh button and status capsule inside the scroll content — the "web app in a window" signature.

**C2 — The palette is literal CSS, not system color.** GatherTheme.swift:9-46 hard-codes hex pairs resolved through NSColor(name:) with a single light/dark branch (GatherTheme.swift:52-57); no materials, no separator colors, no high-contrast variants, and the card surface differs from the page background by 1.06:1 (see P0-4).

**C3 — Window cannot be tiled.** RootView.swift:246  .frame(minWidth: 1100, minHeight: 720)  exceeds a half-screen Split View on a 1440 pt display; HIG expects windows to work across a range of sizes.

**C4 — Almost no keyboard/contextual affordances in the four pages.** Grep across the four files: .searchable 0, .contextMenu 1 (a redundant one, PersonsView.swift:161), .focusable/.defaultFocus 0, .refreshable 0, keyboardShortcut 1 (PersonsView.swift:480). No Cmd+R refresh, no Cmd+[ / Esc back, no Cmd+F search, no focus-ring policy, no right-click menus on cluster cards or job rows.

**C5 — The shared badge applies Latin typography to CJK.** Support/GatherBadge.swift:51-52  .textCase(.uppercase).kerning(0.5)  is applied to localized strings (this app is zh-first). Not referenced by the four audited files today, but it is the shared component they should use instead of their hand-rolled capsules (P1-29).

---

## P0 — blocking / visibly broken on screen

### P0-1 · Page chrome, back navigation and tabs are drawn inside the content; the title bar never names the page
**Where** SettingsView.swift:1084-1102, FaceKeywordingView.swift:1042-1062, SessionControlView.swift:308-334, PersonsView.swift:276-288
    Button(GatherLocalization.l("返回"), systemImage: "chevron.left", action: onBack).buttonStyle(.plain)   // fkw:1045, control:311
    Text(GatherLocalization.l("设置")).font(.largeTitle.weight(.bold))                                       // settings:1087

- **Wrong** — HIG Window Anatomy / Toolbars: Back, view switching, Refresh and status belong in the title bar / toolbar; the title bar names the current view. The app has zero .toolbar usage.
- **Hurts** — Every page paints a 100-160 pt fake title bar (H1 + subtitle + tab row + status capsule) that fights the real one; on macOS 26 the window shows no Liquid Glass toolbar at all, so the app reads as a browser page in a frame. The four pages use four different header layouts (Settings: surface band L1101; FaceKw: unstyled header L1061 with a surface band starting only at the step chips L1077; Control: surface band L333; Persons: no page header at all), so one app feels like four.
- **Fix** — .navigationTitle(...) / .navigationSubtitle(...) per page plus a toolbar with ToolbarItem(placement: .navigation) for the back button and ToolbarItem(placement: .primaryAction) for Refresh (macOS 11+); on macOS 26 add ToolbarSpacer / .buttonStyle(.glass) guarded by if #available(macOS 26.0, *). Delete the in-content H1 from all four pages.

### P0-2 · Custom tab bar replaces the system control
**Where** SessionControlView.swift:324-329, FaceKeywordingView.swift:1054-1059, component Support/SessionTabBar.swift:23-83
    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? GatherTheme.primarySoft : Color.clear))   // SessionTabBar.swift:59-61
    .overlay(alignment: .bottom) { if selected { RoundedRectangle(cornerRadius: 1).fill(GatherTheme.primary).frame(height: 2) } }

- **Wrong** — HIG Segmented Controls / Tab Views: view switching is a system control (Picker(.segmented) / TabView), not six painted chips with an underline.
- **Hurts** — Non-native look (radius 6 + 2 pt underline = web nav), no keyboard traversal (arrow keys, Cmd+1…6), no system focus ring, no badge/overflow behavior, and the 2 pt underline duplicates chrome the toolbar draws itself.
- **Fix** — Picker in a ToolbarItem(placement: .principal) with .pickerStyle(.segmented).labelsHidden() (macOS 11+), or a real TabView(selection:). Keep SessionTab as the selection value; delete the bottom underline overlay.

### P0-3 · People library: hand-built two-pane sidebar, fixed 300 pt list, custom selection, back button in the body
**Where** PersonsView.swift:55-60, 154-169, 243-244, 276-288
    listPane
        .frame(width: 300)                                              // 57
    .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)   // 243
    .buttonStyle(.plain)                                                // 286 (back link)

- **Wrong** — HIG Split Views / Sidebars: two-pane layouts are NavigationSplitView; selection is a bound List(selection:); the detail column does not carry a "back" link.
- **Hurts** — The page shows two columns of left navigation at once (global sidebar plus this fake one); the pane cannot be resized, collapsed or toggled (⌥⌘S), so the detail is hard-capped at window-minus-300; the custom row background duplicates/overrides the system sidebar selection appearance and will not follow Increase Contrast or the macOS 26 sidebar material; "返回人脸库" goes "back" from a detail pane that was never pushed, which is meaningless on macOS.
- **Fix** — NavigationSplitView { List(selection: $selectedId) { ... }.listStyle(.sidebar) } detail: { PersonDetailView(...) } (macOS 13+); drop viewModel.deselect() and the fixed width; use .navigationSplitViewColumnWidth(min:ideal:max:) if a width is needed.

### P0-4 · The card system has no visible separation (1.06:1 fill, 1.32:1 border, in both appearances)
**Where** Support/GatherTheme.swift:14-22, 75-85; used at SettingsView.swift:1179, 1343, 1385, 1406, 1462; SessionControlView.swift:414, 511, 662, 753, 777, 827; FaceKeywordingView.swift:1539-1541, 1719-1720
    .strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1)         // GatherTheme.swift:83
    surface #FAF7F2 on background #F5F0EB  (dark: #2E2A24 on #221E1A)

- **Wrong** — HIG Color: surfaces separate via semantic colors/materials that adapt to appearance and Increase Contrast.
- **Hurts** — Measured: card vs page 1.06:1, border 1.32:1 light; 1.16:1 / 1.17:1 dark. The Settings page reads as one flat cream wash with floating headings; card boundaries vanish for low-vision users and on poor displays. The theme only branches on .darkAqua/.aqua (GatherTheme.swift:52-57), so Increase Contrast changes nothing anywhere in the app.
- **Fix** — Color(nsColor: .controlBackgroundColor) / .windowBackgroundColor plus Color(nsColor: .separatorColor), or .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) (macOS 12+); keep the warm brand tint as .tint()/accent only; if the hex surface must stay, ship an asset-catalog color set with a High Contrast appearance variant.

### P0-5 · Stage connector is drawn ~10 pt below the dots it connects
**Where** SessionControlView.swift:399-405, 445-476
    HStack(spacing: 10) { ... stageConnector(reached: mark.reached); stageMark(mark) }   // 399-404
    Rectangle().fill(...).frame(height: 2).frame(maxWidth: .infinity)                    // 472-475

- **Wrong** — Layout/alignment: a bare Rectangle in a default .center HStack centres on the taller stageMark VStack (28 pt dot + 6 + label ≈ 47 pt), not on the 28 pt dot.
- **Hurts** — Both 2 pt line segments float ~10 pt below the circles in the label band; it looks broken at every size, and the trailing Spacer() (404) leaves the row left-weighted with a dead gap after the third dot.
- **Fix** — Share an alignment guide: put the connector in the same HStack(alignment: .center) as a .frame(height: 28) wrapper, or use .alignmentGuide(.center), or move the label outside the aligned row; alternatively replace the whole stepper with Gauge/ProgressView plus LabeledContent.

### P0-6 · Face review step measures itself with GeometryReader inside a ScrollView
**Where** FaceKeywordingView.swift:925-938, 1334-1340
    GeometryReader { geometry in
        HStack(alignment: .top, spacing: 18) { clusterPane; detailPane.frame(width: min(340, max(280, geometry.size.width * 0.32))) }
    }

- **Wrong** — GeometryReader has no intrinsic height; inside a vertical ScrollView the proposed height is unspecified (GeometryReader falls back to its ~10 pt ideal or fills a fixed proposal), so content height must never depend on it.
- **Hurts** — The entire review step (cluster grid plus the detail pane with its 210 pt member list and editor) can collapse to a sliver or get clipped; it also re-lays out on every width change. This is the step users spend most of their time in.
- **Fix** — Remove the reader: .containerRelativeFrame(.horizontal, count: 3, spacing: 18) (macOS 14+) or ViewThatFits, or make the two panes a real split (HSplitView / NavigationSplitView). If a width is unavoidable, measure once at page level with onGeometryChange(for:of:action:) (macOS 15+, guard with if #available).

### P0-7 · Three to four nested scroll regions in one page
**Where** FaceKeywordingView.swift:925 (page ScrollView), 1546-1556 (memberList, maxHeight 210), 1674-1717 (boundPreview, maxHeight 270), 1731-1739 (xmpPreview, maxHeight 240)
    ScrollView { VStack(spacing: 0) { ForEach(...) } }.frame(maxHeight: 210)
    ... .frame(maxHeight: 270) ... .frame(maxHeight: 240)

- **Wrong** — HIG Scrolling: one scroll surface per pane; a scroll view nested in a scroll view traps the wheel/trackpad gesture with no visual affordance that it scrolls.
- **Hurts** — Scrolling over the member list or XMP preview moves the inner view first, then the page (scroll chaining): the page feels stuck; three different arbitrary heights (210/240/270) make the panes look accidental; a trackpad flick inside a 210 pt box is unusable.
- **Fix** — Own scrolling in one place: make each pane a List/Table with a stable height and .scrollBounceBehavior(.basedOnSize) (macOS 13+), or expand them inline and let the single page scroll view scroll; if a bounded height is required, use one shared constant and a real header so it reads as a separate region.

### P0-8 · Warning color used as text/badge foreground measures 2.41:1
**Where** FaceKeywordingView.swift:1219-1233 (phaseCapsule footnote text), 1667 (24 pt stat number), Support/WritebackReportCard.swift:46, SettingsView.swift:1258 (tint only)
    case .cancelled: return GatherTheme.warning            // 1232, used as .foregroundStyle
    GatherStatCard(value: viewModel.unboundClusters.count, label: ..., color: GatherTheme.warning)   // 1667

- **Wrong** — HIG Accessibility / WCAG AA: body text needs at least 4.5:1, large text 3:1. #D4944F on #FAF7F2 = 2.41:1, on #F5F0EB = 2.28:1 (dark mode is 8.66:1, so only light mode fails).
- **Hurts** — The "已取消" status, the "未绑定并跳过" count and the skipped-writeback card are illegible in light mode; because hue is also the only severity cue in those chips, the meaning is lost with them.
- **Fix** — Use Color(nsColor: .systemOrange) (adapts to appearance and Increase Contrast) or darken the brand warning until it reaches 4.5:1; always pair with an SF Symbol/Label and .accessibilityValue instead of hue alone.

---

## P1 — clearly wrong

### Settings

**P1-1 · Not a Settings scene and not a Form.** SettingsView.swift:1030-1045. VStack + ScrollView + VStack(spacing: 20) of cards under a hand-painted header. HIG: preferences live in a Settings scene (Cmd-,) built from Form + Section. Hurts: no standard label column, no automatic apply/validation behavior, and the page is reachable only through the app's own sidebar (RootView.swift:541-550), not the standard Cmd-, window. **Fix:** a Settings scene (macOS 11+) with Form { Section { LabeledContent(...) { ... } } }.formStyle(.grouped) (macOS 13+); drive Cmd-, with SettingsLink (macOS 14+) instead of a sidebar destination.

**P1-2 · Flat, duplicated typography.** SettingsView.swift:1108, 1279, 1368, 1392-1404, 1451-1452 — seven identical .font(.title3.weight(.semibold)) headings, including "人脸分析" and "常规参数" and "高级参数" in the same card. HIG Typography: one style per level. Hurts: users cannot tell card title from group title; the page has no scannable structure. **Fix:** card = .title2.weight(.semibold), group = .headline, rows = .body; drop the duplicate. Also 1395, 1401, 1452 use the split form .font(.title3).fontWeight(.semibold) — inconsistent with the .font(.title3.weight(...)) used elsewhere.

**P1-3 · Every field has its own Save button; no label column; ragged right edge.** SettingsView.swift:1196-1223, 1465-1531.
    .frame(width: isPathField ? 300 : 220)        // 1486 ... vs .frame(width: 120)  // 1498
    .frame(maxWidth: 440, alignment: .trailing)   // 1220, 1528
- **Wrong** — HIG Settings + Forms: standard macOS preference forms align labels in one column and apply edits immediately (or via onSubmit); buttons are not repeated per row.
- **Hurts** — Five text-field widths (300/220/120/240) and a "trailing 440 pt" pseudo-column mean nothing lines up vertically; each row carries its own button so the right edge is a zig-zag of controls; users must remember to click Save per field.
- **Fix** — Form + LabeledContent("检测模型路径") { TextField(...).onSubmit(save) }; let Form own the label column; one section-level action if a button is really needed.

**P1-4 · Slider rows use a different layout from the shared slider control.** SettingsView.swift:1409-1431 (label above, full-width slider) vs Support/SliderInputView.swift:30-53 (110 pt label column via GatherTheme.formLabelWidth), which the same app uses in the Face page (FaceKeywordingView.swift:1142, 1146). Same data type, two row layouts, no alignment between them. **Fix:** use SliderInputView/SliderInputIntView in Settings too, or adopt a Form/LabeledContent row for both.

**P1-5 · Six counters flatten severity and add a third stat style.** SettingsView.swift:1308-1318, 1360-1362.
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8)
    queueCell(zh: ..., value: sync.failed) / queueCell(zh: ..., value: sync.conflict)
- **Wrong** — HIG Layout/Hierarchy: equal weight for equal-importance data; failures are not equal to successes. GatherStatCard(style: .compact) (GatherCommonViews.swift:65-68) also gives a third look next to .card and .plain.
- **Hurts** — "失败 3" is styled exactly like "已同步 12", so the one number needing action is invisible; meanwhile SessionControlView.swift:766, 785 does emphasize failures with GatherTheme.error, so the same data is loud on one page and silent on another.
- **Fix** — LabeledContent("失败") { Text(...).foregroundStyle(sync.failed > 0 ? Color(nsColor: .systemRed) : .primary) } with a Label icon; one stat component with one style set.

**P1-6 · Check rows are a glyph-only colour signal with no accessibility value.** SettingsView.swift:1346-1357.
    ZStack { Circle().fill(passed ? GatherTheme.success.opacity(0.14) : ...); Text(passed ? "✓" : "✗") }.frame(width: 16, height: 16)
- **Wrong** — HIG Accessibility: never encode status in a decorative glyph/colour alone; every element needs a label and, when it has state, a value.
- **Hurts** — VoiceOver reads the glyph separately from "Capture One 可达" and never says whether it passed; the 16 pt circle with a footnote-bold glyph is optically cramped.
- **Fix** — Label(zh, systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill") plus .accessibilityValue(passed ? "通过" : "未通过") and .symbolRenderingMode(.hierarchical).

**P1-7 · Header actions are unstyled, unshortcuted, and one is destructive.** SettingsView.swift:1093-1098. Refresh and 恢复默认 sit in the content header with no .help, no .keyboardShortcut, and 恢复默认 (which wipes every setting, SettingsView.swift:1065-1072) renders exactly like the safe button. **Fix:** toolbar items, .keyboardShortcut("r", modifiers: .command) (macOS 11+), and Button(role: .destructive)/Color(nsColor: .systemRed) for the reset.

**P1-8 · Model paths are unselectable and have no reveal/copy affordance.** SettingsView.swift:1162-1172, 1229-1231. A monospaced path users are told to put ONNX files into cannot be copied or revealed in Finder. **Fix:** .textSelection(.enabled) plus .contextMenu { Button("在访达中显示") } (macOS 11+), or a read-only TextField.

**P1-9 · A 60-character formatted sentence crammed into a LabeledContent value column.** SettingsView.swift:1135-1148. The "模型信息" row wraps to 3-4 lines at typical widths and drags the label to the top of a paragraph. **Fix:** move it out of the value column (footnote under the row) or use a Grid with .gridColumnAlignment(.leading) and a real multi-line block.

### Face Keywording workbench

**P1-10 · Bespoke wizard stepper; the arrow separator is invisible and disabled steps are double-dimmed.** FaceKeywordingView.swift:1066-1121.
    Text("→").foregroundStyle(Color.gatherBorder)                       // 1070, 1.32:1 — effectively invisible
    .foregroundStyle(isActive ? .accentColor : (isPast ? GatherTheme.success : .secondary))
    .disabled(!enabled).opacity(enabled ? 1 : 0.55)                     // 1117-1118 — .secondary at 55% ≈ 30% alpha
- **Wrong** — HIG Segmented Controls / colour semantics: view switching is a system control; "past" is not "success"; disabled text still has to be legible.
- **Hurts** — The arrow that explains the wizard direction cannot be seen; the "写回" step label is nearly unreadable before review is unlocked; green is used for "already visited", which reads as "done correctly".
- **Fix** — Picker(.segmented) in the toolbar, or keep chips but use .secondary/.primary (never success for navigation), remove the extra .opacity, and replace .help on disabled controls (which never appears) with a visible caption.

**P1-11 · Three-button preset "segmented control" is hand-painted.** FaceKeywordingView.swift:1236-1268. RoundedRectangle(cornerRadius: 6) with a custom primarySoft fill, border and .opacity(0.55) disabled state. HIG: Picker(.segmented). **Fix:** Picker("匹配强度", selection: $presetName) { ... }.pickerStyle(.segmented); it also gains keyboard support and correct focus/disabled rendering.

**P1-12 · Role filter chips do not wrap or scroll.** FaceKeywordingView.swift:1384-1416 (an HStack(spacing: 6) of capsules inside the header row at 1348-1353). With a dozen bound roles the row overflows: chips are clipped and the cluster count/title is pushed off. **Fix:** a Menu/Picker, or ScrollView(.horizontal) with .scrollIndicators(.visible) / ViewThatFits (macOS 13+).

**P1-13 · Card-in-card-in-card (three surfaces, two radii, two border alphas).** FaceKeywordingView.swift:1537-1541 (detail card, padding 16, border 0.6) then 1584-1586 (editor, radius 8 on Color.gatherBackground) then 1618-1620 (merge panel, same). Hurts: the review pane looks like three stacked boxes with no hierarchy, and the outer card is a hand copy of gatherCard() (padding 18) instead of the shared modifier. **Fix:** one gatherCard() plus an inner Form/Section (or .background(.quaternary)); never more than two surface levels.

**P1-14 · Member rows put an always-visible red text button on every line.** FaceKeywordingView.swift:1856-1864: Button(role: .destructive) with .buttonStyle(.plain).foregroundStyle(GatherTheme.error), a roughly 16 pt text hit target, no pressed state, no hover reveal, no context menu, no row selection. **Fix:** List/Table rows with .contextMenu (macOS 11+) or a hover-revealed Button(role: .destructive).buttonStyle(.borderless).foregroundStyle(Color(nsColor: .systemRed)) and a target of at least 24 pt.

**P1-15 · Two rows of identical stat cards on the writeback step.** FaceKeywordingView.swift:1663-1669 (已绑定簇 / 受影响照片 / 未绑定并跳过) and 1788-1799 (WritebackReportCard: 已写入 / 失败 / 已跳过 — same component, same 24 pt numbers). Hurts: the same visual weight is used for "before" expectations and "after" results, so users misread which numbers are outcomes. **Fix:** pre-writeback figures as plain LabeledContent/Grid text; keep the card row only for the report.

**P1-16 · Raw machine status leaks into localized UI.** FaceKeywordingView.swift:1187-1190: Text("分析结果：(result.status)，检测失败 ...") interpolates the core enum (done/failed/cancelled) into the Chinese UI and duplicates the banner already shown at 914-918. **Fix:** route through a localized mapping (the file already has AnalysisPhase.label at 1875-1884) and delete the duplicate line.

**P1-17 · Contradictory tooltips; empty tooltips on disabled buttons.** FaceKeywordingView.swift:1812-1819 renders 重试失败项 only when result.failedItems is non-empty yet attaches .help("没有失败项"); 1825-1830 renders 清理备份 only after isSyncConfirmed yet says "请先在 Capture One 中加载元数据并确认同步"; 917, 1120, 1634, 1642 pass an empty string. Wrong: HIG Help tags must describe the control they are on. Hurts: the most confusing messages appear exactly on the buttons users are trying to use (and .help on a disabled button never shows at all). **Fix:** describe the action ("重试写入失败的 N 项"), drop empty strings, and put prerequisite text in a visible caption.

**P1-18 · Dead clickable capsule.** FaceKeywordingView.swift:1051: C1StatusCapsuleHost(..., onOpenSettings: onOpenSettings ?? {}) — when the host passes nil the capsule still hovers, presses and does nothing. **Fix:** make onOpenSettings non-optional, or render the capsule as non-interactive when there is no destination.

**P1-19 · Main-thread blocking on every cluster action.** FaceKeywordingView.swift:180-198, 630-647. load() is called synchronously from bind (348), unbind (371), removeMember (388) and merge (415); it performs three or four router commands plus jobs.list (all jobs, filtered in Swift) inside recoverAnalysis(). Hurts: one beach-ball per click on a large library; N+1 work per refresh. **Fix:** await client.executeAsync(...) off the main actor, a scoped job query instead of jobs.list, and event-driven refresh instead of reload-everything.

**P1-20 · "加载更多" pagination is redundant and hides results.** FaceKeywordingView.swift:1362-1373. A LazyVGrid already virtualizes rows, so the button adds a click and hides the rest of the library with no benefit. **Fix:** render the filtered clusters lazily; if paging is a product rule, prefetch on scroll instead of a centered button.

**P1-21 · Cluster cards have no keyboard access or context menu; selection is a CSS lift.** FaceKeywordingView.swift:1421-1465 (.offset(y: isSelected ? -1 : 0) at 1453, glow at 1452). Wrong: HIG Selection/Focus and Contextual menus. Hurts: Full Keyboard Access users cannot reach the grid; there is no right-click affordance for bind/merge/remove; the 1 pt lift is a translateY(-1px) web idiom and blurs on fractional points. **Fix:** .contextMenu, List(selection:)/.focusable() with .onKeyPress, and a native selection fill (RoundedRectangle.fill(Color.accentColor.opacity(0.12))) plus the system focus ring; drop the offset.

**P1-22 · Content width jumps between steps.** FaceKeywordingView.swift:929-933: .frame(maxWidth: 860) (analyze) vs .frame(maxWidth: 800) (writeback) vs unbounded (review, 931). Hurts: the left and right edges of the page visibly move when the user steps forward; two magic widths. **Fix:** one shared content-width token applied once around the step container.

**P1-23 · Peer section headings use two different styles.** FaceKeywordingView.swift:1132 (.headline), 1349 and 1626 (.title3.weight(.semibold)), 1787 (.headline). **Fix:** one level per role; if the page uses Form/Section the system supplies it.

**P1-24 · Missing controls in the job list, and copy that promises actions that do not exist.** SessionControlView.swift:742-745, 797-828. The card says "后台任务可在任务中心查看、取消或重试" but the rows only offer 重试 (820) — no 取消, no progress bar (only a footnote 3/120 at 817), no sorting or cap, rows are inert HStacks with no selection or context menu, and the status icon is .succeeded ? checkmark : "circle.dotted" (805), so queued/running/cancelling/cancelled all look identical. **Fix:** a Table/List with a ProgressView(value:total:) column, a row Menu with 取消 (jobs.cancel)/重试/复制 error, and honest copy.

**P1-25 · Duplicate "next action" surfaces.** SessionControlView.swift:489-512 (Action Inbox with a small bordered button) and 638-663 ("推荐下一步" card with a prominent button) render the same derived recommendation, twice, in two visual weights. Hurts: the user sees "重新分析" twice and cannot tell which is authoritative; the prominent one is below the fold. **Fix:** one inbox section with the top item rendered prominently and the rest as rows.

**P1-26 · One-line four-button action row with no state.** SessionControlView.swift:742-754: 扫描索引 / 分析质量 / 打开挑片 / 打开人脸 in a single HStack; clicking 扫描索引 repeatedly enqueues work, no button disables while isWorking, no progress, only a transient toast; the card title "分析与索引" does not describe the two navigation buttons. **Fix:** split navigation (tab bar/toolbar) from analysis actions, add .disabled(viewModel.isWorking) plus .help, and use a Menu/ControlGroup for the actions.

**P1-27 · Blocking refresh loop on the main actor.** SessionControlView.swift:42-61: public func load() performs four synchronous router calls on @MainActor; it is invoked from a 3 s polling loop (273-285) and from three notification observers (286-303). Hurts: during indexing the UI freezes every 3 s for the duration of four IPC/SQLite round-trips; bursts of domainChanged events compound it. **Fix:** async/await off the main actor, coalesce/dedupe event reloads, and fetch only deltas.

**P1-28 · Synchronous retry storm.** SessionControlView.swift:93-115: for job in failed { client.execute("jobs.retry", ...) } on the main thread. **Fix:** await each retry or add a single batch command; show a progress state.

**P1-29 · Empty state and badges re-implemented.** SessionControlView.swift:241-248 uses .font(.system(size: 40)) and .padding(40) instead of the shared GatherEmptyState used elsewhere (PersonsView.swift:176, 190); 478-485 softFlagBadge hand-rolls the GatherBadge capsule. **Fix:** GatherEmptyState / ContentUnavailableView (macOS 14+), GatherBadge(_:tone:).

### People library

**P1-30 · Detail pane stacks two competing scroll surfaces.** PersonsView.swift:303-354 (a Form with its own scroller) and 365-377 (a photo-grid ScrollView) inside one plain VStack with no height constraints. Hurts: the form and the grid fight for vertical space; the grid can end up with almost no height, and the wheel scrolls whichever region the pointer is over. **Fix:** put the photos inside the Form as a Section (or use a single List), or give the panes explicit minHeight/layoutPriority.

**P1-31 · Destructive action in the most prominent spot, rendered as a normal button.** PersonsView.swift:299: Button("删除", role: .destructive) — on macOS role: only affects menus/alerts, so it draws as an ordinary bordered button next to the person's name; the confirmation alert exists (388-413) but the affordance invites accidents. **Fix:** move it to the form footer or a Menu, style with .foregroundStyle(Color(nsColor: .systemRed)), keep the alert.

**P1-32 · Row accessibility throws away information.** PersonsView.swift:166: .accessibilityLabel(person.name) overrides the row's own content, so VoiceOver never hears "N 张照片 · M 个工作区" (235). **Fix:** delete the override or set a combined label including the counts.

**P1-33 · Selection is a Button plus a hand-painted background inside a sidebar List.** PersonsView.swift:154-169, 243-244. The system selection appearance is bypassed, rows get no arrow-key selection or .isSelected semantics beyond the manual trait, and the custom Color.accentColor.opacity(0.14) fill can double up with the sidebar's own hover/selection. **Fix:** List(selection: $viewModel.selectedId) plus NavigationLink(value:) (the file already sets .listStyle(.sidebar) at 169).

**P1-34 · Sidebar rows are 54 pt tall.** PersonsView.swift:228-232: 42 pt circular avatars inside .listStyle(.sidebar). HIG sidebars are compact (roughly 24-28 pt rows); only about nine people fit in a 720 pt window, and the pane is already squeezed by the global sidebar. **Fix:** 24-28 pt avatars in the list, full-size portraits in the detail pane, or a photo grid in the content column.

**P1-35 · Search lives in the pane body with a rounded-border field; no Cmd+F.** PersonsView.swift:111-116. HIG: search belongs in the toolbar/searchable so it gets the system magnifier, clear button, Esc-to-cancel and recents. **Fix:** .searchable(text: $viewModel.searchText, placement: .sidebar) (macOS 13+).

**P1-36 · Referenced photos are inert.** PersonsView.swift:365-377: thumbnails have no hover, click, selection, Quick Look or context menu — a wall of dead images under a "关联照片" heading. **Fix:** wrap in a Button with .onHover and open the gallery, or add .quickLookPreview (macOS 14+) and a .contextMenu (reveal in Finder / copy path).

---

## P2 — polish

1. **Arbitrary spacing scale.** SettingsView.swift:1043, 1100, 1107, 1257, 1391, 1448 use 24/20/18/14/12/26 with no token; GatherTheme has a radius scale (GatherTheme.swift:42-46) but no spacing scale. Fix: one spacing scale (4/8/12/16/24).
2. **Three radii for the same inline notice.** SettingsView.swift:1258-1259 uses Radius.lg (10) while equal-weight error blocks use 8 (FaceKeywordingView.swift:1161, 1525) and cards use 10. Fix: one "inline notice" style.
3. **Same counters, three number styles.** SettingsView.swift:1361 compact card = callout.monospaced() (GatherCommonViews.swift:45) vs SessionControlView.swift:783-784 callout.weight(.semibold).monospaced() vs .card .system(size: 24, weight: .bold) (GatherCommonViews.swift:45, 63). Fix: one stat component.
4. **Fixed-width control stack.** SettingsView.swift:1160, 1212, 1379, 1486, 1498, 1525 (five magic widths); SessionControlView.swift:347 .frame(maxWidth: 220); FaceKeywordingView.swift:1848 .frame(width: 36). Fix: let the layout own width; use Grid/Form alignment.
5. **Hand-tinted dividers.** FaceKeywordingView.swift:1552, 1712, 1735 Divider().opacity(0.5) and Support/WritebackReportCard.swift:68-70 Rectangle().fill(Color.gatherBorder.opacity(0.5)) — a CSS habit; they nearly vanish in dark mode (1.17:1). Fix: plain Divider() / Color(nsColor: .separatorColor).
6. **Flush edges in a bordered scroll box.** FaceKeywordingView.swift:1717-1720 boundPreview uses .padding(.horizontal, 12) with no vertical padding, so the first and last rows touch the 10 pt rounded border. Fix: symmetric padding or .contentMargins (macOS 14+).
7. **Fake indentation.** FaceKeywordingView.swift:1697-1709 indents member filenames with .padding(.leading, 10) — a text-indent port. Fix: a Label/list hierarchy or a real disclosure.
8. **Truncated diff with no escape hatch.** FaceKeywordingView.swift:1750-1757 shows only lastPathComponent and .lineLimit(1) on the before/after keywords, with no .help and no .textSelection. Fix: full path in .help, .textSelection(.enabled), a two-line limit with expansion.
9. **Web lift + glow selection.** FaceKeywordingView.swift:1452-1453 .shadow(radius: 3) plus .offset(y: -1). Fix: selection fill plus the system focus ring.
10. **Job status icon cannot distinguish states.** SessionControlView.swift:805-809: everything except .succeeded is circle.dotted (colour only for .failed); queued/running/cancelling/cancelled/interrupted are indistinguishable. Fix: an SF Symbol per status plus GatherBadge(status:) (already exists, GatherBadge.swift:156-175).
11. **Grid/thumb aspect mismatch leaves ragged gaps.** PersonsView.swift:366-370: GridItem(.adaptive(minimum: 150)) with a fixed 150x110 placeholder means every wider column has dead space at the right; also 150x110 is not the 3:2 of most RAWs, so .fill crops. Fix: .aspectRatio(3/2, contentMode: .fill) inside a full-width cell.
12. **Web eyebrow label.** PersonsView.swift:293-294: Text("人物详情").font(.footnote) above the H1. Fix: drop it or use .navigationSubtitle.
13. **Sheet has a fixed width and no initial focus.** PersonsView.swift:464-486: .frame(width: 380) with no @FocusState/.defaultFocus (macOS 14+), so the user must click into the name field. Fix: .defaultFocus($name, true) (macOS 14+).
14. **Pane title is an H1 in a 300 pt column.** PersonsView.swift:97: .font(.largeTitle.weight(.bold)) for "人脸库" while the same string is also the sidebar item and the window's concept of the page. Fix: toolbar/navigation title.
15. **Hard-coded icon point sizes.** PersonsView.swift:136-137 (28), 209-211 (40) vs the shared GatherEmptyState(iconSize:) used at 176, 190. Fix: GatherEmptyState/ContentUnavailableView plus .imageScale(.large).
16. **Avatar initial colours are literal RGB with a light/dark-only branch.** PersonsView.swift:13-25: NSColor(srgbRed: 61/255, ...) ignores Increase Contrast and any non-aqua appearance. Fix: derive from Color(nsColor: .labelColor) / .selectedContentBackgroundColor.
17. **Context menu with one redundant item.** PersonsView.swift:161-165: right-click offers only "打开", which left-click already does. Fix: add real actions (重命名/删除/在访达中显示/复制名称) or remove it.
18. **Raw UUID fragment as subtitle.** SessionControlView.swift:314: Text(String(format: l("工作区 %@"), String(viewModel.sessionId.prefix(8)))). Fix: the session name plus .help(sessionId).
19. **Banners never expire and shift layout.** SettingsView.swift:1033-1034, SessionControlView.swift:230-231, FaceKeywordingView.swift:914-924, PersonsView.swift:52-54: the notice/error banner is inserted above the scroll view and stays until the next action, so a stale "操作失败" can sit on screen for a whole session and content jumps when it appears. Fix: route notices through GatherToastCenter (already present) or .safeAreaInset with animation and auto-dismiss.
20. **NativeBanner is a bespoke alert style.** RootView.swift:626-652: tinted 12% fill plus border, no icon, no dismiss, no accessibility traits; it is the app's only banner primitive. Fix: a Label with .background(.quaternary), or a toast/inline Form row.
21. **No focus/pressed-state feedback on .plain buttons.** SessionControlView.swift:311 (back), FaceKeywordingView.swift:1045, PersonsView.swift:276-286: .buttonStyle(.plain) with no .contentShape on some, giving a text-sized hit area (about 20 pt, below the 24 pt minimum) and no pressed state; the icon-only "＋" in PersonsView.swift:102-107 is about 20x20 pt. Fix: .buttonStyle(.borderless) plus .frame(minWidth: 24, minHeight: 24) and .contentShape(Rectangle()), or a toolbar item (the system handles hover/press/hit area).
22. **GatherStatCard numbers use a fixed point size.** GatherCommonViews.swift:45: .system(size: 24, weight: .bold) (and GatherEmptyState .system(size: iconSize) at 200-202) — does not scale with text-size settings; prefer .title/.title2, which are Dynamic-Type-aware.
23. **Two different progress primitives for the same idea.** FaceKeywordingView.swift:1284 uses the custom GatherProgressBar while SettingsView.swift:1243 and SessionControlView.swift:346 use ProgressView(value:total:). The custom bar hard-codes an 8 pt track and 4 pt radius and re-implements its own accessibility value (GatherCommonViews.swift:114-144). Fix: standardize on ProgressView with .progressViewStyle(.linear).

---

## What these areas do well

- **Destructive-action discipline is genuinely good.** Every irreversible command is gated by the shared gatherDestructiveConfirm with impact-scoped copy that names counts, paths and recovery: SettingsView.swift:1065-1081, FaceKeywordingView.swift:953-1025 (writeback/retry/unbind/cleanup/confirm-sync/recluster/remove/merge), PersonsView.swift:388-413. confirmed: true can only come from the dialog branch, and cancellation writes a visible notice instead of failing silently.
- **Empty states are real, not dead ends.** PersonsView.swift:175-197 (暂无人物 + 新建 CTA, 未找到匹配 + hint), FaceKeywordingView.swift:1320-1330 (暂无人脸簇 + 前往分析), SessionControlView.swift:241-248 — all built on the shared GatherEmptyState rather than one-off stacks.
- **Correct use of the standard form idiom where it is used.** PersonsView.swift:303-354 is the only page that uses Form + .formStyle(.grouped) + LabeledContent + a role-tagged destructive alert, and it immediately feels native next to its neighbours — evidence that the other three pages are the outliers.
- **Accessibility basics are present in places many apps forget.** reduceMotion is honoured for hover and animation (FaceKeywordingView.swift:1464, SessionControlView.swift:265-268); hidden pages are removed from hit-testing and the accessibility tree (PersonsView.swift:66-68, RootView.swift:191-192, 210-212); decorative images are consistently .accessibilityHidden(true); sliders carry both label and value (SettingsView.swift:1428-1429, SliderInputView.swift:36-37, 96-97); custom chips declare .isSelected (SessionTabBar.swift:66, FaceKeywordingView.swift:1119, 1267); GatherProgressBar exposes a percentage value (GatherCommonViews.swift:141-143).
- **Interaction details that avoid real bugs.** No file re-implements checkboxes, radios, steppers or text fields; thumbnail decoding is off the main thread, cancellation-safe and cost-capped (PhotoThumbnailView.swift:71-107, 145-147); the settings slider commits only on release (SettingsView.swift:1425-1427); SliderInputView clamps typed input and accepts a full-width comma as a decimal separator (SliderInputView.swift:62-70); the create-person sheet uses .onSubmit, .keyboardShortcut(.defaultAction) and disabled-when-empty (PersonsView.swift:467-481); English diagnostics are deliberately kept out of user-facing text and parked in a tooltip (FaceKeywordingView.swift:649-678); no text below .footnote (13 pt) was found, and no uppercase/tracking is applied to CJK inside these four files.

---

## Appendix — issue counts

| Severity | Count | Concentrations |
| --- | --- | --- |
| P0 | 8 | Page chrome (all 4 files), custom nav controls, contrast, layout geometry |
| P1 | 36 | Settings 9 · Face Keywording 14 · Session Control 8 · People 7 |
| P2 | 23 | Magic numbers, duplicate primitives, missing tooltips/context menus |

Highest-leverage fixes, in order: (1) give the window a real toolbar and per-page navigation titles, then delete the in-content headers; (2) replace the hex palette with semantic colors/materials for surfaces, separators and the warning tone; (3) turn Settings into a Settings scene with Form; (4) rebuild the Persons page on NavigationSplitView plus List(selection:); (5) remove the nested scroll regions and the GeometryReader from the face-review step.
