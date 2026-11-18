# 2026-11-18 第三轮全量检查（22 commits / 234 files）

- **评审对象**：本地 `main`（HEAD `3486be0b`，含前两轮修复）相对上游 `origin/main`（`e5c54f37`）：**22 个提交、234 文件、+11587/−965**。本轮额外重点 = **验证第二轮 3 个修复提交（`5bcf915b`/`7b00b69a`/`3486be0b`）**，并以「系统化编译风险审计」补上前两轮 `-parse` 验证的盲区。
- **评审方式**：5 个新的独立 reviewer（review3-compile/core/app/tooling/docs，未参与任何改动）分域只读复核。所有前序 review 归档与审计文档都当作**待验证假设**。
- **环境与上限**：Linux Ubuntu 22.04，无 macOS/Xcode。**未在 macOS 编译/测试、未跑 swift test/check-warnings/Instruments**；证据 = 真实 `swiftc -typecheck`（纯 Foundation 文件、CullingViewModel 族、GatherProtocol/GatherPersistence 整模块 + shim）、真实 Swift Testing harness、Linux 探针、`git archive` scratch 门禁对抗探针、16/17 道 Linux 门禁。
- **分册**：[R3-compile.md](R3-compile.md)、[R3-core.md](R3-core.md)、[R3-app.md](R3-app.md)、[R3-tooling.md](R3-tooling.md)、[R3-docs.md](R3-docs.md)。

## 1. 结论摘要

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| **P0（编译中断/崩溃/数据丢失）** | **0（新）** | round-2 的 4 处 P0 修复被 compile/app/core/docs 四个 reviewer 用真实编译器独立复验通过（DateFormatting `body:` 标签、两处跨文件 `private(set)`、JSON 测试 `try` RHS）；全量 168 改动 Swift 文件启发式扫描（含用修复前快照做阳性对照）无新编译中断 |
| **P1（行为回归/CI 必红）** | **0（新）** | — |
| **P2** | **4** | ① applyImportedPicks 变体人工保护窗口=整批（R3C-01）；② 高风险运行期改动仍无回归测试（R3C-06）；③ docs-facts 的 CI wiring 仍可被 `if:`/短路/包装/附参绕过（R3T-01/02）；④ 归档/文档过时论断（NSCache 悬崖前提、protocol 基线、计数）（R3-docs） |
| **P3** | ~40 | 门禁自描述/链接解析/跨行计数/protocol 守卫/写基线缺 key/test.sh flags/注释标签/import 显式性等 |

**总体判断**：第二轮修复在**编译正确性**上完全闭环（真实类型检查 + 真实模块运行），未发现新的 P0/P1。剩余问题集中在「并发窗口语义」「门禁可信度」「文档与实现一致性」三类：本轮把 applyImportedPicks 的 N+1 预载**整体回退到上游逐张实时读**（正确性优先），并把 docs-facts 的 CI 接线升级为**精确 run 行 + 禁用/短路检测**（含 `if: ${{ false }}` 表达式归一化），其余高性价比 P3 已批量收。

## 2. 已修复项（round-3 fix）

| # | 来源 | 修复 |
| --- | --- | --- |
| 1 | R3C-01/R3C-03/CORE-01b（P2） | `applyImportedPicks` **整体回退**到上游逐张实时读（主照片 + 每个变体各自 getDecision），撤销批前预载；变体人工保护窗口回到 µs 级；回退版与 upstream 去注释后逐字节相同。round-2 的 N+1 收益不再保留（正确性优先），文档同步修正 |
| 2 | R3T-01/02（P2） | docs-facts CI wiring：只认 **fenced block** 清单；按 job 解析、要求**精确 run 行**（含完整命令与参数）；拒绝 `if:false`/`continue-on-error:true`（含 `${{ ... }}` 表达式归一化）、`|| true` 等掩码、echo/包装/附参/跨行/错 job；支持合法 block-scalar 单命令与引号 run；无关注释/禁用 step 不误报。DEVELOPMENT 的 warnings 拆成 `core`/`app` 两条精确命令 |
| 3 | R3T-03（P3） | 门禁清单从「节内任意行」收紧为「仅 fenced code block 内以 ./scripts/ 开头的行」 |
| 4 | R3T-06（P3） | hygiene [c] Markdown 链接支持带 title 的 `[x](path "t")` 与引用式 `[x][ref]` + `[ref]: path`（负例实测 FAIL、正常 212 链接全解析）；头部自描述同步 |
| 5 | R3T-07（P3） | cleanup `@unchecked Sendable` 计数改为**跨行 + 块注释间隔 + 双空格/Tab**（负例 61/60 FAIL，当前仍 60/60）；注释措辞修正 |
| 6 | R3T-08（P3） | protocol 扫描量守卫 105/510→**110/513**（top-105 截断 512 FAIL）；`protocol_files/lines` 标注为信息字段（不参与比较） |
| 7 | R3T-09（P3） | perf/cleanup/protocol 的 `--write-baseline` 在**旧基线缺 key** 时拒绝静默补写（三脚本同构；实测 rc=1） |
| 8 | R3T-10（P3） | test.sh 的 `SWIFT_TEST_FLAGS` 支持换行分隔（先归一为空格再 `read -a`） |
| 9 | R3T-04/R3C-11 等（P3） | DEVELOPMENT warnings 两条精确命令；Sidecar 注释轮次标签纠正；CullingViewModel 显式 `import Observation`；Gallery rowIndex 注释与实现一致；MetadataDisposition catch 增加 warn 日志；Database.close 注释措辞 |
| 10 | R3C-04/C-05/C-07（P3） | MetadataKeywordWriter 过时注释修正；SidecarRegexCache 注明「body 内禁止再调 withRegex」；AssetRepo+Scan 的 DBStatementCache limit 14→16 并修正缩进 |
| 11 | R3D-01~14（P2/P3） | 归档/文档修正：round-2 归档标注「部分修复 + 残余绕过面」；round-1 归档 hash 语义/协议基线/parse≠typecheck 口径；round-3 总览 NSCache 悬崖前提证伪与预算说明；round-2 §5 计数；perf-core-round2 的 applyImportedPicks 回退记录；round-4/ROADMAP/README 的 optimize 与日期 |

