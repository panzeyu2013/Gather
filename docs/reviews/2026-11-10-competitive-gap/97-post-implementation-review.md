# 实现后独立评审：正确性 / 完整性 / 最优性（2026-11-11）

> 评审对象：`88568372..HEAD`（`a97d3c63`，Wave1–3 + 收尾批，共 8 次提交，**213 个文件 / +30,249 行**）。
> 方法：6 名域评审员**只读**独立评审（C1 桥 / 挑片看图 / 导出交付分享 / 元数据检索迁移 / AI 语义评估 / 组织去重层级）+ Lead 交叉复核与全量构建测试；行号均以 `a97d3c63` 为准。
> 本文只记录**已定位有证据的问题**；每条都给"证据锚点 + 建议修法"。P0 已在本轮修复（见 §2 状态），P1/P2 为待修清单。

## 0. 结论

1. **主干成立**：Wave1–3 的每一项都有"服务实现 + Host 接线 + UI 入口 + 测试"，全量套件与门禁在 `a97d3c63` 上全绿（core 1807+25、app 966、12 门禁、release 组装 + App Intents 元数据）。
2. **但"边界组合"普遍不正确**：单条路径大多正确，坏在组合与失败路径——
   - **导入**：跨会话去重默认 `.skip` 且无 UI/无测试；replace 有三处独立缺陷（备份数据丢失、第二目的地必失败、DB 指纹不更新）；预检有写副作用且逐文件全量哈希。
   - **C1**：变体写回"部分成功"仍写 durable ack（门禁误放行）；scan 失败后仍落判断、后续重扫会清掉；pick/reject 实际单向。
   - **挑片**：加载期排队的按键在 flush 时按**新的**当前照片重放（可能标错照片）。
   - **分享**：share.json 上传失败 fail-open（口令/到期失效）；到期后仍能"重新下载"生成 selection.json。
   - **AI**：评估工具的"分类表现"数学退化（会误导立项决策）；"撤销本批"实为会话级清除。
3. 严重度分布：**P0 ×3（数据丢失/静默破坏）**、**P1 ×24**、**P2 ×30 左右**。P0 三条已在本轮全部修复并补回归测试（见 §2 与 §9）；P1/P2 未动代码（建议作为 Wave 4 修复批次）。

## 1. 验证基线（评审时状态）

| 项 | 结果 |
| --- | --- |
| gather-core | `test.sh core`：1807 tests / 263 suites + 25 tests / 4 suites（串行批）全绿 |
| gather-app | `test.sh app`：966 tests / 128 suites 全绿 |
| 门禁 | 12 项 `--strict` 全绿（protocol-surface / design-system / cleanup / layering / coded-errors / domain-events / domain-writes / duplicate-symbols / select-star / no-legacy / test-catalog / warnings） |
| 发布 | `build.sh` 组装成功；`check-appintents.sh` → intents(8)/shortcuts(4)/OK |

> 说明：**测试全绿 ≠ 无缺陷**——本评审的多数 P1 恰好落在"没有测试的路径"上（§6）。这正是本轮 review 的价值。

## 2. P0（数据丢失/静默破坏）

### P0-1 旧配方迁移在 settings 读失败/坏 JSON 时覆盖用户配方（✅ 本轮已修 + 回归测试）
- 证据：`GatherUI/Export/ExportViewModel+Delivery.swift` `readDeliveryRecipes` 读失败 return nil、坏 JSON 回落 defaultRecipes；`loadDeliveryRecipes` 用 `?? defaultRecipes`，随后迁移对无 marker 配方 `changed=true` 立即 persist → 一次瞬时读失败就把默认配方写回 `output.recipes`（旧实现只落内存）。
- 修法（已实施）：区分"读取失败"与"从未保存"；失败时**不赋值、不迁移、不落盘**；坏 JSON 也归为读取失败并记 warn。下次 load 重试。
- 回归测试（已加）：DeliveryRecipeEditorTests.loadFailureDoesNotOverwriteRecipes（读失败与坏 JSON 两种，断言 setInputs 为空）。

