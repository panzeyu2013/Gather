# Wave 5 收口审计（2026-11-16）

> 目的：对 2026-11-11 复核报告的 2 条 P0 风险 + 22 条 P1 做逐项闭环对账，并列出剩余 P2 / 明确不做 / 待决策。
> 基线：Wave 5 Batch 1–8（3af5f491 / d1782603 / f8a4baec / 9ddf68ac / 8a77a5d9 / 6f265649 / 625cc9fe / 本批）。
> 验证：core 1964 tests / 289 suites + 串行 25/4；app 1256 tests / 183 suites；14 项门禁全绿；每批一行 commit 可回滚。

## 1. P0 风险（2 条）

| # | 风险 | 状态 | 证据 |
| --- | --- | --- | --- |
| X1 | C1 变体写回可能改错 variant | 已闭环 | Batch1：写前回读 variant 数，>1 不猜目标、整条跳过且不写 ack；UI 提示回 C1 选变体或走 XMP |
| X2 | S3 交付件客户不可访问 | 已闭环 | Batch1：SigV4 query 预签名 GET（AWS 固定向量测试）+ 客户链接 UI；对象仍默认私有；Batch3 发布记录/HEAD 差分/独立入口 |

## 2. 22 条 P1 对账

| 组 | 项 | 状态 | 落地批次 |
| --- | --- | --- | --- |
| C1 A1 | 写回/选中作用域=当前集合，无 browse | 已闭环 | Batch1（browse 重试 + 报告） |
| C1 A2 | 判断只有选中导入一条通道 | 已闭环 | Batch7（菜单/Dashboard/深链 source=capture-one 统一）+ Batch8（GatherLink 带 source） |
| C1 A3 | 淘汰不可表达 / 关键词污染 | 已闭环（红标约定） | Batch1（停写 culling:* 关键词）+ Batch6（reject→C1 红标，显式确认） |
| C1 A4 | 变体级写回不可控 | 已闭环 | Batch1（写前回读/多变体跳过） |
| Culling B1 | 对比/Survey 决策目标错位 | 已闭环 | Batch1（默认只写 current，显式开关批量） |
| Culling B2 | 浏览连续性 | 已闭环 | Batch1（布局切换保留当前/网格定位）+ Batch2（每会话状态恢复） |
| Culling B3 | RAW 无嵌入 JPEG 快档 | 已闭环（opt-in） | Batch4（RAW≤4096 内嵌预览≥75%；查看器/预取启用，导出/质量仍真解） |
| Culling B4 | C1 已调色预览无提示 | 已闭环 | Batch6（C1 有调整徽标 + 检查器段） |
| Delivery C1 | 交付发布闭环 | 已闭环 | Batch1（链接）+ Batch3（记录/HEAD 差分/独立入口） |
| Delivery C2 | 迁移包丢组织资产 | 已闭环 | Batch3（v2：堆栈/智能相册/保存查询/人物绑定/重复组留档；v1 兼容） |
| Delivery C3 | 导入不是一次配置 | 已闭环 | Batch3（IngestPreset + 预检/失败全量/重试 + 摄取后 AI 初审） |
| Metadata D1 | IPTC 字段/受控值缺 | 已闭环 | Batch2（4 交付字段 + 4 张 CV + Picker/校验） |
| Metadata D2 | GPS 只读 / 无改拍摄时间 | 已闭环 | Batch5（GPS/时间写入 + 反查地名）+ Batch7（内嵌读侧 + 批量时间） |
| Metadata D3 | 模板/词库 I/O；同义词检索；双源静默 | 部分闭环 | Batch2（同义词检索）+ Batch5（模板/词库导入导出）；遗留：JPEG 有 sidecar 时内嵌 IPTC 清不掉 / 非 JPEG 只写 sidecar / 双源静默取 sidecar 未单独改造 |
| AI E1 | 导入即初审默认路径不成立 | 已闭环 | Batch2（5 入口 + 超时不取消 + 状态可见） |
| AI E2 | 人脸是隐式前置 | 已闭环 | Batch2（缺失观测入队 face.analyze 且不阻塞，状态可见） |
| AI E3 | 分组分析不随初审跑 | 已闭环 | Batch6（duplicate.scan + navigation.analyze 编排，失败不阻塞） |
| AI E4 | 场景/最佳帧产品化 / People Filter | 部分闭环 | Batch4（组视图/最佳帧/一键保留 + People Filter）+ Batch7（标签中文化）+ Batch8（入口上移）；遗留：自动关键词写回未做（按手动写回为产品口径） |
| Organize F1 | 无物理文件夹树/浏览即读 | 已闭环 | Batch4（懒加载目录树/按目录筛选）+ Batch8（新建工作区/摄取入口 + 外部卷） |
| Organize F2 | 无批量重命名/文件移动 | 已闭环 | Batch4（PhotoAPI preview/rename/move + sidecar/回滚） |
| Organize F3 | 自动化第二层缺失 | 已闭环（Shortcuts/URL） | Batch5（查询照片 + 写评级/色标/保留）+ Batch4（既有 4 深链/4 intents）；遗留：CLI/AppleScript 字典按边界另立项 |
| Organize F4 | 格式白名单漂移 | 已闭环 | Batch1（PhotoFileTypes 单一白名单 31 项 + 跳过可见） |

