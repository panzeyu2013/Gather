# 最终收尾报告：docs / scripts / 构建产物（2026-10-22）

> 范围与授权：只写 `docs/**`、`scripts/**`、`.gitignore`、`README.md`、`docs/DEVELOPMENT.md` 与 `release/` 生成物、`.build` 残留；**未改 Sources / Tests / Package / Schema**。
> 结论先行：删除 **≈2.21 GiB** 构建产物；当前文档（非 archive）死链 **13 → 0**；`check-duplicate-symbols.sh` 去掉 RequestGate 遗留规则；`check-docs --strict` / `check-test-catalog --strict` / `check-cleanup-ratchet` 全绿；残余：归档 33 条旧源码链接、决策编号冲突（LoadPhase 注释经复核已无 ViewState，非本轮改动）。
> 实测时点：2026-10-22 17:00 +0800（并行工作区仍在改动，文件/行数可能随后漂移）。

## 1. 删除清单（构建产物，先 `ls`/`du` 确认再删）

| 路径 | 大小（du -sh） | 判定 | 处置 |
| --- | ---: | --- | --- |
| `release/Gather.app` | 22 MB | 2026-09-29 产物：arm64 Mach-O + Info.plist + `gather-app_GatherApp.bundle`（104 KB），无用户数据；`release/` 与 `*.app` 均在 `.gitignore`，未被跟踪 | 删除（`release/` 目录保留为空，`build.sh` 会重建） |
| `.build/scratch-app` | 465 MB | SwiftPM scratch（15:27 后无写入，无活动进程写入） | 删除 |
| `.build/scratch-core-p14` | 547 MB | 同上（15:34 后无写入） | 删除 |
| `.build/scratch-p14` | 619 MB | 同上（15:30 后无写入） | 删除 |
| `.build/perf-probe` | 316 KB | 2026-09-30 性能探针源码+二进制残留 | 删除 |
| `desktop/native/.build/scratch-ci` | 615 MB | CI scratch（14:35 后无写入） | 删除 |

合计 **≈2.21 GiB**（du 1024 进制；2,268 MiB 量级）。

**保留（仍在用/属增量缓存）**：`.build/scratch` 954 MB 与 `.build/shared-cache` 416 KB（16:40 仍在被并行构建写入）；`desktop/native/.build/scratch` 928 MB（16:41 仍在写）；`gather-core/.build` 3.1 GB、`gather-app/.build` 4.0 GB（两包增量缓存，未动，删了会强制全量重建）。仓库内无用户数据库/照片数据，`tests/fixtures/local/` 未动。

## 2. 修复清单

### 2.1 脚本

- `scripts/check-duplicate-symbols.sh`（112 → 100 行）：删除 RequestGate 规则（`gate_hits`/`gate_n`、`FAIL RequestGate 存在 N 份`、`ok RequestGate 尚未引入（0 份；Cut 4 落地）`）与摘要中的 “RequestGate 定义” 行；规则 2 文案去掉“当前 3 份 LockedBox + 1 份 ResponseBox”的过期描述，改为“越界即 warning / `--strict` FAIL”；help 范围同步。`--strict` exit 0，输出 3 项（batchAsync / Tests-Support 越界 / 扫描文件数）。
- `scripts/check-docs.sh`（165 → 211 行）：新增“当前文档 md 相对链接存在性”检查——范围 `docs/*.md` + `docs/reviews/*.md` + `docs/archive/README.md` + 根 `README.md`；跳过代码块、行内代码、外链、纯锚点、`<...>` 目标；`--strict` 下缺失即 exit 1。表头检查项编号与 help 范围同步。

### 2.2 stale 符号（RequestGate / ViewState / JobScopeCheckpoint）

- `docs/cut6-cleanup-audit.md`：§1.2 与 §4.2 的“`RequestGate` 1 份”更正为 **0 份**，并加“更正（2026-10-22 最终清理）”说明。
- `docs/cleanup-backlog.md` CL-04 残余：脚本规则已移除；`LoadPhase` 注释经 16:48 复核已无 `ViewState` 引用（并行工作区已修，本轮未改 Sources）。
- `docs/final-report.md` §6.9、`docs/review-remediation-report.md` §3.8、`docs/refactor-progress.md` r8 残余、`docs/refactor-decisions.md` D-164 残余：同步为“脚本已修 / LoadPhase 注释已无 ViewState”。
- `JobScopeCheckpoint` 从 review-remediation 的“死代码”清单移除：它是 `GatherUI/Support/JobScopeCheckpoint.swift` 的单一来源键枚举，被 LiveSessionAPI / Dashboard 与测试引用（不是待删代码）。

### 2.3 死链

- 非 archive 当前文档：**13 → 0**（门禁实测 137 条 md 相对链接全部可解析）。
  - `docs/reviews/face-clustering-benchmark.md`：13 条旧 `GatherCore` 源码链接改到 `GatherAnalysis/Face/*` 与 `GatherDomain/Services/FaceKwService.swift`，并改为相对本文件的 `../../` 形式；已随 CL-13 删除的 `ClusteringImpact.swift` 改为代码文本 + 删除说明；文件头加“链接注”。
- 归档（快照，不逐条回填）：`visual-design-review.md` 30 条、`ui-review-2026-09-29-round2-fixes.md` 3 条旧源码路径链接保留；`docs/archive/README.md` 增加说明。**archive → 当前文档的 24 条出链全部有效**（未改快照正文）。