### P0-2 replace 备份固定名，崩溃遗留的备份被下一次 replace 删除（✅ 本轮已修 + 回归测试）
- 证据：`IngestService.swift`（原 `replaceExisting` 段）备份名 `dest + ".gather-prev"`，且 `if exists { try? removeItem }`；若上次替换在"移走原件之后、写新文件之前"崩溃，遗留备份是用户原件的唯一副本，下次 replace 直接删掉 → 永久丢失。
- 修法（已实施）：备份名带 UUID（互不覆盖）；执行前扫描同目标遗留备份，**发现即拒绝本张**并抛 `leftoverReplaceBackup`（提示人工确认，绝不删除）；回滚仍从备份恢复。
- 回归测试（已加）：IngestServiceTests.replaceRefusesLeftoverBackup + replaceSucceedsAndCleansBackup。

### P0-3 目录包 keepImported 回绑会清空既有照片的缓存元数据（✅ 本轮已修 + 回归测试）
- 证据：`LibraryPackageService.swift:171-178` 对同 photoId 既有行 rebind；`:219-228` 用 `MetadataCacheInput` 只带 rating/label/keywords/descriptive，其余字段 nil → `MetadataCacheRepo.upsert` 写 NULL；包格式本身不含 EXIF/date/GPS（`MaintenanceAPI.swift:78` 附近 DTO）。后果：用户选"保留导入"后拍摄时间/相机/GPS/尺寸被清空；未勾选关键词时 keywords 被写成 `[]`。
- 修法（已指派）：新增"只 UPDATE 迁移字段"的窄路径（GatherPersistence 新方法），rating 仅 >0 时写、keywords 空不覆盖、label/descriptive 仅包内有值时写、EXIF 列一律不动；补 keepImported 保留 EXIF/import 开关关闭的测试。

## 3. P1（正确性/安全性缺陷，按域）

### 3.1 Capture One 桥（评审 A）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| A1 | 变体写回部分成功仍写 durable ack → confirm/finalize 门禁误放行 | `CaptureOneBridge.swift:873-881`（written>0 即 ack）；`DeliveryCoordinator.swift:430-436,557`；测试 `C1BridgeWave3Tests.swift:84-97` 还把该行为钉成期望 | 仅 `notFound.isEmpty && skipped == 0` 时 ack；改测试期望 |
| A2 | scan 失败/取消/超时后仍落 C1 判断，后续成功重扫会整行 upsert 清掉 | `C1ImportJudgementService.swift:229-246,254-255`；`MetadataCacheRepo.swift:241-252`（INSERT 不带指纹）；`MetadataExtractionService.swift:108,238` | 仅 succeeded 落库；或落库后补写指纹；超时改重试 |
| A3 | pick/reject 宣称可逆实际单向（reject 写 pick=false，重读 false→unreviewed） | `CaptureOneBridge.swift:909-912`；`C1ImportJudgementService.swift:46-53` | 改 keep-only 并改文案，或用 C1 原生 reject（待真机核）；补往返用例 |
| A4 | 跨页选择下变体写回静默截断（只从当前页过滤 selectedPhotoIds） | `CullingViewModel+Writeback.swift:376-403`；`CullingViewModel+Grid.swift:64-83` | 提示"仅当前页 N/M"，或按 id 拉全量 |
| A5 | Session 三目录重定向只覆盖菜单"导入文件夹"，新建工作区面板绕过（Trash 复活仍在），而 UI badge 宣称"仅导入 Capture" | `AppBootstrap.swift:489-494,945-955`；`NewSessionSheet.swift:181,320`；`CullingInfoBar.swift:73-83` | 重定向前移共享 helper；badge 与实际一致 |

### 3.2 挑片 / 看图 / 第二屏 / 打印（评审 B）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| B1 | **排队按键 flush 时按新的当前照片/选择集重放 → 可能标错照片** | `CullingViewModel+Actions.swift:8-11,379-391`；`+Load.swift:218-223,313` | 队列存 photoId/selection 快照，不一致即丢弃 |
| B2 | 单图"自定义尺寸"忽略"离白"，与面板参数矛盾 | `PrintLayout.swift:154-170` | custom 也夹进 contentRect |
| B3 | 第二屏只画 2560 基准位图、无细节贴片 → 共享 zoom>1× 时糊，旁屏判焦失效 | `CullingSecondDisplay.swift:266-281` | 按共享布局挂 detail tile，或把镜像 zoom 限到 1× |

