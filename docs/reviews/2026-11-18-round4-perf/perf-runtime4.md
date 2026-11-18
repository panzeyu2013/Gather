# Round4 运行时性能：图片缓存读路径、终态重试异步化、模型缓存 LRU、元数据并发读（task-23 / perf-runtime）

- 日期：2026-11-18（评审目录 2026-11-18-round4-perf）
- 基线：`2521c00b`（rounds 1-3 已提交）+ round-4 同伴未提交改动（本 agent 只改自己写域，未回滚他人改动）
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode → **未编译 app、未运行 app、无 Instruments**。Swift 6.2 只做
  `swiftc -parse`（语法级）；行为证据来自 `.gather/probes/round4/` 下用真实 Swift 6 语义复刻的 Linux 探针
  （**逻辑副本**，不是仓库模块的编译产物；见 §5.3）。
- 行为约束：无用户可见文案/布局/API 变更；无 schema DDL/fingerprint 变更；无新增 `@unchecked Sendable`
  （cleanup ratchet 60/60）；未 git commit。
- 写域：`GatherUI/Support/{PhotoThumbnailView,ThumbnailDiskCache}.swift`、
  `GatherApplication/Services/{Job,Metadata,Maintenance,Export,Delivery,Output,Workflows}/**`、
  `GatherAnalysis/Face/EmbeddingModel.swift`、本文件。

## 0. 摘要（做了什么 + 证据）

| # | 类型 | 位置（改后） | 改动 | before → after 证据 |
|---|------|--------------|------|---------------------|
| R1 | 图片缓存 | `Support/ThumbnailDiskCache.swift:111-142` | 磁盘缓存命中的 mtime 触碰从「每次命中都 setAttributes」改为「1h 窗口 + 命中时 stat 判断」 | 热路径元数据写 1 次/命中 → ≤1 次/小时/文件；`THROTTLE_PROBE_OK touches=2 window_skips=1` |
| R2 | 任务收尾 | `Services/Job/JobService+Settle.swift:97-227`、`JobService+Claim.swift:183` | 终态写瞬时失败的重试等待：同步 `Thread.sleep(0.2)` → `await Task.sleep(for:.milliseconds(200))`，`settle/writeTerminal` 改 async | 不再阻塞协作线程池；`RETRY_PROBE_OK retry_ms=200.3 cancel_ms=0.0`；perf ratchet `blocking_sleep 1 → 0` |
| R3 | 模型缓存 | `GatherAnalysis/Face/EmbeddingModel.swift:690-778` | provider 缓存无界 → LRU 上限 4（现有锁内维护访问序 + 驱逐），保留单飞 | `LRU_PROBE_OK loads=6 count=4`（上限/命中不重载/LRU 驱逐/被逐出重载） |
| R4 | 元数据并发 | `Services/Metadata/MetadataDispositionService.swift:42-98` | `conflicts()` 的逐条 XMP 读盘改为 4 路有界并发（detached 隔离取消 + 保序 + try?-empty） | 串行 N 次读盘 → 最多 4 路并发；`CONFLICTS_PROBE_OK ordered=true failureEmpty=true cancelled=40/40 reads=40` |
| R5 | 元数据解码 | `Services/Maintenance/ExternalMetadataMigrationService.swift:52-58,159` | 逐行 `JSONDecoder()` → 共享 `static let keywordDecoder` | 每行一个解码器 → 1 个；perf ratchet `raw_json_decoder` 计数不变（构造点仍是 1 行） |
| R6 | 评估（不改） | `PhotoThumbnailView.swift:272,455,733,747-825`；`MetadataTemplateService.swift:373`；`SidecarXMPProvider.swift:294-319` | `NSImage(data:)` 惰性解码、模板预览 N+1、sidecar 二次解析：给出结论/可行性/验收条件，见 §1.2/§4.3/§4.4 | 见各节；均写了「为什么不在本轮改」 |

改动源文件 6 个（§7）；未新增测试文件（Tests 不在本任务写域）。

## 1. 图片管线

### 1.1 磁盘缓存命中路径：mtime 触碰节流（R1，已改）

**旧实现**（`ThumbnailDiskCache.data`）：

```swift
guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
// 触碰 mtime，供 LRU 清理（失败不影响读取）。
try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
```

