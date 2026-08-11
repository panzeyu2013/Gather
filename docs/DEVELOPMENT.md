# Gather 开发与贡献指南

Gather 当前是 macOS 14+ 的 Swift/SwiftUI 原生桌面应用。业务能力位于
`desktop/native/gather-core`，界面与应用生命周期位于
`desktop/native/gather-app`；仓库不再依赖 Node.js、Electron、浏览器渲染层或本地
HTTP 服务。

## 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools
- Swift 5.9 或更高版本
- Capture One 仅在需要验证原生插件/导入联动时才需要

真实人脸推理质量、代码签名/公证/安装升级和商业信号不属于本轮重构验收范围。

## 目录结构

```text
desktop/native/
├── gather-core/       # SQLite、任务、索引、元数据、导出和 Vision 服务
└── gather-app/        # SwiftUI 页面、应用路由、菜单与原生命令路由
docs/                  # 开发、测试、架构和迁移记录
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

产物为 `dist/native/Gather.app`。脚本会构建 gather-core、GatherApp，并在存在
Capture One 插件源码时尝试构建插件。默认产物保持未签名；签名、公证和安装包是
独立的发布流程。

## 架构约定

```text
SwiftUI
  ↓
SessionCommandRouter / CommandRouter
  ↓
GatherCore 服务
  ├── SQLite（WAL + 迁移）
  ├── 图片读取、Vision 和 RAW 解码
  ├── JobService（可恢复任务）
  └── MetadataOutbox / XMP 写回
```

### 页面与路由

- `RootView` 负责 Dashboard、Library、Gallery、Similarity、Persons 及原生功能页
  的导航。
- session 功能通过 `SessionCommandRouter` 访问核心服务，保持 session 范围隔离。
- Jobs、Settings、Face Keywording、Duplicates、Culling、Export 和 Control Center
  均由 SwiftUI 原生页面承载。

### 数据与任务

- SQLite 使用 WAL；迁移由 `GatherCore` 的迁移服务统一管理。
- 导入创建 session、写入照片资产后，立即提交 `metadata.scan` 任务；任务中心负责
  进度、失败显示、重试和取消。
- 元数据写回经过 outbox，支持失败重试、冲突处理和重启后恢复。
- 文件操作必须使用数据库中已授权的资产路径；删除、移动和覆盖类操作需要显式确认。
- 重复资产按逻辑资产处理，避免 RAW/JPEG 配对造成重复分析或重复写回。

### 原生边界

- 应用不包含 WKWebView、JavaScriptCore、React、TypeScript IPC 或 Electron 主进程。
- 原生命令路由只接受明确的命令和参数；未知命令返回可诊断错误，不应静默成功。
- UI 不直接持有数据库连接或执行任意文件路径操作，服务层负责授权和事务边界。

## 代码风格

- 遵循 Swift API Design Guidelines，类型使用 `UpperCamelCase`，变量和方法使用
  `lowerCamelCase`。
- 优先使用结构化并发、明确的错误类型和可取消任务。
- 注释解释约束和原因，不重复代码本身。
- 新增服务应同时补充单元测试；涉及页面路由或任务状态时补充模型/路由测试。

## 测试与验收

提交前至少运行：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-core

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-app

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  ./desktop/native/build.sh
```

验收时要区分：

- 测试/编译/应用组装成功：证明代码链路可构建和可执行。
- 真实照片、人脸推理质量、签名公证安装和商业材料性能：本轮明确排除，不能用
  自动化绿灯替代这些外部证据。
- 如果测试输出含 fixture-dependent skip，应单独记录，不得标成失败或误报为真实
  数据集验收。

详细清单见 [TEST.md](TEST.md)，阶段台账见
[NATIVE-DEVELOPMENT-ANALYSIS.md](NATIVE-DEVELOPMENT-ANALYSIS.md)。

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

Node/Electron 运行时和 TypeScript 前端已在 Phase 4 移除。开发、测试和打包入口
统一为 Swift Package 与 `desktop/native/build.sh`。

### 为什么生成的 `.app` 未签名？

这是源码构建的默认边界。需要发布签名时由发布环境提供
`CODESIGN_IDENTITY` 并执行独立的签名、公证和安装验证流程；该流程不属于本轮
重构验收。

## 相关文档

- [中文用户说明](README_CN.md)
- [测试清单](TEST.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
- [原生开发分析](NATIVE-DEVELOPMENT-ANALYSIS.md)
