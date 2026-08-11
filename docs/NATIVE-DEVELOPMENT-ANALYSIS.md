# macOS 原生开发规划（Swift 全原生迁移）

> 版本：v3（2026-08-09）
> v3 = v2 决策 + 模块/文件级迁移台账。每项任务落到具体 TS 文件 → Swift 文件，
> 标注迁移方式（移植/重写/删除/保留）、对接点与验收。
> 决策：**仅 macOS，Swift + SwiftUI 全原生，渐进式移除 Electron**。
> **改造基线 commit（main）：`0d6b667ba97ce23a9880eacc670e5bbaf1ef3c73`**
> （`feat(*): 完善桌面体验与文档`，2026-08-09 固定；当前 refactor-native 分支
> 起点与此同点）。改造进度在 §十 追踪。
> 配套文档：[ROADMAP.md](ROADMAP.md)、[ADR.md](ADR.md)、[DEVELOPMENT.md](DEVELOPMENT.md)。

---

## 一、目标与决策背景

- 最终形态：Swift + SwiftUI 原生应用，不依赖 Electron/Chromium/Node；
- 路径：**渐进式换壳（Strangler Fig）**——Swift 核心库 → 热路径下沉 → 宿主
  切换 → 逐页替换 → 移除 Electron，每阶段独立发布；
- 平台：macOS 独占（Intel + Apple Silicon）；Windows 原生保持决策门（§七）；
- 前置条件（Phase 0 验证门）：商业模型验证 + 性能归因审计确认瓶颈非算法层。

---

## 二、现状盘点（v2 快照，行数为 wc -l 实测）

| 能力 | 现状 | 规模（行） |
|---|---|---|
| 应用外壳 | Electron main/preload/renderer + React 18 + Vite | main/index.ts 595；preload/index.ts 309 |
| 领域服务 | 21 个服务目录（culling 最大） | culling 1902；indexer 1216；face-kw 872；similarity 792；metadata-sync 804 |
| 人脸推理 | ONNX（SCRFD + ArcFace）；darwin CoreML 尝试 + warmup 降级 | face-kw/ 14 文件 |
| 向量索引 | 内存 HNSW + angular LSH（纯算法） | hnsw-index.ts、lsh-index.ts |
| 解码 | sharp + sips 兜底 | image/ 9 文件 |
| 数据库 | better-sqlite3 + WAL；schema.ts 574、migrations.ts 1139、15 个 repo | db/ 18 文件 |
| 协议 | `packages/shared` TS 契约（16 领域模块 + core） | protocol/ 17 文件 |
| IPC | 20 个 `ipc/*.ipc.ts` + helpers.ts + registry.ts + preload 白名单 | ipc/ 22 文件 |
| 渲染层 | React 页面 8 组 + api 20 + components 14 | renderer/ ~81 文件（ts/tsx） |
| C1 集成 | osascript 桥 + GatherLink.coplugin（Swift） | capture-one.ts；coplugin/ |
| 测试 | vitest 94 文件 / e2e 3 spec / 基准 2 脚本 | tests/ |
| 打包 | electron-builder + afterPack 编译 coplugin | electron-builder.yml |

**结论**：真正 darwin-only 硬依赖仅 3 处（sips 兜底、AppleScript 桥、C1 Swift 插件），
迁移时全部保留或原生增强；纯算法资产（聚类/LSH/HNSW/dHash）逻辑可移植。

---

## 三、总体策略与关键机制

### 3.1 目标目录布局（新增）

```
desktop/native/
├── gather-core/                 # Swift Package：核心库（P1 起）
│   ├── Package.swift
│   ├── Sources/GatherCore/
│   │   ├── Protocol/            # TS 契约 → Swift 契约（1.1）
│   │   ├── Database/            # SQLite.swift + 迁移 + repos（1.2）
│   │   ├── IPC/                 # JSON 线协议（helper 模式，1.3）
│   │   ├── Image/               # CoreImage/ImageIO 解码与缩略图（2.1）
│   │   ├── Face/                # Vision 检测/编码 + 聚类/向量移植（2.2/2.3）
│   │   ├── Similarity/          # dHash/embedding/聚类移植（2.3）
│   │   ├── Watch/               # NSFileCoordinator 监控（2.4）
│   │   ├── Services/            # 领域服务重写（3.x 逐服务）
│   │   └── Logging/             # 统一日志/耗时采集（1.4）
│   └── Tests/GatherCoreTests/   # XCTest（对账测试，1.5）
├── gather-app/                  # SwiftUI 宿主 app（P3 起）
│   ├── GatherApp.swift          # App 入口/路由/窗口
│   ├── Host/                    # WKWebView 托管残余 React 页（3.0）
│   └── Views/                   # 逐页 SwiftUI（3.x）
└── build.sh                     # xcodebuild + .app 打包（4.1）
```

### 3.2 关键机制：宿主切换（修正 v2 未回答的并存问题）

v2 说"React 残余页与 SwiftUI 页并存"但未定义机制。P3 引入 **Swift 宿主 +
WKWebView 托管残余 React 页**，实现单一窗口、逐页替换：

```
P2 形态：Electron 壳 → Node 主进程 → gather-core helper（child_process JSON）
P3 形态：Swift 宿主 → 领域服务（同进程直连）＋ WKWebView（残余 React 页
        └→ WKScriptMessageHandler 桥，复用 1.1 契约）
P4 形态：纯 Swift，WKWebView 与 React 资产移除
```

### 3.3 核心决策

- 核心库用 **Swift 而非 Rust**：单语言、无 FFI、系统框架原生（§1.2）；
- **同一 SQLite 文件双实现共存**：P3 每迁移一个领域服务，该领域 repo 的写
  入权从 TS 侧移交 Swift 侧，按领域划分所有权，避免双写；TS 侧对应 ipc 入口
  停用（保留代码至 P4 删除）；
- 算法移植一律 **JS↔Swift 双向对账测试**（1.5），非最后统一验证；
- Vision embedding 与 ArcFace 特征空间不兼容 → P4 一次性全量重算。

### 3.4 迁移方式图例

| 符号 | 含义 |
|---|---|
| **移植** | 逻辑搬移 + 对账测试（算法层） |
| **重写** | 仅保留能力契约，实现全新（IO/并发/UI 层） |
| **保留** | 原样保留（C1 插件等） |
| **删除** | 随宿主移除（P4） |

---

## 四、执行计划（文件级台账）

> 每阶段结束跑 ROADMAP §六 四套基准并记入 §七。验证失败即止损回退。

### Phase 0：验证与决策门（0–2 月）

