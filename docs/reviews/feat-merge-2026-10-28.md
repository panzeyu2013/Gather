# feat 分支合并（2026-10-28）

> 范围：把 `feat`（`a59a2fbc`「落地 P2 模型初审/内嵌元数据/交付闭环并完成六视角审查全量修复」，
> 以 `726622ee` 为 merge-base 单提交 +9,436 −339 / 134 文件）用 `--no-ff` 合入 `main`（`f859ed2c`）。
> 冲突 5 处全部手工解决；随后做了一轮"合并后口径"修正（错误码/en 键/schema 数字）与两处
> 死代码告警清理，并按实测重采样两根 ratchet 基线。验证命令见 §4。

## 1. 合并

- `git merge --no-ff feat` → 合并提交 **`b35ea4d3`**（父 `f859ed2c` + `a59a2fbc`）；merge-base `726622ee`，
  main 侧 7 提交、feat 侧 1 提交。`git diff --diff-filter=D f859ed2c HEAD` 为空（无删除），
  feat 新增文件在合并树中逐一存在。
- 规模：**138 文件 / +9,523 −348**（相对 `f859ed2c` `git diff --shortstat`），新增 **31** 个文件。
- 三块主题：GatherProtocol 新契约（ModelReview / Output / MetadataTarget，错误码 186→194 再 +1 两侧合计 195）、
  GatherPersistence schema 重置为 v1（44 表 / 386 列 / 72 索引 / 65 外键）、GatherHost 的 JPEG 内嵌写回
  （JPEGSegments / IPTCIIM / XMPPacketStore / WebDAV 凭据）与 GatherUI 交付页。

## 2. 冲突解决（5 处）

| 文件 | main 侧 | feat 侧 | 决策 |
|---|---|---|---|
| `Services/MetadataService.swift` | 回读走 `diskSnapshot`（内嵌+sidecar 合成 + `embeddedReadable`），写后校验用 `disk`；新增 WebStatement、联系人结构解析、兄弟刷新 | 回读改 `diskAttributes`；`usageTerms` 去掉 IIM 回退；描述性字段加 `xmpPresentKeys` presence 阻断 | 取 main 的回读/校验骨架（feat 的意图"内嵌+sidecar 合成"已由 `diskSnapshot` 覆盖且更强），保留 feat 的 `usageTerms` 无 IIM 与 presence 阻断，并保留 main 新增的 `webStatement` 表项 |
| `Protocol/ErrorCodeContractTests.swift` | 186 码 | 194 码 | 合并清单已自动并集为 195 条（逐条核对：枚举 195 / 清单 195 / 与枚举零差集），注释与断言改 195 |
| `Protocol/SessionContractTests.swift` | 186 | 194 | 同上，注释按时间线重写为 `…→186（JPEG 内嵌清空）→195（OUTPUT_*×5 + WEBDAV_*×4）`，断言 `== 195` |
| `docs/README.md` | 44/385/v5、1,380/202、735/85、en 1,680 | 44/386/v1、1,416/211、754/88、en 1,746 | 取 feat 的结构与口径，数字按合并树实测重采样（§3） |
| `docs/protocol-surface-baseline.json` | 310 类型 / 1,756 声明 | 332 / 1,904 | 两方都不是合并树实测值，直接 `--write-baseline` 重采样（332 / 1,909） |

其余 11 个"双方都改"的文件（`Core.swift`、`TriageRepo.swift`、`WritebackService.swift`、`LiveCullingAPI.swift`、
`LiveMetadataAPI.swift`、`L10n.swift`、`GatherLocalization.swift`、`Localizable.strings`、
`ImageMetadataProvidersTests.swift`、`ADR.md`/`DEVELOPMENT.md`）由 ort 自动合并，逐文件复核为**语义并集**：
feat 的模型初审/交付/内嵌写回 + main 的 `PhotoVisibility` 谓词收敛、`photo_count` 原子重算、
`humanDecisionSQLList`、成员级联系人清空、`undoAvailable` 均未丢失。

## 3. 合并后口径修正

