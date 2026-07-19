# Contributing to Gather

感谢您对 Gather 的关注！本文档规定了项目的贡献规范。

> 语言：首次提交/Review 使用中文，Commit 信息同时包含中文和英文描述。

---

## 目录

- [提交规范 (Commit Convention)](#提交规范-commit-convention)
- [分支策略 (Branch Strategy)](#分支策略-branch-strategy)
- [开发工作流 (Development Workflow)](#开发工作流-development-workflow)
- [代码风格 (Code Style)](#代码风格-code-style)
- [测试 (Testing)](#测试-testing)
- [Pull Request 流程](#pull-request-流程)

---

## 提交规范 (Commit Convention)

### 格式

每条 commit 信息包含三部分：

```
<type>(<scope>): <subject>

<body>
```

**header** 不超过 72 个字符，**body** 每行不超过 80 个字符。

### Type (类型)

| Type       | 说明            | 英文说明                    |
|-----------|----------------|----------------------------|
| `feat`    | 新功能          | A new feature              |
| `fix`     | 修复 Bug       | A bug fix                  |
| `refactor`| 重构           | Code change without feature or fix |
| `perf`    | 性能优化        | Performance improvement    |
| `style`   | 代码格式        | Code style (format, indent, etc.) |
| `test`    | 测试相关        | Adding or fixing tests     |
| `docs`    | 文档            | Documentation only changes |
| `chore`   | 杂项            | Build process, tooling, dependencies |
| `ci`      | CI/CD          | CI configuration and scripts |
| `revert`  | 回滚            | Revert a previous commit   |

### Scope (范围)

| Scope              | 说明                     |
|--------------------|-------------------------|
| `face-kw`          | 人脸关键词模块 `face_keywording/` |
| `similarity`       | 相似度模块 `similarity/` |
| `engine`           | Python IPC 引擎 `desktop/engine/` |
| `electron`         | Electron 主进程 `desktop/src/main/` |
| `renderer`         | 渲染进程 `desktop/src/renderer/` |
| `shared`           | Python 共享模块 `shared/` |
| `types`            | TypeScript 类型包 `packages/shared/` |
| `scripts`          | 构建/部署脚本 `scripts/` |
| `config`           | 配置文件 (pyproject, tsconfig, etc.) |
| `deps`             | 依赖变更                 |
| `*`                | 跨多个模块的变更          |

### Subject (描述)

先写中文摘要（概括改动意图），后写英文描述（语法完整的句子）。

### Body (正文)

- 解释「为什么」要改，而非「改了什么」
- 列出 Breaking Changes（如有）
- 关联 Issue（如有）

### 示例

```
feat(face-kw): 添加 DBSCAN 聚类结果可视化预览

Implement cluster preview grid with thumbnail rendering and
multi-filter (All/Unbound/Bound/Skipped) support.

- Add cluster grid component with sorted card layout
- Support All/Unbound/Bound/Skipped tab filtering
- Click-to-select with highlighted border feedback
- Merge mode with source/target workflow

Closes #42
```

```
fix(engine): 修复 Python 子进程退出时端口未释放的问题

Fix race condition where Python process port remains in
TIME_WAIT after window close, preventing restart.

- Switch to stdin/stdout IPC to avoid port allocation
- Add SIGTERM handler for clean child process teardown
- Implement 5-second watchdog for forced kill fallback
```

```
refactor(shared): 统一 Session 状态机枚举定义

Unify all session/analysis/writeback status enums across
Python models and TypeScript protocol types.

- Move status enums to shared.models with single source of truth
- Regenerate TypeScript types from Python enum definitions
- Remove duplicate status mappings in renderer pages

Breaking: SessionStatus enum values renamed; update all consumers.
```

```
chore(deps): 升级 Electron 至 42.4.1 并移除弃用 API

Upgrade Electron from 38.x to 42.4.1 and migrate from
deprecated `remote` module to contextBridge pattern.

- Bump electron to ^42.4.1
- Replace `@electron/remote` with ipcRenderer.invoke
- Update webpack config for Electron 42 module resolution
```

---

## 分支策略 (Branch Strategy)

| 分支        | 用途                           | 来源    | 合并目标  |
|-------------|-------------------------------|---------|----------|
| `main`      | 稳定版本                       | —       | —        |
| `feat/*`    | 功能开发                       | `main`  | `main`   |
| `fix/*`     | Bug 修复                      | `main`  | `main`   |
| `chore/*`   | 工具链/依赖/配置变更             | `main`  | `main`   |

命名示例：`feat/face-kw-merge-mode`, `fix/engine-crash-on-exit`。

---

## 开发工作流 (Development Workflow)

### 环境准备

```bash
# Python 环境
uv sync

# Node 依赖
npm install

# 启动开发模式
cd desktop && npm run dev
```

### 开发流程

1. 从 `main` 创建功能分支 `feat/<name>` 或 `fix/<name>`
2. 增量提交，遵循提交规范
3. 确保本地测试通过：
   ```bash
   # Python 测试
   uv run pytest tests/ -v

   # TypeScript 测试
   cd desktop && npm test

   # 类型检查
   cd desktop && npm run typecheck

   # Lint
   uv run ruff check
   ```
4. 推送到远程，创建 Pull Request
5. 获得至少 1 名维护者 Review 后合并

---

## 代码风格 (Code Style)

### Python

- 目标版本：Python 3.10+
- 行宽：120 字符
- 格式化：ruff (`uv run ruff check`)
- 类型注解：所有公开函数/方法需标注类型
- 命名：`snake_case`（函数/变量），`PascalCase`（类），`UPPER_CASE`（常量）

```python
# 正确
def compute_dhash(image_path: str, hash_size: int = 8) -> str: ...

# 错误
def compute_dhash(image_path, hash_size=8): ...
```

### TypeScript

- 目标版本：ES2022
- 行宽：100 字符
- 格式化：ESLint (`npm run lint`)
- 命名：`camelCase`（函数/变量），`PascalCase`（类型/接口/类），`UPPER_CASE`（常量）
- 严格模式：`strict: true`

### 通用

- 缩进：2 空格（Python 使用 4 空格）
- 编码：UTF-8
- 行尾：LF
- 文件末尾保留一个空行

---

## 测试 (Testing)

### Python 测试

- 框架：pytest + pytest-cov
- 位置：`tests/`
- 覆盖率目标：>= 60%（`pyproject.toml` 中配置 `fail_under = 60`）
- 命名：`test_<module>.py`

```bash
uv run pytest tests/ -v --cov
```

### TypeScript 测试

- 框架：Jest 30 + ts-jest
- 位置：`desktop/src/**/*.test.ts` 和 `packages/shared/src/*.test.ts`

```bash
cd desktop && npm test
```

---

## Pull Request 流程

1. **标题** 遵循 `<type>(<scope>): <description>` 格式
2. **描述** 包含：
   - 改动概要（中文 + 英文）
   - 关联 Issue（如 `Closes #123`）
   - 截图（如涉及 UI 变更）
   - 测试结果
3. **检查清单**：
   - [ ] Python 测试通过 (`uv run pytest tests/ -v`)
   - [ ] TypeScript 测试通过 (`cd desktop && npm test`)
   - [ ] Lint 通过 (`uv run ruff check` / `cd desktop && npm run lint`)
   - [ ] 类型检查通过 (`cd desktop && npm run typecheck`)
   - [ ] 无未处理的 TODO/FIXME
   - [ ] 无凭据/密钥被提交
   - [ ] `.gitignore` 已覆盖所有生成文件

---

## 鸣谢

Gather 遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范（v1.0）。
