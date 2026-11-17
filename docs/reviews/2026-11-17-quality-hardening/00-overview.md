# 2026-11-17 全仓质量加固审计（整洁度 / 规范 / 测试 / 设计 / 性能）

- **日期**：2026-11-17（本地时区 CST/UTC+8）
- **基线**：`origin/main` @ `e5c54f37`（Wave5 batch9；本次先 `git fetch` 并从 `0d6b667` 快进 597 个提交）
- **执行**：lead + 8 个子代理（task-1…task-8，写作用域互斥，任务板可追溯）
- **环境与验证上限（重要）**：本轮在 **Linux / Ubuntu 22.04** 主机执行，**无 macOS/Xcode，未运行 `swift build` / `swift test` / 真机 UI**。Swift 侧验证到：SwiftPM manifest 解析、`GatherProtocol` 与 `GatherPreviewData` 两个可移植 target 的 Linux 类型检查、1086/1086 个 `.swift` 文件 `swiftc -parse`。行为等价性为源码级论证；运行时套件数字引用 2026-11-16 的 macOS 全量运行（[98-final-audit.md](../2026-11-11-competitive-gap-rereview/98-final-audit.md) §5）。
- **本文定位**：本轮改动的总览与验收索引；分领域证据见同目录 `perf-core.md`、`perf-ui.md`、`design-system.md`、`standards.md`。

## 1. 结论摘要

| 维度 | 结果 | 主要证据 |
| --- | --- | --- |
| 仓库整洁度 | 26 个文本文件清除行尾空白 / 补齐末行换行；新增 `check-repo-hygiene.sh` 六节门禁（脚本语法、editorconfig、Markdown 链接、本地化表、缓存产物、shellcheck）；1225 个文本文件 0 违规、170 个相对链接 0 断链 | 门禁实时输出；`git diff --check` |
| 代码规范 | `check-domain-writes.sh` 未闭合 heredoc 修复；shellcheck 5→0；Sources `as!` 1→0；清理 ratchet 5→9 指标并收紧 `try_optional` 261→260；`@unchecked Sendable` 60/60 未增长 | `standards.md`、`scripts/check-cleanup-ratchet.sh` |
| 测试文件 | 测试内 `try!` 3→0、`fatalError` 2→0、`preconditionFailure` 1→0、`try? #require` 4→0；断言 +2；catalog/ratchet 全绿；输出 flaky 清单（sleep/墙钟/非 hermetic）与后续建议 | `check-test-catalog.sh --strict`；本次 diff |
| 软件美观度/一致性 | 69 条英文文案按 HIG 打磨（0 个 key 变更）；7 个 icon-only 控件补 8 个 accessibilityLabel（残留真实缺口 0）；116 处设计令牌精确等价替换（43 文件），`font.callout` 84→0、`theme.legacyAlias` 15→5，设计 ratchet 基线收紧 | `design-system.md`、`check-design-system.sh` |
| 性能 | gather-core 7 组修复（10 文件）：JSON coder 逐行分配收口、日期解析共享化、O(n²)→O(n) 等；GatherUI 7 项修复（7 文件）：渲染路径 formatter/解析器缓存、检查器重复派生 hoist；另产出静态热点清单（FK 缺前导索引经第二轮复核为 1 个且无查询使用，详见 §7 更正；N+1 2 处、逐次正则编译 3 处） | `perf-core.md`、`perf-ui.md` |
| 文档 | README / docs 基线校准：API 172→195 方法、功能 target 8→9（总 16→18）、门禁 12/14→15、en 键 2,020→2,680、测试声明口径与最近 macOS 运行分列；新增 `scripts/report-baseline.sh` 只读事实报告，防止文档再次漂移 | 本次 diff；`report-baseline.sh` |

**门禁状态**：可 Linux 执行的 14 道门禁全绿（新增 `check-repo-hygiene.sh`，含 shellcheck）；第 15 道 `check-warnings.sh` 需要 macOS SDK，按 CI 口径待 macOS runner 复验。`check-repo-hygiene` 六节、`check-design-system`、`check-protocol-surface --strict`、`check-test-catalog --strict` 等均有本地实时输出。

## 2. 方法与分工