### 3.3 导出 / 交付 / 分享（评审 C）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| C1 | **share.json 上传失败 fail-open**：非 401/403 失败仅记录后继续传文件，proof.js 拿不到 share.json 即解除门槛 → 口令/到期全失效 | `WebDAVPublisher.swift:228-250`；`S3ShareTransport.swift:293-320`；`GalleryBuilder.swift:777-782` | strict 模式 share.json 失败即中止发布 |
| C2 | 到期后仍可"重新下载"生成 selection.json（只 setLocked 未禁 submit） | `GalleryBuilder.swift:600-603,647-662,738-740,771-772` | 增加 expired 标志，submit 早退，到期 disable download |
| C3 | 命令钩子在失败/部分失败、以及 dedupe 缓存命中时仍执行（注释称成功后执行） | `LiveExportAPI.swift:255-278` | 条件加 `manifestError == nil && totalFailed == 0`；避免缓存重放 |
| C4 | S3 SigV4：无 STS session token；canonical header 只 trim 未折叠连续空格 [需对照规范] | `S3ShareTransport.swift:80,105-162,389-425`；`ProofShare.swift:189-224` | 补 x-amz-security-token + header 规范化 + 固定向量 |
| C5 | **命令钩子是同步阻塞实现**（Lead 复核新增）：`Thread.sleep` + `waitUntilExit` 在 async 路径里阻塞协作线程最长 600s | `ExportPostCommandRunner.swift:191-228` | 改 terminationHandler + continuation + Task.sleep 超时 |

### 3.4 元数据 / 检索 / 迁移中心（评审 D）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| D1 | 库包 relativePath 无穿越/空根校验 → 恶意/损坏包可把照片行指到 newRoot 之外 | `LibraryPackageService.swift:283-287,131-133`；`MaintenanceAPI.swift:78` | standardize + hasPrefix 断言、拒绝绝对/..；newRoot 空用包 session.sourcePath |
| D2 | XMP 迁移遇 Lightroom Rating=-1 触发 `photo_metadata_cache` CHECK(0..5)，整批事务回滚、无报告 | `ExternalMetadataMigrationService.swift:77-85`；`SchemaCurrent+DDLDomain.swift:94` | evaluate 阶段丢弃/钳制并计入 skipped |
| D3 | 批量直改 `diskKnown` 恒 true（diskDescriptive 把 nil 抹成空结构）→ 导入/仅缓存照片产生幻影冲突被静默跳过 | `LiveMetadataAPI.swift:448-453`；`MetadataBatchEdit.swift:249-255,349` | diskDescriptive 返回可选/加 sidecar 标志 |
| D4 | 模板 preview 与 apply 在"读盘失败"时不同源（preview 视未知、apply 标 failed） | `MetadataTemplateService.swift:374-381` vs `:201-202,242-245` | preview 复用 apply 错误分类并禁用应用 |

### 3.5 AI / 语义 / 评估（评审 E）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| E1 | **评估工具"分类表现"表数学退化**：只统计同组 pair → burst precision 恒 1.0、separate precision 恒 0；照常输出会误导决策 A | `SimilarityMetrics.swift:131-143`；`SimilarityEvalCommand.swift:649-658` | 只输出有定义的量，或跨组 pair 按两侧类别复制 |
| E2 | **"撤销本批"实为会话级清除**：UI 不传 photoIds，服务 nil=全会话；batchId 未持久化 | `SemanticSearchSheetModel.swift:111-116`；`SemanticKeywordService.swift:261-274` | 返回并回传本批 photoIds，或改文案为会话级并显示张数 |
| E3 | person facet 桶按姓名精确分组，选中后走 `person contains` LIKE → facet≠网格、点"张三"带出"张三丰" | `FacetQuery.swift:235,243`；`LibraryViewModel.swift:121-123` | 新增 `person_name eq` 精确字段映射 |
| E4 | 自动初审的 generate/apply 在 MainActor 同步执行（非 Sendable TriageService）；且无 triage_enabled 前置判断 | `AppBootstrap.swift:832-841`；`AITriageAutoPipeline.swift:130-145` | 专用 serial actor/job 第三段承载；pipeline 增加 triageEnabled 依赖 |
| E5 | 找相似/标签检索结果只显示 photoId UUID，无缩略图/点击 → 回不到网格 | `SemanticSearchSheet.swift:18-21,147-168` | 照 Gallery 语义面板加 nameFor/onSelect |

