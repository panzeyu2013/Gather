# macOS 原生开发规划（Swift 全原生迁移）

> 版本：v3.1（2026-08-11）
> v3 = v2 决策 + 模块/文件级迁移台账。每项任务落到具体 TS 文件 → Swift 文件，
> 标注迁移方式（移植/重写/删除/保留）、对接点与验收。
> 决策：**仅 macOS，Swift + SwiftUI 全原生，渐进式移除 Electron**。
> **改造基线 commit（main）：`0d6b667ba97ce23a9880eacc670e5bbaf1ef3c73`**
> （`feat(*): 完善桌面体验与文档`，2026-08-09 固定；当前 `refactor` 分支
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
- 本文件 §十一：**UI 对齐补强清单**（main 基线 vs 原生版逐页/逐组件差异与修复台账，2026-08-12 并入原 UI_COMPARISON_REPORT.md）

---

## 十、改造进度追踪

> 基线：main `0d6b667ba97ce23a9880eacc670e5bbaf1ef3c73`；分支：`refactor`。
> 每完成一项在此登记：状态 / 完成日期 / 证据指针（文件或测试命令）。
> 状态：`待做` → `进行中` → `已完成` / `已暂停` / `已终止`。

### 10.1 Phase 0：验证与决策门

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 0.1 | 性能归因审计（代码范围） | 已完成 | 2026-08-11 | `gather-core-benchmarks` 已完成 2 万/5 万规模 dHash、embedding、HNSW、LSH 基准；core/app 原生测试、release build 和 residual scan 已复核。真实实材归因按用户要求不纳入本轮 |
| 0.2 | 商业信号复核 | 范围外 | — | 用户明确要求跳过，不作为重构/代码验收门 |
| 0.3 | 资产台账 | 已完成 | 2026-08-09 | §二/§四 各表已按真实代码核验修正（9 处，含 repo 15、protocol 17、ipc 22、watcher 行号 313/514） |
| 0.4 | P0/P1 修复对齐（代码范围） | 已完成 | 2026-08-11 | Swift core/app 全套测试、原生 release bundle、深链/菜单与 Electron/Node residual scan 已跑通；真实人脸质量、签名/公证安装和商业信号按用户要求跳过 |

### 10.2 Phase 1：Swift 核心库地基

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 1.1 | 契约定型（16+core 领域 → Swift） | 已完成 | 2026-08-09 | 15 域全部落地 `GatherCore/Protocol/*.swift` + 逐域契约测试（15 套件）；core/session 先行示范；`swift test` 375 全绿 |
| 1.2 | 数据库层（schema/migrations/repos） | 已完成 | 2026-08-09 | `Database/DB.swift`（系统 SQLite3 薄包装，better-sqlite3 语义）、`Schema.swift`（41 条 SQL verbatim）、`Migrations.swift`（0→31 全路径 + ADR-005/006 备份回滚）、`Repositories/` 15 个 repo（147 测试）；schema 与 `docs/fixtures/schema.snapshot.json` 41 表全对 |
| 1.3 | helper 形态（HelperProtocol + helper-client） | 已完成 | 2026-08-09 | `IPC/HelperProtocol.swift` 核心路由 + `GatherCoreHelper/main.swift`（stdout JSON 行）+ Electron 侧 `main/services/helper/helper-client.ts`（按 id 匹配/超时）；冒烟通过（echo/session:mock/未知命令） |
| 1.4 | 日志/遥测 | 已完成 | 2026-08-09 | `Logging/Telemetry.swift`（duration/counter/gauge，NDJSON 对齐基准脚本输出；GATHER_TELEMETRY=1 开关）+ 8 测试 |
| 1.5 | 对账测试框架 | 已完成 | 2026-08-09 | `GatherCoreTests/Reconciliation/`：首批 3 函数（dHash 50 / 聚类 17+3 / Face 预处理 17）；后扩展至 **7 函数**——dimensions（26）/ vector（1000 行 topK 逐位一致 + recall，`GATHER_RECONCILIATION_VECTOR=1` 显式门控，CI 单独跑）/ clusterer（8）/ matcher（6 case）；TS 侧生成器 `scripts/reconciliation/generate-*.mjs`（固定种子 + `--check` 双跑拦截漂移，已实测抓到 1 个字节序移植 bug） |

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
| 2.2 | 人脸推理（Vision，代码范围） | 已完成 | 2026-08-11 | `Face/Provider.swift`、`Detector.swift`、`Encoder.swift`、`Inference.swift` 已接入 native face.analyze executor；`GatherApp.prepareNativeEmbeddingRerun` 写入按数据库隔离的 768 维 marker，并排入 dedupe/checkpoint 任务。真实推理质量/ARI/NMI 按用户要求跳过 |
| 2.3 | 哈希/聚类/向量移植 | 已完成 | 2026-08-09 | `Similarity/Hash.swift`+`ClusterEngine.swift`（1.5 对账）+ `Face/Clusterer.swift`（DBSCAN+LSH 门，8 case 对账）+ `Face/VectorIndex.swift`（CosineHnswIndex+CosineLshIndex，topK 逐位一致/recall≥TS）+ `Face/Matcher.swift`（11 用例对账）+ `Services/JobScheduler.swift`（Actor 预算准入，排队取消）+ `AnalysisWorker.swift`（进度流/错误传播）。**基准**：`gather-core-benchmarks`（2 万/5 万两档全过，见 `Sources/GatherCoreBenchmarks/README.md`） |
| 2.4 | 文件监控（FSEvents） | 已完成 | 2026-08-10 | `Watch/Coordinator.swift`（**重写**）：FSEventStream 递归 watcher + 每 session 750ms 去抖 + fullScan 兜底，行为契约与 TS 对齐（扩展名分流/目录事件→全量/注册失败→recovery/15s 轮询对账/stop 清理）。**技术决议**：计划原文的 NSFileCoordinator/FileProvider 不提供目录事件监控（NSFileCoordinator 是读写协调 API、FileProvider 是托管扩展框架），改用 FSEventStream——Node 的 fs.watch(recursive) 在 macOS 底层就是 FSEvents，语义天然一致；且 FSEvents 给绝对路径 + 文件级标志（ItemIsDir/MustScanSubDirs/RootChanged），内核丢事件显式走全量兜底（ROADMAP 1.6 决策 B 的"周期性全量对账"原生形态）。**路径处理**：FSEvents 回调返回 realpath（/var→/private/var），统一 canonicalPath（POSIX realpath 优先 + TS textualPath 式字符串映射兜底，删除事件后 realpath 必失败）。**测试**：`Watch/CoordinatorTests` 13 用例（TS 侧无 watcher 直接单测，本文件补足缺口）：纯文件事件增量/目录与未知事件全量/去抖合并/全量优先/注册失败/15s 轮询注册/根变更注销/stop 清理 + **丢事件对账矩阵**（`reconciliationMatrixRandom200Ops`：固定种子随机 200 次增删改/重命名+目录操作，模拟索引增量应用 == 全量 walk，实测连续 3 轮全绿）。全套 559 测试通过 |

> 2026-08-11 状态修正：2.2 的原生宿主接线已通过 `GatherApp.prepareNativeEmbeddingRerun` 写入按数据库隔离的 768 维 migration marker，并排入带 dedupe/checkpoint 的 `face.analyze` 任务；真实照片集的 ARI/NMI 质量门仍未替代，详见 10.5/10.6。

### 10.4 Phase 3：宿主切换 + 领域服务与 UI 迁移

