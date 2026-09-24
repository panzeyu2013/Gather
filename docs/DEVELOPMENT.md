# Gather 开发与贡献指南

Gather 是 macOS 14+ 的 Swift/SwiftUI 原生桌面应用。业务能力位于
`desktop/native/gather-core`，界面与应用生命周期位于 `desktop/native/gather-app`；
仓库不依赖 Node.js、Electron、浏览器渲染层或本地 HTTP 服务。

本文档合并原 `TEST.md`（测试清单）与 `IPC_CONTRACT.md`（IPC 契约基线）的精华；
测试与契约细节以本节为准，两份旧文档已删除。

## 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools
- Swift 5.9 或更高版本
- Capture One 仅在需要验证原生插件/导入联动时才需要

真实人脸推理质量、代码签名/公证/安装升级和商业信号不属于代码验收范围。

## 目录结构

```text
desktop/native/
├── gather-core/       # Protocol / Store / Runtime / Jobs / Metadata / API / Support + 算法内核
│   └── Sources/GatherCore/{Protocol,Store,Runtime,Jobs,Metadata,API,Support,Face,Image,Similarity,Logging}
├── gather-app/        # SwiftUI 壳层与页面、菜单、组合根（无第二命令层）
│   ├── Sources/GatherApp/   # App(组合根)/ Shell / Dashboard / Library / Gallery / Similarity / Persons / Host / Support
│   ├── Culling/ FaceKeywording/ ControlCenter/ Settings/ Export/ Duplicates/
│   └── Resources/     # en.lproj / zh-Hans.lproj 本地化表
docs/                  # 总览、开发指南、ADR、路线图
```

## 本地开发

### 核心库测试

```bash
cd desktop/native/gather-core
swift test
```

### 应用测试

应用测试包含 SwiftUI 页面模型、原生路由、命令处理和服务接线。macOS 上如遇
Clang 模块缓存权限问题，指定工作区可写的缓存目录：

```bash
cd desktop/native/gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test
```

### 构建应用

```bash
./desktop/native/build.sh
```

产物为 `release/Gather.app`（`OUTPUT_DIR` 可覆盖）。脚本会构建 gather-core、
GatherApp，并在存在 Capture One 插件源码时尝试构建插件。默认产物保持未签名；
`CODESIGN_IDENTITY` 存在时才执行签名，签名、公证和安装包是独立的发布流程。

## 架构约定

```text
SwiftUI（Features：View + ViewModel）
  ↓ 只依赖类型化命令面（无命令名、无 JSON 桥、无同步入口）
GatherAPI / CommandSurface（19 域 · 111 方法，async-only）
  ↓
GatherCore Runtime（actor：Culling / Similarity / Duplicate / Quality / Indexer /
Export / FaceKeywording / Navigation / Session / Jobs / Metadata …）
  ↓ 只经 Store 协议
Store（唯一 SQL 所有者：SQLiteDatabase actor + 迁移注册表 + 每聚合一个 Store）
  ├── SQLite（WAL + 备份/回滚，见 ADR-005）
  ├── 图片读取、Vision 和 RAW 解码（Domain/Image/Face 算法内核）
  └── JobRunner（可恢复任务：executor + checkpoint + dedupeKey + 租约 fencing）
```

**架构规则（门禁脚本强制，回归即失败）：**

1. `Services/` 目录不存在；`Store/` 之外不得出现裸 SQL（CI 扫描）；
2. 命令面只有 async：不存在同步执行入口、信号量桥接或命令名分发表；
3. 参数与结果一律 `Protocol/` DTO（Codable），UI 层不出现命令级 JSON；
4. 有可变状态者一律 `actor`；`@unchecked Sendable` 归零（enforced）；
5. DDL 只在 Store 的 schema 单源；迁移步骤只做数据变换；
6. 错误各有领域类型（`description` 即错误码），UI 经 `GatherErrorText` 单点映射；
7. 并发原语唯一：`ConcurrentMap.run`（值返回、取消传播、保序）。

### 页面与壳层

