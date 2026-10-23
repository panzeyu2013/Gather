# 最终代码验收（只读）

- 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`；HEAD `06b3e0d`，分支 `refactor`（ahead 59）。**审计开始时工作区干净**（`git status --porcelain` 空、无 untracked）；本报告写入后，另有并行 agent 的未提交改动（`.github/workflows/ci.yml`、`scripts/check-layering.sh`、`docs/reviews/final-gate-tests.md`），**非本代理所改**。
- 方法：只读静态审计。**本代理未运行 build / test / 门禁**（按任务书），未改源码/测试/Package/脚本；唯一写入本文件。
- 证据口径：【已确认】= 有 `file:line` 或 `git grep` 计数；【疑似】= 结构/命名推断，未做行为验证。所有计数用 `git ls-files` 限定已跟踪文件（排除 `.build` 产物）。
- 实测规模：**649 个 Swift 文件 / 148,508 行**；Sources 468 / 86,346、Tests 179 / 61,888。按 target：Protocol 71/6,535、Persistence 84/16,418、Delivery 20/6,044、Analysis 14/4,941、Application 44/14,101、Schema 1/203、Benchmarks 2/557、UI 188/29,397、Host 42/7,955、App 2/195。

## 0. 结论

**P0：0。** 未发现数据丢失、越权写、交付状态机旁路或编译级破坏。

**P1：2 条**，都是“口径未完全兑现”，不是新功能缺陷：
1. **>1000 行文件仍有 4 个**（`DeliveryRepo` 1,543 / `AssetRepo` 1,217 / `FaceRepo` 1,194 / `ClusterGraph` 1,119），全在 Persistence 与 Analysis；Application / Delivery / UI 三个整改重点 target **已无 >1000**（最大 767 / 825 / 964）。
2. **交付状态写 owner 只在事实层成立，编译层不成立**：`AssetRepo.swift:722` 有一处 Persistence 内 `UPDATE deliveries`（改名迁移），Delivery 仍有 2 处内联 sessions SQL（一处写），且 `DeliveryRepo` 的 23 个写方法仍是 `public`、Host 仍持有 `DeliveryRepo`。

**P2：10 组**（见 §3），集中在 deprecated API、旧模块名现状注释、死 static/过期注释、benchmark 冗余依赖、6 份 translate 薄包装、800–1000 行邻域、12.6 GB 构建产物与陈旧 target 残留、空目录、生产 `try!`。

**可提交判定**：**可以提交（P0 清零、无阻断缺陷）**，但建议把 P1-1/P1-2 记为已知债务后再合入，或先做 P1-2 的 sessions 窄端口（半天量级）。若验收标准要求“仓库级 >1000 行 = 0 / 写 owner 编译期唯一”，则这两条未达标，不能宣布“全部清零”。

## 1. P0

无。

## 2. P1

### P1-1 >1000 行文件 4 个（仓库级口径未清零）

【已确认】`git ls-files 'desktop/native/*/Sources/*.swift' | xargs wc -l` 实测：

| 文件 | 行数 |
| --- | ---: |
| `gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo.swift:1` | **1,543** |
| `gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo.swift:1` | **1,217** |
| `gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo.swift:1` | **1,194** |
| `gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph.swift:1` | **1,119** |

- **已收口的部分**：`WritebackService.swift` 从 1,472 拆到 **444**（+Execute 428 / +Helpers 300 / +Recover 256 / +Converge 96，写回族合计 1,524 行），Delivery 最大变为 `DeliveryCleanupFlow.swift:1` 825；Application 最大 `Indexer/IndexerService+Scan.swift:1` 767；UI 最大 `PreviewSupport/PreviewFixtures.swift:1` 964（`#if DEBUG`，不进 release）。
- **残余**：Persistence 3 个 Repo + ClusterGraph 仍超 1,000；800–1000 区间还有 5 个（见 §3-6）。
- 影响：审阅/回归成本；和 WP3“>1000 行 = 0”、WP5“单文件 ≤800”的书面口径不一致（当前无门禁强制，仅指标）。
- 建议：Repo 按“读 / 写 / 行映射”纯移动拆分（不改方法体/事务/错误码），ClusterGraph 按“建图 / 查询 / 序列化”拆；先拆 DeliveryRepo（最大且写方法最密）。