1. **先取远端真实基线**：`git fetch --all --prune` → `main` 落后 597 个提交 → `git pull --ff-only`（无冲突；未使用代理，fetch 正常）。
2. **只读侦察定靶**：先跑全部可 Linux 执行的既有门禁（当时 13/13 绿）与静态扫描（行尾空白、末行换行、断链、本地化占位符、print/try!/as!、测试反模式、formatter/coder 分配点），据此切分互不重叠的任务与写作用域。
3. **两轮并行子代理**（任务板 task-1…task-8，均 completed）：
   - 第一轮：`gate-smith`（门禁/CI）、`docs-steward`（文档校准）、`test-steward`（测试卫生）、`ui-copy`（文案/可访问性）、`perf-core`（core 性能）、`perf-ui`（UI 性能）。
   - 第二轮：`standards-hardening`（shellcheck/as!/ratchet）、`design-tokens`（设计令牌等价迁移）。
4. **lead 兜底与验收**：事务范围外的机械修复、冲突裁决（如 perf-ui 新增 `@unchecked Sendable` 触发 ratchet 后要求回炉折叠进既有锁盒子）、全量语法/类型/门禁复跑、提交与本文档。

## 3. 仓库整洁度

- **机械卫生**：26 个文件的行尾空白 / 文件末换行统一（含 2 处 CJK 注释行尾空白、2 处纯空白行、1 个 JSON fixture 与 1 个脚本），`git diff` 只含空白变化；修完后 1225 个 tracked 文本文件 0 违规。
- **新增仓库卫生门禁** `scripts/check-repo-hygiene.sh`（纯 Linux、只读、~`320ms`、6 节独立 PASS/FAIL，CI `gates` job 已接入）：
  - [a] 22 个 `.sh` 过 `bash -n` 且 stderr 必须为空（守住 heredoc 未闭合这类"能跑但已坏"的回归）、`py_compile`、shebang 执行位、无 CR；
  - [b] 1225 个文本文件的 LF / 无行尾空白 / 末行换行 / UTF-8；
  - [c] 72 个 Markdown / 170 个相对链接全部解析到 tracked 文件（跳过代码块与行内代码）；
  - [d] en/zh-Hans 本地化表：2680/9 条 key，0 重复 / 0 空值 / 0 CJK 泄漏 / 0 占位符多重集不一致；
  - [e] scripts 下无提交的缓存/构建产物；
  - [f] tracked `*.sh` 全量 shellcheck（warning 即失败；缺工具 fail-closed 并打印安装提示）。
- **门禁自身修复**：`check-domain-writes.sh` 第 44 行 `<<'PY'` 缺少闭合 `PY`（此前靠"剩余内容恰好全是 Python"才没坏，`bash -n` 持续告警）——已补闭合，仍有 57 个叶子写函数 / 49 已发域 / 0 缺口。
- **脚本规范**：`convert-face-model.py` 补 shebang 执行位；新增 `scripts/report-baseline.sh`（只读事实报告，非门禁）作为文档数字的唯一刷新入口。

## 4. 代码规范

- **shellcheck**：22 个 tracked shell 脚本从 **5 findings / 4 文件** 到 **0**（SC2043 直判、SC2046 xargs 逐行传清单、SC2064 临时目录提脚本级后延迟展开、SC2206 `read -r -a`），全部行为等价（详见 `standards.md` §1）。
- **强制转换清零**：Sources 唯一 `as!`（`ImageMetadataProviders.swift:170`）改为 CFTypeID 判型 + `unsafeDowncast`（等价前提显式化，未知 CF 类型走原 description 兜底）。
- **清理 ratchet 收紧**（`docs/cleanup-baseline.json`，9 个指标）：`try_optional` 261→260；新增 `try_bang`/`as_bang`/`fatal_error`（0 基线）与 `nonisolated_unsafe`（现有 7 处全部为"锁 + 静态表"既有纪律，只降不升）。
- **并发纪律回归拦截**：perf-ui 首版新增 `@unchecked Sendable` 类型使 ratchet 61>60 → 当场回炉把它折叠进既有 `DisplayDateFormatters` 锁盒子，最终 60/60；本轮净新增 `@unchecked Sendable` = 0、净新增 `nonisolated(unsafe)` = 0。
- **API 面不变**：`check-protocol-surface.sh --strict` 通过（public types 514 / declarations 3115 / protocol lines 17177 均未增长）；无公开 API 签名变更。

## 5. 测试文件

