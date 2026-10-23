# 最终验证证据审计（只读静态）

> 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`（HEAD 06b3e0d）
> 审计方式：只读静态读取源码/配置/文档，仅做目录/文件元数据查看（`ls`/`find`/`file`）。**本审计未执行 build、test、门禁脚本、schema verify、build.sh，未做签名/公证/GUI。**
> 运行时数字引用：主线程通报 `core 1,146/171、app 624/69、9 门禁与 schema 全绿`；这些是外部实测证据，本报告未复跑，仅用于与文档对账。

## 0. 结论

1. **CI 结构上覆盖了 9 道门禁、core/app 测试与 schema verify**：`boundary` 跑 no-legacy，`gates` 跑其余 8 道，`gather-core` 跑全量测试 + vector reconciliation + schema verify，`gather-app` 跑串行 app 测试 + bundle 构建；未发现门禁重复执行，脚本/命令路径均存在。
2. **但“发布验收”没有可执行的 CI 路径**：唯一做 universal/签名/公证/插件校验的 `release` job 固定 `runs-on: macos-14`，又硬性要求 SDK ≥26；该 runner 不可能满足，tag 推送必然在 `Assert release SDK` 处失败，不会产出任何发布包。`gather-app` job 只构建 host 单架构、未签名 bundle，不能替代。
3. **机器验收绿 ≠ 发布验收通过**：签名、公证、x86_64 运行期、插件双架构/Capture One 加载、GUI 全部未验证；且现有验收报告内部数字互相矛盾（1,141/1,143、1,092/1,146、616/624、174/179、2,045/2,031、baseline 6/4），不能作为发布签核证据。
4. **测试基建仍有可复现的 flake 面**：core 默认并行，而 `TraceLoggingTests` 与 `LoggerTests` 都替换进程级 `GatherLogger.output`，`.serialized` 只保证套件内串行；另有 33 处 `defer { Task { await stop() } }` 与多处固定 20/50/150ms 时序断言。
5. **架构门禁有实质漏检**：`check-layering.sh` 的 UI/入口禁 import 列表不含 `GatherDelivery`，UI 直接 import Delivery 可绕过“UI 只依赖 Protocol”并保持门禁全绿。

**总判**：CI 的“9 门禁 + schema verify + core/app 测试”可以支撑**开发门禁**；不能支撑“可发布候选/发布 tag 可执行”的结论。发布验证须单列为未通过。

## 1. CI 覆盖矩阵（逐 job）

| Job | 步骤 | 覆盖 | 结论 |
| --- | --- | --- | --- |
| boundary (`ci.yml:27-36`) | `check-no-legacy.sh` | 9 门禁之 1 | 覆盖；`gates` 未重复执行（`:49-50`） |
| gates (`ci.yml:38-62`) | docs / cleanup-ratchet / layering / duplicate / test-catalog / preview / select-star / protocol | 其余 8 门禁 | 覆盖；全部脚本存在 |
| gather-core (`ci.yml:64-85`) | core 全量测试、`GATHER_RECONCILIATION_VECTOR=1` 过滤测试、`gather-schema verify` | core 测试 + schema | 覆盖；verify 只验内存新建库 |
| gather-app (`ci.yml:87-118`) | app 全量测试 `--no-parallel`、`build.sh` | app 测试 + host 单架构 bundle | 覆盖测试；**不含 universal/签名/公证** |
| toolchain-compat (`ci.yml:120-132`) | 最新 toolchain build core/app | 编译漂移哨兵 | 覆盖；不跑测试，不是发布门 |
| release (`ci.yml:145-314`) | universal + 签名 + 公证 + 插件/产物断言 | 发布 | **配置上必然失败**（见 P0-1） |

- “9 门禁”口径成立：no-legacy、docs、cleanup-ratchet、layering、duplicate、test-catalog、preview、select-star、protocol。CI 各执行一次，无重复。
- 路径核对：`./scripts/check-*.sh`、`desktop/native/build.sh`、`gather-schema` 均存在；未发现 CI 指向不存在的脚本/产品。
- schema verify 命令正确：`swift run --package-path desktop/native/gather-core gather-schema verify`（`ci.yml:85`），产品名 `gather-schema` 与 `gather-core/Package.swift:52` 一致；`GatherSchema/main.swift:84-157` 校验 43/373/69/62/user_version=2/FK 0。

## 2. P0（发布阻塞）

### P0-1 release job 在唯一配置的 runner 上必然失败，tag 无法产出发布包

- 位置：`.github/workflows/ci.yml:151`（`runs-on: macos-14`）、`:189-203`（SDK 主版本 <26 直接 `exit 1`）、`:146-158`（`GATHER_ARCHS=universal`、`GATHER_NOTARIZE=1`、`GATHER_RELEASE=1`）。
- 证据链：`ci.yml:147-150` 自己的注释写明 macos-14 最高 Xcode 16/SDK 15，无法满足；`ci.yml:200-202` 在 SDK <26 时 fail closed；`release` 没有其他 runner 分支。
- 影响：`v*` tag / workflow_dispatch 的发布 job 100% 失败；签名、公证、universal app、插件双切片、`stapler`/`spctl` 全都没有真实执行证据。`docs/final-report.md:194` 仍建议“CI bundle 与 GUI smoke 通过后执行发布 tag”，与当前配置矛盾。
- 建议：把 release 移到 `macos-26` 或装有 Xcode 26 的 self-hosted runner；把 runner/SDK 能力作为 job 前置前置检查（当前断言保留）；在可执行 runner 上跑一次完整 tag/dry-run 并保留 artifact 日志。**在完成前，状态只能是“发布验证未通过”，不能写“可发布候选”。**

## 3. P1（发布/门禁/测试可信度）

### P1-1 layering 门禁漏掉 GatherDelivery，UI/入口可绕过分层

- 位置：`scripts/check-layering.sh:66-67`。
- 证据：UI 禁止列表是 `GatherPersistence GatherApplication GatherAnalysis GatherHost`；入口禁止列表是 `GatherProtocol GatherPersistence GatherAnalysis GatherApplication`。两处都没有 `GatherDelivery`。而 `GatherDelivery` 依赖 Protocol + Persistence（`gather-core/Package.swift:79-83`），UI import 它会间接带入持久化层，仍满足“不 import Persistence”的文本检查。
- 影响：这是分层门禁 17 条规则中的实质漏检；UI 直接 import Delivery、入口绕过 Host 直接 import Delivery 都不会红。与“UI 只 import Protocol、GatherApp 只 import Host”的硬约束不符。
- 建议：UI 禁令补 `GatherDelivery`；入口禁令补 `GatherDelivery`（以及任何新增 core 产品）；并在 `ci.yml` 的 layering 步骤保持 `--strict` 不需要（该脚本无 strict，直接 exit 1）。

### P1-2 core 默认并行 + 两个套件替换全局 logger，`.serialized` 不能防跨套件竞争

- 位置：`desktop/native/gather-core/Tests/GatherCoreTests/Logging/TraceLoggingTests.swift:218`（`@Suite(.serialized)`）、`:31-41`（`LogCapture.start()` 读取并替换 `GatherLogger.output/minimumLevel`，未持 `stateLock`）；`desktop/native/gather-core/Tests/GatherCoreTests/LoggerTests.swift:10`、`:40-56`（同样替换全局 output，并用 `stateLock` 保护）。
- 证据：`check-test-catalog.sh` 与 CI 都不限制 core 并行（`ci.yml:79` 无 `--no-parallel`）；Swift Testing 的 suite `.serialized` 只保证套件内串行，两个套件之间仍可并行。`TraceLoggingTests` 的捕获会在另一套件替换/恢复 output 时丢行；`LoggerTests` 的 capture 也可能被 Trace 套件覆盖。
- 影响：`TraceLoggingTests` 的 14 条 trace 断言与 `LoggerTests` 的 4 条日志断言在满载 CI 上可能间歇失败或误绿；日志断言不是业务失败，但会让门禁不可信。
- 建议：给 core 也加 `--no-parallel`（最稳），或让 global logger 捕获走 `GatherLogger.stateLock` 的公共测试 helper，并在 `capture.start/stop` 全程持锁；只给两个套件同时加 `.serialized` 不够（跨套件无效）。

### P1-3 “app 串行与并行均绿”与 CI/文档的 `--no-parallel` 口径冲突

- 位置：`ci.yml:109-116`（app 始终 `--no-parallel`）；`docs/DEVELOPMENT.md:74`（“app 测试始终加 --no-parallel（CI 同口径）”）；`docs/final-report.md:194`（“app 624/69（串行与并行均绿）”）；`docs/reviews/architecture-remediation-status.md:34`（“串行 + 并行 3 次 exit 0”）。
- 证据：仓库自己的历史报告记录了并行失败：`docs/reviews/post-refactor-r1-api.md:113-114`（5 次并行 1 次红）、`post-refactor-r3-build.md:74`（并行 1 issue）、`post-refactor-r5-l10n.md:118`（并行 exit 1）、`post-refactor-r7-tests.md:131`（默认并行 6/6 失败）。当前 CI 没有任何并行 app job，无法复现“并行均绿”。
- 影响：发布证据把“从不执行的模式”写成已通过；如果 owner 按报告在本地并行跑，可能得到与 CI 不同的结果。`--no-parallel` 本身是合理修复，但结论应写“串行绿；并行不设门禁/历史有 flake”。
- 建议：要么保留 `--no-parallel` 并把报告改成“串行门禁”；要么新增一个非阻断的 parallel job 做趋势观测，不能把未执行的并行结果写成通过。

### P1-4 验收报告的“9 门禁”证据表实际只列 8 道，缺 protocol surface

- 位置：`docs/final-report.md:121`（标题“八道门禁”）、`:125-134`（表中只有 cleanup/test-catalog/docs/no-legacy/layering/duplicate/select-star/preview）、`:189` 与 `:194`（结论写“9 门禁 strict”）。
- 证据：CI `gates` 确实执行了 `check-protocol-surface.sh --strict`（`ci.yml:61-62`）；`final-acceptance-build.md:191-200` 的复现命令也列了 9 条（含 protocol）。但作为“最终报告”的证据表没有 protocol 行，读者无法从表内确认第 9 道。
- 影响：发布签核引用的表与 CI/复现命令不一致；protocol ratchet（255 类型/1,340 声明）实际上没有被最终报告表格证据覆盖。
- 建议：把 §5.3 改成 9 行并补 `check-protocol-surface.sh --strict`；同时把“9 道 strict”改成“9 道门禁（6 道带 --strict）”，因为 cleanup/no-legacy/layering 没有 `--strict` 开关（`final-sweep-docs.md:149` 已指出）。

### P1-5 gather-app job 只产出 host 单架构未签名 bundle；universal/签名/公证只在死掉的 release job 里

- 位置：`ci.yml:117-118`（`Native bundle build` 直接跑 `./desktop/native/build.sh`，未设 `GATHER_ARCHS`/`GATHER_RELEASE`/`CODESIGN_IDENTITY`）；`build.sh:155-159`（未设 `GATHER_ARCHS` 时 host 默认）；`build.sh:685-690`（无身份只告警不签名）。
- 证据：`gather-app` job 的注释/名称是 “tests + bundle”，但没有架构/签名断言；`release` job 才有 `GATHER_ARCHS=universal` 与签名/公证（`ci.yml:155-158`、`:223-232`），而该 job 依 P0-1 必失败。本机 `release/` 目录不存在（静态 `ls`），无本地产物可补证。
- 影响：CI 没有任何一次成功构建 universal app 的记录；x86_64 切片只存在于不可执行的 release 配置中；签名/公证零执行。`final-report.md:150` 把 bundle 交 CI，但 CI 的 bundle 是 host 未签名包，不能回答“发布包是否可分发”。
- 建议：新增独立的 `release-dry-run`（universal，不签名）在每次 PR/tag 前置可执行；release 用 self-hosted/macos-26；在 artifact 中保留 `lipo -archs`、`vtool`、`build-info.json` 日志。

### P1-6 时序敏感测试与 fire-and-forget 停服是 flake 面，且 core 默认并行会放大

- 位置/证据：
  - `desktop/native/gather-core/Tests/GatherCoreTests/Concurrent/BatchRunnerTests.swift:74`（body 睡 20ms）、`:80`（`#expect(snap.peak == 4)`）。满载 runner 上 4 个 worker 未必都在 20ms 内入场，peak 可能 <4。
  - `desktop/native/gather-core/Tests/GatherCoreTests/Services/FaceKeywordingServiceTests.swift:1885`、`:1918-1920`（并发读 ≤50ms，3 次取最小）；CI 为共享 macos-14，50ms 是 wall-clock 预算。
  - `desktop/native/gather-core/Tests/GatherCoreTests/Services/DeliveryCoordinatorTests.swift:720`（固定 `Task.sleep(150ms)` 等第二路 replay 进入 claim）；慢机上第二路可能尚未启动。
  - `desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryFilePhaseTests.swift:276-280`（restore 回调内 `Thread.sleep(0.02)`，靠睡眠制造重叠窗口）。
  - **33 处** `defer { Task { await ...stop() } }`：`JobServiceTests.swift:223,246,267,...,958`（27 处）、`TraceLoggingTests.swift:231,266,412,452,500,540`（6 处）。测试结束时 stop 未 await，可能与下一个测试/DB 关闭/日志捕获重叠。