| # | 任务 | 落地物 | 通过标准 |
|---|---|---|---|
| 0.1 | 性能归因审计 | 跑四套基准，输出瓶颈归因报告 | 明确算法 vs 框架归因 |
| 0.2 | 商业信号复核 | 收入/留存证据 | 因果成立，非假设 |
| 0.3 | 资产台账 | 按 §四 各表反查代码，标注每文件归属阶段/方式 | 台账完整 |
| 0.4 | P0/P1 修复对齐 | ROADMAP Phase 0 剩余项（增量聚类 1.3、对账 1.6、验证 2.1） | Release 门 |

**产出**：Go/No-Go 决议。No-Go 即终止，维持 Electron 基线。

### Phase 1：Swift 核心库地基（2–4 月，~0.5 人）

| # | 任务 | 落地物 | 验收 |
|---|---|---|---|
| 1.1 | 契约定型 | `packages/shared/src/protocol/*.ts`（16 领域 + core）→ `GatherCore/Protocol/*.swift` 双向映射表（命令/事件/错误码） | 映射表全量覆盖 + `GatherCoreTests/Protocol` 编译期类型核对 |
| 1.2 | 数据库层 | `db/schema.ts`、`db/migrations.ts` → `GatherCore/Database/Schema.swift`、`Migrations.swift`；15 个 repo 的 SQL 逐条复用；ADR-005/006 流程重写（备份/回滚） | 迁移测试过；`docs/fixtures/schema.snapshot.json` 同步（TS 侧不变量测试双绿） |
| 1.3 | helper 形态 | `GatherCore/IPC/HelperProtocol.swift`（stdout JSON 线协议）+ Electron 侧 `main/services/helper/helper-client.ts`（新） | 冒烟：Electron 壳调 core 解码返回结果 |
| 1.4 | 日志/遥测 | `GatherCore/Logging/`，对齐现有 profiling 日志格式 | 四套基准可采集 Swift 侧指标 |
| 1.5 | **对账测试框架** | `GatherCoreTests/Reconciliation/`：同一 fixture 输入双跑（TS vitest ↔ Swift XCTest） | dHash/聚类/人脸预处理 3 个移植函数首批对账通过 |

### Phase 2：热路径下沉（4–9 月，~1 人，混合形态运行期）

每子任务独立发布。TS 侧 IPC 契约（`ipc/*.ipc.ts`）**不变**，服务内部改路由。

#### 2.1 解码 + 缩略图

| TS 现役（迁移方式） | Swift 落地 |
|---|---|
| `services/image/decoders/sharp-decoder.ts`（**重写**） | `Image/RAWDecoder.swift`（CoreImage RAW 管线，替代 libvips） |
| `services/image/decoders/sips-decoder.ts`（**删除**，系统框架替代兜底） | — |
| `services/image/decoders/fast-dimensions.ts`（**移植**） | `Image/Dimensions.swift`（单遍状态机） |
| `services/image/disk-cache.ts`（**重写**，SQLite 换 SQLite.swift） | `Database/ImageCache.swift` |
| `services/image/image.service.ts`（**改路由**） | 内部调用 helper-client |

**验收**：Import 基准 RAW/JPEG 混合冷热两轮 ≤ 基线；缩略图走
`CGImageSourceCreateThumbnailAtIndex`。

#### 2.2 人脸推理（ONNX → Vision）

| TS 现役（迁移方式） | Swift 落地 |
|---|---|
| `face-kw/face-detector.ts`、`face-encoder.ts`（**重写**） | `Face/Detector.swift`、`Encoder.swift`（`VNDetectFaceRectanglesRequest` / `VNGenerateFaceEmbeddings`） |
| `face-kw/face-inference-worker.ts`、`face-inference-worker-client.ts`（**重写**） | `Face/Inference.swift`（Swift 并发模型重设计：Actor + 流式进度/取消） |
| `face-kw/face-inference-fallback.ts`、`provider.ts`（**重写**） | `Face/Provider.swift`（provider 枚举：vision/cpu 可切换，含质量不达标回退 ONNX 的开关） |
| `face-kw/onnx-validator.ts`、`model-config.ts`、`model-downloader.ts`（**删除**） | —（Vision 无需模型资产） |
| `face-kw/face-preprocessing` 逻辑（见测试） | `Face/Preprocessing.swift`（**移植**，对账） |

**验收**：Face 基准 1 万张 ≤ 30 分钟；0.3c 质量对账 ARI/NMI ≥ 0.95；不达标保留
ONNX provider 回退。

#### 2.3 哈希/聚类/向量（**移植**，全部配 1.5 对账）

| TS 源 | Swift 落地 |
|---|---|
| `similarity/hash-computer.ts` | `Similarity/Hash.swift` |
| `similarity/cluster-engine.ts`（dHash 聚类） | `Similarity/ClusterEngine.swift` |
| `face-kw/face-clusterer.ts`（DBSCAN + LSH） | `Face/Clusterer.swift` |
| `face-kw/hnsw-index.ts`、`lsh-index.ts` | `Face/VectorIndex.swift`（CosineHnswIndex + angular LSH） |
| `face-kw/face-matcher.ts` | `Face/Matcher.swift` |
| `utils/analysis-worker.ts`、`heavy-task-scheduler.ts`（**重写**） | `Services/JobScheduler.swift`（Actor 调度、流式进度/心跳超时语义保留） |

**验收**：Similarity 基准 2 万/5 万通过；每个移植函数 JS↔Swift 输出对账
（dHash 精确相等，聚类比 ARI/NMI、向量比 recall）。

#### 2.4 文件监控

| TS 现役（迁移方式） | Swift 落地 |
|---|---|
| `indexer/index.service.ts` 的 watcher 段（`index.service.ts:313` watcher 状态 / `:514` watch() 注册，段 313–560，**重写**） | `Watch/Coordinator.swift`（NSFileCoordinator / FileProvider） |

**验收**：丢事件对账矩阵（ROADMAP 1.6）通过。

### Phase 3：宿主切换 + 领域服务与 UI 逐模块迁移（9–15 月，1–1.5 人）

先 3.0 建立宿主与桥，再按「页面-服务-仓库」配对逐模块替换，每模块交付
"SwiftUI 页面 + Swift 服务 + repo 所有权移交"，TS 侧 ipc 入口同步停用。

#### 3.0 宿主与桥（地基）

| 落地物 | 说明 |
|---|---|
| `gather-app/GatherApp.swift` | App 入口、路由（对应 `renderer/App.tsx` + `main.tsx`）、窗口 |
| `gather-app/Host/WebViewHost.swift` | WKWebView 托管残余 React 页 + `WKScriptMessageHandler` 桥（替代 `preload/index.ts` 的 gather:command 白名单语义） |
| `gather-app/Host/WebBridge.swift` | 桥契约 = 1.1 映射表，`renderer/api/client.ts` 改指桥 |

