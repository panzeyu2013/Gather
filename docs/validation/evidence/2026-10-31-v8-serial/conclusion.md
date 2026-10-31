# V8 CI 串行全量（2026-10-31）

- 命令：`swift test --no-parallel`（core、app 各自，含构建）。
- core：**1,624 tests / 240 suites passed**，10.87 s，exit 0。
- app：**859 tests / 99 suites passed**，17.14 s，exit 0。
- 这复现 CI 的串行口径，排除“只有并行才绿”的假绿。
- 与 V0 的差异：V0 用 `test.sh` 把进程级状态套件拆成第二遍；串行一次跑完，数量一致（1,599 + 25 = 1,624）。
