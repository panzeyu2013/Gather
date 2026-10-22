# 重构后 R7 测试与门禁有效性评审

- 评审对象：`/Users/panzeyu2013/Desktop/code/develop/Gather`（HEAD `82603e0`，重构工作区未提交）
- 评审方式：**只读**。未修改源码/测试/Package/脚本，只运行针对性测试与 CI 同款门禁。
- 评审日期：2026-10-22
- 基线声明（docs/refactor-progress.md:17-18、docs/final-report.md:38）：core **1,092/157**、app **581/66**，8 门禁全过。

## 结论先行

1. **P0（已确认）**：app 全量测试在 Swift Testing **默认并行**下本机 **6/6 次失败**（每次 1–9 个 issue，4 个不同用例）；只有加 `--no-parallel` 才 3/3 全绿。CI 的 app job 恰好**不加** `--no-parallel`（`.github/workflows/ci.yml:87`），而台账/验收命令明确带 `--no-parallel`（`docs/final-report.md:38,80`）。CI 与验收跑的不是同一条命令，CI 侧红/间歇红的概率很高（远端 CI 未实际观测，标“疑似红”）。
2. **P1（已确认）**：3 个真实照片人脸用例用 `.enabled(if: fixtureImageData != nil)` 永久跳过（本机无 `GATHER_FACE_FIXTURE` 时显示 `skipped`），但基线 1,092 **包含这 3 条**；`check-test-catalog.sh` 只识别 `.disabled`，完全看不到 `.enabled(if:)`，CI 又只跑 warning 模式。即“skip 3”既不在数量口径里，也不在门禁里。
3. **P1（已确认）**：**没有测试数量/覆盖率的 ratchet**。删掉一批测试不会让任何门禁变红；1,092/581 只是文档数字，CI 不校验。
4. **P1（已确认）**：`check-test-catalog.sh` 在 CI 里没有 `--strict`（`.github/workflows/ci.yml:46`），即使加 strict 也只检查“文件头 + 到期字样”，新增禁用用例仍可能静默通过。
5. **P2**：其余门禁存在“规则窄于名字”的问题（layering 只匹配 `^import X`；select-star 漏多星号；docs 只查 ADR 反引号路径；duplicate 只查 3 个符号；ratchet baseline 元数据过期）。当前都真绿，但存在假绿路径。
6. **覆盖率结论**：Delivery/SchemaV1/ClusterGraph/FaceMatcher 的新测试质量总体高（含 golden、逐位一致、回滚、随机对账）；短板集中在 **失败/重放失败路径、Workspace 扇出语义、bundle 打包**，以及**测试基础设施的确定性**。

---

## 1. 范围与方法

### 1.1 实测命令与结果

| 命令 | 结果 | exit |
| --- | --- | ---: |
| `gather-core: swift test --disable-sandbox --cache-path ../.build/shared-cache --scratch-path ../.build/scratch` | `Test run with 1092 tests in 157 suites passed`（2 次） | 0 |
| `gather-app: 同上 + --no-parallel` | `Test run with 581 tests in 66 suites passed`（3 次） | 0 |
| `gather-app: 同上，默认并行（= CI 命令）` | **6 次全失败**：`Test run ... failed ... with 1/2/5/9 issues` | 1 |
| `core: 同上 + --explicit-target-dependency-import-check error`（CI 同款） | `Test run with 1092 tests in 157 suites passed` | 0 |
| `app: 同上 + strict import check + --no-parallel`（CI 同款仅差并行） | `Test run with 581 tests in 66 suites passed after 13.036s` | 0 |

失败用例（去重后 4 个）：

| 用例 | file:line | 失败点 |
| --- | --- | --- |
| `4a-2b：setVisible 启停兜底轮询（幂等），shutdown 后不复活` | `desktop/native/gather-app/Tests/GatherAppTests/DuplicatesControlCenterAPITests.swift:384` | `#expect(await waitUntilAsync { sessionAPI.getCalls.count >= 2 })` |
| `B8.2b：cancelQualityAnalysis 走 JobAPI.cancel 且保留可见文案` | `.../CullingViewModelAPITests.swift:573` | `#expect(await waitUntilAsync { vm.notice == ... })` |
| `保存提示用人类标签，不暴露内部键` | `.../SettingsSaveSemanticsTests.swift:96,100` | 先 `_ = await waitUntilAsync { vm.notice != nil }`（丢弃结果），随后断言 notice 文案 |
| `影响面计数：角色绑定与人物建议都算已绑定，未绑定的不算` | `.../FaceReclusterConfirmTests.swift:46,58-59` | `makeViewModel` 等 clusters 落地（返回 Bool 被丢弃），随后断言 `impact.clusterCount == 3` |

共同点：都依赖 `waitUntilAsync` 默认 **2s** 超时（`.../Support/AsyncWait.swift:28`）；并行满载时等待超时，测试继续执行并对派生状态断言 → 表现为业务断言失败。**这是测试基础设施的确定性缺陷，不是产品逻辑缺陷**（串行全绿、单测过滤全绿）。

### 1.2 只读边界与限制

- 扫描范围：**163 个测试文件**（core 98 + app 65）、**1,673 个 `@Test` 声明**、535 个 Swift 源文件；8 个门禁脚本 + 1 个 CI workflow。HEAD 侧用 `git show HEAD:` 取旧测试文件与 @Test 数。
- 未运行 `build.sh`（本机 DSH 沙箱 `sandbox_apply: Operation not permitted`，台账已记）；未做人工 GUI 验收。
- 未观测 GitHub Actions 远端结果；CI 结论基于“命令与环境一致 + 本机复现”，按“疑似”标注。
- 测试数用 `swift test` 汇总行 + `@Test` 声明数双向核对；`@Test` 原文出现 1,675 次（core 1,092 + app 583，其中 app 2 次在注释里，实际声明 581）。

