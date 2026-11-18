# R2-3 独立评审：测试与测试系统（Tests/** + test-system scripts）

- 任务：task-33（lead 指派；只读评审，未修改任何 tracked 文件）
- 评审对象：local main HEAD `0288ea8d`（19 commits / 226 files / +10432/−961，相对 `origin/main` `e5c54f37`）
  中与测试系统相关的全部改动；重点是 round-1 修复提交 `6e940350`（JSONValueCodingTests / ReviewFixTests）
  与 `9be6a000`（check-test-catalog ratchet 基线）。
- 环境：Linux Ubuntu 22.04、无 macOS/Xcode；Swift 6.2（`.gather/swift62`，x86_64-linux）、
  Swift Testing 6.2、shellcheck 0.10.0、python3。**未编译/未运行 macOS target、未运行仓库测试 target**。
- 方法（全部在 `.gather/` scratch 完成）：`git show/diff/blame`；真实 `GatherProtocol` 模块 +
  真实 Swift Testing 的 Linux `swift test` harness（测试文件逐字复制）；修复版/变异版 oracle
  对拍（drift-injection）；`PhotoDecodeGate` + AsyncWait helper + 两个新增用例**逐字**抽取成
  AppKit-free Linux 测试并加压重复运行；`git archive` + 复制的门禁脚本做删用例负向探针；
  独立文本计数器复核 catalog 口径。
- **快照说明**：评审期间 lead 正在把 round-2 发现修进工作区（截至 2026-11-18T03:1x UTC 有
  `JSONValueCodingTests.swift`、`DateFormatting.swift`、`CullingViewModel.swift`、
  `check-test-catalog.sh` 等未提交改动）。下文分别标注 **HEAD（0288ea8d）** 与 **工作区快照**；
  HEAD 是评审判定基准，工作区状态仅作"修复是否有效"的验证。

## 1. 结论摘要

| 级别 | 数量 | 说明 |
|---|---|---|
| **P0** | **1** | **R2T-01**：修复提交 `6e940350` 在 `JSONValueCodingTests.swift:128` 引入 Swift 编译错误（`try` 在 `==` 右侧）⇒ **gather-core 测试 target 无法编译，CI `swift test` 必红**。round-1 的 P1（oracle 抖动）修复把测试改成了 P0 编译中断。**工作区已有未提交修复，我用真实 GatherProtocol+Swift Testing 验证其可编译且确定性通过（12/12）——必须提交。** |
| P1 | 0 | 未发现其他确定性 CI 红/正确性回归（测试面）；app/core Sources 侧的另 3 个编译 P0（DateFormatting 闭包标签、pageAssignmentCount/navigationGroupsVersion private 跨文件）由 review2-app/core 分册负责，本册只交叉引用。 |
| **P2** | **2** | R2T-03：6e940350 的 14 个运行时文件中的高风险修复仍无新增回归测试（CORE-03 未闭环）；R2T-04：R3-T02/T03 未修——4 个新 formatter 缓存 0 测试、无环境变化/持锁测试。 |
| P3 | 7 | R2T-02 断言 ratchet 基线 HEAD 仍差 4（工作区最新快照已重钉为 14959/14959，精确）；R2T-05 5 处冗余 `try` warning 未清；R2T-06 oracle fixture 缺口（slash 转义漂移测不到）；R2T-07 工作区修复里的重复 decode；R2T-08 2 个同型未加 started 信号的负向窗口；R2T-09 测试门禁对"语义编译错误"盲区；R2T-10 注释/文档数字与实测不一致（docs 侧 R2D-08 已另报）。 |

**总结论**：round-1 的修复方向正确，但 `6e940350` 自身引入了两个新问题——JSON 测试不可编译（本册 P0）
与 app Sources 不可编译（R2-app/core 已报）。`9be6a000` 的 ratchet 收紧方向正确且 @Test/@Suite 已精确钉死，
断言基线因修复提交新增的 4 条断言在 HEAD 上又差 4（14958/14954）；工作区最新快照已把 `BASELINE_ASSERT` 重钉为 14959，与实测 14959 精确相等（评审期间工作区是移动目标，以最终提交为准）。
ReviewFixTests 的 `waiterStarted` 修复**逻辑上真实关闭了 false-green 窗口**且在本机 85 次（含 2× CPU
超订载）重复运行 0 flake。JSON 的新值等价 oracle 在修复语法后确定性通过（20/20），并能拦截
`.prettyPrinted`/`withoutEscapingSlashes`（后者需补 fixture）等真实漂移。

