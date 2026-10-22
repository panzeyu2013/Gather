# Cut 3 模块拆分 / 构建 / 打包 只读评审（R3-build）

> 状态：只读评审。唯一写入本文件；未改源码、`Package.swift`、脚本、CI。
> 评审时间：2026-10-22 14:30–15:0x +0800。工作树为拆分后状态（HEAD `82603e0` 之上约 500 项未提交变更；评审开始时为 492，期间随并行工作增长）。
> 口径：**【已确认】** = 本次有命令/文件行证据；**【疑似】** = 依赖环境或未执行的运行期推断。

---

## 1. 范围与方法

**范围**：两个 `Package.swift` 的 target/依赖图与 public 面；strict import check；资源 bundle（FaceModels、lproj、Info.plist）；bundle 命名；`build.sh` 路径与断言；CI workflow；`scripts` 路径与门禁接线；从空 scratch 的可构建性；测试 target 与 Preview DEBUG 边界；发布配置差异；打包/运行时风险。

**方法（本次实际执行）**：

```bash
# 1) 依赖图/产物：两个包 describe（本机 SwiftPM 自带 sandbox 被 DSH 拒绝，故 --disable-sandbox）
swift package --package-path desktop/native/gather-core --disable-sandbox describe --type json
swift package --package-path desktop/native/gather-app  --disable-sandbox describe --type json

# 2) 空 scratch 构建（不 clean 仓库；scratch 全部在 /tmp/gather-r3.CYXiNi）
swift build --package-path .../gather-core --disable-sandbox --cache-path /tmp/.../cache \
  --scratch-path /tmp/.../core-scratch -c debug --explicit-target-dependency-import-check error
swift build --package-path .../gather-app  ... -c debug --explicit-target-dependency-import-check error
# 同样参数再跑 -c release、--build-tests

# 3) 门禁（只读执行）
for s in check-no-legacy check-layering check-cleanup-ratchet check-test-catalog \
         check-duplicate-symbols check-preview-surface check-select-star check-docs; do ./scripts/$s.sh ...; done

# 4) 负向对照：验证 strict import flag 真的会失败（/tmp 最小包，A 依赖 B 却 import C）
swift build --disable-sandbox --explicit-target-dependency-import-check error   # → error: 'A' is missing a dependency on 'C'，exit 1

# 5) 测试对照
swift test --package-path .../gather-core ... --explicit-target-dependency-import-check error   # 1092/157 pass
swift test --package-path .../gather-app  ... --explicit-target-dependency-import-check error   # 并行：failed 1 issue
swift test --package-path .../gather-app  ... --no-parallel                                    # 581/66 pass

# 6) 产物检查：find *.bundle、plutil、vtool -show-build、生成 resource_bundle_accessor.swift

# 7) 运行期解析探针（/tmp 独立 Swift 脚本，不改仓库）：
#    Bundle(url:).url(forResource:"SFace", withExtension:"mlpackage", subdirectory:"FaceModels")
#    Bundle(url:).url(forResource:"zh-hans"/"zh-Hans"/"en", withExtension:"lproj") + localizedString

# 8) 端到端组装模拟（/tmp）：把 release 产物按 build.sh 的 cp 步骤装成 Gather.app，plutil -lint + 路径核对
```

工具链：Swift 6.4 / Xcode 27.1 / SDK 27.0（`swift --version`、`xcodebuild -version`）。

**结果摘要**：空 scratch **debug/release 两个包均 exit 0**（core release 52.6s、app release 64.6s），两包 **test target 均编译 exit 0**；core 全量测试 **1092 tests / 157 suites passed**（3.881s，exit 0），app **581/66** 串行通过、并行 1 issue；8 个门禁本地全过；按 `build.sh` 的 cp 步骤在 /tmp 组装 Gather.app 后 `plutil -lint` OK、FaceModels/lproj/Info.plist 路径全部核对通过。发现 **P0 = 0**，P1 = 3，P2 = 12。

**未执行/限制（不得当作通过项）**：① `build.sh` 本身未执行——本机 SwiftPM 自带 sandbox 被 DSH 拒绝（`sandbox_apply: Operation not permitted`），改为在干净 release 产物上逐条复核其 find/cp 断言，并在 /tmp 模拟组装；② core 全量测试已跑（1092/157），app 测试并行/串行各跑一次；③ 未做签名/公证、真机启动、GUI smoke、大小写敏感卷验证。