每次缓存命中 = `stat(源文件)`（`key()` 需要 mtime+size 做失效判定）+ 读整份 JPEG + **一次 inode 元数据写**
（utimensat）。滚动回看时每个缩略图命中都写一次：空转的写放大（弄脏文件系统 journal，与「读缓存」的
期望成本不符），而 prune 的 LRU 只需要「最近有没有被用过」的粗粒度。

**新实现**：`touchInterval = 3600`；命中时先 stat 缓存文件自身的 mtime，未超过 1h 直接跳过；只有超过
1h 才写一次。失败与旧实现一致只影响 LRU 精度，不影响读取。

| 命中路径 | 旧 | 新（稳态热文件） |
|----------|----|------------------|
| 元数据 syscall | stat(源) + **utimensat(缓存)** | stat(源) + stat(缓存) |
| 文件内容 | open/read/close 整份 JPEG | 同左 |
| 元数据写 | 1 次/命中 | ≤1 次/小时/文件 |

**LRU 正确性论证**：prune 只在总量 >512MB 时按 `contentModificationDate` 升序删到 80%。节流后「热文件」
的 mtime 最多滞后 1h —— 连续被读的文件每 ≤1h 会被再看一次 age 并补写；可能被误判为旧的只有「读取间隔
跨度 >1h 且恰好处在淘汰边界」的项，而这已经是冷缓存（prune 目标）。因此相对顺序在 1h 粒度内保持，
最坏是把「1h 内使用次数不同」的项视为同龄——对淘汰正确性无实质影响。

**证据**：Linux 探针复刻同一逻辑（窗口缩到 1s、把文件 mtime 设为 100s 前）：
```
THROTTLE_PROBE_OK touches=2 window_skips=1
```
即：过期 → 触碰；窗口内 → 不写；窗口外 → 再触碰。

**不能证明的部分（诚实声明）**：Linux 上无法测 APFS 的 stat vs utimensat 实际耗时，也无 macOS 内存/IO
采样；**确定收益**是「热路径不再产生元数据写」，**不确定**的是单个 syscall 的 microbenchmark 差值
（两者都是元数据操作，量级可能接近）。若真机发现 1h 窗口导致淘汰不准，可把 `touchInterval` 下调（如 600s），
逻辑不变。

### 1.2 `NSImage(data:)` 惰性解码（R6：评估后**不改**，记录原因与落地设计）

**现状**：三处视图在 MainActor 上 `NSImage(data:)`（`PhotoThumbnailView.swift:272,455,733`；另有同伴文件的
预取点 `CullingViewModel+Preload.swift:301`）。RAW 解码/JPEG 编码已经由 `PhotoThumbnailDecoder.decodeAsync`
（`PhotoThumbnailView.swift:569-602`，闸门 + 后台队列）移出主线程；主线程剩余成本 = 小尺寸 JPEG（256-1024 档）
的**惰性位图解码**（首绘）+ NSImage rep 构建。round-3 审计把这一点列为「需 image-pipeline agent 处理」，
本轮按任务要求做了实现评估。

**任务建议的方案**：后台 `CGImageSource` 解出 CGImage → `NSImage(cgImage:size:)`（size 用像素×72/DPI），
让惰性解码发生在后台。

**评估结论：本轮不做代码改动。** 四类阻塞理由（任何一条都需要 macOS 实测才能关闭）：

1. **点尺寸/DPI 语义无法在本机验证**：`NSImage(data:)` 的点尺寸由 AppKit 从像素与分辨率元数据折算
   （常见公式：pixels × 72 / DPI，缺 DPI 视为 72）。若某些 JPEG 的 DPI 元数据缺失/为 0/非方（dpiX≠dpiY）、
   或 AppKit 对该格式的处理与公式不同，`NSImage(cgImage:size:)` 会改变 `image.size` —— 该值参与
   `.aspectRatio(.fill/.fit)`（`PhotoThumbnailView` body）与 `FaceCropThumbnailView.layout` 的几何计算，
   属于**用户可见的布局变化**。Linux 无 AppKit，不能对拍。
2. **EXIF 方向语义无法验证**：`CGImageSourceCreateImageAtIndex` 默认**不应用** EXIF Orientation
   （只有 thumbnail 变体才受 `kCGImageSourceCreateThumbnailWithTransform` 影响）；`NSImage(data:)` 对
   JPEG 方向的处理是 AppKit 实现细节。若两者不一致，竖拍照片会旋转 90° —— 这是比性能更严重的可见回归。
