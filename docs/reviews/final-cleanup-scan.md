# Gather 最终死代码 / 收尾扫描（只读）

> 扫描对象：`/Users/panzeyu2013/Desktop/code/develop/Gather`，HEAD `df73880`。
> 扫描时点：2026-10-22 20:35–21:05 +0800。本任务只新增本报告，未改源码 / 测试 / Package / scripts / 其他 docs。
> **并行工作区提示（20:57 快照）**：扫描期间另有 agent 已开始执行清理——`git status` 为 **63 M / 1 D / 6 ??**（66 files changed, +200/−302），其中包含：删除 `GatherUI/Support/JobScopeCheckpoint.swift`、`makeGatherTestDB` 改名、`GatherLocalization`/测试调整、README/ROADMAP/DEVELOPMENT 更新、新增 `MenuCopy.swift` 与 4 份 `final-acceptance-*.md`。**本报告所有行号/引用以 HEAD `df73880` 为准**；当前工作树已不等于 HEAD，执行前先 `git diff` 对账，已被他人改掉的项直接跳过，不要重复改/覆盖。
> 方法：`git grep` 全仓（core + app + Tests + scripts + 当前 docs）、`scripts/find-unused-symbols.swift`、`scripts/check-duplicate-symbols.sh`、私有成员引用检测（声明外 0 次引用）、文件头路径存在性校验、`du`/跟踪状态核对；每一档结论都附可复算命令。
> 口径：**A = 全仓代码零引用、可直接删**；**B = 有测试/契约/文档引用，需先迁移再删**；**C = 协议 / 动态调用 / 测试契约 / 历史快照，保留**。

---

## 0. 结论先行

- **P0 = 0**：未发现会被运行时触发的死代码或断链。
- **P1 = 3**（都已确认，不是疑似）：
  1. **当前文档的架构与 schema 版本口径过期**：仍写 `GatherDomain`、7 target、`user_version=1`、`Sources/GatherTestSupport`；实际是 8 个功能 target（含 `GatherDelivery`、`GatherApplication`）、`user_version=2`、测试夹具在 `Tests/GatherTestSupport`。见 §5.9。
  2. **`JobScopeCheckpoint` 被两份收尾报告描述为“被 LiveSessionAPI / Dashboard 引用”，实测生产引用为 0**；它只是测试引用的 22 行类型，且与 `JobCreateParams.metadataScanRequestedPathsKey` / `metadataScanCheckpoint` 重复。见 §3-B01、§5.5。
  3. **26 处 Swift 文件头 path 指向已不存在的文件**（23 条 `Sources/GatherDomain/Services/...`、2 条旧 `GatherAnalysis/Concurrent/...`、1 条旧测试文件名），另有 4 处交付端口注释仍宣称已删除的旧端口/转发存在。见 §2-A01、§5.2。
- **A 档共 11 组**（P2 级，除 A01/A09/A11 的注释外均需编译/测试验收）：26 行错误文件头、`IndexerService.sha256File` 9 行、`GatherProgressBar` 4 个废弃参数（约 20 行）、`GatherLocalization.appLocale` 6 行、2 个未读私有常量、`VectorIndex.Candidate` 5 行、9 个零调用私有测试 helper（112 行）、`FaceSimMutationPort` 28 行、4 处过期交付端口注释、4 处 Package 清单“四层”注释、11 GB 构建产物。
- **B 档共 10 组**：`JobScopeCheckpoint`（22 行）、`makeGatherTestDB` 别名（22 个调用点 / 18 文件）、`GatherLocalization` 旧翻译函数（约 73 行，测试 parity 钉住）、core/app 逐字重复的 `ServiceConstructionTestSupport`（344 行）、5 组重复 helper、`GatherDomainChange` 命名、`MetadataSync*` 命名、`FileSystemDeliveryFilePort` / `RELEASE` 旧别名与文档刷新。
- **C 档**：AppKit 动态回调、旧 Protocol DTO（旧报告口径 112 个）+ 契约测试、`DeliveryModule.template/.metadata`（DB CHECK 契约）、历史 Cut/WP/S5c/Phase 注释、archive 与 reviews 快照、Capture One 领域语义的 `Sync` 命名。
- **测试基线**：core **1,100 tests / 165 suites**（exit 0）；app **617 tests / 68 suites**（首跑 1 个既有 flake、隔离与全量重跑均 exit 0）。旧口径 1,128/159、616/68 已过期。
- **P2 = A/B 两档中的非阻断项**（死成员、重复 helper、旧别名、脚本门禁缺口）；均不改变运行时行为，但需要批次化验收，不能与 P1 的文档/契约问题混为一谈。
- **建议不要“大爆炸”**：按 §6 的 6 个批次推进；每批先跑 `check-*` 门禁，再跑对应测试。A 档可先做“零行为”的 B1（文件头/注释）与 B2（死成员），不需要全量重构。

---

## 1. 基线与实测

### 1.1 规模

| 项 | 实测 | 口径 |
| --- | ---: | --- |
| core + app Swift 文件 | **602** | `find desktop/native -name '*.swift' -not -path '*/.build/*'` |
| core + app Swift 行数 | **143,589** | 同上 `wc -l` 汇总 |
| 测试文件 | **174** | `check-test-catalog.sh`：core 105 + GatherTestSupport 3 + app 66 |
| Protocol 文件 / 行 | **70 / 6,514** | `check-protocol-surface.sh` |
| 当前 docs md 链接 | **146 / 缺失 0** | `check-docs.sh --strict` |
| `.build` 总量 | **11 GB** | 根 1.5G + desktop/native 1.0G + core 4.0G + app 4.9G |

> 说明：全仓 `find . -name '*.swift'` 为 622，其中约 20 个在 `Capture_One_Plugin_SDK` / `desktop/coplugin` / `scripts`，不属于 core/app；本报告后续“源码”均指 core+app 的 602 个文件。

### 1.2 门禁（全部实跑，exit 0）

| 命令 | 结果 |
| --- | --- |
| `./scripts/check-no-legacy.sh` | OK；enforced 7、tracked 6；`awaitSync` 0、Services 32、raw SQL 0、`@unchecked Sendable` 81、dual-track l10n 0、`batchAsync` 1 |
| `./scripts/check-duplicate-symbols.sh --strict` | OK；618 个 Swift；`batchAsync` 1；Tests/Support 外 0 |
| `./scripts/check-layering.sh --strict` | OK；17 条规则全 0 违规（GatherUI 187 文件、GatherApp 2、GatherHost 42、GatherAnalysis 14、GatherApplication 32、GatherPersistence 78） |
| `./scripts/check-test-catalog.sh --strict` | OK；测试文件 174、缺文件头 0、skip 3（`.enabled(if:)` 3） |
| `./scripts/check-test-catalog.sh --self-test` | SELFTEST OK |
| `./scripts/check-preview-surface.sh --strict` | PASS；`#Preview` 14 块 / 5 文件 / 2,031 行 |
| `./scripts/check-select-star.sh --strict` | OK；Sources 4 处 / 1 文件（baseline 6）、Tests 白名单 1 |
| `./scripts/check-protocol-surface.sh --strict` | OK；254 public 类型 / 1,338 声明行 / zero-reference 0 / Router 信封 0 |
| `./scripts/check-cleanup-ratchet.sh` | OK；unchecked 53/53、try? 231/231、services_prepare 0/0、todo 0/0、withKnownIssue 0/0 |
| `./scripts/check-docs.sh --strict` | OK；ADR 反引号路径 20（缺失 0）、当前文档链接 146（缺失 0）、reviews 26 篇（含本报告与并行报告）、schema 代码 2 / ADR 2 |
| `swift scripts/find-unused-symbols.swift --all --json` | 620 Swift / 444 source / 174 test / 4,326 public 声明；候选 **2**（均为 AppKit 回调） |

### 1.3 测试实测