## 2. 发现表

| ID | 严重度 | 位置（file:line / commit） | 问题 | 证据（我检查/实跑了什么） | 建议修复 | 置信度 | macOS 不可验证 |
|---|---|---|---|---|---|---|---|
| **R2T-01** | **P0** | `desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift:128`（6e940350） | `#expect(try JSONValue.parse(json) == try JSONValue.parse(baseline), …)`：Swift 禁止 `try` 出现在非赋值运算符右侧 ⇒ `error: 'try' cannot appear to the right of a non-assignment operator`；`GatherCoreTests` 整个 test target 编译失败。CI `.github/workflows/ci.yml:117` 的 `swift test --package-path desktop/native/gather-core` 必红；`check-test-catalog`/语法门禁只数声明不编译，拦不到。 | ① 逐字把 5ea5c38f（修复前）与 HEAD 两版测试文件放进**真实 GatherProtocol product + Swift Testing** 的 Linux harness 测试 target：修复前 `swift build --build-tests` → “Build complete! (1.20s)”，HEAD 版 → 上面两条 `error:`（含 macro expansion 定位），`FIXED_BUILD_RC=1`。② `git blame` 确认该行由 6e940350 新增。③ 全仓扫描 `(==|!=|&&|\|\|) try ` 仅此 1 处。④ 工作区已有未提交修复（先 `let parsedBaseline/parsedJSON = try …`）；我把工作区文件逐字放进同一 harness：编译通过、6/6 isolated + 6/6 parallel 全绿。 | 采纳工作区修复（先取值再断言），提交并跑 macOS `./scripts/test.sh core`（至少 `--filter JSONValueCodingTests`）。round-1 §2#3 应改判"修坏、已修复待复验"。 | 高（语言规则，跨平台） | 否 |
| R2T-02 | P3 | `scripts/check-test-catalog.sh:486`（HEAD `BASELINE_ASSERT=14954`；工作区最新快照 14959） | 三个 ratchet 基线重钉后，`@Test 3267/3267`、`@Suite 419/419` 与实测**精确相等**（删 1 个即 FAIL），但**HEAD 的断言基线仍低于实测**：实测 **14958**（差 4），`9be6a000` 注释"重钉到实测值"对断言不成立。工作区最新快照已把基线重钉为 14959/14959（精确），评审期间工作区是移动目标，以最终提交为准。 | ① HEAD：`./scripts/check-test-catalog.sh --strict` → `@Test 3267/3267 · @Suite 419/419`、`断言 14958/14954`；`./scripts/report-baseline.sh` → `合计 @Test 3267 / @Suite 419 / #expect+#require 14958`。② 独立文本计数（不剥注释）：`@Test` 3267、`@Suite` 419、`#expect/#require` 14962；4 条在注释里（CullingSyncServiceTests:191、MetadataEditorTests:134、app AsyncWait.swift:47-48）⇒ 剥注释后 14958，与脚本口径**吻合**。③ 工作区最新：14959/14959。④ 已有 round-2 分册（R2D-11）提出同一问题并在修。 | HEAD 侧：在最终编辑定稿后把 `BASELINE_ASSERT` 重钉到最终实测（工作区已按 14959 完成）。 | 高 | 否 |
| **R2T-03** | **P2** | 6e940350 修改的 14 个运行时文件（DBStatementCache/DB、applyImportedPicks、JobService+Settle、NavigationService、DateFormatting、LightboxView、CullingViewModel+Preload、ThumbnailDiskCache）+ 既有高风险 perf 改动 | **CORE-03 未闭环**：修复提交只改了 2 个测试文件（JSON/ReviewFix），其修复的运行时行为没有新增回归测试；且多数修复是并发/锁/Observation/时序类，现有测试无法证明修复有效。 | 测试引用计数（git grep Tests）：`DBStatementCache`=0、`writeTerminal`=0、`pruneAtStartupIfNeeded`=0、`pageAssignmentCount`=0、`resolvedCurrentIndex`(Lightbox)=0、`parseISODate/LegacyWallDateParsers`=0、`NavigationService` 日期解析=0；`applyImportedPicks` 有 6 处既有用例但**无 revision 冲突语义测试**（CullingServiceTests:2078-2133 只测未知 id/历史合并/幂等/人工优先）；`EmbeddingModel.cache` LRU（`maxProviders=4`+`recency`）无淘汰测试（唯一 `evictions` 断言在 L10nFormatTests，是另一个缓存）；`Database.close` 无 `PRAGMA optimize` 移除后语义测试；`NavigationService.LegacyWallDateParsers.date` 无任何测试。Note: `heartbeatSqlErrorDoesNotAbortOrCancelJob`（JobServiceTests:513-545）间接覆盖 writeTerminal 重试路径，但"任务取消时仍等满 200ms 再重试一次"的 R5-04 新语义未直接测。 | 优先级：① DateFormatting 持锁（并发锤测可写：多线程调 9 个方法 × N 次不断言崩溃/死锁）；② applyImportedPicks revision：并发 updateState 与 imported 批交错，断言人工决策不被覆盖；③ JobService 取消时终态写重试节奏（测耗时 ≥200ms 且重试恰好 1 次）；④ Lightbox resolvedCurrentIndex 抽纯函数测 stale 身份（R2-app 已建议）；⑤ NavigationService 日期解析纯函数单测（确定性、可在 Linux 跑）；⑥ DBStatementCache DEBUG assert 的负例（跨连接复用触发 assert——需要 DEBUG 下死亡测试，可选）。 | 高（代码可判定） | 否（除 Observation/Lightbox 渲染类） |
| **R2T-04** | **P2** | `desktop/native/gather-app/Tests/GatherAppTests/DisplayDateFormattersTests.swift`（全文）；生产 `Sources/GatherUI/Support/DateFormatting.swift:146/162/170/177` | R3-T02/T03 未修：同轮新增的 4 个 formatter 缓存（`fileSize` 7 个生产调用点、`internetDateTimeString`/`parseFixedUTC`/`formatFixedUTC` 各 1）仍 **0 测试**；R3-T03 的"环境变化仍与旧实现一致"仍无测试（本 diff 恰好把 `mediumShort` 缓存键补上 calendar/timeZone 且改为持锁格式化，属该声明的直接实现，但无任何测试背书）。既有 6 个用例只是 same-env 的 cached-vs-fresh 字节比较，**结构上不可能**发现 cache-key 漏环境维度。 | ① 我把**当前工作区** `DateFormatting.swift` + `DisplayDateFormattersTests.swift` 逐字复制到 Linux harness 运行：3/3 通过（说明修复未破坏既有 oracle）。② 测试引用：`internetDateTimeString(`/`parseFixedUTC(`/`formatFixedUTC(` 在 Tests 均为 0；`fileSize(` 的 3 处命中是 `MetadataDisplay.fileSize`（另一个函数）。③ 环境维度探针（scratch，save/restore `NSTimeZone.default`）：Linux 上 `TimeZone.current` 在进程内**不跟随** `NSTimeZone.default` 变化（实测从 UTC→Tokyo→UTC，`TimeZone.current` 恒为 `Etc/UTC`，而新建 `DateFormatter()` 的 fresh 输出会跟随）——因此该维度在 Linux 上无法动态验证；macOS 行为未知（见 R2-app 同结论）。 | 按现有 oracle 模式补 4 个缓存用例（fileSize 边界值；ISO 输出固定 epoch；parse/format fixedUTC 往返 + 方向）；R3-T03 用例建议在 macOS-only 的 `#if canImport(Darwin)` 下 save/restore `NSTimeZone.default` 再断言，或给 `environmentKey` 抽成可注入的纯函数单测（把"取环境"参数化，Linux 可测）。 | 高 | Partly（环境传播需 macOS） |
| R2T-05 | P3 | `DuplicateServiceTests.swift:492`、`FaceKeywordingServiceTests.swift:391/1881/1948`、`SimilarityServiceTests.swift:959` | R3-T06 未清：条件闭包不抛错却写 `try await waitUntilCondition`（`@rethrows`），编译器给 `warning: no calls to throwing functions occur within 'try' expression`；测试 target 不在 `-warnings-as-errors` 面内，不会红，属噪音。 | ① 逐字把 `GatherTestSupport/AsyncWait.swift` + 一个 `try await waitUntilCondition { true }` 探针 `swiftc -typecheck -swift-version 6` → 复现上述 warning。② 5 个站点的闭包逐一核对均非 throwing（`calls.value > 0`/`entered.value`/`blocked.value`）；其余 8 处 `try await waitUntilCondition` 的闭包内含 `try runRow/list`，`try` 合法。 | 删这 5 处 `try`（或给 helper 加非 throwing overload）。建议顺手在 `check-warnings.sh` 加一条"测试 target 不得新增该 warning"的非阻塞提示（可选）。 | 高 | 否 |
| R2T-06 | P3 | `JSONValueCodingTests.swift:51-73`（stringify oracle 的 fixture） | 新 oracle 的 fixture 覆盖不足：`stringifyMatchesBaselineEncoder` 的字符串值不含 `/`，因此 `.outputFormatting = .withoutEscapingSlashes` 这类真实配置漂移**测不到**（画面/路径类 payload 里 `/` 很常见）；对象 key 也无大写/下划线，key 编解码策略漂移在 Darwin 上可能测不到（Linux Foundation 对 Dictionary key 策略本身不生效，无法在 Linux 验证）。`.sortedKeys` 漂移按新契约（值等价）不拦截，属已声明的取舍。 | 在 GatherProtocol 副本上做**变异注入**（drift-injection）对拍（同文件 oracle、真实模块）：baseline PASS；`prettyPrinted` → 被数组字节断言+新增的换行断言拦截（FAIL）；`withoutEscapingSlashes` → **PASS（漏检）**；把 `.string("a/b")` 加进 values 后同一变异 → **FAIL（可拦截）**；`.sortedKeys` → PASS（按设计）；`convertToSnakeCase`/`convertFromSnakeCase` 在 Linux corelibs 对 Dictionary key 不生效，未能验证（Darwin 未知）。 | 在 stringify values 里补 `.string("a/b")`（顺带覆盖 `"\u4e2d\u6587/emoji"`）；可选补 `{"userName":…}`/snake_case 输入到 parse/roundTrip fixture，让 Darwin 上的 key 策略漂移可被拦截。 | 高（Linux 实测） | 否（Linux 可证）/ Partly（Darwin key 策略） |
| R2T-07 | P3 | 工作区未提交 `JSONValueCodingTests.swift:130-133` | 工作区修复引入重复解码/冗余断言：`parsed`（:126）与 `parsedJSON`（:131）都是 `JSONValue.parse(json)`；`#expect(parsedJSON == parsedBaseline)` 被前两条断言（`parsed == value`、`parsedBaseline == value`）逻辑蕴含。无害但多一次 decode、多一条冗余断言（也把断言计数从 14958 推高到 14959，因此工作区基线已随之定为 14959）。 | 逐行读工作区 diff；harness 运行确认行为正确（12/12 绿）。逻辑蕴含关系可直接推导。 | `#expect(parsed == parsedBaseline)`（复用已解析的 `parsed`），删掉 `parsedJSON`；若保留则把 `BASELINE_ASSERT` 定格到 14959。 | 高 | 否 |
| R2T-08 | P3 | `APIDuplicateQualityTests.swift:281-283`、`APIExportMetadataTests.swift:257-259` | 与 R3-T04 同型的另两处"负向窗口"仍无"Task 已启动"信号：`#expect(!(await waitUntilCondition(timeout: 0.5) { secondFinished.isSet }))` 无法区分"已进入 dedupe 排队"与"Task 还没跑"。目前有下游正断言兜底（`jobs.count == 1` / `firstResult == secondResult`：若第二个 Task 迟到、在首个 job 终结后才执行，会新建 job ⇒ 计数断言失败），所以不构成 false-green，但负向窗口本身证据力弱。 | 读两处测试全文（APIDuplicateQualityTests:264-293、APIExportMetadataTests:239-266）；确认后续有 job 计数/结果相等断言。 | 同 R3-T04 修法：Task 体内先 set `started` 旗标，正向等待后再做负向窗口（可选，成本 ~5 行/处）。 | 高 | 否 |
| R2T-09 | P3 | 测试门禁面（`scripts/check-test-catalog.sh` / 评审方法） | 测试系统对"**语义编译错误**"完全盲区：catalog 只数声明、`swiftc -parse` 只做语法、cleanup/warnings 门禁都不编译测试 target；round-1 因此把 P1 改成了 P0 却仍宣称"测试文件 parse 全绿"。Linux 侧无法真实编译测试 target（GatherAnalysis 依赖 CoreGraphics），CI 的 `swift test` 是唯一拦截点。 | 本轮直接观测：HEAD 的 JSON 测试 `-parse` 通过（round-1 §4/5 的结论来源）、catalog 绿（`--strict OK`），但真实 Swift Testing 编译失败（R2T-01 证据）。| 在 CI 保持 `swift test`（已有）；文档/评审标准里明确"parse 绿 ≠ 可编译"，本地验证结论必须写清验证层级；可选：为**纯 Foundation test 文件**（如 JSONValueCodingTests）在 Linux 跑最小 harness（本评审已有脚本形态）作为补充。 | 高 | 否 |
| R2T-10 | P3 | `scripts/check-test-catalog.sh:370-386 / 483-487`（注释块） | 注释块本身完整（插入位置正确、门禁可读），但新增注释"重钉到实测值"对断言不准确（见 R2T-02）；另外 `docs/README.md:47`（HEAD）仍写"均不低于基线 2,502 / 283"——HEAD 的 ratchet 已重钉成 3267/419，docs 与门禁自相矛盾（R2-docs R2D-08 已报，工作区已在修，此处仅交叉确认）。 | 读 HEAD 注释块；`--strict` 输出与 docs/README 文本对拍；工作区 docs/README 已改成"基线 3,267 / 419；断言 14,958"（数字仍待随最终断言计数同步）。 | 随 R2T-02 一起收口注释/文档数字。 | 高 | 否 |