### 3.6 组织 / 去重 / 层级（评审 F）
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| F1 | **跨会话去重对"未回填 checksum"的库内照片完全失效**（懒索引常态） | `PhotoRepo.swift:423-431`（只查 checksum != ''，无 archived 过滤）；`SessionService.swift:246-258` | 返回 size 命中且 checksum 空的行，runner 懒算+回填（限流） |
| F2 | 预检（previewIngest）违反只读契约：经 photoChecksums 回写 updateChecksum；且对每个源文件无条件 SHA-256 | `SessionIngestRunner.swift:105-109`；`SessionService.swift:288-296`；`IngestService.swift:378-383` | preview 只读索引；仅 size 命中候选才哈希 |
| F3 | replace 成功后库内照片行 checksum/size 不更新（INSERT OR IGNORE，忽略既有 filepath） | `SessionIngestRunner.swift:61-67`；`PhotoRepo.swift:315` | replace 成功后 stat+updateChecksum |
| F4 | replace × 第二目的地必然失败（replace 的 destPath 在 destinationRoot 外，secondDestinationPath 抛错） | `IngestService.swift:603-604,814-824` | replace 项跳过第二份或按源根相对镜像 |
| F5 | replace 可命中 archived/`_rejects` 照片（fingerprint 无 archived 谓词） | `PhotoRepo.swift:431`；`IngestService.swift:394-401` | fingerprint 加 `archived_at IS NULL` |

### 3.7 Lead 交叉复核新增
| # | 问题 | 证据 | 建议 |
| --- | --- | --- | --- |
| L1 | **导入去重的用户可见性缺失**：`IngestSheet` 不传 duplicatePolicy（默认 skip）、不显示 libraryDuplicates/librarySkipped/replaced，也无 `previewIngest` 入口 → 跨工作区导入被静默跳过 | `IngestSheet.swift:189-196,115-124`；`SessionIngestInputs.swift:62-92`；`LiveSessionAPI.swift:72-77`（preview 无 UI 调用） | 摄取面板加"重复处置"三选一 + 预检计数 + 结果显示分类 |
| L2 | 第二目的地副本 `verify: false`（备份不可信）——评审 40 册 #11 仍未修 | `IngestService.swift:614,631,715,729` | 第二副本也校验和（或至少记入报告） |
| L3 | 摄取去重/预检/replace **零单测**（grep 无 IngestDuplicatePolicy/replaceExisting/previewIngest 测试） | 测试目录 grep 实证 | 补性能与失败路径测试（见 §6） |

## 4. P2（设计债/性能/可维护性）摘要

- **API 面膨胀**：Protocol public types 415→**485**、declarations 2460→2880（两次 --allow-growth 记账）。不少 DTO 只服务单模块（如 Print*/Eval 选项），可降为 internal 或收敛到 app 侧。
- **C1**：`C1SessionDirectoryResolver.dedupe` 无生产调用点；自动 reload 不先 select 写回路径 → 必然 noSelection 被抑制；MetadataSyncBar"待重载"用 gateEnabled 而非 ack 缺失；skipped/malformed 只日志；Hot Folder 提示无条件下展示；依赖 hidden `selected variants` 无回退；latestScanJob 排序余量；重定向会话名/source 偏差；G9 按钮依赖 workspace?.culling。
- **挑片**：预取双通道对同一图整解 2 次（GUI 2560 + 宿主 2560 丢弃）；miss 判定不查磁盘缓存；`NSScreen.main` 取 backingScale（多屏错档）；第二屏 9 格共用 limit=4 解码闸；`pageVersion` 每次决策重置 120ms debounce → 快速连按预取饿死；网格布局忙碌角标隐藏；actual-pixels 窗口 resize 后不重锚；打印临时 PDF 不删、200 张静默截断、边框几何/自定义纸越界、无横向方向；Dock 重开主窗口被第二屏挡住。
- **导出/分享**：钩子 command/outputTail 入 manifest（可能落盘密钥）；transport 切换不清空 secret；S3 本地读/配置错误被标 NETWORK 并重试；WatermarkLogoCache 无 mtime/上限；`OutputSharePublisher` 抽象生产未用（三处重复校验）；无新参数时 share.json 转义与 proof 页 DOM 非逐字节一致。
- **AI/评估**：averageVector 未 L2 归一化（范数加权）；scene 与 keyword 共用 `keyword_path` → 同维剔除过宽；baseline 硬编码 0.95 且 k=4 vs k=10 口径不齐；`PairBuild.skipped` 静默丢样本；标注集未查跨组重复照片；CSV 坏行静默跳过；pixels9x8 复制实现有漂移风险；超时不取消 job/入队异常被吞；固定 dedupeKey + inheritCheckpoint 潜在 stale photoIds；广播/撤销状态缺口；undo 未分组逐张 flush；plan items 无上限。
- **组织/层级**：`libraryPhotoDuplicates` "最早"非全局顺序且全表入内存；会话内去重被绕过；preview newCount/totalCount 口径错；空 NOT 组静默无约束；facet 同维剔除对 NOT 不生效；并/差集顺序依赖侧栏顺序；历史非规范名 rename 无法规范化；折叠 key 跨工作区共用。
- **元数据**：迁移事件发到旧 session（新建 session 后不刷新）；规则编辑器字段目录缺 person/volume/directory/has_duplicates（restore 后编辑不完整）；导入失败统一包装成"诊断导出失败"。

