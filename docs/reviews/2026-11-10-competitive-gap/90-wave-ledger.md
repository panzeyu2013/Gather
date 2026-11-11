# 修复台账：Wave 1（2026-11-11）

> 目标：`goal-eb78f289-3807-4129-bad0-74b03e45a5da`（推进 Wave 1–3）。
> 口径：本文件只记"已修/未修/证据/基线变更"，产品结论见 [00-synthesis.md](00-synthesis.md)，缺口明细见各分册。
> 验证纪律：**构建与测试只由 Lead 执行**（多 agent 各自编译会占满机器）；子代理只做静态实现与静态自查。

## 1. 本轮已修（Wave 1）

| 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- |
| P0-1（30 册 G1） | C1 选中读取改为 application 级 `selected variants` + `parent image.path`；删除 `on error` 吞错，失败上浮 `C1_SCRIPT_FAILED`；`select` 用 document+variants 形式 | `gather-app/Sources/GatherHost/CaptureOneBridge.swift`、`gather-core/Sources/GatherProtocol/Protocol/C1.swift` |
| P0-2（G2） | `reload metadata` 改为按选中 variant 循环；无选中报 `C1_NO_SELECTED_PHOTOS`（不盲发、不写假 ack）；新增 `CullingAPI.acknowledgeManualReload` + 同步菜单「我已在 Capture One 手动加载元数据」 | 同上 + `API/CullingAPI.swift`、`Host/APIs/LiveCullingAPI.swift`、`GatherUI/Culling/CullingSyncControls.swift` |
| P0-4（20 册 #4） | 预取接线：±1 用与显示同键的 UI 缓存预热、±2 走 `preloadPreviews`、下一张 `prioritizeThumbnail`；`isLoading` 早退改单槽 pending commit + 忙碌角标 | `GatherUI/Culling/CullingViewModel+Preload.swift`、`CullingViewModel+Actions.swift`、`CullingWorkbench*.swift` |
| 20 册 #1/#2 | 专注模式（隐藏检查器+胶片条+窗口全屏，F / 菜单 / 按钮）；真 1:1 缩放（⌘1、⌘⌥0），⌘0 修正为"适配窗口" | `CullingView.swift`、`CullingWorkbenchViewer.swift`、`Interaction/CullingFocusModeActions.swift`、`GatherAppCommands.swift` |
| P0-8（05 册 §3.1） | `.heic/.heif/.psd` 进解码白名单 + CGImageSource 整图兜底（PSD 取合成扁平图），失败抛 `unsupportedExtension` 不崩 | `GatherAnalysis/Image/RAWDecoder.swift` |
| P0-5（40 册 #2） | 导出色彩空间（sRGB/P3/Adobe RGB）、DPI（JPEG/TIFF 元数据）、输出锐化（unsharp）；`ExportOptions`/`OutputRecipe` 可选字段（旧 JSON 兼容）+ 配方→导出的透传 | `Protocol/Export.swift`、`Protocol/Output.swift`、`ExportService+Run/Plan.swift`、`Output/OutputService.swift`、`ExportView+Options.swift` |
| 05 册 §1.3（堆栈） | 堆栈管理接线：新建/加入/移出/重命名/取消堆叠（右键菜单 + 选择栏），破坏性动作走 Confirmed | `GatherUI/Gallery/GalleryStackActions.swift`、`GalleryViewModel+Load.swift`、`GalleryGrid.swift` |
| 05 册 §1.4（卷重连） | 更正原判（能力早已由 `LiveLibraryDataProvider` 接线）；补 relink 结果可见性（N 个 / 0 个匹配） | `Library/LibraryViewModel+Load.swift`、`LibraryView.swift` |
| G9（30 册） | 元数据页「待 C1 重载」时给 reload + 手动 ack，复用挑片 VM 串行队列 | `GatherUI/Metadata/MetadataSyncBar.swift` |
| G10（30 册） | 同步菜单新增「在 Capture One 中显示」（区分 open -a 兜底"可能导入"语义） | `CullingSyncControls.swift`、`CullingViewModel+Writeback.swift` |

