# 重构决策记录（2026-10-21）

> 配套：docs/reviews/refactor-design-breaking-2026-10-21.md、docs/test-audit.md、docs/refactor-progress.md
> 规则：每条决策记录背景、决定、影响、执行 Cut；后续如推翻需新增条目，不直接改写历史。

## D-001 Protocol 契约测试的处置

- 背景：core/Protocol 有 191 条测试，主要是“TS 字段名逐字一致”的 JSON 契约（CullingContractTests、SessionContractTests 等）。TS packages/shared 已不存在，JSON 命令面也将在 Cut 1 删除。
- 决定：
  1. **删除**所有命令参数键/JSON envelope/TS 字段名 parity 断言（约 160 条）。
  2. **保留并改写** DTO 的 Codable 往返测试（约 30 条），覆盖新 API 输入/输出、job checkpoint、delivery attributes 等仍会序列化的类型。
  3. ErrorLocalizationCoverageTests 保留 4 条思路，但改为 GatherError(code/params) + L10n.errorText 的契约，不再按旧 errorMessage 字符串。
- 影响：Protocol 测试 191 → 约 30；Cut 1 与 API 协议同 PR 完成，不保留旧契约测试。
- 执行：Cut 1（Agent Test 负责）。

## D-002 skip / disabled baseline 口径

- 背景：progress ledger 的“98”来自 grep 命中 withKnownIssue/.disabled 的字符串（含注释），不可复现。
- 决定：采用源码级口径：**.disabled = 0；withKnownIssue = 0；.enabled(if:) = 4 处，默认跳过 8 条**（VectorIndexReconciliationTests 整组 5 + FaceRealPhotoPipelineTests 3）。所有默认跳过的用例必须写到期条件；Cut 6 门禁按此口径统计。
- 影响：docs/cleanup-baseline.json 与 check-test-catalog.sh 必须用“声明级”计数，不能 grep 注释；progress ledger 基线更正。
- 执行：Cut 0（立即修正 baseline）。

## D-003 迁移测试与旧库入口

- 背景：MigrationTests 10 条、makeMigratedDB 是 57 个用例/17 个文件的单点入口；SchemaV1 删除迁移链后这些用例不能原样保留。
- 决定：不保留迁移版本测试；把 makeMigratedDB 改名为 makeTestDatabase，内部直接建 SchemaV1 内存库；57 个用例改为在新库上验证行为，不删除其业务断言。仅删除“版本升级/回滚/旧 schema 同形”类用例。
- 影响：Cut 2 测试改造范围明确；避免误删 57 个行为用例。
- 执行：Cut 2（与 SchemaV1 同 PR）。

## D-004 可立即执行的安全清理

- 背景：test-audit 标记了与 Cut 1/2 无关、可立即做的清理。
- 决定：Cut 0 内先做三项：
  1. LockedBox/ResponseBox/AsyncGate/JobEventSink 收进 Tests/Support，删除三份 LockedBox；
  2. FaceEmbeddingFingerprintTests 写 home 的用例改临时目录；
  3. 4 处 .enabled(if:) 增加到期条件注释。
- 不触碰命令面、迁移、outbox/writeback、语言锁相关测试。
- 执行：Cut 0（Agent SafeCleanup）。状态：done；app 298 tests、core 受影响 121 tests 绿；asleep 跳过条件未改。

## D-005 清理 baseline 的“声明级”计数

