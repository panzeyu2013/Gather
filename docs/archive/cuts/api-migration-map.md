# 118 命令 → 类型化 API 映射（Cut 0 盘点 + Cut 1 收口）

> **状态（2026-10-22，Cut 1 完成）**：118 条命令已全部落地为 **16 个协议 / 110 个方法**
> （TemplateAPI 6 个条件方法保留）；0 条字符串命令；**B0–B8 全部完成**。
> `SessionCommandRouter` / `CommandRouter` / `NativeCommandClient` /
> `check-command-surface.sh` 已删除。
>
> 依据：docs/reviews/refactor-design-breaking-2026-10-21.md §1（删除清单）、§3（类型化 API）、§8（清理计划）、§9（Cut 1）。
> 方法：Cut 0 逐 case 读取 `SessionCommandRouter.swift`（3,258 行）的 118 个 case，抽取参数、返回值、执行语义与全部校验点；Cut 1 按域落到 `GatherCore/API/*API.swift` 与 `gather-app/Host/APIs/*`。
> 边界：§2/§6 的行号与命令名是 **Cut 0 历史快照**，Router 已删除，不能按行号定位；新增代码以 API 协议与 Live 实现为准。逐条验收见 [cut1-completion-report.md](cut1-completion-report.md)。

---

## 0. 结论摘要

| 项 | 实测 | 证据 |
| --- | --- | --- |
| 命令总数 | **118**（82 sync + 36 async） | check-command-surface.sh 输出「注册 118 个 case 标签 / 118 个唯一命令」；sync switch 675-1639，async switch 1646-2560 |
| Router 规模 | 3,258 行、24 个注入依赖 | SessionCommandRouter.swift:100-151（db + 23 个服务/Repo） |
| 校验点 | requiredString 111、optionalString 31、confirmed 31、clampedLimit 4、clampedOffset 3、requirePhotoPath 2、allowedPhotoPaths 3、validatedString 6、数组校验 13、数值校验 31 | 见 §6 统计（不含函数定义行） |
| UI 派发点 | 12 个文件、**113 处**字面量派发（73 execute + 37 executeAsync + 3 enqueue），覆盖 83 条命令；另有 4 条经三元/变量派发 | grep execute("x.y") / executeAsync("x.y") / enqueue("x.y") |
| 无 UI 入口 | **31 条**（仅 CommandSurfaceRuntimeTests 黄金清单引用） | 见 §5；黄金清单位于 Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift:78-198 |
| 目标协议 → 已落地 | **16 个协议、110 个方法**（含 TemplateAPI 6 个条件方法） | 实测 16 个 `API/*API.swift` / 110 个协议方法（2026-10-22；证据见完成报告）；若删除 Template 域则为 15/104 |
| 落地状态 | **已全部落地** | `grep -rnE 'execute(Async)?\( *"' gather-app = 0`；Router/Client/脚本 0 文件；app 455/55、core 1080/149 绿 |
| 命令账 | 118 = 110 个行为方法 + 4 条被取代删除 + 4 条合并进同用例方法 | 见 §3/§4/§5 |

**一句话判断（Cut 0）：** 118 条命令里有 31 条在当前 UI 已无入口，4 条被同域新命令取代，4 条可与同用例命令合并；真正需要“一一保留行为”的是 110 个方法。命令面删得掉，但 Router 里的 **31 处 confirmed、111 处 requiredString、5 类范围/枚举校验** 必须在 Cut 1 逐条落到输入类型或 API 实现，否则会出现“能编译、能启动、但破坏性操作失去门禁”的静默回归。

**Cut 1 结果：** 110 个方法全部落地；破坏性入口改为 `Confirmed<T>`，输入校验在类型 `init`/`decode` 完成，路径授权由 `PhotoPathPolicy` 承担；执行结果与门禁见 [cut1-completion-report.md](cut1-completion-report.md)。

---

## 1. 盘点口径

### 1.1 文件与分段

| 区段 | 行号 | 内容 |
| --- | --- | --- |
| 依赖与构造 | 69-151 | 24 个 let 依赖；init 逐一赋值后 registerExecutors() |
| 便捷装配 | 178-383 | makeDefault（数据库 + XMP provider + 写去抖 + faceKw 注入） |
| Job executor 注册 | 384-665 | 把 job 类型映射到服务执行器（本表不展开，Cut 1 由 JobAPI 承接） |
| 同步命令 switch | 675-1639 | 82 个 case，execute(_:params:) |
| 异步命令 switch | 1646-2560 | 36 个 case，executeAsync(_:params:completion:)。未特化命令走 2552 的 GCD 回退调用 execute |
| 参数/校验 helper | 2565-2664 | requiredString/optionalString/validatedString/数组/数值/confirmed/clamp |
| 其余装配 helper | 2666-3258 | filters/patch/tags/export options/assignments/错误映射 |

### 1.2 计数（可由脚本复现）

- 域分布：culling 19、fkw 13、sim 10、session 8、person 8、metadata 7、settings 6、template 6、album 6、assets 5、jobs 4、navigation 4、dup 4、image 4、export 4、filter 3、photo 2、quality 2、workspace 1、face 1、index 1。
- 同步/异步：sync 82、async 36（check-command-surface.sh 独立复核）。
- 执行语义：job→wait 5 条（sim.recluster、sim.analyze、dup.scan、fkw.analyze、export.execute）；job 立即返回 5 条（session.create 的 filepaths 分支、session.create_from_directory、index.scan、quality.analyze、image.preload_thumbnails）；其余 async 为 Task 内直接 await 服务。
- 敏感面：confirmed 31 条、路径授权 4 条（image.*）、sourcePath 准入 2 条（session.create 的 sanitize + session.create_from_directory 的 service 目录/禁根校验）。

### 1.3 表内记号

- 输入：星号 * 表示必填、? 表示可选、=x 表示默认值、[T] 表示数组、E(a/b) 表示枚举白名单、Int(a…b) 表示整数范围。
- 语义：sync 同步返回；async 异步 executeAsync（Task 内 await）；job 建 job 立即返回；job→wait 建 job 并等待结果。
- 校验：C = confirmed；V = validatedString（长度/非空白）；L = clampedLimit；O = clampedOffset；R = 数值/整数/范围；E = 枚举；N = 非空数组/对象；T = 严格类型；P = 单路径授权 requirePhotoPath；A = 批量路径授权 allowedPhotoPaths；S = sourcePath 准入。
- 处置：保留；合并→X；删除（行为一并删除）；仅删命令（行为保留为 API 方法，字符串入口消失）。

---

## 2. 逐条映射（118 条）

### 2.1 session + workspace（9 条）