### P1-2 写 owner 有破口 + Delivery 内联 sessions SQL

【已确认】**deliveries / delivery_items 的 DML，在 `DeliveryStateWriter` 之外还有 1 处**：

- `GatherPersistence/.../AssetRepo.swift:721-728`：改名迁移直接 `UPDATE deliveries SET xmp_path = ?, photo_path = ?, updated_at = ?`。守卫是 `status == "writing" → ASSET_RELINK_XMP_BUSY`（`:711-713`）与“目标 xmp 行已存在 → ASSET_RELINK_OUTBOX_CONFLICT”（`:718-720`），不经过 `DeliveryRepo`，也不经过 `DeliveryStateWriter`。
- 【已确认】该路径**生产可达**：`LiveAssetAPI.relinkRoot`（`gather-app/Sources/GatherHost/APIs/LiveAssetAPI.swift:59`）→ `AssetRepo.relinkRoot`（`:326`）→ `relocateMetadataState`（`:433` / `:532`）。
- 【已确认】未迁移 `delivery_intents.xmp_path`（DDL 见 `SchemaV1.swift:731-741`）。改名后旧路径 intent 在 `DeliveryReplayFlow` 里只会走 `.alreadyGone`（`DeliveryReplayFlow.swift:259-261`），DB 段因 `get(path) == nil` 不删行（`DeliveryRepo.swift:1347`），后果是**陈旧 intent + 可能遗留备份文件**，不会误删新行。

【已确认】**Delivery 仍有 2 处内联 sessions SQL**（`SessionRepo` 已被绕过）：
- `Writeback/WritebackService+Converge.swift:31-34`：`UPDATE sessions SET reload_acked_at = NULL, updated_at = ?`（写）。
- `Coordinator/DeliveryCoordinator.swift:399-401`：`SELECT reload_acked_at FROM sessions WHERE id = ?`（读）。

【已确认】**编译期唯一性不成立**：`DeliveryRepo` 的 23 个写方法仍是 `public`（`:271`–`:1404`）；`DeliveryStateWriter.init(repo: DeliveryRepo)`（`DeliveryStateWriter.swift:33`）收具体类型；Host 仍持有 `DeliveryRepo`（`LiveMetadataAPI.swift:66/80`，只读用途）；没有 `DeliveryWriting` 之类的窄写协议。

【已确认】**事实层仍成立**：生产写的调用点全部落在 `writer.*` / `stateWriter.*`（`DeliveryCleanupFlow`、`DeliveryMirrorWriter`、`DeliveryReplayFlow`、`WritebackService+Execute/+Recover`、`LiveMetadataAPI:244`），`GatherApplication` 只有 `DeliveryModulePorts.confirm` 语义入口；Host 对 `DeliveryRepo` 的写调用 = 0。

- 影响：不构成数据损坏，但“状态机唯一 owner”是约定而非类型约束；两个模块（Persistence 的改名迁移、Delivery 的 sessions ack）可以合法地绕过它。
- 建议：①Persist 增 `SessionAckReading/Writing` 与 `DeliveryRelocation` 窄端口，两处内联 SQL + `AssetRepo` 的 `UPDATE deliveries` 改走端口；②`DeliveryRepo` 写方法降 `internal` 并在 Persistence 暴露 `DeliveryWriting`；③Host 只拿 `DeliveryStateWriter` + 窄读端口。保持现有事务边界与错误码不变。

## 3. P2

