# Cut 6 清理 / 文档 / 交付 独立评审（post-refactor r8）

> 评审日期：2026-10-22 · 评审对象：工作区（HEAD `82603e0`，未提交）· 只读评审，除本文件外未改任何源码/测试/脚本/文档。
> 复现环境：macOS，DSH workspace-write；命令均在 `/Users/panzeyu2013/Desktop/code/develop/Gather` 执行。
> 口径：**【已确认】** = 本次实跑/静态检索可复现；**【疑似】** = 静态推断或环境相关，需 owner 复核。

## 1. 范围与方法

### 1.1 范围

- 清理完整性：死代码、未用符号、旧名残留、重复类型、public API 最小性、`find-unused-symbols` 剩余 2。
- 文档一致性：`final-report.md` / `refactor-progress.md` / `refactor-decisions.md` / ADR / README / DEVELOPMENT / ROADMAP 的指标与归档链接。
- 清理账：`cleanup-backlog.md` CL-01..CL-20 状态、CL-18/CL-20 残余、被删 lproj key 证据。
- 交付面：git 工作区状态、未跟踪文件、临时/大文件、`build.sh`、`.github/workflows/ci.yml`。
- 安全/健壮性：路径遍历、符号链接、数据库重置/备份、错误信息泄漏。

### 1.2 方法（本次实际执行）

| 类别 | 命令/方法 | 结果 |
| --- | --- | --- |
| 文件/行数 | `find desktop/native -name '*.swift' -not -path '*/.build/*' \| wc -l` + 逐文件 `wc -l` | 535 文件 / 133,740 行，与报告一致 |
| core 测试 | `swift test --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error` | **1092 tests / 157 suites passed**，exit 0 |
| app 测试（串行） | 同上 + `--no-parallel`，`CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache` | **581 tests / 66 suites passed**，exit 0 |
| app 测试（并行，CI 口径） | 去掉 `--no-parallel`，其余同 | **2 次均失败**（`CullingViewModelAPITests.swift:421-423`），见 P1-1 |
| Schema | `gather-schema verify`；`gather-schema dump` 灌入临时 SQLite，逐表 `pragma_table_info`/`pragma_foreign_key_list` | 43 表 / 373 列 / 69 索引 / 62 FK / user_version=1 |
| 门禁 | 8 个 `scripts/check-*.sh`（strict 可用者带 `--strict`） | 全部 exit 0；ratchet 53/236/126/0/0 |
| 未用符号 | `swift scripts/find-unused-symbols.swift --root .` | 2 个候选（均为 AppKit 协议方法），见 P2-6 |
| 文档规模 | `find docs -name '*.md' \| wc -l` + `wc -l` | 44 篇 / 18,999 行，与报告一致 |
| 链接 | 自建 Python 相对链接扫描（`README.md` + `docs/**/*.md`） | 252 条相对链接；md→md 150 条全部可解析；**47 条代码路径链接失效** |
| lproj | `git show HEAD:...` 与当前 en/zh 做键集合差 | en 删 105 / 增 12，净 −93；zh 删 1 / 增 0 |
| git | `git status --porcelain`、`git diff --cached --stat` | 155 staged / 392 unstaged / 386 untracked |

> 时间口径：以上数字在 2026-10-22 14:30–14:45 采集。期间 `docs/reviews/` 新增了 7 篇并行评审（`post-refactor-r1..r7-*.md`），因此“docs 44 篇 / 18,999 行”“reviews 5 篇”只对应 Cut 6c 报告写作时的仓库状态；复核时全仓 docs 已是 **52 篇 / 21,008 行**。本报告不把这 7 篇计入 Cut 6 交付。

---

## 2. P0

**无。** 未发现会导致数据不可恢复、任意文件写/删、权限提升或构建产物必然不可用的 P0。数据库重置路径与导出路径均有保守保护（见 §5），本次未发现突破。

---

## 3. P1（交付/验收口径错误或会造成返工）

### P1-1 app 测试在 CI 口径（默认并行）下失败；已交付的“581/66 全绿”只在加 `--no-parallel` 时成立 【已确认】

