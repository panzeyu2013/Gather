# W2d 设计：IndexerRuntime + ExportRuntime + NavigationRuntime + FaceRuntime

> 来源：只读设计子代理 `a540ba89`（未改任何文件）。旧实现合计 3,771 行（Indexer 1160 / Export 617 / Navigation 558 / FaceKw 1436）；四者仅被 `SessionCommandRouter.swift` 引用；旧测试 67 个 @Test 均有承接。

## 0. 共性冻结约定
- **Store 统一放 `Sources/GatherCore/Store/`**（不在 Runtime 下建 Store 子目录）；仅新建 1 个跨聚合 Store：`Store/IndexerStore.swift`。
- **Runtime 禁 SQL/禁 `database.*`/禁 `SQLiteDatabase`；注释里也不能出现这些字面量**（门禁是文本 grep）；`@unchecked Sendable` 同理会误触度量。
- W2a 前置（名字冻结）：`ConcurrentMap.run(_:concurrency:body:)`、`SHA256.stream(of:chunkSize:)`、`TimeFormat.isoMilliseconds`、`Runtime/Support/JobProgressPort.swift`（协议 + 两代 job context 扩展）、`PhotoVariants`（`PhotoAssets` 迁移）、`PhotoFormats.rawExtensions` 取并集。
- 命名纪律：纯函数容器用 caseless enum 静态方法（避免与旧顶层函数重名）；public 错误类型 `IndexerError/ExportError/NavigationError/FaceError` **只能在删除旧服务文件的同一提交**启用（之前用临时 `*RuntimeError` + 机械 rename）。
- Face 写回 DTO 收敛到 `Protocol/Core.swift`；Face 契约结果迁 `Protocol/Face.swift`。

## 1. 四个 Runtime 的形态
| Runtime | 形态 | 状态 | 关键拆分文件 |
|---|---|---|---|
| Indexer | **struct: Sendable**（seam 注入化后无可变状态；actor 会串行化跨会话扫描→性能回归） | `stat`/`fileHasher` 可变接缝 → init 注入 `@Sendable`；`WalkChannel` 改 actor；`BatchCursor` → ConcurrentMap | `IndexerError`/`IndexerPaths`/`IndexerFileSystem`/`FileWalk`/`IndexerBatchPlan`/`ChecksumBackfillResult` + `Store/IndexerStore.swift` |
| Export | **actor** | `cancelled: Set<String>` + `activeCount`（唯一可变） | `ExportError`/`ExportValidation`/`ExportPaths`/`ExportVariants`/`ExportNaming`/`ExportTranscoder`/`ExportReportBuilder` |
| Navigation | **struct: Sendable**（无状态；纯 CPU 分组放 `Task.detached`） | 无 | `NavigationError`/`NavigationValidation`/`NavigationGrouping`/`NavigationFingerprint`/`CaptureQuality` |
| Face | **actor** | `flights: [String: FaceFlight]`（token UUID 取代 `===` 身份比较） | `FaceError`/`FaceInferenceContract`/`FaceAnalysisSignature`/`FaceClustering`/`FaceObservationCodec`/`FaceKeywordPlan`/`FaceBindingMigration`/`FaceClusterSummary` |

