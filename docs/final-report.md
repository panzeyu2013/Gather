# Gather 破坏性重构最终报告（Cut 6 / 6c）

> 日期：2026-10-22 · 当前 HEAD 见 `git log`（Cut 6c 快照基线 `82603e0`）· 工作区干净（本地 commit 已提交，未 push）
> 权威计划：`docs/reviews/refactor-design-breaking-2026-10-21.md` · 台账：`docs/refactor-progress.md` · 决策：`docs/refactor-decisions.md`
> 本报告是 Cut 6c 的交付索引：目标/结果、Cut 0–6、指标、删除清单、验证证据、残余项、回滚说明。

## 1. 目标与结果

目标是把两包单体原生应用重构为**类型化、可验证、单实现**的 7-target SwiftPM 工程：删除字符串命令与 Router、以 SchemaV1 取代迁移链、拆分模块、收敛 UI 状态与本地化、算法单趟化，最后冻结指标与门禁。

结果：**Cut 0–6 全部完成**（2026-10-22），并在 8 路独立评审后完成 **P0/P1 修复轮**，随后执行 **架构整改 WP0–WP7b**。Cut 6c 时点：0 条字符串命令、16 个域协议/110 个方法、SchemaV1（43 表/373 列/69 索引/62 外键）、179 个错误码、页面/VM 中 `l()` 为 0、14 个 `#Preview`、core 1,092/157 + app 581/66 全绿。架构整改后：core **1,146/171**、app **624/69**、schema **user_version=2**、ratchet **54/230/0/0/0**、Application SQL **0**、Delivery Coordinator **543 行**、Protocol **255 类型/1,340 声明**；最终独立验收见 final-acceptance 系列报告；当前状态与提交见 [architecture-remediation-status.md](reviews/architecture-remediation-status.md)。人工 GUI smoke 与真实签名/公证仍未执行；10k 人脸精确聚类 19.25s，按 D-158 接受 ≤20s 基线。

### 1.1 评审修复轮（2026-10-22）

8 路只读评审（API/持久化/构建/UI/本地化/算法/测试/清理）发现 2 个 P0、20+ P1；本轮已完成：

- **P0-1**：Delivery cleanup/replay/orphan restore 文件阶段加 revision/status/base_fingerprint 守卫；新增 XMPFileLock 串行 restore/remove/writeback，TOCTOU 窗口收敛；三入口 + 并发回归测试。
- **P0-2**：CI/README/DEVELOPMENT 统一 app `--no-parallel`；AsyncWait 改 ContinuousClock+可配置上限；4+2 个 flake 用例显式断言/隔离；app 默认并行 5/5、串行 1/1 实测绿（修复前并行 6/6 红）。
- **数据完整性**：mergeInput 全会话 confirmed_at 重置；writing 租约 claim/renew + 300s TTL + 崩溃归位；metadata enqueue 单事务；user_version 列形指纹不符即重置；Indexer 先删 person_photos；cleanup 其他模块 pending 时 skip。
- **功能闭环**：metadata 手动队列接 WritebackService.executePending（rating/label/keywords 立即写盘）；acceptExternalState 只到 written 并清旧确认；session.create 目录分支 job+回滚；JobCreateParams.metadataScan 工厂单源。
- **UI**：SessionWorkspace 两级可见性（页面级 setPageVisible），隐藏页不再轮询；endSession 接 Dashboard 删除；Gallery 构造零副作用、首可见加载；删除 RequestGate/ViewState 死代码（CL-04 deferred）。
- **测试/打包/本地化**：补 15 个 API Live 行为测试；test-catalog 识别 enabled(if)/Suite(.disabled) 且 CI strict；entitlements + SFace/lproj 精确断言；设置页动态中文改固定 key；L10n.plural 7 模板 + parity 扩 Notice/三元；剩余 76 模板列 CL。
- **清理**：ratchet baseline 更新 53/240/127；删除 Sources/.build 379MB；新增 docs/review-remediation-report.md。

残余（不冒充完成）：GUI smoke、build.sh 本机完整执行（CI 承接）、10k 19.25s 性能、剩余 76 复数模板、进程外写盘不与 XMPFileLock 串行、markWritten 未校验 owner、git 未 commit/混合态、少量 P2/CL。

### 1.2 架构整改 WP0–WP7b（2026-10-22）

按 [architecture-remediation-plan.md](reviews/architecture-remediation-plan.md) 完成：

