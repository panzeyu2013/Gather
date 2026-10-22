# Gather 架构整改设计与执行方案（2026-10-22）

> 依据：docs/reviews/architecture-macro-2026-10-22.md、architecture-macro-core.md、architecture-macro-app.md。
> 设计冻结在本文件；执行进度写 docs/refactor-progress.md，决策写 docs/refactor-decisions.md。
> 原则：保持模块化单体；不做 feature target、不引入 TCA/reducer、不重写 UI；每个 WP 行为保持、独立提交、独立验收。

## 0. 目标与非目标

目标：
1. 把 GatherDomain 从应用服务 + 数据访问 + 文件编排收敛为明确的 Application 层。
2. 把 Delivery 从跨 feature 的巨型 Coordinator 提取为可独立测试的 Delivery 引擎。
3. 把 Host 的 SwiftUI 外壳与 UI 的 Live provider 归位；删除同步 API 双面。
4. 把 Protocol 公开面从历史沉积收敛到当前契约。
5. 为 1.0 建立 Schema 迁移与可复现发布路径。

非目标：
- 不拆 Culling/Face/Similarity 为独立 target（会形成 feature 间环）。
- 不引入全局 reducer/TCA；保留 @Observable VM + SessionWorkspace。
- 不重写 SwiftUI 页面；只移动归属、收敛生命周期。
- 不在本轮改产品功能/视觉。

## 1. 目标架构

~~~text
GatherApp
  └─ GatherHost（组合根 / Live API / 平台桥）
       ├─ GatherUI（页面 + VM + Shell，只依赖 Protocol）
       ├─ GatherApplication（用例编排；原 GatherDomain）
       │    ├─ GatherDelivery（交付引擎）
       │    │    ├─ GatherPersistence（SQLite/Schema/Repo）
       │    │    └─ GatherProtocol
       │    ├─ GatherPersistence
       │    ├─ GatherAnalysis
       │    └─ GatherProtocol
       └─ GatherProtocol
GatherSchema → GatherPersistence
Benchmarks → GatherProtocol + GatherAnalysis
GatherTestSupport（product）→ GatherProtocol + GatherPersistence
~~~

依赖规则：Protocol 零依赖；Persistence/Analysis 只依赖 Protocol；Delivery 只依赖 Protocol+Persistence；Application 依赖 Delivery/Persistence/Analysis；UI 只依赖 Protocol；Host 依赖全部；App 只依赖 Host/UI。

## 2. 所有权矩阵

| 关注点 | 唯一 owner |
| --- | --- |
| API/DTO/错误码 | GatherProtocol |
| SQLite/Schema/Repo | GatherPersistence |
| 人脸/相似度算法 | GatherAnalysis |
| Delivery 状态机/文件阶段/Intent | GatherDelivery |
| 用例编排 | GatherApplication |
| 页面/VM/Shell | GatherUI |
| 组合根/Live API/平台桥 | GatherHost |
| App 生命周期 | GatherApp |

## 3. 工作包

### WP0 基线冻结（0.5 人日）
- 记录 core 1128/159、app 616/68、ratchet 53/235/127、Application SQL 125/40、public 4259、Host SwiftUI 882 行。
- 每 WP 一个 commit；验收 8 门禁 + schema verify。

### WP1 Protocol 瘦身（约 2 人日）
设计：删除 89 个零引用类型（约 942 行）+ 6 个 Router 信封（Core.swift 约 160-320）；保留 API 输入输出/错误码/确认/分页/路径。新增 scripts/check-protocol-surface.sh 统计 public 类型与零引用（ratchet 只降不升）。
步骤：生成候选（find-unused-symbols + 全仓 grep）→ 删除类型与对应 ContractTests → 更新 APIContractIndex/文档 → core/app 全量。
验收：Protocol 类型 347→≤260；零引用=0；core/app 绿；门禁绿。风险：动态/反射使用；用 grep + 契约测试双证。

### WP2 Delivery 引擎（6–8 人日）
设计：新增 GatherDelivery target。
- Coordinator/DeliveryCoordinator.swift（≤600 行/文件）
- Coordinator/DeliveryStateMachine.swift（显式迁移表）
- Coordinator/DeliveryIntentStore.swift（prepare/advance/finish 单事务）
- File/DeliveryFilePhase.swift（verify→restore/remove→verify，持 XMPFileLock）
- File/XMPFileLock.swift
- Writeback/WritebackService.swift、MetadataMutationService.swift
- Ports/DeliveryFilePort.swift、MetadataMutationPort.swift、DeliveryModuleAdapter.swift
下移依赖：XMPProvider、MetadataContract 移到 Protocol；MetadataFingerprint、PhotoAssetResolver 移到 Persistence；DeliveryRepo/Intent/Summary/State 留 Persistence。
收敛 owner：所有状态写入经 DeliveryStateWriter；DB 删除 + intent.finish 同一事务（当前 Coordinator:1615 与 :1712 两事务合并）；feature 差异由 DeliveryModuleAdapter 提供（4 个），Coordinator 不再 switch 模块。
步骤：2a 纯移动（1–2 天）→ 2b 拆 Coordinator（2–3 天）→ 2c 适配器（2–3 天）→ 迁移/新增测试。
验收：Coordinator ≤600 行/文件；状态写入 35→≤8；adapter 15→≤5；finish 单事务；core/app 绿；锁顺序文档 + 压力测试。
风险：XMPProvider 下移依赖方向；用端口 + typealias 过渡。