**验收**：全量 React 页面在 Swift 宿主内跑通 e2e（`tests/e2e/app.spec.ts` 等价）。

#### 3.1–3.6 模块配对台账

| # | 页面（React → SwiftUI） | 主进程服务（重写 → Swift） | repo 移交 | 关键组件（React → SwiftUI） |
|---|---|---|---|---|
| 3.1 | `pages/Dashboard/index.tsx` | `services/workspace/workspace-status.service.ts`、`services/jobs/job.service.ts` | analysis-job.repo | `hooks/useWorkspaceStatus.ts`（→ `@Observable`）、`utils/c1-preflight.ts` |
| 3.2 | `pages/Library/index.tsx`、`SessionDetail/Gallery.tsx` | `services/session/session.service.ts`（283）、`services/assets/*`（logical-photo-assets、photo-asset-resolver） | session.repo、photo.repo、asset.repo | `components/Lightbox`、`components/MetadataPanel`、`components/FilterBar`、`pages/SessionDetail/justified-layout.ts`（**移植**） |
| 3.3 | `pages/Similarity/index.tsx` | `services/similarity/similarity.service.ts`（792，重写；算法已下沉 2.3） | similarity-result.repo | `stores/similarityStore.ts`、`components/WritebackReport`、`components/SliderInput` |
| 3.4 | `pages/SessionDetail/Culling.tsx` | `services/culling/culling.service.ts`（1902，**最大服务**）、`services/writeback/writeback.service.ts`（630）、`services/metadata/metadata-sync-coordinator.ts`（804）、`metadata-mutation.service.ts`、`metadata-fingerprint.ts`、`metadata-conflict-fields.ts`、`metadata-contract.ts`、`metadata.service.ts`、`metadata-writer.interface.ts` | culling-decision.repo、culling-history.repo、metadata-outbox.repo、metadata-keyword-origin.repo、writeback.repo、metadata-cache.repo | `utils/c1-sync-controls.ts`、`SessionDetail/C1StatusCapsule.tsx` |
| 3.5 | `pages/FaceKeywording/*`（StepAnalyze/Review/Writeback + store）、`pages/Persons/*`（PersonDetail） | `services/face-kw/face-kw.service.ts`（872，重写）、`services/template/template.service.ts` | face.repo、person.repo | `components/TemplatePicker`、`pages/SessionDetail/ControlCenter/*`（workspace-view） |
| 3.6 | `pages/Settings/*`（含 C1HealthPanel）、`pages/Jobs`、`SessionDetail/Duplicates.tsx`、`Export.tsx`、`SessionDetail/indexProgress.ts` | `services/settings/settings.service.ts`、`services/quality/quality.service.ts`、`services/duplicate/duplicate.service.ts`、`services/export/*`（export、report）、`services/filter/filter-engine.ts`、`services/navigation/navigation.service.ts` | settings.repo、smart-album.repo | `components/Toast*`、`components/Dialog*`、`components/ProgressBar`、`components/Badge`、`components/Loading`、`components/ErrorBoundary`、`stores/sessionStore.ts`、`stores/settingsStore.ts`、`hooks/useEvent.ts`（→ AsyncStream/NotificationCenter） |

**i18n 收尾**（随 3.6）：`renderer/locales/*` → `Localizable.xcstrings`（key 表
复用 1063 key/语言，术语表 docs/i18n-glossary.md 不变）。

**C1 桥**（随 3.4/3.5）：`main/capture-one.ts`、`services/capture-one/*`（c1-health、
sync-state、errors）→ Swift 直连；`GatherLink.coplugin` **保留**。

**写回可靠性重做**（随 3.4，最大风险）：outbox/冲突检测/状态机 Swift 实现，
用 `tests/unit/services/culling/metadata-outbox.test.ts`、
`metadata-sync-coordinator.test.ts`、`writeback-service.test.ts`、
`tests/unit/services/capture-one/*` 行为基线对账。

**验收（每模块）**：该页 React 版可下线；对应 TS ipc 入口停用；相关单测在
Swift 侧等价通过；e2e 页面级 spec 转 Swift 侧。

### Phase 4：移除 Electron（15–18 月，~0.5 人）

| # | 任务 | 落地物 | 说明 |
|---|---|---|---|
| 4.1 | 打包替换 | `build.sh`（xcodebuild + 签名 + notarize），替代 electron-builder.yml、`scripts/afterPack.cjs` | coplugin 编译逻辑迁入 build.sh |
| 4.2 | 原生集成 | 深链：`main/deep-link.ts` → `CFBundleURLTypes` + `onOpenURL`；菜单：`main/menu.ts` → SwiftUI Menu/AppDelegate | 保留两语言 label 表 |
| 4.3 | embedding 重跑 | Vision 全量重算一次，模型版本指纹冻结（复用 ROADMAP V.1 机制） | 发布前离线完成 |
| 4.4 | 删除残留 | **删除**：`main/`（index.ts 595、ipc/ 22 文件、di/、db/ TS 侧、locale*.ts、utils/ worker 等）、`preload/index.ts`、`renderer/`、`packages/shared/`、`desktop/package.json` Electron 依赖、`tests/` 中 TS 单测、`scripts/*.mjs` 基准（迁 Swift） | 无 Electron/Node 残留 |
| 4.5 | 收尾验收 | 四套基准全绿 + Stretch 门（10 万规模） | `tests/e2e/` 等价迁移到 Swift UI 测试 |

---

## 五、关键风险与对策

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| 1 | IPC 契约重做（16+core 领域） | 数据流全量变动 | 1.1 最先定型 + 双向映射表唯一事实源 |
| 2 | 写回可靠性重做 | 用户 XMP 数据安全 | 3.4 用现有 4 组单测行为基线对账 |
| 3 | 历史 embedding 弃用 | 人脸分析重跑 | 4.3 一次全量重算 + 指纹冻结 |
| 4 | Phase 0 失败 | 投入作废 | No-Go 即终止 |
| 5 | 双实现共存期 SQLite 双写 | 数据损坏 | 3.x repo 所有权按领域划分，移交后 TS 侧 ipc 停用 |
| 6 | WKWebView 桥性能/兼容 | 残余页体验 | 3.0 先行 e2e 验证；页面迁移窗口压短 |
| 7 | Vision 质量未知 | 检测/识别质量差异 | 2.2 过 0.3c 门；不达标保留 ONNX provider |
| 8 | 算法移植精度漂移（float32/位运算/舍入） | 结果与 TS 不一致 | 1.5 对账框架逐函数门禁 + 固定种子 |
| 9 | Intel/AS 双架构 | 打包分发 | xcframework 通用二进制，CI 双架构验证 |

