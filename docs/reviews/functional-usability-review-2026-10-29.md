# Gather 功能性与易用性全量评审（用户视角 + 开发者视角）

- 日期：2026-10-29
- 对象：分支 `features`，HEAD `c77c3a57`（工作区干净）
- 方法：静态代码核对 + 4 路只读子评审（挑片/图库、导入/导出/元数据/人脸/设置、核心服务、开发者体验）+ 实测门禁与测试
- 未做：GUI 实机点击、Capture One 实机联动、真实照片集质量评估
- 结论：**未发现 P0；发现 9 个 P1、14 组 P2（约 25 个具体问题）、10 项 P3 级打磨项。**
  工程底座明显强于同类单人项目；风险集中在“主入口的后续路径”“批量选择的作用域”“长任务的可控性”“默认重置/写回的破坏范围”和“文档与实现漂移”。

> 严重级别口径
> - **P0**：数据丢失、崩溃、主流程完全不可用且无规避。
> - **P1**：主流程在一类常见场景下不可用、会把决策写到错误对象、不可逆地丢用户数据，或错误范围被严重低估。
> - **P2**：可用但体验/一致性/可发现性明显受损，或需要开发者绕路。
> - **P3**：打磨、文案、文档、工程卫生。

---

## 0. 一页结论

### 0.1 最该先修的 9 件事（P1）

| # | 问题 | 用户后果 | 关键证据 |
|---|---|---|---|
| P1-1 | “导入文件夹”把目录拆成文件清单，建出 `sourcePath == ""` 的工作区 | 之后无法整目录重扫、无法摄取、目录监听不启动；与 ⌘N 新建工作区行为不一致 | `GatherAppDelegate.swift:192-196`、`AppImport.swift:57-76`、`IndexerService+Scan.swift:36-38` |
| P1-2 | 原生导入失败只写日志 | 点“导入文件夹”后界面毫无反应，无原因、无重试 | `AppImport.swift:100-102` |
| P1-3 | 摄取面板：无进度/取消、原始错误上屏、`runModal`、无来源目录时必然失败 | 大卡导入像卡死；失败原因不可读；在文件导入会话里是死胡同 | `IngestSheet.swift:94-99,120-122,147-149,152-178`、`LiveSessionAPI.swift:62-69` |
| P1-4 | 人脸写回预览不随绑定/解绑/合并失效 | 把过期关键词写回 XMP；确认框里的“N 项/N 张”也是旧数字 | `FaceKeywordingViewModel+Review.swift:19-28`、`+Writeback.swift:56-64`、`FaceWritebackStep.swift:24-35` |
| P1-5 | “恢复默认”清空元数据模板、交付配方、批次撤销历史，文案未提；语言选择器与实际界面不一致 | 一次点击不可逆丢用户产物；英文界面显示中文选中值 | `SettingsConfirmations.swift:31`、`SettingsService.swift:92-105`、`SettingsViewModel+Loading.swift:136-145` |
| P1-6 | 胶片条普通点击只改当前照片、不清空多选 | ⌘选 3 张后点第 4 张再按 P/X，实际写的是前 3 张 | `CullingFilmstrip.swift:134-139`、`CullingViewModel+Actions.swift:325-328,299-309` |
| P1-7 | ⌘A 全选整个范围后，批量决策静默只落已加载页 | 头部显示“已选 5000 张”，实际只改 200 张，无跳过说明 | `CullingGrid.swift:97`、`CullingViewModel+Grid.swift:55-77`、`+Actions.swift:245-247,299-309` |
| P1-8 | 相似组决策显示“已加载子集”的组员数，服务端却按完整组淘汰；且无二次确认 | 显示“相似组 · 2 张”，实际淘汰屏幕外 28 张 | `CullingInspector.swift:363-374,477-480`、`CullingService+Commands.swift:707-742` |
| P1-9 | 网格布局整条 infoBar 消失，同步/写回/重置入口随之消失 | 批量挑片后无法写回 XMP/确认同步，必须自己发现切回单图 | `CullingWorkbench.swift:36-51`、`CullingInfoBar.swift:97-137` |

### 0.2 最值得保留的 6 件事

1. **类型化同进程 API**：16 个域协议 / 134 个方法，无字符串命令路由；UI 不 import 持久化层，分层由 `check-layering.sh` 与 `--explicit-target-dependency-import-check error` 守住。
2. **破坏性动作的确认文化**：`Confirmed<T>` 只在确认分支构造；挑片/导出/人脸/人物/相似度都有确认弹窗与取消文案，且有测试覆盖。
3. **真撤销栈与冲突处理**：挑片自建历史栈（服务端持久化）、写回引擎的备份/冲突/重启恢复，比“只在前端保留 undo”可靠。
4. **本地化基础设施**：`L10n` 值类型 + 渲染期语言 + 1,748 条英文表 + 代码 key ⊆ en 表 + 错误码↔文案双向契约测试。
5. **任务与门禁**：`JobService` 的租约/心跳/取消宽限/checkpoint；12 个 `check-*.sh` + @Test/@Suite/断言 ratchet；本次实测全绿。
6. **视觉与无障碍底子**：DesignSystem 语义色（浅/深/高对比四态）、reduceMotion、空/错态带重试、缩略图有文件名/星级/决策的 accessibility label。

---

## 1. 评审范围与方法

### 1.1 覆盖

- 界面：`GatherUI` 的全部页面/设计系统/支撑目录（Dashboard、Library、Gallery、Culling、Similarity、Duplicates、FaceKeywording、Persons、Metadata、Export、Settings、Shell、Interaction、DesignSystem、Support…）。
- 宿主：`GatherHost` 的 AppImport、AppDelegate、SessionWorkspaceFactory、SidecarXMPProvider、Embedded、Live*API。
- 核心：`GatherApplication/Services` 的 Culling/Ingest/Export/Metadata/Similarity/Duplicate/Face/Triage/Job/Maintenance/Session。
- 契约：`GatherProtocol/API` 的 16 个协议、输入/输出、错误码；`GatherPersistence` 的 schema 与仓储只做抽查。
- 工程：`scripts/*.sh`、`desktop/native/build.sh`、`.github/workflows/ci.yml`、README/docs/ROADMAP。

### 1.2 实测

