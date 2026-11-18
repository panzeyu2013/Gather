# 2026-11-18 第二轮全量独立评审（19 commits / 226 files）

- **评审对象**：本地 `main`（HEAD `0288ea8d`，含第一轮评审修复）相对上游 `origin/main`（`e5c54f37`）：**19 个提交、226 文件、+10432/−961**。
- **评审方式**：5 个新的独立 reviewer（review2-core / review2-app / review2-tests / review2-tooling / review2-docs，均未参与任何改动）分域只读复核。重点 = ① 验证第一轮 3 个修复提交（`6e940350`/`9be6a000`/`0288ea8d`）是否正确、完整、无副作用；② 用新视角重扫全部本地 diff 的残余风险与遗漏。所有评审文档与自审文档均被当作**待验证假设**。
- **环境与上限**：Linux Ubuntu 22.04，无 macOS/Xcode。**未在 macOS 编译/测试、未跑 swift test、无 Instruments/真机 UI**；证据 = 逐文件 `swiftc -parse` + **纯 Foundation 文件真实 `-typecheck`** + 真实 `GatherProtocol` 模块构建与 Swift Testing harness + Linux 探针 + `git archive` scratch 门禁负向探针 + 16/17 道 Linux 门禁。
- **分册**：[R2-core.md](R2-core.md)、[R2-app.md](R2-app.md)、[R2-tests.md](R2-tests.md)、[R2-tooling.md](R2-tooling.md)、[R2-docs.md](R2-docs.md)。

## 1. 结论摘要

| 级别 | 数量 | 代表问题 | 处置 |
| --- | --- | --- | --- |
| **P0（编译中断/CI 必红）** | **3** | 全部由第一轮修复提交 `6e940350`（2 个）或更早的 `2cbe3e68`（1 个）引入，第一轮用 `-parse` 验证漏检：① DateFormatting `withFormatter` 第三参数无外部标签、4 处调用写 `body:` → 4 条 extraneous argument label；② `CullingViewModel+Preload` 跨文件读 `private` 的 `pageAssignmentCount`；③ `CullingViewModel+Navigation` 跨文件读写 `private` 的 `navigationGroupsVersion`（第一轮 A1 修复所在文件直接不可编译）。另 core 测试 `JSONValueCodingTests` 的 `try` 位于 `==` 右侧 → GatherCoreTests target 编译失败（与 ① 同属 round-1 修复引入）。 | **全部已修**（见 §2），并引入"纯 Foundation 文件 `-typecheck` + 跨文件 private 启发式扫描"作为后续验收手段 |
| P1（新引入的行为回归） | 0 | — | — |
| P2（风险/完整性） | ~10 | docs-facts 的 CI wiring 仅全文子串（注释/掩码可绕过）；门禁清单可用节内正文提及绕过；test-catalog 断言基线 14954 非实测（实际 14958→14959）；protocol 扫描量守卫过松（50/100）；`.gitignore`×2 不在 hygiene [b] 面且 BOM 未查；`protocol_lines` 说明性字段漂移未更新；`MetadataKeywordWriter` 整批失败退化；`SidecarRegexCache<T: Sendable>` 的 Darwin `[NSRange]` 编译风险；applyImportedPicks 仍不具 DB 级乐观锁（上游同缺陷）；第一轮归档含 dangling hash 与"已修"夸大部分 | 已修/已降级/已记录（见 §2、§3） |
| P3（nit/加固） | ~40 | 协议守卫与基线说明、`@unchecked  Sendable` 双空格绕过、`--write-baseline` 缺 key 静默写、preload 守卫同内容替换误放弃、rowIndex map 不变量、启动计时口径等 | 高性价比项已收，其余记录 |

**总体判断**：第一轮修复的**语义方向全部成立**（DateFormatting 持锁/环境键、Observation 补读、Lightbox 身份校验、rowIndex 回退、applyImportedPicks 实时读、close optimize 移除、Mutex 日期解析、detached 200ms、DBStatementCache owner、测试窗口修复），但**第一轮以 `-parse` 作为"已修"证据不可靠**——本轮首次对纯 Foundation 文件做真实 typecheck + 跨文件访问级别扫描，立刻暴露 3 个 P0。后续验收已改用更硬的证据链。

## 2. 已修复项（round-2 fix）