> 说明：下方原始模块台账保留迁移过程中的中间记录；2026-08-11 的“最终状态覆盖”表是本轮交叉检查后的权威状态，旧证据中的 WKWebView/未接线描述不再代表当前工作树。

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 3.0 | 宿主与桥（Swift 宿主 + WKWebView） | 部分完成 | 2026-08-10 | `gather-app`（SwiftPM executable，依赖 gather-core）：`GatherApp.swift`（@main 入口/窗口/启动装配：Application Support/gather.sqlite + MigrationRunner + renderer 定位）+ `Host/WebViewHost.swift`（WKWebView + `loadFileURL(renderer/index.html, allowingReadAccessTo:)` + WKUserScript 注入 BridgeScript + 导航禁外跳 + didFail 日志）+ `Host/WebBridge.swift`（**preload 三层校验完整镜像**：命令白名单 118（与 core.ts 全对账）/destructive 30 必须 confirmed:true/params isRecord；事件白名单 9；响应信封 {id,ok,data,error} 复用 HelperProtocol 约定；同步/异步命令路由分流）+ `Host/BridgeScript.swift`（`window.gather` 全 20 方法同名 shim，Promise 按 id 配对）+ `Host/GatherImageSchemeHandler.swift`（`gather-image://` WKURLSchemeHandler 直出 JPEG，等价主进程 protocol.handle）+ `Host/SessionCommandRouter.swift`（渐进式接线：**~107/118 命令已点亮**——session.*/photo.*/workspace.status/jobs.*/image.get_dimensions/face.models_status/settings.*/filter.*/navigation.*/sim.*（含写回族）/assets.*/dup.*/fkw.*/person.*/template.*/quality.*/metadata.*/index.scan/session.create_from_directory/album.*/culling.*，含 executor 异步 sim.analyze/dup.scan/fkw.analyze/quality.analyze/index.scan 等；仅 export.*/image.preload_* NOT_IMPLEMENTED）。**技术决议**：① macOS 26 SDK Foundation 自带同名 `JSONValue`，宿主内模式匹配被遮蔽 → GatherCore 增 `JSONValue` 访问器（isObject/objectValue/boolValue/numberValue）供跨模块安全读取；② macOS 26 WebKit `callAsyncJavaScript` 返回 nil，测试改同步 `evaluateJavaScript` + 全局变量轮询；③ 错误消息对账：SimilarityServiceError/DuplicateServiceError 增 CustomStringConvertible，executor 失败经 String(describing:) 记录的 job errorMessage 与 TS 逐字一致。**测试**：`WebBridgeTests` 10 用例 + RouterCommands 21 + RouterCommandsWave2 55 + RouterCommandsWave3 11（每命令 ≥1 成功路径 + 参数缺失错误路径）+ `WebViewHostSmokeTests` 3 用例（**真实 WKWebView + 真实 vite 产物**：session.list 桥回路返回信封/destructive 无 confirmed reject/未知命令 reject）。**验收口径**：桥回路冒烟已过（等价 e2e 桥段）；全量 React 页面 e2e 验证待 renderer 资产与命令覆盖到位后补。**待接线**：export.*（ExportService 未移植）+ image.preload_*（ImageService 编排） |
| 3.1 | Dashboard 模块（workspace/jobs） | 已完成 | 2026-08-10 | 服务层：`WorkspaceStatusService`（26 用例与 TS 单测一一对应）+ `JobService`（drain/取消/心跳看门狗/进度节流/checkpoint/waitForResult/并发上限 2/clearCompleted 阶段证据保护，11 用例）。**页面+壳**：`gather-app/RootView.swift`（宿主导航壳：侧栏 + `RootNavigation` 可测导航模型 + WebViewContainer 单实例 ZStack 常驻，`WebViewHost.navigate(to:)` 走 location.hash 驱动 React HashRouter；工作台=SwiftUI DashboardView、全局图库/人脸库/任务中心/设置=WKWebView 残余页）+ `Dashboard/DashboardViewModel.swift`（`DashboardDataProvider` 协议注入，workspace.status/jobs.list 直连 GatherCore，2s/30s 轮询对齐 react-query）+ `Dashboard/DashboardView.swift`（工作区概览条/会话卡片/任务中心 attention+history/cancel/retry/清理已完成/新建工作区 NSOpenPanel/删除确认）。测试：`DashboardViewModelTests` 13 + `RootViewTests` 6（含真实窗口端到端：RootView 切换 → React hash 路由）。**未覆盖（TODO 标注）**：Capture One 导入、create_from_directory 一跳化、索引失败重试、多选批量删除、jobs:progress 事件通道（轮询兜底）。TS ipc 入口停用随 3.6 Jobs 页面迁移一并执行 |
| 3.2 | Library/Gallery 模块（session/assets） | 已完成 | 2026-08-10 | 服务层已移植：`Services/SessionService.swift`（283 行 TS 全量：createSession/createFromDirectory 目录校验与根目录拒绝/listSessions/getSession 源路径推导持久化/deleteSession(s) 依赖序删除 + orphan 标记/addPhotos 分批尺寸 + index_seq bump + draft→photos_loaded/updateSession；模块级纯函数 commonParentDirectory/normalizeImportFilepaths/sanitizeSessionSourcePath 对齐 TS）、`Services/PhotoAssets.swift`（collapsePhotoAssets：asset_id 分组 + RAW 优先）、`Services/PhotoAssetResolver.swift`（resolve/resolveMany 5 路 JOIN 分块读、asset_read_mode 三态、dual shadow-read 警告、sha256 路径摘要）。另：`Database/DB.swift` transaction 支持 SAVEPOINT 嵌套（better-sqlite3 语义，TS 的 addPhotos/deleteSessions 依赖嵌套事务）。测试：`SessionServiceTests`（15）+ `PhotoAssetResolverTests`（8）。**页面完成**：`gather-app/Library/`（LibraryViewModel+View：跨工作区浏览、photo.list_page 分页、filter.photos_global 筛选、缩略图网格 gather-image://、防抖提交）+ `gather-app/Gallery/`（GalleryViewModel+View：键集分页 cursor 语义对齐 TS、变体折叠/展开（raw 首选）、搜索链式拉满（limit 1000）+ 退出保留首页（pages.slice(0,1)）、hasNextPage 守卫、客户端 hasFace/noFace 过滤、JustifiedLayout.swift 移植布局纯函数）+ `Support/`（LiveDataProvider 直连路由）。RootView 导航壳接入 Library/Gallery 页（工作区详情按 sessionId 参数装配）。测试：LibraryViewModelTests + GalleryViewModelTests（含真实 SQLite 集成）+ JustifiedLayoutTests。**待做**：TS ipc 停用随页面迁移收尾 |
| 3.3 | Similarity 模块 | 部分完成 | 2026-08-10 | 服务层已移植：`Services/SimilarityService.swift`（792 行 TS 全量：analyze 快照事务/index_seq/校验/既有 hash 过滤/hash 复用（400 分块批量读）/缺 hash 解码计算（注入 thumbnailProvider，DHash 已下沉 2.3）/聚类（clusterProvider 默认 ClusterEngine）/buildStoredResult/replace/邻域阈值档预计算（单次 pairwise 多档）；hasResult/getResult 成员表组装 + legacy groups_json 回退 + 阈值档解析；cancel 占用语义 + 共享 analysis_status 保护；recluster；run 记录 running→ok/failed 终态与早退语义对齐 TS finally；JobAbortSignal 协作取消——pre-cluster abort 早退、cluster 中 abort 抛 JobCancelledError 写 cancelled）。测试：`SimilarityServiceTests`（14，含 reuse-and-tiers / run-record 窗口断言 / result-lazy / cancellation 一一对应）。**接线**：sim.result/sim.cancel_analysis 同步 + sim.recluster/sim.analyze 异步（JobService executor + waitForResult）已接（2026-08-10）。**页面完成**：`gather-app/Similarity/`（SimilarityViewModel+View：阈值/组大小滑杆草稿（tier 防抖 + requestID 过期守卫）、分析运行状态机（idle/loading/result/error）、进度轮询（jobs.list 替代 jobs:progress 推送）、重新聚类、取消；阈值档预计算采纳（stats.threshold 校验）+ 无匹配档保留草稿）。RootView 接入 Similarity 页。测试：SimilarityViewModelTests（17，含真实库 sim.analyze 全链路）。**待做**：TS ipc 停用随页面迁移收尾 |
| 3.4 | Culling 模块（writeback/metadata，最大） | 已完成 | 2026-08-10 | **服务层全量**：`Services/CullingService.swift`（**TS 1902 行全量移植**：decide keep/reject/pending/rating/colorLabel 与 revision 冲突、批量 decide/decide_group、RAW/JPEG 共享侧车合并一次 XMP 操作、同资产变体 pick 合并、历史栈 undo/redo（before/after 快照恢复 + ALREADY_UNDONE/NOT_UNDONE/DIVERGED/栈序守卫）、summary 七项计数、reset 全量/按组、sync_status/flush/retry_sync/finalize_sync/writeback/retry_failed_writeback/confirm_sync/cleanup、资产分组分页 list_page（游标/首选 RAW/质量相对排名/面孔归一化/precomputed 层排除）、getUpdateContext 缓存）；写回协作经 `CullingWritebackPort/CullingSyncPort` 协议注入真实 WritebackService/MetadataSyncCoordinator（**写回引擎零改动**，不重写）。测试：`CullingServiceTests` 57 用例（TS 25 case 全覆盖 + 超量边界）。**接线**：culling.* 全部 20 命令（sync 17 + async 3，destructive 双兜底逐字消息对齐；WebBridgeTests RouterCommandsWave3 11 用例）。**3.4 写回链**（前置，同日完成）：`WritebackService.swift`（630+planners 全量：preview/execute/retryFailed/confirmSync/cleanup 状态机、face keyword 合并计划）+ `MetadataSyncCoordinator.swift`（804 行协调状态机：claim/冲突检测/备份写回/重试/确认/清理）+ `MetadataMutationService.swift`（queuePhotoValues/queueMutation 串行链）+ `MetadataService.swift` + `MetadataFingerprint.swift` + `MetadataConflictFields.swift` + `MetadataContract.swift` + `MetadataProviders.swift`（XMPProvider/C1BridgeProvider 协议 + DefaultC1BridgeProvider）+ `CaptureOneSyncState.swift`（会话同步状态聚合）；XMP 文件读写宿主实现 `SidecarXMPProvider.swift`（gather-app）。测试：WritebackServiceTests + MetadataSyncTests 系列逐 case 对应 TS 4 组基线（metadata-outbox/sync-coordinator/writeback-service/capture-one） |
| 3.5 | FaceKeywording/Persons 模块 | 部分完成 | 2026-08-10 | **服务层全量**：`Services/FaceKwService.swift`（**872 行 TS 全量移植**：analyze 经 JobService executor + checkpoint（JobAbortSignal.addHandler 传播 abort）、clusters（含 binding/members）、bind/unbind/merge/remove_member、preview/writeback/confirm_sync/cleanup（经 FaceKwWritebackBridge 适配 WritebackService）、recluster/cancel_analysis、run 终态与早退语义、分析签名构造）+ `Services/TemplateService.swift`（CRUD + apply 经 SettingsService 落库）。测试：FaceKeywordingServiceTests + TemplateServiceTests（fkw 全行为 + template 11 用例）。**接线**：fkw.* 11 命令 + person.* 8 命令 + template.* 6 命令（face-kw.ipc.ts/person.ipc.ts/template.ipc.ts 逐字段对齐；destructive 双兜底；WebBridgeTests RouterCommandsWave2）。**待做**：Persons 页面 SwiftUI + fkw/person TS ipc 停用 |
| 3.6 | Settings/Jobs/收尾模块 | 部分完成 | 2026-08-10 | **服务层 5/6 完成**：①`Protocol/Settings.swift`（MLStatusData/MLModelPresence/MLModelInfo，对齐 settings.ipc.ts 内联形状）+ `Services/SettingsService.swift`（40 键默认值表逐字对齐，13 测试）；②`Services/NavigationService.swift`（16 测试）；③`Services/FilterEngine.swift`（16 测试）；④`Services/DuplicateService.swift`（**588 行 TS 全量移植**：single-flight scan/busy、sha256 精确组（并发 2）、视觉组（注入 thumbnailProvider→DHash，阈值默认 4）、similarity_hashes 复用（size/mtime 一致校验）、getGroups/resolveGroup/resolveMember（keep_one 分数与 mtime 决出/COALESCE 语义）、排除 exact 于 visual；**哈希写路径与 SimilarityService 同 UPSERT `ON CONFLICT(session_id, photo_id)` 协调互不覆盖**；21 测试含单飞 busy/取消不落库/进度三阶段）。**接线**（`SessionCommandRouter` 3.0 补全，TS 事实源逐字段对齐）：同步 21 命令 settings.*(6)/filter.*(3)/navigation.list/split/merge/sim.result/sim.cancel_analysis/jobs.cancel/retry/clear_completed/photo.list_page/assets.candidates + 异步 sim.analyze/dup.scan（JobService executor + waitForResult，checkpoint/dedupeKey 逐字对齐）+ 前已接线 12 命令，共 33 命令点亮（WebBridgeTests RouterCommands 套件 21 用例）。**错误消息对账修复**：SimilarityServiceError/DuplicateServiceError 增 CustomStringConvertible（description=TS error.message），executor 失败经 `String(describing:)` 记录的 errorMessage 与 TS 逐字一致（SIM_NO_PHOTOS 等）。**收尾完成**：`Services/QualityService.swift`（**482 行 TS 全量**：analyze executor + progress checkpoint（photoIds/nextPhotoIndex，photoIds nil 省略键对齐 TS）、metricFromPixels 锐度/曝光公式、faceBox 区域裁剪（regionPixels 四舍五入）+ subjectSharpness/closedEyeRisk/qualityScore 加权公式、技术质量相对排名、get 最新行去重；`Services/IndexerService.swift`（index.service.ts 扫描核心：目录 walk/checksum（lazy 模式）/asset_files 回填/幽灵照片/缺失检测；watcher 复用 2.4 Watch/Coordinator）。测试：QualityServiceTests + IndexerServiceTests。**接线**：quality.* 2 命令 + index.scan + session.create_from_directory（executor 链 + 入队失败回滚）+ metadata.* 5 命令 + sim 写回族 6 命令 + assets 剩余 4 命令 + album.* 6 命令（SmartAlbumRepo + FilterEngine 组合），共 **54 新命令**（RouterCommandsWave2 55 用例）+ **culling.* 20 命令**（Wave3 11 用例）——累计 **~107/118 命令点亮**，仅 export.*/image.preload_* 未接（ExportService 未移植/ImageService 编排）。**待做**：ExportService、image.preload_* 编排、TS ipc 停用随页面迁移 |

