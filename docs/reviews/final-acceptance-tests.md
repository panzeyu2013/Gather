# Gather WP1–WP7b 测试覆盖与行为验收（final acceptance tests）

> 范围：HEAD `df73880`（工作区干净；本轮只读，未改源码/测试/脚本/CI）。
> 对象：WP1–WP7b 新增/改动的测试是否真正覆盖新行为，以及回归缺口。
> 证据口径：`file:line` 为当前 HEAD 行号；“已确认”= 本轮实测/读码可复现；“疑似”= 需要额外环境或未执行。
> 报告文件是唯一写入物（`docs/reviews/final-acceptance-tests.md`）。

## 0. 结论先行

1. **测试总量与稳定性达标**：core **1,100 tests / 165 suites** exit 0；app **617 tests / 68 suites** exit 0；core 连跑 3 次、app 连跑 2 次均绿；新增的 delivery/trace 套件连跑 5 次均绿。core 的 1,100 个用例里有 **3 个条件 skip**，有效执行 **1,097**。
2. **WP1/WP2/WP4d/WP6/WP7b 有实质新测试**：Protocol 删除的是零引用 DTO；Delivery 的 state machine/file phase/DB phase/adapter 共 24 例直接覆盖新边界；SchemaMigration 11 例覆盖 V1→V2、回滚、fail-closed、备份；PageVisibility 新增 6 例覆盖默认不可见/幂等/关闭终态；trace 5 例覆盖 Job 与 Delivery 的主干。
3. **最大缺口不是“没跑”，而是“新边界没有断言”**：
   - **WP3b（Application SQL/Repo Ports）新增约 3,000 行持久化代码，0 条功能测试断言**；测试侧只增加了两套 **348/346 行**的旧签名装配 shim，且 **0 个 fake repo**（计划要求核心测试可改用 fake repo ≥50%）。
   - **WP4d 的菜单命令测试被改成 L10n 字面量自证**：`zh("新建工作区") == "新建工作区"`，不再测 `GatherAppMenuCopy` / `GatherAppCommands` 的实际映射、通知名与快捷键。
   - **WP7b 测试头部声明的 cancelled/interrupted/lease-lost/finalize 路径没有对应用例**；失败/取消/终态分支的 trace 只覆盖了 succeeded/failed 与 cleanup/replay/confirm。
   - **WP6 迁移的提交前两道保险（`foreign_key_check`、迁移后 shape）没有失败用例**；非 SQLite 文件的默认 fail-closed 也没有用例（只有显式 reset 的成功路径）。
4. **代码量与测试数总体匹配，但两处明显失衡**：WP3b 是“大改 + 仅 shim”；WP5a/WP5b/WP4c 是纯移动（测试 0 行修改，靠既有端到端用例兜底，可接受但缺角色级回归网）。WP2a/3a 是纯移动，符合预期。
5. **没有发现空测试或“只断言不抛”的新增用例**：新增 Delivery/Schema 用例的断言均落到行为结果（删除/回滚/intent phase/文件内容/日志行）；发现的是“覆盖声明大于实际”“测试目标不可达导致测试弱化”“shim 复制”三类问题。

## 1. 方法与被测基线

### 1.1 方法

1. 逐 commit 看测试 diff：`git log --reverse --oneline 30f51f0..HEAD`、`git diff --stat <commit>^ <commit> -- '*/Tests/*'`。
2. 新测试文件全文阅读 + 与生产实现逐分支对照（Delivery 5 文件、Trace 1 文件、SchemaMigration 1 文件、PageVisibility 1 文件、Support 2 文件）。
3. 计数：`grep -rc '@Test'`、`swift test` 实际执行、`scripts/check-test-catalog.sh --strict`。
4. 稳定性：全量 core 3 次、app 2 次；`TraceLoggingTests|DeliveryFilePhaseTests` 5 次。
5. 静态检查：新测试文件是否直接引用新类型、是否存在 fake repo、测试 support 是否重复、skip 站点与元数据。

### 1.2 实测命令与结果

```bash
# core（计划 §5 原文 flags）
swift test --package-path desktop/native/gather-core --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error
# → 1100 tests / 165 suites, exit 0, 3 skipped; 连跑 3 次均绿

# app（计划 §5 原文 flags + --no-parallel）
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error
# → 617 tests / 68 suites, exit 0; 连跑 2 次均绿

# 新增套件定向
swift test ... --filter 'SchemaMigrationTests|DeliveryStateMachineTests|DeliveryFilePhaseTests|DeliveryDBPhaseTests|DeliveryModuleAdapterTests|TraceLoggingTests'
# → 40 tests / 6 suites, exit 0
swift test --package-path desktop/native/gather-app ... --filter 'WorkspaceVisibilityTests'
# → 6 tests / 1 suite, exit 0

# 稳定性
for i in 1..5: --filter 'TraceLoggingTests|DeliveryFilePhaseTests'
# → 每次 13 tests / 2 suites, exit 0
```