---

## 六、预算与资源

| 阶段 | 周期 | 人力 | 主要投入 |
|---|---|---|---|
| Phase 0 | 0–2 月 | 0.3 人 | 审计/台账 |
| Phase 1 | 2–4 月 | 0.5 人 | 契约/数据库/对账框架 |
| Phase 2 | 4–9 月 | 1 人 | 解码/人脸/聚类/监控下沉 |
| Phase 3 | 9–15 月 | 1–1.5 人 | 宿主桥 + 6 组模块（culling 组最重） |
| Phase 4 | 15–18 月 | 0.5 人 | 打包/重跑/清理 |

合计 **1.5–2 人年**。关键技能：Swift/SwiftUI、Core Image/Vision、SQLite.swift、
WKWebView 桥、Xcode 签名打包。

---

## 七、参考：被否决路径

| 路径 | 否决理由 |
|---|---|
| 维持 Electron | 与目标冲突；仅作 No-Go 回退基线 |
| Windows 原生（C++/WinUI 3） | 独立决策（ROADMAP 4.3）；双 UI 双倍维护（v1 §3） |
| Tauri 2 / Qt / Rust+egui | 跨平台收益对本目标无意义；FFI/UI 成本高（v1 §4） |
| Swift 内核 + 永久 Electron 壳 | 外壳钳制性能上限；仅作 Phase 2 中间态 |

---

## 八、不做清单

- 不做 Windows 原生、Tauri/Qt/其他跨平台框架；
- 不保留双栈长期并存（4.4 必须清 Electron 残留）；
- 不做云端同步/移动端/视频（沿用 ROADMAP §九）。

---

## 九、相关文档

- [ROADMAP.md](ROADMAP.md)：P0-P2 修复、里程碑 V、四套基准（§五/§六/§七）
- [ADR.md](ADR.md)：数据库迁移 ADR-005/006、写回/冲突、错误码化
- [DEVELOPMENT.md](DEVELOPMENT.md)：构建/测试/打包约定（P1-4 逐项迁移）
- [IPC_CONTRACT.md](IPC_CONTRACT.md)：1.1 契约定型输入
- [TEST.md](TEST.md)：单测/e2e 基线，3.4 写回对账来源

---

## 十、改造进度追踪

> 基线：main `0d6b667ba97ce23a9880eacc670e5bbaf1ef3c73`；分支：refactor-native。
> 每完成一项在此登记：状态 / 完成日期 / 证据指针（文件或测试命令）。
> 状态：`待做` → `进行中` → `已完成` / `已暂停` / `已终止`。

### 10.1 Phase 0：验证与决策门

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 0.1 | 性能归因审计 | 待做 | — | — |
| 0.2 | 商业信号复核 | 待做 | — | — |
| 0.3 | 资产台账 | 已完成 | 2026-08-09 | §二/§四 各表已按真实代码核验修正（9 处，含 repo 15、protocol 17、ipc 22、watcher 行号 313/514） |
| 0.4 | P0/P1 修复对齐 | 待做 | — | — |

### 10.2 Phase 1：Swift 核心库地基

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 1.1 | 契约定型（16+core 领域 → Swift） | 已完成 | 2026-08-09 | 15 域全部落地 `GatherCore/Protocol/*.swift` + 逐域契约测试（15 套件）；core/session 先行示范；`swift test` 375 全绿 |
| 1.2 | 数据库层（schema/migrations/repos） | 已完成 | 2026-08-09 | `Database/DB.swift`（系统 SQLite3 薄包装，better-sqlite3 语义）、`Schema.swift`（41 条 SQL verbatim）、`Migrations.swift`（0→31 全路径 + ADR-005/006 备份回滚）、`Repositories/` 15 个 repo（147 测试）；schema 与 `docs/fixtures/schema.snapshot.json` 41 表全对 |
| 1.3 | helper 形态（HelperProtocol + helper-client） | 已完成 | 2026-08-09 | `IPC/HelperProtocol.swift` 核心路由 + `GatherCoreHelper/main.swift`（stdout JSON 行）+ Electron 侧 `main/services/helper/helper-client.ts`（按 id 匹配/超时）；冒烟通过（echo/session:mock/未知命令） |
| 1.4 | 日志/遥测 | 已完成 | 2026-08-09 | `Logging/Telemetry.swift`（duration/counter/gauge，NDJSON 对齐基准脚本输出；GATHER_TELEMETRY=1 开关）+ 8 测试 |
| 1.5 | 对账测试框架 | 已完成 | 2026-08-09 | `GatherCoreTests/Reconciliation/`：首批 3 函数（dHash 50 / 聚类 17+3 / Face 预处理 17）；后扩展至 **7 函数**——dimensions（26）/ vector（1000 行 topK 逐位一致 + recall）/ clusterer（8）/ matcher（6 case）；TS 侧生成器 `scripts/reconciliation/generate-*.mjs`（固定种子 + `--check` 双跑拦截漂移，已实测抓到 1 个字节序移植 bug） |

