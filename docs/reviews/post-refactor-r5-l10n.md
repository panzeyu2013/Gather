# Cut 4b 全量本地化正确性评审（post-refactor R5 / L10n）

> 只读评审。评审对象：`desktop/native/gather-app` 的 Cut 4b 本地化（en/zh 表、l10n 调用、语言切换、错误码文案）。
> 本报告只写这一个文件；源码/资源/测试/Package/脚本均未改动。
> 评审时间：2026-10-22。结论以当前工作树为准（HEAD 之后有大量未提交改动，已按工作树核对）。

## 1. 范围与方法

- **表**：`Sources/GatherUI/Resources/en.lproj/Localizable.strings`（1,313 键 / 1,391 行）、`zh-Hans.lproj/Localizable.strings`（9 键 / 11 行）；无 `.stringsdict`。
- **代码**：`GatherUI/Support/{GatherLocalization,L10n,LocalizedText,LanguageStore,NativeBanner,CommandError}.swift`，`GatherHost/{RootView,GatherAppDelegate,GatherAppCommands,RootShellOverlay,AppBootstrap}.swift`，全部页面的 `l10n`/`LocalizedText`/notice 调用点。
- **方法**：
  1. Python 解析两张 `.strings`，做键集合/重复/占位符（含 `%%`、`%lld`、`%d`、`%@`、长度修饰、位置参数）逐条比对；`plutil -lint` 通过。
  2. 自写 Swift 轻量扫描器（去注释、保留字符串）提取所有本地化调用点、动态 key、CJK 字面量；不依赖只读测试。
  3. 用 `git show HEAD:...` 取重构前 en 表（1,406 条/1,395 唯一键）与当前表做集合差，重算删除键；对每个删除键在当前 `Sources` 中查整段字面量、插值、拼接残留。
  4. 对照 `GatherErrorCode` 枚举（179）与 `errorMessages`（179）逐条核对，并检查 4 个参数化模板的生产者与 `orderedParams`。
  5. 静态走查语言切换链路（LanguageStore 写入口、SwiftUI Observation、AppKit 菜单、environment 注入、日期/数字 locale、Toast）。

---

## 2. 结论（先行）

- **P0：未发现**。静态范围内没有会导致崩溃/数据损坏/整页不可用的本地化缺陷；`L10n.render` 已把类型错配、裸 `%`、缺参收敛为安全路径。
- **P1：4 条已确认（第 4 条是测试门禁）**：
  1. 设置页人脸模型路径校验的**动态中文句子**在英文界面回退中文（真实用户可见）。
  2. 英文表**没有复数处理**（无 `.stringsdict`，至少 76 个计数模板只有复数形式，`1 photos`）。
  3. parity 测试**漏扫 3 类 Notice 包装器与三元分支**，整类 key 缺英文不会报红。
  4. CI 默认并行跑 app 测试（未加 `--no-parallel`）已实测 581/66 失败；另有本地化全局语言未加锁读点，门禁结果不可信。
- **P2：10 条**（分隔符、ByteCountFormatter 系统 locale、Toast 环境兜底、`INVALID_PARAM` 参数未展示、文档 94+31 口径、zh 表 9 条冗余条目、注释/`dynamicKey` 漂移、AppKit 菜单语言覆盖（疑似）、LiveSettingsAPI 广播契约、Settings 空值回退）。
- **已删除 94 键的静态证据：可靠**；但 `94+31` 是重复计数，实际是 6a-1 的 63 + 6a-2 的 31 = 94（详见 §7）。allowlist 只剩 1 条，属最小集合，但它是“只被测试引用”的 key，可再收。

---

## 3. P0

无。

说明：`L10n.render`（`Support/L10n.swift:364-406`）对 `%lld/%d/%f/%@` 按实参类型规范化，裸 `%` 转义为 `%%`，`*` 宽度直接放弃格式化；`CommandErrorText.resolve` 的本地校验分支只把 `%lld/%d` 归一为 `%@` 后调用 `String(format:)`（`Support/NativeBanner.swift:43-48`），现存本地校验 key 的转换符只有 `%@/%lld`（已逐条枚举），未发现可触发 `String(format:)` 崩溃的模板。

---

## 4. P1

### P1-1【已确认】设置页人脸模型路径校验：英文界面显示中文

**file:line**