---

## 2. 测试基线核对

### 2.1 数量核对

| 口径 | 声明 | 实测 | 结论 |
| --- | ---: | ---: | --- |
| core | 1,092 / 157 | 1,092 / 157，exit 0 | 一致 |
| app | 581 / 66 | 581 / 66（`--no-parallel`），exit 0 | 一致；并行不成立 |
| @Test 声明总数 | — | 1,673 | 一致（1092+581）；原文出现 1,675 次（含 app 2 条注释示例） |
| 参数化用例 | — | 18 个 `@Test(..., arguments:)` | 汇总行按“函数”计，参数 case 不计入 581/1,092 |
| 实际执行 vs skipped | — | 3 条永久 skip（见 P1-1） | core 有效执行 1,089（app 581 全执行；无 env 时） |

### 2.2 被删/新增测试与行为变化是否匹配

HEAD 的测试文件（`git show HEAD:`）与当前工作区对比：

| 被删测试文件 | HEAD @Test | 对应行为变化 | 替代覆盖 |
| --- | ---: | --- | --- |
| `CommandSurfaceRuntimeTests.swift` | 4 | Router/字符串命令删除（Cut 1） | `APISessionTests` / `APICullingTests` 等 10 个 `API*Tests` 文件 |
| `NativeCommandClientTests.swift` | 7 | 同上 | 同上 + `ExecutorRegistryTests` / `AppCompositionTests` |
| `MetadataOutboxRepoTests.swift` | 20 | 旧同步栈删除（Cut 2） | `DeliveryRepoTests`（25）、`DeliveryIntentRepoTests`（10） |
| `WritebackRepoTests.swift` | 9 | 同上 | `DeliveryRepoTests` / `WritebackServiceTests`（13） |
| `MetadataSyncCoordinatorTests.swift` | 10 | 同上 | `DeliveryCoordinatorTests`（16） |
| `MetadataWritebackStateMachineTests.swift` | 14 | 状态机收敛到 `DeliveryState` | `DeliveryRepoTests` 状态迁移用例 + `SchemaV1Tests` CHECK |
| `ClusteringImpactTests.swift` | 9 | ClusterEngine 删除（Cut 5） | `ClusterGraphTests`（12） |
| `HelperMessageTests.swift` | 4 | Helper IPC 功能整体删除（grep Sources = 0） | 无需替代 |
| `HelperProtocolTests.swift` | 19 | 同上 | 无需替代 |
| **合计** | **96**（含 app 11） | | 新增约 474 条（core +183 净、app +291 净） |

判断：**删除与行为变化基本匹配，未发现“功能仍在但测试被成片删除”的孤儿**（已确认；Helper IPC 源码已 0 引用，属合法删除）。新增测试主要落在 typed API、Delivery/SchemaV1、ClusterGraph/FaceMatcher，方向正确。

> 口径漂移：HEAD 的 app @Test 实测 301，而台账 Cut 0 记 298（差 3，未见说明；疑为基线快照时点差异）。本表按 HEAD 实测 301 计。

### 2.3 关键新代码断言抽样（有效性）

| 模块 | 测试 | 断言强度 | 评价 |
| --- | --- | --- | --- |
| Delivery | `DeliveryCoordinatorTests` 16 例；`DeliveryRepoTests` 25 例；`DeliveryIntentRepoTests` 10 例 | 状态门禁、跨会话、cleanup/finalize、replay prepared/fileDone、restore 失败、**事务回滚 2 例**（`DeliveryRepoTests.swift:501,539`）、CAS/illegalTransition | 强；缺 replay 失败与批量部分失败 |
| SchemaV1 | `SchemaV1Tests` 18 例 | 43 表/373 列/69 索引/62 FK、CHECK/FK/RESTRICT/CASCADE、列名映射 | 强 |
| Database | `DatabaseFacadeTests` 10 例 | user_version=99 重置含 -wal/-shm、非 SQLite 重置、事务/SAVEPOINT、close 幂等 | 强，覆盖迁移/重置 |
| ClusterGraph | `ClusterGraphTests` 12 例 | 17 例 golden 逐组/组序、state 不变量、度门控、多档、200 步随机增删、32,769 streaming 对账 | 强 |
| FaceMatcher | `FaceMatcherBatchTests` 8 例 | 批量 vs 逐条 **精确 Double 逐位一致**、排除/亚军、margin、维度错误、批量不建 LSH | 强 |
| API | 10 个 `API*Tests` + 16 个 ContractTests | 7 个用真实服务 + 内存 SQLite；`APIFaceUITests`/`APISimilarityUITests` 是 VM+Stub，`APIErrorPresentationTests` 是映射测试；错误码/参数错误有断言 | 中上；`LiveCullingAPI.history` 无 Live 层用例；无方法面完整性门禁 |
| Workspace | `FactoryTests`、`ViewStateTests`、`WorkspaceIntentTests` | Store 复用/LRU/pin/activate、7 VM sessionId、intent 单槽；ViewState 状态机 | 中；`SessionWorkspace` 扇出未直接断言 |

---

### 2.4 门禁逐项结论（是否可能假绿/漏扫）