## 2. Lead 验证证据（2026-11-11）

- 构建：`gather-core` / `gather-app` `swift build --disable-sandbox` 均 Build complete（app 11.75s，无 warning；`check-warnings.sh` PASS）。
- 测试（只跑窄 filter）：
  - core：`--filter "RAWDecoderTests|ExportServiceTests|OutputServiceTests|ExportContractTests|OutputContractTests|ErrorCodeContractTests"` → **71 tests / 9 suites passed**。
  - app：`--filter "C1BridgeWave1|Culling|StackAndVolumeWiring|LocalizationParity|ErrorLocalizationCoverage|GalleryViewModel|LibraryViewModel|C1RoundTrip|APICulling|C1StatusCapsule|CullingSyncFlow"` → **244 tests / 29 suites passed**。
- 门禁：design-system PASS；cleanup-ratchet OK（未涨）；test-catalog OK(--strict)；layering OK；coded-errors OK；no-legacy OK；select-star OK；domain-events OK；domain-writes OK；duplicate-symbols OK；preview-surface PASS；warnings PASS。

## 3. 基线变更（必须有账）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 415 → **418**；public_declarations 2460 → **2475**；protocol_lines 12625 → 12759 | Wave 1 新增：`ExportColorSpace`/`ExportSharpening`、`CaptureOneBridgeError.noSelection`、`CullingAPI.acknowledgeManualReload`、`C1RoundTripError` 上移、若干字段成员。用 `--write-baseline --allow-growth` 写入。 |
| 其余基线 | 未变 | design-system / cleanup / test-catalog 均未上涨。 |

## 4. 遗留与真机门（未完成，别当成已验收）

1. **C1 真机矩阵未跑**：脚本契约按本机 `CaptureOne.sdef`（16.7.8.16）文本钉死，仍需真机验「选 10 张 → 导入 / 写回 → reload / 无选中 → C1_NO_SELECTED_PHOTOS / 手动 Load → ack → confirm+finalize」。见 30 册 §4.1 验收清单。
2. **专注模式/⌘⌥0**：未实机点验（全屏与 ESC 互操作、组合键是否被 AppKit 吞）。
3. **预取收益未实测**：链路已接线，但"按 → 到清晰图"的秒数未测（20 册遗留）。
4. **PSD 只支持合成扁平图**；HEIC 解码失败时保持占位符不崩。
5. **输出锐化是 CPU 盒式模糊近似**（确定性、可单测），>20MP 大图多一次全图缓冲。
6. **P0-3（C1 变体级读取）** 与 **P0-6（配方编辑器）** 拆到 Wave 1.5（task-11 / task-10）。
7. **P0-7（托管式客户交付）** 留在 Wave 3（task 待建）：需要设计签名链接/口令/到期，属 L。

## 5. 下一批（已排）

- task-10：交付配方编辑器（依赖本轮 OutputRecipe 新字段）。
- task-11：C1 变体级读取（rating/色标/pick/关键词 → 导入即带判断）。
- task-12：对比多格清晰 + 3 图/Survey + 直方图/合焦键位。
- task-13：关键词库/变量/批量直改/检索覆盖。
- task-14：AI 初审接入导入 + 场景标签闭环。
- task-15：集合层级 + 集合运算 + 跨会话导入去重。
- task-16：导出/交付规格补齐（图片水印/子目录/联系表参数）。

---

## 6. Wave 2 第一批（2026-11-11 同日，task-10 / task-12 / task-11）