- 12 个门禁逐条执行，全部 exit 0（含 `check-docs --strict`、`check-test-catalog --strict`、`check-protocol-surface --strict`）。
- 测试：`SWIFT_TEST_FLAGS="--disable-sandbox ..." ./scripts/test.sh all` → exit 0；core **1419 + 24 = 1443 tests / 216 suites**，app **762 tests / 89 suites**。
  本机 DSH 沙箱下 SwiftPM 自带 sandbox 会失败，故加了 `--disable-sandbox`；这不是仓库缺陷。
- 环境：macOS 27.0.1、Xcode 27.1、Swift 6.4；包声明 macOS 26+/Swift 6.2+。

### 1.3 说明

- 本报告不重复 `docs/reviews/` 已记账且已确认无新增后果的历史问题；对“已知但仍有用户可见后果”的项会明确标注。
- 焦点、嵌套面板、视觉布局三类问题无法只靠静态代码 100% 判定，文中会标“需 GUI 复核”。

---

## 2. 功能地图（逐项结论）

| 功能 | 用户视角 | 开发者视角 | 主要问题 |
|---|---|---|---|
| 工作台 / 首跑 | 视觉完整、空态好；主 CTA 的后续路径断裂 | VM 拆分清晰，错误态有重试 | P1-1、P1-2、P2-12 |
| 导入 / 摄取 | 入口深、无进度、失败不可读 | 服务与 UI 语义耦合 `sourcePath` | P1-1/P1-3、P2-10 |
| 图库 / 灯箱 | 浏览/筛选好；无键盘、多选无动作 | 查询与选择分离，逻辑清楚 | P2-2 |
| 挑片 | 核心能力最强（undo/对比/批量）；选择语义 3 个 P1 | 历史栈/服务端校验扎实；三套快捷键已漂移 | P1-6/7/8/9、P2-3/4 |
| 相似度 | 预设/阈值/取消/写回完整 | 结果档位与写回预览耦合 | P2-9、P1-8 |
| 重复 | 非破坏、推荐、确认 | 组/成员状态双源 | P2-8 |
| 人脸 / 人物 | 三步向导与门控好；人物库缺整理动作 | 服务端能力强于 UI | P1-4、P2-7 |
| 元数据 / IPTC / 模板 | 单张编辑严谨；批量反馈弱 | 补丁/失败/撤销设计好 | P2-5/6 |
| 技术建议（Beta） | 默认安全、可撤销 | Trie 语义与人工优先做得深 | 无 P1；入口与术语可再打磨 |
| 淘汰移出 | 非破坏、变体一起、skipped 分项 | 服务端展开逻辑完整 | 无 P1 |
| 导出 / 交付 / WebDAV | 两套引擎同页、缺“所选”、失败不可操作 | 计划单一来源；交付缺确认 | P2-1 |
| 设置 / 维护 / 备份 | 备份/恢复/诊断完整；reset 范围被低估 | 维护 API 干净 | P1-5、P2-11、P3-9 |
| 任务中心 | 持久化/取消/重试；假成功 | Bool 返回值无消费者 | 开发者 §6.3 |
| 本地化 | 基础设施强；单复数/术语有洞 | key 即中文、parity 测试好 | P2-14 |
| 开发者体验 | — | 分层/门禁/测试强；文档与 API 索引弱 | §6 |

---

## 3. P1（主流程 / 错误写入 / 数据丢失）

### P1-1 从“导入文件夹”进入会建出没有来源目录的工作区

**证据链**

1. `GatherAppDelegate.swift:186-196`：面板把所选目录递归枚举出照片，只要非空就返回 `.files(...)`，而不是 `.directory(...)`。
2. `AppImport.swift:57-76`：只有“恰好一个目录”才走 `sourcePath` 分支；文件清单走 `filepaths` 分支，`sourcePath` 为 nil。
3. `LiveSessionAPI.swift:244-247` + `SessionService.swift:288-295`：`sanitizeSessionSourcePath` 在 `sourcePath` 为空时直接返回空串。
4. 后果：
   - `IndexerService+Scan.swift:36-38`：`requestedPaths == nil` 时无 sourcePath 直接抛 `noSourcePath`；工作区后续无法“整目录重扫”。
   - `LiveSessionAPI.swift:62-69`：摄取目标必须在 `session.sourcePath` 内；空 base 时任何目标都被拒。
   - `SessionWorkspaceFactory.swift:96-100`：sourcePath 为空不启动 `SessionDirectoryMonitor`，Finder 新增照片不会自动进库。
5. 同一应用里 `DashboardViewModel+Actions.swift:24-25` 的 ⌘N 新建工作区走的是正常目录分支，两个入口行为不一致。

**用户影响**：首屏主按钮“导入文件夹”建出的工作区可浏览、可挑片，但“加照片/重扫/摄取”这条后续路径断掉；用户通常会在几天后才发现，且没有界面提示。

**修法**

- 面板选择的是目录时，**始终**返回 `.directory`（或同时把目录作为 `sourcePath` 传给 `session.create`，让 `sanitizeSessionSourcePath` 校验）；文件清单只用于“显式多选文件”的入口。
- 对历史 file-scope 工作区：控制中心的“扫描索引”改为“重新选择来源文件夹”，或提供“为工作区指定根目录”的修复入口。
- 补契约测试：目录导入后 `session.sourcePath` 非空，且 `metadata.scan` checkpoint 为空（目录全树）。

**验收**：首屏“导入文件夹”选择一个含 10 张 RAW 的目录 → 工作区详情 sourcePath 非空；在 Finder 加一张 → 目录监听/重扫能发现；摄取目标默认 `<source>/_ingest` 可执行。

---

### P1-2 原生导入失败完全静默

**证据**：`AppImport.swift:100-102`

```swift
} catch {
    GatherLogger.log("native import failed: \(error)", level: .error)
}
```

不 post `importCompleted`、不弹 toast、不写可见错误。对比成功路径 `AppImport.swift:89-99` 会 post 通知，`RootShellOverlay.swift:30-56` 会展示失败计数。

**用户影响**：数据库忙、权限、路径失效、schema 不匹配时，点“导入文件夹”界面没有任何变化；用户只会重复点击，且日志入口在 UI 里不可见（见 §6.5）。

**修法**：catch 中 post 一条失败通知（携带 `CommandError`），由 RootView 出 error toast；toast 带“查看日志/导出诊断包”动作。成功但 0 张也应有明确反馈。

**验收**：注入一个必失败的 `sessionAPI.create`（如只读 DB）→ 界面出现可读错误 + 重试/诊断入口。

---

### P1-3 摄取面板：死胡同、无进度/取消、原始错误、阻塞式面板

