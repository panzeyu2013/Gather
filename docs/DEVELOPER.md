# Gather — Developer Guide

## 架构

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
