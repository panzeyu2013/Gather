# R3 独立评审：测试与验证改动（Tests/** + scripts/test.sh + 新增 AsyncWait helper）

- 任务：task-28（lead 指派，独立评审；只读仓库，不修改源码/测试/脚本）
- 评审对象：local main 相对 origin/main（e5c54f37）16 个提交里与测试相关的 3 个提交：
  - `6fecfcce` chore(hygiene)：测试文件 EOF/行尾规范化 + `check-test-catalog.sh` trap 修复 + `scripts/test.sh`
  - `5a4cb265` test(hygiene)：清理 try!/fatalError/preconditionFailure 反模式（7 文件）
  - `708a6b89` test(hygiene)：统一异步等待、收敛墙钟容差、新增 2 个缓存回归测试 + 新 helper（20 文件）
- 验证环境：Linux Ubuntu 22.04，Swift 6.2（`.gather/swift62`），无 macOS/Xcode。
  本机**不能** `swift build/test` gather-core/app 测试 target（`GatherAnalysis` 需要 CoreGraphics）。
  本次用两类 Linux 探针提高置信度（§4 有清单/命令）：
  1) 把 `GatherProtocol` 在 Linux 编出真实模块，新测试文件**逐字复制**后编译/运行；
  2) 把 `DateFormatting.swift`（Foundation-only 生产文件）与两个 AsyncWait helper **逐字复制**后编译/运行语义探针。
  所有复制/探针都在 `.gather/` 完成，未改动仓库源码。

## 1. 结论摘要

| 级别 | 数量 | 说明 |
|---|---|---|
| P0 | 0 | 未发现崩溃/数据丢失/编译级破坏 |
| P1 | 1 | **R3-T01**：新增 JSONValueCodingTests 的"逐字节相等"oracle 在 Linux Swift 6.2 上可复现失败/抖动（隔离 6 次 pass 1/fail 5）；macOS 未验证，且 Foundation 不保证 JSON 对象 key 顺序 |
| P2 | 4 | R3-T02/03（新 DisplayDateFormattersTests 覆盖缺口：同轮新增 4 个 formatter 缓存 0 测试；env 维度 oracle 缺口，探针证实 mediumShort 会停在旧时区）、R3-T04（ReviewFix 负向窗口可 false-green）、R3-T05（test-catalog 计数 ratchet 严重过期，非本轮引入） |
| P3 | 7 | try 冗余 warning、AsyncWait 两 helper 语义不对称、waitForTerminal 二次查询、DefaultSignatures 失去记忆化、test.sh 多行 flags 边界、LockedFlag 重复、docs 数字疑点 |

总体：**3 个测试提交方向与绝大部分改动正确**（反模式清理语义保真、异步等待迁移全部断言结果、
墙钟容差仍能拦住病态回归、文档里的计数/睡眠/helper 副本数字经独立复核全部精确）。
唯一算"交付物自身有缺陷"的是 R3-T01（新增回归测试的核心卖点不可靠）；R3-T02/03 是同一新文件的覆盖缺口，建议同批补。

## 2. 发现表

### R3-T01（P1）JSONValueCodingTests 的逐字节相等 oracle 不成立：Linux 上可复现失败

- 位置：`desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift:107-118`
  （`roundTripMatchesBaseline`）；同类假设也在 `:47-64`（`stringifyMatchesBaselineEncoder` 的 .object 用例）。引入 commit 708a6b89。
- 问题：断言"共享 `JSONValueCoding.encoder` 输出"与"每次新建默认 `JSONEncoder` 输出"**逐字节相等**。
  但对象（Dictionary）编码的 key 顺序不是 Foundation 承诺的稳定契约（`.sortedKeys` 之所以存在）；
  `roundTripMatchesBaseline` 自身在两次编码之间调用 `JSONValue.parse`（即 JSONDecoder），
  在 Linux Swift 6.2 上这会改变**同一 value 后续编码**的 key 顺序 → 断言确定/随机失败。
- 证据（逐字复制该测试文件 + Linux 编出的真实 `GatherProtocol` 模块，`swift test`）：