说明：core 的 3 个 skip 是 `FaceRealPhotoPipelineTests` 的真实照片夹具门（`desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceRealPhotoPipelineTests.swift:42,66,80`），需要 `GATHER_FACE_FIXTURE`；CI 不设置，故必然 skip。`check-test-catalog --strict` 报 **3 skip 站点，元数据 0 缺失**（owner/到期/原因齐全），但 `swift test` 的 “1100 tests” 汇总包含 skip，**有效执行是 1,097**，台账/状态文档写 1,100 时应注明。

### 1.3 测试基础设施现状

- `GatherTestSupport` 作为 core library product，app 测试通过 `.product(name: "GatherTestSupport", ...)` 复用 `makeTestDB/AsyncGate/LockedBox`；app 侧只留 `TestSupportReexports.swift` 的 typealias 与 `makeGatherTestDB` 转发（`desktop/native/gather-app/Tests/GatherAppTests/Support/TestSupportReexports.swift:14-20`）。`makeGatherTestDB` 仍有 **24 处**调用点、`makeTestDB` **91 处**；WP7 自己的注释写明“22 处改完后删除转发”，属于已知尾部债务（P2）。
- `check-test-catalog.sh --strict` 只检查文件头与 skip 元数据，**不检查测试数/覆盖率**；WP7 计划中的 “test count/coverage ratchet” 没有落地（P2）。
- app 全部用例串行（`--no-parallel`，CI 同口径）；core 默认并行，11 个 `@Suite(.serialized)`；trace 套件用 `.serialized` 并替换进程级 `GatherLogger.output`。

## 2. 新测试清单（按 WP）

| WP | 新增/改动测试 | 规模 | 直接覆盖 |
| --- | --- | ---: | --- |
| WP1 Protocol 瘦身 | 16 个 ContractTests 删除/改写 | +4 / −859 行；70 个 func 删除、2 个新增 | 68 个纯 DTO 用例删除 + 2 个混合用例改名重写（`cullingUpdatePatchRoundTrip`、`albumUpdateParamsRoundTrip`）+ 1 个原地改写（`AnalysisJobType`）；删除类型已从 Protocol 消失 |
| WP2 Delivery | `DeliveryStateMachineTests`、`DeliveryFilePhaseTests`、`DeliveryDBPhaseTests`、`DeliveryModuleRoutingTests`、`DeliveryTestSupport` | 5 文件 / 887 行 / 24 例 | 迁移表对齐（5）、文件阶段竞态/锁（8）、DB 单事务回滚（5）、adapter 路由/能力（6）、共享夹具 |
| WP2c | `FaceKeywordingServiceTests` +66 行、`DeliveryModuleRoutingTests` 改写 | +85 / −34 | 删除 14 个旧转发后，服务直连 adapter 的路由 |
| WP3b Repo Ports / SQL | 仅 `ServiceConstructionTestSupport`（core 348 / app 346 行） | +694 行，0 条断言 | 旧 `connection:` 测试构造 -> 生产 repo/query 的装配；无新行为断言 |
| WP5a/WP5b | 无测试 diff（0 行） | 新增 11 文件 / 5,085 行（Culling 2,508 / Face 2,577） | 既有 Culling 84 例、Face 55 例仍走门面；无角色级新用例 |
| WP4a/WP4c | WP4a 仅 1 行删除；WP4c 0 测试 diff | Composition 4 文件 / 503 行 | 既有 `AppCompositionTests` 5 例（单图、runtime、metadata、services 复用） |
| WP4d PageVisibility | `WorkspaceVisibilityTests` +70 行、`CullingViewModelAPITests`/ `SimilarityViewModelTests` +7 行、`ShellLanguageWiringTests` 改写 | +96 / −17 | 7×{true,true,false,false,true} 矩阵、默认不可见、close 终态；菜单测试弱化（见 P1-2） |
| WP7b trace | `Logging/TraceLoggingTests.swift` | 349 行 / 5 例 | Job start/succeeded/failed；Delivery confirm/cleanup/replay；失败 warn |
| WP6a/WP6b Schema | `SchemaMigrationTests` 11 例、DatabaseFacadeTests 改写、MigrationTests/SchemaV1Tests 断言更新 | +289 / −83（WP6b） | V1→V2、幂等、回滚、newer/corrupt、备份有效/保留 3 套、指纹、transaction mode |
| WP6c universal/Float16 | 无测试 diff | build.sh +275、ci.yml +108 | 仅编译/脚本门；x86_64 运行期未验证 |