- `Sources/GatherUI/Settings/SettingsViewModel+Fields.swift:74-82`（两个函数生成中文句子，路径直接插进字符串）
- 调用点：`SettingsViewModel+Fields.swift:37`、`:131`（`errorMessage = CommandError.localized(reason)`）
- 渲染：`Sources/GatherUI/Support/NativeBanner.swift:28-34`（`l10n.errorText(error)` → 未命中表 → `l10n(error.code)` 回退 key）
- 测试漏扫依据：`Tests/GatherAppTests/LocalizationParityTests.swift:79-160`（插值字面量被 `!interpolated` 排除）

**证据**

```swift
// SettingsViewModel+Fields.swift:74
static func faceEmbeddingModelNotFoundText(_ path: String) -> String {
    "人脸嵌入模型不存在：\(path)（支持 .mlmodel、.mlpackage 或 .mlmodelc；留空使用内置 SFace 身份模型）"
}
// :131
if key == Self.faceEmbeddingModelSettingKey, !raw.isEmpty,
   let reason = Self.faceEmbeddingModelPathError(raw) {
    errorMessage = CommandError.localized(reason)   // reason 是运行时中文长句
    return
}
```

`CommandError.localized(reason)` 把整句当 key；`reason` 含运行时路径，**不可能**在 en 表预置。`errorText` 先尝试 `errorMessages[reason]`（失败），再取第一个 ASCII 冒号（中文句子里是 `：`，通常没有 ASCII `:`），最终 `l10n(error.code)` 查表失败，原样返回中文。英文界面下用户选择不存在/扩展名错误的模型路径时，横幅显示中文。`faceEmbeddingUnsupportedFormatText` 同理。

**影响**：设置页唯一的人脸模型路径校验反馈在 en 下不可读；用户无法按提示修正。因路径是变量，单个 key 无法通过补 en 条目修复。

**修复建议**：让校验返回结构化结果（码/枚举/固定 key + 参数），渲染期用 `LocalizedText("人脸嵌入模型不存在：%@（支持 .mlmodel、.mlpackage 或 .mlmodelc；留空使用内置 SFace 身份模型）", params: [path])`，并补 en 条目；同步改 `SettingsSaveSemanticsTests` 对 core `FaceEmbeddingError.description` 的逐字断言（可改为断言固定模板 + 参数）。

### P1-2【已确认】英文无复数处理：76 个计数模板只有复数形式

**file:line**

- `Sources/GatherUI/Support/L10n.swift:213-215`（`format` → `formatted`）、`:234-242`（`Bundle.localizedString(forKey:value:table:)`，无 count/plural 参数）
- 资源目录只有 `en.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings`，**无 `.stringsdict`**（`find Sources/GatherUI/Resources -type f`）。
- 样例：`en.lproj/Localizable.strings:681` `"%lld 张照片" = "%lld photos"`；:563 `"写回队列：%d 项" = "Writeback Queue: %d Items"`；:758 `"第 %lld–%lld 张" = "Photos %lld–%lld"`；:666 `"%@ · %lld 张照片" = "%@ · %lld photos"`。调用点如 `C1StatusCapsule.swift:303`（queue=1）、`PersonsView.swift:222`（1 张照片 / 1 个工作区）会直接产出 “1 Items”“1 photos”“1 workspaces”。

**证据**：`L10n.format` 直接把本地化后的字符串交给 `String(format:)`（`L10n.swift:405`），没有 `String.localizedStringWithFormat` / `String(localized:)` 的 plural 选择；en 表所有计数模板只写了一个复数名词。全表 76 条 `%lld/%d` 计数模板全部如此（脚本统计，含 `%lld files`、`%lld items`、`%lld groups`、`%lld members` 等）。当 count=1 时英文界面显示 “1 photos”“1 Items”“1 files”。

**影响**：英文用户在所有计数位置看到系统性语法错误；尤其导出预览、XMP 队列、人脸样本、重复组等高频页面。不是崩溃，但属于本地化正确性缺陷，且无法靠逐条改 en 文案解决（英文单复数取决于运行时数值）。

**修复建议**：为计数 key 增加 `.stringsdict`（或 `String(localized:)` + `%#@…@`），在 `L10n` 增加 `format(key, count:)` 走 plural 查表；调用点把 `l10n.format("%lld 张照片", n)` 改为 plural 入口。parity 测试需同时校验 stringsdict 的 one/other 变体。

### P1-3【已确认】parity 测试漏扫 Notice 包装器与三元分支，整类 key 缺英文不会报红

**file:line**

