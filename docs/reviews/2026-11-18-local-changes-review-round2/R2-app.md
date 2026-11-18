# R2 第二轮独立评审：gather-app（GatherUI / GatherHost）修复验证 + 残余风险

- 评审人：review2-app（第二轮独立评审；与第一轮 review-app 为不同审查方）
- 评审对象（app 侧）：
  - 第一轮修复提交 **6e940350** 的全部 app 改动（`desktop/native/gather-app/Sources/**` + `Tests/**`）；
  - 本地 main 相对 `origin/main`（e5c54f37）的全部 app 改动：**109 files, +1660/−639**（全仓 19 commits / 226 files）；
  - 残余项复评：round-1 R2-app.md 的 A3/A8/A9/A12 等未修项。
- 基线：HEAD = **0288ea8d**。评审进行中工作区另有他人（lead/其他 reviewer）的**未提交**修复，下文按
  「HEAD 状态」与「工作区快照」分别注明；本人全程只读，未修改任何 tracked 文件。
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode。Swift 6.2（.gather/swift62/usr/bin/swiftc）：
  - 全量 `-parse` **463/463** app Swift 文件（Sources+Tests）通过（EXIT 0）；
  - **本轮新增能力：对不依赖 SwiftUI/AppKit 的纯 Foundation 文件做真实 `-typecheck`**（第一轮只有 `-parse`）；
  - 全部逻辑探针在 .gather/r2app2/（gitignored）：DateFormatting 原样编译 + 17,295 组新旧对拍、
    Observation 依赖探针（-O）、布局缓存/Lightbox/packedSize/preload 守卫逻辑对拍、并发锤测；
  - 10 道 app 相关仓库门禁全部 EXIT 0。
- **验证上限（必须保留）**：未编译 AppKit/SwiftUI target、未链接、未运行 App、未跑 swift test、
  未跑 check-warnings、无 Instruments/真机。SwiftUI 运行时行为（body 失效时序、NSCache 淘汰、
  AppKit 的 NSImage/DPI 行为）与 Apple Foundation 输出只能在 macOS 复验。

## 0. 摘要（先给 P0）

**本轮发现 3 个 P0（编译破坏），全部是纯 Swift 语言规则、与平台无关 ⇒ macOS `swift build` 必红。**
其中 2 个是 6e940350 修复提交自己引入的，1 个是更早的本地提交（2cbe3e68）引入、**第一轮漏掉的**；
第一轮的验证方式是「331/331 `swiftc -parse` 通过」，而 `-parse` 只做语法解析，**不查标签匹配、不查访问级别**，
因此这三个都查不出来。

1. **P0-1（6e940350 引入）DateFormatting.swift 多尾闭包标签错**：`withFormatter<T>(key:make:_ body:)`
   第三个参数声明为**无外部标签** `_ body:`，4 处调用却写多尾闭包标签 `... } body: { ... }` ⇒
   `error: extraneous argument label 'body:' in call` ×4。
   - 证据：HEAD blob 原样 `swiftc -typecheck -swift-version 6` → 4 errors（行 77/108/120/132）；
     最小两文件探针复现同规则；**工作区已有一行未提交修复**（`_ body:` → `body:`），该版本
     `-typecheck` **EXIT 0**（我复核为正确最小修复）。
2. **P0-2（6e940350 引入）CullingViewModel+Preload.swift 跨文件访问 private 成员**：
   新增过期守卫读 `pageAssignmentCount`，该属性在 CullingViewModel.swift:155 声明为
   `@ObservationIgnored private var`（Swift `private` = 文件作用域，+Preload.swift 是另一文件）⇒
   `error: 'pageAssignmentCount' is inaccessible due to 'private' protection level`。
   - 证据：Linux 两文件最小探针复现该规则；grep 全仓只有一处声明、无 internal 镜像属性。
   - 工作区已改为 `@ObservationIgnored var pageAssignmentCount = 0`（internal）——**能编译**，
     但更严谨的写法是 `@ObservationIgnored private(set) var`（跨文件只读、setter 仍限本文件）。
3. **P0-3（2cbe3e68 引入，第一轮漏掉）navigationGroupsVersion 跨文件访问 private 成员**：
   声明在 CullingViewModel.swift:321 `@ObservationIgnored private var navigationGroupsVersion`，
   却在 CullingViewModel+Navigation.swift:238/245 跨文件读写（就是本轮 R2-A1 修复所在函数）⇒
   同型 `inaccessible due to 'private'` 编译错误。**截至我最后一次检查（11:2x），工作区仍未修**。
   - 证据：Linux 两文件最小探针（.gather/r2app2/a.swift+b.swift）复现；grep 声明唯一；
     启发式扫描（diff 新增的 35 个 private 成员名 × 跨文件引用）只命中 P0-2/P0-3 两个真阳性。
   - 建议：`@ObservationIgnored private(set) var navigationGroupsVersion = 0`（与 P0-2 同口径）。