| 任务 | 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- | --- |
| task-10 | 40 册 #3/#6（P0-6） | 交付配方编辑器：格式/质量/长边/色彩空间/DPI/锐化/文字水印/命名模板/子目录/联系表(行列+字段+caption)/画廊(尺寸+字段) 全可编辑；新建不再硬编码 85/2048；非法值中文校验并前置拦截；预检与 OutputService 映射同源 | `GatherUI/Export/ExportViewModel+Delivery.swift`、`ExportView+Delivery.swift` |
| task-12 | 20 册 #3/#6/#7/#8 | 对比多格清晰（1–2 图全格贴可见区细节，3/4/Survey 当前+hover）；`PhotoDetailTier.budget` 按实际同屏张数动态（8192/6144/5120/4096/3200）；新增 `compare3` 与 `survey(n≤9)`；键位 裸 H/F/R/C，专注模式改 ⇧F | `Culling/CullingGrid.swift`、`CullingComparison.swift`、`CullingViewerParts.swift`、`CullingWorkbenchViewer.swift`、`Support/PhotoThumbnailView.swift` |
| task-11 | 30 册 G3（P0-3） | C1 变体级读取：一次脚本读 selected variants 的 rating/color tag/pick/keywords → `C1SelectionSnapshot`；导入 `afterCreate` 钩子拿 sessionId → 后台等 `metadata.scan` 终态 → 落 `photo_metadata_cache`（rating>0/label/keywords 并集）与 `culling_decisions`(source=imported, 仅 pick=true→keep)，人工决策整张跳过；失败降级发新码 `C1_JUDGEMENTS_UNAVAILABLE` | `GatherProtocol/Protocol/C1.swift`、`Core.swift`、`GatherApplication/Services/C1/C1ImportJudgementService.swift`、`GatherHost/CaptureOneBridge.swift`、`AppImport.swift`、`AppBootstrap.swift` |

**Lead 修复的 2 个编译/逻辑缺陷**（子代理静态自查未发现，构建/测试暴露）：
1. `CullingGrid.swift` 参数名 `columns` 遮蔽同名静态函数 → `Self.columns(for:)`（编译错误）。
2. `C1ImportJudgementService.mapColorTag(0)` 因返回类型是 Optional，`.none` 被解析成 `Optional.none(nil)` → 显式写 `CaptureOneColorLabel.none`（测试捕获）。
3. `CullingSurveyLayoutTests` 一处字符串未插值（`"p($0)"`）导致闭包参数被忽略（测试编译错误）。

### 验证证据（Lead 执行）

- 构建：`gather-core`、`gather-app` `swift build --disable-sandbox` 无 error。
- 测试：
  - core `--filter "ErrorCodeContractTests|SessionContractTests"` → 12 tests / 2 suites passed。
  - app `--filter "DeliveryRecipeEditorTests|CullingSurveyLayoutTests|ReviewFixTests|LocalizationParityTests|LayoutBudgetTests|B6bExportViewModelTests|Culling"` → **220 tests / 22 suites passed**。
  - app `--filter "C1BridgeWave2|C1BridgeWave1|CullingSyncFlow|LocalizationParityTests|ErrorLocalizationCoverageTests|GatherAppDelegateTests|DeliveryRecipeEditorTests|CullingSurveyLayoutTests"` → **96 tests / 22 suites passed**。
- 门禁（--strict 口径）：protocol-surface OK（重基线后）、design-system PASS、cleanup-ratchet OK、test-catalog OK、layering OK、warnings PASS。

### 基线变更（第二批）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 418 → **420**；public_declarations 2475 → **2487**；protocol_lines 12759 → 12811 | `C1VariantJudgement`/`C1SelectionSnapshot`、`GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE` |
| `docs/protocol-surface-modules-baseline.json` | gatherapplication 200→**203** 类型 / 1330→**1361** 声明 | 新 `GatherApplication/Services/C1/` 公开服务 |

### 遗留（第二批）

1. C1 color tag 整数序（0=None…7=Purple）按 C1 UI 顺序推定，**sdef 无枚举，需真机核对 8 个色标**。
2. 判断落库在 `metadata.scan` 之后（后台最多等 10 分钟，无进度提示）；应用在落库前退出会丢判断（重新导入可再读）。
3. 同一路径集合的并发重复 C1 导入会共用/竞争同一快照 key（第二个退化为仅文件导入）。
4. 配方 `destination` 现在双语义（绝对=旧配方原样 / 相对=交付根下子目录），协议注释仍是"绝对目录"，建议后续加 `subdirectory` 字段。
5. 联系表/画廊参数是 run 级草稿（`SettingsKey` 是穷尽枚举，持久化需单独立项）。
6. 2 图对比预算 5120→6144（判焦更实，峰值内存约 ×2）；Survey 上限 9。

