# Gather 架构重写方案

日期：2026-07-11
分支：`refactor/architecture-redesign`

---

## 一、重写背景

### 1.1 现状

当前应用在生产环境中未真实落地，没有用户数据依赖和向后兼容约束。这给了我们**从零设计架构**的自由。

### 1.2 当前痛点

| 问题 | 说明 |
|------|------|
| 三套语言 | Python（后端） + TypeScript（前端） + AppleScript（Capture One），上下文切换成本高 |
| 两套 IPC | Electron IPC（renderer ↔ main） + stdin/stdout MessagePack（main ↔ Python），复杂度翻倍 |
| Python 包体积 | mediapipe + numpy + scipy + dlib + Pillow + lxml + Python runtime ≈ **300-500MB** |
| 单体 SessionManager | 975 行，集 5 个 Repository 职责于一身 |
| 重复模式 | FaceKeywordingService（954 行）和 SimilarityService（693 行）的 progress/cancel/thread 逻辑大量重复 |
| 前后端类型不同步 | Python dataclass → `to_dict()`，TypeScript interface 手动再写一遍 |
| 无框架前端 | 纯 vanilla TypeScript + innerHTML 拼接，组件化程度低 |
| 全局 CSS | `style.css` 1323 行，无样式隔离 |

### 1.3 重写目标

1. **单一语言**：全栈 TypeScript，消除跨语言心智负担
2. **单一 IPC**：Electron IPC 直接调用，取消 stdin/stdout 协议层
3. **包体积**：~200MB，无 Python runtime
4. **干净架构**：Repository + Service + Command Pattern
5. **前端 React**：组件化、类型安全、CSS Modules
6. **自动化测试**：Vitest + Playwright

---

## 二、总体架构

```
┌──────────────────────────────────────────────────────────────┐
│                    Electron                                  │
│                                                              │
│  ┌─────────── Main Process (Node.js / TypeScript) ────────┐  │
│  │                                                         │  │
│  │  ipcMain.handle('gather:command', cmd, params)          │  │
│  │         │                                                │  │
│  │  ┌──────┴────────────────────────────────────────┐      │  │
│  │  │           CommandRegistry                      │      │  │
│  │  │  ├── SessionCommands                          │      │  │
│  │  │  ├── FaceKwCommands                           │      │  │
│  │  │  └── SimilarityCommands                       │      │  │
│  │  └──────┬────────────────────────────────────────┘      │  │
│  │         │                                                │  │
│  │  ┌──────┴───────┐ ┌──────────┐ ┌──────────────────┐     │  │
│  │  │  Services     │ │  DB /   │ │  Capture One     │     │  │
│  │  │  ├─ session   │ │  Repos  │ │  AppleScript     │     │  │
│  │  │  ├─ face-kw   │ │         │ │                  │     │  │
│  │  │  └─ similarity│ │ SQLite  │ │                  │     │  │
│  │  └───────────────┘ └─────────┘ └──────────────────┘     │  │
│  │                                                         │  │
│  └─────────────────────────────────────────────────────────┘  │
│                    ↑ contextBridge (preload)                   │
│  ┌─────────── Renderer Process (React) ────────────────────┐  │
│  │                                                         │  │
│  │  React 18 + TypeScript + Vite + CSS Modules             │  │
│  │                                                         │  │
│  │  Pages: Dashboard / Similarity / Face Keywording        │  │
│  │  State:  Zustand (client) + TanStack Query (server)    │  │
│  │  Router: React Router v6                               │  │
│  │                                                         │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 2.1 核心变化

| 变化 | 旧方案 | 新方案 |
|------|--------|--------|
| 后端语言 | Python | TypeScript（Node.js main process） |
| 通信方式 | stdin/stdout MessagePack | Electron IPC |
| 进程数量 | Electron + Python 两个进程 | 单一 Electron 进程 |
| 人脸检测 | mediapipe (Python) | ONNX Runtime + RetinaFace |
| 人脸编码 | face_recognition (dlib) | ONNX Runtime + ArcFace |
| 推理加速 | 无 | CoreML EP（M 芯片 ANE/GPU）+ Apple Accelerate（CPU 回退）|
| dHash | imagehash (Python) | 纯 JS 实现 |
| DBSCAN | scikit-learn | 纯 JS 实现 |
| XMP 写 | lxml (Python) | fast-xml-parser (JS) |
| 缩略图 | Pillow (Python) | sharp (Node.js) |
| 数据库 | sqlite3 (Python) | better-sqlite3 (Node.js) |
| 打包体积 | ~500MB+ | ~200MB |

### 2.2 包体积明细

| 组件 | 体积 | 说明 |
|------|------|------|
| Electron (Chromium) | ~150MB | 不可压缩 |
| `onnxruntime-node` | ~15MB | ONNX Runtime（macOS arm64 预编译包自带 CoreML EP）|
| `sharp` | ~8MB | 图像处理 |
| `better-sqlite3` | ~2MB | SQLite |
| JS 源码 + npm deps | ~3MB | fast-xml-parser 等纯 JS 库 |
| ONNX 模型文件 | ~20-40MB | RetinaFace（检测）+ ArcFace（编码）|
| React bundle (min) | ~200KB | Vite build |
| **合计** | **~198-218MB** | |

---

## 三、目录结构

```
gather/
├── package.json                  # monorepo root
│
├── desktop/                      # Electron 应用
│   ├── package.json
│   ├── tsconfig.json
│   ├── vite.config.ts            # Vite for renderer
│   ├── electron-builder.yml
│   │
│   ├── src/
│   │   ├── main/                 # Main process (后端)
│   │   │   ├── index.ts          # 入口：创建窗口 + 注册 IPC
│   │   │   ├── ipc/              # IPC handlers
│   │   │   │   ├── registry.ts          # CommandRegistry
│   │   │   │   ├── session.ipc.ts
│   │   │   │   ├── similarity.ipc.ts
│   │   │   │   ├── face-kw.ipc.ts
│   │   │   │   └── thumbnail.ipc.ts
│   │   │   │
│   │   │   ├── services/         # 业务逻辑
│   │   │   │   ├── session/
│   │   │   │   │   └── session.service.ts
│   │   │   │   ├── similarity/
│   │   │   │   │   ├── similarity.service.ts
│   │   │   │   │   ├── hash-computer.ts    # dHash (纯 JS)
│   │   │   │   │   └── cluster-engine.ts   # DBSCAN (纯 JS)
│   │   │   │   ├── face-kw/
│   │   │   │   │   ├── face-kw.service.ts
│   │   │   │   │   ├── face-detector.ts    # ONNX Runtime + 可选模型
│   │   │   │   │   ├── face-encoder.ts     # onnxruntime + ArcFace
│   │   │   │   │   └── face-clusterer.ts   # DBSCAN
│   │   │   │   ├── writeback/
│   │   │   │   │   └── writeback.service.ts
│   │   │   │   └── xmp/
│   │   │   │       └── xmp-writer.ts       # fast-xml-parser
│   │   │   │
│   │   │   ├── db/               # 数据访问层
│   │   │   │   ├── database.ts            # better-sqlite3 连接
│   │   │   │   ├── migrations.ts          # schema 迁移
│   │   │   │   └── repositories/
│   │   │   │       ├── session.repo.ts
│   │   │   │       ├── photo.repo.ts
│   │   │   │       ├── face.repo.ts
│   │   │   │       └── writeback.repo.ts
│   │   │   │
│   │   │   ├── capture-one.ts    # AppleScript 桥（保留）
│   │   │   │
│   │   │   └── utils/            # 通用工具
│   │   │       ├── progress.ts   # 进度推送
│   │   │       └── validation.ts
│   │   │
│   │   ├── preload/
│   │   │   └── index.ts          # contextBridge（安全模型保留）
│   │   │
│   │   └── renderer/             # React 前端
│   │       ├── main.tsx          # 入口
│   │       ├── App.tsx           # 根组件
│   │       ├── router.tsx        # React Router
│   │       ├── index.html
│   │       │
│   │       ├── pages/
│   │       │   ├── Dashboard/
│   │       │   ├── Similarity/
│   │       │   └── FaceKeywording/
│   │       │
│   │       ├── components/       # 共享 UI 组件
│   │       │   ├── Layout/
│   │       │   ├── Toast/
│   │       │   ├── Dialog/
│   │       │   ├── ProgressBar/
│   │       │   ├── Loading/
│   │       │   ├── Badge/
│   │       │   └── WritebackReport/
│   │       │
│   │       ├── stores/           # Zustand
│   │       │   ├── sessionStore.ts
│   │       │   ├── similarityStore.ts
│   │       │   └── faceKwStore.ts
│   │       │
│   │       ├── api/              # API 调用层
│   │       │   ├── client.ts
│   │       │   ├── session.ts
│   │       │   ├── similarity.ts
│   │       │   ├── faceKw.ts
│   │       │   └── types.ts
│   │       │
│   │       ├── hooks/            # 自定义 hooks
│   │       │   ├── useEngine.ts
│   │       │   ├── usePoll.ts
│   │       │   └── useProgress.ts
│   │       │
│   │       └── styles/
│   │           ├── global.css
│   │           └── variables.module.css
│   │
│   └── resources/                # 静态资源
│       ├── models/               # ONNX 模型文件（检测+编码）
│       │   ├── face-detection/   # 可放多个模型自由切换
│       │   │   ├── retinaface.onnx
│       │   │   ├── yolov8-face.onnx
│       │   │   └── mtcnn.onnx
│       │   └── face-encoder/
│       │       └── arcface.onnx
│       └── icons/
│
├── packages/
│   └── shared/                   # 前后端共享类型
│       ├── package.json
│       ├── tsconfig.json
│       └── src/
│           ├── index.ts
│           ├── protocol.ts       # IPC 命令、响应、事件类型
│           └── constants.ts      # 全局常量
│
└── tests/
    ├── e2e/                      # Playwright E2E
    │   ├── fixtures/