- 证据：
  - CI 实际命令：`.github/workflows/ci.yml:87` — `swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`（**无 `--no-parallel`**）。
  - 本机按 CI 口径（仅额外加 `--disable-sandbox`/cache/scratch）实跑两次，均为 `Test run with 581 tests in 66 suites failed`，失败点固定为：
    - `gather-app/Tests/GatherAppTests/CullingViewModelAPITests.swift:421` `vm.history.first?.undone == true` → false
    - `:422` `vm.undoOperation == nil` → false
    - `:423` `vm.redoOperation?.id == 7` → nil
  - 加 `--no-parallel` 后同机同代码 **581/66 passed**，exit 0（与 `docs/final-report.md:80`、`docs/DEVELOPMENT.md:211` 的台账一致）。
  - 交付文档的可复现命令也没有 `--no-parallel`：`README.md:68`、`docs/DEVELOPMENT.md:210-211`。
  - 【疑似，代码可确认】竞态方向：`Culling/CullingViewModel+Actions.swift:282-315` 的 `applyHistory` 在 `markHistoryOperation` 后调用 `refreshSilently()`；后者在 `CullingViewModel+Load.swift:32-60` 起 `Task.detached`，其 `applySnapshot`（同文件 `:82`）会用快照里的 `history` 覆盖本地状态。测试 stub 的 `history()` 不随 `applyHistory` 更新（仍返回 `undone=false`），并行调度下 detached 刷新先于断言完成，把刚标记的 undone 覆盖回去。
- 影响：CI `gather-app tests + bundle` job 会在 bundle 之前红掉，`build.sh` 根本不会执行；最终报告的“app 581/66 全绿”与 CI 口径不可复现。这是**交付门禁与验收命令不一致**：两次连续全量并行均复现同一断言，不是偶发 flake；但根因是测试夹具与未等待刷新，不是生产 API 失败。
- 建议（owner 决定其一）：
  1. CI/README/DEVELOPMENT 统一加 `--no-parallel`（最小改动，与已验收口径一致）；或
  2. 修 `undo()` 的异步刷新竞态，使并行下稳定（推荐，但不属于 Cut 6 只读范围）。
  在二者完成前，不应把 CI 的 app job 写成已验证通过。

### P1-2 工作区是“staged + unstaged + untracked”三方混合；386 个未跟踪文件包含 app 主体，按常规 `git commit` 会丢交付 【已确认】

- 证据：
  - `git diff --cached --stat`：155 个文件已 staged（+10,939 / −6,259）。
  - `git diff --name-only`：392 个文件 unstaged。
  - `git ls-files --others --exclude-standard`：**386 个未跟踪文件**，其中 `desktop/native/gather-app` 264 个、`docs/archive/reviews` 67 个、`gather-core` 24 个、`docs/archive/cuts` 10 个、`scripts/` 8 个、`docs/final-report.md` 等根文档若干。
  - `git status --porcelain` 同时存在 `D `（已 staged 删除）、` D`（工作区删除）、`RD`（rename 后删除）、`AM/RM` 四种状态。
  - `docs/final-report.md:137/141/165` 只写“全部改动未 commit”“整仓回退即回到 HEAD”，未说明未跟踪文件与 staged 混态。
- 影响：owner 若执行 `git commit -m ...`（不带 `-A`），只会提交 155 个 staged 文件；新拆分的 GatherUI/GatherHost 主体、归档文档、报告均不会入库，仓库将处于“能 diff、不能构建”的状态。若执行 `git checkout/restore` 清理，会丢失 392 个未暂存修改。
- 建议：交付前先做一次工作区快照（`git add -A` 后 `git diff --cached` 审查，或整目录复制/打包），并在最终报告写明“提交必须 `git add -A`；禁止在未备份前 checkout/restore”。同时把 `git status` 三方计数写进报告，而不是只写“未提交”。

### P1-3 Cut 4 的“统一 stale 守卫（RequestGate）”未落地，且 RequestGate 是零调用点死代码；Cut 6 仍把它当作门禁通过项 【已确认】

- 证据：
  - `gather-app/Sources/GatherUI/Support/RequestGate.swift:2` 自述：“Cut 4 / 4a-0：latest-wins 代次闸门（**零调用点**；全仓唯一一份，§4a-0 风险项）”。
  - 生产引用检索：`grep -rn 'RequestGate' gather-app/Sources` 只命中定义文件本身；其余命中全部在 `Tests/GatherAppTests/RequestGateTests.swift`。
  - CL-04 的验收条件未满足：`grep -rnE 'fetchGeneration|latestRequestID|tierRequestID|pageVersion' gather-app --include='*.swift'` = **38 行**（按符号 17/5/7/11，含 2 行同时命中两符号），例如 `Culling/CullingViewModel.swift:159` `var pageVersion = 0`、`CullingViewModel+Load.swift:35/60/177/239` 仍手写代次。
  - `docs/cleanup-backlog.md:49` 该条仍写 `status: pending，Cut 4`；但 `docs/refactor-progress.md:31` 与 `docs/final-report.md:21` 把 Cut 4 标为完成，`docs/final-report.md:101` 还把 `RequestGate 1 份` 列为 duplicate-symbols 门禁通过证据。