## 3. 逐项验证（round-1 修复是否成立）

### 3.1 R2T-01：JSONValueCodingTests 修复（HEAD 编译坏 / 工作区修复有效）

**HEAD 状态（0288ea8d）**：`JSONValueCodingTests.swift:128` 非法 `try` ⇒ `GatherCoreTests` 编译失败。

```text
# 5ea5c38f（修复前）版本逐字放入 harness 测试 target：
swift build --build-tests → "Build complete! (1.20s)"   PRE_FIX_BUILD_RC=0
# HEAD（6e940350 之后）版本逐字放入同一 target：
JSONValueCodingTests.swift:128:46: error: 'try' cannot appear to the right of a non-assignment operator
macro expansion #expect:1:51: error: 'try' cannot appear to the right of a non-assignment operator
FIXED_BUILD_RC=1
```

**工作区修复状态**：lead 未提交改动把两处断言改成先 `let parsedBaseline/parsedJSON = try JSONValue.parse(…)` 再断言，并新增
`#expect(!cached.contains("\n"), "默认 encoder 不得输出换行（.prettyPrinted 漂移）")`。我把它逐字放进
真实 GatherProtocol + Swift Testing harness：

```text
worktree-json isolated: pass=6 fail=0
worktree-json parallel: pass=6 fail=0
```

