# Cut 6 前置只读审计（2026-10-22）

> 任务：Cut 6「清扫与防腐」开工前的只读审计。**本文件是唯一写入物**；未改源码/测试/Package/资源/脚本。
> 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`（HEAD `82603e0`，工作区含 Cut 1–5 未提交改动）。
> 依据：`docs/cleanup-backlog.md`（CL-02/12/16/18/19/20）、`docs/test-audit.md`、`scripts/check-cleanup-ratchet.sh`、
> `docs/cleanup-baseline.json`、`docs/refactor-progress.md`、`docs/refactor-decisions.md`、全仓 grep。
> 标记：**【已确认】**= 有命令/源码证据；**【疑似】**= 静态推断，需人工确认。
> 更正（2026-10-22 最终清理）：`RequestGate` 在本审计时已是零生产调用点（1 份定义是 4a-0 遗留），随后随 CL-04 删除；§1.2 / §4.2 的“1 份”已按事实更正为 0。

---

## 0. 结论先行（计划漂移 + 本轮实测）

| 项 | 任务书/旧文档口径 | 本轮实测 | 判定 |
| --- | --- | --- | --- |
| CL-02 待删 | 1,797 行 | **0 行**：`Migrations.swift`(1,628) + `MigrationTests`(169) 已于 Cut 2 删除/改写 | **plan drift，CL-02 已 done** |
| 未引用 lproj key | 62 个 | **64 个**（en 1,407 键；Sources 全文字面量比对） | +2 drift |
| `@unchecked Sendable` | backlog 写 39，baseline 53 | **53**（Sources，ratchet 口径） | backlog 数字过期 |
| `try?` | backlog 写 320，baseline 242 | **236**（已低于 baseline 6） | backlog 数字过期 |
| 测试 | core 1092/157、app 580/66 | **core 1092/157 exit 0；app 580/66 exit 0**（本轮实跑） | 一致 |
| ratchet | — | **53 / 236 / 126 / 0 / 0**，OK（baseline 53/242/126/0/0） | 全部 ≤ baseline |
| schema | — | **43 表 / 373 列 / 69 索引 / 62 FK / user_version=1** | 与 SchemaV1 头注释一致 |
| 门禁 | — | 8 个门禁全 PASS（含 `--strict`） | 见 §7 |

**本轮可删面（低风险）**：64 行 lproj（63 en + 1 zh）+ 约 57 行死代码 = **约 121 行**；
另有 172 行外部进程测试（`ReviewAcceptanceTests`/`DeepModelAcceptanceTests`）可选重写，不计入必删。
**不删只改**：172 个文件头注释的旧路径、80 处测试 helper 旧名、6 处 ImageCache 注释。

---

## 1. CL-02 / CL-12 / CL-16 / CL-18 / CL-19 / CL-20 现状与动作

### 1.1 CL-02 迁移链 / 旧 Schema / 快照 —— 【已确认】done，0 行待删

| 对象 | 计划 | 实测 | 是否仍被引用 |
| --- | --- | --- | --- |
| `Database/Migrations.swift` | 删 1,628 行 | HEAD 实测 1,628 行，文件已不存在 | 代码 0（仅 4 处注释） |
| `Database/MigrationTests.swift` | 删 169 行 | 现 **91 行**（fresh-only 重写，−78） | 是：fresh 建库门禁本体，保留 |
| `SchemaV1Transition.swift` | 删（backlog 未计） | 121 行，从未进 HEAD，已删 | 0 |
| `Schema.swift` | 649 行 → 14 | 现 **19 行**（`currentSchemaVersion=1` + 活跃 job SQL 字面量） | 是：`AnalysisJobRepo` + `check-docs` 两处 |
| `docs/fixtures/schema.snapshot.json` | 删/归档 | **仍在**，49 行，`schemaVersion: 35` 且含 legacy 表（`metadata_outbox`/`writeback_items`/`asset_file_metadata`/`schema_version`） | 仅 docs（ADR:85/623、ROADMAP:112），无代码/门禁 → **建议 6b 移入 `docs/archive/`** |

合计已删 `1,628 + 169 = 1,797`（backlog 口径），另加 `121 + 630`（Transition/Schema 收缩）实际更多。
**残余动作**（6b）：`docs/fixtures/schema.snapshot.json` → `docs/archive/schema.snapshot-v35.json`，并在 ADR-006 注明"历史快照，schema 1 以 SchemaV1.swift 为准"。
引用核对：`SchemaV1Transition|MigrationRunner` 在 Sources = 0；Tests 中 87 处是注释/历史断言 + `makeMigratedDB` 旧名（见 §3.4）。

### 1.2 CL-12 测试 helper 重复 —— 【已确认】基本 done，仅剩改名

| 符号 | 现状 | 结论 |
| --- | --- | --- |
| `LockedBox` | **1 份**：`gather-app/Tests/GatherAppTests/Support/LockedBox.swift:18` | done |
| `AsyncGate` | **2 份**（每包 1）：`gather-app/.../Support/AsyncGate.swift:11`、`gather-core/Tests/GatherTestSupport/AsyncGate.swift:16` | done（跨包不能共享） |
| `ResponseBox` | 0（随 `CommandSurfaceRuntimeTests` 删除） | done |
| `JobEventSink` | 1 份 private，`GlobalInfraTests.swift:128`（仅本文件 2 处使用） | 保留（单文件私有，不必上移） |

`check-duplicate-symbols.sh --strict`：**PASS**（`batchAsync` 1、Support 外 0；`RequestGate` 规则已于 2026-10-22 最终清理随 CL-04 移除，不再计入）。
**残余动作**（6a）：无删除；建议在 backlog 直接把 CL-12 标 done，并把 `JobEventSink` 记为"允许单文件私有"。

### 1.3 CL-16 历史文档 / ADR 漂移 —— 【已确认】ADR 已修，README/DEVELOPMENT/ROADMAP 仍漂

- ADR 已修：`docs/ADR.md:13` "当前 schema 1"，`:78` "43 表 / 373 列 / 69 索引"，`check-docs --strict` PASS。
- 残留漂移（逐项见 §5）：根 `README.md` 仍写 Router/GatherCore/迁移/outbox；`docs/DEVELOPMENT.md` 目录树、
  本地化、门禁、测试台账全部停留在 Cut 0 前；`docs/ROADMAP.md:84/85/112` 数字与路径过期；`docs/README.md` 措辞。
- 归档：`docs/reviews/` 22 篇 + `assets/`（14 图 + 3 子目录），`docs/archive/` 只有 README（自述"尚未搬迁"）。

### 1.4 CL-18 吞错 / 弱类型 —— 【已确认】数字见 §1 表；53 处 unchecked 中 25 处缺就近依据

- `try?` 236 行 / 82 文件；Top：`ExportService.swift` 22、`JobService.swift` 21、`ModelInstaller.swift` 13、
  `FaceKwService.swift` 10、`MetadataService.swift` 10、`CullingService.swift` 8、`ThumbnailDiskCache.swift` 8。
- `@unchecked Sendable` 53 行；Top：`JobService` 6、`CaptureOneBridge` 4、`MetadataService` 3、`EmbeddingModel` 2。
  以声明行 ±4 行检索"锁/lock/不可变"注释：**28 处有、25 处无**；但抽查 `LiveSessionAPI.swift:30` 的依据注释在
  声明下方 6–8 行（`init` 上方），说明 ±4 会误判。**建议 6a 用 ±12 行重扫后只补注释，不批量改语义**。
- **动作**：不把 `try?` 改 `throw`（会改 UI 错误路径，风险高）；只把 ratchet baseline 从 242 收紧到 236，
  并把 53 处 unchecked 的依据注释纳入 `check-cleanup-ratchet` 的"注释就近"检查（新增 warning 指标，不 hard fail）。

### 1.5 CL-19 旧回归测试 —— 【已确认】1,302 行 / 60 例，外部进程 4 例仍在

| 文件 | 行 | `@Test` | 判定 |
| --- | ---: | ---: | --- |
| `gather-app/Tests/GatherAppTests/ReviewFixTests.swift` | 994 | 45 | 保留（F/B 系列 bug 代码仍在），合并 defer |
| `gather-app/.../ReviewAcceptanceTests.swift` | 135 | 6 | **重写**：`:27 /usr/bin/awk`、`:39 /bin/sh`、`:60-61 /usr/bin/zip` |
| `gather-app/.../DeepModelAcceptanceTests.swift` | 37 | 1 | **重写/删**：`:24 /usr/bin/zip` |
| `gather-core/.../ReviewAcceptanceTests.swift` | 83 | 5 | 保留（D14 已从 8 条裁到 5 条） |
| `gather-core/.../DeepReviewAcceptanceTests.swift` | 53 | 3 | 保留（原 160 行 → 53，D14 已裁） |

合计 1,302 行 / 60 例。可删面：两个 app acceptance 文件 172 行（重写为预置 zip 夹具或标 manual）；
`ReviewFixTests` 45 例中约 9 例是同一行为的不同输入（test-audit M11），**6a 不合并**（收益低、易丢断言）。

### 1.6 CL-20 未用资源 / 调试开关 —— 【已确认】en 1,407 / 孤儿 64 / `#if DEBUG` 17 处（16 行有效）