- `Tests/GatherAppTests/LocalizationParityTests.swift:72`（`callPattern` 只含 `GatherLocalization.l|l10n.format|l10n|LocalizedText|l|CommandError.localized`）
- `:79-160`（`scannedLiteralKeys`：遇到第一个字符串后无条件 `isFirstArgument = false`，三元第二分支不收集；`:135` 即该赋值）
- `:247-256`（`englishTableCoversEveryUsedKey` 只检查 `usedKeys()`）
- `:306-312`（`englishTableDoesNotFallBackToChinese` 同样只遍历 `usedKeys()`）

**证据**

1. `CullingNotice` / `FaceNotice` / `SimilarityNotice` 都是 `LocalizedText` 的轻包装（如 `Culling/CullingNotice.swift:28`、`FaceKeywording/FaceNotice.swift:22`），但不在 `callPattern` 中。当前 Sources 中这 3 类包装器共有 **53 个 CJK 字面量**（含重复；脚本统计；例如 `CullingViewModel+Writeback.swift:170` “已完成元数据同步（%lld 项已确认加载）”、`FaceKeywordingViewModel+Writeback.swift:67` “已写回 %lld 项；请先让 Capture One 重新加载元数据”）。它们不会进入 `usedKeys()`，因此：
   - en 表缺这些 key 时，`englishTableCoversEveryUsedKey` 不会报红；
   - `englishTableDoesNotFallBackToChinese` 也不会报红（key 不在 usedKeys）。
   我逐条核对了当前这 53 个字面量，**目前都在 en 表**，所以是“测试保证缺口”而非现存文案缺失；但这类 notice 是主要用户反馈面，下一次新增 notice 漏翻会被静默放过。
2. 三元第一实参：`GatherAppDelegate.swift:420` `l10n(sidebarVisible ? "隐藏侧栏" : "显示侧栏")`；扫描器收集第一个字面量后把 `isFirstArgument` 置 false，第二分支 “显示侧栏” 不进 key 集合。类似 `LibraryView+Support.swift:168` 的三元（“将拆分…”/“将拒绝…”）只收集第一支。当前两支都在表里（我另行全量扫描确认），但缺第二支时测试不会发现。
3. 运行时变量 key 完全不在扫描范围（测试注释已承认；`SettingsViewModel+Fields.swift:37/131` 的 `reason` 即此类），与 P1-1 是同一个洞。

**影响**：parity 测试对“Notice 全部 key”“三元第二分支”“动态 key”三类不设防；当前恰好齐全，但无法证明“代码在用 key ⊆ en 表”这一承诺，属于测试有效性 P1（Cut 4b 的验收依赖它）。

**修复建议**：`callPattern` 增加三种 Notice；收集三元全部字符串字面量（不要把第一个字符串当成实参结束）；对已知动态 key 目录（Settings 已枚举）补 `l10n(variable)` 白名单/反向断言；或把 key 常量集中到可扫描的静态表，禁止裸字符串直接进 `LocalizedText`。

### P1-4【已确认，测试门禁】CI 默认并行跑 app 测试失败；另有本地化全局语言未加锁读点

**file:line**

- `.github/workflows/ci.yml:87`：`swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`（无 `--no-parallel`）
- 全局语言：`Support/GatherLocalization.swift:409-412`（进程级 `appLanguage`），`LanguageStore.set/seed` 会写它（`LanguageStore.swift:73/90/115`）
- 未持锁读点：`Tests/GatherAppTests/APIPhotoTests.swift:349`（`GatherLocalization.errorText("ALBUM_NOT_FOUND")` 在 `AppLanguageLock` 外）；`GlobalInfraTests.swift:94-119` 在锁内临时切 en；`LanguageStoreTests` 也在锁内切 en。
- `AppLanguageLock`（`Tests/GatherAppTests/Support/AppLanguageLock.swift`）是协作式 NSLock，只保护“主动使用它”的用例；`APIPhotoTests:349` 这类读点不在锁内，仍会与并行套件的临时切换竞争。

**证据/状态（本轮实测）**：2026-10-22 在同一 `.build/scratch` 上运行不带 `--no-parallel` 的全量 app 测试，**exit 1**，输出 `Test run with 581 tests in 66 suites failed`，失败项为 `4a-2b：setVisible 启停兜底轮询（幂等），shutdown 后不复活`（2.779s，1 issue）。该用例是轮询时序测试而非本地化断言——说明默认并行下整套 app 门禁已在**非本地化**用例上失败，不能作为 L10n 验收证据。同一用例单独跑 `--filter setVisibleStopsPollingDefersEventsAndShutdownSticks` 为 1 test / 1 suite、1.379s、exit 0；全量加 `--no-parallel` 为 **581 tests / 66 suites、13.008s、exit 0**。说明是默认并行负载下的时序 flake，不是确定性本地化回归；但 CI 默认配置仍红。另用 `--filter 'LocalizationParityTests|LanguageStoreTests|GatherLocalizationTests|APIPhotoTests'` 单独跑 30 tests / 4 suites 为 exit 0。静态竞争面（`APIPhotoTests:349` 未持锁读全局）仍成立，只是本轮全量失败先发生在时序用例上。