- Protocol 347→251 类型、零引用 89→0、Router 信封 6→0，新增 protocol surface ratchet。
- GatherDelivery target 提取；Coordinator 1,964→366（含 WP7b 日志），状态写入 33→8，模块适配器 15→0（5 方法），DB 删除 + intent.finish 单事务；旧 feature 转发端口删除。
- GatherDomain→GatherApplication；8 组 Repository/Query Ports；Application DBConnection 16→0、connection.prepare 125→0（services_prepare ratchet 0）。
- RootShell/RootView 882 行迁 UI；27 sync 核 + 18 UI sync 端口 + Bridge 删除；AppComposition 421→107，Composition 拆为 Core/FeatureAPIs/Runtime/Root。
- CullingService 2,496→138 门面 + 6 文件；FaceKwService 2,528→171 门面 + 5 文件。
- Schema V2 no-op 迁移 + VACUUM INTO 备份/回滚；universal/arm64/x86_64、版本注入、签名/公证接口与 release CI。
- GatherTestSupport 变 product；manifest 去 xcrun；CI 加 schema verify。
- PageVisibility 统一 7 VM 生命周期；GatherAppCommands 迁 GatherApp（Host SwiftUI=0）；Job/Delivery trace 日志与阶段边界。

当前指标与剩余项以 [architecture-remediation-status.md](reviews/architecture-remediation-status.md) 为准；历史 Cut 表保留快照口径。

## 2. 六个 Cut 的完成表

| Cut | 状态 | 关键产出 | 收口验收 |
| --- | --- | --- | --- |
| 0 盘点/审计/门禁 | 完成 | test-audit、cleanup-backlog、api-migration-map（118→16/110）、cleanup-baseline + 8 个门禁脚本；安全清理 | app 298 tests、core 受影响 121 tests 绿 |
| 1 类型化 API，删 Router | 完成（B8.5） | 118 条字符串命令→0；16 协议/110 方法；删 Router/CommandRouter/NativeCommandClient 等 7 文件 4,052 行；AppComposition/AppRuntime | 0 字符串命令；app 455/55、core 1080/149 绿 |
| 2 SchemaV1 + Database + Delivery | 完成（S5c-2b-3b-2b-3） | `Database.open`→SchemaV1（不兼容库整体重置，含 -wal/-shm）；启动 replay；删旧同步/迁移栈 5 文件 4,081 + 4 测试 1,983 行 | 10 条 P0 门禁 + fresh DB 全功能；core 1080/151、app 461/55 |
| 3 模块拆分 | 完成（D-105） | 当时 7 target：Protocol/Persistence/Analysis/Domain/UI/Host/App；删伞 `GatherCore`；UI 只 import Protocol（后续拆出 GatherDelivery，当前 8 target） | UI 不 import Persistence；core 1057/149、app 461/55 |
| 4 UI 状态层 + 本地化 | 完成（4a/4b/4c） | SessionStore/Workspace/ViewState（2026-10-22 删除，CL-04 deferred）/CommandError/LanguageStore；`l()` 1,481→0；11 个巨型 View 拆分；14 个 `#Preview` | RootView 壳 148 行；app 580/66、core 1057/149 绿 |
| 5 算法单趟化 | 完成（5a–5d） | ClusterGraph 单实现；删 ClusterEngine/ClusteringImpact/HNSW/6 份 BFS；批量 FaceMatcher；聚类移出锁；10k bench | core 1,092/157 绿；HNSW 代码引用 0（仅历史注释）；10k release 19.25s（5s 目标未达） |
| 6 清扫与防腐 | **完成（6a/6b/6c）** | 删 94 en（含 31 孤儿）+ 1 zh key、12 死符号；28 篇文档归档；注释/改名；L10n 注释 177→179、1,407→1,313（评审修复轮 +9 键 → 1,322）；本报告 | core 1,092/157、app 581/66；8 门禁 strict + schema verify + preview strict 全过；build.sh 本机受限、GUI 待人工 |

## 3. 最终指标（Cut 6c 冻结）