| # | 命令 | 行 | 输入（类型；默认/范围） | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | session.list | 678 | — | [SessionData] | sync | — | SessionAPI.list；保留 |
| 2 | session.get | 682 | sessionId:String* | SessionData | sync | 无记录→SESSION_NOT_FOUND | SessionAPI.get；保留 |
| 3 | session.create | 689 | name:String*；source:String="manual"；sourcePath:String?；filepaths:[String]?=[]；truncatedImport:Bool=false | 无 filepaths：SessionData；有 filepaths：{session, failedFiles, added, skipped} | sync；filepaths 分支另建 metadataScan job | S；T | SessionAPI.create → SessionCreateResult（统一两种形状）；合并 create_from_directory |
| 4 | session.create_from_directory | 2119 | name:String=""；sourcePath:String*（service 校验真实目录/禁根） | SessionData（另建 metadataScan job；job 创建失败回滚会话） | async（内联：建会话 + 建 job） | S（service）；T；失败回滚 | 合并→SessionAPI.create（M1）；仅删命令 |
| 5 | session.delete | 740 | sessionId:String*；confirmed:Bool=false | Void（null） | sync | C | SessionAPI.delete；合并 delete_many |
| 6 | session.delete_many | 745 | sessionIds:[String]*；confirmed | Void | sync | C；N | 并入 SessionAPI.delete(ids:) |
| 7 | session.update | 750 | sessionId:String*；name:String* | SessionData | sync | T（无长度上限） | SessionAPI.update；保留 |
| 8 | session.add_photos | 756 | sessionId:String*；filepaths:[String]*；source:String="import" | AddPhotoResult{added,skipped,total,failedFiles} | sync | T；N | SessionAPI.addPhotos；合并 create 的 filepaths 分支语义 |
| 9 | workspace.status | 810 | sessionId:String* | WorkspaceStatus | sync | 无记录→SESSION_NOT_FOUND | SessionAPI.status；保留 |

### 2.2 photo + filter + image（9 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | photo.list | 770 | sessionId:String* | [PhotoProjectionRow]（全量、无分页） | sync | — | **删除**（被 photo.list_page 取代；无 UI 调用） |
| 11 | photo.list_page | 792 | sessionId*；limit:Int=200（L 1…1000）；afterFirstRowid:Int64?；expandVariants:Bool=false | {rows:[PhotoPageRow], cursor:Int64?} | sync | L；T | PhotoAPI.page；保留 |
| 12 | filter.photos | 889 | sessionId*；sortBy?；sortOrder?；limit:Int=100（L 1…500）；offset:Int=0（O≥0） | [FilteredPhotoData] | sync | L；O；sort 由 service 解释（Router 无枚举校验，疑似缺口） | 合并→PhotoAPI.search |
| 13 | filter.photos_global | 908 | sessionId?；limit=100（1…500）；offset≥0 | {photos,total} | sync | L；O | PhotoAPI.search（sessionId 可选=全局）；合并 #12 |
| 14 | filter.suggest | 926 | sessionId*；keyword:String="" | [FilterSuggestion] | sync | — | PhotoAPI.suggestions；仅删命令（无 UI） |
| 15 | image.prioritize_thumbnail | 1366 | path:String*；size:Int=设置 thumbnail_size（R 64…8192） | Void | sync | P；R | PhotoAPI.prioritizeThumbnail；仅删命令 |
| 16 | image.preload_thumbnails | 1373 | paths:[String]?（A）；size:Int=设置值（无范围） | jobId:String | job（thumbnailBuild） | A | PhotoAPI.preloadThumbnails；仅删命令 |
| 17 | image.preload_previews | 1391 | paths:[String]?（A）；maxDimension:Int=2048（无范围） | Void | sync | A | PhotoAPI.preloadPreviews；仅删命令 |
| 18 | image.get_dimensions | 1397 | paths:[String]?（A）或 path:String*（P） | {width,height} 或 {path:{width,height}} | sync | P/A | PhotoAPI.dimensions(paths:) 单形态；合并双分支 |

### 2.3 culling（19 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 19 | culling.list_page | 1444 | sessionId*；scope:E（CullingScope）；filters:Object?（ratings 0…5、pickStates/colorLabels/qualityStatus 枚举、2 个 Bool）；groupId?；afterRowId:Int64?（R≥1 整数）；limit:Int=200（R 1…2000） | CullingPage | sync | E；R；N | CullingAPI.page；保留 |
| 20 | culling.history | 1480 | sessionId*；limit:Int?（R 1…500，默认 100） | [CullingHistoryOperation] | sync | R | CullingAPI.history；保留 |
| 21 | culling.apply_history | 1496 | sessionId*；entries:[{photoId*, expectedRevision:Int≥0, patch}]（1…10000）；historyOperationId:Int*（R≥1 整数）；direction:E（undo/redo） | [CullingUpdateResult] | sync | N；R；E | CullingAPI.applyHistory；保留 |
| 22 | culling.update | 1541 | sessionId*；photoId*；expectedRevision:Int*（R≥0 整数）；patch{rating 0…5, pickState E, colorLabel E} | CullingUpdateResult | sync | R；E | CullingAPI.update；保留 |
| 23 | culling.batch_update | 1557 | sessionId*；photoIds:[String]*（≤10000）；patch | [CullingUpdateResult] | sync | N；R | CullingAPI.batchUpdate；保留 |
| 24 | culling.decide_group | 1569 | sessionId*；groupId*；keepPhotoIds:[String]*（≤10000） | [CullingUpdateResult] | sync | N；R | CullingAPI.decideGroup；保留 |
| 25 | culling.sync_status | 1584 | sessionId* | MetadataSyncSummary + reloadAckedAt | sync | — | CullingAPI.syncStatus；保留 |
| 26 | culling.groups | 1595 | sessionId* | [CullingGroup] | sync | — | CullingAPI.groups；保留 |
| 27 | culling.decide | 1600 | sessionId*；photoId*；decision:E（keep/reject/pending） | Bool | sync | E | **删除**（旧 renderer 入口；被 culling.update 取代；仅测试引用） |
| 28 | culling.batch_decide | 1611 | sessionId*；photoIds*；decision:E | Bool | sync | E | **删除**（被 batch_update 取代；仅测试引用） |
| 29 | culling.summary | 1622 | sessionId* | CullingSummary | sync | — | CullingAPI.summary；保留 |
| 30 | culling.reset | 1627 | confirmed；sessionId*；groupId? | Bool | sync | C | CullingAPI.reset；保留 |
| 31 | culling.writeback | 2215 | confirmed；sessionId*；target:E（rating/color_label/keyword） | WritebackResult | async | C；E | CullingAPI.writeback；保留 |
| 32 | culling.flush | 2245 | sessionId* | MetadataSyncSummary | async | — | CullingAPI.flush；保留 |
| 33 | culling.retry_sync | 2261 | sessionId* | MetadataSyncSummary | async | — | CullingAPI.retrySync；保留 |
| 34 | culling.retry_failed_writeback | 1994 | confirmed；sessionId* | WritebackResult | async | C | CullingAPI.retryFailedWriteback；保留 |
| 35 | culling.cleanup | 2013 | confirmed；sessionId* | CleanupResult | async | C | CullingAPI.cleanup；保留 |
| 36 | culling.finalize_sync | 2513 | confirmed；sessionId* | MetadataSyncSummary | async | C | CullingAPI.finalizeSync；保留 |
| 37 | culling.confirm_sync | 2531 | sessionId* | Bool | async | — | CullingAPI.confirmSync；保留 |

