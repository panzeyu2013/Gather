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

## Batch 4（task-18 ~ task-21）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-18 | 物理文件夹树 / 按目录浏览 | ingest-export | 资料库左栏「文件夹/集合」页签 + 懒加载目录树；点目录应用 directory 前缀筛选并即时提交；面包屑/清除/刷新/Finder/复制路径；根=当前筛选工作区 sourcePath |
| task-19 | 导入后批量重命名 + 文件移动 | c1-fix | PhotoAPI 新增 previewRename/renamePhotos/movePhotos（不新开域）；token 预演 + 冲突策略 + 两阶段改名 + sidecar 随行 + 组内失败整组回滚；移动经 AssetRepo relocate 事务化更新库路径；Gallery 右键 + sheet |
| task-20 | 场景/连拍最佳帧视图 + People Filter | ai-similarity | 挑片组视图（导航组收窄、lead 置顶、quality 排序、最佳徽标、一键保留最佳/淘汰其余）；人物筛选（已加载窗口客户端投影 + 精确 eq）；Gallery facet 补 person + 保存查询还原 |
| task-21 | RAW 嵌入 JPEG 快档 | culling-viewer | decodeScaled 对 RAW≤4096 先取内嵌预览（≥75% 才用，否则回退整解）；查看器/预取 opt-in，导出/打印/质量分析默认仍真解；纯决策函数 + 伪装 RAW 测试 |

### 关键设计取舍

- RAW 快档：allowEmbeddedPreview 默认 false，仅 RAWImageDecoder / ImagePreloadService 传 true；导出/联系表/画廊/质量/模型分析保持完整解码，避免交付件采样到内嵌 JPEG。
- 重命名：模板不允许路径分隔符（改名不是移动）；{seq:3} 的冒号按 token 内语法处理，不算路径分隔符；扩展名缺失补原扩展名、显式改扩展名拒绝。
- 移动：目标必须是用户选择的绝对目录；同批内部撞名一律拒绝；sidecar 有兄弟消费则复制、否则移动。
- 文件夹树：只读目录、不 stat 图片/不算张数；「用此目录新建工作区/摄取」因宿主回调不接受指定目录暂未接线，保留 Finder/复制路径。
- 组视图/人物：人物筛选当前是已加载窗口的客户端投影（服务端 CullingFilters 无 person 条件），UI 已明示；keep-best 两次 batchUpdate 形成两步撤销。
- 设计门禁：新增 UI 全部改用 GatherFont/GatherMetrics token，design-system 指标不增长。

### 验证（Lead 执行，2026-11-11）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1946 / 286 + 串行 25 / 4 全绿；app 1138 / 162 全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线记账：protocol-surface public_types 501→511、public_declarations 3040→3094、protocol_lines 16574→16827（FileOps DTO + 协议方法）；cleanup 未涨；design-system font.systemSize 15=15、literalSpacing 87<89。
- Lead 修：RAW 快档默认关闭（导出不被采样）+ viewer/preload opt-in；rename 模板 {seq:N} 冒号误判；l10n 73 键 + Burst/Scene scanner 冲突；design token 回归；测试 actor 隔离/optional 运算符；protocol 基线。

### 未闭环/下一批

1. 文件夹树右键「新建工作区/摄取到此工作区」未接线（宿主回调只接受外壳选择器）。
2. 挑片人物筛选只覆盖已加载窗口；服务端 CullingFilters/CullingPageQuery 无 person 条件（下批扩协议）。
3. keep-best 两次 batchUpdate = 两步撤销；组视图当前只在挑片页。
4. RAW 真机（CR3/NEF/ARW/DNG）内嵌尺寸/方向/2560 回退需人工抽查。
5. Batch 5：GPS/拍摄时间、模板/词库导入导出、自动化查询/写评级、发布端点扩展、剩余 P2。

## Batch 5（task-22 ~ task-24）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-22 | GPS 编辑/反查 + 改拍摄时间 | metadata-search | MetadataAPI 增 applyGeoAndDate/diskGeoDate（默认实现 + 盘上回读校验，不谎报）；SidecarXMP Patching 写 exif:DateTimeOriginal/GPSLatitude/GPSLongitude 并写后 verify；编辑器「位置与时间」分区 + MapKit 反查地名（CLGeocoder 在 macOS 26 已废弃）；JPEG 内嵌目标显式禁用并说明 |
| task-23 | 模板与词库导入/导出 | c1-fix | UI 层 MetadataTransferService：模板 JSON 导出/导入（同名跳过/覆盖预览 + Confirmed）；词库 CSV 导出/导入（只增路径/覆盖同义词，不删除、不移动层级）；坏行/空文件/超 2000 行显式拒绝 |
| task-24 | 自动化第二层 | c1-interop | runtime 增 queryPhotos/applyDecisions；Shortcuts 增「查询照片」「设置照片评级/标记」；URL gather://rate?session&photo…&rating/label/pick；未启动/非法参数可读错误；原 4 动作与 4 路由保留 |

