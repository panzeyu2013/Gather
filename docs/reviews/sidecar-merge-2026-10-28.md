# sidecar 合并 + 两轮合并后的全量评审修复（2026-10-28）

> 范围：把 `sidecar`（`b9cab346`「统一 sidecar 术语为『附属文件』/sidecar」）用 `--no-ff` 合入
> `main`（`2b5e361a`，即 feat 合并后的树），合并提交 **`526e2507`**；随后做全仓术语统一，
> 并逐条处理 6 路只读评审（元数据 / 错误码协议 / 自动合并接缝 / 数据面 / 门禁台账 / UI 本地化）
> 的 P0–P2 发现。本轮修复单独提交，见 §6。

## 1. sidecar 合并

- `git merge --no-ff sidecar`；merge-base `726622ee`，与 feat 同一分叉点。
- 分支本身是**纯术语重构**（105 文件 +388 −388）：用户可见中文文案「侧车/边车/侧边栏」→
  「附属文件」，en 值保持 `Sidecar`；代码注释 / `@Test` 描述 / docs 散文 → `sidecar`
  （中英之间补空格），另有 13 处顺带润色（去掉冗余「文件」后缀、"同 sidecar"→"同一 sidecar"）。
- 已用归一化脚本验证：把两侧的 侧车/边车/侧边栏/附属文件/sidecar 统一投影后，92/105 文件
  逐字节相同，剩余 13 处即上述润色 —— 没有夹带行为改动。
- 冲突 6 处，全部取 HEAD（feat 合并后的更新语义），再按新术语改写：
  | 文件 | 冲突原因 | 解决 |
  |---|---|---|
  | `MetadataService.swift`（2 处） | sidecar 侧是基线文本（`diskAttributes` 内联实现 / `guard attributesMatch`） | 取 HEAD 的 `diskSnapshot` 与写后校验骨架 |
  | `DeliveryTypes.swift` | sidecar 侧 `TSPath.xmpSidecarPath` 直算 | 取 HEAD 的 `MetadataTargetResolver` |
  | `SchemaCurrent+DDLDomain.swift` | 表 40 注释 | 取 HEAD 的 `target_kind` 语义说明 |
  | `MetadataSections.swift` | main 新增「写入目标」条件标签 | 取 HEAD，标签「侧车」→「附属文件」 |
  | `MetadataEditorSheet.swift` / `en.lproj` | main 新增「内嵌字段不可在此清空」文案 | 取 HEAD 文案，术语与键同步改「附属文件」 |

## 2. 全仓术语统一（feat 合入后的残留）

feat 带来大量新文案/注释，合并只覆盖了 sidecar 分叉点之前的文本，因此合并后仍有
**559 处**（含 docs）残留。按"文案 vs 散文"两类规则一次清完：

| 类别 | 规则 | 例 |
|---|---|---|
| 用户可见串（`.strings` 键 / `l10n(...)` / 错误文案） | → 「附属文件」 | 「留空表示清空侧车字段」→「…清空附属文件字段」 |
| 代码注释 / `@Test` 描述 / `#expect` 文案 / docs 散文 | → `sidecar`，两侧 CJK 补空格 | 「侧车快照」→「sidecar 快照」 |

- 关键陷阱：`en.lproj` 的**键就是中文文案**，改文案必须同步改键与所有调用点。
  `MetadataSections` 曾出现"调用点仍用旧键、en 表已改名「附属文件」"的失配
  （UI 会直接显示裸键），已在统一时成对修正；核对用的是临时 python 脚本（未入库），
  常驻守卫是 `LocalizationParityTests`。
- 终态：**源码 / 资源 0 命中**（`grep -rn '侧车|边车|侧边栏' desktop` = 0）；docs 里只剩
  本台账与 `feat-merge` 台账在**描述这次改名**时引用的旧词（`grep … docs` = 8）。
  未跟踪的 `release/` 构建产物不计。
- 规模：121 文件 +525 −525（**104 个双方共有 + 17 个仅合并侧**；分支共 105 个文件，
  `SchemaCurrent+DDLDomain.swift` 的表 40 注释 hunk 在合并时被判为"已由 HEAD 覆盖"而丢弃，
  由修复提交补回，因此"仅合并侧"比"分支独有"多 1）。
- **归档快照不回填**：`docs/archive/` 里的 7 个历史文档已被分支改过术语，本轮按
  [docs/archive/README.md](../archive/README.md) 的"快照不随当前架构回填"回退，并在该 README 记录例外。