### 2.4 face / fkw（14 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 38 | fkw.clusters | 1005 | sessionId* | [FaceClusterData] | sync | — | FaceAPI.clusters；保留 |
| 39 | fkw.bind | 1011 | sessionId*；clusterId:Int64*；roleName:String*；keywords:[String]*（元素必须 String） | {done} | sync | T；N | FaceAPI.bind；保留 |
| 40 | fkw.merge | 1028 | sessionId*；source:Int64*；target:Int64* | {done} | sync | — | FaceAPI.merge；保留 |
| 41 | fkw.remove_member | 1036 | sessionId*；clusterId:Int64*；memberId:Int64* | {done} | sync | — | FaceAPI.removeMember；保留 |
| 42 | fkw.cancel_analysis | 1045 | sessionId* | {done} | sync（cancelScope + service.cancel） | — | FaceAPI.cancelAnalysis；保留 |
| 43 | fkw.analyze | 1795 | sessionId*；eps:Double?（R 0…1）；minSamples:Double?（R 1…1e6 整数）；detectorPath:String?=设置；encoderPath:String?=设置 | FaceAnalysisResult | job→wait（faceAnalyze） | R | FaceAPI.analyze；保留 |
| 44 | fkw.recluster | 1836 | sessionId*；eps?（0…1）；minSamples?（1…1e6） | {done} | async | R | FaceAPI.recluster；保留 |
| 45 | fkw.unbind | 1857 | confirmed；sessionId*；clusterId:Int64*（无整数/范围校验） | FkwUnbindResult | async | C | FaceAPI.unbind；保留 |
| 46 | fkw.preview | 1881 | sessionId*；options?{createAlbums,addPrefix,markUngrouped,writeIPTC} | FaceKwWritebackPreview | async | — | FaceAPI.preview；保留 |
| 47 | fkw.writeback | 1897 | confirmed；sessionId*；items:[FaceKwWritebackItem]?（nil→[]，非数组→FKW_ITEMS_INVALID） | FaceKwWritebackResult | async | C；T | FaceAPI.writeback；保留 |
| 48 | fkw.confirm_sync | 1925 | sessionId* | Bool | async | — | FaceAPI.confirmSync；保留 |
| 49 | fkw.confirm_cleanup | 1939 | confirmed；sessionId* | FaceKwCleanupResult | async | C | 合并→FaceAPI.cleanup（函数体与 49 逐字相同） |
| 50 | fkw.cleanup | 1958 | confirmed；sessionId* | FaceKwCleanupResult | async | C | FaceAPI.cleanup；保留 |
| 51 | face.models_status | 1429 | —（读 settings + 文件存在性） | {provider,fallbackToOnnxEnabled,modelsPresent,downloading} | sync | — | FaceAPI.modelsStatus；保留 |

### 2.5 similarity（10 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 52 | sim.result | 955 | sessionId*；threshold:Double?（直接 Int() 截断，无范围） | SimilarityResult?（无结果 null） | sync | — | SimilarityAPI.result；保留 |
| 53 | sim.cancel_analysis | 964 | sessionId* | Bool | sync | — | SimilarityAPI.cancelAnalysis；保留 |
| 54 | sim.recluster | 1675 | sessionId*；threshold:Double?（R 0…64 整数，默认设置 10）；minGroupSize:Double?（R≥2 整数，默认 2）；groupingMode:String?（仅 "sequential"，其余静默=global） | SimilarityResult? | job→wait（similarityAnalyze，checkpoint.operation=recluster） | R；E（软） | SimilarityAPI.recluster；保留 |
| 55 | sim.analyze | 1720 | 同 53（checkpoint 保留 null 表示缺省） | Bool | job→wait（similarityAnalyze） | R；E（软） | SimilarityAPI.analyze；保留（建议统一返回 SimilarityResult） |
| 56 | sim.preview_writeback | 2442 | sessionId*；assignments:[SimilarityKeywordAssignment]*（逐项校验）；threshold:Double? | WritebackPreview | async | T；R | SimilarityAPI.previewWriteback；保留 |
| 57 | sim.writeback | 2459 | confirmed；sessionId*；itemIds:[Int]*（非空，否则 SIM_PREVIEW_REQUIRED）；threshold?（查 hasResult） | WritebackResult | async | C；N；R | SimilarityAPI.writeback；保留 |
| 58 | sim.writeback_items | 1227 | sessionId* | [WritebackItem] | sync | — | SimilarityAPI.writebackItems；建议并入 previewWriteback 返回 |
| 59 | sim.confirm_sync | 2499 | sessionId* | Bool | async | — | SimilarityAPI.confirmSync；保留 |
| 60 | sim.retry_failed_writeback | 2032 | confirmed；sessionId* | WritebackResult | async | C | SimilarityAPI.retryFailedWriteback；保留 |
| 61 | sim.cleanup | 2051 | confirmed；sessionId* | CleanupResult | async | C | SimilarityAPI.cleanup；保留 |

### 2.6 duplicate（4 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 62 | dup.resolve | 981 | confirmed；groupId:Int*；resolution:E（keep_one/keep_all） | Bool | sync | C；E | DuplicateAPI.resolve；保留 |
| 63 | dup.resolve_member | 994 | confirmed；memberId:Int*；isKept:Bool=true | Bool | sync | C | DuplicateAPI.resolveMember；保留 |
| 64 | dup.scan | 1762 | sessionId*；visualThreshold:Double?（R 0…64 整数） | DuplicateScanResult | job→wait（duplicateScan） | R | DuplicateAPI.scan；保留 |
| 65 | dup.groups | 1980 | sessionId* | [DuplicateGroup] | async | — | DuplicateAPI.groups；保留 |

### 2.7 export（4 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 66 | export.cancel | 1416 | sessionId* | Bool | sync（cancelScope(exportExecute) + service.cancel） | — | ExportAPI.cancel；保留 |
| 67 | export.report | 1422 | sessionId*；reportType:String="session_summary"；format:String? | ReportData | sync | 无枚举校验（疑似缺口） | ExportAPI.report；保留 |
| 68 | export.preview | 2278 | sessionId*；options:ExportOptions?=空对象 | ExportPreview | async | T（options 解码） | ExportAPI.preview；保留 |
| 69 | export.execute | 2323 | confirmed；sessionId*；options?=空对象 | ExportResult | job→wait（exportExecute，先 start） | C；T | ExportAPI.execute；保留 |

### 2.8 metadata（7 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 70 | metadata.orphans | 1219 | — | [MetadataOrphan] | sync | — | MetadataAPI.orphans；保留 |
| 71 | metadata.resolve_conflict | 2146 | confirmed；sessionId*；xmpPath*；choices:Object*{field:E(MetadataField)→choice:E(MetadataConflictChoice)} | MetadataSyncSummary | async | C；E；N | MetadataAPI.resolveConflict；保留 |
| 72 | metadata.resolve_orphan | 2188 | confirmed；xmpPath*；action:E（MetadataOrphanAction） | [MetadataOrphan] | async | C；E | MetadataAPI.resolveOrphan；保留 |
| 73 | metadata.get | 2367 | photoIds:[String]*（非空） | {photoId: MetadataTags} | async | N | MetadataAPI.get；仅删命令 |
| 74 | metadata.set | 2385 | confirmed；photoId*；tags:Object?（非对象按空对象，TS 强转） | MetadataTags | async | C；T（宽松） | MetadataAPI.set；仅删命令 |
| 75 | metadata.batch_set | 2404 | confirmed；updates:[{photoId*, tags?}]*（非空） | BatchMetadataResult | async | C；N；T | MetadataAPI.batchSet；仅删命令 |
| 76 | metadata.conflicts | 2428 | sessionId* | [MetadataConflict] | async | — | MetadataAPI.conflicts；保留 |