| 门禁 | CI 调用 | 本次结果 | 可能假绿/漏扫 | baseline |
| --- | --- | --- | --- | --- |
| check-docs | `--strict`（ci.yml:36） | PASS（ADR 20 路径，缺失 0；schema 1=1） | 只查 ADR 反引号路径；不查 README/其他 md 链接；"已删除"整行豁免 | schema 1 |
| check-cleanup-ratchet | 硬失败（:38） | OK 53/236/126/0/0 | try? baseline 242（当前 236，余量 6）；baseline scopes 指向已删路径；只扫 Sources；--write-baseline 可上调 | 53/242/126/0/0 |
| check-no-legacy | 硬失败（:40） | OK 7 enforced / 6 tracked | Router 规则只扫 app；find/grep 未 prune `Sources/.build`（379MB）；tracked 只打印 | 无 |
| check-layering | 硬失败（:42） | OK 17 条 | 只匹配行首 `import X`；无 canImport/@testable/import kind；无 core 层间反向依赖 | 0 违规 |
| check-duplicate-symbols | `--strict`（:44） | OK（batchAsync 1、RequestGate 1） | 只查 3 个符号；不查测试 helper/Stub 重复 | 0 |
| check-test-catalog | 仅 warning（:46） | PASS（0 disabled / 0 knownIssue） | 不识别 `.enabled(if:)`；strict 只查文件头+“到期”；skip 数不进基线 | 0 |
| check-preview-surface | `--strict`（:48） | PASS 14 块 / 5 文件 | 只数宏；不编译预览；DEBUG 嵌套靠 awk | ≥12 / strict 14 |
| check-select-star | `--strict`（:50） | OK Sources 6 / Tests 1 | 只匹配 SELECT 后紧跟的星号；多星号/列后星号漏计；Tests 白名单文件级 | 6 / 1 |

**CI 是否真正执行**：是——8 道门禁都在 `gates` job 中（`.github/workflows/ci.yml:32-51`），core/app 测试也执行（:67,87）。但 test-catalog 非 strict、app 测试非串行、没有测试数量/覆盖率校验；因此“门禁全过”不等于“测试基线被守住”。

**负向验证**：`./scripts/check-select-star.sh --strict --baseline 0` → `FAILED（--strict）`，exit 1，证明 ratchet 本身是活开关；问题在于 regex/白名单口径，而不是“永远绿”。

### 2.5 测试写法扫描（只断言不抛 / 快照 / mock / fixture / 并发）

- **零断言**：逐文件解析 1,673 个 `@Test` 函数体，未发现真正零断言用例。3 个表面命中均为误报：`IncrementalClustererTests.swift:239` 调 `expectEquivalent`、`LocalizationParityTests.swift:322` 调 `assertParity`、`ReviewAcceptanceTests.swift:100` 用 `Issue.record`。
- **宽泛 throws**：`(any Error).self` 仍有 **23 处**，集中在 `NavigationServiceTests.swift:68-216`（10 处）、`AssetRepoTests.swift:556-661`（6 处）、`SimilarityServiceTests.swift:371,741,993`（3 处）、`FilterEngineTests.swift:93,101`（2 处）；其余错误用例多断言具体错误/错误码。详见 P2-13。
- **快照/字符串**：集中在 `Tests/GatherCoreTests/Protocol/*ContractTests`（16 文件），用于锁 DTO 的 JSON 键/rawValue，是对外契约的有意快照，不是“实现抄一遍”；未发现把实现输出自身再断言一次的循环快照。
- **mock 过度**：7 个 `API*Tests` 用真实服务 + 内存 SQLite 断言 API 边界（如 `APICullingTests.swift:102-120` 装配 `LiveCullingAPI` + 真 Repo）；`APIFaceUITests`/`APISimilarityUITests` 是 VM 层 Stub 测试，`APIErrorPresentationTests` 是纯映射；VM 测试用 `Stub*` 但同时断言调用入参/状态，抽样未发现“stub 返回什么就断言什么”的 tautology。主要风险是 `Stub*` 与生产协议漂移不会被编译期发现（协议未变时）。
- **fixture 写死**：`/tmp/...`、`/v/...`、`/Users/me/...` 多数是 DB 行里的假路径，不做文件 IO；`#filePath` 定位的 Reconciliation fixture/本地化表是仓库内 hermetic 资源。例外是 `MetadataParallelBatchTests.swift:54` 的固定 `/tmp/gather-parallel-probe/`（仅入库路径，未落盘）与 `FaceRealPhotoPipelineTests` 的环境变量素材（永久 skip，见 P1-1）。
- **并发**：app 26 处固定 `Task.sleep`（P2-12）+ `waitUntilAsync` 2s 上限（P0-1）是并行 flake 的结构性来源；core 在默认并行下 2 次全绿，未观察到 flake。

## 3. P0 发现

### P0-1 app CI 用默认并行，本机必红；验收却用 `--no-parallel`

- **证据**
  - CI：`.github/workflows/ci.yml:87` → `swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`，无 `--no-parallel`。
  - 验收：`docs/final-report.md:38,80` 明确写 `--no-parallel`；`docs/refactor-progress.md:33,166` 的 581/66 也来自该命令。
  - 实测：默认并行全量 6/6 失败（`Test run with 581 tests in 66 suites failed ... with 1/2/5/9 issues`），串行 3/3 通过。
  - 等待基座：`AsyncWait.swift:28` 默认 `timeout: TimeInterval = 2`；多个调用点用 `_ = await waitUntilAsync {...}` 丢弃返回值（`SettingsSaveSemanticsTests.swift:96`、`DuplicatesControlCenterAPITests.swift:281,287,301,313,314,333,359`）。
  - 隔离验证：4 个用例用 `--filter` 一起并行跑 → `Test run with 4 tests in 4 suites passed after 0.413s`；说明不是用例间共享状态，而是**整包 581 条并行时的调度/主线程饥饿**把 2s 等待耗尽。