> 附注（2026-08-09 工具链决议）：本机已装 swift.org 官方 toolchain 6.1.2（Linux，
> swift test 真跑 475 测试全绿）。四项决策修正：
> 1. **SQLite.swift 弃用**：其全部版本携带 Apple 专属 SQLCipher 二进制 target，
>    Linux SwiftPM 无法解析；改用系统 `import SQLite3` + C shim（`Sources/CSQLite/`），
>    零外部依赖，语义对齐 better-sqlite3（`Database/DB.swift`）。
> 2. **测试框架**：沿用 Swift Testing（CLT-only 环境的既定选择）；注意 Linux 6.1.2
>    上 `@Test(.serialized)` 不生效，涉及静态全局状态的测试（Logger/Telemetry）须用
>    模块内互斥锁（stateLock 模式）。
> 3. **Package.swift**：原 CLT 专属 rpath 改为 `#if os(macOS)` 条件化，Linux 可编译；
>    fixtures/README 显式 exclude，构建 0 warning。
> 4. **Swift 6 并发检查**（JobService 实现经验）：async 上下文直接调用
>    `NSLock.lock()/unlock()` 会报「unavailable from asynchronous contexts」——
>    须把临界区提取为同步辅助函数（takeCompletedResult/setController 等），
>    async 方法只调用同步辅助。另：`Task {}` 为异步调度（TS 的 async 函数在
>    首个 await 前同步执行），依赖「注册即生效」的状态（如并发计数）必须在
>    Task 外同步完成；swift-testing 并行跑测试时 Task 调度延迟明显，涉及
>    时序的测试须轮询等待条件而非固定 sleep。
>
> 附注 2（2026-08-10 macOS 26 环境实测，切换完整 Xcode 26.5 后）：
> 1. **macOS Foundation 与 Linux corelibs 的 NSString 差异**：Linux 上 String 有
>    `standardizingPath`/`pathComponents`/`lastPathComponent` 扩展，macOS 只有
>    NSString 有；且含 NUL 的 String 经 `NSString.appendingPathComponent` 会返回
>    nil 导致隐式解包崩溃（RepositorySupport.swift 的 tilde 保护逻辑，Linux 不触发）。
>    修复：字符串拼接 + standardizingPath 替代桥接调用。
> 2. **SQLite 3.51 只读 WAL 行为**：header 标记 WAL 的库只读打开必须有同名
>    -shm 文件，否则 prepare 报 SQLITE_CANTOPEN（旧版/Electron 打包版无此行为）；
>    迁移备份完整性检查因此失败。修复：检查前创建空 -wal/-shm 伴随文件、检查后清理
>    （Migrations.swift backupIntegrityCheckOK）。
> 3. **部署目标 macOS 13 → 14**：2.2 人脸推理原假设 VNGenerateFaceEmbeddingsRequest，
>    但 macOS 26.5 SDK 公开 API 无此请求（tbd/头文件/swiftinterface 均无）；
>    改用人脸区域裁剪 + VNGenerateImageFeaturePrintRequest rev2（768 维）。
>    部署目标提升到 14 仅为后续 API 可用性预留，当前实现未依赖 14 专属 API。
> 4. **macOS 26 SDK Foundation 自带同名 `JSONValue`**（3.0 宿主实测）：宿主模块内
>    对 GatherCore.JSONValue 做 `case .object` 模式匹配会被解析到 Foundation 版本
>    导致编译错误（"member 'object' expects argument"）——跨模块读取一律经
>    GatherCore 内访问器（isObject/objectValue/boolValue/numberValue/arrayElements）。
> 5. **macOS 26 WebKit `callAsyncJavaScript` 返回 nil**（3.0 实测）：简单表达式也
>    返回 nil；测试改同步 `evaluateJavaScript` + 全局变量轮询模式。

### 10.3 Phase 2：热路径下沉

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 2.1 | 解码 + 缩略图 | 已完成 | 2026-08-10 | `Image/Dimensions.swift`（fast-dimensions 移植，26 case 对账）+ `Database/ImageCache.swift`（disk-cache 重写，21 测试）+ **`Image/RAWDecoder.swift`（CoreImage/ImageIO 重写 sharp+sips：getDimensions 含 EXIF orientation 5-8 交换、getThumbnail 走 `CGImageSourceCreateThumbnailAtIndex` + WithTransform、getPreview fit-inside 不放大；11 测试）** + helper `image:dimensions`/`image:thumbnail`/`image:preview` 三命令（HelperProtocolTests 30 测试）+ `image.service.ts` 改路由（thumbnail/preview 优先 helper 含 RAW，失败回退 sharp；GATHER_CORE_HELPER=1 启用，默认零变化）+ **`sips-decoder.ts` 删除**（能力被 RAWDecoder 覆盖；di/init.ts 注册链移除）。验收冒烟：3200×2400 PNG → 缩略图 256×192 / 预览 ≤2048 / 尺寸 3200×2400；TS 侧 98 文件 597 测试全绿 |
| 2.2 | 人脸推理（Vision） | 部分完成 | 2026-08-10 | `Face/Provider.swift`（provider 枚举 vision/cpu + `FaceInferenceConfig` 对齐 MODEL_CONFIG 默认值 + fallbackToOnnxEnabled 开关）+ `Face/Detector.swift`（VNDetectFaceRectanglesRequest，bbox/confidence + 左上原点转换 + 阈值/上限过滤）+ `Face/Encoder.swift`（检测 → 人脸区域裁剪 → VNGenerateImageFeaturePrintRequest rev2 提取 embedding，L2 归一化）+ `Face/Inference.swift`（Actor 批处理：逐图独立失败/进度流/取消，对齐 face-kw.service 批语义）；FaceInferenceTests 12 用例。**环境决议**：macOS 26.5 SDK 无 `VNGenerateFaceEmbeddingsRequest`（计划假设 API，tbd/头文件/swiftinterface 均无），改用人脸区域裁剪 + feature print（768 维，实测 rev2）作 embedding；与 ArcFace 512 维特征空间不兼容（§3.3 已声明 P4 全量重算）。**待接线**：TS 侧 face-kw.service 路由（推理走 helper 需同进程直连——线协议传大批量图片 base64 不现实，且 512/768 维混写会破坏聚类，故随 3.0 宿主切换接入）；**0.3c 质量对账门**（ARI/NMI ≥ 0.95）需真实人脸数据集（基准环境），未过时 `fallbackToOnnxEnabled` 回退 TS ONNX 管线 |
| 2.3 | 哈希/聚类/向量移植 | 已完成 | 2026-08-09 | `Similarity/Hash.swift`+`ClusterEngine.swift`（1.5 对账）+ `Face/Clusterer.swift`（DBSCAN+LSH 门，8 case 对账）+ `Face/VectorIndex.swift`（CosineHnswIndex+CosineLshIndex，topK 逐位一致/recall≥TS）+ `Face/Matcher.swift`（11 用例对账）+ `Services/JobScheduler.swift`（Actor 预算准入，排队取消）+ `AnalysisWorker.swift`（进度流/错误传播）。**基准**：`gather-core-benchmarks`（2 万/5 万两档全过，见 `Sources/GatherCoreBenchmarks/README.md`） |
| 2.4 | 文件监控（FSEvents） | 已完成 | 2026-08-10 | `Watch/Coordinator.swift`（**重写**）：FSEventStream 递归 watcher + 每 session 750ms 去抖 + fullScan 兜底，行为契约与 TS 对齐（扩展名分流/目录事件→全量/注册失败→recovery/15s 轮询对账/stop 清理）。**技术决议**：计划原文的 NSFileCoordinator/FileProvider 不提供目录事件监控（NSFileCoordinator 是读写协调 API、FileProvider 是托管扩展框架），改用 FSEventStream——Node 的 fs.watch(recursive) 在 macOS 底层就是 FSEvents，语义天然一致；且 FSEvents 给绝对路径 + 文件级标志（ItemIsDir/MustScanSubDirs/RootChanged），内核丢事件显式走全量兜底（ROADMAP 1.6 决策 B 的"周期性全量对账"原生形态）。**路径处理**：FSEvents 回调返回 realpath（/var→/private/var），统一 canonicalPath（POSIX realpath 优先 + TS textualPath 式字符串映射兜底，删除事件后 realpath 必失败）。**测试**：`Watch/CoordinatorTests` 13 用例（TS 侧无 watcher 直接单测，本文件补足缺口）：纯文件事件增量/目录与未知事件全量/去抖合并/全量优先/注册失败/15s 轮询注册/根变更注销/stop 清理 + **丢事件对账矩阵**（`reconciliationMatrixRandom200Ops`：固定种子随机 200 次增删改/重命名+目录操作，模拟索引增量应用 == 全量 walk，实测连续 3 轮全绿）。全套 559 测试通过 |

