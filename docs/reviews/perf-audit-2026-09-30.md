# 原生侧性能审计台账（2026-09-30）

> 来源：6 路只读审计（图片管线 / 数据库 / SwiftUI 热路径 / 刷新轮询 / IPC 序列化 / 算法管线）。
> 本文件为**索引与量化摘要**，完整报告由各审计员原始输出保留。
> 审计轮已抽验的关键结论标「✅ 抽验通过」；审计员未实测的项标「疑似」。
> E（IPC/序列化）与 F（算法管线）在本文写作时仍在运行，结论到货后追加。

## 0. 总量（六路合并去重后）

- **P0 19 条 / P1 33 条 / P2 26 条**（同一问题被多方独立命中的按一条计，交叉确证见 §5b）。
- 六路：A 图片管线 / B 数据库 / C SwiftUI 视图层 / D 刷新轮询 / E 命令面与序列化 / F 算法管线；全部只读、均声明了未验证边界。

## 0. 审计员自己的实测口径（重要）

- A 的毫秒数来自本机合成 JPEG（6000×4000 / 5000×3300，页缓存命中）→ **性能下界**；RAW 的 100–800ms 来自代码注释，未实测。
- B 的 SQL 计时来自系统 sqlite3 3.54 **内存库** + 合成 1 万行 → 磁盘库只会更差。
- D 的毫秒数是按 payload × 频率的**量级估算**，未插桩。
- 主代理自己的微基准（`.build/perf-probe/`，不入库，`swiftc -O`）见 §2。

## 1. P0（用户可感卡顿 / 内存爆炸风险）

| ID | 位置 | 问题 | 量化 | 修复 | 置信 |
| --- | --- | --- | --- | --- | --- |
| A-1 | GalleryView:1241-1258 / PhotoThumbnailView:451-461 | 灯箱相邻预取解 2048 后**丢弃**（decode 从不写缓存），且显示用 2560 → 永不命中；detached 占用 4 个解码名额 | 每次 ←/→ = 4 次 24MP 解码 ≈ 108–150ms（RAW 0.4–3.2s） | 删预取，或走同一 loader、用 `preview:path#2560` 键 + 写缓存 + 并发 ≤1 | ✅ 抽验通过 |
| A-2 | PhotoThumbnailView:246-251 / 449-461 | `DispatchSemaphore(4)` 阻塞式`wait()` 在 `Task.detached` 里（阻塞协作线程池）；不继承取消、无优先级传递；可见图 `priority:.utility` | 一屏 40 格滚过 = 40 次全图解码继续跑（JPEG 1.1s / RAW 4–32s CPU） | actor 闸门（优先级队列 + 同键去重 + 取名额前查取消）；nonisolated async 继承取消；可见图 `.userInitiated` | ✅ 抽验通过 |
| A-3 | RAWDecoder:232-266 / PhotoThumbnailView:571-583 | **无持久化缩略图缓存**：冷启动/回滚全部重解；512MB NSCache 按实测 cost 只容 161 张（1024 档 3.24MB） | 1 万张 RAW 全量遍历 17–133 分钟 CPU，每次重启归零 | 产出 JPEG 落盘 `Application Support/Gather/thumb-cache/<hash(path+mtime+bucket)>.jpg`，读前查盘 | ✅ 抽验通过 |
| B-1 | DB.swift:89-96/246-263 + GatherApp:108 | **全进程单连接 + 递归锁**，锁覆盖整次结果集物化 → 长查询/长事务让所有 DB 访问排队 | Culling filtered 页 24ms/万行、游标查询 9–12ms/万行期间，UI 的 `settings.get`/`photo.list_page`/`workspace.status` 全阻塞 | 只读查询走独立连接（WAL 多读者）；写连接串行队列；至少别让锁跨越结果集 | ✅ 抽验通过 |
| B-2 | AssetRepo:1029-1177（调用 SessionService:209 / IndexerService:692） | `ensurePhoto` 逐张照片 ~12 条语句（每条重新 prepare）+ 1–2 次 stat + 1 次 `nowISOString()` | 1 万张 ≈ 12 万语句 + 2 万 syscall + 1 万 formatter 构造（0.6–2.4s 纯编译），全程持全局锁 | 语句 prepare 到循环外；batch 取一次 timestamp；`IN (...)` 批量查；sidecar 三连写用 `ON CONFLICT ... RETURNING` | ✅ 抽验通过 |
| B-3 | IndexerService:193-198 + 76-77（并发 6） | `Data(contentsOf:)` 整文件读入再 `SHA256.hash(data)`；hex 每字节 `String(format:)` | 100MB RAW × 6 并发 ≈ **1.2–2.4GB 瞬时分配** | 分块增量哈希（1MB）+ 并发×文件大小 ≤256MB 限流；hex 查表 | ✅ 抽验通过 |
| B-4/D-1 | AnalysisJobRepo:174-179/402-407 + 5 处 @MainActor 调用 | `jobs.list` 无 LIMIT、逐行 `JSONValue.parse(checkpoint_json)`，主线程同步 + `.decoded(as:)` 二次往返；被 0.5–3s 轮询 | checkpoint 可达 ~1MB（1 万张导出/导入）；单次 20–80ms，活动期 2–4 次/s | 列表加 `includeCheckpoint:false`（续跑走 `latestTerminalCheckpoint`）；加 scope/type 过滤；改 executeAsync | ✅ 抽验通过 |
| D-2 | SessionCommandRouter:570-579 + 589/597-599 | `checkpoint()` **每张照片**重建 options + destinations + completedPhotoIds 全量快照 → O(n²) | n=1 万 → Σk ≈ 5×10⁷ 次装箱/插入（秒级 CPU），每 250ms 再 stringify ~1MB 落库 | checkpoint 改为落库前惰性构造（增量 + dirty），保持续跑语义 | ✅ 抽验通过（逐行读代码确认每张回调） |
| D-3/A-5/C-3 | GalleryViewModel:302-320 + GalleryView:196/662/426 | `loadedPhotos`/`filteredPhotos` 无缓存；`.onChange(of: filteredPhotos)` 每轮 body 深比较；闭包内 `lowercased()` | 1 万行：单轮 ≈3 次 flatMap + 2 万次 lowercased + 1 万元素深比较（我实测 3.6–3.9ms/万行含 lowercased，2–4 遍/body） | pages 变更时失效的缓存 + 轻量指纹监听；lowercased 提出循环 | ✅ 抽验通过（我另测：纯 struct filter ~30µs，含 lowercased 3.6ms） |
| A-6 | CullingView:3344-3368 | 细节层几何用 `viewerProxy` 整窗尺寸 + `page.assets.first` → 2×2 对比时多解约 4 倍面积，并可能用错照片（贴片错位） | 每次去抖解码放大数倍 | 传 `cellGeometry.size` 与**当前** asset | ✅ 抽验通过（我上轮引入的缺陷） |

## 2. 主代理微基准（可复现，`.build/perf-probe/`）