---

## 7. Wave 2 第二批（2026-11-11 同日，task-13 / task-14 / task-15 / task-16）

| 任务 | 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- | --- |
| task-13 | 10 册 Top3 | 关键词库（树/改名/合并/同义词/受控值）协议+UI；补全读词库并展开同义词；元数据变量引擎 `{seq}/{client}/{year}/{month}/{day}/{filename}/{name}/{ext}/{camera}`（宽度/转义/未解析可枚举）；批量直改 `<mixed>` + 逐张预检；检索 jsonFields 11→31、搜索串 5→17 字段；FilterRuleEditor 字段目录 41 项 | `Protocol/KeywordLibrary.swift`、`MetadataVariables.swift`、`MetadataBatchEdit.swift`、`Application/Services/Keyword/`、`GatherUI/Metadata/KeywordLibrarySheet.swift`、`MetadataBatchEditorSheet.swift`、`PhotoFilterQuery.swift` |
| task-14 | 50 册 Top3 ①② | `AITriageAutoPipeline`：导入后等 scan→复用/入队 quality→等终态→生成建议→按开关 automation 应用（轮询可注入、取消/失败只收敛不阻塞导入）；场景标签写回关键词（幂等 + root 子树撤销 + 来源标记）；facet 新增 scene（keyword 子树桶）与 person（persons JOIN，按逻辑资产去重）；语义检索多选平均向量 + labels 分支接 UI；`SemanticSearchSheet` 三合一 | `Application/Services/Quality/AITriageAutoPipeline.swift`、`Semantic/SemanticKeywordService.swift`、`Semantics.swift`、`FacetQuery.swift`、`GatherUI/SemanticSearch/` |
| task-15 | 40 册 #9/#10 | 集合运算：`FilterLogic.not` + 集合/堆栈 EXISTS 子查询 + 相对日期；`AlbumAPI.combineCollections` 物化 并/交/差；跨会话导入去重（size 预筛 + checksum 全库比对，skip/coexist/replace，replace 带 .gather-prev 备份回滚）；`SessionAPI.previewIngest` 四类计数；Curation 集合运算 sheet | `Protocol/Filter.swift`、`Queries/PhotoFilterQuery.swift`、`CollectionRepo.swift`、`IngestService.swift`、`SessionIngestRunner.swift`、`GatherUI/Curation/CollectionSidebar.swift` |
| task-16 | 40 册 #5/#6/#18 | 图片水印（logo PNG，宽度比例/边距/透明度，只缩不放、超 2048 降采样、缓存）；子目录 token 规则（`{yyyy}/{MM}/{dd}/{client}/{event}/{orig}`，校验顺序稳定：unclosedToken/strayBrace/unknownToken/pathTraversal/...）；联系表与画廊参数随配方持久化（旧 run 级回落兼容），manifest 记录相对路径 | `Protocol/Export.swift`、`Output.swift`、`ExportService+Run/Plan.swift`、`OutputService.swift`、`GatherUI/Export/` |

### Lead 修掉的 7 处缺陷（子代理静态自查未发现，构建/测试暴露）

1. `IngestService.plan` 公开方法用了 internal 的 `SessionService.LibraryDuplicateTarget` → 补 public + init。
2. `AITriageAutoPipeline` switch 未穷尽 `.waiting` → 补防御分支。
3. `AITriageAutoPipeline` `"quality-(job.status.rawValue)"` 漏字符串插值 → 修。
4. `OutputServiceTests` 新用例跨 suite 调私有 `makeFixture` → 新增文件级 `makeWave2OutputFixture`。
5. `SemanticKeywordServiceTests` `#expect(xs.allSatisfy(\.keyPath))` 触发宏 rethrows 报错 → 改闭包。
6. en.lproj 缺 `词库操作失败：%@` 英文条目 → 补（Lead 收口）。
7. domain 门禁：新增发布点登记 `MetadataBatchEditorSheet`/`KeywordLibrarySheet`/`SemanticSearchSheetModel`，并在写回处补 `.metadata` 域事件。