命令（两包均加 `--disable-sandbox`，app 按仓规 `--no-parallel`）：

```bash
swift test --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
swift test --package-path desktop/native/gather-app  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
```

| 包 | 结果 | exit |
| --- | --- | ---: |
| gather-core | **1,100 tests / 165 suites passed**（3 skip，有效 1,097） | 0 |
| gather-app 首跑 | 617 / 68，**1 个用例 3 个 issue**（`CullingViewModelAPITests.swift:351-353`，`update` 的 undo/history 断言） | 1 |
| gather-app 隔离重跑 | `CullingViewModelAPITests` **16 / 1 passed** | 0 |
| gather-app 全量重跑 | **617 tests / 68 suites passed**（16.989s） | 0 |

判定：app 首跑失败为**既有 flake**（同一命令、同一源码，全量重跑与隔离重跑均绿；本轮只写报告，未改任何源码/测试）。日志：`/tmp/gather-final-cleanup-tests.log`、`/tmp/retry-culling.log`、`/tmp/app-rerun.log`。
**时点限制**：上述测试跑在“HEAD + 并行注释修复”的中间工作树（20:42–20:45）；20:57 后并行 agent 已继续删/改（JobScopeCheckpoint、makeGatherTestDB、GatherLocalization 等），当前树必须重跑测试后才能引用本数字，不能把它当最终验收。

> 旧基线数字（core 1,128/159、app 616/68）已过期：本轮实测 core **1,100/165**、app **617/68**。文件数变化来自并行重构，非本轮。
> **本报告所有“零引用”均指静态全仓 grep，不等价于运行期覆盖。**

### 1.4 未执行 / 限制

- **并行改动**：20:52 采样 `git status` 有 **29 个 M**（26 个文件头 + 3 个交付端口注释）；20:57 已增长到 **63 M / 1 D / 6 ??**，并行 agent 正在执行本报告 B01（删 `JobScopeCheckpoint`）、B02（`makeGatherTestDB` 改名）、B03（`GatherLocalization`）与 B10（docs）等项。这些修改**不是本任务做的**。报告仍按 HEAD 记录（因为任务指定 HEAD），但当前工作树中这些项已可能“已修/已删”。落地前先 `git diff --stat`；若变更已在，跳过对应批次，避免重复劳动或冲突。
- 未跑 `build.sh`（会写 `release/`，且本机 DSH 沙箱历史上拒绝 SwiftPM `sandbox-exec`）。
- 未做 GUI / 视觉 / 打包 / codesign 验收。
- `.build` 可能正被并行构建写入；删除命令必须先 `lsof`/mtime 确认。

---

## 2. A 档：确认零引用，可直接删（按风险从低到高）

### A01. 26 处错误文件头（注释，26 行）【已确认】

**证据**：逐文件取前 3 行，匹配 `desktop/native/....swift` 并与真实路径比较；26 个文件的首行路径不存在（`os.path.exists == 0`）。其中 **23 个仍写已删除的 `Sources/GatherDomain/Services/*`**，2 个写旧 `Sources/GatherAnalysis/Concurrent/*`，1 个写旧测试文件名。

23 个 GatherDomain 文件头：

```text
Sources/GatherProtocol/Protocol/MetadataContract.swift:1
Sources/GatherPersistence/Database/MetadataFingerprint.swift:1
Sources/GatherPersistence/Database/Repositories/PhotoAssetResolver.swift:1
Sources/GatherApplication/Services/TemplateService.swift:1
Sources/GatherApplication/Services/IndexerService.swift:1
Sources/GatherApplication/Services/ImagePreloadService.swift:1
Sources/GatherApplication/Services/CaptureOneSyncState.swift:1
Sources/GatherApplication/Services/ExportService.swift:1
Sources/GatherApplication/Services/JobService.swift:1
Sources/GatherApplication/Services/QualityService.swift:1
Sources/GatherApplication/Services/SimilarityService.swift:1
Sources/GatherApplication/Services/DuplicateService.swift:1
Sources/GatherApplication/Services/FilterEngine.swift:1
Sources/GatherApplication/Services/WorkspaceStatusService.swift:1
Sources/GatherApplication/Services/CullingService.swift:1
Sources/GatherApplication/Services/MetadataService.swift:1
Sources/GatherApplication/Services/ImageMetadataProviders.swift:1
Sources/GatherApplication/Services/SettingsService.swift:1
Sources/GatherApplication/Services/MetadataProviders.swift:1
Sources/GatherApplication/Services/SessionService.swift:1
Sources/GatherApplication/Services/PhotoAssets.swift:1
Sources/GatherApplication/Services/SettingsNumber.swift:1
Sources/GatherApplication/Services/NavigationService.swift:1
```

另外 3 个：

```text
Sources/GatherPersistence/Support/BatchCursor.swift:1          -> GatherAnalysis/Concurrent/BatchCursor.swift（不存在）
Sources/GatherPersistence/Support/BatchRunner.swift:1          -> GatherAnalysis/Concurrent/BatchRunner.swift（不存在）
Tests/GatherCoreTests/Delivery/DeliveryModuleRoutingTests.swift:1 -> DeliveryModuleAdapterTests.swift（文件已改名）
```

**处置**：把首行改成当前真实路径，或直接删除该行。**零行为影响**。
**并行状态**：20:52 工作树已把这 26 行全部改成真实路径（29 个 M 文件的一部分）；若该改动保留，则本项无需再做，直接进入 A02。
**验收**：重跑下面的脚本应输出 0：

```bash
python3 - <<'PY'
import os,re
bad=[]
for dp,dn,fn in os.walk('desktop/native'):
    if '/.build' in dp: continue
    for f in fn:
        if not f.endswith('.swift'): continue
        p=os.path.join(dp,f)
        head=open(p,encoding='utf-8').readline()
        m=re.search(r'(desktop/native/[^\s:*]+\.swift)',head)
        if m and m.group(1)!=p: bad.append((p,m.group(1)))
print(len(bad)); [print(x) for x in bad]
PY
```

### A02. `IndexerService.sha256File` 废弃别名（9 行）【已确认】

- 位置：`desktop/native/gather-core/Sources/GatherApplication/Services/IndexerService.swift:201-209`。
- 证据：`git grep -n 'IndexerService\.sha256File' -- '*.swift'` = **0**；生产与测试都直接用 `FileHasher.sha256File`（`DuplicateService.swift:316`、`AssetRepo.swift:390`、`FileHasherTests.swift:52/57/71/87/99` 等）。别名自身是 `@available(*, deprecated)`，注释也写明“过渡别名”。
- 处置：删 201-209（保留前面的历史说明可缩成 1 行）。
- 验收：`git grep -n 'IndexerService\.sha256File' -- '*.swift'` = 0；`swift build --package-path desktop/native/gather-core --disable-sandbox` exit 0。

### A03. `GatherProgressBar` 的 4 个废弃外观参数（约 20 行）【已确认】

- 位置：`desktop/native/gather-app/Sources/GatherUI/Support/GatherCommonViews.swift:106-113`（`track` / `border` / `height` / `cornerRadius`），以及 `:118-137` 的 init 参数和赋值。
- 证据：`GatherProgressBar` 全仓只有 **1 个**调用点 `Dashboard/JobRowView.swift:95`，只传 `fraction/fill/label/accessibilityText`；`git grep 'track:' -- '*.swift'` 仅命中声明本身（2 行），`border:`/`height:`/`cornerRadius:` 无调用。四个属性在 View 体内不参与布局（注释明确“现已忽略”）。
- 处置：删 4 个属性、init 的 4 个参数与 4 行赋值；`#Preview` 不受影响（14 块不变）。
- 验收：`git grep -nE 'GatherProgressBar|\.track:|\.border:' -- '*.swift'` 只剩唯一调用点；`check-preview-surface.sh --strict` = 14。

### A04. `GatherLocalization.appLocale`（6 行）【已确认】