## 3. 残余与后续（before-merge / later）

**合并前必须**：
1. **macOS 首跑**：`swift build`（两包）、`swift test`（GatherCoreTests + GatherAppTests）、`check-warnings.sh core/app`、UI/Instruments 冒烟。三条评审线均未在 macOS 编译过；本机 `-typecheck`/harness 是逼近而非等价。
2. 提交后按最终提交重跑 16 道 Linux 门禁（本轮 gate 脚本改动较大，已在本工作树全绿 + 对抗探针，但需对最终 commit 复核）。

**后续（不阻塞合并）**：
- **CORE-03 回归测试缺口**：DBStatementCache（跨连接 DEBUG assert/limit/末块）、JobService async retry、EmbeddingModel LRU、Database.close 幂等、KeywordWriter 回退分支；app 侧 DateFormatting 持锁/环境键、Observation 依赖、preload 守卫、rowIndex 回退。
- **真 DB 级乐观锁**（上游设计债）：updateState 的 revision 比较与传入 preloadedDecision 同源；要真正防丢失更新需事务内 fresh 行校验或条件 UPDATE，属行为变化。
- **docs-facts 残余绕过面**：step/job `if: ${{ <非字面> }}` 表达式（如 always() 之外的条件）与 docs-facts 自监视盲区；hygiene [g] 本地化门禁未覆盖设计系统 wrapper 的裸 String 组件；shellcheck 版本未 pin。
- **协议基线**：`protocol_files/lines` 仍为信息字段（不参与比较）；模块级指标已纳入缺 key 拒绝。
- **app 修复测试**：DateFormatting/observation/Lightbox 等逻辑目前只有 Linux 探针，建议补可 Linux 运行的纯逻辑回归测试。
- **preload 守卫误放弃（P3）**：决策回显同内容替换 page 时会放弃本轮预热；可在 await 后重算 plan 做 Equatable 比较。
- **NSCache 预算**：悬崖前提已证伪（App 自编码预览无 DPI），真实残余是 512MB 对 2560 预览容量有限（约 24 张），需真机实测后调预算/分桶。
- **test.sh flags 文档**：已支持换行分隔；`--parallel` 等仍按本机语义。

## 4. 验证（修复后实跑）

```text
SwiftPM manifest（core/app）→ OK
GatherProtocol / GatherPreviewData Linux 构建 → OK
DateFormatting 真实 swiftc -typecheck（Swift 6）→ OK
JSONValueCodingTests：真实 GatherProtocol + Swift Testing harness 6/6、隔离/并行/多次复跑确定性 OK
swiftc -parse：全仓 1090 文件 → 0 failures
16/17 道 Linux 可跑门禁 → 全 PASS（含 5 个 --strict）
对抗探针：docs-facts（if/coe/表达式/附参/echo/注释/跨行/job 级/valid block-scalar/valid quoted/无关禁用 step）、hygiene 标题+引用链接、cleanup 跨行/块注释、protocol 截断/缺 key、write-baseline 缺 key → 全部符合预期
git diff --check → 干净
```

## 5. 分册覆盖

- R3-compile：168 改动文件系统化编译风险审计；41/168 真实编译器级验证；跨文件 private 扫描器用修复前快照做阳性对照；P0/P1/P2=0，2 P3。
- R3-core：round-2 core 4/4 修复真实复验（含 GatherPersistence 整模块 typecheck）；round-1 core 全复核；applyImportedPicks 回退与 upstream 等价性确认；P2×2 + P3×11。
- R3-app：round-2 app 修复真实 typecheck + 22,005 次格式化 oracle 对比；0 P0/P1/P2；P3×6。
- R3-tooling：16 门禁两轮逐字节一致；round-2 gate 修复逐项复核；工作区 round-3 门禁修复对抗复验（精确 run/禁用/短路/链接/计数/写基线）；残余 P2×1 + P3×8。
- R3-docs：round-2 归档准确性、文档数字、链接/索引、修复最优性；P2×2 + P3×12。

> 说明：分册是各 reviewer 在修复前的独立快照（file:line 对应 HEAD `3486be0b`），修复后以本总览与最终提交为准。