⇒ **编译问题已解决、修复后确定性通过**；该修复必须提交（HEAD 否则 CI 红）。注意 R2T-07 的重复 decode。

### 3.2 值等价 oracle 是否仍然拦得住真实漂移（drift-injection）

方法：把 `Sources/GatherProtocol` 复制进 scratch 包（`.gather/r2-json-drift`），只变异
`JSONValueCoding.encoder/decoder`/添加 fixture，逐变异跑**逐字**测试文件（修复语法后的版本）。

| 变异（真实可能出现的漂移） | 结果 | 说明 |
|---|---|---|
| baseline（无变异） | PASS | 20 次 isolated+parallel 全绿 |
| encoder `.prettyPrinted` | **FAIL（被拦）** | 数组字节断言失败；工作区新增的换行断言对对象也拦 |
| encoder `.withoutEscapingSlashes`（当前 fixture） | **PASS（漏检）** | values 里没有 `/`；见 R2T-06 |
| encoder `.withoutEscapingSlashes`（fixture 加 `.string("a/b")`） | **FAIL（被拦）** | 证明补 fixture 即可 |
| encoder `.sortedKeys` | PASS | 按"对象值等价"新契约属预期不拦 |
| decoder `.convertFromSnakeCase` / encoder `.convertToSnakeCase` | PASS（Linux） | Linux corelibs 对 Dictionary key 策略不生效；Darwin 未知 |