### 2.4 指标与台账

- `docs/cleanup-backlog.md`：CL-18 增“最终复核 53/240/127/0/0”；CL-20 验收改 en **1,322** / zh 9（`^"` 计键；简单正则 1,321 + 1 个含转义引号的键）；CL-04 残余更新；新增 §10 收尾复核。
- `docs/final-report.md`：§3 en 1,322、文档 55 篇、测试 166 文件、新增“收尾复核”行（535/138,829）；§5.3 三门禁数字（catalog 166、docs 链接 0、dup 535）；§6.10 收尾残余；§9.2 预期数字。
- `docs/review-remediation-report.md`：§2 增收尾复核；§3.8 重写；文档口径行改“已修（收尾）”。
- `docs/ROADMAP.md` / `docs/DEVELOPMENT.md` / `docs/README.md`：en 1,313 → **1,322**；README 基线改为评审修复轮数字；DEVELOPMENT 门禁说明补 md 链接检查。
- `docs/refactor-progress.md` 新增“最终收尾”小节；`docs/refactor-decisions.md` 新增 **D-166**。

## 3. 门禁（实测）

| 命令 | 结果 | exit |
| --- | --- | ---: |
| `./scripts/check-docs.sh --strict` | OK：ADR 反引号路径 20（缺失 0）；当前文档 md 链接 137（缺失 0）；reviews 14 篇；schema 声明一致 | 0 |
| `./scripts/check-test-catalog.sh --strict` | OK：测试文件 **166**；缺文件头注释 0；skip 站点 3（`.enabled(if:)` 3）；skip 元数据缺失 0 | 0 |
| `./scripts/check-cleanup-ratchet.sh` | OK：current/baseline = 53/53、**235/240**、127/127、0/0、0/0（try? 比 baseline 低 5，可收紧） | 0 |
| `./scripts/check-duplicate-symbols.sh --strict` | OK：535 文件（并行工作区 16:52–17:00 采样 533–535）；`batchAsync` 1；Tests/Support 外 0；RequestGate 规则已移除 | 0 |

未执行：`swift test` 全量（本轮无源码改动，按任务书不跑）；`check-test-catalog.sh --self-test`（可选负例）。`git status` 复核：本轮只改 `docs/`、`scripts/` 与已忽略的 `release/`、`.build/`；Sources 的变动（含 LoadPhase 注释）来自并行工作区，不是本任务。

## 4. 指标快照（2026-10-22 17:00）

| 指标 | 值 | 备注 |
| --- | ---: | --- |
| Swift 文件 / 行数 | **535 / 138,829** | 2026-10-22 17:00 采样（16:52 533 / 16:57 534 / 17:00 535，并行工作区仍在变）；6c 冻结 535 / 133,740 |
| 测试文件 | **166** | `check-test-catalog` 口径（core 99 + app 67） |
| en / zh 键 | **1,322 / 9** | 1,313 为 6c 时点；修复轮 +9 键 |
| #Preview | **14 块 / 5 文件 / 2,045 行** | `check-preview-surface.sh --strict` |
| docs md | **55 篇 / 21,787 行**（非 archive 26 篇 / 8,765 行） | 含本文件；archive 29 篇 |
| 清理 ratchet | 53 / 235 / 127 / 0 / 0（baseline 240） | current/baseline：unchecked 53/53、try? 235/240、prepare 127/127 |
| 构建产物（保留） | 根 `.build` 955 MB；`desktop/native/.build` 928 MB；两包 `.build` 3.1 GB + 4.0 GB | `release/` 0 字节（空目录） |

## 5. 残余 / 未做

1. **LoadPhase 注释（已闭环，非本轮）**：`desktop/native/gather-app/Sources/GatherUI/Support/LoadPhase.swift:9/18` 在 2026-10-22 16:48 已被并行工作区改为不再引用 `ViewState`；本轮按“不改 Sources”未动，无需再改。
2. **归档旧源码链接**：33 条（2 个文件）按“快照不改”保留，只在 archive 索引注明。
3. **决策编号冲突**：`docs/refactor-decisions.md` 存在两组 D-162 / D-163 标题（6b 期重复），未重排（会影响既有引用）；D-166 为本次新增。
4. **测试例数未复跑**：沿用最近记录 core 1,128/159 + app 616/68；本轮只跑门禁。
5. **两包 `.build` 未删**：3.1 GB + 4.0 GB 属活动增量缓存；如需彻底回收，owner 可跑 `swift package clean`（会强制下次全量重建）。
6. **release/ 为空**：本机无 bundle 可验收；CI 的 `gather-app tests + bundle` 仍是唯一 bundle 证据链（`build.sh` 在本机被 DSH 沙箱拒绝）。
7. GUI smoke / 打包 / 10k 性能等既有残余不在本轮范围（见 final-report §6）。

## 6. 复现命令

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
# 死链与文档门禁
./scripts/check-docs.sh --strict
# 测试目录门禁
./scripts/check-test-catalog.sh --strict
# 清理 ratchet
./scripts/check-cleanup-ratchet.sh
# 重复符号
./scripts/check-duplicate-symbols.sh --strict
# 指标复算
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print | wc -l
grep -cE '^"' desktop/native/gather-app/Sources/GatherUI/Resources/en.lproj/Localizable.strings
# 构建产物现状
du -sh .build desktop/native/.build desktop/native/gather-core/.build desktop/native/gather-app/.build release
```