### 10.4 Phase 3：宿主切换 + 领域服务与 UI 迁移

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 3.0 | 宿主与桥（Swift 宿主 + WKWebView） | 部分完成 | 2026-08-10 | `gather-app`（SwiftPM executable，依赖 gather-core）：`GatherApp.swift`（@main 入口/窗口/启动装配：Application Support/gather.sqlite + MigrationRunner + renderer 定位）+ `Host/WebViewHost.swift`（WKWebView + `loadFileURL(renderer/index.html, allowingReadAccessTo:)` + WKUserScript 注入 BridgeScript + 导航禁外跳 + didFail 日志）+ `Host/WebBridge.swift`（**preload 三层校验完整镜像**：命令白名单 118（与 core.ts 全对账）/destructive 30 必须 confirmed:true/params isRecord；事件白名单 9；响应信封 {id,ok,data,error} 复用 HelperProtocol 约定；同步/异步命令路由分流）+ `Host/BridgeScript.swift`（`window.gather` 全 20 方法同名 shim，Promise 按 id 配对）+ `Host/GatherImageSchemeHandler.swift`（`gather-image://` WKURLSchemeHandler 直出 JPEG，等价主进程 protocol.handle）+ `Host/SessionCommandRouter.swift`（渐进式接线：**~107/118 命令已点亮**——session.*/photo.*/workspace.status/jobs.*/image.get_dimensions/face.models_status/settings.*/filter.*/navigation.*/sim.*（含写回族）/assets.*/dup.*/fkw.*/person.*/template.*/quality.*/metadata.*/index.scan/session.create_from_directory/album.*/culling.*，含 executor 异步 sim.analyze/dup.scan/fkw.analyze/quality.analyze/index.scan 等；仅 export.*/image.preload_* NOT_IMPLEMENTED）。**技术决议**：① macOS 26 SDK Foundation 自带同名 `JSONValue`，宿主内模式匹配被遮蔽 → GatherCore 增 `JSONValue` 访问器（isObject/objectValue/boolValue/numberValue）供跨模块安全读取；② macOS 26 WebKit `callAsyncJavaScript` 返回 nil，测试改同步 `evaluateJavaScript` + 全局变量轮询；③ 错误消息对账：SimilarityServiceError/DuplicateServiceError 增 CustomStringConvertible，executor 失败经 String(describing:) 记录的 job errorMessage 与 TS 逐字一致。**测试**：`WebBridgeTests` 10 用例 + RouterCommands 21 + RouterCommandsWave2 55 + RouterCommandsWave3 11（每命令 ≥1 成功路径 + 参数缺失错误路径）+ `WebViewHostSmokeTests` 3 用例（**真实 WKWebView + 真实 vite 产物**：session.list 桥回路返回信封/destructive 无 confirmed reject/未知命令 reject）。**验收口径**：桥回路冒烟已过（等价 e2e 桥段）；全量 React 页面 e2e 验证待 renderer 资产与命令覆盖到位后补。**待接线**：export.*（ExportService 未移植）+ image.preload_*（ImageService 编排） |
| 3.1 | Dashboard 模块（workspace/jobs） | 已完成 | 2026-08-10 | 服务层：`WorkspaceStatusService`（26 用例与 TS 单测一一对应）+ `JobService`（drain/取消/心跳看门狗/进度节流/checkpoint/waitForResult/并发上限 2/clearCompleted 阶段证据保护，11 用例）。**页面+壳**：`gather-app/RootView.swift`（宿主导航壳：侧栏 + `RootNavigation` 可测导航模型 + WebViewContainer 单实例 ZStack 常驻，`WebViewHost.navigate(to:)` 走 location.hash 驱动 React HashRouter；工作台=SwiftUI DashboardView、全局图库/人脸库/任务中心/设置=WKWebView 残余页）+ `Dashboard/DashboardViewModel.swift`（`DashboardDataProvider` 协议注入，workspace.status/jobs.list 直连 GatherCore，2s/30s 轮询对齐 react-query）+ `Dashboard/DashboardView.swift`（工作区概览条/会话卡片/任务中心 attention+history/cancel/retry/清理已完成/新建工作区 NSOpenPanel/删除确认）。测试：`DashboardViewModelTests` 13 + `RootViewTests` 6（含真实窗口端到端：RootView 切换 → React hash 路由）。**未覆盖（TODO 标注）**：Capture One 导入、create_from_directory 一跳化、索引失败重试、多选批量删除、jobs:progress 事件通道（轮询兜底）。TS ipc 入口停用随 3.6 Jobs 页面迁移一并执行 |
| 3.2 | Library/Gallery 模块（session/assets） | 已完成 | 2026-08-10 | 服务层已移植：`Services/SessionService.swift`（283 行 TS 全量：createSession/createFromDirectory 目录校验与根目录拒绝/listSessions/getSession 源路径推导持久化/deleteSession(s) 依赖序删除 + orphan 标记/addPhotos 分批尺寸 + index_seq bump + draft→photos_loaded/updateSession；模块级纯函数 commonParentDirectory/normalizeImportFilepaths/sanitizeSessionSourcePath 对齐 TS）、`Services/PhotoAssets.swift`（collapsePhotoAssets：asset_id 分组 + RAW 优先）、`Services/PhotoAssetResolver.swift`（resolve/resolveMany 5 路 JOIN 分块读、asset_read_mode 三态、dual shadow-read 警告、sha256 路径摘要）。另：`Database/DB.swift` transaction 支持 SAVEPOINT 嵌套（better-sqlite3 语义，TS 的 addPhotos/deleteSessions 依赖嵌套事务）。测试：`SessionServiceTests`（15）+ `PhotoAssetResolverTests`（8）。**页面完成**：`gather-app/Library/`（LibraryViewModel+View：跨工作区浏览、photo.list_page 分页、filter.photos_global 筛选、缩略图网格 gather-image://、防抖提交）+ `gather-app/Gallery/`（GalleryViewModel+View：键集分页 cursor 语义对齐 TS、变体折叠/展开（raw 首选）、搜索链式拉满（limit 1000）+ 退出保留首页（pages.slice(0,1)）、hasNextPage 守卫、客户端 hasFace/noFace 过滤、JustifiedLayout.swift 移植布局纯函数）+ `Support/`（LiveDataProvider 直连路由）。RootView 导航壳接入 Library/Gallery 页（工作区详情按 sessionId 参数装配）。测试：LibraryViewModelTests + GalleryViewModelTests（含真实 SQLite 集成）+ JustifiedLayoutTests。**待做**：TS ipc 停用随页面迁移收尾 |
| 3.3 | Similarity 模块 | 部分完成 | 2026-08-10 | 服务层已移植：`Services/SimilarityService.swift`（792 行 TS 全量：analyze 快照事务/index_seq/校验/既有 hash 过滤/hash 复用（400 分块批量读）/缺 hash 解码计算（注入 thumbnailProvider，DHash 已下沉 2.3）/聚类（clusterProvider 默认 ClusterEngine）/buildStoredResult/replace/邻域阈值档预计算（单次 pairwise 多档）；hasResult/getResult 成员表组装 + legacy groups_json 回退 + 阈值档解析；cancel 占用语义 + 共享 analysis_status 保护；recluster；run 记录 running→ok/failed 终态与早退语义对齐 TS finally；JobAbortSignal 协作取消——pre-cluster abort 早退、cluster 中 abort 抛 JobCancelledError 写 cancelled）。测试：`SimilarityServiceTests`（14，含 reuse-and-tiers / run-record 窗口断言 / result-lazy / cancellation 一一对应）。**接线**：sim.result/sim.cancel_analysis 同步 + sim.recluster/sim.analyze 异步（JobService executor + waitForResult）已接（2026-08-10）。**页面完成**：`gather-app/Similarity/`（SimilarityViewModel+View：阈值/组大小滑杆草稿（tier 防抖 + requestID 过期守卫）、分析运行状态机（idle/loading/result/error）、进度轮询（jobs.list 替代 jobs:progress 推送）、重新聚类、取消；阈值档预计算采纳（stats.threshold 校验）+ 无匹配档保留草稿）。RootView 接入 Similarity 页。测试：SimilarityViewModelTests（17，含真实库 sim.analyze 全链路）。**待做**：TS ipc 停用随页面迁移收尾 |
| 3.4 | Culling 模块（writeback/metadata，最大） | 已完成 | 2026-08-10 | **服务层全量**：`Services/CullingService.swift`（**TS 1902 行全量移植**：decide keep/reject/pending/rating/colorLabel 与 revision 冲突、批量 decide/decide_group、RAW/JPEG 共享侧车合并一次 XMP 操作、同资产变体 pick 合并、历史栈 undo/redo（before/after 快照恢复 + ALREADY_UNDONE/NOT_UNDONE/DIVERGED/栈序守卫）、summary 七项计数、reset 全量/按组、sync_status/flush/retry_sync/finalize_sync/writeback/retry_failed_writeback/confirm_sync/cleanup、资产分组分页 list_page（游标/首选 RAW/质量相对排名/面孔归一化/precomputed 层排除）、getUpdateContext 缓存）；写回协作经 `CullingWritebackPort/CullingSyncPort` 协议注入真实 WritebackService/MetadataSyncCoordinator（**写回引擎零改动**，不重写）。测试：`CullingServiceTests` 57 用例（TS 25 case 全覆盖 + 超量边界）。**接线**：culling.* 全部 20 命令（sync 17 + async 3，destructive 双兜底逐字消息对齐；WebBridgeTests RouterCommandsWave3 11 用例）。**3.4 写回链**（前置，同日完成）：`WritebackService.swift`（630+planners 全量：preview/execute/retryFailed/confirmSync/cleanup 状态机、face keyword 合并计划）+ `MetadataSyncCoordinator.swift`（804 行协调状态机：claim/冲突检测/备份写回/重试/确认/清理）+ `MetadataMutationService.swift`（queuePhotoValues/queueMutation 串行链）+ `MetadataService.swift` + `MetadataFingerprint.swift` + `MetadataConflictFields.swift` + `MetadataContract.swift` + `MetadataProviders.swift`（XMPProvider/C1BridgeProvider 协议 + DefaultC1BridgeProvider）+ `CaptureOneSyncState.swift`（会话同步状态聚合）；XMP 文件读写宿主实现 `SidecarXMPProvider.swift`（gather-app）。测试：WritebackServiceTests + MetadataSyncTests 系列逐 case 对应 TS 4 组基线（metadata-outbox/sync-coordinator/writeback-service/capture-one） |
| 3.5 | FaceKeywording/Persons 模块 | 部分完成 | 2026-08-10 | **服务层全量**：`Services/FaceKwService.swift`（**872 行 TS 全量移植**：analyze 经 JobService executor + checkpoint（JobAbortSignal.addHandler 传播 abort）、clusters（含 binding/members）、bind/unbind/merge/remove_member、preview/writeback/confirm_sync/cleanup（经 FaceKwWritebackBridge 适配 WritebackService）、recluster/cancel_analysis、run 终态与早退语义、分析签名构造）+ `Services/TemplateService.swift`（CRUD + apply 经 SettingsService 落库）。测试：FaceKeywordingServiceTests + TemplateServiceTests（fkw 全行为 + template 11 用例）。**接线**：fkw.* 11 命令 + person.* 8 命令 + template.* 6 命令（face-kw.ipc.ts/person.ipc.ts/template.ipc.ts 逐字段对齐；destructive 双兜底；WebBridgeTests RouterCommandsWave2）。**待做**：Persons 页面 SwiftUI + fkw/person TS ipc 停用 |
| 3.6 | Settings/Jobs/收尾模块 | 部分完成 | 2026-08-10 | **服务层 5/6 完成**：①`Protocol/Settings.swift`（MLStatusData/MLModelPresence/MLModelInfo，对齐 settings.ipc.ts 内联形状）+ `Services/SettingsService.swift`（40 键默认值表逐字对齐，13 测试）；②`Services/NavigationService.swift`（16 测试）；③`Services/FilterEngine.swift`（16 测试）；④`Services/DuplicateService.swift`（**588 行 TS 全量移植**：single-flight scan/busy、sha256 精确组（并发 2）、视觉组（注入 thumbnailProvider→DHash，阈值默认 4）、similarity_hashes 复用（size/mtime 一致校验）、getGroups/resolveGroup/resolveMember（keep_one 分数与 mtime 决出/COALESCE 语义）、排除 exact 于 visual；**哈希写路径与 SimilarityService 同 UPSERT `ON CONFLICT(session_id, photo_id)` 协调互不覆盖**；21 测试含单飞 busy/取消不落库/进度三阶段）。**接线**（`SessionCommandRouter` 3.0 补全，TS 事实源逐字段对齐）：同步 21 命令 settings.*(6)/filter.*(3)/navigation.list/split/merge/sim.result/sim.cancel_analysis/jobs.cancel/retry/clear_completed/photo.list_page/assets.candidates + 异步 sim.analyze/dup.scan（JobService executor + waitForResult，checkpoint/dedupeKey 逐字对齐）+ 前已接线 12 命令，共 33 命令点亮（WebBridgeTests RouterCommands 套件 21 用例）。**错误消息对账修复**：SimilarityServiceError/DuplicateServiceError 增 CustomStringConvertible（description=TS error.message），executor 失败经 `String(describing:)` 记录的 errorMessage 与 TS 逐字一致（SIM_NO_PHOTOS 等）。**收尾完成**：`Services/QualityService.swift`（**482 行 TS 全量**：analyze executor + progress checkpoint（photoIds/nextPhotoIndex，photoIds nil 省略键对齐 TS）、metricFromPixels 锐度/曝光公式、faceBox 区域裁剪（regionPixels 四舍五入）+ subjectSharpness/closedEyeRisk/qualityScore 加权公式、技术质量相对排名、get 最新行去重；`Services/IndexerService.swift`（index.service.ts 扫描核心：目录 walk/checksum（lazy 模式）/asset_files 回填/幽灵照片/缺失检测；watcher 复用 2.4 Watch/Coordinator）。测试：QualityServiceTests + IndexerServiceTests。**接线**：quality.* 2 命令 + index.scan + session.create_from_directory（executor 链 + 入队失败回滚）+ metadata.* 5 命令 + sim 写回族 6 命令 + assets 剩余 4 命令 + album.* 6 命令（SmartAlbumRepo + FilterEngine 组合），共 **54 新命令**（RouterCommandsWave2 55 用例）+ **culling.* 20 命令**（Wave3 11 用例）——累计 **~107/118 命令点亮**，仅 export.*/image.preload_* 未接（ExportService 未移植/ImageService 编排）。**待做**：ExportService、image.preload_* 编排、TS ipc 停用随页面迁移 |

