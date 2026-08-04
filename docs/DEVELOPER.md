# Gather — Developer Guide

> 注意：本文其余章节描述的是早期 Python 引擎架构，已废弃。当前实现为纯 TypeScript
> Electron 应用（见仓库根目录 README.md 的 Architecture 一节）。以下「渲染层数据流约定」
> 是对当前代码的规范说明。

---

## 测试布局（当前有效）
```
tests/
├── unit/            # 所有 vitest 单元测试（vitest.config.ts 的 include 根）
│   ├── services/    # 主进程服务（按领域子目录分组）
│   ├── renderer/    # 渲染层 hook / api / store
│   └── shared/      # 跨进程协议与架构不变量
├── e2e/             # Playwright + Electron 端到端（*.spec.ts）
└── fixtures/        # 单测共享素材
```

- 新增单元测试一律放 `tests/unit/` 对应子目录；相对导入按 `tests/unit/` 的层级计算。
- 架构不变量测试（`tests/unit/shared/architecture-invariants.test.ts`）禁止改动测试路径约定。

---

## 主进程依赖注入约定（当前有效）

- **平台相关的组合只允许出现在 DI 组装根（`desktop/src/main/di/init.ts`）**，服务核心不得出现
  `process.platform` / `process.platform === 'darwin'` 分支。
- 典型：解码器集合通过 `DI_TOKENS.IMAGE_DECODERS` 注入，由组合根按平台组装
  （darwin 注册 `[SharpDecoder, SipsDecoder]`，其余仅 `SharpDecoder`）；
  `ImageService` 核心只消费注入的列表，回退逻辑是"按注册顺序依次尝试"的通用链，
  因此可在任意平台被确定性测试。
- 新增平台相关能力时，照此模式：组合根决定"有哪些"，服务核心决定"怎么用"。

---

## 渲染层数据流约定（当前有效）

**服务端（主进程）状态 → React Query；瞬时 UI 状态 → Zustand；禁止把服务端状态镜像进 zustand 或组件 local state。**

1. **React Query 拥有所有经 IPC 读取的服务端数据**：sessions、photos、culling assets/summary/history、
   similarity result、face clusters、library、jobs、persons。变更用 `useMutation` + `invalidateQueries`（按前缀失效）。
2. **Zustand 只放纯 UI/草稿状态**：当前 session id、分析参数草稿、wizard 步骤、toast。不得存服务端返回的列表/对象。
3. **查询缓存是 undo/redo 等派生状态的唯一事实源**：不要在 query 数据之外再维护一份可漂移的本地副本；
   若必须维护，变更后必须 `invalidateQueries` 对应 key（例如 culling undo/redo 后失效 `['culling','history', sessionId]`）。
4. **参数类草稿与结果的关系**：结果对象记录其实际计算参数（如 similarity result stats），
   草稿只在「新的结果对象到达」时按结果校准，避免陈旧结果覆盖用户正在编辑的草稿。
5. **推送优先**：主进程能推送的事件（`jobs:progress`、`culling:sync-status`）一律用 `useEvent` 订阅消费，
   不要用 `refetchInterval` 轮询去拉同一个状态。轮询只用于低频、无推送通道的数据。
6. **事件订阅必须用 `useEvent`**（组件卸载自动清理），禁止在 effect 里裸调 `window.gather.onEvent`。

---

## 架构（旧·Python 引擎，仅供历史参考）

```
Electron (desktop/src/)
├── Main Process               src/main/
│   ├── index.ts              入口, 窗口, IPC, 菜单
│   ├── python-bridge.ts      spawn + MessagePack 协议
│   └── capture-one.ts        osascript 桥接
├── Preload                    src/preload/
│   └── index.ts              contextBridge API
├── Renderer (SPA)             src/renderer/
│   ├── app.ts                路由 + 生命周期
│   ├── router.ts             navigate / registerCleanup
│   ├── api.ts                engine 客户端
│   ├── components/           dom.ts, toast.ts
│   └── pages/
│       ├── dashboard.ts      首页
│       ├── similarity.ts     相似度
│       └── face-kw.ts        人脸标注
└── Shared Types               packages/shared/src/
    └── protocol.ts           Command / Response / Event

Python Engine (desktop/engine/)
├── engine.py                 入口, 23 dispatch cases
└── protocol.py               长度前缀 MessagePack 读写

Python 核心模块
├── shared/                   models, db, session_manager
├── face_keywording/          service, face_engine, writeback
├── similarity/               service, analysis
└── tests/                    单元测试
```

---

## 通信协议

```
┌──────────────────┬─────────────────────────────┐
│ 4 bytes (BE u32) │ N bytes MessagePack payload │
│   payload 长度   │                             │
└──────────────────┴─────────────────────────────┘
```

stdin/stdout, 二进制安全, 零 HTTP, 零端口, 零 CSRF。

### 消息格式