> 前置说明：工作树约 500 项未提交（`scripts/*.sh` 7 个新脚本、`ci.yml`、两个 `Package.swift`、`Sources/GatherUI|GatherHost` 全部为未跟踪/未提交）。**从 HEAD 的干净 clone 不含本 Cut**，CI 会因脚本缺失直接失败；本报告评的是当前工作树。此项不记为代码 P0（见 P2-9）。

---

## 2. P0（阻断构建/打包）

**无。** 本次在空 scratch 上确认：

- core：`GatherProtocol → {GatherPersistence, GatherAnalysis} → GatherDomain`，`GatherSchema → GatherPersistence`，两个 benchmark → `GatherAnalysis`，无环。
- app：`GatherApp → GatherHost → GatherUI → GatherProtocol`，`GatherHost` 另依赖四层；`gather-app` 包仅一个 product；`swift package describe` 正常输出，无 cyclic dependency。
- 两包 `-c debug` / `-c release` 均从零 scratch 构建成功；`--build-tests` 两包均 exit 0。
- `build.sh` 依赖的 4 个事实在干净产物上逐条成立：`gather-core_GatherAnalysis.bundle`、`gather-app_GatherUI.bundle`、`FaceModels/SFace.mlpackage`、两套 `.lproj`。

---

## 3. P1（高：CI 准入失效 / 签名后功能失效 / 发布门漏检）

### P1-1 【已确认，本次复现】app 测试默认并行失败，而 CI 未加 `--no-parallel`
- 证据：`.github/workflows/ci.yml:87` → `swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`（无 `--no-parallel`）。
- 对照口径：`docs/final-report.md:38/69/80`、`docs/refactor-progress.md:70` 均记录 app 测试必须 `--no-parallel`（581/66 绿）。
- 实测（空 scratch，同一 test bundle）：
  - 默认并行：`Test run with 581 tests in 66 suites failed after 5.434 seconds with 1 issue`，失败点 `Tests/GatherAppTests/DuplicatesControlCenterAPITests.swift:384:9 Expectation failed: await waitUntilAsync { sessionAPI.getCalls.count >= 2 }`；exit 1。
  - `--no-parallel`：`581 tests in 66 suites passed after 12.937 seconds`；exit 0。
  - 该用例用 20ms 真实时钟轮询并等待 `getCalls.count >= 2`；并行负载下等待窗口被拖过（是否与其它用例共享全局状态尚未进一步证明，只确证并行模式失败、串行模式通过）。
- 影响：**CI 的 app job 红 → `Native bundle build`（`ci.yml:89`）永不执行**；CI 是当前唯一 bundle 验证门，等于发布门失效。本次一次复现即失败（并行负载/CI 下更易触发），不能当偶发跳过。
- 修复：CI 该行加 `--no-parallel`（与文档一致，最小改动）；或把该用例的轮询改用可控时钟/注入 scheduler，从根本上消除时序敏感（推荐后者，但前者先止血）。

### P1-2 【已确认缺 entitlements；运行期后果疑似】release 签名开 hardened runtime，却没有 Apple Events 自动化 entitlement
- 证据：`desktop/native/build.sh:126-127`：`codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"`；全仓 `find . -name '*.entitlements'` = 0 个文件，`build.sh` 也无 `--entitlements`。
- 应用确实依赖 Apple Events：`Sources/GatherHost/CaptureOneBridge.swift:73/82/113/129/154` 调用 `runAppleScript`（`:172` 实现），Info.plist:34 已声明 `NSAppleEventsUsageDescription`。
- 影响：一旦用 Developer ID 签名并按 `--options runtime` 分发，**未带 `com.apple.security.automation.apple-events` 的 app 发送 AppleEvent 会被 TCC 拒绝（-1743）**，Capture One 导入/写回/预检整条链路在发布包中失效；本地未签名 ad-hoc 运行不会暴露（因此 CI 的 bundle job 也测不出）。
- 修复：新增 `Gather.entitlements`（`com.apple.security.automation.apple-events`，如需沙盒再补相应项），`codesign` 传 `--entitlements`；签名后用 `codesign -d --entitlements -` 断言；补一条"签名后 C1 预检"人工验收项。