| 场景 | 实测 | 对比 | 结论 |
| --- | --- | --- | --- |
| `isoString` 每次 new DateFormatter | **55.3 µs/次** | 复用 0.64 µs（86×）；FormatStyle 0.17 µs（330×） | 105–107 处调用，逐行循环内多处 |
| `tsParseISODate` 每次 new ×2 | **169.5 µs/次** | 复用 36 µs（4.7×）；FormatStyle.parse 0.24 µs（700×） | 解析比格式化更贵 |
| **等价性验证** | `1756000000.123` → DateFormatter `.123` vs FormatStyle `.122` | `updated_at` 参与 ORDER BY / 取最新行 | **不要换 FormatStyle**，改为复用（语义零变化） |
| 1 万行 filter（含 `lowercased()`） | 3.6–3.9 ms/次 | 纯 struct filter ~30 µs；预小写数组 3.6 ms（分配才是瓶颈） | 修法是**记忆化**，不是微优化闭包 |
| 本地化 `Bundle.localizedString` | 0.47 µs/次 | 字典记忆 0.036 µs（13×） | Culling 单文件 255 处调用 |
| `ISO8601FormatStyle` 解析无毫秒串 | legacy formatter 返回 nil | 仓库靠第二个 formatter 兜底 | 现有双 formatter 兜底**是对的**，别删 |

## 3. P1（规模上去后明显）

| ID | 位置 | 问题 | 量化 | 修复 |
| --- | --- | --- | --- | --- |
| B-5 | PhotoRepo:232-263 / CullingService:1354-1385 | keyset 游标查询实为「每页全量聚合」，LIMIT 无法下推；每页再跑 countForScope | EQP：GROUP BY 临时 B 树 + 全行扫描；9–12ms/页，50 页 0.5s | 真 keyset 或物化 `asset_groups(first_rowid)` |
| B-6 | PhotoRepo:170-186 / CullingService:1426-1434 | `preferredRowPredicate` 相关子查询内 22 条 `LOWER()+LIKE` 逐行求值 | filtered 页 24.2ms → 去掉后 5.8ms（占 75%），50 页 ≈900ms | RAW 判定落持久列 / JOIN `asset_files.media_type`；至少去掉 `LOWER()` |
| B-7 | MetadataOutboxRepo:804-853 | 全量读 + 逐行 UPDATE/查询（每条重新 prepare） | finalize = 1 万 prepare + 1 万 UPDATE；linked 会话 ≥3 万查询 | 单条 UPDATE；JOIN 替代；`resolveConflict` 用 `get(xmpPath)` |
| B-8 | FaceKwService:842-861 / FaceRepo:566-617 | 逐张照片一个事务；全仓未设 `synchronous`（默认 FULL） | 2 万次 COMMIT ≈ 2–10s 纯 fsync，每次抢全局锁 | 64 张一批一个事务；`PRAGMA synchronous=NORMAL`（WAL 下安全） |
| B-9 | ClusterEngine:99-259/288-313 | 相似度全对全 O(n²)，位图 n²/8 字节 | n=1 万 5×10⁷ 对（0.2–0.5s）；n=32768 5.4×10⁸ 对 + 134MB | 分带 LSH（可精确召回）或懒分配位图 |
| B-10 | FilterEngine:112-166 | 两个相关 `GROUP_CONCAT` 子查询逐输出行全扫 photos | 500 行/页 × 10 万 × 2 ≈ 1 亿行访问/页 | 先 `GROUP BY asset_key` 聚合再 JOIN |
| B-11 | WorkspaceStatusService:262-275 | `analysis_runs` **完全无索引**（唯一确凿漏索引） | 每次状态刷新 2 次全表扫；随 run 累积 | 追加 `INDEX_SQL` 复合索引（零风险） |
| A-7 | RAWDecoder:246-282 / PhotoThumbnailView:252-257 | JPEG 往返编码（CGImage→JPEG→NSImage 再解），真解码被推到首次绘制 | 2560 编码 11.5–18.7ms；绘制 31.4ms vs 直通 14.3ms | 新增 `makeCGImage` 直通 + `NSImage(cgImage:)`，Data 面留给 IPC |
| A-8 | GalleryView:844 / GalleryViewModel:154-166 | 网格档位固定 1024，与 density×backing 无关 | 160pt 格子超采样 3.2×；1024 档 cost 3.24MB/张（512MB 容 161 张） | 按 density×backing 分桶 256/512/1024 |
| A-9 | PhotoThumbnailView:410-412 | 人脸裁切缓存键含 bbox → 同照片 N 张脸 = N 次全图解码 | 512 裁切 18.8ms + 811KB/条；10 张脸 = 8MB | 键改为 `preview:path#loadSize`（裁切本就在视图内做） |
| A-10 | RAWDecoder:129-184（区域解码） | 非 RAW 上区域解码无收益（CI 仍整图解码 + 多编 315KB JPEG）；tile 与缩略图争用 512MB 缓存 | 1200×800 区域 34.1ms vs 整图 downsample 33.6ms；4 格×10 步 ≈1.36s | 非 RAW 走整图档位+裁剪；tile 独立小缓存 + 平移复用 |
| D-4 | DashboardViewModel:337-343 | 每轮逐会话同步 `workspace.status`（每次 ~13 条 SQL） | 20 会话 × 13 = 260 查询/轮，15s/30s 一轮，主线程 | 合并聚合查询 / executeAsync；只解析最新 checkpoint |
| D-5 | LibraryView:126-136 / LibraryViewModel:383 | 索引进度期每 ~1.5s 全量 `reloadSupport()`（4 条同步命令 + 当前页） | 1 万张索引全程持续；jobTerminal 分支无 isActive 门控 | 降到终态/15s 档；补 isActive |
| D-6 | CullingView:588-616/645-714 | 逐按键 6 条同步查询 + ~1000 行编解码，无合并窗口 | 3–5 键/s → 每键 0.5–1MB JSON 往返；cancel 不中断解码 | refreshSilently 加 200–300ms trailing 合并 |
| D-7 | JSONValueDecoding:11-13 | `decoded(as:)` = encode→decode 双程，且每次新建 coder；75 处调用 | Culling 单轮 0.5–1MB ≈10–25ms，全在主 actor | 复用 static coder；大 payload 后台解码 |
| D-8 | GalleryViewModel:564-584 | 搜索/筛选态链式拉取到无游标（上限=整个库） | 5 万张 = 50 请求、数万行（15–40MB）常驻 | 行数/内存上限或服务端分页（需产品确认） |
| D-9/C-1 | ExportView:707/921-923 | 命名模式每键入一字符 → 全量 `export.preview`（无防抖） | 1 万张 ≈5 万 syscall/字符（我另测：ExportService 每张 3–5 stat + 可能 2 次读） | 300ms 防抖或回车/失焦提交 |
| C-2 | GalleryView:981-988/1014 | 灯箱每帧 4 次 O(n) 线性查找 + `.onChange(of: photos)` 整数组比较 | n=1 万 ≈4 万次 String 比较/帧 | 传下标或字典；onChange 改轻量指纹 |