### 关键设计取舍

- GPS/时间：写入走既有 attributeWriter + 交付队列，服务层额外盘上回读（AttributeWriter.attributesMatch 不含 GPS/时间）；读回不一致 → failed + uncertain（XMP_WRITE_VERIFICATION_FAILED）。
- JPEG 内嵌目标（xmpPath==filepath）暂不支持 GPS/时间：写侧 SidecarXMP 与内嵌写器语义不同，编辑器显式禁用而不是假成功。
- 反查地名只填 city/state/country，不回写坐标；无对应地名/取消/网络失败均有可见文案。
- 模板/词库导入不改 core 协议：复用 templates/templateFields/saveTemplate/createKeyword/setKeywordSynonyms；词库 CSV 同义词用分号+反斜杠转义。
- 自动化：查询用 PhotoAPI.search（keywords contains_any / rating gte），写判断用 CullingAPI.batchUpdate，不新造查询语言；URL 与 Shortcuts 共用同一 runtime。
- 批量时间调整 UI 仍单张（API 已支持 photoIds 数组）；清空 GPS 需 MetadataWriteAttributes 增加 clear 信号（未做）。

### 验证（Lead 执行，2026-11-16）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1953 / 288 + 串行 25 / 4 全绿；app 1189 / 171 全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线记账：protocol-surface public_types 511→513、public_declarations 3094→3109、protocol_lines 16827→17020（MetadataGeoDate DTO/方法 + automation runtime DTO/错误 + 深链路由）。
- Lead 修：SidecarXMP verify 误用 MetadataField.dateCreated/location → .descriptive；MetadataGeoDateService 缺 import GatherProtocol；gather://rate 空 photo 语义（空串=missingPhotoIds）；41 条 l10n 缺键 + 1 条斜杠/顿号不一致；测试替身空串 dateTaken 归一化。

### 未闭环/下一批

1. JPEG 内嵌 GPS/时间读侧映射未接线（MetadataAttributes.embeddedAttributesFromParse 需加 exif 三项），编辑器对 JPEG 内嵌目标仍禁用。
2. 批量时间偏移 UI、GPS 清空信号、写入后缓存投影刷新（facet/只读面板滞后到下次 scan）。
3. 模板/词库导入格式与 Lightroom 兼容 CSV、模板 2000 上限提示未做。
4. 自动化无 CLI/AppleScript 字典（仍按边界另立项）；Shortcuts 查询返回为 dialog 摘要，无可落盘结果。
5. Batch 6：C1 R6/插件诊断、AI 分组自动/场景标签中文化、文件夹树右键入口、发布端点扩展、剩余 P2、真机清单。

## Batch 6（task-25 ~ task-27）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-25 | C1 收尾：淘汰红标 + 预览调整提示 | c1-interop | CullingAPI.writeRejectedColorTags：对 reject 照片在 C1 只写色标红（覆盖色标，不写 pick/rating/关键词/ack，多变体跳过）；同步菜单确认弹窗与报告；查看器/检查器「C1 有调整」徽标（ImageIO 预览不含 C1 调整，读取失败静默隐藏） |
| task-26 | AI 初审自动分组分析 | ai-similarity | 新增 ensureGroupArtifacts：quality 成功后、generateTriage 前跑 duplicate.scan（JobService，15min 成功/活跃复用，dedupeKey 带 nonce）与 navigation.analyze（既有 NavigationAPI，已有组不重算）；60s 有界等待，失败只记日志继续初审 |
| task-27 | 文件夹树新建工作区入口 | ingest-export | FolderTreePanel 右键「用此目录新建工作区…」→ LibraryView onCreateWorkspace → RootView 设置 NewWorkspaceRequest(folderPath:) 并切 Dashboard；复用预填目录 sheet；空/不可读行不出现菜单项；摄取入口仍留后续批 |

### 关键设计取舍

- C1 淘汰：C1 16.7 无 reject 位，采用显式红标约定；只改色标、不写其它判断；多 variant 不猜目标；动作需确认且文案明说覆盖语义。
- C1 调整提示：复用既有 adjustmentHints；仅 c1Installed 时读、≤4MB；失败/未接线静默隐藏，不影响看图。
- AI 分组：duplicate 走 JobService（不改 job 类型）；navigation 无 job 类型，直接调 NavigationAPI；两者失败互不影响，初审不被拖停；60s 到点 job 留后台，本轮可能缺组比较理由，下次导入可补。
- 文件夹树：只做「新建工作区」预填，不直接创建；摄取依赖挑片 VM，留后续批。

