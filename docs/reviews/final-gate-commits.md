# 最终提交门禁审计（61 个本地 commit）

- 仓库：/Users/panzeyu2013/Desktop/code/develop/Gather
- 分支/HEAD：refactor / 91c70eb（origin/refactor = 5905cad，ahead 61）
- 范围：origin/refactor..HEAD 的 61 个 commit（审计快照为 06b3e0d 的 59 个，另有 60edad0、91c70eb 两个收口 commit）
- 方式：只做 git/文件静态读取，**未执行 build/test/打包**；测试与门禁数字引用主线程本轮实测（core 1146/171、app 624/69、9 门禁与 schema 全绿）及 docs/final-report.md §5、docs/reviews/architecture-remediation-status.md §2。
- 提交规范依据：[DEVELOPMENT.md](../DEVELOPMENT.md#L529-L544)（Conventional Commits“建议” + PR 四项说明 + 禁止提交构建产物/个人照片/模型文件/本地数据库）。

## 0. 结论（先行）

1. **没有发现 P0**：工作区干净；61 个 commit 无 merge、无 fixup/squash；未跟踪构建产物、数据库、日志、临时文件、证书或明文凭据；关键数据修复（finalize 备份顺序、lease owner CAS、370 列 V1 迁移）在 HEAD 静态可证已落地。
2. **有 4 个 P1 决策/修复项**：① 38.5 MB 的 SFace 模型文件入库，与 DEVELOPMENT 的“模型文件不入库”直接冲突；② 最终文档仍有 6 处可复算漂移（91c70eb 已修掉 ratchet/有效测试数/Protocol 等大部分）；③ 发布门仍有 app icon、签名/公证、release 实跑等未闭环；④ 历史含 1 个 719 文件巨提交和 1 个 checkpoint 提交，push 前必须决定“接受并说明”还是“重写”。
3. **提交规范基本面合格**：61 个 subject 全部能被 Conventional Commits 头解析；22 refactor / 11 docs / 8 feat / 6 build / 5 chore / 5 fix / 2 test / 2 ci。问题集中在“一个 commit 混多个 scope”“历史双语 subject 过长”“正文为空”，不是类型前缀错误。
4. **PR 定位应是“可合并候选”，不是“可发布”**：主线程测试全绿，但 GUI、真实签名/公证、x86_64 运行期、CI release 均未验证，且 app icon 缺失（[final-sweep-release.md](final-sweep-release.md#L366)）。60edad0 已把 release runner 改为 macos-26，但该 job 仍从未实际运行。

## 1. P0 / P1

### P0（阻断提交/合并）

无。未发现可复现的数据损坏、明文凭据、构建产物入库或未提交源码。

### P1（push/PR 前必须处理或明确决策）

#### P1-1 模型文件入库，与仓库自己的提交规则冲突

- 事实：**desktop/native/gather-core/Sources/GatherAnalysis/Resources/FaceModels/SFace.mlpackage/Data/com.apple.CoreML/weights/weight.bin** 为 **38,542,848 B**；同目录 model.mlmodel 45,008 B、LICENSE.txt 11,358 B。git ls-tree -r -l HEAD 可复算。
- 规则：[DEVELOPMENT.md](../DEVELOPMENT.md#L544) 明确写“不要把构建产物、个人照片、模型文件或本地数据库提交到仓库”。
- 缓解事实：模型是 Apache-2.0，manifest.json 记录来源 commit/SHA-256，scripts/convert-face-model.py 可复现转换；README 也写明随包分发（[docs/README.md](../README.md#L66-L67)）。因此这不是“来路不明的大文件”，而是**规则与产品资产的冲突**。
- 影响：一旦 push，38.5 MB blob 进入远端历史；当前整个 .git pack 仅 74.30 MiB，模型占一半以上。现在重写还便宜，push 后只能 filter-repo + 强推。
- 建议（二选一，push 前定）：
  - A. 保留资产：在 DEVELOPMENT 增加“随包分发的第三方推理模型”例外，补 .gitattributes（binary/LFS），PR 中说明 Apache-2.0 与来源；
  - B. 不入库：改用 LFS 或构建期下载/转换，历史中移除该 blob（同时确认 build.sh 的 model 校验与 CI 缓存策略）。

#### P1-2 最终文档仍有 6 处与 HEAD 不同步

91c70eb 已修正 ratchet 54/230、core 有效 1,143、Protocol 255、9 道门禁（gate 输出 179 个测试文件）、preview 2,031 行；**仍未修**：

| 文档声明 | 位置 | HEAD 实测/静态证据 |
| --- | --- | --- |
| en 1,322 键 | [final-report.md](../final-report.md#L65)、[refactor-progress.md](../refactor-progress.md#L15) | grep -c '^"' en.lproj/Localizable.strings = **1,332** |
| GatherDelivery 16 文件 | [architecture-remediation-status.md](architecture-remediation-status.md#L38)、[final-report.md](../final-report.md#L70) | find .../GatherDelivery -name '*.swift' = **20**（59085a0 拆分 Writeback） |
| 状态文档 HEAD cdf3962 | [architecture-remediation-status.md](architecture-remediation-status.md#L4) | 实际 **91c70eb**（晚 12 个 commit） |
| 641 Swift 文件（§8 又写 535） | [final-report.md](../final-report.md#L58)、[final-report.md](../final-report.md#L190) | git ls-files '*.swift' = **651**；desktop/native 下 649 |
| 测试文件 174 | [final-report.md](../final-report.md#L70) | catalog 三个根目录 *.swift = **179** |
| “无模型资产” | [ROADMAP.md](../ROADMAP.md#L200) | 随包 **38.5 MB** SFace（README 与 DEVELOPMENT 均写随包） |

另有一条结论口径问题：[final-report.md](../final-report.md#L194) 仍写“可发布候选”，但 app icon、签名/公证、release job 均未闭环（见 P1-3）。

#### P1-3 发布门未闭环，不能把本 PR 描述成“可发布”

- **app icon 缺失**：仓库无 *.icns/Assets.car，Info.plist 无 CFBundleIconFile；final-sweep-release.md 将其列为“未修（产品 P1）”（[final-sweep-release.md](final-sweep-release.md#L366)）。
- **签名/公证 0 覆盖**：codesign --verify、notarytool、stapler、spctl 均未在真实凭据下执行（[final-acceptance-build.md](final-acceptance-build.md#L133)）。
- **release job 从未运行**：无 tag，release job 从未触发（[final-sweep-release.md](final-sweep-release.md#L77)）；60edad0 已把 runner 改为 macos-26，但尚未实跑，SDK 可用性未证实。
- **x86_64 只编译未运行**：无 Rosetta/Intel 启动、CoreML、资源解析验证（[final-acceptance-build.md](final-acceptance-build.md#L134)）。
- 结论：PR 可以合并代码，但发布说明必须写“release blocked by app icon + real signing/notarization + CI release run”，不能写“可分发包已验收”。

#### P1-4 历史可 Review 性：1 个 719 文件巨提交 + 1 个 checkpoint

- **30f51f0 refactor(native)!: 完成破坏性重构与评审修复收尾**：git show --stat **719 files / +95,028 / −43,184**；--name-only 893 路径（重命名被拆成 add/delete）。同时含代码、测试、49 个归档截图、文档、脚本、清理与 P0/P1 修复；类型写 refactor!，但实际混了 fix/UI/docs/cleanup。
- **ad9df1b chore: checkpoint native Swift review and UI improvements**：149 files / +17,024 / −4,669，正文为空，典型 WIP checkpoint；含 76 个新增文件与 65 个 docs 路径（多为截图）。
- 其余混合代表：90641e2（200 files，人脸管线 + Swift 6 迁移）、38b0928（39 files，UI error + test support + release + CI pin）、877b2cd（28 files，trace/helper/warnings/baseline）、d0311e4（62 files，dead code + docs）、796a2b2（build/release + 3 个源码 warning 修复）、64d2230（tests + 抬高 unchecked baseline）、82603e0（模型 + 代码 + 脚本 + docs，正文为空）。
- 决策：**不建议在 push 前重写**——architecture-remediation-status.md 的 WP 表引用了 65c0179…1031954 等 hash，重写会连带改文档；但若团队要求“可 bisect 的原子提交”，必须在 push 前做，push 后成本更高。最低要求：PR 描述中承认这段历史，后续 commit 不再复制该模式。

## 2. 提交审计

### 2.1 type / scope / 描述

- 全部 61 个 subject 通过 Conventional Commits 头解析（type、可选 scope、可选 !、冒号、description）。
- 类型分布：refactor 22、docs 11、feat 8、build 6、chore 5、fix 5、test 2、ci 2。
- 合规但不够好的点：
  - **6 个双语 slash subject**（584e836、1edb20f、58ffba4、4b3a3a4、90641e2、d86849d）：description 应是单句，“中文 / English”会让 subject 变成两段。
  - **5 个 subject > 100 字符**（最长 58ffba4 146、90641e2 134、815762c 125、1edb20f 121、d86849d 111），不利 git log --oneline。
  - **5 个空正文**（584e836、1edb20f、ad9df1b、82603e0、ab7752e）；其中前四个是行为/资产变更，缺少“为什么/验证/边界”。
  - scope 命名不统一：app（gather-app）、application（GatherApplication）、native（历史大范围）并存；chore/docs 多数无 scope。可接受，但 PR 模板应说明 scope 词表。
  - 30f51f0 的 ! 有完整 BREAKING CHANGE: footer，这一点合格；其余无 ! 的 breaking 语义变更（Schema reset、旧命令面删除）已在正文说明，但未用 footer，建议以后统一。
  - 64d2230 在 test commit 中把 unchecked_sendable 53→54；有“NSLock 保护的进程内状态”理由，且后续 877b2cd 把 try? 231→230，属“有理由的定向放宽”，但应在 PR 中单独点名，避免被当成无声放水。

### 2.2 是否混合无关改动

有，且集中在历史段：

| commit | 规模 | 混合内容 |
| --- | ---: | --- |
| 30f51f0 | 719 files / +95,028 / −43,184 | 代码 + 测试 + 49 张归档截图 + 文档 + 脚本 + 清理 + P0/P1 修复 |
| ad9df1b | 149 / +17,024 / −4,669 | WIP checkpoint；代码 + 65 个 docs 路径（多为 assets） |
| 90641e2 | 200 / +26,754 / −14,756 | 人脸管线 + Swift 6 迁移 + 测试/文档 |
| d0311e4 | 62 | dead code + 文件头 + README/DEVELOPMENT/ROADMAP |
| 38b0928 | 39 / +915 / −297 | UI error 映射 + FileSystemDeliveryFilePort 迁 test support + release 校验 + CI pin |
| 877b2cd | 28 | trace + helper 去重 + warning + protocol/ratchet baseline |
| 796a2b2 | 8 | build/release 插件 universal + 3 个源码 warning 修复（L10n/DB/Culling） |
| 64d2230 | 3 | 新增 port fakes + 修改 cleanup baseline |
| 82603e0 | 40 / +1,496 / −385 | 38.5 MB 模型 + 人脸代码 + 转换脚本 + docs，正文为空 |

WP 段（bf9adba…1031954）大多做到“一个 WP 一个 commit”，代码 + 对应测试 + 状态文档同 commit 是合理的，不按“混合”扣分。

### 2.3 构建产物 / 凭证 / 大文件 / 临时文件

- **未跟踪**：.app、.dmg、.zip、.sqlite、.db、.log、.tmp、.env、.p12/.cer/.pem/.key/.mobileprovision、.DS_Store。git ls-files 仅命中 2 个模型文件（weight.bin、model.mlmodel）。
- **凭证**：diff 的 + 行只出现 GitHub secrets 引用与 MACOS_CERT_PASSWORD 等变量名，没有明文值；.gitignore 已覆盖证书与 .env*。
- **大文件**：模型 38.5 MB；vector-fixtures.json 3,630,166 B；docs/archive/reviews/assets 中多张 3.6–3.9 MB PNG（最大 3,870,288 B）。无 .gitattributes、无 LFS；.git pack 74.30 MiB。
- **临时文件**：工作区有被 ignore 的 .build（多个，数 GB）、tests/、Capture_One_Plugin_SDK_(Mac)_v1.0.1/、desktop/coplugin/GatherLink.coplugin/；未入库。.gitignore 尚未忽略 .cleanup-verify/（前次 release 扫尾已提，未修）。
- **空白/EOF**：git diff --check origin/refactor..HEAD 有 9 处：IndexerService.swift:144 trailing whitespace，及 8 个文件“new blank line at EOF”（SessionService/PhotoRepo/SessionRepo/SimilarityResultRepo/SmartAlbumRepo/FaceEmbeddingFingerprintTests/IndexerServiceTests/IncrementalClustererTests）。属 P2 清理，不阻断。

### 2.4 fixup / WIP

- 无 fixup! / squash! / 字面 WIP。
- 有 1 个 WIP 语义提交：ad9df1b chore: checkpoint native Swift review and UI improvements（空正文、149 files）。
- 有 1 个 docs 提交 ab7752e docs: refresh remediation status HEAD 只把 HEAD 写成 cdf3962，提交后即过期（下一 commit 就不是它），属“自指过期”而非 WIP。

### 2.5 每个 WP / P1 / P2 是否有清晰 commit

**WP 映射（来自 [architecture-remediation-status.md](architecture-remediation-status.md#L6-L29)，逐项核对存在）：**

| WP | commit |
| --- | --- |
| WP0 基线冻结 | 无独立 commit（状态表写“—”） |
| WP1 | 65c0179 |
| WP2a / 2b / 2c | 62551b6 / b6db25a / 7bbfc94 |
| WP3a / 3b-1 / 3b-2 / 3b-3 | b97d10f / 9387fa4 / 93304b5 / 6bccb77 |
| WP4a / 4b / 4c / 4d | bf9adba / 66adef8 / c644e6b / 01143ad |
| WP5a / 5b | efc6598 / c475974 |
| WP6a / 6b / 6c | 67eb35d / 95f0075 / f0eb94d（后续 796a2b2、645ca11 收紧 release） |
| WP7 / WP7b | d2527a8 / 1031954 |

结论：WP1–WP7b 都有清晰、带 WP 标签的 commit；**WP0 没有独立 commit**（可接受为“基线冻结”文档动作，但严格按“每个 WP 有 commit”不成立）。

**P0/P1：**

- 评审轮的 P0/P1（P0-1 Delivery 文件阶段守卫、P0-2 CI 并行 flake、P1-9 metadata 执行器、P1-10 跨会话确认等）**没有逐项 commit**；它们被折进 30f51f0 巨提交，映射只存在于 [review-remediation-report.md](../review-remediation-report.md) 的“文件落点”表，commit message 不含 P1 编号。可追溯性靠文档，不靠 git。
- 独立验收的 P1 有明确落点：4287c4c（finalize 备份顺序）、8278d22（lease owner / confirm 单事务 / Host 写收敛）、0f2ef19（370 列 V1→V2）、03a9db6（服务改 any 端口）、a99388f（4 个 >1000 行服务拆分）、59085a0（WritebackService 拆分）、8b67025（FilterValue/RAW 源）、4ce48cd（orphan 路径/replay claim）、645ca11 + 796a2b2（release 门/插件 universal）。
- 测试验收的 P0 由 e6761cc 覆盖（migration guard/fail-closed/backup/FK 断言）；P1 的 fake repo 由 64d2230 补。
- 未闭合：app icon（P1-5，无 commit）、真实签名/公证与 release 实跑（外部条件，无 commit）、x86_64 运行期（无 commit）。
- 60edad0 是新的 CI 收口：core 加 --no-parallel、release runner 改 macos-26、UI/App 禁 import GatherDelivery、删旧对账 step；91c70eb 是新的 docs 收口：补 final-gate-code/tests 报告并修正大部分验收数字。两者都属于“收口 commit”，不是新的 WP。

**P2：** 877b2cd、38b0928、06b3e0d 收口了大部分代码/文案 P2；但 [final-sweep-release.md](final-sweep-release.md#L340-L367) 明确 P2-15/16/17（历史拆分、LFS、.cleanup-verify ignore）**未修**，P2-14（状态文档过期）也只修了一部分。

### 2.6 工作区与未 push 风险

- **工作区干净**：git status --porcelain 为空；只有被 ignore 的本地目录。git diff --check 的 9 处空白问题在已提交内容里，不在工作区。
- **未 push**：61 个 commit 只在本地 refactor；无 tag；远端 origin 为 https://github.com/panzeyu2013/Gather.git。
- **base 风险**：origin/refactor 是 HEAD 的祖先，ahead 61；origin/main 也是祖先，ahead **81**（origin/refactor 比 origin/main 多 20 个 commit）。若 PR 以 main 为 base，GitHub 会显示 81 个 commit，不是 61 个；PR 描述必须写清 base，否则范围对不上。
- **本地 main 分叉**：本地 main 比 origin/main ahead 305，且 **HEAD 不是本地 main 的祖先**（HEAD NOT ancestor of local main）；不要为了“合并”顺手 push main，会带出另一条未审历史。
- **无备份**：没有 tag、没有远端分支、没有 bundle。61 个 commit + 38.5 MB 模型只在工作机；push 前建议至少打一个本地 backup tag/bundle（本次审计不执行）。
- **push 体积**：pack 74.30 MiB，模型占 38.5 MB；GitHub 单文件 100 MB 限制未触发，但首次 push 会明显变慢，且模型历史不可压缩。

### 2.7 最终文档与代码同步（补充复算）

91c70eb 已把 final-report 的 core/app 测试数、有效测试数、ratchet、Protocol、9 门禁、179 测试文件、preview 2,031 行、select-star baseline 4 修正；仍余 P1-2 表中 6 项。另：

- [final-report.md](../final-report.md#L58) 的 641 Swift 文件与 [final-report.md](../final-report.md#L190) 的 535/138,829 仍是不同历史口径，和当前 651/890 files 对不上；建议直接删掉这两个过期汇总，或标注“Cut 6c 快照，不用于 HEAD”。
- [final-report.md](../final-report.md#L194) 的“可发布候选”与 P1-3 的 app icon/签名/release 未跑冲突，建议改为“机器验收通过，发布门待外部验证”。
- [ROADMAP.md](../ROADMAP.md#L200) 的“无模型资产”与 README/DEVELOPMENT/38.5 MB 实际资产冲突，属明确事实错误。

## 3. 建议的 PR 描述（可直接粘贴，按实际 base 调整）

~~~~markdown
## 概述

将 refactor 分支的 61 个本地 commit（相对 origin/refactor）合并到主分支。目标是把两包单体原生应用收敛为 8-target SwiftPM 工程：类型化 API、Schema V2、GatherDelivery、Repository Ports、Host/UI 收口、测试基建与可复现发布。

> 若 base 为 origin/main，本 PR 实际包含 81 个 commit（origin/refactor 比 origin/main 多 20 个）；请确认 base 后再 Review。

## 变更边界

- 模块：GatherProtocol / GatherPersistence / GatherDelivery / GatherAnalysis / GatherApplication / GatherUI / GatherHost / GatherApp（8 target；另有 GatherSchema、2 个 bench、test target）。
- API：0 字符串命令；Protocol 255 类型 / 1,340 声明；16 域协议 / 110 方法。
- 数据：Schema V1→V2 线性迁移；43 表 / 373 列 / 69 索引 / 62 FK；user_version=2；370 列历史 V1 可补 3 列；未知形态 fail-closed。
- 交付：Delivery Coordinator 543 行；finalize 在 DB 提交后才删备份；markWritten/markFailed/markConflict 带 lease owner CAS；confirm 单事务；Host 不再直调 DeliveryRepo 写状态。
- UI/宿主：PageVisibility 7 VM；Host SwiftUI import 0；UI 只 import Protocol；GatherAppCommands 迁 GatherApp；UI/App 禁 import GatherDelivery。
- 发布：universal/arm64/x86_64、版本注入、签名/公证接口、插件 universal 校验、release runner 改 macos-26。
- 本 PR 不包含：真实发布凭据、GUI 人工验收、CI release 实跑。

## 验证（主线程本轮实测；本审计未复跑）

- core：1146 tests / 171 suites，exit 0。
- app：624 tests / 69 suites，exit 0（串行 + 并行 3 次）。
- schema：43 表 / 373 列 / 69 索引 / 62 FK / user_version=2 / FK 违规 0。
- 门禁：9 道 strict 全绿；ratchet 54/230/0/0/0；protocol 255/1,340；preview 14 块 / 2,031 行。
- 命令（摘自 docs/final-report.md §5.1–5.3，CI 可直接复用）：

~~~bash
swift build --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
swift test --package-path desktop/native/gather-core --no-parallel --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error

swift build --package-path desktop/native/gather-app --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error

swift run --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify
~~~

- 本机 build.sh 受 DSH sandbox 限制未完整执行；bundle 由 CI 的 gather-app tests + bundle job 验证（本 PR 未跑）。

## 未验证 / 明确排除的外部条件

- 人工 GUI smoke（启动、导入、逐页中英 A/B、挑片撤销、人脸/相似度/导出、菜单、Cmd+Q）未做。
- 真实 Developer ID 签名、notarytool、stapler、spctl 未跑；app icon 缺失（无 CFBundleIconFile）。
- x86_64 仅编译，未在 Rosetta/Intel 运行；插件 x86 仅 lipo 证据，未在 C1 实机加载。
- CI release job 从未运行（无 tag）；60edad0 已改 macos-26，但 SDK 可用性未证实。
- 10k 人脸精确聚类 release 19.25s（按 D-158 接受 ≤20s，5s 为 stretch）。
- 外部编辑器（Capture One）写盘不与进程内 XMPFileLock 串行，靠 revision/fingerprint 事后检测。

## 数据迁移 / 写回 / 删除影响

- 迁移：V1（373 列）→V2 为版本位 no-op；370 列旧 V1 在 BEGIN IMMEDIATE 内补 3 列，迁移前 pre-v2-* 备份，失败回滚、库停在旧版本；未知列形默认 fail-closed，只有显式 resetPolicy 才把库（含 -wal/-shm）改名为 .incompatible-* 后重建。旧 outbox/writeback/metadata 表不迁移、不导入。
- 写回：metadata/culling/face/similarity 走同一 Delivery 状态机；finalize 先 DB 删行后删备份；mergeInput 重置全会话 confirmed_at；confirm 在一个 IMMEDIATE 事务内复核门禁。
- 删除：cleanup 有跨模块 item gate；finalize 删除交付行后清理备份；备份路径做前缀/目录/符号链接/常规文件校验；删除会话不级联删除 delivery/备份（P2-14 已知，当前不自动清理）。
- 恢复：迁移失败保留备份但不自动 restore；需要人工把 pre-v2-* 移回。开发期数据库按可丢弃处理。

## 风险 / 回滚

- 代码回滚：61 个本地 commit 未 push，可按 git log 选择 revert；不要 reset --hard。
- 数据回滚：保留 pre-v2-* 备份；不可兼容库改名而非删除；恢复时停应用、移走新库、把备份改回原名。
- 历史风险：30f51f0 为 719 文件巨提交，bisect 成本高；ad9df1b 为 checkpoint；若要求原子历史，需在 push 前重写并同步 docs hash。
~~~~

## 4. 提交前必须修 / 建议 commit message

> 本审计按“push 前最后一关”给建议；不要求改源码语义。

| 优先级 | 动作 | 建议 commit message |
| --- | --- | --- |
| P1-1 | 决定 SFace 模型：LFS + 文档例外，或移出历史 | build(repo): track bundled SFace model with Git LFS / docs: document bundled SFace model exception |
| P1-2 | 修剩余 6 处文档漂移（§1.2） | docs(repo): correct remaining final metrics and HEAD snapshot |
| P1-3 | 补 app icon / CFBundleIconFile；发布前跑真实签名/公证 | fix(release): add app icon and CFBundleIconFile |
| P1-4 | push 前决定是否重写 30f51f0/ad9df1b；若不重写，PR 中说明 | 不新增 commit；若重写则同步更新 docs 引用 hash |
| P2 | 修 9 处空白/EOF | style: normalize trailing whitespace and EOF newlines |
| P2 | ROADMAP 的“无模型资产” | docs(roadmap): correct bundled SFace model statement |
| P2 | 把 .cleanup-verify/ 加入 ignore | chore(repo): ignore .cleanup-verify |
| P2 | 为 unchecked_sendable 53→54 留 PR 说明（不新增 commit） | — |

## 5. 审计边界

- **未运行** swift build/test、build.sh、门禁脚本、gather-schema verify；测试/门禁数字来自主线程本轮实测与 docs，未在本报告中复跑。
- 未做 GUI、签名、公证、CI、x86_64 运行期验证；未联网核对 GitHub runner 生命周期。
- 未改源码/测试/commit；唯一写入为本文件。
- 文件/行数、blob 大小、commit 统计均由 git ls-tree、git show --stat、git diff --shortstat 静态得出；个别文档计数可能采用历史口径，§1.2 已标“口径未注明”的项不强行判错。
