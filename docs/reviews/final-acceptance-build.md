# 发布验收 · 独立重跑报告（HEAD df73880）

> **快照声明**：本报告是 df73880 的验收快照；P1/P2 收口后的最终数字（core 1,144/171、app 617/68、ratchet 54/230、protocol 254/1,339）见 [architecture-remediation-status.md](architecture-remediation-status.md)。

> 验收人：独立验收子代理（不采信台账，全部命令本机重跑；台账仅用于对账）
> 时间：2026-10-22 20:35–20:48（Asia/Shanghai）
> 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`，HEAD `df73880`（refactor 分支，`origin/refactor..HEAD` = 34），验收开始时 `git status` 干净
> 环境：macOS 27.0.1（26A434）/ arm64 / Xcode 27.1（Build 27A9275，SDK MacOSX27.0）/ Swift 6.4（swift-driver 1.168.6）/ sqlite3 3.54.0
> 本次只写本报告，未改任何源码、测试、Package 或脚本。
>
> **基线声明**：验收开始时（20:35）工作区干净，全部实测（20:35–20:46）都跑在 `df73880` 的干净工作区上。20:47 起另有并行子代理修改了 39 个源文件 + 新增 `MenuCopy.swift`（`git status` 现为 dirty），**与本次验收无关，也不在 20:35–20:46 的任何一次构建/测试之内**；若在其改动后重跑，数字可能不同，需以新的 HEAD/工作区重新基线。

## 0. 结论（先行）

**可验收（有条件）。** 功能面全绿：core `1,100 tests / 165 suites` exit 0（含一次 clean 重建），app `617 / 68` 串行 + 默认并行 3 次 + 一次 clean 串行全部 exit 0（0 skip、0 flake），9 道门禁全部 exit 0，Schema 双路复核一致（43 表 / 373 列 / 69 显式索引 / 62 FK / user_version=2 / 0 违规），universal 产物真实存在（`x86_64 arm64`，两切片 `minos 14.0 / sdk 27.0`，版本注入与发布门反向用例均符合设计）。

**但发布门未闭环**：无 Developer ID / notarytool 凭据，签名、公证、staple、`spctl` 真路径**未验证**；本机未装 Rosetta，x86_64 切片**只验编译未验运行**；`build.sh` 原样在本沙盒环境**首次直接失败**（SwiftPM manifest 沙箱无法嵌套，需注入 `--disable-sandbox`，属环境限制而非仓库缺陷）。台账存在 5 处数字/口径漂移（P2-1～P2-5），均不影响架构结论。

**P0 = 0；P1 = 2；P2 = 7。**
**建议：架构整改验收通过；对外发布前必须补一次带凭据的签名/公证实跑 + Intel（或 Rosetta）实机冒烟。**

## 1. 命令与结果表

### 1.1 core 测试

| 运行 | 命令（cwd `desktop/native/gather-core`） | N / M / exit | 耗时 |
| --- | --- | --- | --- |
| 基线 | `swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error` | **1,100 / 165 / 0** | 构建 0.38s（增量）+ 测试 4.076s |
| clean 重建 | 同 flags，换 `.build/scratch-clean` 空目录 | **1,100 / 165 / 0** | 构建 24.64s + 测试 3.685s |

- 汇总行：`✔ Test run with 1100 tests in 165 suites passed`（两轮一致）。
- **skip 3 个**（稳定复现）：`Tests/GatherCoreTests/Face/FaceRealPhotoPipelineTests.swift:42/66/80`，均 `.enabled(if: fixtureImageData != nil)`，未设 `GATHER_FACE_FIXTURE` → 有效执行 **1,097**（`check-test-catalog` 登记的 3 个 skip 站点即此 3 例）。
- clean 重建日志含 `[Pre-planning 1/531]`，确认为从零编译，非复用旧产物。

### 1.2 app 测试（串行 + 默认并行 3 次，flags 同 §1.1）

| 轮次 | 命令要点（cwd `desktop/native/gather-app`） | N / M / exit | 耗时 |
| --- | --- | --- | --- |
| 串行 | `swift test --no-parallel ...` | **617 / 68 / 0** | 16.751s |
| 并行 #1 | `swift test ...` | **617 / 68 / 0** | 7.257s |
| 并行 #2 | 同上 | **617 / 68 / 0** | 7.515s |
| 并行 #3 | 同上 | **617 / 68 / 0** | 7.457s |
| clean 串行 | `--no-parallel` + 空 `.build/scratch-clean` | **617 / 68 / 0** | 构建 22.70s + 测试 17.128s |

- 失败点：**无**。4 轮 `0 failure`，skip 0，3 次默认并行（`SessionWorkspace`/日志/XMP 临时目录等共享资源）**无 flake**。
- clean 日志 `[Pre-planning 1/392]`，从零编译通过。

### 1.3 九道门禁

| # | 门禁 | exit | 关键数字 |
| --- | --- | --- | --- |
| 1 | `check-cleanup-ratchet.sh` | 0 | unchecked_sendable **53/53**、try_optional **231/231**、services_prepare **0/0**、todo_fixme **0/0**、with_known_issue **0/0**（当前/基线） |
| 2 | `check-docs.sh --strict` | 0 | ADR 反引号路径 20（缺 0）；当前文档 md 链接 146（缺 0）；docs/reviews 21 篇（本轮开跑时；并行验收报告写入后 26 篇，复跑仍 exit 0）；schema 代码 2 = ADR 声明 2 |
| 3 | `check-test-catalog.sh --strict` | 0 | 测试文件 174；缺文件头 0；skip 站点 **3**（.enabled 3 / .disabled 0 / withKnownIssue 0）；skip 元数据缺失 0 |
| 4 | `check-no-legacy.sh` | 0 | 7 条 enforced 全 `ok`；6 条 tracked：awaitSync 0、Services 32 文件、raw SQL 0、unchecked Sendable 81、dual-track l10n 0、batchAsync 1 |
| 5 | `check-layering.sh` | 0 | 17 条规则全部 0 违规（GatherUI 187 / GatherApp 2 / GatherHost 42 / Analysis 14 / App 32 / Persistence 78 个文件逐一断言） |
| 6 | `check-duplicate-symbols.sh --strict` | 0 | 扫描 618 个 Swift 文件；`func batchAsync` 仅 1 份（`BatchRunner.swift:50`）；LockedBox/ResponseBox 越界 0 |
| 7 | `check-select-star.sh --strict` | 0 | Sources **4 处 / 1 文件**（baseline 6，低于基线）；Tests 1 处 / 1 文件（白名单内） |
| 8 | `check-preview-surface.sh --strict` | 0 | `#Preview` = **14**（strict 门槛 14 / 底线 12）；PreviewSupport 5 文件 / 2,031 行；全部在 `#if DEBUG` 内 |
| 9 | `check-protocol-surface.sh --strict` | 0 | Protocol 70 文件 / 6,514 行；public 类型 **254**；public 声明行 **1,338**；zero-reference **0**；Router 信封 **0** |