3. **颜色空间/alpha 处理差异**：`NSImage(data:)` 经 NSBitmapImageRep 的 ICC/色彩管理路径；CGImage 直通
   `NSImage(cgImage:)` 在 Display P3/CMYK 源上可能呈现不同。无 macOS 像素比对不能排除。
4. **Swift 6 隔离约束**：`NSImage` 非 Sendable；`Task.detached` 的 Success 必须 Sendable，跨回 MainActor
   需要 `sending` 结果/竞态 continuation/复用现有 `@unchecked Sendable` 盒子（新类型被 cleanup ratchet 禁止）。
   即便技术上可行，也只能在「后台构造 NSImage」路线上走，而 AppKit 对象的线程亲和性同样只能在 macOS 验证。

**若后续在 macOS 上实施，建议的验收清单**（供负责人排期）：
- A/B 对拍：对样例集（72/300/空白 dpi、dpiX≠dpiY、8 个方向 EXIF、sRGB/P3/AdobeRGB）比较
  `image.size` 与首帧渲染像素；
- 主线程 hitch：Instruments Time Profiler 记录 200 张滚动，确认「首绘解码」从主线程消失且总 CPU 不升；
- 回退开关：不改公开 API，新增内部 helper + 仅在「DPI 元数据存在且 dpiX==dpiY 且方向=1」时走 eager 路径，
  其余回落 `NSImage(data:)` —— 这是把风险面收敛到「可验证子集」的最小方案，但仍必须先有 macOS 对拍。
- 预期收益上限：剩余主线程成本只是小 JPEG 解码（1-3ms/张量级，非 RAW 的 100-800ms）—— **不是本轮最大的
  性能问题**；优先度应排在启动/DB/查询之后。

### 1.3 `PhotoThumbnailCache` 锁/cost/key 复查（R6：不改）

- **key**：`模式 + path + size + epoch`（`PhotoThumbnailView.swift:772-779`）。模式与解码尺寸都在键里
  （256/512/1024/区域 tile 不会互相覆盖）；epoch 让「用户主动刷新」后旧键失效并驱动 `.task(id:)` 重启。
- **锁**：`PhotoThumbnailCacheBox.lock`（NSLock）只保护 `epoch` 读写与「键生成/存取」的原子性；
  `NSCache` 本身线程安全，锁内不回调外部代码（无重入风险）。读路径：每次 body 求值 1 次 `key()`（取锁读
  epoch），每次 load 1 次 `image(for:)`（取锁读 NSCache）→ 都是无争用 ns 级临界区，**没有可证明的收益**
  去改锁粒度（把 image() 的锁去掉可省 ~20ns，但会削弱现有 Sendable 依据，收益/风险不合算）。
- **cost**：round-3 已改为「位图像素 × 4B × 1.2（下限 256KB）」，`totalCostLimit=512MB`，DPI 图不再低估。
- **结论**：键/锁/cost 均无安全微改；本轮不改，仅记录。

## 2. JobService 终态写重试：同步阻塞 → 异步等待（R2，已改）

**旧实现**（`JobService+Settle.swift:205-216` 改前）：

```swift
private func writeTerminal(_ body: () throws -> Bool) -> TerminalWriteOutcome {
    do { return try body() ? .written : .missed }
    catch {
        do {
            Thread.sleep(forTimeInterval: 0.2)      // 阻塞当前线程 200ms
            return try body() ? .written : .missed
        } catch let retryError { return .failed(retryError) }
    }
}
```

终态写（条件 UPDATE）遇到瞬时 SQL 错误时重试一次；等待用 `Thread.sleep`，在 Swift 并发下会**阻塞协作
线程池的一个线程** 200ms（多个任务同时收尾时可能造成线程池饥饿，影响其它任务调度）。

**新实现**：`settle` 与 `writeTerminal` 改为 `async`；等待改 `try await Task.sleep(for: .milliseconds(200))`；
调用点 `JobService+Claim.swift:183` 改为 `await settle(...)`。取消语义：`Task.sleep` 在停机取消时立即
返回，仍会执行那一次重试（与旧实现「至少重试一次」一致；写终态是停机前必须尝试的收尾，不因取消跳过）。

**证据**：
- 探针复刻同一逻辑（`RETRY_PROBE_OK retry_ms=200.3 cancel_ms=0.0`）：首次失败→200ms 后重试一次成功
  （attempts=2，实测 200.3ms）；两次都失败→attempts=2 返回 failed；任务被取消时 sleep 立即返回、
  仍重试一次（attempts=2，实测 0.0ms）。