| # | 来源 | 修复 |
| --- | --- | --- |
| 1 | R2-app P0-1 / R2-docs P0 / R2-tests P0 | `DateFormatting.withFormatter` 第三参数改为外部标签 `body:`；用 Linux 真实 typecheck 验证 4 处调用编译通过 |
| 2 | R2-app P0-2 / R2-docs P0 | `pageAssignmentCount` 改 `@ObservationIgnored private(set) var`（+Preload 只读） |
| 3 | R2-app P0-3 | `navigationGroupsVersion` 改 `@ObservationIgnored private(set) var`（+Navigation 只读；第一轮漏报的 `2cbe3e68` P0） |
| 4 | R2-core/R2-tests P0 | `JSONValueCodingTests` 的 `try` 拆成先取值再断言；新增"默认 encoder 无换行"格式漂移守卫 |
| 5 | R2T-01 / R2D-04（P2） | docs-facts CI wiring 升级：从 DEVELOPMENT「## 门禁」清单提取**完整命令**（含 flags），要求 ci.yml 非注释行逐条出现，并拒绝 `|| true`/`|| :` 掩码；清单只认以 `./scripts/` 开头的行 |
| 6 | R2T-02（P2） | 门禁清单作用域：只认以清单项形式出现的脚本行（节内正文提及不算） |
| 7 | R2T-03 / R2D（P3） | test-catalog 断言基线重钉到实测 **14959**；docs/README 同步 |
| 8 | R2T-05/06（P3） | hygiene [b] 增加 BOM 检测、`.gitignore` 进扫描面 |
| 9 | R2T-07（P3） | `protocol-surface` 用 `--write-baseline` 更新说明性字段（protocol_lines 17177→17192），门禁 strict 通过 |
| 10 | R2T-04/03（P3） | `check-protocol-surface` 注释改为 while-read 语义；扫描量守卫 50/100 → 100/400 |
| 11 | R2T-09（P3） | cleanup ratchet 的 `@unchecked Sendable` 改用空白类正则，双空格绕过被计数（60/60 不变） |
| 12 | R2C-05 / CORE-07（P2） | `MetadataKeywordWriter` 批量失败回退逐行读（不新增 `try?`，try_optional 保持 257） |
| 13 | R2C-04 / CORE-04（P2） | `SidecarRegexCache.withRegex` 去掉 `T: Sendable` 约束（Linux 探针验证 `[NSRange]` 返回可编译，Darwin 风险解除） |
| 14 | R2C-02/R2C-03（P2） | applyImportedPicks 注释与文档修正：明确只恢复逐张 µs 窗口、不含 DB 级乐观锁（上游同缺陷）；round-1 归档的"已修"描述与 dangling hash 修正 |
| 15 | R2D-05 等 P3 | 归档 hash 改 `0288ea8d`；protocol 基线"已修"改为"仅记录漂移"；ROADMAP/round-4 总览的 close-optimize 残留、perf-core-round2 的 touched* 表述、NSCache 悬崖前提（round-2 证伪）全部修正 |
| 16 | 验收方式 | 后续修复验收改为"纯 Foundation 文件真实 `-typecheck` + 可编译 target `swift build`"，不再以 `-parse` 全过作为"已修"证据（记录在 R2-docs） |

## 3. 残余与后续（均需 macOS 或下一轮）

1. **macOS 首跑必查（最高优先级）**：三个 P0 修复只经过真实 typecheck/逻辑探针；仍需 `swift build`（含 AppKit/SwiftUI target）、`swift test`、`check-warnings`、UI/Instruments。建议先跑 GatherCoreTests（JSONValueCodingTests）与 gather-app 全量构建。
2. **CORE-03 测试覆盖缺口**：DBStatementCache、applyImportedPicks revision 语义、JobService async 重试、EmbeddingModel LRU、Database.close 语义仍无新增回归测试；本轮仅修既有 flaky/false-green 测试。
3. **applyImportedPicks 的"真乐观锁"**：updateState 的 revision 比较与传入 preloadedDecision 同源（上游既有设计债务）；若要 DB 级检测，需在事务内用 fresh 行校验 expectedRevision 或改条件 UPDATE，属行为变化，建议单独立项。
4. **docs-facts 残余绕过面（P3）**：`if: false` / `continue-on-error: true` / 步骤级禁用仍未检测；门禁命令若被拆行/包 wrapper 也可能漏判（当前 CI 是直接 run 行，风险低）。
5. **协议基线**：`protocol_lines` 仍不参与比较（说明性字段）；模块级 baseline 的 `--write-baseline` 缺 key 静默写（P3，建议加一致性断言）。
6. **app 修复缺测试**：DateFormatting 新环境键/持锁、navigationGroupSize/similarGroupAssets 依赖、preload 守卫、rowIndex 回退等只有逻辑探针，建议补回归测试（Linux 可运行的纯逻辑部分先加）。
7. **preload 守卫误放弃（P3）**：决策回显用"同内容新 page"替换时守卫会放弃本轮预热（不重试）；可在 await 后重算 plan 做 Equatable 比较再决定。
8. **NSCache 预算**：悬崖前提已证伪（App 自编码预览无 DPI），但 512MB 对 2560 预览容量有限（约 24 张），需真机实测后决定是否调预算/分桶。

## 4. 验证（修复后实跑）

```text
SwiftPM manifest（core/app）→ OK
GatherProtocol / GatherPreviewData Linux 类型检查 → OK
swiftc -parse：全仓 1090 文件 → 0 failures
纯 Foundation 修复文件 Linux swiftc -typecheck（Swift 6）→ 0 errors
16/17 道 Linux 可跑门禁 → 全 PASS（含 5 个 --strict、hygiene 7/7、docs-facts、9 指标 perf-ratchet）
git diff --check → 干净
```

## 5. 分册覆盖

- R2-core：44 个 core 改动文件 + 15 个测试文件；5 处修复逐项验证（4 通过、Culling 行为等价但"检测未恢复"校正）；1 P0 + 2 P2 + 8 P3。
- R2-app：app 全部 463 文件 parse + 纯 Foundation 文件 typecheck + 跨文件 private 启发式扫描（暴露 2 P0）；17,295 次格式化 oracle 对拍；3 P0 + 0 P1 + 少量 P3。
- R2-tests：真实 GatherProtocol + Swift Testing harness 复现 P0；ReviewFixTests 窗口复核；test-catalog 基线实测；1 P0 + 残余测试缺口。
- R2-tooling：`git archive` scratch 负向探针 14 类；门禁修复正常路径等价；2 P2（CI wiring/清单作用域）+ 12 P3。
- R2-docs：归档/文档/修复最优性；3 P0 汇总 + 5 P2 + 17 P3；验证"移除 close optimize/持锁/基线收紧"取舍合理。

> 说明：各分册是修复前的独立快照（file:line 对应 HEAD `0288ea8d`），修复后以本总览与最终提交为准。