> **2026-08-11 最终状态覆盖（本轮执行结果，以本段为准）**：Phase 3 页面、服务和原生路由已全量收尾；Phase 4 已移除 WKWebView、React/TypeScript renderer、TS IPC、Electron 配置和 Node 构建入口。真实人脸质量、签名/公证安装、商业信号按用户明确要求列为本轮范围外，不阻塞代码验收。

| # | 本轮状态 | 证据与剩余边界 |
|---|---|---|
| 3.0 | 已完成 | `GatherApp`、`RootView`、`SessionCommandRouter` 和 `CommandRouter` 组成纯 SwiftUI/同进程路由；Export、ImagePreload、路径授权和原生导入均已接线；WKWebView/桥文件已删除 |
| 3.1 | 已完成 | Dashboard、Jobs、控制中心、原生文件/深链导入、一跳建库、索引/质量任务、失败重试和删除流程已由原生页面/服务承接；任务中心以 JobService 为唯一状态源 |
| 3.2 | 已完成 | Library/Gallery SwiftUI 页面、智能相册 CRUD、RAW/JPEG 资产关联、孤立 XMP、离线卷重关联、真实 SQLite 集成测试、变体折叠与分页完成；TS 页面和 IPC 已移除 |
| 3.3 | 已完成 | Similarity SwiftUI 页面、分析/取消/重聚类、阈值档、写回预览/执行/重试/清理、Capture One 确认链路和任务状态轮询完成；TS 页面和 IPC 已移除 |
| 3.4 | 已完成 | Culling 挑片预览/对比、范围与质量筛选、相似度组决策、导航组、逐字段冲突处理、写回、XMP/Capture One 同步链与命令接线已完成 |
| 3.5 | 已完成 | FaceKeywording、Persons、Template 和控制中心的原生流程与路由装配已完成；对应 TS IPC 已移除 |
| 3.6 | 已完成 | Settings、Jobs、Duplicates、Export、ImagePreload、Filter、Navigation、Quality、Indexer 全部由 SwiftUI/GatherCore 承接；对应 TS IPC、renderer 和打包入口已删除 |


> **2026-08-12 第四轮命令面校准**：SessionCommandRouter 实测 **118/118 命令全点亮**
> （同步 execute 103 + 异步 executeAsync 22，去重 118，与 TS preload 白名单逐名相等；
> export.* 与 image.preload_* 均已接线）。destructive 确认门控 31/31 全覆盖。
> 历史文本中的 "~107/118"、"仅 export.*/image.preload_* NOT_IMPLEMENTED"、
> "culling 20（sync 17 + async 3）"（实为 19：16+3）、"fkw 11 命令"（实为 13）、
> "metadata 5 命令"（实为 7）均已过时，以本段为准。

