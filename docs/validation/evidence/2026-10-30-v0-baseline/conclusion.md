# V0 基线结论（2026-10-30 首跑；2026-10-31 修复后重跑）

- 代码冻结点：`b25077cf165970f21ed8839b1ca65ca677987249`（main）。
- V1 预演修复：`08bf00b`（多个 0x0404 IIM 写回显式失败）。
- 当前基线：`49d48477`（含修复与验证文档），`dirty=0`。
- 执行：`./scripts/validation/v0-baseline.sh`，14/14 步 exit 0。
- 测试：core 1,598 / 236 + 串行 25 / 4 + app 858 / 98 = **2,481 tests / 338 runtime suites**。
- test-catalog：`@Test 2481/2481 · @Suite 279/279 · 断言 11,454/11,454`，skip 站点 17（元数据缺失 0、过期 0）。
- schema：`tables=55 columns=451 indexes=86 fks=81 user_version=1 foreign_key_violations=0`。
- 门禁：12/12 exit 0。
- 环境：macOS 27.0.1（26A434）、Xcode 27.2（27B52）、Swift 6.4.2、SDK 27.2。
- 结论：**V0 go**，代码基线可进入 V1。
- 历史：首跑（`b25077cf`）为 2,480 tests / app 857；V1 修复新增 1 例后为 2,481 / 858。两轮均 14/14。
- 限制：并发跑 core/app 的 `test.sh` 会因临时目录清理竞态产生假红；本次记录一次 app 假红，顺序重跑绿。

原始日志：`.build/validation/logs/`（`v0-summary.tsv`、`v0-tests.log`、`v0-schema.log`、`gate-*.log`）。
