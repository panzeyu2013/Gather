# Cut 1 执行简报（类型化 API + 删除 Router）

> **状态（2026-10-22）**：已完成。实际结果、证据与验收见
> [cut1-completion-report.md](cut1-completion-report.md)；本文保留原计划（历史）。
>
> 依据：docs/reviews/refactor-design-breaking-2026-10-21.md §3、§8、§9；
> 输入：docs/api-migration-map.md（Cut 0 产出）、docs/cleanup-backlog.md；
> 目标：用 15 个域协议替代 118 条字符串命令，删除 Router/JSON envelope，UI 全部改 typed API。

## 基线

- 118 条命令（82 sync / 36 async），Router 3,258 行、24 个依赖。
- Protocol 层已有大量 *Params 类型（CullingListPageParams、ExportExecuteParams 等），优先复用。
- UI 侧 81 处 execute/executeAsync 调用，分布在 12 个文件。
- 服务层已有 public 方法：Culling 24、Job 16、MetadataSync 15、FaceKw 15、Writeback 11、Session 11、Filter 7、Export 7、Duplicate 7。

## 阶段与文件所有权

> 细化批次以 docs/api-migration-map.md §7 的 B0-B8 为准（16 协议 / 110 方法 / 17.5 人日）。本文件的 1A-1E 是粗粒度归属：
> 1A=B0（协议与共享类型）；1B=B1+B2；1C=B3；1D=B4+B5；1E=B6+B7；1F=B8（删除与测试收口）。
> 当前已启动 1A（Agent b3e916bc-913e-4b14-9ee4-60aced4410b2）。

| 阶段 | 内容 | 所有者（单个 subagent） | 产出 |
| --- | --- | --- | --- |
| 1A | API 协议与输入/输出类型 | Agent API | Sources/GatherCore/API/{Session,Culling,Export,Jobs,...}API.swift |
| 1B | Live API 实现：Session/Culling/Jobs/Export | Agent CoreA | Sources/GatherApp/Host/APIs/{Session,Culling,Jobs,Export}API.swift |
| 1C | Live API 实现：Metadata/Face/Similarity/Duplicate/Person/Album/Filter/Navigation/Settings/Image/Template/Quality/Index/Assets/Workspace | Agent CoreB | Sources/GatherApp/Host/APIs/*.swift |
| 1D | UI 迁移 12 个文件 + 删除 Router/命令面 | Agent UI | Culling/Settings/Export/Duplicates/FaceKeywording/ControlCenter/Sources/GatherApp/* |
| 1E | 测试：API 行为测试、删除命令面测试 | Agent Test | Tests/APITests、删除 CommandSurfaceRuntimeTests/StubCommandRouter |

## 规则

- 阶段 1A/1B/1C 可并行；1D 依赖 1A+1B+1C 的协议与实现；1E 与 1D 同步。
- 1B 与 1C 不得修改同一文件；共享类型只由 1A 所有。
- 每个 API 方法必须保留 Router 的校验：MISSING_PARAM、范围钳制、路径授权、confirmed 门禁。
- 破坏性操作输入用 Confirmed<T>；不再有裸 confirmed: Bool。
- 每阶段结束必须 swift build 两包通过；1D 结束后 0 处 execute("x.y")。
- 不做兼容层；Router 在 1D 一次性删除，不保留双路径。

## 测试与契约（结合 D-001 / D-003）

- 删除命令面测试：CommandSurfaceRuntimeTests、StubCommandRouter 相关、NativeCommandClientTests 中只测 JSON envelope 的用例。
- Protocol 契约测试按 D-001：删除 TS/参数字典/JSON envelope parity（约 160 条）；保留并改写约 30 条 DTO Codable 往返；ErrorLocalizationCoverage 改为 GatherError + L10n.errorText。
- 新增 API 行为测试：每个域至少覆盖
  1. happy path；
  2. 缺参/非法参数（等价 MISSING_PARAM/INVALID_PARAM）；
  3. 路径未授权（PHOTO_NOT_FOUND）；
  4. destructive 未确认；
  5. job 取消/失败（涉及 job 的域）。
- 迁移测试在 Cut 1 不动；Cut 2 删除迁移链时，按 D-003 把 makeMigratedDB 改为 makeTestDatabase（SchemaV1 内存库），保留 57 个业务断言，只删版本升级/回滚用例。
- 测试目标：Cut 1 结束后 core/app 测试数可以下降（删除命令面契约），但每个保留测试必须能指出保护的行为；API 行为测试新增不少于 60 条。

## 验收

- 0 条字符串命令调用；0 个 CommandRouter/WebResponse/NativeCommandClient 引用。
- 118 条行为由 API 测试覆盖（每域至少 happy + 参数错误 + 权限/确认错误）。
- UI 可构建启动；core/app 测试绿；清理账：删除约 3,500 行、删除 5 个文件、删除 118 个命令符号。