- **影响**：CI app job 红或间歇红；本地/台账“全绿”不能代表 CI。若 CI 实际通过，只是 runner 核数/调度差异，flake 仍在。对“1,673 tests 全绿”的验收结论有实质削弱。
- **修复**
  1. 立刻在 CI app job 加 `--no-parallel`（与验收、台账统一；最小改动）。
  2. 并行确定性修复（推荐，保留并行收益）：把 `_ = await waitUntilAsync` 改为 `#expect(await waitUntilAsync(timeout: 10) {...})`；对轮询类用例提高超时到 10s 或 `@Suite(.serialized)`；避免 5–20ms 轮询 + 2s 上限。
  3. 若想保留并行收益：CI 主 job 用 `--no-parallel`，另设 nightly/可选 job 跑默认并行并收集 flake 列表；在清理完 4 个等待点后再把主 job 切回并行。
- **状态**：**已确认（本机 6/6 并行失败、3/3 串行通过；CI 命令与验收不同）**；**疑似（远端 CI 具体红/绿未观测）**。

---

## 4. P1 发现

### P1-1 3 个真实照片用例永久 skip，基线把它们算作“通过”

- **证据**
  - `desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceRealPhotoPipelineTests.swift:40,62,74`：三条 `.enabled(if: fixtureImageData != nil)`，fixture 只从环境变量 `GATHER_FACE_FIXTURE` 读取（同文件 :29-36）。
  - 实测无 env 时：`➜ Test ... skipped` ×3，汇总仍是 `Test run with 3 tests in 1 suite passed`；core 全量 1,092 包含这 3 条。CI workflow 未设置 `GATHER_FACE_FIXTURE`（`grep -rn GATHER_FACE_FIXTURE .github` = 0），因此 CI 上必然 skip。
  - `scripts/check-test-catalog.sh:59-60` 只匹配 `@Test.*\.disabled` 与 `withKnownIssue`；实测输出 `.disabled 用例 0 / withKnownIssue 0`，`.enabled(if:)` 完全不可见。
  - 这不是新发现：`docs/test-audit.md:106`（D9）已写“`.enabled(if: GATHER_FACE_FIXTURE != nil)`，CI 永绿但零执行；§8.3-4 要求到期条件 → 移入 `scripts/manual` 或删”，处置列写“Cut 0 可立即”；`docs/test-audit.md:198` 仍记“3 处 / 默认跳过 3 条”；`docs/refactor-decisions.md:19`（D-002）要求“Cut 6 门禁按此口径统计”。即：审计已识别、台账已承认，但代码与门禁都没关。
- **影响**：真实照片链路的唯一端到端用例（含 `encodeFailures` 计数断言）在 CI 永远不跑；1,092 的“有效执行”是 1,089；到期注释（`// 到期条件：...`）没有任何门禁强制。审计 §8.3-4 的“到期即移除”没有执行证据。
- **修复**
  1. 把受控小图（脱敏/合成真实人脸）纳入仓库 fixture，默认启用；环境变量仅作为额外素材入口。
  2. 若坚持手动，移到 `scripts/manual/` 并从测试目标排除，避免计入基线；同时在台账写“手动项”而非“tests passed”。
  3. 扩展 `check-test-catalog`：统计 `.enabled(if:)`、`#require` 早退、`skip` 计数，并要求“到期 + issue 链接”；CI 加 `--strict`。
- **状态**：**已确认**（运行输出 skipped；门禁不可见）。

### P1-2 没有测试数量/覆盖率 ratchet：删测试不会红

- **证据**
  - 全仓脚本/CI 无 1,092/581 校验：`grep -rn '1092\|581' scripts .github` 仅命中 docs；`check-test-catalog.sh` 只统计文件头、disabled、withKnownIssue（:46-69），不统计 `@Test` 数量。
  - CI 无 `--enable-code-coverage` / `llvm-cov`（grep .github scripts = 0）。
  - 测试数量只存在于 `docs/final-report.md:38,78-80,155,166` 和进度台账。
- **影响**：任何 Cut 后续误删/合并测试、或新代码只写“能编译”的测试，CI 仍绿；“1,092/581”是可被静默改写的文档事实，而非门禁。
- **修复**：新增 `scripts/check-test-count.sh`，解析 `swift test` 汇总行并对 core/app 设定精确值（更新需显式改 baseline 文件并进 diff）；或纳入 `check-test-catalog --strict`。若参数化用例导致计数波动，用“函数声明数 + 参数 case 数”双口径。
- **状态**：**已确认**（门禁缺失），风险等级取决于后续是否还会删测试。

### P1-3 `check-test-catalog` 在 CI 是 warning 模式，且 strict 规则不足

- **证据**
  - `.github/workflows/ci.yml:46`：`./scripts/check-test-catalog.sh`（无 `--strict`）。
  - `scripts/check-test-catalog.sh:116-121`：strict 只在 `header_missing > 0` 或 `untriaged_n > 0` 时失败；`disabled_n` 本身不导致失败。
  - “到期”判定是 `.disabled` 命中行前后 2 行的字符串匹配（:81-87），注释措辞可轻易满足；`.enabled(if:)` 不进入任何统计。正则同样漏掉 **整组禁用**：`@Suite(.disabled(...))`、`@Suite(.enabled(if: ...))` 既不匹配 `@Test.*` 也不以 `.disabled` 开头（当前仓库 0 处，但门禁拦不住未来）。
  - `docs/test-audit.md:253` 写“`check-test-catalog.sh` 强制『skip 必须带到期条件 + owner』；D9 已按此处置”——与脚本实际能力不符（脚本没有 skip/owner 规则，D9 的 3 条仍在）。
- **影响**：新增/续期的禁用用例不会阻断 CI；测试目录的“防腐”承诺（D-002/§8.6）没有真正执行，审计结论与实现脱节。
- **修复**：CI 改 `--strict`；把 `.enabled(if:)`、环境变量分支、`#require` 早退纳入统计；要求每条带“到期 + 负责人/issue”；对 skip 数设 ratchet 0（除白名单）。
- **状态**：**已确认**。

### P1-4 “8 门禁 strict”是人工验收口径，CI 并不执行同样 strict