### WP3 Application 层（5–8 人日）
设计：GatherDomain 重命名 GatherApplication（纯移动 1 天）。Persistence 增加 Ports：Session/Photo/Face/Similarity/Delivery/Job/Metadata/Asset Repository；Application 只注入 any XxxRepository，不持 DBConnection；复杂查询下沉 Query。按用例拆大服务：Culling→Query/Command/Writeback；Face→Cluster/Review/Writeback；Similarity→Analyze/Writeback。
步骤：3a 重命名+Ports（2 天）→ 3b Culling（2–3 天）→ 3c Face/Similarity（2–3 天）→ 3d SQL ratchet。
验收：Application 内 connection.prepare ≤15；>1000 行文件=0；核心测试可改用 fake repo ≥50%；全绿。

### WP4 App 语义归位（5–8 人日）
设计：D-017，把 RootView/RootShell*（约 882 行）迁入 GatherUI/Shell；Host 只留 AppBootstrap/AppComposition/AppRuntime/AppDelegate/Live API/桥。3 个 Live provider 从 UI 移到 Host；UI 定义数据端口。删除 27 个 Live 同步核 + 18 个 UI 同步端口 + SyncAPIPortBridge（Dashboard 先行，再 Library/Gallery）。AppComposition 拆 Core/FeatureAPIs/Root；删 AppServices 未用 override 与 9 个 makeX，目标 ≤200 行/文件。统一 7 VM 的 PageVisibility/LoadPhase 契约。
验收：Host 内 SwiftUI 文件=0（AppDelegate 除外）；sync 端口=0；Composition ≤200 行/文件；app 616 绿；生命周期矩阵测试。

### WP5 Culling/Face 角色拆分（10–15 人日，最后）
按 query/command/writeback 拆 CullingService 2,800 与 FaceKwService 2,544；目标单文件 ≤800 行、77/43 方法分布到 3 类服务。放最后，前置 WP2/WP3。

### WP6 Schema 迁移与发布（5–8 人日）
设计：SchemaVersion（user_version=2 或 schema_migrations 表）+ Migration 协议；Database.open：current 校验 shape；older 备份→事务迁移→校验；newer incompatible/fail closed；开发重置只允许 GATHER_DEV_RESET=1。发布：固定 SDK/Swift、universal、sign、notarize、staple、版本注入。
验收：V1 数据迁移到 V2 保留；失败回滚；迁移测试 + 发布 job。风险：不可逆；备份 + fail closed。

### WP7 测试/构建/可观测性（3–5 人日）
- GatherTestSupport 改为 library product；app 测试依赖；删 TestDatabase/AsyncGate/LockedBox 复制。
- Package.swift 移除 xcrun manifest 调用；SDK 由 build.sh/CI 环境提供。
- CI 加 gather-schema verify；新增 test count/coverage ratchet；Delivery/Job trace id。
验收：app test target 依赖 product；manifest 无 Process/xcrun；CI 绿。

## 4. 执行顺序与并行

| Wave | 内容 | 日历 | 依赖 |
| --- | --- | ---: | ---: |
| W0 | WP0 + WP1 + WP7 测试/构建 | 4–5 天 | 无 |
| W1 | WP2 Delivery（2a→2b→2c） | 6–8 天 | WP1 |
| W2 | WP3 Application 与 WP4 App 并行 | 8–10 天 | W1 |
| W3 | WP5 拆分 + WP6 迁移/发布 | 10–15 天 | W2 |

并行：W1 可与 WP4 shell 移动并行；WP4 provider async 等 WP2 接口稳定；W2 core/app 可并行但 Protocol 变更先冻结；WP6 设计可早开始、执行放 W3。

## 5. 每 WP 验收命令

~~~bash
swift test --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
./scripts/check-layering.sh
./scripts/check-cleanup-ratchet.sh
./scripts/check-test-catalog.sh --strict
./scripts/check-duplicate-symbols.sh --strict
./scripts/check-docs.sh --strict
./scripts/check-no-legacy.sh
./scripts/check-select-star.sh --strict
./scripts/check-preview-surface.sh --strict
swift run --package-path desktop/native/gather-core gather-schema verify
~~~

## 6. 指标基线 → 目标

| 指标 | 当前 | 目标 |
| --- | ---: | ---: |
| Application connection.prepare | 125 | ≤15 |
| Application 持 DBConnection 文件 | 16/28 | 0 |
| Delivery 状态写入点 | 35 | ≤8 |
| Delivery 模块适配器方法 | 15/25 | ≤5 |
| DeliveryCoordinator 行数 | 1964 | ≤600/文件 |
| Protocol 类型 | 347 | ≤260 |
| Protocol 零引用类型 | 89 | 0 |
| Host 内 SwiftUI 外壳 | 882 行 | 0 |
| 同步 API/端口 | 27+18 | 0 |
| AppComposition 行数 | 390 | ≤200/文件 |
| Schema 版本 | 1（重置） | 2+（迁移） |

## 7. 风险与回滚

- WP2 最高风险：先纯移动保留行为，再拆逻辑；每步一个可回滚 commit。
- WP3 重命名/协议化：用 typealias/转发过渡，保留旧入口一个版本。
- WP6 迁移不可逆：强制备份、fail closed；开发重置只允许显式环境变量。
- WP4 shell 移动：RootShellDependencies 注入，先移动再改依赖。
- 任何 WP 失败：回滚该 commit，不影响其他 WP；记录 drift。

## 8. 结论

先 WP1（便宜、降契约噪音）与 WP2（最高风险、最高收益），再 WP3/WP4 并行；WP5 最后；WP6 在 1.0 前必须完成。整体约 35–50 人日，2–3 人并行约 4–6 周。