### 子代理按回执修复的 4 处

- `CollectionRepo.visibleMemberPhotoIds` 的 SQL 插值 `\(` 丢失（near "(" syntax error）→ 修。
- 图片水印 y 基准两套坐标混用 → 显式 topDown→CG 换算 + 测试坐标口径统一。
- 子目录模板 reason 优先级/措辞（unclosedToken 先于 unknownToken）→ 修。
- `FacetSemanticDimensionTests` 断言与 fixture 冲突（p4 横跨两场景）→ 改为有区分度的反向收窄断言。

### 验证证据（Lead 执行）

- 构建：`gather-core` / `gather-app` `swift build --disable-sandbox` 无 error。
- 测试：
  - core `--filter "MetadataVariableEngineTests|…|SessionContractTests"` → **138 tests / 20 suites passed**；收口后再跑 108 tests / 16 suites passed。
  - app `--filter "LocalizationParityTests|…|ReviewFixTests|StackAndVolumeWiring"` → **358 tests / 42 suites passed**；收口后再跑 252 tests / 24 suites passed。
- 门禁（--strict 口径）：protocol-surface OK、design-system PASS、layering OK、coded-errors OK、domain-events OK、domain-writes OK、duplicate-symbols OK、select-star OK、no-legacy OK、test-catalog OK、cleanup-ratchet OK、warnings PASS。

### 基线变更（第二批 2）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 420 → **460**；public_declarations 2487 → **2718**；protocol_lines 12811 → **14492** | task-13 关键词库/变量/批量 DTO、task-14 语义/场景标签 DTO、task-15 过滤/摄取 DTO、task-16 导出/子目录 DTO |
| `docs/protocol-surface-modules-baseline.json` | gatherapplication 203→**208** / 1361→**1419** | 新服务（KeywordLibraryService / SemanticKeywordService / AITriageAutoPipeline） |
| `docs/cleanup-baseline.json` | try_optional 255 → **261**（--allow-growth 记账） | 6 处 best-effort 清理（摄取 replace 的备份/回滚删除、语义索引回填失败不阻断写回、导出临时文件清理） |

### 遗留（第二批 2）

1. **模板侧变量未接**：变量引擎已在"批量文案"落地；模板 apply/preview 仍按字面写入（预览与实际可能不一致），建议下一波接模板。
2. **图片水印错误码**复用 `EXPORT_PARAMS_INVALID + params(field/reason)`，未加专用码。
3. **旧交付配方不自动补 gallery artifact**：升级后旧配方若 artifacts 里没有 `.gallery` 不再生成画廊（不静默改用户数据）；需要一次性迁移的话另立任务。
4. **集合层级（Collection Set）未做**：需 schema 变更（表/列计数断言），单独立项。
5. **scene/person facet 在 Filtering/FacetBar 的标题**落到 default 文案；NOT/集合/相对日期目前只有 API/JSON 路径可存，FilterRuleEditor 的编辑入口未接（属 task-13 目录，下一波）。
6. **C1 color tag 整数序**仍未真机核对；C1 关键词含 `|` 会按层级解析。
7. 搜索 OR 扩到 17 字段的大库性能未测；词库补全每次读全量同义词（当前规模可接受）。

---

## 8. Wave 3 第一批（2026-11-11，task-18 / task-19 / task-21）