### 2.9 person（8 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 77 | person.list | 1054 | — | [PersonData] | sync | — | PersonAPI.list；保留 |
| 78 | person.get | 1059 | personId* | PersonDetailData | sync | 无记录→PERSON_NOT_FOUND | PersonAPI.get；保留 |
| 79 | person.create | 1087 | name:String*（V ≤4096 非空白）；keywords:[String]? | {id:String} | sync | V | PersonAPI.create；保留 |
| 80 | person.update | 1094 | personId*；name?（trim）；keywords?；notes?；matchThreshold:Double? | {done} | sync | — | PersonAPI.update；保留 |
| 81 | person.delete | 1101 | confirmed；personId* | {done} | sync | C | PersonAPI.delete；保留 |
| 82 | person.merge | 1110 | confirmed；sourceId*；targetId* | {done} | sync | C | PersonAPI.merge；仅删命令 |
| 83 | person.remove_photo | 1120 | confirmed；personId*；photoId* | {done} | sync | C | PersonAPI.removePhoto；仅删命令 |
| 84 | person.search_photos | 1130 | personId*；sessionIds?；limit:Int?；offset:Int?（Int() 截断，无钳制） | {photos,total} | sync | — | PersonAPI.searchPhotos；仅删命令 |

### 2.10 album（6 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 85 | album.create | 1271 | name:String*（V）；criteria:FilterGroup*（parse + buildWhereClause）；sortBy?；sortOrder?；description?；icon? | SmartAlbumDetailData | sync | V；E（filter 结构） | AlbumAPI.create；保留 |
| 86 | album.list | 1286 | — | [SmartAlbumData]（损坏 criteria 带 validationError） | sync | — | AlbumAPI.list；保留 |
| 87 | album.get | 1310 | albumId* | SmartAlbumDetailData | sync | 无记录→ALBUM_NOT_FOUND | **删除**（get_photos 已复用 albumDetailData；无 UI 调用） |
| 88 | album.update | 1318 | albumId*；name?；description?；criteria:Object?；sortBy?；sortOrder?；icon? | {done} | sync | criteria 必须 Object | AlbumAPI.update；保留 |
| 89 | album.delete | 1337 | confirmed；albumId* | {done} | sync | C | AlbumAPI.delete；保留 |
| 90 | album.get_photos | 1346 | albumId*；limit:Int=100（L 1…500）；offset≥0（O） | {photos,total} | sync | L；O | AlbumAPI.photos；保留 |

### 2.11 navigation（4 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 91 | navigation.list | 935 | sessionId* | [NavigationGroup] | sync | — | NavigationAPI.list；保留 |
| 92 | navigation.split | 939 | sessionId*；groupId*；beforePhotoId* | [NavigationGroup] | sync | — | NavigationAPI.split；保留 |
| 93 | navigation.merge | 947 | sessionId*；groupIds:[String]* | [NavigationGroup] | sync | N | NavigationAPI.merge；保留 |
| 94 | navigation.analyze | 1649 | sessionId*；burstGapSeconds:Double=2；sceneGapSeconds:Double=1800；dryRun:Bool=false | [NavigationGroup] | async | 范围由 service 校验（NAV_*） | NavigationAPI.analyze；保留 |

### 2.12 jobs + index（5 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 95 | jobs.list | 822 | includeCheckpoint:Bool=true | [AnalysisJobData] | sync | — | JobAPI.list；保留 |
| 96 | jobs.cancel | 830 | jobId* | Bool | sync | — | JobAPI.cancel；保留 |
| 97 | jobs.retry | 835 | jobId* | Bool | sync | — | JobAPI.retry；保留 |
| 98 | jobs.clear_completed | 841 | confirmed | Int（删除行数） | sync | C | JobAPI.clearCompleted；仅删命令（无 UI） |
| 99 | index.scan | 2072 | sessionId* | AnalysisJobData | job（metadataScan，立即返回） | — | JobAPI.start(.metadataScan)；合并 |

### 2.13 settings（6 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | settings.get_all | 849 | — | [String:String] | sync | — | SettingsAPI.all；保留 |
| 101 | settings.get | 853 | key:String*（V ≤256，trim） | String | sync | V | SettingsAPI.get；保留 |
| 102 | settings.set | 858 | key:String*（V ≤256）；value:String*（V ≤4096，allowEmpty） | {done} | sync | V | SettingsAPI.set；保留 |
| 103 | settings.reset | 865 | — | [String:String] | sync | — | SettingsAPI.reset；保留 |
| 104 | settings.set_language | 871 | language:E（"zh-CN"/"en"）* | {language} | sync | E | SettingsAPI.setLanguage；保留 |
| 105 | settings.get_ml_status | 883 | — | MLStatusData | sync | — | SettingsAPI.mlStatus；保留（可与 face.models_status 合并，见 §4.3） |

### 2.14 assets（5 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 106 | assets.candidates | 974 | sessionId:String? | [AssetLinkCandidateData] | sync | — | AssetAPI.candidates；保留 |
| 107 | assets.accept_candidate | 1234 | confirmed；candidateId* | Bool | sync | C | AssetAPI.accept；保留 |
| 108 | assets.reject_candidate | 1245 | confirmed；candidateId* | Bool | sync | C | AssetAPI.reject；保留 |
| 109 | assets.volumes | 1254 | — | [AssetVolumeData] | sync | — | AssetAPI.volumes；保留 |
| 110 | assets.relink_root | 1258 | confirmed；oldRoot*；newRoot* | Int（重链行数） | sync | C | AssetAPI.relinkRoot；保留 |

### 2.15 template（6 条 · 条件保留）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 111 | template.create | 1145 | name:String*（V）；description:String=""；config:Object*（WorkflowTemplateConfig） | TemplateData | sync | V；T | TemplateAPI.create；仅删命令（0 UI 调用，需产品确认） |
| 112 | template.list | 1156 | — | [TemplateData] | sync | — | TemplateAPI.list；同上 |
| 113 | template.get | 1159 | templateId* | TemplateData | sync | 无记录→TEMPLATE_NOT_FOUND | TemplateAPI.get；同上 |
| 114 | template.update | 1166 | templateId*；name?；description?；config? | TemplateData | sync | config 必须 Object | TemplateAPI.update；同上 |
| 115 | template.delete | 1185 | confirmed；templateId* | {done} | sync | C | TemplateAPI.delete；同上 |
| 116 | template.apply | 1194 | confirmed；templateId*；sessionId* | {done} | sync | C | TemplateAPI.apply；同上 |

