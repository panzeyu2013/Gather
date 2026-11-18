# R3-compile：第三轮 Swift 编译风险系统审计（本地 main vs 上游 origin/main）

- **评审对象（committed 状态）**：HEAD `3486be0b`，即 `origin/main`（e5c54f37）..HEAD 的 **22 commits / 234 files / +11587−1165**，其中 **168 个改动 Swift 文件**。
- **本轮定位**：R3-1，最高优先级 = ① 独立复验 round-2 的 P0 修复（commit `5bcf915b`）在真实编译下是否正确、完整、无新编译问题；② 用新视角系统扫描全部改动 Swift 文件的编译风险（-parse 之外的访问级/标签/泛型/宏/并发/可用性/可变性）。
- **状态**：**完成**。本机可实现的最强证据已全部跑完并逐条记录。
- **环境上限**：Linux Ubuntu 22.04，无 macOS/Xcode/SDK；**未在 macOS 编译/测试**。可用：Swift 6.2（.gather/swift62）、SwiftPM、Foundation/Synchronization/Observation/Testing 的 Linux 模块、shellcheck、python3、git。
- **moving-target 声明**：本审计针对 **committed HEAD 3486be0b**。评审期间 lead 在工作区应用了 round-3 修复（7 个 Swift 文件 + 脚本/文档未提交修改），**不在本册结论范围内**，也未据此调整任何 HEAD 结论。

---

## 1. 结论摘要

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| **P0（编译中断/崩溃/数据丢失/安全）** | **0** | 未发现。round-2 的 4 个 P0 修复已用**真实 Swift 6.2 编译器**独立复验通过；对 168 个改动 Swift 文件的系统扫描未再暴露新的编译中断 |
| **P1（新行为回归/CI 必红）** | **0** | 未发现。CI gates job 在 HEAD 快照上 15/16 可执行门禁 PASS（第 16 个 `check-repo-hygiene` 在非 git 快照中按设计 FAIL，见 §5.6）；新增 CI 步骤（round-2 wiring）实跑通过 |
| **P2（风险/健壮性/最优性）** | **0** | 无可归入 P2 的编译类问题 |
| **P3（nit）** | **2** | 见 §2（均为注释/import 层级，不影响编译） |

**一句话**：**round-2 修复方向与实现均成立，且没有引入新的编译问题**；剩余编译风险只剩本机不可编译的 macOS 专属 target（AppKit/SwiftUI/CoreML/Vision 及其 View 层），需 macOS 首跑 `swift build`/`swift test`/`check-warnings.sh` 做最终确认（见 §5）。

---

## 2. Findings

| ID | 级别 | 位置 | 问题 | 证据 | 建议修复 | 置信度 | macOS 不可证 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R3C-01 | **P3** | `desktop/native/gather-core/Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:21` | round-2 修复（5bcf915b）新增注释写 **"round-6 评审（CORE-04/R2C-04）"**，但该仓库评审轮次是 round-1/2/3，此修复由第二轮评审触发；编号会误导后续检索/归档交叉引用 | `git log -1 -S 'round-6 评审' -- <file>` → `5bcf915b`（round-2 修复提交）；对照 round-2 归档 `docs/reviews/2026-11-18-local-changes-review-round2/R2-core.md` 的命名 R2C-04/CORE-04 | 改为 "round-2 评审（CORE-04/R2C-04）" | 高 | 否（文本） |
| R3C-02 | **P3** | `desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel.swift:9` | 文件用 `@Observable`（:14）但**没有 `import Observation`**，只 `import SwiftUI`（依赖 SwiftUI 对 Observation 的再导出）。origin/main 已如此（**非本轮 diff 引入**），当前可编译；但未来清理 "无用 SwiftUI import" 时会直接编译中断 | ① 该文件无任何 SwiftUI 符号（scratch 中把 `import SwiftUI` 换成 `import Observation` 后 CullingViewModel 全族真实 typecheck 通过，EXIT 0）；② `git show origin/main:<file> | grep import` 同样只有 SwiftUI；③ 同 target 的其他 `@Observable` 文件（如 GalleryViewModel.swift）都显式 `import Observation` | 显式加 `import Observation`（可保留 SwiftUI 若确有符号；本文件不需要） | 中（Darwin 的 SwiftUI 是否 re-export Observation 本机不可直接验证，但 "文件用 @Observable 而无 Observation import 仅靠 SwiftUI" 是事实） | 部分 |