| 任务 | 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- | --- |
| task-18 | 30 册 G4/G5/G6/G12 | 变体级 C1 **写回**：协议新增 `writeVariantJudgements`（要求 + 默认 unsupported 降级）、`C1ColorTagMapping` 读写单一事实源；按路径→image→variants 只写目标 variant（优先已 pick，否则 position 1），写 rating/color tag/pick，**不写关键词**（keep→pick=true / reject→pick=false / unreviewed 不写），单次上限 500；写后写 durable reload-ack（口径已批准：catalog 权威，不 reload）；Session 三目录识别（Capture/Selects/Trash，扫描根=Capture、Trash 不扫、Selects 同名去重）+ 信息条标注 + Hot Folder「不检测」边界提示；UI 菜单「在 Capture One 中写回判断（变体级）」+ 失败可执行下一步 | `Protocol/C1.swift`、`GatherHost/CaptureOneBridge.swift`、`AppBootstrap.swift`（Facade）、`GatherUI/Culling/*` |
| task-19 | 20 册 #5 / 50 册 #8 | 感知级相似**评估物**（产品行为零改动）：标注集解码/校验/指纹、pair 指标与阈值曲线/推荐工作点、聚类 ARI/过度合并、FeaturePrint 与 dHash 双通道、`similarity-eval` 子命令（markdown+JSON+基线对照+`--self-test`）、本地采样脚本、决策报告（先定后测的立项门槛/阈值先验/9 类失败/成本） | `Sources/GatherTriageEval/*`、`scripts/sample-similarity-annotation.sh`、`docs/reviews/2026-11-10-competitive-gap/95-similarity-eval-design.md` |
| task-21 | 05 册 §2 | 自动化面：`gather://session/<id>`、`photo/<id>`、`import?session=`（加入已有工作区）+ 兼容旧 import；4 个 App Intents/Shortcuts 动作（经 @Sendable runtime 复用既有 API，未启动显式 runtimeUnavailable）；导出后命令钩子（模板拆参数后替换占位符、不经 shell、超时 1–600s、失败只记 Outcome/manifest）；新增 settings 键 2 个 | `GatherHost/Automation/*`、`GatherApp/GatherAutomationIntents.swift`、`GatherApplication/Services/Export/ExportPostCommandRunner.swift`、`SettingsKey.swift` |

### Lead 修掉的缺陷（3 处 + 1 处防回归）

1. `SimilarityEvalCommand.swift`：`struct SimilarityEvalCLIError`（含 `case`）→ `enum`；604 行多行字符串插值里跨行闭包 → 先算 `firstFailed` 再插值。
2. `AppBootstrap.automationImportName()` 在 @Sendable 闭包里调用 MainActor 静态方法 → 标 `nonisolated`。
3. cleanup ratchet 回涨（try_optional +9）：把 `ExportPostCommandRunner` 的 8 处、`AppBootstrap` 的 1 处 `try?` 改成 do/catch（保持指标 261 不变）。
4. tool `--self-test` 失败（推荐阈值 0.97 vs 0.9）：由 ai-reviewer 复核数学后确认**期望错**（0.99 是负样本，0.97 处 precision=0.5），新增逐点混淆矩阵断言 + 达标路径用例，并修正 cosine 容差（Float 精度），self-test 现 PASS。

### 验证证据（Lead 执行）

- 构建：`gather-core`（含 tool target）与 `gather-app` `swift build --build-tests --disable-sandbox` 无 error。
- 测试：core **57 tests / 9 suites**、app **225 tests / 40 suites** 通过（含 C1BridgeWave3 / GatherDeepLinkRoute / ExportPostCommand / GatherAutomationRuntime / 既有 C1/本地化回归）。
- 工具：`similarity-eval --self-test` → **PASS**；旧 CLI `--help` 冒烟正常。
- 门禁 12 项全绿（含 `--strict`）；cleanup 指标未涨（try_optional 261）。

### 基线变更（Wave 3 第一批）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 460 → **468**；public_declarations 2718 → **2765**；protocol_lines 14492 → **14825** | task-18 的 C1 写回/目录角色 DTO 与协议要求、task-21 的 `OutputPostCommandOutcome` |
| cleanup | 未变（261） | 新增 try? 已改为 do/catch |

### 遗留（Wave 3 第一批）