## 4. P2（小优化，摘要）

| ID | 位置 | 问题 | 修复 |
| --- | --- | --- | --- |
| A-11 | PhotoThumbnailView:598-600 | NSCache cost 用 `NSImage.size`（点）；改直通后 300dpi 图会低估 13.6× | 改用 `cgImage.width×height×bytesPerPixel` |
| A-12 | 多处硬编码档位（Library 512/Persons 64-240/胶片 256…） | 桶位不统一，部分欠采样 | 收敛到一张桶位表 |
| A-13 | ImagePreloadService:30-81 | 解码结果全部丢弃（`_ =`），native 侧无调用点 | 删除或改为写缓存 |
| A-14 | SessionService:187-206 + DashboardViewModel(@MainActor) | 导入逐文件读尺寸在主线程串行（`import_concurrency` 未生效） | 移出主线程 + 真并发 |
| A-15 | GalleryView:740-751 | 布局缓存 key 对全部 id 重哈希（1 万次/body） | 用 VM 版本号做 key |
| B-12 | RepositorySupport:13-23 | `isoString` 每次 new DateFormatter（105 处） | 复用（加锁）；**不要**换 FormatStyle（差 1ms） |
| B-13 | 全仓 499 处 `connection.prepare` | 无语句缓存，同 SQL 反复编译 | `prepare_v3(PERSISTENT)` + LRU（绑定 close/reopen） |
| B-14 | Migrations:1067-1111 | 每次启动两遍 photos 全表 GROUP BY 查重 | 用 schema_version 门控或只留一遍 |
| B-15 | WorkspaceStatusService:53-129 | 一次刷新 10–12 条语句 + 双计数 | 合并聚合；补索引 |
| B-16 | ExportService:216-269 | 计划阶段逐张 fileExists+isReadableFile+sidecar 读两份 | 一次 `tsStat`；sidecar 先比 size/mtime |
| D-10 | C1StatusCapsule:105-139 | 页面销毁无 `onDisappear` 退订 → 跨会话永久 12s 轮询（同 B2 类） | 补 `.onDisappear` 退订 |
| D-11 | SimilarityViewModel:608-645 | 结果轮询无空闲上限（进度轮询有 30 轮） | 复用空闲上限 |
| D-12 | GatherEventCenter:99-104 | 每进度帧一个 `Task { @MainActor }`，同步广播给所有页 | `assumeIsolated` 或合并缓冲 |
| D-13 | C1StatusCapsule:242-250 | `formatTime` 每次 body 新建 2 个 formatter | 静态缓存（语言变化失效） |

## 4b. P0/P1（命令面与序列化 · 审计员 E）

| ID | 位置 | 问题 | 量化 | 修复 |
| --- | --- | --- | --- | --- |
| E-1 | SimilarityViewModel:77-84/620-645 + SimilarityService:531-591 | `sim.result` 在 @MainActor **同步**执行；全量照片 → JSONValue → encode/decode 共 **4 遍序列化**；`pollForResult` 每 2s 一次，阈值滑动每次再拉 | 2 万张 ≈ 2.5MB JSON × 4 遍，秒级主线程占用 | provider 改 async（executeAsync）；服务侧分页/只回代表图；`decoded(as:)` 去往返 |
| E-2 | SessionCommandRouter:523-540 + SessionCommandRouter:570-600 | checkpoint 每张照片重建；缩略图 executor 每帧重建整份 paths 数组 | 1 万张 ≈ 2×10⁸ 次分配 + 2 万次 options 编解码 | options 只算一次；增量构建；由节流器触发生成 |
| E-3 | ExportService:715-745/773-788/429 | `resolveName` 每张新建 DateFormatter + Calendar + 3 次 URL 解析；`assertDestinationPath` 对同一常量目标目录逐文件 `canonicalPath`（2 万次 `resolvingSymlinksInPath`） | 1 万张 × 3 遍交付 ≈ 3 万个 DateFormatter | 目录 canonical 提到循环外；formatter/Calendar 每计划复用；sessionName sanitize 只算一次 |
| E-4 | MetadataSyncCoordinator:275-304 + MetadataOutboxRepo:259-269 + C1StatusCapsule:70-98 | `culling.sync_status` 每 12s 在主线程返回**全量 items**（UI 只用 counts） | 1 万张待同步 ≈ 2MB payload/次 | items 可选/截断或新增 sync_counts；相似度改取计数 |
| E-5 | IndexerService:749-753 | `pendingChecksums` 物化整会话照片只为 1 个计数 | 5 万张全行（含大列） | Repo 加 `SELECT COUNT(*)`（走 idx_photos_session） |
| E-6 | SessionCommandRouter:2625-2640 / 1334-1345 / GatherAppDelegate:462-474 | `parseFilterCriteria` 为校验做 JSON 往返；`image.preload_thumbnails` 的 dedupeKey 用全部路径 joined（200 路径 ≈20KB 键）；`importFolder` 在主线程递归 enumerate + 逐文件 2 次 stat | — | 校验改直判；dedupeKey 用集合哈希；枚举+过滤移后台、复用 enumerator URL |
| E-7 | Core.swift:95-112 + RepositorySupport:71-73 + MetadataOutboxRepo:154-179 | `JSONValue` 解码 5 路 `try?` 探测（对象/数组节点平均 3-4 次失败 decode）；`parse` 每次新建 decoder；outbox 行计算属性被重复 parse 2-4 次 | 1 万行 × 3 ≈ 3 万次 decoder 构造+解析 | 单遍类型判定或 JSONSerialization 一次成树；共享 decoder；计算属性改惰性存储 |
## 4c. P0/P1（分析算法管线 · 审计员 F）