> 说明：两条 P3 均不改变任何编译结论；未发现可归为 P0/P1/P2 的编译类问题。

---

## 3. round-2 P0 修复独立复验（真实编译器，非 -parse）

> 背景：round-2 发现 3 类 4 个 P0（DateFormatting 闭包标签、CullingViewModel 跨文件 private 读 ×2、JSONValueCodingTests `try` 在 `==` 右侧），在 `5bcf915b` 修复。以下逐项复验。

### 3.1 DateFormatting `withFormatter` 外部标签（R2-app P0-1 / R2-docs P0 / R2-tests P0）

- **修复后代码**：`Sources/GatherUI/Support/DateFormatting.swift:59`
  `private func withFormatter<T>(key: String, make: () -> DateFormatter, body: (DateFormatter) -> T) -> T`；
  4 个调用点（:77/:108/:120/:132）均为 `withFormatter(key: …) { … } body: { formatter in … }`（多尾随闭包第二个带 `body:` 标签，合法）。
- **证据**：`swiftc -typecheck -swift-version 6 <file>` → **EXIT 0**（该文件只 import Foundation，可独立编译；4 个调用点全部在编译单元内）。`-warnings-as-errors` 下同样 EXIT 0。
- **结论**：P0 修复成立，无新编译问题。

### 3.2 CullingViewModel 跨文件 private 读（R2-app P0-2 / P0-3）

- **修复后代码**：`CullingViewModel.swift:156` `@ObservationIgnored private(set) var pageAssignmentCount`，:322 `@ObservationIgnored private(set) var navigationGroupsVersion`；`+Preload.swift:188/196`、`+Navigation.swift:238/245` 只读。
- **证据 1（宏/访问级精确探针）**：把 @Observable + `@ObservationIgnored private(set)` + didSet `&+=` + **跨文件 extension 只读**逐字复刻为 Linux 探针（.gather/r3c/probe/obs_probe.swift + obs_probe_ext.swift），`swiftc -typecheck -swift-version 6` → **EXIT 0**（覆盖 `-parse` 看不到的宏展开/访问级规则）。
- **证据 2（真实文件整族 typecheck，强证据）**：把 **CullingViewModel.swift + 全部改动/同族扩展**（+Actions/+Grid/+Keywords/+Load/+Navigation/+Preload/+Triage/+Writeback、CullingViewStateStore）与同族真实支持文件（CullingNotice/CullingSelectionSnapshot/CullingFilterState/CullingSyncFlow/C1RoundTripPorts/CullingGroupDecision 等）放在 scratch，用**真实 GatherProtocol 模块**（SPM 构建）+ 精确 stub（仅未改动的 SwiftUI/AppKit 符号：NSEvent.ModifierFlags、NSImage、PhotoThumbnailCache、ThumbnailDiskCache、PhotoDetailTier、CullingGridDensity/CullingLayoutMode；签名照抄真实文件）+ 无关 infra stub（CommandError/L10n/GatherEventCenter）→ **EXIT 0，0 errors**；`-warnings-as-errors` 亦 EXIT 0。
- **证据 3（写侧）**：全仓 `grep` + private(set) 写扫描：两属性只在声明文件的 didSet 内 `&+=`，无跨文件写。
- **结论**：P0 修复成立，无新编译问题（且该头部注释与 round-2 记录一致）。