1. **App Intents 发现性**：SwiftPM 构建不生成 `Metadata.appintents`，需在 `build.sh` 组装后加 `xcrun appintentsmetadataprocessor`，否则 Shortcuts 里看不到动作（代码/运行时可验证，打包步骤未做）。
2. **C1 变体写回真机未验**：只在文本层按 sdef 钉契约；需真机确认 `variant.rating/color tag/pick` 可写、多 variant 只改目标、写后门禁放行。
3. **Selects 覆盖不完整**：重定向只扫 Capture，Selects 中与 Capture 不同名的移动文件不导入（已上 UI 提示；完整方案需索引器目录排除）。
4. **reject 往返不闭合**：C1 只有布尔 pick，reject→pick=false，而 Wave2 导入侧 false→未处理（保守不误杀）。
5. **Hot Folder 不检测**：sdef 无读取接口，仅 UI 明示「未检测」。
6. **评估工具无独立 test target**：用内置 `--self-test` 作验收点；真实数值待标注集。
7. **导出后钩子只挂整套交付**（`runRecipes` 成功后），单次 export.execute 不触发；UI 未展示 postCommand。

---

## 9. Wave 3 第二批（2026-11-11，task-17 / task-20 / task-24 / task-26）

| 任务 | 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- | --- |
| task-17 | 40 册 #1/#17（P0-7） | 交付分享：`OutputShareTransport` 抽象 + WebDAV 适配（复用既有 publisher）+ **S3 兼容传输**（SigV4 头签名、PUT/DELETE 可写探针、401/403 立即中止、404 桶不存在、5xx/网络可重试、对象默认私有）；凭据只进 Keychain（键=canonical endpoint+accessKeyID，secret 不落库/日志/share.json）；`OutputShareManifest` 统一 share.json writer；**口令门**（PBKDF2-HMAC-SHA256 100k，proof.html/js WebCrypto 同参校验、错误口令不泄露存在性、页面明示「非加密仅防随手翻阅」）+ **到期**（校样页只读过期态、明示无服务端强制）；`WebDAVPublishInput` 增可选 transport（默认 webdav 旧调用逐字兼容）；失败分类 auth/notFound/network/server/validation/localIO/unknown 汇总进 Summary；WebDAVPublishSheet 支持 WebDAV/S3 切换与 SecureField | `Services/Output/OutputShareTransport.swift`、`S3ShareTransport.swift`、`OutputSharePassword.swift`、`OutputShareManifest.swift`、`Protocol/ProofShare.swift`、`Protocol/Output.swift`、`GatherUI/Export/WebDAVPublishSheet.swift`、`LiveExportAPI.swift`（批准越界） |
| task-20 | 20 册 #11、40 册 #7 | **第二显示器**：独立 id 的 `Window`（保持 Window 非 WindowGroup，⌘N/Window 菜单语义不变）+ App 级 `CullingSecondDisplayCoordinator`；镜像桥共享同一 CullingViewModel（选择/当前照片一致），只读镜像（无手势/无评级/不调 setVisible → 无双份轮询）；主窗口关闭 → 第二屏转「主窗口已关闭」空态，重开自动恢复；**打印版面**：`PrintLayout` 纯逻辑（纸张/边距/单图 fit|custom+边框/多页分页/header-footer-pageNumber/cell-image-caption）+ `PrintDocumentRenderer` PDF（复用 RAWDecoder 栅格化、临时文件原子替换、坏图留空框）+ `PrintOptionsSheet` + `PrintSupport` 打印独占闸（已有一打印中拒绝第二个并明确提示） | `GatherApp/GatherApp.swift`、`GatherUI/Culling/CullingSecondDisplay.swift`、`GatherUI/Export/PrintOptionsSheet.swift`、`PrintRenderingPort.swift`、`GatherHost/APIs/LivePrintRenderer.swift`、`GatherApplication/Services/Export/Print*.swift` |
| task-24 | 40 册 #14/#16 | 目录迁移：库导出为 `*.gatherlib.json` 可移植包（相对路径清单，不打包原图；formatVersion 更高显式失败）；导入/合并按 photoId→checksum 两级去重 + 三种冲突策略（keepLocal/keepImported/coexist），按 newRoot 重绑定路径，单事务回滚；`keepImported` 命中既有 photoId 时 pmc/决策写回**照片行原会话**；`ExternalMetadataMigrationService` 两阶段读 XMP（不解析 .lrcat/.cos）迁移 rating/label/keywords；ControlCenter `MigrationCenterCard` 提供导出/导入/从 XMP 迁移三条入口（未接线显式提示）+ 报告与「按字段计」文案 | `API/MaintenanceAPI.swift`、`Repositories/LibraryPackageStore.swift`、`Services/Maintenance/LibraryPackageService.swift`、`ExternalMetadataMigrationService.swift`、`GatherUI/ControlCenter/MigrationCenterCard.swift` |
| task-26 | 收尾 | 真机验收清单 `96-manual-acceptance.md`（293 行，13 节 + 22 行记录表）：C1 矩阵 10 项 / 第二屏 / 打印 / Shortcuts 与 URL scheme / 翻片延迟实测 / 配方 GUI / 产物检查 / 目录迁移 / 已知未闭环 12 项 / P0-P2 分级与回滚 | `docs/reviews/2026-11-10-competitive-gap/96-manual-acceptance.md` |