- perf ratchet：`blocking_sleep 1 → 0`（Sources 内仅此一处；grep 复核后剩余命中只在本文件注释行）。
- call site 全量：`settle` 仅 `JobService+Claim.swift:183` 一个调用点；Tests 无直接调用（grep 复核）。
- 语义保持：重试次数/顺序/200ms 间隔/错误返回完全一致；唯一时序差异是「pump/removeActiveRun 在瞬时
  写失败时最多晚 200ms」（同一任务顺序执行，非并发重排）。

## 3. EmbeddingModel.Cache：无界 provider 缓存 → LRU 上限 4（R3，已改）

**旧实现**：`providers: [String: FaceEmbeddingProvider]` 只增不减。缓存键 = path + version +
递归 stat 指纹 + computeUnits：同一路径反复换模型权重/计算单元（指纹变化）会不断编译新的 CoreML
provider（每个都是几十 MB 级模型实例），进程内存无界增长。

**新实现**（同一把锁内，不改并发模型）：
- `static let maxProviders = 4`；`providers` 之外增加 `recency: [String]`（最近使用在尾部）；
- 命中：`markUsedLocked(key)` 移到尾部后返回；
- 未命中：保持「锁内加载」的单飞语义（同一 key 不会被重复编译），加载后 `installLocked` 插入并
  `while recency.count > 4 { 驱逐头部 } `；
- `removeAll()` 同时清空 `recency`。

**驱逐安全性**：只丢**缓存引用**。正在推理的调用方持有 provider 强引用（`FaceInferenceEngine` 把注入实例存
在 `private let injectedEmbedder`，见 `Face/Inference.swift:50,57`），不会被提前释放；下次同键请求重新加载，
语义与冷启动一致。内存上界 = 4 个 provider。

**证据**：
- `LRU_PROBE_OK loads=6 count=4`：4 键填满（loads=4）→ 命中不重载（loads 仍 4）→ 插入第 5 键后
  count=4 且最久未用的被驱逐、刚被 refresh 的保留 → 被驱逐键重载（loads=6）。
- 既有测试兼容：`FaceEmbeddingModelTests.cacheReusesProviderAndInvalidatesOnFileChange` 只用 3 个键
  （v1/v2/改文件后的 v1'），3 ≤ 4 不触发驱逐，counter 断言（1/2/3）不变；`FaceEmbeddingFingerprintTests`
  用 1-2 个键。
- 残余（低）：同一进程若用过 >4 种不同「路径+版本+指纹+computeUnits」组合，旧组合会重载（一次编译的
  冷启动成本）。实际运行一次只用一个模型，只有用户在同一会话内反复改模型设置才会触发；可接受的退化。

## 4. 元数据批量化/并发（R4/R5 + 评估）

### 4.1 `MetadataDispositionService.conflicts`：串行 XMP 读盘 → 4 路有界并发（R4，已改）

**旧实现**：`for delivery in conflictDeliveries { let items = items(deliveryId:) ; await xmp.readAttributes(...) }`
—— 每条冲突行串行读一次 XMP。冲突多时（批量写入后一批 sidecar 同时冲突）读盘延迟线性叠加。

**新实现**（`MetadataDispositionService.swift:42-98`）：
1. **DB 部分保持串行**：`conflictDeliveries` 后的 `items(deliveryId:)` 逐行读 —— 端口只有单行 API
   （`MetadataDispositionStore.swift:14`），不改公开协议；且是进程内 SQLite 读、冲突行通常个位数。
2. **XMP 读盘改有界并发**：`batchAsync(rows, concurrency: 4)`，body = `(try? await xmp.readAttributes(...)) ?? MetadataWriteAttributes()`。
   并行安全依据：`XMPProvider: Sendable`（`GatherProtocol/Protocol/XMPProvider.swift:113`）；`SidecarXMPProvider`
   的「同路径串行」契约只约束**写**路径，不同 sidecar 的**只读**并行安全。