- 位置：`.../GatherUI/Support/GatherLocalization.swift:422-427`。
- 证据：全仓实际读取 0；仅两处注释提到 `GatherLocalization.appLocale`（`C1StatusCapsule.swift:196`、`L10n.swift:118`）。`L10n` 有自己的 `locale`。
- 处置：删 422-427（含注释）。
- 验收：`git grep -n 'GatherLocalization\.appLocale' -- '*.swift'` = 0（注释同步改）。

### A05. 两个未读私有常量（2 行）【已确认】

| 位置 | 证据 |
| --- | --- |
| `GatherApplication/Services/CullingService.swift:75` `private static let chunkSize = 800` | 本文件内除声明外 0 次引用；分块 SQL 已下沉到 Persistence |
| `GatherApplication/Services/NavigationService.swift:82` `private static let qualityChunkSize = 800` | 同上，0 次引用 |

- 处置：删 2 行及各自 1 行注释；不影响任何 API。
- 验收：`swift build` exit 0；两文件的 `chunkSize` grep = 0。

### A06. `VectorIndex.Candidate`（5 行）【已确认】

- 位置：`desktop/native/gather-core/Sources/GatherAnalysis/Face/VectorIndex.swift:314-318`。
- 证据：`grep -n '\bCandidate\b'` 在本文件只命中声明；`verifyCandidates` 的参数名是 `candidates`，类型并非该 struct。全仓无 `Candidate(` 构造。
- 处置：删 314-318。
- 验收：`swift test --package-path desktop/native/gather-core --filter VectorIndex` exit 0。

### A07. 9 个零调用私有测试 helper（112 行）【已确认】

判定：`^private func <name>` 在文件内除声明外出现 0 次；无 `#selector`、无字符串引用、非 `@Test` 入口。

| 文件:行 | 行数 | 备注 |
| --- | ---: | --- |
| `Tests/GatherAppTests/IndexHeaderCopyTests.swift:87-97` `percentMatrix` | 11 | 旧矩阵 helper |
| `Tests/GatherAppTests/IndexHeaderCopyTests.swift:268-275` `inlinePercentMatrix` | 8 | 同上 |
| `Tests/GatherAppTests/DashboardViewModelTests.swift:612-639` `terminalFrameMatrix` | 28 | 断言已内联 |
| `Tests/GatherAppTests/GlobalInfraTests.swift:29-38` `errorTextMatrix` | 10 | 与 `L10n` 测试迁移后遗留 |
| `Tests/GatherAppTests/WorkspaceStageMarksTests.swift:53-62` `marksMatrix` | 10 | 同上 |
| `Tests/GatherAppTests/CullingSyncFlowTests.swift:103-113` `deriveControlsMatrix` | 11 | 同上 |
| `Tests/GatherAppTests/CullingSyncFlowTests.swift:129-133` `syncFlowStateMatrix` | 5 | 同上 |
| `Tests/GatherAppTests/ReviewFixTests.swift:251-264` `renderedCenter` | 14 | 旧布局断言 |
| `Tests/GatherCoreTests/Services/DeliveryCoordinatorTests.swift:264-278` `makeWrittenDelivery` | 15 | 夹具未接线 |

- 处置：逐个删；**测试例数不变**（这些不是 `@Test`）。
- 验收：`swift test` 总数与删除前一致；`check-test-catalog --strict` 仍 174 文件。
- 若担心“未来可能用”，可先只删 5 个最短的（`inlinePercentMatrix`、`syncFlowStateMatrix`、`errorTextMatrix`、`marksMatrix`、`deriveControlsMatrix`），把 3 个 15+ 行的留到 B。

### A08. `FaceSimMutationPort`（28 行）【已确认】

- 位置：`desktop/native/gather-app/Tests/GatherAppTests/APIFaceSimilarityTests.swift:124-151`（含 1 行文档注释，共 28 行）。
- 证据：`git grep -n 'FaceSimMutationPort' -- '*.swift'` 只有声明 1 行；该测试用的是另一个 `Fake...Port`。
- 处置：删 124-151。
- 验收：`swift test --package-path desktop/native/gather-app --filter APIFaceSimilarity` exit 0。

### A09. 4 处过期交付端口注释（注释，约 10 行）【已确认】

| 位置 | 过期描述 | 事实 |
| --- | --- | --- |
| `GatherDelivery/Ports/DeliveryModulePorts.swift:14-15` | “旧端口协议保留为面向 feature 的窄接口…把 14 个名字转发到 5 个适配器方法” | 本文件已无旧端口协议/14 个转发；只有 `DeliveryEngine` + `DeliveryModuleAdapter` |
| `GatherDelivery/Coordinator/DeliveryCoordinator.swift:15-16` | “15 个 culling/face/similarity 转发方法…见 `Ports/DeliveryModuleAdapter.swift`” | 文件名不存在（实际 `DeliveryModulePorts.swift`），且 WP2c 已删转发 |
| `GatherDelivery/Types/DeliveryTypes.swift:269-273` | “S5c-2a 过渡默认；宿主未注入 `CullingDeliveryPort` 时…S5c-2b 接线” | `CullingDeliveryPort` 已不存在；宿主默认走 `XMPDeliveryFilePort` |
| `Tests/.../DeliveryModuleRoutingTests.swift:1` | 文件头写 `DeliveryModuleAdapterTests.swift` | 实际文件名 `DeliveryModuleRoutingTests.swift` |

- 处置：删除“旧端口仍保留”的句子，改为当前 5+3 面；Coordinator 注释改为指向 `DeliveryModulePorts.swift`；Types 注释只保留 `FileSystemDeliveryFilePort` 的测试用途。
- 验收：`git grep -n 'CullingDeliveryPort\|Ports/DeliveryModuleAdapter.swift' -- '*.swift'` = 0（若保留历史说明，必须标“已删除”并加粗）。
- 关联：`DeliveryModulePorts.swift:4-5` 的“迁移前”历史说明是准确的，**保留**。

### A10. 构建产物（11 GB，非源码）【已确认】

- 实测：`.build` 1.5G、`desktop/native/.build` 1.0G、`gather-core/.build` 4.0G、`gather-app/.build` 4.9G。
- 证据：`git ls-files | grep '\.build/'` = **0**（全部 ignored）；但内容里仍有已删除 target 的产物：
  - `desktop/native/.build/scratch/out/Products/Debug/GatherDomain.swiftmodule`、`libGatherDomain.a`、`GatherDomain.o`
  - `gather-app/.build/out/Products/Release/GatherCore.swiftmodule`、`gather-core_GatherCore.bundle`
  - `gather-app/.build/out/Intermediates.noindex/.../GatherDomain-t.build`
- 处置（先确认无活动构建）：
  ```bash
  pgrep -fl 'swift-build|swift test|swiftc' || true
  rm -rf desktop/native/.build/scratch-check desktop/native/.build/release-scratch
  # 彻底回收（会强制下次全量重建）：
  swift package --package-path desktop/native/gather-core clean
  swift package --package-path desktop/native/gather-app clean
  ```
  根 `.build` 与 `desktop/native/.build` 只在确认无并行构建后删。
- 验收：`du -sh` 下降；`git status --ignored` 仍只显示 `!! .build/`；`swift build` 能从零通过（CI 已覆盖）。

### A11. Package 清单里的“四层 / 四个分层 product”注释（4 处）【已确认】

| 位置 | 过期写法 | 事实 |
| --- | --- | --- |
| `gather-core/Package.swift:2` | “四层 target” | 5 个分层 target（Protocol / Persistence / Delivery / Analysis / Application） |
| `gather-core/Package.swift:41` | “4 个分层库” | 紧接的 products 列了 5 个库（含 GatherDelivery） |
| `gather-app/Package.swift:5` | “依赖四层 core” | 依赖 5 个 core product |
| `gather-app/Package.swift:7` | “只依赖四个分层 product” | 同上；下一行依赖清单还漏了 GatherDelivery |