- en 1,407 键（`wc -l` 1,486 行含 47 个 section 注释 + 空行）；zh-Hans 仅 10 键（最小表）。
- **64 个键未被任何 Swift 源引用**（方法：unescape `\"` 后对 372 个 Sources 文件做整键子串比对）；
  其中 2 个在 Tests 出现：`检测模型路径`（`:83`，被 `SettingsSaveSemanticsTests:284` 断言英文
  `"Detection Model Path"`）、`返回工作台`（`:439`，仅出现在 `ReviewFixTests:708` 的断言消息里）。
- `#if DEBUG` grep **17 处** = 16 行非注释守卫（11 个页面 `#Preview` + 5 个 `PreviewSupport` 整文件守卫）+ 1 行注释；
  不存在 DEBUG-only 路由；`#Preview` 14 块（`check-preview-surface --strict` PASS）。
- 处置：**删 63 键、保留 1 键**（`检测模型路径`）；zh 表删 1 个孤儿（`未找到可用的人脸身份模型`）；
  给 `LocalizationParityTests` 补"孤儿键 ⊆ allowlist"断言（allowlist 只放 `检测模型路径`）；
  把 `#if DEBUG` 非注释行数（16）作为 ratchet 的 warning 指标。

---

## 2. 64 个未引用 key 逐条判定

> 口径：en.lproj 键集合（1,407）− Sources 全文字面量（含 `Text("...")`、`LocalizedText`、`SettingField.zhLabel` 等动态 key）。
> 全部 64 个 **不在任何 `#Preview` 中**（Preview 也在 Sources，若引用必命中）；"动态"列指 key 由运行时对象传入
> （`SettingField.zhLabel`、三元分支、拼接），只有 `检测模型路径` 属于此类（由测试构造）。
> zh 列：zh-Hans 表只有 10 键，除 `:1462` 外均无 zh 条目（zh 命中 key 本身，回退中文）。

