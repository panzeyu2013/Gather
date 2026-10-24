# 会话页 Phase 4 收口（2026-10-24）

> 关闭 [Phase 2-4 审查报告](appearance-m2-m4-review.md) §4 的 7 项未关闭项，并处理
> 合并遗留：manifest 外部进程（WP7 回退）、菜单双轨、真实挂载测试缺口。
> 验证机：macOS 27 / Xcode 27；arm64 与 universal 均实测。

## 1. 菜单与命令中心（审查 §4-1、§4-2）

- **可观察 readiness**：[AppCommandCenter.swift](../../desktop/native/gather-app/Sources/GatherUI/Interaction/AppCommandCenter.swift)
  改为 `install(_:handler:)` + 可观察 `installed` 集合；删除 5 个
  `@ObservationIgnored` 闭包与 clearHandlers 的隐式失效。
- **禁用态**：[GatherAppCommands.swift](../../desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift)
  读 `focusedSceneValue(\.commandAvailability)`（[RootView.swift](../../desktop/native/gather-app/Sources/GatherUI/Shell/RootView.swift) 注入）
  并对 5 个命令 `.disabled(!installed.contains)`；侧栏项按 `sidebarExpanded`
  取「显示/隐藏侧栏」真实标题。
- **单轨菜单**：[GatherAppDelegate.swift](../../desktop/native/gather-app/Sources/GatherHost/GatherAppDelegate.swift)
  删除 `installMenu`、`ensureStandardMenus`、AppKit File/Edit 构建与全部菜单
  selector；菜单只由 SwiftUI `.commands` 提供。实测 `NSApp.mainMenu` 为
  App/File/Edit/View/Window/Help 六项，File 含 3 个命令 + 系统 Close。
- **入口去通知**：导入与 C1 改走
  [RootShellDependencies.swift](../../desktop/native/gather-app/Sources/GatherUI/Support/RootShellDependencies.swift)
  的 `importFiles / chooseImportFolder / captureOneImport` typed 闭包；
  删除 `menuNewWorkspace`、`menuImportFolder`、`menuToggleSidebar`、
  `menuOpenSettings`、`captureOneImportRequest` 五个通知名。
- **单窗口**：[GatherApp.swift](../../desktop/native/gather-app/Sources/GatherApp/GatherApp.swift)
  由 `WindowGroup` 改为 `Window("Gather", id: "main")`，命令中心与菜单 handler
  不再有「第二个窗口共享/覆盖」的未定义状态。

## 2. 检查器共享（审查 §4-3）

新增 [GatherInspectorSection.swift](../../desktop/native/gather-app/Sources/GatherUI/DesignSystem/Patterns/GatherInspectorSection.swift)：
标题（可选 SF Symbol / 副标题）+ 内容 + 统一卡片。迁移：

- Gallery 检查器 2 个分区；
- Library 4 张管理卡；
- Culling 5 个分区（当前照片/筛选/相似组/选择管理/统计）。

## 3. focused-scope 撤销/重做（审查 §4-6）

- 新增 [CullingHistoryActions.swift](../../desktop/native/gather-app/Sources/GatherUI/Interaction/CullingHistoryActions.swift)：
  `cullingHistory` focused value + `sidebarExpanded` + `commandAvailability`。
- [CullingView.swift](../../desktop/native/gather-app/Sources/GatherUI/Culling/CullingView.swift)
  在页面可见时注入自建历史栈；`.commands` 只在 `cullingHistory != nil` 时
  `CommandGroup(replacing: .undoRedo)`，其他页面/文本框仍走系统 UndoManager。
- [CullingToolbar.swift](../../desktop/native/gather-app/Sources/GatherUI/Culling/CullingToolbar.swift)
  删除按钮上重复的 ⌘Z/⇧⌘Z（菜单成为唯一快捷键来源）。

## 4. 真实挂载可见性测试（审查 §4-4）

[WorkspaceVisibilityTests.swift](../../desktop/native/gather-app/Tests/GatherAppTests/WorkspaceVisibilityTests.swift)
新增 `mountedSessionPageDrivesPageVisibility`：`NSApplication.shared` + 真实
`NSWindow` + `NSHostingView(GatherSessionPage)`，挂载后
`gallery.isVisible == true`，从窗口移除 contentView 后 `false`。
上一轮 SIGSEGV 的根因是测试进程未初始化 NSApplication；本地修复后稳定通过。

## 5. 截图矩阵（审查 §4-5）

- [english-library.png](assets/appearance-m2-m4/english-library.png)：英文界面 +
  检查器 4 张共享卡片（`--ui-language en`，scene 发布后设置）。
- [data-gallery.png](assets/appearance-m2-m4/data-gallery.png)：隔离库导入 4 张
  样例照片后的图库（页签/工具栏/网格/文件名为真实数据）。
- 截图仍由 `screencapture -l <windowID>` 生成，未做人工点击验收。

## 6. WP7 与构建

- [Package.swift](../../desktop/native/gather-app/Package.swift) 恢复
  **manifest 纯声明**（只读 `GATHER_SDK_VERSION`，不执行 `xcrun`/`Process`）；
  SDK 探测回到 `build.sh`（`--manifest-cache none` 保证重链）。
- `build.sh` 实测：`SDK version ... 27.0 (source: xcrun)`；
  `vtool -show-build` 的 app 与 GatherLink 均为 `minos 14.0 / sdk 27.0`。
- `GATHER_ARCHS=universal`：app 与 C1 插件均为 `x86_64 arm64` fat 产物。
  插件切片此前会因 `swiftc` 模块缓存落在不可写的系统临时目录而静默复用上一
  架构；`build.sh` 现在把 `TMPDIR`/`CLANG_MODULE_CACHE_PATH` 固定到输出
  目录，两个切片都真实重编译（`lipo -info` 实测）。

## 7. 验证（本机实测）

| 检查 | 结果 |
| --- | --- |
| gather-core `swift test` | **1171 tests / 176 suites，exit 0**；3 条 fixture skip |
| gather-app `swift test --no-parallel` | **641 tests / 72 suites，exit 0** |
| app 连续压力复跑 | 20 次全绿（首轮 1 次失败为与 core 编译并行的负载偶发，未复现） |
| `./desktop/native/build.sh` | exit 0；arm64、未签名（默认） |
| 签名构建（Developer ID Application） | exit 0；`codesign --verify --deep --strict` 通过（hardened runtime） |
| `GATHER_ARCHS=universal` | exit 0；x86_64 + arm64（app + 插件） |
| 门禁 | 10 个 `check-*.sh` + CI 的 `--strict` 变体全绿 |
| 菜单结构 | SwiftUI 主菜单含 File/Edit/View/Window/Help；删除 AppKit 兜底后不变 |

## 8. 本机无法产生的外部证据

- 公证/安装升级：本机无 notarytool 凭据（keychain 无 profile），只能签名不能公证；
  分发包因此仍是 signed-but-not-notarized。
- 人工点击流程（页签/返回/菜单禁用态）与真实 Capture One 联动：本机辅助功能
  自动化不可用；菜单禁用态由 `installed` 单测 + focused-scope 代码路径覆盖，
  未做鼠标级验收。
- x86_64 仅完成编译与 fat 打包，未在 Intel 机器运行。