3. **取消隔离（本轮发现的坑，已修）**：`BatchRunner` 的取消契约是「调用方取消后停发新号，返回已完成项
   的**部分结果**」。旧串行实现不响应取消（逐条 try?-empty 继续），若把部分结果按下标对齐会错位/越界。
   实测探针：40 项批读、调用方 50ms 后取消 → `batchAsync` 只返回 8 项。因此把整批读放进
   `Task.detached(priority: .userInitiated)`：不随调用方取消，结果与 rows 严格一一对应（与旧语义一致；
   一次调用一个 detached，成本可忽略）。读取结果仍按 4 路并发上限执行。构建阶段加防御性下标兜底
   （理论不可达时按「读失败=空属性」处理，绝不越界）。

**保持的语义**：返回顺序 = 冲突行顺序；单条读失败 = try?-empty（不伪造 remote 值）；字段投影/裁决逻辑不变；
对外签名 `async throws` 不变。`try?` 出现次数不变（cleanup ratchet 的 try_optional 净改善来自 R1，不是这里）。

**证据**：`CONFLICTS_PROBE_OK ordered=true failureEmpty=true cancelled=40/40 reads=40` —— 用逐字拷贝的
`BatchRunner` + 同构调用代码在 Swift 6 下编译运行：慢项先完成不影响输出顺序；p3 读失败行得到空属性；
调用方中途取消后仍拿到 40/40 且每行只读一次（无重复读）。

### 4.2 `ExternalMetadataMigrationService.decodeKeywords`：逐行解码器 → 共享解码器（R5，已改）

evaluate 阶段逐候选调用 `decodeKeywords`（迁移可扫到上万张，有 keywords 的行才解码）。旧实现每行
`JSONDecoder()`；新实现 `private static let keywordDecoder = JSONDecoder()`（`Sendable` 依据：JSONDecoder 无跨
调用可变状态、Foundation 已标 Sendable，与 `GatherPersistence/Support/BatchRunner.swift` 同目录的
`RepoJSONCoding` 先例一致；Linux 探针 `STATIC_JSONDECODER_OK` 验证 Swift 6 + warnings-as-errors 可通过）。
输出/失败回退（解码失败 → 空列表 + debug 日志）逐字不变；perf ratchet 的 `raw_json_decoder` 构造点计数
（1 行）不变。

### 4.3 `MetadataTemplateService.preview` 的 N+1 评估（R6：**不改**，记录）

- 现状：`preview` 对每张照片调用 `metadata.photoDetail(photoId:)`（`MetadataTemplateService.swift:373-374`）；
  `photoDetail` = `photoRepo.getLookupByIds([photoId])` + `metadataCacheRepo.get(photoId)`（`MetadataService.swift:261-266`），
  即 **2 条 SQL/张**；同循环内还有逐张 `await metadata.diskAttributes(...)`（读盘 IO，串行）。
- 为何不在本轮批量：TemplateService 只持有 `metadata: MetadataService`（`:128`），没有仓储级访问；
  MetadataService 也没有「批量 photoDetail」API（`getPhotosByIds` 只给 lookup，`getMetadata` 给 tags，
  都不含 cache 行/descriptive 投影所需的完整形状）。新增批量 API 会扩大公开面（且 `Services/MetadataService.swift`
  不在本任务写域）。UI 侧通常有 200 上限（`MetadataBatchEditorSheet.swift:32,110`），服务层未设上限
  （模板 sheet 传当前选择）。
- 建议后续（需单独任务）：给 MetadataService 加 `photoDetails(photoIds:) -> [MetadataPhotoDetail]`
  （`getLookupByIds` + `MetadataCacheRepo.getBatch` + `PhotoMetadataProjector` 一次投影），preview 改为一次批量
  取 detail；读盘（`diskAttributes`）可再按有界并发（注意与 §4.1 相同的取消/保序问题）。收益：SQL 2N → ~2 批；
  但读盘是主成本，收益中等。

### 4.4 `SidecarXMPProvider.readSidecar` 二次解析调查（R6：写域外，未改，给方案）

- 现状（`GatherMetadataIO/SidecarXMPProvider.swift:294-319`）：同一份 sidecar 数据
  1) `XMLParser` + `SidecarXMLDelegate`（rating/label/urgency/日期/GPS/关键词）；
  2) `Self.normalizeKnownPrefixes(data)`（Data→String→xmlns 正则扫描→必要时逐标签改写→Data，见
     `SidecarXMPProvider+IPTCReading.swift:62-117`）后，再 `XMLParser` + `IPTCXMLDelegate`（描述性元数据/triage）。
  文件头注释（本文件 :5）说明这是**有意**的取舍：「单文件二次解析的代价可忽略（sidecar 通常 < 20KB），
  换来的是不用改动已验证的旧解析路径」。