| ID | 位置 | 问题 | 量化 | 修复 |
| --- | --- | --- | --- | --- |
| F-1 | FaceKwService:891-927 / 1844-1859 / 648 | 人脸分析**完全串行**；每张照片 JPEG 编码+2 次解码空转（`getPreview` 编 JPEG → `CGImageSourceCreateImageAtIndex` 再解）；`face_decode_concurrency` 只当批大小、`face_inference_parallel_workers` 默认 1；`detect_input_size=640` 在审计时点**未见消费点**（第二轮验证更正：当前树已接线 FaceKwService:645→769→1723，仅剩 CGImage 直通/真并发） | 10 万张 ×150–400ms ≈ 数小时；检测像素 ≈10× | decodeProvider 直接返回 CGImage；检测前降采样；decode/推理真并发（**注意 analysis_signature 含 previewMaxDimension，改尺寸会触发全库重算**） |
| F-2 | ClusterEngine:243-250/301-313/173-178/522-531 | dHash 聚类 O(n²) 全对比较、无分桶预筛；>32768 走 5×O(n²)；**聚类期间不可取消**（`SimilarityService:388-398` 只在返回后查 abort） | 仓库自带基线：20k=1.1s / 50k=18.5s（超二次劣化）；100k 预计 1.5–5min；位图 32768 ⇒ 134MB | 阈值/前缀分桶预筛 + 位集分块 + abort 传入聚类（对账 fixture 必须逐位一致） |
| F-3 | FaceKwService:670-675/739-744/1246-1264 + FaceRepo:330-335 + Clusterer:222-231 | 人脸 embedding BLOB 三次全量载入 + 多份副本（DBRow→行对象→flat→normalizedFlat 的 `var flat = source` COW 全量拷贝） | 10 万脸单次 ≈300MB，峰值 1–2GB | getObservations 排除 embedding 按需分页；连续 buffer；normalizedFlat 原地 |
| F-4 | （与 E-1 同源，交叉确证）sim.result 主线程 | 见 E-1 | 100k 张每次阈值切换/2s 轮询全量投影 + 两次整包序列化 | 同 E-1 |
| F-5 | FaceKwService:843-861 + FaceRepo:588/489-514 + DB:76-81 + **SettingsService:76-79 / SettingsView:760-767** | 每张已分析照片 **2 次独立 COMMIT**（2×1 万 = 2 万次 fsync）；更严重：`db_synchronous=normal`、`db_cache_size_mb=64` 两项设置**已定义并暴露在 UI，但从未接线**（PRAGMA 只有 journal_mode/foreign_keys/busy_timeout）——改了不生效 | 10 万张 20 万次 WAL fsync ≈2–3min（外置卷 17–66min） | 每 64 张一个事务；打开连接时读设置 `exec PRAGMA synchronous/cache_size` |
| F-6 | ImageCache:24-88 + IndexerService:195-198 + DuplicateService:302-306 | 纯 Swift SHA-256（逐字节数组索引）；本机实测 **342 MiB/s vs CryptoKit 3220 MiB/s = 9.4×**；仍整文件读入 | 10 万×30MB=3TB ⇒ 纯哈希 2.4h（CryptoKit 15min） | `#if canImport(CryptoKit)` 走流式 CryptoKit（字节一致），Linux 保留回退 |
| F-7 | FaceKwService:1568-1584 + Matcher:179-191 | margin 路径每查询**暴力全库**（`bestScoresPerPerson` 绕过已建 LSH），且与 `matchAgainstLibrary` 重复计算；`face_match_margin` 默认 0.01 恒 >0 ⇒ 必走 | 库 5k×768 ⇒ 每 query 3.8M FLOP；20k 新脸 ⇒ 7.7e10 FLOP | 用一次 matchAgainstLibrary 的候选按 person 聚合亚军 |
| F-8 | DuplicateService:638-661/665-677/682-695 | 逐组 prepare+SELECT；两个 UPDATE 把全部成员 id 展开成单个 IN（>32766 变量触 SQLite 上限，SQL 文本数 MB） | 5k 组 ⇒ 5k 次查询 | 内存计数；chunked(400) + 临时表 |
| F-9 | JobService:112-126/331-341 + SessionCommandRouter:528-539 | 进度 flush 每次先 `get(id)`（整行含 checkpoint 解析）+ stringify 整个 checkpoint；thumbnailBuild 把**全量 paths** 放进 checkpoint 且每帧回传 | 10 万路径 ≈10MB JSON ×4Hz ≈120MB/s | checkpoint 只写增量键（nextPathIndex）；paths 一次性存入后不回传 |
| F-10 | SimilarityService:966-985/881-890/902-904 | `precomputeNeighborTiers` 白建 4 份完整结果（`built.result` 丢弃）；主结果把全量 groups 序列化进 groups_json 而 getResult 有成员表时永不读 | 100k ≈12MB 无用 JSON | buildStoredResult 加 skipResult；主结果存紧凑 JSON |
| F-11 | IncrementalClusterer:211-234/262-267 + VectorIndex:709-712 + Clusterer:310 | graphCache 可同时驻留多个 ComponentGraph（各 ≤134MB）；`neighbors` 每查询分配 `[Bool](count)`（9n 字节×n 次 ⇒ n=50k 时 22GB 内存流量）；每簇再分配 n 字节 | 见左 | 按分量串行；代际标记/复用 scratch（保持 BFS 顺序） |

**主代理抽验补充（2026-09-30）**：F-5 的「设置未接线」已独立确认——PRAGMA 全仓只有 `journal_mode`/`foreign_keys`/`busy_timeout`（DB.swift:76-81），`db_synchronous`/`db_cache_size_mb` 仅在 SettingsService.swift:76-79 定义、SettingsView.swift:762/767 暴露，**无任何消费者**（功能缺陷，不只是性能）。
C 的中途项（待其完整报告）：`SettingsViewModel.lastSyncDate`（SettingsView.swift:544-554）是计算属性，逐项 `parseISO8601Date` + 排序比较器再解析一次（O(n log n) 次解析/每次 body 访问）；`DashboardView.swift` 仅 1 处 `DateFormatter()` 实例化，C 所述「每行 6 次」尚未核实（可能被逐行 helper 调用多次）。

P2：CosineHnswIndex 零生产消费者（要么接线要么删）；`photoGroupMapCache` 32 条 × 整会话 map（100k ⇒ 最坏 160–320MB 常驻）；IndexerService 对 existing 重复 canonical + 每目录项重算 root components；ImagePreloadService 预览预取不可取消且串行。
## 4d. P0/P1（SwiftUI 视图层 · 审计员 C，完整报告）