### P1-3 【已确认】FaceModels 打包断言只要求"任意 .mlpackage"，与运行期写死的 `SFace` 不一致
- 证据：`build.sh:77-81` 只做 `find "$FACE_MODELS_DIR" -maxdepth 1 -type d -name '*.mlpackage' -print -quit`，非空即通过；运行期 `Sources/GatherAnalysis/Face/EmbeddingModel.swift:553-555` 写死 `Bundle.module.url(forResource: "SFace", withExtension: "mlpackage", subdirectory: "FaceModels")`。
- 影响：模型包改名/换包（如 `SFace-v2.mlpackage`）时，`build.sh` 绿灯、发布成功，但首次人脸/相似度路径抛 `FaceEmbeddingError.modelNotFound("内置 SFace.mlpackage")`（`EmbeddingModel.swift:569-570`）——正是评审要点里的"模型找不到"。同理 `FaceModels/manifest.json` 缺失也不拦。
- 修复：断言精确路径 `$FACE_MODELS_DIR/SFace.mlpackage` 为目录，并断言 `manifest.json`、`native_ramp_reference.json`、`LICENSE.txt`；最好在 CI 里对打包后的 app 跑一次 `Bundle.module` 解析 smoke（或 `gather-face-benchmarks --smoke`）。

---

## 4. P2（中：门禁漏检、API 面、可移植性、构建卫生）

### P2-1 【已确认】本地化断言只看目录，不看 `Localizable.strings`
- 证据：`build.sh:46-51`（源码侧）与 `:84-89`（bundle 侧）都只判断 `-d .../xx.lproj`。设计文档 `docs/archive/cuts/module-split-map-v2.md:729` 明确要求"assert en.lproj/Localizable.strings 与 zh-Hans.lproj/Localizable.strings 都存在"。
- 影响：空的 `.lproj` 目录能让发布门通过，UI 全部回退 key（源代码里 key 即中文），英文界面"静默全中文"，且无任何报错。
- 修复：两处改为 `[[ -f "$.../$lang.lproj/Localizable.strings" ]]`；顺带断言 `Info.plist` 含 `CFBundleLocalizations`（`plutil -extract`）。

### P2-2 【已确认】拆分后 public 面没有收口（过度 public）
- 证据（本次脚本：按模块抓 `public (final|nonisolated)? (struct|class|enum|actor|protocol)`，再统计模块外（含两包 Tests）0 次命中的类型）：
  - `GatherPersistence`：122 个 public 类型，**33 个模块外 0 引用**，例：`Database/Repositories/AssetRepo.swift:70` `public struct SessionAssetRow`、`:101` `public struct BackfillResult`、`RepositorySupport.swift:187` `public struct TSFileStat`。
  - `GatherDomain`：111 个 public，**24 个 0 引用**，例：`Services/CullingService.swift:143` `public struct CullingPhotoRow`、`Services/FilterEngine.swift:27` `public struct WhereClauseResult`。
  - `GatherUI`：127 个 public，**48 个 0 引用**，例：`Support/GatherBadge.swift:32` `public struct GatherBadge`、`Support/GatherCommonViews.swift:13` `public struct GatherStatCard`。
  - `GatherProtocol`：360 个 public，14 个 0 引用（例 `API/Core/BoundedString.swift`、`API/Core/NonEmpty.swift`）。
  - `GatherHost`：32 个 public，2 个 0 引用（`FaceKwWritebackBridge.swift`、`ImportPathRulesAdapter.swift`）；Host 与 `GatherApp` 同包，对 App 暴露完全可以用 `package` 而非 `public`。
- 判断依据：core 测试 97 处 `@testable import`，不需要 public；app 测试虽用 plain `import`，但上述类型在 Tests 中 0 命中。即这些 public 只是"拆 target 时不敢改访问级"的遗留，不是跨模块契约。
- 影响：模块边界名义存在、实际 API 面泄漏；后续任何包外复用时被误当稳定 API；也掩盖真正需要跨 target 的端口/协议。
- 修复：按模块做一次 public→internal 审计（凭 0 外部引用清单批量改），只保留 Host/UI 真正消费的符号；把跨 target 契约收敛到 `GatherProtocol` 与 UI 端口协议。