### 3.3 JSONValueCodingTests `try` 在 `==` 右侧（R2-tests P0）

- **修复后代码**（:127-133）：先 `let parsedBaseline = try JSONValue.parse(baseline)`，再 `#expect(parsedBaseline == value)`、`#expect(parsed == parsedBaseline)`；另加 `#expect(!cached.contains("\n"))` 守卫。
- **证据**：真实 SPM 构建的 `GatherProtocol`（debug，`-enable-testing`）+ 工具链自带 Swift Testing 模块：`swiftc -typecheck -swift-version 6 -I <Modules> Tests/.../JSONValueCodingTests.swift` → **EXIT 0**（`-warnings-as-errors` 也 0）。
- **规则侧证**：探针复现语法规则 —— `if 1 == try f()` 报 `'try' cannot appear to the right of a non-assignment operator`；`#expect(try f() == 2)` 合法；`x += try f()`、三元 `? try` 合法。
- **结论**：P0 修复成立。

### 3.4 `5bcf915b` 其余两处加固是否引入编译问题

| 改动 | 复验方式 | 结果 |
| --- | --- | --- |
| `SidecarXMPProvider+IPTCReading.swift:24` `withRegex<T>` 去掉 `T: Sendable` | 逐字复刻 `SidecarRegexCache`（含 `Mutex<[String: NSRegularExpression]>`）+ 真实文件的 **4 处调用形态**（labeled-tuple 数组上下文类型、`String?` 返回、`[(prefix: String, uri: String)]` guard、`[NSRange]` guard）→ `swiftc -typecheck -swift-version 6` | **EXIT 0**（`-warnings-as-errors` 也 0）。Linux 的 `Synchronization` 与 Darwin 同源实现，`Mutex.withLock` 不要求返回值 Sendable，Darwin `NSRange` 编译风险已解除 |
| `MetadataKeywordWriter.swift:132-151`（getBatch 失败回退逐行读） | 逐 API 核对：`MetadataRepository.get(_:) throws -> MetadataCacheRow?`（Ports/MetadataRepository.swift:10）、`getBatch(_:) throws -> [MetadataCacheRow]`（:11）、`MetadataCacheRepo.get`（:261）、`GatherLogger.log(_:level:)`（Protocol/Logging/Logger.swift:79）、`LogLevel.warn`（:6）；文件 imports 含 GatherProtocol/Persistence/Delivery | **API 级一致**；GatherApplication 依赖 Vision/CoreML/Analysis 无法在 Linux 整包 typecheck，故列为 "API 级核对通过、整包编译需 macOS"（§5） |
| `CullingService+Commands.swift:408-460` | diff 为**纯注释**修改；`getDecision(sessionId:photoId:)`（CullingDecisionRepo.swift:96）、`getByPhotoIds(sessionId:photoIds:)`（:118）、`updateState(...)`（CullingService+Commands.swift:13）均按现有签名调用 | **无代码变更引入** |

### 3.5 修复是否引入新编译问题（宏观）

- 修复涉及文件所在 target：`GatherProtocol` **真实 SPM 构建通过**（114 文件）；`GatherPersistence` **真实 SPM 构建通过**（245 编译单元，见 §4.2）；`GatherUI` 的两个改动族（Culling/Gallery ViewModel）**真实 typecheck 通过**；`GatherApplication`/`GatherMetadataIO` 用探针 + API 核对覆盖（§3.2/§3.4）。
- **结论**：round-2 修复**未引入新编译问题**（本机可证范围内），修复本身编译正确。

---

## 4. 全量编译风险扫描（168 个改动 Swift 文件）

### 4.1 语法面

- `swiftc -parse -enable-bare-slash-regex` **全仓 1090 个 Swift 文件 → 0 failures**（独立重跑，非沿用旧日志）。
- `git diff --check origin/main..HEAD` → 干净（exit 0）。