```text
# 逐字测试文件，隔离运行（--no-parallel）6 次
jsonvalue isolated: pass=1 fail=5
# 默认并行 4 次
jsonvalue parallel: pass=1 fail=3
# 失败样例（同一 value，两次编码 key 顺序不同）
Expectation failed: (json → "{\"meta\":{\"ok\":true},\"id\":7,\"tags\":[\"x\",\"y\"]}")
                 == (baseline → "{\"id\":7,\"tags\":[\"x\",\"y\"],\"meta\":{\"ok\":true}}")
```

  机制探针（最小用例，排除测试逻辑）：
  - `encode(value)` → **任意** `JSONDecoder().decode(...)`（甚至 `JSONValue.parse("1")`）→ 再 `encode(value)`：
    两次输出 key 顺序不同；而 `value` 的 Dictionary 迭代顺序前后一致（不是输入数据变了，是 Foundation 编码器
    内部顺序受进程全局状态影响）。
  - 先触发一次 JSONDecoder 再连续编码 → 顺序稳定（之后不再翻转）。
  - `SWIFT_DETERMINISTIC_HASHING=1` 下同一测试全绿 → 与哈希种子初始化相关。
  - 因此该测试是"进程内是否已用过 JSONDecoder + 并行调度"相关的**抖动测试**：单独跑必挂/常挂；
    全量大 target 里可能因前面的用例已初始化 decoder 而侥幸通过（最坏的假绿/假红形态）。
- 建议修复：不要对含对象的 JSON 做跨 encoder 原始字节比较。改为：
  1) 结构比较：`#expect(try JSONValue.parse(cached) == JSONValue.parse(baseline))`；
  2) 字节级只保留给"顺序有定义"的标量/数组用例；
  3) 若仍要拦 `.sortedKeys/.prettyPrinted` 配置漂移：两侧都 `.sortedKeys` 规范化后再比字节，
     并单独断言默认输出无换行（`#expect(!json.contains("\n"))`）。
  改后请在 macOS 跑 `--filter JSONValueCodingTests` 与全量各一遍。
- 置信度：高（Linux 可复现、机制已定位）。
- macOS 不可验证：是。Darwin Foundation 可能不出现该翻转（若如此只是"侥幸稳定"，oracle 假设仍不成立）；
  macOS 首跑若红则升级 CI 阻塞。

### R3-T02（P2）DisplayDateFormattersTests 漏掉同一轮新增的 4 个 formatter 缓存（0 测试）

- 位置：`desktop/native/gather-app/Tests/GatherAppTests/DisplayDateFormattersTests.swift` 只覆盖
  mediumShort/pattern/localizedTemplate/shortShort/internetDateTime(+Fractional)/parseISO8601Date；
  生产 `desktop/native/gather-app/Sources/GatherUI/Support/DateFormatting.swift:130/146/154/161`
  （fileSize / internetDateTimeString / parseFixedUTC / formatFixedUTC），引入 commit 2b9bf100（在本 16 提交内）。
- 问题：这 4 个也是"缓存 vs 每次新建"的性能改造（生产调用点分别 8/1/1/1 处），但**全仓测试 0 引用**；
  708a6b89 的评审文档 §6.4 自己写了"perf-ui 未提交的 fileSize / internetDateTimeString / parseFixedUTC /
  formatFixedUTC 不在本文件覆盖范围；合并后建议按同一 oracle 模式补测"——现已合并，仍未补。
- 证据：`grep -rn "\.fileSize(|\.internetDateTimeString(|\.parseFixedUTC(|\.formatFixedUTC(" Tests` → 0 命中
  （`MetadataDisplay.fileSize` 是另一个函数，不算）；生产定义/调用点用 grep 核对。
- 建议修复：按现有"新建同配置 formatter 为 oracle"模式补 4 个用例；parseFixedUTC/formatFixedUTC 固定
  UTC+en_US_POSIX，断言方向/往返即可。
- 置信度：高。macOS 不可验证：否（可在 Linux 直跑，见 §4）。

### R3-T03（P2）DisplayDateFormattersTests 的 oracle 固定了环境，测不到"环境变化仍与旧实现一致"的声明

- 位置：测试 `DisplayDateFormattersTests.swift:29-41` 等；生产注释 `DateFormatting.swift:90-93`
  （"运行中改系统设置会命中新实例，输出不会停在旧环境（与旧实现一致，不引入展示差异）"）、
  `environmentKey` 在 `:180-182`。