```typescript
// 请求（Electron → Python）
// Parameters are spread to top level alongside id and type.
// Reserved keys (id, type, ok, error, event, data, cmd) are stripped from params.
{ id: number, type: string, ...params }

// 响应（Python → Electron）
{ id: number, ok?: unknown, error?: string }

// 事件（Python → Electron）
{ type: "event", event: "progress" | "ready", data: Record<string, unknown> }
```

---

## 命令列表

| 命令 | 功能 |
|------|------|
| `session.create` / `session.delete` / `session.list` / `session.add_photos` | 会话 CRUD |
| `fkw.analyze` / `fkw.clusters` | 人脸分析 + 获取簇 |
| `fkw.bind` / `fkw.unbind` / `fkw.merge` / `fkw.remove_member` | 角色绑定/合并/移除 |
| `fkw.preview` / `fkw.writeback` / `fkw.confirm_sync` / `fkw.cleanup` | 预览/写回/确认同步/清理 |
| `fkw.confirm_cleanup` | 旧兼容命令：确认同步后立即清理，新 UI 不应直接调用 |
| `sim.analyze` / `sim.result` / `sim.recluster` / `sim.preview_writeback` / `sim.writeback` | 相似度分析/重聚类/写回预览/执行写回 |
| `shutdown` | 优雅退出 |

---

## 开发环境

```bash
# 安装 Python 依赖（从项目根目录运行）
uv sync --dev

cd desktop

# 安装 Node 依赖
npm install

# 启动开发模式
npm run dev
# → tsc 编译 Main Process + Webpack Dev Server (port 5173)
# → Electron 窗口通过 loadURL('http://localhost:5173') 加载渲染进程
# → Renderer 代码热更新（HMR），Main 代码需重启

# 类型检查
npm run typecheck

# 构建生产包
npm run build

# 打包 .dmg
npm run dist:mac

# 仅运行 Python 测试
uv run pytest tests/ -v
```

---

## 文件结构

```
Gather/
├── desktop/                     # Electron 项目
│   ├── package.json
│   ├── tsconfig.main.json
│   ├── tsconfig.renderer.json
│   ├── electron-builder.yml
│   ├── webpack.renderer.config.js
│   ├── src/                     # TypeScript 源码
│   │   ├── main/
│   │   ├── preload/
│   │   ├── renderer/
│   │   └── shared/
│   ├── engine/                  # Python 引擎
│   └── resources/               # macOS 图标/权限
├── packages/shared/              # @gather/shared TypeScript 类型
├── shared/                      # 共享模块 (models, db, session_manager)
├── face_keywording/             # 人脸模块 (service, face_engine, writeback)
├── similarity/                  # 相似度模块 (service, analysis)
├── tests/                       # Python 单元测试
├── pyproject.toml               # Python 依赖管理
├── install.sh                   # 一键构建脚本
├── docs/README_CN.md                 # 用户文档
└── docs/TEST.md                      # 测试清单
```

---

## 打包配置

`electron-builder.yml`:
- macOS: `hardenedRuntime dmg`，entitlements 注册
- Windows: NSIS 安装包（待验证）
- `extraResources` 复制 Python engine + 核心模块到 app bundle
- `.dmg` 内嵌 Python venv，用户无需安装 Python

打包后目录结构：

```
Gather.app/Contents/
├── MacOS/Gather                 # Electron 可执行文件
├── Resources/
│   ├── app.asar                 # 前端代码（压缩包）
│   ├── engine/                  # Python 引擎
│   └── shared/, face_keywording/, similarity/  # 核心模块
└── Frameworks/                  # Electron Framework
```

---

## 安全模型

| 配置 | 值 | 目的 |
|------|-----|------|
| `contextIsolation` | `true` | renderer 无法直接访问 Node.js API |
| `sandbox` | `true` | 操作系统级沙箱隔离 |
| `nodeIntegration` | `false` | 禁止 renderer 中使用 `require` |
| `preload` | `preload/index.js` | 通过 `contextBridge` 暴露最小 API |
| 通信 | stdin/stdout | 无网络端口暴露 |
| 协议 | MessagePack 二进制 | 无 HTTP 攻击面（CSRF、XSS via URL） |

---

## 常见问题

### 开发模式报 `spawn python3 ENOENT`
```bash
# 确认 Python3 可用
which python3
# 安装 Python 依赖
uv sync
```

### 打包后 Python 引擎找不到模块
检查 `electron-builder.yml` 中 `extraResources` 过滤规则，确保 `shared/`, `face_keywording/`, `similarity/` 目录被正确包含。

### AppleScript 权限
macOS 首次运行时系统会弹窗请求辅助功能权限，需在 `系统设置 → 隐私与安全性 → 自动化` 中允许 Gather 控制 Capture One。

### 端口占用
Webpack Dev Server 使用端口 5173（`strictPort: true`），若被占用需先释放该端口。