### 2.1 新增 Delivery 用例逐条

- `DeliveryStateMachineTests`（5）：Delivery/Item 全 (from,to) 与 Persistence 表逐边一致；named transition 来源集合；cleanup/confirm/reopen/mirror 谓词；来源集合非空子集。**这是新状态机的结构门禁，质量好**。
- `DeliveryFilePhaseTests`（8）：指纹 await 窗口内新输入 -> `.changed`；锁外 revision 变化 -> `.skipped(.changed)`；外部指纹不符 -> `.skipped(.conflict)`；restore 期间新输入 -> `.invalidated` 且 intent 回 pending；备份缺失 -> `.fileFailed`；finalize 只删备份；同路径锁串行。
- `DeliveryDBPhaseTests`（5）：删除 delivery+intent 同事务；用 SQLite trigger 让 `finish` 失败，断言 delivery/intent 都回滚；提交后重复调用 `.alreadyGone`；item 门禁 skip 时 intent applied + error；finalize 同事务。
- `DeliveryModuleRoutingTests`（6）：5 个 adapter 方法固定 module；能力矩阵；越权抛 `unsupportedCapability` 且不转引擎；culling/face/similarity 路由；coordinator factory 的 module 匹配。

### 2.2 新增 Schema 用例逐条

`SchemaMigrationTests` 11 例：V1→V2 逐表行数保留/备份/43 表；重复 open 幂等；production catalog 的 v2/no-op/plan/validate；失败迁移回滚（user_version=1、注入列不存在、备份保留、可重试）；v3 fail-closed 字节不变 + 显式 reset；V0 有表默认 corrupt + reset；370 列 shape 不符默认 corrupt + issue 可读 + reset；备份 header/quick_check/user_version/行数；备份保留 3 套；指纹 43/373/69/62 + 7c7e…；transaction immediate/exclusive/嵌套 SAVEPOINT。

## 3. 覆盖缺口与回归风险

### P0（建议阻断验收 / 必须补）

#### P0-1 迁移提交前的两道保险没有失败用例

- 证据：`desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaMigrator.swift:48-54` 在事务内执行 `PRAGMA foreign_key_check`，非空即 `.migration`；`:57-62` 用 `targetSnapshot.shape.issues` 做迁移后形态校验，不符即回滚。设计测试矩阵 T4 明确要求“迁移后形态不符 -> 抛 `.migration`，issue 可读（不静默通过）”（`docs/reviews/wp6-schema-migration-design.md:448-462`，T4 在 :451）。
- 现状：`SchemaMigrationTests.swift:226-266` 的失败注入是 `FailingMigrationV1ToV2.apply` 先 `ALTER TABLE` 再 `throw`；它证明的是“任意抛错 -> 事务回滚”，**没有**证明两道 guard 本身会拦住错误：
  - 没有“迁移成功但 shape 与 target 不符”的 catalog/迁移（例如只 bump 版本、expectation 故意不匹配）；
  - 没有“迁移后 FK 违规”的迁移（`foreign_keys=OFF` 下插入孤儿行，再让 guard 报错）。
- 影响：这两条是迁移 commit 前的最后保险；如果未来迁移实现或 shape 校验回归，现有测试仍会全绿，用户库可能以错误形态提交。这是本报告唯一的 P0。

### P1（应在 final acceptance 前补）

#### P1-1 WP3b：新 SQL/Repo 边界 0 条功能断言，且 0 个 fake repo

- 证据：WP3b 三刀合计 `5,401 insertions / 2,135 deletions`（含测试 support 694 行），新增 `PhotoFilterQuery`、`CullingReadQuery`、`CullingAssetPageQuery`、`DuplicateGroupQuery`、`IndexerRepo`、`NavigationRepo`、`QualityRepo`、`TemplateRepo`、`AnalysisRunRepo`、`SimilarityHashRepo` 等；但测试 diff 只有 `ServiceConstructionTestSupport.swift`（core 348 行 / app 346 行），没有一条新断言（`docs/refactor-progress.md:290-299` 也写明“测试 support 两侧补旧 connection: 便利 init”）。
- 证据：这些新类型在测试中只出现在 shim 的构造里：`desktop/native/gather-core/Tests/GatherCoreTests/Support/ServiceConstructionTestSupport.swift:126,277-278,314,337`（app 同构文件对应行）；`grep` 无任何 `SessionRepository`/`PhotoRepository`/fake repo 实现，计划“核心测试可改用 fake repo ≥50%”未达成（`docs/reviews/architecture-remediation-plan.md:85`）。
- 影响：既有 service 测试仍绿（1,100/165），但只证明“被走到的分支”；新 query/repo 的边界（空结果、分页钳制、动态 SQL、错误映射、跨会话）没有直接门禁。一次“移动时抄错一个 SQL 分支”可能恰好落在既有用例未覆盖的组合里。**这不是说移动已出错，而是验收无法证明未出错。**
- 备注：`FilterEngineTests` 等仍会间接走 `PhotoFilterQuery`（`desktop/native/gather-core/Tests/GatherCoreTests/Services/FilterEngineTests.swift:68`），所以不能把“0 直接测试”写成“0 覆盖”；结论是**新边界缺直接回归网**。