- 问题：oracle 每次新建 formatter，但测试在同一进程/TZ/calendar 下比较，无法验证上述声明；
  而 `mediumShort`（`:64-73`，**pre-existing**，cache key 只有 locale、无 environmentKey）
  在系统时区变化后会返回旧时区展示串，新实例/带 envKey 的 `shortShort` 会跟随。Linux 探针（save/restore
  `NSTimeZone.default`）实测：
```text
before cached: Nov 14, 2023 at 10:13 PM   fresh: Nov 14, 2023 at 10:13 PM
after  cached: Nov 14, 2023 at 10:13 PM   fresh: Nov 15, 2023 at 7:13 AM   (Tokyo)
shortShort cached: 11/15/23, 7:13 AM     fresh: 11/15/23, 7:13 AM
cached-follows: false
```
- 影响：① 本测试无法发现"缓存键漏掉隐式环境"这类回归（pattern/shortShort/localizedTemplate 正是本轮
  新增 envKey 的方法，该声明没有测试背书）；② mediumShort 的陈旧展示是 pre-existing 生产问题（不属本 diff），
  但本 diff 的新测试本应覆盖这个维度；建议开单给 perf-ui/UI owner。
- 建议修复：测试里 save/restore `NSTimeZone.default`（如可行再 `Calendar`），断言 envKey 方法跟随新实例；
  mediumShort 的 cache key 建议补 environmentKey（另开生产修复）。macOS 时区变更通知路径需 owner 复验。
- 置信度：中高（cache key 缺失确定；macOS 传播路径未验证）。macOS 不可验证：是（传播路径）/否（key 缺口）。

### R3-T04（P2）ReviewFix 两个"负向窗口"仍可 false-green（未证明等待者已排队）

- 位置：`desktop/native/gather-app/Tests/GatherAppTests/ReviewFixTests.swift:1069-1090`
  （decodeGateSerializesBeyondLimit）与 `:1089-1104`（decodeGateCancellationDoesNotHang）；
  被测 `PhotoDecodeGate` 在 `Sources/GatherUI/Support/PhotoThumbnailView.swift:497-538`
  （actor，acquire 用可取消退避睡眠，无队列观察面）。
- 问题：`waiterDone` 只在 `gate.acquire()` 返回后才置位；"负向窗口 = 未完成"无法区分"已在 acquire 排队"
  与"Task 还没被调度起来"。若 80ms/40ms 窗口内 waiter 尚未启动：
  - 串行用例：窗口后 `gate.release()`，waiter 随后启动并立刻拿名额 → `second == true` 通过，
    **"limit=1 必须排队"从未被验证**；
  - 取消用例：waiter 取消后（甚至启动前）acquire 返回 false → `acquired == false` 通过，
    **"取消已排队等待者"这一目标路径未覆盖**。
  旧代码的 80/40ms 固定 sleep 有同样缺口；本轮换成带断言的窗口是改进，但**没有加"已启动"信号**，
  不能宣称已消除 false-green。CI 串行 + 重载机器上概率不低。
- 建议修复：Task 内 `gate.acquire()` 之前置 `waiterStarted`，先用正向
  `#expect(await waitUntilAsync { waiterStarted.isSet })` 确认已启动，再做负向窗口；或给 actor 暴露
  测试可见的排队计数（测试 target 可 `@testable`）。
- 置信度：高（代码路径可判定）。macOS 不可验证：否（概率不可量化）。

### R3-T05（P2）test-catalog 计数 ratchet 严重过期，"删用例"保护实际失效（pre-existing）

- 位置：`scripts/check-test-catalog.sh:370-371`（`BASELINE_TEST_DECL=2502` / `BASELINE_SUITE_DECL=283`）、
  `:484`（`BASELINE_ASSERT=11509`）；本轮（6fecfcce）只改 trap/shellcheck 注释，未动基线。
- 问题：本轮硬门禁实测 `@Test 3267 / baseline 2502`、`@Suite 419 / 283`、断言 `14954 / 11509`。
  ratchet 只防"低于基线"，当前允许**静默删除最多 765 个 @Test / 3445 条断言**而不失败，
  "删真用例补空壳"保护等于没有。708a6b89 文档把 3255→3267 当"供 docs 校准"计数，但基线没收紧。
- 证据：`./scripts/check-test-catalog.sh --strict` 输出；另用与脚本同款剥注释计数器对
  `git archive origin/main` 的 Tests 独立计算：origin 3255/417/14911，current 3267/419/14954，
  与文档声称的 +12/+2/+43 完全一致。