## 5. 已确认成立的关键契约（给信心）

- C1：四段 AppleScript 对象归属/参数形式与 16.7 sdef 一致（`:244/:1081/:1541/:1852-1855/:1956-1966`）；失败不伪造 ack；G3 读失败可降级；afterCreate 异常隔离；color tag 0→`.none` 非 nil。
- 挑片：第二屏真只读（无写 API/不调 setVisible）；预取取消链完整；打印坐标方向与 ContactSheetRenderer 同约定；打印独占双闸；排队 flush 时序自洽。
- 导出/分享：SigV4 主链路与 AWS 固定向量一致；命令钩子无 shell 注入（split→argv）；子目录 token 校验与执行期路径兜底；凭据/口令只进 Keychain + manifest 哈希、PBKDF2 参数前后端一致、错误口令通用文案；到期/口令/子目录校验边界有测试。
- 元数据：模板 apply/preview 共用展开与 planner、未解析整批拒绝；预览 token 绑定且 apply 校验 STALE；批量 <mixed> 同源；检索字段 allowlist + 全绑定参数 + escapeLike；关键词操作单事务。
- AI：automation apply 不覆盖人工/客户决策（human 跳过 + revision 复核 + 幂等）；job dedupeKey 复用；标签映射幂等；多选检索种子排除/阈值有测试；scene/person facet 按逻辑资产去重。
- 组织：NOT = OR 后取反语义与参数顺序正确（含空组）；容器 EXISTS 空集边界正确；集合运算顺序契约与 rename 子树单事务/环检测；旧配方迁移幂等且不动自定义 artifacts。

## 6. 测试覆盖缺口（按"缺口即风险"排序）

1. **导入去重/replace/preview 全零测试**（备份回滚、第二目的地交互、DB 指纹刷新、archived 目标、预检副作用）。
2. 迁移：settings 读失败/坏 JSON 不落盘（P0-1 回归）、keepImported 保留 EXIF（P0-3）、relativePath 穿越/空根。
3. proof.js 无 JS 级测试：到期后 download→submit、share.json 404 fail-open、gate 绕过。
4. 打印：`PrintDocumentRenderer` 零测试（页数/坏图占位/取消后临时文件清理）；第二屏只读/画布零测试。
5. 排队按键无"目标照片已变"用例（对应 B1）。
6. facet：keyword_path+scene 交叉、person 桶→网格一致性、__global__ 下新维。
7. 评估：分类表语义（对应 E1）、baseline/primary pair 数一致性、CSV 坏行、ARI 边界、datasetHash 稳定。
8. AI pipeline：同会话二次触发/checkpoint 继承、triage_enabled=0、入队失败。
9. SigV4：显式 endpoint 带 path、header 内含空格、STS token 向量。
10. C1 真机矩阵（脚本语义只能文本断言）。

## 7. 建议修复批次（Wave 4，按 ROI 排序）

1. **P0 收尾 + 数据安全**：P0-3（已派）、P0-1/P0-2 回归测试、D1 路径穿越、A1 ack 条件、C1 share fail-open、C2 到期提交。
2. **正确性高频路径**：B1 队列快照、F3/F4/F5 replace 三连、A2 scan 竞态、E2 撤销范围、E3 person facet 口径、C3 钩子条件、C5 钩子异步化。
3. **用户可见完整性**：L1 摄取去重 UI + 预检、F1 checksum 懒回填、E5 检索结果可操作、B3 第二屏细节、D3 批量直改幻影冲突、E4 triage 后台化。
4. **测试补齐**：§6 的 1/2/3/4/5/7。
5. **设计收敛（可延后）**：API 面收敛、预取双通道合并、C1 自动化自闭合、评估指标归一化、P2 列表清理。

## 8. 局限

