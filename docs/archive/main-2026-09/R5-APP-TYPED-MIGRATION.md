# R5 宿主接线迁移规范（app 侧类型化命令面）

> **状态：已完成（本规范是执行期契约，保留作历史记录）。**
> 收口轮结果：app 侧 30 个文件、约 120 处命令调用全部改为类型化域方法；
> 旧命令路由层/客户端/JSON 桥/测试替身已全部删除；门禁 `awaitSync` / 路由符号 /
> 模块桥 / 双轨本地化四条度量归零并转 enforced。完成记录见
> [ARCHITECTURE-REFACTOR-PLAN.md](ARCHITECTURE-REFACTOR-PLAN.md) §31。

> 目标：app 层不再出现命令名字符串、不再出现命令级 JSON 桥。
> 组合根 `Sources/GatherApp/App/AppComposition.swift` 产出 `GatherCore.CommandSurface`（19 域协议）。
> 本文件是各切片（provider / feature 视图 / 测试）的共同契约。

## 0. 硬规则

1. 删除 `NativeCommandClient`、`CommandRouter`、`SessionCommandRouter`、`JSONValueDecoding`
   在 app 源码中的一切使用（注释里也不要写这些标识符——门禁按出现次数计数）。
2. 不再有 `execute(` / `executeAsync(` 调用；不再构造 `[String: JSONValue]` 参数。
3. 行为不变：错误码、门控（confirmed）、缺省值、分页语义、文案一律保持。
4. 错误展示统一 `GatherErrorText.message(for: error)`（`Sources/GatherApp/Support/GatherErrorText.swift`）。
5. 不新增兼容层/双路径/旧重载；旧参数直接替换。
6. 只改自己被分配的文件；不要 git add/commit；不要改 core。

## 1. 注入约定

- 组合根产物：`AppComposition`（`commands: CommandSurface`、`jobRunner: JobRunner`、
  `sessionRuntime: SessionRuntime`、`settingsAPI: SettingsAPI`、`prepareForTermination()`、
  `recordCaptureOneReloadAck(sessionId:)`）。
- 特性视图统一签名：`init(sessionId: String, commands: CommandSurface, ...)`（保留原有导航闭包参数）。
- provider 统一签名：`init(commands: CommandSurface)`（需要作业运行器时追加 `jobRunner: JobRunner`）。
- `C1StatusCapsuleHost` 新签名：`C1StatusCapsuleHost(sessionId:culling:onOpenSettings:)`，
  其中 `culling: any CullingCommands`（即 `commands.culling`）。
- `SessionShellView` 已改为 `commands: CommandSurface?` 并已把 `commands` 透传给 5 个页签视图。

## 2. 旧命令 → 类型化方法对照