- 建议修复：非本轮引入（基线最后一次修改在 origin/main 之前），但作为"测试卫生"交付的一部分，
  建议下一轮把三个基线收紧到实测值并在 docs 记账；否则本轮"新增 12 测试"没有 ratchet 意义。
- 置信度：高。macOS 不可验证：否。

### R3-T06（P3）5 处迁移调用点的 `try` 冗余（编译器 warning）

- 位置：`DuplicateServiceTests.swift:492`；`FaceKeywordingServiceTests.swift:391/1881/1948`；
  `SimilarityServiceTests.swift:959`。condition 闭包不抛错但写成 `try await waitUntilCondition`，
  Swift 6.2 对 rethrows 调用给 `warning: no calls to throwing functions occur within 'try' expression`
  （本次 Linux 探针已复现同类 warning）。
- 影响：测试 target 不在 `check-warnings.sh` 的 `-warnings-as-errors` 面内（只 build Sources），
  CI 的 `swift test` 也不把 warning 当错 → **不会红**；属噪音，如未来把测试纳入严格告警会集中爆。
- 建议修复：删这 5 处 `try`；或给 helper 增加非 throwing overload。
  （`FaceKeywordingServiceTests:414` 闭包内 `try runRow`，那处 try 必要，不在列表内。）
- 置信度：高。macOS 不可验证：否。

### R3-T07（P3）两个 AsyncWait helper 语义不对称（backoff / 超时越过）未在文档说明

- 位置：core `desktop/native/gather-core/Tests/GatherTestSupport/AsyncWait.swift:21-59`（固定 interval=20ms、
  超时返回"最后一次求值结果"、非 @MainActor、rethrows）；app `Support/AsyncWait.swift:51-68`
  （5ms 起指数退避到 100ms、超时直接返回 false、@MainActor、@discardableResult）。
- 问题：文档统称"共享异步等待"，但策略不同：core 版并行满载下每 20ms 唤醒（5s 超时≈250 次）；
  app 版退避到 ≤100ms；两者超时都可能越过一个 interval（core ≤20ms、app ≤100ms）——Linux 探针实测
  app `timeout: 0.5` 实耗 0.556s。属"失败上限"语义，但文档未写。
- 建议修复：可选。core helper 可复用 app 的退避；或两文件头写明差异与超时越过上界。
- 置信度：高（代码+探针）。macOS 不可验证：否。

### R3-T08（P3）`waitForTerminal` 改成"等待 + 二次查询"引入 TOCTOU 与重复查询

- 位置：`AppRuntimeTests.swift:145-157`、`WorkflowRegistryTests.swift:169-181`。
- 问题：旧实现返回轮询中读到的 terminal 快照；新实现 `guard terminal else { return nil }` 后又 list 一次。
  若 job 在两次查询间被删（当前夹具不会），会从"拿到终态"变 nil；且每调用多一次全量 list（测试规模无感）。
  现有调用方都断言非 nil，语义等价成立。
- 建议修复：让条件闭包把命中的 job 存进 Sendable box 返回，避免二次查询；或查询后校验 status 仍为终态。
- 置信度：高。macOS 不可验证：否。

### R3-T09（P3）`DefaultSignatures.analysisSignature()` 从 static let 变 static func 后失去记忆化

- 位置：`FaceKeywordingServiceTests.swift:183-198`（5a4cb265）。抛错替代 try! 方向正确；static let 原本只求值一次
  （惰性），现在 3 个调用点都会重新执行 `FaceEmbeddingModelFactory.spec(...)`。测试成本很小，
  注释"仍保持惰性求值"属实但不再是"只算一次"。
- 建议修复：可选，加简单缓存或注释说明"每次重算"。
- 置信度：高。macOS 不可验证：否。

### R3-T10（P3）`scripts/test.sh:34` `read -r -a` 只消费第一行 flags（边界行为变窄）

- 位置：`scripts/test.sh:31-34`（6fecfcce）。旧写法按任意空白（含换行）拆分；新 `read` 只读第一行。
  用假 `swift` 干跑验证：空值 → 0 参数且不因 `set -e` 退出；`--disable-sandbox --filter Foo.*` → 正确拆 2 个参数，
  且 `Foo.*` **不再被 glob 展开**（本改动收益，SC2206 也消掉）。多行 flags 属非预期用法，影响可忽略。
