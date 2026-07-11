# Gather 架构重构方案

日期：2026-07-11
分支：`refactor/architecture-redesign`

---

## 一、重构目标

1. **前端引入 React**，终结 600-700 行模块级变量 + innerHTML 拼接模式
2. **Python 后端解耦**，拆分 975 行 SessionManager/954 行 FaceKeywordingService
3. **统一前后端类型**，消除 TypeScript 与 Python 之间 raw dict 数据流
4. **自动化测试覆盖**，用 Playwright E2E 替代 300 条手动测试清单
5. **消除 CSP unsafe-inline**，所有样式通过 CSS Modules / class 应用

---

## 二、前置条件（重构前必须达成）

1. 代码已提交或清理：当前分支从 `main` 创建，无未提交遗留变更
2. 所有现有测试通过：
   ```bash
   npm --prefix desktop test -- --runInBand
   uv run pytest
   ```
3. 团队成员确认本方案的分阶段策略，避免大爆炸式重构

---

## 三、总体架构

### 保留不改的部分

这些层已经设计良好，并且经过了生产验证：

| 层 | 文件 | 保留理由 |
|---|---|---|
| IPC 协议 | `python-bridge.ts` / `engine/protocol.py` | length-prefix + MessagePack 二进制协议高效可靠，重启退避机制完善 |
| 安全模型 | `preload/index.ts` / `main/index.ts` | contextIsolation / sandbox / ALLOWED_COMMANDS 校验 / deepSanitize |
| Python 引擎入口 | `engine/engine.py` | 整体保留但内部 dispatch 改为 Command Pattern |
| AppleScript 桥 | `capture-one.ts` | Capture One 集成逻辑稳定 |

### 需要重构的部分

```
┌──────────────────────────────────────────────────────────┐
│                    Electron Main Process                  │
│  index.ts → python-bridge.ts (keep) → engine.py (refactor)│
│         ↑                                          keep  │
│         │  contextBridge (keep)                          │
│         ↓                                               │
│  ┌─────────────── Renderer Process ───────────────────┐ │
│  │  React 18 + TypeScript + Vite + CSS Modules        │ │
│  │                                                     │ │
│  │  ┌─────────────────────────────────────────────┐   │ │
│  │  │  TanStack Query — 服务端状态（API 调用/轮询）  │   │ │
│  │  │  Zustand — 客户端状态（UI/导航/编辑中数据）    │   │ │
│  │  │  React Router v6 — 路由 + 导航守卫            │   │ │
│  │  └─────────────────────────────────────────────┘   │ │
│  │                                                     │ │
│  │  Pages: Dashboard / Similarity / Face Keywording    │ │
│  │  Components: Layout / Toast / Dialog / Progress     │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 前端与后端的约定边界

```
Renderer (React)         Main Process              Python Engine
─────────────────        ──────────────────        ──────────────
api/client.ts  ──send──> python-bridge.ts  ──stdin──> engine.py
                  <──event──                  <──stdout──
                         │                             │
                    contextBridge            CommandRegistry
                         │                             │
                    preload/index.ts       SessionRepository
                                           PhotoRepository
                                           FaceRepository