| # | en 行 | key | en 值 | 动态/预览 | zh | 判定 |
| ---: | ---: | --- | --- | --- | --- | --- |
| 1 | 8 | `yyyy年M月d日 HH:mm` | yyyy/M/d HH:mm | 否/否 | — | 删（`PersonsView.swift:495` 已改为 `dateFormat="yyyy年M月d日"`） |
| 2 | 17 | `重叠人脸的过滤阈值` | Filter threshold for overlapping faces | 否/否 | — | 删（NMS 设置已移除） |
| 3 | 21 | `推理并行线程数` | Parallel inference threads | 否/否 | — | 删（ONNX 设置已移除） |
| 4 | 78 | `原生宿主配置、推理后端和模型状态` | Native host configuration, inference backend, and model status | 否/否 | — | 删 |
| 5 | 83 | `检测模型路径` | Detection Model Path | **是**/否 | — | **保留（allowlist）**：`SettingsSaveSemanticsTests:284` 断言 en 文案 |
| 6 | 84 | `编码模型路径` | Encoding Model Path | 否/否 | — | 删 |
| 7 | 95 | `模型文件未找到。请将 ONNX 模型文件放入以下文件夹：` | Model files not found. Put the ONNX model files in the following folder: | 否/否 | — | 删（ONNX 已删） |
| 8 | 156 | `已重试同步队列，但同步状态读取失败` | Sync queue retried, but reading sync status failed | 否/否 | — | 删（现行文案是 `已重试同步队列`） |
| 9 | 157 | `已刷新同步队列，但同步状态读取失败` | Sync queue refreshed, but reading sync status failed | 否/否 | — | 删（同上） |
| 10 | 199 | `挑片工具` | Culling Tools | 否/否 | — | 删（页面标题已改） |
| 11 | 311 | `后台任务可在任务中心查看、取消或重试。` | Background tasks can be viewed, canceled, or retried in the Task Center. | 否/否 | — | 删 |
| 12 | 319 | `存在失败或冲突的写入项，请先处理后再继续` | Some writes failed or conflicted; handle them before continuing | 否/否 | — | 删（`LocalizationParityTests:245` 钉的是另一句） |
| 13 | 320 | `正在等待 Capture One 确认写入…` | Waiting for Capture One to confirm the write… | 否/否 | — | 删（C1 话术已换） |
| 14 | 323 | `暂无工作区任务` | No Workspace Tasks | 否/否 | — | 删 |
| 15 | 348 | `请先完成上一步` | Complete the previous step first | 否/否 | — | 删 |
| 16 | 357 | `人脸推理当前使用系统内置引擎，建议前往设置确认模型状态。` | Face inference currently uses the system built-in engine; check the model status in Settings. | 否/否 | — | 删（SFace 落地后不再有"内置引擎需确认"） |
| 17 | 373 | `选择目标簇后合并当前簇到目标簇` | Select a target cluster to merge the current cluster into it | 否/否 | — | 删 |
| 18 | 387 | `没有失败项` | No Failed Items | 否/否 | — | 删 |
| 19 | 400 | `先切页再开 sheet` | Switch pages before opening the sheet | 否/否 | — | 删（审查备注误入 strings） |
| 20 | 405 | `任一 item hover 全部文字降透明` | Hovering any item dims all text | 否/否 | — | 删（同上） |
| 21 | 434 | `CoreML（失败自动回退 CPU）` | CoreML (Falls Back to CPU on Failure) | 否/否 | — | 删（旧推理后端选项） |
| 22 | 439 | `返回工作台` | Back to Workbench | 否/否 | — | 删（仅断言消息出现） |
| 23 | 458 | `返回图库` | Back to Library | 否/否 | — | 删 |
| 24 | 489 | `加载元数据失败` | Failed to load metadata | 否/否 | — | 删 |
| 25 | 504 | `全部在线状态` | All Online Statuses | 否/否 | — | 删（筛选器已无该档） |
| 26 | 507 | `全部存储卷` | All Volumes | 否/否 | — | 删 |
| 27 | 508 | `全部重复状态` | All Duplicate Statuses | 否/否 | — | 删 |
| 28 | 511 | `全部导入时间` | All Import Times | 否/否 | — | 删 |
| 29 | 515 | `收起更多筛选` | Collapse More Filters | 否/否 | — | 删 |
| 30 | 563 | `收起历史` | Collapse History | 否/否 | — | 删 |
| 31 | 575 | `选择文件夹后自动生成` | Generated automatically after choosing the folder | 否/否 | — | 删（现行是 `选择文件夹后名称会自动生成，也可以先手动输入。`） |
| 32 | 576 | `留空则使用照片所在文件夹名称` | Leave empty to use the folder containing the photos | 否/否 | — | 删 |
| 33 | 616 | `状态色全变 accent` | Status colors switch to accent | 否/否 | — | 删（审查备注误入） |
| 34 | 634 | `加载中...` | Loading… | 否/否 | — | 删（现行全部用 `加载中…`，三处） |
| 35 | 670 | `批量导出` | Batch Export | 否/否 | — | 删 |
| 36 | 671 | `未选择导出目录` | No export directory selected | 否/否 | — | 删 |
| 37 | 684 | `命名模式（{date}/{time}/{counter}/{original}/{session}）` | Naming Pattern ({date}/{time}/{counter}/{original}/{session}) | 否/否 | — | 删（`ExportView+Options.swift:71` 只用占位符列表） |
| 38 | 696 | `导出目录（不要选择导入目录）` | Export Directory (Do Not Choose the Import Directory) | 否/否 | — | 删 |
| 39 | 715 | `点击「开始扫描」按钮检测重复照片` | Click “Start Scan” to detect duplicate photos | 否/否 | — | 删 |
| 40 | 718 | `· 保留最佳` | · Keep Best | 否/否 | — | 删（现行 `保留最佳`，无前缀） |
| 41 | 719 | `· 保留全部` | · Keep All | 否/否 | — | 删（同上） |
| 42 | 725 | `人脸推理当前使用系统内置引擎` | Face inference currently uses the system built-in engine | 否/否 | — | 删 |
| 43 | 737 | `%@（%lld 张）` | %@ (%lld photos) | 否/否 | — | 删（整句已改） |
| 44 | 762 | `XMP 写入失败：%@` | XMP write failed: %@ | 否/否 | — | 删（错误码路径接管） |
| 45 | 770 | `仅显示角色「%@」的簇` | Show only clusters with the role “%@” | 否/否 | — | 删 |
| 46 | 777 | `分析结果：%@，检测失败 %lld 张，编码失败 %lld 个人脸` | Analysis results: %@, %lld photos failed detection, %lld faces failed encoding | 否/否 | — | 删 |
| 47 | 779 | `前往「%@」步骤` | Go to the “%@” step | 否/否 | — | 删 |
| 48 | 794 | `展开 %lld 项` | Expand %lld items | 否/否 | — | 删 |
| 49 | 796 | `工作区 %@` | Workspace %@ | 否/否 | — | 删 |
| 50 | 797 | `工作区 %@ · 按统一格式、命名规则导出照片及元数据` | Workspace %@ · export photos and metadata with unified formats and naming rules | 否/否 | — | 删（`ExportView.swift:142` 只用后半句） |
| 51 | 827 | `清理失败：%@` | Cleanup failed: %@ | 否/否 | — | 删 |
| 52 | 829 | `清除「%@」筛选` | Clear the “%@” filter | 否/否 | — | 删 |
| 53 | 833 | `确认失败：%@` | Failed to confirm: %@ | 否/否 | — | 删 |
| 54 | 850 | `重试失败：%@` | Failed to retry: %@ | 否/否 | — | 删 |
| 55 | 854 | `预览失败：%@` | Preview failed: %@ | 否/否 | — | 删 |
| 56 | 859 | `%lld%% 滚轮缩放 · 拖动平移 · 双击复位 · ⌘+/⌘− 缩放` | %lld%% scroll to zoom · drag to pan · double-click to reset · ⌘+/⌘− to zoom | 否/否 | — | 删 |
| 57 | 890 | `调整侧栏宽度` | Resize Sidebar | 否/否 | — | 删 |
| 58 | 892 | `双尺度检测 %lld×%lld + %lld×%lld，分析预览最长边 %lldpx，编码输入 %lld×%lld，特征维度 %lld` | Dual-scale detection … | 否/否 | — | 删（旧 ONNX 模型卡） |
| 59 | 1163 | `%@（请展开失败项查看原因）` | %@ (expand the failed items to see why) | 否/否 | — | 删 |
| 60 | 1216 | 长句：`留空 = 内置 Vision 特征…`（见附录 A） | Empty = built-in Vision feature print … | 否/否 | — | 删（SFace 设置已换文案） |
| 61 | 1222 | 长句：`开=只对新增照片做增量聚类…`（见附录 A） | On = only new photos are clustered incrementally … | 否/否 | — | 删（现行设置描述不同） |
| 62 | 1240 | `人脸库不可用` | People library unavailable | 否/否 | — | 删 |
| 63 | 1331 | `请确认应用的数据目录可访问。` | Make sure the app’s data directory is accessible. | 否/否 | — | 删 |
| 64 | 1462 | `未找到可用的人脸身份模型` | No usable face identity model was found | 否/否 | **有** | 删（zh 同步删；现行文案 `人脸模型不可用，请前往设置…`） |