- 影响：这些用例在报告里被写成“连跑 5 次/3 次均绿”，但绿的结果依赖机器负载；core 并行时尤其不稳。属于“已确认的 flake 风险”，不是已观测失败。
- 建议：用 `withTaskGroup`/continuation 门控替代固定睡眠；`peak == 4` 改为 `peak <= 4 && peak >= 2` 或直接断言“至少 2 路真并发”；≤50ms 改为相对基线（无锁时读取 vs 锁定时读取）或放大到 200ms；stop 改为显式 `await` 的 `defer` 结构（Swift 6 可用 `async` 清理 helper）。

### P1-7 验收/状态/最终报告的数字互相矛盾，不能作为同一时点证据

- 位置与差异：
  - `docs/final-report.md:67`：1,146 中含 3 skip，却写“有效 1,141”（应为 1,143）；`status:33` 写 1,143 正确。
  - `docs/final-report.md:108` 仍写 `core 1092/157`、`:110` 写 `app 616/68`；同一文件 `:11`、`:194` 写 1,146/171、624/69。`§5.1` 是旧快照，未标“时点”。
  - `docs/final-report.md:127` 写 ratchet `53/235/127/0/0`；`docs/cleanup-baseline.json:6-11` 与 `docs/refactor-progress.md:16` 是 `54/230/0/0/0`。
  - `docs/final-report.md:133` 写 select-star `Sources 6 处/2 文件（baseline 6）`；`scripts/check-select-star.sh:31` 的 `BASELINE=4`，静态源码实际是 4 处（`DuplicateGroupQuery.swift:24,35,42,51`），`DEVELOPMENT.md:436` 也写 4。
  - `docs/final-report.md:134` 写 preview `2,045` 行；5 个 PreviewSupport 文件静态合计 **2,031** 行（`PreviewFixtures 964 + PreviewAPIs 412 + PreviewProviders 91 + PreviewFactory 405 + PreviewShellViews 159`），`refactor-progress.md:270` 也是 2,031。
  - `docs/final-report.md:128` 写 test-catalog 166 文件、`:199` 写 174；`check-test-catalog.sh:24-28` 的 3 个根当前共 **179** 个 `.swift`（GatherCoreTests 107 + GatherTestSupport 5 + GatherAppTests 67）。174 少算了 GatherTestSupport 的 5 个。
  - `docs/reviews/architecture-remediation-status.md:61` 写 Protocol “254 类型”；`docs/protocol-surface-baseline.json:4-8` 与静态计数是 **255/1,340**（`final-acceptance-build.md:156` 也写 254/1,338，属于旧快照）。
  - `docs/reviews/final-acceptance-tests.md:12` 的 1,100/165 + 617/68 是 pre-closure 快照，当前 status 已 1,146/171 + 624/69；该报告 `:124` 还说 trace 只有 5 个 `@Test`，当前 `TraceLoggingTests.swift` 已是 14 个；`:110` 的“0 个 fake repo”也已过时（PortFakeSupport 有 22 个 fake 类型）。四份 final-acceptance 报告头没有“已被 status/D-172 取代”的提示（final-sweep-docs.md:80-83 已指出）。