**R3-T01 原始问题可复现**：同一 harness 跑 5ea5c38f 版本的**旧字节 oracle**：
isolated pass=1/fail=4、parallel pass=1/fail=4（与 round-1 的 1/5、1/4 同型）。⇒ 换成
"对象解析后值等价 + 标量/数组字节" 的方向正确，且修复语法后 oracle 是**确定性**的。

**标量/数组字节断言的逻辑合理性**：数组元素有序、标量编码无键序问题；`if case .object = value { continue }`
只对对象跳过裸字节（Foundation 不承诺 key 序，round-1 已实证）。实测 20+ 次（含 isolated/parallel）
无抖动。残差：`.number(-1e-9)` 等浮点文本由 Foundation 序列化，Linux 稳定；Darwin 未验证（同一 Foundation 语义，风险低）。

### 3.3 ReviewFixTests 的 `waiterStarted` 修复（R3-T04）

**是否真的关闭 false-green 窗口**——结论：**对当前代码是**。论证：
`PhotoDecodeGate.acquire()` 是 actor 方法，Task 体内 `waiterStarted.set()`（同步）→ 紧接
`await gate.acquire()`（同步入队到 gate actor 后挂起），两步之间**没有挂起点**，因此测试端观察到
`waiterStarted` ⇒ acquire 调用已经入队；测试随后 80ms/40ms 负向窗口内 gate 的 `running == 1` 不会变，
acquire 只可能进入退避睡眠（不会完成）；`release()` 是在负向窗口之后从测试任务发出的，actor 先处理
早入队的 acquire 再处理 release ⇒ "limit=1 必须排队 / 取消排队者" 路径确实被覆盖。
残余：若未来有人在 `set()` 与 `acquire()` 之间插入挂起点，该信号语义会弱化为"仅 Task 已启动"
（当前注释也如实写"Task 已启动"，未夸大）。