### 2.16 quality（2 条）

| # | 命令 | 行 | 输入 | 输出 | 语义 | 校验 | 建议 API |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 117 | quality.get | 1206 | sessionId*；photoIds:[String]? | [QualityResult] | sync | — | QualityAPI.results；仅删命令（无 UI 读取方） |
| 118 | quality.analyze | 2090 | sessionId*；photoIds:[String]?（提供但为空→INVALID_PARAM） | AnalysisJobData | job（qualityScore） | N | QualityAPI.analyze；保留 |

> 编号说明：全表连续编号 1-118，共 118 条命令（2.1 含 workspace.status 与 create_from_directory）。

---

## 3. 域归组与建议协议（16 个 / 110 方法）

| # | 协议 | 覆盖命令（条） | 方法数 | 方法清单 |
| --- | --- | --- | --- | --- |
| 1 | SessionAPI | session 8 + workspace 1 = 9 | 7 | list、get、create、update、delete(ids:)、addPhotos、status |
| 2 | PhotoAPI | photo 2 + filter 3 + image 4 = 9 | 7 | page、search、suggestions、dimensions、prioritizeThumbnail、preloadThumbnails、preloadPreviews |
| 3 | CullingAPI | 19 | 17 | page、history、applyHistory、update、batchUpdate、decideGroup、groups、summary、syncStatus、reset、writeback、flush、retrySync、retryFailedWriteback、cleanup、finalizeSync、confirmSync |
| 4 | FaceAPI | fkw 13 + face 1 = 14 | 13 | clusters、bind、merge、removeMember、analyze、recluster、cancelAnalysis、unbind、preview、writeback、confirmSync、cleanup、modelsStatus |
| 5 | SimilarityAPI | 10 | 10 | result、analyze、recluster、cancelAnalysis、previewWriteback、writebackItems、writeback、confirmSync、retryFailedWriteback、cleanup |
| 6 | DuplicateAPI | 4 | 4 | scan、groups、resolve、resolveMember |
| 7 | ExportAPI | 4 | 4 | preview、execute、cancel、report |
| 8 | MetadataAPI | 7 | 7 | get、set、batchSet、conflicts、orphans、resolveConflict、resolveOrphan |
| 9 | PersonAPI | 8 | 8 | list、get、create、update、delete、merge、removePhoto、searchPhotos |
| 10 | AlbumAPI | 6 | 5 | create、list、update、delete、photos |
| 11 | NavigationAPI | 4 | 4 | list、split、merge、analyze |
| 12 | JobAPI | jobs 4 + index 1 = 5 | 5 | list、cancel、retry、clearCompleted、start(JobRequest) |
| 13 | SettingsAPI | 6 | 6 | all、get、set、reset、setLanguage、mlStatus |
| 14 | AssetAPI | 5 | 5 | candidates、volumes、accept、reject、relinkRoot |
| 15 | QualityAPI | 2 | 2 | analyze、results |
| 16 | TemplateAPI（条件） | 6 | 6 | create、list、get、update、delete、apply |
| **合计** | **16** | **118** | **110** | — |

**归属原则（与方案 §3.1 对齐）：**

1. **SessionAPI 吸收 workspace.status**：它是“会话工作区状态”，不是独立域；Dashboard 已绕过 Router 直连 SessionService（DashboardViewModel.swift:94-129），Cut 1 必须把它一并切到 SessionAPI，否则会留下第二套入口。
2. **PhotoAPI 吸收 filter 与 image**：三者共用 photos 表的读路径与路径授权；filter.* 是查询 DSL，image.* 是同一照片集合的派生媒体，不构成独立限界上下文。
3. **JobAPI 吸收 index.scan 与 quality.analyze 的“建 job”面**：两者都只是 JobService.create 的形状；具体执行仍由 Job executor 归属域服务。quality.get 留在 QualityAPI。
4. **Culling/Face/Similarity 各自保留 writeback/confirm/cleanup**（方案 §3.1 的 CullingAPI 已如此）：Cut 2 的 DeliveryCoordinator 是它们的共同实现，不是新的公共协议，避免 UI 依赖跨域聚合。
5. **TemplateAPI 单独存在但标条件**：6 条命令 0 UI 调用（§5），若产品确认不做模板功能，Cut 1 直接删除该协议，总数变 **15 协议 / 104 方法**。

---

## 4. 合并清单

### 4.1 已计入 110 方法的合并（4 组）

| ID | 合并对象 | 证据 | 合并后语义 | 输出统一 |
| --- | --- | --- | --- | --- |
| M1 | session.create + session.create_from_directory（add_photos 共用导入输入类型，方法保留） | 689-739、2119-2145、756-769 | SessionAPI.create(SessionCreateInput)：目录会话走 createFromDirectory，文件导入走 create + addPhotos + metadataScan job；addPhotos 单独保留给“向已存在会话追加” | SessionCreateResult{session, added, skipped, failedFiles}；不再出现 SessionData / 对象两形状 |
| M2 | session.delete + session.delete_many | 740-749 | SessionAPI.delete(ids:[String], Confirmed)；单条是 ids.count==1 的语法糖 | Void；删除条数可由返回 Int 表达 |
| M3 | filter.photos + filter.photos_global | 889-925 | PhotoAPI.search(PhotoQuery)：sessionId == nil 即全局；同一 PageRequest、同一排序 | PhotoPage{photos,total}（现 889 返回裸数组，需统一） |
| M4 | fkw.confirm_cleanup + fkw.cleanup | 1939-1975（函数体逐字相同） | FaceAPI.cleanup(Confirmed<SessionId>) | FaceKwCleanupResult |

### 4.2 已计入“删除”的取代（4 组）

| ID | 删除对象 | 取代者 | 证据 |
| --- | --- | --- | --- |
| R1 | photo.list | photo.list_page | 770-791 无分页全量；792-809 键集分页；UI 仅调用 list_page（GalleryViewModel.swift:141） |
| R2 | culling.decide | culling.update | 1600-1608 注释“旧版 renderer 单张决策”；1541-1554 为当前写路径；UI 无调用 |
| R3 | culling.batch_decide | culling.batch_update | 1611-1619 注释“旧版 renderer 批量决策”；1557-1566 为当前写路径；UI 无调用 |
| R4 | album.get | album.get_photos | 1310-1316 与 1346-1365 都通过 albumDetailData(row:)；get_photos 已含详情+分页，UI 只用 list/get_photos |

### 4.3 可选进一步合并（不改变 110 基线，建议 Cut 1 评估）