| ID | 位置 | 问题 | 量化 | 修复 |
| --- | --- | --- | --- | --- |
| C-1 | SettingsView:544-550/1443/1131-1137 | `lastSyncDate` 是计算属性、写在 body 里，对 `syncStatus.items`（**无 LIMIT** 的全 outbox 行）逐项 ISO 解析；`parseISO8601Date` 每次新建 ≤2 个 formatter | 5000 行 ⇒ 每次 body 1 万个 formatter；叠加 12s 轮询 ⇒ 「开着设置窗 = 每 12 秒一次秒级停顿」 | 改 stored（refreshSyncState 时算一次）；解析器提 static；`getSummary` 加 LIMIT/只回计数 |
| C-2 | FaceKeywordingView:182-202 + SessionCommandRouter:966-970 | `load()` 在 @MainActor **同步** `fkw.clusters`，payload 含本页**从不读取**的 `thumbnailBase64`；路由 `JSONValue(from:)` + `decoded(as:)` = **3 遍全量 JSON** | 数千簇 × ~10KB base64 ⇒ 数十 MB 字符串主线程来回编解码，每次 bind/unbind/merge 都冻结一次 | 本页 DTO 去掉 base64；改 executeAsync 后台解码；簇分页（UI 已有「加载更多」） |
| C-3 | SessionControlView:42-61/340-352 | 索引期每 3s 在 @MainActor 串行 4 条同步命令；`jobs.list` 先取**全库任务**再在 Swift 里 filter 本会话 | 任务表 2000 行 ⇒ 每 3s 2000 条 encode+decode；正是用户盯进度条时 | 取数移后台；`jobs.list` 支持 scopeId 过滤；轮询期只查 `workspace.status` |
| C-4 | DashboardViewModel:332-344 | `refreshSessions` 是 async 但**循环体内无 await** ⇒ N 个工作区 × ~10 条同步 SQL 挤在一个不可中断的主线程块 | 100 工作区 ≈ 1000 次同步查询；15s/30s 一轮 + 终态事件再触发 | 聚合移后台或新增批量 `workspace.statuses`；一次替换 statuses |
| C-5 | DuplicatesView:693/724 + 467/472/473/643/644 | 同一卡把 `recommendation` 算**两遍**（各遍历全量成员 + 每成员 ≤2 次 ISO 解析）；一次 body 做 **5 次全量 filter**；阈值滑块是连续 Binding | G=3000、组均 200 ⇒ 单 body ≈1.5 万谓词 + 800 次日期解析/卡，拖动按帧重算 | VM 缓存 groupId→recommendedId 与 filtered/计数；消除重复调用 |
| C-6 | LibraryView:326-335/412/491 + 56 | 候选/孤立两个 ForEach 直接放在 `ScrollView { VStack }`（**非惰性**）且默认可见；底层查询无 LIMIT | 一次 RAW+JPEG 导入可上万条 ⇒ 每次重建 2 万次 URL 解析 + 上万个选择容器 | 包 `LazyVStack`（零行为变化）；查询加分页 |
| C-7 | FaceKeywordingView:919/1555/1528/1817-1819 | hover 状态挂在**页面级** ⇒ 鼠标每次进出卡片重建整页；`visibleClusters` 一次 body 访问 4 次；`boundClusters` 在行内再求值 | 1000+ 簇时一次鼠标扫过 = 数百次整页重建 + O(B×C) 过滤 | hover 下沉到卡片；body 内求值一次；roles/boundClusters 改 stored |
| C-8 | DashboardView:561-568/438/517 | `dateText` 每次 = 1 个 DateFormatter + 最多 2 个 ISO8601DateFormatter；`SessionRowView` 每行调 2 次（identity + accessibilityValue） | **每行 6 个 formatter/次重绘**，30 可见行 ≈180 个（10–30ms）；body 被 1Hz 进度刷新驱动 | formatter 提 static；VM 预计算日期文本与 `sessionNames` 字典 |
| C-9 | PersonsView:280-318/347-357 | `name/notes` 是详情页 @State，`.disabled(name…)` 让**每次击键**重建整个 body（含 2 次 dateText + 无上限照片 LazyVGrid 的 diff） | 每键 0.2–1ms + 网格 diff（数千张时明显） | 日期文本 VM 预计算；`.disabled` 只读派生 Bool，避免整页重算 |
| C-10 | CullingView:2358-2370/2403-2412/2995-2997 | 胶片条每次 body `Array(...enumerated())` 为**全部已加载** asset 分配元组；`currentAsset` O(n) 扫描多处引用；`currentGroupAssets` 一次 body 被引用 4 次且每次 filter 全表 | 数千 asset × ~8 遍/决策 | VM 缓存 photoId→asset 与 currentGroupAssets；ForEach 直接用 assets（id 已稳定） |

P2（C）：C1 胶囊每次 body 4 个 formatter（正文+tooltip 各一次 `formatTime`）；网格缩略图超采样 ~5× 且 512MB 只装约 128 张；`FaceCropThumbnailView` 缓存键每次现拼 4 次 `String(format:)`；`WindowBridge.updateNSView` 每帧往主队列投递一次闭包；`GatherLocalization.l()` 每次 2 把 NSLock + Bundle 查表（建议语言切换时整体快照成 `[String:String]`，调用点 Culling 255 处 / FaceKw 181 处）。

**修正前文标注**：C-P1-2「Dashboard 每行 6 次 Formatter」**成立**——`dateText` 定义在 DashboardView:561-568（我此前 grep 到的 1 处 `DateFormatter()`），每行调 2 次 × 每次最多 3 个 formatter；C-P0-1 的 Settings 全表解析也已独立确认。
## 5. 建议修复批次

**批次 1（低风险、立即可感知，建议先做）**
1. A-1 预取改为写缓存/删除；A-6 tile 几何改 `cellGeometry` + 当前 asset（**正确性缺陷**）；A-9 人脸键去 bbox。
2. D-3 Gallery 派生层缓存 + 轻量指纹；D-9 命名输入 300ms 防抖。
3. B-4/D-1 `jobs.list` 轻投影（`includeCheckpoint:false`）+ 无活跃任务停轮询。
4. B-11 `analysis_runs` 索引（零风险）。
5. D-10 C1 胶囊 `onDisappear` 退订；D-11 相似度轮询上限。
6. B-12 formatter 复用（**保持 DateFormatter 语义**）；D-7 复用 coder。
7. E-5 `pendingChecksums` 改 COUNT(*)；E-3 导出目录 canonical/DateFormatter 外提；E-4 sync_status 去全量 items。
8. E-1 `sim.result` 改 async（相似度页主线程秒级占用，用户可感）。
9. C-1 Settings `lastSyncDate` 改 stored + 解析器 static（12s 一次秒级停顿）；C-8 Dashboard `dateText` 提 static（每行 6 个 formatter）。
10. C-6 Library 检查器两个 `ForEach` 包 `LazyVStack`（零行为变化）；C-7 人脸页 hover 下沉到卡片 + `visibleClusters` 只求值一次。
11. C-2 `fkw.clusters` 去掉本页不用的 `thumbnailBase64`（payload 直接瘦身）。
12. C-10 胶片条去掉 `Array(...enumerated())` 包装 + VM 缓存 `currentAsset`/`currentGroupAssets`；C-5 消除重复 `recommendation` 计算。

**批次 2（结构性，需回归导出/分析语义）**
7. D-2 导出 checkpoint 惰性构造。
8. A-2 解码闸门 actor 化（优先级 + 取消 + 同键去重）。
9. A-3 磁盘缩略图缓存（含失效/配额/GC）。
10. B-2 语句 prepare 外提 + 批量写；B-8 批量事务 + `synchronous=NORMAL`；B-13 语句缓存。

**批次 3（需产品确认或大库验证）**
11. B-1 单连接拆分（只读连接 + 写连接）；B-5 keyset 分页重构；B-9 分带 LSH；D-8 链式拉取上限。

## 5b. 交叉确证（多审计员独立命中同一处）

- **E-1 = F-4 = D-3 邻近**：`sim.result` 主线程 + 双次序列化（E 与 F 独立确证）。
- **B-4 = D-1 = E 的 P0-2**：`jobs.list` 无界 checkpoint 逐行 parse + 主线程轮询（三方独立确证）。
- **B-3 = E-5 = F-6**：SHA-256 整文件读入（B/E/F 独立命中，F 给出 9.4× 实测差）。
- **B-8 = F-5**：逐张事务 + `synchronous` 未接线（B 推断「未设」，F 找到「设置已定义且暴露 UI 但从未生效」）。
- **A-5 = C-2/C-3 = D-3**：Gallery 派生属性与灯箱 O(n) 查找（三方独立确证）。
- **B-1 = E 的 P2-3**：单连接全局锁（两方独立确证）。