- 处置：把“四层/四个”改为“五个分层（Protocol / Persistence / Delivery / Analysis / Application）”；app 的依赖箭头补上 Delivery。
- 验收：`git grep -nE '四层|4 个分层|四个分层' -- '*.swift' ':!docs/archive/**'` 只剩历史/已删除说明。
- 风险：纯注释；但 Package.swift 是构建清单，改动后建议 `swift build` 一次确认未误触语法。

---

## 3. B 档：需迁移 / 测试后删

### B01. `JobScopeCheckpoint`（22 行，生产 0 引用，测试 3 处）【已确认；纠正两份旧报告】

- 文件：`desktop/native/gather-app/Sources/GatherUI/Support/JobScopeCheckpoint.swift:13-21`；全文件 22 行。
- 证据：
  - `git grep -n 'JobScopeCheckpoint' -- '*.swift'`：**1 个定义 + 2 行 GatherApp 注释 + 5 行测试断言**（`APISessionTests.swift:113/176`、`DashboardViewModelTests.swift:413/489/491`）。
  - `JobScopeCheckpoint.make` 的调用点 = **0**；生产代码没有任何地方引用它。
  - 协议层已有单一真相源：`GatherProtocol/API/Inputs/JobInputs.swift:30` `JobCreateParams.metadataScanRequestedPathsKey = "requestedPaths"`，以及 `:34-39` `metadataScanCheckpoint(requestedPaths:)` 生成同形载荷。
  - `GatherHost/ExecutorRegistry.swift:169-170` 读的是字面量 `"requestedPaths"`；`AppImport` / Dashboard 也走 `JobCreateParams.metadataScan` 工厂。
- 结论：`JobScopeCheckpoint` 是重复常量 + 死转发。两份旧报告（`final-cleanup-core.md:37`、`final-cleanup-docs.md:34`）称其“被 LiveSessionAPI / Dashboard 引用”，**与实测不符**。
- 迁移（3 处测试）：
  ```swift
  // 旧
  scan.checkpoint[JobScopeCheckpoint.requestedPathsKey]
  // 新
  scan.checkpoint[JobCreateParams.metadataScanRequestedPathsKey]
  ```
- 删除：`JobScopeCheckpoint.swift` 整文件（22 行）；同步删 `GatherApp.swift:8/111` 注释中的名字。
- 验收：`git grep -n 'JobScopeCheckpoint' -- '*.swift'` = 0；`swift test --package-path desktop/native/gather-app --filter 'APISession|DashboardViewModel'` exit 0。

### B02. `makeGatherTestDB` 别名（22 调用点 / 18 文件）【已确认】

- 定义：`Tests/GatherAppTests/Support/TestSupportReexports.swift:17-20`（4 行，含注释）。
- 调用：**22 处**，分布 18 个文件（`APICullingTests` / `APIDuplicateQualityTests` / `APIExportMetadataTests`×2 / `APIFaceSimilarityTests` / `APIFaceTests` / `APIPersonTemplateTests`×2 / `APIPhotoTests` / `APISessionTests` / `APISimilarityTests` / `AppCompositionTests` / `AppRuntimeTests`×2 / `DashboardViewModelTests`×2 / `ExecutorRegistryTests` / `GalleryViewModelTests` / `GatherAppDelegateTests` / `LayoutBudgetTests` / `LibraryViewModelTests` / `SimilarityViewModelTests`）。另有 2 处在转发文件自身（注释 + 函数体）。
- 证据：文件头注释自己写明“并行工作区收尾后，把 22 处调用点改名为 makeTestDB，再删除本转发”。
- 处置：`sed` 级替换 22 处 → `makeTestDB()`；删 `TestSupportReexports.swift:17-20`（`AsyncGate` / `LockedBox` 两个 typealias 仍被使用，保留文件）。
- 验收：`git grep -n 'makeGatherTestDB' -- '*.swift'` = 0；app 测试数不变；`check-duplicate-symbols --strict` exit 0。

### B03. `GatherLocalization` 旧翻译函数（7 个入口，约 73 行，测试 parity 钉住）【已确认】

- 仍在线上的只有：`errorMessages`（179 码表，`CommandError.swift:124/142` 与 `L10n.swift:332/339` 读取）、`jobStatusKeys` / `jobTypeKeys` / `progressPhaseKeys`（`L10n.swift:275/281/287`）、`appLanguage` / `setAppLanguage`（`LanguageStore.swift:40/73/90/110/114-115`，兼容桥）、`errorText` 等旧入口仅测试用。
- 零生产调用的成员（均为 `public static`）：
  - `errorText(_:)` `:251-254`
  - `jobErrorMessage(_:)` `:295-299`
  - `message(for:)` `:303-314`
  - `cancellationNotice(_:)` `:323-325`
  - `jobStatusText(_:)` `:342-345`
  - `jobTypeText(_:)` `:358-362`
  - `progressPhaseText(_:)` `:394-397`
  - 合计约 **53 行**；连带 `resolvedTemplate` / `interpolate` / `l` 只在测试与旧函数内部使用（若全删，再减约 20 行）。
- 证据：`git grep -n 'GatherLocalization\.' -- '*.swift'` 的非测试命中只有 `appLanguage` / `setAppLanguage` / `errorMessages` / `*Keys`；`LocalizationParityTests.swift:427-445` 与 `GlobalInfraTests.swift:50-98` 在测试侧钉住旧函数与 `L10n` 的逐字 parity。
- 处置：先把 parity 测试改为只比较表/键（或直接对 `L10n` 断言），再删旧函数；`l` 若仅测试使用，一并删。**不要**删 `errorMessages` / 三张 key 表 / `appLanguage` 兼容桥。
- 验收：`git grep -nE 'GatherLocalization\.(errorText|jobErrorMessage|message\(for:|cancellationNotice|jobStatusText|jobTypeText|progressPhaseText)' -- '*.swift'` = 0；`LocalizationParityTests` / `GlobalInfraTests` 绿。

### B04. core/app 逐字重复的测试装配支持（344 行）【已确认】

- 两个文件：
  - `desktop/native/gather-core/Tests/GatherCoreTests/Support/ServiceConstructionTestSupport.swift`（348 行）
  - `desktop/native/gather-app/Tests/GatherAppTests/ServiceConstructionTestSupport.swift`（346 行）
- 证据：`diff -u` 只有前 2 行文件头不同，**其余 344 行逐字相同**；内容是 13 个 `extension XxxService` 的 convenience init。
- 处置：把公共体移入 `Tests/GatherTestSupport/ServiceConstructionTestSupport.swift`；给 `GatherTestSupport` 增加 `GatherApplication` 依赖（无环：Application 不依赖 TestSupport），两个测试 target 都 `import GatherTestSupport`，删两份副本。
- 验收：`diff` 两文件不再存在；core+app 测试绿；`check-layering --strict` 仍 0（测试 target 不受生产 layering 规则约束）。
- 注意：这是一次**测试 target 结构变更**，单独成批，不与 A 档混做。

### B05. 5 组重复 helper（约 250 行重复）【已确认，按收益排序】