- 影响：最终报告同时包含“旧快照”和“当前值”，且至少 6 处数字与脚本/源码不一致；发布会把错误数字当签核依据。
- 建议：统一以一次带时间戳的实测为准，修 final-report §5.1/§5.3/§9；历史数字加“Cut 6c/df73880 快照”横幅；test-catalog/preview/ratchet 三个数直接以脚本输出回填，不再手写。

### P1-8 PortFake 只补了服务编排，WP3b 的直接 SQL/Repo 边界仍无回归网

- 位置：`desktop/native/gather-core/Tests/GatherCoreTests/Services/PortFakeTests.swift`（8 个 `@Test`，5 个套件）、`PortFakeSupport.swift:35-741`（22 个 fake 类型）。
- 证据：fake 覆盖 `SettingsRepository/PhotoRepository/SessionRepository/.../PersonRepository`，但 `PhotoFilterQuery`、`CullingAssetPageQuery`、`CullingReadQuery`、`DuplicateGroupQuery` 在测试中只在 `ServiceConstructionTestSupport.swift:133,284-285,321` 被构造，没有直接断言空结果、分页钳制、动态谓词、错误映射。
- 与现有报告的关系：`docs/reviews/final-acceptance-tests.md:110` 写“0 个 fake repo”，在 PortFake 落地后已过期；但该报告 P1-1 的核心结论（新 Query/Repo 边界缺直接断言）仍成立。
- 影响：服务级 fake 测试能证明编排，不证明 SQL 文本/列序/边界；WP3b 的最大验收盲区仍在。
- 建议：至少给上述 4 个 Query 各加 3-5 条直接 SQLite 断言（空集、LIMIT/OFFSET 钳制、动态字段、跨 session、错误绑定），或在 final-report 明确写“WP3b 边界仅间接覆盖”。