### P2-1 `markWriting` 仍是 deprecated public
【已确认】`DeliveryRepo.swift:342-344` `@available(*, deprecated, message: "生产已无调用；请使用 claimWriting（租约 owner/TTL）")`；生产调用 0；Tests 命中 **core 33 行 / app 8 行**（app：`APICullingTests.swift:226/758`、`APIExportMetadataTests.swift:684/721/724/902/989/1338`；core：`DeliveryRepoTests` 为主）。建议先把测试改 `claimWriting(leaseOwner: "test")`，再删该 API。

### P2-2 旧模块名“当现状”注释仍有 3 处
【已确认】`GatherDomain` 15 处、`GatherCore` 8 处（已从 25/16 下降），其中仍是“现存路径”语气的：
- `GatherProtocol/Protocol/XMPProvider.swift:9`：“不属于交付依赖面，留在 GatherDomain”（该类型已在 Protocol）。
- `GatherAnalysis/Image/RAWDecoder.swift:19`：“不影响 GatherCore 其余部分”（无此模块）。
- `GatherProtocol/Protocol/Culling.swift:9-10`：“（session.ts，GatherCore 已有）”。
其余 12 处是改写溯源（“WP3a 由 GatherDomain 改名”“不能 import GatherDomain”），可保留。

### P2-3 死 static / 过期注释 / 未接线域
【已确认】`GatherApplication/Services/PhotoAssets.swift:13` `public static let rawExtensions = PhotoFileTypes.rawExtensions`：生产 0 引用，仅 `PhotoFileTypesTests.swift:32`、`FilterEngineTests.swift:301` 钉住（已不再是 Persistence 泄漏，只是死别名）。
【已确认】`GatherApplication/Services/Export/ExportService+Plan.swift:396` 注释仍写“复用全仓唯一真相源 AssetRepo.rawExtensions”，`:402` 实际已改 `PhotoFileTypes.rawExtensions`。
【已确认】`GatherHost/APIs/AppServices.swift:63` `template` 域：全仓 UI 0 调用（D-008 保留），但同名 7 条注释（`:41/47/50/53/56/59/62`“B4b/B5b/B6b/B7b 才迁移，暂不传给页面”）已过期——16 个域都已接线（`AppBootstrap.swift:225-236`）。
建议：删 `PhotoAssets.rawExtensions` 并改 2 条测试；删/改过期注释；`template` 明确标“保留未接线（D-008）”。

### P2-4 benchmark target 依赖冗余
【已确认】`gather-core/Package.swift:117` 与 `:123` 两个 benchmark target 都声明 `"GatherProtocol"`，但 `Sources/GatherCoreBenchmarks/main.swift:17-18`（Foundation、GatherAnalysis）与 `Sources/GatherFaceBenchmarks/main.swift:1-5`（Foundation、GatherAnalysis、CoreGraphics、ImageIO、UTI）**均未 import GatherProtocol**，也无其类型引用。建议删依赖（`--explicit-target-dependency-import-check` 不检查“多声明”，所以一直没报）。

### P2-5 `translate` 仍有 6 份薄包装
【已确认】公共臂已统一到 `LiveAPIErrorMapping.translateCommon`（`AppServices.swift:147`）与 `translateDomain`（`:171`），6 个 API 各剩 3–6 行骨架：`LiveDuplicateAPI.swift:133`、`LiveExportAPI.swift:179`、`LiveFaceAPI.swift:267`、`LiveQualityAPI.swift:124`、`LiveSimilarityAPI.swift:264`、`LiveTemplateAPI.swift:145`。建议：域分支改为 `[GatherErrorCode?]` 表驱动，或先保留（风险已很低）。

### P2-6 800–1000 行邻域 + 超大测试文件
【已确认】源文件 5 个：`GatherHost/SidecarXMPProvider.swift:1` 916、`UI/PreviewSupport/PreviewFixtures.swift:1` 964（DEBUG）、`Persistence/.../PersonRepo.swift:1` 884、`Persistence/Database/SchemaV1.swift:1` 846（DDL 真相源，拆分价值低）、`GatherDelivery/Coordinator/DeliveryCleanupFlow.swift:1` 825。
【已确认】测试 3 个破 1,400：`CullingServiceTests.swift` 2,533、`FaceKeywordingServiceTests.swift` 1,940、`app/Tests/.../APIExportMetadataTests.swift` 1,425。建议按 page/domain 拆测试文件（门禁只查文件头与目录，拆分不影响计数）。

