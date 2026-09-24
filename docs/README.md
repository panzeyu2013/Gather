<div align="center">

# Gather

**面向 Capture One 的本地优先原生照片挑选与目录协作工具。**

Gather 把本地文件夹或 Capture One 选中项组织成工作区，在一个 SwiftUI 桌面应用中
完成浏览、挑片、相似照片审核、人脸关键词标注和可靠的元数据写回。

[English](../README.md) · [核心工作流](#核心工作流) · [快速开始](#快速开始)

[![CI](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml/badge.svg)](https://github.com/panzeyu2013/Gather/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-252525?logo=apple)
[![MIT License](https://img.shields.io/badge/license-MIT-c56a42.svg)](../LICENSE)

</div>

> [!IMPORTANT]
> 当前源码构建生成未签名 `.app`。签名、公证、安装升级和商业信号验证属于独立的
> 发布活动，不是代码验收门。
> 本文档由原 `README_CN.md` 并入并更新至原生架构（Electron/React 时代内容已随
> `NATIVE-DEVELOPMENT-ANALYSIS.md` 一并归档删除）。

## 架构一句话

**SwiftUI 页面 → 类型化命令面 `CommandSurface`（19 域 · 111 方法，async-only）
→ `GatherCore` Runtime（actor）→ Store**：SQLite（WAL + 迁移）为唯一持久层，
Vision/ImageIO/RAW 解码负责图像，`JobRunner` 承载可恢复后台任务，Metadata outbox
负责可靠写回。app 侧不存在命令名字符串、命令级 JSON 与第二命令层。
无 Node.js、无 Electron、无浏览器渲染层、无本地 HTTP 服务。

## 核心工作流

| 工作流 | 主要能力 |
| --- | --- |
| **工作台与图库** | 工作区管理、跨工作区浏览、组合筛选、逻辑 RAW/JPEG 资产和分页图库。 |
| **挑片** | 保留/淘汰、星级、色标、对比、撤销/重做、元数据同步、失败重试和清理。 |
| **相似度与重复** | dHash 聚类、阈值审核、精确/视觉重复组和安全处理。 |
| **人物与人脸关键词** | 原生 Vision 推理调度、簇审核、人物绑定和 XMP 关键词写回。 |
| **导出与任务** | 预览、变体输出、JPEG/TIFF 转换、XMP 复制、可恢复任务、取消和报告。 |

## 目录结构

```text
desktop/native/
├── build.sh                 # 原生 release 组装（gather-core + gather-app + .app）
├── gather-core/             # Swift Package：Protocol/Store/Runtime/Jobs/Metadata/API/Support + 算法内核
│   ├── Sources/GatherCore/  #   Protocol/ Store/ Runtime/ Jobs/ Metadata/ API/ Support/ Face/ Image/ Similarity/ Logging/
│   └── Tests/GatherCoreTests/  # swift-testing（含对账、迁移与结构漂移门禁）
└── gather-app/              # Swift Package：SwiftUI 壳层与页面、组合根、菜单
    ├── Sources/GatherApp/   #   App（AppComposition 组合根）/ Shell / Dashboard / Library / Gallery / Similarity / Persons /
    │                        #   Host（CaptureOneBridge、GatherAppDelegate）/ Support（主题、本地化、错误映射、事件、Toast）
    ├── Culling/ FaceKeywording/ ControlCenter/ Settings/ Export/ Duplicates/
    └── Resources/           #   en.lproj / zh-Hans.lproj Localizable.strings
docs/                        # 本文档、开发指南、ADR、路线图
```

## 快速开始

### 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools，支持 Swift 5.9+
- 仅使用本地文件夹时不要求 Capture One
- 人脸分析使用系统 Vision，无需模型资产；真实数据集推理质量属于明确跳过的外部验收

### 运行原生测试

```bash
cd desktop/native/gather-core
swift test

cd ../gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test
```

### 构建 macOS 应用

```bash
./desktop/native/build.sh
```

产物位于 `release/Gather.app`（可用 `OUTPUT_DIR` 覆盖）。脚本只构建 Swift 核心和
SwiftUI 应用，不需要 JavaScript 工具链；设置 `CODESIGN_IDENTITY` 后才会执行可选
签名，公证与安装升级属于独立发布活动。

## 数据与安全模型

```text
SwiftUI → CommandSurface（19 域类型化命令）→ GatherCore Runtime
                                  ├─ Store（唯一 SQL 所有者：SQLite WAL + 迁移 + 备份/回滚）
                                  ├─ Vision/ImageIO/RAW 解码
                                  └─ XMP 与元数据写回队列（outbox）+ JobRunner
```

破坏性操作需要显式确认（`confirmed` 门控 31 项），图片路径必须来自数据库资产授权，
元数据 outbox 支持重试、冲突处理和重启恢复。应用不启动本地 HTTP 服务，也不依赖
浏览器渲染运行时。

## 文档

- [开发与贡献指南](DEVELOPMENT.md)：构建/测试、IPC 契约精华、本地化体系、HIG 约定
- [架构决策记录](ADR.md)：ADR-001~020 既有决策 + 性能决议与四项遗留方案（ADR-021~026）
- [路线图](ROADMAP.md)：已完成勾除、未完成保留的更新路线图

## 许可证

Gather 使用 [MIT License](../LICENSE)。