- 影响：Cut 4 声称的“4 套 stale 守卫统一”没有发生；新增的 RequestGate 只有测试引用，属于死代码，且 `check-duplicate-symbols.sh` 只校验“定义唯一”，无法发现“零调用点”，形成假绿灯。后续维护者会以为守卫已统一。
- 建议：二选一——(a) 在 Cut 6/7 真正迁移 4 个 VM 到 RequestGate 并删除私有代次，补齐乱序/取消/重入测试；(b) 若决定不做，把 CL-04 明确标为 `deferred`、在 final-report 残余项列出，并把 RequestGate 标为“预留/未接线”或删除，避免被门禁误计为完成。

---

## 4. P2（文档/清理/健壮性瑕疵）

### P2-1 cleanup-backlog 的 CL 状态与 Cut 完成度不一致；6 条 pending 未进入最终残余清单 【已确认】

- 证据：`docs/cleanup-backlog.md` 中仍为 pending：
  - `:49` CL-04（4 套 stale 守卫，Cut 4）——确实未做（见 P1-3）。
  - `:69` CL-07（两套缩略图 loader，Cut 4）——**确实未做**：`PhotoThumbnailView.swift:222` 与 `:415` 仍是两个 `private func load(for key:)`，各自带一份 `@State`（`:164-168`、`:289-293`）；全仓无 `ThumbnailLoader`。pending 准确，但未进最终残余。
  - `:75` CL-08（6 个 VM errorMessage）——`grep -rn 'var errorMessage: String?' gather-app` 仅剩 1 处，且是 Host 的 `AppBootstrap.swift:61`，不是页面/VM；应标 done。
  - `:81` CL-09（SessionDraftCache/isActive）——`RootView.swift` 148 行、无 SessionDraftCache 存储；应标 done（`isActive` 仅作为 CullingViewModel 可见性字段保留，不是旧传参）。
  - `:87` CL-10（`.id(languageVersion)` + l10n）——生产 `GatherLocalization.l(` = 0（9 处全在 Tests）；应标 done。
  - `:132` CL-17（重复常量）——`rawExtensions` 已收敛到 `GatherProtocol/Protocol/PhotoFileTypes.swift:22`，但 `PollingPolicy` 全仓 0 引用，轮询常量仍在各 VM；应标 partial/deferred。
- 影响：`docs/final-report.md:133-137` 的残余只列 CL-18/19/20，读者会以为 CL-01..CL-20 只剩 3 条；实际至少 CL-04、CL-07、CL-17 仍未收口，CL-08/09/10 已做完却仍挂 pending。
- 建议：逐条按实测更新状态（done / deferred + 原因），并把 CL-04/07/17 写进 final-report §6。

### P2-2 Schema.swift 行数口径仍有一处旧值 14（应为 19） 【已确认】

- 证据：`docs/cleanup-backlog.md:40` 写 “`Schema.swift` 649→14”；`docs/refactor-progress.md:120` 与 `docs/refactor-decisions.md:1423` 已更正为 649→19。
- 实测：当前 `desktop/native/gather-core/Sources/GatherPersistence/Database/Schema.swift` = 19 行；HEAD 版本 = 649 行。
- 影响：同一指标在账本中出现 14/19 两个值，且 14 是错误值；check-docs 不校验此类数字，不会被门禁拦住。
- 建议：把 CL-02 改为 649→19（与 progress/decisions 对齐）。

### P2-3 “删 94 个 en key”的删除数不可按 git 差集复算；en 基线 1,407 也与 HEAD 的 1,406 条不一致 【已确认】

- 证据：
  - 当前 en：`gather-app/Sources/GatherUI/Resources/en.lproj/Localizable.strings` 1,313 条（`^"` 计）；zh 9 条。
  - HEAD en：`git show HEAD:desktop/native/gather-app/Resources/en.lproj/Localizable.strings | grep -cE '^"'` = **1,406**（1,478 行，1,406 个 `=`/ `;`，无跨行项）。
  - 键集合差：**删除 105 条、新增 12 条**，净 −93；zh 删除 1、新增 0（10→9）。
  - 报告写 “删 94 en（含 31 孤儿）+ 1 zh”“en 1,407→1,313”（`docs/final-report.md:23/36/134`，`docs/refactor-progress.md:163-164`）。