### P2-7 构建产物 12.6 GB + 已删除 target 的陈旧产物
【已确认】`du -sh`：根 `.build` 1.5G、`desktop/native/.build` 1.0G、core `.build` 4.6G、app `.build` 5.5G；全部被 `.gitignore` 覆盖，**无产物入库**（`git ls-files` 0 命中）。
【已确认】其中仍有**已删除的 `GatherCore` 伞 target** 的陈旧产物：`gather-*/.build/out/Intermediates.noindex/gather-core.build/{Debug,Release}/GatherCore-t.build/DerivedSources/resource_bundle_accessor.swift`（bundle 名 `gather-core_GatherCore`），以及 `.build/scratch/scope4probe*.swift`（`import GatherCore` 的临时探针）。当前 `Package.swift` 已无该 target。
建议：发布/验收前 `rm -rf` 四个 `.build`（不影响可复现性，重建即可）；scratch 探针不进仓库。

### P2-8 空目录 `gather-app/Resources/`
【已确认】`desktop/native/gather-app/Resources` 0 文件、`git ls-files` 无条目、全仓无引用；真实资源在 `Sources/GatherUI/Resources/{en,zh-Hans}.lproj`（`:214-224` 由 build.sh 拷贝）。建议删除，避免误以为资源目录在包根。

### P2-9 生产 `try!` / `as!`
【已确认】`GatherApplication/Services/NavigationService.swift:422` `try! JSONSerialization.data(withJSONObject: payload)`；payload 只含 `Double/Int/String/Bool/[Any]`，且 `validateNavigationParameters` 先拒绝非法参数，实际风险低但不该用 `try!`。`GatherPersistence/Database/Queries/PhotoFilterQuery.swift:385` 为 `[String]`，安全。`GatherApplication/Services/ImageMetadataProviders.swift:166` 的 `as!` 前有 `CFGetTypeID == CGImageMetadataTagGetTypeID()` 守卫，安全。建议前者改 `guard let data = try? ... else { return "" }` 或 `throws`。

### P2-10 台账/索引漂移（代码侧 2 处，文档侧 1 处；越界未改）
【已确认】`gather-core/Package.swift:49` 注释“app 不链接它（GatherTestSupport）”，但 `gather-app/Package.swift:131` 的 `GatherAppTests` 明确链接（运行时不链接，注释应写“app 运行时不链接”）。
【已确认】`docs/reviews/README.md:1` 写“当前有效评审（30 篇）”，新增本报告后为 31 篇；索引表只有 4 条。**白名单外，未改**。

## 4. 构建 / 依赖

### 4.1 target 图（声明 vs 实际 import，全部吻合）
【已确认】`gather-core/Package.swift:57-137` 与 `gather-app/Package.swift:80-135`：

```
GatherProtocol(0) ← GatherPersistence(+CSQLite) ← GatherDelivery(Protocol,Persistence) ← GatherApplication(+Analysis)
GatherProtocol ← GatherAnalysis        GatherTestSupport(Protocol,Persistence,Delivery,Analysis,Application) 仅测试链接
GatherProtocol ← GatherUI ← GatherHost(+4 core) ← GatherApp(SwiftUI 可执行)
```