### 1.4 Schema：`gather-schema verify` + SQLite 独立复核

| 路径 | 方法 | 结果 |
| --- | --- | --- |
| Swift 校验 | `swift run ... gather-schema verify` | `schema ok: tables=43 columns=373 indexes=69 fks=62 user_version=2 foreign_key_violations=0`，exit 0 |
| 独立复核 | `gather-schema dump`（730 行 SQL）→ `sqlite3 3.54.0` 建库，**不经过任何 Swift 校验代码** | 表 **43**（另 `sqlite_sequence` 1 张，AUTOINCREMENT 内部表）；列 **373**；显式索引 **69**（索引对象共 101 = 69 + 32 autoindex）；FK 边 **62**；`user_version` **2**；`pragma_foreign_key_check` **0**；`integrity_check` **ok**；trigger/view **0** |

两路完全一致 → Schema 与 FK 台账可信。

### 1.5 universal 构建 / `build.sh`

| 尝试 | 命令 | exit | 结果 |
| --- | --- | --- | --- |
| A（原样执行） | `GATHER_ARCHS=universal OUTPUT_DIR=/tmp/... bash desktop/native/build.sh` | **1** | `error: 'gather-core': Invalid manifest ...` + `sandbox-exec: sandbox_apply: Operation not permitted`。原因：SwiftPM 编译 manifest 时自建 `sandbox-exec`，本会话外层 DSH 沙盒禁止嵌套沙盒；脚本的 `swift build` 未带 `--disable-sandbox` |
| B（仅注入 `--disable-sandbox`） | `PATH=/tmp/swiftshim:$PATH GATHER_ARCHS=universal bash build.sh`（shim 只给 `swift build` 追加该 flag，其余原样） | **0** | 全流程通过（脚本内本地化 / FaceModels / entitlements / 资源 bundle 断言全部通过，无 failed 输出），产出 `Gather.app` |
| C（版本注入） | B + `GATHER_VERSION=3.0.9 GATHER_BUILD_NUMBER=42` | **0** | `injected CFBundleShortVersionString=3.0.9 CFBundleVersion=42`；产物 Info.plist 回读 `3.0.9 / 42` |
| D（发布门反向） | C + `GATHER_RELEASE=1`，无 `CODESIGN_IDENTITY` | **1** | `release mode requires CODESIGN_IDENTITY; refusing to ship an unsigned bundle`（门禁按设计拒绝；另一路无版本时也正确 exit 1） |

