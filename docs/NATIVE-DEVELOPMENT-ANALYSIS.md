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
| 1.5 | 对账测试框架 | 已完成 | 2026-08-09 | `GatherCoreTests/Reconciliation/`：3 个移植函数首批对账通过——dHash（50 fixture）/ dHash 聚类（17+3）/ Face 预处理（17）；TS 侧生成器 `scripts/reconciliation/generate-*.mjs`（`--check` 双跑拦截漂移） |

> 附注（2026-08-09 工具链决议）：本机已装 swift.org 官方 toolchain 6.1.2（Linux，
> swift test 真跑 375 测试全绿）。三项决策修正：
> 1. **SQLite.swift 弃用**：其全部版本携带 Apple 专属 SQLCipher 二进制 target，
>    Linux SwiftPM 无法解析；改用系统 `import SQLite3` + C shim（`Sources/CSQLite/`），
>    零外部依赖，语义对齐 better-sqlite3（`Database/DB.swift`）。
> 2. **测试框架**：沿用 Swift Testing（CLT-only 环境的既定选择）；注意 Linux 6.1.2
>    上 `@Test(.serialized)` 不生效，涉及静态全局状态的测试（Logger/Telemetry）须用
>    模块内互斥锁（stateLock 模式）。
> 3. **Package.swift**：原 CLT 专属 rpath 改为 `#if os(macOS)` 条件化，Linux 可编译。

### 10.3 Phase 2：热路径下沉

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 2.1 | 解码 + 缩略图 | 待做 | — | — |
| 2.2 | 人脸推理（Vision） | 待做 | — | — |
| 2.3 | 哈希/聚类/向量移植 | 待做 | — | — |
| 2.4 | 文件监控（NSFileCoordinator） | 待做 | — | — |

### 10.4 Phase 3：宿主切换 + 领域服务与 UI 迁移

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 3.0 | 宿主与桥（Swift 宿主 + WKWebView） | 待做 | — | — |
| 3.1 | Dashboard 模块（workspace/jobs） | 待做 | — | — |
| 3.2 | Library/Gallery 模块（session/assets） | 待做 | — | — |
| 3.3 | Similarity 模块 | 待做 | — | — |
| 3.4 | Culling 模块（writeback/metadata，最大） | 待做 | — | — |
| 3.5 | FaceKeywording/Persons 模块 | 待做 | — | — |
| 3.6 | Settings/Jobs/收尾模块 | 待做 | — | — |

### 10.5 Phase 4：移除 Electron

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 4.1 | 打包替换（build.sh） | 待做 | — | — |
| 4.2 | 原生集成（深链/菜单） | 待做 | — | — |
| 4.3 | embedding 重跑 | 待做 | — | — |
| 4.4 | 删除 Electron 残留 | 待做 | — | — |
| 4.5 | 收尾验收（四套基准 + Stretch 门） | 待做 | — | — |