| 检查 | 结果 |
| --- | --- |
| `GatherUI` 只 import Protocol | 【已确认】**是**：188 文件里 144 import `GatherProtocol`，其余 core 模块 0；系统模块仅 SwiftUI 107 / AppKit 29 / Foundation 80 / Observation 5 / Combine 2 / os 1 / CryptoKit 1 / CoreGraphics 1 |
| `GatherHost` 不 import SwiftUI | 【已确认】**是**：0 命中；AppKit 1 / CoreGraphics 1 / Observation 1 |
| `GatherDelivery` 不 import Application/Analysis/UI/Host | 【已确认】**是**：仅 Protocol + Persistence + Foundation |
| Application 不触达具体 Repo / DBConnection | 【已确认】**是**：`AssetRepo|PhotoRepo|FaceRepo|DeliveryRepo|PersonRepo|SessionRepo|…` 0 命中；`DBValue` 仅 `FilterEngine.swift:152` 的私有扩展；`WhereClauseResult.params` 已是 `[FilterValue]`（`FilterEngine.swift:17`），公开 API 不再泄漏 Persistence |
| 依赖强制 | 【已确认】`build.sh:191` 与 `ci.yml:79/81/116/130/132` 均带 `--explicit-target-dependency-import-check error`；分层另有 `scripts/check-layering.sh` |
| 外部依赖 | 【已确认】0 个：只有 `.package(path: "../gather-core")`（`gather-app/Package.swift:78`），无 `Package.resolved` |
| 资源 | 【已确认】`GatherAnalysis` 用 `.copy("Resources/FaceModels")`（37 MB：SFace.mlpackage + manifest + native_ramp_reference + LICENSE）；`GatherUI` 用 `.process("Resources")`，`exclude: ["Support/Info.plist"]`（Package:89）；`en.lproj` 1,414 行、`zh-Hans.lproj` 11 行（中文即 key 的回退设计），build.sh `:289-299/:383-384` 有非空断言 |
| 冗余 | 【已确认】benchmark 2 个 target 的 `GatherProtocol`（P2-4）；`GatherApp` 同时依赖 `GatherHost`+`GatherUI` 属必要（两文件都 import） |

## 5. 死代码 / 临时 / 未跟踪 / 构建产物

- 【已确认】审计开始时 `git status --porcelain`：**空**；`--untracked-files=all`：**空**（写报告后本文件 `??`；随后出现并行 agent 的 `ci.yml`/`check-layering.sh` 改动与 `final-gate-tests.md`，非本代理）；`--ignored=matching` 只有 `.build/`、`Capture_One_Plugin_SDK_(Mac)_v1.0.1/`（下载参考）、`desktop/coplugin/GatherLink.coplugin/`、`tests/fixtures/local/`。
- 【已确认】无构建产物入库（`.build|DerivedData|*.app|*.o|*.dSYM|node_modules` 0 命中）；无 `.orig/.bak/.rej/.swp/.log/.tmp` 入库。
- 【已确认】TODO/FIXME 0（全仓唯一 `XXX` 命中是 `FaceKwService+Analyze.swift:564` 的“\uXXXX 转义”说明）；`@available(*, deprecated)` 1（markWriting）；`@unchecked Sendable` baseline 54（`docs/cleanup-baseline.json`），本代理未复算。
- 【已确认】历史死符号确已清零：`JobScopeCheckpoint` / `makeGatherTestDB` / `GatherDomainChange` / `FaceSimMutationPort` / `VectorIndex.Candidate` / `appLocale` 全仓 0；`sha256File` 仅剩 `FileHasher` 一处定义 + 真实调用。
- 【已确认】测试基建无重复：`Tests/GatherTestSupport` 5 文件 604 行是唯一实现；app 侧 `Tests/GatherAppTests/ServiceConstructionTestSupport.swift:8` 只有 8 行 `@_exported import`。
- 【已确认】早前 P2 已闭环：`FileSystemDeliveryFilePort` 移入 `Tests/GatherTestSupport/FileSystemDeliveryFilePort.swift:15`（生产 0）；`GatherProgressBar.width` 已删（`GatherUI/Support/GatherCommonViews.swift:101-135` 只剩 fraction/fill/label/accessibilityText）；`StubSimilarityAPI` 私有副本已删（`APISimilarityUITests.swift:23` 注释 + `Support/StubSimilarityAPI.swift:67` 唯一实现）；`FilterEngine.simpleFields/metadataFields` 已删。
- 【已确认】12.6 GB 忽略产物与陈旧 `GatherCore` target 残留（P2-7）。