### 4.2 Linux 可构建部分的**真实模块构建**（Swift 6 严格并发 + warnings-as-errors）

| 模块 | 方式 | 结果 |
| --- | --- | --- |
| GatherProtocol（3 个改动文件：C1/Core/DescriptiveMetadata） | `swift build --target GatherProtocol`；再 `-Xswiftc -warnings-as-errors` | **成功 / EXIT 0** |
| GatherPersistence（22 个改动文件） | `swift build --target GatherPersistence` + **Linux `os` 模块精确 API shim**（仅 `OSAllocatedUnfairLock(initialState:)/uncheckedState:/withLock/withLockUnchecked/lock/unlock`，签名按 Darwin os.swiftinterface，实现 NSLock，仅 typecheck 用）；再 `-warnings-as-errors` | **成功 / EXIT 0**（`#if canImport(CryptoKit)` 在 Linux 走纯 Swift SHA256 分支；DB 改用 `import os` 是 Linux 不可用的唯一原因，已用精确 shim 解除） |
| SwiftPM manifests | `swift package dump-package` ×（gather-core, gather-app） | **OK**（core Package.swift 的 diff 仅补文件末尾换行） |

### 4.3 抽取式**真实 typecheck**（不可整包编译的改动族）

| 族 | 覆盖的改动文件 | 方式 | 结果 |
| --- | --- | --- | --- |
| CullingViewModel | CullingViewModel.swift、+Actions、+Grid、+Load、+Navigation、+Preload（+ 未改动的 +Triage/+Keywords/+Writeback/CullingViewStateStore 作为依赖） | 真实 GatherProtocol + 精确 stub（未改动 SwiftUI/AppKit 符号与无关 infra，签名照抄） | **EXIT 0 / warnings-as-errors 0** |
| GalleryViewModel | GalleryViewModel.swift、+Derived、+Events、+Scroll（+同族扩展与 Support 文件） | 同上 | **EXIT 0 / warnings-as-errors 0** |
| 单文件真实 typecheck | `Support/DateFormatting.swift`、`Support/JSONValueDecoding.swift`、`Support/ThumbnailDiskCache.swift`（CryptoKit 仅 shim `SHA256.hash(data:)` 一个 API，签名照抄）、`GatherPersistence/Database/DeliveryError.swift`、`GatherProtocol/Protocol/Core.swift`、`Tests/GatherTestSupport/AsyncWait.swift` | 真实模块 + 精确 shim | **全部 EXIT 0**（ThumbnailDiskCache 需 `-package-name gather-app`，与真实 SPM 一致） |
| 改动测试文件 | `GatherCoreTests/Protocol/JSONValueCodingTests.swift`（真实 GatherProtocol+Testing）、`GatherAppTests/DisplayDateFormattersTests.swift`（用真实 DateFormatting.swift 构建 mini `GatherUI` 模块后 typecheck） | 真实编译器 | **EXIT 0** |
| Sidecar 调用形态 | `+IPTC.swift`/`+IPTCReading.swift` 的 4 处 `withRegex` 调用 + `withRegex` 本体（§3.4） | 逐字复制到探针 | **EXIT 0** |

### 4.4 定向编译风险启发式（对象 = 全部改动文件，并做了**对照验证**与误报清洗）