### P2-3 【已确认副作用，沙箱失败疑似】app `Package.swift` 在 manifest 求值期执行 `xcrun`
- 证据：`desktop/native/gather-app/Package.swift:40-54` 在顶层用 `Process()` 跑 `/usr/bin/xcrun --show-sdk-version`；`:58` 读环境变量；`:63-70` 生成 `-platform_version` linker flags。
- 影响：① 每个 `swift build/test/package describe`（包括 IDE、CI 每次 manifest 编译）都 fork 进程，manifest 不再纯函数；② 产物随宿主 SDK 变化（非 hermetic），CI 上 `macos-latest` 与本地不同 SDK 会得到不同 `LC_BUILD_VERSION.sdk`；③ SwiftPM manifest sandbox 对进程执行/文件读取的策略因版本而异，本机 DSH 拒绝 `sandbox-exec`，**未能在带 sandbox 的 manifest 编译下验证**（CI 上大概率可行）。实测 `--disable-sandbox` 下正常，`vtool` 显示 `minos 14.0 / sdk 27.0`。
- 修复：改为构建脚本参数（`swift build -Xlinker -platform_version ...` 由 `build.sh` 传入）或 `GATHER_SDK_VERSION` 显式化，manifest 保持无副作用；若保留，至少在 CI 固定 `GATHER_SDK_VERSION` 消除漂移。

### P2-4 【已确认代码差异；CLT-only 失败疑似】Swift Testing 的 CLT 回退只加在 core，app 测试没有
- 证据：`desktop/native/gather-core/Package.swift:10-32` 探测 `/Library/Developer/CommandLineTools/.../SwiftTesting.framework` 并给 test target 加 `-F`/`-rpath`；`desktop/native/gather-app/Package.swift:22,123-133` 的 `GatherAppTests` 只有 `swift6Settings`，无对应 `testSwiftSettings/linkerSettings`。
- 影响：只装 Command Line Tools（无完整 Xcode）的机器上，core 测试可按设计运行，**app 测试会在链接 Swift Testing 时失败**；两包构建前置条件不一致，文档也未写"app 测试必须 Xcode"。
- 修复：把 CLT 探测抽成两包共享的片段（或 app 包复制同一段）；或在 `docs/DEVELOPMENT.md` 明确 app 测试要求 Xcode 并让脚本早失败。

### P2-5 【已确认】`GatherTestSupport` 不是 product，app 测试复制了同一套 DB fixture
- 证据：`gather-core/Package.swift:89-94`（普通 `.target`，未出现在 `products` `:40-51`）；app 侧 `Tests/GatherAppTests/Support/TestDatabase.swift:15-17` `makeGatherTestDB()` 直接 `exec(SchemaV1.sql)`（app 测试 19 处调用），与 core `Tests/GatherTestSupport/DatabaseTestSupport.swift:20` `makeTestDB()` 重复；该文件头注释（`DatabaseTestSupport.swift:7`）还写着"public API 便于 GatherAppTests 将来复用"，但跨包无法 import。
- 影响：Schema 变更时两处夹具要同步改；且 core 的 fixture 注释与事实不符。另：`GatherTestSupport` 是普通 library target，`swift build -c release` 也会编译它（只是不链接），增加发布构建时间。
- 修复：把 TestSupport 升为 `.library` product（仅测试用），app 测试声明依赖；或明确"两包各自持有 fixture"并删掉误导注释；release 构建用 `--product gather-app` 避免编译测试基建。

### P2-6 【已确认】`GatherUI` 里定义了同名 `GatherDomain` 类型，遮蔽 core 模块名
- 证据：`Sources/GatherUI/Support/GatherEventCenter.swift:25` `public enum GatherDomain: String, Sendable, CaseIterable`；Host 多个文件同时 `import GatherDomain` + `import GatherUI`（`AppComposition.swift`、`AppBootstrap.swift` 等 11 文件），app 测试同样两者都 import。
- 影响：目前能编译只是因为没人写 `GatherDomain.CullingService` 这种模块限定名；一旦写，`GatherDomain` 解析到 UI 的枚举而非模块，报错难懂。拆分后模块名本应可用作限定符，这里被人为破坏。
- 修复：把 UI 的事件域枚举改名（`GatherDomainKind` / `ChangeDomain`），模块名留给 `GatherDomain`。

