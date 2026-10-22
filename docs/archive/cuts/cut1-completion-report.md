# Cut 1 完成报告（B8.5 收口）

> 日期：2026-10-22（Asia/Shanghai）。状态：**Cut 1 完成**。
> 范围：B8.5 文档收口、cleanup ratchet、已删路径引用、完成报告；
> 生产逻辑不改（仅删除 4 个新增类型上多余的 `@unchecked Sendable`，并修正 1 处注释）。
> 索引：[refactor-progress.md](../../refactor-progress.md)、[api-migration-map.md](api-migration-map.md)、
> [refactor-decisions.md](../../refactor-decisions.md) D-036..D-081。

## 1. 目标

Cut 1 的目标是用类型化域 API 替代 118 条字符串命令，删除 Router/命令面并保留原有校验与确认语义。
B8.5 只做收口：审计 ratchet 漂移、让文档与已删路径一致、跑门禁、给出可复核的完成证据。

验收口径（来自 [cut1-execution-brief.md](cut1-execution-brief.md)）：

- 0 条字符串命令调用；0 个 CommandRouter/WebResponse/NativeCommandClient 引用；
- 118 条行为由 16 个协议 / 110 个方法覆盖；
- UI 可构建启动；core/app 测试绿；删除账可复核。

## 2. 结果摘要

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 字符串命令 | **0** | 见 §3.1（grep 0 命中） |
| 域协议 | **16 个 / 110 个方法** | `gather-core/Sources/GatherCore/API/*API.swift`；逐协议计数见 §3.2 |
| Router/Client | **0 文件、0 引用** | `check-no-legacy.sh` R5（脚本 74-76 行）全部 enforced 0 |
| 删除 | **7 文件 / 4,052 行** | 逐文件 HEAD 行数见 §5 |
| 测试 | **app 455/55、core 1080/149** | 2026-10-22 本机 `swift test`（app 加 `--no-parallel`） |
| 清理 ratchet | **55 / 287 / 132 / 0 / 0** | `docs/cleanup-baseline.json`；`check-cleanup-ratchet.sh` OK |
| 文档门禁 | **PASS（--strict 也 OK）** | `check-docs.sh`；ADR 缺失路径 0、schema 35 一致 |
| enforced 回潮 | **0** | R5 四类 tracked 0；enforced 规则 7 条全过 |

## 3. 指标与证据

### 3.1 命令面归零

    grep -rnE 'execute(Async)?\( *"|enqueue\( *"' desktop/native/gather-app --include='*.swift' | grep -v '/.build/' | wc -l
    # 0
    grep -rnE 'SessionCommandRouter|CommandRouter|NativeCommandClient|WebResponse|StubCommandRouter' \
      desktop/native/gather-app desktop/native/gather-core --include='*.swift' | grep -v '/.build/' | wc -l
    # 0

`check-no-legacy.sh:74-76` 对三类符号做 0 文件断言；删除后的 Router 文件不存在：

    test ! -e desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
    test ! -e desktop/native/gather-app/Sources/GatherApp/Host/CommandRouter.swift
    test ! -e desktop/native/gather-app/Sources/GatherApp/Support/NativeCommandClient.swift
    test ! -e scripts/check-command-surface.sh

### 3.2 16 个协议 / 110 个方法

| 协议 | 文件:行 | 方法数 |
| --- | --- | ---: |
| SessionAPI | `API/SessionAPI.swift:18` | 7 |
| CullingAPI | `API/CullingAPI.swift:19` | 17 |
| ExportAPI | `API/ExportAPI.swift:15` | 4 |
| JobAPI | `API/JobAPI.swift:14` | 5 |
| DuplicateAPI | `API/DuplicateAPI.swift:13` | 4 |
| FaceAPI | `API/FaceAPI.swift:21` | 13 |
| SimilarityAPI | `API/SimilarityAPI.swift:20` | 10 |
| PhotoAPI | `API/PhotoAPI.swift:18` | 7 |
| AlbumAPI | `API/AlbumAPI.swift:15` | 5 |
| PersonAPI | `API/PersonAPI.swift:15` | 8 |
| MetadataAPI | `API/MetadataAPI.swift:15` | 7 |
| SettingsAPI | `API/SettingsAPI.swift:15` | 6 |
| NavigationAPI | `API/NavigationAPI.swift:14` | 4 |
| AssetAPI | `API/AssetAPI.swift:15` | 5 |
| QualityAPI | `API/QualityAPI.swift:13` | 2 |
| TemplateAPI | `API/TemplateAPI.swift:13` | 6 |
| **合计** | | **110** |