```

---

## 四、前端架构详细设计

### 4.1 目录结构

```
desktop/src/renderer/
├── main.tsx                     # React 入口，挂载 <App/>
├── App.tsx                      # 根组件：EngineProvider + Router + Sidebar
├── router.tsx                   # React Router 路由配置
│
├── pages/
│   ├── Dashboard/
│   │   ├── index.tsx            # 页面组件
│   │   ├── SessionCard.tsx      # 会话卡片
│   │   ├── SessionFilter.tsx    # 筛选器
│   │   └── index.module.css
│   ├── Similarity/
│   │   ├── index.tsx            # 页面组件（编排子组件）
│   │   ├── AnalysisPanel.tsx    # 分析控制面板
│   │   ├── GroupGrid.tsx        # 分组网格
│   │   ├── GroupCard.tsx        # 单个分组卡片
│   │   ├── WritebackPanel.tsx   # 写回面板
│   │   └── index.module.css
│   └── FaceKeywording/
│       ├── index.tsx            # 3 步工作流编排
│       ├── StepAnalyze.tsx      # 步骤 1：分析
│       ├── StepReview.tsx       # 步骤 2：审阅
│       ├── ClusterGrid.tsx      # 聚类网格
│       ├── ClusterDetail.tsx    # 聚类详情 + 标签编辑
│       ├── TagEditor.tsx        # 标签编辑器
│       ├── StepWriteback.tsx    # 步骤 3：写回
│       └── index.module.css
│
├── components/                  # 共享 UI 组件
│   ├── Layout/
│   │   ├── Sidebar.tsx
│   │   ├── PageShell.tsx
│   │   └── index.module.css
│   ├── ProgressBar/
│   │   ├── index.tsx
│   │   └── index.module.css
│   ├── Toast/
│   │   ├── ToastContainer.tsx
│   │   ├── Toast.tsx
│   │   └── index.module.css
│   ├── Dialog/
│   │   ├── Dialog.tsx
│   │   ├── ConfirmDialog.tsx
│   │   └── index.module.css
│   ├── Loading/
│   │   └── index.tsx
│   └── Badge/
│       ├── index.tsx
│       └── index.module.css
│
├── stores/                      # Zustand 状态管理
│   ├── sessionStore.ts          # 当前会话 + 导航
│   ├── similarityStore.ts       # 相似度页面状态
│   └── faceKwStore.ts           # 人脸关键词页面状态
│
├── api/                         # API 调用层
│   ├── client.ts                # 封装 window.gather.sendCommand
│   ├── session.ts               # session.* 命令
│   ├── similarity.ts            # sim.* 命令
│   ├── faceKw.ts                # fkw.* 命令
│   └── types.ts                 # API 类型定义
│
├── hooks/                       # 通用 hooks
│   ├── useEngine.ts             # Engine 连接/重启监听
│   ├── usePoll.ts               # 轮询（替代 utils/poll.ts）
│   └── useProgress.ts           # 进度监听
│
├── styles/
│   ├── global.css               # CSS Reset + 设计 Token
│   └── variables.module.css     # CSS 变量（可被 CSS Modules 导入）
│
├── utils/
│   ├── validation.ts            # isValidBase64 / clampInteger
│   ├── format.ts                # 格式化工具
│   └── dom.ts                   # 精简 DOM 工具（仅在不便用 React 的地方使用）
│
└── index.html                   # Vite 入口 HTML
```

### 4.2 路由设计 (React Router v6)

```tsx
// router.tsx
<Routes>
  <Route element={<PageShell />}>     // 统一 Layout + Sidebar
    <Route path="/" element={<Dashboard />} />
    <Route path="/similarity/:sessionId" element={<Similarity />} />
    <Route path="/face-kw/:sessionId" element={<FaceKeywording />} />
  </Route>
</Routes>
```

对比当前：

| 维度 | 当前 (hash + manual cleanup) | 重构后 (React Router) |
|---|---|---|
| URL 格式 | `#similarity` + sessionStorage | `/similarity/:sessionId` |
| 参数传递 | 全局变量 + sessionStorage | 路由参数 `useParams()` |
| 导航守卫 | 手动 `if` 检查 | `useBlocker()` |
| 生命周期 | registerCleanup / runCleanup | useEffect unmount / useBlocker |
| 导航触发 | navigate() 函数 | `<Link>` + `useNavigate()` |

### 4.3 状态管理 (Zustand)

#### sessionStore — 全局会话/导航状态

```typescript
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

#### similarityStore — 相似度页面状态

```typescript
interface SimilarityStore {
  sessionId: string
  groups: SimilarityGroup[]
  ungrouped: { path: string }[]
  stats: Record<string, number>
  analysisStatus: 'idle' | 'running' | 'done' | 'error'

  selectedGroupIds: Set<string>
  threshold: number
  minGroupSize: number

  startAnalysis: (sessionId: string) => void
  setGroups: (groups: SimilarityGroup[]) => void
  toggleGroup: (id: string) => void
  setThreshold: (v: number) => void
  reset: () => void
}
```

#### faceKwStore — 人脸关键词页面状态

```typescript
interface FaceKwStore {
  sessionId: string
  step: 1 | 2 | 3
  clusters: ClusterData[]
  bindings: Record<number, BindingState>
  skipped: Record<number, boolean>
  selectedClusterId: number | null
  mergeMode: boolean
  mergeSourceId: number | null
  analysisStatus: 'idle' | 'running' | 'done'