- **可证明安全的优化提案**（需 GatherMetadataIO 写域 + 跑现有 SidecarXMPProvider*/IPTCTests）：
  - 常见情形（文档没有「已知命名空间绑到非规范前缀」）`normalizeKnownPrefixes` 返回原文：此时两次解析
    的输入**逐字节相同**，可用一个复合委托（把同一组 SAX 回调转发给两个独立委托）**一次解析**得到两者结果
    —— 两个委托都是纯收集状态机，同事件流 ⇒ 输出相等的等价性可由构造证明；有改写时回退现有两遍。
  - 顺带：`normalizeKnownPrefixes(Data)` 恒做 Data→String→Data 往返，即使无改写；无改写时直接返回原
    `Data` 可省两次拷贝（同样可证明等价）。
- 为什么本轮不做：文件不在任务写域；改动涉及 IPTC 前缀归一化的关键路径，必须用现有测试套件（macOS 或
  可在 Linux 构建的 GatherMetadataIO target）验证后才敢合入。列出供后续排期。

### 4.5 其余服务子目录复查

按 round-3 的同一扫描口径复查 `Services/{Job,Export,Delivery,Session,Maintenance,Output,Workflows}`：
循环体内无逐行 `DateFormatter/ISO8601DateFormatter/JSONEncoder/JSONDecoder` 构造，也无逐行
`items(deliveryId:)/get(photoId)` 类 DB 调用（仅 Metadata 两处误报：枚举字段循环/switch 分支，非构造点）。
`Services/Delivery`、`Services/Session` 目录**不存在**（交付域在 `GatherDelivery` target、会话域在
`Services/SessionService.swift`），审计项 N/A。

## 5. 验证

### 5.1 语法（Linux，Swift 6.2）

```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <6 个被改文件>   # 全部 exit 0，无输出
```

**语法级**，不覆盖 Swift 6 类型/并发检查（并发形状见 §5.3 的编译级探针）。

### 5.2 门禁（交付前最后运行）

| 门禁 | 命令 | 结果 |
|------|------|------|
| cleanup ratchet | `./scripts/check-cleanup-ratchet.sh` | PASS（unchecked_sendable 60/60；try_optional 256/257 改善 1） |
| perf ratchet | `./scripts/check-perf-ratchet.sh` | PASS（blocking_sleep **1→0**（R2）；raw_json_decode_chain **23→22**（R5：逐行 `JSONDecoder().decode` → 共享 `keywordDecoder.decode`）；其余持平） |
| layering | `./scripts/check-layering.sh` | PASS |
| protocol surface | `./scripts/check-protocol-surface.sh --strict` | PASS（未改公开协议/API） |
| design system | `./scripts/check-design-system.sh` | PASS |
| repo hygiene | `PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh` | PASS（[a]-[g]；含 shellcheck/空白/本地化） |

说明：`blocking_sleep` 与 `try_optional` 的改善需要 gate-smith 在 round-4 收口时收紧 baseline（baseline 文件不在本
任务写域，本 agent 未改）。

### 5.3 Linux 行为探针（`.gather/probes/round4/`，Swift 6 + `-warnings-as-errors`）

| 探针 | 复刻内容 | 输出 |
|------|----------|------|
| `lru_probe.swift` | `EmbeddingModel.Cache` 的 LRU 逻辑（上限/命中/驱逐/重载） | `LRU_PROBE_OK loads=6 count=4` |
| `retry_probe.swift` | `JobService.writeTerminal` 的异步重试语义（成功/两次失败/取消） | `RETRY_PROBE_OK retry_ms=200.3 cancel_ms=0.0` |
| `throttle_probe.swift` | `ThumbnailDiskCache.touchIfStale` 的窗口节流（真实临时文件 mtime） | `THROTTLE_PROBE_OK touches=2 window_skips=1` |
| `conflicts_probe.swift` | 逐字拷贝 `BatchRunner` + 同构的 conflicts 调用形态（保序/失败空属性/取消不截断/无重复读） | `CONFLICTS_PROBE_OK ordered=true failureEmpty=true cancelled=40/40 reads=40` |
| `cancel_probe.swift` | `batchAsync` 的取消契约（40 项、调用方取消 → 部分结果） | `CANCEL_PROBE partial_count=8 full_count=40` / `detached_count=40` |
| （静态） | `static let decoder = JSONDecoder()` 在 Swift 6 下 Sendable 检查 | `STATIC_JSONDECODER_OK` |

