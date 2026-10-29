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

**SwiftUI 页面 → 16 个域 API（129 个类型化方法，`AppServices` 注入）→ 8 个
SwiftPM target**：`GatherProtocol`（值类型/协议/错误码）、`GatherPersistence`
（SchemaCurrent/Database/仓储）、`GatherDelivery`（交付引擎）、`GatherAnalysis`
（聚类/人脸/图像）、`GatherApplication`（服务与任务）、`GatherUI`（页面/状态层）、
`GatherHost`（组合根/Live API）、`GatherApp`（入口）。SQLite（WAL，SchemaCurrent 44 表 /
386 列 / user_version=1）为唯一持久层，
Vision/ImageIO/RAW 解码负责图像，`JobService` 承载可恢复后台任务，
`DeliveryCoordinator` 负责可靠写回。无 Node.js、无 Electron、无浏览器渲染层、
无本地 HTTP 服务。

Cut 1 已删除 118 条字符串命令与 `SessionCommandRouter` / `CommandRouter` /
`NativeCommandClient`；历史命令映射见 [api-migration-map.md](archive/cuts/api-migration-map.md)。

> 当前基线（2026-10-29 测试审计后采样）：8 个功能 target、Schema **44 表 / 386 列 / 72 索引 / 65 外键（user_version=1）**、
> core **1,444 tests / 216 suites**、app **761 tests / 89 suites**（两包都用 `scripts/test.sh` 并行；app 并行的 NSWindow/KVO SIGSEGV 已于 2026-10-29 修复，排查单例时用 `--no-parallel`）、
> en 1,749 键 / zh 9 占位键；无 Router、无字符串命令。
> 只有当前 schema 可打开；旧迁移链已删除，旧版本/未知形态默认 fail-closed，仅显式重置策略才归档重建。
> **12 个** `check-*.sh` 门禁全绿（strict 可用者带 `--strict`，另有 test-catalog `--self-test` 负例）；
> ratchet **60/255/0/0/0**（较 54/228：新增摄取/模板/IPTC/交付代码带来的 +6/+27，
> 其中 2 处 `@unchecked Sendable` 已收敛为编译器校验的 `Sendable`；口径见
> [design/p1/iptc-progress.md](design/p1/iptc-progress.md)）。

## 核心工作流

| 工作流 | 主要能力 |
| --- | --- |
| **工作台与图库** | 工作区管理、跨工作区浏览、组合筛选、逻辑 RAW/JPEG 资产和分页图库。 |
| **挑片** | 保留/淘汰、星级、色标、对比、撤销/重做、元数据同步、失败重试和清理。 |
| **摄取** | 存储卡/文件夹导入：EXIF 日期与相机型号驱动重命名模板、校验和验证、可选第二目的地，RAW/JPEG 配对与图库同源。 |
| **元数据与 IPTC** | 读取有效 EXIF/XMP/IPTC（含 JPEG 内嵌 IPTC），单张编辑 32 个 IPTC Core/Extension 字段，批量套用命名模板，两条路径都可从批次历史撤销。 |
| **技术建议** | 技术质量建议（Beta）写成可移植信号（默认只写空评级、私有命名空间、可选关键词），带批次撤销守卫。 |
| **淘汰移出** | 把淘汰照片移到 `_rejects`（不删除）；RAW/JPEG 变体一起移，共享 `.xmp` 复制而非从留下的文件上拿走。 |
| **相似度与重复** | dHash 聚类、阈值审核、精确/视觉重复组和安全处理。 |
| **人物与人脸关键词** | 原生 Vision 推理调度、簇审核、人物绑定和 XMP 关键词写回。 |
| **导出与任务** | 预览、变体输出、JPEG/TIFF 转换、XMP 复制、可恢复任务、取消和报告。 |

## 目录结构

目录树、target 与各目录职责的唯一真相源是 [DEVELOPMENT.md](DEVELOPMENT.md)；本文不再
复制，避免两处漂移。

## 快速开始

### 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools，支持 Swift 6.0+
- 仅使用本地文件夹时不要求 Capture One
- 人脸分析用系统 Vision 做检测/对齐，身份特征来自随包分发的 SFace CoreML 模型
  （`FaceModels/SFace.mlpackage`，随 `build.sh` 一起校验与打包）；真实数据集推理
  质量属于明确跳过的外部验收

### 运行原生测试

```bash
# core：并行主批 + 4 个进程级状态套件串行批；app：并行（单例排障用 --no-parallel）。
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh core
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh app
```

默认测试套件只验证正确性；质量/召回/F1 基线与 CoreML/Vision 集成在夜间
(`.github/workflows/nightly.yml`) 运行。日常测试不组装 `.app`。

### 构建 macOS 应用（发布/打包）

```bash
./desktop/native/build.sh
```

完整 bundle 只在发布/打包时构建，不属于日常测试循环。

产物位于 `release/Gather.app`（可用 `OUTPUT_DIR` 覆盖）。脚本只构建 Swift 核心和
SwiftUI 应用，不需要 JavaScript 工具链；设置 `CODESIGN_IDENTITY` 后才会执行可选
签名（带 hardened runtime 与 `desktop/native/Gather.entitlements` 的 Apple Events
权限，并复核签名结果），公证与安装升级属于独立发布活动。组装门会断言内置
`SFace.mlpackage` + `manifest.json` 以及两套非空 `Localizable.strings`，模型或
本地化缺失会在打包时直接失败。

## 数据与安全模型

数据流与 API 契约的唯一真相源是 [DEVELOPMENT.md](DEVELOPMENT.md)。不变量：破坏性
操作必须显式确认（`Confirmed<T>` 编译期标记 + UI 真实弹窗；API 层仍校验输入与路径
授权）；图片路径必须来自数据库资产授权；写回经 `deliveries` 持久化，支持重试、
冲突处理和重启恢复。应用不启动本地 HTTP 服务，也不依赖浏览器渲染运行时。

## 文档

- [开发与贡献指南](DEVELOPMENT.md)：构建/测试、类型化 API 契约、本地化体系、HIG 约定
- [测试体系审计与优化](test-runtime-audit.md)：并行拆分、耗时/CPU/RSS、覆盖率与重叠审计（2026-10-29）
- [设计系统与页面配方](design/appearance-interaction.md)：token 角色、页面骨架、组件规则与 ratchet
- [架构决策记录](ADR.md)：ADR-001~020 既有决策 + 性能决议与遗留方案（ADR-021~029，
  含未接线资产删除裁决 ADR-028 与人脸管线 ADR-029）
- [Cut 1 完成报告](archive/cuts/cut1-completion-report.md)：118→16 协议/110 方法、Router 删除、
  门禁与 ratchet 收口（历史）
- [路线图](ROADMAP.md)：已完成勾除、未完成保留的更新路线图
- [最终报告](final-report.md)：Cut 0–6 指标、删除清单、验证证据、残余项与回滚说明
- [重构进度台账](refactor-progress.md) / [决策记录](refactor-decisions.md)：Cut 状态与 D-xxx（D-163 最终关闭）
- [历史文档归档](archive/README.md)：18 篇评审 + 10 篇 Cut 文档（行号为当时快照）

## 许可证

Gather 使用 [MIT License](../LICENSE)。