| ID | 对象 | 建议 | 收益/风险 |
| --- | --- | --- | --- |
| O1 | sim.writeback_items → sim.preview_writeback | preview 返回 items:[WritebackItemPreview]（含 id），删除独立读方法 | -1 方法；需确认 SimilarityViewModel:235 的“先取 items 再 preview”流程可合并 |
| O2 | jobs.clear_completed | 无 UI，删除 | -1 方法；功能可由 JobService 维护命令替代 |
| O3 | face.models_status + settings.get_ml_status | 统一为 SettingsAPI.mlStatus（含 face 段） | -1 方法；两者形状不同，需合并 DTO |
| O4 | culling.flush + culling.retry_sync | CullingAPI.sync(mode: .flush/.retry) | -1 方法；UI 已用三元切换（CullingView.swift:1198），合并自然 |
| O5 | sim.analyze + sim.recluster | SimilarityAPI.analyze(mode:)，统一返回 SimilarityResult | -1 方法；现 analyze 返回 Bool、recluster 返回 Result，属行为不一致 |
| O6 | session.add_photos + create(filepaths) | 只保留 addPhotos，create 仅建会话 | -0 方法（M1 已表达）；避免 create 内隐式 job/回滚逻辑重复 |

> 若 O1/O2/O3/O4/O5 全采纳：**15 协议 / 105 方法**（Template 保留）；再删 Template 则 **15 / 99**。本文以 16/110 作为 Cut 1 的基线，避免一次改太多语义。

---

## 5. 删除与裁决清单

### 5.1 真删除（行为不再保留，4 条）

| 命令 | 行 | 证据 | 结论 |
| --- | --- | --- | --- |
| photo.list | 770 | 无 UI 调用；全量无分页，与 list_page 重叠 | 删除 |
| culling.decide | 1600 | 仅 CommandSurfaceRuntimeTests 引用；update 已覆盖 | 删除 |
| culling.batch_decide | 1611 | 仅测试引用；batch_update 已覆盖 | 删除 |
| album.get | 1310 | 仅测试引用；get_photos 复用同一 detail 构造 | 删除 |

### 5.2 仅测试引用（31 条，Cut 0 历史）

**历史证据：** 对 12 个 UI 目录执行 execute/executeAsync/enqueue("x.y") 扫描，以下 31 条命令在 UI 侧 0 命中；其唯一外部引用是 `Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift:78-198` 的 118 条黄金清单（82 sync + 36 async）。该文件已随 B8.4 删除，下表保留行为去向，不再是“现存引用”状态。

| 类别 | 命令 | 建议 |
| --- | --- | --- |
| session 写路径（6） | session.create、session.delete、session.delete_many、session.update、session.add_photos、session.create_from_directory | 行为已由 Dashboard 与菜单直连 sessionService 覆盖（DashboardViewModel.swift:94-129、GatherApp.swift:251-273），**仅删命令**，方法保留 |
| filter（2） | filter.photos、filter.suggest | photos 合并进 search；suggest 保留方法 |
| photo（1） | photo.list | 真删除（R1） |
| album（1） | album.get | 真删除（R4） |
| culling（2） | culling.decide、culling.batch_decide | 真删除（R2/R3） |
| fkw（1） | fkw.confirm_cleanup | 合并（M4） |
| image（4） | image.prioritize_thumbnail、image.preload_thumbnails、image.preload_previews、image.get_dimensions | 仅删命令；方法保留在 PhotoAPI |
| jobs（1） | jobs.clear_completed | 仅删命令（或 O2 删除） |
| person（3） | person.merge、person.remove_photo、person.search_photos | 仅删命令；方法保留 |
| template（6） | template.create/list/get/update/delete/apply | **条件删除**：无 UI、无服务层其他消费者；若产品不做模板则整域删除 |
| quality（1） | quality.get | 仅删命令；无 UI 读取方，建议评估删除行为 |
| metadata（3） | metadata.get、metadata.set、metadata.batch_set | 仅删命令；当前无元数据编辑 UI |

**注：** culling.flush、culling.retry_sync、assets.accept_candidate、assets.reject_candidate 虽无字面量调用，但经三元/变量派发（CullingView.swift:1198、LibraryViewModel.swift:272），**不算** test-only，必须保留。

### 5.3 保留（87 条）

其余 87 条均有 UI 派发点或变量派发，一一映射到 §2 的协议方法。

---

## 6. 校验逻辑清单（Cut 1 不得丢失）

### 6.1 helper 统计与承载方式

| 规则 | 调用数 | 现状语义（行） | Cut 1 承载 | 丢失风险 |
| --- | --- | --- | --- | --- |
| requiredString | 111 | 非 String/缺失→MISSING_PARAM:key（2565-2570） | 输入类型非可选 String；解码失败→GatherError（错误码方案见 §8 R1） | 若用 optional 默认空串，会静默接受缺失 |
| optionalString | 31 | null→nil；非 String→INVALID_PARAM:key（2591-2599） | String?；类型错误在 decode 期失败 | 若 tolerant decode，错类型会变 nil |
| validatedString | 6 | 长度上限（默认 4096）、非空白 trim；allowEmpty 例外（2603-2617） | BoundedString/NonBlankString，在 init 校验 | settings key 256、value 4096 的上限易漏 |
| requiredStringArray | 7 | 缺失→MISSING；元素非 String→INVALID（2619-2629） | [String]，元素类型编译期保证 | 元素混入数字被静默丢弃（旧 compactMap 已修） |
| optionalStringArray | 6 | null→nil；非数组/含非 String→INVALID（2870-2880） | [String]? | 同上 |
| requiredNumber | 8 | 缺失/非 number/NaN/∞→INVALID（2637-2642） | Double/Int 类型 + init 范围 | 整数位截断（见 6.3） |
| optionalNumber | 23 | 非 number/NaN/∞→**nil**（2631-2634） | 严格 Double?，类型错不降级 | 最危险：错类型变默认值 |
| optionalBool | 4 | 非 bool→nil（2644-2647） | Bool?/默认值 | 同 optionalNumber |
| confirmed | 31 | 仅 .bool(true) 为真（2649-2652） | Confirmed<T>，构造受控 | **P0**：漏一条即破坏性操作无门禁 |
| clampedLimit | 4 | floor 后 clamp 1…max；缺省 default（2655-2658） | PageRequest.limit（同名默认/上限） | 上限值：photo 1000、filter 500、album 500 |
| clampedOffset | 3 | floor 后 max(0, ·)（2661-2664） | PageRequest.offset | 负数/小数钳制 |
| requirePhotoPath | 2 | 非空、≤4096、必须存在于 photos 表，否则 PHOTO_NOT_FOUND（2575-2580） | PhotoPathPolicy.requireKnown(_:) | 任意文件读取 oracle |
| allowedPhotoPaths | 3 | 过滤空/超长/不存在/去重（2582-2589） | PhotoPathPolicy.filterKnown(_:) | 批量路径越权 |
| requireObject / requiredSubString | 1+1 | batch_set 逐项校验（2882-2901） | [MetadataUpdate] 类型化 | 逐项 photoId 缺失 |

### 6.2 命令级校验映射（逐条）