│   │   ├── dashboard.spec.ts
│   │   ├── similarity.spec.ts
│   │   ├── face-keywording.spec.ts
│   │   ├── navigation.spec.ts
│   │   └── engine-recovery.spec.ts
│   │
│   └── vitest/                   # Vitest 单元测试
│       ├── main/
│       │   ├── services/
│       │   ├── db/
│       │   └── ipc/
│       └── renderer/
│           ├── components/
│           ├── stores/
│           └── api/
```

---

## 四、IPC 设计

### 4.1 通信模式

```typescript
// packages/shared/src/protocol.ts
// 所有命令和响应的类型定义

export type Command =
  | { type: 'session.create'; params: SessionCreateParams }
  | { type: 'session.list'; params: Record<string, never> }
  | { type: 'session.delete'; params: { sessionId: string; confirmed: boolean } }
  | { type: 'fkw.analyze'; params: { sessionId: string } }
  | { type: 'fkw.bind'; params: { sessionId: string; clusterId: string; roleName: string; keywords: string[] } }
  | { type: 'sim.analyze'; params: { sessionId: string; threshold?: number; minGroupSize?: number } }
  // ... 完整类型见 packages/shared/src/protocol.ts

export type Event =
  | { type: 'progress'; data: ProgressData }
  | { type: 'engine:status'; data: EngineStatus }
  | { type: 'c1:import-trigger'; data: C1ImportData }
```

```typescript
// desktop/src/main/ipc/registry.ts
import { ipcMain } from 'electron'
import type { Command } from '@gather/shared'

type CommandHandler = (params: unknown) => Promise<unknown>

export class CommandRegistry {
  private handlers = new Map<string, CommandHandler>()

  register(type: string, handler: CommandHandler): void {
    this.handlers.set(type, handler)
  }

  execute(type: string, params: unknown): Promise<unknown> {
    const handler = this.handlers.get(type)
    if (!handler) throw new Error(`Unknown command: ${type}`)
    return handler(params)
  }
}

// 注册所有 handler
export function registerAllIpcHandlers(registry: CommandRegistry): void {
  ipcMain.handle('gather:command', async (_event, cmd: string, params: unknown) => {
    return registry.execute(cmd, params)
  })

  ipcMain.handle('gather:get-version', () => app.getVersion())
}
```

```typescript
// desktop/src/renderer/api/client.ts
import type { Command } from '@gather/shared'