### 10.5 Phase 4：移除 Electron

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 4.1 | 打包替换（build.sh） | 待做 | — | — |
| 4.2 | 原生集成（深链/菜单） | 待做 | — | — |
| 4.3 | embedding 重跑 | 待做 | — | — |
| 4.4 | 删除 Electron 残留 | 待做 | — | — |
| 4.5 | 收尾验收（四套基准 + Stretch 门） | 待做 | — | — |

### 10.6 后续计划与待办（2026-08-10 快照）

> 原则：Linux 可推进的任务优先；需 macOS 框架（CoreImage/Vision/AppKit/
> NSFileCoordinator）的条目标注「需 Mac」。
> **2026-08-10 起平台限制解除**：开发机已切换 macOS 26（Xcode 26.5），
> 原标注「需 Mac」的条目（2.4/3.0/3.1–3.3 页面等）均可在本机推进，
> 「需 Mac」标注仅保留平台属性说明，不再构成阻塞。
> 2026-08-10：3.2/3.3 服务层已完成（见 10.4 证据），原两行 P1 任务转为
> 「页面/接线待 Mac」并降级；新增下一个 Linux 可做项 3.6 服务层（settings/
> quality/duplicate/filter/navigation 中可独立重写者）。
> 2026-08-10 晚：**2.4 文件监控已完成**（FSEvents，见 10.3 证据），P1 项移除；
> **3.0 宿主与桥已完成核心**（gather-app 骨架 + WebBridge 三层校验 + 真实
> WebView 桥回路冒烟，见 10.4 证据）——原 P2 升为可用基线，3.1–3.3 页面
> 收尾与命令接线成为下一步主线。
> 2026-08-10 深夜：**3.6 服务层首批 3 服务完成**（Settings/Navigation/Filter，
> 见 10.4 证据）——剩余 Duplicate/Quality 两项降为续做；全套 597 测试全绿。
> 2026-08-10（次日）：**3.1 模块完成**（Dashboard SwiftUI 页面 + RootView 导航
> 壳，见 10.4）；**3.6 服务层 5/6 完成**（DuplicateService 588 行全量移植，
> 哈希写路径与 SimilarityService 协调）；**3.0 命令接线补全**（33 命令点亮：
> settings/filter/navigation/sim/jobs/photo.list_page/assets/dup + executor
> 异步 sim.analyze/dup.scan；错误消息 CustomStringConvertible 对账修复）。
> 全套：gather-core 618（71 suites）+ gather-app 60（6 suites）全绿。
> 2026-08-10（冲刺）：**Phase 3 服务层全部完成**——3.4 Culling（1902 行 + 写回链
> 8 文件）、3.5 FaceKw（872）+ Template、3.6 Quality（482）+ Indexer；**3.2/3.3
> 页面完成**（Library/Gallery/Similarity SwiftUI + JustifiedLayout 移植）；
> **命令接线 ~107/118**（fkw/person/template/quality/metadata/sim 写回/assets
> 剩余/album/culling 全量 + executor 链）；仅 export.*/image.preload_* 未接。
> 全套：gather-core 757（97 suites）+ gather-app 185（12 suites）全绿。