- 影响：94 是“两次阶段计数的净差”，不是可审计的删除条数；其中 12 条新增（如 `显示侧栏`、`照片不存在或无权访问。`）说明工作区并非只删不增。若按“删除 key 的回归风险”评估，应看 105 条被删集合，而不是 94。1,407 这个“重构前基线”无法从 HEAD 复算（HEAD 只有 1,406 条），疑似把某个中途新增 key 计进了基线；应写成“Cut 4 时点工作区 1,407，HEAD 1,406”。
- 建议：在 CL-20/6a 证据里附“被删 105 条 + 新增 12 条”的清单或可复现命令（`comm -23/-13`），并说明 94 的口径；把 1,407 改成“当时工作区 1,407（HEAD 1,406）”。

### P2-4 当前有效文档仍有 13 条指向旧 `GatherCore` 路径的死链接；归档文档另有 34 条代码路径死链 【已确认】

- 证据：
  - `docs/reviews/face-clustering-benchmark.md`（`docs/reviews/README.md` 明确列为“当前有效评审”）第 103-107、114-116、138 行的 `[Alignment.swift](desktop/native/gather-core/Sources/GatherCore/Face/Alignment.swift)` 等 13 条链接全部 404——旧伞 target 路径已删。
  - 归档：`docs/archive/reviews/visual-design-review.md` 30 条、`ui-review-2026-09-29-round2-fixes.md` 3 条、`perf-audit-2026-09-30.md` 1 条 `.swift` 链接失效；`docs/archive/README.md` 已声明“归档保留当时路径”，属预期但未加“链接可能失效”的逐文件提示。
  - 自建扫描：md→md 相对链接 150 条 0 缺失；失效的 47 条全部是 `.swift` 路径（46）加 1 条 `(count)` 伪链接。
- 影响：`docs/final-report.md:98`/`docs/refactor-progress.md:165` 的“md 链接 133 条/图片 47 条 0 缺失”只覆盖 md/图片，不覆盖代码路径；当前文档的源码指引会把读者带到不存在的文件。
- 建议：把 `face-clustering-benchmark.md` 的链接改为现路径（`GatherAnalysis/Face/*`、`GatherDomain/Services/FaceKwService.swift`），或在文件头注明“路径为 2026-10 快照”；归档文档在 README 统一注明代码链接不保证有效即可。

### P2-5 构建产物 `gather-app/Sources/.build` 达 379MB，报告只写“2 个生成 accessor” 【已确认】

- 证据：`du -sh desktop/native/gather-app/Sources/.build` = **379M**；其中包含 `scratch/out/Intermediates.noindex/gather-core.build/.../resource_bundle_accessor.swift` 与 `gather-app.build/.../resource_bundle_accessor.swift` 等整套中间产物。该目录被 `.gitignore` 的 `.build/` 忽略。
- 影响：`find-unused-symbols` 报 “swift files: 537（sources 372, tests 163）”，而报告口径是 535，差的 2 个就是这两个生成文件；同时 379MB 构建垃圾留在 `Sources/` 下，会污染任何未排除 `.build` 的扫描/打包。`docs/final-report.md:137` 只写“2 个生成 accessor”，低估了体量。
- 建议：删除 `gather-app/Sources/.build`（先确认无进程使用），或把 scratch 路径统一到 `desktop/native/.build`；报告改为“379MB 中间产物（含 2 个生成 accessor）”。

### P2-6 `find-unused-symbols` 剩余 2 为真，但工具口径掩盖“仅测试引用”的死 API 【已确认/疑似】

- 证据：实跑输出 `candidates: 2`：`GatherAppDelegate.swift:557 applicationShouldTerminate`、`:320 applicationSupportsSecureRestorableState`，二者都是 AppKit 协议方法（由系统调用），**不是死代码**——数值为真，语义是假阳性。
- 但同一工具把 Tests 计入引用：`RequestGate`（仅测试）、`RouterCommandError`（生产零构造，见 P2-7）都不会进候选。报告 `docs/final-report.md:101` 用 `RequestGate 1 份` 作为清理通过证据，属于工具口径误用。
- 建议：文档写“2 个候选均为 AppKit 协议方法，人工复核为误报”；不要把“候选数”当作“死代码为 0”的证明。若要度量最小 public API，增加“Sources 外零引用、仅 Tests 引用”的第二口径。

### P2-7 旧命令面类型 `RouterCommandError` 仍留在生产错误漏斗中，且没有任何生产构造点 【已确认】