| 扫描 | 规则 | HEAD 命中（清洗后） | 校验方式 |
| --- | --- | --- | --- |
| **跨文件 private 读** | 全仓提取 `private/fileprivate` 声明 + 同 target 其它文件/测试 target（@testable 也不暴露 private）用法；strict-unique 名 + 标签/字符串/注释/遮蔽过滤 | **0**（25 条候选逐条人工排除：参数标签、SDK 同名、重载、行内注释） | **对照验证**：对 round-2 修复前快照（`0288ea8d`）重跑，**精确命中两处已知 P0**（pageAssignmentCount、navigationGroupsVersion）→ 扫描器有效；HEAD 全为误报 |
| **private(set) 跨文件写** | 赋值/`+=`/`.append` 等写模式 | **0** | 同上 |
| **diff 新增 private 成员被跨文件使用** | 新增行提取 + 类型归属（extension 上下文 + 类型名提及） | 0 真问题（35 候选 = 参数标签/internal(set)/同名局部/SDK 重载） | 人工逐条 |
| **`try` 位于非赋值运算符右侧** | 新增行 `op try …`（`== != && \|\| ?? + - * / …`） | **0**（6 命中全在 docs markdown 引用旧 P0 文本） | 语法探针先确认真规则（`+=`/三元合法），再扫代码 |
| **多尾随闭包标签 vs 函数声明** | 全仓函数参数外部标签 × 改动文件 `} label: {` 调用 | **0**（19 候选全为 SwiftUI Button/Section/Label/ContentUnavailableView/DisclosureGroup 等 SDK 标签） | 人工逐条 |
| **删除 public/internal API 后仍被引用** | diff 删除声明名 + HEAD 已无该声明 + 仍被 `.name(`/`name(` 引用 | **0** | 脚本（H7），全仓含测试 |
| **public API 参数标签变更** | origin/main vs HEAD 声明（name+外部标签）比对 × 跨模块引用 | **0**（19 条"新声明"候选均为误配，无真实签名变更） | 人工复核 |
| **新增 public API 的调用标签** | 新增 public 声明 vs app 调用点标签 | **0 mismatch** | 脚本 |
| **enum 新增 case vs switch 穷举** | diff 新增 `case` 行 + switch 覆盖分析 | **0 新增 case**（本 diff 未加 enum case），无风险 | grep diff |
| **var→let 转换后仍被写** | diff `- var X`/`+ let X` 同文件 + 写模式 | **0**（1 候选为局部变量误报） | 人工 |
| **Swift Testing `#require` 缺 `try`** | 改动测试文件 | **0** | 脚本 |
| **`fatalError/preconditionFailure/try!/as!/@unchecked Sendable/nonisolated(unsafe)` 新增** | Sources 新增行 | **0 新增**（`as! CGImageMetadataTag` 被**移除**并改为 CFTypeID 校验后的 `unsafeDowncast`，属安全改进） | grep diff |
| **async 化函数的调用点是否都补 `await`** | round-1 fix 把 `JobService.settle`/`writeTerminal` 改 async | **1 个调用点已补 `await`**（JobService+Claim.swift:183），无遗漏 | grep 全仓（含测试） |
| **签名变化的调用点**（NavigationService.group 新增 timestamps/sequences 参数） | 全仓调用点 | **2 处均已更新**（NavigationService.swift:120/122） | grep |
| **SwiftUI 改动风险面** | 91 个改动 GatherUI 文件中 78 个 import SwiftUI/AppKit → 无法编译；改动多为 l10n/设计令牌/缓存 | 启发式 + 抽检（CullingGrid 布局缓存、GalleryGrid 行索引、LightboxView 下标缓存、ThumbnailDiskCache 均已逐行读） | 人工 + 族 typecheck |

### 4.5 @Observable / 并发隔离 / 可用性 / 宏

- **@Observable/@ObservationIgnored**：新增用法全部在 Culling/Gallery 两族，**真实 typecheck 通过**（含 `@ObservationIgnored private(set) var`、`@ObservationIgnored var` 元组缓存）；无 `@Observable` 加到 struct/enum/actor 的情况。
- **actor 隔离/@MainActor/Sendable**：GatherProtocol、GatherPersistence 在 Swift 6 语言模式下真实构建通过（含 `-warnings-as-errors`）；Culling/Gallery 两族在 Swift 6 下真实 typecheck 通过；新增 `Task.detached` 位于已编译的 `CullingViewModel+Preload`（通过）与未编译的 AppBootstrap/BackupStore/MetadataMutation 等（人工复核捕获变量均为 Sendable 值/常量，**需 macOS 最终确认**）。
- **availability**：两个 Package 都是 `.macOS(.v26)`，target 内无 `@available/#available` 新增，无 "API 比部署目标新" 风险。
- **宏参数（#expect/#require）**：JSONValueCodingTests 真实 typecheck；语法探针确认 `#expect(try f() == x)` 合法、`#expect(a == try f())` 非法；全仓 `#require` 无缺 `try`。
- **泛型/推断**：Sidecar `withRegex<T>`（无 Sendable 约束）+ 4 种真实调用形态编译通过；Culling/Gallery 族的泛型缓存与 tuple 类型推断编译通过。