### 10.5 Phase 4：移除 Electron

| # | 任务 | 状态 | 完成日期 | 证据 |
|---|---|---|---|---|
| 4.1 | 打包替换（build.sh） | 已完成 | 2026-08-11 | `desktop/native/build.sh` 直接执行 gather-core + gather-app Swift release 构建并组装 `release/Gather.app`（默认输出目录，可用 `OUTPUT_DIR` 覆盖），不再依赖 Node/renderer；签名/公证按范围外处理 |
| 4.2 | 原生集成（深链/菜单） | 已完成 | 2026-08-11 | `GatherAppDelegate.swift` 支持 `gather://import`、文件打开面板、拖入/打开文件、菜单与通知；`GatherDeepLink` 过滤扩展名、去重并校验常规文件；单测通过 |
| 4.3 | embedding 重跑（代码范围） | 已完成 | 2026-08-11 | 原生首次启动按数据库写入 768 维 Vision feature print rev2 设置，并为已有工作区创建带 dedupe/checkpoint 的 `face.analyze` 任务；真实照片集质量结果按用户要求跳过 |
| 4.4 | 删除 Electron 残留 | 已完成 | 2026-08-11 | 已删除 `desktop/src`、`desktop/package.json`、`packages/shared`、TS IPC/preload/renderer、Electron/Vite/Playwright 配置及旧 JS 测试脚本；原生包源只保留 Swift/SwiftUI |
| 4.5 | 收尾验收（代码门） | 已完成 | 2026-08-11 | gather-core 760 测试（98 suites）、gather-app 81 测试（7 suites）、native release bundle、Swift source/static residual scan 均通过；真实人脸质量、签名/公证安装、商业信号明确跳过，不作为本轮代码门 |

### 10.6 后续计划与待办（2026-08-11 快照）

> 本轮已完成：Phase 3 全部原生页面/服务/路由、原生 release 打包脚本、深链/菜单、ExportService、ImagePreloadService、图片授权校验、embedding 重跑任务装配，以及 Phase 4 Electron/Node 运行时清理。下列历史说明保留用于追踪；当前待办仅保留明确范围外或需要外部发布材料的门。

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
| 范围外 | **真实人脸质量**：真实数据集 ARI/NMI、推理质量和标注集验收 | 外部标注数据与基准环境 | 用户明确要求跳过；代码侧已保留 Vision 768 维隔离、marker、dedupe/checkpoint 重跑调度 |
| 范围外 | **签名/公证/安装**：Apple 凭据、notarization、安装升级回滚、SBOM/模型 license 材料 | 发布凭据与运维环境 | 用户明确要求跳过；build.sh 只负责可复现 unsigned bundle 组装 |
| 范围外 | **商业信号/实材性能归因**：导入/Culling/Similarity/Face 的真实材料与产品决策 | 产品数据与实材环境 | 用户明确要求跳过；算法基准和自动化测试不被冒充为商业证据 |
| 可选 | **Telemetry 归档** | 基准环境可用 | `GATHER_TELEMETRY=1` 已实现；不阻塞本轮原生代码验收 |

---

## 十一、UI 对齐补强清单（main 基线 vs 原生版）

> 2026-08-12：由 8 个并行 subagent 对每个页面/组件逐一通读生成，并入原
> `UI_COMPARISON_REPORT.md`（该独立文件已删除，本节为权威台账）。
> 基线：`main` 分支 `desktop/src/renderer`（Electron + React 18 + TS + CSS Modules
> + i18next）；对比对象：当前 `refactor` 分支 `desktop/native/gather-app`（SwiftUI +
> GatherCore 同进程直连）。行号引用均以分析时点为准。
> 状态图例：`待做` → `进行中` → `已完成`。
> **2026-08-12 第一轮修复（9 个并行 subagent 分域实施）**：全局设施（GatherLocalization
> 本地化层 / GatherEventCenter 事件总线 / GatherToast Toast 系统 / NativeCommandClient
> 出口翻译）与逐页 P0/P1 修复已落地，当时 gather-app 81/81 + gather-core 760/760 全绿
> （第二轮后 90/90，见 §11.12）；P2 样式与数据源限制项见 §11.11。
> **2026-08-12 第三轮（本轮）**：一致性审计后修复崩溃/生命周期/契约差异，见 §11.13。

### 11.0 总览与全局缺口

- 数据/命令契约层对齐度高（gather-core 逐字段搬运 TS 契约），差异集中在 **UI 层**。
- **五大方向性缺口**：
  1. **C1（Capture One）集成层整体缺失**：导入预检四层门控、健康面板、同步状态机、状态胶囊全部缺失；
  2. **事件驱动刷新未接线**：`jobs:progress` / `culling:sync-status` / `gather:notification` 三条推送通道无任何 SwiftUI 消费者，各页靠手动刷新或局部轮询；
  3. **错误码与文案无本地化**：`GatherErrorCode`、job type/status/progressMessage 的 rawValue 直接展示给用户，无 i18n；
  4. **品牌视觉语言整体丢失**：主色 `#a54d2a`、暖米底色 `#f5f0eb`、边框+阴影+圆角(10/14/20)+hover 全部退化为系统蓝/系统灰平面风；
  5. **Toast 系统完全缺失**，替换为常驻 banner，且 `captureOneError` 通知已 post 但无人订阅（错误静默丢失）。

#### 全局设计 token 对比（global.css vs SwiftUI 实际值）

| Token | 原始版 | 原生版 | 结论 |
|---|---|---|---|
| 背景 | `--color-bg:#f5f0eb` 暖米色 | `windowBackgroundColor` 系统灰 | 品牌底色丢失 |
| 表面 | `#faf7f2` / elevated `#fffaf6` | `.controlBackgroundColor` | 近似、无 elevated |
| 主色 | `--color-primary:#a54d2a`（陶土橘），hover `#9e4525`，soft `#f3dfd4` | `Color.accentColor`（系统蓝），全工程无 `.tint` 覆盖 | **品牌主色丢失** |
| 语义色 | success `#31723d` / error `#b3403f` / warning `#d4944f` / info `#2d6ba1` | 系统 `.green/.red/.orange/.blue` | 语义近似 |
| 圆角 | sm 10 / md 14 / lg 20 / control 12 / pill 999（px） | 内联字面量 6/8/10（pt），无 token | 更锐利、无体系 |
| 阴影 | `--shadow-sm/md/control` 双层柔和阴影 | **无任何阴影** | 层级感缺失 |
| hover | `--color-hover:#f0e8de`、按钮上浮/换色/反色 | 仅系统按钮默认态 | 反馈缺失 |
| 字号 | 14px 基线；h1 24px/700；卡片名 16px/600 | 13pt 基线；24pt 页头；`.headline`13pt | 层级近似、值不同 |
| 暗色模式 | **无**（固定浅色） | 系统语义色自动适配 | **原生更强** |
| 响应式 | 多页 media query（680/760/900/1000px） | 无（窗口 min 1100×720） | 原生无 |

### 11.1 Dashboard / Library

**对齐良好**：10 个筛选字段、300ms 防抖、60/页分页、criteriaKey 归零页码、会话列表骨架均等价。

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| Capture One 导入（来源选择 + 四层预检门控 reachable/appRunning/automationAuthorized/documentOpen） | Dashboard/index.tsx L190-198, L295-303, L538-571；c1-preflight.ts L61-104 | NewSessionSheet 仅本地文件夹（DashboardView.swift L428-502）；`onCaptureOneImport` 桥已存在但 UI 无入口 | 已完成 |
| 多选 + 全选(半选) + 批量删除 | index.tsx L76-78, L244-249, L393-425, L618-626 | 无 | 已完成 |
| 索引失败卡片重试按钮 | index.tsx L361-371, L463-467 | 无 | 已完成 |
| Toast 通知系统（截断导入警告/部分失败提示） | ToastStore + index.tsx L208-219 | 无（仅 actionError 横幅） | 已完成 |
| jobs:progress 事件实时推送 | index.tsx L118-153 | 仅 2s/30s 轮询，且每 tick 每会话 N+1 查 workspace.status | 已完成 |
| 错误码 → 中文文案 | utils/errors.ts L12-40；locales/ | 裸 code 直显 | 已完成 |
| Library 支持面板 24 条上限 + "另有 N 个" | Library/index.tsx L348, L377, L390-392 | 仅 4 条、无更多提示 | 已完成 |
| 字符串插值 bug | — | LibraryView.swift L175 `"⚠️ (album.name)"`、L256 `"还有 (...count - 4) 个候选"` 为字面量 | 已完成 |
| i18n（zh/en） | locales/ 全套 | 全部硬编码中文 | 部分完成（仅 Settings 页 PageCopy，全应用 i18n 未做，见 11.11 ③） |