- `AppShellView`（`Sources/GatherApp/Shell/`）是根视图：左侧特性列表 +
  右侧按 Feature 渲染；`ShellCoordinator` 承担菜单/通知/窗口标题/拖放/语言版本
  与会话级 ViewModel 构造。
- 会话级页面经 `SessionShellView` 承载 5 个工作区页签（控制中心/人脸/重复/挑片/
  导出），导航状态由 `AppNavigationState` 注入；session 切换用
  `.id("session-shell-\(sessionId)-\(tab)")` 守卫强制重建。
- Jobs、Settings、Face Keywording、Duplicates、Culling、Export 和 Control Center
  均由 SwiftUI 原生页面承载；每个 Feature 的 ViewModel 独立文件、`@MainActor`
  `@Observable`、只依赖命令面或数据提供者协议（可注入替身）。

### 数据与任务

- SQLite 使用 WAL；迁移由 `Store/StoreMigrator.swift`（33 步注册表）统一管理，
  含磁盘空间检查、SQLite backup API 备份与失败恢复（见 ADR-005）；DDL 单源在
  `Store/StoreSchema.swift`，结构漂移由 `StoreSchemaTests` 门禁。
- 导入创建 session、写入照片资产后，立即提交 `metadata.scan` 任务；任务中心负责
  进度、失败显示、重试和取消。
- 元数据写回经过 outbox，支持失败重试、冲突处理和重启后恢复。
- 文件操作必须使用数据库中已授权的资产路径；删除、移动和覆盖类操作需要显式确认。
- 重复资产按逻辑资产处理，避免 RAW/JPEG 配对造成重复分析或重复写回。

### 原生边界

- 应用不包含 WKWebView、JavaScriptCore、React、TypeScript IPC 或 Electron 主进程。
- UI 只经 `CommandSurface` 的领域协议调用能力；不存在命令名字符串与命令级 JSON，
  未知能力在编译期即不可表达（R5 出口）。
- UI 不直接持有数据库连接或执行任意文件路径操作，Runtime/Store 负责授权和事务边界。

## 本地化体系

界面文案统一经 `Support/GatherLocalization.swift` 的本地化层，禁止硬编码裸码直显。

### 入口与回退语义

- `GatherLocalization.l(key)`（`GatherLocalization.swift:180-186`）：**key 即中文
  文案**；按 `appLanguage` 查 `Bundle.module` 中的 `.lproj` 表——`zh-Hans.lproj`
  表为空（占位），未命中自动回退 key（即中文）；`en.lproj`（925 行）提供英文
  翻译，未翻译的 key 仍回退中文。所有文案调用点写中文 key，无需两处登记。
- 错误码翻译：`errorText(_:)` 覆盖 156 项 `GatherErrorCode` → 中文文案
  （`errorMessages` 表，`GatherLocalization.swift:10-170`）；未知码回退通用文案。
- 任务侧映射：`jobStatusText` / `jobTypeText` / `progressPhaseText` 分别覆盖
  `jobs.status.*` / `jobs.type.*` / `progress.*` 相位键。
- 通用出口：`GatherErrorText.message(for:)`（`Support/GatherErrorText.swift`）
  是 UI 展示错误的唯一出口：Swift 领域错误的 `description` 即错误码 → 翻译为
  文案（未知码回退通用文案）；显式 NSError 诊断消息原样保留；
  `jobErrorMessage` 只翻译错误码，非错误码回退通用文案（原始细节留给 tooltip）。
- 语言状态：`appLanguage`（zh-CN/en）、`setAppLanguage(_:)`、`appLocale`
  （格式化跟随语言）；设置页 `settings.set_language` → `languageChanged` 通知 →
  `RootView` 重建外壳文案并 `GatherAppDelegate` 重建菜单。

### 新增文案规范

1. 页面文案一律调用 `GatherLocalization.l("中文文案")`，需要英文时同步补
   `en.lproj/Localizable.strings`（key 为同一中文串）。
2. 错误必须先以错误码形式从服务层抛出（`GatherCore` 错误枚举），UI 层经
   `errorText`/`message(for:)` 映射，不直接展示 rawValue。
3. 参数插值用 `String(format: GatherLocalization.l(...), ...)`，占位符语义与
   en 表保持一致。