#### P1-2 WP4d：菜单命令测试退化为 L10n 字面量自证

- 证据：`desktop/native/gather-app/Tests/GatherAppTests/ShellLanguageWiringTests.swift:54-75` 现在的断言是 `L10n(language:...)` 对 5 个 key 的翻译，例如 `:61` `#expect(zh("新建工作区") == "新建工作区")`；它不再构造 `GatherAppCommands`，也不断言 `GatherAppMenuCopy` 的 5 个属性映射、通知名、快捷键。
- 原因（测试自己写明）：WP4d 把 `GatherAppCommands` 迁入 `GatherApp` 可执行 target，而 `GatherAppTests` 只依赖 `GatherUI/GatherHost`（`desktop/native/gather-app/Package.swift:121-125`），无法 import 可执行模块（`ShellLanguageWiringTests.swift:54-58`）。
- 生产实现仍在：`desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift:26-33` 的 `GatherAppMenuCopy`、`:42-51` 的 `GatherAppCommands`、`:60-104` 的通知/快捷键；其注释还写着“便于单测”，与实际可达性矛盾。
- 影响：这是明确的**覆盖丢失**，不是“测试变少”而已：菜单文案 key 与 UI 命令的接线断了测试；如果 `newWorkspace` 错接 `importFolder` 的 key、或 `⌘O` 错配通知，现有测试全绿。属于用户可见回归。
- 修复方向：把 `GatherAppMenuCopy` 移到 `GatherUI`（或加一个可 import 的 package target/测试 target），让测试断言 5 个属性 + `body` 的通知名/快捷键；不要在测试里复制 key 列表。

#### P1-3 WP7b：trace 的覆盖声明大于实际用例

- 证据：`desktop/native/gather-core/Tests/GatherCoreTests/Logging/TraceLoggingTests.swift:5-10` 头部声明覆盖 Job `start` 与 terminal `succeeded/failed/cancelled/interrupted/lease-lost`、Delivery `confirm/cleanup/finalize/replay` 的 file/db 边界；实际只有 5 个 `@Test`（`:178,212,246,283,326`）：
  - Job 只测 succeeded（178）与 failed（212）；
  - Delivery 只测 confirm 成功（326）、cleanup 成功（246）、cleanup 失败后 replay（283）；
  - 没有 cancelled、interrupted、lease-lost、cancel-grace、stop-timeout（生产分支在 `desktop/native/gather-core/Sources/GatherApplication/Services/JobService.swift:867-910,943-980`）；
  - 没有 finalize 的 file/db 边界（生产在 `desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow.swift:449-630`）；
  - 没有 confirm 失败（incomplete/reload 未 ack）的 warn（生产在 `DeliveryCoordinator.swift:255-286`）。
- 影响：Job 取消/停机恢复与 finalize 是 trace 最需要排障的路径，也是最容易在重构中掉日志的路径；现有测试无法证明“每个终态都有 trace”。注意：业务行为本身有旧测试（Face cancel、finalize），缺的是**trace 断言**，所以影响定位在可观测性回归而非数据正确性。

#### P1-4 非 SQLite 文件的默认 fail-closed 没有用例（T7 只测了显式 reset）

- 证据：`desktop/native/gather-core/Tests/GatherCoreTests/Database/DatabaseFacadeTests.swift:206-224` 的“非 SQLite 文件”用例仍传 `options: Database.Options(resetPolicy: .renameToIncompatible)`（`:217`），断言成功重置；`SchemaMigrationTests` 的默认 fail-closed 只覆盖 V0 有表（`:319-358`）、370 列（`:360-415`）、v3（`:268-317`），没有“非 SQLite 文件 + 默认 policy -> `.corrupt` 且文件字节不变”。
- 设计 T7 要求默认 `.corrupt(.notADatabase)`、devReset 才改名（`docs/reviews/wp6-schema-migration-design.md:454`）。
- 影响：默认路径的数据安全门（绝不把未知文件当旧库重置）缺一条关键回归；现有用例只证明显式 reset 可用。

#### P1-5 SchemaCatalog 的非法链矩阵没有用例（T14 只测了 plan(from: v3)）