**影响**：CI 的 app job 在当前配置下红；本地化 parity、错误文案断言的全量结果不可作为 Cut 4b 验收证据。也意味着“app 581/66 绿”的台账数字只在 `--no-parallel` 下成立。

**修复建议**：CI 的 app `swift test` 加 `--no-parallel`（与台账口径一致）；中期把 `GatherLocalization.appLanguage` 从测试可达的进程全局改为显式注入，删掉 `AppLanguageLock` 依赖。

---

## 5. P2

### P2-1【已确认】中文枚举分隔符进入英文界面

- `Sources/GatherHost/AppImport.swift:121`：失败示例 `.joined(separator: "、")`，经 `RootShellOverlay.swift:65` 的 en 模板 `"%lld photos imported; %@ read failed: %@%@"` 上屏，英文界面出现 “a、b、c”。
- `Sources/GatherUI/Library/LibraryView+Support.swift:261`：卷根路径 `.joined(separator: "、")` 直接 `Text(...)`。
- `Sources/GatherUI/Dashboard/DashboardViewModel+Actions.swift:268`、`CullingViewModel+Writeback.swift:45/70` 的 `"、"`/`"；"` 也会进入英文提示/诊断。
- 影响：英文界面标点不统一；不阻断功能。修复：分隔符也走 `l10n("、")`（en 表已有 `"、" = ", "`），或按语言选择 `", "` / `"; "`。

### P2-2【已确认】ByteCountFormatter 跟随系统 locale，不跟界面语言

- `Sources/GatherUI/Export/ExportView+Preview.swift:18/21/66`：`ByteCountFormatter.string(fromByteCount:countStyle:)` 无 locale 参数。
- 影响：界面语言 en、系统区域非 en 时，文件大小单位/分组可能按系统区域显示，与页面其他数字（`l10n.locale`）不一致。Settings/Persons 的日期已正确改用 `l10n.locale`（`PersonsView.swift:490-499`、`SettingsViewModel+Sync.swift:81-84`），此处是残余。修复：用 `ByteCountFormatter` 实例并设 `locale = l10n.locale`，或统一数字格式化入口。

### P2-3【已确认】Toast 在事件点解析为 String，切语言后已显示的 Toast 不刷新；ToastView 的关闭按钮还在 environment 外

- `Sources/GatherUI/Support/GatherToast.swift:30-51`：`ToastItem.message: String`，`show` 时已渲染；切语言后已显示的 5s Toast 保持旧语言。
- `Sources/GatherHost/RootView.swift:99` 只对 `detail` 注入 `\.languageStore`；`:131-134` 的 `.overlay { ToastView() }` 挂在 `NavigationSplitView` 外层，ToastView 读不到 store，`GatherToast.swift:138` 回退固定 `zhCN`，英文界面下关闭按钮 tooltip/accessibility 仍是中文。
- 影响：瞬时提示的旧语言残留 + 关闭按钮文案错误；低危。修复：Toast 存 `LocalizedText` 或把 overlay 放进注入 environment 的子树；至少给 ToastView 显式传 `L10n`。

### P2-4【已确认】`INVALID_PARAM` 的 field/reason 参数从未展示

- `GatherLocalization.swift:73`：`"INVALID_PARAM": "参数无效，请检查输入。"`（无占位符）；`GatherError.invalidParameter`（`GatherError.swift:47-53`）固定带 `field/reason`，`CommandError.orderedParams` 也会保留，但模板不插值，UI 只显示通用句。
- 影响：用户不知道哪个字段无效；与 `GatherError` 注释“params 只存可上屏、可插值的字段”不一致。修复：模板改为 `"参数无效：{{field}}"` 或按码/字段细分文案，并补 en。

### P2-5【已确认，文档口径】“94+31”重复计数

- `docs/refactor-progress.md:163-164`：6a-1 删 63 en + 1 zh；6a-2 删 31 孤儿；合计 94 en。`docs/final-report.md:134` 也写 94。
- 本报告用 `git show HEAD:.../en.lproj/Localizable.strings` 与当前表实测：旧 1,406 条（1,395 唯一）→ 新 1,313 唯一，**删除 94 个唯一键**。台账的 1,407 基线 = 1,395 + 4b 新增 12；6a-1 63 + 6a-2 31 = 94，1,407 − 94 = 1,313。任务书“94+31”若指两批，应是 63+31；若指总量，31 已被 94 包含。
- 影响：台账数字会让后续审计误以为删了 125 个 key。建议改为“6a-1 63 + 6a-2 31 = 94”。