| 旧命令 | 类型化调用 |
|---|---|
| session.create | `commands.session.create(SessionCreateParams(...))` |
| session.create_from_directory | `commands.session.createFromDirectory(SessionCreateFromDirectoryParams(...))` |
| session.list | `commands.session.list()` |
| session.get | `commands.session.get(SessionGetParams(sessionId:))` |
| session.update | `commands.session.update(SessionUpdateParams(...))` |
| session.add_photos | `commands.session.addPhotos(SessionAddPhotosParams(...))` |
| session.delete / delete_many | `commands.session.delete / deleteMany`（DTO 带 confirmed） |
| photo.list_page | `commands.photo.listPage(sessionId:afterFirstRowid:limit:expandVariants:)` |
| filter.photos / photos_global / suggest | `commands.filter.photos / photosGlobal / suggest` |
| album.* | `commands.album.{create,list,get,update,delete,getPhotos}` |
| assets.* | `commands.assets.{candidates,acceptCandidate,rejectCandidate,volumes,relinkRoot}` |
| culling.list_page / groups / summary / history / sync_status / update / batch_update / decide_group / apply_history / writeback / retry_failed_writeback / flush / retry_sync / finalize_sync / confirm_sync / cleanup / reset | `commands.culling.<同名驼峰>`（`retrySync`/`finalizeSync`/`decideGroup`/…） |
| sim.* | `commands.similarity.{analyze,cancelAnalysis,recluster,result,previewWriteback,writeback,writebackItems,retryFailedWriteback,confirmSync,cleanup}` |
| dup.* | `commands.duplicate.{scan,groups,resolve,resolveMember}` |
| quality.* | `commands.quality.{get,analyze}` |
| fkw.* + face.models_status | `commands.face.{analyze,cancelAnalysis,recluster,clusters,bind,unbind,merge,removeMember,preview,writeback,confirmSync,confirmCleanup,cleanup,modelsStatus}` |
| person.* | `commands.person.{list,get,create,update,delete,merge,removePhoto,searchPhotos}` |
| template.* | `commands.template.{create,list,get,update,delete,apply}` |
| metadata.get/set/batch_set/conflicts/resolve_conflict/resolve_orphan/orphans | `commands.metadata.{get,set,batchSet,conflicts,resolveConflict,resolveOrphan,orphans}` |
| navigation.analyze/list/split/merge | `commands.navigation.{analyze,list,split,merge}` |
| jobs.list/cancel/retry/clear_completed | `commands.jobs.{list,cancel,retry,clearCompleted}` |
| index.scan | `commands.index.scan(IndexScanParams(sessionId:))` |
| export.preview/execute/cancel/report | `commands.export.{preview,execute,cancel,report}` |
| workspace.status | `commands.workspace.status(WorkspaceStatusParams(sessionId:))` |
| settings.get_all/get/set/reset/set_language/get_ml_status | `commands.settings.{getAll,get,set,reset,setLanguage,getMLStatus}` |

实现细节以 `Sources/GatherCore/API/*Commands.swift`（协议签名）与
`Sources/GatherCore/API/Impl/*CommandsImpl.swift`（每个方法都标注了「旧命令：x.y」）为准。
参数 DTO 在 `Sources/GatherCore/Protocol/*.swift`。

## 3. 典型改写

旧（provider）：
```swift
private let client: NativeCommandClient
public init(router: SessionCommandRouter) { self.client = NativeCommandClient(router: router) }
func list() async throws -> [PersonData] {
    try await client.executeAsync("person.list", params: [:]).decoded(as: [PersonData].self)
}
```
新：
```swift
private let commands: CommandSurface
public init(commands: CommandSurface) { self.commands = commands }
func list() async throws -> [PersonData] {
    try await commands.person.list(PersonListParams())
}
```

旧（视图）：
```swift
let data = try await client.executeAsync("culling.list_page", params: params)
let page = try data.decoded(as: CullingPage.self)
```
新：
```swift
let page = try await commands.culling.listPage(params)   // params 已是 CullingListPageParams
```

- `.decoded(as: T.self)` 一律删掉：类型化方法直接返回 T。
- 旧 `params: ["x": .string(v), "n": .number(d)]` → 对应 DTO 的字段（注意可选字段用 `?`）。
- 旧 JSON 响应里手工取的字段（如 `response.objectValue?["id"]`）→ 类型化返回值；
  `person.create` 直接返回 id 字符串。
- 旧 `RouterCommandError(message:)` / `BridgeError` → 直接用领域错误类型（core 已定义）
  或 `GatherErrorText` 展示；无对应码值时不要伪造错误码。
- 旧 `NativeCommandClient.message(for:)` → `GatherErrorText.message(for:)`。

## 4. 编译自检（各切片）

```bash
cd desktop/native/gather-app
swift build --disable-sandbox \
  --cache-path /private/tmp/gather-swiftpm/cache-<切片名> \
  --config-path /private/tmp/gather-swiftpm/config-<切片名> \
  --security-path /private/tmp/gather-swiftpm/security-<切片名> \
  --scratch-path /private/tmp/gather-swiftpm/scratch-<切片名> 2>&1 | grep -E '<你的文件>\.swift.*error' | head -40
```
并行切片期间其他文件必然报错——只修属于你的文件里的诊断。