async function sendCommand<T>(cmd: string, params?: Record<string, unknown>): Promise<T> {
  const result = await window.gather.sendCommand(cmd, params ?? {})
  return result as T
}
```

### 4.2 IPC 通道一览

| Channel | 方向 | 用途 |
|---------|------|------|
| `gather:command` | Renderer → Main (invoke) | 执行命令并等待结果 |
| `gather:event` | Main → Renderer (send) | 推送事件（进度、状态变更） |
| `gather:get-version` | Renderer → Main (invoke) | 获取应用版本 |
| `gather:select-files` | Renderer → Main (invoke) | 打开文件选择对话框 |
| `gather:select-directory` | Renderer → Main (invoke) | 打开目录选择对话框 |

---

## 五、后端详细设计（Main Process）

### 5.1 Service 拆分

| 当前（需要重写的旧代码） | 新 Service | 职责 |
|-------------------------|-----------|------|
| `SessionManager` (975 行) | `SessionService` + 4 个 Repository | 会话 CRUD、照片管理 |
| `FaceKeywordingService` (954 行) | `FaceKwService` + `FaceDetector` + `FaceEncoder` + `FaceClusterer` | 人脸检测、编码、聚类、绑定 |
| `SimilarityService` (693 行) | `SimilarityService` + `HashComputer` + `ClusterEngine` | dHash 计算、聚类 |
| `BaseService` (51 行) | 删除，职责分散到各 Service | - |
| `SessionService` (63 行) | 保留并增强 | 会话业务逻辑 |
| 无 | `WritebackService`（新增） | 统一写回生命周期 |
| 无 | `XmpWriter`（新增） | XMP 文件读写 |

### 5.2 Repository 模式

```typescript
// desktop/src/main/db/repositories/session.repo.ts
export class SessionRepository {
  get(id: string): Session | null
  create(name: string, source: ImportSource): Session
  delete(id: string): boolean
  list(): Session[]
  updateName(id: string, name: string): boolean
  updateStatus(id: string, status: SessionStatus): void
}

// desktop/src/main/db/repositories/photo.repo.ts
export class PhotoRepository {
  getBySession(sessionId: string): Photo[]
  getByIds(ids: string[]): Photo[]
  addPhotos(sessionId: string, filepaths: string[], source: string): AddPhotoResult
  countBySession(sessionId: string): number
  countBySessions(sessionIds: string[]): Map<string, number>
}

// desktop/src/main/db/repositories/face.repo.ts
export class FaceRepository {
  saveObservations(sessionId: string, observations: FaceObservation[]): number[]
  getObservations(sessionId: string): FaceObservation[]
  saveClusters(sessionId: string, clusters: FaceCluster[]): number[]
  getClusters(sessionId: string, includeMembers?: boolean): FaceCluster[]
  updateBinding(clusterId: number, roleName: string, keywords: string[]): void
  deleteBinding(clusterId: number): void
  mergeClusters(sourceId: number, targetId: number, members: FaceClusterMember[]): void
}

// desktop/src/main/db/repositories/writeback.repo.ts
export class WritebackRepository {
  saveItems(sessionId: string, items: WritebackItem[]): number[]
  getItems(sessionId: string, module?: string, status?: string): WritebackItem[]
  updateStatus(itemId: number, status: string, error?: string): void
  getFailedCount(sessionId: string): number
  deleteItems(sessionId: string): void
}
```

### 5.3 Session 状态机

```
DRAFT ──[addPhotos]──> PHOTOS_LOADED ──[startAnalysis]──> ANALYZING ──[done]──> REVIEW
                            │                                      │
                            │                        [cancel/fail]──┘
                            │
                            └──[delete]──> (deleted)

REVIEW ──[startAnalysis]──> ANALYZING（重新分析）
REVIEW ──[writeback]──> (写回中) ──[confirmSync]──> COMPLETED

> 注：DRAFT、PHOTOS_LOADED、REVIEW、COMPLETED 状态下均可执行 delete 操作，直接进入 (deleted) 终态。ANALYZING 状态需先 cancel 再 delete。
```

```typescript
enum SessionStatus {
  DRAFT = 'draft',
  PHOTOS_LOADED = 'photos_loaded',
  ANALYZING = 'analyzing',
  REVIEW = 'review',
  COMPLETED = 'completed',
}

enum AnalysisStatus {
  IDLE = 'idle',
  RUNNING = 'running',
  DONE = 'done',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
}

enum WritebackStatus {
  IDLE = 'idle',
  RUNNING = 'running',
  DONE = 'done',
  PARTIAL = 'partial',
  CLEANED = 'cleaned',
}
```

### 5.4 SQLite Schema 概览

```sql
-- sessions: 会话
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  analysis_status TEXT NOT NULL DEFAULT 'idle',
  writeback_status TEXT NOT NULL DEFAULT 'idle',
  import_source TEXT NOT NULL DEFAULT 'unknown',
  photo_count INTEGER NOT NULL DEFAULT 0,
  failed_writeback_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- photos: 照片
CREATE TABLE photos (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  filepath TEXT NOT NULL,
  filename TEXT NOT NULL DEFAULT '',
  checksum TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending',
  metadata TEXT NOT NULL DEFAULT '{}',
  result TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- face_observations: 人脸观察结果
CREATE TABLE face_observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  bbox_x REAL NOT NULL, bbox_y REAL NOT NULL,
  bbox_w REAL NOT NULL, bbox_h REAL NOT NULL,
  embedding BLOB NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0
);

-- face_clusters: 人脸聚类
CREATE TABLE face_clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  label TEXT NOT NULL DEFAULT '',
  member_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'unbound'
);

-- face_cluster_members: 聚类成员
CREATE TABLE face_cluster_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  photo_id TEXT NOT NULL,
  photo_path TEXT NOT NULL,
  bbox TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  observation_id INTEGER
);

-- role_bindings: 角色绑定
CREATE TABLE role_bindings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL UNIQUE REFERENCES face_clusters(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  role_name TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]'
);

-- similarity_hashes: dHash 缓存
CREATE TABLE similarity_hashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  photo_id TEXT NOT NULL REFERENCES photos(id),
  hash_hex TEXT NOT NULL
);

-- similarity_results: 相似度分析结果
-- 注：groups_json 存储完整分组数据。当前 session 规模（单次 <1000 张）下 JSON 体积可控（<1MB）。
-- 若未来需要按组查询，可拆分为 similarity_groups + similarity_group_members 两张表。
CREATE TABLE similarity_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  groups_json TEXT NOT NULL,
  stats_json TEXT NOT NULL DEFAULT '{}',
  param_threshold INTEGER NOT NULL,
  param_min_group_size INTEGER NOT NULL DEFAULT 2,
  created_at TEXT NOT NULL
);

-- writeback_items: 写回审计追踪
CREATE TABLE writeback_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  module TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  xmp_path TEXT NOT NULL DEFAULT '',
  backup_path TEXT NOT NULL DEFAULT '',
  xmp_status TEXT NOT NULL DEFAULT 'pending',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 1,
  last_attempt_at TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);