`build.sh` 内部真实执行的正是两条多架构构建（=任务书里的 `swift build --arch arm64 --arch x86_64`，release 配置）：

```bash
swift build --package-path gather-core -c release --arch arm64 --arch x86_64 \
  --explicit-target-dependency-import-check error
swift build --package-path gather-app  -c release --arch arm64 --arch x86_64 \
  --explicit-target-dependency-import-check error --manifest-cache none
```

（后者带 `--manifest-cache none`，保证脚本探测到的 `GATHER_SDK_VERSION=27.0` 真正写进 Mach-O；实测 `vtool` 确认生效。）

产物事实（`/tmp/gather-release-uni/Gather.app`，可执行 53.5 MB）：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 切片 | `lipo -archs` / `file` | **`x86_64 arm64`**；Mach-O universal binary with 2 architectures；53,488,728 B |
| 构建元数据 | `vtool -show-build` | 两切片均 `minos 14.0` / `sdk 27.0`（LC_BUILD_VERSION）→ Liquid Glass 的 SDK 注入机制**真实生效**（不是 14.0 fallback） |
| 签名 | `codesign -dv --verbose=4` | `flags=0x20002(adhoc,linker-signed)`，**无 Developer ID** |
| 签名校验 | `codesign --verify --deep --strict` | `code object is not signed at all`（未签名，签名段从未执行） |
| 公证 | — | 未执行（无凭据；脚本按设计 skip 并 exit 0，输出 `notarization: not notarized`） |
| 门禁评估 | `spctl -a -t exec -vv` | `accepted ... source=no usable signature` 且 `override=security disabled` → **该环境 Gatekeeper 已关闭，此结果不能作为签名/公证证据** |
| 包内容 | `ls Contents/Resources` | `en.lproj`、`zh-Hans.lproj`、`gather-app_GatherUI.bundle`、`gather-core_GatherAnalysis.bundle`（含 `FaceModels/SFace.mlpackage` + `manifest.json` + `native_ramp_reference.json` + `LICENSE.txt`）、`build-info.json` |
| build-info | `cat build-info.json` | `{"version":"3.0.0","build":"3.0.0","commit":"df73880","archs":"x86_64 arm64","sdk_version":"27.0"}` |
| 插件 | `lipo -archs Contents/PlugIns/GatherLink.coplugin/...` | **arm64 单架构**（脚本已 warn：universal app + 宿主架构插件） |
| entitlements 资产 | `plutil -lint` + 脚本断言 | 合法 plist；`com.apple.security.automation.apple-events=true`；**故意不含** `app-sandbox`；因未签名，entitlement **未进入代码签名** |