### 验证（Lead 执行，2026-11-16）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1956 / 288 + 串行 25 / 4 全绿；app 1222 / 177 全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线记账：protocol-surface public_types 513（gatherapplication 261→262，AITriageGroupArtifactsOutcome）、public_declarations 3109（gatherapplication 1786→1788）、protocol_lines 17020→17066；test-catalog 增长按脚本允许（@Test 3203 / @Suite 408）。
- Lead 修：Batch6 新增 15 条 l10n en 条目；protocol 基线重写；全量构建/测试/门禁。

### 未闭环/下一批

1. CaptureOneBridgeFacade / C1RoundTripCoordinator 未转发 writeRejectedColorTags（默认 .unsupported）；生产 UI 走 LiveCullingAPI 正常，facade 路径待补。
2. AI 分组失败原因仅日志；AITriageStatusStore.Phase 未扩「分组分析未完成」，状态卡暂不显示。
3. 文件夹树「摄取到此工作区」未做（IngestSheet 依赖挑片 VM）。
4. Batch 7：场景标签中文化/自动关键词、发布端点扩展（FTP/SFTP/网盘）、C1 插件安装/诊断面、JPEG 内嵌 GPS/时间读侧、剩余 P2、真机验收清单。

## Batch 7（task-28 ~ task-30）

| task | 域 | owner | 结论 |
| --- | --- | --- | --- |
| task-28 | C1 判断入口统一（A2） | c1-interop | C1ImportCoordinator 下沉到 AppImport；菜单/Dashboard（source=capture-one）/深链 source=capture-one 共用快照→暂存→建库后落库；普通 local/Shortcuts 不变；失败不影响导入 |
| task-29 | AI 场景标签中文化 | ai-similarity | SemanticLabelCatalog（56 英文标签 + 11 中文别名）；中文输入反向映射英文检索；结果/写回预览显示中文，落盘路径仍 AI|场景|<英文> 可逆；未收录中文提示换英文 |
| task-30 | JPEG 内嵌 GPS/时间读侧 + 批量时间调整 | metadata-search | embeddedAttributesFromParse 补 dateTaken/latitude/longitude（XMP 优先、显式空阻断原生回退、原生 EXIF/GPS 兜底）；编辑器解除 JPEG 内嵌禁用；批量编辑器时间偏移/设为时刻 + 预演 + Confirmed |

### 关键设计取舍

- C1 入口：判断快照按「归一化路径集合」暂存，避免 await 交错把 A 的判断应用到 B 会话；快照+fallback 双失败时深链静默降级为仅按文件导入（日志可见），菜单路径仍上浮错误码。
- 场景标签：中文只影响显示/输入映射，XMP 关键词保持英文路径，保证可逆与既有照片兼容；不做第二层中文同义词写回。
- 内嵌 GPS/时间：present-but-empty 阻断原生回退（显式清空不得被相机值复活）；写侧内嵌快路径能回读 exif:*；旧 embedded_fast_path=0 路径对相机已有日期可能写后校验显式失败，不谎报。
- 批量时间：绝对时刻一次 applyGeoAndDate(photoIds 数组)；偏移因每张目标时间不同逐张调用（上限 200）；固定 UTC 墙上时间，DST 不敏感。

### 验证（Lead 执行，2026-11-16）

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1964 / 289 + 串行 25 / 4 全绿；app 1248 / 182 全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线：protocol-surface 513 types / 3109 declarations / 17138 lines（Batch7 无 public 增长，--strict 直接过）；test-catalog 按脚本允许增长。
- Lead 修：CreateSessionOutcome 字段改 package（Host 桥读取）；GatherAppDelegate 测试补 coordinator.capturePaths + 去掉错误的 importSource 断言；MetadataGeoDate 测试插值 bug（GEO_(index) 重复路径）；场景标签 4 条 en 译文非法引号/含中文；C1Dashboard 桥套件串行化；SemanticSearchSheetModel trailing-closure warning；批量时间失败断言 fixture。

### 未闭环/下一批

1. GatherLink 插件 URL 仍缺 &source=capture-one（Host 已就绪，coplugin 不在 scope）；插件安装/诊断面未做。
2. 深链快照+fallback 双失败静默降级（仅日志）；AI 分组失败原因仍只在日志（AITriageStatusStore.Phase 未扩）。
3. 批量时间偏移是逐张调用（200 上限），无单批事务；写后 GPS/时间缓存投影不刷新（编辑器重开读盘正确）。
4. 场景标签未做自动关键词/中文同义词写回；内嵌 GPS/时间 slow path 写回可能镜像相机 EXIF 到 XMP（读侧一致性取舍）。
5. Batch 8：发布端点扩展、剩余 P2、真机验收清单更新、最终收口台账。