---

## 5. 验证上限 / 剩余风险（必须 macOS 首跑）

1. **不可编译（需 macOS）**：GatherAnalysis（CoreML/Vision/CoreGraphics/ImageIO）、GatherApplication（依赖 Analysis）、GatherMetadataIO（依赖 Analysis）、gather-app 全部 SwiftUI/AppKit View 层（**91 个改动 GatherUI 文件中 78 个**）、GatherAppTests、大部分 GatherCoreTests。→ **一次 macOS `swift build`（两个包）+ `swift test` 是最终裁决**。
2. **`check-warnings.sh`（-warnings-as-errors）无法本机运行**：已用 Linux 等价方式对可编译目标（GatherProtocol/Persistence、两 ViewModel 族、单文件 typecheck）加 `-warnings-as-errors` 复核，均 0 warning；未编译 target 的新 warning 仍可能让 macOS CI 变红。
3. **shim/stub 边界**：Linux `os` 模块与 AppKit/SwiftUI/CryptoKit 符号 stub 仅用于让**未改动**依赖通过类型检查，签名按公开接口抄录；风险仅限这些未改动符号的 Darwin 微妙差异，不影响改动文件内部判定。
4. **启发式的固有盲区**：无类型信息时，跨文件成员访问/标签匹配只能靠 unique-name + 遮蔽过滤（已用 round-2 修复前快照做阳性对照，证明对 P0 类型有效）；SDK-only 的 SwiftUI View 层 API 误用（如新修饰符)本机不可证。
5. **CI 门禁复核**：在 **HEAD 快照**（`git archive HEAD`）上实跑 CI 的 16 个 Linux 门禁脚本 → **15 PASS**（含 round-2 新增 hygiene/docs-facts/perf-ratchet 的依赖项；唯一 FAIL 的 `check-repo-hygiene.sh` 因快照非 git 检出、`git ls-files` 返回 0，属工具环境限制而非仓库问题）；`check-repo-hygiene.sh` 在非 git 快照中按设计无法运行（`git ls-files` 返回 0）→ 仅在真实检出可复核；真实工作区（含 lead 的 round-3 未提交改动）实跑 PASS。HEAD 的 11 个改动脚本 `bash -n` 全过、`shellcheck -S warning` 0 finding。
6. 本册**不覆盖**行为/性能/文档正确性问题（其他 round-3 reviewer 分册）；不评价 lead 工作区未提交的 round-3 修复。

---

## 6. 附录：关键证据命令（可复现）

