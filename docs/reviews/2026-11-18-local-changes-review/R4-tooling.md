# R4 独立评审：脚本 / 门禁 / CI / 文档与基线（tooling 面）

- **评审人/任务**：review-tooling（task-29：scripts/gates/CI/docs/baselines 正确性+完整性）
- **被评对象**：本地分支 HEAD `5ea5c38f`（origin/main = `e5c54f37`，16 个提交；`git diff --shortstat origin/main...HEAD` = 220 files, +9243/-949），重点是 2026-11-17/18 四轮自驱优化中新增/修改的 15 个 `scripts/**`、`.github/workflows/ci.yml`、`.gitattributes`、4 个 ratchet baseline（cleanup/design/perf/protocol）、以及 README/docs/ROADMAP/DEVELOPMENT/评审归档中的数字与门禁声明。
- **环境与验证上限**：Linux Ubuntu 22.04，**无 macOS/Xcode**，未运行 `swift build` / `swift test` / 真机 UI。可执行面 = 仓库自带 16 道 Linux 门禁（17 道中 `check-warnings.sh` 需 macOS SDK）、shellcheck 0.10.0（`.gather/shellcheck`）、Python3、只读 `git`、Python sqlite3。所有负向探针在 `.gather/` 下的独立副本（`git archive` + 假 `git` stub）里做，**未改动被评审文件**。
- **评审时点**：2026-11-18 02:2x–02:5x UTC；工作树仅 `docs/reviews/2026-11-18-local-changes-review/`（本轮评审文档）未跟踪。
- **结论摘要**：**未发现 P0/P1**（无编译破坏、无数据丢失、无安全面、无已证实的行为回归）。16/17 道 Linux 可跑门禁在最终树全绿（含 5 个 `--strict`）。共 **26 条发现：P2 × 6、P3 × 20**，集中在「门禁有漏检/可被绕过但 fail-closed」「ratchet 基线未收紧到实测值」「文档数字与最终提交不同步」三类；对最终树的**数字本身**（targets/API/schema/l10n/门禁数/perf 9 指标/测试声明）逐项复核一致。

## 1. Findings