| # | 重复 | 证据 | 建议落点 |
| --- | --- | --- | --- |
| 1 | `orderedUnion` 3 份 | `LiveSimilarityAPI.swift:294-301`、`FaceKwService+Writeback.swift:247-253`、`WritebackService.swift:1245-1252`；前两份逐字等价，第三份 O(n²) | `GatherProtocol` 或 `Persistence/Support` 的 `orderedUnion`；三处改调用 |
| 2 | `parseBbox` 2 份 | `FaceKwService+Review.swift:346-352` 与 `FaceRepo.swift:1173-1179` 逐字相同 | `GatherProtocol` 的 `JSONValue` 扩展 |
| 3 | `patchFields` 2 份 | `CullingViewModel+Actions.swift:73-79` 与 `CullingService+Commands.swift:668-674` 逐字相同 | `CullingUpdatePatch.fields` 计算属性（Protocol） |
| 4 | `toFaceKwItem` / `toWritebackItem` 各 2 份 | `LiveFaceAPI.swift:349-380` 与 `FaceKwWritebackBridge.swift:87-134` | 抽到 `FaceKwWritebackBridge` 的 `static` 转换，LiveFaceAPI 复用 |
| 5 | `translate(_:)` 7 份 | 7 个 `Live*API` 私有函数，共同臂：`GatherError` 直传、`JobServiceError.jobFailed` 转码、`DBError.message` 转码 | `LiveAPIErrorMapping` 增加通用 `translateDomain(_:)`，各 API 只留域特有分支 |

- 处置：每组独立的 1 个 PR/批次；先补等价的表驱动测试，再删副本。
- 验收：`git grep -n 'func orderedUnion' -- '*.swift'` = 1；其余同理；对应测试绿。
- 备注：`loadFailureState`（`DashboardView.swift:227-239` vs `LibraryView+Content.swift:56-68`）只有 8 行差异且页面文案不同，**建议不合并**（C 档），除非同时做通用 `ContentUnavailableState` 组件。

### B06. `GatherDomainChange` 命名残留（16 处 / 11 文件）【已确认】

- 定义：`GatherUI/Support/GatherEventCenter.swift:56`。
- 证据：`git grep -n 'GatherDomainChange' -- '*.swift'` = **16 处 / 11 文件**；其中生产 13 处、测试 3 处。同文件 `:25` 的枚举已经叫 `GatherChangeDomain`（D-169 的改名），payload 仍以已删除模块名 `GatherDomain` 开头，形成两套词序。
- 处置：改名 `GatherChangeEvent`（或 `GatherDomainChangeEvent`），全量 16 处；注释同步。
- 验收：`git grep -n 'GatherDomainChange' -- '*.swift'` = 0；`swift test --filter 'LibraryViewModel|CullingViewModelAPI'` 绿。
- 分类说明：不是死代码，但属于“旧模块名残留”，且改名面小（16 处），适合在 B 批一次做掉。

### B07. `Sync` 命名残留（公共协议面）【已确认，改名成本高】

- 代表：`MetadataSyncStatus`（`Protocol/Culling.swift:58`）、`MetadataSyncItem`（`:357`）、`MetadataSyncSummary`（`:378`）、`CullingSyncStatus`（`API/Outputs/CullingOutputs.swift:10`）、`CullingAPI.syncStatus/flush/retrySync/finalizeSync`。
- 证据：`MetadataSyncSummary` 全仓 **89 处**（生产 + 测试 + stub）；`syncStatus` 201 处（含 UI/API）。这些是**协议契约**，不是零引用。
- 判断：`Sync` 在这里是 Capture One 的“元数据同步”领域语义（`MetadataSyncStatus` 的 7 态 + reload ack），不是旧模块路径残留；如果产品词表仍叫 sync，**建议保留**（C）。若要统一为 Delivery，属于 API breaking，需单列 D-xxx，不能混在清理批。
- 处置：本轮**只清注释**（`MetadataSyncSummary` 已由 DeliverySummaryQuery 投影，可在类型注释写“delivery projection, 保留旧名以兼容协议”），不改名。

### B08. `FileSystemDeliveryFilePort`（生产 0 引用，测试 7 处）【已确认】

- 位置：`GatherDelivery/Types/DeliveryTypes.swift:269-...`。
- 证据：生产 0 构造；测试 7 处（core `ServiceConstructionTestSupport.swift:173/246/287`、app 同名文件 `:173/246/287`、`CullingServiceTests.swift:1535`）。生产默认已在 `DeliveryCoordinator.swift:140` 注入 `XMPDeliveryFilePort`。
- 处置：若要删，先把测试改用 `XMPDeliveryFilePort` 或测试内 `FakeDeliveryFilePort`，再删类型；**不要**只删类型导致测试红。
- 验收：`git grep -n 'FileSystemDeliveryFilePort' -- 'desktop/native/gather-core/Sources'` = 0；core 测试绿。

### B09. `RELEASE=1` 旧别名（build.sh:34-35）【已确认，兼容层】

- 证据：`RELEASE` 只出现在 `build.sh:34-35`；CI / docs 当前全部用 `GATHER_RELEASE`；`docs/reviews/wp6-schema-migration-design.md:491` 是历史设计稿。
- 处置（breaking 口径）：删 `RELEASE` 回退，只认 `GATHER_RELEASE`；更新 `DEVELOPMENT.md:112`（若仍提旧别名）。
- 验收：`GATHER_RELEASE=1 ./desktop/native/build.sh` 行为不变；`grep -n 'RELEASE=' desktop/native/build.sh` 不再出现旧别名。

### B10. 当前文档口径刷新（见 §5.9 的精确行号）

- 只改**当前**文档：根 `README.md`、`docs/README.md`、`docs/DEVELOPMENT.md`、`docs/ROADMAP.md` 的当前基线行、`.github/workflows/ci.yml:78-79` 注释。
- **不要**改 `docs/reviews/**` 与 `docs/archive/**`（快照）；`docs/final-cleanup-*.md` / `refactor-progress` / `refactor-decisions` 中的日期化历史条目可保留，只在“当前口径”段落更正。
- 验收：`git grep -nE 'user_version=1|GatherDomain|7 target|Sources/GatherTestSupport' -- README.md docs/README.md docs/DEVELOPMENT.md docs/ROADMAP.md` 只剩“历史/已删除”说明；`check-docs --strict` exit 0。

---

## 4. C 档：保留（协议 / 动态 / 测试契约）

| 候选 | 位置 / 规模 | 保留理由 |
| --- | --- | --- |
| `applicationShouldTerminate` / `applicationSupportsSecureRestorableState` | `GatherAppDelegate.swift:305/542` | `find-unused-symbols` 的 2 个候选；NSApplicationDelegate 动态调用，删了会失去系统行为 |
| 旧 Protocol DTO（旧报告口径 112 个，未逐项复算） | `Sources/GatherProtocol/Protocol/*` | 被 `*ContractTests` 逐字段钉住；删除需同批重写约 197 例（旧报告已登记 D-001/D-007）；本轮 `check-protocol-surface` 显示 254 public 类型、zero-reference 0 |
| `DeliveryModule.template/.metadata` | `Persistence/Database/DeliveryState.swift:120-121` | Schema CHECK 的真实落库值 + 解码路径；不能因当前无专属接线而删 |
| `DeliveryModuleCapability` / `unsupportedCapability` | `DeliveryModulePorts.swift:42-80` | 新协议面，测试 `DeliveryModuleRoutingTests` 钉住；不是旧端口 |
| `MetadataSync*` / `syncStatus` | 见 B07 | Capture One 同步领域词表；改名是 API breaking，不是死代码 |
| 历史 `Cut/WP/S5c/Phase` 注释 | 744 / 219 / 130 / 79 行 | 决策溯源；只修“声称当前路径”的句子，不做全量删除 |
| `docs/archive/**`、`docs/reviews/**` | 26 篇 reviews；旧报告记录 33 条 archive 源码链接（未逐条复算） | 快照，按 archive 索引说明保留；`check-docs` 不检查 archive 正文 |
| `CaptureOneSyncState` | `GatherApplication/Services/CaptureOneSyncState.swift` | Host/UI 仍经端口调用 `aggregateSessionState`，不是死代码 |
| `AppLanguageStorage` / `LocalizationBundleCache` | `GatherLocalization.swift:12-59` | 仍被 `appLanguage` / `l` 使用；只删其上的旧翻译函数（B03） |
| `@available(deprecated)` 的 `GatherProgressBar` 参数 | 见 A03 | 本轮判 A；若产品要求保留公开初始化兼容，则降为 C（但仓库当前无调用点） |

