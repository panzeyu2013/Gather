# Gather 开发与贡献指南

> 本文合并了原 `docs/CONTRIBUTING.md` 与 `docs/DEVELOPER.md`，按当前仓库
> （纯 TypeScript Electron 应用）现状重写。历史 Python 引擎架构章节已删除。
> 相关规范文档：`docs/ADR.md`（架构决策）、`docs/IPC_CONTRACT.md`（IPC 契约）、
> `docs/TEST.md`（测试清单）。

---

## 目录

- [项目概览](#项目概览)
- [技术栈](#技术栈)
- [本地开发](#本地开发)
- [代码风格](#代码风格)
- [提交规范](#提交规范)
- [分支策略](#分支策略)
- [Pull Request 流程](#pull-request-流程)
- [测试](#测试)
- [架构](#架构)
- [打包](#打包)
- [常见问题](#常见问题)

---

## 项目概览

Gather 是面向 Capture One 摄影师的桌面照片组织工具：按视觉相似度分组、
标注人脸关键词、提供挑片工作台，并把星级/颜色/关键词写入 XMP sidecar 供
Capture One 读取。它是一个独立 Electron 应用，不依赖浏览器。

## 技术栈

| 层 | 技术 |
|----|------|
| 桌面框架 | Electron 42（`contextIsolation: true`、`sandbox: true`、`nodeIntegration: false`） |
| 渲染层 | React 18 + Vite + CSS Modules，`react-router-dom` |
| 状态 | 服务端状态走 `@tanstack/react-query`，纯 UI/草稿走 `zustand` |
| 主进程 DI | `tsyringe`，组合根在 `desktop/src/main/di/init.ts` |
| 存储 | `better-sqlite3`（WAL） |
| 图像 | `sharp` + `sips`（macOS）解码链、`exiftool-vendored` |
| 人脸 | ONNX Runtime（SCRFD 检测 + ArcFace 编码） |
| 协议 | `packages/shared` TypeScript 契约 + `gather:command` IPC |
| 打包 | `electron-builder`（macOS dmg / Windows NSIS） |

---

## 本地开发

### 环境准备

- Node.js ≥ 22（`desktop/package.json` engines）
- `npm install`（根目录，workspaces：`desktop`、`packages/*`）
- `desktop` 的 `postinstall` 会执行 `electron-rebuild`，确保原生模块
  （better-sqlite3、sharp、onnxruntime）匹配 Electron ABI

### 常用命令（根目录）

```bash
npm install                  # 安装依赖（含原生模块重建）
npm run dev                  # 启动 Vite + Electron 开发模式
npm run build                # 构建 @gather/shared 与 desktop
npm run typecheck            # tsc 主进程 + 渲染层 + shared
npm run lint                 # ESLint（desktop/src）
npm run test:vitest          # 单元测试
npm run test:e2e             # Playwright + Electron 端到端（需先 build）
npm run electron             # 构建并启动本地正式应用
npm run dist:mac --workspace=desktop   # 打包 macOS dmg（产物 desktop/release/）
npm run benchmark:reliability         # SQLite 可靠性基准
npm run benchmark:application         # Electron 应用规模基准
```

---

## 代码风格

- TypeScript 目标 ES2022，`strict: true`；行宽 100；ESLint 校验
  （`npm run lint`）。
- 命名：`camelCase`（函数/变量）、`PascalCase`（类型/接口/类）、
  `UPPER_CASE`（常量）。
- 缩进 2 空格，UTF-8，LF 行尾，文件末尾保留一个空行。
- 不添加与意图无关的注释；注释解释"为什么"而非"是什么"。

---

## 提交规范

Commit 信息同时包含中文和英文描述，遵循
[Conventional Commits](https://www.conventionalcommits.org/) v1.0。

```
<type>(<scope>): <subject>

<body>
```

- **header** 不超过 72 个字符；**body** 每行不超过 80 个字符。
- **subject**：先写中文摘要（概括改动意图），后写英文描述（语法完整的句子）。
- **body**：解释「为什么」要改，而非「改了什么」；列出 Breaking Changes
  （如有）；关联 Issue（如有）。

### Type

| Type       | 说明        | 英文说明 |
|------------|-------------|---------|
| `feat`     | 新功能      | A new feature |
| `fix`      | 修复 Bug   | A bug fix |
| `refactor` | 重构        | Code change without feature or fix |
| `perf`     | 性能优化    | Performance improvement |
| `style`    | 代码格式    | Code style (format, indent, etc.) |
| `test`     | 测试相关    | Adding or fixing tests |
| `docs`     | 文档        | Documentation only changes |
| `chore`    | 杂项        | Build process, tooling, dependencies |
| `ci`       | CI/CD       | CI configuration and scripts |
| `revert`   | 回滚        | Revert a previous commit |

### Scope

| Scope      | 说明 |
|------------|------|
| `face-kw`  | 人脸关键词模块 |
| `similarity` | 相似度模块 |
| `culling`  | 挑片工作台 |
| `electron` | Electron 主进程 `desktop/src/main/` |
| `renderer` | 渲染进程 `desktop/src/renderer/` |
| `types`    | TypeScript 类型包 `packages/shared/` |
| `scripts`  | 构建/基准脚本 `scripts/` |
| `config`   | 配置文件 |
| `deps`     | 依赖变更 |
| `docs`     | 文档 |
| `*`        | 跨多个模块的变更 |

### 示例

```
fix(image): 修复大文件 RAW 解码卡死的问题

Fix main-process stall on large/corrupt RAW: bound full-file reads and
replace the O(n²) JPEG segment scan with a single-pass state machine.

- Add size cap and byte/time limits to the decode fallback path
- Fall back to sips instead of reading the whole file when possible
- Persist negative raw-index results to avoid repeated probes

Closes #123
```

---

## 分支策略

| 分支        | 用途          | 来源    | 合并目标 |
|-------------|--------------|---------|---------|
| `main`      | 稳定版本      | —       | —       |
| `feat/*`    | 功能开发      | `main`  | `main`  |
| `fix/*`     | Bug 修复      | `main`  | `main`  |
| `chore/*`   | 工具链/依赖/配置 | `main` | `main`  |

命名示例：`fix/image-raw-hang`、`feat/face-model-onboarding`。

---

## Pull Request 流程

1. **标题** 遵循 `<type>(<scope>): <description>` 格式。
2. **描述** 包含：改动概要（中文 + 英文）、关联 Issue（如 `Closes #123`）、
   截图（如涉及 UI 变更）、测试结果。
3. **检查清单**：
   - [ ] `npm run typecheck` 通过
   - [ ] `npm run lint` 通过
   - [ ] `npm run test:vitest` 通过
   - [ ] `npm run build` 通过
   - [ ] `npm run test:e2e` 通过（涉及主进程/渲染层改动时）
   - [ ] 无未处理的 TODO/FIXME
   - [ ] 无凭据/密钥被提交
   - [ ] `.gitignore` 已覆盖所有生成文件

---

## 测试

### 测试布局

```
tests/
├── unit/            # 所有 vitest 单元测试（vitest.config.ts 的 include 根）
│   ├── services/    # 主进程服务（按领域子目录分组）
│   ├── renderer/    # 渲染层 hook / api / store
│   └── shared/      # 跨进程协议与架构不变量
├── e2e/             # Playwright + Electron 端到端（*.spec.ts）
└── fixtures/        # 单测共享素材
    └── local/       # 本地面向 e2e 的素材（git-ignored，见下）
```

- 新增单元测试一律放 `tests/unit/` 对应子目录；相对导入按 `tests/unit/` 的
  层级计算。
- 架构不变量测试（`tests/unit/shared/architecture-invariants.test.ts`）禁止
  改动测试路径约定；schema 快照 `docs/fixtures/schema-v27.snapshot.json` 与
  迁移索引 DDL 由该测试强制校验（ADR-006）。
- `desktop/vitest.config.ts` 把 `better-sqlite3` 别名到
  `better-sqlite3-system`（为系统 Node 编译的副本），使单测无需手动重建
  原生模块。

### 人脸 e2e 本地素材（git-ignored）

`tests/e2e/face-workflow.spec.ts` 需要两类无法入库的素材（体积、第三方许可、
肖像权）：

- ONNX 模型：`face_detector.onnx`（SCRFD）+ `face_encoder.onnx`（ArcFace）；
- 含真实人脸的 RAW 照片（`.arw/.cr2/.cr3/.dng/.nef/.orf/.raf/.rw2`）。

这两类素材放在 git-ignored 目录 `tests/fixtures/local/` 下，规范见
`tests/fixtures/local-fixtures.md`。一键准备：

```bash
node scripts/setup-local-face-fixtures.mjs   # 软链接 ONNX 模型 + 创建 raw/
# 再向 tests/fixtures/local/raw/ 放入 2+ 张含人脸的 RAW（或用软链接指向自己的照片目录）
npm run test:e2e                             # 素材存在则自动运行，否则跳过
```

也可通过环境变量 `GATHER_FACE_E2E_SOURCE_DIR` / `GATHER_FACE_E2E_DETECTOR` /
`GATHER_FACE_E2E_ENCODER` 指定素材路径。测试只读取照片副本（复制到临时目录），
不会修改原始文件。

---

## 架构

### 进程模型

```
Electron Desktop App
  ├── Main Process (Node.js)
  │   ├── services/   # 领域服务（image / similarity / face-kw / culling /
  │   │               #   writeback / metadata / jobs / indexer / export ...）
  │   ├── ipc/        # gather:command 命令注册
  │   ├── db/         # SQLite + 迁移 + repositories
  │   ├── di/         # tsyringe 组合根
  │   ├── utils/      # 调度器、worker、工具
  │   ├── capture-one.ts   # osascript 桥接
  │   └── deep-link.ts     # gather:// 协议
  ├── Preload (contextBridge, 安全隔离)
  └── Renderer (React 18 + Vite + CSS Modules)
```

### 主进程依赖注入约定

- **平台相关的组合只允许出现在 DI 组装根（`desktop/src/main/di/init.ts`）**，
  服务核心不得出现 `process.platform` 分支。
- 典型：解码器集合通过 `DI_TOKENS.IMAGE_DECODERS` 注入，由组合根按平台组装
  （darwin 注册 `[SharpDecoder, SipsDecoder]`，其余仅 `SharpDecoder`）；
  `ImageService` 核心只消费注入的列表，回退逻辑是"按注册顺序依次尝试"的
  通用链。
- 新增平台相关能力时，照此模式：组合根决定"有哪些"，服务核心决定"怎么用"。

### 渲染层数据流约定

**服务端（主进程）状态 → React Query；瞬时 UI 状态 → Zustand；禁止把服务端
状态镜像进 zustand 或组件 local state。**

1. **React Query 拥有所有经 IPC 读取的服务端数据**：sessions、photos、
   culling assets/summary/history、similarity result、face clusters、
   library、jobs、persons。变更用 `useMutation` + `invalidateQueries`
   （按前缀失效）。
2. **Zustand 只放纯 UI/草稿状态**：当前 session id、分析参数草稿、wizard
   步骤、toast。不得存服务端返回的列表/对象。
3. **查询缓存是 undo/redo 等派生状态的唯一事实源**：不要在 query 数据之外
   再维护一份可漂移的本地副本；若必须维护，变更后必须 `invalidateQueries`
   对应 key（例如 culling undo/redo 后失效 `['culling','history', sessionId]`）。
4. **参数类草稿与结果的关系**：结果对象记录其实际计算参数（如 similarity
   result stats），草稿只在「新的结果对象到达」时按结果校准，避免陈旧结果
   覆盖用户正在编辑的草稿。
5. **推送优先**：主进程能推送的事件（`jobs:progress`、`culling:sync-status`）
   一律用 `useEvent` 订阅消费，不要用 `refetchInterval` 轮询拉同一个状态。
   轮询只用于低频、无推送通道的数据。
6. **事件订阅必须用 `useEvent`**（组件卸载自动清理），禁止在 effect 里裸调
   `window.gather.onEvent`。

### IPC 契约

- 渲染层命令走 `gather:command`（`ipcMain.handle` / contextBridge），参数与
  返回类型由 `packages/shared/src/protocol/` 定义；`tests/unit/shared/protocol.test.ts`
  强制 preload 白名单与协议类型同步。
- 破坏性命令在 preload 边界要求 `{ confirmed: true }`。
- 进度与状态经 `gather:event` 推送。
- 契约基线详见 `docs/IPC_CONTRACT.md`；命令清单以 `packages/shared` 与
  `desktop/src/preload/index.ts` 为准。

### 存储与迁移

- SQLite WAL；schema 由 `desktop/src/main/db/schema.ts` 与迁移
  （`migrations.ts`）管理。
- 迁移不变量与备份/恢复策略见 ADR-005/006：
  - 迁移前磁盘空间检查 → `wal_checkpoint(TRUNCATE)` → SQLite backup API
    备份 → `integrity_check`；
  - 迁移失败保留失败副本并从备份恢复，不删任何用户照片或 XMP；
  - 迁移后 `foreign_key_check` + 关键表列不变量 + 版本校验；
  - 表级 schema 变更必须同步 `docs/fixtures/schema-v27.snapshot.json`。

### 安全模型

| 配置 | 值 | 目的 |
|------|-----|------|
| `contextIsolation` | `true` | renderer 无法直接访问 Node.js API |
| `sandbox` | `true` | 操作系统级沙箱隔离 |
| `nodeIntegration` | `false` | 禁止 renderer 中使用 `require` |
| preload | contextBridge 白名单 | 仅暴露最小 API |
| 通信 | `gather:command` / 自定义协议 | 零 HTTP、零端口攻击面 |

---

## 打包

- macOS：`npm run dist:mac --workspace=desktop` → `desktop/release/*.dmg`
  （`hardenedRuntime`，entitlements 已注册）。
- Windows：NSIS 安装包（**待验证**）。
- Capture One 原生插件 `GatherLink.coplugin` 在 macOS 打包时由 electron-builder
  `afterPack` 钩子自动编译并随包分发（`desktop/scripts/afterPack.cjs`，目标架构
  跟随应用构建）；宿主机缺失 Capture One SDK 时跳过并打印警告，不阻断发布。
  手动构建/安装可执行 `cd desktop/coplugin && make all && make install`。

---

## 常见问题

### 开发模式如何启动？

```bash
npm install
npm run dev    # Vite + Electron 开发模式（渲染层 HMR，主进程改动需重启）
```

### 单元测试报 better-sqlite3 原生模块错误？

确认根目录 `npm install` 已执行；vitest 使用 `better-sqlite3-system` 别名，
无需为测试单独重建原生模块。若 Electron 运行时原生模块不匹配，重跑
`npm install` 触发 `electron-rebuild`。

### AppleScript 权限

macOS 首次调用 Capture One 桥接时会请求自动化权限；在
`系统设置 → 隐私与安全性 → 自动化` 中允许 Gather 控制 Capture One。

### 打包后无法连接 Capture One？

确认进程名为 "Capture One"/"Capture One Pro" 等合法名称、C1 已打开文档；
详见 `desktop/src/main/capture-one.ts` 的进程名校验。

---

## 相关文档

- [架构决策记录](docs/ADR.md)
- [IPC 契约基线](docs/IPC_CONTRACT.md)
- [测试清单](docs/TEST.md)
- [人脸 e2e 本地素材规范](../tests/fixtures/local-fixtures.md)
- [中文用户说明](docs/README_CN.md)