| ID | 级别 | 位置（file:line / commit） | 问题 | 证据 | 建议修复 | 置信度 | macOS 不可验？ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | P2 | scripts/check-docs-facts.sh:365-382 | `[gate-list]` 只检查 `./scripts/<name>` 是否在 docs/DEVELOPMENT.md **全文任意位置**出现；把脚本从「## 门禁」清单删掉、只在文末留一句「旧注：…曾在清单中」仍 PASS | 探针 D3：删除清单行 + 文末追加旧注 → rc=0、无 FAIL（门禁清单完整性被正文提及绕过） | 解析 `## 门禁` 之后代码块内的行（行首 `./scripts/`），只在该集合内比对 `gate_scripts`；或把清单改成机读 JSON/表并校验行数 | 高 | 否 |
| F2 | P2 | scripts/check-docs-facts.sh（对照 .github/workflows/ci.yml） | 文档事实门禁不校验「门禁是否真接入 CI」：把 ci.yml 的 `Repo hygiene` step 删掉后 docs-facts 仍 rc=0；「17 道门禁」声明与 CI wiring 可脱节 | 探针 D5：scratch 副本删除 `- name: Repo hygiene` 两步 → docs-facts RC=0 | 从 ci.yml 提取 `run: ./scripts/*.sh` 集合，断言 = gate 集合 ∪ 边界 job/警告 job 的口径，并与 docs 声明交叉；缺脚本/缺 step 都 FAIL | 高 | 部分（CI 实际执行） |
| F3 | P2 | scripts/check-repo-hygiene.sh:180-182（TEXT_EXT） | `[b]` 只查硬编码扩展子集（swift/md/sh/py/json/yml/yaml/strings/txt + editorconfig/gitattributes），窄于 `.editorconfig` 的 `[*]`（indent/eol/charset/trim/final-newline 对**所有**文件生效）：`.plist`×2、`.entitlements`、`.modulemap`、`.h`、`.c`、`.tsv`、`Makefile`、`LICENSE`、`SHA256SUMS` 完全不在检查面 | `git ls-files` 扩展统计（实测这些类型均 tracked）；探针：CRLF 写进 docs/README.md 被抓，同类违规写进 .plist/.tsv 不会被抓 | 由 .editorconfig 的 `[*]`/`[*.ext]` 派生文件集（或对 tracked 且 UTF-8 可解码文件全量查 CR/行尾空白/末行换行）；至少补 .plist/.entitlements/.modulemap/.h/.c/.tsv/.pbxproj/.xcconfig | 高 | 否 |
| F4 | P2 | scripts/check-repo-hygiene.sh:259-276, 292-307 | `[c]` 只认行内 `[x](path)` 形态且不做 HTML 注释剥离：① `<!-- [x](missing.md) -->` 会被当作真链接**误报**；② reference-style `[x][r]` + `[r]: path` 完全不检查（漏检）；③ 带 title 的 `[x](p "t")` 正则不匹配 → 静默漏检 | 探针 C1：HTML 注释链接 → FAIL（误报）；reference 定义 + 引用缺失目标 → PASS（漏检）；带 title 链接未计入链接数 | strip HTML 注释后解析；补 reference 定义（`^\s*\[r\]:\s*(\S+)`）与引用使用；LINK 正则可选匹配 title 并对未解析形态计数（防静默跳过） | 高 | 否 |
| F5 | P2 | scripts/check-repo-hygiene.sh:638-692（skip_interpolation） | `[g]` 词法器把字符串插值内容整体丢弃：`Text("\(flag ? "嵌套中文" : "") ")` 这种插值内嵌 CJK 字面量**不报**（漏检，且 Swift 6 允许嵌套引号）；同时 `Text(verbatim: "中文")` 会被报（对「故意逐字显示」的误报，当前仓库无此用法） | 探针 G7（插值嵌套）rc=0 漏检；G8（Text(verbatim:)）rc=1 误报；G1/G2/G3/G5/G6/G9 行为符合预期 | 递归 tokenize 插值表达式（`skip_interpolation` 内继续产出 token，而不是直接跳过）；verbatim 如属产品允许，加入豁免并在注释写明 | 高 | 否 |
| F6 | P2 | scripts/check-test-catalog.sh:370-371,484（constants） | 反删用例 ratchet 基线远旧于实测：`@Test 3267/2502`、`@Suite 419/283`、断言 `14954/11509` → 最多可静默删 ~765 条 @Test / ~3445 条断言才触发 FAIL；与脚本自述「下限按实测值钉死」（:339）和 round-2/4 台账「基线已收紧」的说法不一致 | 实测 `./scripts/check-test-catalog.sh --strict` 输出上述比值；`report-baseline` 同数；基线常量自 2026-10-31 后未再更新（git 历史） | 收尾把三个常量重钉到当前实测（并在 docs/reviews 记账），或让 gate 在 current>baseline 时打印「可收紧」提示（与 perf ratchet 一致） | 高 | 否 |
| F7 | P3 | scripts/design-system-baseline.json + scripts/check-design-system.py:38 | 基线留 4 处余量：`empty.contentUnavailable` current 6 / baseline 10（收尾未跑 `--update`）；另 `theme.legacyAlias` 的唯一命中是**注释**（GatherGlass.swift:21 的 doc 注释），真实代码 0 —— 指标「含注释计数」是有意设计，但基线/文档未说明 | `./scripts/check-design-system.sh` 输出 `improved (-4)`；grep 定位唯一 legacyAlias 命中为注释行 | 收尾 `--update` 收紧到 6（依赖注释口径的 1 需在 baseline note 说明），或把注释从计数中排除并显式记录口径变更 | 高 | 否 |
| F8 | P3 | docs/cleanup-baseline.json:8（try_optional） | `try_optional` baseline 257 / current 256（round-4 已下降，未收紧）；ratchet 只降不升 → 1 处松弛 | `./scripts/check-cleanup-ratchet.sh` 输出 `try_optional 256 257 ok (improved 1; 可收紧 baseline)` | 收尾 `--write-baseline` 收紧（其余 8 指标已精确相等） | 高 | 否 |
| F9 | P3 | docs/protocol-surface-baseline.json:3-4 + scripts/check-protocol-surface.sh:229-232 | 基线里的 `protocol_files`/`protocol_lines` 会写入但**从不参与比较**，且已漂移：baseline 111 文件/17177 行 vs 最终树实测 111 文件/17192 行（+15 行） | `--strict` 输出 `Protocol 文件/行 111 / 17192`；compare_metric 只比 public_types/public_declarations/zero_reference/router_envelope | 把两字段纳入 compare_metric（行数只警告不失败也行），或从基线删除并在 note 标注为信息字段，避免「基线即事实」误读 | 高 | 否 |
| F10 | P3 | scripts/report-baseline.sh:417-469 + 脚本头 :17-18 | ① 性能段是 `check-perf-ratchet.sh` 9 指标的**第二份实现**（Python `\s` + `lstrip` 对比 grep `[[:space:]]`），当前实测一致但长期会漂移；② 头部宣称 schema「与 DDL 字面量实测计数交叉核对」，但代码只实测 tables/indexes/FKs，**列数（451）从未实测** | 注入 probe 文件后 report 与 gate 的 9 项增量逐项一致（parity 已验证）；report 输出只有「DDL 实测: tables/indexes/foreign keys」无 columns | 给 gate 加 `--json`，让 report 消费同一份计算（单一实现）；或至少加「两脚本结果相等」自检；头部注释改为「列数取自 expected* 常量」 | 高 | 否 |
| F11 | P3 | .gitattributes:51-55 | 4 个生成型 ratchet baseline 都标了 `linguist-generated=true`，但本轮新增的 `docs/perf-baseline.json` **没标** → GitHub diff 展开、语言统计把 JSON 计入，与同目录约定不一致 | 清单逐行对比；`git check-attr` 对 perf-baseline 无 linguist 属性 | 追加 `docs/perf-baseline.json linguist-generated=true` | 高 | 否 |
| F12 | P3 | docs/reviews/2026-11-18-round4-perf/gates-round4.md:§4/§5 | 该文仍写「report-baseline 当前硬编码 7 项…作为 follow-up 给 lead」「现有 7 项 current/baseline」，但**同一提交 5ea5c38f** 已由 lead 在 report-baseline 补上 2 条 chain 指标（9 项），00-overview §2.3 也写明已修 → 归档文档自相矛盾/过期 | `git show 5ea5c38f -- scripts/report-baseline.sh` 显示新增 raw_json_encode_chain/raw_json_decode_chain；实测 report 输出 9 行 | 更新 §4/§5（注明「已由 lead 在 5ea5c38f 补齐，本节为过程快照」） | 高 | 否 |
| F13 | P3 | docs/README.md:43 | 「当前基线（2026-11-17 **第二轮**加固后采样）」但块内是第三/四轮数值：门禁数 17 是 round-3 才达到（commit 级实测：57469cfd=15、42a89e01=16、2521c00b=17），同块还含 @Test 3267 等 round-2 数；采样日期与内容矛盾 | 逐 commit 计算 check-*.sh 数；docs/README 当前文本 | 采样标注改为「2026-11-18 round-4 收尾」并给每项（若有差异）标轮次；或允许 docs-facts 校验采样日期字符串 | 高 | 否 |
| F14 | P3 | docs/ROADMAP.md:3 | 「2026-11-18（第二、三、四轮加固后）校准」——本分支实际有**四**轮（round-1 = 2026-11-17 quality-hardening 也改了 README/docs 基线） | 16 个 commit 的 round 分组 + round-1 文档（quality-hardening/00-overview.md:74） | 改为「四轮加固后（round-1..4）」 | 高 | 否 |
| F15 | P3 | docs/cleanup-backlog.md（本轮未改） | 新增零容忍指标（try_bang / as_bang / fatal_error / nonisolated_unsafe=7）只在 round 文档记账；docs/README 定义为「清理台账（门禁输入）」的 cleanup-backlog 仍是旧指标行（CL-18 等），与 docs/cleanup-baseline.json 的 9 指标不同步 | grep 该文档 + 现 baseline 9 指标 | 在「摘要/CL-18」处补一行「ratchet 指标以此 JSON 的 9 项为准」并列出新指标 | 中 | 否 |
| F16 | P3 | scripts/check-repo-hygiene.sh:341-367 | `[d]` 占位符比较用整串身份（Counter）：`%1$d` vs `%d`（同一参数的等价写法）会报「占位符不一致」；当前 en 表无 `%n$` 用法（grep = 0），属潜在误报 | 注入探针 D7 → FAIL；`grep -cE '%[0-9]+\$'` en.strings = 0 | 比较前把 `%([0-9]+)\$` 归一化（或只比较转换符多重集 + 位置映射） | 高 | 否 |
| F17 | P3 | scripts/check-repo-hygiene.sh:403-423 | `[d]` 解析器遇到非引号残留（如裸 token）走 `assert` → AssertionError traceback，而非结构化错误（fail-closed，但报错不可读） | 注入 `garbage_token 123` → rc=1 + Traceback/AssertionError | `read_quoted` 前先判断首字符，抛 ValueError（「期望 key 的引号，实际 …」），与既有「缺 =」消息一致 | 高 | 否 |
| F18 | P3 | scripts/check-repo-hygiene.sh:204-219 | `[b]` 只判 UTF-8 可解码，不查 UTF-8 BOM；`.editorconfig` 的 `charset=utf-8` 语义是无 BOM，BOM 文件可通过门禁 | 探针：docs/README.md 前加 BOM → rc=0 | `data.startswith(codecs.BOM_UTF8)` 时 FAIL（提示 charset=utf-8 不含 BOM） | 高 | 否 |
| F19 | P3 | scripts/check-docs-facts.sh:292-298 | schema 常量正则强制显式 `: Int` 类型标注；改成 `expectedTableCount = 55` 后报「缺少 expectedTableCount 常量」（fail-closed 但脆且误导） | 探针 D6：改类型标注 → FAIL「缺少常量」 | 正则改 `expected<Name>(?:\s*:\s*Int)?\s*=\s*(\d+)`；错误消息区分「常量缺失」与「写法不支持」 | 高 | 否 |
| F20 | P3 | scripts/check-perf-ratchet.sh:159-169 | `--write-baseline` 反膨胀守卫对「baseline 缺 key」直接 `continue`：新增指标在旧 baseline 缺 key 时会被静默写入（正常校验模式会 FAIL 缺 key，但写入路径不拦） | 代码路径 + 缺 key 探针（校验模式 FAIL 已验） | 缺 key 时同样拒绝写入（要求先补 key 或显式 --allow-growth） | 高 | 否 |
| F21 | P3 | scripts/check-perf-ratchet.sh:104-112 | 源码行匹配的已知漏检：`JSONEncoder( )`（括号内空白）、`JSONEncoder.init()` 不计；行尾注释命中计入（与 cleanup ratchet 同口径，header 已声明） | 注入探针 P1：date+3/iso+1/encoder+1/chain+1…，其中 `JSONEncoder( )` 未计入；词边界正确（myDateFormatter/SomeJSONEncoder 不计、ISO 不双计） | 保持并文档化；若要更严可加 `JSONEncoder\(\s*\)` 模式（可能引入误报，需评估） | 高 | 否 |
| F22 | P3 | scripts/check-protocol-surface.sh:73-83（本轮 diff） | xargs 改写的新失败模式：路径含**单引号**时 xargs 报 `unmatched single quote`，`set -euo pipefail` 下脚本 rc=1 但 stdout 为空、丢失 ratchet diff（旧 `$(cat)` 写法反而能正确计数并 FAIL 515>514）；且本脚本**没有扫描量下限守卫**（空目录时各指标 0 只 warn，--strict 会绿） | scratch 探针：新增 `O'BrienProbe.swift` → 新脚本 rc=1/仅 stderr xargs 错；旧脚本 rc=1 且输出 `public_types = 515 > baseline 514` | 改 `while IFS= read -r f; do cat "$f"; done`（与 :71 行同写法，无双引号解析问题）或 `find -print0 + xargs -0`；补 proto_file_n / public_types 下限守卫（防静默 0 命中） | 高 | 否 |
| F23 | P3 | scripts/test.sh:34 + standards.md §1.2 等价表 | `read -r -a FLAGS` 读入写法与旧的不加引号展开在「变量含换行」时不同（旧：2 个 flag；新：只取首行 1 个）；单行正常用法无影响，但等价表未覆盖该 case | bash 实测：`--a\n--b` → old=2 / new=1；空值/unset/多 flag/glob 均验证一致 | 在 standards.md 等价表补「不含换行」前提（或 read -d '' 整串拆；不必要） | 高 | 否 |
| F24 | P3 | docs/reviews/README.md（索引） | 当前评审轮目录 `2026-11-18-local-changes-review/` 尚未入索引；收尾补链接时目标必须已 `git tracked`，否则 hygiene [c]（tracked 链接目标）会 FAIL | `ls docs/reviews/*/` 与索引表格对比：仅当前轮目录 UNLINKED | lead/docs-steward 收尾加一行（并在文件 tracked 后跑 hygiene [c]） | 高 | 否 |
| F25 | P3 | .github/workflows/ci.yml（验证方式） | 本机无 actionlint；PyYAML（YAML 1.1）把顶层 `on:` 解析成布尔 True（`safe_load()['on']` 为 None）→ 仓库/评审文档里「PyYAML 解析 OK」只能证明可解析，不能证明 GH Actions schema 正确 | 实测 safe_load keys 含 True；结构断言（jobs/steps/needs/runs-on）另行手写校验通过 | CI/评审用 actionlint（或 ruamel yaml 1.2 + 结构断言）；至少把「actionlint 未跑」写进评审限制 | 高 | 部分 |
| F26 | P3 | scripts/check-repo-hygiene.sh:536-574（[f]） | shellcheck 版本未 pin（本地 0.10.0；CI ubuntu-latest 镜像自带，standards.md 自述「未 pin」）→ 镜像升级新增 warning 会让门禁在无代码改动时变红 | standards.md §验证上限；本地 0.10.0 实跑 0 finding | 固定 shellcheck 版本（下载 release binary 并校验）或 pin runner 镜像；失败消息已打印版本，可接受但需知风险 | 高 | 部分（CI 镜像） |