- 背景：grep 计数会把注释、字符串、测试 helper 算进去，导致 ratchet 失真。
- 决定：check-cleanup-ratchet.sh 对 @unchecked Sendable、prepare(、try? 等使用“语法行 + 排除注释/字符串”的近似计数；baseline 由脚本生成并在 docs/cleanup-baseline.json 记录口径（脚本版本号 + 命令）。
- 影响：C 的 baseline 需在 Cut 0 结束前复核；不一致时以声明级口径为准。
- 执行：Cut 0（Agent Gates）。

## D-006 清理 ratchet 的扫描范围

- 背景：初版 check-cleanup-ratchet.sh 只扫 gather-app/Sources，漏掉 Culling/Settings/Export/Duplicates/FaceKeywording/ControlCenter 六个功能页目录；baseline 因此偏低（unchecked 39、try? 320）。
- 决定：ratchet 的 unchecked_sendable / try_optional / todo_fixme 必须同时覆盖 gather-app 功能页目录；已修正脚本并重新生成 baseline：unchecked 40、try? 348、services prepare 128、TODO/FIXME 0、withKnownIssue 0。
- 口径：只统计非纯注释行；指标下降后才允许手动 --write-baseline 收紧，并在 PR 说明下降原因。
- 影响：Cut 4/5 迁入 GatherUI 后，路径变化需同步调整脚本 scope；Cut 6 以本 baseline 作为防腐起点。
- 执行：Cut 0（已完成）。


## D-007 API 输入类型的来源

- 背景：Protocol 下 99 个 *Params DTO 零外部引用，但字段与 Router 手工解析的参数高度重合；Router 用 requiredString 逐键解析，从未构造这些 DTO。
- 决定：
  1. 不盲删 99 个 Params。Cut 1 先做逐条对照：字段、可选性、默认值、范围与 Router 一致的，直接作为 API 输入类型复用。
  2. 形状不一致或语义不清的，在 GatherProtocol/API 下新建输入类型，不复用旧 DTO。
  3. Cut 1 结束后删除未被复用的旧 Params；保留者必须有 API 引用与 Codable 往返测试。
- 影响：API 输入类型以“语义正确”优先，不以“少写文件”优先；D-001 的 30 条 DTO 测试覆盖保留者。

## D-008 smart_albums / workflow_templates 的取舍

- 背景：两套能力只有 Router 的 album.* / template.* 可达，UI 0 调用；Template 在 ROADMAP 4.2 有 UX 待办，Album 无明确排期。
- 决定：暂不删除。保留 TemplateService / SmartAlbumRepo 与两张表，Cut 1 提供 typed API（无 UI），不计入“死代码”删除指标；Cut 6 再评估，若无入口再按清理规则删除。
- 影响：Cut 1 的 API 方法数比“只做已接线功能”多约 12 个；换取未来功能不返工。

## D-009 测试计数口径

- 运行时：core 994 / app 298（swift test 自报）。
- 源码 @Test：core 994 / app 301（部分参数化用例运行时计数不同）。
- 决定：CI 验收与“测试是否全绿”用运行时数；清理审计与删除/合并账用源码 @Test 数。两处数字不一致时注明口径，不互相覆盖。
- 清理目标：core 约 761 / app 约 253（源码口径）；运行时目标在 Cut 1 后重新记录。

## D-010 参数错误码

- 背景：Router 有 111 处 requiredString 抛 MISSING_PARAM 字符串，GatherErrorCode 无对应项；177 项冻结测试会阻止新增。
- 决定：新增 GatherErrorCode.INVALID_PARAM 与 PHOTO_NOT_FOUND（179 项），params 携带 field；删除“177 数量冻结”断言，保留本地化覆盖测试并为新码补 zh/en 文案。MISSING_PARAM 不再单独建码，统一为 INVALID_PARAM(field=...)。
- 影响：Cut 1 类型化解码统一抛 GatherError(.INVALID_PARAM, params: ["field": ...])；ErrorCodeContractTests 已更新为 179 项，app 本地化覆盖测试通过。
- 执行：Cut 1（与 API 协议同 PR）。状态：done（core 21 tests + app 4 tests 绿）。

## D-011 Confirmed 的构造与安全边界

- 背景：方案要求 Confirmed<T> init internal，但 UI 与 API 跨模块无法构造；Router 旧 confirmed: Bool 本来也不是安全边界。
- 决定：Cut 1 采用“调用点标记”而非密码学门禁：
  1. Confirmed<T> 定义在 API 模块，public init(_ value: T, source: ConfirmationSource = .userDialog)；
  2. ConfirmationSource 为 enum（userDialog / automation / test），仅用于审计与测试；
  3. API 不接收裸 Bool；破坏性方法只能接收 Confirmed<T>，从类型上消除“忘记确认”；
  4. 代码评审与测试保证只有确认弹窗/自动化入口构造 Confirmed；不在 Cut 1 引入 token/ledger。
- 影响：跨模块可构造，Cut 1 不被可见性阻塞；若未来需要防误用，再引入 ConfirmationGate token。

## D-012 Router 校验缺口的处理

- 背景：api-migration-map §6.3 确认 G1-G10：optionalNumber 静默 nil、Int(double) 截断、groupingMode 静默回退 global、sim.writeback 丢弃非法 itemIds 等。
- 决定：Cut 1 不原样搬运，按“显式失败”修复：
  1. 数值类型不符/非有限 -> INVALID_PARAM，不静默 nil；
  2. Int 转换先范围检查，禁止 trap/截断；
  3. 枚举未知值 -> INVALID_PARAM，不静默默认；
  4. 数组元素非法 -> INVALID_PARAM，不静默丢弃；
  5. 每条修复配一个 API 行为测试（错误路径）。
- 影响：与旧行为有意不同，记录在 Cut 1 清理账与 ADR-031；UI 若依赖旧静默行为，在 UI 迁移时修正。
- 执行：Cut 1（B1-B8 各批随域修复）。

## D-013 SchemaV1 最终形态（Cut 2 前置设计）

- 依据：docs/archive/cuts/schema-v1-draft.md（1598 行，sqlite3 3.54 验证通过）。
- 数量：44 表 → 43 表；396 列 → 370 列；62 索引 → 69 索引；63 FK → 62 FK（56 CASCADE + 6 SET NULL）。
- 删除：asset_file_metadata、schema_version；metadata_outbox/metadata_outbox_sessions/writeback_items 替换为 deliveries/delivery_sessions/delivery_items/delivery_intents。
- 修正：assets.status 不是死列（写 offline_unverified/orphan 且被 WHERE 使用），保留；backlog 的 391 列是行级漏计，实际 396。
- 偏离方案 §4.3 的四处（采纳）：
  1. deliveries 用 id 代理主键 + xmp_path UNIQUE（xmp 改名不连带删子行）；
  2. deliveries 增 photo_path；
  3. 去掉 source_module（归属由 delivery_items.module 表达）；
  4. persisted_revision 合并进 revision。
- 必须配套的四个缓解：
  - R1 列级对账：42 处 SELECT * 改为显式列清单；为 43 表逐列断言，禁止按位置读行。
  - R2 用户数据 FK：role_bindings / 人工绑定禁止 CASCADE；用 SET NULL 或 RESTRICT，避免重聚类静默删除用户绑定。
  - R3 CHECK 与 enum：现存 "indexed" 不在枚举内；把 indexed 加入 PhotoStatus（或迁移为现有值），否则 CHECK 会让既有写入抛错。
  - R4 旧库重置：移走 db 时必须同时移走 -wal/-shm；首次启动一次性提示，并把重置记录写入 app_settings。
  - R5 交付切换：新 delivery 表与旧 outbox/writeback 不得双写；同一 PR 删除旧表/Repo/测试。
- 执行：Cut 2。状态：设计完成，待实现。

## D-014 UI 不得直接依赖 GatherAnalysis

- 背景：module-split-map E-04 发现 PhotoThumbnailView 直接调用 RAWDecoder（UI→Analysis）。
- 决定：不开 UI→Analysis 白名单。新增 ImageDecoderPort（GatherProtocol）：decodeThumbnail/preview/dimensions；由 GatherAnalysis 实现、GatherHost 注入 UI。UI 只依赖 Protocol。
- 影响：Cut 3 增加约 1 人日；PhotoThumbnailView 的三个调用点改为 port。UI 的 import 规则保持干净。

## D-015 GatherSchema 去留

- 决定：保留 GatherSchema 可执行 target（schema dump/verify 是 Cut 2/6 的验收工具），依赖 GatherPersistence。不进 app bundle、不对外分发。
- 影响：Package.swift 多一个 executable target，CI 增加 schema-diff job。

## D-016 GatherCoreHelper / IPC 退役

- 背景：HelperProtocol 与 helper 可执行仅测试/线协议使用；IPC 同时横跨 SessionData 与 RAWDecoder。
- 决定：Cut 3a 先审计 GatherCoreHelper 的所有调用方；若无生产调用，删除 helper + IPC 目录 + 相关测试；若仍需要，IPC 整体移入 GatherProtocol（不留在 Analysis），并只依赖 Protocol。
- 影响：预计净删 3 文件/259 行 + helper 测试；清理账计入 Cut 3。

## D-017 RootView 归属

- 决定：Cut 3 保留 RootView 在 GatherHost（它持有 Live providers/AppServices）；Cut 4 再把 Shell 与页面迁入 GatherUI，Host 只留装配与 Bridge。
- 影响：Cut 3 的 GatherUI 只包含页面/VM/Support/Resources，RootView 仍是 Host 入口；Cut 4 再调整。

## D-018 测试 target 拆分

- 背景：makeMigratedDB 被 27 文件跨 Persistence/Analysis/Domain 使用，114 个 @testable 文件；一次拆 4 个测试 target 会同时红。
- 决定：Cut 3 只拆生产 target；测试保持单一 GatherCoreTests + 新增 GatherTestSupport（library target，放 makeTestDatabase/LockedBox/AsyncGate 等共享夹具）。GatherAppTests 依赖 GatherUI + GatherHost。四路测试 target 延后到 Cut 6，确认稳定后再拆。
- 影响：测试仍可 import 所有 core 模块；生产依赖边界由 --explicit-target-dependency-import-check 保证。


## D-019 AppServices 注入方式

- 背景：B1 初始方案用 AppServices.current 全局注册表绕过 RootView 构造，属于服务定位器；且 bootstrap 新建 SettingsService 会与 Router 私有实例形成双缓存。
- 决定：
  1. 禁止全局 AppServices.current；RootView 增加 let appServices，显式传给 SettingsView/SessionControlView；
  2. SessionCommandRouter 的 settingsService 临时改为 public let（B8 删除 Router 时一并移除），AppServices 复用它，不新建第二个实例；
  3. Dashboard 保留旧 services init 仅供既有测试，生产路径走 SessionAPI/JobAPI；
  4. B2-B7 扩展 AppServices 时同样显式注入，不引入服务定位器。
- 影响：RootView/Router 各有一处最小改动；B8 清理；避免双缓存与隐藏依赖。
- 执行：Cut 1 B1。

## D-020 RAW 分支点号修复

- 背景：RAWDecoder 的无点 ext 与旧 PhotoRepo.rawExtensions 的带点表比较，导致 RAW 区域解码分支从未命中，CIRAWFilter 一直未生效。
- 决定：修复。PhotoFileTypes.isRAW 内部规范化（trim、去前导点、小写），对 "nef"/".nef"/" cr2 " 一致返回 true；RAWDecoder 用无点 ext 调用；保留 CIRAWFilter 失败回退 CIImage。
- 影响：行为变更——RAW 区域解码首次真正走 CIRAWFilter；本机无 RAW fixture，方向/渲染需人工用 NEF/CR2 验证，写入 Cut 3 风险。
- 执行：Cut 3a E-01。

## D-021 删除 sessions.writeback_status，状态改为派生

- 背景：SchemaV1 已删除 sessions.writeback_status（draft §2.4）；S2 的 confirm 无法写入不存在的列。
- 决定：交付状态唯一真相源是 deliveries/delivery_items；会话级 writeback_status 由聚合查询派生（pending/writing/written/failed/conflict/cleaned 计数 → done/partial/cleaned）。
- 影响：
  1. DeliveryRepo.confirm 只推进 delivery/item 状态，不再写 session 列；
  2. SessionData/SessionRow 的 writebackStatus 改为读取时派生（JOIN/子查询或 DeliveryRepo.summary）；
  3. Culling/ControlCenter 的同步摘要改读 DeliveryRepo.summary；
  4. 旧 SessionRepo.updateWritebackStatus 在 Cut 2 接线时删除。
- 执行：Cut 2 接线；S2 已留 TODO 与派生 SQL 注释。

## D-022 ScanPath 下沉与 E-02 残余

- 背景：E-01/E-02 完成后，Database/ 仍有 8 处引用 Services/IndexerService.swift 的 ScanPath（按文件归属仍是 Persistence→Domain）；DuplicateService 仍调 deprecated IndexerService.sha256File。
- 决定：
  1. 把 ScanPath 整体移到 GatherPersistence（Database/ScanPath.swift），TSPath 已在 RepositorySupport；IndexerService 只保留调用。
  2. DuplicateService 改用 FileHasher.sha256File，消除 deprecation warning。
  3. PhotoAssets.swift:12 的 AssetRepo.rawExtensions 别名留到 Cut 3a 清理（domain→persistence 合法但重复）。
- 影响：拆 target 前 Persistence 不再依赖 Domain 文件；E-02 真环彻底断开。
- 执行：Cut 3a 前置。

## D-023 Delivery S2 范围与 S3 待办

- 背景：S2 完成 DeliveryState/DeliveryRepo/confirm 与 19 条测试；intents/cleanup 回放、mergeInput、item 并发语义未做。
- 决定：
  1. confirm 不写 sessions.writeback_status（D-021，列已删；会话状态读取时聚合派生）。
  2. S3 实现 delivery_intents 回放（prepared 重做文件+DB、fileDone 只补 DB、applied 删除 intent）与 DeliveryCoordinator；在接线前完成。
  3. S3 增加 DeliveryRepo.mergeInput(expectedRevision:) 表达新输入/revision 推进；createOrGet 保持“已存在不覆盖”。
  4. delivery_items 不做 revision CAS，接受 last-writer-wins（投影数据；真源是 deliveries 的 revision CAS）；在 ADR-034 写明。
  5. DeliveryRepoError 暂不映射 GatherErrorCode；Cut 2 接线时由 API 边界转 GatherError，必要时再补码。
- 影响：S2 不接线、不双写；S3 完成后才能切换生产路径。
- 执行：Cut 2 S3。

## D-024 D-010 导致的旧负例修正

- 背景：LibraryViewModelTests.userFacingTextTranslatesParameterizedCode 用 "INVALID_PARAM:limit" 作为“未知码”负例；D-010 后 INVALID_PARAM 已成为已知码，负例失效。
- 决定：负例改为真正未知码 "UNKNOWN_CODE:limit"，保留“未知码走通用文案、不猜参数”的原意；不放宽码形门槛。
- 影响：仅测试夹具变化，产品行为不变。
- 执行：Cut 1 B1 收尾。

## D-025 用户数据 FK 策略

- 背景：R2 审计发现 role_bindings.cluster_id 在 SchemaV1 中为 CASCADE，重聚类/删簇会静默删除用户绑定；绑定同时是 XMP 人物关键词清理凭据。
- 决定：
  1. role_bindings.cluster_id 改为 ON DELETE RESTRICT；删除 session/cluster 前必须显式迁移或删除绑定。
  2. 其他用户数据边（matched_person_id 等）用 SET NULL，不 CASCADE。
  3. SchemaV1Tests 增加“删簇被 RESTRICT 拒绝”与“删 person 置 NULL”用例。
- 影响：SessionService.deleteCascade 需显式处理 role_bindings；Cut 2 接线时补。

## D-026 SELECT * 与位置读取

- 背景：R1 审计实测 41 处实际 SELECT *（非 42）、40 处位置读取、0 处按列名；V1 会改变 10 处行形，face_observations 少 2 列、photos 少 2 列。
- 决定：Cut 2 接线前，41 处全部改显式列清单；优先 P0：FaceObservationRow(row[18]) 越界、PhotoRow(row.count>=16) 守卫。
- 影响：Repo 行映射从位置改为按列名/显式索引；新增逐表列数测试。

## D-027 CHECK 与生产值

- 背景：asset_members.binding_source 生产写 auto_raw_jpeg，不在 V1 CHECK 内，RAW/JPEG 合并会抛 CHECK failed；indexed 仅测试写。
- 决定：CHECK 补齐所有生产值（auto_raw_jpeg），indexed 加入 photos.status 或迁移旧值；新增 enum↔CHECK 双向测试，禁止再出现“代码写得出、DB 收不下”。
- 执行：Cut 2 S1 修正 + 接线前验证。

## D-028 Cut 2 接线门禁（来自 R1/R2/R3 审计）

- 背景：schema-v1-risk-audit 给出 24 条可执行项，其中 10 条 P0。
- 决定：Cut 2 接线前必须满足：
  1. DB 层新增 NamedRow/queryNamed/decoded(by:)，41 处 SELECT * 全部改显式列；scripts/check-select-star.sh 对 Sources 0 命中。
  2. P0 行形修复：PhotoRow 14 列、FaceObservationRow 17 列（删 sourceFileSize/Mtime 或 JOIN）、FaceClusterRow、SessionRow。
  3. 旧表读点随旧表删除：MetadataOutboxRepo/WritebackRepo/CullingService 不得平移到 deliveries。
  4. SchemaV1Tests 增加列名/列序/NOT NULL/默认值快照 + 删除矩阵。
  5. R3-01 auto_raw_jpeg 正向写入测试；R3-02 TemplateService fixture 改 completed，不把 indexed 加进 SessionStatus。
  6. R2-02 person_photos.photo_id/session_id 改 RESTRICT；R2-04 feedback.person_id SET NULL；R2-05 matched_person_id SET NULL 时 status='unbound'。
- 执行：Cut 2 S4/S5；清单见 docs/archive/cuts/schema-v1-risk-audit.md §4。

## D-029 ScanPath 下沉后的 target 归属

- 背景：D-022 完成，ScanPath 定义仅在 Database/ScanPath.swift；全仓 84 次引用。
- 决定：
  1. Package.swift 声明 GatherDomain → GatherPersistence（Services 4 文件使用 ScanPath，合法宽边）。
  2. SessionCommandRouter.swift:707 引用 ScanPath，Cut 3 必须归 GatherHost（Host 可 import 全部 core）；禁止归 GatherUI。
  3. Database 注释中 5 行提及 IndexerService（Migrations/AssetRepo/FileHasher/ImageCache）在 Cut 6 清理；ImageCache:3 的“生产调用”描述已失真。
  4. PhotoAssets.swift:12 的 rawExtensions 别名与 IndexerService.sha256File deprecated 别名在 Cut 3a 删除。
- 影响：Cut 3a 的 Package.swift 依赖表与 target 归属以此为准。

## D-030 B1 完成与残余 Router 路径

- 背景：B1 完成 Session/Job/Settings 的 Live API 与 3 个调用方迁移；app 309 tests 绿。
- 决定：
  1. GatherApp.importFiles、prepareNativeEmbeddingRerun 仍直连 service，B2/B5 处理；B8 前清零。
  2. SettingsView 的 session.list/culling.sync_status、ControlCenter 的 session.get/workspace.status/culling.sync_status/index.scan/quality.analyze 留给对应批次。
  3. SettingsViewModel/SessionControlViewModel 的 Router 兼容分支仅测试使用，B8 删除。
  4. LiveDashboardDataProvider 旧 services 构造器仅测试，B8 删除。
  5. 非域错误（DBError 等）在 API 边界暂回退通用文案；后续补 unspecified 或域内码。
  6. clearCompleted 的 Confirmed 来源标为 .userDialog 但无弹窗；D-011 允许，B8 前复核。

## D-031 mergeInput 必须重开状态

- 背景：S3 的 mergeInput 只推进 revision/photo_path/base，不改 status；written/synced 行收到新输入后仍停留旧状态，confirm 可能误判已写。
- 决定：
  1. DeliveryState 增加 synced→pending（以及 written/failed/conflict→pending）合法迁移；
  2. mergeInput 在 revision 推进成功后把 status 置 pending（cleaned 除外），items 不动；
  3. 增加测试：written→merge→pending、synced→merge→pending、CAS 失败不变、cleaned 拒绝。
- 执行：Cut 2 S4a（与 NamedRow 同批）。

## D-032 Cut 2 S4 拆分

- 决定：R1 的 41 处 SELECT * 不一次改完。S4a 只做基础设施与 P0 前置：
  1. DB 层 NamedRow/queryNamed/decoded(by:)；
  2. DeliveryState/mergeInput 状态修复（D-031）；
  3. scripts/check-select-star.sh（Sources 0 命中，Tests 白名单）；
  4. 为 PhotoRow/FaceObservationRow/FaceClusterRow/SessionRow 写 V1 列映射单元测试（用 SchemaV1 内存库），不改旧 Repo 生产查询。
- S5 再做 schema 切换与 41 处查询改写（Database.open→SchemaV1、makeTestDatabase、旧表/旧列读点删除）。这样避免“改 mapper 但测试仍跑旧 schema”的夹生状态。

## D-033 SchemaV1 风险修正最终状态

- FK 62 条：RESTRICT 3（role_bindings.cluster_id、person_photos.photo_id/session_id）、SET NULL 7、CASCADE 52；person_embeddings 三列保留 CASCADE（派生可重建）。
- CHECK：asset_members.binding_source 已含 auto_raw_jpeg；photos.status 不加入 indexed（唯一写入点是 TemplateServiceTests 的 sessions.status，已改为 completed）。
- SchemaV1Tests：17 tests 绿；含删簇 RESTRICT、auto_raw_jpeg 正向、photos 拒绝 indexed、person_photos RESTRICT、feedback SET NULL、embeddings 级联。
- 行为提示：V1 接线后，删除 session/photo 前必须显式删除 role_bindings 与 person_photos，否则 FK 报错；SessionService.deleteCascade 需按此改造。
- 未做：R1-07 列名/列序快照、R3-05 enum↔CHECK 生成；S4a/S5 处理。

## D-034 matched_person_id SET NULL 与审计后续

- 背景：face_clusters.matched_person_id 为 SET NULL；删 person 后簇可留 bound + NULL。TemplateServiceTests 的 indexed 夹具已在审计后修正。
- 决定：
  1. 不用触发器；Cut 2 S5 在解除身份时显式 UPDATE face_clusters.status='unbound'，并加“删 person 后无 bound+NULL”测试。
  2. person_embeddings.photo_id/session_id 保留 CASCADE（派生向量可重建），加删除后无残留测试。
  3. TemplateServiceTests 已改 completed，11 tests 绿；审计正文旧状态以 addendum 为准。
  4. R1 的 41 处 SELECT * 仍由 S5 处理，是 Cut 2 最大阻塞。

## D-035 Cut 2 S5 前置：Database facade

- 背景：S4a 完成 NamedRow/mergeInput/check-select-star/V1 行映射；但生产仍走旧 DBConnection + MigrationRunner，SchemaV1 未接入。
- 决定：S5 前先实现 Database facade（B-1）：
  1. Database.open(at:)：user_version 0→建 SchemaV1；≠1→移走 db/wal/shm 并新建；:memory:→SchemaV1；
  2. read/write/async 作用域（先单连接+锁，读池延后）；
  3. typed DatabaseError（busy/constraint/io/corrupt/closed/schema/misuse）；
  4. 测试：fresh 建库、旧库重置连 -wal/-shm、内存库、读写/嵌套事务。
- 影响：S5 再切换 Repos/测试到 Database + SchemaV1；旧 Repo 在 S5 内一次性改造。
- 执行：Cut 2 B-1。

## D-036 B2 的 Router 依赖临时暴露

- 背景：B2 需要 PhotoRepo/FilterEngine/NavigationService 等实例装配 Live API；Router 原为 private。
- 决定：
  1. 接受 7 个依赖改模块内可见，但必须标注 deprecated（“B8 删除 Router 前仅用于 AppServices 装配”）；
  2. AppServices.live(router:) 是组合缝；B8 时改为 AppServices.init(database:...)，删除 Router 与这些 accessor；
  3. 不新增 public 依赖访问器；若后续再需要，改为单一 CoreServiceBundle，不逐个开口；
  4. GatherApp 的 provider init 变化接受，旧 4 参 live 删除。
- 影响：B8 清理清单增加 7 个 accessor 与 live(router:)；在此之前不得让 UI 直接使用这些 accessor。

## D-037 B-1 完成与 S5 前置

- Database facade 完成：9 tests 绿；open/:memory:/user_version 重置（含 -wal/-shm）/read/write/async/close/DatabaseError 全通过。
- S5 主切换不能先于 DeliveryCoordinator：SchemaV1 已删 metadata_outbox/writeback_items，旧服务仍依赖它们；直接切库会让写回/同步链路失效。
- 决定：先完成 DeliveryCoordinator（confirm/cleanup/intent 回放 + XMP 文件阶段），再执行 S5（Database.open→SchemaV1、10 处行映射、旧表删除、Repo/测试切换）。
- 执行：Cut 2 S4。

## D-038 Database facade 风险接受

- B-1 完成：9 tests 绿；open/read/write/async/reset/typed error 全部落地。
- 接受项：
  1. read/write 共单连接（读池延后），长读会阻塞写；S5 后按基准决定是否启用读池。
  2. 重置会移走旧库（含 -wal/-shm），旧数据只能人工恢复；R4 的 UI 提示在 Cut 2 接线时补。
  3. 每次 open 对 V1 库跑 foreign_key_check；大库启动延迟在 S5 基准中测量，必要时改为按需。
  4. .incompatible 保留 3 套的 prune 暂无独立测试，Cut 6 补。
- 不阻塞 S5；风险进入 Cut 6 清理/基准清单。

## D-039 B3 的 Router 可见性

- 背景：CullingService/db 为 private，AppServices 无法复用；新建第二个实例会产生双 MetadataSyncCoordinator/WritebackService（双定时器/双状态机）。
- 决定：仅把 cullingService 与 db 两处 private 改 internal，加“B3 临时、B8 删除”注释；不改命令 case/dispatch；不新建第二个服务实例。
- 影响：B8 清理清单增加这两处；B3b 迁移 CullingView 后仍是同一组合根。

## D-040 S5 预备完成

- 23 处 SELECT * 已展开为显式列（8 文件 + TableColumns.swift），列序与旧 DDL/row mapper 一致；1070 tests / 148 suites 全绿。
- 剩余 Sources 17 处：V1 行形 11（photos/face_observations/metadata_outbox×7/writeback_items/CullingService）+ Services 6（TemplateService×2、DuplicateService×4）；Tests 1（EXPLAIN 白名单）。
- check-select-star baseline 已从 40 收紧到 17；--strict 通过。
- S5 剩余工作：Database.open→SchemaV1、11 处行映射 + 17 处显式列、旧表/Repo/测试删除、SessionService 按 RESTRICT 顺序改造、DeliveryCoordinator 接线。

## D-041 B4 的 Router 可见性

- 背景：SimilarityAPI 的 result/writeback/confirm/cleanup 必须复用 Router 内同一份 SimilarityService/WritebackService；新建第二实例会破坏取消槽、互斥与 outbox 单实例语义。
- 决定：仅把 similarityService、writebackService 两处 private 改 internal，加“B4a 临时、B8 删除”注释；不改命令 case/dispatch/构造顺序；不新建第二实例。
- 影响：B8 清理清单增加这两处；B4b UI 迁移继续复用同一组合根。

## D-042 S5 分步：先做 V1 兼容行映射（仍跑旧 schema）

- 背景：S4 Coordinator 完成；S5 一次性切库仍被 Session/outbox/writeback 依赖阻塞。
- 观察：V1 的行映射改到“旧/新 schema 交集列”后，可在旧 schema 上先跑通，提前消除 R1 的 11 处行形风险。
- 决定：
  1. S5a 先改 PhotoRow（14）、FaceObservationRow（17）、FaceClusterRow（10）及其 SELECT 显式列；不删旧表、不切 Database.open。
  2. 旧 schema 多出的列不选；V1 切换时这些查询自然兼容。
  3. SessionRow（11）与 writeback_status 派生、outbox/writeback 删除留 S5b。
  4. S5b 再做 Database.open→SchemaV1 + delivery 接线 + 旧表删除。
- 影响：S5 被拆成两个可在旧 schema 上验证的步骤，降低一次性切库风险。

## D-043 S4 DeliveryCoordinator 完成与 S5b 待办

- S4 完成：confirm/cleanup/replay/sessionSummary 与 DeliverySummaryQuery，10 新测试、43 tests 全绿。
- 语义：confirm 单事务 + 跨会话返回 unconfirmedSessionIds；cleanup 指纹校验 + intent 前滚；replay 分 prepared/fileDone。
- S5b 必须补：
  1. String module → DeliveryModule 映射（culling/fkw/sim）；
  2. Database.open 后调用 replay()；
  3. reload_acked_at 门禁（§5.4-2）；
  4. cleanup 物理删行后派生状态 idle / cleaned 语义与 UI 文案；
  5. 旧 WritebackService/MetadataSyncCoordinator/MetadataOutboxRepo/WritebackRepo 删除与调用点切换。

## D-044 S5a 完成与 S5b 范围

- S5a：PhotoRow 14、FaceObservationRow 17、FaceClusterRow 10；读侧显式列；1080 tests / 149 suites 全绿。
- 剩余：
  1. 写入仍写旧列（PhotoRepo metadata/result、FaceRepo thumbnail_base64/member_count/source_file_size/mtime）→ S5b 删除。
  2. FilterEngine 仍 SELECT p.metadata,p.result 并按位置 6/7 读 → S5b 改显式列。
  3. SessionRow 14→11 依赖 writeback_status 派生与 delivery 表 → 留 S5c（切库+接线）。
  4. metadata_outbox/writeback_items 表消失 → S5c。
- 决定：S5b 只做“旧 schema 上可验证”的写侧与 FilterEngine 清理；S5c 再做 Schema 切换 + SessionRow + delivery 接线 + 旧表删除。

## D-045 B4a 完成与 RootView 冲突

- B4a：Face 13 + Similarity 10 方法、AppServices 扩展、13 tests；app 343 tests 绿。
- modelsStatus.provider 从 "coreml" 改为 "vision"（FaceProvider.vision），UI 只消费 modelsPresent；作为行为可见差异记录。
- B4b 需要改 RootView 传 appServices.face/similarity，但 B3b 正在改 RootView（CullingView 构造）；串行执行：B3b 完成后再启动 B4b。
- 期间 B5a（Duplicate/Quality）只改 AppServices/GatherApp/新 API，不与 B3b 冲突，可并行。

## D-046 B3b 完成与剩余 Router 调用

- B3b：CullingView/CullingViewModel 迁移到 CullingAPI；19 条 culling 命令（17 方法）+ 4 条 navigation 命令已切；343 tests 全绿，新增 7 tests。
- 保留的旧构造器（RouterCullingAPI/RouterNavigationAPI）仅为 LayoutBudget/CullingSyncFlow 测试接缝，生产 RootView 不走；B8 前迁移测试并删除。
- CullingView 剩余 Router：quality.analyze、jobs.list/cancel、metadata.conflicts/resolve_conflict、CaptureOneBridge.reloadMetadata、C1StatusCapsuleHost(router:)；由 B5/B6/B8 处理。
- 风险：迭代方法 async 后快速连击可能并发提交，由 revision conflict 兜底；GatherError 参数暂未插值；B8 复核。

## D-047 B5 的 Router 可见性

- 背景：DuplicateService/QualityService 为 private，AppServices 无法复用同一实例。
- 决定：仅 duplicateService、qualityService 两处 private 改 internal，加“B5a 临时、B8 删除”注释；不改命令分支；不新建第二实例。
- 影响：B8 清理清单增加这两处。

## D-048 S5b 完成与 S5c 分步

- S5b：PhotoRepo 写侧、FaceRepo 写侧、FilterEngine 显式列完成；1081 tests / 149 suites 全绿。
- S5c 分三步，避免一次切库把所有链路同时打断：
  1. S5c-1：Database.open → “V1 + 临时 legacy 表”混合 schema（outbox/writeback 暂留），测试夹具切到 mixed schema；验证 V1 表与旧服务共存。
  2. S5c-2：Culling/FaceKw/Similarity 接 DeliveryCoordinator；删除旧 WritebackService/MetadataSyncCoordinator/Repo 与其表。
  3. S5c-3：删除混合层，Database.open 只用 SchemaV1；更新测试夹具/快照。
- 前置：FaceKwService.refreshClusterMemberCounts 仍写 member_count，切库前必须删除（S5c-prep）。

## D-049 S5c-1 混合 schema 方案

- 目标：在不改生产 Database.open 的前提下，让测试跑“V1 + 临时 legacy 表/列”，提前验证 V1 行映射与服务共存。
- 混合内容：
  1. SchemaV1 的 43 表；
  2. 临时 legacy 表 metadata_outbox、metadata_outbox_sessions、writeback_items；
  3. 临时 sessions 列 writeback_status、import_source、failed_writeback_count（SessionRow 仍 14 列）。
- 测试 helper makeMigratedDB 改为创建混合库；删除迁移版本测试，保留 fresh/hybrid 测试。
- S5c-2 接 DeliveryCoordinator 后删除 legacy 表/列；S5c-3 生产切 Database.open→SchemaV1。
- 生产代码与 MigrationRunner 本步不动。

## D-050 B5a filtered 通过 / B6 预授权

- B5a：Duplicate 4 + Quality 2，17 tests / 3 suites 绿；全量 app 等 B4b 最终报告后跑。
- B6a 预授权：为复用 Router 内同一实例，允许把 exportService/metadataService/metadataSyncCoordinator（按实际需要）private 改 internal，加“B6a 临时、B8 删除”注释；不得新建第二实例；不改命令 case/dispatch。

## D-051 B5a 完成与 B5b 注意

- B5a：Duplicate 4 + Quality 2，全量 app 368 tests / 43 suites 绿；B5a 自身 17 tests。
- 行为差异：
  1. quality.results 对空白/超 10k photoIds 显式 INVALID_PARAM（旧 quality.get 允许空串，属收紧）；
  2. groupNotFound/memberNotFound 无 GatherErrorCode，保留 DuplicateServiceError；B5b UI 必须兼容非 GatherError；
  3. analyze 返回 AnalysisJobData（协议定义），无事件流；B5b 轮询沿用旧逻辑。
- B5b 待 B4b 释放 RootView 后启动；AppServices.duplicate/quality 已注入。

## D-052 S5c-1 不加生产兼容列

- 背景：混合 schema 测试暴露生产写侧仍写 V1 已删除列（analysis_runs.params/created_at、assets.capture_fingerprint、person_embeddings.face_bbox/quality、smart_albums.schema_version）。
- 决定：不通过 Transition ALTER 补兼容列；直接迁移 4 处生产写入到 V1 列（analysis_runs.params_json + created_at、删除 capture_fingerprint、删除 face_bbox/quality、schema_version→filter_schema_version）。
- Transition 仅保留 3 张 legacy 表 + sessions 3 列（S5c-2/3 删除）。
- 影响：避免把写侧缺口藏到 S5c-3；S5c-1 结束即验证 V1 写入形状。

## D-053 app 测试库切 V1+Transition

- 背景：S5c-1 把 SmartAlbumRepo 切到 filter_schema_version，app 测试仍用 MigrationRunner 建旧 schema，导致 no such column。
- 决定：app 测试统一用 makeGatherTestDB()：DBConnection(:memory:) + SchemaV1.sql + SchemaV1Transition.sql；不再用 MigrationRunner 建库。
- 影响：app 测试与 core 测试同库形；S5c-3 删除 Transition 后，helper 只 exec SchemaV1.sql。
- 执行：B4b 新增 helper 并替换；B5a/B6a 新测试复用。

## D-054 S5c-1 完成

- 混合 schema 测试完成：core 1074 tests / 148 suites 全绿（删 10 个迁移/同形用例，新增 3 个 fresh/hybrid/FK 用例）。
- SchemaV1Transition：3 张 legacy 表 + sessions 3 列 + 5 索引；metadata_outbox 必须按部署形态（v18 重建 + v27 追加 source_module 在列尾），不能直接用 Schema.swift 合并 DDL 的列序。
- 4 处生产写侧已迁移：analysis_runs.params_json + created_at、assets 去 capture_fingerprint、person_embeddings 去 face_bbox/quality、smart_albums 去 schema_version。
- 夹具修复约 20 处；skip 0；门禁通过。
- S5c-2：DeliveryCoordinator 接 Culling/FaceKw/Similarity 的 writeback/confirm/cleanup，删除旧 WritebackService/MetadataSyncCoordinator/MetadataOutboxRepo/WritebackRepo 与旧表。
- S5c-3：删除 Transition，Database.open 只用 SchemaV1。

## D-055 S5c-2 分两步

- S5c-2a：CullingService 的 confirmSync/finalizeSync/cleanup 接 DeliveryCoordinator（module=.culling），保留旧 writeback 计划路径；先验证单事务确认/清理/回放。
- S5c-2b：writeback 计划改 DeliveryRepo items，FaceKw/Similarity 同步；再删旧 WritebackService/MetadataSyncCoordinator/MetadataOutboxRepo/WritebackRepo 与旧表。
- 原因：confirm/cleanup 边界清晰、可先测；writeback 涉及 plan/patch/XMP 生成，单独处理。

## D-056 app 测试夹具不得写 V1 已删列

- 背景：app 测试 INSERT photos 仍带 metadata/result（Dashboard/Similarity/Library），V1+Transition 下报 no such column。
- 决定：测试夹具只写 V1 列；metadata 行为用 photo_metadata_cache 覆盖。Transition 不补 photos 兼容列（D-052）。
- 执行：B4b 修复 3 处 + 全量 grep；B5a/B6a 新测试遵守。

## D-058 B6a 完成与 B7 预授权

- B6a：Export 4 + Metadata 7，17 tests 绿；AppServices 八域；Router 仅放宽 metadataService/metadataSyncCoordinator。
- 行为收紧：report.format 改 ReportFormat；metadata tags 缺失/非对象解码期失败；preview/execute 缺省 options 仍抛 EXPORT_PARAMS_INVALID。
- 全量 app 仍有 9 个 photos.metadata 夹具失败，由 B4b 修（D-056），不是 B6a 回归。
- B6b（ExportView/LibraryViewModel/RootView）等 B4b 释放 RootView。
- B7a 预授权：personService/templateService 按需 private→internal，加 B7a/B8 注释；不新建第二实例。

## D-057 app 夹具已由父 agent 修复

- 修复 4 处：DashboardViewModelTests:189、SimilarityViewModelTests:318、LibraryViewModelTests:224、GalleryViewModelTests:195。
- 全部改为 V1 photos 列；grep app Tests 的 INSERT INTO photos 已无 metadata/result/checksum_file_size/checksum_file_mtime_ms。
- B4b 直接跑全量 app；Transition 不补列。

## D-059 B4b 完成

- FaceKeywording 13 + Similarity 10 条命令迁移；RootView 传 face/similarity/job；新增 10 条 UI API 测试。
- app 全量 387 tests / 45 suites 绿；测试库统一 makeGatherTestDB。
- Similarity 夹具保留 checksum_file_size/mtime（V1 photos 仍有这两列；删了会让 analyze 快路径失效），父 agent 的过度删除已由 B4b 纠正。
- 剩余 Router：Face 页 C1StatusCapsuleHost、Similarity 页 CaptureOneBridge；旧 router 构造器/适配器待 B8。
- B5b（Duplicates/ControlCenter）现在启动；B6b 等 B5b 释放 RootView。

## D-060 S5c-2a 不冒充 finalize

- finalizeSync 是“保留 XMP 并结束”（删 synced outbox + 备份，不恢复），cleanup 是“恢复原 XMP 后删”；两者不是别名。
- 决定：S5c-2a 只接 confirmSync + cleanup；finalizeSync 保留旧链路。S5c-2b 给 Coordinator 加 finalize(dropWithoutRestore) + intent 前滚，再切。
- 过渡期 syncStatus/flush/retry 仍读 outbox，confirm/cleanup 读 deliveries，会空转；S5c-2a 不可单独发布，必须与 S5c-2b 同版。
- confirm 失败门禁改为 delivery.failed → XMP_CONFIRM_INCOMPLETE；reload_acked_at 门禁 S5c-2b 必补。
- S5c-2b 头号项：writeback 写 deliveries、syncStatus 切 DeliverySummaryQuery、finalize 实现。

## D-061 B7a 完成

- Person 8 + Template 6 方法；5 tests 绿。
- Person 域无 PersonService，LivePersonAPI 直接依赖 PersonRepo（D-058 的 personService 实际是 personRepo）。
- apply invalidSessionStatus 无专用码，收敛 INVALID_PARAM(field=sessionId)，原消息进 underlying。
- 保持旧幂等：delete/merge/removePhoto/update 对不存在 id 仍 no-op。
- 新增收紧：空白 id、NaN threshold、负 limit/offset → INVALID_PARAM。
- 工作区并发：CullingService 在 00:53 被 S5c-2a 短暂改坏后恢复；B7b/B8 前需重跑全量。

## D-062 S5c-2a 完成与 S5c-2b 顺延

- S5c-2a：Culling confirm/cleanup 接 DeliveryCoordinator；finalize 留旧；core 1080/149、app 407/49 全绿。
- S5c-2b 是 writeback 执行器整体切换（WritebackService 的 preview/persist/execute 从 outbox 改 deliveries）+ finalize(dropWithoutRestore) + syncStatus/flush/retry 改 DeliverySummaryQuery + FaceKw/Similarity + 删旧服务/表，规模大且必须同版发布。
- 决定：先完成 Cut 1 剩余 UI/API（B6b/B7b/B8），让 app 达到 0 字符串命令；S5c-2b 作为 Cut 2 收尾专项，不与 Cut 1 并行改同一批 Service，避免双线互相打断。
- S5c-2a 不可单独发布；在 S5c-2b 完成前，生产仍走旧 schema/旧 writeback，混合 schema 仅测试使用。

## D-063 B5b 完成

- Duplicates/ControlCenter 迁移：duplicate.scan/groups/resolve/resolveMember、jobs.list/cancel/retry、quality.analyze、index.scan→JobAPI.start。
- RootView 传 appServices.duplicate/job/quality；错误统一 APIErrorPresentation；DuplicateServiceError 无码回落通用文案。
- 新增 15 tests；全量 app 407/49 绿（含 B7a 并行 5 条）。
- 剩余：ControlCenter session.get/workspace.status/culling.sync_status + C1StatusCapsuleHost；Duplicates 仅 C1StatusCapsuleHost；CullingView 的 quality/jobs/metadata 留 B6b/B8。
- B6b 启动：ExportView、LibraryViewModel(metadata.orphans/resolve_orphan)、CullingView(metadata.conflicts/resolve_conflict)、RootView。

## D-064 B6b 完成

- ExportView preview/execute/cancel/report → ExportAPI；execute 仅 confirmed 分支构造 Confirmed(.userDialog)，未确认本地拒绝；ReportFormat 进 ExportReportInput。
- LibraryViewModel metadata.orphans/resolve_orphan → MetadataAPI（async）；CullingView conflicts/resolve → MetadataAPI；RootView 注入 export/metadata。
- 新增 11 tests；app 418/50 绿。
- Library 的 MetadataAPI 是第二个无状态 Live 包装（同一 service/coordinator），因 GatherApp 不在可写范围；B8 改为 AppServices 注入。
- 剩余 Router：ExportView session.get/C1 胶囊；CullingView quality/jobs/C1/CaptureOneBridge/旧适配器；Library 0。
- command-surface 红项来自 RouterNavigationAPI 同步 execute("navigation.analyze")，B8 前改成 executeAsync 一行。

## D-065 B8 审计结论

- docs/archive/cuts/b8-router-removal-map.md（516 行）：118 命令 = 15 条生产 UI 字符串（19 处）+ 45 条仅测试/旧适配器 + 58 条无调用方。
- 剩余工作不在协议层（15+45 都有 typed API），而在：
  1. 组合根/运行时：JobService 启动、8 个 executor 注册、停机、reload ack；
  2. 同步 UI/provider 接缝：session.get/list、settings.get 等需 async 化；
  3. 以 CommandRouter/JSONValue 为骨架的 19 个测试文件；
  4. 6 个旧适配器（RouterCullingAPI/RouterNavigationAPI/RouterFaceAPI/RouterMetadataAPI/Legacy 等）。
- command-surface 的 navigation.analyze 红项是适配器同步 execute，不是误报；删除适配器后消失。
- B8 分步：B8a 运行时/组合根 + 剩余 session/settings 调用；B8b Culling/Export/C1 收口；B8c 删适配器/测试/Router/命令面脚本。

## D-066 B7b 范围

- PersonsViewModel 独立在 Persons/PersonsViewModel.swift，纳入 B7b 可写；不把 VM 塞进 View。
- GatherApp 仍构造 LivePersonsDataProvider 并传 RootView；B4b 先例：RootView 收下 legacy provider 但用 appServices.person 构造 VM，生产不消费，B8 删除 provider。
- GatherApp 本批不改。

## D-067 B8 审计最终与执行顺序

- b8-router-removal-map.md 559 行：118 = 15 生产 + 45 测试适配器 + 58 无调用；19 个测试文件依赖 CommandRouter/JSONValue。
- 三大阻塞：组合根/运行时（makeDefault/registerExecutors/prepareForTermination/jobService/db.close/reload ack）、6 处同步 UI/provider 接缝、19 个测试重写。
- 执行顺序按审计：B8.1 测试 → B8.2 UI → B8.3 组合根/运行时 → B8.4 删 Router/命令面。
- B8.1 分两批：B8.1a Culling/Face/Similarity 大型套件 + StubCommandRouter/RecordingCommandRouter；B8.1b 其余 13 个测试文件。

## D-068 B7b 完成

- PersonsViewModel 8 方法 → PersonAPI；delete/merge/removePhoto 用 Confirmed(.userDialog)；select async + selectionGeneration。
- RootView 用 appServices.person；legacy LivePersonsDataProvider 保留（GatherApp 构造、页面不消费），B8 随 Router 一起删。
- PersonsViewModelTests 18 条；app 430/50 绿（两次）。
- 风险：merge/removePhoto/searchPhotos 无 UI 入口；select 异步高亮毫秒滞后；legacy provider 仍被 command-surface 统计 5 条。
- B8.2a 等 B8.1a 测试迁移完成后启动，避免改 VM 同时改测试。

## D-069 B8.1a 完成

- 4 个测试文件（CullingSyncFlow/FaceKeywording/Similarity/LayoutBudget）迁 typed stub；65 tests/7 suites。
- 新增 B8CullingAPIStub/B8NavigationAPIStub/B8FaceAPIStub/B8SimilarityAPIStub；删除 JSONValue 响应表/命令名断言约 31 行。
- app 全量 436 tests / 51 suites 绿（基线 418，净 +18）；目标 4 文件对 StubCommandRouter 引用 0。
- 仍余 10 个测试文件 + StubCommandRouter 自身（20 处），B8.1b 处理；Gallery/Library 生产 provider 仍用 makeDefault，留 B8.2/8.3。

## D-070 B8.1b 完成

- 10 个测试文件/121 用例迁 typed stub；删除 StubCommandRouter（20 处引用归零），check-no-legacy meter 14→0。
- 新增 B8SessionControlRouter（58 行，唯一同步适配层：session.get/workspace.status/culling.sync_status）与 B8SettingsAPIStub（136 行）。
- app 全量 436/51 绿；默认并行仍有既有 appLanguage/全局通知 flake（与迁移无关，另立任务）。
- B8.2a 启动：ExportView/ControlCenter/SettingsView/Gallery 的 session/settings/workspace/culling.sync_status 接缝。

## D-071 B8.1b 完成与 B8.3a

- B8.1b：10 文件/121 用例 typed stub；StubCommandRouter 删除、引用 0；check-no-legacy 14→0；app 436/51 绿。
- 新增 B8SessionControlRouter（测试唯一同步适配层）与 B8SettingsAPIStub。
- B8.3a 启动：把 Router.registerExecutors 的 8 个 executor 抽到 Host/ExecutorRegistry，Router 暂时委托；不动 GatherApp 生命周期/AppServices。
- B8.2a 并行（Export/ControlCenter/Settings/Gallery 接缝），两者文件不重叠。

## D-072 B8.3a 完成

- ExecutorRegistry 356 行，10 依赖 + 8 executor；Router 3297→3041（-256），registerExecutors 仅委托。
- 等价性：237 行正文规范化 diff 仅 self.decodeJSON→decodeJSON；注册顺序/checkpoint/默认参数一致。
- 4 tests + 全量 app 440/52 绿。
- B8.3b 剩余：AppComposition/AppRuntime 生命周期、reload ack、AppServices runtime/sessionRepo、22 accessor 降级、GatherApp @State router 收口。

## D-073 B8.2b 完成

- CullingViewModel 注入 JobAPI/QualityAPI：quality.analyze 轮询 jobs.list，cancelQualityAnalysis 走 JobAPI.cancel；删旧 (sessionId:router:) 构造。
- Gallery retryIndex → JobAPI.start(metadataScan, dedupeKey 旧值)，删除 provider.retryIndex/router。
- RootView 传 job/quality；Culling 仅剩 C1 胶囊与 CaptureOne reload ack（B8.2e）。
- 4 新测试，app 444/52 绿；旧 router 构造删除属源码不兼容变更，测试已同步。
- B8.3b 拆分：b-1 AppRuntime 生命周期（不移动 makeDefault）；b-2 AppComposition 移动 24 服务构造。

## D-074 B8.2b 完成与 B8.2e

- Culling quality/jobs + Gallery index 全部 typed；质量轮询 500ms→JobAPI.list，cancel fire-and-forget；Gallery dedupeKey 保持；app 444/52 绿。
- 旧 (sessionId:router:) 构造删除，测试同步。
- B8.2e 启动：C1StatusCapsuleHost(router:) → C1StatusCapsule(culling:session:)，7 个调用点；B8.3b-1 并行（GatherApp/Router/AppServices），文件不重叠。

## D-075 B8.2e 完成

- C1StatusCapsuleHost(router:) → (sessionId:culling:onOpenSettings:)，7 个调用点全部替换。
- C1StatusService 持 CullingAPI，refresh 直调 syncStatus；失败静默置 failedToLoad；per-session generation 防旧响应；Host 无 router。
- 删除 Duplicates/Export/Culling/ControlCenter/Gallery/Similarity/Face 页面的 router 参数。
- 剩余 router：RootView 的 CaptureOneBridge 4 处；FaceKeywordingView legacy init；CullingView 文件内旧适配器类。
- 新增 7 tests；app 456/54 绿（含并行 B8.3b-1 5 条）。

## D-076 B8.3b-1 完成

- AppRuntime：start（ExecutorRegistry+jobService.start，幂等）、shutdown（stop→coordinator.shutdown→db.close，共享 Task）、recordReloadAck；shutdown 后 start 抛 alreadyShutDown。
- Router 持 runtime（同一 db/jobService/coordinator/executorDeps），prepareForTermination/recordReloadAck/registerExecutors 委托；AppServices.runtime。
- GatherApp 用同一 runtime start/shutdown；未移 makeDefault（B8.3b-2）。
- 5 tests + 全量 456/54 绿。
- B8.3b-2 剩余：AppComposition.make(db:) 承接 24 服务、runtime 由组合根构造、删 Router.runtime/22 accessor/六个 live(router:)、settings 走 SettingsAPI、jobService.start 收口。

## D-077 B8.2d/f 完成

- 删除 PersonsDataProvider/LivePersonsDataProvider（5 条 person 字符串命令）；GatherApp 不再构造/传参；RootView 只用 appServices.person。
- GatherApp Settings scene 改 typed SettingsView(session:settings:culling:)；删 settings.set/applyStoredInterfaceLanguage 字符串分支，启动语言走 SettingsAPI.get("ui_language")。
- 删 SettingsView 的 router 兼容 init；GatherApp 内 router.execute 归零。
- app 458/55 绿（新增 StartupLanguageTests 2）。
- 剩余 Router：RootView CaptureOneBridge 4 处 + Dashboard/Library/Gallery/Similarity legacy provider；GatherApp importFiles/prepareNativeEmbeddingRerun 仍用 router.sessionService/jobService。
- 既有 appLanguage flake 仍在（GlobalInfraTests 切 en 与并行套件冲突），建议后续 l() 显式语言或扩大 AppLanguageLock。

## D-078 B8.3b-2a 完成

- AppComposition 381 行：24 依赖 + runtime；make(db:) 逐字搬 makeDefault（coordinator.start/executorDeps），DB 仍 DBConnection+MigrationRunner。
- Router.makeDefault = AppComposition.make().makeRouter()；Router 内无服务构造；新增 internal init(...runtime:) 保证同一 runtime。
- AppServices.live(composition:) 唯一 assemble；6 个 live(router:) 暂留委托。
- GatherApp 一次 composition；6 tests；app 464/56 绿。
- B8.3b-2b 剩余：删 22 accessor（+2 临时）、AppComposition(router:)、6 个 live(router:)、GatherApp @State router、CaptureOneBridge/LiveLibrary/Gallery/Similarity provider/importFiles/embedding rerun 的 Router 依赖。
- check-cleanup-ratchet FAIL 是 B8 期间 baseline 漂移，净增 0；B8.4 后收紧。

## D-079 B8.3b-2b 完成

- GatherApp/RootView 去 router；CaptureOneBridge 用 runtime.recordReloadAck；Gallery/Library provider 改 typed API；删 LiveSimilarityDataProvider。
- AppServices 删 6 个 live(router:)；AppComposition 删 init(router:)/makeRouter（移到 TestSupport）；Router 24 字段全 private，删 convenience init/makeDefault/recordReloadAck/prepareForTermination/applyStoredInterfaceLanguage/registerExecutors，只剩 init + execute/executeAsync。
- app 464/56 绿（--no-parallel）；生产宿主/providers 0 Router 引用。
- 剩余：FaceKeywordingView 4 处、CullingView 3 处 legacy CommandRouter init；DashboardViewModel NativeCommandClient.userFacingMessage；Live* 注释。
- B8.4：删 Router/CommandRouter/NativeCommandClient、legacy adapters、CommandSurfaceRuntimeTests、AppCompositionTestSupport、check-command-surface.sh；Dashboard 改 APIErrorPresentation；命令面黄金清单清理。

## D-080 Cut 1 完成

- 删除 7 文件/3568 行：SessionCommandRouter、CommandRouter、NativeCommandClient、CommandSurfaceRuntimeTests、AppCompositionTestSupport、NativeCommandClientTests、check-command-surface.sh。
- 删除 legacy 适配器：CullingView 的 RouterCulling/RouterNavigation/RouterMetadata、FaceKeywordingView 的 RouterFace/RouterFaceJob/FaceLegacySyncLoading、Similarity 的 LegacySimilarityAPIAdapter。
- 0 字符串命令：grep execute(/executeAsync(/enqueue( = 0；app 内 CommandRouter/NativeCommandClient/WebResponse/StubCommandRouter = 0。
- app 455/55 绿（--no-parallel；-9 命令面/黄金清单/客户端测试 +4 漏斗）；core build 绿。
- check-no-legacy enforced 0（SessionCommandRouter/CommandRouter/WebResponse/NativeCommandClient 均 enforced）。
- 遗留：check-cleanup-ratchet FAIL（unchecked 59 vs 40、prepare 132 vs 128），B8 期间漂移，B8.5 审计；check-docs 有已删脚本路径 warning。
- 下一步：B8.5 文档/ratchet 收口，然后 Cut 2 S5c-2b。

## D-081 B8.5 收口完成（2026-10-22）

- 删除账复核：D-080 的 7 文件中，`git show HEAD` 实测合计 4,052 行
  （3,258+51+77+296+223+38+109）；D-080 的 3,568 = 生产 3 文件 3,386 + 脚本 109
  + 未进 HEAD 的 AppCompositionTestSupport 约 73，未计 3 个测试文件 557 行。以 4,052 为准确认。
- ratchet：`unchecked_sendable` 59→55；删除 4 个门面（LiveJobAPI/LiveDuplicateAPI/
  LiveMetadataAPI/LiveQualityAPI）上多余的 `@unchecked Sendable`（final + 全 Sendable
  依赖，协议继承已声明 Sendable，改由编译器检查）。保留 15：12 个 Live 门面
  （Repo/Service 非 Sendable）、LivePhotoPathPolicy、AppRuntime、JobObserverBag。
  `services_prepare` 132（净 +4 = DeliveryCoordinator 4 条 cleanup SQL + 1 个
  `intentRepo.prepare(`，减 FaceKwService 删除的 1 条）；SQL 是原子 cleanup 事务，保留。
  `try_optional` 348→287。baseline 已 `--write-baseline`。
- 文档：新增 `docs/archive/cuts/cut1-completion-report.md`；api-migration-map 标 16/110 已落地、
  B0-B8 完成；refactor-progress Cut 1 完成；cleanup-backlog CL-01 done；README/
  DEVELOPMENT/ROADMAP/ADR 的 Router/118 描述改为类型化 API；ADR-028 删除清单与
  check-command-surface 标“已删除”；b8-map/test-audit/brief 加历史横幅；
  module-split-map 脚本行改“已删除”。
- 门禁：check-docs 支持“已删除”历史行 + “当前 schema”声明（ADR 现声明 35）；
  `check-docs.sh` 与 `--strict` 均过；check-cleanup-ratchet OK；check-no-legacy OK。
- 测试：core 1080/149、app 455/55（--no-parallel）绿。
- 遗留：人工 GUI smoke 未做；15 处 @unchecked 与 132 处 prepare 需 Cut 2/3 继续收口。
  下一步：Cut 2 S5c-2b（writeback 执行器/finalize/syncStatus/FaceKw/旧表）。

## D-081 Cut 1 收口与 S5c-2b-1

- Cut 1 完成：0 字符串命令；Router/CommandRouter/NativeCommandClient 删除；app 455/55、core 1080/149；ratchet 55/287/132/0/0；docs/no-legacy/layering/duplicate 全绿。
- S5c-2b 分阶段：
  1. S5c-2b-1：Culling writeback 执行后把 items 镜像进 deliveries（过渡双写，2c 删除旧 writeback）；syncStatus/flush/retry 改 DeliverySummaryQuery；finalize(dropWithoutRestore)；reload_acked_at 门禁。
  2. S5c-2b-2：FaceKw/Similarity confirm/cleanup 接 Coordinator。
  3. S5c-2b-3：删 WritebackService/MetadataSyncCoordinator/MetadataOutboxRepo/WritebackRepo + legacy 表/列；S5c-3 纯 V1。

## D-082 S5c-2b-1 完成

- Culling writeback/retry 镜像 deliveries：revision 0/merge+1→pending；items module=.culling、status written/failed；base/backup 过渡从 outbox 抄。
- syncStatus 用 DeliverySummaryQuery.metadataSummary（一交付一行）；flush/retry 只跑 coordinator.replay。
- finalize：reload_ack 门禁 + intent .cleanup op=finalize + 删备份不碰 XMP + deleteSyncedDelivery 单事务；失败保留 intent。
- confirm/finalize 未 ack 抛 XMP_CONFIRM_REQUIRES_SYNC。
- core 1097/150 绿（+17）；ratchet try? 287、prepare 130（改善 2）。
- 2b-2：FaceKw/Similarity confirm/cleanup + 镜像。2b-3：writeback 执行器整体切 deliveries、删旧服务/表、Database.open replay、纯 V1。

## D-083 S5c-2b-2 完成

- DeliveryModule 映射：face_kw/face-keyword→.faceKeyword（落库 face-keyword）、similarity→.similarity；未知 nil。
- FaceKw/Similarity writeback 镜像 deliveries/items；confirm/cleanup 走 DeliveryCoordinator；错误码保持。
- core 1113/154 绿；ratchet 287/130 不升；门禁通过。
- 风险：LiveSimilarityAPI 仍直调 WritebackService（2b-3 改接 SimilarityService）；旧 outbox 停在 written 可能触发 WRITEBACK_OTHER_MODULE_ACTIVE，2b-3 必须同版删旧表/门禁；FaceKw unbind 关键词移除未纳入交付。
- S5c-2b-3a：WritebackService 持久化层从 writebackRepo/outbox 改 DeliveryRepo；2b-3b 删旧服务/表、Database.open→V1、启动 replay。

## D-084 S5c-2b-3a 完成

- WritebackService 持久化层改 DeliveryRepo：preview/execute/persistAttributes/retryFailed/confirmSync/cleanup/getItems 全部走 deliveries/items；删 writebackRepo/outboxRepo/SessionRepo 依赖。
- 真实文件写入/备份/校验不变；execute 抢租约、两阶段、逐项 written/failed；confirm 单事务；cleanup 只删 synced items。
- core 1119/154、app 455/55 绿；ratchet try? 284↓3、prepare 130↓2。
- 3b 必办：LiveSimilarityAPI 改接、AssetRepo.relocateMetadataState 迁 deliveries、WorkspaceStatusService 改交付、execute backup/base 直接写、删旧服务/表/Transition、Database.open→V1+replay。

## D-085 S5c-2b-3b-1 放开范围

- 允许改 SimilarityService.swift、AppComposition.swift，新增 Host/SimilarityWritebackBridge.swift：扩 preview/persistKeywords/writebackItems 转发与 SimilarityWritebackProvider；AppComposition 注入，生产不得抛 WRITEBACK_PROVIDER_NOT_INJECTED。
- relink：旧 outbox/writeback_items 照旧 + UPDATE deliveries.xmp_path/photo_path；writing→ASSET_RELINK_XMP_BUSY，目标已有交付→ASSET_RELINK_OUTBOX_CONFLICT；delivery_sessions/items 按 delivery_id 不改。
- backup：选 (a) execute 自行 xmp.backup() 并回读 attributes 计算 base_fingerprint/base_values；不注入 outbox 基线；与协调器暂时各备份一份，3b-2 删协调器时收敛。

## D-086 S5c-2b-3b-1 完成与 3b-2a

- LiveSimilarityAPI 全接 SimilarityService；SimilarityWritebackBridge 注入；relink 迁 deliveries；workspace culled 查 delivery_items；execute 直写 backup/base。
- core 1123/154、app 456/55 绿；ratchet 55/284/129。
- 3b-2a：WritebackService 去 MetadataSyncPort（waitForIdle/flush 改直接写/no-op，summary 用 DeliverySummaryQuery，confirm 用 DeliveryRepo，cleanup 用 DeliveryCoordinator）；删除 MetadataSyncCoordinator/MetadataOutboxRepo/WritebackRepo 文件与 AppComposition 构造；Culling/FaceKw/Sim 的旧 sync 端口改 DeliveryCoordinator。
- 3b-2b：Database.open→SchemaV1、启动 replay、删旧表/3 列/Transition、纯 V1 夹具。
- 注意：WritebackService 保留为交付执行器，不删除。

## D-087 S5c-2b-3b-2a 选 A

- 删除三旧文件会破坏 MetadataMutationService（手动队列）、WorkspaceStatusService（计数）、AppRuntime（shutdown）、LiveMetadataAPI（conflicts/orphans）与 Culling syncStatus/schedule。
- 2a 只做去端口：WritebackService 去 metadataSync 直写；Culling syncStatus 读 deliveries；FaceKw/Sim 删 outbox 基线抄写；三文件与 4 消费方暂留。
- 2b 统一收口：迁移 4 消费方、删三文件、Database.open→V1、删表/3 列/Transition、replay。
- 2a 不满足 grep 零引用；报告必须标注。

## D-088 S5c-2b-3b-2a 完成与 2b 拆分

- WritebackService 去 metadataSync：execute 直写 xmp、flush 只读摘要、confirm 单事务、cleanup 走 Coordinator；Culling syncStatus 交付优先/outbox 兜底；Face/Sim 镜像 baseline 读 deliveries。
- core 1125/154、app 456/55 绿；三旧文件保留（2a 不满足 grep 0）。
- 2b 分三步：
  1. 2b-1：WorkspaceStatusService 计数、AppRuntime shutdown、Culling 剩余 outbox、Face/Sim WritebackRepo 镜像读、AppComposition 收窄。
  2. 2b-2：MetadataMutationService 手动队列、LiveMetadataAPI conflicts/orphans/resolve 迁交付或显式下线。
  3. 2b-3：Database.open→SchemaV1 + replay、删三文件/旧表/3 列/Transition、纯 V1 夹具。

## D-089 S5c-2b-3b-2b-1 完成

- WorkspaceStatusService.summaryCounts 改 DeliverySummaryQuery（三模块按 xmpPath 去重取最高严重度）。
- AppRuntime 去 metadataSyncCoordinator；shutdown 只 stop jobService + db.close。
- Culling 删 metadataOutboxRepo/CullingSyncPort，assembleAssets/conflict/applyHistory/syncStatus 改 deliveries；loadOutboxByPaths 换 delivery_items。
- FaceKw/Similarity 镜像状态读 delivery_items；无 id 不镜像。
- AppComposition 仅保留 coordinator 给 MetadataMutationService/LiveMetadataAPI（2b-2 删）。
- core 1125/154、app 456/55 绿；ratchet prepare 131↓1。
- 过渡缺口：手动 rating/label 仍写 outbox，Workspace xmp pending 暂不含手动变更；2b-2 迁移后消失。

## D-090 S5c-2b-3b-2b-2 裁决

- 批准 AppServices.makeMetadata 最小改动 + AppComposition 增 deliveryRepo/xmpProvider 替换 coordinator。
- 事件：DeliveryCoordinator/WritebackService 增 onDeliveryStateChanged 闭包，AppComposition 注入 post GatherEventCenter；不得静默丢失 c1-sync-status。
- 关键词：优先 attributes_json.keywords_mode=merge/replace 实现 replace/remove；否则明确仅 append 等价，replace/remove 列 2b-3 阻塞。
- conflicts/orphans 用交付派生可接受。

## D-091 S5c-2b-3b-2b-2 完成

- MetadataMutationService 手动队列迁 deliveries/items（module=.metadata，pending）；rating/label→attributes_json，keywords + keywords_mode(merge/replace)；replace/remove 真正删词。
- LiveMetadataAPI conflicts/orphans/resolve 全走交付；orphans=无 delivery_sessions 关联；keep/restore/retry 保留。
- AppComposition 删 coordinator，增 deliveryRepo/xmpProvider；单一 DeliveryCoordinator 注入四域。
- DeliveryCoordinator/WritebackService eventSink 恢复 c1-sync-status 推送。
- core 1135/155、app 460/55 绿；ratchet try? 286、prepare 131。
- 2b-3：Database.open→SchemaV1+replay、删三旧文件/测试/旧表/3 列/Transition、MetadataSyncError.externallyModified 迁移、纯 V1 夹具。

## D-092 2b-3 追加范围

- SessionRepo 仍写 sessions 3 legacy 列：改 V1 11 列；writebackStatus 由 deliveries/items 派生、failedWritebackCount=failed item 计数、importSource=空串；INSERT/UPDATE 去 3 列。
- SessionService 删 writeback_items；按 D-033 先显式删 role_bindings/person_photos（RESTRICT）再删 session。
- AssetRepo.relocateMetadataState 旧表分支改 deliveries/delivery_items。
- 不碰 UI/API 形状；更多 V1 缺列引用列入报告，禁止 try? 静默。

## D-093 S5c-2b-3b-2b-3 完成（Cut 2 关闭）

- 生产建库：GatherApp → `Database.open(at:)`（user_version=1；不兼容库整体重置含 -wal/-shm）；AppComposition.make(database:) 用 database.connection 构造服务；DBConnection+MigrationRunner 双入口取消。
- 启动 replay：AppRuntime.start 在 jobService.start 后调度一次 DeliveryCoordinator.replayPendingDeliveries()（后台 Task，不阻塞启动）；失败 error 日志 + runtime.deliveryReplayFailure 可见；shutdown 先 await 回放再关库。
- 删除 5 生产文件 4,081 行：MetadataSyncCoordinator(1230)/MetadataOutboxRepo(897)/WritebackRepo(205)/Migrations(1628)/SchemaV1Transition(121)；删除 4 测试文件 1,983 行；Schema.swift 649→19（仅 activeAnalysisJobStatusSQLList + check-docs 版本镜像）。
- MetadataSyncError → DeliveryError（4 个仍用码：confirmIncomplete/confirmRequiresSync/otherSessionNotConfirmed/externallyModified）；MetadataWritebackFailure/MetadataCodedError/DeliveryPath 一同落在 Database/DeliveryError.swift。
- V1 缺列修复（D-092 追加项）：SessionRepo 11 列 + 按名解码、writebackStatus/失败数由交付聚合派生、importSource 空串；SessionService 删 writeback_items、补显式 role_bindings 删除；AssetRepo.relink 只迁 deliveries/keyword origins。
- 夹具：makeMigratedDB/makeGatherTestDB 只 exec SchemaV1.sql；MigrationTests 改 fresh only（43 表/10 列/无 legacy）。
- core 1080/151、app 461/55 绿（--no-parallel）；ratchet 53/242/126/0/0；no-legacy/docs/test-catalog/select-star 全过。

## D-094 Cut 2 关闭（已复核）

- 独立复核：core 1080/151、app 461/55（--no-parallel）全绿；生产 Database.open→SchemaV1；旧同步栈删除 5 文件 4,081 行 + 4 测试 1,983 行；ratchet 53/242/126/0/0；docs schema=1。
- 残余：SessionService.listSessions 每会话 2 条聚合（N+1）；importSource 恒空；旧库首启整体重置（设计内）；未做 GUI smoke。
- Cut 3 先做只读复核：Cut 1/2 删除后文件数/依赖已变，module-split-map 需更新后再拆 target。

## D-095 Cut 3a-0 启动

- module-split-map-v2：364 文件/122,692 行；目标 Protocol 66/Persistence 30/Analysis 21/Domain 28/UI 35/Host 28/App 1；3a 6 步、3b 7 步。
- 3a-0 先删 helper/IPC 6 文件 597 行（生产调用 0），摘 Package.swift helper product/target；验收 grep HelperProtocol/HelperMessage/ImageCommands=0 + build 绿。
- 3a-1 再 git mv 145 文件；3a-2 Package.swift 单人独占；3a-3 import；3a-4 TestSupport；3a-5 CSQLite/error。

## D-096 3a-0 完成

- 删除 helper/IPC 6 文件 597 行 + 23 tests；Package.swift 摘 helper product/target。
- grep 三符号=0；core build 绿；1057 tests/149 suites（1080-23）。
- 3a-1/2 合并执行：git mv 145 文件到 Protocol/Persistence/Analysis/Domain，重写 Package.swift，保留过渡 GatherCore umbrella（@_exported 四 target）直到 3b；同批修 import 使 build 绿。

## D-097 3a-1/2 完成

- 142 文件 git mv：Protocol 66/Persistence 30/Analysis 21/Domain 28；FaceModels 随 Analysis；GatherCore 仅 Umbrella.swift。
- Package.swift 四 target + 过渡伞；依赖 Protocol<-Persistence<-Domain，Analysis<-Protocol；strict import check build/build-tests 均绿。
- 类型下移：FaceAnalysisResult/FaceClusterBinding/FaceClusterData/FkwUnbindResult/SimilarityResult/MetadataFingerprintError/ClusterState/JSONValue/IdentityPolicy -> Protocol；若干可见性 public。
- core 1057/149 绿；app build 绿（仍用伞）。
- 3a-3：94 处 @testable import GatherCore + 2 benchmarks 改直接模块 import。

## D-098 3a-3 完成

- 94 文件/101 行 import：92 测试删 94 处 @testable import GatherCore；补 5 行 Persistence/Domain；2 benchmarks 改 import GatherAnalysis。
- 伞 import = 0；core build + 1057/149 绿；strict import check 绿。
- Package 仍声明 benchmarks/tests 依赖 GatherCore（伞暂不能删）；3a-5/3b 收口。
- 3a-4：GatherTestSupport 抽 RepoTestSupport/AsyncGate + 39 调用点。

## D-099 3a-4 完成

- Tests/GatherTestSupport：DatabaseTestSupport.swift（9 fixture public + makeTestDatabase + makeMigratedDB 别名）、AsyncGate.swift；依赖 Persistence/Protocol。
- 38 调用方加 import；旧 RepoTestSupport/AsyncGate 删除；Package 加 target 依赖。
- strict import check + core 1057/149 绿。
- 3a-5：tests/benchmarks 去 GatherCore 依赖、GatherSchema 可执行、strict check 接 build.sh/CI、注释修正；伞保留给 app 到 3b。

## D-100 3a-5 完成（core 拆分完成）

- Package：tests 依赖四 target+TestSupport+CSQLite；benchmarks 去伞；新增 gather-schema executable。
- GatherSchema dump 723 行、verify 43 表/user_version=1/FK 0。
- build.sh/CI 加 strict import check；scripts 路径改 GatherDomain/Services、GatherPersistence/Schema；CORE_RESOURCE_BUNDLE 改 GatherAnalysis。
- core 1057/149、8 target strict build 绿；app build 绿（伞仍在）。
- check-docs --strict 仍红：ADR 4 条旧路径，3b 修。
- 3b 先做 AppBootstrap/AppImport 抽取（3b-1），再做类型搬家/目录/Package。

## D-101 3b-1 完成

- AppBootstrap 231 行（startup/shutdown 与旧顺序逐行一致）、AppImport 184 行；GatherApp 407->121 行。
- 保留 3 个迁移期转发给 3b-2 删除；app 461/55 绿。
- 3b-0：先做类型搬家（APIErrorPresentation 出 AppServices、SessionServiceError/C1PreflightStatus/CaptureOneBridging 进 Protocol），避免 3b-2 目录拆分后 UI<->Host 成环。

## D-102 3b-0 完成

- APIErrorPresentation -> app Support（11 UI 调用零改）；SessionServiceError -> Protocol/SessionErrors；C1PreflightStatus/CaptureOneBridgeError/CaptureOneBridging -> Protocol/C1（5 成员）。
- CaptureOneBridge conformance；新增 4 处 import GatherProtocol。
- core 1057/149、app 461/55 绿。
- 3b-2+3 合并：移动 UI/Host 64 文件 + 重写 Package + 修 UI 12 文件边界，一次保持绿。

## D-103 3b-2+3 完成

- 66 Swift + 3 资源迁移：GatherHost 30+5 适配器；GatherUI 36+8 端口；GatherApp 仅 GatherApp.swift。
- Package：UI=Protocol+Resources；Host=UI+四 core；App=Host+UI；Tests=UI/Host+四 core。
- UI 边界：E-16 零改；E-17 全 any CaptureOneBridging 删 4 自建；E-18 UI 声明 Sync*API 端口、Host 实现；E-19 wire(JobProgressSource)/clearableSettingKeys/typed provider；额外消除 DomainErrorMessaging/JobCancellationMarker/端口等越界。
- UI 四禁用 import grep=0；UI target strict build 绿；app 461/55 绿。
- 3b-4 端口/适配器落位与 RAWDecoder 注释；3b-6 build.sh/CI/bundle/Info.plist/删伞。

## D-104 3b-6 完成

- build.sh：strict flag；Info.plist 从 GatherUI/Support；bundle 固定 GatherAnalysis/GatherUI；FaceModels/mlpackage/en+zh-Hans 硬失败；lproj 双拷。
- 删伞：gather-core 删 GatherCore product/target/Umbrella；app 只依赖四 core product。
- 门禁：layering 加 UI/Host/App 规则；test-catalog 根更新；docs BASES/ADR 修路径；no-legacy 允许 Host *Adapter；CI gates job + app strict flag。
- core 1057/149、app 461/55；build.sh debug 成功；gather-schema verify 43/1/0。
- 剩余：5 测试缺文件头（catalog strict 红）、select-star 基线 17 vs 实际 6、UI 5 处 RAWDecoder 注释；3b-4/5 收口。

## D-105 Cut 3 关闭

- 7 target：Protocol/Persistence/Analysis/Domain/UI/Host/App；2 executable：GatherSchema/benchmarks；无伞；UI 只 import Protocol；Host 聚合。
- 3b-4/5：UI RAWDecoder=0、select-star 6/6 strict、test-catalog strict 0 缺头、ratchet 53/234/126/0/0、layering 17 规则全过。
- core 1057/149、app 461/55；UI/Host/App strict import；build.sh/CI 新布局通过（CI 直接跑）。
- Cut 3 关闭；进入 Cut 4：SessionStore/Workspace/Intent/ViewState/LanguageStore、View 拆分、l10n codemod、Preview。

## D-106 Cut 4 审计与 4a-1

- 审计 docs/archive/cuts/cut4-ui-audit.md（1196 行）：14 持有者/213 状态字段；isActive 40 生产站点（RootView 全 true）；SessionDraftCache 10 字段 max 8；.id(languageVersion) 1 处；errorMessage 7 VM/154 写/15 渲染；l10n 1481 处（非 1439）；#Preview 0。
- 计划：4a 状态层/ViewState/LanguageStore（8-10 人日）；4b l10n（6-8）；4c View/Preview（8-10）。
- 4a-1：只新增 10 文件零调用点 + 5 组测试；不删 errorMessage/isActive/.id、不改 View。
- 设计偏差：l10n 1481；errorMessage 7 VM；Workspace 加 control/gallery/similarity；capacity 6。

## D-107 4a-1 完成

- 15 新文件（10 状态层 + 5 测试 37 例）零调用点；ViewState/CommandError/RequestGate/LocalizedText/L10n/LanguageStore/WorkspaceIntent/SessionWorkspace/SessionStore/RootShellDependencies。
- CommandError 只搬码/参数/诊断；L10n 渲染期插值；LanguageStore 唯一写入入口；SessionStore capacity 6/pinned。
- app 498/60 绿；layering/ratchet/duplicate/catalog/no-legacy 全过。
- 4a-2 分：2a RootView/SessionStore 接线；2b VM setVisible 钩子；2c intents/标题/测试；4a-3 LanguageStore。

## D-108 4a-2b 完成

- 4 VM 新增 setVisible/shutdown：Culling isActive 唯一写入口+画质轮询；Gallery index 轮询/deferred；Similarity progress+result；Control while 迁 VM（3s/15s）。
- 6 新测试；app 504/60 绿；5 门禁过。
- 4a-2a 分两步：先加 SessionWorkspaceFactory/SceneState deps（不改 RootView），再切 RootView 去 draftCache/单槽。

## D-109 4a-2a-1 完成

- SessionWorkspaceFactory（Host）：7 VM 现有 init，不新建服务；SceneState 增 rootDeps/sessionStore（capacity 6），启动不建 workspace。
- 6 新测试；app 510/61 绿；layering/duplicate/catalog/ratchet/no-legacy 过。
- 4a-2a-2：RootView 吃 scene.rootDeps/sessionStore，删 draftCache VM 缓存/单槽/syncViewModels；SessionTabHost 取 workspace；页面 init 收 VM；可见性接 workspace；intents 留 2c。

## D-110 4a-2a-2 完成

- RootView(deps:sessionStore:navigation:)；删 appServices/provider 存储、gallery/similarity 单槽、syncViewModels、faceKwInitialRole、draftCache 4 VM 字典/LRU。
- 7 会话页 package init(workspace:...) 取 VM；SessionTabHost environment；切换 activate+setVisible。
- 人脸深链走 .faceRole intent；RootNavigation pendingGalleryPhoto 暂留。
- app 516/62 绿；已知：workspace 首建构造 7 VM，Gallery 首屏补载提前、Control VM 复用。
- 4a-2c：余 4 pending+photo/lastSessionId 迁 intent/Store、标题缓存、Host 移 UI、close/VM shutdown、删 isActive/兼容 init。

## D-111 4a-2c 完成

- 删 SessionDraftCache 与 RootNavigation lastSessionId/pendingGalleryPhoto*/sidebarSessionId；intents 迁 WorkspaceIntent take-and-clear。
- 标题 workspace.sessionName 异步缓存；SessionTabHost/environment key 移 UI/Shell；setVisible 7 VM fan-out；close 7 shutdown；新增 Duplicates/Export/Face 钩子。
- 删 RootView isActive:true/7 页面 isActive 参数/兼容 init；SceneState 清 3 provider。
- app 520/62 绿；4 新测试；门禁全过。
- 4a-3 分：3a LanguageStore 接线/删 .id/commands；3b errorMessage/LoadPhase->ViewState/CommandError。

## D-112 4a-3a 完成

- LanguageStore 装配进 AppBootstrap/SceneState；GatherApp 读 language；RootView 删 languageVersion/.id；Commands 改 language + 纯函数 copy；Settings setLanguage 持久化后 store.set。
- 删 .id(languageVersion)/commandsLanguageVersion；会话 .id 保留（身份）。
- app 524/63 绿；4 新测试；门禁全过。
- 遗留：DashboardView/GatherAppDelegate 旧语言写点；文档 .id 描述；4b 前个别子视图文案可能滞后。
- 4a-3b-1：7 VM errorMessage:String? -> CommandError?，渲染期 L10n；LoadPhase 留 3b-2。

## D-113 4a-3b-1 完成

- 7 VM errorMessage/同源字段 -> CommandError?；赋值只 CommandError(error)，删 Culling/Similarity/Export 旧漏斗。
- 新增 CommandErrorText.resolve 单点渲染（码/L10n/本地 key/回退/裸 %）；16 处渲染替换；orderedParams 前缀匹配。
- 22 断言改码/参数；app 529/63 绿；门禁全过。
- 4a-3b-2a：LoadPhase.failed(String)+Similarity Phase.error(String) -> CommandError/ViewState；2b：errorDetail/notice/writebackMessage -> LocalizedText + languageStore 下发。

## D-114 4a-3b-2a 完成

- LoadPhase.failed(String)->failed(CommandError)（新增 error 访问器）；Similarity Phase.error(CommandError)；4 列表 VM 赋值改 CommandError。
- 4 个 View 渲染用 l10n + CommandErrorText.resolve；Similarity 用 phase.error。
- 12 断言改 code/diagnostic；app 529/63 绿；门禁全过。
- 4a-3b-2b：errorDetail/notice/writebackMessage->LocalizedText；actionError/createError/jobsError->CommandError?；LanguageStore 下发；LoadPhase->ViewState 留 2c。
- 政策：CommandErrorText 的 CJK 分支仅 VM 本地校验；API 中文诊断不直接上屏（2b 决策）。

## D-115 4a-3b-2b 完成

- 6 notice + Face errorDetail/errorTooltip + Similarity writebackMessage -> LocalizedText?；4 VM actionError/createError/jobsError -> CommandError?。
- CommandError 增 origin(.api/.localValidation)；散文/NSError 只进 diagnostic；CJK 分支仅 localValidation；LocalizedText 支持 {{param}}/%@/%lld。
- LanguageStore environment key；RootView/SessionTabHost 下发；10 View 删全局 l10n 兜底。
- app 532/63 绿；门禁全过；Settings/Culling 仍有嵌套预格式化参数残项。
- 2c 决定：LoadPhase 保留为 ViewState 过渡桥（failed 已 CommandError）；Similarity 双份随 4c 收敛；Preview 归 4c。
- 4b-1：先修 en 表缺失/冲突/重复与非 l() 51 处；1,481 l() codemod 留 4b-2。

## D-116 4b-1 完成

- en 表 1407/1407（删 11 重复、裁 3 冲突、补 10 key）；中文 key 约定不变。
- 31 处非 l() 迁移（errorText/progress/job/appLocale/appLanguage/setAppLanguage）；LanguageStore 唯一写入口；L10n 增 job/progress/error/取消 helper。
- 新增 LocalizationParityTests 5 例；app 537/64 绿；全门禁 OK。
- 余 l() 1316 处；4b-2 按页 codemod（Culling 265/Face 183/Sim 182/Library 127/Control 117/Dashboard 137/Settings 108/Export 98/Gallery 93/Dup 82/Persons 56/Support 41；Host 67/App 4 allowlist）。
- 4b-2-prep：先补 L10n 字符串缓存/format/动态 key 助手。

## D-117 4b-2-prep 收口与 4b-2a

- L10nStringCache 改 OSAllocatedUnfairLock（无 @unchecked），ratchet 保持 53；app 556/65 绿；全门禁过。
- 4b-2a：Culling 页面 217 处 l() codemod -> l10n/l10n.format；动态 key/拼接/错误横幅手工；本页测试 + app 556。
- 后续 Face 151/Sim 113/Library 109/Dashboard 108/Control 100/Settings 89/Export 83/Gallery 77/Dup 64/Persons 52/Support 41；Host 58/App 4 allowlist。

## D-118 4b-2a Culling 完成

- Culling 217 行/225 处 l() -> 0；String(format:) -> 0；View 4 处 environment l10n；VM ScopeMode/PendingAction/targetLabel -> LocalizedText；notice 改 CullingNotice。
- 写回/取消嵌套模板改渲染期；中文 key/en 不变。
- app 557/65 绿（+1）；门禁全过；allowlist：CommandError.params 内目标名/reasonSummary 仍事件点解析。
- 4b-2b Face：153 l/21 format；注意 %.0f%%、Preset static、scopeText +=、reportCancellation、encodingFailureWarning。

## D-119 4b-2b Face 完成

- Face l() 153 -> 0；21 单行 format 19 迁移（16 l10n.format、3 reportCancellation LocalizedText），%.0f%% 保留；8 多行 format 随结构消失。
- Preset.title/StepItem.label/AnalysisPhase.label -> LocalizedText；scopeText 8 个改渲染期；reportCancellation/encodingFailureWarning -> LocalizedText；notice FaceNotice。
- app 557/65 绿；门禁过；注释/docs 台账留 4b-3。
- 4b-2c Similarity：4 scopeText +=、4 onCancel、VM 18 派生提示、statusText 二次 format、子视图 env。

## D-120 4b-2c Similarity 完成

- View 103 处/95 行 l() + VM 18 处 -> 0；format 归一 l10n.format；4 scopeText -> scopeText(with:)；4 onCancel -> LocalizedText。
- notice -> SimilarityNotice；VM loadHint/confirmHint/cleanupHint/statusText -> LocalizedText；statusText 二次 format 改渲染期。
- 子视图补 env；阈值 Int 保留；app 558/65 绿；门禁过。
- 残留：Support 取消键、三份 Notice 同形、LocalizedText.cancel 仍用于 Settings/Dup。
- 4b-2d Library：LibraryColorOption static label、3 static funcs with l10n、%% 模板、rangeText U+2013、NSOpenPanel prompt 决策。

## D-121 4b-2d Library 完成

- LibraryView 113 + VM 2 = 115 处 l() -> 0；14 String(format) 归一 l10n.format；%% 置信度经 L10nFormat 断言。
- LibraryCardView env；3 static func 加 with l10n；LibraryColorOption.label -> LocalizedText；rangeText -> LocalizedText；NSOpenPanel prompt 由页面传 l10n（无 allowlist）。
- app 558/65 绿；Library 23/1 绿。
- 4b-2e Dashboard：108（View 87/VM 21）、23 format；C1Preflight label/guidance、SessionSource.label、photoCountLabel -> LocalizedText/with l10n；typeLabel/importFailureMessage 加 l10n；directorySessionName 持久化默认值 allowlist。

## D-122 4b-2e Dashboard 完成

- l() 108 -> 1（View 87->0；VM 1 allowlist directorySessionName 持久化默认名）；format 23 -> 0。
- C1Preflight label/guidance/photoCountLabel -> LocalizedText；SessionSource.label -> label(with:)；JobRowView.typeLabel/importFailureMessage/createSession 加 l10n。
- "导入照片" 写 sessions.name allowlist；Capture One 导入走 l10n；NSOpenPanel message 用 View env。
- app 558/65 绿；Dashboard 27/2 绿。
- 4b-2f Control：100 l/12 format；static jobTypeLabel with l10n；IndexHeader/StageMarks/Inbox/SyncStatus 显式 with l10n；%lld%% l10n.format。

## D-123 4b-2f Control 完成

- 100 l() -> 0；12 format 全消（11 l10n.format + indexPercentText）；文件 GatherLocalization=0。
- indexHeaderCopy/stageMarks/inboxItems/syncStatusText 加 with l10n；jobTypeLabel(_:with:)；测试去 AppLanguageLock 改显式 L10n，+5 en 用例。
- app 563/65 绿；filter 73/5 绿。
- 残余：C1StatusCapsule(4)/GatherBadge(13) 仍全局，4b-3 收。
- 4b-2g Settings：89 l/11 format；12 处 VM/静态表用 l10n/with；77 View 用注入 languageStore；7 动态 key；dateText 改为设置语言 locale（修系统语言 bug，行为变更）；3 处 %.2f 保留。

## D-124 4b-2g Settings 完成

- l() 89->0（View 77 + VM/静态 12）；format 11：5 l10n.format、3 LocalizedText、numberText %.2f l10n.format、2 纯数值保留。
- VM save/label/number/date/InstallError/Pending 加 with l10n；动态 12 调用点/77 去重 key en 覆盖断言。
- dateText 改 l10n.locale（en 输出变为 "Oct 22, 2026 at 9:17 AM"，行为变更已测试）。
- app 570/65 绿（+7）。
- 4b-2h Export：83 l（VM7/View76）、9 format；namingPreview/NSOpenPanel with l10n；scopeLabel 参与 id 需同步测试；第 863 行多参拼接手工。

## D-125 4b-2h Export 完成

- l() 83 行/85 处 -> 0；format 11 形态 -> 0（2 归一、9 迁移含 2 跨行）；GatherLocalization=0。
- scopeLabel -> LocalizedText；id 用 key 不随语言变；namingPreview/chooseDestination with l10n。
- app 570/65 绿；B6b 6/1、Localization 17/3、L10nFormat 19/1 绿。
- 4b-2i Gallery：80 l（View75/VM5）、7 format；VM static indexHeaderCopy with l10n；GalleryCell/Lightbox 补 env；227/633 归一；578/847 模板迁移。

## D-126 4b-2i Gallery 完成

- View 75 + VM 5 l() -> 0；format 7 -> 0；GatherLocalization=0；GalleryCell/Lightbox 补 env。
- VM indexHeaderCopy 加 with l10n 保持 String；%% 单 %。
- app 572/65 绿（+2）；Gallery 41/4 绿；IndexHeaderCopyTests 去 AppLanguageLock + en/%% 断言。
- 4b-2j Duplicates：73 l/14 format；Pending models 改 LocalizedText/with l10n；VisualPreset.label(with:)；GroupCardView env；%.1f MB 保留。

## D-127 4b-2j Duplicates 完成

- 73 l() -> 0；format 14+2 跨行 -> 0；GatherLocalization=0。
- PendingGroupResolution/PendingMemberDecision -> LocalizedText/scopeText(with:)；VisualPreset.label(with:)；GroupCardView env。
- %.1f MB l10n.format 无 locale；取消动作残留（已点取消后切语言不重翻）。
- app 577/66 绿（+5）；Duplicates 21/3 绿；65 key en 断言。
- 4b-2k Persons：52 l/9 format；PersonListRow env；reviewLabel with l10n；dateText 改 l10n.locale（en 行为变更）；删除取消独立模板；Toast 调用点 l10n；%.2f 保留。

## D-128 4b-2k Persons 完成

- Persons 52 l() -> 0；9 format 迁（8 l10n.format、reviewLabel -> LocalizedText）；%.2f 保留。
- dateText 改 l10n.locale/isChinese；en 固定 en_US "1/1/2026"，去系统区域依赖；zh 系统不变。
- app 577/66 绿；Persons 18/1、过滤 19/2 绿。
- 4b-2l Support：41 l（TabBar14/Badge13/ReportCard4/C1 4/Slider2/Toast2/Banner1/Common1）+ DashboardVM 1；授权跨页调用点；GatherBadge/tabTitle with l10n；C1 模型传 L10n；parity 正则加 l10n.format；删 DateFormatting.localizedMinute（0 引用）。

## D-129 4b-2l Support 完成

- 42 l()（Support 41 + DashboardVM 1）-> 0；5 format -> l10n.format；GatherUI l()=0。
- GatherBadge/SessionTabBar.tabTitle/C1 capsule/tooltip 显式 L10n；跨页调用点更新；DashboardVM directorySessionName with l10n（撤销 allowlist）。
- parity 正则加 l10n.format、排除 %.2f；key 844->994（补扫 3 个无中文 key）；测试 +1。
- app 578/66 绿；DateFormatting.localizedMinute 删除；system-locale 仅 detectSystemLanguage 1 处。
- 4b-3 Host/App：Host 58（Delegate49/RootView6/AppImport2/AppBootstrap1）+ App 4；3 format。

## D-130 4b-3 完成（源码 l()=0）

- Host 58 + App 4 全迁；3 处 String(format: GatherLocalization) -> l10n.format；Sources 内 GatherLocalization.l( = 0。
- Delegate 增 languageStore + l10n 兜底固定 zhCN；菜单 copy 函数接收 l10n；ensureStandardMenus 补 NSApp 守卫。
- RootView WebPage.title(with:)；GatherApp 4 处读 scene l10n。
- app 580/66 绿（+2）；门禁过。
- 4c-1：PreviewSupport fixtures + 14 #Preview + check-preview-surface.sh；4c-2 起拆 Culling/Root/Settings 等巨型 View。

## D-131 4c-1 完成

- PreviewSupport 5 文件 2045 行（fixtures/APIs/providers/factory/shell）；14 #Preview（11 页面 + SessionTab/Root/Shell）；全 #if DEBUG。
- check-preview-surface.sh --strict（>=14、DEBUG、无测试 import）进 CI；build/test 580/66 绿。
- 限制：Root 预览是结构外壳非真 RootView；fixture 比预估大因 DTO 完整；无 GUI 目视。
- 4c-2a：CullingView 3726 拆分（VM 独立、shell<=200、单文件<=600），保持 @State/测试/Preview。

## D-132 4c-2a Culling 拆分完成

- CullingView 3732 -> 18 文件/3897 行；VM 468 + Load/Navigation/Actions/Writeback extensions；shell 140。
- 段落 View：Workbench/Toolbar/Inspector/InfoBar/Filmstrip/Conflict/Viewer/Parts/Content/Destructive/DisplayFormat。
- @State/@SceneStorage 留壳；task/onAppear/order 不变；private->internal 跨文件最小化。
- app 580/66、Culling 32/7 绿；preview 14 strict pass；门禁过。
- 4c-2b Face：2177 行；VM 775 需拆 extension；11 @State/8 PendingFace*；Step1/2/3；MemberRow FocusState 同调用位置。

## D-133 4c-2b Face 拆分完成

- 14 文件/2237 行（<=600）：VM 333 + Analysis/Review/Writeback/Notice；壳 128；Confirmations/Steps/Analyze/Review/Writeback/ClusterCard/MemberRow/Toolbar。
- 11 @State 留壳；8 PendingFace* 集中 Confirmations；FocusState 同 MemberRow；无 .id/层级/动画改动。
- app 580/66、Face 48/6 绿；preview 14 pass；测试零改。
- 4c-2c Gallery：先移 SessionTab 到 Shell；拆壳/筛选/检查器/网格/Cell/Lightbox；保 task(id:)/onAppear/layoutCache/lightboxIndex/@SceneStorage；Lightbox 不套 .id。

## D-134 4c-2c Gallery 拆分完成

- GalleryView 1368 -> 8 文件/1403 行：壳 198、Content 332、Toolbar 59、Inspector 117、Grid 153、Cell 120、Lightbox 424、Shell/SessionTab 15。
- SessionTab 原样迁 Shell；body/Cell/Lightbox 行等价；grid .onAppear 原位；Lightbox 无 .id。
- app 580/66、Gallery 过滤 58/4、LayoutBudget 8/1 绿；preview strict pass；门禁过。
- 残余：GalleryViewModel 996 行 >600，随后续拆分收；docs 补记。
- 4c-2d Settings：1935 行；VM 102-997 + C1ProbeGate/ModelInstaller/Pending*；7 @State+@FocusState；3 focusedFieldKey.onChange；3 task/2 fileImporter/2 confirm 顺序不可动；languageStore 注入 let。

## D-135 4c-2d Settings 拆分完成

- Settings 17 文件 2050 行：壳 181；View extensions Model/Fields/C1Health/Sections/FaceAnalysis；VM 103+Catalog/Fields/Loading/C1Health/Sync/Download；ModelInstaller/SettingsModels/C1Probe/Confirmations。
- @FocusState 唯一实例 internal，3 focused/3 onChange 原样分布 +Fields/+Model；languageStore/l10n internal。
- GalleryViewModel 996 -> 1048（主 359 + 7 extensions）；API 不变。
- app 580/66、定点 75/8 绿；preview strict pass；门禁过。
- 4c-2e Control：1187 行；拆 VM/JobRow/Inbox/Sync/Index 等；保轮询/任务行/状态。

## D-136 4c-2e Control 拆分完成

- 1276 -> 14 文件/1384 行；壳 195；VM 202 + Actions 121；IndexHeader/Stages/Inbox/Recommendation/Toolbox/Sync/Jobs/Toolbar/Actions/JobRow/Models。
- .task/.onAppear/.onDisappear/.onReceive 顺序逐字；轮询在 VM；仅 retry 动作；#Preview 保留。
- app 580/66、Control 118/10 绿；preview strict pass；门禁过。
- 4c-2f Export：1190 行；VM 598/View 520；先抽 VM 再拆五段；保 5 状态（debounceTask/viewModel/pendingExport/2 FocusState Binding）；接线顺序 load→take→refresh→onDisappear→onChange 300ms→onReceive→confirm。

## D-137 4c-2f Export 拆分完成

- 1190 -> 13 文件/1287 行：VM 343 + Preview/Plan/Execute/Report；壳 200；Progress/Range/Options/Preview/Result/FieldError；ExportConfirmation 50。
- 5 状态留壳；FocusState Binding 下传；Form 顺序与接线逐字保留；init/ExportConfirmation 不变。
- app 580/66、Export 26/3 绿；preview strict pass。
- 4c-2g Duplicates：910 行；VM 317 整段搬；View 444-771/GroupCard 775-904；4 @State；两 confirm 不同节点；tabSelector @Bindable/onChange 原位。

## D-138 4c-2g Duplicates 拆分完成

- 910 -> 4 文件/983 行：壳 199、VM 434（原 126-442 + Pending/Preset）、+Sections 207、DuplicatesGroupCardView 143。
- GroupCardView 与 Similarity file-private 同名冲突，Duplicates 版改名 DuplicatesGroupCardView（相似度侧 4c-2h 再改）。
- 4 @State；无 FocusState；tabSelector @Bindable/onChange 原位；两 confirm 分节点；order 不变。
- app 580/66、Duplicates 21/3 绿；preview strict pass；门禁过。
- 4c-2h Similarity：View 1010/VM 1021；VM 先 extensions；4 Pending @State + 4 confirm；接线 task(id:)->onChange(session)->onReceive(c1)->onChange(keywords)->onChange(result)；GroupCardView 改名 SimilarityGroupCardView，isHovered 随卡片。

## D-139 4c-2h Similarity 拆分完成

- 2031 -> 14 文件/2160 行：VM 321+Load/Analysis/Result/Writeback/Sync；View 壳 161+Content/Analysis/Writeback/Toolbar/GroupCard/MemberCell/Confirmations。
- 4 Pending @State 原位；接线顺序逐字；4 confirm 同节点顺序；GroupCard/MemberCell 改名；static let 移类型体、maxIdle 移 VM。
- app 580/66、Similarity 48/6 绿；preview strict；门禁过。
- 4c-2i Dashboard：View 966/VM 917；VM 拆 preflight/load/API/actions/polling/derived；View 4 类型（Dashboard 33-420/SessionRow 425/JobRow 599/NewSessionSheet 722）；8+4 @State 留类型体；接线/2 alert 顺序；#Preview 963。

## D-141 4c-2i Dashboard 拆分完成

- 1883 -> 11 文件/1958 行：VM 396 + Preflight 25/Load 79/API 50/Actions 272/Polling 81/Derived 68；View 壳 432 + SessionRow 179/JobRow 128/NewSessionSheet 248。
- 接线顺序逐字；两个 alert 同节点；7 @State + @Binding + @Bindable（brief 8 为误记）；轮询在 VM；#Preview 429。
- app 580/66、Dashboard 27/2 绿；preview 14 PASS；门禁过。
- 4c-2j Library：View 940/VM 796；View extensions + LibraryCardView；VM 6 MARK；8 @State + PendingRelink 留壳；5 confirm 节点/顺序；jobProgress 去抖 Task 保 View（所有权决策）。

## D-142 4c-2j Library 拆分完成

- 1736 -> 13 文件/1851 行：VM 402+Load/Filter/Paging/Fetch/EventRefresh/ErrorText；View 壳 155+Toolbar/Filters/Support/Content/Card。
- 8 @State + PendingRelink + @SceneStorage 留壳；5 confirm 同序；接线逐字；jobProgress 去抖留 View（显式）。
- app 580/66、Library 23/1 绿；preview 14 PASS；门禁过。
- 4c-2k RootView：768 行；拆 shell<=300 + Sidebar/Toolbar/DetailRouter/Overlays；保 RootNavigation/SessionStore/workspace/onAppear/onChange。

## D-143 4c-2k RootView 拆分完成

- RootView 768 -> 7 文件/886 行：壳 148、Navigation 206、Sidebar 86、Toolbar 78、Detail 129、Overlay 78、Workspace 161。
- onReceive×6/onAppear/onChange/task 顺序不变；SessionTabRouter/environment/.id/sidebar/windowTitle 保留；@State 留壳。
- app 580/66、Root 20/3 绿；preview 14 PASS；全门禁过。
- Cut 4 关闭口径：Root 148、#Preview 14、无 languageVersion/.id、isActive 仅 CullingViewModel 轮询字段、errorMessage 7 VM 已 CommandError。
- 残：Similarity phase.error 与 errorMessage 双份；CullingDisplayFormat 注释；docs 台账。

## D-144 Cut 4 关闭（2026-10-22）

- 4a：4a-1 新增 15 文件（10 状态层 + 5 测试/37 例）；4a-2/3 接 SessionWorkspace（capacity 6）/WorkspaceIntent、7 VM setVisible/shutdown、RootView 去 draftCache/单槽、LanguageStore；7 VM errorMessage→CommandError。
- 4b：`l()`=0（页面/VM 的 `GatherLocalization.l(` 调用 0，Support 内部实现除外）；en 1407 条；parity 在用 key **1265**（D-129 记 994，4b-3 Host/App + 4c-1 PreviewSupport 后漂移，测试仍绿）；无 `.id(languageVersion)`。
- 4c：11 个巨型 View 拆分，页面目录 141 个 Swift 文件（含 VM/子视图），壳 128–432 行；RootView 7 文件/886 行、壳 148；#Preview 14 + `check-preview-surface.sh --strict`。
- 4c-3：Similarity 页级错误唯一来源 `phase.error`；`errorMessage` 改只读代理（`actionError` 只承载操作级错误）；View 全页错误只读 phase；文案/码不变。
- 4c-3：`CullingDisplayFormat.swift:23` 注释改为 `Library/LibraryView+Filters.swift` 的 `LibraryColorOption`。
- 验证：app 580/66、core 1057/149、`--filter Similarity` 48/6 全绿；ratchet 53/233/126/0/0、layering 17 条、docs PASS、preview strict 14；app/core `swift build` exit 0。
- 残余收口：Similarity 双份已收（本 D）；Culling 注释已修（本 D）；仅余**无 GUI 人工验收**（Preview 渲染/页面交互未目视，GUI smoke 待人工）。


## D-145 Cut 4 关闭

- Similarity 双份收敛：删存储 errorMessage，phase.error 唯一页级来源；actionError 操作级；errorMessage 只读代理；View 只读 phase.error。
- CullingDisplayFormat 注释修正；progress Cut 3/4 更新；D-144 已记。
- app 580/66、core 1057/149；preview 14；ratchet 53/233/126/0/0；docs PASS。
- parity 实测 1265（D-129 的 994 为 4b-2l 时点，Host/App+PreviewSupport 后增长），台账已注明。
- 残余仅无 GUI 人工验收；Cut 4 关闭。
- 进入 Cut 5 审计：ClusterGraph/ClusterPipeline、HNSW/5 BFS 副本/双重聚类、FaceMatcher 批处理、三阶段人脸分析。

## D-146 Cut 5 审计完成

- docs/archive/cuts/cut5-algorithm-audit.md 810 行：相似度 2 实现 1503 行；人脸 DBSCAN 533 + ANN 866；度门控 BFS 6 份（非 5）；双聚类 3 趟 O(n²)，第 2 趟纯浪费。
- 可删净 ~2285 行：双聚类 515/HNSW 471+36+55/ClusteringImpact 442+672/仅测试 60/FaceMatcher 旧 API 30。
- P0：人脸聚类在 connection.transaction 内持锁（FaceKwService:902-933），<=20000 LSH 不启用，10k 脸 ~17s 锁内。
- FaceMatcher 批量化仅预计算范数（保累加序）；三阶段 A 短事务/B 锁外/C 短事务 + algorithm_version。
- 漂移：VectorNeighborIndex 协议不存在需新建；single-flight 已实现；4 个"仅测试"实为生产函数。
- 5a：只增 ClusterGraph.swift + ClusterGraphParityTests（6 fixture 等组/序、200 随机、n=32769 streaming），零回滚。

## D-147 5a 完成

- ClusterGraph.swift 478 行（HashGraphTable/NeighborhoodGraph/Hash+Streaming/DegreeGatedBFS/ClusterWorkspace）；9 tests；core 1066/152 绿。
- fixture 实际 17（15 global/2 sequential），15 全跑；groups 含组序/组内序与 ClusterEngine.clusterByHash 逐位相等；200 随机分量/组相等；n=32769 streaming 一致。
- 差异：6 份 BFS 划分/种子序一致，组内序不同（wave #1/#3 新实现；stack DFS 逆序 #2/#4/#5；#6 canonical 第三种）。未发现划分差异。
- 5b-1：SimilarityService.decideCluster 一次图+BFS 产 result+state，删第二次 buildState；precomputeNeighborTiers 多档并集；IncrementalClusterer BFS 换新；暂不删旧文件。

## D-148 5b-1 完成

- ClusterGraph +300：MultiThresholdHashGraph/TierGraph、ClusterGraphOutcome、ClusterGraphPipeline.run/runTiers；Similarity ClusterProvider 返回 Outcome，global=run，sequential=ClusterEngine（待删）。
- decideCluster 单趟 result+state；analyze 3->2 趟；多档 4 位图->1 并集（32k 537MB->134MB）。
- Incremental update 受影响/合并分量用 pipeline，DSU 保留；buildState 留 oracle。
- core 1071/153 绿（+5）；focused 137/32；app build；门禁过。
- 风险：>32768 streaming 组内序 wave vs 旧 stack（划分/种子/state 不变）。
- 5b-2a：Duplicate/AppComposition 注入 pipeline；删 ClusterEngine/旧 Incremental 内部/6 BFS/HNSW/ClusteringImpact；迁 ClusterEngineError/defaultMaxBitset；测试改 golden。

## D-149 5b-2a 完成（唯一实现切换；删旧聚类 / HNSW / ClusteringImpact）

- 删 4 文件 / 2,584 行：ClusterEngine.swift 753、ClusteringImpact.swift 442、
  ClusteringImpactTests.swift 672（9 例）、ClusterGraphParityTests.swift 717（12 例 / 4 套件，
  旧实现参照随实现消失）。
- 唯一实现 = ClusterGraph.swift（784 → 943 行）：迁入 HashEntry / HashGroupingMode /
  ClusterResult / ClusterGraphError（原 ClusterEngineError）+ defaultMaxBitsetEntries
  （原 maxBitsetEntries = 32768）+ sequential（runSequential / runSequentialTiers，
  原 clusterSequentially）+ 模式分发 run(mode:) / runTiers(mode:)（服务侧不再各写 switch）。
- 6 份 BFS → 2 形态：ClusterEngine #1/#2/#3 与 IncrementalClusterer #4/#5/#6 全删；
  只剩 DegreeGatedBFS.components（popLast 栈）与 groups（frontier 波次）。
- IncrementalClusterer 748 → 340 行：删 buildState / ParsedHashes / ComponentGraph /
  connectedComponents / groupComponent(Scanning)；增量装配改用 HashGraphTable 距离 +
  ClusterGraphPipeline.run 重算受影响分量（不再自建第二份图）。
- HNSW：VectorIndex 866 → 370 行（CosineHnswIndex / HnswConfig / HnswHits / FaceVector +
  invalidNeighborCounts / invalidEF / dimensionMismatch）；benchHnsw + 调用 + 死 helper
  bruteForceTopK（bench 333 → 281）；VectorIndexReconciliationTests 323 → 213 行、5 → 3 例，
  取消 GATHER_RECONCILIATION_VECTOR gate（默认运行）。LSH 保留（Clusterer/Matcher 生产在用）。
- 注入点：DuplicateService 默认 clusterProvider 与 AppComposition 同一调用
  ClusterGraphPipeline.run(mode:).result；SimilarityService 两处 ClusterEngine 调用
  （sequential 单档/多档）删除，provider 直接走 pipeline 的 run/runTiers(mode:)。
- 测试：core 1071/153 → 1060/152（−11 例 / −1 套件，exit 0）：−9 ClusteringImpact、
  −12 parity、+12 ClusterGraphTests（fixture golden 17 例 + 单趟 state 不变量 +
  度门控/wave 序 golden + 多档/模式分发 + 200 次增量一致 + streaming 2 例）、
  −2 HNSW 专属（hnswTopK / rejectsDimensionMismatches）。oracle 迁移：
  ClusterReconciliationTests 改断言 pipeline（fixture golden 不变）；IncrementalClustererTests
  与 SimilarityIncrementalServiceTests 的全量参照改为 ClusterGraphPipeline.run/runTiers；
  服务层落库一致性用例保留，对照实现改为 pipeline。
- 验收：core 全量 1060/152 exit 0；app build exit 0（--build-tests 也过）；
  ratchet 53/233/126/0/0 OK、layering 17、duplicate PASS、no-legacy OK、
  test-catalog PASS、select-star Sources 6 / Tests 1 OK。
- 漂移 / 残余：① fixture vector-fixtures.json 仍含 hnsw 段、生成脚本
  scripts/reconciliation/generate-vector-fixtures.mjs 仍产出（不在本刀可写范围，5d 收）；
  ② ADR-011（HNSW 决策正文）、cleanup-backlog CL-05/06/13/20、test-audit skip 计数留给 5d
  （本轮只把 ADR 中已删文件的路径标注“已删除”，check-docs 缺失 1→0 PASS）；
  ③ sequential 多档 progress 改为「已完成档 + 当前档」单调映射（旧 clusterByHashMulti 的
  totalUnits = count × (tiers + 1) 口径未复刻；无测试依赖）；
  ④ >32768 streaming 组内序仍为 wave（5b-1 已记）。
- 5b-2b 剩余：similarity_cluster_meta 加 algorithm_version / input_signature /
  state_digest（SchemaV1）；matches 增列比对；ClusterStateDiff + apply 行级 upsert
  （现 replace 为两表 DELETE 全表重插）。

## D-150 5b-2a 完成

- 删 4 文件/2584 行：ClusterEngine 753、ClusteringImpact 442、其测试 672、ClusterGraphParity 717（旧参照消失）。
- Incremental 748->340；VectorIndex 866->370（HNSW 471 删，LSH 留）；bench 281；ClusterGraph 943（迁 DTO/错误/defaultMaxBitset + runSequential/runTiers）。
- 6 BFS->2 形态；Duplicate/AppComposition/Similarity/Incremental/bench 全部注入 pipeline；测试改 golden；新增 ClusterGraphTests 12 例。
- core 1060/152 绿（-11/-1）；app build；全门禁过。
- 5b-2b：similarity_cluster_meta 加 algorithm_version/input_signature/state_digest；matches 增列比对；ClusterStateDiff/apply 行级 upsert（现 DELETE 全表重插）。

## D-151 5b-2b 选 A（repo 化）

- 新增 4 处 prepare 在 Service 导致 ratchet 130/126；不 bump baseline。
- 扩白名单 SimilarityClusterStateRepo：版本读写/loadVersion/apply(diff)/meta+state upsert/delete 全放 repo；Service 只编排；删旧 replace。
- 授权同步 schema 列数 370->373 文档（draft/ADR/progress），不改历史结论。
- 目标 prepare 126、core 1073 绿、app build、docs/layering 过。

## D-152 5b-2b 完成

- SchemaV1 meta +3 列（algorithm_version/input_signature/state_digest），43 表/373 列；CHECK/default/version=1。
- ClusterStateVersioning（v1/signature/digest FNV-1a64 行序无关）、ClusterStateEntry/Diff。
- SimilarityClusterStateRepo：matches 六列比对、load 11 列、apply 单行 upsert+只 upsert diff+只删 removed；旧 replace 删除；Service 只编排。
- core 1073/153 绿（+13）；app build；ratchet 126；全门禁过；schema 文档同步 373。
- 5c-1：FaceMatcher.match(clusters:) 批量（库/范数/LSH 各一次，禁改累加序）；去 N+1；core 1073。

## D-153 5c-1 完成

- FaceMatcher.match(clusters:library:...) 批量：库/范数一次，簇循环零 DB；bestScoresPerPerson(queries:) 逐位一致；批量不用 LSH 收缩（对账）。
- FaceKwService 去 N+1：成员一次分块 IN、feedback 一次；SELECT C=1/8 均 7（旧 2C+5）。
- core 1085/155 绿（+12）；app build；门禁过。
- 残余：>lshMinPoints 仍建一次未用 LSH；<=4 查询需 FaceRepo 批量成员/modelSpace（5c-2）；C 需 cluster_signature 清理 API。
- 5c-2：A 短事务检测/嵌入；B 零事务聚类（锁外、isCancelled、total）；C 短事务 index_seq 复核/feedback 采集/写簇/签名/reconcile+match；补取消/index_seq/并发读探针。

## D-154 5c-2 完成

- A 逐照片短事务+checkpoint+取消；B 一次读快照、DBSCAN/增量锁外、isCancelled、失败只清签名；C index_seq 复核、写簇/成员/签名、C2 best-effort reconcile+match。
- FaceRepo clearClusterSignature/getClusterMatchRows；matchClusters 传 modelSpace；SELECT 固定 4（C=1/8）；并发读最小 0.019ms（旧阻塞到聚类结束）。
- core 1092/157 绿（+7）；app build；门禁过。
- 接受 drift：face C 不做字面 ClusterStateDiff（无自然键），单事务+完全相同跳过；FaceClusterProvider +isCancelled；A 失败/取消观测保留（迁移整体回滚）；C2 失败不回滚簇。
- 5d：删 hnsw fixture/生成脚本、ADR-011 HNSW 正文、backlog/test-audit、10k face bench、FaceMatcher 跳过未用 LSH。

## D-155 5d-1 完成（HNSW 残留清理 + 文档收口）

- fixture：`Tests/GatherCoreTests/Reconciliation/Fixtures/vector-fixtures.json` 删 `hnsw` 段
  **2,418 行**（143,273 → 140,855；3.66 → 3.63 MB），只余 `lsh`；`rows`/`queries`/`lsh` 与旧
  fixture **逐字节一致**（同种子重算复现，LSH total recall 0.8436 未变），唯一改动是 `source`
  去掉 hnsw-index.ts。
- 生成器：`scripts/reconciliation/generate-vector-fixtures.mjs` 在 bf936d4（移除 TS 源码）随目录
  删除；本刀按 git 历史（96dba9c）取回并剥掉 HNSW 参照实现/DEFAULT_HNSW_CONFIG/getLevels/
  bruteTop1，**1,016 → 563 行（−453）**，只产 LSH；`--check` 与入库 fixture 逐字节一致。
  语料仍来自 hnsw-recall.test.ts（文件名保留为史实，注释已注明与 HNSW 索引无关）。
- ADR-011 → **superseded**（HNSW 已删除、被 ClusterGraph + LSH 取代），历史正文保留、标"不再
  约束实现"；ADR 另一处"LSH/HNSW 维度"改为 LSH（HNSW 已删）。全文不再有"当前使用 HNSW"。
- cleanup-backlog：CL-05 done（**1,161 行** = ClusterEngine 753 + Incremental 748→340）、
  CL-06 done（**548 行** = VectorIndex −496 + bench −52；5d-1 另删 fixture 2,418 + 生成器 453）、
  CL-13 done（删除面 **1,114 行** = ClusteringImpact 442 + 测试 672；残余 ImageCache 重命名转
  Cut 6）。**CL-20 不标 done**：5b/5c 未删任何 lproj 键，实测 62 个未用（Cut 0 记 49）、
  `#if DEBUG` 17（全为 #Preview 守卫）——按 drift 记录并转 Cut 6，不照抄任务书的"done"。
- test-audit §7：5b-2a −11（−23/+12）、5b-2b +13、5c-1 +12、5c-2 +7 → 1071/153 → **1092/157**
  （净 +21/+4）；skip 8 → **3**（HNSW gate 删除）；Reconciliation 24 → 22。
- schema-v1-risk-audit 加注：**370 → 373 列**（5b-2b 三列；索引 69/FK 62 不变），370 按历史快照读。
- 门禁：check-docs --strict OK、no-legacy OK（7 enforced / 6 tracked）、layering OK、duplicate
  PASS、ratchet 53/236/126/0/0 OK；core build exit 0，全量 **1092/157** exit 0。
- 5d-2 剩余：10k 人脸聚类 bench 档位；`FaceMatcher` 超 `lshMinPoints` 仍建一次未用 LSH 的 skip。

## D-156 5d-1 完成

- fixture 删 hnsw 2,418 行（143,273->140,855），LSH 段逐字节不变；生成器重建 563 行只产 LSH，--check exit 0。
- ADR-011 superseded（HNSW 全删，ClusterGraph+LSH 取代）；backlog CL-05/06/13 done，CL-20 pending（62 未引用 key，Cut 6 清）。
- test-audit 滚动对账 1071/153->1092/157；schema risk audit 注 370->373；progress/decisions 更新。
- core 1092/157、docs strict/layering/duplicate/no-legacy 全绿。
- 5d-2：FaceMatcher >lshMinPoints 跳过未用 LSH；10k face bench/锁外收益；Reconciliation README/ROADMAP 历史化；ImageCache SHA256 重命名；CL-20 留 Cut 6。

## D-157 5d-2 完成（LSH skip / 10k face bench / 文档与改名）

- FaceMatcher：`prepareLibraryRows()`（行维度校验 + > lshMinPoints 时平铺，**不建 LSH**）
  与 `loadLibrary()`（唯一建 `CosineLshIndex` 的入口）拆开；`loadLibrary` 只被实例级
  `matchAgainstLibrary` 调用，批量 `match(clusters:)` / `bestScoresPerPerson(queries:)`
  只走 `prepareLibraryRows`。`lshMinPoints` 公开参数保留（同一门仍服务实例 API/平铺）。
  正确性：批量逐查询的库行序、逐项累加序、零向量短路、维度错误触发点全部不变；
  既有 `FaceMatcherBatchTests` 用例改名并加断言：批量前后 `hasLSHIndex == false`、
  `matchAgainstLibrary` 后 == true、批量结果与 `bestScoresPerPerson` 逐位相等。
- Bench：`gather-core-benchmarks --face-10k`（显式档，不进 `--smoke`/默认档）：
  50 身份 × 200 样本 × 512 维（确定性 mulberry32；无检测/嵌入模型，A 段不测）。
  聚类路径按构建配置并用 `path=/build=` 显式标注：release（-c release）跑生产 10k 默认的
  **精确 DBSCAN**；debug（-Onone）精确 O(n²) 不可行，改跑 LSH 候选（bits 12 / tables 2 /
  probeRadius 0 / eps 0.9 / minPts 5），两构建数字不可互比。匹配 = 每身份 1 行库（50 行）、
  每 10 张同人脸一簇（1,000 簇）、`FaceMatcher.match(clusters:)` 精确批量（两构建同路径）。
- 10k debug / LSH 实测（Apple M5 Pro / macOS 27.0.1，3 跑）：总 28.5/28.9/30.1s，中位
  **28.9s**；聚类 12.65/12.98/13.84s → 中位 **12.98s**（groups=50、largest=200、noise=0）；
  批量匹配 15.42/15.56/15.90s → 中位 **15.56s**（matched=1000/1000、ambiguous=0）；生成
  0.37–0.39s；内存粗估 聚类 **58.8MB**（entries 19.5 + flat 19.5 + LSH rows 19.5 + 桶表
  0.22）/ 匹配 **19.6MB**。
- 10k release / 精确实测（同机，3 跑）：总 19.45/19.50/19.54s，中位 **19.50s**；聚类
  19.23/19.25/19.32s → 中位 **19.25s**（groups=50、largest=200、noise=0）；批量匹配
  152.6/152.8/153.7ms → 中位 **152.8ms**（matched=1000/1000）；生成 0.064–0.099s；内存
  粗估 聚类 **39.1MB** / 匹配 19.6MB。
- **§6.3 门槛未达（实测 drift）**：审计目标"10k 人脸 DBSCAN 精确路径 release 单核 ≤5s"，
  本机单进程实测 **19.25s**（约 3.85× 目标）；"锁内 0s"属服务层（5c-2 并发读探针
  0.019ms），本 bench 不覆盖。按实测记录，不写成达标；是否下调目标/继续优化由 owner 定。
- `--smoke` 仍快（实测 1.16–1.24s；dHash 139.5ms / embedding 717.9ms / LSH 220–231ms），
  新档只由 `--face-10k` 触发，不进默认/冒烟。
- 文档：`Tests/GatherCoreTests/Reconciliation/README.md` 的 HNSW 段改为历史/superseded
  （fixture 只含 lsh、套件默认运行），并修正 target 拆分后的 Swift 路径；`docs/ROADMAP.md`
  8 处 HNSW 描述（痛点 10、决策 D、对账/基准、质量门禁、里程碑 V、基线记录）全部标历史，
  不再声称当前使用 HNSW。
- 改名：`GatherPersistence/Database/ImageCache.swift` → **`SHA256.swift`**（纯改名，逻辑
  未动）；注释与 `FileHasher` 对齐（CryptoKit 流式 ↔ Linux 纯 Swift 回退、同输出）。
  旧名残留注释在 `FileHasher.swift` + 4 个 GatherDomain 文件（不在可写范围，转 Cut 6）。
- CL-20：62 个未引用 lproj key **一个未删**，status 仍 pending/Cut 6（任务书明确不删）。
- 验证：core 全量 **1092/157** exit 0（不增 @Test）；app build exit 0；docs --strict /
  layering / duplicate / no-legacy / test-catalog / ratchet **53/236/126/0/0** 全绿。


## D-158 Cut 5 关闭与 10k 基线

- 5d-2：FaceMatcher 批量不建 LSH（prepareLibraryRows/loadLibrary 拆分，测试 hasLSHIndex false/true）；ImageCache->SHA256 改名；Reconciliation README/ROADMAP HNSW 历史化。
- 10k face bench（M5 Pro，release）：精确 DBSCAN 19.25s、批量匹配 152.8ms、总 19.50s、内存 39.1/19.6MB；groups=50/largest=200/noise=0；debug LSH 12.98s/15.56s。
- 审计 5s 目标未达（3.85x）：接受实测 19.25s 为新 release 基线，目标暂调 <=20s；5s 作为后续优化 stretch，不作为 Cut 5/6 阻塞。原因：10k 精确 DBSCAN O(n²) 单核。
- Cut 5 关闭：ClusterGraph 单实现、HNSW/ClusteringImpact/旧 BFS 删除、双聚类 3->2 趟、批量匹配 N+1->4 SELECT、锁外聚类 0.019ms 并发读。
- Cut 6 审计：CL-12/16/18/19/20、CL-02、62 未引用 lproj、旧 ImageCache 注释、docs 归档、ratchet 收紧、最终验收。

## D-159 Cut 6 审计完成

- docs/cut6-cleanup-audit.md 510 行：CL-02 已 done（1,797 行 Cut 2 已删）；lproj 未引用 64（非62）-> 删63+保留1（检测模型路径 pinned）；zh 1 孤儿。
- 本轮可删 ~121 行（64 key + 57 死代码/12 符号）；172 行外部进程 acceptance 测试可选重写。
- 旧名：代码0；注释 ImageCache6/Migrations4/HNSW5/ClusterEngine8；172 文件头；makeMigratedDB 79 调用建议改名。
- 基线 core1092/157、app580/66、schema43/373/69/62、ratchet53/236/126/0/0、8门禁 strict、skip3。
- 风险：key 静态证据/动态拼接、172+79 改名冲突、docs 归档无门禁/bundle 本机不可跑。
- 6a-1 删 63 en +1 zh key、保留检测模型路径、parity 孤儿 allowlist 断言。

## D-160 6a-1 完成

- 删 63 en +1 zh key；en 1407->1344、zh 10->9；保留检测模型路径。
- 漂移：en 存量孤儿实测 32（审计仅1，整键子串误判）；31 未删，登记 legacyUnusedOrphans 待 6a-2；parity 函数级 allowlist = pinned(1)+legacy(31)。
- en 旧 :413 注释改“遗留键待 6a-2”；未造假文件路径。
- app 581/66（+1 孤儿断言）、core 1092/157；catalog/ratchet 不变。
- 6a-2：删 12 死符号/57 行 + 31 孤儿 key + 15 处旧 section 注释；parity allowlist 收 1。

## D-161 6a-2 完成

- 删 12 符号（净 -63 行）、31 孤儿 key（en 1344->1313）、14 处 section 注释旧路径；parity allowlist 32->1，删 legacyUnusedOrphans。
- core 1092/157、app 581/66、parity 7/1；ratchet 53/236/126/0/0；find-unused 12->2（AppKit）；public 4296->4284。
- 6b：docs 归档（reviews 18/cuts 10 + 链接重写）、makeMigratedDB->makeTestDB 80 处、172 文件头旧 target、ImageCache/Migrations 注释 4+4、HNSW 句更新、schema snapshot 归档。
- 31 键仅静态证据；GUI en A/B 未做。

## D-162 6b docs 归档完成

- 归档：18 篇 reviews -> docs/archive/reviews/（assets 随迁，47 张图片相对链接仍可解析）、10 篇 Cut 文档 -> docs/archive/cuts/；docs/reviews 留 4 篇 + README；新建 docs/archive/README.md 索引（含旧->新映射与"行号为当时快照"声明）。不建 18 个 redirect stub，避免 docs/reviews 仍显示 22 篇。
- 链接：全仓 docs md 链接 133 条、图片 47 条，自建检查 0 缺失；check-docs --strict ADR 反引号路径 20 条缺失 0、reviews 5（4 篇 + README）。
- 当前口径：根 README/docs README/DEVELOPMENT/ROADMAP/ADR 改为 7 target、SchemaV1 43 表/373 列/69 索引/62 FK/user_version=1、无 Router/118、16 协议/110 方法、179 错误码、core 1092/157 + app 581/66；DEVELOPMENT 目录树/本地化/台账/门禁重写；ROADMAP §3.1 与迁移快照行更新。
- 快照：docs/fixtures/schema.snapshot.json -> docs/archive/schema.snapshot-v35.json；ADR-006 标注历史，ADR-029 标题加"（schema 34，历史）"。
- 证据：check-docs --strict PASS；md 链接 0 缺失（脚本为一次性只读检查，未新增门禁脚本）。

## D-163 6b 机械改名 / 注释完成

- makeMigratedDB -> makeTestDB：80 处（1 定义 + 79 调用、40 文件）；合并 makeTestDatabase 临时别名层，TestSupport 只保留一个建库入口。
- 文件头旧 target 路径：171 个（计划 172，漂移 -1；旧路径全部指向不存在文件，已按实际路径回填）；复扫 stale 0。
- 注释：ImageCache 4 处（FileHasher/DuplicateService/NavigationService/MetadataFingerprint；SHA256.swift 的 2 处改名记录保留）、Migrations 4 处（AppComposition/Database/PersonRepo/SchemaV1）、VectorIndexReconciliationTests 的 HNSW 段改为 5d-1 已删 fixture 的当前事实。
- 验证：core 1092/157、app 581/66 exit 0；ratchet 53/236/126/0/0；test-catalog --strict / check-docs --strict / no-legacy / layering(17) / duplicate-symbols --strict / select-star / preview-surface --strict 全绿。
- 残余：L10n.swift 源码注释仍写"177 码 / en 1,407"（不在本刀可写白名单，未改；当前实际 179 / 1,313）；历史归档文档正文中的旧代码路径仍是快照值（L10n 两项已由下方 D-163 最终关闭解决）。

## D-162 6b 完成

- docs：reviews 18+cuts 10 归档，assets 49 随迁，archive README；137 md/47 图链接 0 缺失（修 44 断链/26 入链）。
- 当前口径：7 target、SchemaV1 43/373/69/62、无 Router/118、16 协议/110 方法、179 错误码、core 1092/157、app 581/66。
- makeMigratedDB->makeTestDB 80 处/40 文件；文件头 171（漂移-1）；ImageCache/Migrations/HNSW 注释。
- backlog CL-02/12/16/19/20 done；CL-18 ratchet pending。
- 8 门禁全绿；bundle/GUI smoke 未做。
- 6c：修 L10n 注释 177/1407->179/1313；最终全量/门禁/报告/指标/Goal 关闭。

## D-163 最终关闭（6c，2026-10-22）

- **L10n 注释收口**：`GatherUI/Support/L10n.swift` 两处旧数字改为当前事实——错误码 177→**179**、en 表 1,407→**1,313**；全文件复扫 177/1,407 为 0。
- **最终规模**：535 个 Swift 文件 / 133,740 行（Cut 2 关闭时 364 / 122,692；+171 文件 / +11,048 行，文件增长主要来自拆分）；生产 370 / 测试 163 + 2 个 Package.swift。
- **最终验收（实测）**：core build+test strict **1,092/157** exit 0；app build+test strict + `--no-parallel` **581/66** exit 0；`gather-schema verify` = 43 表 / user_version 1 / FK 违规 0，SQLite pragma 复核 **43 表/373 列/69 索引/62 FK**。
- **门禁**：cleanup-ratchet **53/236/126/0/0**（baseline 53/242/126/0/0，try? 低 6）、test-catalog --strict、docs --strict、no-legacy（7 enforced）、layering（17）、duplicate --strict、select-star --strict、preview --strict（**14** 块/5 文件/2,045 行）全部 exit 0。
- **build.sh**：本机 exit 1，失败在第一个 release `swift build` 的 manifest 阶段（`sandbox-exec: sandbox_apply: Operation not permitted`）；build.sh 不带 `--disable-sandbox`，DSH 环境无法本地跑通。未生成 `release/Gather.app`，bundle/lproj/FaceModels/codesign 均未本机验证，交 CI `gather-app tests + bundle`。
- **GUI**：人工 smoke（导入/挑片/相似度/人脸/导出/中英逐页 A/B/优雅停机）未执行，不写成通过；无 GUI 自动化环境。
- **10k 人脸**：release 精确 DBSCAN 19.25s / 批量匹配 152.8ms / 总 19.50s（3 跑中位），审计 ≤5s 目标未达（约 3.85×）；D-158 已接受 ≤20s 为新基线，5s 留作 stretch。
- **残余**：CL-18 仍 pending（try? 236、unchecked 53，未批量改语义）；CL-20 done 但仅静态键证据（删 94 en + 1 zh，保留 `检测模型路径`，无 GUI en A/B）；CL-19 保留 60 例、4 例外部队列非 hermetic；ratchet baseline 未收紧到 236。
- **交付**：`docs/final-report.md`（目标/结果、Cut 0–6 表、指标、删除清单、证据、残余、回滚、Goal 关闭材料）；progress 顶部与 Cut 6 行同步为最终值；`Schema.swift` 旧记 649→14 更正为 649→19。
- **Goal 关闭**：代码与机器验收范围完成，无未解决代码阻塞；GUI/bundle 属人工/CI 承接项且已留档。建议 owner 确认承接方式后将 goal 标记 complete（本 subagent 无 goal 上下文，不执行 update_goal）。

## D-164 CL-04 deferred：删除未接线的 RequestGate / ViewState（r8 P1-3，2026-10-22）

- **背景**：R8 P1-3 确认 Cut 4 的“统一 stale 守卫”未落地——`RequestGate` 自 4a-0 起零生产调用点（仅 `RequestGateTests`），却被 final-report 的 duplicate 门禁写成“RequestGate 1 份”通过证据；R4 P2-8 确认 `ViewState` 同样零生产调用点。
- **决策**：按“不留‘以后可能用’的类型储备”删除，而非补接线：`GatherUI/Support/RequestGate.swift`（34 行）、`GatherUI/Support/ViewState.swift`（49 行）、`Tests/GatherAppTests/RequestGateTests.swift`（4 例/58 行）、`ViewStateTests.swift`（8 例/98 行），共 **4 文件 / 239 行 / 12 例**。CL-04 记 `deferred`（理由 + 解除条件见 cleanup-backlog），4 个 VM 的私有代次原样保留，不在本轮改业务 VM。
- **证据**：删前 app 606/67；本刀删除 12 例后 **594/65**，串行 exit 0（16.792s），默认并行连跑 3 次均 exit 0（7.363/7.511/7.776s）；当前树因并行工作区新增 5 例/1 套件为 **599/66**，最终串行 exit 0（17.199s），默认并行再跑 3 次均 exit 0（7.646/7.680/7.670s）。core 1,124/158 绿（并行 WritebackService 改动带来 +4 例，本刀未改 core）。8 门禁全过（ratchet 53/240/126/0/0，dup RequestGate 0 份，preview 14）。
- **台账**：cleanup-backlog CL-04 → deferred 并新增 `deferred` 状态定义；final-report 撤销 RequestGate 门禁证据、§6 增第 9 条残余、§5.1 增删除后 app 行；progress 增“评审修复轮”小节。
- **残余**：`GatherUI/Support/LoadPhase.swift:9/18` 注释经 2026-10-22 16:48 复核已无 `ViewState` 引用（并行工作区已修）；4 套守卫仍 37 行未统一。~~`scripts/check-duplicate-symbols.sh` 仍保留 RequestGate 规则~~ → 已于 D-166 移除。

## D-165 评审修复轮完成

- 8 路只读 review（docs/reviews/post-refactor-r1..r8 + summary）发现 2 P0、20+ P1；本轮全量修复 P0 与产品 P1。
- P0-1：Delivery cleanup/replay/orphan restore revision/status/base_fingerprint 守卫 + XMPFileLock 串行 restore/writeback；三入口回归。
- P0-2：CI --no-parallel + AsyncWait 10s/ContinuousClock + 4/2 flake 隔离；app 616/68 串行与并行 5/5 绿。
- P1：metadata executePending、acceptExternal 只 written+resetConfirmations、cleanup 跨模块 gate、mergeInput 全会话重置、writing claim/TTL/归位、enqueue 单事务、schema shape 指纹、Indexer FK 顺序、session.create job+回滚、metadataScan 工厂、15 API 测试、workspace 两级可见性、endSession、Gallery 懒加载、RequestGate/ViewState 删除、catalog skip 门禁、entitlements/SFace/lproj、l10n 固定 key+7 plural+parity。
- 指标：core 1128/159（3 skip，有效 1125）、app 616/68、ratchet 53/240/127/0/0、schema 43/373/69/62、8 门禁 strict 绿。
- 残余：GUI smoke、build.sh 本机完整执行（CI）、10k 19.25s、76 plural 模板、进程外写盘不互斥、markWritten owner、git 未 commit/混合态、少量 P2/CL；CL-04 deferred。
- 报告：docs/review-remediation-report.md、docs/final-report.md §1.1。

## D-166 最终收尾：文档 / 脚本 / 构建产物清理（2026-10-22）

- **范围**：只动 docs/**、scripts/**、.gitignore、README / docs/DEVELOPMENT 与 `release/` 生成物、`.build` 残留；未改 Sources / Tests / Package / Schema。
- **脚本**：`check-duplicate-symbols.sh` 删除 RequestGate 同名规则与“Cut 4 落地”文案（该类型已在 D-164 删除，0 份时不再输出“尚未引入”）；规则 2 文案改为“越界即 warning / --strict FAIL”，去掉“当前 3 份 LockedBox + 1 份 ResponseBox”的过期描述。输出由 4 项变 3 项，`--strict` 仍 exit 0。
- **文档 stale 符号**：`cut6-cleanup-audit.md` §1.2/§4.2 的“RequestGate 1 份”更正为 0 份；`cleanup-backlog` CL-04 残余、`final-report` §6.9、`refactor-progress` r8 小节同步；`review-remediation-report` 从死代码清单移除 `JobScopeCheckpoint`（已是单一来源键枚举，被 LiveSessionAPI/Dashboard 与测试引用）。
- **死链**：非 archive 当前文档 **0 缺失**（`face-clustering-benchmark.md` 13 条旧 `GatherCore` 源码链接改为 `GatherAnalysis/Face/*` + `GatherDomain/Services/FaceKwService.swift`；已删除的 `ClusteringImpact.swift` 改为代码文本）。归档 33 条旧源码链接按“快照不改”保留，只在 `docs/archive/README.md` 注明。`check-docs.sh` 新增“当前文档 md 相对链接存在性”检查（跳过 archive、代码块/行内代码、外链、纯锚点）。
- **指标（实测，17:00）**：en **1,322** / zh 9（`^"` 计键；1,313 为 6c 时点值）、测试文件 **166**、`#Preview` 14、ratchet **53/235/127/0/0**（baseline 240）、**535** Swift 文件 / **138,829** 行（17:00 采样；并行工作区仍在变；6c 时点 535 / 133,740）。
- **构建产物**：删除 `release/Gather.app`（22 MB，2026-09-29 旧 bundle）与 `.build/{scratch-app,scratch-core-p14,scratch-p14,perf-probe}`（≈1.63 GB，均非活动）；保留并行构建正在写入的 `.build/scratch`、`.build/shared-cache` 与两包 `.build` 增量缓存。
- **残余**：归档 33 条旧源码路径链接；`refactor-decisions.md` 存在重复的 D-162 / D-163 标题（历史编号冲突，未重排）；测试例数未复跑（沿用 1,128/159 + 616/68 最近记录）。`GatherUI/Support/LoadPhase.swift:9/18` 注释经 16:48 复核已无 `ViewState`（并行工作区已修，非本轮）。

## D-167 WP7 测试/构建基础设施：共享夹具 product 与 manifest 去外部进程（2026-10-22）

- **背景**：architecture-remediation-plan WP7 + architecture-macro-app §5.1/§5.3。GatherTestSupport 只是 core 内的普通 target，app 测试复制了 AsyncGate/LockedBox/TestDatabase；app manifest 在求值期启动 xcrun 取 SDK，输出随机器漂移且失败时静默回退。
- **决定 1（共享夹具）**：GatherTestSupport 暴露为 core 的 library product（target 路径 `Tests/GatherTestSupport` 不变；app 只把它链接进 GatherAppTests，不进运行时）。app 删除 3 文件 / **89 行**（AsyncGate 39 / LockedBox 31 / TestDatabase 19），新增 `Support/TestSupportReexports.swift`（20 行）用 typealias + `makeGatherTestDB` 转发保持调用点零改动；建库唯一实现是 `makeTestDB()`。**makeGatherTestDB 是临时转发**（22 处调用点），等并行 Shell 迁移收尾后统一改名并删除。LockedBox 落在 `Tests/GatherTestSupport/Support/` 是为满足 duplicate-symbols 的路径约定。
- **决定 2（SDK 显式化）**：manifest 不再执行 Process/Pipe/xcrun；值 = `GATHER_SDK_VERSION`（trim 后非空）或固定默认 **26.0**（Liquid Glass 起效的最低 SDK，不再退回部署目标 14.0）。`build.sh` 探测 `xcrun --show-sdk-version` 后 export（显式值优先），CI 用 “Resolve SDK version” 写 `$GITHUB_ENV`。SwiftPM 的 manifest 缓存不把该 env 计入 key：同 scratch 下默认 26.0 → env 27.0 不会重链；因此 build.sh 的 app 构建与 CI app 测试加 `--manifest-cache none`（实测加后同 scratch 也得到 sdk 27.0）。
- **决定 3（CI）**：gather-core job 新增 `swift run ... gather-schema verify`；app 测试保留 `--no-parallel`，并加 `--manifest-cache none`。
- **证据**：core **1128/159**（17:35 改动前，exit 0）→ 并行 WP1 瘦身 Protocol 后 **1060/159**（exit 0，-68 例、套件数不变，非本刀）；app **616/68** 串行 exit 0（16.78s）、默认并行 **3/3** exit 0（7.305/7.240/7.261s）；`vtool` LC_BUILD_VERSION：minos 14.0，unset → sdk 26.0，env 27.0（fresh/none）→ sdk 27.0；schema `tables=43 user_version=1 foreign_key_violations=0`；8 门禁全过（ratchet **53/233/127/0/0**、test-catalog 165 文件、duplicate 0 越界、docs 142 链接 0 缺失、preview 14）。
- **未做/限制**：`build.sh` 未完整执行（DSH 沙箱拒绝 SwiftPM sandbox-exec，只做 `bash -n` + 探测块单测，bundle 交 CI）；`docs/DEVELOPMENT.md` 不在白名单（其目录树仍写 `Sources/GatherTestSupport`，实际 `Tests/`，且缺 SDK/env 说明）；app 测试 target 的 CLT-only `-F/-rpath` 探测未补（既有差异）；人工 GUI 未执行。

## D-168 WP1 Protocol 瘦身：零引用口径与 Router 信封删除（2026-10-22）

- **背景**：architecture-remediation-plan WP1 / architecture-macro-core §5.3。实测 347 个顶层 public 类型 / 1,752 声明 / 89 零引用 / 6 个 Router 信封；目标 ≤260 类型、零引用 0。
- **决定 1（零引用口径）**：零引用 = 生产 Sources（Persistence/Analysis/Domain + gather-app/Sources）0 引用 **且** Protocol 内 0 引用（注释/字符串剥离、排除声明本身）。Tests 单列、不作为存活依据（延续 D-001：Router 时代 JSON 契约可删）；只被 ContractTests 构造的 DTO 仍算死面。
- **决定 2（信封）**：删除 6 个 Router JSON 信封 `ResponseID` / `ErrorDetail` / `ResponseErrorBody` / `ResponseOk` / `ResponseErr` / `Response<T>`，同步删除 `SessionContractTests` 的 6 个 JSON 往返用例。`Response` 已含在 89 内；其余 5 个因彼此引用不在 89 初始集合，按信封整体删除。
- **决定 3（二级死亡）**：删除失去唯一消费者的 `BindingData`（仅 `FaceCluster.binding`）与 `MetadataMutationTarget`（仅 `MetadataMutationRequest.target`）；删除上游后复算零引用为 0。
- **决定 4（保留面）**：保留 13 个被 API 签名直接引用的旧 `*Params`（SessionUpdate/PersonCreate/PersonUpdate/PersonSearchPhotos/AlbumCreate/AlbumUpdate/NavigationSplit/NavigationMerge/NavigationAnalyze/JobCreate/QualityGet/TemplateCreate/TemplateUpdate）；新增输入只进 `API/Inputs/`，不得复活旧 `*Params` 或 `Response*`（D-007 收口）。
- **决定 5（契约测试）**：纯 DTO 构造/JSON key 用例随类型删除（68 例）；混合用例改写保留存活类型断言（`CullingUpdatePatch` / `AlbumUpdateParams` / `AnalysisJobType`，3 例）；存活 DTO 的 Codable 往返测试保留。
- **结果**：类型 **347→251**、声明 **1,752→1,320**、零引用 **89→0**、信封 **6→0**；Protocol 行 7,598→6,325（`+11/−1,284`，净 −1,273；96 类型块 1,184 行 + 注释/空行清理）。core **1,128/159→1,060/159** exit 0；app **616/68** exit 0；新增 `check-protocol-surface.sh --strict` + `docs/protocol-surface-baseline.json`（251/1,320/0/0）。
- **证据**：`docs/reviews/wp1-protocol-inventory.md`（347 行逐条 file:line/prod/proto/test 计数；89 零引用测试证据；6 信封行范围；96 删除清单）；8 门禁 strict 全过；schema verify 43 表/user_version 1/FK 0。
- **残余/限制**：13 个旧 Params 仍属历史形状（D-007 允许）；本机 bare `swift run ... gather-schema verify` 在 manifest 阶段被 DSH sandbox 拒绝，改用 `--disable-sandbox` + 共享 cache/scratch 实测通过；无 GUI 验收；不 commit。
## D-169 WP3a：GatherDomain → GatherApplication 纯重命名（2026-10-22）

- **背景**：architecture-remediation-plan WP3 3a（纯移动 1 天）；GatherDomain 实为 Application 层（architecture-macro-core §3.2 T1/T2、§6 O-2）。
- **决定 1（纯重命名）**：`git mv Sources/GatherDomain Sources/GatherApplication`，**21 文件 / 15,211 行**内容零改动；core product/target、app Host/测试 product 依赖、全仓 import **130 行**（72 + @testable 58）更新；不改业务逻辑/API/其他 target 名称。Repo 协议与 Ports 拆分留给 WP3b。
- **决定 2（UI 枚举改名）**：GatherUI `public enum GatherDomain`（GatherEventCenter.swift:25）与模块同名遮蔽（r3-build P2-6）；改名 **`GatherChangeDomain`**（1 声明 + 6 引用 / 4 文件），表达"写路径变更域"并与 Application 模块名解耦。
- **决定 3（必要偏离记账）**：门禁脚本/基线/文档硬引用旧目录 5+1+2 文件 / 20 处字符串：scripts/{check-layering,check-cleanup-ratchet,check-no-legacy,check-docs,check-protocol-surface}.sh、`docs/cleanup-baseline.json` services_prepare scope、`docs/ADR.md` 3 行、`docs/reviews/face-clustering-benchmark.md` 2 条链接。不改则 layering skip / ratchet services_prepare 127→0 / no-legacy 21→0（三处假绿）+ docs --strict 红。
- **证据**：core **1,084/163** exit 0 ×3、app 串行 **616/68** ×3、并行 **616/68** ×3；9 门禁全绿（ratchet **53/230/120/0/0**、schema 43/1/0）；`check-protocol-surface --strict` 254/1,338/0/0 exit 0。
- **残余**：48 处源码注释旧名/旧路径未改（21 个 Application 文件头 + Persistence 4 + Protocol 5 + app 18）；`docs/DEVELOPMENT.md:39/113` 与 `docs/README.md:28` 的 target 列表未更新（白名单外）；不 commit；无 GUI 验收。