| 指标 | 基线/重构前 | 最终值 | 口径 |
| --- | ---: | ---: | --- |
| Swift 文件 | 364（Cut 2 关闭） | **675**（Cut 6c 快照 535） | 收尾实测（含拆分文件）；排除 `.build`；历史 6c 数字保留在归档 |
| 总行数 | 122,692 | — | 收尾未重算全量行数；以当前 `wc -l` 为准，避免旧 133,740 与拆分后矛盾 |
| SwiftPM target | 2 包（含伞 GatherCore） | **8** | GatherProtocol / GatherPersistence / GatherAnalysis / GatherDelivery / GatherApplication / GatherUI / GatherHost / GatherApp（另有 GatherSchema、2 个 bench、test target） |
| Schema | 旧迁移链（v35 快照） | **43 表 / 373 列 / 69 索引 / 62 外键 / user_version=2** | `gather-schema verify` + SQLite `pragma_table_info`/`pragma_foreign_key_list` 独立复核；V1→V2 线性迁移 |
| 错误码 | 179 | **179** | `GatherErrorCode` 的 `case` 计数（L10n.swift 注释旧写 177，6c 修正） |
| 域协议/方法 | 118 条字符串命令 | **16 协议 / 110 方法** | `GatherProtocol/API/*API.swift` 的 `public protocol` 与 `func` 计数；`PhotoPathPolicy` 端口不计入 16 |
| 字符串命令 | 118（82 sync + 36 async） | **0** | `grep -rnE 'execute(Async)?\( *"|enqueue\( *"' gather-app --include='*.swift'` = 0 |
| 本地化 | en 1,407 / zh 10；`l()` 1,481 处 | **en 1,332 / zh 9；页面/VM `l()` = 0** | 修复轮新增 plural/#one/FaceModelPathIssue 9 键；`en` 按 `^"` 计键（1,332；P2 错误码文案新增 10 键） |
| Preview | — | **14 块 / 5 个 PreviewSupport 文件 / 2,031 行** | `check-preview-surface.sh --strict` |
| 测试 | core 994 / app 298（Cut 0） | **core 1,146/171 + app 624/69** | P1/P2 收尾实测；core 3 条真实照片 skip（有效 1,143）；app 串行 + 并行 3 次均绿 |
| 清理 ratchet | 40 / 348 / 128 / 0 / 0（Cut 0） | **54 / 230 / 0 / 0 / 0** | services_prepare 0；unchecked +1 为进程内 replay claim，try? 231→230 |
| 文档 | 42 篇 / 18,609 行 | **55 篇 / 21,787 行（非 archive 26 篇 / 8,765 行）** | 含本报告与 archive 索引；28 篇历史文档已归档；2026-10-22 收尾实测 |
| 收尾复核（2026-10-22 23:00） | — | **675 Swift 文件；测试文件 179；#Preview 14；非 archive 死链 0** | P1/P2 收尾实测；Coordinator 543 行、GatherDelivery 20 文件 |

## 4. 删除清单（主要项）

行数口径：HEAD 可取得的文件按 `git show HEAD:<path> | wc -l`；重构中新建后删除的文件（ClusterGraphParity、SchemaV1Transition）按删除时台账。行数为“删除/减少”，不等于全仓净变化。

| 领域 | 主要项 | 行数/数量 |
| --- | --- | ---: |
| 命令面 / Router | SessionCommandRouter 3,258；CommandRouter 51；NativeCommandClient 77；CommandSurfaceRuntimeTests 296；NativeCommandClientTests 223；StubCommandRouter 38；check-command-surface.sh 109（合计 7 文件） | **4,052**（118 条命令） |
| 旧同步 / 迁移 / outbox | MetadataSyncCoordinator 1,230；MetadataOutboxRepo 897；WritebackRepo 205；Migrations 1,628；SchemaV1Transition 121 = 4,081；4 个测试 1,983（707/517/264/495）；`Schema.swift` 649→19 | **6,694**（含 Schema 净减 630） |
| 聚类 / HNSW | ClusterEngine 753；ClusteringImpact 442；其测试 672；ClusterGraphParity 717；HNSW 471；benchHnsw 52；VectorIndexReconciliation 323→213（−110）；IncrementalClusterer 748→340（−408）；6 份 BFS→2 | **3,625** |
| 向量基准数据 | vector-fixtures 的 HNSW 段 2,418 行；生成器 1,016→563（−453，保留只产 LSH 的脚本） | **2,418**（另改写 −453） |
| 6a 死代码 / 注释 | 12 个零引用符号、净 −63 行；14 处旧 section 注释路径 | **57** |
| 6a/6b 资源 / 文档 | en 键 −94（63 直接删除 + 31 存量孤儿）、zh −1；parity allowlist 32→1；28 篇文档归档（18 reviews + 10 cuts）、49 个 assets；`makeMigratedDB`→`makeTestDB` 80 处；171 个文件头旧 target 路径 | **95 个 lproj 键 / 28 篇** |
| **合计（主要项相加）** | 不含新增/改写与 UI 拆分 | **≈16.8k 行** |