**删除清单**：63 个 en 键（除 `检测模型路径`）+ 1 个 zh 键（`:7`） = **64 行**。
**保留 allowlist**：`检测模型路径`（1 个，测试钉住英文值；6a 在 parity 测试里显式 allowlist）。
**section 注释**：47 个 section 无一会因删键变空；但 `:432 /* Sources/GatherApp/Host/SessionCommandRouter.swift */`
是已删文件的旧路径，6a 改为 `/* GatherAppDelegate.swift（菜单） */`（该段剩 `最近同步`）。

**附录 A：两个超长 key 原文**
- 行 1216：`留空 = 内置 Vision 特征（通用图像特征）；填入 ArcFace/SFace 等 .mlmodel 或 .mlmodelc 即切换为专用人脸模型（需 112×112 图像输入）。填了但加载失败会直接报错，不会退回内置特征——两套向量空间混用会让相似度阈值失去意义`
- 行 1222：`开=只对新增照片做增量聚类，已有簇与用户绑定身份不会被重算冲掉；关=每次分析都全量重聚类（慢，但会收敛到全局最优）`

---

## 3. 旧名残留（逐项 file:line）

### 3.1 ImageCache（6 处，全是注释）

| 文件:行 | 内容 | 动作 |
| --- | --- | --- |
| `GatherPersistence/Database/FileHasher.swift:12` | "回退纯 Swift SHA256（Database/ImageCache.swift）" | 改 `SHA256.swift` |
| `GatherDomain/Services/DuplicateService.swift:18` | "SHA256（FIPS 180-4 纯 Swift 实现，ImageCache.swift）" | 改 `SHA256.swift` |
| `GatherDomain/Services/NavigationService.swift:21` | "→ GatherCore SHA256（ImageCache.swift 纯…）" | 改 `SHA256.swift` + 去 `GatherCore` |
| `GatherDomain/Services/MetadataFingerprint.swift:5` | "→ SHA256（…，ImageCache.swift）" | 改 `SHA256.swift` |
| `GatherPersistence/Database/SHA256.swift:11/13` | "原 ImageCache 磁盘缩略图缓存…" / "由 `ImageCache.swift` 更名…" | 保留（历史说明，正是改名记录） |

### 3.2 Migrations / Router / 118 / command surface

| 类别 | Sources/Tests | scripts/CI | docs |
| --- | --- | --- | --- |
| `Migrations`/`MigrationRunner`/`SchemaV1Transition` | 4 处注释：`AppComposition.swift:24`、`Database.swift:11`、`PersonRepo.swift:26`、`SchemaV1.swift:39`；Tests 87 处（79 个 `makeMigratedDB()` 调用 + 注释） | `check-docs.sh:12` 注释 | 98 处（多为历史记录） |
| `SessionCommandRouter` / `CommandRouter` / `NativeCommandClient` / `WebResponse` | **0 代码**；`check-no-legacy.sh:78-80` 的 enforced 规则名 | `.github/workflows/ci.yml:25` 注释 | 根 `README.md:84`（**仍写成当前架构**）、`docs/README.md:31`、ADR:336/586 |
| `118` 命令 | 0 | — | `README.md`、`docs/README.md`、DEVELOPMENT:242/246、ROADMAP:85/139（均带"历史"语境，可保留） |
| `check-command-surface` | 0（脚本已删） | `ci.yml:25` 注释 | `DEVELOPMENT.md:230` 注释、ADR:586 |

**代码侧旧名 = 0**（`check-no-legacy` 7 条 enforced 全 0）。**唯一会误导读者的是根 `README.md`**（见 §5）。
**建议改名**：`makeMigratedDB()` → `makeTestDB()`（1 定义 `GatherTestSupport/DatabaseTestSupport.swift:26` + 79 调用 + 注释），
纯机械替换；不做则每次读代码都要先解释"migrated 其实没有迁移"。

### 3.3 HNSW / ClusterEngine / 旧聚类

| 文件:行 | 内容 | 动作 |
| --- | --- | --- |
| `GatherAnalysis/Face/VectorIndex.swift:4` | "HNSW（CosineHnswIndex 471 行 + HnswConfig/HnswHits + …）" | 保留（删除记录） |
| `GatherCoreBenchmarks/main.swift:5` | "HNSW 基准已删" | 保留 |
| `Tests/.../VectorIndexReconciliationTests.swift:10-13` | "HNSW 已删除…fixture 的 hnsw 段暂时保留" | **更新**：fixture 的 hnsw 段已于 5d-1 删除，此句过期 |
| `GatherAnalysis/Similarity/ClusterGraph.swift:4/12/45/77/892` | "原 ClusterEngine…" 5 处 | 保留（迁移记录） |
| `Tests/.../ClusterGraphTests.swift:4`、`IncrementalClustererTests.swift:3`、`SimilarityIncrementalServiceTests.swift:434` | "旧 ClusterEngine" | 保留 |
| `IncrementalClusterer` | **仍是活代码**（`SimilarityService.swift:1101/1107`），不是残留 | 不要当旧名删 |

代码引用：`CosineHnswIndex|HnswConfig|HnswHits|benchHnsw` = 0；`ClusteringImpact` = 0（全仓）。

### 3.4 其它旧名 / 旧路径

| 项 | 数量 | 证据 | 动作 |
| --- | ---: | --- | --- |
| 文件头旧路径注释 | **172 文件** | 首行仍写 `Sources/GatherCore/...` / `Sources/GatherApp/...` / `gather-app/<Feature>/...` | 6a 机械改为当前路径（净 0 行，churn 172） |
| `GatherCore` 伞名 | Sources 0 引用（layering 17 条 OK）；注释里仍有 `GatherCore SHA256` 等 | §3.1/3.2 | 随手改 |
| `metadata_outbox` / `writeback_items` | 仅 `MigrationTests.swift:38` 的 negative 断言（有意） | 其余 68 处是注释 | 保留 negative 断言 |
| `schema.snapshot.json` | 49 行，schemaVersion 35 + legacy 表 | 无门禁引用 | 归档（§1.1） |
| `release/Gather.app` 旧 bundle | 含旧 `SessionCommandRouter` 注释的 lproj | `release/` 已 gitignore | 无需处理（构建产物） |