-- 索引
CREATE INDEX idx_photos_session ON photos(session_id);
CREATE INDEX idx_photos_filepath ON photos(filepath);
CREATE INDEX idx_face_observations_session ON face_observations(session_id);
CREATE INDEX idx_face_observations_photo ON face_observations(photo_id);
CREATE INDEX idx_face_clusters_session ON face_clusters(session_id);
CREATE INDEX idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
CREATE INDEX idx_face_cluster_members_session ON face_cluster_members(session_id);
CREATE INDEX idx_similarity_hashes_session ON similarity_hashes(session_id);
CREATE INDEX idx_similarity_hashes_photo ON similarity_hashes(photo_id);
CREATE INDEX idx_similarity_results_session ON similarity_results(session_id);
CREATE INDEX idx_writeback_items_session ON writeback_items(session_id);
CREATE INDEX idx_writeback_items_photo ON writeback_items(photo_id);
```

> **连接配置**：启用 WAL 模式（`PRAGMA journal_mode=WAL`），允许并发读不阻塞写，适合分析过程中 renderer 轮询读取 + main 持续写入的场景。同时启用 `PRAGMA synchronous=NORMAL`、`PRAGMA cache_size=-64000`（64MB 缓存）。

### 5.5 人脸检测与编码（ONNX Runtime，macOS CoreML 加速）

检测和编码统一使用 ONNX Runtime。macOS arm64 预编译包已包含 CoreML Execution Provider，
推理可自动利用 M 芯片的 ANE（神经网络引擎）和 GPU 加速。CPU 作为回退层。

实测 M1 上 RetinaFace 单张 ~15-30ms（CoreML）、ArcFace 单人脸 ~3-5ms，对一个 session 数百张照片的场景足够。

模型文件放在 `resources/models/` 目录下，用户可通过替换文件切换检测模型。

```
resources/models/
├── face-detection/
│   ├── retinaface.onnx      # 推荐：平衡精度和速度
│   ├── yolov8-face.onnx     # 备选：更快
│   └── mtcnn.onnx           # 备选：轻量
└── face-encoder/
    └── arcface.onnx         # 128-d embedding
```

模型选择机制：

```typescript
// models/config.ts — 模型选择配置
export interface ModelConfig {
  detection: 'retinaface' | 'yolov8-face' | 'mtcnn'
  encoding: 'arcface'
}

const DEFAULT_MODEL_CONFIG: ModelConfig = {
  detection: 'retinaface',
  encoding: 'arcface',
}
```

> **设计要点**：
> - **懒加载**：ONNX 模型（~20-40MB）不在应用启动时加载，仅在首次调用人脸检测/编码功能时初始化，避免拖慢启动速度
> - **单例复用**：`detectionSession` 和 `encodingSession` 为模块级单例，初始化一次后跨请求复用
> - **管线化处理**：detector 和 encoder 之间用生产者-消费者模式衔接——detector 输出人脸区域后立即送入 encoder，无需等待全部检测完成

```typescript
// desktop/src/main/services/face-kw/face-detector.ts
// ONNX Runtime CPU 推理，所有检测模型共用同一接口
import ort from 'onnxruntime-node'

let detectionSession: ort.InferenceSession | null = null

export async function initializeFaceDetection(modelName: string): Promise<void> {
  const modelPath = path.join(
    app.getAppPath(), 'resources', 'models', 'face-detection', `${modelName}.onnx`
  )
  // macOS: CoreML EP 优先（ANE/GPU），CPU 回退
  // 其他平台: CPU only
  const isMac = process.platform === 'darwin'
  const providers = isMac ? ['coreml', 'cpu'] : ['cpu']
  detectionSession = await ort.InferenceSession.create(modelPath, { executionProviders: providers })
}

export interface DetectedFace {
  bbox: [number, number, number, number]  // [x, y, w, h]
  confidence: number
  landmarks?: number[][]
}

export async function detectFaces(preprocessedImage: Float32Array, modelName: string): Promise<DetectedFace[]> {
  if (!detectionSession) throw new Error('Face detection model not initialized')
  // 模型通用接口：
  // 1. sharp 读取图像 → 预处理为模型需要的输入格式
  // 2. detectionSession.run(feeds)
  // 3. 后处理：解析模型输出的 bbox + score + landmarks
  // 不同模型的输出格式不同，后处理逻辑不同
  const feeds = { input: new ort.Tensor('float32', preprocessedImage, [1, 3, 640, 640]) }
  const results = await detectionSession.run(feeds)

  // 根据模型类型解析结果（不同模型输出格式不同）
  return parseDetectionOutput(modelName, results)
}
```

```typescript
// desktop/src/main/services/face-kw/face-encoder.ts
// 编码模型固定为 ArcFace，输出 128-d embedding
import ort from 'onnxruntime-node'

let encodingSession: ort.InferenceSession | null = null

export async function initializeFaceEncoder(): Promise<void> {
  const isMac = process.platform === 'darwin'
  const providers = isMac ? ['coreml', 'cpu'] : ['cpu']
  encodingSession = await ort.InferenceSession.create(
    path.join(app.getAppPath(), 'resources', 'models', 'face-encoder', 'arcface.onnx'),
    { executionProviders: providers }
  )
}

export async function encodeFace(alignedFace: Float32Array): Promise<number[]> {
  if (!encodingSession) throw new Error('Face encoder not initialized')
  const feeds = { input: new ort.Tensor('float32', alignedFace, [1, 3, 112, 112]) }
  const results = await encodingSession.run(feeds)
  return Array.from(results.output.data as Float32Array)
}
```

```typescript
// desktop/src/main/services/face-kw/face-clusterer.ts
// 纯 JS DBSCAN 实现
export function dbscan(
  embeddings: number[][],
  eps: number,
  minPts: number
): { clusters: number[][]; noise: number[] } {
  const labels = new Array(embeddings.length).fill(-1) // -1 = unvisited
  let clusterId = 0

  for (let i = 0; i < embeddings.length; i++) {
    if (labels[i] !== -1) continue
    const neighbors = regionQuery(embeddings, i, eps)
    if (neighbors.length < minPts) {
      labels[i] = 0 // noise
      continue
    }
    clusterId++
    expandCluster(embeddings, labels, i, neighbors, clusterId, eps, minPts)
  }

  // 整理结果
  const clusters: number[][] = []
  const noise: number[] = []
  for (let i = 0; i < labels.length; i++) {
    if (labels[i] === 0) noise.push(i)
    else {
      while (clusters.length <= labels[i]) clusters.push([])
      clusters[labels[i]].push(i)
    }
  }
  return { clusters: clusters.filter(c => c.length > 0), noise }
}
```

> **DBSCAN 性能与优化**：
>
> 本项目中 DBSCAN 用于两个场景，瓶颈完全不同：
>
> | 场景 | 向量维度 | 距离度量 | 单次比较 | O(n²) 规模上限 | 推荐优化 |
> |------|---------|---------|---------|---------------|---------|
> | dHash 相似度聚类 | 64-bit hash | Hamming（XOR + popcount） | ~1 CPU 指令 | ~50,000 张（~1s） | Multi-Index Hashing（纯 JS） |
> | 人脸 Embedding 聚类 | 128-d float32 | 余弦相似度（归一化后点积） | ~128 次乘加（~0.2μs） | ~3,000 人脸（~1s） | HNSW 近似最近邻 |
>
> **dHash 优化 — Multi-Index Hashing**：将 64-bit hash 拆分为 4 段 16-bit 子串，构建 4 个倒排索引。查询时仅比较共享 ≥1 段子串的候选对，比较次数从 n² 降至 n·k。纯 JS 实现，零额外依赖，50,000 张 < 30ms。
>
> **Embedding 优化 — HNSW**：构建分层可导航小世界图，近似最近邻搜索 O(log n)。推荐 `hnswlib-node` npm 包（~3MB 原生绑定），8,000 个 128-d 向量聚类从 ~7s 降至 ~150ms。备选方案：预计算距离矩阵（`Float32Array` + Worker 并行），无需原生依赖。
>
> **实现路径**：Phase 1 用暴力 O(n²)（< 5000 规模完全足够），后续按实际规模按需引入 Multi-Index / HNSW。

### 5.6 dHash 计算（纯 JS）

```typescript
// desktop/src/main/services/similarity/hash-computer.ts
import sharp from 'sharp'