| 项 | 合并前（两侧各自） | 合并后 | 落点 |
|---|---|---|---|
| 错误码 | 186 / 194 | **195** | `Core.swift`、两个契约测试、`GatherLocalization.errorMessages`、ADR-017、DEVELOPMENT、ROADMAP |
| en 键 | 1,680 / 1,746 | **1,748**（侧车术语轮补 model.review 文案后为 1,749） | README、ROADMAP、DEVELOPMENT（`zh-Hans` 仍 9 占位） |
| schema 形状 | 44/385/v5（main）、44/386/v1（feat） | **44 / 386 / 72 / 65，`user_version=1`** | README、ROADMAP、ADR、DEVELOPMENT；`gather-schema verify` 实测 |
| 死代码告警 | feat 新增 2 处 | 清零 | `OutputService.swift:142` `var→let`；`:321` 删未用的 `day` 局部量与随之失效的 `date` 形参 |

> 上一轮曾把 `docs/ADR.md` 里"schema 5 时代 44 表 / 385 列"改写成"44 张表"来绕开
> `check-docs` 的形状校验 —— 这是**门禁假绿**（评审 R5 判 P1）。已在 sidecar 轮修正：
> 门禁改为按"行内含历史/已删除"排除 + 折行拼接，ADR 措辞还原为"44 表"。
> 见 [sidecar-merge-2026-10-28.md](sidecar-merge-2026-10-28.md) §4。

## 4. 实测（本机 2026-10-28，arm64 / Swift 6.4）

冷构建：`rm -rf desktop/native/{gather-core,gather-app}/.build` 后依次执行。

| 项 | 命令 | 结果 |
|---|---|---|
| core 构建 | `swift build --package-path desktop/native/gather-core --disable-sandbox` | exit 0 |
| app 构建 | `swift build --package-path desktop/native/gather-app --disable-sandbox` | exit 0 |
| core 测试 | `swift test --package-path desktop/native/gather-core --disable-sandbox` | **1427 tests / 213 suites**，exit 0 |
| app 测试 | `swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox` | **761 tests / 89 suites**，exit 0 |
| schema | `gather-schema verify` | `tables=44 columns=386 indexes=72 fks=65 user_version=1 violations=0`，exit 0 |
| 门禁 | 12 个 `check-*.sh`（strict 可用者带 `--strict`） | **12/12 exit 0** |

用例数守恒自证：`@Test` 声明 base 2097 + main 18 + feat 73 = **2188**（合并树实测 2188），
`@Suite` 222 + 3 + 15 = **240**（实测 240）——自动合并没有吞掉任何用例。

## 5. 基线变更记账（只许收紧）

| 基线 | 变更 | 理由 |
|---|---|---|
| `docs/protocol-surface-baseline.json` | 310/1,756 → **332 类型 / 1,909 声明**（90 文件 / 9,424 行） | 合并树实测；两侧基线都低于合并结果，不重采样会直接假红 |
| `scripts/check-test-catalog.sh` ratchet | `2115/225` → **2188/240** | 合入 feat 的 73 个 `@Test` / 15 个 `@Suite` 后，旧下限容忍静默删掉整套 feat 测试 |
| `docs/cleanup-baseline.json` | 不变（`60/255/0/0/0`，实测恰好持平） | 新代码没有新增 `try?` / `@unchecked Sendable` |
| `docs/design-system-baseline.json` | 不变 | 实测持平 |

## 6. 残余

- **并行模式 app 测试**仍会 SIGSEGV（feat 已注明既有问题，非本次引入），验收一律 `--no-parallel`。
- **9 处源码告警**（合并前 6 + feat 新增 3）：其中 2 处已在本轮清零，剩下的
  `ExportViewModel+Delivery.swift:155`（`Task { @MainActor [weak self] }` 与外层强捕获归属不一致）
  是**语义性**告警：改成强捕获会改变 VM 生命周期，需要 UI 层用例兜住，本轮只记录不改。
  其余 6 处（`DB.swift:479`、`AppBootstrap.swift:319`、`AppImport.swift:68`、
  `SidecarXMPProvider+Patching.swift:252`、`CullingViewModel.swift:195`、`:197`）为既有告警。
- **schema 破坏性重置**：`user_version` 5 → 1，旧库按 `.incompatible-<ts>` 归档重建，界面给一次性提示；
  这是 feat 的设计决策（ADR-036），不是合并引入的缺陷，但发布说明必须写。
- **未做 GUI 验收**：交付页/初审芯片/WebDAV 面板只到编译 + 单测层，没有真人过一遍界面。
- **未做签名/公证**与真实 WebDAV 服务器联调：`WebDAVPublisherTests` 全部是 fake transport。