**P1/P2**：卡片 hover 上浮+主色边框、选中态（原 css L81-85, L476-479）→ 无；日期格式 `2026年8月11日 14:30` vs `yyyy/M/d HH:mm`；RAW/JPEG 候选状态文案、孤立 XMP 错误码翻译 → rawValue 直出；任务进度 phase 翻译 → progressMessage 原文；侧边栏 76px 图标栏+4px 指示条 vs 200px 文字侧栏；离线角标 黑底70% vs 红底85%；星级文本色 vs 橙色。注：FilterBar/FilterBuilder 原始版亦为无引用死代码，不列入缺失。

### 11.2 SessionDetail 外壳 + Gallery + ControlCenter

**对齐良好**：justified 布局算法逐行等价（含单测）、搜索拉满链、selection 语义、resize 重排。

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| C1 状态胶囊（健康色点+队列计数+最近同步+12s 轮询+事件刷新） | index.tsx L136；C1StatusCapsule.tsx 全 | 完全缺失 | 待做（控制中心仅 syncCard 静态计数） |
| 会话头索引进度条 + 失败重试 + 权威计数三态文案（含 "≥" 截断语义） | index.tsx L158-188；indexProgress.ts L32-64 | Gallery 头无；控制中心仅静态数字 + rawValue 枚举 | 已完成 |
| 控制中心 Action Inbox（7 类聚合、固定优先级、失败任务 ≤3 行） | ControlCenter/index.tsx L127-154；workspace-view.ts L70-169 | 完全缺失；推荐卡直接显示 `recommendedNext.action` 原始枚举字符串 | 已完成 |
| 三硬阶段进度条 + 软标记 | ControlCenter/index.tsx L100-125 | 仅文本数值 | 已完成 |
| 推荐下一步 6 态完整映射 | workspace-view.ts L210-276 | 仅字符串 contains 猜页签（`retry_jobs` 无法路由） | 已完成 |
| 事件驱动刷新 + 30s/3s 轮询兜底 | useWorkspaceStatus.ts L10-49；index.tsx L86-106 | 控制中心无轮询、无自动刷新，仅手动"刷新"按钮 | 已完成 |
| 访问会话自动触发 metadata.scan（5s 节流） | index.tsx L52-61 | 缺失（需手动点扫描索引） | 待做（控制中心有手动按钮） |
| Lightbox 滚轮缩放（0.5–5x）/ ←/→ 键盘翻页 / 相邻图预加载 | Lightbox.tsx L46-57, L78-95 | 均缺失（仅手势/按钮/Esc） | 待做（越界保护已补，见 11.13） |
| 错误码 i18n | utils/errors.ts | 裸码直显 | 已完成 |

**P1/P2**：缩略图尺寸按设置 256/1024/2048 vs 固定 512；搜索 useDeferredValue 即时 vs 300ms 防抖（注释为有意差异）；布局变矮时 scrollTop 钳制 → 无；单元格 hover 阴影/提亮、图片 contain 留边 vs fill 裁切；选择栏 primary 实底白字 vs accent 6% 淡底；返回语义 控制中心→Dashboard vs →Gallery。原生更强项：Gallery 失败态+重试、Lightbox 元数据 4 项、离线徽标、控制中心 jobsCard 内联任务列表。

### 11.3 Culling / Duplicates（原生版最薄弱页）

**P0 缺口（效率级缺失）**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| 三栏工作台布局（工具条/查看器/胶片条/左侧评分区） | Culling.tsx L1175-1686；Culling.module.css L10-19 | 单列 ScrollView 表单 + 网格；查看器降级为弹出 sheet | 待做（11.11 自述保留） |
| 键盘快捷键：0-5 评分、P/空格保留、X 拒绝、U 待定、←/→ 翻页、Cmd+Z 撤销重做 | Culling.tsx L1109-1149 | 全无 | 已完成 |
| 胶片条（±50 虚拟化窗口、Cmd/Ctrl/Shift 多选、状态叠加层） | L1491-1579 | 完全缺失 | 待做（11.11 自述保留） |
| 多条件组合筛选（星级+颜色+状态+冲突+未审） | L1720-1817 | 单一 FilterMode 枚举，星级/颜色维度缺失 | 已完成 |
| 批量评分/批量颜色（作用于选中集） | L828-906, L1587-1652 | 仅批量 pickState | 已完成 |
| 相似度组对比池（对比同组成员而非连续照片） | L675-691 | L1084 固定相邻照片 | 已完成 |
| 人脸中心对齐平移（faceAlign） | L208-213, L229 | 仅放大，不对准 | 已完成 |
| 内嵌查看器滚轮缩放 + 双击复位 + 缩放百分比 | L1311-1375 | sheet 内无滚轮/双击 | 已完成 |
| culling:sync-status 事件订阅 + rAF 合帧 → 局部 patch | L612-632, L707-724 | 无事件；每次更新后整页 6 接口重拉，选择状态丢失 | 已完成 |
| 预览预加载（后 8 张大图） | L699-705 | 无 | 已完成 |
| 浏览位置恢复（refetch 后 loadUntilPhoto） | L486-514 | 无 | 已完成 |
| "保留当前/保留所选，拒绝其余" + 自动跳到下一组 | L991-1091, L1653-1682 | 仅"只保留第一张" | 已完成 |
| 加载中/空列表/无工作区引导态 | L1151-1173 | 无渲染（isLoading 存在未渲染，空列表空白） | 已完成 |
| Duplicates：推荐徽章（best-member 评分） | Duplicates.tsx L68-75, L128-131 | 无 | 已完成 |
| Duplicates：成员上限 12 + 展开/折叠 | L10, L77-79, L135-145 | 全部渲染 | 已完成 |
| Duplicates：三档预设（2/4/7）+ 0-10 滑块 | L309-343 | Stepper 1...16（范围语义不一致） | 已完成 |
| Duplicates：100 组分页 + 加载更多 | L11, L291-296, L406-416 | 全量一次性渲染 | 已完成 |
| 错误码本地化 | utils/errors.ts | 原始描述直出 | 已完成 |

**P1/P2**：自动前进开关、主视图 1/2/4 对比与 faceAlign 开关、导航组跳转、联动变体提示；同步按钮条件显隐（written>0/synced>0）→ 常显；评分/颜色当前值高亮、快捷键小字标注 → Menu 无反馈；Duplicates 成员文件大小、Tab 计数徽标、本地 patch 更新（每次整页重拉）；样式：胶片缩略图 122px 双高亮、42px 决策大按钮、28px 颜色圆钮、浮动冲突面板 → 全部无。

### 11.4 Export / Jobs

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| Export 实时进度（逐文件 current/total/文件名、百分比、进度条、"Preparing export..."） | Export.tsx L131-158, L334-346；export.ipc.ts L141-163 | 完全无进度 UI，仅 isWorking 禁按钮；底层进度数据其实已写 DB（SessionCommandRouter L500-507） | 已完成 |
| Jobs 自动刷新（有活跃任务 2s 条件轮询） | Jobs/index.tsx L32-41 | 一次性 .task + 手动刷新；JobService.setProgressSink 存在但宿主从未接线 | 已完成 |
| 命名变量提示 + 实时命名预览（{date}/{time}/{counter}...） | Export.tsx L160-166, L286-293 | 仅一个文本框 | 已完成 |
| 预览空间不足红色警告 | Export.tsx L320-325 | 无 | 已完成 |
| 错误码→文案（EXPORT_*/CANCELLED） | utils/errors.ts | 裸码直显 | 已完成 |
| Jobs 状态/类型/阶段本地化（"取消中"/"metadata.scan"/progressMessage） | index.tsx L11-26；utils/progress.ts | rawValue 直出 | 已完成 |
| Jobs 加载态 | index.tsx L85-86 | isLoading 未渲染 | 已完成 |