**证据**

- 入口只有挑片检查器里的“摄取照片…”：`CullingInspector.swift:186-189`；文件菜单只有“导入文件夹/从 C1 导入”，没有“摄取/从存储卡导入”。
- 无 sourcePath 的会话：`IngestSheet.swift:110-119` 提示“无法确定会话目录，请手动选择目标文件夹”，但手选任何目录都会被 `LiveSessionAPI.swift:62-69` 拒绝（目标必须在 sourcePath 内）——形成死胡同。
- 长任务：`IngestSheet.swift:94-99` 只有“开始摄取”被禁用，`run()`（:126-150）无进度回调、无取消；服务端 `IngestService.execute` 是同步循环。
- 错误：`IngestSheet.swift:121,148` 用 `String(describing: error)` 直接上屏；`result.failed.first?.message`（:87-90）是中文自由文本；`LiveSessionAPI.swift:128` 把 `sourcePath` 塞进 `photoId` 字段，第三方无法按码处理。
- 三个“选择…”按钮用 `NSOpenPanel.runModal()`（:157,166,175），而仓库在 `NewSessionSheet.swift:127-136` / `ExportViewModel.swift:298-301` 已明确改为非阻塞 `begin()`，注释还写着“本仓已弃用”。

**用户影响**：64GB 卡导入时界面静止、无法中止；失败只显示一段英文/中文混杂的诊断；在文件导入工作区里，按提示操作也永远失败；sheet 内的嵌套 modal 面板可能被遮挡或阻塞主线程。

**修法**

1. 摄取任务化（job + progress + cancel），或至少 `onProgress` + 取消检查点；结果按 `{sourcePath, destPath, code, detail, retryable}` 返回。
2. 错误统一走 `CommandErrorText.resolve`；原始诊断只进 `.help`/日志。
3. 三个面板改异步 `begin`。
4. 无 sourcePath 时禁用入口并给出“先为工作区指定根目录”的动作，而不是引导用户手选必败路径。
5. 入口上移到文件菜单/工作台（“从存储卡摄取…”），而不是只藏在挑片检查器。

**验收**：1000 张导入可见进度并可取消；失败项可按码统计；无 sourcePath 时入口不可用且有修复按钮。

---

### P1-4 人脸写回预览不随绑定变化失效，会把过期关键词写回 XMP

**证据**

- 只有 `previewWriteback()` 会赋值 `preview`：`FaceKeywordingViewModel+Writeback.swift:20-23`。
- `bind` / `unbind` / `merge` / `split` / `removeMember` 成功后只 `await reload()`：`FaceKeywordingViewModel+Review.swift:19-28,55-67,85-91`；`reload()` 不碰 `preview`（`FaceKeywordingViewModel.swift:223-245`）。
- 写回直接用 `preview.items`：`FaceKeywordingViewModel+Writeback.swift:56-64`。
- UI 只要 `preview != nil` 就继续展示旧预览：`FaceWritebackStep.swift:24-35`。
- 确认框用**当前** `boundClusters.count` 与**旧** `preview.items.count/affectedPhotos` 拼在一起：`FaceWritebackStep.swift:9-13`。

**用户影响**：解绑某簇（文案承诺撤销已写入的人脸关键词）后再点“确认写回”，旧关键词会被重新写回；新绑定的角色不会写入；确认框的影响范围不可信。这是“用户以为在修正，实际在恢复错误数据”。

**修法**：任何簇/绑定/成员变更成功后置 `preview = nil`（并清 `writebackResult`）；或给预览加签名（簇版本/绑定指纹），确认与执行前比对，不一致则要求重算。补一条“解绑 → 写回”的回归用例。

**验收**：绑定 A → 生成预览 → 解绑 A → 预览消失/失效；直接走确认流时必须重新预览，且写回项不含 A。

---

### P1-5 “恢复默认”清空用户模板/配方/批次历史，确认文案未说明；语言状态不同步

**证据**

- 确认文案只说“模型路径、推理后端、缓存与写回参数等；不会删除照片或 XMP 文件”：`SettingsConfirmations.swift:31`。
- 默认值集合包含 `output.recipes`、`metadata.templates`、`metadata.applyBatches`、`backup_dir`、`ui_language`：`SettingsService.swift:92-105`。
- `LiveSettingsAPI.swift:49-55` 的 `reset()` 全量写回 defaults。
- `applyResetSettings` 只改本地 `language` 变量，不写 `languageStore`：`SettingsViewModel+Loading.swift:136-145`；对照 `setLanguage`（:55-75）会写 store。

**用户影响**：一次“恢复默认”不可逆地删除自建元数据模板、交付配方、批次撤销历史、备份目录；英文界面点完后选择器显示“简体中文”，整窗仍是英文，重启后才切换。

**修法**：reset 白名单排除用户数据键（templates/batches/recipes/backup_*/language 是否保留需产品决定）；或在弹窗逐项列出“将删除 N 个模板、N 条配方、N 条撤销历史”并二次确认。`applyResetSettings` 同步 `languageStore.set(...)`。

**验收**：建 2 个模板 + 1 条配方 → 恢复默认 → 弹窗明确列出将删除的数量；确认后模板/配方保留（或按产品选择删除但可导出备份）；语言选择器与界面一致。

---

### P1-6 胶片条普通点击不清空多选，P/X 会写进旧选择

**证据**

- `CullingFilmstrip.swift:134-139`：普通点击走 `viewModel.selectCurrent(asset.photo.id)`。
- `CullingViewModel+Actions.swift:325-328`：`selectCurrent` 只改 `currentPhotoId`，不动 `selectedPhotoIds`。
- `CullingViewModel+Actions.swift:299-309`：`commit` 优先 `targets = visibleSelection`。
- 缩略图只区分 current/selected，没有“即将批量写入”的提示：`CullingFilmstrip.swift:118-131`。

**用户影响**：⌘点选 3 张后普通点击第 4 张，再按 P/X，实际写的是前 3 张；用户以为在给当前照片做决策，可能误淘汰/误保留。撤销可救，但批量误操作不易察觉。

**修法**：普通点击同时 `selectedPhotoIds = [id]`（与 `gridClick` 的普通点击一致）；或在查看器旁常驻“当前 / 批量 N”指示，并让 `commit` 在没有显式批量模式时只作用当前照片。补一条“多选后单击另一张再 P”的用例。

**验收**：⌘选 3 张 → 单击第 4 张 → 按 X → 只有第 4 张变淘汰；头部选择计数归 1。