### 1.6 release 构建编译警告

universal release 构建共 **11 条唯一警告**（去重后，源码位置级）：

| 位置 | 警告 | 判断 |
| --- | --- | --- |
| `GatherUI/Support/L10n.swift:490-491` | `cast from 'any CVarArg' to unrelated type 'Substring'/'Character' always fails` | **疑似**：两个 case 永远走不到（死分支），格式化路径的 Substring/Character 支持名存实亡 |
| `GatherUI/Culling/CullingViewModel.swift:439` | `?? 左侧非可选，右侧永不使用` | 死 `??`，语义噪音 |
| `GatherUI/Culling/CullingWorkbenchViewer.swift:453` | `initialization of immutable value 'budget' was never used` | **疑似未接线**：`PhotoDetailTier.budget(forVisibleCells:)` 算了却改用 `detailBaseSize` |
| `GatherDelivery/Coordinator/DeliveryReplayFlow.swift:75` | `traceDB 未使用` | WP7b 遗留死变量（replay 的 db 相位日志实际在 :246/:322 另建，功能不缺） |
| `GatherPersistence/Database/DB.swift:234,236` | `result of 'try?' is unused` ×2 | PRAGMA 失败被静默吞掉（既有模式） |
| `GatherUI/Support/GatherCommonViews.swift:131-134` | `track/border/height/cornerRadius` deprecated ×4 | 已标 deprecated 的旧 ProgressView 样式残留 |

## 2. 未验证 / 环境限制（不伪称通过）

1. **真实签名 / 公证 / staple / spctl**：无 Developer ID 证书与 notarytool 凭据 → 未验。§1.5 的 `spctl accepted` 是 Gatekeeper 被关闭的产物，**不算证据**。
2. **x86_64 运行期**：本机未装 Rosetta（`arch -x86_64 /usr/bin/true` → `Bad CPU type in executable`），x86_64 切片只验了编译与 Mach-O 结构；GUI 冷启动、CoreML(SFace) 实推理、Apple Events 授权均未做（无 GUI 自动化）。
3. **`build.sh` 原样执行**：受外层沙盒限制失败；本轮以"仅追加 `--disable-sandbox`"的等价方式跑通。CI/本地终端预期不受影响，但**本环境无法证伪**。
4. **3 个真实照片用例**：无 `GATHER_FACE_FIXTURE` → skip（已登记 owner=`face-pipeline`、到期 2026-12-31）。
5. **SwiftPM 用户级缓存不可写**：`~/Library/org.swift.swiftpm`、`~/Library/Caches/org.swift.swiftpm` 被沙盒拒绝，SwiftPM 自动降级并 warning（manifest 缓存写入失败 `attempt to write a readonly database`），不影响构建/测试结论。

## 3. P0 / P1 / P2

### P0（阻断验收）
无。

### P1
- **P1-1 发布门未闭环（签名 / 公证）**：`build.sh` 的签名段与公证段本轮**从未真正执行**。证据：尝试 B `warning: CODESIGN_IDENTITY is unset; app is unsigned`、`codesign --verify --deep --strict` → `code object is not signed at all`；尝试 D 证明门禁会拒绝无签名发布。影响：**不能声称"可分发包已验收"**（spctl/notarytool/staple 三条工具链 0 覆盖）。修复：在持证机器/CI 上跑 `GATHER_RELEASE=1 GATHER_NOTARIZE=1 CODESIGN_IDENTITY="Developer ID Application: ..."`，留 `codesign --verify --deep --strict`、`stapler validate`、`spctl -a -t exec` 三段日志；并把 `codesign -d --entitlements` 的 apple-events=true 回读结果贴进报告。
- **P1-2 x86_64 只编译未运行（且插件单架构）**：`lipo` 证明双切片都在，但无 Rosetta/Intel 机器验证启动、SFace CoreML、资源 bundle 解析与 Apple Events；`GatherLink.coplugin` 仍是 **arm64-only**，Intel 用户会丢 Capture One 插件（脚本 warn 但发布门不拦）。修复：Intel 机（或 `softwareupdate --install-rosetta` 后）做一次冷启动 + 人脸/相似度/导出冒烟；插件多架构化或接受"Intel 无插件"并在发布说明中写明。