- **证据**：`docs/final-report.md:23,90-103,156` 写“8 门禁 strict + preview strict 全过”（§5.3 标题 `八道门禁（strict 可用的均带 --strict）`，其中 :97 记 `check-test-catalog.sh --strict` OK）；但 CI 中 `check-test-catalog.sh` 不带 strict（`.github/workflows/ci.yml:46`）、`check-cleanup-ratchet.sh` 没有 strict 模式（:38）、`check-layering.sh` 本身硬失败但无 strict 概念；真正在 CI 带 `--strict` 的是 docs/duplicate/preview/select-star。
- **影响**：文档的“8 门禁 strict 全过”描述的是**人工验收**（final-report §5.3 的命令可以复现），不是 CI 的实际执行口径；容易把“CI 会拦”与“人工跑过”混为一谈。当前 test-catalog strict 恰好 0 违规，所以差异尚未显形；一旦新增无到期说明的禁用用例，人工验收会红、CI 仍绿。
- **修复**：统一措辞（“人工验收：4 道 strict + 3 道硬失败 + 1 道 strict”），或直接让 CI 的 test-catalog 带 strict，使两者同口径。
- **状态**：**已确认**（文档与脚本事实）。

---

## 5. P2 发现

### P2-1 `check-layering.sh` 只匹配行首 `import X`，存在合法语法绕过

- **证据**：`scripts/check-layering.sh:55` 的正则 `^[[:space:]]*import[[:space:]]+$mod([[:space:]]|$)`。不覆盖 `@testable import`、`@_exported import`、`import struct GatherPersistence.X`、`#if canImport(GatherPersistence)`；也不检查 GatherPersistence→GatherAnalysis/Domain 的反向依赖、测试 target 的越层 import。
- **影响**：当前 0 违规，但换一种合法 import 写法即可“假绿”；作为纵深防御弱于 `--explicit-target-dependency-import-check`（CI 已开，见 ci.yml:67/87）。
- **修复**：正则改为 `^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?import[[:space:]]+(struct|class|enum|protocol|func|typealias|actor|let|var)?[[:space:]]*(GatherPersistence|...)`；补 `canImport` 与 core 层间矩阵。
- **状态**：**已确认（规则缺口）**；当前无实际违规。

### P2-2 `check-select-star.sh` 漏计“非行首星号”与多星号查询

- **证据**：`scripts/check-select-star.sh:174` 只匹配 `SELECT [DISTINCT] [qual.]\*`；`SELECT a.id, b.* FROM ...` 或 `SELECT a.*, b.*` 中的 `b.*` 不计数（脚本注释声称“同一行多条按多条计”）。Tests 白名单是**文件级**（:33），同文件新增第二处 SELECT * 只要总数仍为 1 就通过。
- **影响**：Sources 基线 6 可能被“列 + 星号”写法绕过；新增查询未必红。
- **修复**：在字符串内统计所有 `(?:[A-Za-z_][A-Za-z0-9_]*\.)?\*`，但排除 `COUNT(*)`；Tests 白名单改为“文件:行 + 允许数量”。
- **状态**：**已确认（正则缺口）**；当前 6/1 与实测一致。

### P2-3 `check-docs.sh` 只校验 ADR 反引号路径，不校验 Markdown 链接

- **证据**：`scripts/check-docs.sh:47-48` 只取 `docs/ADR.md` 的反引号 token；:88 只统计 `docs/reviews` 篇数。6b 声称“md 链接 133 条/图片 47 条 0 缺失”（progress:165），但没有任何脚本复查；README/DEVELOPMENT/final-report/本报告新增链接不会让门禁失败。
- **影响**：文档漂移只能靠一次性人工命令；归档/改路径后断链可静默存在。
- **修复**：加轻量链接检查（相对路径 + 图片），或把 6b 的检查脚本固化进 CI。
- **状态**：**已确认（范围缺口）**。

### P2-4 cleanup ratchet：baseline 元数据过期，try? 留有 +6 余量

- **证据**：`docs/cleanup-baseline.json:7-16` 的 `try_optional: 242`，实测 236（`check-cleanup-ratchet.sh` 输出 improved 6）；同文件 `scopes` 仍写 `Sources/GatherCore/Services`、`gather-app 功能页目录`（已不存在的路径）。脚本只覆盖 Sources（:23-29），Tests 不在 unchecked/try? 口径。
- **影响**：新增 6 个 `try?` 也不会红；baseline 文件误导读者以为仍在 GatherCore 伞下。文档 final-report:170 已把“未收紧”列为残余，属已承认风险。
- **修复**：`--write-baseline` 后收紧到 236；重写 scopes 为当前四层路径；在 CI 中检测 baseline 的 scope 路径是否存在。
- **状态**：**已确认**。

### P2-5 `check-duplicate-symbols.sh` 名不副实：只查 3 个符号

- **证据**：`scripts/check-duplicate-symbols.sh:55,58,62` 只查 `func batchAsync`、`LockedBox/ResponseBox`、`RequestGate`。当前 `--strict` PASS，但无法发现多个 `Stub*`/测试 helper、重复的等待器、重复的 DB 夹具等。
- **影响**：“duplicate symbols PASS”容易被误解为“无重复实现”；实际只是 3 条人工白名单。
- **修复**：扩展为“Tests 下同名 struct/class/actor 重复”“同名顶层 func”“同文件重复 #expect helper”，或改名“check-known-duplicates”。
- **状态**：**已确认**。

### P2-6 `check-preview-surface.sh` 只数宏，不证明预览可编译/可渲染