### P2-7 【已确认】依赖声明有"多报"：benchmark/TestSupport 声明了未使用的 `GatherProtocol`
- 证据：`gather-core/Package.swift:96-106`（两个 benchmark 均 `dependencies: ["GatherProtocol", "GatherAnalysis"]`），但 `Sources/GatherCoreBenchmarks/main.swift:17` 只 `import GatherAnalysis`，`GatherFaceBenchmarks/main.swift:1-5` 只 `import GatherAnalysis` + 系统框架；`Package.swift:89-94` 的 `GatherTestSupport` 声明 `GatherProtocol`，实际 `DatabaseTestSupport.swift:10-11` 只 `import Foundation/GatherPersistence`。
- 影响：strict import check 只查"缺依赖"，不查"多依赖"，图与真实需求漂移；benchmark 会多链一层 Protocol（当前无功能影响）。
- 修复：删多余依赖，让 describe 图 = 真实 import 图；可在门禁加"声明依赖必须被至少一个文件 import"的检查。

### P2-8 【已确认】`build.sh` 重复构建 core；`--deep` 签名与缺 plist 校验
- 证据：`build.sh:22` 先在 core 包 `.build` 全量构建一次，`:23` 构建 app 时 SwiftPM 又把 core 在 app 的 scratch 里重建一次（本次 release 实测 core 52.6s + app 64.6s 中包含重复 core 编译）；`:28` 再跑一次 `--show-bin-path`。`:127` 用已弃用的 `--deep` 递归签名；`:41-45` 只断言 Info.plist 存在，无 `plutil -lint`。
- 影响：CI 时间白花；`--deep` 对嵌套 `GatherLink.coplugin` 的签名/公证不可靠；非法 plist 可发布后在启动时才炸。另外脚本没有 notarytool/stapler 步骤，`CODESIGN_IDENTITY` 未设置时直接输出未签名包（`:128-130`），Gatekeeper 会拒；有签名也没有公证，分发链路仍不完整。
- 修复：删 `:22` 的独立 core 构建（依赖 app 构建即可，bundle 断言仍从 app bin 目录取）；`:28` 的 bin path 由 `:23` 的构建结果缓存；显式先签 coplugin → 资源 bundle → app；加 `plutil -lint "$INFO_PLIST"`；补 `notarytool submit` + `stapler`（或文档明确发布不走公证）。

### P2-9 【已确认】交付态：约 500 项未提交，干净 clone 与 CI 门禁不成立（流程，不是代码缺陷）
- 证据：评审开始时 `git status --porcelain | wc -l` = 492，结束前 500（并行工作仍在改）；`scripts/check-cleanup-ratchet.sh` 等 7 个脚本为 `??`，`check-command-surface.sh` 为 `D`；`ci.yml` 引用这些脚本（`ci.yml:36-50`）。
- 影响：当前工作树可构建、门禁可过；但一个干净 checkout（HEAD）既没有拆分后的源码，也没有新脚本，CI 会在 `Docs consistency` 前就 "No such file"。评审/验收若只跑本地工作树，无法回归到提交态。另：`desktop/native/gather-app/Sources/.build` 有 **379MB** 遗留构建缓存（未被 git 跟踪；`check-preview-surface.sh:44-47` 专门 prune 它，`check-no-legacy.sh` 的 grep 则未 prune），属源码树卫生问题。
- 修复：按 Cut 收口提交（源码 + 两个 Package.swift + scripts + ci.yml + docs 同批），再在干净 clone 上跑一遍 `ci.yml` 等价命令。

### P2-10 【已确认】zh 本地化表按小写 `zh-hans` 查找，实际永远落空
- 证据：`Sources/GatherUI/Support/L10n.swift:577` `localizedBundle(named: "zh-hans")`，`Sources/GatherUI/Support/GatherLocalization.swift:287` `appLanguage == "zh-CN" ? "zh-hans" : "en"`；而实际目录是 `Resources/zh-Hans.lproj`（`Package.swift:94-97`），`Language.rawValue` 又是 `"zh-CN"`（`L10n.swift:123`）——`zh-CN / zh-Hans / zh-hans` 三种写法并存。
- 运行期探针（干净 release 产物，独立 Swift 脚本）：`Bundle(url: .../gather-app_GatherUI.bundle).url(forResource: "zh-hans", withExtension: "lproj")` = **NIL**；同一 bundle 的 `"zh-Hans"`、`"en"` 均命中，`localizedString("设置")` 分别返回「设置」「Settings」。说明不是"大小写敏感卷才失败"，而是**在本机 APFS 上就失败**。
- 影响：zh 表 9 条（本次解析 `zh-Hans.lproj` 共 9 对，**全部 key == value**）当前被静默忽略，回退 key=中文源文本，所以界面暂时无可见差异；一旦 zh 表出现与 key 不同的文案或占位符，就静默失效。en 路径正常。也正因 key==value，"zh 表留空"的设计缺陷一直没暴露。
- 修复：统一成 `"zh-Hans"`（或按 `Locale` 解析），`Language` rawValue、`L10n`、`GatherLocalization` 三处共用一个映射；补一条"zh bundle 非 nil 且命中 key != value"的回归测试。