- 建议修复：不必改；若要求 100% 旧语义需 `mapfile`（macOS bash 3.2 无），现状是合理取舍。
- 置信度：高。macOS 不可验证：否（CI 不跑 test.sh，本地 macOS 需 owner 确认）。

### R3-T11（P3）同款"锁盒布尔旗标"已有 3 份私有副本

- 位置：本轮新增 `APIDuplicateQualityTests.swift:35-41`（LockedFlag）、`ReviewFixTests.swift:19-25`（ReviewFixFlag）；
  既有 `APIExportMetadataTests.swift:409-416`（LockedFlag）。实现完全相同（NSLock + Bool）。
- 影响：无功能问题（file-private 不冲突；cleanup ratchet 只扫 Sources，Tests 不计 @unchecked Sendable），仅复制粘贴。
- 建议修复：挪一份到 `GatherTestSupport`（public，测试专用 product）供两 target 共用。
- 置信度：高。macOS 不可验证：否。

### R3-T12（P3）`docs/test-runtime-audit.md` 新增基线句里 suite 数字对不上（交 docs-steward）

- 位置：`docs/test-runtime-audit.md`（708a6b89 新增段落）。声明口径 "core 2,001 @Test / 235 @Suite、
  app 1,266 / 184"（与 catalog 实测一致：合计 3267/419 ✓），但同句"最近一次 macOS 运行（2026-11-16）为
  core 1,970 / 290 + 串行 25 / 4"里 core suite 数 290 > 235，口径不明。建议注明口径或删掉不可对账数字。
- 置信度：中（数字核对确定，语义推测）。macOS 不可验证：否。

## 3. 逐热点结论

1. **反模式替换**：**通过**。Tests 下实际 `try!`/`fatalError`/`preconditionFailure`/`try? #require` 均为 0
   （grep 只剩注释说明文字）；7 个文件的函数签名补 `throws`/`async throws` 已逐个核对；断言没有削弱
   （失败从"崩溃"变"用例失败"，不是从"失败"变"通过"）；`insertTrackedFile` 的 preconditionFailure →
   public `MissingFixtureFileError`，7 个调用点本来就 `try`；关键表达式用 Swift 6.2 typecheck 探针
   （`#expect(try JSONValue.parse(...)...)`、`try #require(arr.first)`、`#expect(try await rethrowsHelper {...})`）全部通过。
2. **异步等待迁移**：**通过（P3 建议）**。语义探针全绿：满足即返回；deadline 有界（0.2s→0.202s）；
   超时返回最后求值；条件抛错 rethrows；取消后立即返回 false（50ms 内）；负向窗口等满（0.1s→0.101s）；
   app helper 指数退避生效（0.5s 内求值 ≤30 次而非 ~100 次）；@MainActor 条件可见；
   "non-Sendable 捕获 + 等待后继续使用 + 跨模块 helper"形态在 Swift 6 模式可编译可运行。
   迁移点全部断言结果（`_ =` 丢弃 0）；5 个 app 文件均 `import GatherTestSupport`；core helper 只被
   非 @MainActor 套件调用，app helper 新调用点所在套件均 @MainActor（隔离匹配）。残余私有 helper
   （JobService/TraceLogging/Writeback）pre-existing 且文档已列（其中两个返回 Void、超时静默继续，建议继续跟踪）。
3. **墙钟容差**：**通过**。ReadPool `< 1s` 仍能拦"SELECT 等写事务释放"病态回归（会撞 5s 慢事务兜底）；
   ExportPostCommand 子进程 30s + 断言 < 10s 对照 runner 实现（1s SIGTERM、2s SIGKILL、取消 terminate）
   仍有区分度；CullingDecisionRepo 改钉 created_at 是**加强**且确定性（已核对 upsert SQL 不写 created_at、
   该表无触发器）。
4. **新增测试**：DisplayDateFormattersTests **能编译能跑**（Linux 逐字文件 6/6 通过 ×3 次重复），oracle 对
   已覆盖口径与生产一致，但覆盖缺口 → R3-T02/03；JSONValueCodingTests **能编译**（真实 GatherProtocol 模块），
   malformed/结构比较用例正常，但 roundTrip 逐字节 oracle 可复现失败 → R3-T01。
   helper 可见性/归属 OK：GatherTestSupport 是普通 library target（path 显式 `Tests/GatherTestSupport`，public API，
   product 只进测试链接），两 test target 都依赖 → 新 helper 两 target 均可见、无重复符号；新 3 个 .swift 首行均为 `//` 路径注释。