**P1/P2**：默认导出格式 original vs jpeg；原图格式下应隐藏水印/最长边控件（原生提交即报 EXPORT_ORIGINAL_NO_TRANSFORM——UI 可达的运行时错误）；水印默认 opacity 0.5/字号 24/滑块 0.1–1 vs 0.65/"32"/0.05–1；naming counterStart/dateFormat 默认值未传；JPEG 质量滑块 vs 文本框；目录为空按钮禁用 vs 提交时报错；历史折叠 + 计数；清空已完成精确禁用（阶段证据排除）；空态虚线框；尝试次数显示；工作区名称 vs id 前缀；样式：Jobs 表格列对齐 vs 流式卡片、28px 圆角进度条 vs 系统细条、sticky 毛玻璃操作栏 vs 无。

### 11.5 Similarity

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| C1 同步状态机（syncState 视图 + loadMetadata/confirmSync/cleanup 三按钮门控 + 禁用 hints + 状态文案 + 事件刷新） | c1-sync-controls.ts 全；index.tsx L696-719, L834-843, L905-937 | 三个无门控按钮；reload+confirm 合并成一步，丢失 ack 语义；误点清理可能破坏写回备份 | 已完成 |
| XMP 写回预览明细（before→after 关键词、新建/更新、共享照片数、外部冲突标记、来源、50 条+more） | index.tsx L882-904 | 仅 6 条"文件名：关键词" | 已完成 |
| 失败项明细列表（路径 + 翻译错误码） | WritebackReport.tsx L56-70 | 无（仅重试按钮） | 已完成 |
| 空分组空态 + 加载中态 | index.tsx L634-640, L1010 | 无 | 已完成 |
| culling:sync-status 事件驱动刷新 | index.tsx L715-719 | 无 | 已完成 |
| 中文逗号关键词分隔（"，" 不生效，真实缺陷） | index.tsx L721-724 | SimilarityViewModel L482 仅英文逗号 | 已完成 |

**P1/P2**：写回结果三色统计卡 → 单行文本；busy 文案 → 无；关键词/选择变化时清空旧写回结果 → 不清（旧结果残留误判风险）；结果替换时重置展开/滚动状态 → 仅 onAppear；代表缩略图 64×64 r10 → 56×56 r4；网格 70vh → 固定 520；页面 1040px 居中 → 全宽；滑块自定义 → 系统 Slider；进度 1s 轮询替代推送（可接受）；分析/取消按钮 pending 态缺失。原生更强项：写回确认对话框、清理确认对话框（原始版直接执行）。

### 11.6 Persons / FaceKeywording

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| FaceKeywording 三步状态机 + 步骤条 + "分析完成才可进审核"门控 | FaceKeywording/index.tsx L26-56 | 单页堆叠，无门控（分析未完成也可点写回） | 已完成 |
| 分析实时进度（jobs:progress → 相位文案 + current/total + 进度条） | StepAnalyze.tsx L17-42, L130-155 | 无任何进度反馈（阻塞 await waitForResult） | 已完成 |
| 分析断点恢复（挂载查 jobs.list 恢复 running 态） | StepAnalyze.tsx L101-125 | 无（重进页面分析状态丢失） | 已完成 |
| 模型缺失引导（警示条 + 打开设置） | StepAnalyze.tsx L78-97, L219-229 | 无 | 已完成 |
| 审核角色筛选条 + "前往人脸审核"携带 `?role=` 预筛选 | StepReview.tsx L45-51；PersonDetail.tsx L161 | role 丢失（RootView L160 只传 sessionId） | 待做 |
| 审核 100/批分页 + 加载更多 | StepReview.tsx L13, L55-59, L174-184 | 一次性渲染全部簇 | 已完成 |
| 写回统计卡（3 项）+ 簇级预览 + XMP 前后对比（前 50 项） | StepWriteback.tsx L125-185 | 仅一行摘要 + 前 8 行；FaceKwWritebackBridge 字段已全量搬运，缺的只是 UI | 已完成 |
| 写回失败明细 + 错误码翻译 | WritebackReport.tsx L56-70 | 仅计数 | 已完成 |
| 清理备份门控（确认同步后才可清理） | StepWriteback.tsx L212 | 无条件可点 | 已完成 |
| Persons 空态/无结果态/加载态 | Persons/index.tsx L54-102 | 均缺失 | 已完成 |
| Persons 错误静默：actionError 被赋值但 View 无渲染点 | PersonDetail.tsx L74, L97, L108 | PersonsViewModel.swift L107, L118, L129 → 无 UI | 已完成 |

**P1/P2**：eps 范围 0.3–0.95 vs Stepper 0.1...2（超 1 触发 FACE_EPS_INVALID）；默认 minSamples=2 vs 原版 3；簇卡 2×2 拼贴+绑定徽章、成员置信度/序号、合并目标下拉 → 单缩略图/手输编号；预设三档 + 高级折叠面板 → 裸 Stepper；人物卡片封面网格 → 列表行；详情头像/阈值 → 无；样式：步骤胶囊、统计卡 tabular-nums、选中 ring 光环 → 无。

### 11.7 Settings / C1HealthPanel

**P0 缺口**

| 功能 | 原始位置 | 原生现状 | 状态 |
|---|---|---|---|
| C1 健康面板整体（四层预检 + ✓/✗ 徽标 + 重新检测按钮 + 错误提示） | C1HealthPanel.tsx 全；c1-health.ts L76-140 | 仅一行"已连接：进程探测"文本；错误直接显示 `C1_NOT_RUNNING` | 已完成 |
| 写回队列 6 格计数 + 12s 轮询 + 最近同步时间 + 命令耗时 | C1HealthPanel.tsx L17-33, L47-77, L116-155 | 无 | 部分完成（面板+四层预检已做；6 格/最近同步时间占位，见 11.11 ②） |
| 模型下载（横幅 + 进度 + 阶段翻译 + 失败态） | index.tsx L369-392 | 全库无 download 命令 | 不适用（2.2 决议 Vision 无需模型资产，SessionCommandRouter:1422） |
| 人脸分析常规参数（3 滑块）+ 高级参数（3 滑块） | index.tsx L227-286, L457-512 | 无滑块；40 个原始 key 平铺 + 单 TextField 编辑 | 已完成 |
| 模型路径编辑 + 打开目录 + blur 重查 | index.tsx L326-367 | 路径不可编辑 | 已完成 |
| 5 分组 × 18 项的 label/描述/select 选项/数值 min-max | index.tsx L25-74, L604-651 | 丢失（内部键直接暴露可编辑） | 已完成 |
| 语言即时生效（i18n 全量 + 主进程菜单重建 + 系统语言回退） | index.tsx L186-194；settings.ipc.ts L38-46 | 假功能：仅持久化 + notice；菜单不重建；界面全部硬编码中文 | 部分完成（仅设置页联动，菜单/全应用未做，见 11.11 ①） |

**P1/P2**：立即保存 + dirty 提示 vs 逐 key 显式保存；250ms 防抖+失败回滚+重置门闩 → 无；折叠分区 + chevron 动画 → 常显；页面级 loading → 仅 modelCard 占位；后端 auto/manual 双态 + "恢复自动"链接 → 仅 Picker；卡片边框/阴影/14px 圆角、✓/✗ 徽标、队列 6 格网格、安装横幅 → 无。原生更强项：恢复默认 confirmationDialog、暗色模式跟随系统。

### 11.8 通用组件体系

