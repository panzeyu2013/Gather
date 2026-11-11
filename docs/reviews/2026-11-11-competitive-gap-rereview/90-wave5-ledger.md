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

## Batch 2（task-11 ~ task-14）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-11 | AI 初审端到端（E1/E2） | ai-similarity | Host 侧 AITriageAutoScheduler 统一 5 个导入入口（菜单/Finder、C1、Dashboard 新建、加照片、Shortcuts）；索引/质量等待按 progress 续期，超时只停止等待不取消 job；控制中心状态行可见；缺人脸观测时入队 faceAnalyze 且不阻塞 |
| task-12 | 元数据：IPTC 字段 + 受控值 + 同义词检索 | metadata-search | 新增 4 个交付字段（instructions/eventIdentifier/modelReleaseID/propertyReleaseID）与 4 张受控词表 + Picker/校验；keyword/keyword_path 过滤接整词同义词展开 |
| task-13 | 浏览状态恢复 | culling-viewer | 新增 CullingViewStateStore：按 session 存/恢复 scope/filters/sort/layout/density/当前照片/参考槽/胶片条/检查器；0.5s 节流 + 离开 flush；定位不到回退首张 |
| task-14 | 元数据收口 | metadata-search | embeddedDescriptiveFields 补 4 字段（JPEG 内嵌写后校验可读）；IIM 2:40 Special Instructions；FilterRuleEditor/搜索串收录 4 个新字段 |

### 关键设计取舍

- AI 超时：job 不取消，继续后台跑；状态行显示「质量分析仍在后台继续」；索引等待 6× 预算（约 30 分钟）、质量按 progress 续期（hardLimit 约 2h）。
- 人脸前置：只做「缺观测则入队 face.analyze，不等待」；similarity/duplicate 自动分组留后续批。
- 元数据字段：表驱动唯一真相源；imageCreator 因 PLUS 结构为 struct/multi 未做；release status 的 PLUS CV 站点损坏，本轮只做 ID 文本不做状态词表校验。
- 受控值：只在 UI 层校验 + 写盘归一化（countryCode 大写）；批量面板/模板仍自由文本（下一批）。
- 浏览状态：每 session 的查看状态存 UserDefaults（非 settings 用户偏好）；多选/待定队列/决策目标语义不持久化。

### 验证（Lead 执行，2026-11-11）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1902 tests / 280 suites + 串行 25 / 4 全绿；app 1098 tests / 156 suites 全绿。
- 门禁 14 项全绿（含 warnings，CLANG_MODULE_CACHE_PATH 指定后）。
- 基线记账：protocol-surface public_types 490→491（IPTCControlledVocabulary）、public_declarations 2929→2948（+19：受控值类型/4 字段/新描述符）、protocol_lines 15818→16154。

### 未闭环/下一批

1. 摄取（IngestSheet→ingest）未接 AI 初审：WorkflowRegistry 不在 task 作用域，留 Batch 3。
2. XMPPacketReader 的 IIM-only fast-path 未补 2:40，外部只写 IIM 的老文件在 fast-path 读不到 instructions（XMP 通道正常）。
3. 受控值只在单张编辑器生效；批量面板/模板仍自由文本。
4. 存量 qname 与 IPTC 2025.1 不一致（Iptc4xmpExt vs plus:ModelReleaseStatus）未动，需单独立项做兼容迁移。
5. 浏览状态定位预算 2 万张，超出按找不到回退首张；参考对比模式不持久化。

## Batch 3（task-15 ~ task-17）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-15 | 交付发布二期 | bridge-organize | 发布成功写 .gather-share-publish.json（history + files size/mtime/etag）；WebDAV/S3 先 HEAD 差分，未变跳过并计数；交付页新增「发布已生成的交付包…」独立入口 + 最近 5 次历史 + 客户链接 |
| task-16 | 导入一次配置 | ingest-export | IngestPreset（改名模板/第二目的地/校验/重复策略/metadataTemplateID）存 settings + Picker/保存/删除/回填；预检目标路径与冲突样例、失败全量展开 + 只重试失败项、第二目的地复制计数；摄取成功且 registered>0 调度 AI 初审 |
| task-17 | 迁移包组织资产 | c1-fix | 包格式 v2：stacks/smartAlbums/savedSearches/personBindings/duplicateGroups 五段；旧 v1 缺段兼容；导入按 photoId 映射重建容器并重写 criteria 引用，未映射 skipped，重复组只留档；收尾自动入队 metadata.scan |

### 关键设计取舍

- 发布记录只在 result.isSuccess 时写（部分失败不覆盖上一次可用基线）；WebDAV 生产 transport 不返回 PUT 响应头，ETag 缺失时用 Content-Length + 本地 stat 兜底（proof.html 可能每轮重传，保守正确）。
- 导入预设：ingest.presets 是用户内容（reset 保留），ingest.last_preset 是偏好；metadataTemplateID 只持久化/回填，未接线导入时套模板（后续批）。
- 迁移包：face cluster id / 堆栈折叠状态不可移植，显式 skipped 并在报告/UI 标注；smartAlbums 全库导出、savedSearches 按作用域还原。
- AI 初审摄取入口：用 SessionAPI 装饰器（TriageSchedulingSessionAPI）而非 WorkflowRegistry；以后新增绕过 rootDeps.session 的摄取入口需再接。

### 验证（Lead 执行，2026-11-11）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1921 / 282 + 串行 25 / 4 全绿；app 1112 / 157 全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线记账：protocol-surface public_types 491→501、public_declarations 2948→3040、protocol_lines 16154→16574（发布历史/迁移段/导入预设 DTO）；cleanup try_optional 261→260（收紧，非增长）。
- Lead 修：重复 stacks 声明、测试 async NSLock、孤儿/缺失 l10n、默认值断言、SavedSearchRepo 列表语义、entry? 造成的 try_optional 假阳性命名。

### 未闭环/下一批

1. 发布记录部分失败不写、WebDAV PUT ETag 缺失、S3 链接 TTL 仍 24h。
2. metadataTemplateID 未在摄取后应用；批量面板/模板的受控值仍自由文本。
3. 摄取入口 AI 调度依赖 SessionAPI 装饰器；WorkflowRegistry 层未统一。
4. XMPPacketReader IIM-only fast-path 仍缺 2:40（外部 IIM 老文件在 fast-path 读不到 instructions）。
5. 发布历史只在同一交付目录可见；跨目录/跨机器无全局历史（不做服务端）。