- 证据：`desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaCatalog.swift:42-77` 的 `validate` 有 6 个拒绝点：缺 current 快照、跳号、from ≥ current、from 重复、缺 from 快照、缺 to 快照；`plan` 再拒绝缺步/重复步/起点高于 current。测试只有 `SchemaMigrationTests.swift:208-213` 的 `plan(from: v3)` 抛错；没有构造“跳号/重复 (from,to)/缺步/缺快照”的 catalog。
- 设计 T14 明确要求“plan 抛 .migration，消息点明缺哪一步”（`docs/reviews/wp6-schema-migration-design.md:461`）。
- 影响：迁移链注册错误（未来加 V3 时）会先被 `validate` 拦，但该逻辑没有门禁；属于 WP6 的 P1 缺口。

#### P1-6 备份失败（`.io`，不迁移）没有用例

- 证据：`desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaBackup.swift:41-47` 把 `VACUUM INTO`/校验失败收敛为 `.io`，设计 §4.3 明确“备份是迁移前置条件，失败不迁移”；`SchemaMigrationTests` 只测成功备份（`:417-443`）与保留策略（`:445-468`），没有注入备份失败。
- 影响：备份失败时不能迁移、不能留下半成品是迁移安全的核心；现有测试只证明正常路径。建议用只读目录/非法备份目标/抢占 `VACUUM INTO` 目标之一注入。

#### P1-7 成功迁移后没有断言 `foreign_key_check` 为空（T1 漏项）

- 证据：设计 T1 要求“迁移后 `foreign_key_check` 空”（`docs/reviews/wp6-schema-migration-design.md:448`）；`SchemaMigrationTests.swift:132-160` 只断言 `user_version=2`、43 表、逐表行数、备份存在与无 `.incompatible-*`，没有对迁移后的库执行 `foreign_key_check`。
- 影响：`SchemaMigrator` 在提交前会检查 FK（`:48-54`），但测试没有从“迁移完成后的用户库”侧再确认一次；若 guard 被绕过/禁用，成功路径仍会绿。与 P0-1 的 FK 失败路径互补，建议一起补。

### P2（可排期，不阻断）

#### P2-1 测试 support 复制，WP7“删复制”目标未完全达成

- 证据：`desktop/native/gather-core/Tests/GatherCoreTests/Support/ServiceConstructionTestSupport.swift`（348 行）与 `desktop/native/gather-app/Tests/GatherAppTests/ServiceConstructionTestSupport.swift`（346 行）除文件头外逐字相同（`diff` 仅前 2 行注释差异）；两者都标注 WP3b-1 的“旧 connection: 签名装配”。这不是 WP7 删除的 3 个夹具，但属于同一类“测试侧复制生产装配”。
- 影响：生产 init 参数/端口变化时，两套 shim 需要同步；一旦漂移，core 与 app 的“编译期契约”会给出不同结果。建议下沉到 `GatherTestSupport` 或删除（测试改用端口构造）。

#### P2-2 测试数/覆盖率 ratchet 未落地；skip 计数使汇总数偏高

- 证据：`scripts/check-test-catalog.sh:4-9` 只做文件头 + skip 元数据；CI 只跑测试（`.github/workflows/ci.yml:74-75,112`），没有 N tests 下限/覆盖率门；core 实际 1,100 包含 3 skip（有效 1,097）。
- 影响：删测试不会红；台账容易把 skip 计入“通过数”。建议 CI 记录并比较有效执行数，skip 单独列。

#### P2-3 WP5a/WP5b 纯移动 0 测试 diff，缺角色级回归网

- 证据：`efc6598`、`c475974` 的测试 diff 为空；新增 11 文件 / 5,085 行；既有 Culling 84 例、Face 55 例仍绿（core 1,100）。“纯移动”由台账的行多重集比对背书（`docs/refactor-progress.md:301-318`）。
- 影响：可接受（纯移动），但拆分出的 `+Queries/+Commands/+Delivery` 与 Face 的 `+Analyze/+Clusters/+Review/+Writeback` 没有独立 seam 测试；未来某一角色文件回归只能靠端到端用例，定位成本高。建议至少给每个新 role 文件加 1 个“直接调用内部方法”的契约用例（若访问级允许）。

#### P2-4 WP4c Composition 拆分 0 测试 diff

- 证据：`c644e6b` 无测试改动；`Composition/{Core,FeatureAPIs,Root,Runtime}.swift` 503 行；`AppCompositionTests` 仅 5 例（`desktop/native/gather-app/Tests/GatherAppTests/AppCompositionTests.swift:60-190`）。
- 影响：单图/生命周期仍被覆盖，但 FeatureAPIs 的 12 个 API 是否全部接到同一服务、是否有重复构造，没有逐项断言；拆分本身是纯移动，风险可控。

#### P2-5 Delivery 文件阶段错误分支与跨会话 cleanup 缺直接用例