> 备注：F7–F26 中与「基线/文档」相关的项都不是本轮 diff 引入的**行为回归**，而是「ratchet 承诺未落地/文档与最终提交不同步」的完整性问题；真正影响门禁可信度的优先级最高的是 F1/F2/F4/F6。

## 2. Verified OK（独立复核通过）

### 2.1 门禁套件（最终树 @ 5ea5c38f，Linux 可跑 16/17 全绿）

- 逐脚本实跑：`check-backlog-evidence / cleanup-ratchet / coded-errors / design-system / docs-facts / domain-events / domain-writes / duplicate-symbols(--strict) / layering / no-legacy / perf-ratchet / preview-surface(--strict) / protocol-surface(--strict) / repo-hygiene / select-star(--strict) / test-catalog(--strict)` 全部 rc=0；`git diff --check` 干净。
- `check-repo-hygiene` 7 节全 PASS：bash -n 26 个 .sh（stderr 全空）/ py_compile 4 个 scripts/**/*.py / shebang 执行位 31 个 / .sh 无 CR；[b] 1250 个文本文件；[c] 88 md / 200 链接全部 tracked；[d] en 2682 key / zh 9 key，0 重复/0 空值/0 CJK/0 占位符不一致（832 token）；[e] scripts/ 35 tracked 文件 0 缓存产物；[f] shellcheck 0.10.0 26 个 tracked *.sh 0 finding；[g] 272 文件 / 2264 处 UI 调用 / CJK 1718 全部已包裹。
- `docs-facts`：targets 18（core 13 / app 5，functional 9）、域 API 16 协议/195 方法、schema 55/451/86/81、l10n en 2682/zh 9、门禁脚本 17；README/docs/README/DEVELOPMENT 断言全部匹配。
- `perf-ratchet`：9 指标全部等于 baseline（28/30/45/38/20/22/3/1/0，Sources 750 文件）；`cleanup-ratchet` 9 指标不超 baseline；`design-system` PASS；`select-star` 4/4；`protocol-surface --strict` 4 个受控指标 + 5 个模块指标全部 ok。