## 4. P2（口径/基建尾差）

1. **schema verify 只验内存新建库，CI 没有独立 dump/sqlite3/迁移库复核**：`GatherSchema/main.swift:15-18` 明确“不打开磁盘库”；`ci.yml:85` 只跑 verify。`final-report.md:119` 的“dump 灌入内存 SQLite 独立复核 43/373/69/62”是本机一次性证据，不是 CI 门禁。建议 CI 追加 `gather-schema dump > /tmp/schema.sql` + `sqlite3` pragma 计数，或把该复核做成测试。
2. **test-catalog 不校验 skip 到期/数量**：`check-test-catalog.sh:83-95` 只匹配 owner/到期/原因文本，不比较日期，也不设 skip budget。3 条 `FaceRealPhotoPipelineTests.swift:42,66,80` 的“到期 2026-12-31”不会被任何门禁执行；到期后仍可永久 skip。
3. **没有测试数量/覆盖率 ratchet**：CI 只跑 `swift test`（`ci.yml:79,116`），没有 N tests 下限；删测试不会红。现状只能靠文档数字，而文档数字已漂移（P1-7）。
4. **GatherTestSupport 作为 library product 暴露，但只有测试链接**：`gather-core/Package.swift:50,105-113`、`gather-app/Package.swift:131`。结构可用；未发现 app 运行时链接。遗留风险是 `Tests/GatherTestSupport` 路径不符合 SwiftPM 常规“Tests 只放测试 target”的直觉，建议在 Package 注释/CI 中保持“只进测试链接”的断言（目前无自动化）。
5. **check-select-star 与 check-docs 的 strict 口径**：`check-select-star.sh:35` 默认 warning；CI 用 `--strict` 正确。`check-docs.sh:188-191` 的 `reviews>20 && archive missing` 规则当前不会触发（archive 存在），但 `final-report.md:129` 的“reviews 历史 14 篇”已过期（当前 `docs/reviews` 远超 20 篇）。
6. **CI release 的插件前置未自动化**：`ci.yml:237-243` 做插件存在/双切片/版本断言，但 `build.sh:395-396,420,562-566` 要求仓库根存在被 `.gitignore:33` 忽略的 Capture One SDK 与 `desktop/coplugin/Makefile`。hosted runner 不会自动安装 SDK，release 在 P0-1 之后还会在此失败。建议把“SDK 安装/路径”写成 runner 镜像步骤，或在 job 开头显式 preflight。
7. **CI 仍保留已取消的 `GATHER_RECONCILIATION_VECTOR` 开关，并重复跑同一套件**：`ci.yml:80-81` 用 `GATHER_RECONCILIATION_VECTOR=1 swift test --filter VectorIndexReconciliationTests`；但该门控随 5b-2a 取消、套件默认运行（`VectorIndexReconciliationTests.swift:12-13`、`Reconciliation/README.md:41`），全量 `swift test` 已含这 3 个 `@Test`。环境变量现在是 no-op，步骤只造成重复执行/误导。建议删除该 step，或改成“全量测试已包含”的注释。
8. **build.sh 的 release 前置本身是完整的**：`:89-101` 强制 universal + Developer ID + `GATHER_NOTARIZE=1`，`:145-148` 强制 version，`:420-566` 强制插件；这是当前配置下唯一可信的发布门。问题不在 build.sh，而在 CI runner 与凭据未提供。建议保持，不要为了“让 release 绿”放宽。
9. **测试计数口径未定义，汇总数无法从 `@Test` 声明直接复算**：静态 `@Test` 声明为 core **1,067** / app **622**（107/67 个测试文件）；主线程通报是 core 1,146 / app 624。差值 79/2 与参数化用例规模同量级（`SchemaV1Tests.swift:463,477` 的 43 个逐表列 + 30 个 CHECK case、`FaceKeywordingServiceTests.swift:200` 的 5 个参数、`IncrementalClustererTests.swift:267` 的 5 个 seed 等）。**疑似**：`swift test` 汇总行把参数 case 计入“tests”，而 `post-refactor-r7-tests.md:60` 写“参数 case 不计入”。建议在 DEVELOPMENT 定义“声明数/执行数/参数 case”的固定口径，并让报告同时给“函数数 + case 数”，否则 1,146/624 无法从源码复算。