  selectCluster: (id: number) => void
  bindCluster: (id: number, role: string, keywords: string[]) => void
  skipCluster: (id: number) => void
  enterMergeMode: (sourceId: number) => void
  mergeCluster: (targetId: number) => void
  reset: () => void
}
```

**为什么用 Zustand 而非 React Context：**
- Zustand store 可在组件外使用（API layer 需要读写状态）
- 不需要 Provider 嵌套
- 内置 `subscribe`，可在 hook 之外监听变化（Engine restart 场景）
- DevTools 支持，方便调试

### 4.4 API 层

```typescript
// api/client.ts
import type { GatherAPI } from '@gather/shared'

declare global {
  interface Window {
    gather: GatherAPI
  }
}

async function sendCommand<T>(command: string, params?: Record<string, unknown>): Promise<T> {
  const response = await window.gather.sendCommand(command, params ?? {})
  if (!response.ok) {
    throw new ApiError(response.error)
  }
  return response.data as T
}

// api/similarity.ts
import { sendCommand } from './client'

export const similarityApi = {
  analyze: (sessionId: string, threshold: number, minGroupSize: number) =>
    sendCommand<{ analysis_id: string }>('sim.analyze', { session_id: sessionId, threshold, min_group_size: minGroupSize }),

  getResult: (sessionId: string) =>
    sendCommand<{ groups: SimilarityGroup[]; ungrouped: { path: string }[]; stats: Record<string, number> }>(
      'sim.get_result', { session_id: sessionId }
    ),

  recluster: (sessionId: string, threshold: number, minGroupSize: number) =>
    sendCommand<{ groups: SimilarityGroup[] }>('sim.recluster', { session_id: sessionId, threshold, min_group_size: minGroupSize }),

  previewWriteback: (sessionId: string, groupIds: string[], options: WritebackOptions) =>
    sendCommand<WritebackPreview>('sim.preview_writeback', { session_id: sessionId, group_ids: groupIds, options }),

  writeback: (sessionId: string, groupIds: string[], options: WritebackOptions) =>
    sendCommand<WritebackResult>('sim.writeback', { session_id: sessionId, group_ids: groupIds, options, confirmed: true }),

  retryFailed: (sessionId: string) =>
    sendCommand<WritebackResult>('sim.retry_failed_writeback', { session_id: sessionId }),
}
```

### 4.5 TanStack Query 管理服务端状态

对于需要轮询/缓存/重试的 API 调用，使用 TanStack Query：

```typescript
// hooks/useSimilarityResult.ts
import { useQuery } from '@tanstack/react-query'
import { similarityApi } from '../api/similarity'

export function useSimilarityResult(sessionId: string) {
  return useQuery({
    queryKey: ['similarity', 'result', sessionId],
    queryFn: () => similarityApi.getResult(sessionId),
    enabled: !!sessionId,
    refetchInterval: (query) =>
      query.state.data?.analysis_status === 'running' ? 1000 : false,
  })
}
```

对比当前轮询方式：

| 维度 | 当前 (createPollLoop + isDone check) | 重构后 (TanStack Query) |
|---|---|---|
| 声明周期管理 | 手动 stop/start | 自动管理 |
| 缓存 | 无，每次重新获取 | 内置缓存 + staleTime |
| 重试 | 手动实现 | 内置 retry / retryDelay |
| 组件集成 | 需要绑定到 DOM | useQuery hook 直接在组件中使用 |
| DevTools | 无 | React Query DevTools |

### 4.6 组件代码量预期

| 当前文件 | 行数 | 重构后组件 | 预期行数 |
|---|---|---|---|
| similarity.ts | 618 | AnalysisPanel, GroupGrid, GroupCard, WritebackPanel + store + hooks | 80-150/文件 |
| face-kw.ts | 705 | StepAnalyze, StepReview, ClusterGrid, ClusterDetail, TagEditor, StepWriteback + store + hooks | 80-150/文件 |
| dashboard.ts | ~200 | Dashboard, SessionCard, SessionFilter + hooks | 60-100/文件 |
| api.ts | ~300 | client.ts + 3 个模块文件 | 40-80/文件 |
| style.css | 1323 | 拆到各 CSS Modules | 40-100/文件 |

### 4.7 CSS Modules + 设计 Token

保留当前 style.css 中定义良好的 CSS 自定义属性作为全局设计 Token：

```css
/* styles/global.css */
:root {
  --surface-primary: #1a1a1a;
  --surface-secondary: #252525;
  --surface-tertiary: #2e2e2e;
  --text-primary: #e0e0e0;
  --text-secondary: #999;
  --accent: #4a9eff;
  --danger: #e74c3c;
  --success: #27ae60;
  --warning: #f39c12;
  --border: #333;
  --focus-ring: 0 0 0 2px rgba(74, 158, 255, 0.4);
}
```

每个组件的样式隔离在 CSS Module 中：

```css
/* pages/Similarity/GroupCard.module.css */
.card {
  background: var(--surface-secondary);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 12px;
}
.card.selected {
  border-color: var(--accent);
}
.card:hover {
  background: var(--surface-tertiary);
}
```

使用方式：

```tsx
// GroupCard.tsx
import styles from './GroupCard.module.css'