- 证据：`DeliveryFilePhase.swift:77,99` 的 `.guardFailed`（指纹读取抛错）、`:121,134` 的 `.alreadyGone`、`:177-194` 的无备份 `removeFile` 失败路径均无新用例；`DeliveryTestSupport.swift:138` 提供 `setRemoveFailure` 但新套件未使用；`DeliveryDBPhase.swift:122` 的 `foreignItemsRetained` 只有旧端到端用例（`DeliveryCoordinatorTests.swift:557`）。cleanup 跨两个 linked session 没有用例（confirm 有，`DeliveryCoordinatorTests.swift:409-444`）。
- 影响：`.guardFailed` 的语义是“保留 prepared intent、下次 replay 重试”，这是失败恢复的关键；建议补 direct case。

#### P2-6 PageVisibility 的“副作用幂等”只对 3 个 VM 可观测

- 证据：`WorkspaceVisibilityTests.swift:283-323` 的 7×5 矩阵对 7 个 VM 断言**状态**；副作用只对 gallery/control/similarity 用请求计数（`:123-240`）。`PageVisibility.swift:11-18` 的契约要求“重复 true/false 不重复启动/停止副作用”，但 control/face/duplicates/export 只有状态断言，没有副作用断言；也没有“隐藏时取消在途请求”的用例（Gallery/Culling/Control 各自轮询）。
- 影响：状态对但轮询多发/漏停的回归不会被矩阵抓住；现有 3 页有计数覆盖，另外 4 页需补。

#### P2-7 Float16 x86_64 分支没有运行期验证

- 证据：`desktop/native/gather-core/Sources/GatherAnalysis/Face/EmbeddingModel.swift:517-531` 新增 `#if arch(arm64)` 快路径与 `:526-531` 的 x86_64 fallback；测试 `FaceEmbeddingFingerprintTests.swift:151-160` 的 float16 用例在 arm64 上走快路径，x86_64 fallback 不执行。状态文档也承认 x86_64/Rosetta 未验证（`docs/reviews/architecture-remediation-status.md:54`）。
- 影响：该 fallback 只保证编译；如 CI runner 为 arm64，则永远测不到。建议加 x86_64 build + Rosetta 运行一次（或 CI `macos-14` 的 Intel runner）。（**疑似**：本机无法确认 CI runner 架构。）

#### P2-8 trace 测试的全局 logger 与 fire-and-forget 停止有 flake/泄漏风险

- 证据：`TraceLoggingTests.swift:30-50` 替换进程级 `GatherLogger.output/minimumLevel`；`:189,224` 用 `defer { Task { await service.stop() } }` 发起非结构化 Task，测试结束前不等待 stop；虽然本轮 5 次重复均绿，但 core 默认并行，日志捕获/后台 Job 生命周期在慢机上可能互相影响。
- 影响：当前不红（已实测 5 次），但建议 `await service.stop()` 用 `async defer`/显式等待，或把 JobService 的 start/stop 生命周期收敛到套件级。

#### P2-9 测试卫生小项

- `DeliveryModuleRoutingTests.swift:1` 文件头仍写 `DeliveryModuleAdapterTests.swift`（与文件名/套件名不一致）；
- `:184-192` 的 `coordinatorFactoryProducesAdapterWithMatchingModule` 创建 `DeliveryCoordinator(connection: try DeliveryTestSupport.makeDB())` 后未 `close()`；
- `DeliveryFilePhaseTests.swift:206-225` 的锁串行用例在 async closure 中用 `Thread.sleep(forTimeInterval: 0.02)`，慢机/调度抖动下有 flake 风险（本轮 5 次绿）；
- `SchemaMigrationTests.swift:445-468` 的备份保留只断言数量 3，未断言同秒冲突的 `-2` 命名（日志实际生成了 `-2/-3/-4`，测试未钉住）。

#### P2-10 DeliveryStateMachine 的迁移表/部分谓词没有生产调用点

- 证据：`DeliveryStateMachine.swift:75-90` 的 `deliveryTable/allows/sources/orderedSources`、`:123-129` 的 `itemTable/allows`、`:139` 的 `isConfirmReady`、`:147` 的 `shouldReopenForInput` 只在测试中被调用；生产只用到 `isCleanupCandidate`（`DeliveryCleanupFlow.swift:56,426`）、`isMirrorableItemStatus`（`DeliveryMirrorWriter.swift:39`）、`isTerminalForNewInput`（`DeliveryStateWriter.swift:186,201`）。
- 影响：`DeliveryStateMachineTests` 的 5 例里有 3 例在守护一张**未被编排层使用**的表；文件头“编排层先判定、Persistence CAS 兜底”的描述（`:4-5,11-14`）与调用点不符。不是行为回归，但属于“测试数/代码量看起来匹配、实际守的是死表”的假信心。要么把表接入编排（`isConfirmReady`/`shouldReopenForInput`），要么删表/测试并保留已用的谓词。