### P2
- **P2-1 `GatherDelivery` 文件数漂移**：台账 "15 文件"，实测 **14 个 `.swift`**（`find -type f` 亦为 14，无资源/非代码文件）。
- **P2-2 台账 HEAD 快照过期**：文档头 `HEAD 1031954`，实际 `df73880`（`1031954..HEAD` = 1 个 docs 提交）。
- **P2-3 core 测试数含 skip 未注记**：`1,100` 是 Swift Testing 汇总口径（含 3 个 skip），有效执行 **1,097**；`check-test-catalog` 说明了该口径，但状态文档 §2 未标注。
- **P2-4 "状态写入 8" 口径不可复现**：`DeliveryStateWriter` 有 21 个方法，其中直接对应 `DeliveryStatus` 迁移的入口恰为 **8** 个（`claimWriting`/`markWriting`/`renewWriting`/`markWritten`/`markFailed`/`markConflict`/`confirm`/`mergeInput`）——数字能对上，但文档没写口径，第三方无法独立复算。其余 Delivery 指标（Coordinator 366、CleanupFlow 674、ReplayFlow 400、adapters 5 方法）实测吻合。
- **P2-5 select-star ratchet 未收紧**：Sources 实测 **4** < baseline **6**，门禁提示可下调；基线滞后会让回归有 2 处缓冲。
- **P2-6 警告债 11 条**：见 §1.6；其中 `L10n.swift:490-491`（永远失败的 cast）与 `CullingWorkbenchViewer.swift:453`（budget 未使用）建议单独确认是否为"死代码"还是"漏接线"。
- **P2-7 WP7b 遗留死变量**：`DeliveryReplayFlow.swift:75` 的 `traceDB`；功能不缺（db 相位日志在 `:246/:322`），但会持续产生编译警告，且说明 WP7b 落地时有未清理的中间态。

## 4. 与 `architecture-remediation-status.md` 逐项对账

| 台账指标（§2） | 台账值 | 实测值 | 判定 |
| --- | --- | --- | --- |
| core tests / suites | 1,100 / 165，exit 0 | 1,100 / 165，exit 0（含 3 skip；clean 重建同样 1,100/165） | ✅（口径注记 P2-3） |
| app tests / suites | 617 / 68，串行 + 并行 3 次 exit 0 | 617 / 68，串行 1 + 并行 3 + clean 串行 1，全 exit 0 | ✅ |
| Schema 表/列/索引/FK | 43 / 373 / 69 / 62 | 43 / 373 / 69 / 62（gather-schema + sqlite3 双路） | ✅ |
| user_version | 2 | 2 | ✅ |
| FK 违规 | 0 | 0 | ✅ |
| 9 道 strict 门禁 | 全绿 | 9/9 exit 0 | ✅ |
| cleanup ratchet | 53 / 231 / 0 / 0 / 0 | 53 / 231 / 0 / 0 / 0 | ✅ |
| protocol surface | 254 / 1,338 / 0 / 0 | 254 / 1,338 / 0 / 0 | ✅ |
| preview | 14 | 14 | ✅ |
| Application DBConnection / prepare | 0 / 0 | 0 / 0（`GatherApplication` 内 4 处命中全为注释） | ✅ |
| services_prepare ratchet | 0 | 0 | ✅ |
| Coordinator 行数 | 366 | 366 | ✅ |
| CleanupFlow / ReplayFlow | 674 / 400 | 674 / 400 | ✅ |
| GatherDelivery 文件数 | 15 | **14** | ❌ 偏差 P2-1 |
| 状态写入 | 8 | 8（按状态迁移入口口径；文档未定义） | ⚠️ 口径不可复现 P2-4 |
| 模块适配器方法 | 5 | 5（`CoordinatorDeliveryAdapter`；外层 `DeliveryModulePorts` 6，多一个 `replay`） | ✅ |
| Protocol public 类型 / 声明 | 254 / 1,338 | 254 / 1,338 | ✅ |
| Router 信封 | 0 | 0 | ✅ |
| Host RootShell 在 UI | 是 | 是（`Sources/GatherUI/Shell/RootShell*.swift` 6 文件 722 行） | ✅ |
| UI sync 端口 | 0 | 0（5 处命中全为注释） | ✅ |
| AppComposition 行数 | 107 | 107 | ✅ |
| Release：universal + build.sh 全流程 | 通过 | universal 通过（`x86_64 arm64`）；build.sh 需注入 `--disable-sandbox` 才可跑 | ⚠️ 条件成立（环境） |
| 签名 / 公证 | 未验证 | 未验证（无凭据） | ✅ 与台账一致 |
| 本地 commit 数 | 34 待 review | `origin/refactor..HEAD` = 34 | ✅ |

