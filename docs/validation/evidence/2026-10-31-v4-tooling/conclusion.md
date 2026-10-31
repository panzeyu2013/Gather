# V4 工具就绪检查（2026-10-31）

- `gather-triage-eval` 可执行：`--db/--session/--labels/--export-signals/--strict`。
- fail-closed：
  - 缺 labels 文件 → `cannot read labels ...`，exit 2；
  - 非 SQLite 文件 → `corrupt("不是 SQLite 文件：...")`，exit 2。
  两种输入都没有静默成功。
- `--help` 打印 usage，但 exit 2（P2，脚本可用性小问题）。
- `--strict` 阈值：误杀率 <1%、reject precision ≥99%、复核率 ≤35%、覆盖率 ≥65%；
  与计划里的“triage 与人工一致 ≥80%”是不同口径，报告需双列。
- 仍缺：标注集；闭眼/合焦/审美准确率没有现成 CLI；`gather-face-benchmarks` 只覆盖
  embedding/聚类。V4 不能判定。
