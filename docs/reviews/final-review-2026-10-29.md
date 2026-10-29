# 最终全量评审（四视角）+ 处置（2026-10-29）

> 范围：对合并后的主线（HEAD `92a03c2c`，含 feat/sidecar 两次合并与三轮修复）派 4 个只读评审员，
> 分别从**正确性 / 完整性 / 最优性 / 简洁性**四个视角全量检查。本文件记录发现与处置：
> 已修的直接落到 `fix(final-review)` 提交；未修的明确写原因与下一步，不隐藏。
>
> 评审方式：只读（不改文件、不跑 build/test/门禁），结论均带 `file:line` 与证据原文。

## 1. 四视角结论

| 视角 | 结论 | P0 | P1 | P2 |
|---|---|---|---|---|
| 正确性 | 五轮修复方向已真实落到代码；无 P0/P1（无数据错误/崩溃/假绿），6 条 P2 见 §3.5 | 0 | 0 | 6 |
| 完整性 | 数字面可信；"写侧必有清理"在元数据/模板模块断链 | 0 | 2（1 已确认 / 1 疑似） | 5 |
| 最优性 | 内嵌写回把照片当 sidecar：首写 6 次整读 + 6 遍哈希，峰值 ≈6× 文件 | 0 | 2 | 5 |
| 简洁性 | 无 P0/P1 级"多余"，但约 150 行零调用/仅测试调用的死面 + 两套已漂移的合并表 | 0 | 0 | 9 |

## 2. 本轮已修（`fix(final-review)`）

| 来源 | 问题 | 处置 |
|---|---|---|
| 简洁性 #2 | `MetadataWriteRouter.merge` 与 `MetadataService.mergeAttributes` 是同一张表，路由版多三个字段 → JPEG 读路径**静默丢 `triageSignal`** | 合并表收敛到 `MetadataService.mergeAttributes`（public，补齐 triageSignal/keywordsMode/replaceContact），删路由副本 −28 行 |
| 简洁性 #4 | `ModelReviewRepo.latestByAssetFile` 全仓零引用 | 删除 −20 行，设计文档同步说明 |
| 简洁性 #9 | `XMPPacketStoreError.description` 与 `code` 逐字重复；`WebDAVCredentialStore.service` 未进任何 Keychain 查询 | `description { code }`；删未用常量 |
| 完整性 #6 | `README`/`DEVELOPMENT` 写"129 个类型化方法"（实测 134）、"18 个 #Preview / 13 个文件"（实测 14 / 12） | 全部按实测改数 |
| 完整性 #7 | `check-layering.sh` 头注释仍写"尚未拆分 target…exit 0"（正文早已 20 条 fail-closed） | 删除误导注释 |
| 正确性 #1 | 交付相位读 `event.update.phase`，但执行器写的是 `message: "output.i/n"` → 相位恒 nil（**我自己上一轮引入的**） | 改 `phase ?? message`，相位真正上屏 |
| 正确性 #5 | `isControlledName` 对**整串路径**做 `contains`：目录名里带 `.gather-backup-` 就能让该目录下任意文件（内嵌模式下是原片）通过最后一道删除守卫 | 只看 `lastPathComponent`；补注释说明为什么限定到文件名 |
| 正确性 #6 | 白名单迁到 `DeliveryBackupPath` 后，两处注释仍写"唯一来源在 XMPBackupNaming" | 注释同步 |
| 正确性 #2 | 台账里 app 761 / 断言 10,199 / 注释 2193 与实测（762 / 10,204 / 2195）不一致 | 全部按实测回填 |

## 3. 未修，明确记账（含原因与下一步）

### 3.1 完整性 P1：元数据/模板写侧没有清理入口（备份会一直堆）

- 证据：`MetadataAPI.swift:18-66` 的 20 个方法没有 confirm/cleanup/finalize；`DeliveryStateMachine.swift:128-131`
  规定"只有 synced 可删"、`DeliveryStateWriter.swift:345` 又"刻意停在 written"；但每次写盘都会建
  `deliveries` 行并写 `.gather-backup-*`（`WritebackService+Execute.swift:394`）。
- 影响：长期使用后原片旁会累积备份，`deliveries` 只增不减（磁盘与行数都涨）。
- 为什么不在这轮修：需要动交付状态机（written → synced 的翻档时机）或新增元数据模块的 cleanup 入口 +
  UI，属于功能改动；`DeliveryModulePorts.swift:60-63` 又已经对外声明 template/metadata 支持 cleanup，
  贸然翻档会让"可撤销"失效。**下一步**：单开一刀，先补 `metadata.cleanup` 的 API + 宿主实现 +
  撤销快照保留策略，再用现有 `DeliveryDBPhase` 做一次端到端。
- 相关的疑似 P1（`DeliveryDBPhase.swift:202`）：同 sidecar 的 written item 会挡死 culling cleanup，
  与上一条同源，应一起收敛。

### 3.2 最优性 P1：内嵌写回的单张开销与内存峰值

- 证据：`WritebackService+Execute.swift:371,394,467` 与 `MetadataMutationService.swift:226` 各自
  `Data(contentsOf:)` 整读照片；`JPEGSegments.swift:97,114,260` 又把整文件复制成 `[UInt8]` 再切片。
- 影响：首写单张 6 次整读 + 6 遍 SHA256；12MB 照片 2k 张约 144GB 读放大（最优约 24GB），
  峰值内存 ≈6× 文件（40MB 照片 4 并发 ≈1GB）。
- 为什么不在这轮修：需要在 `XMPProvider` 端口上引入"一次读、多处用"的数据句柄，并同步改指纹/备份/
  写后校验三条路径 —— 这是接口级重构，本轮只做评审与记账。