计数命令：

    grep -hE '^    (public )?func ' desktop/native/gather-core/Sources/GatherCore/API/*API.swift | wc -l
    # 110

### 3.3 组合根、确认与路径授权

- `AppComposition.make(db:)`（`Host/AppComposition.swift:75`）构造唯一 db/服务/runtime；
  `AppServices.live(composition:)`（`Host/APIs/AppServices.swift:109`）只包装共享实例。
- `AppRuntime.start()` / `shutdown()`（`Host/AppRuntime.swift:74/97`）负责 executor 注册、
  JobService 启停、coordinator 排空与 db.close；重复 shutdown 等同一个 Task。
- 破坏性入口只接收 `Confirmed<Value>`（`API/Core/Confirmed.swift:22`）；类型层面禁止裸 Bool。
- 路径授权由 `PhotoPathPolicy`（`API/Core/PhotoPathPolicy.swift:15`）承担；未授权返回
  `PHOTO_NOT_FOUND`，不暴露任意文件读取。
- 错误漏斗仍是 `APIErrorPresentation`；旧 `RouterCommandError` 只作为错误载体保留。

### 3.4 UI 注入

页面只接收 `any XxxAPI`（`RootView` / 六个功能页 / Dashboard 的 provider 已迁移）；
`AppServices` 的 16 个字段与 §3.2 的协议一一对应。`GatherAppDelegate` 的 import 路径改
`SessionAPI` + `JobAPI`，不再构造 Router。

## 4. Cleanup ratchet 审计

### 4.1 `unchecked_sendable`：59 → 55（新增 19 处）

19 处全部来自 Cut 1 新增文件：17 个 Live* 类型（16 个 API 门面 + `LivePhotoPathPolicy`）+ `AppRuntime` + `JobObserverBag`。

**删除 4 处多余的 `@unchecked`（改为协议继承的 Sendable，由编译器检查）：**

| 类型 | 位置 | 依赖 |
| --- | --- | --- |
| LiveJobAPI | `LiveJobAPI.swift:20` | JobService（Sendable） |
| LiveDuplicateAPI | `LiveDuplicateAPI.swift:38` | DuplicateService、JobService（均 Sendable） |
| LiveMetadataAPI | `LiveMetadataAPI.swift:33` | MetadataService、MetadataSyncCoordinator（均 Sendable） |
| LiveQualityAPI | `LiveQualityAPI.swift:31` | QualityService、JobService（均 Sendable） |

**保留 15 处（不能删）：**

| 类型 | 数量 | 保留理由 |
| --- | ---: | --- |
| Live API 门面（Album/Asset/Culling/Export/Face/Navigation/Person/Photo/Session/Settings/Similarity/Template） | 12 | 依赖的 Repo/Service（SmartAlbumRepo、FilterEngine、CullingService、ExportService、FaceKwService、NavigationService、PersonRepo、PhotoRepo、SessionService、SettingsService、SimilarityService、TemplateService 等）仍非 Sendable；给它们加 Sendable 属于 Cut 2/3 的服务边界收口 |
| LivePhotoPathPolicy | 1 | 依赖 PhotoRepo（非 Sendable） |
| AppRuntime | 1 | `lifecycle` / `shutdownTask` / `registeredTypes` 在 NSLock 内读写，可变状态无法静态证明 |
| JobObserverBag | 1 | `tokens` / `removed` 在 NSLock 内读写；onTermination 与补发路径可能并发 |

结论：55 是当前结构下的下限；继续下降需要先把 Repo/Service 改为 Sendable 或引入 actor，
不在 B8.5 的文档收口范围内。

### 4.2 `services_prepare`：128 → 132（净增 4）

新增 5 处匹配、删除 1 处，净 +4：

| 位置 | 内容 | 处置 |
| --- | --- | --- |
| `Services/DeliveryCoordinator.swift:633` | `SELECT COUNT(*) ... confirmed_at = ''`（删行前复核未确认链接） | 保留 |
| `Services/DeliveryCoordinator.swift:640` | `DELETE FROM delivery_items` | 保留 |
| `Services/DeliveryCoordinator.swift:642` | `DELETE FROM delivery_sessions` | 保留 |
| `Services/DeliveryCoordinator.swift:644` | `DELETE FROM deliveries`（带 revision/status 守卫） | 保留 |
| `Services/DeliveryCoordinator.swift:414` | `intentRepo.prepare(`——仓储方法名，不是 SQL | 保留（指标误计） |
| `Services/FaceKwService.swift`（删除） | `refreshClusterMemberCounts` 的 1 条 `prepare(` | 已删（派生缓存刷新移除；成员真相源仍是 `face_cluster_members`） |

4 条 SQL 是 S5c-2a cleanup 的原子事务：文件阶段是 await，删行前必须再确认没有新会话链入，
然后在同一事务删除 items/sessions/deliveries。拆成 Repo 方法属于 Cut 2/3 的 Repository 收口，
不能在 B8.5 改动生产逻辑。baseline 因此更新为 132，并在 [refactor-progress.md](../../refactor-progress.md) §4 记录。

### 4.3 其他指标

- `try_optional` 348 → **287**：Cut 1 删除 JSON envelope/旧测试后自然下降；baseline 收紧到 287，
  防止回升。
- `todo_fixme` 0、`with_known_issue` 0：保持不变。
- baseline 由 `./scripts/check-cleanup-ratchet.sh --write-baseline` 生成，
  `generated_at` 为 2026-10-21T19:01:01Z（本地 2026-10-22 03:01）。

## 5. 删除清单

| 文件 | HEAD 行数 | 说明 |
| --- | ---: | --- |
| `Sources/GatherApp/Host/SessionCommandRouter.swift` | 3,258 | 118 命令、24 依赖、参数校验/JSON envelope |
| `Sources/GatherApp/Host/CommandRouter.swift` | 51 | `WebResponse` + Router 协议 |
| `Sources/GatherApp/Support/NativeCommandClient.swift` | 77 | 字符串客户端/错误漏斗旧副本 |
| `Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift` | 296 | 118 命令黄金清单 |
| `Tests/GatherAppTests/NativeCommandClientTests.swift` | 223 | JSON envelope/漏斗对拍 |
| `Tests/GatherAppTests/Support/StubCommandRouter.swift` | 38 | 测试桩 |
| `scripts/check-command-surface.sh` | 109 | 命令面文本门禁 |
| **合计** | **4,052** | 7 文件 |

另删除（不进上表）：

- legacy adapter/包装：RouterCulling/RouterNavigation/RouterMetadata、RouterFace/RouterFaceJob/
  FaceLegacySyncLoading、LegacySimilarityAPIAdapter；
- 工作区测试支撑 `AppCompositionTestSupport`（约 73 行，按 D-080 差额推算，未进 HEAD）；
- 118 个命令符号、`photo.list`/`culling.decide`/`culling.batch_decide`/`album.get` 4 条真删除命令，
  `fkw.confirm_cleanup` 等 4 条合并命令（行为由 API 方法覆盖）。

> 行数口径：D-080 的 3,568 = 生产 3 文件 3,386 + 脚本 109 + AppCompositionTestSupport 约 73，
> 未计 3 个测试文件 557 行；本表按 `git show HEAD:<path> | wc -l` 实测 4,052。两套口径都在
> 本文与 D-081 留档，后续引用以 4,052（7 文件）为准。

## 6. 测试与门禁

### 6.1 测试

| 包 | 命令 | 结果 |
| --- | --- | --- |
| gather-core | `swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch` | **1080 tests / 149 suites passed** |
| gather-app | 同上 + `--no-parallel` | **455 tests / 55 suites passed** |

app 从 Cut 0 的 298 条增长到 455 条；D-080 记录本轮删除 9 条命令面/黄金清单/客户端测试，
新增 4 条错误漏斗测试。命令行为由 `Tests/GatherAppTests/API*Tests.swift` 覆盖（每域 happy +
参数错误 + 确认/路径错误）。

### 6.2 门禁

    ./scripts/check-cleanup-ratchet.sh   # OK（55/287/132/0/0）
    ./scripts/check-docs.sh             # PASS（--strict 也 OK）
    ./scripts/check-no-legacy.sh        # OK（7 enforced；R5 四类 0 file）
    ./scripts/check-layering.sh         # OK（未拆分 baseline 模式）
    ./scripts/check-duplicate-symbols.sh # PASS（warning mode）

`check-docs` 本次做了两处**门禁语义修正**（不是放宽）：

1. 反引号路径检查跳过显式标注“已删除”的行——ADR-028 删除清单与 Cut 1 已删脚本是历史记录，
   之前会被误报为缺失；
2. schema 比较优先只读 ADR 的“当前 schema”声明（现为 35），历史 ADR 的 33/34 不再造成假阳性；
   若没有该声明仍回退全文比较。

修正后 ADR 缺失路径 0、`docs/archive` 已建立、schema 一致，普通与 `--strict` 均 PASS。

## 7. 文档收口

| 文档 | 变更 |
| --- | --- |
| [refactor-progress.md](../../refactor-progress.md) | Cut 1 标完成；新增完成证据、删除账、ratchet 说明、S5c-2b |
| [api-migration-map.md](api-migration-map.md) | 标 16/110 已落地、B0-B8 完成；§2/§6 标历史快照 |
| [cleanup-backlog.md](../../cleanup-backlog.md) | CL-01 done；CL-02 改为 1,797 行待删；CL-11 部分完成 |
| [README.md](../../README.md) | 架构一句话改为 16 域 API；安全模型改 `Confirmed<T>` |
| [DEVELOPMENT.md](../../DEVELOPMENT.md) | 删除 118 命令/脚本门禁；新增类型化 API 契约与历史对照 |
| [ROADMAP.md](../../ROADMAP.md) | “命令面 118/118”改为“类型化 API 16/110” |
| [ADR.md](../../ADR.md) | 当前 schema 35/44 表；ADR-028 删除项与 check-command-surface 标“已删除”；Router 描述标历史 |
| [b8-router-removal-map.md](b8-router-removal-map.md) | 加“历史执行映射，已完成”横幅 |
| [test-audit.md](../../test-audit.md) | 加“历史快照”横幅 |
| [cut1-execution-brief.md](cut1-execution-brief.md) | 加“已完成”横幅 |
| [module-split-map.md](module-split-map.md) | check-command-surface 行改为“已删除” |
| [archive/README.md](../README.md) | 建立归档目录（Cut 6 搬迁入口） |

## 8. 遗留风险

1. **15 处 `@unchecked Sendable` 仍在**：依赖 Repo/Service 未 Sendable；需 Cut 2/3 的服务边界
   收口，不能只靠删注解。
2. **132 处 Services 内联 `prepare(`**：ratchet baseline 已上调；4 条新 SQL 属于 DeliveryCoordinator
   的原子 cleanup，后续 Repository 化时应连同事务一起迁移，不能只搬 SQL。
3. **人工 GUI smoke 未做**：新建/导入/索引/挑片/人脸/相似度/导出未在无 GUI 自动化下声称验收；
   只能记为待人工（与 D-080 一致）。
4. **Template 6 个方法保留但无 UI**：产品是否保留模板域仍未拍板；删除会变成 15/104，需另开决策。
5. **docs/reviews 22 篇未搬迁**：`docs/archive` 已建立，但物理归档属 Cut 6；当前靠横幅标记历史。
6. **ADR 历史 schema 33/34 仍留在正文**：这是决策历史，不是漂移；`check-docs` 只比较“当前 schema”
   声明。若未来要全文一致，应在 Cut 6 统一改写历史条目。

## 9. 下一步：Cut 2 S5c-2b

S5c-2b 承接 S5c-2a 的 Delivery/SchemaV1 接线，范围：

- writeback 执行器与 finalize：把 culling/fkw/sim 的写回路径接到 DeliveryCoordinator；
- `syncStatus` / reload ack：统一读 `deliveries`，删除旧 `writeback_items`/`metadata_outbox` 读路径；
- FaceKw 与旧表：delivery 化 face keyword 写回，移除旧表双写；
- 关联决策：D-054/055/060/062；验收：fresh DB 全功能 + 10 条 P0 门禁 + core/app 全绿。

完成 S5c-2b 后，Cut 2 的 SchemaV1/Delivery 主线收口，再进入 Cut 3a/3b 模块拆分。

## 10. 复现命令

    cd /Users/panzeyu2013/Desktop/code/develop/Gather
    ./scripts/check-cleanup-ratchet.sh
    ./scripts/check-docs.sh --strict
    ./scripts/check-no-legacy.sh
    ./scripts/check-layering.sh
    ./scripts/check-duplicate-symbols.sh

    cd desktop/native/gather-app
    swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
    cd ../gather-core
    swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