---

### P1-7 ⌘A 全选整个范围后，批量决策静默只落已加载页

**证据**

- `CullingGrid.swift:97`：⌘A → `selectAll`。
- `CullingViewModel+Grid.swift:55-77`：`selectAllInScope` 把服务端返回的整个范围 id（最多 20,000）写入 `selectedPhotoIds`，超限时只提示“已选中前 N 张”。
- `CullingViewModel+Actions.swift:245-247`：`batchUpdate` 再与 `page?.assets`（已加载页）求交。
- `CullingViewModel+Actions.swift:299-309`：`commit` 只提交 `visibleSelection`；`batchUpdate` 的 notice 只报实际写入数（:272-278）。
- `CullingGrid.swift:239-241`：头部仍显示全量“已选 N 张”。

**用户影响**：全选 5,000 张后按 X，只有当前页 200 张被改；界面先显示“已选 5000 张”，再显示“已更新 200 张”，没有“其余 4,800 张未处理”的说明。用户会以为批量决策已覆盖全范围，导出时才发现大量未处理。

**修法**：二选一并在 UI 明示：
1. 对完整选择分块执行（服务端单批上限内分批，带进度/取消），或
2. 把选择集收敛到可见页并明确提示“已跳过屏幕外 N 张”。

至少要把“已选 5000 / 已更新 200”改成可解释的结果，并保留可续做的入口。

**验收**：全选跨 3 页 → P → 要么 5000 张全部落库（分批），要么界面明确“仅当前页 200 张，已跳过 4800 张”。

---

### P1-8 相似组决策按完整组淘汰，但 UI 只显示已加载子集且无确认

**证据**

- `CullingInspector.swift:365`：标题 `l10n.format("相似组 · %lld 张", currentGroupAssets.count)`。
- `CullingInspector.swift:477-480`：`currentGroupAssets` 只过滤 `viewModel.page?.assets`。
- `CullingInspector.swift:368-374`：“保留当前 1 张”直接调用 `keepInGroupRejectRest(groupId, keepPhotoIds: [current])`，无二次确认。
- `CullingViewModel+Navigation.swift:98-109` → `decideSimilarityGroup`；`CullingViewModel+Actions.swift:83-109` 用完整 `group.images` 校验。
- `CullingService+Commands.swift:707-742`：从 `similarity_result` 取完整组员，keep 之外的**全部**写 reject。

**用户影响**：组跨页/被排序打散时，界面显示“相似组 · 2 张”，实际组 30 张；点“保留当前 1 张”会淘汰另外 28 张（含屏幕外），且没有确认。组只剩 1 张已加载时入口直接消失。

**修法**：用服务端的完整组员数展示；点决策前弹出确认（保留 1 / 淘汰 N-1，列出前 3 个文件名）；或提供“仅处理已加载组员”。`keepValid` 也改用完整组计数。

**验收**：构造跨页相似组（30 张，只加载 2 张）→ 标题显示 30；点“保留当前 1 张”必须先确认并显示将淘汰 29 张。

---

### P1-9 网格布局下整条 infoBar 消失，同步/写回/重置入口随之消失

**证据**

- `CullingWorkbench.swift:36-51`：`if layoutMode == .grid { CullingGridView(...) } else { ... CullingInfoBar(...) }`。
- `CullingInfoBar.swift:97-137`：同步菜单、“立即写入 XMP”、“写回 XMP…”、重试失败项、保留 XMP 并结束、恢复原 XMP、重置挑片全部只在这里。
- C1 状态胶囊只打开设置：`C1StatusCapsule.swift:216`。
- 网格 header 只有计数/全屏：`CullingGrid.swift:235-252`。

**用户影响**：用户切到网格做批量挑片（这也是唯一支持 ⌘A 的布局）后，无法写回 XMP、确认同步或重置挑片；必须自己发现要切回单图/对比布局，界面没有任何提示。工作流被布局切成两半。

**修法**：把同步 Menu 与重置移到工具栏/检查器（与布局无关），或在网格 header 增加紧凑同步入口；若刻意只放 infoBar，至少在网格显示“同步请切回单图”。

**验收**：网格布局下能看到并执行“写回 XMP / 同步 / 重置”；不需要切布局。

---

## 4. P2（体验 / 一致性 / 反馈）

### 4.1 导出与整套交付

**P2-1 两套导出引擎同页并存，关系不明；整套交付无确认；范围缺“所选照片”；失败不可操作**

- 同页先“导出设置/预览/结果”，再“整套交付/配方/联系表/画廊/WebDAV”：`ExportView.swift:83-94`。两套按钮（“开始导出” vs “开始整套交付”）、两套结果、两套设置，没有任何说明。
- 传统导出有确认弹窗并冻结参数快照（`ExportView.swift:131-151`）；整套交付点“开始整套交付”直接执行（`ExportView+Delivery.swift:44-48` → `ExportViewModel+Delivery.swift:210-263`），没有文件数/空间/覆盖策略确认。`Confirmed(input)` 使用默认 `.userDialog`，但实际没有弹窗。
- 导出范围只有“按筛选/工作区全部”（`ExportView+Range.swift:18-25`），协议里已有 `ExportScope.selected`（`Protocol/Export.swift:9-13`）和确认文案（`ExportConfirmation.swift:47`）但 UI 不可达；默认是 `.session`（`ExportViewModel.swift:94`），在图库选 10 张后很容易整库导出。
- 结果区只显示 `errors.prefix(3)`（`ExportView+Result.swift:19-23`），无“还有 N 条”、无重试、无“在 Finder 中显示”；取消提示 `notice = "已取消导出"`（`ExportViewModel+Execute.swift:61`）走绿色成功条（`ExportView.swift:67-70`），且 notice 在开始新动作时不清空（`ExportViewModel+Delivery.swift:138` 是少数清空点）。

**建议**：明确产品口径——若“整套交付”是未来主路径，就把传统导出降级为“快速导出”并折叠；给交付加确认（文件数/空间/是否覆盖）；把 `.selected` 接上并在有选择时默认；结果区显示总数 + “查看全部” + 重试 + Finder；动作开始时清 notice，取消用中性色。

### 4.2 图库与挑片交互

**P2-2 图库没有键盘导航/⌘A，多选是死胡同**