## 6. 修复记录（2026-09-30，全量修复第一轮）

验证：**gather-app 288 tests / 29 suites 通过**（+2）· **gather-core 962 tests / 135 suites**（+1；唯一失败仍为沙箱禁止写 home 的环境性用例）· 两条门禁通过。

| # | 编号 | 修复 | 位置 |
| --- | --- | --- | --- |
| 1 | A-6 | 细节层几何改用**当前单元格尺寸 + 当前照片**（对比模式下不再多解 4 倍面积、不再贴错照片） | CullingView |
| 2 | A-1 | 灯箱预取：只为相邻 2 张、键与显示一致（2560）、命中跳过、写入缓存、串行 + 取消检查（原为 100% 无效解码） | GalleryView |
| 3 | A-1 | 缓存键收敛到 `PhotoThumbnailCache.key`（显示与预取共用，防漂移） | PhotoThumbnailView |
| 4 | A-9 | 人脸裁切缓存键去掉 bbox（裁切是视图内几何，N 张脸不再各解一次整图） | PhotoThumbnailView |
| 5 | A-2 | 解码闸门 actor 化：异步排队（不阻塞协作线程池）、取名额前后双查取消、同键在飞去重；视图统一走 `decodeAsync` | PhotoThumbnailView / PhotoDecodeGate |
| 6 | A-3 | **持久化缩略图缓存**（键含源文件 mtime+size，512MB 上限 + LRU 清理，App 启动开启、测试默认关闭） | 新增 ThumbnailDiskCache.swift |
| 7 | D-3/A-5/C-P1-1 | `loadedPhotos`/`filteredPhotos` 记忆化（代数 + 参数键）、过滤词提出循环、`.onChange` 改轻量指纹、布局键改用代数（去掉 O(n) 哈希） | GalleryViewModel/GalleryView |
| 8 | C-1 | Settings `lastSyncDate` 改 stored（刷新时算一次，并在两条成功路径重算） | SettingsView |
| 9 | C-8/C-1/P2 | Dashboard/Settings 展示日期改 `Date.FormatStyle`（不再每行新建 DateFormatter）；展示用 ISO 解析改 FormatStyle（等价性实测 0/7 mismatch，约 700×） | DashboardView/SettingsView/DateFormatting |
| 10 | C-P1-6 | 人脸页 `boundClusters`/`unboundClusters`/`roleNames` 改 stored（一次 body 不再多次全表 filter） | FaceKeywordingView |
| 11 | E-5 | `pendingChecksums` 下沉为 `COUNT(*)`（不再物化整会话行） | PhotoRepo/IndexerService |
| 12 | D-9/C-P0-2 | 导出命名/水印输入 300ms 去抖（原为每字符一次全量 preview） | ExportView |
| 13 | B-4/D-1/E-P0-2 | `jobs.list` 轻投影：`includeCheckpoint` 参数（默认 true 保持契约），Culling/控制中心/人脸页传 false | AnalysisJobRepo/JobService/Router/3 视图 |
| 14 | E-3 | `resolveName` 时间 formatter 改为**每计划一份**（仍不跨线程共享）；目标目录 canonical 提到循环外（省 2 万次符号链解析） | ExportService |
| 15 | D-2/E-2/C-P2-3 | 导出 checkpoint 缓存 + 代数失效（options 只编码一次，不再每张重建全量快照） | SessionCommandRouter |
| 16 | B-12 | `isoString`/`tsParseISODate` 复用锁保护的 formatter（实测 55µs→0.64µs，169µs→36µs；**保持 DateFormatter 语义**） | RepositorySupport |
| 17 | F-5 | `db_synchronous`/`db_cache_size_mb` 接线（宿主注入只读设置钩子；默认 normal/64MB 生效） | DB.swift/GatherApp |
| 18 | F-6/B-3 | `sha256File` 改 CryptoKit 4MB 分块流式（内存恒定、约 9.4×），Linux 保留纯 Swift 回退；**新增流式 vs 一次性逐字节对账测试** | IndexerService |
| 19 | D-11 | 相似度结果轮询加空闲上限（30 轮后自停，与进度轮询一致） | SimilarityViewModel |
| 20 | C-6 | Library 检查器两个无界 ForEach 包 `LazyVStack`（零行为变化） | LibraryView |
| 21 | C-2 | `fkw.clusters` 不再回传本页不读的 `thumbnailBase64` | SessionCommandRouter |
| 22 | B-11 | `analysis_runs(session_id, kind, status, id DESC)` 索引（唯一确凿漏索引） | Schema.swift |
| 23 | D-10 | C1 状态胶囊 `onDisappear` 退订（跨会话永久 12s 轮询） | C1StatusCapsule |

新增回归：磁盘缓存键失效（mtime/size/档位/缺失文件）· 解码闸门串行语义 · 流式哈希逐字节对账（core）。

## 6b. 第二轮检查：自查修正（2026-09-30）

第二轮派 5 个只读验证员复核第一轮 23 项；**在等待期间的自查**先发现并修掉 5 处（含一处严重缺陷）：

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| S-1 | `PhotoDecodeGate` 用 checked continuation 排队，**等待期间被取消的请求永远不会被 resume** | 取消的等待者永久挂起 → `inFlight[key]` 永不清理 → **该照片缩略图此后永久空白**（滚动离开就会触发） | 改为「可取消睡眠轮询 + acquire 返回 Bool」；新增回归 `decodeGateCancellationDoesNotHang`（取消必须立即返回 false）与 `decodeGateSerializesBeyondLimit` |
| S-2 | A-6 的 `lastCellSize` 在 **body 求值期间写 @State**（`let _ = { … lastCellSize = … }()`） | SwiftUI「Modifying state during view update」+ 额外布局循环（正是仓库 F01 曾移除的模式） | 改挂 `.onAppear` + `.onChange(of: cellGeometry.size)` |
| S-3 | A-1 预取改用 `Task.detached { decode(...) }`（**绕开闸门**，同步 decode 已无信号量） | 预取并发无界，重新引入「滚动时并发解码风暴」 | 预取改走 `PhotoThumbnailDecoder.decodeAsync`（受闸门/去重/磁盘缓存管） |
| S-4 | F-5 的 `settingsProvider` 在 `DBConnection(path:)`（open 已执行 PRAGMA）**之后**注入 | 用户改的 `db_synchronous`/`db_cache_size_mb` 仍不生效（首次 open 时钩子为 nil） | `settingsProvider` 加 `didSet` → 注入时重放 `applyPerformancePragmas()`；open 与注入各调一次 |
| S-5 | A-3 的 `ThumbnailDiskCache.store` 每次都 `pruneIfNeeded()`（**每次解码枚举整个缓存目录**） | 新增 IO 热点（目录大时反而更慢） | 节流：每 128 次写入或距上次 ≥60s 才真正枚举 |