### P2-11 【已确认，低】Reconciliation fixture 被 exclude 出 test target，却按 `#filePath` 读源码树
- 证据：`gather-core/Package.swift:114` `exclude: ["Reconciliation/Fixtures", "Reconciliation/README.md"]`；`Tests/GatherCoreTests/Reconciliation/Harness.swift:13-15` 用 `#filePath` 拼 `Fixtures`。
- 影响：测试只能在源码 checkout 内跑；把 `.xctest`/构建产物单独分发时 fixture 不存在。CI 不受影响，属可移植性/测试资产问题。
- 修复：把 Fixtures 作为 test target 资源 `.copy` 并改用 `Bundle.module`，或保留现状但在文档写明"测试依赖源码树"。

### P2-12 【已确认，低；非本 Cut 回归】发布产物是 arm64 单架构
- 证据：`lipo -info` 干净 release `gather-app` = `Non-fat file ... architecture: arm64`；`build.sh:117` 的 coplugin 也用 `uname -m`；仓库里旧的 `release/Gather.app/Contents/MacOS/Gather` 同为 arm64。
- 影响：Info.plist 声明 `LSMinimumSystemVersion=14.0`，但 Intel Mac 无法运行；若要 universal 分发需 `swift build --arch arm64 --arch x86_64`（或分别构建后 lipo）。旧产物同样如此，故不计为 Cut 3 回归，仅记录。
- 修复：若产品目标含 Intel，`build.sh` 用双 `--arch`；否则在 README/发布说明明确"Apple Silicon only"。

---

## 5. 已验证正确项（避免误伤）

| 项 | 证据 |
| --- | --- |
| 依赖图无环、无越界（7 个产品 target） | `describe`：Protocol 0 依赖；Persistence→Protocol+CSQLite；Analysis→Protocol；Domain→{Protocol,Persistence,Analysis}；UI→Protocol（product）；Host→UI+4产品；App→Host+UI |
| UI 只依赖 Protocol | `grep '^import ' Sources/GatherUI` → 仅 GatherProtocol + 系统框架；`check-layering` 17 条全 ok |
| strict import 真的生效 | 最小包负向对照：`error: 'A' is missing a dependency on 'C'...`，exit 1 |
| bundle 命名与 SwiftPM 一致 | 生成 `resource_bundle_accessor.swift` 的 `bundleName = "gather-app_GatherUI"` / `"gather-core_GatherAnalysis"`；产物目录同名 |
| 打包后 Bundle.module 可解析 | accessor 候选顺序含 `Bundle.main.resourceURL`（= `Contents/Resources`），`build.sh:99-100` 正把两个 bundle 放该处 |
| 运行期解析探针 | 干净 release 产物上：`url(forResource:"SFace", withExtension:"mlpackage", subdirectory:"FaceModels")` 命中；UI bundle 的 `zh-Hans`/`en` lproj 命中，`localizedString("设置")` = 设置 / Settings；`zh-hans` 为 NIL（见 P2-10） |
| FaceModels / lproj / Info.plist | release 产物：`.../gather-core_GatherAnalysis.bundle/Contents/Resources/FaceModels/SFace.mlpackage`；UI bundle `Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings`；Info.plist `CFBundleLocalizations=[en,zh-Hans]` |
| 架构 | clean release `gather-app` 为 arm64 单架构（见 P2-12） |
| release 与 debug 差异 | release 构建 exit 0（PreviewSupport 的 `#if DEBUG` 全部编掉）；两配置 `LC_BUILD_VERSION` 均 `minos 14.0 / sdk 27.0`；DEBUG 才有的 `PACKAGE_RESOURCE_BUNDLE_PATH` override 不影响发布 |
| 门禁接线 | 8 个脚本本地全过（ratchet 53/236/126/0/0，preview 14，select-star 6/1，docs strict OK，layering OK，no-legacy 7 enforced）；CI `gates` 已列 8 条（`ci.yml:35-50`）；`check-test-catalog` 已含 `Tests/GatherTestSupport` |
| 端到端组装 | /tmp 按 `build.sh:91-110` 组装：`Contents/MacOS/Gather` + `Info.plist` + 两个 bundle + 两套 lproj 齐全；`plutil -lint Info.plist` OK；`otool -L` 仅系统框架（无第三方 dylib） |
| `build.sh` 路径 | `UI_SUPPORT/UI_RESOURCES/INFO_PLIST` 与仓库实际一致；两 bundle 名与产出一致；`--show-bin-path` 兼容新布局 |