- 证据：
  - 定义：`gather-app/Sources/GatherUI/Support/JSONValueDecoding.swift:38`（`public struct RouterCommandError`）。
  - 生产引用：`APIErrorPresentation.swift:34`、`CommandError.swift:102`、`GatherLocalization.swift:306`、`FaceKeywording/FaceKeywordingViewModel+Analysis.swift:199` 都只是 `as? RouterCommandError` 分支；`grep -rn 'RouterCommandError(' gather-app/Sources gather-core/Sources` = **0**。
  - 测试仍有 3 个文件、11 处构造它（`APIErrorPresentationTests`、`CommandErrorTests`、`GlobalInfraTests`）。
  - `check-no-legacy.sh` 的 R5 只匹配 `CommandRouter|WebResponse` 等字面量，`RouterCommandError` 不在规则内（`scripts/check-no-legacy.sh:78-80`）。
- 影响：字符串命令已删，但“旧异步命令错误载体”仍在 public API 与错误漏斗里；这是 Cut 1 “旧实现删除且无并存”口径的残留，也是 `find-unused` 的盲区。
- 建议：删除该类型及 4 处 `as?` 分支与对应测试注入；若确需保留历史载荷翻译，降至 `internal` 并注明“仅测试/日志兼容”。

### P2-8 源码注释仍有 12 处（11 个文件）旧伞 target 名 `GatherCore` 【已确认】

- 证据（均非 target 名/包名本身）：
  - `gather-core/Sources/GatherProtocol/Protocol/Culling.swift:9-10`（“GatherCore 已有”）
  - `gather-core/Sources/GatherDomain/Services/ExportService.swift:4`（“刻意保持在 GatherCore”）
  - `gather-core/Sources/GatherSchema/main.swift:20`（“Tests/GatherCoreTests/...” 路径仍有效，但语义是旧目录）
  - `gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift:19`
  - `gather-app/Sources/GatherUI/Gallery/GalleryView.swift:2`、`Similarity/SimilarityView.swift:2`、`Library/LibraryView.swift:2`、`Dashboard/DashboardView.swift:2`、`Dashboard/DashboardViewModel.swift:2`
  - `gather-app/Sources/GatherHost/FaceKwWritebackBridge.swift:2`、`SidecarXMPProvider.swift:19`
- 影响：6b 声称“171 个文件头旧 target 路径回填”，但这些正文注释未改；与“删伞 GatherCore”的交付口径不一致，容易让新读者以为还存在伞模块。
- 建议：批量改为 `GatherDomain` / `GatherAnalysis` / `GatherProtocol` 等实际 target，或改成中性“core”。

### P2-9 数据库重置是“多文件顺序 move”，中途失败会留下主库与 WAL 分离的备份；清理旧备份用 `try?` 静默失败 【疑似（代码已确认，触发概率低）】

- 证据：
  - `Database.swift:411-428`：顺序 move `-shm` → `-wal` → 主库；任一步失败即抛 `.io`。若 `-wal` 已移走、主库 move 失败，原路径只剩旧主库、WAL 在 `<db>.incompatible-<ts>-wal`，不是原子备份套。
  - `Database.swift:459-480` `pruneIncompatibleCopies`：`try? fileManager.removeItem` 吞掉删除失败，且按字符串排序后 `dropLast(keep)` 淘汰；如果目录里出现非本函数命名的同前缀文件（例如用户手工备份 `gather.sqlite.incompatible-20260101-000000-manual`），会被当作旧副本删除。
  - 默认 `retainIncompatibleCopies = 3`（`Database.swift:75-88`），保留 3 套符合 ADR-005。
- 影响：重置失败时恢复步骤比报告写的“把备份改回原名”复杂（需同时配对 `-wal`）；`prune` 的 `try?` 会让“备份删除失败”不可观测。
- 建议：先把主库 move 到临时名，再 move sidecar 到同一 target 前缀，最后统一 rename（或失败时回滚已移动文件）；`prune` 记录删除失败日志，且只删除本函数生成的时间戳格式。

### P2-10 扫描链路对“文件符号链接”仍会跟随，词法 `isWithin` 无法约束链接目标；错误信息含绝对路径并直达 UI 【疑似】

- 证据：
  - `IndexerService.swift:623-637`：目录用 `ScanPath.isDirectory`（lstat，不递归符号链接目录）；非目录再用 `stat`（跟随链接）判 `isFile`，因此 session 根内的文件符号链接会被导入，其目标可在根外。
  - `ScanPath.isWithin`（`ScanPath.swift:75-80`）是纯词法分量比较，不解析链接；`excludedRoots` 的排除对链接目标不生效。
  - `DatabaseError` 文案包含完整路径与 `error.localizedDescription`（`Database.swift:415-417/424-426/494-496`）；`APIErrorPresentation.swift:39` 对非 `GatherError` 直接返回 `localizedDescription`，`AppBootstrap.swift:96` 把结果放进首页错误文案。
