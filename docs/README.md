# Gather

面向 Capture One 的本地优先原生照片挑选与目录协作工具。

Gather 把本地文件夹或 Capture One 选中项组织成工作区，在一个 SwiftUI 桌面应用中
完成浏览、挑片、相似照片审核、人脸关键词标注和可靠的元数据写回。

## 架构

SwiftUI（GatherUI）→ AppServices（16 个域 API / 172 个类型化方法）→ GatherHost
（AppComposition / AppRuntime / Live*API）→ GatherApplication（服务与 JobService）；
交付在 GatherDelivery，持久层是 GatherPersistence，图像/人脸在 GatherAnalysis。

- SQLite（WAL）单一当前 schema：`SchemaCurrent` 55 表 / 449 列 / 84 索引 / 81 外键，
  `user_version=1`。旧版本/未知形态默认 fail closed，只有显式重置才归档重建。
- 无 Node.js、Electron、浏览器渲染层或本地 HTTP 服务。

## 核心工作流

| 工作流 | 主要能力 |
| --- | --- |
| 工作台与图库 | 工作区、跨区浏览、组合筛选、逻辑 RAW/JPEG 资产、分页 |
| 挑片 | 保留/淘汰、星级、色标、对比、撤销/重做、同步与重试 |
| 摄取 | 存储卡/文件夹导入、EXIF 重命名、校验和、可选第二目的地 |
| 元数据与 IPTC | EXIF/XMP/IPTC 读写、32 个 IPTC 字段编辑、批量模板、批次撤销 |
| 技术建议 | 技术质量建议（Beta），可移植信号与批次撤销 |
| 淘汰移出 | 移到 `_rejects`（不删除），RAW/JPEG 同移，共享 `.xmp` 复制 |
| 相似度与重复 | dHash 聚类、阈值审核、精确/视觉重复、安全处理 |
| 人物与人脸关键词 | Vision 分析、簇审核、人物绑定、XMP 写回 |
| 导出与任务 | 预览、变体输出、JPEG/TIFF、XMP 复制、可恢复任务 |

## 快速开始

- macOS 26+、Xcode 26+（Swift 6.2+）；Capture One 可选。
- 测试入口：`./scripts/test.sh core|app`（或 `all`）。
- 完整 `.app` 只在发布/打包时构建：`./desktop/native/build.sh`。

## 当前基线（2026-10-30 交互整改后采样，以脚本输出为准）

- 8 个功能 target（含测试/工具共 16 个）。
- gather-core 1,609 tests / 239 suites；gather-app 829 tests / 93 suites。
- 12 个 `check-*.sh` 门禁（2026-10-30 移除 `check-docs.sh`）；en 2,015 键 / zh 9 占位键。

## 文档

| 文档 | 内容 |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 环境、目录、测试、构建/发布、架构约定、本地化/HIG、门禁、API 契约 |
| [ADR.md](ADR.md) | 架构决策记录 |
| [ROADMAP.md](ROADMAP.md) | 路线图与当前状态 |
| [delivery-lock-order.md](delivery-lock-order.md) | 锁顺序 |
| [test-runtime-audit.md](test-runtime-audit.md) | 测试体系审计 |
| [cleanup-backlog.md](cleanup-backlog.md) | 清理台账（门禁输入） |
| [design/appearance-interaction.md](design/appearance-interaction.md) | 设计系统与页面配方 |
| [design/functional-usability-remediation-2026-10-29.md](design/functional-usability-remediation-2026-10-29.md) | 功能与易用性整改 |

## 许可证

MIT