export async function computeDHash(imagePath: string, hashSize = 8): Promise<string> {
  // 1. 读取图像，转为灰度，缩放到 (hashSize + 1) x hashSize
  const { data, info } = await sharp(imagePath)
    .grayscale()
    .resize(hashSize + 1, hashSize, { fit: 'fill' })
    .raw()
    .toBuffer({ resolveWithObject: true })

  // 2. 计算每行相邻像素差值
  const hash: number[] = []
  for (let row = 0; row < hashSize; row++) {
    for (let col = 0; col < hashSize; col++) {
      const left = data[row * (hashSize + 1) + col]
      const right = data[row * (hashSize + 1) + col + 1]
      hash.push(left < right ? 1 : 0)
    }
  }

  // 3. 转为十六进制字符串
  const bits = hash.join('')
  const hex: string[] = []
  for (let i = 0; i < bits.length; i += 4) {
    hex.push(parseInt(bits.slice(i, i + 4), 2).toString(16))
  }
  return hex.join('')
}
```

> **性能说明**：dHash 计算 O(1) × N，瓶颈在 `sharp` 图像解码 I/O，Worker Pool 并行可缓解。相似度聚类的 DBSCAN 优化策略见 5.5 节。

### 5.7 统一写回生命周期

```
Plan → Preview → Execute → Review Failures → Retry → Confirm Sync → Cleanup (or Defer)
```

```typescript
// desktop/src/main/services/writeback/writeback.service.ts
export class WritebackService {
  constructor(
    private writebackRepo: WritebackRepository,
    private xmpWriter: XmpWriter,
  ) {}

  async preview(sessionId: string, module: string, options: WritebackOptions): Promise<WritebackPreview>
  async execute(sessionId: string, module: string, items: WritebackItem[]): Promise<WritebackResult>
  async retryFailed(sessionId: string, module: string): Promise<WritebackResult>
  async confirmSync(sessionId: string): Promise<void>
  async cleanup(sessionId: string): Promise<CleanupResult>
  deferCleanup(sessionId: string): void  // 标记延迟清理
  getPendingCleanup(): string[]  // 返回待清理的 session 列表
}
```

> Similarity 和 Face Keywording 模块的 writeback.* 命令均委托 WritebackService 统一执行写回逻辑，各模块只负责调用 preview/execute/retryFailed 方法。

### 5.8 并发模型（Worker Threads）

人脸检测、dHash 计算、DBSCAN 聚类均为 CPU 密集型操作，不可阻塞 Electron 主进程。采用 `worker_threads` 将计算卸载到 Worker 线程。

```
Main Process (调度)          Worker Threads (计算)
     │                              │
     ├── dHash 批量计算 ───────────> Worker Pool (os.cpus().length 线程)
     ├── 人脸检测+编码 ───────────> Worker (单线程, ONNX)
     └── DBSCAN 聚类 ────────────> Worker (单线程)
```

- **dHash 批量计算**：Worker Pool 线程数 = `os.cpus().length`，每线程处理 N/C 张图片。瓶颈在 `sharp` 图像 I/O，并行可接近线性加速
- **人脸检测+编码**：ONNX Runtime 推理在 Worker 线程执行，CoreML EP 利用 ANE/GPU，避免阻塞主进程 UI 响应
- **DBSCAN 聚类**：dHash 聚类（Hamming 距离）和人脸 Embedding 聚类（余弦相似度）均在 Worker 线程执行，具体优化策略见 5.5 节

所有 Worker 通过 `parentPort.postMessage()` 回传结果、`worker.on('message')` 接收进度。主进程负责汇总结果、写入数据库、向 renderer 推送进度事件。

**各阶段耗时预估**（M1，单次 session 2000 张照片，约 1000 张人脸）：

| 阶段 | 操作 | 单线程 | 并行 | 瓶颈 |
|------|------|--------|------|------|
| 照片导入 | sharp 缩略图 + SQLite | 3-5s | 3-5s | I/O |
| dHash 计算 | sharp 缩放 + hash × 2000 | 8-15s | 2-3s (8线程) | I/O |
| 相似度聚类 | Hamming 距离 + DBSCAN | < 5ms | < 5ms | 计算（可忽略） |
| 人脸检测 | RetinaFace ONNX × 2000 | 30-60s | 30-60s | ONNX |
| 人脸编码 | ArcFace ONNX × 1000 | 3-5s | 3-5s | ONNX |
| 人脸聚类 | 128-d DBSCAN × 1000 | ~100ms | ~100ms | 计算（可忽略） |
| XMP 写回 | 文件读写 × 2000 | 10-30s | 10-30s | 磁盘 I/O |

**并行策略**：dHash 计算与人脸检测可并行执行（无数据依赖），将串行总耗时从 60-95s 压缩至最长单阶段 ~30-60s。

**取消机制**：所有长时间操作统一使用 `AbortController`：

```typescript
// desktop/src/main/services/face-kw/face-kw.service.ts
export class FaceKwService {
  private abortController: AbortController | null = null

  async analyze(sessionId: string, signal?: AbortSignal): Promise<void> {
    this.abortController = new AbortController()
    const mergedSignal = signal
      ? AbortSignal.any([signal, this.abortController.signal])
      : this.abortController.signal

    for (const photo of photos) {
      if (mergedSignal.aborted) throw new CancelError()
      // ...
    }
  }