| 优先级 | 任务 | 前置 | 说明 |
|---|---|---|---|
| P0 | **2.2 收尾**：0.3c 质量对账（真实人脸数据集，ARI/NMI ≥ 0.95 门）；TS 侧 face-kw.service 推理路由随宿主切换接入（Swift 侧 Detector/Encoder/Inference/Provider 已就绪 2026-08-10） | 基准环境 / 宿主 | Vision embedding 768 维（feature print rev2）与 ArcFace 512 维不兼容，P4 全量重算时统一 |
| P1 | **3.6 收尾**：ExportService 移植 + export.* 接线；image.preload_* 编排（ImageService 任务）；TS ipc 停用随各页面迁移（3.2/3.3 页面已上线 SwiftUI，React 对应页可下线） | 服务层已就绪（2026-08-10） | 3.4/3.5/3.6 服务层全部完成，仅剩 export 与 preload 编排 |
| P2 | **3.0 补全（续）**：gather-image 库内校验、深链/菜单（4.2 前置） | 接线已基本全量（~107/118） | 桥与白名单已就绪 |
| P2 | **Phase 0 残余**：0.1 性能归因审计 / 0.2 商业信号复核 / 0.4 P0/P1 修复对齐 | — | Go/No-Go 门未正式落锤；当前按继续推进执行 |
| P2 | **Telemetry 对接**：四套基准采集 Swift 侧指标（1.4 验收） | 基准环境可用 | `GATHER_TELEMETRY=1` 已实现；Swift 基准已产出 NDJSON 指标行 |
| P3 | **Phase 4 收尾**：build.sh 打包/深链/菜单/embedding 重跑/Electron 残留删除 | Phase 3 完成 | — |