### P2-6【已确认】zh 表 9 条 key=value 冗余条目

- `zh-Hans.lproj/Localizable.strings` 9 条均为 `"X" = "X";`（长句/模型说明）。按“zh 表留空、key 即中文”的约定这些条目无功能作用，只增加维护面；当前与 en 表键一致、无重复。可删（Cut 6 保留可能是为了占位/说明）。不影响正确性。

### P2-7【已确认，注释/API 漂移】源码计数注释未随 179 更新；`dynamicKey` 入口零使用

- `Sources/GatherUI/Support/GatherLocalization.swift:62` 仍写“错误码 → 中文文案（error.* 键，156 项）”，实际 179；`Tests/GatherAppTests/LocalizationParityTests.swift:331` 注释仍写“177 个码”，实际 179。D-163 只改了 L10n.swift 的 177/1,407，漏了这两处。
- `LocalizedText(dynamicKey:)`（`Support/LocalizedText.swift:31`）在 Sources 中 **0 调用点**（仅测试 `L10nFormatTests` 使用）；4b-2 注释声称用独立标签让 parity 区分动态 key，但实际没有任何调用使用它，静态扫描仍无法分辨。
- 影响：不影响运行时，但会让后续审计/扫描误判覆盖规模。修复：改注释为 179，或删掉未使用的 `dynamicKey` 入口（或真正用于 Settings/菜单动态 key）。

### P2-8【疑似】AppKit 完整菜单与 SwiftUI 标准菜单的语言覆盖不确定

- `GatherAppDelegate.installMenu` 构建完整 AppKit 菜单（文件/编辑/显示/窗口/帮助，均走 `l10n`），但 `languageChanged` 的 `rebuildMenu` 只调用 `ensureStandardMenus`（只补/重建 File/Edit 注入项），不会重跑 `installMenu`（`GatherAppDelegate.swift:186-205`、`:293-449`）。
- 按代码注释（N08）SwiftUI 会用自己构建的主菜单替换 `NSApp.mainMenu`，实际生效的是 `GatherAppCommands`，它只替换 newItem/sidebar/help 三组；Edit/View/Window/Help 的标准项由系统本地化，跟**系统语言**而不是 `LanguageStore`。若 AppKit 菜单在某些系统版本存活，则 View/Window/Help 会停在旧语言（`languageChanged` 不重建）。
- 影响：中英切换后菜单可能中英混排；无 GUI 无法判定实际走哪条路径，故标“疑似”。修复：统一由一个菜单构建方按 `LanguageStore` 重建完整菜单，或在 SwiftUI 侧显式替换标准菜单组。

### P2-9【已确认】LiveSettingsAPI 的 languageChanged 广播不带 userInfo，LanguageStore 的“外部采纳”路径实际失效

- `GatherHost/APIs/LiveSettingsAPI.swift:72-78` 投递 `NotificationCenter.post(name: languageChanged, object: language.rawValue)`，**没有 userInfo**；`LanguageStore.swift:47-62` 的观察者只从 `userInfo[notificationLanguageKey]` 取语言，取不到就退回 `GatherLocalization.appLanguage`（`adoptNotification` `:109-111`），而此时全局仍是旧语言 → 采纳为 no-op。
- 当前设置页仍能切换，是因为 `SettingsViewModel+Loading.swift:66-67` 在 API 返回后显式调用 `languageStore.set(applied)`，由第二次带 userInfo 的广播完成状态更新；`DashboardView.swift:114-118` 也会从 `notification.object` 读语言并调 `store.set(rawLanguage:)`，但仅在**工作台可见**时生效。两者都是对 store 的补写，API 广播的“唯一入口”契约没有闭合；若未来有调用方只调 `settingsAPI.setLanguage` 且工作台不可见（或测试只依赖该广播），语言不会变。`APISessionTests.settingsSetLanguage` 只断言 object，未断言 store 采纳，故测试也漏。
- 影响：潜在的语言切换失效/菜单慢一拍；当前生产路径被 SettingsViewModel 兜住，列为 P2。修复：广播统一带 `userInfo: [notificationLanguageKey: rawValue]`，或 LanguageStore 同时读取 `notification.object as? String`；补“仅经 API 广播后 store.language 已变”的测试。