5. **完整性**：无删除用例（diff 只有新增 @Test/@Suite）；无重复测试；数量类文档声明**全部复核为真**
   （3255→3267 / 417→419 / 14911→14954 / 330→333 文件；sleep 49→32、文件 30→20、Thread.sleep 6→2、
   重复 wait helper 4→0）；计数 ratchet 基线过期 → R3-T05；`scripts/test.sh` 改动正确（假 swift 干跑验证）
   只有多行 flags 边界 → R3-T10；catalog trap 改动正确（--self-test 通过、无临时目录残留、shellcheck 0 finding）。

## 4. 独立验证通过清单（本次实际跑的）

| # | 检查 | 命令/方式 | 结果 |
|---|---|---|---|
| 1 | 改动测试文件语法 | `.gather/swift_syntax_all.sh <31 个改动 .swift>`（Swift 6.2 `-parse`） | 31 files, 0 failures |
| 2 | test catalog 硬门禁 | `./scripts/check-test-catalog.sh --strict` | OK：333 文件 / @Test 3267·2502 / @Suite 419·283 / 断言 14954·11509 / 缺头 0 / skip 元数据缺失 0 / 过期 0 |
| 3 | catalog 负例自测 | `./scripts/check-test-catalog.sh --self-test` | SELFTEST OK，无 `/tmp/tmp.*` 残留 |
| 4 | cleanup ratchet | `./scripts/check-cleanup-ratchet.sh` | OK（try_optional 256/257、try_bang 0、fatal_error 0 等；Tests 不在扫描面） |
| 5 | repo hygiene（含 shellcheck 26 个 sh） | `PATH=.gather:$PATH ./scripts/check-repo-hygiene.sh` | a–g 全 PASS，shellcheck 0 finding |
| 6 | docs-facts / duplicate-symbols | 两个脚本 | 均 OK |
| 7 | 新 helper 单独编译（Swift 6 模式） | `swiftc -typecheck -swift-version 6` × 两个 AsyncWait.swift | 均通过 |
| 8 | 新 helper 语义探针（13 用例） | `.gather/r3-harness`（helper 逐字复制，Swift 6 模式） | 13/13 pass（deadline/rethrows/cancel/backoff/negative window/MainActor/跨模块 non-Sendable 捕获） |
| 9 | DisplayDateFormattersTests 运行 | 测试文件 + `DateFormatting.swift` 逐字复制，Linux `swift test` | 6/6 pass ×3 次 |
| 10 | JSONValueCodingTests 运行 | 测试文件逐字 + 仓库编出的真实 GatherProtocol 模块 | 可编译；isolated 6 次 = pass 1/fail 5；parallel 4 次 = pass 1/fail 3（R3-T01） |
| 11 | 计数声明独立复核 | `git archive origin/main` 提取 Tests + 脚本同款剥注释计数器 | origin 3255/417/14911 → current 3267/419/14954，delta +12/+2/+43 = 文档声明 |
| 12 | sleep / helper 副本声明复核 | 自写掩码扫描器（origin 提取 + 当前工作树） | 49→32 站点、30→20 文件、Thread.sleep 6→2、4 份重复 wait helper→0，与文档 §1/§5 一致；helper 内部 4 个 Task.sleep 计入总数 |
| 13 | 反模式清零 | grep try!/fatalError/preconditionFailure/try? #require in Tests | 0 处实际代码（仅 3 处注释文字）；`?? 0` 残留均为无关数值兜底 |
| 14 | 迁移调用点断言审计 | grep `_ = await waitUntilAsync` / `_ = try await waitUntilCondition` | 0 丢弃；全部 #expect 或 guard+throw |
| 15 | 迁移文件 import | 逐文件 grep | 5 个 app 文件均 `import GatherTestSupport` |
| 16 | test.sh 参数行为 | 假 `swift` 干跑：空值 / `--disable-sandbox --filter Foo.*` | 空值→0 参数且不退出；两 flag 正确拆分；`Foo.*` 不再 glob 展开；serial 名单推导正常 |
| 17 | bash 边界 | `read -r -a` 在 `set -euo pipefail` + 空 herestring 下 rc=0 | 与脚本注释一致 |
| 18 | 墙钟语义对照生产实现 | 读 ExportPostCommandRunner / CullingDecisionRepo / ReadPool 相关代码 | 阈值仍有区分度 |
| 19 | 文档数字一致性 | test-hygiene-round2 §1/§2/§3/§5 + round2 overview | 除 R3-T12 疑点外全部对账 |
| 20 | mediumShort 时区漂移探针 | 逐字生产文件 + save/restore NSTimeZone.default | 复现 stale（R3-T03 证据） |