## 3. 六路只读评审的发现（合计 4 P1 已修 + 3 P1 结构性修复 + 20 P2）

| # | 面 | 关键发现（已修） |
|---|---|---|
| R1 | 元数据 | P1 成员级联系人清空不算"清空意图"→ 内嵌不可读时 fail-open 报 written；P1 sidecar 里的空 `CreatorContactInfo` 会整块抹掉内嵌联系人；P2 投影刷新发生在"内嵌可读性"判定之前（会先用仅 sidecar 快照覆盖缓存） |
| R2 | 错误码/协议 | P1 `OutputServiceError`/`WebDAVError` 用裸字面量拼码、不 conform `CodedError`；P1 新增 20 个 public 契约类型零契约测试；P2 5 处源码注释仍写「186 码」 |
| R3 | 自动合并接缝 | 11 个"双方都改"文件逐 hunk 复核为真并集，零丢失；P2 `TriageRepo` 新增指纹缺可见性谓词、`WorkspaceStatusService` 任务类型名过期 |
| R4 | 数据面 | P1 `legacyVersions=[2,3,4,5]` 与未来 bump 相撞（旧构建会把新库归档重建）；P2 DDL 注释里的旧指纹、`ResetSupport` 回滚失败却宣称"保持原样"、`MetadataWriteRouter.removeFile` 无守卫 |
| R5 | 门禁/台账 | P1 `check-docs` 形状校验可被"把 44 表改写成 44 张表"和"折行"绕过（**我上一轮就是这么绕的**）；P2 台账的合并规模/路径写错；P2 `--write-baseline` 可无脑洗白 |
| R6 | UI/本地化 | P1 job 失败明细只进 `underlying` → 交付横幅渲染成「失败（）」；P1 控制中心失败行只传码、`job.message` 从未被消费；P2 交付项错误串直接上屏英文码、`model.review` 相位缺键、WebDAV 进度帧无守卫 |

## 4. 本轮修复（按面）

- **元数据**：`hasClearAttempt` 纳入 `clearedContactMembers`；读侧空 `CreatorContactInfo` 不再当
  "显式清空"（显式清空只走写侧）；把内嵌可读性判定**前移到缓存投影之前**；
  `blockedByExplicitEmpty` 遮蔽非空 IIM 时补 debug 诊断（语义不改，否则清空会被旧值复活）。
- **错误码**：两个域枚举 conform `CodedError`、码改用 `GatherErrorCode` 成员（裸字面量清零）；
  `translateCommon` 把 `"CODE: 散文"` 尾部落成 `params["detail"]`，UI 的 `{{detail}}` 不再为空。
- **契约测试**：新增 `OutputContractTests`（5 例 / 1 套件）：写目标策略表、`target_kind` 与
  artifact rawValue 冻结、`OutputServiceError`/`WebDAVError` 的码全部 ∈ `GatherErrorCode`、
  `ModelReviewResult`/`OutputRecipe` 的 Codable 往返。
- **数据面**：`legacyVersions` 改成"只在 `userVersion == 1` 生效的一次性桥接"，bump 后自动失效
  （那些库改走 fail-closed，绝不被归档重建）；triage 模型指纹补可见性谓词；DDL 注释里的旧指纹、
  `.migrated`、`target_kind` 三处漂移改正；`ResetSupport` 回滚失败时如实上报 staging 路径；
  `MetadataWriteRouter.removeFile` 补"只删 .xmp / 受控备份"守卫。
- **UI/本地化**：控制中心失败行带 `job.message`；交付项错误串过 `L10n`；补 `model.review` 相位文案；
  WebDAV 进度帧加"仍在发布中"守卫（取消后迟到的帧不再把进度条写回）。
- **门禁**：`check-docs` 形状校验改为「按行内含『历史/已删除』排除 + 折行按行尾 `/` 拼接后匹配」，
  并用 BSD awk 的 `index()` 做字节判断（多字节正则不可靠）；ADR 里被上一轮改写的「44 张表」
  已还原为「44 表」——门禁不再需要靠改措辞绕开。

### 4.1 第二轮核验（术语终态 / 修复正确性 / 合并接缝）追加修复