**统计：24 项中 21 项完全吻合、2 项口径/条件性吻合（状态写入口径不可复现、Release 条件成立）、1 项偏差（GatherDelivery 文件数）。**

## 5. 复现命令

```bash
# 1) core
cd desktop/native/gather-core
swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error

# 2) app：串行 + 默认并行 3 次
cd ../gather-app
swift test --no-parallel --disable-sandbox --cache-path .build/shared-cache \
  --scratch-path .build/scratch --explicit-target-dependency-import-check error
for i in 1 2 3; do swift test --disable-sandbox --cache-path .build/shared-cache \
  --scratch-path .build/scratch --explicit-target-dependency-import-check error; done

# 3) 九门禁
./scripts/check-cleanup-ratchet.sh
./scripts/check-docs.sh --strict
./scripts/check-test-catalog.sh --strict
./scripts/check-no-legacy.sh
./scripts/check-layering.sh
./scripts/check-duplicate-symbols.sh --strict
./scripts/check-select-star.sh --strict
./scripts/check-preview-surface.sh --strict
./scripts/check-protocol-surface.sh --strict

# 4) Schema（双路）
swift run --package-path desktop/native/gather-core gather-schema verify
BIN=$(swift build --package-path desktop/native/gather-core --show-bin-path)
"$BIN/gather-schema" dump > /tmp/schema.sql
rm -f /tmp/verify.db && sqlite3 /tmp/verify.db < /tmp/schema.sql
sqlite3 /tmp/verify.db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
sqlite3 /tmp/verify.db "SELECT * FROM pragma_user_version; SELECT count(*) FROM pragma_foreign_key_check;"

# 5) universal 发布（受限沙盒内需让 swift build 带 --disable-sandbox）
GATHER_ARCHS=universal OUTPUT_DIR=/tmp/gather-release bash desktop/native/build.sh
lipo -archs /tmp/gather-release/Gather.app/Contents/MacOS/Gather
vtool -show-build /tmp/gather-release/Gather.app/Contents/MacOS/Gather
codesign -dv --verbose=4 /tmp/gather-release/Gather.app

# 6) 反向：发布门必须拒绝无签名
GATHER_ARCHS=universal GATHER_RELEASE=1 GATHER_VERSION=3.0.9 GATHER_BUILD_NUMBER=42 \
  OUTPUT_DIR=/tmp/gather-release-neg bash desktop/native/build.sh   # 期望 exit 1
```

## 6. 最终结论

- **架构整改主体：可验收。** 测试、门禁、Schema、分层、公开面全部实测通过；台账 24 项对账中 21 项完全吻合，偏差集中在文件计数与口径描述，不影响架构结论。
- **对外发布：需修（补验证）。** 唯一未闭环的是签名/公证与 x86_64 运行期（外加插件单架构），三者都在台账"剩余"里如实披露，属凭据/硬件缺失，非代码缺陷。
- **台账校正建议**（并入下一次 docs 提交）：GatherDelivery 14、状态写入口径说明、"1,100 含 3 skip"、HEAD 快照更新、select-star baseline 6→4。
