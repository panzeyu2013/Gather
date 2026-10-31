# V0 基线结论（2026-10-30 首跑；2026-10-31 多轮修复后重跑）

- 代码冻结点：`b25077cf165970f21ed8839b1ca65ca677987249`（main）。
- 修复：`08bf00b`（多 IIM 显式失败）、`32bb453`（universal Float16/插件）、`31fc9d8`（SDK 探测）、`ca577d9`（C1 16 检测）。
- 当前基线：`322c186b`，`dirty=0`。
- 执行：`./scripts/validation/v0-baseline.sh`，14/14 步 exit 0。
- 测试：core 1,599 / 236 + 串行 25 / 4 + app 859 / 99 = **2,483 tests / 339 runtime suites**。
- test-catalog：`@Test 2483/2483 · @Suite 280/280 · 断言 11,459/11,459`，skip 站点 17（元数据缺失 0、过期 0）。
- schema：`tables=55 columns=451 indexes=86 fks=81 user_version=1 foreign_key_violations=0`。
- 门禁：12/12 exit 0。
- 环境：macOS 27.0.1（26A434）、Xcode 27.2（27B52）、Swift 6.4.2、SDK 27.2。
- 结论：**V0 go**，代码基线可进入 V1。
- 历史：首跑（`b25077cf`）2,480 / app 857；V1 修复后 2,481；universal 修复后 2,482；C1 修复后 2,483。各轮均 14/14。
- 限制：并发跑 core/app 的 `test.sh` 会因临时目录清理竞态产生假红；本次记录一次 app 假红，顺序重跑绿。

原始日志：`.build/validation/logs/`（`v0-summary.tsv`、`v0-tests.log`、`v0-schema.log`、`gate-*.log`）。
