# T0 真实集质量门（操作手册）

> P0 的唯一外部验收项：建议淘汰误杀率 < 1%。本文定义数据、命令、指标与判定。
> 策略与阈值见 [t0-triage-policy.md](../design/p0/t0-triage-policy.md) §10。
> 结论口径：**没有跑过真实 400 张标注集，就不能宣称质量门通过**；合成数据/单测只证明实现正确，不证明真实精度。

## 1. 数据要求

- 400 张真实照片，四层各 100：婚礼/活动、人像、体育/动作、商品/风光（无脸）。
- 两名摄影师**独立**标 keep / reject / unsure；争议由第三人裁决；报告 Cohen's κ（目标 ≥0.6）。
- 标注对象是**逻辑资产**（RAW+JPEG 算一条），路径写代表文件即可；同 basename 多文件时必须写绝对路径。
- 数据集不进入仓库；放在本机目录，由实验记录引用。

## 2. 准备评估库

质量分析必须在库里跑过（T0 读的是 `asset_analysis.technical_quality`）。建议复制一份库，避免评估写操作污染主库：

```bash
sqlite3 ~/Library/Application\ Support/Gather/gather.sqlite \
  "VACUUM INTO '/private/tmp/gather-eval.sqlite';"
```

会话 id 可从库里查：

```bash
sqlite3 /private/tmp/gather-eval.sqlite "SELECT id, name, photo_count FROM sessions;"
```

## 3. 标注文件

CSV 或 TSV，每行：`photo_path,label[,category]`

```csv
photo_path,label,category
/Volumes/Shoot/IMG_0001.NEF,keep,wedding
/Volumes/Shoot/IMG_0002.NEF,reject,wedding
/Volumes/Shoot/IMG_0100.JPG,unsure,portrait
```

- label：`keep` / `reject` / `unsure`（也接受 pick/no/? 等别名）。
- category 可选；用于分层报告（婚礼/人像/体育/商品风光）。
- 未匹配到会话资产的标注、无法识别的 label 都会单独计数，不会被静默忽略。

## 4. 运行

```bash
cd desktop/native/gather-core
swift run -c release --disable-sandbox gather-triage-eval \
  --db /private/tmp/gather-eval.sqlite \
  --session <session-id> \
  --labels /path/to/labels.csv \
  --strict
```

- **只读**：打开库、`TriageRepo.loadCandidates`、`evaluateTriage`；不生成建议、不写决策、不写 XMP。
- `--strict`：任一门槛失败 exit 1；适合 CI/发布门禁。
- 输出 Markdown：总体 + 分类的误杀率、reject precision、复核率、覆盖率，以及 unmatched/unknown 计数。

## 5. 指标与门槛

| 指标 | 定义 | 门槛 |
|---|---|---|
| 误杀率 | 真实 keep 被判 reject / 真实 keep | **< 1%** |
| reject precision | 真实 reject 且判 reject / 全部判 reject | ≥ 99% |
| 复核率 | review / 有标注（不含 unsure） | ≤ 35% |
| 覆盖率 | (keep + reject) / 有标注 | ≥ 65% |

- `unsure` 不计入分母；分母为 0 时指标显示 `n/a` 并判 FAIL（“没有样本”不等于 0%）。
- 分类报告不得出现单层误杀率 >2%；否则即使总体达标也保持 Beta。

## 6. 当前状态（2026-10-25）

- 指标纯函数与 CLI 已实现并有单测（`TriageMetricsTests` 4 条）。
- **真实 400 张标注集尚未提供**，质量门未执行；因此 T0 对外仍是“技术质量建议（Beta）”，不能写“误杀率 <1%”。
- 下一步：按 §1 准备数据 → §2 复制库 → §3 标注 → §4 跑 `--strict` → 把输出附到 P0 验收报告。

## 7. 工具自检（不是质量证据）

2026-10-25 用 3 张照片的临时夹具（2 张 exact duplicate + 1 张单张）验证 CLI 全链路：

- 输出 `candidates=3 labeled=3 unsure=0 unmatched=0`；
- 误杀率 0%、reject precision 100%、复核率 0%、覆盖率 100%；`--strict` exit 0。

这次自检只证明读取库、候选映射、标注匹配、指标计算与退出码可用，
**不证明真实照片上的精度**，不能替代 400 张标注集。
