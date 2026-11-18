# R2 第二轮独立评审：脚本 / 门禁 / CI / 基线（tooling 面）—— 对抗性复核 + 门禁体系完整性

- **评审人/任务**：review2-tooling（task-34：独立第二轮 adversarial review，scope = `scripts/**`、`.github/workflows/ci.yml`、`.gitattributes`、ratchet baselines）。
- **被评对象**：本地 `main` HEAD `0288ea8d`（`origin/main` = `e5c54f37`，19 个提交，226 files / +10432 / −961）。重点复核 2026-11-18 修复提交 `9be6a000`（gates/baselines，7 文件 +48/−11）与 `0288ea8d`（docs 归档，17 个 docs 文件、无 scripts/baseline 改动）；同时以全新视角重扫本地 diff 的脚本/CI/基线面，找第一轮遗漏与未修复残余。
- **环境与验证上限**：Linux Ubuntu 22.04，**无 macOS/Xcode**。可执行面 = 仓库自带 Linux 门禁 + shellcheck 0.10.0（`.gather/shellcheck`）+ python3 + 只读 git + Swift 6.2 Linux `swiftc -parse`（仅语法，不是类型/并发检查）。未跑 `swift build/test`、`check-warnings.sh`（macOS SDK）、actionlint（未安装）、CI runner。
- **对抗性探针环境**：`.gather/r2tooling/`——`git archive HEAD` 解出的独立副本（1271 tracked 文件）+ 假 `git` stub（支持 `rev-parse --show-toplevel` / `ls-files -z [pathspec]`），`PATH` 前置，**未改动真实工作树**。探针命令见 §5。
- **评审时点工作树状态**：开始时 `git status --short` 为空；评审期间出现**他人并发**的未提交改动（15 个 tracked 文件，含本 scope 的 `scripts/check-docs-facts.sh`、`scripts/check-repo-hygiene.sh`、`scripts/check-test-catalog.sh`，另见 §6——非本评审修改、未触碰）。**本文件的 findings 针对已提交的 HEAD `0288ea8d`**；§2 的门禁实跑是在工作树干净期完成的；并发改动只在 §6 单独记录，不当作已验证。`docs/reviews/2026-11-18-local-changes-review-round2/` 为未跟踪的本轮评审目录。
- **结论摘要**：**0 P0 / 0 P1**。`9be6a000` 的 7 处改动均**正确、可运行、正常路径行为等价**；但其中两项门禁加固（R4-F1 的清单作用域、R4-F2 的 CI wiring）均为**不完整修复**，新检查本身可被“节内正文提及 / 注释掉的 CI 步骤 / `if: false` / `continue-on-error` / 去掉 `--strict`”绕过 → **P2 × 2**。另有 **P3 × 12**：断言基线仍差 4 条实测、protocol 扫描量守卫过松、protocol 基线说明性字段漂移（F9 未修且总览误称已修）、BOM 仍未检查（F18）、hygiene 头部注释与 `.gitignore` 覆盖残余、perf/cleanup/protocol `--write-baseline` 缺 key 静默写（F20 类）、`@unchecked  Sendable` 双空格绕过 ratchet、report-baseline 头部断言不实（F10）、总览引用悬空 commit、`test.sh` 换行 flag 残余。

## 1. Findings