## 3. 剩余 P2 / 明确不做 / 待决策

### 3.1 仍需代码工作（按优先级）

1. C1 插件往返：GatherLink 目前仍 Open With 单向；role/Edit/Publish 入口、安装/版本/兼容诊断未做（P2）。
2. C1 关键词写回：淘汰已用红标约定，但关键词 → C1 apply keyword 仍未接（P2）。
3. Metadata 双源：JPEG 有 .xmp 时内嵌 IPTC 清理、非 JPEG 只写 sidecar、双源不同值静默取 sidecar（P1 尾巴，需单独设计写策略）。
4. AI 自动关键词：场景标签只做显示/检索/手动写回；自动写回与中文同义词写回未做（产品口径）。
5. JPEG 内嵌 slow path：embedded_fast_path=0 时写回可能镜像相机 EXIF 到 XMP；内嵌 GPS/时间写侧只走快路径。
6. 发布端点：内置仅 WebDAV/S3；FTP/SFTP/网盘/社媒未做（可用导出后钩子替代，P2）。
7. 剩余 P2：联系表纸张/横向、画廊字段、客户成片 ZIP、导出元数据精简、屏幕色彩管理/软打样、幻灯片/多窗口/拖出、C1 500 张自动分批、收藏夹/虚拟副本边界声明等。

### 3.2 明确不做（ROADMAP/产品决策）

- RAW 显影/编辑/图层、色彩编辑；视频/PDF/AI/EPS；云同步/多人/客户账号；Windows/移动端/Web；自然语言/CLIP 文搜 UI；解析 C1 .cos/LR .lrcat；完整 DAM/跨工具目录迁移；服务端托管交付平台；服务端强制口令/到期；catalog 级容器/跨工作区集合 schema 迁移；虚拟副本/版本组 schema；幻灯片/多窗口/外部编辑器（专业外设集成层，按立项处理）。

## 4. 真机验收清单（人工执行，本轮未跑）

沿用 96-manual-acceptance.md §1–§12，并补充 Wave5 新增项：

1. C1：多变体写回跳过与提示；browse 跨集合重试；select 前 deselect；淘汰红标动作；C1 有调整徽标；GatherLink 插件带 source=capture-one 后判断/来源标生效。
2. 交付：S3 预签名链接客户可打开与到期；WebDAV 静态入口；发布记录/HEAD 差分二次发布跳过；部分失败重试。
3. 元数据：GPS/拍摄时间 sidecar 写入与读回；反查地名（MapKit，网络/无结果）；批量时间偏移预演/应用；模板/词库导入导出；JPEG 内嵌 GPS/时间读回。
4. 挑片：对比/Survey 默认只写当前 + 批量开关；布局切换/回到页签状态恢复；RAW 内嵌快档 256/512/1024 与 2560 回退；第二屏/打印/Shortcuts（既有）。
5. 组织/自动化：目录树筛选/外部卷/新建工作区/摄取；批量重命名/移动（sidecar/回滚）；组视图/最佳帧/People Filter；Shortcuts 查询与写评级、gather://rate。
6. AI：导入即初审（5 入口）、超时不取消、人脸缺失入队、自动分组、场景标签中文检索/写回、状态卡。

## 5. 验证汇总

- 构建：gather-core / gather-app swift build --build-tests --disable-sandbox 均通过。
- 测试：core 1964 / 289 + 串行 25 / 4；app 1256 / 183；全绿。
- 门禁 14 项全绿（含 warnings）。
- 基线：protocol-surface 513 types / 3109 declarations / 17138 lines；cleanup 不涨；design-system 不涨。
- 每个 batch 独立 commit，工作树可回滚。