export function GroupCard({ group, selected, onToggle }: Props) {
  return (
    <div
      className={`${styles.card} ${selected ? styles.selected : ''}`}
      onClick={() => onToggle(group.id)}
    >
      <img src={group.representative} alt="" />
      <span>{group.photos.length} photos</span>
    </div>
  )
}
```

---

## 五、Python 后端架构详细设计

### 5.1 Engine Dispatch：Command Pattern

当前（23 个 elif case）：

```python
# engine.py
def _dispatch(self, msg):
    cmd = msg['type']
    if cmd == 'session.create':
        return self._handle_session_create(msg)
    elif cmd == 'fkw.analyze':
        return self._handle_fkw_analyze(msg)
    # ... 21 more elifs
```

重构后：

```python
# engine.py (核心骨架，不膨胀)
class GatherEngine:
    def __init__(self):
        self._registry = CommandRegistry()
        self._register_commands()

    def _register_commands(self):
        self._registry.register('session.create',    CreateSessionCommand(session_repo))
        self._registry.register('session.list',      ListSessionsCommand(session_repo))
        self._registry.register('session.delete',    DeleteSessionCommand(session_repo))
        self._registry.register('session.add_photos', AddPhotosCommand(photo_repo))
        self._registry.register('fkw.analyze',        AnalyzeFacesCommand(face_orchestrator))
        self._registry.register('fkw.get_clusters',   GetClustersCommand(face_repo))
        self._registry.register('fkw.bind',           BindClusterCommand(face_repo))
        self._registry.register('sim.analyze',        AnalyzeSimilarityCommand(sim_orchestrator))
        self._registry.register('sim.get_result',     GetSimilarityResultCommand(sim_repo))
        # ...

    def dispatch(self, msg):
        command = self._registry.get(msg['type'])
        if command is None:
            raise UnknownCommandError(msg['type'])
        return command.execute(msg.get('params', {}))

# commands/session.py
class CreateSessionCommand:
    def __init__(self, repo: SessionRepository):
        self._repo = repo
    def execute(self, params: dict) -> SessionData:
        return self._repo.create(params['name'])
```

### 5.2 Service 拆分

| 当前 | 行数 | 重构后 | 预期行数 |
|---|---|---|---|
| `SessionManager` | 975 | `SessionRepository` + `SessionService` | 200 + 150 |
| `FaceKeywordingService` | 954 | `FaceDetector` + `FaceClusterer` + `FaceBindingService` + `FaceWritebackService` + `FaceOrchestrator` | 100-200/文件 |
| `SimilarityService` | 693 | `HashComputer` + `ClusterEngine` + `SimilarityWritebackService` + `SimilarityOrchestrator` | 100-200/文件 |
| `BaseService` | mixed | `CacheManager` + `TaskRunner`（独立关注点） | 100 |

### 5.3 Repository 模式

```python
# repositories/session_repository.py
class SessionRepository:
    def get(self, id: str) -> Session: ...
    def create(self, name: str, source: str = 'local') -> Session: ...
    def delete(self, id: str) -> None: ...
    def list(self) -> list[SessionData]: ...
    def add_photos(self, id: str, paths: list[str], source: str) -> int: ...