| ID | 级别 | 位置（file:line / commit） | 问题 | 证据（本次实跑/实读） | 建议修复 | 置信度 | macOS 不可验？ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R2T-01 | **P2** | `scripts/check-docs-facts.sh:392-403`（commit 9be6a000，R4-F2 修复未完成） | 新 CI wiring 断言只做 `'./scripts/<name>' in ci_text` **全文子串**匹配：步骤被**注释掉**、路径只出现在任意注释里、步骤加了 `if: false`、`continue-on-error: true`、`run: … || true`、或把 `--strict` 从 CI 去掉，门禁全部仍 PASS；改为 `bash scripts/x.sh`（无 `./`）则**误报**。门禁只防“整行删除”，不防“静默禁用/降级” | scratch 探针（改 ci.yml 后跑 docs-facts）：① 删 `run: ./scripts/check-repo-hygiene.sh` → rc=1 FAIL ✅；② 同一行改成 `# run: …` → **rc=0**（“CI 已接入全部 17 个门禁脚本”）；③ 删两步 + 文末注释 `# moved elsewhere: ./scripts/check-repo-hygiene.sh` → **rc=0**；④ 步骤加 `if: false` → **rc=0**；⑤ 把**所有** `run:` 里门禁路径注释掉 → **rc=0**；⑥ 去掉 protocol/test-catalog 两步的 `--strict` → **rc=0**；⑦ `|| true` + `continue-on-error: true` → **rc=0**；⑧ `run: bash scripts/check-layering.sh` → **rc=1 误报**；ci.yml 清空 → rc=1 FAIL ✅ | 用结构化解析（或严格行形态 + 同 step 块内禁止 `#`/`continue-on-error`/`if: false`/`||`/`&&`）提取**实际会执行**的 `run` 行，并把 docs/DEVELOPMENT 声明的 `--strict` 与 CI 实参交叉校验；或改为机读 gate registry（JSON）同时驱动 docs/CI。另注：docs-facts 自身被删/注释时无人再检查（自监视盲区），可加一条与 docs 无关的 meta 断言（如 ci.yml 中必须出现自身） | 高 | 否 |
| R2T-02 | **P2** | `scripts/check-docs-facts.sh:372-384`（commit 9be6a000，R4-F1 修复未完成） | 清单作用域只从 `## 门禁` 截到下一个 `## `；**小节内任意文本**出现 `./scripts/<name>` 即算数，不限于代码块清单行。删掉清单行、只在同节正文/注释里提一句即可绕过；把清单行改成注释（`# ./scripts/check-layering.sh …`）也 PASS | scratch 探针（docs-facts）：① 删 `./scripts/check-layering.sh` 清单行 → rc=1 FAIL ✅；② 删该行 + 在门禁节内加正文“注：历史提到 ./scripts/check-layering.sh 已合并。”→ **rc=0 绕过**；③ 清单行前加 `# ` 注释 → **rc=0**；④ 提及放到下一 `##` 节之外（真·节外）→ rc=1 ✅；⑤ 标题改 `## 门禁与 CI`（前缀）→ rc=0（合理）；⑥ 标题改 `## Gates` → rc=1 fail-closed ✅；⑦ 门禁节前插一个空的重复 `## 门禁` → rc=1（取第一节，fail-closed，可接受但脆） | 只解析该节 **fenced code block 内以 `./scripts/` 起始的行**（行锚定正则 + 提取脚本名），或把清单改成机读 JSON/表格；不要用全文子串 | 高 | 否 |
| R2T-03 | P3 | `scripts/check-test-catalog.sh:370-373,486`（commit 9be6a000） | `BASELINE_ASSERT=14954` **不是修复提交时的实测值**：`6e940350`/HEAD 实测 **14958**，仍是第一轮修复前（`5ea5c38f`=14954）的数字 → 当前仍可静默删 4 条断言；注释“三个基线重钉到实测值：2502/283/11509 -> 3267/419/14954”对断言一项不实；`@Test/@Suite` 已精确。`report-baseline` 也把 14958 与 baseline 14954 并排打印 | `git archive 5ea5c38f` Tests 实测 3267/419/14954；`git archive 6e940350` 与 `9be6a000` 实测均 3267/419/**14958**；HEAD gate 输出 `断言 ratchet #expect+#require 14958/14954`；scratch 探针：注释掉 4 条 `#expect` → rc=0（14954 仍 = baseline），5 条 → FAIL（14953） | 重钉 `BASELINE_ASSERT=14958`（或按最终树重测）并修正注释；顺带在报告里标注“baseline 与 current 的差可收紧” | 高 | 否 |
| R2T-04 | P3 | `scripts/check-protocol-surface.sh:82-86`（commit 9be6a000，R4-F22 守卫） | 扫描量守卫阈值 `proto_file_n < 50 || public_types < 100` 相对实测 111 文件 / 514 类型过松：**截断到 50 个文件（429 类型）`--strict` 仍 rc=0**（下行只会 warn 不会 FAIL）；守卫只是“归零绊线”，挡不住“丢掉 54% 扫描面”的路径/半边目录故障 | scratch 探针：保留 51 个最多类型的文件 → rc=0（protocol 51/13215、types 429，warn 后 OK）；保留 50 → rc=0；保留 20 → rc=2 `FAIL 扫描量异常：proto_file_n=20 public_types=277` ✅ | 阈值由基线派生（如 `proto_file_n >= protocol_files_baseline - 5`、`public_types >= public_types_baseline - 10`），或把 `protocol_files`/`protocol_lines` 纳入 compare_metric（回落超过容差即 FAIL） | 高 | 否 |
| R2T-05 | P3 | `scripts/check-protocol-surface.sh:73-75`（commit 9be6a000） | 注释仍写“文件清单用 **xargs** 逐行传入…路径含空白时会拆错”，但实现已改 `while IFS= read -r`；且“空白会拆错”对 `xargs -I{}` 不成立（真正崩的是**单引号**）。注释与代码/事实都不符 | `sed -n '73,76p'` 显示 xargs 描述 + while-read 代码；旧版（`5ea5c38f`）实测：带空格文件名 rc=0（不拆错），带单引号文件名 rc=1 `xargs: unmatched single quote` | 更新注释为 while-read 方案，删掉“空白拆错”论断；若保留历史说明，注明单引号才是旧 xargs 的失败原因 | 高 | 否 |
| R2T-06 | P3 | `scripts/check-repo-hygiene.sh:204-226`（R4-F18 未修） | `[b]` 只 `data.decode('utf-8')`，**不查 UTF-8 BOM**；`.editorconfig:7` 是 `charset=utf-8`（无 BOM 语义）。BOM 文件可通过 | scratch 探针：给 `docs/README.md`（常规文本）、`Info.plist`（本轮新增类型）、`LICENSE`（basename 类型）前缀 `\xef\xbb\xbf` → 三例 `[b] ok 1266 个文本文件全部符合`、rc=0 | `if data.startswith(codecs.BOM_UTF8): problems.append((path,'has UTF-8 BOM (charset=utf-8 不含 BOM)'))`；并加负例自测 | 高 | 否 |
| R2T-07 | P3 | `scripts/check-repo-hygiene.sh:13-15` vs `:180-194`（commit 9be6a000） | `[b]` 头部注释仍宣称检查面是“swift/md/sh/py/json/yml/yaml/strings/txt + editorconfig/gitattributes”，与实现新增的 plist/entitlements/modulemap/h/c/tsv/pbxproj/xcconfig/m/mm/Makefile/LICENSE/SHA256SUMS 不一致（门禁文档自描述过期） | sed 同屏对比：头部 3 行 vs `TEXT_EXT/TEXT_FILENAMES` 常量 | 同步头部注释（并列出 `TEXT_FILENAMES`） | 高 | 否 |
| R2T-08 | P3 | `scripts/check-repo-hygiene.sh:180-194`（commit 9be6a000） | 文件面仍是硬编码集合，仍漏 2 个 tracked 文本文件 `.gitignore`、`desktop/.gitignore`（`.editorconfig [*]` 对其同样生效）；当前二者干净，但违规不会被抓。tracked 1271 中 1266 被覆盖、3 个二进制（icns/mlmodel/bin）合理排除、2 个 .gitignore 未覆盖 | 用与 [b] 相同的判定枚举 tracked：uncovered = `.gitignore, desktop/.gitignore, AppIcon.icns, model.mlmodel, weight.bin`；对未覆盖文件跑同规则无违规；扩展统计确认无 `.pbxproj/.xcconfig/.m/.mm/.h/.c` 之外的新文本类型 | 把 `.gitignore` 加入 `TEXT_FILENAMES`（或更彻底：对 tracked 且可 UTF-8 解码且不含 NUL 的文件全查，二进制用显式 allowlist）；至少在注释写明“已知排除” | 高 | 否 |
| R2T-09 | P3 | `docs/protocol-surface-baseline.json:4-5` + `docs/reviews/2026-11-18-local-changes-review/00-overview.md:42`（F9 未修/总览误称已修） | 基线 `protocol_files/protocol_lines` 写入但**从不参与比较**，且已漂移：baseline `111/17177` vs 实测 `111/17192`（+15 行）；`9be6a000` 及整个本地 range **都没改过** protocol 基线（`git diff 5ea5c38f..HEAD -- docs/protocol-surface-baseline.json` 为空），但 00-overview §2 #18 声称“protocol 基线说明性字段更新” | `grep protocol docs/protocol-surface-baseline.json` → 17177；`./scripts/check-protocol-surface.sh --strict` → `Protocol 文件/行 111 / 17192`；`git log --oneline 5ea5c38f..HEAD -- docs/protocol-surface-baseline.json` 为空；compare_metric 只有 4 个指标 | 二选一（与第一轮 F9 建议一致）：把 files/lines 纳入 compare_metric（行数可只 warn/或容忍 ±N），或从基线删除并在 note 标为信息字段；同时修正 00-overview 的“已修”声明 | 高 | 否 |
| R2T-10 | P3 | `scripts/check-perf-ratchet.sh:159-175`（R4-F20 未修）；`scripts/check-cleanup-ratchet.sh:131-147`、`scripts/check-protocol-surface.sh:190-207` 同型 | `--write-baseline` 的反膨胀守卫对“baseline 缺 key”执行 `[ -n "$base" ] || continue`：新增指标在旧基线缺 key 时会**被静默写入**（普通校验模式缺 key 是 FAIL，写入路径反而不拦） | scratch 探针：删 `docs/perf-baseline.json` 的 `raw_byte_formatter` key → 普通模式 rc=1 `FAIL (baseline 缺 key)` ✅；`--write-baseline`（无 `--allow-growth`）→ **rc=0 “baseline 已写入”，key 静默恢复**；cleanup/protocol 守卫代码同构（同样 `continue`） | 缺 key 时同样拒绝写入（要求先补 key 或显式 `--allow-growth`）；三脚本统一修正 | 高 | 否 |
| R2T-11 | P3 | `scripts/check-cleanup-ratchet.sh:82`（新增指标族，非本轮 fix） | `unchecked_sendable` 用字面量 `'@unchecked Sendable'` 单空格匹配：`@unchecked  Sendable`（双空格，Swift 6 **合法**语法）不计入，可绕过 ratchet；`nonisolated (unsafe)`（空格）变体在 Swift 6 语言模式是错误（不会进仓），不作为 finding | `swiftc -parse`：`final class Probe: @unchecked  Sendable {…}` rc=0 无警告；scratch 注入单空格 → cleanup `unchecked_sendable 61/60 FAIL`；双空格 → **60/60 ok**；`nonisolated (unsafe)` parse rc=0 但有 “extraneous whitespace … error in Swift 6 language mode” 警告 | 正则改 `@unchecked[[:space:]]+Sendable`（BSD/GNU grep -E 都支持 POSIX 字符类）；同类零容忍指标复查空白变体 | 高 | 否（语法用 Linux swiftc 验证） |
| R2T-12 | P3 | `docs/reviews/2026-11-18-local-changes-review/00-overview.md:21`（docs 声明不实） | 总览把第三笔修复写成 `33ef7313`（docs 归档/文档修正），但该 commit **不在 HEAD 历史中**（悬空对象；实际提交是 `0288ea8d`，内容/信息相同，应为改写前 hash）；按 commit 复核的人会找不到 | `git merge-base --is-ancestor 33ef7313 HEAD` → NOT ancestor；`git cat-file -t 33ef7313` 存在；`git log --oneline -1 33ef7313` 与 `0288ea8d` 同 message；`git rev-list --count origin/main..HEAD`=19 | 改为 `0288ea8d`（或写成“docs 归档提交”） | 高 | 否 |
| R2T-13 | P3 | `scripts/report-baseline.sh:17-18`（R4-F10 未修；非门禁） | 头部宣称 schema 段是“expected* 常量**与 DDL 字面量实测计数交叉核对**”，但代码/输出只实测 tables/indexes/foreign keys，**列数 451 从未实测**；性能段仍是 perf-ratchet 的第二份实现（当前实测一致，长期有漂移风险）。非门禁、不进 CI，影响面小 | `./scripts/report-baseline.sh` 输出 `DDL 实测: tables 55 / indexes 86 / foreign keys 81`，列数来自 `expectedColumnCount` 常量；两次运行输出逐字节一致（110 行）；测试/@Test/@Suite/断言 3267/419/14958、perf 9 项与门禁一致；`grep -c report-baseline .github/workflows/ci.yml` = 0（非门禁属实） | 头部改成“列数取自 expected* 常量；DDL 实测 tables/indexes/FKs”，或补真实列数测量；性能段加“与 check-perf-ratchet.sh 必须一致”的自检提示 | 高 | 否 |
| R2T-14 | P3 | `scripts/test.sh:31`（R4-F23 残余，未修） | `read -r -a FLAGS <<< "${SWIFT_TEST_FLAGS:-}"` 只按**首行**拆 flag；旧写法不加引号展开时变量含换行会拆成 2 个 flag、新写法只取首行 1 个。单行正常用法等价（空/多 flag/glob 语义新写法更安全），属文档化残余 | 代码 diff 与 bash 语义（第一轮实测：`--a\n--b` → old=2 / new=1）；正常值等价见第一轮 R4 §2.7（本次不再重复该 bash 探针） | 加一行注释“SWIFT_TEST_FLAGS 不支持换行分隔”（或改为整串按空白拆分） | 高 | 否 |

> 注：R2T-03/05/07/08/09/12/13/14 都是“门禁自描述/残余缺口”类问题，不是本轮引入的行为回归；真正影响门禁可信度的是 R2T-01/R2T-02（第一轮 F1/F2 的修复不完整），建议优先修。

## 2. Verified OK（独立复核通过）

### 2.1 修复提交范围与结构（9be6a000 / 0288ea8d）
- `9be6a000` 只改 7 个文件（numstat：.gitattributes 1/0、docs/cleanup-baseline.json 1/1、check-docs-facts.sh **22/1**、check-protocol-surface.sh **10/4**、check-repo-hygiene.sh **8/1**、check-test-catalog.sh **5/3**、design-system-baseline.json 1/1；合计 +48/−11），与 commit message 对得上，无无关改动。
- `0288ea8d` 只改 docs（DEVELOPMENT/README/ROADMAP/round-1..4 归档/回顾索引），**不碰** scripts/CI/baseline；本地 range 共 19 个提交、226 files / +10432/−961 与任务描述一致。
- `git diff --check origin/main..HEAD` rc=0（提交范围无行尾空白/EOF 问题）。

### 2.2 门禁套件实跑（HEAD 最终树，Linux 可跑 16/16 全绿）
逐条跑 `./scripts/check-*.sh`（[f] 前置 `PATH="$PWD/.gather:$PATH"`，与 CI 同 flags）：

    check-backlog-evidence rc=0   3ms | check-cleanup-ratchet rc=0  8477ms | check-coded-errors rc=0  87ms
    check-design-system   rc=0  74ms | check-docs-facts    rc=0  47ms | check-domain-events rc=0  25ms
    check-domain-writes   rc=0 161ms | check-duplicate-symbols(--strict) rc=0 1893ms | check-layering rc=0 122ms
    check-no-legacy       rc=0 221ms | check-perf-ratchet rc=0 9593ms | check-preview-surface(--strict) rc=0 64ms
    check-protocol-surface(--strict) rc=0 3481ms | check-repo-hygiene rc=0 1700ms | check-select-star(--strict) rc=0 1863ms
    check-test-catalog(--strict) rc=0 1142ms

关键数字：hygiene [a] 26 sh / [b] **1266** 文本文件 / [c] 94 md·206 链接 / [d] en 2682·zh 9 / [e] 35 tracked scripts 无缓存产物 / [f] shellcheck 0.10.0 26 sh 0 finding / [g] 272 文件·2264 调用·CJK 1718 全包裹；docs-facts 全部断言 PASS（targets 18、API 16/195、schema 55/451/86/81、en 2682/zh 9、门禁 17）；perf 9 指标全部 = baseline（28/30/45/38/20/22/3/1/0，Sources 750）；protocol 4 指标 + 10 个模块指标 = baseline；cleanup 9 指标 = baseline；design 8 指标 = baseline。`check-warnings.sh` 需 macOS，未跑（见 §3）。

### 2.3 docs-facts（R4-F1/F2 修复）对抗性验证
- 负向：删清单行 → FAIL ✅；删清单行 + 节外提及 → FAIL ✅；标题改 `## Gates` → FAIL ✅；删整个门禁节 → FAIL ✅；重复空节在前 → FAIL（取第一节，fail-closed）✅；CI 步骤整行删除 → FAIL ✅；ci.yml 清空 → FAIL ✅。
- 动态计数：scratch 新增未接线的 `scripts/check-probe-gate.sh` → FAIL 三项（README 门禁数 17≠18、DEVELOPMENT 缺清单、CI 未接入）；在 DEVELOPMENT 清单 + ci.yml step + docs/README 计数全部补齐后 → PASS（“CI 已接入全部 18 个门禁脚本”）✅。
- 正向：HEAD 树 `ok CI 已接入全部 17 个门禁脚本`、清单 17/17 ✅。
- 绕过面见 R2T-01/R2T-02（这是本次唯一未通过的加固项）。

### 2.4 check-repo-hygiene [b] 扩展面（R4-F3 修复）
- 正向：HEAD `[b] ok 1266 个文本文件全部符合`；扩展新增覆盖 10 个文件（2 plist、entitlements、modulemap、h、c、tsv、Makefile、LICENSE、SHA256SUMS），这些文件在扩展前不在扫描面。扫描耗时随整套 hygiene 1.7s（[b] 为纯 Python 单遍读 1266 文件，无性能问题）。
- 负向（scratch，全部按预期 FAIL 并给 file:line）：`.entitlements` 追加 CRLF → `has CR`；`Info.plist` 追加行尾空白 → `L31 trailing whitespace`；`module.modulemap` 去末行换行 → `missing final newline`；`SHA256SUMS`（basename 规则）去末行换行 → FAIL；`Makefile` 行尾 tab → `L51 trailing whitespace`；`LICENSE` 行尾空白 → FAIL；`summary.tsv` 行尾空白 → FAIL。
- 无假阳性：HEAD 1266 文件全过（LICENSE/Makefile/SHA256SUMS 即在其列）；负例只在注入后触发。残余缺口：BOM（R2T-06）与 `.gitignore`（R2T-08），且头部注释过期（R2T-07）。

### 2.5 check-test-catalog ratchet（R4-F6 修复）
- 正向：`@Test 3267/3267 · @Suite 419/419` 精确相等（独立用脚本内同一计数逻辑在 HEAD 与 `5ea5c38f` 树复算一致）；`--self-test` rc=0 `SELFTEST OK`。
- 删除检出仍有效（scratch）：删 1 个 `@Test` → FAIL（3266<3267）；删 1 个 `@Suite` → FAIL（418<419）；注释掉 5 条断言 → FAIL（14953<14954）。注释块算术可复核：3267−2502=765、14954−11509=3445 与注释一致。
- 残余：断言基线差 4（R2T-03）。

### 2.6 check-protocol-surface while-read 替换 + 守卫（R4-F22 修复）
- **正常路径行为等价**：scratch 中同时跑旧版（`git show 5ea5c38f:…`，主清单 xargs、模块 xargs）与新 HEAD 版（全 while-read）：stdout **逐字节 identical（25 行）**，rc 均 0，stderr 均空；5 个模块 10 行指标与 baseline 全 ok。
- **单引号路径修复真实有效**：新建 `GatherProtocol/Probe Note's.swift`（仅注释、无 public 声明）→ 旧版 rc=1 `xargs: unmatched single quote`、stdout 空；新版 **rc=0** 且输出完整指标。带空格文件名旧/新都 rc=0（旧版不拆错，见 R2T-05）。
- 指标确实会拦截真实增长：同名文件含 `public struct` 时旧/新都 rc=1（515>514），新版还能打印完整 metrics（旧版直接崩）。
- 守卫对“归零/近零”有效：保留 20 个文件 → rc=2 `FAIL 扫描量异常`；但对“截断到 50 文件/429 类型”过松（R2T-04）。

### 2.7 .gitattributes（R4-F11）与基线收紧（R4-F7/F8）
- `9be6a000` 的 .gitattributes 只加一行 `docs/perf-baseline.json linguist-generated=true`，位置/分隔符与既有 4 行一致；文件可被 git 正常解析（`git check-attr -a` rc=0 无告警）。`git check-attr linguist-generated`：5 个 baseline 全部 `true`；新行无碰撞（`docs/perf-baseline.json.bak`/其他目录 unspecified）；`docs/perf-baseline.json` 的 `text: set / eol: lf` 正确；`git ls-files --eol` = 1268 `i/lf` + 3 `i/-text`（3 二进制），无 CRLF 债务。
- 基线收紧审计（origin/main → HEAD，逐 key）：cleanup `try_optional 261→257` 收紧、新增 4 个零容忍指标实测 0/0/0/7、其余 4 项持平；design `font.callout 86→0`、`spacing.literalSpacing 89→86`、`empty.contentUnavailable 28→6`、`theme.legacyAlias 15→1` 收紧，`font.systemSize/literalPadding/groupBox/radius` 持平；**无任何指标被放宽**。perf baseline 为本 range 新增（9 指标），当前实测逐项相等；protocol/module 基线未变（漂移问题见 R2T-09）。
- `9be6a000` 对 cleanup baseline 的改动只有 `generated_at`（metrics 无变化，因为 6e940350 后实测仍与 5ea5c38f 的 257 相等）；design 基线 `empty.contentUnavailable 10→6` 与实测 6 精确相等，8 指标全部 `ok` 无 `improved` 余量。
- design-system 旧正则 5 命中 vs 新 `\b` 正则 1 命中（多出的 4 个正是 `GatherTheme.primaryText` 误报：SessionControlView+Stages/Sync、PersonsView ×2），baseline=1 与 current=1，第一轮修复结论可复现。

### 2.8 CI workflow
- PyYAML 可解析（`on:` 在 YAML 1.1 下键为 `True`，与第一轮相同，属解析器口径而非语法错误）；无 tab/不可见字符；新增 3 个 step 均加在 `gates` job 末尾，`needs`/依赖图未改。
- 结构核对：`gates` 15 个 gate run + `boundary` 1 个 = 16；`gather-core`/`gather-app` 各 1 个 `check-warnings.sh` = 17 = gate 集合；新增 step 顺序与 docs/DEVELOPMENT 清单顺序一致；gates job timeout 10 分钟，本地整套门禁合计约 30s，余量充足。
- CI 明确引用 `report-baseline` 0 次、`check-appintents` 0 次（与“非门禁/自检”口径一致）。

### 2.9 其它脚本面（本轮 diff 逐文件重看）
- `check-cleanup-ratchet.sh`：新增 4 指标实测生效——注入 `try!` → `try_bang 1/0 FAIL (+1)`；注入 `nonisolated(unsafe)` → `8/7 FAIL (+1)`；`--write-baseline` 遇增长 `涨：try_bang 0 -> 1` 后 REFUSED（rc=1，符合“只许收紧”）；baseline 在 scratch 未被写脏。模式健壮性残余见 R2T-11。
- `check-coded-errors.sh`（仅补 EOF 换行）、`check-domain-writes.sh`（补 heredoc `PY` 终止符）、`check-preview-surface.sh`（单元素 for→if，同一文件/同一 FAIL 文案）——三者 diff 均为纯清洁/等价重构，整套门禁 green 佐证无行为变化。
- `check-test-catalog.sh` SC2064 trap 修复：`SELFTEST_TMP` 升为脚本级 + 单引号延迟展开，`--self-test` rc=0 且临时目录被清理（本轮实跑验证）。
- `scripts/report-baseline.sh`：非门禁、不进 CI、只读（无文件写入路径）、输出确定性（连续两次 110 行逐字节一致）；测试计数 3267/419/14958、perf 9 项、schema DDL 55/86/81 与各门禁一致。头部断言问题见 R2T-13。
- `scripts/test.sh` 的 `read -r -a FLAGS`：单行/空/unset 语义与旧写法等价（第一轮已实测），仅换行分隔差异（R2T-14）。
- `check-design-system.py`、`check-protocol-surface.sh` 的 `\b` 与模块 ratchet 均按第一轮描述生效（见 §2.7/2.6）。

## 3. Coverage & Limitations

- **无 macOS/Xcode**：未编译、未类型检查、未跑 `swift test`/`check-warnings.sh`/AppIntents 自检、未验证 CI macOS runner 行为；Swift 相关只做 `swiftc -parse` 语法探针（R2T-11）。
- **CI 无 actionlint**：只用 PyYAML 解析 + 手写结构断言；未验证 GitHub Actions schema、表达式语义、`if:` 求值、runner 预装清单（shellcheck 版本未 pin 的 R4-F26 风险仍在）。R2T-01 的 `if: false`/`continue-on-error` 绕过是**静态**证明，未在真实 Actions 上执行。
- **假 git stub 边界**：只模拟 `rev-parse`/`ls-files -z [pathspec]`，不覆盖 CI 的 sparse/depth/权限差异；不改 tracked 文件、不 git commit/checkout/reset；所有注入在 `.gather/r2tooling/work` + `/tmp` 内完成并已复原。
- **时间快照**：门禁实跑期间真实工作树出现他人并发未提交改动（DateFormatting.swift 1 行参数标签），实测计数不受影响；修复提交本身的工作树在开评时为 clean。
- **未穷举**：未对 94 个 md 的所有链接做语义核对（依赖 [c] 机制）；未对 docs 的措辞/数字逐一重算（数字部分由 docs-facts + report-baseline 交叉）；未重新证明所有第一轮 shellcheck 修复的行为等价（protocol-surface 已逐字节对拍；其余按 diff 等价性 + 门禁 green 判断）。
- **第一轮 F4/F5/F18/F20/F23/F10/F9/F25 等残余**：本轮复核到 F9/F18/F20/F10/F23 仍未修（见 findings），F4/F5（hygiene [c] HTML 注释/reference link、[g] 插值 CJK/verbatim）与 F25（actionlint）未重新探针（非本轮 fix 面，第一轮结论仍按“未修”计）。
- 本评审**未修改任何 tracked 文件**；只写本文件。

## 4. 给 lead 的处置建议（按性价比排序）

1. **P2 必修（低成本）**：R2T-02 把 gate-list 限定为“门禁节内、行首 `./scripts/` 的 fenced code block 行”；R2T-01 至少禁止“注释行/同 step `continue-on-error`/`if: false`/`||` 吞错”并把 README 声明的 `--strict` 与 CI 实参对齐（或做机读 registry）。这两项决定 17 道门禁能否真正被 CI 执行，是门禁体系可信度的根。
2. **P3 顺手修**：R2T-03 断言基线钉 14958（单行）；R2T-05/R2T-07 注释同步；R2T-06 加 BOM 检查；R2T-08 加 `.gitignore`；R2T-09 修 00-overview 的“protocol 基线已更新”与文档漂移字段（或纳入比较）；R2T-12 改 hash；R2T-13 改头部措辞；R2T-10/R2T-11 统一缺 key/空白正则（P3，可下一轮 gate-smith）。
3. **文档面交给 docs-steward**：R2T-09 的 00-overview §2 #18、R2T-12 的 `33ef7313`；另外 docs/reviews/README 索引需补本轮目录（目标文件 tracked 后才过 hygiene [c]）。

## 5. 复现入口（scratch，gitignored）

    # 独立副本 + 假 git stub（本 review 全部探针的基础）
    mkdir -p .gather/r2tooling/{base,bin}; git archive HEAD | tar -x -C .gather/r2tooling/base
    git ls-files -z > .gather/r2tooling/tracked.z
    # fake git: rev-parse --show-toplevel -> $PWD ; ls-files -z [pathspec] -> tracked.z 过滤（源码见 .gather/r2tooling/bin/git）
    cp -a .gather/r2tooling/base .gather/r2tooling/work
    export PATH="$PWD/.gather/r2tooling/bin:$PWD/.gather:$PATH" STUB_TRACKED="$PWD/.gather/r2tooling/tracked.z"
    # 例：docs-facts 绕过（注释 CI 步骤 / 节内正文提及）
    cd .gather/r2tooling/work && ./scripts/check-docs-facts.sh      # baseline rc=0
    # 其它关键探针（本轮内联执行，逐条结果见 §1/§2）：
    #   - hygiene: 在 work 内注入 CRLF/行尾空白/丢末行换行/BOM 到 .plist/.entitlements/.modulemap/SHA256SUMS/LICENSE
    #   - test-catalog: 注释 4/5 条 #expect、删 1 个 @Test/@Suite
    #   - protocol: 旧版 = git show 5ea5c38f:scripts/check-protocol-surface.sh；单引号/空格文件名；截断到 50/51/20 文件
    #   - perf/cleanup/protocol --write-baseline 缺 key / 增长拒绝；@unchecked 双空格
    # 真实树只读复核：./scripts/check-*.sh（16 道）+ git check-attr / git ls-files --eol / report-baseline.sh

## 6. 评审期间并发工作树改动（非本评审修改，仅记录）

评审后段（约 03:3x–03:4x UTC）工作树出现另一 agent 的未提交改动（15 个 tracked 文件，`git diff | sha256sum` 在 3s 窗口内稳定；本评审未触碰）。其中落在本 scope 的 3 个脚本与我的 findings 高度相关：

- `scripts/check-docs-facts.sh`：gate-list 改为先收集「门禁小节内的 `./scripts/` 行首清单项」（跳过 `#` 注释行、允许 `- ` 前缀）再比对；CI wiring 改为先剔除**整行注释**再子串匹配。——**方向上修掉了 R2T-02**（节内正文/注释提及不再算清单）；但 **R2T-01 的绕过面仍在**：`if: false`、`continue-on-error: true`、`run: … || true`、以及从 CI 去掉 `--strict` 都不会被剔除逻辑发现（整行注释过滤只覆盖 B2/B9 两类）。
- `scripts/check-repo-hygiene.sh`：`TEXT_FILENAMES` 加 `.gitignore`、新增 UTF-8 BOM 检查（`data.startswith(b'\xef\xbb\xbf')`）。——对应 **R2T-06/R2T-08**；在该 in-flight 树实测 `[b] ok 1268 个文本文件全部符合`（1266+2 .gitignore）。
- `scripts/check-test-catalog.sh`：`BASELINE_ASSERT` 14954→14958，注释“+4 重钉到实测”。——对应 **R2T-03**；但同一批 in-flight 改动还改了 `Tests/.../JSONValueCodingTests.swift`（+9 行），实测断言变成 **14959**，即若按现状提交，baseline 又差 1 条（需在最终提交前重测/再钉）。
- 其余 in-flight 改动（Swift 源码 4 个 + JSONValueCodingTests + 5 个 docs/归档）不在本 scope，未评审。

**结论**：这些未提交改动若被 lead 采用，需要重新在**提交后的最终树**上跑全部门禁并复核上述三点。当前 in-flight 树上 `check-docs-facts / check-repo-hygiene / check-test-catalog` 实测 rc 均 0，但不构成对最终提交的验证（文件随时可能继续变化）。

*验证上限声明：以上“OK”均指 Linux 静态/门禁/语法级验证；不构成 macOS 编译、测试、CI runner 或真机行为证明。*
