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
  `MetadataSections` 曾出现"调用点仍用「侧车」键、en 表已改名「附属文件」"的失配
  （UI 会直接显示裸键），已在统一时成对修正，并加了一条 key↔call-site 全量核对脚本检查。
- 终态：`grep -rn '侧车|边车|侧边栏'` = **0**（不含未跟踪的 `release/` 产物）。
- 规模：121 文件 +525 −525（105 来自分支 + 16 来自本轮补漏）。

## 3. 六路只读评审的发现（合计 4 P1 已修 + 3 P1 结构性修复 + 20 P2）

| # | 面 | 关键发现（已修） |
|---|---|---|
| R1 | 元数据 | P1 成员级联系人清空不算"清空意图"→ 内嵌不可读时 fail-open 报 written；P1 侧车空 `CreatorContactInfo` 会整块抹掉内嵌联系人；P2 投影刷新发生在"内嵌可读性"判定之前（会先用仅 sidecar 快照覆盖缓存） |
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

## 5. 实测（`rm -rf .build` 冷构建后串行）

| 项 | 结果 |
|---|---|
| core 构建 / 测试 | exit 0；**1432 tests / 214 suites**（含新增契约测试），exit 0 |
| app 构建 / 测试（`--no-parallel`） | exit 0；**761 tests / 89 suites**，exit 0 |
| `gather-schema verify` | `tables=44 columns=386 indexes=72 fks=65 user_version=1 violations=0`，exit 0 |
| 12 个 `check-*.sh` | **12/12 exit 0**（strict 可用者带 `--strict`） |

## 6. 残余（未修，明确记账）

- `check-protocol-surface.sh --write-baseline` 仍可把任意膨胀洗白（评审 P2）：本轮只记录，
  未加"基线不可上涨"只读开关——那会改变门禁语义，需要单独决策。
- `check-test-catalog` 的 ratchet 数的是**声明**而非执行（`.disabled` / `#if false` 都算），
  删真补空仍可能绿。
- 合并接缝评审建议的"交付页独立进度字段"未做（`ExportViewModel` 按 checkpoint 过滤掉
  `output.run` 帧是**有意**的，给交付页单开进度需要新的状态与 UI，属功能改动）。
- `JPEGMetadataWritebackTests` 仍只覆盖 sidecar 路径（生产默认 auto→embedded）：补 router 用例
  需要新的测试脚手架，列为下一步。
- 未做 GUI 验收、未做签名/公证；WebDAV 仍是 fake transport。