- 影响：本机单用户场景风险低；但如果导入的是他人给的目录，可能把根外文件纳入“照片库”并读取其内容（导入是读路径，不写目标）。数据库打开失败时首页会显示用户主目录路径（信息泄漏面很小，但不符合“错误文案统一”的设计）。
- 建议：文件也用 lstat，符号链接文件跳过或解析后校验 `isWithin(resolved, root)`；错误展示层对 `DatabaseError.io/schema` 统一映射为稳定文案，路径只进日志。

### P2-11 CI 未执行 `gather-schema verify`；仍保留已删除的 `GATHER_RECONCILIATION_VECTOR` 开关 【已确认】

- 证据：`.github/workflows/ci.yml:28-50` 的 gates job 只有 8 个脚本；`:66-69` 的 core job 仍设 `GATHER_RECONCILIATION_VECTOR=1`，而 CL-06/5d-1 已写明该 gate 被取消、测试默认运行（`docs/cleanup-backlog.md:64`）。
- 影响：最终报告把 `gather-schema verify` 列为验收证据，但 CI 不会在后续 PR 守护 43/373/69/62 与 FK 不变量；环境变量是无效残留。
- 建议：gates job 增加 `swift run --package-path desktop/native/gather-core gather-schema verify`（macOS job 或单独 job）；删除无效 env。

### P2-12 决策/基线账本的元数据过期与编号冲突 【已确认】

- 证据：
  - `docs/refactor-decisions.md` 有 3 组重复编号：`D-081` 在 `:669` 与 `:692`，`D-162` 在 `:1388` 与 `:1404`，`D-163` 在 `:1396` 与 `:1413`（两组 D-163 内容不同：机械改名 vs 最终关闭）。`grep -c '^## D-'` = 165，但最大编号只到 163。
  - `docs/cleanup-baseline.json:93` 的 `services_prepare` scope 仍写已删除的 `gather-core/Sources/GatherCore/Services/**/*.swift`，实际脚本统计 `GatherDomain/Services`；`generated_at` = `2026-10-21T20:51:23Z`，而 `docs/refactor-progress.md:91` 记的是 `2026-10-21T19:01:01Z`。
  - `docs/refactor-decisions.md:1415` 称“L10n 注释全文件复扫 177/1,407 为 0”，但其他源码注释仍写 177：`GatherProtocol/API/Errors/GatherError.swift:12`（“不在 177 码内”）、`GatherPersistence/Database/DatabaseError.swift:19`（“177 个 GatherErrorCode”）。
- 影响：账本编号冲突会让 “D-163” 指代不明；baseline 的 scope 元数据与脚本实际行为不一致，后续 `--write-baseline` 会悄悄改写 scope；177 残留与“179 码”口径冲突。
- 建议：把后一组 D-162/D-163 重编号为 D-164/D-165（D-081 合并或重编），baseline 用 `--write-baseline` 重新生成或手改 scope/generated_at，源码 177 注释改为 179（或“当时 177，现 179”）。

### P2-13 文档仍称“人脸分析无需模型资产”，与实际 bundled SFace（38MB）和 build.sh 硬依赖矛盾；release/ 另有 9-29 的旧 bundle 【已确认】

- 证据：
  - `docs/README.md:64`：“人脸分析使用系统 Vision，无需模型资产”；`docs/ROADMAP.md:200`：“Vision 原生，无模型资产”。
  - 实际：`gather-core/Sources/GatherAnalysis/Resources/FaceModels/SFace.mlpackage/.../weight.bin` 38MB（git 跟踪）；debug 产物 `gather-core_GatherAnalysis.bundle/Contents/Resources/FaceModels/SFace.mlpackage` 存在；`build.sh:71-81` 找不到 FaceModels/.mlpackage 直接 exit 1。
  - `release/Gather.app` 是 2026-09-29 的旧 22MB arm64 二进制，早于本次重构；`docs/final-report.md:11/131/142` 说“本机未生成 bundle”。
- 影响：按文档会以为换机/裁剪资源也能跑人脸；实际 build.sh 会失败，且旧 bundle 可能被误当成本次产物做人工 smoke。
- 建议：文档改为“内置 SFace 模型包（FaceModels）随 GatherAnalysis 资源打包，约 38MB；真实数据质量验收仍为外部项”；删除或明确标注 `release/Gather.app` 为 2026-09-29 旧产物（`release/` 已 gitignore，不会入库）。

### P2-14 测试建库入口实际有两份（core `makeTestDB` / app `makeGatherTestDB`），与“唯一入口”注释不符 【已确认】