- **反模式清零**（7+ 文件）：`try! #require` → 抛出测试 + `try #require`；`fatalError` 位图夹具 → `try #require(...)`（坏环境失败用例而不是杀测试进程）；fixture 助手 `preconditionFailure` → 可抛 `MissingFixtureFileError`；`try? #require` + `?? 0` 静默降级 → `try #require`；`#expect((try? ...)) ` → `#expect(try ...)`。断言数 14911→14913（只增），`@Test 3255/2502`、`@Suite 417/283` 不变，`check-test-catalog.sh --strict` 绿。
- **flaky / 非 hermetic 盘点**（未改，写入建议）：`Thread.sleep` 6、`Task.sleep` 43（多数为取消容忍/轮询）、固定 `/tmp` 字面量 172（均为 fixture 路径，无真实写系统临时根）、墙钟上界断言 3 处（`ReadPoolTests`、`ExportPostCommandTests`）、固定等待落定 8 处（建议迁移到 app 侧异步 `waitUntilAsync`）。结论：默认套件无"墙上时钟相等"断言，非 hermetic 项多为有意的 oracle。
- **测试运行时基线**：最近 macOS 全量（2026-11-16）core 1,970 tests/290 suites + 串行 25/4、app 1,260/184；文档按"声明口径 / 最近 macOS 运行"分列，避免把 Linux 静态计数冒充运行时结果。

## 6. 软件美观度 / 设计一致性

- **英文文案**：69 条高可见条目按 macOS HIG 打磨（按钮/菜单/标签保持 Title Case，告警/状态/说明用 sentence case；展开 "C1"→"Capture One"；统一 "writeback/relink/recluster/reindex" 等术语；5 处弯引号；色标术语 "red color label"），**0 个 key 变更、占位符多重集逐条保持**，不触碰测试钉死的字符串（清单见 `design-system.md` 对应的 ui-copy 交付说明与 `.gather/ui-copy-report.md`）。
- **可访问性**：对全仓 124 个 `Image(systemName:)` 站点做语句级扫描，7 个纯图标控件补 `.accessibilityLabel`（均复用 en 表既有 key，0 新增翻译），残留真实缺口 0。
- **设计令牌等价迁移**（116 处 / 43 文件，值逐字符等价 ⇒ 零视觉变化）：`.font(.callout|.headline|.body|.title3|…)` → `GatherFont.*` 角色，`GatherTheme.contentBackground/secondaryContentBackground` → `surface/surfaceMuted`，精确等值 spacing → `GatherMetrics.Space.*`。指标：`font.callout` 84→0、`theme.legacyAlias` 15→5、`spacing.literalSpacing` 87→86；`scripts/design-system-baseline.json` 已收紧，后续新增裸 `.font(.callout)` 会直接 FAIL。`check-preview-surface --strict` 保持 #Preview=14 / 12 文件 / 2,210 行不变。
- **刻意不迁移**（避免"看起来统一、实际改视觉"）：`font.systemSize` 15 处（无精确角色）、非令牌 spacing 86 处（10/0/3/5/14…不等值）、`Radius.panel`（8 与 `media` 同值但语义不同）、`.font(.title2)` 裸调用（换角色会变字重）。

## 7. 性能

- **gather-core**（`perf-core.md`，7 组 / 10 文件）：`JSONValue` 编解码器共享实例（收口全仓 57 处调用与元数据缓存 4 coder/行）；TriageRepo/QualityService/RepositorySupport/PersonRepo/CullingHistoryRepo 逐行 coder hoist；NavigationService 日期解析共享 + 分组逐行预计算（每行少 2×3 formatter + 2×正则编译）；Sidecar 读取去掉冗余 stat；`applyRelativeRanks` O(n²)→O(n)。
- **GatherUI**（`perf-ui.md`，7 项 / 7 文件）：`DisplayDateFormatters` 增加 pattern/template/shortShort 缓存与 ISO 解析器（折叠进既有锁盒子）；C1 状态胶囊、元数据批次行、导出命名预览、WebDAV 发布历史、人物详情改为缓存；`CullingInspector` body 重复派生 hoist（500 张页每次渲染少 ~2 次全页 filter/扫描）。
- **静态热点（只报告，未改）**：SQLite 55 表/86 索引/81 FK 的 FK 子列索引结论已由第二轮更正（查询计划审计见 `../2026-11-17-round2-hardening/perf-core-round2.md` §5.1，schema 未变）：**计入 SQLite PK/UNIQUE 自动索引后，真正缺前导索引的 FK 子列只有 1 个** —— `session_assets.display_file_id` → `asset_files`，且源码中没有任何按 `display_file_id` 过滤的查询（只在 INSERT/UPDATE 写入），当前无实际性能影响；若只计显式 `CREATE INDEX`、忽略 `sqlite_autoindex` 则为 19 个，但自动索引同样是可用 BTREE，不应算缺失（两种口径都复现不出「10」）。改 schema 需 fingerprint/计数联动与 macOS 复验，建议随下一次 schema bump 处理；N+1 2 处（`CullingService+Commands` 逐照片 `getDecision`、`LibraryPackageService` 逐 binding `personsRepo.get`）；逐次 `NSRegularExpression` 编译 3 处（sidecar IPTC 读侧、`NavigationService.filenameSequence`）。
- **收益表述纪律**：所有"消除 N 次分配"均为按代码路径推导的构造次数，不是实测耗时；运行时收益需 macOS Instruments 复测。