## 5. 发布未验证项（必须单列，不得写成通过）

| 项 | 当前证据 | 状态 |
| --- | --- | --- |
| 签名 | `build.sh:625-691` 有签名/entitlement 回读逻辑；CI 仅 release job，未执行；本机无 `release/` 产物 | **未验证** |
| 公证 / staple / spctl | `build.sh:693-736`；CI `ci.yml:295-296`；无凭据/无成功 job | **未验证** |
| x86_64 运行期 | `build.sh:351-366` 只做 lipo 断言；CI 无 x86 运行；本机无 Rosetta 证据 | **未验证**（仅可能编译切片） |
| 插件双架构 / C1 加载 | `ci.yml:237-261` 断言；SDK 不在仓库、hosted runner 无安装；本机插件产物仅 arm64（`.arch-x86_64` 戳与二进制架构不一致，静态 `file` 显示 arm64） | **未验证** |
| GUI | 无 GUI 自动化；仓库无 GUI smoke job | **未验证**（与 `final-report.md:161` 一致） |
| universal app | 只有不可执行的 release job 设置 `GATHER_ARCHS=universal`；`gather-app` job 是 host 单架构 | **未验证** |

> 注：本机 `desktop/coplugin/GatherLink.coplugin/Contents/MacOS/GatherLink` 是 `.gitignore:23` 忽略的本地产物；`file` 静态显示 arm64，而目录里有 `.arch-x86_64` 戳，说明该产物不是可信的 universal 证据，不能用于发布。