| 组件 | 原始版 | 原生版 | 结论 | 状态 |
|---|---|---|---|---|
| Toast（4 类型/5s 自动消失/堆叠/×关闭/全局事件） | ToastStore.ts L17-29 | 无；两色常驻 banner | P0 | 已完成 |
| gather:notification 事件链 | App.tsx L79-89 | `GatherAppNotification.captureOneError` 已 post 但全工程无订阅者，导入失败静默丢失 | P0 | 已完成 |
| ErrorBoundary 崩溃兜底 | 路由级降级 UI + 重试 | 无（SwiftUI 崩溃即白屏） | P0 | 待做 |
| SliderInput（Settings 6 项数值） | 滑块+数字+clamp+step | 退化裸 TextField | P0 | 已完成 |
| Dialog/ConfirmDialog | 焦点陷阱/inert/遮罩点击关闭/Esc | sheet/confirmationDialog 系统级（遮罩点击不关闭） | P1 | 待做 |
| Lightbox | 滚轮缩放/键盘翻页/预加载/DPR | 按钮+捏合/Esc | P1 | 待做 |
| Badge 12 色状态表 | 独立色表 11px uppercase | 单色 capsule（5 会话状态） | P1 | 待做 |
| WritebackReport | 统计卡 + 失败项明细 | 计数文本 | P1 | 已完成 |
| ProgressBar | 8px 主色条 + 不确定态滑动动画 | 系统 ProgressView | P2 | 待做 |
| MetadataPanel / TemplatePicker | 原始版亦为无引用死代码 | 无 | P2（无实际影响） | 已完成 |
| PageShell | 路由切换滚动归零 | 保留滚动位置 | P2 | 待做 |
| Sidebar | 76px 图标栏 + 指示条 + hover + /sessions 下隐藏 + 当前会话快捷项 | 200px 文字侧栏 + ⌘0 开关 | P2 | 待做 |

### 11.9 全局性修复顺序（跨页面通用，建议先做）

1. **事件总线/推送接线**：把 `jobs:progress` / `culling:sync-status`（或 JobService.setProgressSink → NotificationCenter）接成 SwiftUI 可订阅通道，替代全手动刷新；受益页：Dashboard、ControlCenter、Gallery、Culling、Jobs、Export、Similarity、FaceKeywording。
2. **错误码/状态文案本地化层**：建 `GatherErrorCode → 中文文案` 映射（错误码、job type、job status、progress phase 四类约 60-80 键），在 `NativeCommandClient.message(for:)` 出口统一翻译；消除所有 rawValue 直显。
3. **设计 token 落地**：定义 `GatherTheme`（brandColor #a54d2a、背景、圆角、阴影、hover），替换 40+ 处内联 cornerRadius 与 30+ 处 controlBackgroundColor 重复。
4. **Toast 系统**：轻量全局 toast/banner 层（至少订阅 captureOneError），先解决"错误静默丢失"。
5. **轮询规范**：以 SimilarityViewModel 1s 轮询为范式下沉到 Jobs/Export/ControlCenter/FaceKeywording。

### 11.10 原生版最薄弱点 Top 汇总（subagent 共识）

1. **C1 集成层整体缺失**（导入预检门控、健康面板、同步状态机、状态胶囊）——产品核心闭环不可感知，且误清理有数据风险。
2. **Culling 工作台降级**（胶片条 + 快捷键 + 内嵌查看器 + 批量操作 + 实时同步反馈全无）——挑片核心效率场景不可用。
3. **控制中心从决策引擎降级为数据展示页**（Action Inbox、阶段条、推荐下一步映射全无，且把枚举字符串当文案）。
4. **无事件/推送机制**（全页面退化为手动刷新/局部轮询）。
5. **错误静默与假功能**：Persons actionError 无 UI、captureOneError 无订阅者、语言切换只改自己、中文逗号不生效。

### 11.11 修复轮限制与后续待办（2026-08-12）

> 9 个并行 subagent 分域实施 + 全局设施落地，测试全绿。以下为各域汇报的数据源
> 限制与未做项，作为下一轮输入。

| 域 | 限制 / 未做项 |
|---|---|
| Similarity | C1 同步状态机的 ack 状态无路由查询命令，以本地标记近似（服务端 requireReloadAck 兜底）；建议后续在 SessionCommandRouter 接线 c1:sync-state 查询 |
| Settings | ① 语言切换仅设置页文案联动，应用菜单未随 ui_language 重建（GatherAppDelegate.installMenu 需提取为可重建入口）；② C1 健康面板写回队列 6 格与最近同步时间依赖未接线的 c1:sync-state；③ 其余页面仍硬编码中文（全应用 i18n 未做） |
| Dashboard | 预检 automationAuthorized/documentOpen 为 osascript 探测近似；C1 队列/同步状态未上卡片（原版仅胶囊有） |
| Culling | 键盘焦点机制仅编译级验证，真机若按钮点击后快捷键失效需调整 focusable 策略；胶片条（filmstrip）与内嵌主视图查看器仍未重建（工作台布局差异保留）；culling:sync-status 实时推送仍无（事件总线只覆盖 jobs） |
| 通用 | GatherTheme 设计 token（品牌色 #a54d2a/暖米底/圆角/阴影/hover）未落地（P2）；Lightbox 滚轮缩放/键盘翻页/预加载、Dialog 遮罩点击关闭、Badge 12 色表、ErrorBoundary 等价物、PageShell 滚动归零、侧边栏形态（P2）未做；全应用 i18n 未做 |

### 11.12 一致性审计轮（2026-08-12，第二轮）

> 5 个只读审计 subagent 逐域核对服务契约/TS 基线后，4 个修复 subagent 分域落地。
> gather-app 90/90（含新增 GatherLocalization/GatherEventCenter/GatherToast 9 项测试）
> + gather-core 760/760 全绿。已修复清单：

| 严重度 | 问题 | 修复 |
|---|---|---|
| HIGH | FaceKw 写回链路 5 命令（unbind/preview/writeback/confirm_sync/confirm_cleanup/cleanup）经 executeAsync 路由无分支 → NOT_IMPLEMENTED 不可用 | SessionCommandRouter.executeAsync 补 6 个 fkw 分支（与同步侧同参数校验/服务调用） |
| HIGH | c1SyncStatus 事件死通道（postC1SyncStatusChange 无调用点，Culling/ControlCenter/Similarity 事件刷新空转） | makeDefault 接线 metadataSyncCoordinator.eventSink → 广播；Culling 另补同步状态轮询兜底 |
| MED | Similarity 写回/预览传草稿 threshold vs TS result.stats.threshold（SIM_THRESHOLD_NO_RESULTS 风险） | 新增 writebackThreshold 取结果档位，三处调用点统一 |
| MED | Culling 相似度分组范围被单组化（未选组空页+自动选第一组）；跨页选择被第一页取交截断 | 未选组发全量请求（服务端 buildSimilarityClause(nil) 已支持）；loadedPhotoIds 全集取交 |
| MED | C1 单文件导入 sourcePath 未 sanitize（索引器可能监控整个父目录）；入队失败无回滚（半成品会话） | 复用 SessionService.sanitizeSessionSourcePath；enqueue 失败 deleteSession 回滚 |
| MED | 裸错误码直显（Dashboard/Gallery/Library/Similarity 4 处 message(for:)） | 统一 GatherLocalization.errorText 出口 |
| MED | Gallery/Library 打开即快照（无事件刷新） | onReceive(jobTerminal) + 500ms 防抖刷新（Gallery 按 sessionId 过滤） |
| MED | Settings C1 健康每 12s 全量重探测（持续向 C1 发 Apple Event）vs TS 仅挂载+手动 | 改为单次检测+手动重检；timedOut 判定移到 notAuthorized 前（TS errors.ts 优先级） |
| LOW×12 | Culling 插值 bug「(photoId)」/rawValue 直显×4（pickState/冲突字段/导航组类型/候选状态）；对比池回退路径；jumpToNextGroup 向后；快捷键 busy 防护；质量错误 jobErrorMessage；FaceKw 裸码×2/0 簇 phase 回退；Duplicates 阈值 0...10/标点；Persons select 静默/删除文案/标题/死代码；ControlCenter default→done/detail nil；标点混用；C1 错误码 3 个补表 | 全部落地 |

**遗留**（记录在案，未修）：Similarity 同步状态为模块级 vs TS 会话级聚合（服务端兜底无数据风险）；retry_jobs 由"跳任务中心"改为"逐个重试"（有意差异，文案已注明）；fkw 键盘焦点需真机验证；c1:sync-state 查询命令仍未接线（Settings 队列 6 格/最近同步时间占位）。

### 11.13 第三轮扫描（2026-08-12）

> 5 个只读审计 subagent（Gallery/Lightbox 算法、Export/Jobs 行为、并发与生命周期、
> 测试覆盖、文案与台账漂移）+ 5 个修复 subagent 分域落地。gather-app 90/90 +
> gather-core 760/760 全绿。另校准 §11.1-11.8 台账 10 处状态（审计发现 9 处
> "已完成"与代码/自述遗留矛盾）。