## 8. 文档与基线校准

- README（EN）/docs/README（ZH）事实对齐：16 域 API / **195** 方法；**9** 个功能 target（含测试/工具共 **18** 个，补 `GatherMetadataIO`）；SQLite 55 表/451 列/86 索引/81 FK + `user_version=1`；测试"声明口径"（core 1,995/234、app 1,260/183）与"最近一次 macOS 运行"分列；en 2,680 / zh-Hans 9；门禁 15。
- docs/ROADMAP、docs/DEVELOPMENT（172→195、门禁清单、AppIntents 4→6 动作、ratchet 9 指标、`report-baseline.sh` 说明）、docs/ADR（错误码 210 项）、docs/test-runtime-audit（补充 2026-11-17 当前基线块，历史快照保留）。
- 新增 `scripts/report-baseline.sh`：只读输出 targets/API/测试声明/本地化/schema/protocol/cleanup 基线，已写入 DEVELOPMENT 作为文档校准入口。

## 9. 验证证据（2026-11-17 本地实跑）

```text
# SwiftPM manifest（Linux Swift 6.2）
swift package dump-package  → gather-core OK / gather-app OK
# 可移植 target 类型检查（Linux）
swift build --target GatherProtocol   → complete (4.1s)
swift build --target GatherPreviewData → complete (4.2s)
# 语法：1086/1086
swiftc -parse -enable-bare-slash-regex（逐文件） → 0 failures
# 门禁（Linux 可执行 14/15；shellcheck 在 PATH）
check-no-legacy / cleanup-ratchet / layering / domain-events / domain-writes /
duplicate-symbols --strict / test-catalog --strict / preview-surface --strict /
design-system / select-star --strict / protocol-surface --strict / coded-errors /
backlog-evidence / repo-hygiene（6 节含 shellcheck）  → 全部 PASS
check-warnings.sh → 需要 macOS SDK，未在本机执行（CI 两个 macOS job 覆盖）
# 其他
git diff --check → 干净；scripts 无 CRLF；1225 文本文件 editorconfig 0 违规
```

## 10. 风险与后续建议

1. **本轮未编译/未运行**：所有 Swift 改动的最终类型检查与运行时套件需 macOS CI 首跑确认（改动均为行为保持的最小变换，风险点已在各分册列出：`#require` 在 throwing helper 中的用法、静态 formatter/coder 的 Foundation Sendable 标注、UTF 展示格式逐字节等价性）。`check-warnings.sh`（-warnings-as-errors）同样待 macOS。
2. **收益需实测**：性能改动只做到"构造次数/复杂度"层面，建议 macOS 上跑 `gather-core-benchmarks` 与 Instruments 时间线复核。
3. **schema 性能项**：按第二轮查询计划审计（`../2026-11-17-round2-hardening/perf-core-round2.md` §5.1），计入 SQLite PK/UNIQUE 自动索引后仅 1 个 FK 子列缺前导索引（`session_assets.display_file_id`，当前无查询使用；只计显式 `CREATE INDEX` 时为 19 个）。若后续补索引，建议在下次 `user_version` 迁移时加 `session_assets(display_file_id)` 索引并同步 `expectedExplicitIndexCount`/`expectedShapeFingerprint`（需 macOS 跑 schema 测试生成指纹）。
4. **shellcheck 版本漂移**：门禁 [f] 依赖 `shellcheck`（本地 0.10.0，CI 用 ubuntu-latest 自带版本，未 pin）；如 CI 升版引入新规则，需按门禁提示同步修脚本。
5. **AppIntents 自检**：`scripts/check-appintents.sh` 默认仍硬性要求 Wave3 的 4 个 intent，而应用当前提供 6 个动作（docs/DEVELOPMENT 已如实分列）；是否把新 2 个动作纳入硬性预期，建议随下次真机验收决定。
6. **文案测试钉死项**："New Workspace"/"Import Folder" 等菜单标题、`Cancelled/Canceled` 拼写等被测试精确断言，HIG 收尾需测试所有者一起改，本轮未动。