### P2-10【已确认】Settings 语言选择的空值回退硬编码 zh-CN，与 LanguageStore 的系统语言默认不一致

- `SettingsViewModel+Loading.swift:30` 与 `:138`（reset 后）都把空的 `ui_language` 回退为 `"zh-CN"`；`SettingsViewModel.swift:29` 的初始值也是 `"zh-CN"`。
- 冷启动时 `ui_language` 默认是空串（`SettingsService.swift:91`），`AppBootstrap` 只在非空时 `languageStore.seed`（`AppBootstrap.swift:169-171`），因此英文 macOS + 全新数据库的实际界面是 en（LanguageStore 系统检测），但设置页 Picker 显示“简体中文”。
- 影响：语言选择器与真实界面语言不一致；用户可能误判当前语言，或首次选择时才落库。修复：空值回退 `languageStore.language.rawValue`（或 bootstrap 时把系统检测值写入 `ui_language`），并补“空 ui_language + en 系统”的用例。

---

## 6. 错误码 179 文案覆盖 / 参数插值 / 回退（核对结果）

- **数量**：`GatherErrorCode` 枚举 179 个 case（`gather-core/Sources/GatherProtocol/Protocol/Core.swift:366`），`GatherLocalization.errorMessages` 179 条唯一键（`GatherLocalization.swift:63-246`），双向差集为空；en 表覆盖全部 179 条中文模板（脚本逐条比对，0 缺失）。
- **参数化模板**：仅 4 条带 `{{}}`：`XMP_CONFIRM_OTHER_SESSION_PENDING`（session）、`CULLING_REVISION_CONFLICT`（expected/current）、`FILTER_FIELD_UNKNOWN`（field）、`FILTER_SCHEMA_UNSUPPORTED`（version）。en 条目占位符序列与中文一致（en 表 :931/:981/:982/:996）。
- **顺序**：`CULLING_REVISION_CONFLICT` 生产者用 `expectedRevision/currentRevision`（`LiveCullingAPI.swift:262-268`），`CommandError.orderedParams` 按前缀 `expected/current` 命中，顺序正确；`FILTER_FIELD_UNKNOWN` 生产者带 `field`（`LivePhotoAPI.swift:276-277`、`AppServices.swift:288-289`），单参数正确；`XMP_CONFIRM_OTHER_SESSION_PENDING` 走 `DeliveryError.description` 的 `CODE: sessionId` 单冒号分支（`DeliveryError.swift:111`），`resolvedTemplate` 取 tail 插值，正确。
- **回退**：未知码/空码走 `unknownErrorKey`（en 表已收录，en 表 :830 “Something went wrong. Please try again later.”）；`jobErrorMessage` 非码走通用回退；`CommandErrorText` 的 API 散文只进 diagnostic，不上屏（`NativeBanner.swift:29-33` 政策正确）。
- **残余**：`APIErrorPresentation.message(for: GatherError)` 只传 `code.rawValue`、不传 `params`（`APIErrorPresentation.swift:24-26`），若未来启动路径抛参数化 `GatherError` 会显示空占位符；当前仅 `AppBootstrap.swift:96` 使用，未命中参数化码，属潜在 P2。

---

## 7. 已删除 94 键的静态证据与 allowlist

### 7.1 重算

- 旧表（HEAD，`desktop/native/gather-app/Resources/en.lproj/Localizable.strings`）：1,406 条 / 1,395 唯一键。
- 当前表：1,313 条 / 1,313 唯一键。
- 集合差：**删除 94 个唯一键**、新增 12 个键（`Embedded`、`XMP Sidecar`、`其中 %lld 项存在问题…` 等）。台账的 1,407 基线 = HEAD 唯一 1,395 + 4b 期间新增 12；1,407 − 63（6a-1）− 31（6a-2）= 1,313，与实测闭合。
- zh 表：旧 10 键 → 新 9 键，删除 1 个孤儿（`未找到可用的人脸身份模型`），与台账“63 en + 1 zh”一致。

### 7.2 删除键是否仍有运行时引用

我对 94 个删除键逐个在当前 `Sources` 中检索（去注释）：

- **整段字面量命中：0**；
- **插值字面量（去掉 `\(...)` 后完全相等）：0**；
- 命中的 151 行全部是更长文案的**子串**（如删除键 “完成” 出现在 “已完成/完成同步” 中）或错误码表/注释，不构成 key。
- 结论：现有静态证据（`sourceLiteralKeys` 整段字面量比对）对**这些键**是可靠的；94 个 key 删除后没有发现通过拼接/插值继续查表的残留。