- **证据**：`scripts/check-preview-surface.sh:47-57` 用 grep 统计行首 `#Preview`；strict 的 `#if DEBUG` 判定是手写 awk 深度（:100-107），不处理 `#elseif`，也不编译。Release 构建（CI build.sh）因 `#if DEBUG` 不编译预览体。
- **影响**：14 个预览可能在 DEBUG 下编译失败而门禁仍绿；预览 fixture 的 API 替身与生产 API 漂移也不会被发现。
- **修复**：CI 增加 `swift build`（Debug，GatherUI）已经会编译 PreviewSupport——需确认 PreviewSupport 在 Debug app target 中参与编译；若未参与，增加一个专用 Debug 编译任务。
- **状态**：**疑似（门禁本身不编译；但 CI app test 的 Debug 构建会编译 GatherUI/PreviewSupport，理论上 `#Preview` 展开失败会阻断 build，未单独注入验证）**。

### P2-7 Delivery/AppRuntime 失败路径与状态机矩阵覆盖不足

- **证据**
  - `DeliveryCoordinatorTests.swift:457-504,671-700` 只断言 replay 的 `failedCount == 0`；没有一条构造“replay 文件阶段失败 → failedCount > 0 + intent 保留 + 错误文本”的用例。
  - `AppRuntimeTests.swift:212` 只断言 `deliveryReplayFailure == nil`；启动回放失败分支（写 error 日志 + 暴露 failure）无测试。
  - 状态机唯一真相源 `DeliveryState.swift:47-84`（7×7）只有零星 6 个断言（`DeliveryRepoTests.swift:277-278,736-739`），无全矩阵表驱动；`DeliveryItemStatus` 同理。
  - `DeliveryCoordinator.cleanup` 的“多条交付中一条 restore 失败、其余成功”无批量部分失败用例；事务回滚只在 Repo 层（`DeliveryRepoTests.swift:501,539`）。
- **影响**：失败/重放失败是交付模型最危险的路径（可能重复写文件或丢 intent），目前只有正向断言；状态机回归只能靠零散用例。
- **修复**：加表驱动 7×7/4×4 矩阵；加 replay 失败、批量部分失败、AppRuntime 失败注入三条用例。
- **状态**：**已确认（缺失）**。

### P2-8 Workspace 扇出与关闭终态未直接断言

- **证据**：`SessionWorkspace.swift:78-89` 的 `setVisible` 对 7 个 VM 扇出、:125-140 的 `close` 调 7 个 shutdown 并清 intent；`FactoryTests.swift:220-246` 只断言 workspace 的 `isVisible/lifecycle`，未断言 7 个 VM 实际收到 setVisible/shutdown；`WorkspaceIntentTests.swift` 只测枚举与局部字典，不测 `SessionWorkspace.enqueue/take`（后者的直接测试在 `FactoryTests.swift:303-330`，只覆盖 intent，不覆盖关闭清空）。
- **影响**：“唯一扇出点”一旦漏掉某个 VM（例如新增第 8 个 VM）不会被测试发现；close 后 VM 是否真的停止长任务只能靠各 VM 自身测试。
- **修复**：用 7 个 spy VM 断言 setVisible(true/false) 与 shutdown 各一次；close 后再 setVisible/enqueue 断言 no-op。
- **状态**：**已确认（缺失）**。

### P2-9 bundle 打包只有“目录存在”检查，没有内容契约

- **证据**：`desktop/native/build.sh:41-49,71-90` 只检查 Info.plist 存在、`.lproj` 目录存在、FaceModels/.mlpackage 存在；未校验 `Info.plist` 的 `CFBundleLocalizations`（当前值 en/zh-Hans，`Info.plist:9-13`）、`*.strings` 键集合、资源 bundle 的 `Bundle.module` 解析。测试侧无“打包后 bundle 内容”用例。
- **影响**：主 bundle 丢 `.lproj` 或 CFBundleLocalizations 漂移时，系统菜单语言会回退；CI 的 build.sh 不会发现（只查目录存在）。
- **修复**：build.sh 增加 `plutil` 校验 CFBundleLocalizations 与 en/zh-Hans 一致、检查两个 .lproj 均有 Localizable.strings；或加一个读取 assembled bundle 的 smoke 测试。
- **状态**：**已确认（检查缺口）**；CI 有 build.sh，故非零覆盖。

### P2-10 仓库内 379MB 构建产物位于 `gather-app/Sources/.build`

- **证据**：`desktop/native/gather-app/Sources/.build` 379MB（含 2 个 `resource_bundle_accessor.swift`）；`check-no-legacy.sh:60` 的 `find "$NATIVE"` 未 prune `.build`，`grep -rE --include='*.swift'` 会扫到它（:19,35）。
- **影响**：门禁扫描变慢；若该目录残留旧源码副本，可能产生假阳性/假阴性；也说明有人从 `Sources` 目录跑过构建。属仓库卫生问题，不直接影响测试结论。
- **修复**：删除该目录；在 check-no-legacy 的 find/grep 统一加 `-path '*/.build' -prune` / `--exclude-dir=.build`。
- **状态**：**已确认**。

### P2-11 `LiveCullingAPI.history` 在 Live API 层没有测试（110 方法中的 1 个）

- **证据**：`gather-core/Sources/GatherProtocol/API/CullingAPI.swift:21` 定义 `history(_:)`，`gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:67` 实现；但 `APICullingTests.swift` 没有任何 `api.history(...)` 调用，`grep -rn '\.history(' Tests` = 0。VM 路径有测试（`CullingSyncFlowTests.swift:139,158`），但走的是 `StubCullingAPI`，只验证 VM 传参，不验证 Live 实现的查询/限制/投影。
- **影响**：16 协议 110 方法没有“方法面完整性”门禁；删/改 `LiveCullingAPI.history` 可保持全绿。属单点缺口，风险低。
- **修复**：在 `APICullingTests` 补一条真实 Repo 的 history 用例（session/limit/行数/字段投影 + 空结果）；并考虑为 110 方法建编译期引用清单。
- **状态**：**已确认（覆盖缺失）**。