**是否在慢 CI 上引入新 flake**——用**逐字抽取**的探针验证：把 `PhotoDecodeTaskBox+PhotoDecodeGate`
（PhotoThumbnailView.swift:475-547）、app `AsyncWait.swift`、`ReviewFixFlag` 与两个 @Test 原样搬进
Linux Swift Testing 包（`.gather/r2-reviewfix`，@MainActor suite，与真实隔离一致）：

```text
reviewfix-fixed serial:   pass=40 fail=0   （--no-parallel）
reviewfix-fixed parallel: pass=30 fail=0
reviewfix-fixed under-load serial: pass=15 fail=0   （28 核机器上 56 个 busy loop 超订载）
单测实测耗时：test1 0.162s / test2 0.080s
```

`waiterStarted` 正向等待窗口 0.5s，正常路径 Task 在首次让出即启动（微秒级），余量 >1000×；
负向窗口 80ms/40ms 与 gate 退避上限 20ms 匹配。⇒ 修复代码本身可编译（AppKit-free 子集）、
无flaky 证据。**macOS 上整套 app 测试无法在本机验证**（见 §5）。

### 3.4 test-catalog ratchet 基线（9be6a000）

**计数（HEAD 0288ea8d，实跑）**：

```text
./scripts/check-test-catalog.sh --strict  → OK
  测试文件 333；缺文件头 0；skip 站点 17（.enabled 17 / .disabled 0 / withKnownIssue 0）；skip 元数据缺失 0；过期 0
  用例/套件 ratchet  @Test 3267/3267 · @Suite 419/419
  断言 ratchet        #expect+#require 14958/14954
```

- **3267/419 与实测精确相等** ⇒ "删 1 个用例即 FAIL"成立；**14954 ≠ 14958** ⇒ 断言仍有 4 条静默删除余量（P3，见 R2T-02）。
- 独立口径核对（不依赖脚本）：文本 `@Test` 3267、`@Suite` 419、`#expect/#require` 14962 − 4 条注释 = 14958；333 个文件。文件头/skip 均为门禁实测 0 缺失。
- **删用例负向探针**（`.gather/r2-catalog-scratch` 复制 scripts + 三个 Tests 根，实跑）：

```text
baseline                         → OK (--strict) rc=0
删 1 个 @Test 声明                → FAIL @Test 3266 < 3267，rc=1
删 1 个 @Suite                    → FAIL @Suite 418 < 419，rc=1
删 4 条断言（HEAD 基线）          → OK（14954/14954；证明 4 条余量）
删 5 条断言                       → FAIL 14953 < 14954，rc=1
```