| 命令（行） | 校验 | Cut 1 输入类型/实现 |
| --- | --- | --- |
| session.create（689） | sourcePath 禁根；带 filepaths 时仅接受 ≥2 张照片的真实公共父目录（702-709，SessionService.swift:299） | SessionCreateInput.init 调 sanitizeSessionSourcePath；违规则 sourcePath=""（保留现语义，不抛错） |
| session.delete/delete_many（740/745） | confirmed | Confirmed<SessionIds> |
| session.create_from_directory（2119） | sourcePath 必须是真实目录且非禁根/主目录祖先（service 层 SessionService.swift:86-105） | SessionAPI.create 的目录分支复用同一规则；不要只依赖 UI 选择器 |
| settings.get/set（853/858） | key ≤256、value ≤4096 allowEmpty（855-861） | SettingsKey、SettingsValue（BoundedString） |
| settings.set_language（871） | 仅 zh-CN/en（873-875） | Language enum |
| filter.photos/global（889/908） | limit 1…500 默认 100；offset≥0（896-897/912-913） | PageRequest(default:100,max:500) |
| sim.result（955） | threshold→Int 截断，无范围 | Int? + 0…64 校验（**补缺口**） |
| dup.resolve（981） | resolution ∈ keep_one/keep_all（986-989） | DupResolution |
| fkw.bind（1011） | keywords 必须 String 数组（1017-1021） | [String] 非可选 |
| template.create/update（1145/1166） | config 必须 Object（1149-1151/1176-1179） | WorkflowTemplateConfig |
| album.create（1271） | criteria 必填 + buildWhereClause（1274-1275） | FilterGroup |
| album.update（1318） | criteria 存在时必须 Object（1324-1326） | FilterGroup? |
| image.*（1366-1413） | size 64…8192（1369）；路径授权（1368/1374/1392/1400/1411） | ImageRequest + PhotoPathPolicy |
| culling.list_page（1444） | scope 枚举；filters 白名单/ratings 0…5/pickStates/colorLabels/qualityStatus；afterRowId≥1；limit 1…2000 默认 200（1446-1473） | CullingPageQuery（scope enum + CullingFilters + afterRowId + PageRequest(200,2000)） |
| culling.history（1480） | limit 1…500 默认 100（1483-1491） | HistoryQuery |
| culling.apply_history（1496） | entries 1…10000；逐项 photoId/expectedRevision≥0/patch；historyOperationId≥1；direction undo/redo（1498-1531） | [CullingHistoryApplyEntry] + NonEmpty + Direction |
| culling.update（1541） | expectedRevision≥0；patch 字段枚举/0…5（1544-1549，3031-3059） | CullingUpdatePatch |
| culling.batch_update/decide_group（1557/1569） | photoIds ≤10000；keepPhotoIds ≤10000 | BoundedArray(10000) |
| culling.reset（1627） | confirmed | Confirmed<CullingResetInput> |
| culling.writeback（2215） | confirmed；target 枚举（2228-2230） | Confirmed<CullingWritebackInput> |
| export.preview/execute（2278/2323） | options 解码；execute confirmed（2324） | ExportInput + Confirmed<ExportInput>；指纹在 API 实现内 |
| metadata.resolve_conflict（2146） | choices Object；field/choice 枚举（2159-2175） | [MetadataField: MetadataConflictChoice] |
| metadata.resolve_orphan（2188） | action 枚举（2197-2200） | MetadataOrphanAction |
| metadata.get（2367） | photoIds 非空（2368） | NonEmpty<[String]> |
| metadata.set（2385） | confirmed；photoId 必填；tags 缺失/非对象→空对象，解码失败→MISSING_PARAM:tags（2386-2393） | Confirmed<MetadataSetInput>；tags 用显式空对象常量，不把错类型当空 |
| metadata.batch_set（2404） | updates 非空；逐项 photoId（2409-2419） | [MetadataUpdate] |
| sim.preview_writeback（2442） | assignments 校验（2443-2446，3078-3102） | [SimilarityKeywordAssignment] |
| sim.writeback（2459） | itemIds 非空（2472）；threshold 有结果（2478-2481）；pending 数量匹配（2487-2489） | Confirmed<SimilarityWritebackInput>；stale 检查留在 API 实现 |
| quality.analyze（2090） | photoIds 提供但为空→INVALID（2095-2099） | [String]? + 非空校验 |
| fkw.analyze/recluster（1795/1836） | eps 0…1；minPts 1…1e6 整数（1692/1735/1808/1847） | FaceClusteringParameters |
| dup.scan（1762） | visualThreshold 0…64 整数（1770-1771） | Threshold（DHash.isValidThreshold） |
| navigation.analyze（1649） | 默认 2/1800；范围由 service（1654-1662） | NavigationAnalyzeInput（默认值保留） |

### 6.3 已确认的校验缺口（Cut 1 应一并修复，勿原样搬运）

| # | 位置 | 现状 | 影响 |
| --- | --- | --- | --- |
| G1 | 2631-2634 optionalNumber | 类型错误/NaN/∞ 静默返回 nil，调用方回落默认值（如 sim threshold 变设置默认） | 错误输入被“成功”处理 |
| G2 | 958、985、998、1014、1031-1040、1134-1135、1376、1393、1866 | Int(double)/Int64(double) 直接截断，无整数/范围校验 | 小数/越界被截断；fkw.unbind 的 clusterId 可被截断到错误簇 |
| G3 | 1687-1691、1727-1731 | groupingMode 仅识别 "sequential"，其余（含非法值）静默变 global；枚举 SIM_GROUPING_MODE_INVALID 未使用 | 非法参数被接受 |
| G4 | 1496-1521 | entries 的 photoId 允许空串（stringValue 非空未校验） | 由 service 兜底，错误码不稳定 |
| G5 | 2368 | metadata.get 只校验非空，不去重/不限长 | 大批量查询无上限 |
| G6 | 2385-2393 | metadata.set 的 tags 非对象按空对象处理（TS 强转） | 错类型静默清空标签 |
| G7 | 1369 vs 1376/1393 | image 仅 prioritize 对 size 做 64…8192 钳制；preload 的 size/maxDimension 无范围 | 负值/0 传入解码层 |
| G8 | 1422-1427 | export.report 的 reportType/format 为自由字符串，Router 侧无枚举（service 是否兜底未确认） | 非法类型可能到服务层才失败 |
| G9 | 2468-2471 | sim.writeback 的 itemIds 静默丢弃非整数/非数字元素 | 部分条目被忽略而不报错 |
| G10 | 689-693 | session.create 的 source 为自由字符串（默认 manual），无枚举 | 来源字段可写入任意值 |

> G1/G2/G3/G9 属于“静默降级”，Cut 1 类型化后应改为**显式失败**；这会改变个别测试的输入矩阵，需在 1E 阶段补“错误路径”用例。

---

## 7. Cut 1 分批实施顺序

> **B0–B8 状态（2026-10-22）：全部完成。** B8 已删除命令面与脚本，验收见
> [cut1-completion-report.md](cut1-completion-report.md)；下表保留原始批次、文件与退出条件。
>
> 前置：Cut 1 阶段 1A 在 gather-core/Sources/GatherCore/API/ 落协议与类型（Cut 3 再整体搬到 GatherProtocol/GatherDomain），避免在 Cut 1 改 Package.swift 的 target 结构。