### P2-12 app 测试仍有 26 处固定 `Task.sleep`（含 500ms/400ms）

- **证据**：`grep -rn 'Task.sleep' gather-app/Tests | wc -l` = 26；例如 `GalleryViewModelTests.swift:406,412,431,451`（500/80/500/400ms）、`APIDuplicateQualityTests.swift:267`（500ms）、`APIExportMetadataTests.swift:251`（500ms）。这些等待没有谓词条件，短了 flake、长了拖慢；并行满载时余量不确定。
- **影响**：CI 慢 runner/并行时增加 flake 面；也掩盖真实延迟回归（400ms 的固定睡眠会让 300ms 的实现也通过）。
- **修复**：改为 `waitUntilAsync` 谓词等待 + 明确上限；对必须观察“负向窗口”的用例保留 `awaitNegativeWindow` 并注释依据。
- **状态**：**已确认（写法存在）**；本次未观测到这些点直接失败，属风险项。

### P2-13 23 处错误用例只断言“抛了任意 Error”，不校验错误码

- **证据**：`grep -rE 'throws: *\(any Error\)\.self' Tests` = 23。最典型是 `NavigationServiceTests.swift:191-209`：三条注释分别写 `NAV_MERGE_MIN_TWO` / `NAV_MERGE_TYPE_MISMATCH` / `NAV_GROUP_NOT_FOUND`，但三条断言都是 `#expect(throws: (any Error).self)`；`splitOutOfGroupThrows`（:212-218）同样不校验 `NAV_SPLIT_OUT_OF_GROUP`。`AssetRepoTests.swift:556,631,647-661` 的 relink 根目录错误也未校验 `ASSET_RELINK_*` 码。
- **影响**：实现抛错类型/错误码回归（例如把 `NAV_GROUP_NOT_FOUND` 错写成 `NAV_MERGE_MIN_TWO`，或 DB 错误直接外泄）不会红；错误码是 typed API 契约的一部分，这类用例只保“会抛”，不保“抛对”。
- **修复**：改为 `#expect(throws: NavigationError.mergeMinTwo)` 等具体 case（`NavigationError`，见 `NavigationService.swift:42-59`）；AssetRepo 的 relink 错误是 `DBError.message("ASSET_RELINK_*")`，需 catch 后断言 message/code。
- **状态**：**已确认**（数量与文件行号来自 grep；具体错误码以源码/注释为准）。

---

## 6. 覆盖率缺口（按任务要求分类）

| 类别 | 现状 | 缺口 | 优先级 |
| --- | --- | --- | --- |
| 错误路径 | API 域测试有 GatherError/INVALID_PARAM；Repo 有 illegalTransition/FK | Live API 每个方法的错误分支未系统化；Delivery replay 失败 `failedCount>0` 无断言；AppRuntime replay failure 无测试 | P1/P2 |
| 取消 | Job/Similarity/Face/Export/Culling 均有取消用例（grep 实测）；FaceClusterCancellation 2 例 | Delivery cleanup/replay 无取消语义测试（若实现不支持，应在文档说明）；Workspace close 的 VM 取消只间接覆盖 | P2 |
| 回滚 | `DeliveryRepoTests.swift:501,539` 两个事务回滚；`DatabaseFacadeTests` 事务/SAVEPOINT | cleanup 批量部分失败、文件已恢复但 DB 删除失败的中途态无测试 | P2 |
| 迁移/重置 | `DatabaseFacadeTests.swift:125,180` 覆盖 user_version=99 + -wal/-shm、非 SQLite 重置；`MigrationTests` fresh only | 无“reset 后启动回放/旧 intent 清理”联动测试 | P2 |
| 语言切换 | `LanguageStoreTests` 7 例（切换/广播/订阅/seed）、`StartupLanguageTests`、`ShellLanguageWiringTests`、parity | 无 GUI 端到端（无 GUI 自动化，台账已声明）；无 bundle 缺表时的回退测试 | P2 |
| bundle | build.sh 检查目录；无测试 | CFBundleLocalizations/strings 内容、Bundle.module 解析、FaceModels 实际加载（除 bundledModelRunsRealCoreMLInference） | P2 |
| 测试基础设施 | — | 4 个并行 flake；3 个永久 skip；waitUntilAsync 丢弃返回值；无数量/覆盖率 ratchet | P0/P1 |

---

## 7. 建议的补测清单（按优先级）

### P0（本周）

1. **CI app job 加 `--no-parallel`**（`.github/workflows/ci.yml:87`），先恢复“CI = 验收命令”；同时在 docs 固定“CI 命令”与“本地验收命令”一致。
2. **修 4 个 flake**：`DuplicatesControlCenterAPITests.swift:384`、`CullingViewModelAPITests.swift:573`、`SettingsSaveSemanticsTests.swift:96-100`、`FaceReclusterConfirmTests.swift:46-59`：等待结果必须 `#expect`，超时 10s；轮询类套件可 `.serialized`；禁止 `_ = await waitUntilAsync` 后直接断言派生状态。

### P1（本 Cut 收口前）

3. **让 3 个真实照片用例默认运行**：仓库内受控 JPEG fixture（可合成人脸/脱敏），或移出测试目标并在台账记“手动”；禁止 `.enabled(if:)` 静默 skip。
4. **扩展 `check-test-catalog`**：统计 `.enabled(if:)`/环境变量/`#require` 早退；skip 数设 0 白名单；CI 加 `--strict`。
5. **测试数量 ratchet**：新增 `check-test-count.sh`（core 1,092 / app 581 精确或下限），CI 执行；任何数量变化必须显式改 baseline。
6. **Delivery 失败路径**：replay 文件阶段失败（failedCount>0、intent 保留、错误可见）、批量 cleanup 一条失败其余成功、AppRuntime replay 失败写 `deliveryReplayFailure`。
7. **Delivery 状态机全矩阵**：7×7 `DeliveryStatus`、4×4 `DeliveryItemStatus` 表驱动，锁死 `canTransition`。