4. 界面语言选项名（中文 / English）为固定品牌名，两语言文件同值，不本地化。

## HIG 规范约定

### 语义字体

- 页面层级使用系统语义字号：`.largeTitle`（页头）、`.title3.weight(.semibold)`
  （区块标题）、`.headline` / `.callout` / `.caption`（正文与辅助信息），
  不散落字号字面量；数值展示用 `tabular-nums` 保持对齐。

### 按钮层级

- 侧栏/工具栏导航按钮：`.buttonStyle(.plain)` + 自定义 hover/选中态
  （见 `RootView.swift:510-549`），选中项加 `.accessibilityAddTraits(.isSelected)`。
- 主操作：系统 `Button` 经根视图 `.tint(GatherTheme.primary)` 统一着色，保持
  控件原生形态。
- 破坏性操作：`role: .destructive` + `confirmationDialog` 双确认（如重置挑片、
  清理备份）；高频确认（写回/组决策/完成同步）由命令层 `confirmed` 门控承担，
  不再弹窗（对齐旧版零弹窗语义）。
- 弹层统一使用系统 sheet/confirmationDialog，不复刻自绘 Dialog（Electron 时代
  的 APG 焦点管理 ADR-018 由系统组件天然覆盖）。

### 无障碍

- 常驻隐藏页 `.accessibilityHidden(!isVisible)`，避免隐藏控件被 Tab/VoiceOver
  触达（RootView 五个常驻页均有）。
- 图标按钮与语义化控件补 `.accessibilityLabel`；动画跟随
  `@Environment(\.accessibilityReduceMotion)` 降级（`.transition`/`.animation`
  判断 reduceMotion）。

### 主题令牌

- 颜色/圆角/间距统一取 `Support/GatherTheme.swift`（primary `#A54D2A`、背景
  `#F5F0EB`、语义色、`Radius`/`Spacing` 阶梯，含明暗动态适配），禁止内联色值
  字面量；卡片统一用 `gatherCard()` 修饰符。

## 测试与验收

### 自动化门禁

提交前在仓库根目录至少运行：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-core

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-app

./desktop/native/build.sh
```

验收记录至少包含：gather-core 测试总数/套件数/失败数、gather-app 同名指标、
`.app` 组装结果、fixture-dependent skip 与未执行的外部验收项。
（最近一次台账：gather-core 1200 / 153 suites（串行；按当前约定跳过 2 个高计算
similarity 套件）、gather-app 181 / 18 suites（串行），R5/R8 收口轮。）
提交前同时运行 `./scripts/check-no-legacy.sh`（24 条 enforced 规则、0 tracked 度量）。

验收时要区分：

- 测试/编译/应用组装成功：证明代码链路可构建和可执行；
- 真实照片、人脸推理质量、签名公证安装和商业材料性能：明确排除，不能用自动化
  绿灯替代这些外部证据；
- 如果测试输出含 fixture-dependent skip（如 `VectorIndexReconciliationTests` 由
  `GATHER_RECONCILIATION_VECTOR=1` 显式门控），应单独记录，不得标成失败。

### 手工检查清单（按变更面选择）

- **启动与导航**：`.app` 可启动、页面互导航、session 不串数据、`Cmd+Q` 遵循
  生命周期、启动不依赖本地 HTTP。
- **工作区与图库**：建会话即自动 `metadata.scan`；含中文/空格/特殊字符路径可
  建资产；分页、缩略图、星级色标；撤销/重做后 UI 与持久化一致；空态明确。
- **相似度/重复/挑片**：分析可启动/取消；阈值与组大小修改后状态一致；破坏性
  重复处理有确认且失败有原因；挑片写回触发元数据同步；重复提交分析不产生
  不可控任务。
- **人脸关键词**：只验收链路与写回安全，不评价真实推理质量；分析/簇/审核状态
  可见；写回失败可诊断可重试；重启后 outbox 可恢复；无脸/损坏图有明确状态。
- **导出/任务/元数据**：进度可见、支持取消/重试；失败不静默；导出目标不覆盖
  未授权源资产；重启后可恢复可恢复任务；XMP outbox 重试/冲突/清理。
- **错误与安全**：未知命令返回结构化错误；缺记录不崩溃；写回/删除/覆盖均有
  确认边界；资产路径来自授权记录；SQLite 迁移失败保留错误信息、不删用户数据。

### 原生边界残留扫描

```bash
test "$(rg --files desktop/src packages/shared tests scripts | wc -l | tr -d ' ')" = 0
! rg -n '^(import (WebKit|JavaScriptCore)|.*WKWebView|.*WebViewHost|.*WebBridge)' \
  desktop/native --glob '*.swift'