### 5.4 验证天花板（明确未做）

- 未跑 `swift build/test`（app/GatherUI 依赖 macOS AppKit/CoreML；core 的 GatherAnalysis 依赖 CoreGraphics，
  Linux 无法构建）→ 真实模块的类型/并发检查、AppKit/ImageIO/CoreML 行为、界面渲染均未验证。
- 无 macOS 真机/无 Instruments：磁盘缓存 syscall 收益、主线程 hitch、LRU 实际内存曲线都是成本模型推导；
  探针是**逻辑副本**，不是仓库模块。
- 未新增回归测试（Tests 不在本任务写域）；conflicts 取消/保序语义靠 §5.3 探针与现有 API 测试
  （`APIExportMetadataTests.conflictsAndResolve` 单冲突行不受并发化影响）间接覆盖。
- `ThumbnailDiskCache` 的 1h 窗口在真实 APFS 上的 LRU 效果未验证（见 §1.1 声明）。

## 6. 残余风险与后续建议（按优先级）

1. **P1（需 macOS）`NSImage(data:)` 主线程惰性解码**：见 §1.2。剩余主线程成本是小 JPEG 解码（1-3ms/张量级），
   优先级低于启动/DB 查询；若做，按 §1.2 验收清单先在「DPI 存在且 dpiX==dpiY 且方向=1」子集上 A/B。
2. **P2 模板预览 N+1**：见 §4.3；需要 MetadataService 批量 detail API（公开面 +1，需评审）。
3. **P3 sidecar 二次解析**：见 §4.4；GatherMetadataIO 写域内、可证明等价的两步优化（复合委托 + 免往返拷贝），
   需跑现有 IPTC 测试。
4. **P3 conflicts 并发读的语义边界**：不同 conflict 行若指向同一 `photoPath`（理论上重复行），并发只读仍安全
   （不写文件），但会把同一文件读多次；目前 `conflictDeliveries` 按 xmpPath 唯一，不影响。
5. **P4 模型缓存 LRU 驱逐抖动**：同进程 >4 种模型组合会重载（§3 残余），仅用户反复改模型设置时出现。
6. **P4 磁盘缓存 LRU 1h 粒度**：极端淘汰边界下列序不精确（§1.1），可通过下调 `touchInterval` 调整。
7. **P5 终态收尾 pump 延迟**：瞬时 DB 写失败时，`pump/removeActiveRun` 最多晚 200ms（§2 语义差异），
   属罕见错误路径，且旧实现同样要等 200ms（只是阻塞线程）。
8. 观察项：`PhotoDecodeGate` 的等待者用 50ms 轮询探针实现「取消即返回」（`PhotoThumbnailView.swift:609-621`），
   RAW 解码 100-800ms 期间每个等待者约 2-16 次唤醒；可用 continuation/cancellation-handler 消除轮询，但属
   并发竞态敏感改动（重复 resume 风险），本轮未动，列观察项。

## 7. 改动清单

| 文件 | 行（改后） | 内容 |
|------|------------|------|
| `desktop/native/gather-app/Sources/GatherUI/Support/ThumbnailDiskCache.swift` | 111-142 | R1：`touchInterval` + `data()` 调 `touchIfStale` + stat-gated 触碰 |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Settle.swift` | 93-97（settle async）、119/143/159/181（await writeTerminal）、205-227（async writeTerminal + Task.sleep） | R2 |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Claim.swift` | 183 | R2 调用点 `await settle` |
| `desktop/native/gather-core/Sources/GatherAnalysis/Face/EmbeddingModel.swift` | 690-778 | R3：maxProviders/recency/markUsedLocked/installLocked/removeAll |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataDispositionService.swift` | 42-98 | R4：串行 DB + detached 4 路并发 XMP + 保序/兜底 |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/ExternalMetadataMigrationService.swift` | 52-58、159 | R5：共享 keywordDecoder |
| `docs/reviews/2026-11-18-round4-perf/perf-runtime4.md` | 本文件 | 审计记录 |

未 commit；未改 schema/DDL/fingerprint、未改公开 API 签名、未改 en.lproj/design baseline、未新增
`@unchecked Sendable`。