| 发现 | 处置 |
|---|---|
| 3 条中文 UI 串仍写「sidecar 文件」（`Localizable.strings` + 3 个调用点） | 键与调用点同步改「附属文件」，en 值不变 |
| 台账称"有 key↔call-site 核对脚本" | 改记为"临时 python 脚本（未入库），常驻守卫是 `LocalizationParityTests`" |
| `hasClearAttempt` 里同一段 `cleared` 判定重复两遍 | 删重；并补 2 条回归测试（成员级清空算清空意图、空 contact 结构不覆盖内嵌） |
| `modelReviewFingerprint` 加了可见性谓词，与 `photoFingerprint` 口径打架 | **回退**：两者都按全量行计（归档不触发全批 stale），并在注释里写清口径 |
| 控制中心把「CODE: CODE: 散文」拼成双码 | message 已以码开头时不再补前缀 |
| `target_kind` 注释仍暗示"参与恢复决策" | 改为"仅记录，读写路径都不读它" |
| 备份删除白名单缺 `.gather-archived-`（计划中的归档 sidecar 名） | `DeliveryTypes` 与 `MetadataWriteRouter` 两处补上 |
| `check-docs` 仍可被「44 张表」与"折行断点不在 / 处"绕过（评审实测） | 收行逻辑改用 python：`<N>\s*[张个]?\s*表` 都算现行声明、本条无「列」就把后续两行拼入、只跳过"含历史/已删除且不含当前"的行 |

## 5. 实测（`rm -rf .build` 冷构建后串行）

| 项 | 结果 |
|---|---|
| core 构建 / 测试 | exit 0；**1433 tests / 214 suites**（含新增契约测试），exit 0 |
| app 构建 / 测试（`--no-parallel`） | exit 0；**761 tests / 89 suites**，exit 0 |
| `gather-schema verify` | `tables=44 columns=386 indexes=72 fks=65 user_version=1 violations=0`，exit 0 |
| 12 个 `check-*.sh` | **12/12 exit 0**（strict 可用者带 `--strict`） |

## 6. 残余清零（第三轮，提交 `92a03c2c`）

上一版列出的五条残余已全部处理：

| 原残余 | 处置 | 证据 |
|---|---|---|
| `--write-baseline` 可把膨胀洗白 | 加 `--allow-growth` 闸门：指标上涨时`--write-baseline` 直接 REFUSED（exit 1）并打印涨幅；确需扩张必须显式批准并在台账记账 | 人为压低 `public_types` 到 292 后实测 REFUSED，`--allow-growth` 才放行 |
| test-catalog ratchet 只数声明 | 追加**断言 ratchet**（`#expect` + `#require` = 10,199），删真补空会让断言数掉 | `check-test-catalog.sh` 的 §7 |
| 交付页无进度（`output.run` 帧被过滤） | `ExportViewModel` 增 `deliveryProgress`/`deliveryPhase`，交付区渲染进度条 + 相位 + n/N；原过滤只针对"单张导出"那套状态 | `ExportViewModel.applyJobEvent`、`ExportView+Delivery` |
| JPEG 内嵌写回缺 router 用例 | 新增"无 .xmp 的 JPEG 走内嵌、不生成 sidecar、值真进 APP1"用例（真 JPEG + 真 router） | `JPEGMetadataWritebackTests.embeddedTargetWritesIntoJPEG` |
| `PhotoVisibilityGateTests` 误报文档注释里的 SQL | 门禁改为**先抹掉整行注释再扫描**（行数不变，行号仍准）；并故意把 `archived_at IS NULL` 写回注释验证不再误报 | `PhotoVisibilityGateTests.strippingLineComments` |

同时在第三轮清掉了 **7 处源码告警**（`AppBootstrap` 未用返回值、`AppImport` 死变量、
`SidecarXMPProvider+Patching` `var→let`、`DB.swift` 未用结果、`CullingViewModel` 冗余
`internal(set)` ×2、`ExportViewModel+Delivery` 的 weak 捕获归属），冷构建实测 **0 告警**。

仍未做（环境/范围所限，不是缺陷）：
- 未做 GUI 验收、未做签名/公证；WebDAV 仍是 fake transport。
- `.gather-archived-<ts>` 的 sidecar→embedded 迁移功能未实现（白名单已预留），它属于
  `docs/design/p2-review-delivery/plan-2026-10-28.md` §2.5 的功能项，不在本轮范围。
- 设置项 `metadata_write_mode` 的 `sidecar` 选项标签仍是英文技术名「XMP Sidecar」
  （en 值同名）：按"格式名保持英文"的既有约定有意保留。