## 6. 已确认通过（可复算）

- 交付写路径：`DeliveryStateWriter` 模块外只暴露 5 个语义入口（`:319/357/388/413/422`），其余 20 个 internal；`DeliveryRepo` 写调用在 Delivery 外 0（Host 0、Application 0）。
- 错误码 → UI：单一漏斗 `GatherUI/Support/APIErrorPresentation.swift:22`（GatherError / SessionServiceError / APIError / RouterCommandError / BridgeError），`L10n.errorText` 未命中回退通用文案（`L10n.swift:263-265`），Delivery 11 码单表 `DeliveryErrorPresentation.swift:5-13`，挑片另有 `CullingViewModel+Writeback.swift:84` 码形漏斗。**无原始码直接上屏**。
- 重复 helper：`orderedUnion` / `parseBbox` 各 1 份，`patchFields` 0，`toFaceKwItem/toWritebackItem` 各 1 份（历史结论复核仍成立）。
- 旧文件头：全量比对 **599** 个带路径头注释的 Swift 文件与其真实路径，**0 错配**（路径头注释形如 `// desktop/native/...`；bash 循环逐文件比对，非抽样）。
- 迁移框架：`SchemaV1.createSQL`（`:842`）保留为 V1 真相源，当前版本 V2（`Migration/SchemaV2.swift`），`gather-schema` 可执行（`Sources/GatherSchema` 203 行，CI `:85` 跑 `verify`）。

## 7. 未执行 / 限制

- 本代理**未**运行 `swift build/test`、9 道门禁、`gather-schema verify`、`build.sh`；以上全部为静态证据，未经编译器再验证。
- 父代理实测（**引用，非本代理运行**）：core **1146 tests / 171 suites**、app **624 tests / 69 suites**、9 道门禁 + schema 全绿。
- 未做 GUI / 原生人工验收；未验证签名/公证/universal 产物。
- 未逐项验证拆分后跨文件 `private` 访问级是否逐一合法（需编译器）；未做运行时并发/竞态验证。
- 未复核 `.build` 内产物与源码的一致性（12.6 GB 为陈旧目录，可能早于 HEAD）。

## 8. 修复顺序建议

1. P1-2（半天）：sessions ack 读写下沉 Persistence 窄端口；`AssetRepo` 改名迁移改走 `DeliveryRelocation` 端口并迁移/清理 `delivery_intents`；`DeliveryRepo` 写方法降权 + `DeliveryWriting` 协议。
2. P1-1（1–2 天，纯移动）：`DeliveryRepo` → 读/写/行映射；`AssetRepo`/`FaceRepo` 同法；`ClusterGraph` → 建图/查询/序列化。
3. P2-1/P2-3/P2-4（低风险删改）：测试迁 `claimWriting` 后删 `markWriting`；删 `PhotoAssets.rawExtensions` 与过期注释；删 benchmark 的 `GatherProtocol` 依赖。
4. P2-7/P2-8：清 `.build` 与空 `Resources` 目录（发布前一次性）。
5. P2-5/P2-6/P2-9/P2-10：表驱动 translate、拆 800–1000 邻域与超大测试、`try!` 收敛、台账/索引修正。

## 9. 提交判定

- **可提交**：P0 = 0；P1 两条为口径级、无运行时断路；工作区在审计开始时干净、无产物/临时文件入库、依赖图与分层约束全部成立（本代理只新增本报告；其余改动来自并行 agent）。
- **不能宣称**：“仓库级 >1000 行 = 0”“写 owner 编译期唯一”“所有历史口径全部清零”——这三条与 §2 的证据不符。
- 合入前请以父代理的实测为准（core 1146/171、app 624/69、9 门禁全绿），本报告只负责静态残余清单。