- 选择栏只在 `selectedIds` 非空时渲染：`GalleryView+Content.swift:24-26`；零选中时看不到“全选”。
- “全选”help 写“当前筛选下的全部照片”，实际只对 `filteredPhotos`（已加载页）逐个 toggle：`GalleryView+Content.swift:233-237,253-260`，且是主线程 O(n)。
- `GalleryInspector.swift:101` 只在 `selectedIds.count == 1` 时展示元数据；2 张以上没有任何批量动作。
- `GalleryGrid.swift:117-146` 只有点击 + 右键菜单，整页除灯箱外没有 `onKeyPress`/方向键/Return。

**建议**：选择栏常显 + ⌘A；批量动作（评分/色标/加入相册/导出所选）或移除多选；补方向键/Return/Shift 范围选择；全选走服务端 selection（像挑片那样）或批量 setter。

**P2-3 挑片：多选显示与写入对象不一致；对比对象取列表开头；U 前进不一致；紧凑工具栏无取消**

- 多选时标题“批量 N 张”，但星级取 `currentAsset`（`CullingInspector.swift:40,62`）、色标 get 也取当前照片（:465-473），点击却写整个选择集（`CullingViewModel+Actions.swift:307-309`）。当前照片不在选择集时，点 5★ 写给别人，星级行仍显示当前照片旧值。
- 2/4 图对比：`CullingWorkbenchViewer.swift:416-420` 用“相似组或全列表去掉当前后的前 N 张”，无相似组时当前第 100 张会对比列表第 1 张。
- U：查看器默认 `shouldAdvance=true`（`CullingWorkbenchViewer.swift:183-185`），网格 `state != .unreviewed`（`CullingGrid.swift:365`），检查器 `false`（`CullingInspector.swift:49-51`），注释明确“U 不前进”（`CullingViewModel+Actions.swift:293-294`）。
- 紧凑工具栏只有进度、没有完整工具栏的取消按钮：`CullingToolbar.swift:107-132` vs :156-184。
- 查看器只 `.focusable()`，未主动取焦（`CullingWorkbenchViewer.swift:148-155,200-202`）；网格/灯箱都显式取焦（`CullingGrid.swift:229-232`、`LightboxView.swift:67-78`）。**此条需 GUI 复核**，若首帧无焦点，P/X/空格/0–5 会看起来失效。

**建议**：多选时按选择集算混合态，或只显示当前照片并把批量写入改成显式“应用到 N 张”；对比优先用已选照片，否则当前 ± 相邻；U 统一不前进；紧凑档补取消；查看器加 `@FocusState`/默认焦点。

**P2-4 挑片筛选 scope 与筛选状态不同步，空态无清除按钮**

- `filters` 只在 `scope == .filtered` 时下发：`CullingViewModel+Load.swift:202`；`setFilterState` 会自动切 `.filtered`（:327），但 `setScope` 不清 `filterState`（:342-347）。
- 检查器仍显示“N 项筛选”（`CullingInspector.swift:349-351`）。
- 筛到 0 张时空态只有文案“切换到全部照片或清除筛选条件”，没有按钮（`CullingView+Content.swift:37-41`）；“重置筛选”在默认折叠的 DisclosureGroup 底部（`CullingFilterControls.swift:64-68`）。

**建议**：离开 `.filtered` 时清空或禁用筛选并标注“筛选仅在按筛选范围生效”；空态加“清除筛选”按钮；工具栏加活跃筛选 chip。

**P2-5 冲突逐个裁决、无批量；失败清单截断**

- `CullingConflictPanel.swift:19-24` 只展示 `conflicts.first`；:91-115 每次处理一个；:117-140 失败清单只显示前 3 项 + 计数，无“查看全部”。
- 大批量写回冲突时，用户需要逐个点“采用外部值/保留 Gather”，没有“全部采用外部/全部保留”的批量动作（哪怕有风险，也应显式提供并确认）。

**建议**：提供批量策略（全部保留/全部采用外部/按字段批量） + 影响计数确认；失败清单可展开/导出。

### 4.3 元数据、模板与人物

**P2-6 元数据/模板面板：无未保存改动保护，原始错误上屏，批次行重复名/日期不随语言**

- `MetadataEditorSheet.swift:76` 的“取消”直接 `dismiss()`；该表单有 32 个描述性字段 + 8 个联系人成员（文件头 :2），`changedFieldCount` 已算好却只用于禁用“应用”。`MetadataTemplateFieldsSheet.swift:89` 同样。
- `MetadataTemplateSheet.swift:203,211,241,257,272,298`、`MetadataBatchSheet.swift:99,137`、`MetadataTemplateFieldsSheet.swift:148`、`IngestSheet.swift:121,148` 均为 `String(describing: error)`；同场景的 `MetadataEditorSheet.swift:217` 用 `CommandErrorText.resolve`。
- 批次行先 `Text(name)`，下一行又以 name 开头（`MetadataBatchSheet.swift:34-41`）；triage 批次两行都是“技术建议写回”。日期用无 locale 的 `DateFormatter`（:103-112），英文界面出现中文日期。

**建议**：有改动时关闭前确认或保留草稿；错误统一走 `CommandErrorText`，原文进 `.help`/日志；批次行只保留一种名称，日期走 `DisplayDateFormatters` + `l10n.locale`。

**P2-7 人物库无法合并人物、无法移除关联照片**

- `PersonsViewModel.swift:148-157` 已实现带确认的 `merge`，`PersonsView.swift:444-455` 详情页只有“删除人物”；`removePhoto`（:169-190）同样无调用点。
- 绑定时按角色名自动建人物（`FaceKwService+Review.swift:336` 的 `upsertByName`），同名写法不同就会留下重复人物。

**用户影响**：写错一次人名就多一个人物，唯一清理手段是删除人物（连带解除全部绑定）或去人脸页逐簇解绑；误绑照片无法从人物页移除。

**建议**：详情/列表加“合并到…”（选目标 + 影响计数 + 确认，复用现有 API）；关联照片格加“移除此照片”。

**P2-8 重复组处置后成员回改不更新组 resolution，徽标与导出语义不一致且不可回到未处理**

- `DuplicatesViewModel.swift:329-335` 只改 `member.isKept/resolution`，不改 `group.resolution`。
- `DuplicatesGroupCardView.swift:34-40` 徽标读 `group.resolution`；:43-46 菜单只有“保留最佳/保留全部”，没有“恢复未处理”。

**影响**：组“保留最佳”后逐张改回保留，卡片仍显示“保留最佳”；无法把组恢复为未处置；导出过滤与徽标可能不一致。