验证：gather-app **289 tests / 29 suites 通过**（+1）。注：首次全量跑时 `rapidThresholdChangesAdoptOnlyLatest` 因 5 个验证子代理并发构建造成时序抖动而失败，单独重跑该套件 24 项全绿。
### 6c. 第二轮：验证员发现并已修的缺陷

| 来源 | 编号 | 问题 | 修复 |
| --- | --- | --- | --- |
| 验证员 3 | **V3-P0** | `deliverySummary` 是 checkpoint 唯一漏失效的写入点 → 终态 checkpoint **永远不含** exported/failed/skipped/totalFiles/errors（工作区「已导出」判定误报、导出页可能闪错文案、F3 明细不落盘） | 摘要赋值后补 `invalidateCheckpoint()`；并注释锁定「回调必须串行」前提 |
| 验证员 3 | V3-P1 | 手动「预览」不取消挂起的去抖任务 → 清单自己消失一个往返；视图销毁不取消；`previewSection` 缺 `isPlanStale` 守卫（去抖窗口内显示旧清单） | 预览按钮先 `planDebounceTask?.cancel()`；新增 `.onDisappear` 取消；`previewSection` 加 `!isPlanStale` |
| 验证员 3 | V3-P2 | `deliveryFingerprint` 的 resolveName 仍每张新建 DateFormatter（E-3 未闭环） | 指纹循环外建一份并传参 |
| 验证员 3 | V3-P2 | Dashboard / Similarity 两处**进程内**轮询仍在逐行解析 checkpoint（`jobs.list` 轻投影覆盖缺口） | 两者改 `includeCheckpoint: false`（Dashboard provider 加参数、VM 传 false、契约测试改传 true 保留断言）；全仓已无全量调用点 |
| 验证员 1 | **V1-1** | 人脸裁切 `FaceCropThumbnailView.load` 仍裸 `Task.detached { decode }` → 一屏 20-40 路并发（limit=4 形同虚设），且同照片 N 张脸各解一次（A-9 收益首屏不生效） | 改走 `decodeAsync`（闸门 + 同键去重 + 磁盘缓存） |
| 验证员 1 | V1-2 | 区域解码（贴片）不走闸门，且注释谎称「与整图共用闸门」；4 格同时放大无限制 | 新增 `decodeRegionAsync` + 独立 region 闸门（limit 2，不与整图互相排队），修掉假注释 |
| 验证员 1 | V1-3 | 闸门 `existingTask`/`setTask` 两次 await 的 check-then-act → 同键并发会各建任务（重复解码）；清理可能清掉后来者的在飞任务 | 合并为单次 actor 事务 `taskBox(for:make:)` + 引用盒子 identity 校验清理（`remove(_:for:)`）；轮询改 2→20ms 指数退避 |
| 验证员 1 | V1-4 | `pruneIfNeeded` 只有条数/时间阈值 → 512MB 硬上限变软上限（两轮 prune 之间最多再进 128 张 2560 档 ≈ 数百 MB） | 增加**字节阈值**（累计 ≥64MB 即 prune），恢复硬约束语义 |
| 验证员 1 | V1-5 | 对比模式：`detailTileState` 是整页唯一状态，非当前格把「当前照片的可见区域」贴到别人底图 → 宽高比不同即错位 | 贴片与 `lastCellSize` 都限定 `cell.asset.photo.id == currentAsset?.photo.id` |
| 验证员 4 | V4-1 | F-6 未闭环：`DuplicateService` 仍整文件读入 + 纯 Swift 哈希（审计点名处） | 改走 `IndexerService.sha256File`（CryptoKit 分块流式）；修 `IndexerService` 顶部「整文件 SHA256」注释漂移 |
| 验证员 4 | V4-2 | F-5 接线**无任何回归测试**（正因如此漏过一轮） | 新增 `DatabasePragmaTests`（3 例：默认值 / 注入即重放 / 非法值与钳制） |
| 验证员 4 | V4-3 | 设置 UI `db_cache_size_mb` 无上限（DB 静默截到 1024MB）；`db → settingsProvider → SettingsRepo → db` 强引用环 | UI 上限改 1024 与 clamp 对齐；闭包改 `[weak settingsRepo]` |

最终验证：**gather-app 290 tests / 29 suites 通过**（+1）· **gather-core 965 tests / 136 suites**（+3；唯一失败仍为沙箱环境性用例）· 两条门禁通过。

> 说明：验证员 scope 1 与 scope 4 在报告时观察到工作树被并发编辑（我在修他们上一轮指出的问题）；他们已按各自绑定的 revision 逐一复核，结论与本文一致。scope 2（视图派生/格式化）与 scope 5（遗留与新增风险普查）报告到货后追加。
### 6d. 第二轮验证结论（5 个只读验证员）

| 验证范围 | 结论 |
| --- | --- |
| 解码/图像（scope 1） | **全部确证修复**：A-6（body 写 @State 已改生命周期回调、非当前格错位已关）、A-1（键一致 + 走闸门 + 写缓存）、A-2（旁路补齐 / TOCTOU 关闭 / 退避轮询；名额无泄漏、inFlight 不残留——验证员另用探针实测 `taskBox` 闭包未继承 actor 隔离）、A-3（三重节流 + 目录注入 + 往返测试）、A-9（键去 bbox + 首屏同键共享） |
| 视图派生/格式化（scope 2） | 报告到货；其中「FormatStyle 展示输出」一项经我自查**发现真实回归并已修正**（zh 下 09:46→9:46），现改为缓存 DateFormatter（性能保留、输出逐字节一致） |
| 导出/命令面（scope 3） | 确证修复 + 抓到一个 **P0**（deliverySummary 漏失效 → 终态 checkpoint 永缺摘要）与 2 个 P1/P2（预览与去抖互斥、指纹路径 formatter），**均已修**；确认 `jobs.list` 轻投影无显示回归、默认 true 保契约的决策正确 |
| DB/核心（scope 4） | **5 项中 4 项确证**（索引、COUNT(*) 语义等价、formatter 复用逐字节一致、F-5 接线——验证员用探针实测 PRAGMA 生效）；F-6 未闭环（DuplicateService）**已补**，并按其建议新增 `DatabasePragmaTests` 3 例 |
| 遗留与新增风险（scope 5） | 确认 4 项立即升级建议；其中「取消传播」**已实现**（等待者计数 + 可取消赛跑探针）；「C-2 目标不符」**已回退**（那是 person DTO，且该字段全仓无写入点，原审计前提不成立）；其余见 §7 |

### 6e. 第二轮收尾改动（本轮）