## 4. 代码改动与测试数匹配

| WP | 生产改动（近似） | 测试改动 | 判断 |
| --- | ---: | ---: | --- |
| WP1 Protocol | −1,273 行 / −96 类型 | −859 行 / 68 纯删 + 2 改名 + 1 原地改写 | 匹配（删的是零引用 DTO；无残留行为） |
| WP2a Delivery target | 3,630 行纯移动 | 16 个 import +1 行 | 匹配（纯移动） |
| WP2b Delivery 拆分 | Coordinator 1,964→319；+state/file/DB/intent/adapter | +889 行 / 24 例 | 匹配，且质量最高的一组 |
| WP2c 删旧端口 | −14 转发 | +85 / −34 | 匹配（服务直连 adapter） |
| WP3a rename | 21 文件 / 15,211 行 | 100 行 import 改名 | 匹配（纯重命名） |
| WP3b Repo Ports/SQL | 约 +3,000 行持久化代码 | **0 条断言**，仅 694 行 shim | **不匹配（P1-1）** |
| WP4a shell | 882 行移动 | −1 行 import | 匹配 |
| WP4b async provider | −27 sync 核 / −18 端口 | 3 文件 +68 / −106 | 大体匹配；菜单/命令另见 WP4d |
| WP4c Composition | 421→107，4 文件 503 行 | 0 | 可接受的纯拆分，但缺角色级断言（P2-4） |
| WP4d PageVisibility/Commands | 7 VM 统一 + Commands 迁移 | +96 / −17，1 个新矩阵例 | PageVisibility 匹配；菜单覆盖丢失（P1-2） |
| WP5a/b split | 5,085 行 / 11 文件 | 0 | 纯移动可接受；缺角色级（P2-3） |
| WP6a/b Schema | +1,500 行（框架/备份/V2） | +289 / −83，11 例 | 主干匹配；安全失败路径缺（P0-1/P1-4/P1-5/P1-6/P1-7） |
| WP6c release | build.sh +275、ci +108 | 0 | 无法用单测覆盖，但本地/CI 未实跑签名链（P2-7 相关） |
| WP7 infra | product/依赖/manifest | 0 新用例 | 基础设施目标部分达成；复制 shim 仍在（P2-1） |
| WP7b trace | Job/Delivery 日志点 | 349 行 / 5 例 | 主干匹配；声明 > 实际（P1-3） |

补充：WP1 的 diff 里 `grep '^-.*func '` 计 **70** 个删除、`^+.*func` 计 **2** 个新增；台账写“删 68 例 + 改写 3 例”（`docs/refactor-progress.md:235-245`）。两者可对齐为“68 纯 DTO 删除 + 2 个混合用例改名重写（旧名删/新名加）+ 1 个原地改写（`AnalysisJobType`）”；不要用 70−68=2 反推“台账漏了 2 个”，diff 的新增行只能看到改名的那 2 个（P2 文档项）。

## 5. 推荐补测清单（按优先级）

### P0（先补，补完再宣布 WP6 验收）

1. **迁移后 shape 不符**：注入“只 bump user_version、snapshot expectation 错”的 `SchemaMigration`，断言 `.migration`、`user_version` 仍 1、无新列、备份存在、无 `.incompatible-*`。落点 `SchemaMigrationTests`。
2. **迁移后 FK 违规**：`foreign_keys=OFF` 下写入孤儿行/坏 FK，断言 `.migration`、事务回滚、原库 `foreign_key_check` 为空。落点同上。

### P1（final acceptance 前）

3. **非 SQLite 默认 fail-closed**：写 16 字节非 SQLite 文件，默认 `Database.open` -> `.corrupt`，文件字节/mtime 不变；再测 `.renameToIncompatible` -> 改名重建。落点 `DatabaseFacadeTests` 或 `SchemaMigrationTests`。
4. **SchemaCatalog 非法链矩阵**：跳号、重复 (from,to)、缺 from 快照、缺 current 快照、from ≥ current；断言 `validate/plan` 的 `.migration` 与可读消息。
5. **备份失败**：只读目录/非法 `VACUUM INTO` 目标 -> `.io`，`user_version` 不变、无迁移、无新备份；可加备份校验失败（伪造 header/版本）。
6. **菜单命令真实映射**：让 `GatherAppMenuCopy`/`GatherAppCommands` 可被测试 target import（移到 `GatherUI` 或加 package test target）；断言 5 个属性、4 个通知名 + Help URL、4 个快捷键（⌘N/⌘O/⇧⌘I/⌥⌘S）。
7. **trace 全终态**：Job cancelled、interrupted（stop-timeout/application-stopped）、lease-lost（conditional update miss）、cancel-grace；Delivery finalize file/db、confirm 失败 warn；断言同一 `trace=job:<id>`/`delivery:<id>/rev:<n>/<phase>` 与 `phase/reason`。
8. **WP3b 新 SQL 边界**：至少给 `PhotoFilterQuery`、`CullingReadQuery/CullingAssetPageQuery`、`DuplicateGroupQuery` 各 1-2 个直接用例（空结果/分页钳制/动态条件/错误映射）；用 fake `SessionRepository/PhotoRepository` 替换 1-2 个 service 的 DB，向计划中的 ≥50% 靠近。