## 6. 建议修复顺序

1. **先修 P0-1**：release runner 换成可提供 Xcode 26/SDK 26 的环境；在 runner 上装 Capture One SDK 到 `Capture_One_Plugin_SDK_(Mac)_v1.0.1`；跑一次完整 dry-run/tag，保存 artifact。未完成前状态写“发布验证未通过”。
2. **再修 P1-1/P1-2**：layering 补 `GatherDelivery`；core logger 捕获改为持 `stateLock` 或 core 串行；这两个直接决定门禁可信度。
3. **修 P1-7 文档数字**：以当前树一次性回填 final-report/status 的 core/app、ratchet、select-star、preview、test-catalog、protocol 数字，历史快照加横幅。
4. **补 P1-8/P2**：WP3b Query 直接断言、test-count/skip 到期 ratchet、schema dump+sqlite3 CI 复核。
5. **测试 flake 治理**：替换固定 20/50/150ms 断言；33 处 fire-and-forget stop 改为显式 await。

## 7. 本审计未执行 / 限制

- 未执行任何 `swift build/test`、`scripts/check-*.sh`、`gather-schema`、`build.sh`、`codesign`/`notarytool`/`stapler`；仅做 `ls`/`find`/`file` 元数据查看。所有“会失败/会通过”的判断来自代码路径与配置，不是实测。
- 未联网核对 GitHub runner 镜像的 SDK 上限；P0-1 的“macos-14 不提供 Xcode 26”依据仓库注释与既有验收报告（`final-sweep-release.md:56-62`），本审计按“配置必然要求 ≥26 而 runner 固定 macos-14”判定为失败路径，不依赖具体镜像版本。
- 未读取 CI secrets 是否存在；签名/公证结论只基于“job 从未成功执行”与“无 artifact”。
- 未做 GUI 人工验收；任何“界面正常/外观正常”的说法都不在本报告证据内。