# repositories/photo_repository.py
class PhotoRepository:
    def get_by_session(self, session_id: str) -> list[Photo]: ...
    def get_by_ids(self, ids: list[int]) -> list[Photo]: ...
    def update_checksum(self, id: int, checksum: str) -> None: ...

# repositories/face_repository.py
class FaceRepository:
    def save_clusters(self, session_id: str, clusters: list[FaceCluster]) -> None: ...
    def get_clusters(self, session_id: str) -> list[FaceCluster]: ...
    def update_binding(self, cluster_id: int, binding: RoleBinding) -> None: ...
    def get_cluster_members(self, cluster_id: int) -> list[FaceObservation]: ...

# repositories/similarity_repository.py
class SimilarityRepository:
    def save_hashes(self, session_id: str, hashes: list[PhotoHash]) -> None: ...
    def get_result(self, session_id: str) -> SimilarityResult: ...
    def save_result(self, session_id: str, groups: list[SimilarityGroup]) -> None: ...
```

### 5.4 Orchestrator 编排层

各 Service/Detector 之间不直接互相调用，由 Orchestrator 编排：

```python
# face_keywording/orchestrator.py
class FaceKeywordingOrchestrator:
    def __init__(self,
                 detector: FaceDetector,
                 clusterer: FaceClusterer,
                 writeback_service: FaceWritebackService,
                 photo_repo: PhotoRepository,
                 face_repo: FaceRepository,
                 task_runner: TaskRunner,
                 progress_emitter: ProgressEmitter):
        self._detector = detector
        self._clusterer = clusterer
        self._writeback = writeback_service
        self._photo_repo = photo_repo
        self._face_repo = face_repo
        self._task_runner = task_runner
        self._progress = progress_emitter

    def analyze(self, session_id: str) -> str:
        photos = self._photo_repo.get_by_session(session_id)
        analysis_id = str(uuid.uuid4())

        self._task_runner.run(analysis_id, self._do_analyze, session_id, photos)
        return analysis_id

    def _do_analyze(self, session_id: str, photos: list[Photo]):
        observations = []
        total = len(photos)
        for i, photo in enumerate(photos):
            faces = self._detector.detect(photo)
            observations.extend(faces)
            self._progress.emit(session_id, 'fkw.analyze', i / total)

        clusters = self._clusterer.cluster(observations)
        self._face_repo.save_clusters(session_id, clusters)

    def writeback(self, session_id: str, cluster_ids: list[int]) -> WritebackResult:
        clusters = [self._face_repo.get_cluster(cid) for cid in cluster_ids]
        results = []
        for cluster in clusters:
            result = self._writeback.write_xmp(cluster)
            results.append(result)
        return WritebackResult(results)