- 证据：
  - `gather-core/Tests/GatherTestSupport/DatabaseTestSupport.swift:18-20`：注释称“本函数是 core/app 测试唯一的建库入口”，定义 `public func makeTestDB()`（3 行：DBConnection(:memory:) + SchemaV1.sql）。
  - `gather-app/Tests/GatherAppTests/Support/TestDatabase.swift:14-19`：另一个 `func makeGatherTestDB()`，实现逐字相同；app 测试有 19 处调用，core 测试有 78 处 `makeTestDB` 调用。
  - 两个包不能共享 test target（GatherTestSupport 不是 product），所以“结构上无法合并”是事实；但注释/报告“只保留一个建库入口/80 处”会让读者以为 app 也用 core 的 helper。
- 影响：两处 DDL 夹具将来若一边改、一边忘改，会出现“core 测试绿、app 测试用旧夹具”的漂移；当前两份都只是 exec SchemaV1.sql，风险低但违反单实现口径。
- 建议：要么把 `GatherTestSupport` 提为 product 让 app 测试依赖，要么把注释改为“每包一份（跨 package 不可共享）”，并在 final-report 的 80 处口径里注明 app 侧另有 19 处未改名。

### P2-15 报告中的验收命令有 3 处按字面运行得不到宣称值 【已确认】

- 证据：
  - `docs/final-report.md:125`：`grep -rnE '\bl\(' Sources --include='*.swift' | grep -v /Support/` 实际输出 **2 行**（`DashboardView.swift:117`、`RootShellToolbar.swift:28`，均为注释），不是 0；语义上的“页面/VM 调用 0”成立，但命令需加 `grep -v '^.*:[0-9]*: *//'`。
  - `docs/final-report.md:53` 的 “`makeTestDB` 80 处/40 文件” 实测 `grep -rn makeTestDB` = **81 处**（1 定义 + 78 调用 + 2 处注释；非注释 79 行），文件 40 个；口径应写“79 个代码位置 + 2 处注释”。
  - `docs/final-report.md:29/101` 的 535 文件与 duplicate 门禁 535 一致，但 `find-unused-symbols` 自报 537（含 `Sources/.build` 的 2 个生成 accessor，见 P2-5）；两份“全仓文件数”不能互证。
- 影响：复跑者会以为报告数字错了；实际是命令/口径没写清。验收命令应能被原样复制执行并得到宣称值。
- 建议：在报告里给出带 `grep -v '^\s*//'`、排除 `.build` 的精确命令，并把“处/文件/代码位置”的口径写清。

### P2-16 导出的“旧文件备份/回滚”在失败路径上用 `try?` 静默，sidecar 备份失败仍会继续覆盖 【疑似（代码已确认，触发概率低）】

- 证据：
  - `ExportService.swift:447-457` `backupSidecar()`：`try? removeItem`、`if (try? copyItem(...)) != nil`；复制失败时 `sidecarBackup` 保持 nil，调用方仍继续写新 sidecar。
  - `:459-480` `commit()/rollback()`：删除/恢复全部 `try?`；回滚失败无日志、无错误返回，用户只看到原始错误。
  - `:484-509` `installFile`：覆盖前备份成功才继续；写入失败时 `:506` 删除备份而非恢复（若 `replaceItemAt` 失败已破坏目标，原文件只剩内存中的 backup URL 且被删）。
- 影响：磁盘满/权限/卷拔出的边缘场景下，可能“导出报失败但旧文件/旧 XMP 已被覆盖且备份被删”，与 `:429-430` 注释承诺的“回滚用备份恢复”不符。
- 建议：`backupSidecar` 失败应 throw 并中止该文件；`rollback` 返回/记录失败并保留备份；`installFile` 的 catch 分支在目标可能已被替换时优先恢复备份，而不是删除备份。

### P2-17 `docs/reviews/README.md` 仍写“当前有效评审（4 篇）”，实际已有 12 篇非 README 评审（并行评审未索引） 【已确认】

- 证据：`docs/reviews/README.md:1` 标题与表格只列 4 篇 + README；`ls docs/reviews/*.md` 现为 13 个文件（12 篇非 README：4 篇旧评审 + `post-refactor-r1-api.md` … `r7-tests.md` 7 篇 + 本报告）。`./scripts/check-docs.sh --strict` 只检查 `docs/reviews` 篇数 >20 的告警，不会发现索引缺项。
- 影响：索引与目录不一致，读者/门禁对“当前有效评审”的认知漂移；后续再归档时容易漏掉新报告。
- 建议：由本轮评审收口人把这 8 篇（r1–r7 + 本报告）补进 `docs/reviews/README.md` 表格，或新增“本轮评审（未定稿）”分组；同时把 check-docs 的 review_count 口径改为“目录篇数 == README 表格篇数”。