## 2. 重要语义修正（含真实缺陷）
| 编号 | 问题 | 修正 |
|---|---|---|
| **F5（P0，新发现）** | `replaceObservationsByPhoto` 先删 `face_observations`，而 `face_cluster_members.observation_id` 无 ON DELETE → **已有聚类时重新推理必然 FK 失败、分析永远 failed** | 同事务先 `UPDATE face_cluster_members SET observation_id=NULL WHERE session_id=? AND photo_id=?` 再删观测 |
| F1/F8 | 取消窗口（check→register 跨锁）、`recluster` 无并发守卫 | actor 无 await 临界区 check+register、token 比较、recluster 同 flight 互斥并可取消 |
| F2 | 关键词幂等/去重规则三处不一致 | 统一 `FaceKeywordPlan.normalizedKeywords`（bind/preview/unbind 共用） |
| F3/F4 | 聚类替换三步非原子（失败丢绑定）；早退判据不含观测版本 | `FaceStore.replaceClusters` 单事务；签名加 `obsVersion` |
| **E1（P0）** | 导出分组 key `assetId ?? id` 与全库 `COALESCE(NULLIF(asset_id,''),id)` 不一致 → `asset_id=''` 时整会话并成 1 组 | `ExportVariants` 用 `assetId.flatMap{ $0.isEmpty ? nil : $0 } ?? id`，并按首次出现序输出 |
| E3 | 取消先到被 `setCancelled(false)` 吞掉（`cancelled` 码不可达） | actor `cancelled` + activeCount，consume-on-completion，execute 不再清标志 |
| E4/E5 | `sourceMissing` 永不抛；全失败仍报成功 | 每文件存在性校验 → `EXPORT_SOURCE_MISSING`；计划非空且全失败 → `EXPORT_ALL_FAILED`（**待裁决**） |
| E7 | XMP 冲突两次 `Data(contentsOf:)` | `FileManager.contentsEqual` |
| I1（P1） | 缓存清扫未按 FK 顺序（6 张子表 NO ACTION） | `IndexerStore.purgeGeneratedCachePhotos` 单事务按依赖顺序 + 孤儿守卫 |
| I3/I4/I5/I6 | relink N+1、sha256 整读、backfill 跨页累积、pendingChecksums 全投影 | 批量 relink 单事务、`SHA256.stream`、流式分页、COUNT |
| **N1（P1）** | 导航指纹字段不全（缺 filepath/filename/cameraModel）+ `try!` | 固定字段序 + version 前缀 + 手写规范串 |
| N4/N6/N7 | split/merge 三步非原子；`withLead` 排序不稳定；`NAV_*` 码不可达 | Store 单事务 replace/merge；显式 tie-break；router 增映射 |

## 3. 跨波共享 Store 方法
`JobStore.insertAnalysisRun/finishAnalysisRun/latestAnalysisRun`（Similarity+Face 共用）、`Store/IndexerStore.swift`（5 方法，表范围冻结）、`PhotoStore.applyIndexWrites/updateChecksumIfEmpty/countPendingChecksums/reportRows`、`AssetStore.relinkMovedFiles`、`FaceStore.replaceClusters/roleBindingReportRows`、`CullingStore.decisionKinds`、`NavigationStore.replaceGroup/mergeGroups`。

## 4. 验收（四服务共同）
- 编译 0 error；core ≥ 基线且 67 个旧用例全部有归属；app 172/19；`Services layer` 25→21（本波 −4）。
- Runtime 内 0 SQL/0 NSLock/0 `@unchecked Sendable`/0 `Data(contentsOf:`；错误码逐字（`INDEX_*`/`EXPORT_*`/`NAV_*`/`FACE_*`/`FKW_*`）。
- 性能劣化 ≤10%：Indexer relink N→1、photo 写 N→1、pendingChecksums 全投影→COUNT、sha256 峰值 ≤2×chunk；Export 每文件恰 1 次 stat；Navigation 5 万行分组在 detached 线程；Face analyze Store 读次数 ≤ 旧实现。

## 5. 待裁决（11 项，摘要）
1 无状态 Runtime 用 struct（建议）；2 Export 全失败是否抛错；3 `fkw.cancel_analysis` 是否覆盖 recluster；4 Face 写回 DTO 收敛时机（建议同批）；5 `PhotoFormats.rawExtensions` 并集归属（会影响 `rawExtensionLikeSQL` 长度）；6 `JobProgressPort` 统一采用面；7 F5 修法（NULL 解链 vs 删成员行）；8 签名格式变化导致的一次性重算；9 门禁新增项是否转 enforced；10 **R7 证据更正：两个 `fkw.unbind` 分支（1521/2080）都要求 clusterId**，死分支差异仅是预检路径（我此前的 note 已过期，以本条为准）；11 `ExportResumeState` 观察者端口化时机。