---

## 5. 逐项扫描结果

### 5.1 旧 `GatherDomain` 路径 / 注释

- 源码命中 `GatherDomain` **64 行 / 30 文件**，拆开：
  - **23 行**是 A01 的错误文件头（删/改）。
  - **6 行**是仍把 `Sources/GatherDomain/Services/*` 当现状的注释：
    - `GatherHost/CaptureOneSyncStateAdapter.swift:5`
    - `GatherHost/ImportPathRulesAdapter.swift:6`
    - `GatherUI/Settings/SettingsViewModel+Catalog.swift:56`
    - `GatherUI/Support/CaptureOneSyncStatePort.swift:5`
    - `GatherUI/Dashboard/DashboardViewModel+Actions.swift:62`
    - `Tests/GatherAppTests/SimilarityViewModelTests.swift:98`
  - **13 行**是 `GatherDomainChange` 类型（B06；不是模块引用）。
  - 其余是准确的历史说明（`Package.swift:92` “WP3a 纯重命名”、`SessionErrors.swift:3` / `XMPProvider.swift:3` “从 GatherDomain 上移/下移”、`FileHasher.swift:7` / `ScanPath.swift:7` “不能 import GatherDomain 时代”），**保留**或改写成“旧模块名”即可，属 C。
- 当前 docs 仍有 **5 行**把 `GatherDomain` 当现存模块（README 2、DEVELOPMENT 2、docs/README 1）；历史账本/评审中的引用不计（D-169 已记录重命名）。见 §5.9。

### 5.2 旧 feature delivery 端口

- **代码符号 0**：`CullingDeliveryPort` / `FaceKwDeliveryPort` / `SimilarityDeliveryPort` / `FeatureDeliveryPorts` / `DeliverySink` / `FileDelivery` 在 `*.swift` 中只剩注释命中。
- 旧协议确实已删除；现存的是 `DeliveryEngine`（6 操作）+ `DeliveryModuleAdapter`（5 方法 + module/capabilities/engine）+ `CoordinatorDeliveryAdapter`。
- 残留是 **4 处注释**（A09）+ `FileSystemDeliveryFilePort` 测试用类型（B08）。`docs/reviews/architecture-remediation-status.md:14` 的“删除 FeatureDeliveryPorts 与 14 个旧转发”是历史记录，保留。

### 5.3 `sync` 命名残留

- 文件/类型层面的 `Sync`：`CaptureOneSyncStatePort.swift`、`SessionControlView+Sync.swift`、`SettingsViewModel+Sync.swift`、`SimilarityViewModel+Sync.swift`、`CullingSyncFlowTests.swift`、`CaptureOneSyncState.swift`。
- 其中 `CaptureOneSyncState` 是 C1 同步状态机（领域语义，保留）；`MetadataSyncSummary/Status/Item` 是交付投影的旧名（B07，建议保留并注记）。
- `syncStatus` 有 201 处，**不能**按“残留”批量删；它是 `CullingAPI` 的公开方法与 UI 状态字段。
- 唯一可低成本清的是注释：`DeliveryCoordinator.swift:15-16`、`DeliveryModulePorts.swift:14-15`、`DeliveryTypes.swift:269-273`（A09）。

### 5.4 `RequestGate` / `ViewState`

- 源码 / 测试：**0**（`git grep -E 'RequestGate|ViewState' -- '*.swift'` 无命中）。
- 仅 `scripts/check-duplicate-symbols.sh:9` 有一行历史说明，和 docs 中“已删除”的记录。
- 结论：**已闭环**，无需再动。唯一文档噪声：`docs/final-cleanup-app.md:35` 仍说 `LoadPhase` 有两处 `ViewState` 引用；实测 `LoadPhase.swift:1-23` 已无，属过期描述（B10 文档刷新）。

### 5.5 `JobScopeCheckpoint`

见 B01。补充：`GatherUI/Support/JobScopeCheckpoint.swift` 22 行；`JobScopeCheckpoint.make(requestedPaths:)` 与 `JobCreateParams.metadataScanCheckpoint(requestedPaths:)` 生成完全相同的 `[String: JSONValue]`；保留它只会制造两个“唯一真相源”。

### 5.6 `makeGatherTestDB` 别名

见 B02。补充：`git grep -c 'makeGatherTestDB' -- '*.swift'` 合计 **24**（22 调用 + 2 在转发文件）；`TestSupportReexports.swift` 共 20 行，删除转发后剩 16 行（`AsyncGate` / `LockedBox` 仍需保留）。

### 5.7 旧 INFO / 版本 / Phase 注释

- `// INFO` / `INFO:` 在 `*.swift` 中 **0** 命中；没有老式 `INFO` 块。
- 版本注释分为三类：
  1. **真过期**：`GatherCore` / `GatherDomain` 的模块描述（A01、B06），以及 docs 的 `user_version=1` / 7 target（§5.9）。
  2. **有意保留的回退值**：`Info.plist` 的 `3.0.0`、`build.sh:69/110/279` 的 “local fallback”，与发布注入逻辑一致，**保留**。
  3. **历史 Phase/WP/Cut/S5c 标记**：79 / 219 / 744 / 130 行，作为迁移溯源保留；只修其中声称“当前仍是 GatherCore/GatherDomain”的 10 行（`DashboardView.swift:2`、`DashboardViewModel.swift:2`、`GalleryView.swift:2`、`LibraryView.swift:2`、`SimilarityView.swift:2`、`FaceKwWritebackBridge.swift:2`、`SidecarXMPProvider.swift:19`、`ExportService.swift:4`、`RAWDecoder.swift:19`、`Protocol/Culling.swift:9-10`），改为 `GatherApplication` / `core`。
- `docs/DEVELOPMENT.md:99` 的 `3.0.0` 与 `build.sh` 一致，保留。

### 5.8 重复 helper（已确认清单）

| 组 | 副本 | 重复行数（估） | 结论 |
| --- | --- | ---: | --- |
| `ServiceConstructionTestSupport` | 2 | **344** | B04，收益最大 |
| `orderedUnion` | 3 | 24 | B05-1 |
| `parseBbox` | 2 | 14 | B05-2 |
| `patchFields` | 2 | 14 | B05-3 |
| `toFaceKwItem` / `toWritebackItem` | 2×2 | ~100 | B05-4 |
| `translate(_:)` | 7 | ~100（共同臂 ~35） | B05-5，先抽公共臂 |
| `loadFailureState` | 2 | 26（8 行差异） | **C**：不同页面文案，合并收益低 |
| `normalizedPath` | 2 | 10 | **C**：空串 vs 空白语义 + 不同错误类型，合并需统一校验口径 |
| `isDirectory` | 2 | 8 | **C**：`lstat`（防符号链接） vs `FileManager`，语义不同，不是重复 |
| `normalize` | 2（不同命名空间） | 4 | **C**：一个是 sidecar 归一化，一个是 `standardizingPath` |
| `requireNonBlank` / `map` / `mapAsync` | 7 / 9 / 6 份 | ~100 | 每份的 `Self.translate(error)` 域映射不同；旧报告已评为“合并风险大于收益”，维持 C（若做，先统一 translate 再抽 wrapper） |

### 5.9 docs 过期口径（P1）