| 严重度 | 问题 | 修复 |
|---|---|---|
| HIGH | Gallery Lightbox 陈旧 index 越界崩溃（事件刷新缩水 photos 后 `photos[index]`） | 按 photo.id 定位/消失即关闭/safe 下标/`Array.subscript(safe:)`；Lightbox 打开期间事件刷新改为"跳过重排+关闭后补刷" |
| HIGH | CullingViewerView 陈旧 index 越界崩溃（质量分析完成/刷新缩回 500 条） | `@State index` → `currentPhotoId` 按 id 重定位、越界 guard、move 钳制 |
| HIGH | 会话切换后 Gallery/Similarity 新 VM 永不加载（opacity 常驻 + `.task` 仅首帧） | `.task(id: sessionId)` + `.onChange(of: sessionId)` 双触发 + VM init 兜底（loadIfNeeded 幂等） |
| HIGH | 缩略图主线程同步解码（RAW 100-800ms 卡 UI、无并发上限） | `Task.detached(.utility)` 后台解码 + DispatchSemaphore(4) 限流（对齐 thumbnail_concurrency）；NSCache 键含 size/preview |
| MED | Gallery 布局缓存键过弱（同 count 复用错位行）/行宽超算 32px/缩略图硬编码 512 vs 设置分桶 256/1024/2048/reload 与在途链式拉取竞态滞留 loading/fetchTask 死代码 | 键加数据哈希+数据变化失效；行宽 -32；读 thumbnail_size 分桶；reload 先 cancel fetchTask + phase 兜底；[weak self] |
| MED | Similarity/Dashboard 轮询在隐藏时持续（stop 无调用点）；Similarity pollProgress 永不退出；adoptResult last-writer-wins | RootView onChange 离开/回来显式 stop/start（Dashboard 加 isVisible 钩子）；30 轮无活跃退出；resultRequestID 结果代防过期覆盖 |
| MED | Culling 加载更多按钮抢焦（快捷键静默失效无恢复）；颜色菜单英文裸值；拆分按钮 UUID 直显；try? 吞错×6（同步状态/辅助查询/写回解码） | 补 nonFocusable；颜色中文表；按钮显文件名；lastSyncError 字段 + 解码失败不再假报成功 |
| MED | Export 空水印报错 vs TS 静默；freeSpace=-1 误报空间不足；无"准备中"态；错误明细 10→3 条；maxDimension 小数截断 | 空文本不发 watermark；freeSpace>=0 门控+未知显示；preparing 卡片；prefix(3)；parseInt 语义截断 |
| MED | Jobs hasClearableHistory 仅计 succeeded（漏 failed/cancelled/interrupted）；事件刷新 4 次/秒 | 基于全部 jobs 四态+阶段证据排除；1s 最小间隔合并 |
| MED | ControlCenter 加载/空态缺失；FaceKeywording isLoading 未渲染（误显空态）+"打开设置自动下载模型"空头指引 | 加载指示+空态引导；isLoading 渲染；模型文案改中性 |
| LOW×8 | Similarity 相位文案重复实现→统一 GatherLocalization；adoptTier/listSimilarityJobs/refreshSyncState try? 补反馈；Persons 搜索/加载省略号+删除确认插名+reloadAndSelect 吞错；Culling 方向键 .repeat；FaceKw/ControlCenter/Persons 文案统一 | 全部落地 |
| 台账 | 头部 81/81 vs 11.12 90/90 不一致；9 处"已完成"与代码/遗留矛盾（C1 胶囊、自动扫描、Lightbox 键盘滚轮、胶片条、role 筛选、模型下载、队列 6 格、菜单重建、全应用 i18n） | 头部标注轮次；10 处状态改为 待做/部分完成/不适用（Vision 决议无模型下载） |

**遗留**：Lightbox 滚轮缩放/←→ 键盘/相邻预加载、胶片条与三栏工作台、C1 状态胶囊、role 预筛选、c1:sync-state 查询接线（Settings 队列 6 格/最近同步时间占位）、全应用 i18n 与菜单语言重建（以上仍为待做）；测试缺口：8 个 VM（Culling/FaceKw/Export/Duplicates/Jobs/Settings/Persons/SessionControl）与 executeAsync 路由层无直接测试（已列 P0-P3 补测优先级，未执行）。

### 11.14 第四轮扫描（2026-08-12）

> 6 个只读审计 subagent（应用外壳、第三轮修复验证、gather-core 服务层首审、命令面
> 完整性、SwiftUI 视图模式、文案统一清单）+ 5 个修复 subagent 分域落地。
> gather-app 92/92（+2：importCompleted 通知、深链大小写）+ gather-core 765/765
> （+5：waitForResult 竞态/claim 覆盖/index_seq/controller 泄漏/{time} 格式）。

| 严重度 | 问题 | 修复 |
|---|---|---|
| HIGH | JobService.waitForResult 注册竞态（takeCompletedResult 与 appendWaiter 之间任务完成 → 等待者挂满 60 分钟超时） | 检查+注册并入同一把锁（registerWaiterOrTakeCompletedResult）；补确定性测试 |
| HIGH | SimilarityService 校验失败后 controller 泄漏（registerController 先于校验 → 会话永久 SIM_ANALYSIS_RUNNING 直到重启） | 校验移到注册之前；注释注明"有意修复，与 TS 差异"；补测试 |
| P1 | Gallery Lightbox refreshDeferredWhileLightbox 永不消费（onClose 绕过 sheet setter → 补刷丢失+标志泄漏） | 抽 closeLightbox() 共用；onChange 兜底 |
| P1 | PhotoThumbnailView 复用竞态（image 不随 cacheKey 重置→旧图闪烁；detached 解码无 key 校验→短暂错图） | 缓存未命中先清 image/failed；写回前校验启动时捕获的 key |
| P1 | RootView 隐藏页控件可聚焦/可达（opacity 不挡 VoiceOver/Tab，隐藏 TextField 截走 Culling 快捷键） | 五个常驻页加 .accessibilityHidden(!isVisible) |
| MED×6 | ① cancelScope 排队取消结果被 drain notClaimable 覆盖 → claim 失败先查 hasCompletedResult；② IndexerService 取消后 index_seq 不 bump → 终态统一 bump（含取消/失败路径）；③ ExportService {time} 12h AM/PM vs 预览 24h → 固定 HH-mm-ss；④ session.create 忽略 filepaths/truncatedImport + source 默认 folder≠manual → 补 addPhotos 返回 {session,failedFiles,added,skipped}、默认 manual；⑤ export options 解码错误英文散文 → EXPORT_PARAMS_INVALID；⑥ Cmd+Shift+I/深链导入成功后无导航/反馈 → importCompleted 通知（userInfo sessionId/failedCount/addedCount）+ RootView 订阅导航+失败 Toast；Cmd+O 无图分支先切页 | 全部落地（各补测试） |
| P2×8 | Culling 查看器关闭焦点恢复；lastSyncError 独立提示位；Similarity 清理/确认同步补 confirmationDialog、双路加载幂等守卫、pollProgress 失败轮不误退；Dashboard 任务行 progressMessage 本地化；fkw.writeback async 非法 items 对齐 FKW_ITEMS_INVALID；workspace.status 参数 required；Persons alert→confirmationDialog；FaceKw/Duplicates 惰性列表；无障碍 label×4；GatherLocalization 省略号统一 | 全部落地 |
| 文案 | P0×11（9 处错误横幅「操作失败：」前缀 + 本地化省略号）+ P1×16（引号/括号全角、暂无同步状态等） | 全部落地 |
| 台账 | 命令面 118/118 校准（旧 "~107/118"、culling 20/fkw 11/metadata 5 过时）；引导区新增校准段 | 已修 |

**遗留（新增记录）**：gather-core 三服务（MetadataSyncCoordinator/WritebackService/CaptureOneSyncState）无直接测试且 XMP 磁盘路径零覆盖；LOW 若干（eventSink 无锁读写、waitForIdle 无超时、markIntroduced try? 吞错、'cancelling' 重启重跑、sim.analyze dedupeKey 字面默认、fkw 取消窄窗口、MetadataSyncCoordinator 唤醒延迟、GatherAppDelegate 白名单已并入共享常量 RAWDecoder.supportedExtensions）；P2 台账项：Similarity 同步状态模块级 vs 会话级、fkw 键盘焦点需真机验证。
