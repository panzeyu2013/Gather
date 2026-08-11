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
> 发布活动，不是本轮代码重构验收门。

## 核心工作流

| 工作流 | 主要能力 |
| --- | --- |
| **工作台与图库** | 工作区管理、跨工作区浏览、组合筛选、逻辑 RAW/JPEG 资产和分页图库。 |
| **挑片** | 保留/淘汰、星级、色标、对比、撤销/重做、元数据同步、失败重试和清理。 |
| **相似度与重复** | dHash 聚类、阈值审核、精确/视觉重复组和安全处理。 |
| **人物与人脸关键词** | 原生 Vision 推理调度、簇审核、人物绑定和 XMP 关键词写回。 |
| **导出与任务** | 预览、变体输出、JPEG/TIFF 转换、XMP 复制、可恢复任务、取消和报告。 |

## 快速开始

### 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools，支持 Swift 5.9+
- 仅使用本地文件夹时不要求 Capture One
- 人脸分析使用系统 Vision；真实数据集推理质量属于本轮明确跳过的外部验收

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

产物位于 `dist/native/Gather.app`。脚本只构建 Swift 核心和 SwiftUI 应用，不需要
JavaScript 工具链；设置 `CODESIGN_IDENTITY` 后才会执行可选签名。

## 数据与安全模型

```text
SwiftUI → SessionCommandRouter → GatherCore 服务
                                  ├─ SQLite（WAL + 迁移）
                                  ├─ Vision/ImageIO/RAW 解码
                                  └─ XMP 与元数据写回队列
```

破坏性操作需要显式确认，图片路径必须来自数据库资产授权，元数据 outbox 支持重试、
冲突处理和重启恢复。应用不启动本地 HTTP 服务，也不依赖浏览器渲染运行时。

## 文档

- [开发与贡献指南](DEVELOPMENT.md)
- [测试指南](TEST.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
- [原生开发分析](NATIVE-DEVELOPMENT-ANALYSIS.md)

## 许可证

Gather 使用 [MIT License](../LICENSE)。