```

### 5.5 统一 Writeback 生命周期

当前 Similarity 和 Face KW 的写回流程不一致。重构后统一为：

```
Plan → Preview → Execute → Review Failures → Retry → Confirm Sync → Cleanup
```

| 阶段 | 动作 | 一致性要求 |
|---|---|---|
| Plan | 用户选择组/聚类 + 选项 | 前端组件自包含 |
| Preview | 调用 preview API，展示影响范围 | 统一 preview response shape |
| Execute | 执行写回，记录 writeback_items | 统一 WritebackResult |
| Review Failures | 展示成功/失败/跳过详情 | 统一 report 组件 |
| Retry | 重试失败项 | 统一 retry API |
| Confirm Sync | 确认数据已写入 XMP | 统一 confirm_sync API |
| Cleanup | 清理备份/标记完成 | 统一 cleanup API |

---

## 六、测试策略

### 6.1 测试层级

| 层级 | 工具 | 覆盖内容 | 数量目标 |
|---|---|---|---|
| 单元测试 (Python) | pytest (已有) | Repository / Detector / Clusterer / Writeback | 保留现有 + 新增 |
| 单元测试 (TypeScript) | Vitest + Testing Library | 组件渲染 / Store actions / API client | 每个组件至少 1 个 |
| 集成测试 (Python) | pytest | Orchestrator 编排 / Repository + DB | 保留现有 |
| E2E 测试 | Playwright | 完整页面流程 | 覆盖所有用户路径 |

### 6.2 Playwright E2E 结构

```
tests/e2e/
├── fixtures/
│   └── test-session.ts       # 创建测试 session 的 helper
├── dashboard.spec.ts         # 会话列表 / 导入 / CRUD
├── similarity.spec.ts        # 分析 → 审阅 → 写回完整流程
├── face-keywording.spec.ts   # 3 步工作流完整流程
├── navigation.spec.ts        # 路由 / 导航守卫 / edge cases
└── engine-recovery.spec.ts   # Engine 断开 / 重连 / 状态恢复
```

### 6.3 当前手动测试清单替换映射

| 当前 TEST.md 分类 | 覆盖方式 |
|---|---|
| Dashboard CRUD | Playwright E2E + Vitest 单元测试 |
| Similarity 分析/取消/Recluster | Playwright E2E + Python 集成测试 |
| Similarity 写回/重试 | Playwright E2E + Python 集成测试 |
| Face KW 3 步工作流 | Playwright E2E + Python 集成测试 |
| Engine 重连/错误恢复 | Playwright E2E (mock IPC) |
| 安全/权限 | 手动 + RustDesk 式安全测试 |

---

## 七、迁移路径

### Phase 1：基础设施搭建（预估 3-5 天）

目标：可并行开发的基础设施

1. 配置 Vite + React + TypeScript 构建
2. 配置 CSS Modules，迁移 global.css 中的设计 Token
3. 搭建 Zustand store 骨架
4. 搭建 React Router 路由
5. 搭建 TanStack Query 配置
6. 重写 API client 层（保留旧的 `api.ts` 并行运行）
7. 配置 Vitest + Testing Library + Playwright
8. 从旧 style.css 提取设计 Token

**验收标准：**
- `npm run dev` 启动 Vite dev server，React 页面渲染
- 旧的 app.ts 页面仍然可通过旧入口访问（并行运行）
- 所有现有测试通过

### Phase 2：共享组件迁移（预估 2-3 天）

目标：Toast / Dialog / ProgressBar / Badge 全部 React 化

1. 重写 `Toast` → React + CSS Modules
2. 重写 `Dialog` → React + CSS Modules（保留 typedConfirmDialog 逻辑）
3. 重写 `ProgressBar` → React + RAF throttle
4. 重写 `Badge` → React + 完整的状态样式
5. 为每个组件编写 Vitest 测试

**验收标准：**
- 新组件可通过 import 在 React 页面中使用
- 旧页面仍可引用旧的 DOM 版组件（双轨运行）

### Phase 3：Dashboard 迁移（预估 2-3 天）

目标：完整 React 化 Dashboard，功能与旧版一致

1. 迁移 SessionList → React
2. 迁移 SessionCard → React
3. 迁移 Import 功能 → React
4. 迁移 Filter → React
5. 编写 Dashboard E2E 测试

**验收标准：**
- Dashboard 所有功能正常（CRUD / Import / Filter / Delete）
- Dashboard Playwright E2E 通过

### Phase 4：Similarity 迁移（预估 4-5 天）

目标：完整 React 化 Similarity 页面

1. 迁移 AnalysisPanel → React
2. 迁移 GroupGrid / GroupCard → React
3. 迁移 WritebackPanel → React
4. 迁移轮询逻辑 → TanStack Query
5. 编写 Similarity E2E 测试

**验收标准：**
- 分析 / 取消 / Recluster / 写回 / 重试 全部正常
- Similarity Playwright E2E 通过

### Phase 5：Face Keywording 迁移（预估 5-7 天）

目标：完整 React 化 Face KW 3 步工作流

1. 迁移 StepAnalyze → React
2. 迁移 StepReview（ClusterGrid + ClusterDetail + TagEditor）→ React
3. 迁移 StepWriteback → React
4. 迁移 Merge 模式 → React
5. 编写 Face KW E2E 测试

**验收标准：**
- 3 步工作流全部正常
- 合并/跳过/绑定/写回/清理 全部正常
- Face KW Playwright E2E 通过

### Phase 6：Python 后端重构（预估 5-7 天）

目标：Command Pattern + Repository + Service 拆分

1. 提取 Repository 模式（Session / Photo / Face / Similarity）
2. 拆分 FaceDetector / FaceClusterer / FaceBindingService
3. 拆分 HashComputer / ClusterEngine
4. 提取 CommandRegistry + 各 Command
5. Engine dispatch 改为 Command Pattern
6. 统一 Writeback lifecycle

**验收标准：**
- 所有 Python 测试通过
- Engine 启动/IPC/命令处理与前端兼容
- 旧版 service 可安全删除

### Phase 7：收尾（预估 2-3 天）

1. 删除旧代码（app.ts / router.ts / dom.ts / style.css / 旧 pages）
2. 移除 CSP `unsafe-inline`
3. 编写完整 E2E 测试套件
4. 更新 README 和开发者文档
5. 删除 `TEST.md` 手动测试清单

**验收标准：**
- 项目零旧代码
- 所有 E2E 测试通过
- CSP 无 unsafe-inline

### Phase 时间线总览

```
Phase 1 ████████░░░░░░░░░░░░░░░░░░ 基础设施搭建 (3-5d)
Phase 2 ░░░░░░████░░░░░░░░░░░░░░░░ 共享组件迁移 (2-3d)
Phase 3 ░░░░░░░░░░████░░░░░░░░░░░░ Dashboard (2-3d)
Phase 4 ░░░░░░░░░░░░░░██████░░░░░░ Similarity (4-5d)
Phase 5 ░░░░░░░░░░░░░░░░░░░████████ Face KW (5-7d)
Phase 6 ░░░░░░░░░░░░░░░░░░░████████ Python 后端 (5-7d)
Phase 7 ░░░░░░░░░░░░░░░░░░░░░░░░██ 收尾 (2-3d)
                                   ────────────────
                                   25-33 工作日
