# Gather

面向 Capture One 的本地优先原生照片挑选与目录协作工具。

Gather 把本地文件夹或 Capture One 选中项组织成工作区，在一个 SwiftUI 桌面应用中
完成浏览、挑片、相似照片审核、人脸关键词标注和可靠的元数据写回。

## 架构

SwiftUI（GatherUI）→ AppServices（16 个域 API / 195 个类型化方法）→ GatherHost
（AppComposition / AppRuntime / Live*API）→ GatherApplication（服务、JobService、
WorkflowRegistry 的 8 条 workflow）；交付在 GatherDelivery，持久层是 GatherPersistence，
图像/人脸在 GatherAnalysis，XMP/JPEG/IPTC 写盘在 GatherMetadataIO。

- SQLite（WAL）单一当前 schema：`SchemaCurrent` 55 表 / 451 列 / 86 索引 / 81 外键，
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

### 集合层级（命名路径约定）

集合名支持 `A/B/C` 形式的层级路径：侧栏按 `/` 把扁平集合列表组装成树（父节点可以只是分组、没有对应集合记录），新建时可直接输入路径，重命名即「改名/移动」（改父路径 = 换父；父集合改名会连同子集合一起移动）。**这是命名约定，不是数据库父子关系**：`collections` 表仍是扁平表、没有 `parent_id`，真正的 schema 层级（parent_id + 级联策略）需要一次 `user_version` 迁移并另行决策（见 [ROADMAP.md](ROADMAP.md)）。

## 快速开始

- macOS 26+、Xcode 26+（Swift 6.2+）；Capture One 可选。Open With 插件（`desktop/coplugin/GatherLink`）走 `gather://import?source=capture-one`，导入时保留 Capture One 来源标记与判断数据。
- 测试入口：`./scripts/test.sh core|app`（或 `all`）。
- 完整 `.app` 只在发布/打包时构建：`./desktop/native/build.sh`。

## 当前基线（2026-11-18 四轮加固后采样，以脚本输出为准）

- 9 个功能 target（含测试/工具共 18 个）；16 个域 API / 195 个类型化方法。
- **声明口径**（`check-test-catalog.sh` 的 ratchet，按剥注释后的 `@Test`/`@Suite` 声明计）：
  core 2,001 `@Test` / 235 `@Suite`；app 1,266 / 184（合计 3,267 / 419，均不低于基线 2,502 / 283）。
- **最近一次 macOS 运行**（2026-11-16，当前 Linux 环境无法复跑）：core 1,970 tests / 290 suites +
  串行 25 tests / 4 suites（合计 1,995 / 294）；app 1,260 tests / 184 suites。core 声明 235 个
  `@Suite` 与运行时 294 的差额来自只有 `@Test`、没有 `@Suite` 的测试文件（运行时每个文件算一个隐式套件）。
- 17 个 `check-*.sh` 门禁（其中 16 项在 2026-11-17 本地全绿，`check-warnings` 需 macOS SDK、按 CI 口径待
  macOS runner 复验；新增三个 Linux 只读门禁：`check-repo-hygiene.sh`（7 节，含 shellcheck 与本地化用法守卫）、
  `check-docs-facts.sh`（文档基线数字须与源码事实一致）与 `check-perf-ratchet.sh`（性能反模式构造点只降不升，
  基线 docs/perf-baseline.json）；清单见 [DEVELOPMENT.md](DEVELOPMENT.md)）；
  en 2,682 键 / zh-Hans 9 占位键。

## 文档

| 文档 | 内容 |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 环境、目录、测试、构建/发布、架构约定、本地化/HIG、门禁、API 契约 |
| [ADR.md](ADR.md) | 架构决策记录 |
| [ROADMAP.md](ROADMAP.md) | 路线图与当前状态 |
| [delivery-lock-order.md](delivery-lock-order.md) | 锁顺序 |
| [test-runtime-audit.md](test-runtime-audit.md) | 测试体系审计 |
| [validation/2026-10-31-plan.md](validation/2026-10-31-plan.md) | 发布前验证执行方案（V0–V8）与台账 |
| [cleanup-backlog.md](cleanup-backlog.md) | 清理台账（门禁输入） |
| [design/appearance-interaction.md](design/appearance-interaction.md) | 设计系统与页面配方 |
| [design/functional-usability-remediation-2026-10-29.md](design/functional-usability-remediation-2026-10-29.md) | 功能与易用性整改 |
| [reviews/2026-11-17-quality-hardening/00-overview.md](reviews/2026-11-17-quality-hardening/00-overview.md) | 2026-11-17 质量加固审计（round-1）：整洁度 / 规范 / 测试 / 设计 / 性能 |
| [reviews/2026-11-17-round2-hardening/00-overview.md](reviews/2026-11-17-round2-hardening/00-overview.md) | 2026-11-17 第二轮全量加固审计：性能 / 测试 / 门禁 / 国际化 / 设计 |
| [reviews/2026-11-17-round3-perf/00-overview.md](reviews/2026-11-17-round3-perf/00-overview.md) | 2026-11-17 第三轮性能专项加固审计：DB / 查询 · 渲染 · 启动 / 缓存 · 性能门禁 |
| [reviews/2026-11-18-round4-perf/00-overview.md](reviews/2026-11-18-round4-perf/00-overview.md) | 2026-11-18 第四轮性能专项：SQLite / 查询 · 渲染缓存 · 任务 / 内存 · 性能门禁 |
| [reviews/README.md](reviews/README.md) | 评审与审计索引（分轮报告入口与门禁基线记账约定） |

## 许可证

MIT