| 批次 | 范围 | 新增文件 | 修改/删除 | 依赖 | 退出条件 | 人日 |
| --- | --- | --- | --- | --- | --- | --- |
| B0（完成） | 共享类型与门禁原语 | API/Support/{Confirmed,PageRequest,PhotoPathPolicy,BoundedString,NonEmpty}.swift、16 个空协议 | — | 无 | 两包编译；Confirmed 构造可见性方案定稿（见 §8 R2） | 1 |
| B1（完成） | Session + Job + Settings（基础） | API/{Session,Job,Settings}API.swift；Host/APIs/{LiveSession,LiveJob,LiveSettings}API.swift | DashboardViewModel、GatherApp.swift、SettingsView、ControlCenter（jobs） | B0 | 会话 CRUD/设置/任务 0 命令；Dashboard 直连服务改 API | 2.5 |
| B2（完成） | Photo + Filter + Image + Asset + Album + Navigation | 对应 4 个协议（Photo/Asset/Album/Navigation）+ Live 实现 | GalleryViewModel、LibraryViewModel、C1StatusCapsule、LibraryView | B1（JobAPI） | 图库/相册/资产 0 命令；分页与路径授权测试绿 | 2.5 |
| B3（完成） | Culling（最大域） | API/CullingAPI.swift + Host/APIs/LiveCullingAPI.swift | CullingView（先抽 ActionController，再替换 culling 域 19 条命令的调用点） | B1、B2（PhotoPath/PageRequest） | 19 条命令全部走 API；culling 的 5 条 confirmed 在此验证 | 3 |
| B4（完成） | Face + Similarity | 2 协议 + Live 实现 | FaceKeywordingView、SimilarityViewModel | B1、B2 | job→wait 语义与取消路径测试；face 13 + sim 10 | 2.5 |
| B5（完成） | Duplicate + Quality + Index | 2 协议 + Live 实现 | DuplicatesView、ControlCenter（quality/index） | B1 | dup 4 + quality 2 + index 1；JobAPI.start 统一 | 1.5 |
| B6（完成） | Export + Metadata | 2 协议 + Live 实现 | ExportView、LibraryViewModel（orphans）、CullingView（conflicts） | B1、B2、B3 | preview/execute 指纹复用；delivery confirm 单事务语义留 Cut 2 | 2 |
| B7（完成） | Person + Template | 2 协议 + Live 实现 | PersonsViewModel；Template 若无产品结论则删除 | B0 | person 8；template 6 删除或保留有结论 | 1.5 |
| B8（完成） | 删除命令面与门禁收口 | — | 删 SessionCommandRouter.swift、CommandRouter.swift、NativeCommandClient.swift、CommandSurfaceRuntimeTests.swift、Support/StubCommandRouter.swift、NativeCommandClientTests.swift、scripts/check-command-surface.sh；新增 APITests | B1-B7 | **完成**：grep -r 'execute("' Sources = 0；app 455/55、core 1080/149 绿；清理账 | 1 |
| **合计** | | | | | | **约 17.5**（方案预算 15；差额来自 113 处 UI 派发点与 Template 条件分支） |

**依赖与并行：**

- B1 是关键路径（JobAPI 被 B3/B4/B5/B6 共用）；B2 与 B1 可部分并行，但 PageRequest/PhotoPathPolicy 必须先于 B2。
- B3 与 B4 可并行（不同 UI 文件、不同协议）；B5/B6 在 B1/B2 后并行。
- B8 必须最后；删除 Router 前先完成 12 个 UI 文件 + Dashboard（第 13 个文件，直连服务）。
- 1E 测试与 B1-B7 同步：每个方法 happy path + 参数错误 + confirmed/路径错误；删除 CommandSurfaceRuntimeTests 的 118 条黄金清单，改为 APITests 的行为断言。

**每个批次的验收命令：**

    swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
    swift test  --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
    grep -rn 'execute("' Sources Culling Settings Export Duplicates FaceKeywording ControlCenter | wc -l

---

## 8. 风险与待裁决

| # | 事项 | 现状/证据 | 建议 | 级别 |
| --- | --- | --- | --- | --- |
| R1 | 输入校验错误码 | 111 处 requiredString 抛 MISSING_PARAM:string，GatherErrorCode 无对应项 | 方案 A：新增 1 个 INVALID_PARAM（字段名进 params），同 PR 删除“177 冻结”断言；方案 B：保持 177，输入形状错误视为编程错误，用 unspecified | P0，需拍板 |
| R2 | Confirmed<T> 构造可见性 | 方案 §3.5 要求 init internal（仅确认弹窗可构造），但 Cut 1 的 UI 与 Protocol 同包/分包不同 | 采用 ConfirmationGate.mint(scope:) 返回 ConfirmationToken，Confirmed.init(_:token:) 校验 token；不要把 init 设为 public | P0 |
| R3 | 31 条 test-only 命令 | 黄金清单与 CommandSurfaceRuntimeTests 是唯一外部引用 | 先删测试再删命令；template/metadata/image/quality 需产品确认是否保留行为 | P1 |
| R4 | 静默降级输入 | 见 §6.3 G1/G2/G3/G9 | 类型化时改为显式错误；补错误路径测试，避免“修复=行为变化”无记录 | P1 |
| R5 | UI 工作量被低估 | 实测 113 处派发点（brief 写 81）；Dashboard 另有直连服务路径 | Cut 1 UI 预算按 113+ 排；Dashboard/GatherApp 菜单单独排 0.5 人日 | P1 |
| R6 | culling.writeback 等交付语义 | 现为 Task 内 await + WritebackService；Cut 2 才统一 delivery | Cut 1 保留现有服务语义，只换边界；不要在 Cut 1 提前改状态机 | P1 |
| R7 | Template 域 | 6 条命令 0 UI；但 templateService 仍在 makeDefault 装配（178-383） | 产品未确认前，保留 TemplateAPI 但不投入 UI；确认不做则删协议+命令 | P2 |
| R8 | 101 个 *Params 类型 | 96 个除声明外 0 引用（仅 5 个在自身文件中被嵌套引用；JobCreateParams 是唯一真实使用） | 不要盲目复用；以 Input 类型重建并按 §6 加校验，旧 Params 在 Cut 1 末统一清理 | P2 |

---

## 9. 附：本次盘点的可复现命令

    # 以下为 Cut 0 历史复现口径；Router 与 check-command-surface.sh 已在 B8.4 删除。
    # 1) 当前命令面：16 协议 / 110 方法，0 条字符串命令
    grep -hE '^    (public )?func ' desktop/native/gather-core/Sources/GatherCore/API/*API.swift | wc -l   # 110
    grep -rnE 'execute(Async)?\( *"' desktop/native/gather-app --include='*.swift' | grep -v '/.build/' | wc -l   # 0

    # 2) 历史：Router case 与同步/异步分布（文件已删除，仅存档）
    #    git show HEAD:desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift | grep -c 'case "[a-z_]*\.[a-z_]*"'

    # 3) 仅测试引用（示例：template.*）
    grep -rn '"template\.' desktop/native/gather-app --include='*.swift' | grep -v '/.build/'

    # 4) 校验 helper 调用数（历史 §6.1；Router 已删除）

> 说明：§2 的“输出”列以服务返回类型/JSON 形状命名；若 Cut 1 要新增 DTO（如 SessionCreateResult、PhotoPage），以 §3 方法签名为准。