- `--self-test`：SELFTEST OK，无 `/tmp/tmp.*` 残留；`CTC_TEST_ROOTS_OVERRIDE` 在非 self-test 子进程被忽略（实测仍扫真实根、PASS，无绕过）。
- 注释块：`9be6a000` 在既有段落后、常量前插入 2 行注释，结构完整（脚本正常解析常量）；仅"实测值"措辞对断言不准确（R2T-02/R2T-10）。
- shellcheck（0.10.0）对 `check-test-catalog.sh`/`test.sh`/`report-baseline.sh`：0 finding。
- 工作区快照（最终检查时）：`BASELINE_ASSERT` 已重钉为 **14959**，与实测 14959 **精确相等**（新增的换行断言计入）；HEAD 仍是 14954/14958。

### 3.5 `scripts/test.sh`（6fecfcce，未被修复提交改动）

用 fake `swift` 干跑（PATH 注入，记录 argv）：

```text
SWIFT_TEST_FLAGS 空 → 主批参数正确，无空参数；串行批 --skip-build + --filter <推导名单>
SWIFT_TEST_FLAGS="--disable-sandbox --filter Foo.*" → 拆分正确，Foo.* 未被 glob 展开
串行名单推导 = LogFileSinkTests|LoggerTests|ReadPoolTests|TraceLoggingTests（4 个，符号确实存在）
未知目标 → exit 2；bash -n/shellcheck 0 finding
```

### 3.6 其他 round-1 数字/声明复核（全部为真）

| 声明 | 复核方法 | 结果 |
|---|---|---|
| sleep 站点 49→32、文件 30→20、Thread.sleep 6→2 | 复用 round-1 同款注释遮罩扫描器（origin archive vs HEAD 工作树） | 49/30 → 32/20；Thread.sleep 现存 2（DeliveryFilePhaseTests:294、ReadPoolTests:148）✓ |
| Tests 无 `try!`/`fatalError`/`preconditionFailure`/`try? #require` | grep 全 Tests（仅命中注释文字） | 代码 0 处 ✓ |
| 迁移点无 `_ = await waitUntil*` 丢弃 | 对 diff 新增行/全仓 grep | 0 处 ✓ |
| helper 可见性：5 个 app 文件、5 个 core 文件均 import GatherTestSupport | 逐个 grep | 全部 OK ✓ |
| 无删除用例（diff 只新增） | `git diff` 中 `^-.*@Test/@Suite` | 0 删除 ✓ |
| 删除的 29 条 `#expect` 均被更强形态替换（try! → try、optional→non-optional、条件等待替代 spin） | 逐条看 diff 配对 | 未发现断言弱化 ✓ |
| docs 计数声明（core 2,001/235 + app 1,266/184） | `report-baseline.sh` 实跑 | 与 `docs/test-runtime-audit.md:11-12` 一致，合计 3267/419 ✓ |
| DisplayDateFormattersTests 对**当前生产**仍绿 | 逐字复制生产文件+测试到 harness，3 次 | 3/3 PASS ✓ |
| 新增测试文件头注释/skip 元数据 | catalog --strict | 0 缺失 ✓ |

### 3.7 工作区快照（非 HEAD，供 lead 收口参考）