---

## 4. 死代码 / 重复符号 / 未用 public

### 4.1 `find-unused-symbols.swift` 实测（537 文件，4,296 public 声明 / 2,377 unique）

12 个零引用候选 + 1 个 scanner 漏报，人工复核后 **12 个符号可删/降级，2 个必须保留**：

| 符号 | 位置 | 判定 | 理由 |
| --- | --- | --- | --- |
| `FaceInferenceError` | `GatherAnalysis/Face/Inference.swift:43` | **删（3 行）** | 全仓仅声明；`analyzeBatch` 用 `CancellationError` |
| `SessionStore.activeWorkspace` | `GatherUI/Support/SessionStore.swift:41` | **删（4 行）** | 0 引用；`workspace(for:)` 是唯一入口 |
| `SessionWorkspace.updateSessionName` | `SessionWorkspace.swift:94` | **删（5 行）** | 0 引用（标题走 `loadSessionNameIfNeeded`） |
| `SessionWorkspace.noteStale` | `SessionWorkspace.swift:133` | **删（4 行）** | 0 调用方；`staleDomains` 永远为空 |
| `SessionWorkspace.consumeStaleDomains` | `SessionWorkspace.swift:140` | **删（6 行）** | 同上，`setVisible(true)` 未接补刷 |
| `staleDomains` 属性 | `SessionWorkspace.swift:46` | **删（1 行）** | 只被上面两个死方法 + `close()` 清空 |
| `PersonsViewModel.deselect` | `PersonsViewModel.swift:108` | **删（5 行）** | 0 引用（`selected=nil` 由选择路径写） |
| `ImageDecoderPort.isInstalled` | `ImageDecoderPort.swift:88` | **删（6 行）** | 0 引用 |
| `ImportPathRules.isInstalled` | `ImportPathRules.swift:47` | **删（6 行）** | **scanner 漏报**（与上者同名，计数被抵掉）；0 引用 |
| `GatherTheme.shadowSm` | `GatherTheme.swift:60` | **删（1 行）** | 0 引用（`shadowMd` 在用） |
| `Radius.lg` | `GatherTheme.swift:73` | **删（1 行）** | 0 引用（`sm/md` 在用） |
| `L10n.Language.resourceName` | `L10n.swift:127` | **删（4 行）** | 0 引用；bundle 查找用硬编码 `"zh-hans"/"en"` |
| `applicationShouldTerminate` | `GatherAppDelegate.swift:557` | **保留** | NSApplicationDelegate 回调，AppKit 调用 |
| `applicationSupportsSecureRestorableState` | `GatherAppDelegate.swift:320` | **保留** | 同上 |

合计删除约 **57 行 / 12 个符号**（含 `staleDomains` 属性与 4 段文档注释）。验收：`find-unused-symbols.swift` 候选降到 2（仅 AppKit）。

### 4.2 duplicate gate 结果

`check-duplicate-symbols.sh --strict`：PASS。
- `func batchAsync`：1 份（`GatherAnalysis/Concurrent/BatchRunner.swift:50`，允许保留）；
- `LockedBox/ResponseBox` 在 Tests/Support 之外：0；
- `RequestGate`：0 份（2026-10-22 随 CL-04 整文件删除；脚本规则已在最终清理中移除，不再作为门禁证据）。

**gate 覆盖不到的真实重复**（本轮人工发现，6a 不动、记入 6c 报告）：
1. `PhotoThumbnailView.swift` 内 **3 份缩略图加载器**：`load(for:)` 在 `:222`（PhotoThumbnailView）、
   `:415`（FaceCropThumbnailView）、`:696`（RegionThumbnailView），各自一套 `@State` + `.task(id:)` + cache key。
   CL-07 原记 2 份，Cut 4 拆 View 后变 3 份。合并需 `ThumbnailLoader`，风险高于 6a 预算 → defer 到 6c 后。
2. `GatherLocalization.errorText`（`:251`）与 `L10n.errorText`（`:252`）：两实现共用 `errorMessages` 表，
   `LocalizationParityTests` 逐条对拍——**有意保留**（旧出口 + 新值出口），不当重复删。
3. `L10n.Language.resourceName` 与 `localizedBundle(named:)` 硬编码：删前者即可（见 4.1）。

### 4.3 其它"可删但本轮不建议删"

- `AppLanguageLock`（tests support）：Cut 4 已去全局锁，但 parity 测试仍用它切语言；删需重写 3 处测试 → 保留。
- `makeMigratedDB()`：只改名不删（见 §3.2）。
- `VectorIndexReconciliationTests` 的 HNSW 注释段：只改注释。
- `#Preview` 14 块：#if DEBUG 共 16 行有效守卫（11 个 `#Preview` + 5 个 PreviewSupport 文件）承载，保留。

---

## 5. docs 归档与当前口径核对

### 5.1 归档计划（6b）