```

Phase 3-6 可并行：如果两到三人分工，工期可缩减至 15-20 工作日。

---

## 八、风险与缓解

| 风险 | 可能性 | 影响 | 缓解措施 |
|---|---|---|---|
| Phase 1 构建配置不兼容现有 Electron 构建 | 中 | 高 | 先验证单文件 React 组件渲染；保留旧 webpack 配置作为回退 |
| 旧 DOM 操作和新 React 代码并行运行时状态冲突 | 中 | 中 | 通过 contextBridge 隔离，新旧 API client 共存 |
| TanStack Query 轮询与现有 Python 进度事件冲突 | 低 | 中 | 进度事件走 Zustand store，轮询走 TanStack Query，关注点分离 |
| Python 后端重构导致协议不兼容 | 中 | 高 | 先写契约测试，确保 IPC 消息格式不变 |
| Playwright E2E 测试维护成本高 | 低 | 低 | 只覆盖核心用户路径，不追求 100% 覆盖 |

---

## 九、拒绝的方案

### 方案 A：完全重写

从零开始用新架构写整个应用。

- **理由拒绝**：风险极高，6 个月以上的开发周期，期间无法交付业务价值
- **对应策略**：分阶段迁移，每阶段都可交付可用版本

### 方案 B：仅重构前端不动后端

把前端改为 React，Python 后端保持现状。

- **理由拒绝**：后端单体问题同样严重（975 行 SessionManager），拖到后面重构成本更高
- **对应策略**：Phase 3-5 做前端，Phase 6 做后端，利用并行窗口

### 方案 C：保留框架但引入 lit-html / htmx 等轻量方案

用轻量响应式库替代 React。

- **理由拒绝**：与现有代码风格差异大，生态和团队熟悉度不如 React，CSP inline 问题依然存在
- **对应策略**：用户已确认选择 React

---

## 十、验收标准总览

每个 Phase 的通用验收命令：

```bash
# 前端
npm --prefix desktop run typecheck
npm --prefix desktop test -- --runInBand
npm --prefix desktop run lint
npm --prefix desktop run build

# Python
uv run pytest
uv run ruff check . --fix
uv run mypy .

# E2E (Phase 3+)
npx playwright test

# 构建验证
npm run build  # 根目录 monorepo build
```
