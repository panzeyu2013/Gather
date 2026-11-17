# Round-2 测试卫生审计：async waits / shared helpers / wall-clock / cache 回归

- 任务：task-12（round-2 hardening，test-steward）
- 基线 commit：4cb3228d（round-1 已完成；本文件只覆盖测试卫生，不动生产代码）
- 写作用域：desktop/native/{gather-core,gather-app}/Tests/** + 本文件
- 验证环境：Linux（无 macOS/Xcode），Swift 6.2 仅能 swiftc -parse；运行时行为由 macOS owner 用 ./scripts/test.sh 复验（见 §6）

## 1. 睡眠站点 inventory（before → after）

扫描口径：Tests 下非注释行的 Task.sleep / Thread.sleep 调用点（GatherTestSupport 也计入）。

| 指标 | round-2 起点 | 现状 |
|---|---|---|
| sleep 调用点总数 | 49 | 32（-17，-35%） |
| 涉及文件数 | 30 | 20 |
| Thread.sleep | 6 | 2（-4） |
| App 固定「等异步落定」等待（非 Support/） | 17 | 4（-13；4 处均为有意并已注释） |
| App Support/ 替身/helper 注入延迟 | 7 | 7（有意，测试替身模拟延迟） |
| Core 固定/轮询等待（不含共享 helper 本体） | 19 | 19（3 份 sync helper 与 CullingDecision 2ms 删除，ReadPool/DirectoryWatcher 轮询迁到共享 helper） |
| 重复的私有等待 helper 副本 | 4（FaceKeywording/Duplicate/Similarity 3 份 sync + APIExportMetadata 1 份 async） | 0（统一到 2 个共享 helper） |

> 注：总数含共享 helper 内部的 4 个 Task.sleep（core 新 helper 2 + app 既有 helper 2）；这些是等待机制本体，不计入固定等待。

### 1.1 已替换（App 测试，全部断言等待结果）

- APIDuplicateQualityTests.swift:177 waitForJob 有界轮询 → waitUntilCondition，超时 throw（保持原错误）; :282 500ms 固定 settle → **有界负向窗口**（#expect(!(await waitUntilCondition(timeout: 0.5) { secondFinished.isSet }))，第二个 scan 不得在门放行前终态）。
- APIExportMetadataTests.swift:47 waitForJob 同上；:258 500ms settle → 负向窗口；:1090/:1149/:1178 同步条件改共享 waitUntilCondition；:1101/:1183 actor 条件用共享 waitUntilConditionAsync；删除文件内私有 waitUntilAsyncCondition 重复实现。
- AppRuntimeTests.swift:150、WorkflowRegistryTests.swift:174 waitForTerminal 轮询 → waitUntilCondition（超时返回 nil，语义不变）。
- C1StatusCapsuleTests.swift:130 20ms sleep → 条件等待 api.syncStatusCalls.count == 1（第一次 refresh 已发出）。
- C1PendingJudgementReplayTests.swift:83 手写 spin + 2ms sleep → waitUntilConditionAsync（有界，超时由断言兜底）。
- LayoutBudgetTests.swift:226 80ms sleep → 条件等待（clusters/isLoading/step 就绪）。
- ReviewFixTests.swift:1080/1100 解码闸门 80ms/40ms → **有界负向窗口**（等待者不得提前完成/仍在排队）。

### 1.2 已统一（Core 3 份重复 sync helper → 1 个共享 async helper）

新增 GatherTestSupport/AsyncWait.swift（public，不 import Testing）：

- waitUntilCondition(timeout:interval:_ condition: () throws -> Bool) async rethrows -> Bool（:21）
- waitUntilConditionAsync(timeout:interval:_ condition: () async -> Bool) async -> Bool（:42）

设计：Task.sleep 让出协作线程池；ContinuousClock 单调计时（替代墙钟 Date 截止）；每轮检查 Task.isCancelled；超时返回最后一次求值结果；条件抛错 rethrows。默认 5s / 20ms，足够覆盖并行调度且失败有界。

调用点迁移（全部加断言，原 _ = 丢弃改为 #expect）：

- FaceKeywordingServiceTests.swift:391/414/1881/1948
- DuplicateServiceTests.swift:492
- SimilarityServiceTests.swift:326/635/932/959
- 顺带：ReadPoolTests.swift:54（原 for+sleep 轮询）、DirectoryWatcherTests.swift:56（原 8s deadline 轮询）

### 1.3 有意保留（已加注释 / 已有注释）

见 §5 残差清单。

## 2. Wall-clock 容忍度（3 处）

| 位置 | 之前 | 现在 |
|---|---|---|
| ReadPoolTests.swift:57-66 | Date() 计时 + < 0.6s 裸阈值 | ContinuousClock + < .seconds(1)，注释说明「1s 仍能拦住等写事务释放（5s 兜底）的病态回归」 |
| ExportPostCommandTests.swift:52-64 | 子进程 sleep 5、Date() < 4 | 子进程 sleep 30、ContinuousClock < .seconds(10)；宽上限只拦「没按 timeout 终止、等满 30s」 |
| ExportPostCommandTests.swift:150-171 | 子进程 sleep 5、Date() < 3 | sleep 30、< .seconds(10)；150ms 启动余量改走 awaitNegativeWindow（有界窗口） |
| CullingDecisionRepoTests.swift:33-46 | Thread.sleep(2ms) 赌 ISO 毫秒前进 | 删除 sleep：把 created_at 钉到固定 2020-01-01T00:00:00.000Z，断言 ON CONFLICT 保留 created_at 且推进 updated_at（确定性，且比原断言更强） |

## 3. 新增缓存回归测试（2 个新文件）

### desktop/native/gather-app/Tests/GatherAppTests/DisplayDateFormattersTests.swift（1 @Suite / 6 @Test）

oracle = 每次新建同配置 DateFormatter / ISO8601DateFormatter：

- mediumShort（dateStyle .medium + timeStyle .short）zh_CN/en_US × 3 个固定 epoch 逐字节一致；
- pattern（yyyy-MM-dd HH:mm / yyyyMMdd-HHmmss）逐字节一致；
- localizedTemplate（yMd）逐字节一致；
- shortShort（.short/.short）逐字节一致；
- ISO-8601 解析：plain 输入与 fresh [.withInternetDateTime] 结果一致；带小数秒与 fresh [.withInternetDateTime, .withFractionalSeconds] 一致；plain 解析器对小数秒输入返回 nil（旧 fallback 语义）；坏输入双方均 nil；
- parseISO8601Date fallback：带/不带小数秒均解析，坏输入 nil（与 Date.ISO8601FormatStyle 对照）。

### desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift（1 @Suite / 6 @Test）

oracle = 每次新建默认配置 JSONEncoder/JSONDecoder：

- stringify 与 baseline encoder 逐字节一致（null/bool/number/字符串转义/数组/多键对象）；
- parse 与 baseline decoder 结果一致（转义 unicode、空白、标量）；
- JSONValue(encoding:) 与「新建 encoder→decoder」路径一致且模型往返无损；
- decode(_:) 往返一致；
- stringify → parse 无损且与 baseline 编码逐字节一致（防 .sortedKeys 等配置漂移）；
- 损坏输入：JSONValue.parse 与新建 decoder 均抛 DecodingError（失败语义不变）。

声明数变化（供 docs 校准）：@Test 3255 → 3267（+12）、@Suite 417 → 419（+2）、
#expect+#require 14911 → 14954（+43）、测试文件 330 → 333（+3，含 GatherTestSupport/AsyncWait.swift）。

## 4. 门禁与验证

命令（均在 /root/projects/Gather 执行）：

- swiftc -parse -enable-bare-slash-regex <每个改动的 .swift> → 全部 PARSE_OK（语法层）
- ./scripts/check-test-catalog.sh --strict → OK；@Test 3267/2502、@Suite 419/283、断言 14954/11509
- ./scripts/check-cleanup-ratchet.sh → OK（全部指标 ≤ baseline；本次实测 try_optional 257/260、try_bang 0、fatal_error 0 等）
- PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh → OK（a-g 全 PASS，shellcheck 0 finding）

### 验证上限（重要）

Linux 无 macOS/Xcode：**无法 swift build / swift test**。以上只是语法解析 + 仓库门禁；
async 等待迁移、负向窗口断言、ContinuousClock 计时与新回归测试的**运行时行为均未经编译/执行验证**。
owner 需在 macOS 上跑 ./scripts/test.sh core 与 ./scripts/test.sh app 复验。

## 5. 残差清单（有意保留的 sleep，按文件:行）

App：

- C1PendingJudgementReplayTests.swift:45 — 注入的 sleep: seam（真实等待，watcher 紧循环会耗尽脚本结果，注释已说明）。
- CullingViewModelAPITests.swift:223 — 替身注入响应延迟（模拟真实异步写入，已注释）。
- GalleryViewModelTests.swift:125 — 替身注入取页延迟（构造在途悬挂旧响应，已注释）。
- Support/AsyncWait.swift:65/73 — app 等待 helper 本体（waitUntilAsync / awaitNegativeWindow）。
- Support/StubCullingAPI.swift:483/605/817、StubFaceAPI.swift:240、StubSimilarityAPI.swift:203 — 替身注入延迟（delay > .zero 才睡）。
- WorkspaceVisibilityTests.swift:418 — settleMainQueue 主队列排空窗口（替代 RunLoop 泵的既定设计，注释已说明）。

Core：

- BatchRunnerTests.swift:74/90/116/149 — 并发夹具延迟（制造完成序/取消窗口）与有界 spin（已有界）。
- DatabasePragmaTests.swift:110 — 与 db.close() 交错的调度余量（2ms）。
- ReadPoolTests.swift:148 — 慢事务阈值用例的事务内 sleep（阈值 1ms，必须真睡过阈值）。
- DeliveryFilePhaseTests.swift:294 — 并发探针注入的 restore 延迟。
- FaceInferenceTests.swift:181 — 手动集成档（.enabled(if: IntegrationTestGate.modelTestsEnabled)）的启动余量。
- TraceLoggingTests.swift:532/824 — 文件内私有 async wait helper（可后续并入共享 helper）。
- DeliveryCoordinatorTests.swift:720 — 两路 replay 抢占的调度余量（已注释，先释放避免测试自身死锁）。
- DirectoryWatcherTests.swift:49 — FSEventStream 无就绪探针，保留有界启动 warm-up（不是断言窗口）。
- DuplicateServiceTests.swift:470 — boundedOutcome 的超时竞争（等待本身即语义）。
- JobServiceTests.swift:190/209/327 — 文件内私有 wait helper；:955 — 租约 50ms 的过期窗口（墙钟语义本身）。
- WritebackServiceTests.swift:1074/1087 — 文件内私有 sync/async wait helper。

建议后续：把 JobService/TraceLogging/Writeback 的私有 wait helper 也并到共享 helper（本次未做，
避免触碰未列入任务的文件）；BatchRunner 的两处有界 spin 可换共享 helper；App 的三个替身延迟是夹具
语义的一部分，不建议替换。

## 6. 风险与后续

1. **无法编译**：Swift 6 严格并发下，把非 @Sendable 闭包传给 nonisolated async 共享 helper 的
   类型检查未在本机验证（与仓内既有私有 async wait helper 同一模式，风险低但非零）；#expect 内
   await + 负向窗口表达式也需 macOS 编译器确认。
2. **500ms/80ms/40ms 负向窗口**仍是有界墙钟窗口（现在会断言失败而不是静默），在极端调度饥饿下
   「等待者已提前完成」的假阳性概率极低，但仍非纯条件驱动。
3. **CullingDecision 钉时间戳**依赖 SQL 事实：ON CONFLICT DO UPDATE 不写 created_at（对应生产 SQL 已核对）；
   若未来 upsert 改为重写 created_at，该用例会正确变红。
4. **DisplayDateFormatters 的 round-2 新缓存**（perf-ui 未提交的 fileSize / internetDateTimeString /
   parseFixedUTC / formatFixedUTC）不在本文件覆盖范围；合并后建议按同一 oracle 模式补测。
5. 新回归测试依赖 Foundation formatter 语义：字节一致性以「同 OS 的新建实例」为 oracle，跨 macOS
   版本也成立（两侧同时变化），但若有人把展示路径换回 FormatStyle，测试会捕捉到差异。