`docs/reviews/` 22 篇 + `assets/`（14 图 + 3 子目录）。建议 **保留 4 篇在 docs/reviews/**，其余 **18 篇** 移入
`docs/archive/reviews/`（新建目录 + `README.md` 索引，原路径留一行 redirect 说明）：

| 保留（当前仍被引用/仍是权威） | 理由 | 入链 |
| --- | --- | ---: |
| `refactor-design-breaking-2026-10-21.md` | 权威计划，11 处引用 | 11 |
| `architecture-review-2026-10-21.md` | 本轮审计仍引用其行号台账 | 2 |
| `face-clustering-benchmark.md` | `ADR.md:601` 与 cut5 审计引用 | 3 |
| `functional-design-review.md` | DEVELOPMENT 引用（Swift 6 迁移记录） | 2 |

| 归档（18 篇） | 理由 | 入链 |
| --- | --- | ---: |
| `refactor-design-2026-10-21.md` | 已被 breaking 版取代（cut4-ui-audit 引用需改指向） | 1 |
| `native-refactor-report.md` | Cut 0 前的重构历史 | 3 |
| `full-review-2026-09-30.md`、`full-review-2026-09-30-acceptance.md`、`deep-review-2026-09-30-fixes.md` | 9 月验收/修复快照 | 1/1/1 |
| `perf-audit-2026-09-30.md` | 性能审计快照 | 1 |
| `ui-review-2026-09-29-fixes.md`、`-round2-fixes.md`、`-round3-audit.md`、`ui-review-2026-09-30-fixes.md` | UI 修复轮全部完成 | 4 |
| `visual-design-review.md`、`-detail-native-views.md`、`-macos-design-reference.md` | 视觉评审快照 | 4 |
| `ux-review.md`、`window-layout-research.md`、`layout-restructure.md` | UX/布局研究快照 | 2/1/2 |
| `face-identity-replacement-2026-10-03.md` | ADR-030 前置研究 | 1 |
| `liquid-glass-macos-26-27-adoption.md` | macOS 26/27 调研，非当前目标 | 4 |

**Cut 1/3/5 完成物**（`docs/archive/cuts/`，10 篇）：`cut1-execution-brief.md`、`cut1-completion-report.md`、
`b8-router-removal-map.md`、`module-split-map.md`、`module-split-map-v2.md`、`schema-v1-draft.md`、
`schema-v1-risk-audit.md`、`cut4-ui-audit.md`、`cut5-algorithm-audit.md`、`api-migration-map.md`。
**留在 docs/**：README/DEVELOPMENT/ROADMAP/ADR、`refactor-progress.md`、`refactor-decisions.md`、`cleanup-backlog.md`、
`test-audit.md`（已带历史横幅）、本文件、`cut6-completion-report.md`。
**风险**：`check-docs` 只校验 ADR 反引号路径，不校验 md 链接；6b 需自带一个 `grep -o '](.*\.md)'` 存在性检查。
**入链总数**：22 篇中 18 篇有入链，共约 30 处需改（含 ADR/ROADMAP/DEVELOPMENT/backlog/test-audit）。

> **6b 实测（2026-10-22）**：实际归档 18 篇 reviews → `docs/archive/reviews/`（`assets/` 随迁，
> 图片相对链接保持可用），10 篇 Cut 文档 → `docs/archive/cuts/`；`docs/reviews/` 留 4 篇 + README。
> **不建 18 个 redirect stub**（否则 `docs/reviews` 仍是 22 篇）；旧→新路径统一记在
> `docs/archive/README.md`，全仓 md 入链按新路径重写，自建 md 链接检查 **0 缺失**。
> 机械项实测：`makeMigratedDB` **80 处**（1 定义 + 79 调用、40 文件）→ `makeTestDB`；
> 文件头旧 target 路径 **171 个**（计划 172，漂移 -1）；ImageCache 注释 4、Migrations 注释 4、
> HNSW 段 1；`docs/fixtures/schema.snapshot.json` → `docs/archive/schema.snapshot-v35.json`。

### 5.2 README / DEVELOPMENT / ROADMAP / ADR 口径核对

| 文件:行 | 当前写法 | 实际 | 动作 |
| --- | --- | --- | --- |
| 根 `README.md:33` | "SwiftUI pages call `GatherCore` services" | 伞 target 已删，7 target | 改为"调用 16 个域 API" |
| 根 `README.md:55` | Swift 5.9+ | tools 6.0 / Swift 6 语言模式 | 改 6.0 |
| 根 `README.md:84-88` | `SwiftUI → SessionCommandRouter → GatherCore services`；SQLite 迁移 | Router 已删；无迁移（V1 一次成型 + 重置） | **整段重写** |
| 根 `README.md:92` | "metadata outbox rows support retries" | 已被 deliveries 取代 | 改 deliveries |
| 根 `README.md:96` | "command-surface contract" | 脚本已删 | 删 |
| `docs/README.md:26-28` | "→ `GatherCore` 领域服务：SQLite（WAL + 迁移）" | 无 GatherCore target；V1 无迁移 | 改"GatherProtocol/…/GatherDomain" |
| `docs/README.md:59` | "元数据 outbox 支持重试" | deliveries | 改 |
| `docs/DEVELOPMENT.md:36-38` | 目录树 `Sources/GatherCore/{...}`、`Sources/GatherApp`、`gather-app/Culling/` | 现为 `Sources/GatherProtocol`、`GatherPersistence`、`GatherAnalysis`、`GatherDomain` 与 `GatherApp`、`GatherUI`、`GatherHost` | 重画目录树（唯一真相源） |
| `DEVELOPMENT.md:80-84` | 架构图 `GatherCore 服务 / MetadataOutbox` | 同上 | 重写 |
| `DEVELOPMENT.md:89-93` | RootView 常驻页 + `.id("session-tab-…")` 守卫 | 壳 148 行、7 文件；无该 `.id` | 改 |
| `DEVELOPMENT.md:99` | "迁移由 `GatherCore/Database/Migrations.swift` 管理" | 文件已删 | 改 `Database.open(at:)` + 重置策略 |
| `DEVELOPMENT.md:121-132` | `GatherLocalization.l(key)`（:222）、en 1,203 行、173 错误码、`appLanguage` 全局 + RootView 重建 | 现 L10n 值 + 1,407 键 + 177 码 + 无全局重建 | 重写本地化节 |
| `DEVELOPMENT.md:196` | 台账 core 951/134、app 224/27（2026-09-28） | 1,092/157、580/66 | 更新 |
| `DEVELOPMENT.md:230` | 门禁只列 5 个 | 现 8 个（+test-catalog/select-star/preview-surface） | 更新 |
| `DEVELOPMENT.md:244/282/324` | `GatherCore/API/*API.swift`、`GatherCoreTests/Protocol/*ContractTests` | 现 `GatherProtocol/API/`、`Tests/GatherCoreTests/Protocol/`（存在，但路径前缀不同） | 改 |
| `ROADMAP.md:84` | core 795/112、app 173/20 | 1,092/157、580/66 | 更新 |
| `ROADMAP.md:85` | `gather-core/Sources/GatherCore/API/` | `GatherProtocol/API/` | 改 |
| `ROADMAP.md:92` | `MetadataSyncCoordinator` 为写回可靠性 | 已删 → DeliveryCoordinator | 改 |
| `ROADMAP.md:95` | 173 项错误码 | 177 | 改 |
| `ROADMAP.md:112` | 与 `schema.snapshot.json` 43 表全对（schema 34）；`@BT@` 转义残留 | snapshot 为历史；当前 schema 1 | 改：`SchemaV1` + 43 表 + user_version=1 |
| `ADR.md:22-26` | 映射表仍指 `GatherCore/Database/ImageCache.swift`、`GatherCore/Services/CaptureOneSyncState.swift` | 路径已不存在（行内标"已删除"，check-docs 跳过） | 改成 `GatherPersistence/GatherDomain` 现有路径，保留"已删除"说明 |
| `ADR.md:594/621-623` | ADR-029 标题"（schema 34）"、快照同步为 34 | 历史 ADR，保留 | 加"历史"前缀即可 |

---

## 6. 测试现状

| 指标 | 实测 |
| --- | --- |
| core | **1,092 tests / 157 suites，exit 0**（`swift test --package-path gather-core`，3.5s 测试段） |
| app | **580 tests / 66 suites，exit 0**（`--no-parallel`，12.75s） |
| 合计 | 1,672 tests / 223 suites |
| 测试文件 | 163（core 98 + app 65） |
| skip | **3 条**，全部 `.enabled(if: fixtureImageData != nil)`：`FaceRealPhotoPipelineTests.swift:40/62/74`，缺 `GATHER_FACE_FIXTURE` → 实跑输出 "skipped" ×3 |
| `.disabled` / `withKnownIssue` | 0 / 0 |
| `check-test-catalog.sh --strict` | **PASS**（163 文件、缺头注释 0、无"到期"说明 0、禁用 0） |
| 外部进程 | 4 例：`ReviewAcceptanceTests.swift:27/39/60-61`（awk/sh/zip）、`DeepModelAcceptanceTests.swift:24`（zip） |
| 最大套件 | Culling 84 例/2,523 行；FaceKeywording 55/1,890；ReviewFix 45/994；Indexer 35/1,297；Job 32/964 |

**滚动账**（Cut 0 994/141 + 298/32 → 1,092/157 + 580/66）：core +98 例/+16 suite，app +282 例/+34 suite；
新增主要是状态层/本地化/API 契约/算法（5b/5c +44、5d-2 0），删除 23 例（ClusteringImpact 9、parity 12、HNSW 2）。
**可删测试**：只建议重写/删两个外部进程 acceptance 文件（172 行 / 7 例），其余**保留**（bug 代码仍在）。
**不建议**按 test-audit §3.5 压到 761/253：当前 1,092/580 的增量都是替代断言，不是冗余。

---

## 7. 最终验收清单（Cut 6 收口时逐条打勾）

### 7.1 机器项（必须 exit 0，数字写进报告）

| # | 命令 | 期望 |
| ---: | --- | --- |
| 1 | `swift build --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch` | exit 0（本轮已实测 0.55s 增量） |
| 2 | 同上 `gather-app`（+ `CLANG_MODULE_CACHE_PATH`） | exit 0（本轮已实测） |
| 3 | `swift test` core / app（同 flags；app 加 `--no-parallel`） | 1,092/157 与 580/66，0 failed |
| 4 | `./scripts/check-cleanup-ratchet.sh` | 53/236/126/0/0（baseline 53/242/126/0/0；6c 把 try? 收紧到 236） |
| 5 | `./scripts/check-test-catalog.sh --strict` | PASS |
| 6 | `./scripts/check-docs.sh --strict` | PASS（归档后 ADR 路径 0 缺失） |
| 7 | `./scripts/check-no-legacy.sh` | 7 enforced 0；tracked 6 项 |
| 8 | `./scripts/check-layering.sh` | 17 条 OK |
| 9 | `./scripts/check-duplicate-symbols.sh --strict` | PASS |
| 10 | `./scripts/check-select-star.sh` | Sources 6 / Tests 1 |
| 11 | `./scripts/check-preview-surface.sh --strict` | 14 preview / 5 files / 2,045 行 |
| 12 | `swift scripts/find-unused-symbols.swift` | 候选 ≤2（仅 AppKit delegate） |

### 7.2 bundle（CI / 人工，本机未跑）

- `./desktop/native/build.sh`（默认 release）→ `release/Gather.app`；**本机受 sandbox 限制不跑**（历史 `sandbox_apply: Operation not permitted`），由 CI 的 `gather-app tests + bundle` job（`.github/workflows/ci.yml:71-89`）验证。
- build.sh 自带硬断言（不可绕过）：`gather-core_GatherAnalysis.bundle`/`gather-app_GatherUI.bundle` 存在
  （`:58-68`）、`FaceModels` 目录存在（`:72-75`）、`en.lproj`/`zh-Hans.lproj` 在 UI bundle 中（`:85-87`）、
  主 bundle 收到两份 lproj 拷贝（`:99-108`）。
- 报告需记：bundle 大小、`ls release/Gather.app/Contents/Resources | grep -E 'bundle|lproj'` 输出、codesign 状态（未签名）。

### 7.3 GUI smoke（人工，不可自动化；不得用测试绿灯替代）

1. 启动/导航：新建工作区 → 导入（含中文/空格路径）→ 索引进度 → 切页/切 session 不串数据；
2. 挑片：保留/淘汰、星级/色标、撤销/重做、写回同步、失败重试；
3. 相似度/重复：分析启动/取消、阈值改后状态一致、重复组处理有确认；
4. 人脸：分析/簇审核/绑定/合并/重聚类，失败可诊断；
5. 导出/任务：进度、取消、重试、目标不覆盖源资产；
6. 设置：切中/英后**逐页检查是否出现中文回退或空白**（删键后的关键 A/B）；模型路径保存/恢复默认；
7. 菜单/侧栏/窗口标题；`Cmd+Q` 优雅停机（delivery replay 后再关库）。
- 记录格式：页面 × 步骤 × 结果（pass/fail/未测），fail 附截图与日志；**未测不得写 pass**。

### 7.4 指标表（Cut 6 冻结）

| 指标 | 当前值 | 口径 |
| --- | ---: | --- |
| Swift 文件 | **535**（core S 147 / T 98；app S 225 / T 65）+ 2 `Package.swift` | `find ... -name '*.swift'`，排除 `.build` |
| 总行数 | **133,569**（42,329 + 33,223 + 37,824 + 20,193）+ 253 | `cat` 逐文件累加 |
| schema | **43 表 / 373 列 / 69 索引 / 62 FK / user_version 1** | SchemaV1.swift DDL 计数 |
| public 声明 | 4,296（unique 2,377） | find-unused-symbols |
| 测试 | **1,092/157 + 580/66 = 1,672/223** | 实跑 |
| skip | 3（`.enabled(if:)`） | `grep enabled(if:` |
| ratchet | **53 / 236 / 126 / 0 / 0** | check-cleanup-ratchet |
| Services `prepare(` | 126（baseline 126） | ratchet |
| lproj | en **1,407** / zh **10**；孤儿 **64** | 脚本比对 |
| `#Preview` / `#if DEBUG` | 14 块 / 16 行非注释（grep 17 含 1 行注释） | 门禁 / ratchet 口径 |
| docs | 42 个 md / 18,609 行；reviews 22 篇 + assets 14 图/3 目录 | find/wc |
| docs/archive | 仅 1 个 README（归档尚未开始） | find |

---

## 8. 分步计划 6a / 6b / 6c

### 6a 死代码 / 注释 / keys（低风险，先做）

**动作**
1. lproj：删 63 en 键（保留 `检测模型路径`）+ 1 zh 键；改 `:432` 的 section 注释；`LocalizationParityTests` 加
   "en 键 − 在用 key ⊆ allowlist" 断言（allowlist = `检测模型路径`），失败打印前 10 个。
2. 删 12 个死符号（§4.1，约 57 行）：每删一个跑一次 `swift build`；`SessionWorkspace` 的 5 个成员（属性 + 4 方法）一并删。
3. 注释旧名：ImageCache 4 处、`VectorIndexReconciliationTests:10-13`、`Migrations/Schema` 4 处；
   172 个文件头路径机械替换为当前路径；`makeMigratedDB` → `makeTestDB`（79 处调用 + 1 定义）。
4. ratchet：baseline 的 `try_optional` 242 → 236；新增 warning 指标 `#if DEBUG`=16（非注释，暂不 hard fail）。

**验收**：core 1,092/157、app 580/66 全绿；ratchet 53/236/126/0/0；`grep -rn 'ImageCache|GatherCore/Database|GatherApp/Host' Sources` = 0；
`grep -c '检测模型路径' en.lproj` = 1；`find-unused-symbols` 候选 2。
**风险**：删键 A/B（手工）；改 172 个头注释会与并行分支冲突（建议单独一次提交/一次性脚本）；`makeTestDB` 改名触及 40+ 个测试文件。
**回滚**：本步不删除任何文件，只删行/改注释，`git diff` 可逐文件回退。

### 6b docs 归档 / 指标

**动作**
1. 建 `docs/archive/reviews/`（18 篇 + README 索引）与 `docs/archive/cuts/`（10 篇）；原路径留 redirect 行。
2. 更新 30 处入链（ADR 1、ROADMAP 5、DEVELOPMENT 2、backlog 6、test-audit 6、cut5 2、其它）。
3. 重写根 README 架构/数据模型段、DEVELOPMENT 目录树+本地化+测试台账+门禁清单、ROADMAP §3.1 数字与 `:112`、
   docs/README 措辞、ADR 映射表路径；修正 `@BT@` 转义残留。
4. cleanup-backlog：CL-02/12 标 done、CL-18/20 数字改实测、CL-19 记"保留 60 例、重写 7 例"。
5. `schema.snapshot.json` → `docs/archive/schema.snapshot-v35.json`。

**验收**：`check-docs --strict` PASS；自建链接检查（`grep -o '](.*\.md)'` 全部可解析）0 缺失；
`grep -rn 'SessionCommandRouter|Migrations.swift|metadata outbox' README.md docs/README.md docs/DEVELOPMENT.md` = 0（除"历史"行）。
**风险**：归档 28 篇后 30 处链接易漏（无门禁）；历史文档行号语义丢失（README 索引里写清"行号为当时快照"）。
**回滚**：移动即 `git mv`（未提交），可按索引回搬。

### 6c 最终全量 / 报告

**动作**
1. 全量 build/test（§7.1 的 1–3）+ 8 门禁 strict + preview strict + find-unused；
2. CI 跑 `build.sh`，记录 bundle 大小/lproj/FaceModels/签名；
3. 人工 GUI smoke（§7.3）并记录；
4. 写 `docs/cut6-completion-report.md`：目标/结果/删除行数/文件数/符号数/指标表/未做项；
5. ratchet 冻结（53/236/126/0/0），把 `#if DEBUG` 与"孤儿 key=0 + allowlist"纳入 CI。

**验收**：§7.1 全 0；report 与本文件 §7.4 逐项一致；CL-12/16/18/19/20 全部有状态（done 或 blocked+原因）。
**风险**：收紧 baseline 后并行改动回升会红（需同 PR 更新）；GUI 未验收不得写"通过"；bundle 本机不可跑，只能引 CI 证据。

---

## 9. 复现命令（只读）

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
# 规模
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print | wc -l
for d in gather-core/Sources gather-core/Tests gather-app/Sources gather-app/Tests; do
  find desktop/native/$d -name '*.swift' | wc -l; find desktop/native/$d -name '*.swift' -exec cat {} + | wc -l
done
# schema
grep -c 'CREATE TABLE' desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaV1.swift
grep -c 'CREATE INDEX\|CREATE UNIQUE INDEX' desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaV1.swift
grep -c 'REFERENCES' desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaV1.swift
# 测试
cd desktop/native && swift test --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --package-path gather-app --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
# 门禁
cd .. && ./scripts/check-cleanup-ratchet.sh && ./scripts/check-test-catalog.sh --strict && ./scripts/check-docs.sh --strict
./scripts/check-no-legacy.sh && ./scripts/check-layering.sh && ./scripts/check-duplicate-symbols.sh --strict
./scripts/check-select-star.sh && ./scripts/check-preview-surface.sh --strict
# 未用 public
swift scripts/find-unused-symbols.swift
# lproj 孤儿（示意：整键在 Sources 中不存在；需先 unescape \"）
grep -c '^"' desktop/native/gather-app/Sources/GatherUI/Resources/en.lproj/Localizable.strings
```

---

## 10. 残余风险 / 未做

1. **未做人工 GUI smoke**（无 GUI 自动化）：§7.3 全部为待人工；不得声称视觉/交互通过。
2. **bundle 未在本机构建**：build.sh 受 sandbox 限制（历史 `sandbox_apply` 失败），只能由 CI 验证。
3. **`@unchecked Sendable` 依据注释**：25 处"±4 行无注释"里含 `Live*API` 的"下方 6–8 行有注释"误判；6a 用 ±12 行复核后只补注释。
4. **64 键删除**是静态证据（全 Sources 整键比对）；未对真实 en 界面逐页点检。6a 后仍需 §7.3-6 的 A/B。
5. **CL-19 合并**未执行：ReviewFixTests 45 例中的 9 个重叠用例保留，避免丢 F/B 回归。
6. **计划漂移**：CL-02（1,797→0）、CL-20（62→64）、CL-18（39/320→53/236）、ADR 表（35/44→1/43）、
   errorMessage VM 6→7、BFS 4→5 等，均按实测记入本文件，不照抄旧账。