- **下一步**：①`write()` 复用 `backup()` 已读的头部；②内嵌指纹改 `size + mtime + 头部哈希`；
  ③`JPEGSegments` 改 `Data` 下标切片 + `mappedIfSafe`。

### 3.3 完整性 P2：9 个错误码没有抛出点

`METADATA_*`×6、`MODEL_EXTRACT_FAILED`、`SCAN_READ_FAILED`、`XMP_RELOAD_NOT_ACKED` 只存在于枚举与文案表。
它们是**冻结的 IPC 契约**（TS 面仍在用），删码会破坏兼容，因此保留；但"每个码都有抛出点"不成立，
台账不再这么写。

### 3.4 其余 P2（记入待办，不逐条展开）

- `ExportWatermarkType.image` 有契约无实现（渲染器直接 throw `...TypeUnsupported`）。
- `KeywordEdit.blocked` 只在 Protocol 内构造，apply 走 throw、UI 不读。
- 最优性 P2：`CullingAssetPageQuery` 外层 GROUP BY（cursor 不可下推）、`DeliverySummaryQuery` 全表聚合、
  `AnalysisJobRepo` 无索引排序、`MetadataWriteRouter.target()` 最多 29 次 `fileExists`、
  `JPEGMetadataWriter` 在 async 体内做同步 IO、聚类邻域全对距离。
- 简洁性 P2（未删，因会连带改测试与 ratchet）：`DeliveryErrorPresentation` 的恢复动作面、
  `ModelReviewService.statProvider` 死注入、`DeliveryStateMachine` 的三个仅测试谓词、
  `CullingViewModel` 的两个测试缝、`AppRuntime.waitForDeliveryReplay`、`PhotoAssets.rawExtensions` 别名。
- 门禁面：仓库仍无 `-warnings-as-errors` / 告警计数门禁（本轮靠冷构建人工确认 0 告警）。

### 3.5 正确性视角的 P2（未修，均为既有行为问题）

| # | 证据 | 问题 | 下一步 |
|---|---|---|---|
| 1 | `WritebackService+Recover.swift:134-193` | 崩溃恢复只收敛 `deliveries` 行：written 组余项留 writing、failed 组余项留 pending；而 `retryFailed:350` 只读 failed item → UI 重试空转，pending item 还会卡 confirm | 归位时逐项收口（同一事务里 item 与行一起收敛） |
| 2 | `ExportService+Run.swift:208`、`OutputService.swift:151` | 两条 `catch` 分支永远不会命中（全仓无 `throw .cancelled`，execute 也不抛 `CancellationError`）→ 长单张转换期间取消无效 | 要么真抛，要么删死臂并改用显式取消检查点 |
| 3 | `OutputService.swift:131-132` | `sourceDigest = (try? deliveryFingerprint(...)) ?? ""`：指纹失败被当成空摘要，可能与旧运行的 "" 相撞而误跳过照片 | 失败即禁用 resume（不要静默降级成空摘要） |

> 计数口径说明：`swift test` 汇总行的 "1433 tests" 与 `@Test` 声明数相同，而仓内有参数化用例
> （`SchemaCurrentTests` 的 44 列展开、`checkCases` 的 30 例）。这里的 1433/762 是 **runner 打印的
> 汇总行**，不是"被执行断言的分支数"；ratchet 数的是声明数，两者口径不同，已在
> `check-test-catalog.sh` 的注释里写明。

## 4. 复跑（本轮收口时实测）

- 冷构建：core / app 均 exit 0，源码告警 **0**。
- core **1433 tests / 214 suites**、app **762 tests / 89 suites**（`--no-parallel`）exit 0。
- `gather-schema verify`：`44/386/72/65`、`user_version=1`、violations=0。
- 12 个 `check-*.sh` 全绿（strict 可用者带 `--strict`）。

## 5. 收尾核查（closeout，2026-10-29）

按 [DEVELOPMENT.md](../DEVELOPMENT.md) 的「提交与 Pull Request」逐项核对：

| 项 | 结果 |
|---|---|
| 仓库产物 | `git ls-files` 中无 `release/`、`.build/`、`*.sqlite*`、`.DS_Store`；`.gitignore` 覆盖 `release/`、`desktop/release/`、`.build/`、`tests/fixtures/local/` |
| 大文件 | 唯一 >2MB 的非文档文件是 `GatherAnalysis/…/SFace.mlpackage/…/weight.bin`（38.5MB）——DEVELOPMENT 明文允许的模型资产；其余为 `docs/archive` 的历史截图 |
| 未跟踪目录 | `release/`（341MB 构建产物）、`desktop/coplugin/GatherLink.coplugin/`、`Capture_One_Plugin_SDK_(Mac)_v1.0.1/`、空目录 `tests/fixtures/`——全部被忽略，未入库 |
| 冷构建 | core / app exit 0，源码告警 **0** |
| 测试 | core 1433 / 214、app 762 / 89（`--no-parallel`），exit 0 |
| schema | 44 / 386 / 72 / 65、`user_version=1`、violations=0 |
| 门禁 | 12/12 exit 0 |
| 提交规范 | 32 个未推送提交中，**非 merge 提交 100% 形如 `type(scope): subject`**；merge 提交沿用仓库既有的 `merge: 合入 <分支>（<范围>）` 形态（历史 5 个 merge 同形）。未改写历史，以免打断台账里引用的提交号 |
| 推送 | 未推送：`origin/main` 落后 32 个提交，留给评审/合并方 |

> 收尾只做核对与记账，没有新增代码改动。上面 §3 列出的 P1/P2 仍是**已知待办**，
> 不是"已修"；它们需要各自的切口（清理入口 / 端口级重构 / 状态机收敛），应在单独 PR 里做。
