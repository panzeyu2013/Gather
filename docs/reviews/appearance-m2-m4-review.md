# 会话页 Phase 2-4 审查报告（2026-10-24）

> 审查方式：5 个只读子代理，分别覆盖路由/生命周期、Culling/Gallery/Similarity、
> Control/Face/Duplicates/Export、命令/事件/并发、完整性与独立构建测试。
> 关联：[执行记录](appearance-m2-m4-execution.md)、[架构评审](appearance-interaction-architecture-2026-10-24.md)。
> 本报告记录审查发现与处置，不复述实现细节。

## 1. 结论

- 未发现崩溃、数据损坏或发布泄漏。
- 发现 1 个导航正确性 P0：从图库/相似度切普通页签后，previousRoute 变脏，
  返回会落到旧页面而不是真实页级来源。已在审查后修复并补 2 条回归测试。
- Phase 2 主体正确：7 页迁移、页签/返回/背景/副标题/可见性、事件过滤、
  入口参数均与旧实现对应。
- Phase 3 主体正确：AppRoute 单一真相源、Destination 投影、prune 等价、
  workspace 双层可见性成立。
- Phase 4 只完成一半：命令中心主路径已接，但菜单禁用态/AppDelegate 单轨/
  focused scope 未完成；事件迁移主体正确，但存在双层 debounce（已修 Library/Gallery）。
- 测试与门禁：独立验证 debug/release build、640 tests、全部 check-* 通过。

## 2. P0（已修复）

### P0-1 返回状态机在“图库/相似度 → 普通页签”后落错

- 位置：Shell/RootShellNavigation.swift 的 open(_:in:)、openGallery/openSimilarity、
  goBack()；Interaction/GatherSessionPage.swift 的返回分派。
- 复现：dashboard → openSession(control) → openGallery → open(.culling) → back。
  - openGallery 写入 previousRoute = control；
  - 同会话切 culling 不更新/不清 previousRoute；
  - 返回优先命中 stale control，落到控制中心，而不是图库；旧实现会回图库。
- 影响：用户返回落点漂移，可能多按一次/被困会话；文档“返回=真实来源”与实现不一致。
- 修复：
  - open(_:in:) 从 .gallery/.similarity 离开到其他页时记录页级来源；
  - goBack() 无论走 previous/origin/dashboard 都先清 previousRoute；
  - 新增 galleryThenTabBackReturnsToGallery、galleryThenControlThenTabBackReturnsToGallery
    两条回归测试。
- 处置：已修复，640 tests 通过。

## 3. P1（已修复）

| 发现 | 位置 | 处置 |
| --- | --- | --- |
| Culling 空态被 topLeading 顶到上方，下方大留白 | Interaction/GatherSessionPage.swift、Culling/CullingView+Content.swift | emptyGuide 自己撑满并居中；页签行仍贴顶。截图因本机屏幕锁定未重截 |
| Library/Gallery 事件双层 debounce 约 1s | Interaction/DomainEvents.swift + LibraryViewModel+EventRefresh/GalleryViewModel+Events | 两页 modifier 传 debounce: .zero，只保留 VM 单层合并 |
| 菜单在 handler 未安装时静默无操作（bootstrap 早期/无窗口） | GatherAppCommands.swift、AppCommandCenter.swift、RootView.swift | 无 handler 时回退旧通知；import/C1 在 bootstrap 期恢复可用。菜单禁用态仍未做 |
| 意图/导航两条并行实现 + 4 个死方法 | RootShellWorkspace.swift、RootShellNavigation.swift | 删除 4 个未用入口；openGallery 统一走 navigator；新增 clearIntent sink 清旧照片意图 |
| CommandCenter handler 永不清理 | Interaction/AppCommandCenter.swift、RootView.swift | 新增 clearHandlers()；RootView onDisappear 调用 |

## 4. P2 处置（部分关闭）

### 已关闭

- **共享会话工具栏**：新增 GatherSessionToolbar（C1 + 可选刷新 + 可选设置），
  7 个会话页全部迁移；页面特有动作（Export 预览/开始导出、Gallery 搜索）仍追加。
  迁移中发现并修复 **SIGSEGV**：Control/Face 的 @State VM 捕获在 ToolbarContent
  闭包里被复制后失效；两页改为 @Bindable（与 Gallery/Similarity 一致）。
- **兼容层删除**：Destination / SessionTab 类型与投影（destination、
  sessionTabDestination、isSessionTab、selectedWebPage、currentPage、
  gallerySessionId/similaritySessionId、SessionPage.systemImage）全部删除；
  测试与 SessionControlModels 改用 AppRoute/SessionPage；SessionTabHost.swift
  重命名为 SessionPageHost.swift。
- **测试补充**：DomainEventFilter 3 条纯过滤测试、AppCommandCenter clearHandlers
  测试、最小窗口检查器预算 1 条；RootViewTests 全部改为 AppRoute/SessionPage 断言。