## 5. 覆盖与局限（必须随结论一起读）

1. **无 macOS/Xcode，无法 `swift build`/`swift test` 目标仓库测试 target**（GatherAnalysis 依赖 CoreGraphics/Vision/CoreML，
   Linux 编不过；GatherAppTests 依赖 SwiftUI/AppKit）。因此：
   - App 侧测试文件（DisplayDateFormatters/ReviewFix/C1StatusCapsule/LayoutBudget/…）**未在真实 target 编译**，
     只做 `-parse` + 关键 API/可见性静态核对 + 部分逐字复制探针；
   - core 侧只有 GatherProtocol 被真实编译；迁移的 core 测试文件（ReadPool/CullingDecision/DuplicateService/
     FaceKeywording/Similarity/DirectoryWatcher）未 typecheck，"已标 throws/async throws"与断言是**逐处人工核对**，
     不是编译器保证；
   - Swift 6 严格并发在 Darwin 上的最终裁决（尤其 JSONEncoder/JSONDecoder 是否 Sendable、生产
     `JSONValueCoding` 的两个 static let）未验证——若不是 Sendable，GatherProtocol 会在 macOS 编译失败
     （属 perf-core 改动面，但与本轮新测试共用同一路径，故标注）。
2. **Linux Foundation ≠ Darwin Foundation**：R3-T01 的失败/抖动是 Linux Swift 6.2 + swift-corelibs-foundation 实测，
   **macOS 是否同样翻转未知**；即使侥幸稳定，oracle 仍依赖未承诺的 key 顺序，建议按 §2 修复后再声称"逐字节等价"。
   DisplayDateFormatters 的 locale/TZ 具体字符串跨平台可能不同，但测试是同平台 cached vs fresh 相对比较，不影响通过性。
   ISO8601DateFormatter 小数秒 nil、Date.ISO8601FormatStyle 解析等细节在 macOS 需 owner 确认。
3. **运行时概率类结论（负向窗口 false-green、超时越过）**：代码可判定，概率与 macOS 调度相关，未在本机量化。
4. **未评审的面**：perf-ui/perf-core 生产改动的功能正确性（只在与新测试 oracle 直接相关处抽查 DateFormatting/
   JSONValueCoding/ExportPostCommandRunner/CullingDecisionRepo/PhotoDecodeGate）；其余 perf 数字与
   `check-perf-ratchet.sh` 9 指标（仅确认 Tests 不在其扫描面）。
5. **未逐条复核 30 个改动测试文件的每个断言**：聚焦 3 个测试提交的完整 diff + 全部新 helper/新测试 + 迁移点上下文 +
   文档声明对账；其余（EOF/行尾、注释、import）按 diff 全量过了一遍。

## 6. macOS owner 复验清单（建议）

1. `./scripts/check-test-catalog.sh --strict`、`./scripts/check-cleanup-ratchet.sh`、
   `PATH=... ./scripts/check-repo-hygiene.sh`（本机已绿，CI 需同口径）。
2. `./scripts/test.sh core` 与 `./scripts/test.sh app` 各至少 2 次；重点：JSONValueCodingTests（R3-T01 若红即修）、
   5 个超时/负向窗口用例（APIDuplicate/APIExport 500ms、ReviewFix 80/40ms、C1StatusCapsule、LayoutBudget、
   DirectoryWatcher 8s）。
3. 并发顺序敏感项：core 串行批 + 全量各一遍（R3-T01 依赖"进程内是否已用 decoder"）。
4. `./scripts/check-warnings.sh core|app`（Sources 不受本轮测试改动影响，但 mac 编译器版本决定新 warning）。
5. 若时间允许：按 R3-T02/03 补 4 个 formatter 缓存用例 + 1 个 NSTimeZone.default save/restore 用例；
   把 test-catalog 三个基线收紧（R3-T05）。