补充：Cut 1 的 118 条命令被 16 协议/110 方法替代，Router 相关符号与 legacy adapter 删除后 `check-no-legacy` 的 R5 四类文件为 0；Cut 2 删除旧 metadata outbox/writeback 表与列，生产代码不再引用旧表（`Sources/Tests` 旧表/列引用 = 0）。

## 5. 验证证据（2026-10-22 实跑）

### 5.1 构建与测试

命令（在 `desktop/native` 下）：

```bash
# core：build + test，SE-0409 严格 import 检查
swift build --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
swift test  --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error

# app：build + test，--no-parallel；CLANG_MODULE_CACHE_PATH 需按本机设置
swift build --package-path gather-app --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path gather-app --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error --no-parallel
```

| 检查 | 结果 | exit |
| --- | --- | ---: |
| core build（strict） | `Build complete! (8.37s)`；仅有既有测试编译 warning，0 error | 0 |
| core test（strict） | `Test run with 1146 tests in 171 suites passed` | 0 |
| app build（strict） | `Build complete! (4.63s)` | 0 |
| app test（strict + `--no-parallel`） | `Test run with 624 tests in 69 suites passed`（串行 + 并行 3 次） | 0 |
| app test（r8 P1-3 删除后，strict + `--no-parallel`） | `Test run with 599 tests in 66 suites passed after 17.199s`（本刀删除 12 例；并行工作区另 +5 例/1 套件。删除当次为 594/65，默认并行连跑 3 次亦 594/65） | 0 |

### 5.2 Schema

```bash
swift run --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify
```

结果：`schema ok: tables=43 user_version=2 foreign_key_violations=0`（exit 0；Cut 6c 当时为 1，WP6b 后为 2）。另把 `gather-schema dump` 的 DDL 灌入内存 SQLite，用 `pragma_table_info` / `pragma_foreign_key_list` 独立复核：**tables=43，columns=373，indexes=69，foreign_keys=62**。

### 5.3 九道门禁（strict 可用的均带 --strict）+ preview

全部 exit 0：

| 门禁 | 结果 |
| --- | --- |
| `check-cleanup-ratchet.sh` | OK；**54 / 230 / 0 / 0 / 0**（baseline 54/230/0/0/0） |
| `check-test-catalog.sh --strict` | OK；179 个测试文件、缺头注释 0、skip 站点 3、withKnownIssue 0 |
| `check-docs.sh --strict` | OK；ADR 20（缺失 0）、reviews 当前 30 篇、md 链接 0 缺失、schema 声明一致 |
| `check-no-legacy.sh` | OK；7 条 enforced 全过，6 个 tracked 指标 |
| `check-layering.sh` | OK；17 条规则全过（含 UI/App 禁 import GatherDelivery） |
| `check-duplicate-symbols.sh --strict` | OK；扫描 675 文件、batchAsync 1 份、Tests/Support 外 0 |
| `check-select-star.sh --strict` | OK；Sources 4 处 / 1 文件（baseline 4）、Tests 1 处（白名单） |
| `check-preview-surface.sh --strict` | PASS；**14 个 #Preview / 5 个 PreviewSupport 文件 / 2,031 行** |
| `check-protocol-surface.sh --strict` | OK；255 类型 / 1,340 声明 / 0 零引用 / 0 信封 |

### 5.4 build.sh（本机受限，未通过 ≠ 代码失败）

```bash
./desktop/native/build.sh
```

本机 exit 1。失败点：脚本第一个 release 构建（`build.sh:28`，`swift build --package-path .../gather-core -c release --explicit-target-dependency-import-check error`）在编译 manifest 时被沙箱拒绝：

```text
error: 'gather-core': Invalid manifest (...)
sandbox-exec: sandbox_apply: Operation not permitted
BUILD_SH_EXIT:1
```

原因：build.sh 不传 `--disable-sandbox`，而 DSH 环境不允许 `sandbox-exec`。**未在本机生成 `release/Gather.app`，不声称 bundle / lproj / FaceModels / codesign 已验证。** CI 验证命令：`.github/workflows/ci.yml` 的 `gather-app tests + bundle` job 执行 `./desktop/native/build.sh`（macos-14），构建产物与断言以该 job 为准。