---

## 5. 已核实的正面结论（避免只列问题）

- **规模指标可复算**：535 文件 / 133,740 行；生产 370（core 147 + app 223）+ 测试 163 + 2 个 `Package.swift`，与 `docs/final-report.md:29-40` 一致。`docs 44 篇 / 18,999 行` 在 Cut 6c 写作时点可复算（本次 14:30 实测一致）；14:37–14:40 并行新增 7 篇域评审后为 52 篇 / 21,008 行，属新评审轮次，不计入 Cut 6。
- **Schema 指标可复算**：`gather-schema verify` = `tables=43 user_version=1 foreign_key_violations=0`；独立 SQLite pragma 复核 43/373/69/62。
- **错误码/协议可复算**：`GatherErrorCode` `case` = 179；`GatherProtocol/API/*API.swift` = 16 文件 / 110 个 `func`。
- **测试数（串行）可复算**：core 1092/157、app 581/66，exit 0。
- **8 门禁全部 exit 0**：ratchet 53/236/126/0/0（baseline 53/242/126/0/0）、test-catalog 163、docs strict、no-legacy 7 enforced、layering 17、duplicate 535、select-star 6/1、preview 14/5/2045。
- **删除清单主项可复算**：命令面 7 文件 `git show HEAD` 合计 **4,052** 行；旧同步 5 文件台账 4,081 行（其中 SchemaV1Transition 121 行为工作区新建后删除，HEAD 无此文件）；`Schema.swift` 649→**19**。
- **归档结构正确**：`docs/archive/reviews` 18 篇、`docs/archive/cuts` 10 篇、`docs/archive/reviews/assets` 49 个图片；md→md 链接 150 条全部可解析。
- **导出路径防线**：`ExportService.swift:718-756` 拒绝相对路径、`/`、非法命名；`:957-972` 对目标做 canonical 后再判定在根内；写入用临时文件 + 备份 + 失败回滚（`:484-509`）。未发现路径遍历写。失败路径的备份/回滚仍有 P2-16 的静默问题，属健壮性而非遍历漏洞。

---

## 6. 结论

- **机器验收的主干指标是可靠的**：535/133,740、43/373/69/62、179、16/110、core 1092/157、app 581/66（串行）、8 门禁 53/236/126/0/0 均可复算；删除清单的 HEAD 可查部分与报告一致。
- **不能签字的是“交付口径”**：
  1. CI 的 app 测试命令没有 `--no-parallel`，按该命令两次实跑均失败（P1-1）；
  2. 工作区 155 staged / 392 unstaged / 386 untracked，按常规 commit 会丢主体（P1-2）；
  3. Cut 4 的 RequestGate 未接线，CL-04 实际未完成，却被门禁/报告当作完成迹象（P1-3）。
- **文档层面**：CL 状态（P2-1）、Schema 14/19（P2-2）、94 key 的删除证据（P2-3）、当前评审的死链（P2-4）、D 编号冲突与 baseline 元数据（P2-12）、“无需模型资产”与旧 bundle（P2-13）、验收命令口径（P2-15）、reviews 索引（P2-17）是确定的账本漂移；不影响代码运行，但会让后续接手者按错误信息决策。
- **清理层面**：旧名 `GatherCore` 注释 12 处（11 个文件）、`RouterCommandError` 死分支、两个测试建库入口（P2-14）、`Sources/.build` 379MB 属于“已确认但低风险”的 Cut 6 尾项，建议在关闭 goal 前一次性清掉。
- **public API 最小性**：`find-unused` 报 4,284 个 public 声明（唯一名 2,366），core 四层 `package` 声明为 0、app 侧 76+24；core 作为跨包 product 必须 public，不能仅凭计数判定“过大”。**可确认的非最小项**是 `RequestGate`（仅测试引用）与 `RouterCommandError`（生产零构造、仅错误漏斗 as? 与测试构造）；“public API 已最小”这一结论目前没有门禁或清单支撑，属于【疑似未证明】。
- **安全层面**：未发现 P0；数据库重置的多文件 move 与 `prune` 的 `try?`（P2-9）、扫描文件符号链接与路径进错误文案（P2-10）、导出备份/回滚静默（P2-16）是需要在“旧库重置/导入/导出覆盖”场景留档的健壮性项，不是本次阻塞项。

**建议 owner 的关闭顺序**：先修 P1-1（统一 `--no-parallel` 或修竞态）与 P1-2（快照 + 明确提交口径），再决定 P1-3 是补做还是降级为 deferred；P2 可在同一清理轮处理，或明确写入 final-report 残余项。完成后再把 goal 标 complete。