### Lead 修掉的缺陷（6 处）

1. `LibraryPackageStore` 用 `.double(...)`（DBValue 无此成员）→ `.real(...)` ×2。
2. `LibraryPackageServiceTests` 构造 `MetadataWriteAttributes(rating:label:keywords:)` 参数顺序错 → 按声明顺序。
3. `PrintLayoutTests` 的 Int/CGFloat 混用（cellWidth/cellHeight 推断 + 表达式超时）→ 显式 `CGFloat` 注解。
4. `OutputShareTests` 把「签名密钥的 hex」误当 `sha256Hex(signingKey)` → 改为对 key 字节做 hex，并注明期望值语义。
5. `PrintLayoutTests` 用 `Optional<CGFloat> == 814` 字面量比较（Swift 推断成 Int 恒 false）→ `CGFloat(842 - 28)`。
6. 迁移卡片的两个写函数未发域事件 → 在函数体内分别发 `.library`/`.metadata` 并登记 `check-domain-events` 的 `MigrationCenterCard.swift`。

### 验证证据（Lead 执行）

- 构建：`gather-core`（含 tool）与 `gather-app` `swift build --build-tests --disable-sandbox` 无 error。
- 测试：core **35 tests / 4 suites**（OutputShare/WebDAVPublisher/ContactSheetPresentation/LibraryPackageService）通过；app **208 tests / 24 suites**（PrintLayout 10 + CullingSecondDisplay 5 + 本地化/交付/挑片回归）通过。
- 门禁 12 项全绿（`--strict` 口径）：protocol-surface / design-system / cleanup / layering / coded-errors / domain-events / domain-writes / duplicate-symbols / select-star / no-legacy / test-catalog / warnings。

### 基线变更（Wave 3 第二批）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 468 → **484**；public_declarations 2765 → **2870**；protocol_lines 14825 → **15441** | task-17 分享/口令/分类类型、task-20 打印 DTO、task-24 库包/迁移 DTO |
| test-catalog / cleanup | 未变（cleanup try_optional 仍 261） | 新增测试文件均带文件头注释；新代码无 try? |

### 遗留（Wave 3 第二批）

1. **预签名 URL 未实现**（当前 SigV4 头签名 + 对象默认私有）；浏览器直传需另立。
2. S3 的 URLSession 传输暂放 Application 层（留 `s3ShareTransport` 注入点，后续可移到 Host 组合根）。
3. **口令门/到期是纯前端**：页面已明示「非加密 / 无服务端强制」；file:// 或禁用 JS 时回退旧行为。
4. 发布失败分类是 reason 启发式，不是类型化错误码（不新增 GatherErrorCode 的取舍）。
5. **App Intents 打包元数据**仍未做（`build.sh` 未加 `appintentsmetadataprocessor` → Shortcuts 里看不到动作），见 task-25。
6. 打印面板可能与选项 sheet 模态叠加（实机观感待验）；联系表按钮在占用时仍显示旧文案；多页单次上限 200 张。
7. 第二屏未自动选屏/自动全屏；主窗口最小化时显示空态或最后内容。
8. 目录迁移：导入不触发重索引（缺失文件以 pending 登记）；迁移 conflicts 按字段计。