! test -e package.json && ! test -e package-lock.json && ! test -e desktop/package.json
```

扫描应以当前工作树为准；未暂存的删除仍会被 `git ls-files` 列出，不能据此判断
文件仍然存在。

## 命令面契约（R5）

原 IPC 契约冻结的是 renderer/main 双进程边界；原生化后 renderer 与命令名路由层
均已删除，**类型化命令面**是唯一入口。以下规则从旧契约继承并升级为编译期契约。

### 命令面

- `GatherCore.CommandSurface`（`API/CommandSurface.swift`）聚合 **19 域 · 111 方法**
  的 `*Commands` 协议；组合根 `AppComposition` 构造 19 个 `*CommandsImpl` actor。
- 全部方法 `async throws`，参数/结果只用 `Protocol/` DTO；不存在同步入口、
  命令名字符串或命令级 JSON。
- **破坏性命令**必须由入参 DTO 携带 `confirmed`，实现内部校验失败即拒绝
  （如 `SESSION_DELETE_NOT_CONFIRMED`、`WRITEBACK_CONFIRM_REQUIRED`）。
- 参数缺失由 DTO 的可选性表达，运行时仅保留领域校验（不再有 MISSING_PARAM 层）。

### 分组与取消/状态

| 组 | 命令 | 取消/状态 |
|---|---|---|
| Session/photo | `session.*`、`photo.list_page` | session 状态持久化；导入错误按文件返回 |
| Culling | `culling.*`（分页 `culling.list_page`） | 逐 session 同步状态；写回失败可重试 |
| Similarity | `sim.analyze`、`sim.recluster`、`sim.result`、写回族 | analyze 走 JobService executor；recluster 未任务化（ADR-024） |
| Face/person | `fkw.*`、`person.*` | 分析取消；person 破坏性变更需确认 |
| Metadata | `metadata.*` | 变更与恢复需确认；未知 XMP 字段保留 |
| Assets/index | `assets.*`、`index.scan` | 重连需确认；扫描为持久任务，缺失文件保留 |
| Jobs | `jobs.list/cancel/retry/clear_completed` | 状态/租约/进度/重试持久化 |
| Quality/navigation | `quality.*`、`navigation.*` | AI 输出仅建议；组拆分/合并是导航覆盖 |
| Duplicate/filter/album | `dup.*`、`filter.*`、`album.*` | 重复处理破坏性；全局查询库内分页 |
| Export/template | `export.*`、`template.*` | 导出可取消；执行/应用/删除需确认 |
| Image/settings | `image.*`、`settings.*` | 尽力而为，不得使路由崩溃 |

### 兼容性规则

1. 不重命名命令/事件/枚举而不迁移契约测试（`GatherCoreTests/Protocol/*ContractTests`）。
2. 追加参数必须对既有调用方向后兼容。
3. 长任务必须持久化足够状态，使 UI 能区分 running/failed/cancelled/completed
   （JobService lease/checkpoint/dedupeKey 语义）。
4. AI 输出仅建议，未经用户显式命令不得改动 Pick/Reject/Rating/Label。
5. 元数据变更按 patch 而非整文档处理；写入方负责路径解析、基线比较、合并、
   备份与恢复。

### 分页契约（`culling.list_page`）

- 页按**逻辑资产**分组（`COALESCE(asset_id, id)`）：RAW+JPEG 变体永不跨页，每
  资产跨页恰好出现一次。
- `afterRowId`/`nextRowId` 是**不透明 keyset 游标**，UI 原样回传、不得解析。
- `total` 按逻辑资产计数；过滤谓词下推到**首选变体**（RAW 扩展名优先）。

### 事件通道

- 推送走 `GatherEventCenter.shared.wire(jobRunner:)`（`Support/GatherEventCenter.swift`）：
  `jobs:progress` 逐帧（终态帧驱动整页刷新）、`culling:sync-status`（C1 队列
  状态转换）、`gather:notification`（错误码，UI 经 `errorText` 映射）、
  `languageChanged`、`importCompleted`。
- 轮询兜底：Dashboard 活跃 2s/空闲 30s，控制中心 3s/15s，C1 胶囊 12s；事件与
  轮询双通道语义保留，事件丢失不致静默。

### 后台任务

- `metadata.scan`（session 范围，去重键 `metadata.scan:<sessionId>`）、
  `checksum.backfill`（`checksum.backfill:<sessionId>`）、`sim.analyze`、
  `face.analyze`、`duplicate.scan`、`quality.score`、`export.execute`、
  `thumbnail.build` 均由 `JobRunner` executor 承载；重聚类（recluster）除外，
  见 ADR-024。

### 相似度结果档位

- `similarity_results` 可存多档结果（主档 + 预计算邻居阈值 T±4/T±8，
  `"precomputed": true`）；"最新结果"判定（`getLatest`、culling 相似组 SQL、
  质量相对排名）必须排除 precomputed 行（不变量由 `reuse-and-tiers` 测试强制）。

### 增量聚类与簇版本（1.3）

- 聚类状态持久化在 `similarity_cluster_state`（每张已哈希照片的分量归属
  `component_index` + 已成组的 `group_seed`，NULL = 未成组）与
  `similarity_cluster_meta`（参数指纹 / `version` / `incremental_updates`）。
  `photo_id` 故意不加 `photos` 外键：照片删除后的残留行是增量 diff 的
  "已移除"依据，由状态重写（replace）整体清理；级联删除会让移除事件不可见。
- 增量路径的启用条件：分组模式为 `global`、状态参数指纹（阈值/组大小/模式）
  与本次一致、且连续增量次数 < `similarity_cluster_convergence_interval`
  （默认 10）。任一不满足即全量重聚类并清零计数（定期全局收敛）；
  `sequential` 模式无增量设施，会清除状态强制下次全量。
- 不变量：增量结果与 `ClusterEngine.clusterByHash` 全量结果在划分、组顺序
  （种子升序）、代表图（组内首元素 = 种子）与未成组集合上一致；组内其余成员
  为规范序（种子在前、其余按输入序），与全量的 BFS 发现序不承诺逐位相同。
  由 `GatherCoreTests/Similarity/IncrementalClustererTests.swift` 的随机
  200 步对账矩阵强制。
- 复杂度：邻域探测 O(|added| × n)，受影响分量局部重算 O(k²)；未受影响分量
  直接复用旧簇。若整库同属一个巨型分量，增量与全量同阶（无收益），后续可用
  LSH 候选桶降到亚二次。

## 提交与 Pull Request

提交信息建议遵循 Conventional Commits，例如：

```text
refactor(native): 完成原生任务中心路由
```

Pull Request 应说明：

1. 变更涉及的页面、服务或数据边界；
2. 已运行的测试、构建和打包命令及结果；
3. 未验证或明确排除的外部条件；
4. 是否涉及数据迁移、写回、删除或恢复行为。

不要把构建产物、个人照片、模型文件或本地数据库提交到仓库。

## 常见问题

### 构建失败并提示 Clang module cache

将 `CLANG_MODULE_CACHE_PATH` 指向 `/private/tmp` 下可写目录后重试：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test \
  --package-path desktop/native/gather-core
```

### 为什么没有 npm 命令？

Node/Electron 运行时和 TypeScript 前端已随原生迁移移除。开发、测试和打包入口
统一为 Swift Package 与 `desktop/native/build.sh`。

### 为什么生成的 `.app` 未签名？

这是源码构建的默认边界。需要发布签名时由发布环境提供 `CODESIGN_IDENTITY` 并
执行独立的签名、公证和安装验证流程；该流程不属于代码验收。

## 相关文档

- [项目总览](README.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