| 文件:行 | 当前写法 | 实测 |
| --- | --- | --- |
| `README.md:95` | `GatherDomain（服务编排…）` | 模块已删；服务在 `GatherApplication`，交付在 `GatherDelivery` |
| `README.md:101-103` | “seven targets … `GatherDomain`” | 8 个功能 target：Protocol / Persistence / Delivery / Analysis / Application / UI / Host / App（另有 TestSupport） |
| `README.md:96` | `SchemaV1（43 表 / 373 列 / user_version=1）` | 当前 `user_version=2`（V1 快照仍为 1）；`Schema.swift:13`、`Database.swift:6`、`gather-schema verify` 均 2 |
| `docs/README.md:26-29` | 7 target + `GatherDomain` | 同上 |
| `docs/README.md:30` | `user_version=1` | 2 |
| `docs/README.md:38` | “7 target … user_version=1” | 8 target / 2 |
| `docs/DEVELOPMENT.md:35` | “4 个库 target” | 5 个 library product（Protocol/Persistence/Delivery/Analysis/Application）+ TestSupport |
| `docs/DEVELOPMENT.md:39` | `Sources/GatherDomain/` | 实际 `Sources/GatherApplication/` + `Sources/GatherDelivery/` |
| `docs/DEVELOPMENT.md:40` | `Sources/GatherTestSupport/` | 实际 `Tests/GatherTestSupport/`（Package.swift:106 `path: "Tests/GatherTestSupport"`） |
| `docs/DEVELOPMENT.md:196-197` | `GatherDomain 服务` + `user_version=1` | Application + Delivery / 2 |
| `docs/DEVELOPMENT.md:221` | `43 表 / 373 列 / 69 索引 / 62 FK / user_version=1` | 数字对，版本 2 |
| `docs/ROADMAP.md:84` | “7 个 target（…Domain…）” | 8 target |
| `docs/ROADMAP.md:112` | `user_version=1` | 2（该行还写 SchemaV1；V1 快照确实 1，但“当前”应写 2） |
| `.github/workflows/ci.yml:78-79` | “验证 43 表 / user_version=1” | verify 实际断言 2；注释过期 |
| `docs/cleanup-backlog.md:130` | “当前口径 … 7 target … user_version=1” | 过期 |
| `docs/final-cleanup-core.md:37` | “JobScopeCheckpoint … 被 LiveSessionAPI/Dashboard 引用” | 生产 0 引用（B01） |
| `docs/final-cleanup-docs.md:34` | 同上 | 同上 |
| `docs/final-cleanup-docs.md:57` | “535 文件 / 137 链接” | 本轮 602 native 文件 / 146 链接；属快照数字，可保留但应标时点 |

**处置原则**：当前文档改事实；带日期的报告只加“时点”或“已被后续变更取代”，不回填成新数字。`docs/ADR.md` 的 V1 历史迁移描述是正确的（`：69/88` 明确 V1=1、current=2），**不要改**。

### 5.10 scripts / CI

- **脚本路径**：`scripts/*.sh` 中 20 个唯一硬编码 `desktop/native/...` 路径全部存在；无死路径（Python 校验 0 缺失）。
- **脚本门禁缺口**：
  - `find-unused-symbols.swift` 只在本地跑，CI 的 `gates` 未调用（B 档：加一步，允许 `--json` 断言 `candidate_count <= 2`，但 2 个是 AppKit 回调，需 allowlist）。
  - `check-protocol-surface.sh --strict` 未进 CI；当前 0/0，可加。
  - `check-docs.sh` 只检查 ADR 反引号路径 + md 链接，**不检查** `docs/DEVELOPMENT.md` 目录树/代码块中的路径，也不检查 `user_version` 文案；因此 §5.9 的过期能全绿通过（B 档：加目录树/版本断言，或至少在 PR 模板人工核对）。
  - `check-no-legacy.sh` 的 `awaitSync` tracked 为 0，可升级为 enforced 0；`batchAsync` 仍 1（`BatchRunner.swift:50`，保留到对应 Cut）。
- **CI 未用变量**：未发现。`GATHER_ARCHS` / `GATHER_NOTARIZE` / `GATHER_NOTARY_PROFILE` / `APPLE_*` 均由 `build.sh` 消费；`MACOS_CERT_*` / `KEYCHAIN_PASSWORD` 由 “Import Developer ID certificate” step 消费；`INPUT_VERSION` 在 release 版本解析中使用。唯一冗余是 `boundary` 与 `gates` 两个 job 各跑一次 `check-no-legacy.sh`（可合并，非错误）。
- **CI 发布残留**：`release/` 当前不存在；`.gitignore` 忽略 `release/`、`*.app`、`desktop/release/`。`ci.yml:200-220` 的 `release/Gather.app` / `Gather.zip` 是 job 产物路径，不是仓库残留。
- **`.build` 产物**：见 A10；另有 `desktop/native/.build/scratch-check`、`release-scratch`，均为非活动 scratch，可删。

### 5.11 其他旧名

- `GatherCore`（伞 target）：已删除；仍有 10 行生产注释把它当现存模块（§5.7 列表），4 行测试注释。`GatherCoreTests` / `GatherCoreBenchmarks` 是合法 target 名，**不要**批量替换。
- `makeMigratedDB`：源码/测试 **0**（仅 docs 历史记录）；已完成，无需动作。
- `INFO` 块：0。
- `RequestGate` / `ViewState`：0（§5.4）。

---

## 6. 可执行清理批次（避免大爆炸）

> 每批都独立可回滚；批次内先改注释/死成员，再跑门禁，最后跑对应测试。命令均从仓库根执行。

### 批次 0：构建产物（不动源码，先回收空间）

```bash
# 先确认没有活动构建
pgrep -fl 'swift-build|swift test|swiftc' || true
rm -rf desktop/native/.build/scratch-check desktop/native/.build/release-scratch
# 可选：彻底回收两包增量缓存（下次全量重建）
swift package --package-path desktop/native/gather-core clean
swift package --package-path desktop/native/gather-app clean
```

**验收**：`du -sh .build desktop/native/.build desktop/native/gather-core/.build desktop/native/gather-app/.build` 显著下降；`git status --porcelain` 为空；`git ls-files | grep '\.build/'` = 0。
**风险**：若并行 agent 正在构建，先不删；至少保留 `desktop/native/.build/shared-cache`。

### 批次 1：零行为注释与文件头（A01 + A09 + §5.7 的 10 行）

**文件**：26 个文件头 + `DeliveryModulePorts.swift:14-15` + `DeliveryCoordinator.swift:15-16` + `DeliveryTypes.swift:269-273` + `GatherCore` 的 10 行注释 + 4 处 Package 清单“四层”注释（A11）。
**先对账**：`git diff --stat` 若已含这 29 个文件，跳过已修部分（尤其 A01/A09）；不要用全仓 sed 覆盖并行 agent 的改动。
**命令**：逐文件改首行/注释；不要用全仓 sed 替换 `GatherDomain`（会误伤 `GatherDomainChange` 和历史说明）。
**验收**：
```bash
# 文件头错误应为 0
python3 - <<'PY'
import os,re
bad=[]
for dp,dn,fn in os.walk('desktop/native'):
    if '/.build' in dp: continue
    for f in fn:
        if f.endswith('.swift'):
            p=os.path.join(dp,f); line=open(p,encoding='utf-8').readline()
            m=re.search(r'(desktop/native/[^\s:*]+\.swift)',line)
            if m and m.group(1)!=p: bad.append(p)
print('bad headers:',len(bad))
PY
./scripts/check-docs.sh --strict
```
**风险**：纯注释，无运行时风险；不要顺手改 `docs/archive`。

### 批次 2：A 档死成员（A02–A08）

**文件**：`IndexerService.swift`、`GatherCommonViews.swift`、`GatherLocalization.swift`、`CullingService.swift`、`NavigationService.swift`、`VectorIndex.swift`、9 个测试文件、`APIFaceSimilarityTests.swift`。
**命令**：
```bash
swift build --package-path desktop/native/gather-core --disable-sandbox
swift build --package-path desktop/native/gather-app --disable-sandbox
./scripts/check-preview-surface.sh --strict
```
**验收**：`check-duplicate-symbols --strict` / `check-preview-surface --strict` / `check-layering --strict` exit 0；core+app 测试数不变。
**建议拆分**：2a 生产 5 项（A02–A06），2b 测试 2 项（A07–A08），便于定位编译错误。

### 批次 3：测试别名与 checkpoint（B01 + B02）