### 2.2 check-repo-hygiene 的 fail-closed 行为（scratch 副本注入缺陷，全部按预期红）

| 注入 | 结果 |
| --- | --- |
| scripts/*.sh 末尾未闭合 heredoc | [a] FAIL「bash -n stderr 非空」；blanket shellcheck 亦报 SC1044/SC1072 |
| .sh 混入 CR | [a] FAIL「.sh 含 CR」；[b] 亦 FAIL「has CR」 |
| 去掉 shebang 文件执行位 | [a] FAIL「shebang 文件缺执行位」 |
| scripts/*.py 语法错误 | [a] FAIL py_compile |
| md 转 CRLF / 行尾空白 / 丢末行换行 | [b] 分别 FAIL（三态都被抓） |
| md 链接指向未 tracked 文件 | [c] FAIL「链接目标不是 tracked 文件」 |
| tracked 目标在工作树被删 | [c] FAIL「链接目标不在工作树」+ [a]/[b] read error（fail-closed） |
| en 表重复 key / 空 value / 含 CJK / 占位符不一致 / 结构错误 | [d] 逐项 FAIL 并给 file:line |
| scripts/__pycache__/*.pyc 进入 tracked 清单 | [e] FAIL；[a] 同时报「无法读取」（未暂存删除/缺文件也会被拦） |
| 注入 SC2045 级 finding | [f] FAIL 并打印 file:line:col，整脚本 rc=1 |
| 去掉 shellcheck 的 PATH | [f] 单独 FAIL + 安装提示、其余节照跑，整脚本 rc=1（fail-closed ✓） |
| `SHELLCHECK_OPTS='-e SC2045'` 环境变量 | 仍 FAIL（`unset SHELLCHECK_OPTS` 生效，「环境变量放宽门禁」不可行） |

### 2.3 check-repo-hygiene [g] 语义（注入 UI 样例）

- `Text("探针中文")` / `Button("按钮中文")` / `.help("探针中文提示")` → 逐条 FAIL 并给 `file:line [API] '原文'`；总数统计一致（1719/1718）。
- 包裹形态 PASS：`Text(l10n("…"))`、跨多行 `Text( + l10n( + "…")`。
- `#Preview { Text("预览中文") }` PASS（预览块跳过）；`PreviewSupport/` 目录下文件 PASS（目录排除）。
- 最终树 0 违规（1718 个 UI 调用内 CJK 全部包裹）。
- （漏检 F5 已单列：插值内嵌套字面量不查、`Text(verbatim:)` 误报 —— 均为已知面，不影响本轮 0 违规结论。）

### 2.4 check-docs-facts 负向探针

- 把 README 的 `16 typed domain APIs (195 methods)` 改成 194 → FAIL 并打印期望串 ✅（F1 的绕过仅限「正确串出现在全文任意位置」，见 F1）。
- scratch 新增 `scripts/check-probe-gate.sh` → FAIL 两项：docs/README 门禁数期望 18、DEVELOPMENT 清单缺 `./scripts/check-probe-gate.sh` ✅（计数动态、fail-closed）。
- 删 ci.yml 的 Repo hygiene step → 仍 PASS（= F2）。
- 冻结的 gate 计数口径 = `scripts/check-*.sh 18 个 − check-appintents.sh` = 17 ✅（与 README/docs/DEVELOPMENT 声明一致）。

### 2.5 check-perf-ratchet 边界与反通胀

- 词边界正确：`ISO8601DateFormatter()` 只计 raw_iso_formatter（不双计 date）；`myDateFormatter()`、`SomeJSONEncoder()`、`JSONEncoder.init()` 不计；`Foo.DateFormatter()` 计入；纯注释行（// 或 * 开头，含 tab 缩进）不计；行尾注释命中计入（header 已文档化）。
- 注入 13 行 probe：date+3、iso+1、encoder+1、decoder+1、encode_chain+1、decode_chain+1、regex+1、sleep+1，全部按预期；其中 `JSONEncoder( )` 未计（F21）。
- 反通胀：baseline `raw_date_formatter` 临时 −1 → `--write-baseline` 输出「涨：27 -> 28」并 REFUSED(rc=1)；加 `--allow-growth` 后写入成功；正常模式缺 key FAIL；连续两次运行 stdout 逐字节一致。

### 2.6 scripts/report-baseline.sh（非门禁）

- 连续两次输出逐字节一致（确定性）；rc=0。
- 性能段 9 项 current/baseline/status；把 baseline 改低后只打印 `FAIL (+1)` 而 **rc 仍 0**（非门禁语义正确）。
- 与 gate 的计数 parity：scratch 注入同一 probe 后 report 与 perf-ratchet 的 9 项增量逐项相同（date 29、iso 31、encoder 46、encode_chain 21 …）。
- 缺 git 时 rc=1 并报「缺少依赖 git」；测试声明计数与 check-test-catalog 完全一致（3267 @Test / 419 @Suite / 14954 断言）；schema DDL 交叉核对 tables 55 / indexes 86 / FKs 81 一致，user_version=1、fingerprint 打印。
- 头部「Protocol/targets/API/l10n/schema/门禁数/ratchet 基线」全部与实际一致（列数未实测见 F10）。

### 2.7 本轮 shellcheck 修复的「行为等价」（不止 shellcheck 静默）

- **check-protocol-surface**：在最终树上分别跑旧（origin/main）与新实现，`$TMP/decls` 逐字节相同（514 行）、public_declarations 3115/3115、public_types 514/514 → 正常路径行为等价；路径含单引号时的回退见 F22。
- **check-domain-writes heredoc 修复**：旧版 `bash -n` 报「here-document delimited by end-of-file」warning 但 rc=0；新版补 `PY` 终止符。新旧脚本对当前树输出逐字节相同（rc=0），仅旧版多一条 bash stderr warning → 纯修复、无行为变化。
- **check-test-catalog trap**：把 origin/main 版本拷进 scratch（同一测试根）与当前版各跑 `--self-test` → 两者都输出 `SELFTEST OK`、rc=0（推迟展开的脚本级变量写法行为等价，且 SC2064 消除）。
- **check-preview-surface**：单元素 for → if 的 diff 仅为同一文件/同一 FAIL 文案/fail=1，等价（无循环变量复用）。
- **scripts/test.sh FLAGS**：bash 实测空值/unset/`--a --b`/glob 用例新旧一致；空数组 `FLAGS[@]` 的 `+` 展开不产生空参数（不会给 swift test 传空串）；仅「变量含换行」差异见 F23。
- **check-design-system.py 正则 \b**：当前树旧正则计数 5 vs 新正则 1（多出的 4 处正是 `GatherTheme.primaryText` 误报），与代码注释「4 处误报」完全吻合；基线 theme.legacyAlias=1 与 gate current 相等。
- **check-perf-ratchet 新增 chain 指标**：`JSONEncoder().encode` 一行同时计入 raw_json_encoder 与 raw_json_encode_chain —— 刻意互补（文档 §6 已声明），非重复计数错误。

### 2.8 历史数字/文档声明（按 commit 独立重算验证）

- **round-1（quality-hardening）的「API 172→195、功能 target 8→9（总 16→18）、en 2,020→2,680、门禁 12/14→15」是文档校准而非代码变更**：origin/main（e5c54f37）源码实测已是 targets 18/functional 9、API 16/195、en 2680、gates 14（`check-*.sh 15 − appintents`）；而 origin/main 的 README/docs/README 文档仍写 172/8-16/2020/12 → round-1 文档把数字改到与代码一致，声明方向正确、数字可复算。
- **round-2 声明**「@Test 3,255→3,267、@Suite 417→419、断言 14,911→14,954、en 2,680→2,682、未包裹 7→0」：commit 级实测 57469cfd 与 9b1b8aeb 分别为 3255/417/14911 与 3267/419/14954；en 在 round-2 相关提交里 2680→2682；用当前 [g] 解析器回放历史树：e5c54f37/4cb3228d/d1180d62 均报 **7 处**裸 CJK 标点（`、` `：` `，` `（）`，文件/行号为本次回放实测（字符类型与 round-2 文档描述一致）），2b9bf100 起为 0 —— 「7→0」可复现（「门禁首次运行」措辞略宽松：gate 脚本在 42a89e01 才落地，但解析器能复现前态 7 处）。
- **round-3 基线**：`git show 2521c00b:docs/perf-baseline.json` = 7 指标 28/30/46/39/3/1/1；round-4 声明的收紧 46→45、39→38、blocking_sleep 1→0 与最终 baseline 28/30/45/38/20/22/3/1/0 一致；「Sources 750 个文件」「门禁 17」「gates job 15 个 run step」实测一致；round-4 「2521c00b 前三轮共 13 个提交」= `git rev-list --count origin/main..2521c00b` = 13 ✅。
- **standards.md（round-1 标准加固）**：在 origin/main 的 4 个脚本副本上复跑 `shellcheck -S warning` 得到 **恰好 5 findings / 4 文件**（SC2043/SC2046×2/SC2064/SC2206，与文档表格逐条同文件同行）✅；全仓仅 1 处 `shellcheck disable`（check-test-catalog.sh:32，且带理由）✅；Sources 真 `as!` 本体清零（唯一 grep 命中在解释性注释里，cleanup ratchet as_bang=0）✅。

### 2.9 CI workflow

- PyYAML 可解析；无 tab、无行尾空白；全 17 个门禁脚本都在 CI 中（boundary: check-no-legacy；gates: 15 个 step；gather-core/gather-app: check-warnings），无未知脚本引用；`check-appintents.sh` 不在 CI（自检，口径正确）。
- 依赖图无环：boundary→gates；gather-core→gather-app；gates+gather-app→release（release 另有 tag/dispatch if）；concurrency group 含 event_name，tag 推送不被同 ref 分支 push 取消；checkout/cache/upload-artifact 均 pin 到 commit SHA。
- 所有 run step 的命令行与 docs/DEVELOPMENT「门禁」清单一致（含 --strict 5 处）；`release` 的 SDK 断言/签名/公证/双架构校验逻辑静态复核未见明显漏洞（无法在本机执行）。

### 2.10 .gitattributes 与行尾状态

- `git check-attr` 抽检：.swift/.md/.sh/.py/.json/.yml/.strings/.plist/.pbxproj/.entitlements/.xcconfig/.modulemap/.editorconfig/.gitattributes → text=set, eol=lf；`*.mlmodel` / `*.bin` / `*.icns` → binary=set；`**/*.mlpackage/**` 命中包内所有文件（含 Manifest.json，会阻止文本 diff —— 对模型包可接受）。
- `git ls-files --eol`：**1262 个 i/lf + 3 个 i/-text（3 个二进制）**，无 CRLF/混合行尾 tracked 文件 → 引入 .gitattributes 后**无 renormalize 债务**（工作树与索引已是 LF）。
- 现有 tracked 类型均被显式规则或 `* text=auto eol=lf` 覆盖（无扩展名的 LICENSE/Makefile/SHA256SUMS 走 auto，正确）；后续新增二进制类型（mp4/mov/avif/xcframework 等）需补规则（同 F11 类风险，P3）。

### 2.11 其它

- `scripts/perf-sqlite-bench.py`（新，非门禁、不进 CI）：`--rows 500/2000 --repeats 3` rc=0，schema 实建 **55 表/86 索引/81 FK** 与 expected* 一致，`--compare` rc=0；DDL 抽取顺序与 SchemaCurrent.createSQL 拼接一致（源码注释对得上）；语法过 py_compile（[a]）。
- 文档数字与源码一致（逐项重算）：README `16 typed domain APIs (195 methods) / nine functional targets (18 total)`、docs/README `16/195、9 功能 target/18、55 表/451 列/86 索引/81 外键、en 2,682/zh-Hans 9、17 个 check-*.sh 门禁、@Test core 2,001/235 + app 1,266/184 = 3,267/419`；DEVELOPMENT §门禁 17 条命令、§性能 9 指标、§本地化 zh-Hans 9 占位键均与脚本/资源一致；ADR 的 schema 数字一致。
- docs/reviews/README.md 的 7 个轮次入口链接 + 4 个单篇台账链接全部解析到 tracked 文件（hygiene [c] 覆盖）；除当前进行中的本轮目录外无未索引目录（F24）。
- 本分支 16 个提交与 220 files/+9243/-949 的规模核对一致；`.gather/` 未污染仓库（gitignored，scripts/ 下无提交的 __pycache__ 等）。**注意**：仓库根目下 scripts/ 有 3 个文件在本地文件系统权限显示为 `-rwx--x--x`（check-docs-facts/check-perf-ratchet/perf-sqlite-bench），但 **git 索引均为 100755**（`git ls-files -s` 实测），CI checkout 不受影响。

## 3. Coverage & Limitations

- **无法验证（无 macOS/Xcode）**：Swift 编译/类型检查/并发检查、`swift test`、`check-warnings.sh`（本 scope 唯一未跑门禁）、release job 全链路（签名/公证/lipo/vtool/codesign/stapler）、CI runner 镜像行为（ubuntu-latest 是否预装足够新 shellcheck/python3、macos-26 镜像是否存在）、App Intents 自检、round-4 性能数字（mmap A/B、渲染帧耗时、探针结论）——这些只做了静态/文档一致性复核，**不构成运行时证明**。
- **CI 校验方式限制**：无 actionlint；只用 PyYAML（YAML 1.1）做解析 + 手写结构断言（jobs/needs/runs-on/steps/uses pin），未对 workflow schema、表达式语义、secrets 引用做官方校验（F25）。
- **负向探针的边界**：探针在 `git archive` 副本 + 假 git stub 上运行；stub 只模拟 `ls-files/rev-parse/status`，因此「CI checkout 的 sparse/depth/权限差异」类问题未被覆盖。未对全部 88 个 md 的每一个链接做人工语义核对（只依赖 [c] 机制 + 抽样）。
- **历史声明校验**：用独立 Python 重算（Package.swift 计数/协议 func 计数/.strings 解析/文本行匹配），并回放当前 [g] 解析器到历史树；未运行历史版本的脚本本身（除 standards.md 的 shellcheck 复现与 [g] 解析器回放）。
- **不在本评审面**：Swift/SwiftUI/DB 生产代码与性能数字（其他 reviewer 的分册）、docs 的措辞与产品决策、macOS 真机行为。

## 4. 给 lead 的收尾建议（可直接派给 docs-steward，均不影响本轮门禁绿）

1. 收紧/同步基线（低风险）：① `check-test-catalog.sh` 的 `BASELINE_TEST_DECL/SUITE/ASSERT` 重钉到 3267/419/14954；② `check-design-system.sh --update`（contentUnavailable 6）；③ `check-cleanup-ratchet.sh --write-baseline`（try_optional 256）；④ 决定 protocol_lines/protocol_files 是否纳入比较（F9）并在 docs/reviews 记账。
2. 文档同步：F12（gates-round4 §4/§5 加「已由 5ea5c38f 修复」注记）、F13（docs/README:43 采样日期）、F14（ROADMAP:3 轮次措辞）、F15（cleanup-backlog 补 9 指标指向）、F11（.gitattributes 补 perf-baseline 一行）、F24（docs/reviews/README 补本轮目录）。
3. 门禁可提升项（非本轮必须）：F1（docs-facts 只认清单块）、F2（CI wiring 断言）、F3/F4/F5（hygiene [b]/[c]/[g] 覆盖面）、F22（protocol-surface 用 while read+cat 替代 xargs、补扫描量下限）。建议作为下一轮 gate-smith 任务，附本文件探针复现命令。

---
*复现入口：门禁 = `./scripts/check-*.sh`（[f] 需 `PATH="$PWD/.gather:$PATH"`）；注入探针脚本保存在 gitignored 的 `.gather/review4/`（hygiene_probes.py / docs_facts_probes*.py / perf_probes.py / report_probes.py / hygiene_g.py / hist.py）与 `.gather/hygiene-probe/`（git archive 副本 + 假 git stub），可重放。*