### P2（后续）

8. **Workspace 扇出**：7 个 spy VM 断言 setVisible/shutdown；close 后 setVisible/enqueue/take 全 no-op。
9. **错误码断言**：把 23 处 `throws: (any Error).self` 改为具体 `NavigationError`/`DBError`/`GatherError.code`；先做 `NavigationServiceTests:191-218` 三条 merge/split 错误码。
10. **API 面完整性**：先补 `LiveCullingAPI.history` 的真实 Repo 用例；为 16 协议 110 方法建“方法引用清单”（编译期 conformance/枚举），防止删方法后测试仍绿；按域补错误分支。
11. **门禁加固**：layering 正则 + canImport/反向依赖；select-star 统计所有 `x.*`；docs 链接检查；duplicate 扩到测试 helper；preview 增加 Debug 编译验证；build.sh 校验 CFBundleLocalizations 与 strings。
12. **bundle smoke**：assemble 后读取 `Gather.app/Contents/Resources`，断言 en/zh-Hans.lproj、Localizable.strings、FaceModels/.mlpackage 与 Info.plist 一致。
13. **清理** `gather-app/Sources/.build`（379MB）并在所有门禁 find/grep 中 prune `.build`。

---

## 8. 已确认 vs 疑似

| 结论 | 状态 | 依据 |
| --- | --- | --- |
| core 1,092/157 全绿 | 已确认 | 实测 2 次 exit 0 |
| app 581/66 串行全绿 | 已确认 | 实测 3 次 exit 0 |
| app 默认并行必失败（本机） | 已确认 | 6/6 全量并行失败，4 个不同用例 |
| CI app job 与验收命令不一致 | 已确认 | ci.yml:87 vs final-report:80 |
| 远端 CI 实际红/绿 | 疑似 | 未观测 GitHub Actions |
| 3 个真实照片用例永久 skip | 已确认 | 运行输出 skipped ×3 |
| test-catalog 看不到 `.enabled(if:)` | 已确认 | 脚本 :59-60 + 输出 0 disabled |
| 无测试数量/覆盖率 ratchet | 已确认 | 脚本/CI grep 无 1092/581/coverage |
| CI 的 strict import check 本身可过 | 已确认 | core/app 带 `--explicit-target-dependency-import-check error` 实测 exit 0 |
| `LiveCullingAPI.history` 无 Live 层用例 | 已确认（缺失） | `grep '\.history(' Tests` = 0 |
| 26 处固定 Task.sleep | 已确认（写法） | `grep 'Task.sleep' gather-app/Tests` = 26 |
| 23 处错误用例只断言 any Error | 已确认 | grep `throws: (any Error).self` = 23；NavigationServiceTests:191-218 未校验码 |
| 删除测试与行为变化匹配 | 已确认（抽样） | 96 条删除均有对应源码删除/替代测试 |
| Workspace 扇出无直接断言 | 已确认（缺失） | FactoryTests 只断言 workspace 状态 |
| Delivery replay 失败路径无测试 | 已确认（缺失） | 仅 `failedCount == 0` 断言 |
| check-select-star 多星号漏计 | 已确认（规则缺口） | 正则 :174 |
| check-docs 不查 Markdown 链接 | 已确认（范围缺口） | 仅 ADR token |
| preview 宏是否参与 Debug 编译 | 疑似 | 未单独验证 #Preview 展开失败是否阻断 build |
| “8 门禁 strict”口径 | 已确认（人工 vs CI 不同） | final-report §5.3 人工 strict；CI 的 test-catalog 非 strict |

---

## 9. 结论

- **测试有效性**：核心域（Delivery/SchemaV1/ClusterGraph/FaceMatcher）的新测试不是“只断言不抛”的空壳，含 golden、逐位一致、事务回滚、随机对账，质量高于重构前；Application/Workspace 层稍弱，但 Factory/Store/ViewState 有实质断言。明确的弱点有两类：**23 处错误用例只断言“任意 Error”**（P2-13，NavigationService/AssetRepo 最典型），以及 **Workspace 扇出没有 spy 断言**（P2-8）。
- **测试完整性**：最大问题是**基线可被静默改写**（无数量 ratchet）、**skip 不可见**（3 条真实照片用例 + test-catalog 盲区；审计 D9 在 `docs/test-audit.md:106` 已标“CI 永绿但零执行”，至今未关闭），以及**CI/验收命令不一致**（P0）。在这三点修复前，不能把“1,673 tests 全绿”当作可复验的 CI 事实。
- **门禁**：8 道门禁当前都能跑、当前都绿，但“绿”的质量参差：docs/duplicate 规则远窄于名字，select-star/layering 有语法绕过，test-catalog 仅告警，ratchet baseline 过期。它们能防“明显的回潮”，不足以防“聪明的回潮”。
- **建议 owner 的下一步**：先做 P0（CI `--no-parallel` + 4 个等待点），再做 P1-1/P1-2/P1-3（skip 可见 + 数量 ratchet + catalog strict）；P2 可在下个 Cut 批量收口。任何一项完成前，final-report 应把“CI 实测”与“人工串行验收”分开写，避免“8 门禁 strict/1,673 tests 全绿”被读成 CI 已守住。

---

## 附：本次未改动声明

本报告是唯一写入文件；未修改任何源码、测试、`Package.swift`、`scripts/`、`docs/` 其他文件。测试运行产生的 `.build` 产物未纳入版本控制（且未清理既有产物）。