**建议**：成员变更后重算/清空组 resolution；加组级“恢复未处理”；补组/成员状态一致性测试。

### 4.4 相似度、长任务与反馈

**P2-9 相似度分析/重新聚类进行中，旧结果的写回面板仍可预览并写 XMP**

- `SimilarityView+Content.swift:32-37`：`result != nil` 渲染写回面板，`isAnalyzing` 同时渲染进度。
- `SimilarityViewModel+Writeback.swift:26-28`：`canPreviewWriteback` 不含 `isAnalyzing/isReclustering`；:100-116 有预览 + 选择即可执行。

**建议**：分析/聚类期间禁用或遮罩写回面板；预览绑定 `resultRequestID`，执行前再校验结果代。

**P2-10 长批任务无进度/取消；摄取去重整库哈希；`import_concurrency` 是死配置**

- 摄取/模板套用/校样回传/triage 生成：`IngestSheet.swift:94-99`、`MetadataTemplateSheet.swift:121-144`（无 ProgressView）、`LiveSessionAPI.swift:101-104`、`MetadataTemplateService.swift:176-186`；人脸“仅重新聚类”绕过 JobService（`LiveFaceAPI.swift:161-174`），任务中心无进度/取消。
- 摄取去重对会话内所有未回填 checksum 的照片整文件 SHA-256（`SessionService.swift:222-233`），2 万张网络卷会非常慢；哈希失败 `catch {}` 静默漏判。
- `import_concurrency` 被读取但循环内无并发（`SessionService.swift:173-194`），配置无效；NaN/∞ 时 `batchSize = 0`，静默导入 0 张。

**建议**：统一任务化（job + onProgress + cancel）或至少给这些面板加进度/取消；摄取去重先用 size/mtime 粗筛并回填 checksum；把 import 并发真正接上，非法值回退 1 并 warn。

**P2-11 Capture One 预检失败没有分因与下一步动作**

- `SettingsView+C1HealthSection.swift:22-27` 把四种原因合并为一句“预检失败：无法连接 Capture One 自动化通道”；`SettingsViewModel+C1Health.swift:45-51` 存了 `lastError` 但界面不渲染。
- 用户无法区分 TCC 未授权/未开文档/超时/脚本失败，也没有“打开系统设置 → 隐私与安全性 → 自动化”的按钮。

**建议**：按层展示四种检查项与各自修复动作；提供可复制诊断与“重新检测”。

**P2-12 帮助与首次运行的 C1 入口**

- 帮助菜单只打开 GitHub 仓库（`GatherAppCommands.swift:71-77`），离线时无帮助；没有应用内快捷键速查（挑片 P/X/U/0-5、⌘A、⌘K 等只散落在 tooltip）。
- 首屏文案承诺“从文件夹或 Capture One 导入”（`DashboardFirstRunView.swift:113`），但 CTA 只有“导入文件夹/新建工作区”（:125-137），C1 卡片动作是打开设置（:184-191）；真实入口是 ⌘N 表单来源分段或 ⇧⌘I。

**建议**：帮助菜单增加“快捷键”“故障排查”“打开诊断包”；C1 卡片改为触发已有 `captureOneImport`，或在 hero 加第三个次级 CTA。

### 4.5 术语与本地化

**P2-13 导航组（Burst/Scene）术语与入口**

- `CullingFilterControls.swift:76-114`：“保存 Burst/Scene 分组”“预览分组”“导航组”，英文标签硬编码在代码里（:108），中文界面也显示 Burst/Scene；入口在筛选区底部，默认折叠，且没有一句解释“什么是导航组/它解决什么问题”。

**建议**：改名为用户可理解的概念（“连拍分组/场景分组”），加一行说明与示例；给“保存/预览/拆分/合并”补帮助。

**P2-14 英文单复数、术语与破坏性提示颜色**

- 只有 8 个 `#one` 键；大量计数用 `format` 而非 `plural`：`CullingInfoBar.swift:190-194`、`CullingGrid.swift:237`、`ExportView+Delivery.swift:234` 等，en 表对应 `%lld XMP conflicts`、`%lld items` 等，会出现 “1 XMP conflicts / 1 items / 1 photos”。
- 新增配方默认名 `Recipe N`（`ExportViewModel+Delivery.swift:43-53`），默认配方 `Web 2048/Print TIFF`（:61-68），中文界面也显示英文。
- 取消提示走绿色 success banner（`CullingView+Content.swift:19-21`；取消文案见 `CullingViewModel+Writeback.swift:293-296`）。
- “会话/工作区”混用：en 表 `Localizable.strings:76` 同一句出现 workspace 与 session；12 个 key 含“会话”、58 个含“工作区”。

**建议**：对全部计数模板做单复数 lint（或统一走 `plural`）；配方名走 l10n；取消/警告用中性色；用户文案统一“工作区/Workspace”，代码保留 session 并在 DEVELOPMENT 写术语表。

---

## 5. P3（打磨）

1. **“保留已选 K 张”占位符**：`CullingInspector.swift:380` 在空选择时显示字面 K；en 表 :154 也是 “Keep Selected (K)”。应隐藏或用真实计数。
2. **批次列表重复名/日期**：已在 P2-6 合并，不再单列。
3. **报表未知类型空成功**：`ExportService+Report.swift:23,71-73` 对未知 `reportType` 返回空内容；`format` 非 md 一律当 csv。应抛参数错误。
4. **`jobs.clear_completed` 只清 succeeded**：`JobService.swift:502-508` + `LiveJobAPI.swift:49-52`；failed/interrupted/cancelled 行只能永久累积。应允许 UI 清空失败记录。
5. **测试告警未门禁**：构建日志出现 `EmbeddedMetadataWriterTests.swift:122` 冗余 `#require`、`LibraryViewModelTests.swift:297` 未使用变量、:621/656 主线程隔离警告；CI 的 `swift build`（`ci.yml:121`）没有 `-warnings-as-errors`。建议至少对 Sources 开 strict，Tests 允许白名单。
6. **ratchet 可无条件抬高基线**：`check-design-system.py:91-96`、`check-cleanup-ratchet.sh:113-119` 的 `--update/--write-baseline` 不比较旧基线；`check-protocol-surface.sh:162-179` 已有 `--allow-growth` 闸门。建议抽公共 helper，三个 ratchet 统一“上涨必须显式批准 + 记账”。
7. **串行测试名单手工维护**：`scripts/test.sh:30` 的 `CORE_SERIAL_FILTER` 是正则白名单；新增碰 `GatherLogger`/慢事务阈值的套件不会自动进串行批。建议用 `@Suite(.serialized)` 或标记推导。
8. **设计文档过期**：`docs/design/appearance-interaction.md:19` 仍写 `Features/` 目录；:226 说菜单 Phase 4 未完成，而 `GatherAppCommands.swift:4-6` 已收口。建议更新或标历史。
9. **模型下载器不可达**：`SettingsView.swift:180-188` 的确认框依赖 `pendingModelInstall`，但全仓没有任何赋值点；`startModelDownload` 仅从这里可达，`ModelInstaller` 只在测试中被调用。约 300 行 UI/逻辑是死面。建议删掉，或补一个“下载模型”按钮并做校验和。
10. **`runModal` 与仓库政策冲突**：`IngestSheet.swift:157/166/175`、`SettingsView+MaintenanceSection.swift:261/277`；仓库在 `NewSessionSheet.swift:127-136`、`ExportViewModel.swift:298-301` 已改为 `begin()` 并注释“本仓已弃用”。建议统一异步面板。