### 7.3 allowlist 最小性

- `LocalizationParityTests.swift:229`：`testPinnedOrphans = ["检测模型路径"]`，仅 1 条；`:259-279` 断言 allowlist 仍在表、且 Sources 不得再出现该字面量。
- `检测模型路径` 只在 `Tests/GatherAppTests/SettingsSaveSemanticsTests.swift:284` 构造 `SettingField` 时使用，生产 Sources 无引用；保留它是“测试钉英文值”的最小例外。**从集合角度是最小 allowlist**；但严格说该 key 已无产品用途，可改写测试、删 key，allowlist 归零（P2 建议，不影响本轮验收）。
- 风险：`sourceLiteralKeys` 只收整段字面量，跳过含 `\(...)` 的插值字符串；94 个删除键本次未踩中，但方法本身对“插值 key”不设防（与 P1-3 同源）。

---

## 8. 语言切换链路核对（唯一入口 / 菜单 / root / locale / Toast）

- **唯一写入口：已确认**。`Sources` 中 `GatherLocalization.setAppLanguage` 的调用只在 `LanguageStore.swift:73/90/115`；`LiveSettingsAPI.setLanguage` 只持久化 + 广播（`LiveSettingsAPI.swift:58-80`），不再写全局；`SettingsViewModel.setLanguage` 最终调 `languageStore.set`（`SettingsViewModel+Loading.swift:55-74`）。API 广播理论上由 LanguageStore 采纳，但 `LiveSettingsAPI` 的广播不带 userInfo（P2-9），实际由设置页随后的显式 `set` 与 DashboardView 的 `notification.object` 桥接兜住；`LanguageStore.set` 仍是唯一状态写 API，但广播采纳路径未真正收敛。
- **SwiftUI / root 重建：已确认无 `.id(languageVersion)`**。`RootView.swift:99` 把 store 注入 detail 环境；页面用 `@Environment(\.languageStore)` + 计算属性 `l10n`，渲染期读 `store.l10n` 建立 Observation 依赖。`GatherApp.swift:27-35` 读 `bootstrap.languageStore.language/l10n` 驱动 Scene body 与 `.commands` 重建。
- **AppKit 菜单：基本已确认**。`GatherAppDelegate.languageStore.didSet` 立刻 `ensureStandardMenus`（`GatherAppDelegate.swift:124-130`）；`languageChanged` 观察者延后一轮重建（`:186-205`）；菜单标题在构建/触发时取 `l10n`。SwiftUI Commands 由 `GatherApp` body 重建。存在语义探针避免双语菜单叠加（`:244-252`）。
- **日期/数字 locale**：Settings `dateText`（`SettingsViewModel+Sync.swift:81-84`）、Persons `dateText`（`PersonsView.swift:490-499`）、Dashboard（`SessionRowView.swift:172-177`）均用 `l10n.locale`；en 下分别输出 en_US medium/short、yMd。残余是 ByteCountFormatter（P2-2）。
- **Toast/通知**：事件发生时用 `languageStore.l10n` 解析（`RootShellOverlay.swift:55/65/76`），切语言后的下一次事件用新语言；已显示 Toast 不刷新（P2-3）。无障碍公告文本也是事件点 String。
- **兜底**：所有页面 `languageStore?.l10n ?? L10n(language: .zhCN)`；这是固定 zh 兜底，不读进程全局，符合 4a 决策；代价是脱离 RootView 的视图（如 P2-3 的 ToastView）会落到中文。

---

## 9. 表质量逐项结果