```bash
# 0) 语法全量
.gather/swift_syntax_all.sh                       # 1090 files → 0 failures
git diff --check origin/main..HEAD                 # 干净

# 1) 真实模块构建（Linux）
export HOME=$PWD/.gather/home CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc
swift build --target GatherProtocol   -Xswiftc -warnings-as-errors
swift build --target GatherPersistence -Xswiftc -warnings-as-errors \
  -Xswiftc -I -Xswiftc "$PWD/.gather/r3c/shim"     # os 精确 shim（OSAllocatedUnfairLock）

# 2) round-2 P0 复验
swiftc -typecheck -swift-version 6 -warnings-as-errors Sources/GatherUI/Support/DateFormatting.swift
swiftc -typecheck -swift-version 6 -I <spm Modules> Tests/.../JSONValueCodingTests.swift
swiftc -typecheck -swift-version 6 .gather/r3c/probe/obs_probe*.swift        # Observation+private(set) 跨文件
swiftc -typecheck -swift-version 6 .gather/r3c/probe/sidecar_calls_probe.swift  # withRegex 4 调用形态
swiftc -typecheck -swift-version 6 -I <Modules> -I <shim-appkit> .gather/r3c/culling/*.swift  # Culling 族
swiftc -typecheck -swift-version 6 -I <Modules> .gather/r3c/gallery/*.swift                  # Gallery 族

# 3) 启发式扫描（脚本存 .gather/r3c/，gitignored）
python3 .gather/r3c/access_scan3.py .gather/r3c/prefix .gather/r3c/prefix-files.txt  # 阳性对照（命中两 P0）
python3 .gather/r3c/access_scan3.py .                        # HEAD：0 真问题
python3 .gather/r3c/static_scans.py                          # try-RHS / 闭包标签 / #require / var→let / enum
python3 .gather/r3c/diff_scans.py                            # 删除 API / 新增 private / private(set) 写
python3 .gather/r3c/sig_diff.py ; python3 .gather/r3c/newapi_scan.py  # 跨模块签名

# 4) HEAD 快照门禁（15/16 可执行项 PASS；repo-hygiene 需真实 git 检出）
git archive HEAD | tar -x -C .gather/r3c/head && cd .gather/r3c/head && ./scripts/check-*.sh …
```

---

## 7. 逐项覆盖索引（168 个改动 Swift 文件）

| 分组 | 改动数 | 本册证据 |
| --- | --- | --- |
| GatherProtocol（core） | 3 | **真实 SPM 构建**（含 warnings-as-errors） |
| GatherPersistence（core） | 22 | **真实 SPM 构建**（os shim）+ warnings-as-errors |
| GatherApplication（core） | 14 | 启发式扫描 + API/调用点核对（settle/writeTerminal/group/withRegex）+ 关键 hunk 人工读；**整包编译需 macOS** |
| GatherAnalysis（core） | 2 | hunk 人工读（unsafeDowncast 安全化、LRU）；**需 macOS** |
| GatherMetadataIO（core） | 3 | `withRegex` 4 调用形态**逐字探针编译**；readSidecar 简化人工读；**整包需 macOS** |
| GatherUI（app Sources） | 91 | Culling 族 6 + Gallery 族 4 + DateFormatting/JSONValueDecoding/ThumbnailDiskCache 3 = **13 个改动文件真实 typecheck**；其余 78 个 SwiftUI/AppKit View 文件：跨文件/标签/API 启发式 + 抽检；**View 层需 macOS** |
| GatherHost（app Sources） | 1 | 启发式（H1/H7/标签）；**需 macOS** |
| GatherAppTests（app Tests） | 16 | 启发式（#require/try-RHS/标签/private）；DisplayDateFormattersTests 用 mini 模块真实 typecheck；**其余需 macOS** |
| GatherCoreTests（core Tests） | 13 | JSONValueCodingTests 真实 typecheck（Testing+GatherProtocol）；其余依赖 GatherApplication/Analysis 无法本机编译；启发式覆盖 |
| GatherTestSupport（core） | 2 | AsyncWait.swift 真实 typecheck；DatabaseTestSupport 依赖 Persistence+CSQLite（启发式/需 macOS 测试 target） |
| core Package.swift | 1 | manifest dump OK（diff 仅末行换行） |

> 合计 **41/168 个改动文件获得"真实编译器"级别验证**（25 core 模块构建 + 13 GatherUI + 3 测试/支撑），其余 127 个以"探针/API 核对/启发式 + 人工 hunk 复核"覆盖；未覆盖的编译裁决全部集中在需 macOS SDK 的 target（§5.1）。