---

## 6. 开发者视角（DX / 契约 / 工程）

### 6.1 API 面可发现性

- **数字漂移**：`APIContractIndex.swift:5` 写“110 个方法”，实际 134；:18 写“251 类型 / 1,320 声明”，baseline 是 332 / 1,909。`CullingAPI.swift:2` 写“21 个方法”，实际 23；`ExportAPI.swift:2` 写“4 个方法”，实际 7。
- **方法级文档稀薄**：134 个协议方法中只有 39 个的紧邻上一行是 `///`（约 71% 无说明）；没有 DocC/生成的 API 索引。
- **命名/返回风格不统一**：`page(_ query:)` / `groups(_ sessionId:)` / `reset(_ input: Confirmed<…>)` 三种参数风格；`flush` / `retrySync` / `confirmSync` / `finalizeSync` 四个相近概念；`cleanup` / `confirmSync` / `retryFailedWriteback` 在多个协议重名。
- **建议**：让 `check-protocol-surface` 生成按域的 Markdown 索引（方法名 + 一行说明 + 错误码）；要求新增方法至少一行 `///`；把头注释方法数纳入门禁。

### 6.2 错误与确认边界

- **`SettingsAPI.reset()` 没有 `Confirmed`**（`SettingsAPI.swift:19`），VM 还保留 `reset(confirmed: Bool)`（`SettingsViewModel+Loading.swift:118-120`），与 `DEVELOPMENT.md:522`“类型层面禁止裸 Bool”冲突；这是 P1-5 的根因之一。
- **14 个 API 方法返回 `Bool`，没有一个调用点读取**；`SessionControlViewModel+Actions.swift:41-42` 在 `jobAPI.retry` 返回 false 时仍提示“已重试任务”，随后列表又显示失败。
- **域错误无码**：`MetadataTemplateServiceError`（`MetadataTemplateService.swift:12-25`）不实现 `CodedError`，`LiveMetadataAPI.swift:221-225` 原样抛出；UI 只能 `String(describing:)`。`DuplicateServiceError` 的 groupNotFound/memberNotFound 也没有 `gatherCode`（`LiveDuplicateAPI.swift:133-140`）。
- **批量语义分裂**：`CullingService+Commands.swift:342-366` 的 `batchUpdate` 在单事务内，任一冲突整批 0 生效；`importClientSelection`（:437-441）逐张失败继续；`applyTemplate` 也是逐张。调用方无法预判 atomic/partial。
- **建议**：新增 `SettingsResetInput` + `Confirmed`；把 Bool 改成显式结果枚举或 false 即抛；补 `TEMPLATE_*` / `DUP_*` 码；在 API 文档与返回类型标注 atomic/partial。

### 6.3 测试与门禁的盲区

- 测试量很大（2,205 @Test / 10,244 断言，ratchet 全绿），但大量 app 测试在断言“调用次数/调用顺序”（如 `APISimilarityUITests.swift:197,272`），对“失败/false 时用户看到什么”“空/错/取消态文案”覆盖薄。P1-2 的静默失败、P2 的假成功都能全绿。
- 12 个门禁全绿，但不校验：README 的 129/134、V5、15/16、`CONFIGURATION=release` 反向描述；也不校验 API 头注释方法数、方法级 `///` 覆盖率、`runModal` 政策。
- 没有 `-warnings-as-errors`；测试构建仍有告警（P3-5）。
- **建议**：为每个用户动作补一条“notice/error/空态”断言；把文档数字与 API 头数纳入 `check-docs`/`check-protocol-surface`；Sources 开 strict warnings。

### 6.4 上手路径与文档

- **“看到应用”没有顺畅路径**：README Quick start 只有 Run tests / Build bundle（`README.md:65-100`）；`docs/DEVELOPMENT.md:408` 又说不要在日常跑 `build.sh`；文档没有 `swift run` 或 debug 运行入口。`Package.swift:15` 说明 Info.plist 由 build.sh 拷入，直接 `swift run` 不是完整 .app。
- **README 事实错误**：`README.md:33` 仍写 “129 methods”（:106 写 134）；:34 写 “15 total” target（实测 core 12 + app 4 = 16）；:120 写 “current schema (V5)”，实际 `Schema.currentSchemaVersion = 1`（`Schema.swift:13`、`SchemaCurrent.swift:154`）。
- **`CONFIGURATION` 反了**：README :93-94 说 “Set `CONFIGURATION=release` for a release build”，而 `build.sh:23` 默认就是 release；debug 反而要显式设置。
- **测试命令不能按顺序复制**：`DEVELOPMENT.md:58` 先 `cd desktop/native/gather-core`，:61 再执行根目录的 `./scripts/test.sh core`，会报 No such file。
- **功能文档缺口**：README/docs 没有 WebDAV 发布、联系表/打印、客户校样回传、水印、智能相册、导航组、备份/恢复/诊断；`docs/ROADMAP.md` 仍是 2026-08-12 的 Cut 6 快照，W1–W3（模型初审/内嵌元数据/整套交付）未进入路线图。
- **建议**：加 `scripts/run.sh` 或文档化 debug 组装；修正上述数字与 CONFIGURATION；把新功能的用户故事补进 README/ROADMAP；check-docs 直接报出需要修改的文件:行号。

### 6.5 可观测性

