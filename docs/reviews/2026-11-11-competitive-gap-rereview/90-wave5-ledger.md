# Wave 5 收口台账（2026-11-11）

> 目标：按 docs/reviews/2026-11-11-competitive-gap-rereview/ 的复核结论收口 P0 风险与 P1 缺口。
> 每批纪律：子代理只改码 + 补测试；Lead 统一 build / core+app 全量 / 门禁 / 提交；每批一行 commit 可回滚。
> 基线：b1fe3488（复核文档提交后）。

## Batch 1（task-7 ~ task-10）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-7 | C1 写回正确性 | c1-fix | 变体写回写前回读；多 variant 不猜目标、跳过且不写 ack；notFound 用 C1 browse 重试一次；select 前 deselect；XMP 关键词通道停用（不再写 culling:*） |
| task-8 | 挑片决策目标 / 浏览连续性 | culling-fix | 对比/Survey 默认只写当前照片，显式开关才批量；切布局保留当前照片（键集分页续页计划），网格进入定位当前 |
| task-9 | 交付 S3 可用链接 | bridge-organize | SigV4 query 预签名 GET（官方固定向量）；S3 发布后对已上传入口生成 24h 客户链接；WebDAV 拼静态入口；结果区可复制/打开 |
| task-10 | 格式白名单 | ingest-export | PhotoFileTypes.supportedExtensions 成为唯一白名单（RAW22+位图6+渲染3=31）；摄取/索引/解码三处引用；摄取预检/结果与索引日志输出不支持格式分组与样例 |

### 关键设计取舍

- C1 多 variant：不猜目标（写错不可逆），整条跳过并提示回 C1 选变体或改走 XMP（文件级、无歧义）；通知报告新增 skippedMultiVariant，非空不写 durable reload-ack。
- XMP 关键词：挑片判断不再用关键词承载，避免 C1 Load Metadata 把 culling:keep/reject 吸进自己的词库；挑片判断走变体级在线通道，评分/色标仍可写 XMP。
- S3：对象仍默认私有（不写 ACL），只给限时预签名链接；secret 不进 URL/日志；TTL 固定 24h（常量，可后续跟分享到期对齐）。
- 格式：.iiq/.3fr/.x3f/.mrw 等从「静默跳过」变为「可导入 + 不支持格式可见」；ImageIO 解不出的个别 RAW 会从静默跳过变成 failed（真机抽查提示）。
- 浏览连续性：键集分页没有 offset，页变小保留已加载前缀窗口；页变大才按新页重取；当前照片不在窗口时按页对齐请求覆盖它的那一页（上限 2000 回退）。

### 验证（Lead 执行，2026-11-11）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1881 tests / 276 suites + 串行 25 tests / 4 suites 全绿；app 1070 tests / 152 suites 全绿。
- 门禁 14 项全绿：no-legacy / cleanup-ratchet（unchecked_sendable 60=60，未涨）/ layering / domain-events / domain-writes / protocol-surface --strict / duplicate-symbols --strict / test-catalog --strict / select-star --strict / preview-surface --strict / coded-errors / backlog-evidence / design-system / warnings。
- 基线记账：protocol-surface public_types 489→490（IngestUnsupportedFormats）、public_declarations 2914→2929（+15：C1 报告字段、分享 entryURL 字段、格式统计 DTO/字段）、protocol_lines 15714→15818；modules baseline 同步重写。无 public 类型删除。

### 未闭环/下一批

1. C1 R6（reject→Trash collection）未做：C1 无 reject 位，需产品决定用 Trash 容器动作还是仅色标约定。
2. 对比/Survey 自动前进仍是页内下一张；「在对比格内推进当前」需把选片规则下沉到 VM。
3. 检查器「保留/淘汰/星级」按钮仍走批量（评审允许的批量口径），如需同口径收窄另派。
4. 交付发布记录/历史/HEAD 差分/独立发布入口留待 Batch 2+。
5. S3 预签名 / WebDAV 静态入口 / browse / deselect 均为静态与单测级，真机矩阵（96 号 C1-x）仍需人工执行。
