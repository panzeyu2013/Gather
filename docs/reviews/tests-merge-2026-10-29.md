# tests 合入 main（2026-10-29）

> 合并提交：`1c3c4074`（parents `b3b0d578` + `79e688ef`；已 push，`origin/main=1c3c4074`）。
> **提交信息与实际内容不符**：Git 在有 `MERGE_HEAD` 时把已暂存的合并结果与另一会话的
> 预览夹具修复一起提交，message 只写了后者。历史已发布，本轮不改写；tests 的合入内容、
> 冲突解决与验证证据记在本文。后续合并仍按 `merge: 合入 <分支>（…）` 惯例，并在提交前
> 确认没有其他会话共用同一 worktree。

## 1. 合入内容（`79e688ef`，基于 `d70343e5`）

| 主题 | 落点 |
| --- | --- |
| 统一测试入口（core 并行主批 + 4 个进程级状态套件串行批；app 并行） | `scripts/test.sh`、`.github/workflows/ci.yml`、README、`docs/DEVELOPMENT.md` |
| app 并行 SIGSEGV 修复：`NSWindow.close()` → `orderOut()`、嵌套 RunLoop → async settle、窗口 alpha=0 守卫 | `WorkspaceVisibilityTests`、`CullingGridPerfTests` |
| 并行 flake 修复：history 刷新竞态、Gallery 固定等待 → 条件等待、ReadPoolTests 信号量 | `CullingViewModelAPITests`、`GalleryViewModelTests`、`ReadPoolTests` |
| 模型初审覆盖（此前 Repo 0% / Service 10.6%） | 新增 `ModelReviewRepoTests`（5）、`ModelReviewAnalysisTests`（5） |
| 测试体系审计 | `docs/test-runtime-audit.md`、`docs/test-audit.md`、决策文档追加更新 |

## 2. 冲突与解决

| 文件 | 冲突 | 解决 |
| --- | --- | --- |
| `docs/README.md` | 两侧都改基线段 | 保留 main 的 macOS 26 / 134 方法 / Schema 数字，采用 tests 的并行口径；测试数按合并后重采样 |
| `scripts/check-test-catalog.sh` | 两侧都改 ratchet 注释与基线 | 合并为 `2,195→2,205` / `241→242`，保留 main 的断言 ratchet，基线取实测 `10,244` |

无文本冲突但会破坏合并结果的两处语义冲突：

1. **`ModelReviewRepo.latestByAssetFile`** 已在 `bc7e4046` 的收口评审中按「零引用」删除
   （`docs/reviews/final-review-2026-10-29.md`），tests 侧仓储测试覆盖了该方法。
   合并取舍：保留 main 的删除决定，删掉对应 1 例与 3 处断言，只覆盖保留的 `latest` 口径；
   新增用例 11 → 10，并同步 `docs/test-runtime-audit.md` 的计数与覆盖率说明。
2. **`scripts/test.sh` 的 bash 3.2 兼容性**：脚本用 `"${FLAGS[@]}"` 透传 `SWIFT_TEST_FLAGS`；
   macOS 自带 bash 3.2 在 `set -u` 下展开空数组会报 `FLAGS[@]: unbound variable`，
   脚本在 CI 的 `/bin/bash`（3.2.57）上直接 exit 1（本机复现）。改为
   `${FLAGS[@]+"${FLAGS[@]}"}` 后通过；这是 tests 分支提交信息里「验证全绿」未覆盖的路径。

## 3. 重采样（机械计数，2026-10-29 HEAD `1c3c4074`）

| 口径 | 取数命令 | 值 |
| --- | --- | --- |
| core 用例 / 套件 | `SWIFT_TEST_FLAGS=--disable-sandbox ./scripts/test.sh core` | **1,443 / 216**（主批 1,419/212 + 串行批 24/4） |
| app 用例 / 套件 | `SWIFT_TEST_FLAGS=--disable-sandbox ./scripts/test.sh app` | **762 / 89** |
| `@Test` / `@Suite` 声明 | `grep -rhE '^[[:space:]]*@(Test|Suite)([[:space:]]|\()'`（两个 Tests 目录） | **2,205 / 242** |
| 断言 ratchet | `grep -rhoE '#(expect|require)\('` | **10,244** |
| en 键 | `grep -c '^"'`（en.lproj） | **1,748**（zh 占位 9） |

## 4. 验证（全部 exit 0）

| 检查 | 结果 |
| --- | --- |
| `./scripts/test.sh core` | 1,419/212（1.368s）+ 24/4（0.182s）= 1,443/216 |
| `./scripts/test.sh app`（并行） | 762/89（2.752s） |
| `./scripts/test.sh all` | core 1,443/216 + app 762/89，exit 0 |
| app 并行重复 10 次（`swift test --parallel`） | 10/10 exit 0（2.58–2.85s） |
| `swift build --package-path desktop/native/gather-app --explicit-target-dependency-import-check error` | 构建通过 |
| `gather-schema verify` | 44 表 / 386 列 / 72 索引 / 65 外键，`user_version=1`，FK 违规 0 |
| 12 个 `check-*.sh`（strict 可用者带 `--strict`） | 全绿 |
| `check-test-catalog.sh --self-test` | OK |

本机口径：arm64 / macOS 26 / Xcode 27.1 / Swift 6.4 / Debug；测试命令均带
`SWIFT_TEST_FLAGS=--disable-sandbox`（本机 SwiftPM 清单沙箱在 DSH 文件沙箱下不可用，
CI 不需要该参数）。

## 5. 残余

1. **CI 首跑未观察**：本会话 app 并行重复 10/10 全绿（arm64 / Xcode 27.1），
   但 macos-26 / Xcode 26 上的并行稳定性需看首个 CI 周期；如出现 flake，按
   `docs/test-runtime-audit.md` §7 用 `--filter` 二分。tests 分支声称的 50/50 未在本轮复跑。
2. **提交信息不符**：`1c3c4074` 已 push，未改写；若必须严格按 `merge:` 惯例，需要 force push。
3. **未做 GUI 视觉验收**；未在 x86_64 上运行（仅 arm64）。
4. **并发工作区风险**：合入过程中另一会话在同一 worktree 提交了预览夹具修复，才导致
   上述 message 混杂；后续长任务建议独占 worktree。