**修复验证结论**：round-1 的 A1（Observation）、A0（rowIndex 回退）、A2（Lightbox 身份）、
A4/A5（formatter 持锁 + mediumShort 键）、A6、A10、A11、A14、R5-06 守卫、R3-T02 测试窗口，
经代码复读 + 独立探针**全部成立/无回归**（见 §2）；唯一实质副作用是 P0 编译破坏（修复提交自身的
验证方式缺口）与 preload 守卫的保守 false-negative（P3，见 R2A-04）。
round-1 的 A3（NSCache 淘汰悬崖）经本轮**降级**：cost 口径变化对当前数据路径基本是 no-op（证据见 R2A-08）。
**未发现新的行为性 P1/P2 回归。**

## 1. Findings

| ID | 严重度 | 位置（file:line / commit） | 问题 | 证据（我检查/运行了什么） | 建议修复 | 置信度 | macOS 不可验证 |
|---|---|---|---|---|---|---|---|
| R2A-01 | **P0（HEAD 编译中断）** | Sources/GatherUI/Support/DateFormatting.swift:59,77-85,108-114,120-126,132-138（6e940350） | `withFormatter` 第 3 参 `_ body: (DateFormatter)->T`（无外部标签），4 处调用写多尾闭包 `} body: { ... }` ⇒ Swift 6 报 4× `extraneous argument label 'body:' in call`。**HEAD 无法编译**。 | HEAD blob 拷到 .gather/r2app2/head/ 后 `swiftc -typecheck -swift-version 6` → 4 errors（行 77/108/120/132）；最小两文件探针复现；工作区未提交版（参数改 `body:`）`-typecheck` EXIT 0，且被我的等价性探针以 -O 正式编译运行。 | 参数改 `body: (DateFormatter) -> T`（工作区已这么做，正确）；根治：把「可 typecheck 的纯 Foundation 文件」纳入本地/CI 检查（现门禁均为 grep/parse，抓不到此类）。 | 高 | No（语言规则，macOS 同） |
| R2A-02 | **P0（HEAD 编译中断）** | Sources/GatherUI/Culling/CullingViewModel+Preload.swift:188,196 vs CullingViewModel.swift:155（6e940350） | 修复 R5-06 的新守卫读 `pageAssignmentCount`，但它在主文件声明为 `@ObservationIgnored private var`；+Preload.swift 是另一文件 ⇒ `inaccessible due to 'private' protection level`。 | 两文件最小探针复现；grep 全仓：声明仅 CullingViewModel.swift:155，使用仅 +Preload:188/196，无 internal 镜像；工作区已改 internal（当前 grep 可见 `@ObservationIgnored var pageAssignmentCount = 0`），该改法可编译。 | 保持 internal 读能力但收紧写面：`@ObservationIgnored private(set) var pageAssignmentCount = 0`（didSet 在同文件，`private(set)` 不影响）；或加 internal 只读包装属性。 | 高 | No |
| R2A-03 | **P0（编译中断，第一轮漏报）** | Sources/GatherUI/Culling/CullingViewModel.swift:321 vs CullingViewModel+Navigation.swift:238,245（2cbe3e68） | `navigationGroupsVersion` 声明 `@ObservationIgnored private var`，却在 +Navigation.swift 的 `navigationGroupSizeByPhotoID`（即本轮 R2-A1 修复函数）跨文件读写 ⇒ 同型 private 访问编译错误。**当前工作区仍未修**。 | 两文件最小探针复现（a.swift 声明 private、b.swift extension 读 → 同一条 error）；grep 声明唯一；diff 新增 private 成员名跨文件扫描只命中此条与 P0-2。与 round-1 A1 修复同函数 ⇒ 该修复当前根本无法编译。 | `@ObservationIgnored private(set) var navigationGroupsVersion = 0`（或 internal + 注释说明只读）。 | 高 | No |
| R2A-04 | P3（性能副作用） | Sources/GatherUI/Culling/CullingViewModel+Preload.swift:188-197（6e940350） | preload 过期守卫用 `pageAssignmentCount` 比较：**任何 page 重新赋值（包括决策回显只改 state、内容完全相同的替换）都会让在途预取整体放弃**（false negative），且决策回显本身不会重新触发 `scheduleNeighborPreload`（触发点只有 currentPhotoId/pageSignature/onAppear/setVisible）。快速打分后紧跟方向键时，预取可能丢掉一次且不重试，直到下一次切图。 | 读代码 + 触发点 grep（CullingWorkbenchViewer:514/545/558、CullingViewModel.swift:630、+Preload:151）；`applyDecisionStates`（+Actions:39）每次决策都 `self.page = CullingPage(...)` ⇒ pageAssignmentCount++；逻辑探针覆盖 4 种场景（未变通过/页变放弃/当前照片变放弃/同内容替换也放弃）。页面/当前照片真变化的保护是有效的（正确性无风险）。 | 更精确的守卫：await 回来重算 `CullingPreloadPlanner.plan(assets:currentPhotoIndex:)` 与旧 plan 做 `Equatable` 比较（plan 最多 5 项、O(1)），相等即继续；这样只放弃「目标真的变了」的情况，不误伤同内容替换。 | 高 | Partly（时序窗口需 macOS/真机复验） |
| R2A-05 | P3（不变量） | Sources/GatherUI/Gallery/GalleryGrid.swift:14-57（6e940350） | R2-A0 回退只覆盖「映射未命中」；若未来/测试在 `store` 之后直接再写 `rows`，`rowByItemIndex` 命中仍返回**陈旧行号**（不校验身份，也没有 didSet 重建）。当前生产只有 `store(key:rows:)`/`reset()` 两个写点（grep 确认），既有测试只在**新建空缓存**上直接写 rows（此时 map 空，回退生效）。 | 读代码 + 生产写点 grep（GalleryGrid.swift:144、GalleryView.swift:168）；探针：新缓存空 map→nil、直接写 rows→0/0/1/nil 全部符合既有测试断言；store 路径 300 组随机 rows 对拍旧 `firstIndex` 语义 0 mismatch；热路径 500×40 行 map 命中 16.9 ns/次（O(1) 保持）。 | 把 `rows` 收成 `private(set)`（测试改走 `store`）或给 `rows` 加 didSet 重建映射；至少加注释声明「rows 只能经 store 写」。 | 高 | No |
| R2A-06 | P3（脆弱性） | Sources/GatherUI/Culling/CullingGrid.swift:265-300（2cbe3e68/6e940350） | 同几何复用条件 `sameGeometry` 比较了 id 序列与打包宽高、精确 width/rowHeight，但**没有比较 `gap` 参数**；目前唯一调用点传常量 `gap: 8`（CullingGrid.swift:491-499），所以现状正确；未来若 gap 随密度/主题变化，会复用错误行几何。 | 读代码 + `rows(` 调用点 grep（全仓唯一调用点，常量 8）。 | 把 gap 并入 `cachedExact*` 比较，或在函数注释里写明「gap 必须恒定」。 | 高 | No |
| R2A-07 | P3（边界） | Sources/GatherUI/Gallery/LightboxView.swift:54-67（6e940350） | A2 修复后的身份校验对**重复 id** 仍有一个理论窗口：stale 映射命中下标 i、`photos[i].id == currentID` 成立但 i 不是首个匹配（需要 photos 含重复 id 且替换后同一 id 出现在更早位置）⇒ 返回非首个下标；旧「逐帧 firstIndex」实现永远返回首个。仅影响重复 id 数据（本身已破坏 ForEach 身份，属既有问题），显示内容仍是同一 id 的照片。 | 读 makeIndex（首个映射）与 resolvedCurrentIndex；逻辑探针对拍：空数组/nil id/id 消失/重排/重复 id+stale 映射场景下与旧线性语义一致（唯一构造出的差异需要重复 id）。 | 若要严格等价：命中后加一次「首现校验」成本 O(1)（如再取 photos.firstIndex(ofID:) 不安全）——实用上无需处理，记录为已知边界即可。 | 高 | No |
| R2A-08 | P3（对 round-1 A3 的降级修正） | Sources/GatherUI/Support/PhotoThumbnailView.swift:803-824（2cbe3e68） | round-1 断言「cost 由点改像素后，带 300dpi 元数据的相机 JPEG cost 最高 17× ⇒ 淘汰悬崖」。**本轮复核该前提不成立**：进入该缓存的 NSImage 全部来自 App 自己的预览解码（`decodeAsync` → `RAWDecoder.encodeJPEG`，只设置 `kCGImageDestinationLossyCompressionQuality`、不写 DPI），`NSImage(data:)` 的 size 与像素一致（默认 72dpi）⇒ 新旧 cost 在现有路径上**基本相同**，不是行为回归。真正的残余是**既有**预算问题：单个 NSCache 512MB + 2560 档预览 ≈ 21MB/张 ⇒ 约 24 张；8192 档（对比/1:1）≈ 215MB/张 ⇒ 约 2 张；与网格 256/1024 桶共用预算。 | 读 decodeAsync/decodeUncached/RAWDecoder.encodeJPEG（无 DPI 属性）；cost 算术（pixels≈2560×1707→21.0MB；1024→3.36MB；256→256KB 下限）；`totalCostLimit=512MB`（:764）；grep 无 cost 相关测试。 | 保留像素口径（语义更准，且对现状等价）；**建议下一步在 macOS 实测**后决定是否把 totalCostLimit 提到 1–2GB 或按「网格缩略图 / 查看器 tile」分桶预算；补 cost 单测。 | 中（AppKit size 行为需 macOS） | Partly/Yes（NSImage.size 与 NSCache 淘汰需 macOS） |
| R2A-09 | P3（测试覆盖缺口） | Tests/GatherAppTests/**（6e940350 只改了 ReviewFixTests 两处窗口，未为 app 修复新增测试） | 本轮 app 侧修复中，只有 A0 有既有测试 `JustifiedLayoutTests.layoutCacheMapsItemIndexToRow` 覆盖；A1（Observation 依赖）、A2（Lightbox 身份）、R5-06（过期守卫）、A10（packedSize）、A6（prune 顺序）、A11（lookup 等价）都没有回归测试；DateFormatting 的既有 oracle 测试（DisplayDateFormattersTests）只覆盖输出等价，不覆盖「并发持锁」。 | `git show 6e940350 --stat`（仅 ReviewFixTests +8/+8 行窗口修复）；grep Tests 无上述断言。 | 补 2–3 个纯逻辑单测：resolvedCurrentIndex 抽成纯函数测 stale 身份；preload 守卫/plan 等价的纯逻辑测试；packedSize clamp 边界。Observation 依赖在 macOS 上可用 withObservationTracking 测。 | 高 | No |
| R2A-10 | P3（文档口径，round-1 A8 未变） | Sources/GatherHost/AppBootstrap.swift:186-195,423-439（0240eb56） | 启动日志把各阶段标为「自耗时（languageSeed 与 runtimeStart 并行，各自计时）」。实测语义：runtimeStart = 从 detached 启动到 value 返回的墙钟（≈ 其自身时长），languageSeed 为其自身时长；两者并行，只有「把各行相加」时会重复计入两者重叠的那一小段（≤ languageSeed 时长）；行内已注明并行，性质是分析口径而非代码缺陷。 | 读代码 + 并行安全静态复核（GatherLocalization 仅 GatherUI 输出路径引用、runtime.start 路径零引用；DB 经 connectionLock/只读池串行，busy_timeout=5s；两 await 都在 scene 发布前完成；失败路径 seed 先完成）。 | 可保持；若要更精确，日志 label 改为 runtimeStart(wall) 或在 summary 里标注 overlap。 | 高 | Partly（真实启动时序/DB 竞争需 macOS） |
| R2A-11 | P3（残余，round-1 A12） | Sources/GatherUI/Gallery/GalleryView+Content.swift:331-348（2cbe3e68） | `moveGalleryCursor` 锚点仍是 `selectedIds.compactMap { indexByID[$0] }.min()`：每次方向键 O(选中数)。⌘A 全量选择（上万）时每次按键 O(k)（虽已从「每个选中 id 在 filtered 里 O(n) 扫」降到 O(k) 查表）。 | 读代码；本轮未改该行；round-4 文档已记录为残余。 | 可选：VM 内缓存「最小可见选中下标」（key = filtered 代数 + selectionVersion），每次按键 O(1)。 | 高 | No |
| R2A-12 | P3（残余，round-1 A9） | Sources/GatherUI/Culling/CullingFilmstrip.swift:74-86（2cbe3e68） | 续页 onAppear 用 `pageIndex(ofPhotoId:)`（重复 id 取首个）代替旧「body 快照 enumerated 位置」；页内若出现重复 photo id，尾部 4 张触发 loadMore 的位置可能不同；重复 id 本身也会破坏 ForEach 身份（既有问题）。 | 读代码 + 旧/新语义对照；无证据表明实际会出现重复 id（服务端 list_page 按资产唯一）。 | 可保留；若要严格等价保留 (id, offset) 快照或给行独立 identity。 | 高 | No |
| R2A-13 | P3（加固） | Sources/GatherUI/Culling/CullingViewModel.swift:155-156（工作区改动） | P0-2 的修法把 `pageAssignmentCount` 从 `private` 直接放开成 internal **可写**；它是纯缓存代数，外部写会破坏索引不变式（didSet 不会触发，索引逻辑会认为代数未变）。 | 读声明/使用点；当前类型内只有 didSet 会写。 | 改 `@ObservationIgnored private(set) var`（外部可读、不可写）。 | 高 | No |
| R2A-14 | P3（记录） | Sources/GatherUI/Support/DateFormatting.swift:146-158（6e940350 附带） | `fileSize` 在锁内做 ByteCountFormatter 格式化。Linux corelibs 实测 ~50µs/次（缓存实例 50.1µs vs 类方法新实例 47.7µs——**缓存本身几乎不省时间**，耗时在格式化），若未来出现后台调用会与 UI 日期格式化抢同一把锁。当前调用点全在 UI/MainActor（MetadataSyncBar/ExportView/CollectionView/Settings），无实际竞争。 | grep 全部 `DisplayDateFormatters.shared.fileSize` 调用点；Linux 微基准；持锁一致性本身是修复目标。 | 无必须动作；如担心可给 fileSize 单独锁或注明「仅 MainActor 调用」。 | 高 | Partly（Darwin 上 ByteCountFormatter 成本不同） |

> 说明：R2A-01/02/03 未修复前 app target 不可编译，因此本轮所有「app 修复已验证」的结论都是
> **代码语义 + Linux 逻辑等价性**层面的验证，不代表可构建。R2A-01/02 的工作区修复我已复核
> （DateFormatting 真实 `-typecheck` EXIT 0；pageAssignmentCount 访问级别改正），但仍需提交 + macOS 构建确认。

## 2. 修复验证（round-1 → 6e940350，逐项）

> 方法：`git show 6e940350` 逐 hunk 读；读修复后真实上下文；对可移植逻辑原样拷入 Linux 探针
> （.gather/r2app2/）对拍/锤测；门禁复跑。每条都给出「我做了什么」而非只给结论。

### 2.1 DateFormatting：持锁格式化 + mediumShort 环境键（round-1 A4/A5，R3-T03/R5-03）

- **编译**（P0-1）：HEAD 版 4 errors；工作区修复版 `-typecheck` EXIT 0。见 §0/§1。
- **字节等价（核心 claim: 输出与旧"每次新建 formatter"逐字节一致）**：把修复后 `DateFormatting.swift`
  原样拷入探针编译，oracle = 旧调用点「每次新建同配置 formatter」。
  矩阵：11 locales（en_US/en_GB/zh_CN/zh-Hans/de_DE/fr_FR/ar_EG/th_TH/ja_JP/ru_RU/es_ES）× 8 dates
  × {mediumShort, shortShort, 6 个 pattern, 4 个 localizedTemplate, fileSize(16 values),
  internetDateTime/internetDateTimeWithFractionalSeconds(11 inputs), internetDateTimeString,
  parseFixedUTC/formatFixedUTC(3 formats), parseISO8601Date}；
  **15 组环境（TZ ∈ {Asia/Shanghai, America/New_York, Europe/Berlin, UTC, Pacific/Kiritimati}
  × LC_ALL ∈ {en_US.UTF-8, de_DE.UTF-8, th_TH.UTF-8}）共 1153 checks × 15 = 17,295 次比较，0 mismatch**。
- **mediumShort 环境键**：`environmentKey("mediumShort", locale:)` = base|locale|Calendar.current.identifier|
  TimeZone.current.identifier（:196-198），修复前只有 locale。语义上覆盖旧"每次新建取调用时环境"。
  **限制**：Linux corelibs 的 `TimeZone.current` 在进程内不响应 `setenv(TZ)`+`tzset()`（探针实测
  TZ0/TZ1/TZ2 输出不变），因此无法在 Linux 动态证明"运行中改时区会换新 formatter"；这属 macOS 行为，
  与旧实现一致性由键结构保证（新增 formatter 与旧 per-call formatter 同配置）。
- **线程安全/死锁**：`withFormatter` 持 `lock` 执行 body；全类方法面的互调关系：`make`/`body` 只
  构造/调用 `DateFormatter.string(from:)`，`fileSize`/ISO 解析/`fixedUTCFormatter` 的嵌套调用**都在
  同一把锁内但无回调本类**（`fixedUTCFormatter` 注释即"调用方已持锁"）⇒ NSLock 非重入不会死锁。
  16 线程 × 4000 次混合 9 个方法的锤测：**0 失败、无死锁/超时**（timeout 120s）。
- **代价**：单线程 `mediumShort` 新实现 1874.7 ns/次 vs 模拟旧缓存版 1452.6 ns/次（差 ~0.4µs，
  含 environmentKey 的 3 次 Foundation 环境查询），vs 每次新建 formatter 24533 ns/次 ⇒ 缓存收益 ~13×；
  持锁串行只影响跨线程调用，UI 路径全在 MainActor。**可接受**。
- **其余输出语义**：`fileSize` 16 个边界值（0/负/Int64.max/min/1e9…）与
  `ByteCountFormatter.string(fromByteCount:countStyle:.file)` 一致；ISO 解析坏输入 nil 语义一致；
  `parseFixedUTC/formatFixedUTC` 与旧 en_US_POSIX+UTC+固定 pattern 一致。
- **既有 macOS oracle 测试**：`Tests/GatherAppTests/DisplayDateFormattersTests.swift`（708a6b89 新增）
  覆盖 mediumShort/pattern/localizedTemplate/shortShort/ISO 解析（未覆盖 fileSize/fixedUTC/持锁），
  断言逻辑我逐行复核成立；`#expect(formatters.internetDateTime(fractionalISO) == nil)` 的前提
  （Darwin 上 `.withInternetDateTime` 不接受小数秒）与 Linux corelibs 行为一致（探针验证），符合
  Foundation 公开语义。

### 2.2 Observation 依赖（round-1 A1，R5-01）

- 代码：`navigationGroupSizeByPhotoID` 命中路径顶部 `_ = navigationGroups.count`；
  `similarGroupAssets` 命中路径顶部 `_ = page?.assets.count`。
- 探针（.gather/r2app2/obs/main.swift，**-O 编译**，用真实 `Observation.withObservationTracking`）：
  - 修复前形态（命中路径不读底层属性）：缓存预热后再 tracking 读 → 变更 navigationGroups **不触发**（复现 A1）；
  - 修复后形态：**触发**；similarGroupAssets 同型：修复后触发、修复前不触发；反向无误报。
  ⇒ 「读没有被优化掉」（-O 下 getter 的 observation access 有副作用，不可消除）、依赖确实登记。
- 消费点核对：CullingGrid body 经 `groupSizes[asset.photo.id]` 读（CullingGrid.swift:320,341）；
  `navigationGroups` 是 `public internal(set) var` + didSet bump version（CullingViewModel.swift:316-318）；
  两个 cache/version 均 @ObservationIgnored ⇒ 该读是唯一依赖来源，修复必要且充分。
- 注：该函数所在文件目前受 **P0-3** 影响不可编译，不能用 macOS 端到端验证。

### 2.3 Lightbox 身份校验（round-1 A2）

- 代码：命中后三重校验 `indexByID[currentID]` 在界内 **且 `photos[index].id == currentID`**，否则回退线性。
- 逻辑探针对拍旧「逐帧 firstIndex」语义：空数组→nil、currentID nil→nil、stale 映射下标身份不符→回退正确、
  id 消失→nil、重排/换位→正确；与旧实现唯一的理论差异只在「重复 id」数据（R2A-07），且显示内容仍同 id。
- `.task(id: currentID)` 的 `prefetchAdjacent` 使用 resolvedCurrentIndex ⇒ 修复后预取邻居也正确。

### 2.4 GalleryLayoutCache rowIndex（round-1 A0，CI 红修复）

- 代码：map 命中即 O(1)；未命中回退 `rows.firstIndex{...}`（旧语义）。
- 既有测试场景探针：新建缓存 → nil；直接写 rows 后 → 0/0/1/nil **全部与测试断言一致**（A0 红改绿的机制成立）。
- 热路径：500 行×40 项 map 命中 **16.9 ns/lookup**，O(1) 保持。
- 生产写点 grep：只有 store/reset，回退分支只在测试/首帧空缓存走；残余不变量见 R2A-05。

### 2.5 preload 过期守卫（R5-06）

- 代码：`plannedAssignment = pageAssignmentCount` / `plannedCurrentPhotoID = currentPhotoId` 在
  `computePreloadMisses` await **之前**捕获；await 回来比较后决定是否继续消费 misses/发宿主信号。
- 逻辑探针：未变→继续；页赋值代数变→放弃；当前照片变→放弃（真变化保护有效）。
- 副作用：同内容 page 替换（决策回显）也放弃 ⇒ R2A-04（P3，false negative，可改用 plan 等值比较）。
- 编译受 P0-2 影响（HEAD 不可编译；工作区已修访问级别）。

### 2.6 其余修复

- **packedSize clamp（A10）**：`min(max(1,w), Int(UInt32.max))` 后打包。探针：0/负值与旧实现一致；
  常规尺寸新旧一致；`[1, UInt32.max]²` 上单射；>UInt32.max 被 clamp 与 2^32−1 同键（理论碰撞，实拍尺寸不可达，
  clamp 口径与 layout 的 `max(1,·)` 一致）；旧实现 w 与 w+2^32 高位截断碰撞（对照）。
  残余：>4.29e9 px 仍非单射（P3 记录，实际不可达）。
- **loadedPhotoLookup 复用 id 集合（A11）**：`loadedPhotosAndIDs()` 与 loadedPhotoLookup 同 pagesGeneration；
  ids 集合内容与原「photos 循环重建」等价（同一 flatCache.ids），仅省一次集合；`let (photos, loadedIDs)` 解构合法。
- **prune 顺序（A6）**：`guard isEnabled else { return }` 在消费 `didStartupPrune` 之前；生产唯一调用点
  AppBootstrap:277-280 先 `isEnabled = true` 再调用；无测试依赖旧顺序（grep 无引用）⇒ 修复正确。
- **page.didSet 关键词索引（A14）**：didSet 内清 `keywordTargetIndexCache`（CullingViewModel.swift:51）；
  该属性 internal（:70）跨文件可见、同一文件 didSet 可写；缓存只被关键词面板读取、且原 key 含 pageVersion，
  清空无性能副作用（面板外的 body 不读）。
- **R3-T04 测试窗口**：`ReviewFixTests` 两处先 `#expect(await waitUntilAsync(0.5){waiterStarted.isSet})`
  再做 0.08/0.04s 负向窗口；`ReviewFixFlag`/`waitUntilAsync` 均存在（同文件 private class / 共享 helper），
  @MainActor suite 隔离正确。严格说「Task 已启动」仍不等于「已进入闸门排队」，但窗口从"可能没跑"改善为
  "必已跑过 set 之后"；残余为 P3 级测试脆弱性（未发现新红）。

## 3. Verified OK（本轮我独立复核过的点，含第一轮 claim 的抽查）

1. **6e940350 app 侧全部 8 个文件 hunk 逐行读**：CullingGrid packedSize、+Navigation 依赖读、+Preload 守卫、
   CullingViewModel didSet+similarGroupAssets、GalleryGrid rowIndex、+Derived lookup、Lightbox 身份、
   DateFormatting、ThumbnailDiskCache、ReviewFixTests。除 3 个 P0 外未发现其它编译级/语义级错误。
2. **app 全量语法**：463/463 Swift（Sources+Tests）`-parse` EXIT 0（当前工作区快照）。
3. **app 相关门禁 10 道全 PASS**（check-perf-ratchet / cleanup-ratchet / design-system / layering /
   domain-events / domain-writes / no-legacy / select-star / coded-errors / preview-surface）⇒
   修复提交未破坏 ratchet/设计/分层门禁（注意：门禁全为静态 grep/脚本，不能证明可编译）。
4. **round-1 的 A1/A0/A2/A4/A5/A6/A10/A11/A14/R5-06 修复**：见 §2，全部成立/无回归。
5. **round-1 文档中与 app 相关的结论抽查**：字体/颜色 token 迁移（GatherFont.secondary == .callout、
   `GatherTheme.secondaryContentBackground` 就是 `surfaceMuted` 的别名 ⇒ fill 迁移逐字等价，GatherTheme.swift:110-111）；
   Localizable/en 文案 key/占位符属 ui-copy/R3 域，本轮未重跑。
6. **第一轮 A0 的 CI 红判断**：机制成立（既有测试直接写 rows，新实现若只读 map 会 nil），修复后该测试按
   断言逐条通过（探针复现）。
7. **LayoutBudgetTests/CullingKeywordViewModelTests/GalleryViewModelTests 等测试 diff**：只看到 flaky sleep→
   条件等待与注释补充，未发现断言弱化（详情属 R3 测试域，本轮只做 app 交互相关抽查）。

## 4. 第一轮残余项的复评（fresh eyes）

- **A3（NSCache cost/淘汰悬崖）→ 降级 P3（R2A-08）**：round-1 的「300dpi 相机 JPEG ⇒ cost 17×」前提在当前
  数据路径不成立——缓存里所有 NSImage 都来自 App 自己编码的预览 JPEG（无 DPI 属性），点=像素 ⇒ 新旧 cost 相同。
  真正需要关注的是**既有** 512MB 预算在 2560/8192 档下只能容 ~24/~2 张，建议 macOS 实测后调预算或分桶，不是本 diff 的回归。
- **A8（启动计时）→ 维持 P3 文档口径（R2A-10）**：并行安全静态复核成立；sum 的重复计入只有重叠窗口的
  languageSeed 时长，日志已注明并行。
- **A9（filmstrip 重复 id）→ 维持 P3（R2A-12）**；**A12（游标 O(k)）→ 维持 P3（R2A-11）**。
- **第一轮未发现的新类型风险 = 编译级错误**：本轮通过「纯 Foundation 文件真实 typecheck + 访问级别跨文件
  启发式扫描」找到 3 个 P0；建议后续每轮把这两类检查固化（见 R2A-01 修复建议）。

## 5. Coverage & Limitations

**已覆盖**
- 6e940350 app diff 100% 逐行；origin/main..HEAD 中 app 高危/大改动文件（DateFormatting、CullingViewModel 系列、
  CullingGrid、GalleryGrid/+Derived/+Content/Lightbox、AppBootstrap、ThumbnailDiskCache、PhotoThumbnailView、
  CullingInspector、PersonsView、Similarity/Duplicates/Metadata/Export/C1Status call-site 迁移、设计令牌迁移）
  逐一读改动后上下文；changed-call-site API 一致性 grep（knownGroupCount/plan/seedPhotoIds/filteredCache/flatCache 等）。
- Linux 探针：DateFormatting 输出对拍 17,295 组 + 并发锤测 + 成本；Observation 依赖（-O）；
  GalleryLayoutCache（测试场景 + 300 组随机对拍 + 微基准）；Lightbox 身份矩阵；packedSize 单射/clamp；
  preload 守卫场景矩阵；两文件 private 访问规则。
- 门禁 10 道 + 全量 -parse + 可移植文件真实 typecheck。
- 跨文件 private 成员访问启发式扫描（diff 新增 35 个 private 成员名 + 新增行成员访问 vs 全仓 private 声明）。

**未覆盖/上限（必须保留）**
1. **无 macOS**：未 `swift build/test/check-warnings`，未运行 App。P0-1 的修复版与 P0-2 的访问级别修复
   仍需 macOS 构建确认；SwiftUI/严格并发/actor 隔离的诊断未知（例如 Darwin 专属 Sendable 差异）。
2. **SwiftUI 运行时**：body 失效时序（A1/A2 的触发窗口）、@Observable + didSet 的真实刷新顺序、ForEach diff、
   NSCache 淘汰/内存峰值、NSImage DPI 行为都需 macOS；本轮只用同源 Observation 实现（open-source Swift 6.2）做结构证据。
3. **Apple Foundation 与 corelibs 差异**：日期/字节格式逐字节一致性在 Linux 上闭环，但在 Darwin 上仍需
   `DisplayDateFormattersTests` 真实跑；时区/日历运行时变更的缓存跟随（mediumShort 环境键）在 Linux 无法动态复现。
4. **无法端到端运行 app 测试**：除 R2A-09 指出的覆盖缺口外，未推演其它既有测试与新实现的交互（属 R3 域）。
5. 性能数字均为 Linux 微基准/结构证据（µs/ns 级），不代表 Darwin。

## 6. 修复优先级（供 lead）

0. **P0-1/P0-2/P0-3 必修（阻塞 everything）**：P0-1/P0-2 工作区已有修复（建议按 private(set) 收口 P0-2）；
   **P0-3（navigationGroupsVersion → private(set)/internal）当前尚未修**。建议把三处一起提交，并在下一次
   macOS CI 首跑时确认。
1. 把「可 typecheck 的纯 Foundation app 文件」加入本地检查（至少 DateFormatting/JSONValueDecoding/
   其它无 SwiftUI import 的文件），把「跨文件 private 成员访问」做成轻量脚本检查（本次启发式脚本可复用）。
2. P3 批量收：R2A-04（preload plan 等值守卫）、R2A-05（rows 只读化）、R2A-06（gap 入键）、R2A-09（补 2–3 个纯逻辑测试）。
3. macOS 实测项：NSCache 预算/淘汰（R2A-08）、启动计时口径（R2A-10）、DateFormatting 输出 oracle 测试。

## 7. 附：本轮证据清单（可复跑）

- 类型检查：`swiftc -typecheck -swift-version 6 <HEAD-blob DateFormatting.swift>` → 4 errors（77/108/120/132）；
  工作区版 → EXIT 0。
- private 跨文件规则探针：.gather/r2app2/a.swift + b.swift → `'count' is inaccessible due to 'private' protection level`。
- DateFormatting 等价：.gather/r2app2/dfprobe/{DateFormatting.swift,main.swift} → 15 环境 0 mismatch。
- 并发锤测：.gather/r2app2/dfprobe3 → 16×4000 混合调用 failures=0。
- Observation：.gather/r2app2/obs/main.swift（-O）→ 4 项断言全 OK（含修复前形态不触发）。
- 布局/Lightbox/packedSize/preload：.gather/r2app2/logic/main.swift → 全部 OK，rowIndex 16.9ns/次。
- 语法：463/463 app Swift 文件 -parse EXIT 0。
- 门禁：check-perf-ratchet / cleanup-ratchet / design-system / layering / domain-events / domain-writes /
  no-legacy / select-star / coded-errors / preview-surface 全 EXIT 0。