### 5.5 其它证据

- 错误码：`GatherErrorCode` 枚举内 `case` = **179**；L10n.swift 注释写 179 码 / en 表 1,313（缓存上限 ≈3 倍的说明，表当前实测 1,332 键）。
- 协议：16 个 `*API.swift` 内 `func` 合计 **110**；`PhotoPathPolicy` 是端口，不计入。
- 页面/VM `l()`：`grep -rnE '\bl\(' Sources --include='*.swift' | grep -v /Support/` = **0**。
- 字符串命令：`grep -rnE 'execute(Async)?\( *"|enqueue\( *"' gather-app --include='*.swift'` = **0**。

## 6. 残余 / 未做（不阻塞机器验收，必须留档）

1. **人工 GUI smoke 未做**（无 GUI 自动化）：启动/导入/切页、挑片与撤销、相似度/重复、人脸、导出/任务、中英切换逐页 A/B、菜单与 `Cmd+Q` 优雅停机，全部未测；不得用测试绿灯替代。
2. **bundle 本机未构建**：受 DSH 沙箱限制（见 5.4）；bundle 大小、两份 lproj、FaceModels、未签名状态均未在本机验证，交 CI。
3. **10k 人脸精确聚类未达 5s**：release 精确 DBSCAN 19.25s（3 跑中位；总 19.50s、批量匹配 152.8ms、内存粗估 39.1/19.6MB），约为审计目标 5s 的 3.85×；D-158 已接受 ≤20s 为新 release 基线，5s 作为后续 stretch。debug LSH 中位 28.9s（12.98s 聚类 + 15.56s 匹配），两构建不可互比。
4. **CL-18 仍 pending**：`try?` 236 行（baseline 242）、`@unchecked Sendable` 53 行；未批量改语义（会改变 UI 错误路径与测试断言），ratchet 只降不升。
5. **CL-20 已 done，但只是静态证据**：删 94 个 en 键 + 1 个 zh 键（en 1,407→1,313→**1,332**（修复轮 +9 + P2 错误码 10）、zh 10→9），保留 `检测模型路径` 1 个 pinned key；未做真实 en 界面逐页 A/B（GUI 不可用）。
6. **CL-19 已 done**：保留 60 个旧回归用例；其中 4 例依赖 `/usr/bin/zip`、`/bin/sh`、`/usr/bin/awk`，非 hermetic，未重写为夹具。
7. **ratchet baseline 未收紧**：当前 try_optional 已 236，baseline 仍 242；6c 只读验收，未改 `docs/cleanup-baseline.json`。如需冻结为 236，由 owner 跑 `check-cleanup-ratchet.sh --write-baseline` 并复核。
8. **工作区状态**：当前改动已提交且工作区干净（本地 commit 未 push）；`.build`/`release` 仍 gitignored，不计入源码统计。
9. **CL-04 已 deferred，RequestGate/ViewState 已删除**（r8 P1-3，2026-10-22）：两者均零生产调用点，却曾被本报告当作 duplicate 门禁证据。已删除 `GatherUI/Support/RequestGate.swift`（34 行）、`ViewState.swift`（49 行）及测试 `RequestGateTests.swift`（4 例/58 行）、`ViewStateTests.swift`（8 例/98 行），共 **4 文件 / 239 行 / 12 例**；4 套 stale 守卫（Gallery `fetchGeneration` / Library `latestRequestID` / Similarity `tierRequestID` / Culling `pageVersion`，实测 37 行）仍未统一，解除条件见 [cleanup-backlog.md](cleanup-backlog.md) CL-04。本刀删除 12 例（606/67 → 删除后 594/65，串行与默认并行各实测）；当前树因并行工作区新增 5 例/1 套件为 **599/66**（数字随并行工作区仍在变动）。`GatherUI/Support/LoadPhase.swift:9/18` 注释经复核已无旧名（并行工作区 16:48 已修，非本轮改动）；`check-duplicate-symbols.sh` 的 RequestGate 规则与“Cut 4 落地”文案已于 2026-10-22 最终清理移除。
10. **最终收尾（docs/scripts/构建产物，2026-10-22）**：见 [final-cleanup-docs.md](final-cleanup-docs.md)。删除 9-29 的 `release/Gather.app`（22 MB）与 4 个非活动 `.build` scratch + 1 个探针（≈2.19 GiB）；当前文档（非 archive）md 死链 13→0（`face-clustering-benchmark.md` 的旧 `GatherCore` 源码链接）；dup 脚本去掉 RequestGate 规则；en 1,322、测试文件 166、ratchet current 53/235/127（baseline 240）均实测。归档 33 条旧源码路径链接按“快照不改”保留，仅索引注明。