| 编号 | 改动 |
| --- | --- |
| V5-1 | **取消传播**：`PhotoDecodeTaskBox` 增加等待者计数，最后一个等待者离开即 `task.cancel()`；新增可取消的「赛跑探针」使等待者在取消时立刻返回（否则 defer 永不执行、计数永不清零）。回归：`decodeGateCancellationDoesNotHang` |
| V5-2 | C-2 回退（无效改动，目标 DTO 错、字段恒空） |
| V5-3 | A-6 残余：`onChange(of: cellGeometry.size)` 也重新调度贴片几何（拖窗口后不再错位） |
| V5-4 | D-9 文案缺口：去抖 pending 期间显示「正在计算本次导出的文件数…」（新增 `isPlanRefreshScheduled`） |
| V5-5 | 展示日期格式：`dateText` 从 FormatStyle 改回**缓存 DateFormatter**（修复 zh 前导零回归；FormatStyle 只保留在解析路径，实测 0 差异） |
| V5-6 | F-6 闭环：`DuplicateService` 改走流式 `sha256File`；F-5 补 `DatabasePragmaTests`（3 例）；UI `db_cache_size_mb` 上限 1024 与 clamp 对齐；`settingsProvider` 闭包改 weak |

**最终验证（本轮修订）**：gather-app **290 tests / 29 suites 通过** · gather-core **965 tests / 136 suites**（唯一失败为沙箱环境性用例）· 两条门禁通过。
### 6f. 第二轮·scope 2/5 追加修复（本轮最终）

| 来源 | 编号 | 问题 | 修复 |
| --- | --- | --- | --- |
| scope 2 | **V2-1（正确性）** | 相似度「发现终态任务 → 刷新结果」分支是**死代码**（`activeSimilarityJob` 只返回 queued/running/cancelling）⇒ 分析时长 > 结果轮询空闲上限（约 62s）时，页面永远停在无结果，直到 ⌘R / 重进 | 空闲耗尽退出前补一次 `await refreshResult()`（走 adoptResult 代际守卫）；修正常量注释口径（进度 1s/结果 2s） |
| scope 2 | V2-2 | 布局键只用 `代数|条数|宽|密度` → 「搜索词变化但命中数相同」会复用上一组照片的行高（照片对、几何错） | 键补 `filteredFingerprint`（O(1)，零成本） |
| scope 2 | V2-3 | C1 订阅是全局 `Set`（非引用计数）：同一会话多宿主时，先消失的宿主会退掉仍在显示者的订阅；`statuses` 只增不减 | 改 `[String: Int]` 引用计数，归零才停 pollTask 并回收该会话 statuses |
| scope 2 | V2-4 | C-2 误改（person DTO）与「注释与实现不符」 | **已回退**（见 §6e V5-2）；fkw.clusters 的 base64 轻投影未做，原因：迁移后该字段在当前数据下恒空，收益≈0（已记录） |
| scope 5 | V5-3 | A-6 残余：窗口 resize 后贴片几何不重算 | `onChange(of: cellGeometry.size)` 内同时重算贴片 |
| scope 5 | V5-4 | D-9 文案缺口：去抖 pending 期间摘要行整行消失且无占位 | 新增 `isPlanRefreshScheduled`，pending 时显示「正在计算本次导出的文件数…」 |
| 自查 | V5-5 | 展示日期改 FormatStyle 引入 zh 前导零回归（09:46 → 9:46）与 Settings 非 zh 12 小时制 | 改回**缓存 DateFormatter**（`DisplayDateFormatters`），输出与旧实现逐字节一致；FormatStyle 仅保留在解析路径（17 组输入 0 差异） |

**最终（本轮修订）**：gather-app **290 tests / 29 suites 通过** · gather-core **965 tests / 136 suites**（唯一失败为沙箱环境性用例）· 两条门禁通过。
## 7. 仍未修（需专项/产品确认/大库验证）

> 第二轮验证员把其中 3 项列为「应立刻升级」（本轮只完成了取消传播）：
> 1. **A-14 导入与枚举仍在主线程**（万级导入秒级~十秒级冻结）：`GatherApp.swift:234-280` → `SessionService.addPhotos` 的「分批」实为串行 for 循环逐文件 `getDimensions`；`GatherAppDelegate` 主线程整树 enumerate。建议 `Task.detached` + 「正在导入…」态。
> 2. **E-1 `sim.result` 仍在主线程**（4 个入口 × 全量投影 + 3-4 遍序列化）：最小步是给 provider 加 async 版走 `executeAsync` + 后台 decode，协议形状不变。
> 3. **F-2 聚类不可取消**（32k+ 图上取消要等 1.5-5min，位图 134MB）：需要把 abort 信号传进配对/分块循环（只加中断点、不改结果，对账 fixture 守护）。
> 另：`PhotoDecodeGate` 仍无优先级队列（预取与可见图同队）；`assertDestinationPath` 仍逐文件 canonicalPath；D-2 的 checkpoint 仍每张全量重建。

| 编号 | 为何不在本轮 |
| --- | --- |
| B-1 单连接拆分 | 需要设计只读连接 + 迁移 `reopen()` 双连接语义；先做会牵连事务可见性。 |
| B-2 `ensurePhoto` 12 条语句 N+1 | 大改 DB 写入路径，必须同时证明幂等（重复 backfill 不得产生第二个 asset）。 |
| B-8 人脸按批事务 | 需保持「全失败照片保留旧观测/状态」语义；`synchronous=normal` 已先落地降低 fsync 成本。 |
| B-13 语句缓存 | 句柄生命周期要绑定 `close()/reopen()`（迁移会 reopen），需专项。 |
| B-5 keyset 分页重构 · B-6/B-10 SQL 谓词（RAW 判定落列） | 需要迁移 + 回填 + 「页内容 vs countForScope」一致性回归。 |
| B-9/F-2 聚类 LSH + abort 传入 | 必须与对账 fixture 逐位一致，属算法专项。 |
| F-1 人脸 pipeline（CGImage 直通 + 检测降采样） | `analysis_signature` 含 `previewMaxDimension`，改尺寸会触发全库重算，需迁移策略。 |
| F-3 embedding BLOB 流式 · F-7 margin 暴力匹配 | 大规模重构 / 需保证 ambiguous 判定门槛等价。 |
| E-1 sim.result 改 async · E-4 sync_status items 裁剪 | 协议 async 化波及 VM 与 stub；items 裁剪需确认消费方（现只剩存储的 lastSyncDate）。 |
| A-7 JPEG 往返 / CGImage 直通 | 改动 core 解码 API 面（Data 接口是 IPC 契约）。 |
| C-5 重复页 recommendation 缓存 · C-7 人脸页 hover 下沉 · C-10 胶片条 enumerated/currentGroupAssets | 其余视图侧项，改动面各自独立，建议下一轮成批。 |
| A-14 导入移出主线程 · D-5/D-6 刷新合并 · A-10 区域解码策略 | 需要 UI 状态（导入中/刷新合并窗口）与产品口径。 |

## 8. 未验证 / 待补

- 无真机、无真实 RAW 库、无万级真实库：所有毫秒为下界或量级估算（A/B/D 各自声明）。
- 未在运行中的 app 上采样（Instruments/Time Profiler/vmmap）。
- NSCache 淘汰策略与真实 RSS 峰值未测；CIContext/GPU 显存未测。
- E（IPC/序列化）、F（算法管线）报告待合并。
