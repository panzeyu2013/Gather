<div align="center">

# Gather

**面向 Capture One 的本地优先照片挑选与目录协作工具。**

把本地文件夹或 Capture One 选中项组织成工作区，在一个桌面应用中完成浏览、
挑片、相似照片审核、人脸关键词标注和可靠的元数据写回。

[English](../README.md) · [核心功能](#核心工作流) · [快速开始](#快速开始) · [参与贡献](#参与贡献)

[![CI](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml/badge.svg)](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-252525?logo=apple)
![Node.js 22+](https://img.shields.io/badge/Node.js-22%2B-3c873a?logo=nodedotjs&logoColor=white)
[![MIT License](https://img.shields.io/badge/license-MIT-c56a42.svg)](../LICENSE)

</div>

> [!IMPORTANT]
> Gather 仍在积极开发中。macOS 是目前主要且经过测试的桌面平台；仓库中已有
> Windows 打包配置，但 Windows 工作流尚未完成发布级验证。当前推荐从源码在
> 本地安装。

## 为什么使用 Gather？

Capture One 继续负责照片开发并作为最终工作环境；Gather 专注于围绕它产生的
大量筛选决策：寻找相关画面、比较近似照片、设置星级和色标、分配人物关键词，
再通过元数据把结果交还给 Capture One。

- **本地优先：** 照片、索引、模型和元数据处理都留在本机，应用不启动 HTTP
  服务。
- **适配真实拍摄素材：** RAW/JPEG 变体可折叠成一张逻辑照片，证据不足的组合
  会保留给用户确认。
- **键盘优先：** 在挑片工作台内完成保留、淘汰、评级、导航、对比和撤销/重做。
- **可恢复写回：** 元数据变更先持久化，再由支持重试、冲突检测和重启恢复的
  队列处理。

## 核心工作流

| 工作流 | 主要能力 |
| --- | --- |
| **全局图库** | 跨工作区搜索、组合筛选、智能相册、RAW/JPEG 逻辑资产、离线存储卷重连和重复候选。 |
| **挑片** | Pick/Reject、0～5 星、Capture One 色标、自动前进、单图/双图/四图对比、同步缩放、批量操作和撤销/重做。 |
| **相似度** | dHash 感知哈希和层次聚类，可调整阈值，并按组写回关键词。 |
| **人脸库** | 本地 ONNX 人脸检测与编码、DBSCAN 聚类、簇审核/合并/跳过、人物绑定和 XMP 关键词写回。 |
| **导出与任务** | 导出预设、按变体输出、后台进度、取消、诊断和任务重试。 |
| **Capture One** | 通过 AppleScript 导入当前选中项，并通过元数据交还评级、色标或关键词；可选原生插件提供“发送到 Gather”操作。 |

## 快速开始

### 环境要求

- macOS 13 或更高版本
- Node.js 22 或更高版本及 npm
- 仅使用本地文件夹时不要求 Capture One；直接导入选中项和同步需要 Capture One
- 人脸分析需要在本地配置兼容的 SCRFD 与 ArcFace ONNX 模型；仓库不会提交
  模型二进制文件

### 从源码运行

```bash
git clone https://github.com/panzeyu2013/Gather.git
cd Gather
npm install
npm run electron
```

`npm run electron` 会构建共享契约和桌面应用，然后在本地启动正式渲染版本。

### 构建 macOS 安装包

```bash
npm run dist:mac --workspace=desktop
```

DMG 会输出到 `desktop/release/`。用于分发的构建仍需要打包者自己的 Apple 签名
和公证凭据；已发布的产物会列在
[Releases](https://github.com/panzeyu2013/Gather/releases) 页面。

## 第一次工作流

1. 从本地文件夹或 Capture One 当前选中项创建工作区。
2. 打开“挑片”，使用 `P` 保留、`X` 淘汰、`0`～`5` 评级、方向键导航，
   使用 `Cmd/Ctrl+Z` 撤销。
3. 用双图或四图模式比较连拍；人脸对齐会复用已有检测结果，不会重新运行模型。
4. 处理失败或冲突的元数据项目，然后立即写入剩余变更。
5. 在 Capture One 中执行“图像 → 加载元数据”（或设置单向 Auto Sync =
   Load）。只有在 Capture One 完成读取后，再回到 Gather 确认同步。

相似度分析不是前置条件：挑片工作流可以直接处理所有已索引照片。

## 数据与安全模型

```text
渲染进程（React）→ 类型化 gather:command IPC → Electron 主进程
                                                ├─ SQLite（WAL + 迁移）
                                                ├─ 图像 / ONNX 工作线程
                                                └─ XMP 与内嵌元数据写入器
```

- `contextIsolation: true`、`sandbox: true`、`nodeIntegration: false`
- preload 桥只向渲染进程开放最小 API
- 不启动本地 Web 服务，也不监听应用端口
- 元数据 outbox 支持重试、冲突处理和恢复
- RAW/JPEG 关联采用保守规则，并且可由用户撤销

详细约束见[架构决策记录](ADR.md)和 [IPC 契约](IPC_CONTRACT.md)。

## 开发

```bash
npm run dev          # Vite + Electron 开发模式
npm run typecheck    # 主进程、渲染层和共享代码的 TypeScript 检查
npm run lint         # ESLint
npm run test:vitest  # 单元测试
npm run build        # 正式构建
npm run test:e2e     # 正式构建 Electron 冒烟流程
```

人脸工作流 E2E 需要本地 ONNX 模型和至少两张含人脸的 RAW 照片。这些素材由
git 忽略；素材缺失时对应测试会跳过。详见
[本地测试素材说明](../tests/fixtures/local-fixtures.md)。

## 文档

- [开发与贡献指南](DEVELOPMENT.md)
- [测试指南](TEST.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
- [IPC 契约](IPC_CONTRACT.md)
- [原生开发分析](NATIVE-DEVELOPMENT-ANALYSIS.md)

## 参与贡献

欢迎提交 Issue 和 Pull Request。开始修改前请阅读[开发与贡献指南](DEVELOPMENT.md)，
并运行与改动范围对应的检查。涉及界面的改动应附带修改前后截图。

## 许可证

Gather 使用 [MIT License](../LICENSE)。