- `GatherLogger.minimumLevel` 默认 `.info`（`Logger.swift:23`），没有环境变量/设置入口；20 处 `.debug` 日志永远不会落盘。
- 日志路径 `~/Library/Application Support/Gather/Logs/gather.log`（`AppBootstrap.swift:206-207`）未写入文档；设置页只有“导出诊断包”，没有“显示日志”。
- **建议**：加 `GATHER_LOG_LEVEL` 或 defaults 键；文档化日志路径；设置页加“在 Finder 中显示日志”；诊断包 manifest 带上路径与版本。

### 6.6 术语

- 用户文案“会话”和“工作区”指同一个对象，甚至在同一句（`Localizable.strings:76`）；代码域叫 Session，页面叫“工作区控制中心”。建议用户文案统一“工作区”，代码保留 session，并在 DEVELOPMENT 加术语表。

---

## 7. 正面确认（可复核）

1. **分层与依赖方向**：`GatherUI` 只 import `GatherProtocol`；`check-layering.sh` 本次 exit 0；UI 不碰持久化/分析层。
2. **API 契约测试**：`API*Tests.swift` 覆盖 16 个域的 Live 行为；`ErrorLocalizationCoverageTests` 保证 195 个错误码都有文案，且 en 覆盖、占位符序列一致。
3. **本地化 parity**：代码在用的 key 必须有 en 条目、无孤儿键、无重复键；`LocalizationParityTests` 本次通过。
4. **破坏性动作**：挑片/导出/人脸/人物/相似度的确认分支都只构造一次 `Confirmed`，取消只写可见文案；`CullingView+Content.swift:19-21` 的 notice 虽然颜色有问题，但至少不静默。
5. **挑片历史栈**：`CullingViewModel+Actions.swift:367-419` + `CullingHistoryRepo`，支持跨重启的 undo/redo（500 条窗口），且 `undoOperation` 的 MAX(id) 规则有注释与测试。
6. **任务状态机**：`JobService` 的取消宽限、心跳/租约、first-wins 终态、成功路径也尊重取消（`JobService+Settle.swift:94-194`）。
7. **导出计划同源**：`ExportService+Plan.swift:34-112` 的 `buildPlan` 同时服务预览与执行，确认时冻结快照（`ExportView.swift:131-151`）。
8. **设计系统**：`GatherTheme` 四态语义色、`reduceMotion` 接入、空/错态 `ContentUnavailableView` + 重试；14 个 `#Preview` 覆盖主要页面。
9. **门禁质量**：`check-test-catalog` 真的解析 skip 的 owner/到期日；`check-protocol-surface` 有 `--allow-growth` 自证；`check-no-legacy` 有 enforced 规则。
10. **诊断包**：日志 + 设置 + 库统计、默认脱敏绝对路径、20MB 上限（`DiagnosticsCollector.swift:35-66`）。

---

## 8. 建议修复顺序

### Wave 1：止血（P1，约 5–7 人日）

1. 导入链路（P1-1/P1-2）：目录导入走 sourcePath；失败 toast。约 1–1.5 天。
2. 挑片选择语义（P1-6/P1-7/P1-8）：普通点击清空多选；全选分批或显式“仅可见”；相似组按完整组确认。约 2 天。
3. 人脸预览失效（P1-4）：绑定变更清 preview + 签名校验。约 0.5 天。
4. 设置 reset（P1-5）：白名单/二次确认 + languageStore。约 0.5–1 天。
5. 网格布局补同步入口（P1-9）：工具栏/检查器复用 infoBar menu。约 0.5 天。

### Wave 2：体验收口（P2，约 6–8 人日）

- 导出信息架构（P2-1）：明确两套引擎关系、交付确认、`.selected`、结果可操作。2–3 天。
- 图库键盘 + 批量动作（P2-2）：1.5 天。
- 挑片多选显示/对比/U/紧凑取消/焦点（P2-3）：1.5 天。
- 摄取/模板/长任务进度与取消（P2-10）、C1 预检（P2-11）、帮助与首跑（P2-12）：2 天。
- 元数据/人物/重复/相似度（P2-6/7/8/9）：2 天。

### Wave 3：工程与文档（约 3–4 人日）

- API 索引 + 方法注释 + 数字门禁（§6.1）。
- Settings reset Confirmed / Bool 返回值 / 错误码补齐（§6.2）。
- README/DEVELOPMENT/ROADMAP 与实际对齐；加 run.sh；修 CONFIGURATION/测试命令（§6.4）。
- 日志级别/路径/诊断入口（§6.5）。
- 测试从 call-count 转向用户可见行为（§6.3）。

---

## 9. 复跑与实测证据

```bash
# 12 个门禁（本次逐条 exit 0）
./scripts/check-docs.sh --strict
./scripts/check-cleanup-ratchet.sh
./scripts/check-layering.sh
./scripts/check-duplicate-symbols.sh --strict
./scripts/check-test-catalog.sh --strict
./scripts/check-preview-surface.sh --strict
./scripts/check-design-system.sh
./scripts/check-no-legacy.sh
./scripts/check-select-star.sh
./scripts/check-protocol-surface.sh --strict
./scripts/check-coded-errors.sh
./scripts/check-backlog-evidence.sh

# 测试（本机 DSH 沙箱需 --disable-sandbox）
SWIFT_TEST_FLAGS="--disable-sandbox --cache-path .build/swiftpm-cache --scratch-path .build/swiftpm-scratch" \
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
./scripts/test.sh all
```

实测：core **1443 tests / 216 suites**，app **762 tests / 89 suites**，exit 0；门禁 12/12 exit 0。

---

## 10. 本评审的边界与需 GUI 复核项

1. **焦点**：`CullingWorkbenchViewer` 未显式取焦（P2-3）；SwiftUI 是否会在首帧自动把焦点给 `.focusable()` 视图，需要实机按 P/X/空格验证。
2. **嵌套面板**：`IngestSheet` 内 `runModal`（P1-3）是否真的遮挡/阻塞，需要 GUI 复现。
3. **视觉布局**：英文长文案在窄窗口的截断、检查器折叠后的可达性，需要截图/实机。
4. **Capture One 联动**：预检分因、reload ack、冲突裁决的真实链路，需要真实 C1 环境。
5. **大规模数据**：2 万张的摄取去重耗时、全选分批、任务取消的实际体感，需要真实库。

---

> 本报告只评审、不改代码。P1 项建议逐条配回归用例后再合入；P2 可按 Wave 2 分批。所有行号基于 `c77c3a57` 工作树，后续改动需重新 grep。