## 7. 回滚 / 恢复

- **代码回滚**：重构已分解为本地 commit（未 push）；按 `git log` 选择 revert 或 `git revert <range>`，不要 `reset --hard` 丢历史。工作区当前干净，不再存在“未提交工作需备份”的状态。
- **数据库**：存在 **V1→V2 线性迁移**（先 `.pre-v2-*` 一致性备份，再 `BEGIN IMMEDIATE` 补版本/370 列缺列，失败回滚，未知形态默认 fail-closed）。只有显式 `resetPolicy` 才把 `gather.sqlite` 连同 `-wal`/`-shm` 改名为 `<db>.incompatible-<ts>` 后重建；恢复 = 停应用、移走新库、把备份改回原名。
- **旧数据**：旧 outbox/writeback/metadata 表不迁移、不导入；delivery 状态从新库重新开始，启动时仅 replay 新库中未完成的 deliveries。开发期数据按可丢弃处理。
- **文档**：28 篇历史文档已迁入 `docs/archive/`（`docs/archive/README.md` 有旧→新映射）；归档正文的行号是当时快照，不随代码回滚自动恢复。
- **应用**：无签名 bundle 可随时用 `build.sh` 重建；本机受限时以 CI 产物为准。

## 8. Goal 关闭材料

| 关闭条件 | 证据 | 状态 |
| --- | --- | --- |
| 8 target 边界与严格 import | core/app build strict 均 exit 0；layering 17 条 | 通过 |
| 0 字符串命令 / 16 协议 110 方法 | grep = 0；协议/方法计数 | 通过 |
| Schema V2 单真相源 | verify 43/2/0；SQLite 复核 43/373/69/62 | 通过 |
| 旧实现删除且无并存 | no-legacy 7 enforced；R5 四类 0；HNSW/ClusterEngine 引用 0 | 通过 |
| 测试全绿 | core 1,146/171；app 624/69；exit 0 | 通过 |
| 9 门禁（strict 可用）+ preview | 全部 exit 0；preview 14 | 通过 |
| 指标与报告冻结 | 本报告 + refactor-progress 顶部 + D-163 最终关闭 + 2026-10-22 收尾复核（535/138,829、en 1,322） | 通过 |
| L10n 注释 | 177→179、1,407→1,313（表最终 1,322） | 通过 |
| 人工 GUI / 本机 bundle | 未做；已记录命令、失败点与 CI 入口 | **待人工/CI**（非代码阻塞） |

**结论**：8 路评审的 P0/P1 产品路径与架构整改 WP0–WP7b 已闭环，机器验收达到**架构可提交候选**：core 1,146/171、app 624/69（串行与并行均绿）、schema 43/373/69/62/user_version=2、9 门禁 strict、ratchet 54/230/0。**发布门仍未闭环**（app icon 缺失、release runner 需 macos-26/Xcode 26、签名/公证/CI release 未实跑、x86 Rosetta 未验），不能称为“可发布包”；建议 owner 先补资产/凭据并在 macos-26 跑一次 release，再打 tag。

## 9. 后续接手（resume）

1. 先读本报告 + `refactor-progress.md` 顶部 + D-172；当前工作区已提交且干净，HEAD 见 `git log`；未 push。
2. 复跑机器验收：§5.1/5.2/5.3 的命令；预期 core 1,146/171、app 624/69、schema 43/373/69/62/user_version=2、9 门禁 54/230/0/0/0、preview 14、test-catalog 179 文件、docs 非 archive 死链 0。
3. CI 跑 `./desktop/native/build.sh`（`gather-app tests + bundle` job），记录 bundle 大小、两份 lproj、FaceModels、未签名状态。
4. 人工 GUI smoke 按 §6 第 1 项逐项记录 pass/fail；重点做中英切换逐页 A/B（94 个 en 键删除后的回归风险）。
5. 10k 人脸优化以 5s 为 stretch；19.25s 已按 D-158 接受为 ≤20s 基线，优化前先固定机器与 bench 档位。