  cancel(): void {
    this.abortController?.abort()
  }
}
```

Worker 线程通过 `worker.postMessage({ type: 'cancel' })` 接收取消指令，在处理循环中定期检查。

**进度节流**：renderer 通过 `gather:event` 接收进度推送。主进程对进度事件做节流（`throttle(fn, 100)`），最多每秒推送 10 次，避免频繁 IPC 通信影响 UI 响应。

### 5.9 Capture One 集成

Capture One 通过 AppleScript 桥与主进程交互，保留 `desktop/src/main/capture-one.ts` 模块。C1 集成设计为独立模块，不直接依赖 Service 层，通过事件总线与 Session 模块解耦。

**通信方式**：

| 方向 | 方式 | 说明 |
|------|------|------|
| Main → C1 | `child_process.exec('osascript ...')` | 执行 AppleScript，如写入元数据后通知 C1 刷新 |
| C1 → Main | 文件监听 / HTTP 回调 | C1 操作（如导入照片）触发主进程事件 |

**集成场景**：

| 场景 | 方向 | 触发时机 |
|------|------|---------|
| 照片导入 | C1 → Main | 用户在 C1 中导入照片后，触发 `c1:import-trigger` 事件 |
| 元数据刷新 | Main → C1 | 写回完成后，通知 C1 重新读取 XMP |
| 获取选集 | C1 → Main | 获取 C1 当前选中的图片列表，用于快速创建 session |

---

## 六、前端详细设计

### 6.1 路由

```tsx
// desktop/src/renderer/router.tsx
<Routes>
  <Route element={<PageShell />}>
    <Route path="/" element={<Dashboard />} />
    <Route path="/similarity/:sessionId" element={<Similarity />} />
    <Route path="/face-kw/:sessionId" element={<FaceKeywording />} />
  </Route>
</Routes>
```

### 6.2 状态管理

```typescript
// stores/sessionStore.ts — Zustand
interface SessionStore {
  currentSessionId: string | null
  currentPage: PageName
  engineStatus: 'connecting' | 'ready' | 'disconnected'
  setSession: (id: string | null) => void
  navigate: (page: PageName, sessionId?: string) => void
  setEngineStatus: (status: EngineStatus) => void
  reset: () => void
}
```

```typescript
// stores/similarityStore.ts
interface SimilarityStore {
  groups: SimilarityGroup[]
  ungrouped: { path: string }[]
  selectedGroupIds: Set<string>
  threshold: number
  minGroupSize: number
  analysisStatus: 'idle' | 'running' | 'done' | 'error'
  // actions
  setGroups: (groups: SimilarityGroup[]) => void
  toggleGroup: (id: string) => void
  setThreshold: (v: number) => void
  reset: () => void
}
```

```typescript
// stores/faceKwStore.ts
interface FaceKwStore {
  step: 1 | 2 | 3
  clusters: ClusterData[]
  bindings: Record<number, BindingState>
  selectedClusterId: number | null
  mergeMode: boolean
  mergeSourceId: number | null
  analysisStatus: 'idle' | 'running' | 'done'
  // actions
  selectCluster: (id: number) => void
  bindCluster: (id: number, role: string, keywords: string[]) => void
  skipCluster: (id: number) => void
  enterMergeMode: (sourceId: number) => void
  mergeCluster: (targetId: number) => void
  reset: () => void
}
```

### 6.3 TanStack Query 轮询

```typescript
// hooks/useSimilarityResult.ts
export function useSimilarityResult(sessionId: string) {
  return useQuery({
    queryKey: ['similarity', 'result', sessionId],
    queryFn: () => similarityApi.getResult(sessionId),
    enabled: !!sessionId,
    refetchInterval: (query) =>
      query.state.data?.analysisStatus === 'running' ? 1000 : false,
  })
}
```

### 6.4 组件结构

| 页面 | 子组件 |
|------|--------|
| Dashboard | `SessionCard`, `SessionFilter`, `SessionSummary` |
| Similarity | `AnalysisPanel`, `GroupGrid`, `GroupCard`, `WritebackPanel` |
| Face Keywording | `StepAnalyze`, `StepReview` (ClusterGrid + ClusterDetail + TagEditor), `StepWriteback` |

| 共享组件 | 说明 |
|---------|------|
| `Layout/Sidebar` | 导航侧边栏 |
| `Layout/PageShell` | 页面容器 |
| `Toast/ToastContainer` | 通知容器 |
| `Toast/Toast` | 通知条目 |
| `Dialog/Dialog` | 通用模态框 |
| `Dialog/ConfirmDialog` | 确认对话框 |
| `ProgressBar` | 进度条 |
| `Loading` | 加载状态 |
| `Badge` | 徽章 |
| `WritebackReport` | 写回报告 |

---

## 七、质量控制（全 TypeScript 如何保证质量）

### 7.1 类型安全体系

单一语言的最大优势：前后端**共享类型定义**，不需要代码生成或手动同步。IPC 边界处的 `params` 为 `unknown` 类型，需在各 IPC handler 入口通过 discriminated union 收窄类型，或使用运行时校验（如 zod）确保类型安全。

```
packages/shared/src/protocol.ts   ← 唯一的类型源头
        │
        ├── main/                 ← 直用（ipc handler 签名）
        └── renderer/             ← 直用（api client 签名）

// 示例：IPC handler 的类型安全
// main/ipc/session.ipc.ts
ipcMain.handle('gather:command', async (_event, cmd: string, params: unknown) => {
  // cmd 是 'session.create' | 'fkw.analyze' | ...（字面量联合类型）
  // 各 IPC handler 通过 discriminated union 在入口处收窄 params 类型
  const result = await registry.execute(cmd, params)
  return result  // 返回类型也由 cmd 确定
})

// renderer/api/client.ts
const session = await api.sendCommand('session.get', { sessionId: '...' })
// session 的类型自动推导为 SessionData
```

```jsonc
// tsconfig.json — 严格模式
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,   // 避免 undefined 隐患
    "exactOptionalPropertyTypes": true,  // 精确可选属性
    "noPropertyAccessFromIndexSignature": true,
    "forceConsistentCasingInFileNames": true,
    "isolatedModules": true
  }
}
```

> 注：`noUncheckedIndexedAccess: true` 下数组索引访问返回 `T | undefined`，DBSCAN 等底层算法代码中需使用非空断言（`!`）或在逻辑上保证索引有效，或在该文件局部放宽此选项。

### 7.2 测试金字塔

```
        ╱── Playwright E2E (5-8 个) ──╲         ← 关键用户路径
       ╱── Vitest 集成测试 (20-30 个) ──╲        ← Service + SQLite
      ╱── Vitest 单元测试 (100-200 个) ──╲       ← Repository / Service / 算法规格