**Host 聚合判断**：`GatherHost` 是唯一允许 import 四层的组合根（42 文件：`AppComposition`/`AppBootstrap`/`AppRuntime`/`ExecutorRegistry` + `APIs/` 18 文件（16 个 `Live*API` + `AppServices`/`LivePhotoPathPolicy`）+ C1/Similarity/Writeback 桥 + `RootView` 7 文件 + 端口适配器）。方向正确：Host→UI/四层，UI→Host 为 0；Live API 只被 Host 与测试使用，没有反向泄漏进 UI。保留意见：42 文件单 target 内部没有子边界，启动装配、Live API、RootView 壳与端口适配器可任意互引；若 Cut 4/5 继续扩张，建议先在 Host 内按 `APIs/`、`Composition/`、`Shell/` 分目录约定（子 target 会新增依赖声明成本，暂不必拆）。

---

## 6. 已确认 vs 疑似

| 编号 | 结论 | 状态 |
| --- | --- | --- |
| P1-1 | app 默认并行测试失败（1 issue），串行通过；CI 缺 flag | **已确认**（并行/串行各一次实测 + 日志行号） |
| P1-2 | 无 entitlements、签名开 hardened runtime、代码用 Apple Events | 缺失 **已确认**；TCC -1743 运行期后果 **疑似**（取决于签名身份/分发方式） |
| P1-3 | 断言任意 `.mlpackage`，运行期写死 `SFace` | **已确认**（代码对读） |
| P2-1/P2-2/P2-5/P2-6/P2-7/P2-8/P2-9/P2-11/P2-12 | 见正文 | **已确认**（文件/命令证据） |
| P2-3 | manifest 执行 xcrun 的非 hermetic 后果 | 副作用 **已确认**；带 sandbox 的 manifest 编译失败 **疑似**（本机无法执行 `sandbox-exec`） |
| P2-4 | core 有 CLT 回退、app 没有 | 代码差异 **已确认**；CLT-only 机器失败 **疑似**（未在纯 CLT 环境实测） |
| P2-10 | `zh-hans` 查找在干净产物上返回 NIL | **已确认**（运行期探针；当前 9/9 key==value 掩盖影响） |

---

## 7. 结论

1. **拆分本身是正确的**：target 图无环、UI 只依赖 Protocol、Host 作为组合根方向正确、`--explicit-target-dependency-import-check error` 确实能拦越界（已用负向对照证明），空 scratch 下 debug/release/test 全部可构建，资源 bundle 名与运行时解析路径一致。**没有 P0。**
2. **真正的风险不在拆分，而在"发布门只验存在、不验内容"**：`build.sh` 接受任意 `.mlpackage`、只看 `.lproj` 目录、签名不带 automation entitlement——三者都能让发布包"构建成功但功能失效"（人脸模型找不到 / 英文界面空 / C1 自动化被 TCC 拒绝）。
3. **CI 当前是不可信的发布门**：app job 缺 `--no-parallel`，本次复现即红，而 bundle 步骤在它之后；即便修好，bundle 验证也只是"文件存在"级，不是"能启动/能加载模型"级。
4. **拆分后的 API 面没有收口**：Persistence/Domain/UI 共 105 个 public 类型模块外 0 引用，说明 3a/3b 只做了"能编译"，没做"该 internal 的 internal"；这不会立即报错，但会让后续 Cut 的边界持续腐化。
5. **建议顺序**：先修 P1-1（CI 止血）与 P1-3/P2-1（发布断言补强），再做 P1-2（签名 entitlement，需真机验证），最后做 P2-2 的 public 收口与 P2-3/P2-4 的 manifest/工具链收敛。所有修复都不需要回退拆分结构。