- **截图复核**：7 页浅色 + Culling 深色全部用 P2 构建重拍，contact.png 已更新；
  Culling 空态在 light/dark 下均居中，7 页工具栏统一。
- **N01 最小窗口修复**：860×560 截图暴露 AppKit 约束循环崩溃；页签行改用
  GeometryReader 门控（窄窗 Menu，最小宽度 61），inspector ideal 260→220，
  并新增“页签行 + 挑片内容 + 检查器 ≤ 680”回归测试。

### 仍未关闭

1. **菜单 canPerform 禁用态**：GatherAppCommands 仍常启用；handler 状态
   @ObservationIgnored，即使加 .disabled 也不会随安装/卸载刷新。
2. **AppDelegate 仍是第二套菜单**：AppKit 兜底用 selector，不是从 AppCommand 表生成；
   import/C1 仍走 center → 通知 → Delegate。
3. **检查器未共享**：GatherInspectorSection 未落；Culling 仍用 GroupBox，
   Gallery/Library 各自写检查器卡片。
4. **测试缺口**：GatherSessionPage 的真实挂载可见性测试因 NSHostingView/NSWindow
   在测试进程 SIGSEGV 未能保留（改为继续用 WorkspaceVisibilityTests 直接测 workspace）。
5. **截图矩阵**：860×560 与 Culling 高对比已补；英文、有数据（照片/分组/任务）、
   Culling workbench/胶片/对比、inspector 开合仍未截图。
6. **多窗口/上下文**：commandCenter 是 SceneState 级共享，handler 绑定单个 RootView；
   Culling undo/redo 仍只在页面按钮上，没有 focused-scope 的 per-window 上下文。
7. **文档状态**：Phase 4 已改为部分完成；M1 入口已改为 Phase 2-3 完成、Phase 4 部分完成。

## 5. 检查过但未发现问题的关键项

- 7 个会话页全部使用 GatherSessionPage；无 sessionPageChrome/SessionTabBar/
  SessionTabRouter 残留；只有一份 tab strip。
- SessionPageHost 分发 7 页；AppRoute/navigator environment 接线成立；
  页面级 setPageVisible 只由 scaffold 调用。
- 页面事件 domain/session/origin 过滤与旧实现逐条一致；jobTerminal 的
  sessionOnly/scopeId 过滤正确；Culling 保留 change 载荷。
- pruneWorkspaceIntents 从 Destination 改 AppRoute 后逐条等价；
  workspace 双层可见性、LRU、轮询停止覆盖全部路径。
- 7 页入口参数（sessionId/photoId/photoPath/intent）与旧接线一致；
  Culling/Gallery/Similarity 的 task/onReceive/确认弹窗/检查器/灯箱未被破坏。
- en.lproj 删除的孤儿键无引用；本地化 parity 通过。
- release 二进制不含 DEBUG QA 参数；debug/release 均编译。
- 截图 contact sheet 非空；7 页浅色 + Culling 深色可见。

## 6. 独立验证

| 检查 | 结果 |
| --- | --- |
| Debug build（独立 scratch/cache） | 通过 |
| Release build | 通过 |
| 全量 swift test --no-parallel | 640 tests / 72 suites（审查前 634；P0/P1/P2 修复后 640） |
| explicit target dependency check | 通过 |
| docs / layering / preview / test catalog / cleanup / duplicates / no-legacy / protocol / select-star / design-system | 通过 |
| release 二进制 DEBUG 参数 | 无 |
| 截图资产 | 非空；7 页浅色 + Culling 深色 |

## 7. 残余风险

1. 未做真机点击流程：本机鼠标/辅助功能不可用；返回/页签/菜单禁用态靠状态机测试与代码审查。
2. 截图矩阵不完整：860×560 与 Culling 高对比已补；英文、有数据（照片/分组/任务）、
   Culling workbench/胶片/对比、inspector 开合均未截图。
3. LayoutBudgetTests 已补“页签行+挑片内容+检查器”预算；真实页面挂载的
   可见性仍只能靠 WorkspaceVisibilityTests（NSHostingView 测试进程会崩溃）。
4. Gallery 入口竞态未验证：onAppear 先 setVisible、.task 后 take
   galleryPhoto/filter；有单飞 load 但未做并发测试。
5. 多窗口未定义：commandCenter 是 SceneState 级共享，handler 绑定单个 RootView；
   当前 WindowGroup 没有 New Window，风险低但未验证。
6. SessionWorkspace.setPageVisible 不检查 session isVisible：迟到 onAppear 理论上
   可启动 suspended workspace 的 VM；当前靠导航时序。
7. 发布：签名/公证/Info.plist 打包未在本轮验证；--data-dir 是既有测试 seam。
8. Phase 4 未完成项：菜单禁用态、AppDelegate 单轨、检查器共享、focused scope
   （undo/redo 仍只在页面按钮，无 per-window 上下文）、订阅数降到 <5。