- **键覆盖**：en 表 1,313 键；代码侧（字面量 + 动态目录 + 错误码表）逐条核对，缺项仅 `%.2f`（机器格式）与两个错误码（按码表渲染，不是 `.strings` key），无真实缺英文条目。
- **重复**：en 唯一键 1,313/1,313，无重复；zh 9/9，无重复。旧表的 11 条重复已在 4b-1 删除，当前无“后写覆盖”。
- **冲突**：3 条裁决值固定且与测试一致（`星级 = Star Rating`、`存在 XMP 冲突，请先裁决`、`有写入失败项，请先重试`）；未发现同 key 多译。
- **占位符**：逐条比较 key/en value 的 `%@/%d/%lld/%f/%%` 序列，**0 处不一致**；无位置参数（`%1$@`）、无 `%s/%c/%p`、无 `*` 宽度。`plutil -lint` 两文件均 OK。
- **en 残留中文**：en value 的 CJK 字符 **0**；en key 即中文（约定），不是残留。
- **复数/stringsdict**：见 P1-2；无 `.stringsdict`。
- **调用点实参**：对 1,250 个首参为字面量的 `l10n`/`l10n.format` 调用做括号内顶层实参计数，与模板转换符数量 **0 不一致**；对 `LocalizedText`/Notice/`CommandError.localized` 的 `params` 计数同样 **0 不一致**。
- **直接 `String(format:)` 残余**：Sources 中非注释调用 18 行；生产 UI 的 4 处是纯数字格式（`SettingsViewModel+Fields.swift:145`、`SettingsViewModel+Loading.swift:50`、`PersonsView.swift:345` 的 `%.2f`，`FaceMemberRow.swift:21` 的 `%.0f%%`），`AppImport.swift:195` 分钟补零、`ThumbnailDiskCache.swift:78` 哈希、PreviewFixtures 8 处是机器/样例格式；`GatherLocalization.swift:324` 的 `cancellationNotice` 已无生产调用（仅测试/parity），但仍用旧全局 `l()` + `String(format:)`。**未发现用 `String(format:)` 直接格式化本地化模板的生产调用**（旧 1,481 处 codemod 目标已清零）。
- **未包装 CJK 字面量**：扫描 Sources 后，剩余 CJK 集中为 Settings 目录的 `zhLabel/zhDesc` 动态 key、Preview 样例数据、注释/诊断、分隔符（P2-1）和 P1-1 的动态句子；未发现 `Text/Button/Label/Menu` 直接写死中文的未本地化字面量。
- **格式说明符与实参类型/顺序**：`L10n.format` 按实参类型规范化（String+数值 → `%@`；Int+数值 → `%lld`；Float 保留精度），现存调用点未发现 `%f` 配 String 等危险组合；`CommandErrorText` 的本地校验分支已逐条枚举，只有 `%@/%lld`。顺序由模板出现顺序 + `orderedParams` 前缀匹配保证，4 个参数化错误码顺序正确。

---

## 10. 残余 / 未覆盖

- 未做 GUI 目视/A-B（环境无 GUI 自动化）；本报告所有“英文界面显示 X”均为静态代码路径推演，未截图。
- 未串行重跑全量 app 581/66；默认并行全量实测 581/66 **失败**（P1-4）。若需最终验收，应以 `--no-parallel` 重跑并把精确数字写回台账。
- 未验证 `Bundle.module` 在大小写敏感文件系统上查找 `zh-hans`（源码目录是 `zh-Hans`）的行为；macOS 默认 APFS 不区分大小写，CI 也是 macOS，暂列疑似 P2，不计入正式发现。
- `L10n` 缓存上限 4096、负缓存、锁内 `make` 已审；未发现正确性问题。

---

## 11. 已确认 vs 疑似（汇总）

- **已确认**：P1-1（设置页动态中文回退）、P1-2（无复数）、P1-3（parity 漏扫，含实测 53 个 notice 字面量当前齐全）、P1-4（默认并行 581/66 失败，串行 581/66 通过）、P2-1/P2-2/P2-3/P2-4/P2-5/P2-6/P2-7/P2-9/P2-10。
- **疑似**：P2-8（AppKit/SwiftUI 菜单实际由哪套构建方生效，缺 GUI 无法判定）；另 `Bundle.module` 在大小写敏感文件系统查找 `zh-hans` 的行为未验证（仅记录，不计正式发现）。
- **P0**：无。

---

## 12. 最终结论

Cut 4b 的**主体迁移是成立的**：en 表无重复、无占位符错配、无英文残留中文；179 错误码全覆盖且 4 个参数化模板顺序正确；LanguageStore 是唯一写入口，root 不再靠 `.id` 重建，菜单/日期 locale 基本收口；94 个删除 key 的静态证据可复核且无残留引用。

但**不能判定“全量本地化完成”**：

1. 英文界面仍有一处真实中文（设置页模型路径校验，P1-1）；
2. 英文复数系统性缺失（P1-2）；
3. parity 测试对 Notice/三元/动态 key 漏扫，无法支撑“在用 key ⊆ en 表”的验收承诺（P1-3）；
4. CI 默认并行导致本地化测试证据不可信（P1-4）。

建议：P1-1/P1-4 先修（用户可见 + 门禁可信）；P1-2/P1-3 作为 Cut 5 本地化收口（stringsdict + 扫描器）处理；P2 按页清扫。修完后用 `--no-parallel` 重跑 app，并把 en/zh、parity key 数、删除 key 口径写回 `docs/refactor-progress.md`。