截至评审时，工作区未提交改动已含：JSON 测试 P0 修复 + 换行断言、`BASELINE_ASSERT`→14959（=实测）、
`DateFormatting` 闭包标签修复、`pageAssignmentCount` internal、`CullingService+Commands`/`MetadataKeywordWriter`/
`SidecarXMPProvider` 等修复、docs 数字更新。测试面的状态：
- JSON 测试逐字 harness → 编译通过、12/12 绿（R2T-01 消除）；断言 14959/**14959** 精确（HEAD 侧为 14958/14954，差 4；见 R2T-02/R2T-07）。
- `DateFormatting` 工作区版本 + 现有 formatter 测试 → 3/3 绿（未回归）。
- `check-test-catalog --strict` 工作区 → OK（`@Test 3267/3267 · @Suite 419/419 · 断言 14959/14959`）。

## 4. "已验证 OK"清单（本册实跑）

1. 真实 GatherProtocol + Swift Testing：HEAD 测试文件编译失败（P0 复现）；5ea5c38f 旧版可编译但字节 oracle 抖动（isolated 1/5、parallel 1/5）；工作区修复版 12/12 绿。
2. 值等价 oracle 变异注入：prettyPrinted 拦截；withoutEscapingSlashes 靠 fixture 才能拦（补 `.string("a/b")` 后拦截）；sortedKeys 按设计不拦；key 策略在 Linux 不可测。
3. ReviewFix 抽取探针：serial 40/40、parallel 30/30、2× CPU 超订载 15/15 全绿；逐字 gate 行为推导确认 false-green 窗口关闭。
4. test-catalog：`--strict` 绿、333 文件、3267/419 精确、14958 断言（对照独立计数）、skip/header 0 缺失、self-test OK、override 不可绕过、shellcheck 0、删 @Test/@Suite/断言负向探针按预期红。
5. `scripts/test.sh` fake-swift 参数/串行名单/错误码验证。
6. 既有 formatter 测试对当前生产 3/3 绿；环境维度探针说明 Linux `TimeZone.current` 不跟随（macOS 需验）。
7. 数字声明复核：sleep 49→32/30→20、无删除用例、anti-pattern 清零、helper imports、docs 计数口径、工作区 14959。
8. 全量语义扫描：`(==|!=|&&|\|\|) try` 全仓仅 P0 一处；`try await waitUntil*` 13 处中 5 处冗余 warning（R2T-05）；`_ = await waitUntil` 0 处。

## 5. 覆盖与局限（必须随结论一起读）

1. **无 macOS/Xcode**：无法 `swift build/test` 仓库 core/app target（GatherAnalysis 需 CoreGraphics、GatherAppTests 需 SwiftUI/AppKit）。
   - 已验证：`GatherProtocol` 真实模块 + Swift Testing 下的 JSON 测试文件；`DateFormatting.swift`（纯 Foundation）+ formatter 测试；
     `PhotoDecodeGate/TaskBox + app AsyncWait + 两个 ReviewFix 用例` 的 AppKit-free 抽取。
   - 未验证：GatherCoreTests 其余文件、GatherAppTests 其余文件、Darwin Foundation 的 key 序/Dictionary key 策略/DateFormatter 环境传播、
     `swift test` 实际执行顺序/并发调度、CI 真实行为。/tmp `-parse`/typecheck 结论只覆盖可移植子集。
2. **Linux Foundation ≠ Darwin Foundation**：`TimeZone.current` 缓存行为、JSONEncoder 对象 key 序、
   `convertFromSnakeCase` 对 Dictionary 的行为均可能不同（本轮已实测 Linux 侧）。
3. **概率类结论**（false-green、flake）：本机用重复运行/超订载锤测降低不确定性，但 macOS CI 的调度/负载未量化。
4. **工作区是移动目标**：评审期间 lead 在持续落修复（JSON/DateFormatting/门禁/文档），
   本文对工作区状态的描述是 2026-11-18T03:1x UTC 快照；收口后需以最终提交重跑 §3.4/§3.7。
5. **未逐行复核全部 32 个改动测试文件的每条断言**：按"修复提交全量 + 新增/迁移测试热点 + 全量 diff 扫描（删除断言配对、
   sleep、timeout、丢弃断言、negative window）"覆盖；其余小改动（EOF/import/注释）按全量 diff 过了一遍。

## 6. macOS owner 复验清单（建议）

1. 提交工作区修复后跑：`./scripts/check-test-catalog.sh --strict`（期望 @Test 3267/3267、@Suite 419/419、断言 = 最终实测）、`./scripts/test.sh core`（重点 `--filter JSONValueCodingTests` 两遍：并行/串行各一）、`./scripts/test.sh app`（重点 ReviewFixTests 的 2 个 decodeGate 用例 ×3 次；WorkflowRegistry/AppRuntime/APIDuplicate/APIExport 迁移用例）。
2. `swift build --build-tests`（core/app）确认无其他测试文件语义编译错误（本轮 P0 说明 `-parse` 不足）。
3. `./scripts/check-warnings.sh core|app`：确认测试 target 无新增 warning（R2T-05 的 5 处冗余 try 不会红但可顺带清）。
4. DateFormatting 环境维度：在 macOS 上 save/restore `NSTimeZone.default`（或 System Settings 时区）验证 `mediumShort/pattern/shortShort/localizedTemplate` 缓存跟随，并补 fileSize/fixedUTC 4 个缓存单测（R2T-04）。
5. 工作区已把 `BASELINE_ASSERT` 定到 14959（= 实测）；若按 R2T-07 删掉重复 decode/断言，需同步把基线改回 14958。