- 纯静态评审：未在真机点击 GUI、未跑 C1 16.7、未验证 S3/WebDAV 真实网络、未做性能 profiling。
- 行号以 `a97d3c63` 为准；P0 修复会移动后续行号。
- 评审员结论均带证据锚点，但"建议修法"是按最小改动给出的方向，不是完整设计。

## 9. 本轮修复记录（P0）

| P0 | 修复 | 回归测试 | 验证 |
| --- | --- | --- | --- |
| P0-1 配方迁移覆盖 | `loadDeliveryRecipes`：读失败/坏 JSON 不再回落默认配方、不迁移、不落盘；解码失败改返回 nil 并记 warn | `DeliveryRecipeEditorTests.loadFailureDoesNotOverwriteRecipes` | app 967 tests / 128 suites 全绿 |
| P0-2 replace 备份丢失 | `IngestService`：备份名带 UUID；执行前扫描同目标遗留备份，发现即抛 `leftoverReplaceBackup`（不删除）；回滚仍从备份恢复 | `IngestServiceTests.replaceRefusesLeftoverBackup` / `replaceSucceedsAndCleansBackup` | core 1814 tests / 263 suites + 25 / 4 全绿 |
| P0-3 keepImported 清空缓存 | `MetadataCacheRepo.updateMigrationFields` 窄更新（COALESCE，只动 rating/label/keywords/iptc_json/cached_at）；`rebindExisting` 按导入开关与包内有值才写；路径校验拒绝绝对/`..`，空 newRoot 回退 `package.session.sourcePath` | LibraryPackageServiceTests +5 例 | 同上 |

基线记账：`protocol-surface` 因新增 `MetadataCacheRepo.updateMigrationFields`（GatherPersistence public 方法）+1 声明，以 --write-baseline --allow-growth 更新；cleanup / design-system / test-catalog 未变。

## 10. 复核结论

- P0 修复后：**core 1814 tests / 263 suites + 25 / 4、app 967 tests / 128 suites 全绿；protocol-surface/cleanup/design-system/test-catalog 门禁全绿**。
- P1/P2 未动：本报告的 §3/§4 仍是**待修清单**，建议按 §7 的 Wave 4 顺序推进（先正确性高频路径，再用户可见完整性，最后设计收敛）。

## 11. 全量修复执行记录（Wave 4a / 4b / 4c，2026-11-11）

用户要求「全量修复所有问题」后，按本报告 §7 的顺序分三批执行（每批 Lead 统一跑全量套件 + 12 门禁后提交）：

| 批次 | commit | 范围 | 结果 |
| --- | --- | --- | --- |
| Wave 4a | `110d583a` | §3 全部 P1：C1 A1–A5、挑片 B1–B3、导出 C1–C5、元数据 D2–D4、AI E1–E5、组织 F1–F5 + L1/L2 | 全修 + 回归测试 |
| Wave 4b | `b7ba51b4` | §4 P2：C1 诊断链、挑片性能/打印卫生、分享可测性与脱敏、AI facet/dedupeKey/广播/评估、组织 NOT/差集/折叠、打印渲染与第二屏只读测试 | 全修 + 测试补齐 |
| Wave 4c | `cdf961b2` | 对抗审计发现的「半修」：legacy share=nil × 新 proof.js 回归、A2 判断无重试、F1 候选 LIMIT 500、E2 撤销 scope 不持久、C4 AWS 官方向量 | 修复中/已修 |

关键取舍（明确记录，不再视为未修）：
- C1 reject 不写回（C1 16.7 无 reject 位；UI 已说明），pick 只写 keep。
- A2 改为「仅 succeeded 落库」后失败即待重试（4c 补自动重放），不再静默覆盖。
- proof.js 对 http(s) 缺 share.json fail-closed；legacy 未声明分享策略的包保留旧回退（4c 修回归）。
- 跨会话去重默认 .skip 且 UI 可见（重复处置三选一 + 预检计数）；恢复场景需 .coexist。
- 撤销 scope 持久化最小实现（settings 上一批），跨设备/清除设置后不可撤销。
- 未做：集合层级 schema parent_id（沿用名称路径约定）、服务端托管分享（保持 S3/WebDAV + 客户端口令/到期）、感知相似度结论（依赖人工标注集）。

验证（每批提交前）：core / app 全量测试 + protocol-surface/design-system/cleanup/layering/coded-errors/domain-events/domain-writes/duplicate-symbols/select-star/no-legacy/test-catalog/warnings 全绿。