### P2（排期）

9. Delivery file phase：`guardFailed`（fingerprint throw）、`alreadyGone`、无备份 `removeFile` 失败、finalize 的 CAS skip（revision/id/state）；跨两个 linked session 的 cleanup。
10. PageVisibility：7 个 VM 的副作用计数矩阵（不只状态）、hide 时取消在途轮询、A→B 会话切换后 A 的未挂载页保持 0。
11. Composition：FeatureAPIs 每个 API 的类型/同一实例断言；Runtime start/shutdown 的 8 executor 已有，补角色拆分后的重复构造检查。
12. 测试卫生：合并两套 `ServiceConstructionTestSupport`；删除 `makeGatherTestDB` 转发；`coordinatorFactory` 关闭 DB；锁测试去掉 `Thread.sleep`；修正 `DeliveryModuleRoutingTests` 文件头；备份保留断言同秒 `-2`。
13. CI/发布：加有效执行数 ratchet 与 skip budget；x86_64/Rosetta 跑一次 `FaceEmbeddingFingerprintTests`；release workflow 至少 dry-run 版本注入/lipo（签名/公证无凭据时记录限制）。
14. DeliveryStateMachine：要么把 `isConfirmReady`/`shouldReopenForInput`/迁移表接入编排，要么删死表并把测试收敛到已用的 3 个谓词；不要保留“测试守护未使用表”的假信心。

## 6. 结论

WP1–WP7b 的测试工作**不是“只加测试凑数”**：Delivery 的 24 个新用例是本轮质量最高的部分，Schema 11 例也真正覆盖了 V1→V2 的数据保留/回滚/fail-closed；PageVisibility 矩阵和 trace 主干用例也能在回归时变红。**可以判定“主干行为有回归网”**。

但 final acceptance 不能只凭“全绿”：

- **WP3b 是最大的验收盲区**：约 3,000 行新持久化代码没有一条新断言，测试侧只有两套复制 shim，且计划中的 fake repo 目标（≥50%）为 0。现有 1,100 个用例证明的是旧 service 行为，不是新 repo/query 边界。
- **WP4d 的菜单命令测试已经名存实亡**：它测的是 L10n 表，不是命令；这是明确的覆盖丢失，应作为 P1 修复。
- **WP6 的迁移安全网少几条关键失败路径**（shape/FK guard、备份失败、非 SQLite 默认）；其中 shape/FK guard 是唯一 P0，建议补完再宣布 Schema V2 验收完成。
- **WP7b 的 trace 覆盖声明 > 实际**：cancelled/interrupted/lease-lost/finalize/confirm 失败都没有断言；不影响业务正确性，但影响可观测性验收。

综上：**行为验收可给“有条件通过”**——全量测试 1,100/165 + 617/68 exit 0、重复运行稳定；条件是先补 P0（迁移 guard）与 P1-1/P1-2/P1-3（SQL 边界、菜单命令、trace 终态），其余 P1/P2 排期。若 owner 要求“测试与代码改动等比例”，WP3b 与 WP4d 两处不应按“已验收”记账。

## 7. 未执行 / 限制

1. 未改源码/测试/脚本/CI；只新增本报告。没有跑 `build.sh` 的签名/公证/staple/spctl（无凭据），也没有 GUI/视觉验收。
2. 未在 x86_64/Rosetta 运行；Float16 fallback 与 universal 产物的运行期行为未验证（**疑似**，取决于 CI runner 架构）。
3. 未跑覆盖率工具；“0 直接测试”是静态 grep + 测试 diff 结论，不是行覆盖率数字。
4. core/app 全量命令中 app 未加 CI 的 `--manifest-cache none`（本机非 CI 缓存场景）；core 命令与计划一致。两者均 exit 0。
5. `swift test` 汇总的 1,100 包含 3 个 skip；有效执行 1,097。台账若写 1,100 “通过”，应注明 skip。
6. 未逐条验证 68 个被删 Protocol 用例与类型的对应关系（抽查 13 个类型均已从 Protocol 消失；完整清单见 `docs/reviews/wp1-protocol-inventory.md`）。