**文件**：`TestSupportReexports.swift`、22 个 app 测试调用点、3 个 `JobScopeCheckpoint` 测试断言、`JobScopeCheckpoint.swift`、`GatherApp.swift` 注释。
**命令**：
```bash
# 先改名 22 处
rg -l 'makeGatherTestDB' desktop/native/gather-app/Tests | xargs sed -i '' 's/makeGatherTestDB/makeTestDB/g'
# 删转发与 checkpoint 文件后
./scripts/check-duplicate-symbols.sh --strict
swift test --package-path desktop/native/gather-app --disable-sandbox --no-parallel
```
**验收**：`git grep -n 'makeGatherTestDB\|JobScopeCheckpoint' -- '*.swift'` = 0；app 测试数与改前一致。
**注意**：`TestSupportReexports.swift` 里 `AsyncGate` / `LockedBox` 的 typealias **保留**。

### 批次 4：本地化旧出口（B03）

**文件**：`GatherLocalization.swift`、`LocalizationParityTests.swift`、`GlobalInfraTests.swift`。
**顺序**：先把 parity 测试改为比较 `errorMessages`/三张 key 表（或直接对 `L10n` 断言）→ 删 8 个旧函数 → 视情况删 `resolvedTemplate/interpolate/l`。
**验收**：`git grep -nE 'GatherLocalization\.(errorText|jobErrorMessage|message\(for:|cancellationNotice|jobStatusText|jobTypeText|progressPhaseText)' -- '*.swift'` = 0；`LocalizationParityTests` / `GlobalInfraTests` / `check-docs --strict` 绿。
**风险**：`errorMessages` 是 179 码唯一表，**不能删**；`appLanguage` 兼容桥保留。

### 批次 5：重复 helper（B04 + B05）

**顺序**：B04（344 行）优先；B05 每次只做一组，先补测试再删副本。
**文件**：两个 `ServiceConstructionTestSupport.swift`、`GatherTestSupport`、`orderedUnion` 3 处、`parseBbox` 2 处、`patchFields` 2 处、`toFaceKwItem` / `toWritebackItem` 4 处、7 个 `translate`。
**验收**：每组 `git grep -n 'func <name>' -- '*.swift'` 只剩 1 处（或落点 1 处）；core+app 测试绿；`check-layering --strict` 0。
**风险**：`translate` 各 API 的域错误分支不同，先只抽共同臂，不要一次合并 7 份。

### 批次 6：命名与文档（B06 + B07 注记 + B08 + B09 + B10）

**文件**：`GatherEventCenter.swift` + 10 个引用文件、`README.md`、`docs/README.md`、`docs/DEVELOPMENT.md`、`docs/ROADMAP.md`、`ci.yml` 注释、`build.sh`。
**验收**：
```bash
git grep -n 'GatherDomainChange' -- '*.swift'      # = 0（若采纳 B06）
git grep -nE 'user_version=1|7 target|Sources/GatherTestSupport' -- README.md docs/README.md docs/DEVELOPMENT.md docs/ROADMAP.md
./scripts/check-docs.sh --strict
./scripts/check-no-legacy.sh
```
**注意**：`docs/reviews/**` 与 `docs/archive/**` 不改；`final-cleanup-*` 只加“时点/已被取代”注记，不回填。

---

## 7. 测试与最终验证

- 实测汇总（2026-10-22 20:42–20:45）：
  - core：**1,100 tests / 165 suites passed**，exit 0（含 3 skip）。
  - app 首跑：617/68，exit 1，`CullingViewModelAPITests` 的 `update` 用例 3 个 issue（`:351-353`）。
  - app 隔离重跑：`CullingViewModelAPITests` **16/1 passed**，exit 0。
  - app 全量重跑：**617 tests / 68 suites passed**，exit 0。
  - 判定：首跑失败为既有 flake（未改源码/测试；同命令重跑绿）。日志见 `/tmp/gather-final-cleanup-tests.log`、`/tmp/retry-culling.log`、`/tmp/app-rerun.log`。
- 所有 A/B 批次的最小验收都至少包含：
  ```bash
  ./scripts/check-no-legacy.sh
  ./scripts/check-duplicate-symbols.sh --strict
  ./scripts/check-layering.sh --strict
  ./scripts/check-test-catalog.sh --strict
  ./scripts/check-preview-surface.sh --strict
  ./scripts/check-select-star.sh --strict
  ./scripts/check-protocol-surface.sh --strict
  ./scripts/check-cleanup-ratchet.sh
  ./scripts/check-docs.sh --strict
  ```
- 未执行：`build.sh`、`codesign`/`notarytool`、GUI smoke；CI 的 `gather-app tests + bundle` 仍是唯一 bundle 证据链。

---

## 8. 建议记账

- **D-xxx（若采纳 B06）**：`GatherDomainChange` → `GatherChangeEvent`；16 处 / 11 文件；与 D-169 的 `GatherChangeDomain` 命名成对。
- **D-xxx（若采纳 B03）**：删除 `GatherLocalization` 7 个旧翻译出口，parity 测试改表级断言；`errorMessages`/keys/appLanguage 保留。
- **CL-xx（A 档）**：26 处文件头 + 4 处交付端口注释 + 3 个生产死成员（A02–A06）+ 11 个测试死成员（A07/A08）。
- **CL-xx（B 档）**：`JobScopeCheckpoint`（纠正“被生产引用”的旧记录）、`makeGatherTestDB` 22 处、测试装配 344 行去重。
- **CL-xx（文档）**：当前文档 7 target / `GatherDomain` / `user_version=1` / `Sources/GatherTestSupport` 四处口径；`final-cleanup-core.md:37` 与 `final-cleanup-docs.md:34` 的 JobScopeCheckpoint 描述。
- **不建议**把 `MetadataSync*` 改名放进本轮 CL；它是 API breaking，需单列 D-xxx 并评估 UI/协议/测试三面。

---

## 附录 A：A01 的 26 个文件（脚本可复算）

```text
desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataContract.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/MetadataFingerprint.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PhotoAssetResolver.swift
desktop/native/gather-core/Sources/GatherPersistence/Support/BatchCursor.swift
desktop/native/gather-core/Sources/GatherPersistence/Support/BatchRunner.swift
desktop/native/gather-core/Sources/GatherApplication/Services/TemplateService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/IndexerService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/ImagePreloadService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/CaptureOneSyncState.swift
desktop/native/gather-core/Sources/GatherApplication/Services/ExportService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/JobService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/QualityService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/SimilarityService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/DuplicateService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/FilterEngine.swift
desktop/native/gather-core/Sources/GatherApplication/Services/WorkspaceStatusService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/CullingService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/MetadataService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/ImageMetadataProviders.swift
desktop/native/gather-core/Sources/GatherApplication/Services/SettingsService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/MetadataProviders.swift
desktop/native/gather-core/Sources/GatherApplication/Services/SessionService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/PhotoAssets.swift
desktop/native/gather-core/Sources/GatherApplication/Services/SettingsNumber.swift
desktop/native/gather-core/Sources/GatherApplication/Services/NavigationService.swift
desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryModuleRoutingTests.swift
```

## 附录 B：复现命令（只读）

```bash
# 旧名/端口/死符号
git grep -nE 'GatherDomain|CullingDeliveryPort|FaceKwDeliveryPort|SimilarityDeliveryPort|FeatureDeliveryPorts' -- '*.swift'
git grep -nE 'RequestGate|ViewState' -- '*.swift'
git grep -n 'GatherDomainChange' -- '*.swift'
git grep -n 'JobScopeCheckpoint' -- '*.swift'
git grep -n 'makeGatherTestDB' -- '*.swift'
# 未使用 public
swift scripts/find-unused-symbols.swift --all --json
# 重复符号
./scripts/check-duplicate-symbols.sh --strict
# 文件头 path 校验（同 A01 脚本）
```