```

#### Main Process 测试

| 测试对象 | 测试方式 | 数量预期 |
|---------|---------|---------|
| Repository | 对真实 SQLite 内存库执行 CRUD | 每个 repo 5-8 个 |
| Service | mock repository，验证业务逻辑 | 每个 service 8-10 个 |
| IPC handler | mock service，验证参数校验 + 响应 | 每个 handler 2-3 个 |
| 算法（dHash） | 已知输入 → 验证 hex 输出 | 3-5 个 |
| 算法（DBSCAN） | 已知 embedding → 验证聚类结果 | 5-8 个 |
| XMP 写回 | 写 → 读回 → 验证 XML 结构 | 5-8 个 |

```typescript
// test 示例：dHash 算法测试
test('computeDHash: identical images produce identical hash', async () => {
  const hash1 = await computeDHash('fixtures/photo-a.jpg')
  const hash2 = await computeDHash('fixtures/photo-a-copy.jpg')
  expect(hash1).toBe(hash2)
})

test('computeDHash: different images produce different hashes', async () => {
  const hash1 = await computeDHash('fixtures/photo-a.jpg')
  const hash2 = await computeDHash('fixtures/photo-b.jpg')
  expect(hash1).not.toBe(hash2)
})

// test 示例：DBSCAN 算法测试
test('dbscan: clusters known embeddings correctly', () => {
  const faceA = Array(128).fill(0)  // 相同人脸
  const faceB = Array(128).fill(1)  // 不同人脸
  const result = dbscan([faceA, faceA, faceA, faceB, faceB], 0.5, 2)
  expect(result.clusters).toHaveLength(2)
  expect(result.clusters[0]).toHaveLength(3)
  expect(result.clusters[1]).toHaveLength(2)
})
```

#### Renderer 测试

| 测试对象 | 测试方式 | 数量预期 |
|---------|---------|---------|
| 组件 | Testing Library 渲染 + 交互 | 每个组件 2-4 个 |
| Store | 直接调用 action，验证 state 变化 | 每个 store 3-5 个 |
| API client | mock window.gather，验证请求/响应 | 5-8 个 |

#### E2E 测试

```typescript
// Playwright: 完整用户路径
test('dashboard: create session, import photos, see it in list', async () => { ... })
test('similarity: full flow analyze -> review -> writeback', async () => { ... })
test('face-kw: 3-step workflow analyze -> review -> writeback', async () => { ... })
test('navigation: sidebar switching with unsaved state guard', async () => { ... })
```

### 7.3 CI 质量门禁

```yaml
# .github/workflows/ci.yml
jobs:
  quality:
    steps:
      - run: npm run typecheck        # tsconfig strict 检查
      - run: npm run lint             # ESLint
      - run: npm run format:check     # Prettier
      - run: npm run test:vitest      # 单元 + 集成测试（带覆盖率）
      - run: npm run build            # Vite + electron-builder
      - run: npx playwright test      # E2E 测试
```

### 7.4 运行时质量

| 机制 | 说明 |
|------|------|
| 结构化错误 | 所有 IPC handler 返回统一的 `{ ok, data?, error? }` 结构 |
| 前端错误边界 | React Error Boundary 捕获渲染异常 |
| 日志 | electron-log 写入文件，main + renderer 统一日志 |
| 崩溃恢复 | 分析中的 session 重启后标记 stale |
| 模型验证 | ONNX 模型加载失败时有明确用户提示 |
| 性能监控 | dHash/DBSCAN 耗时记录，超过阈值输出警告 |

---

## 八、重写阶段

### Phase 0：技术验证（PoC）

目标：验证核心技术栈在目标平台的可行性，降低 Phase 5（Face Keywording）的集成风险。

1. onnxruntime-node + CoreML EP 在 M1/M2/M3 上的推理链路验证
2. RetinaFace + ArcFace ONNX 模型加载、推理、结果验证
3. ArcFace 编码精度 vs dlib baseline 对比（LFW 数据集），确认偏差在可接受范围内
4. 若 CoreML EP 不可用，确认 CPU fallback 的性能是否满足需求

**验收标准**：

| 指标 | 目标 |
|------|------|
| RetinaFace 单张推理 | < 50ms（CoreML） |
| ArcFace 单人脸编码 | < 10ms（CoreML） |
| ArcFace 精度偏差 | < 2%（vs dlib baseline） |

### Phase 1：项目骨架 + 基础设施

目标：可运行的 Electron + React + Vite + SQLite

1. 初始化 monorepo（npm workspaces）
2. 搭建 Vite + React + TypeScript 构建
3. 搭建 Electron main process 入口
4. 搭建 better-sqlite3 + migrations
5. 搭建 IPC registry
6. 搭建 preload contextBridge
7. 配置 Vitest + Playwright

### Phase 2：共享组件 + Session 模块

1. 实现 Layout / Toast / Dialog / ProgressBar / Badge
2. 实现 SessionRepository + SessionService
3. 实现 session.* IPC handlers
4. 实现 Dashboard React 页面

### Phase 3：写回 + XMP 模块

1. 实现 XmpWriter（fast-xml-parser）
2. 实现 WritebackService
3. 实现 writeback.* IPC handlers
4. 实现 WritebackReport React 组件

### Phase 4：Similarity 模块

1. 实现 HashComputer（dHash 纯 JS）
2. 实现 ClusterEngine（DBSCAN 纯 JS）
3. 实现 SimilarityService
4. 实现 sim.* IPC handlers
5. 实现 Similarity React 页面

### Phase 5：Face Keywording 模块

1. 集成 onnxruntime-node + RetinaFace（人脸检测）
2. 集成 onnxruntime-node + ArcFace（人脸编码）
3. 实现 FaceClusterer（DBSCAN 纯 JS）
4. 实现 FaceKwService
5. 实现 fkw.* IPC handlers
6. 实现 Face Keywording React 页面

### Phase 6：Capture One 集成 + 收尾

1. 适配 AppleScript 桥到新架构
2. 完整 E2E 测试套件
3. 文档更新
4. electron-builder 打包配置

---

## 九、功能模块总览

| 模块 | 功能 | IPC 命令 |
|------|------|---------|
| Session | CRUD、导入照片、状态管理 | `session.create` / `.list` / `.get` / `.delete` / `.addPhotos` / `.update` |
| Similarity | dHash 分析、聚类、重聚类、写回 | `sim.analyze` / `.cancel` / `.result` / `.recluster` / `.previewWriteback` / `.writeback` / `.retryFailed` |
| Face KW | 人脸检测、编码、聚类、绑定、合并、写回 | `fkw.analyze` / `.cancel` / `.clusters` / `.bind` / `.unbind` / `.merge` / `.preview` / `.writeback` / `.confirmSync` / `.cleanup` |
| Writeback | 统一写回生命周期 | 由各模块调用 |
| System | 引擎健康、版本、文件对话框 | `engine.health` / `app.getVersion` / `app.selectFiles` |

---

## 十、风险与应对

| 风险 | 可能性 | 应对 |
|------|--------|------|
| onnxruntime-node macOS 兼容性 + CoreML EP 效果 | 低 | Phase 0 PoC：在 M1/M2/M3 上验证 CoreML 推理链路和性能 |
| ArcFace ONNX 精度 vs dlib baseline | 中 | Phase 0 用 LFW 数据集对比，偏差在可接受范围内则调整聚类阈值补偿 |
| sharp + onnxruntime 原生模块编译 | 低 | electron-rebuild 自动处理 |
| 重写周期过长 | 中 | 每个 Phase 交付可用的最小功能集 |
| AppleScript 桥适配 | 低 | 代码量小，最后阶段处理 |

---

## 十一、拒绝的方案

| 方案 | 理由 |
|------|------|
| Rust + Python sidecar | 包体积 ~500MB 不可控，三套语言维护成本高 |
| 全 Rust（无 Python） | 人脸检测 ONNX 替换风险高，团队招聘困难 |
| 现代化 Python | 两套语言+两套类型系统问题仍然存在 |
| Tauri + Rust 后端 | 需要 Rust 能力，AppleScript 桥适配复杂 |
| 保留当前架构小改 | 积累的技术债会持续拖慢开发 |

---

## 十二、性能设计

### 12.1 设计原则

| 原则 | 说明 |
|------|------|
| 不预设规模上限 | 当前 session 规模（<5000 张）的暴力方案已足够，但架构层面预留优化插槽 |
| 计算不进主进程 | 所有 CPU 密集型操作（图像处理、ONNX 推理、聚类）均在 Worker 线程 |
| Pipeline 优于 Loop | 生产者-消费者模式替代串行 for 循环，计算与 I/O 重叠 |
| 可缓存即持久化 | dHash、embedding 等计算结果存入 SQLite，重新分析时跳过已计算项 |
| 支持取消 | 所有长耗时 Service 接受 `AbortSignal`，用户可随时中断 |
| 懒加载 | ONNX 模型、React 页面均按需加载，不拖慢启动 |

### 12.2 Pipeline 处理模式

对比传统串行模式和 Pipeline 模式：

```
串行（❌）：for photo in photos:  load → compute → save → next
管线（✅）：Producer ──Queue──> Worker Pool ──Queue──> Collector
              │                    │                      │
         文件列表读取         计算(dHash/检测/编码)    批量写入DB
```

| 模块 | Producer | Worker | Collector |
|------|----------|--------|-----------|
| dHash 分析 | 从 SQLite 读取 photo 列表 | sharp 缩放 + hash 计算 | 批量 INSERT 到 similarity_hashes |
| 人脸检测 | 从 SQLite 读取 photo 列表 | ONNX 推理 | 批量 INSERT 到 face_observations |
| 人脸编码 | 从 face_observations 读取待编码人脸 | ONNX 推理 | 更新 face_observations.embedding |
| 写回 | 从 writeback_items 读取待写回项 | XMP 读写 | 更新 writeback_items.status |

Pipeline 优势：
1. **I/O 与计算重叠**：Worker 在计算时，Producer 可预读下一批数据
2. **背压控制**：Queue 有界，防止内存爆增
3. **可取消**：向 Queue 发送 poison pill 即可优雅终止所有 Worker

### 12.3 缓存策略

| 数据 | 存储位置 | 失效条件 |
|------|---------|---------|
| dHash | `similarity_hashes` 表，按 photo_id 唯一 | 原图文件内容变更（checksum 不一致） |
| Face embedding | `face_observations.embedding` BLOB 列 | 切换检测/编码模型时清空重建 |
| Thumbnail 缓存 | 系统临时目录（`app.getPath('temp')/gather-thumbnails/`） | 原图文件变更时重建 |
| ONNX Session | 模块级单例变量 | 切换模型文件时重新创建 |
| React 页面 | Vite code splitting（`React.lazy`） | 构建产物更新 |

### 12.4 取消机制

```
用户点击取消 → IPC 'sim.cancel' / 'fkw.cancel'
                    │
                    ▼
         Service.abortController.abort()
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
     主进程循环   Worker 1   Worker 2
   (检查signal) (检查message) (检查message)
          │         │         │
          └─────────┼─────────┘
                    ▼
         清理：标记 AnalysisStatus.CANCELLED
               丢弃未完成的计算结果
               回滚未提交的 DB 写入
```

### 12.5 进度推送

```
Worker ──进度──> Main Process ──throttle(100ms)──> Renderer
  │                    │                                │
  每处理完一批         聚合多个Worker进度                更新 ProgressBar
  就 postMessage      取最大值后推送                    （最多10次/秒）
```

- 主进程维护 `Map<sessionId, ProgressState>`，记录各模块当前进度
- 节流器确保 `gather:event` 最多每秒 10 次推送
- 前端 ProgressBar 组件通过 `requestAnimationFrame` 做动画平滑

### 12.6 内存管理

| 场景 | 策略 |
|------|------|
| 图像加载 | `sharp` 流式处理，不在内存中持有完整图像 Buffer，处理完立即释放 |
| dHash 计算 | Worker 每次处理单张图片，用完后 `sharp` 实例销毁 |
| Embedding 聚类 | 仅加载当前 session 的向量（128 × faces 个 float32 → 4KB/face），用完释放 |
| SQLite 查询 | 使用 `better-sqlite3` 的 `iterate()` 流式读取，避免大量结果集常驻内存 |
| React 组件 | 大列表使用虚拟滚动（`@tanstack/react-virtual`），仅渲染可视区域 |

### 12.7 启动优化

```
应用启动
  │
  ├── 1. Electron 窗口创建 ────────────── < 500ms
  ├── 2. SQLite 连接 + migration ──────── < 100ms
  ├── 3. React bundle 加载 ─────────────── < 500ms (Vite code split)
  ├── 4. Dashboard 渲染 ───────────────── < 200ms
  │
  └── 5. ONNX 模型（懒加载）────────────── 首次使用人脸功能时 1-2s
       ├── 检测模型加载                    ~800ms
       └── 编码模型加载                    ~400ms
```

- Dashboard、Similarity、FaceKeywording 三个页面独立 code split
- ONNX 模型文件在首次使用时流式读取，不阻塞启动
- `better-sqlite3` 使用单连接复用，不做连接池（SQLite 并发写瓶颈不在此）
