# 第三轮全仓审查 · 实际验收报告（2026-09-30）

> 方法：**用审查员自己的复现探针作为验收用例**（evidence 目录中的 4 个 probe 文件原样收录），
> 再为无法用探针覆盖的条目补可执行验收（迁移故障路径、并发关闭、子进程大输出、模型包完整性）。
> 所有验收都在本机沙箱内真实编译并运行，命令见文末。

## 一、审查员探针（原样收录，修复前失败 → 现在必须通过）

| 探针 | 对应问题 | 验收结果 |
| --- | --- | --- |
| `FullScanProbeTests.identityMustChangeFingerprint` | 5（指纹漏插值） | ✅ 通过（改 `photo.id` 指纹必变） |
| `FullScanProbeTests.xmpChangeMustInvalidateCompletedDelivery` | 1（XMP 续跑） | ✅ 通过——输出 **`XMP resumed content=new,exported=1`**（修复前为 `content=old` 且报成功） |
| `FullScanProbeTests.newRunMustNotClearOtherRunCancellation` | 2（会话级取消） | ✅ 通过（取消 A 后 exported=1/skipped=1，B 不受影响） |
| `ClosedConnectionProbeTests.preparedStatementAfterCloseMustThrow` | 4（失效句柄） | ✅ 通过（关闭后 `run` 抛 `DBError`，不再静默返回 0） |
| `SettingsNumberProbeTests.numericSettingsMustRemainFiniteBeforeIntConversion` | 6（非有限数值） | ✅ 通过（`1e999` 回落 640） |
| `FullScanNavigationProbeTests.galleryBackMustReturnToControl` | 8（图库返回） | ✅ 通过（回到控制中心页签） |

探针文件已收入仓库：`gather-core/Tests/GatherCoreTests/Services/ReviewAcceptanceTests.swift`、
`gather-app/Tests/GatherAppTests/ReviewAcceptanceTests.swift`。

## 二、本轮补充的可执行验收（探针未覆盖的验收标准）

| 问题 | 验收标准（报告原文） | 实际验收 | 结果 |
| --- | --- | --- | --- |
| 3 | 替换失败/替换前后退出，活动路径始终为可打开的旧库或完整恢复库 | `restoreFailureKeepsActiveDatabase`：备份不存在 → 抛错、**活动库路径仍存在**、同一连接重开后可读回原数据；`restoreSuccessReplacesDatabaseAndCleansWAL`：恢复成功读到备份内容、无 `.restore-tmp` 残留、备份保留 | ✅ 通过（**验收过程中发现并修掉真实缺口**：`copyItem` 抛错路径未重开连接） |
| 4 | 阻塞执行器后不得继续访问已关闭连接；并发压力不出现错误句柄或静默成功 | `statementsFailAfterClose`（prepare/run/get 关闭后必须抛错）+ `concurrentQueriesAndCloseStaySafe`（4 任务 × 40 查询与 close 并发，不崩溃；关闭后稳定抛错） | ✅ 通过（**发现并修掉**：无参数语句绕过关闭检查） |
| 7 | stdout/stderr 分别及同时超过管道容量仍完成 | `largeStdoutDoesNotDeadlock`（200,000 字节 stdout）+ `largeStderrDoesNotDeadlock`（200,000 字节 stderr + 非零退出） | ✅ 通过（均在 10s 超时内完成/报错，不挂死） |
| 9 | 缺一个文件、空文件、完整包各自明确结果；旧模型完整保留 | `incompletePackageIsRejected`（缺 `w600k_r50.onnx` → `.missingFile`，既有模型字节不变）+ `emptyFileIsRejected`（`.emptyFile`）+ `completePackageInstalls`（按映射改名落盘） | ✅ 通过 |
| 11 | 改 Swift / 改 plist / 切 TARGET_ARCH 都重新产生插件 | `make -n` 四情形 | ✅ 通过 |
| 2 | 同会话两目录并行，只取消 A；B 完整输出 | 探针 + `cancellingOneRunDoesNotAffectAnotherForSameSession` | ✅ 通过 |
| 1 | 只改 XMP / 新增删除 XMP 都不得静默复用旧完成记录 | 探针（改 XMP）+ `deliveryFingerprintIncludesPhotoIdAndSidecarVersion`（删 XMP）+ 跳过规则改为「目标 sidecar 三态 + 交付版本」 | ✅ 通过 |

## 三、验收过程中**新发现并修复**的缺陷（4 处）

1. **XMP 冲突被静默当成功跳过**（问题 1 的深层原因）：目标 sidecar 与源不同时 `plan.includesXmp=false`，旧跳过条件把冲突当「无需写 sidecar」→ 报成功但目标仍是旧 XMP。改为「目标 sidecar 缺失/冲突一律重交付」，并让新交付**覆盖**目标照片与 sidecar（`installFile` 用临时文件 + 原子替换，失败保留旧文件）。
2. **重交付时目标文件已存在会失败**：`copyItem` 对已存在目标抛 `file exists` → 新交付无法覆盖。改为统一走 `installFile`（原子替换）。
3. **迁移恢复失败未重开连接**：`copyItem` 抛错在 try/catch 之外 → 连接保持关闭（验收测试报「数据库已关闭」）。已把整个恢复过程纳入 do/catch，任何失败都重开原库并清理临时文件。
4. **无参数语句绕过关闭检查**：关闭校验原先只在 `bind(index:)` 内，`get([])`/`run([])` 这类无参调用会跳过。已把校验提到 `query/run/get` 入口。

## 四、当前验证结果（本机沙箱，真实执行）

```
cd desktop/native/gather-core && swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
  → 979 tests / 139 suites，1 失败（沙箱禁止写 home 的环境性用例，与本次改动无关）
cd desktop/native/gather-app  && swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
  → 297 tests / 31 suites 全绿
./scripts/check-command-surface.sh → 通过（C 与 C.UTF-8）
./scripts/check-no-legacy.sh     → 通过
cd desktop/coplugin && make -n all（四种新旧情形）→ 行为正确
```

## 五、**无法在本环境验收**的部分（不计作通过）

- **#7 真实 Capture One 集成**：无 C1 应用、无大量选片场景；管道机制已被 200KB 大输出验收覆盖，但「真实选片 → C1 插件 → 原生 app」端到端未验。
- **#10 插件运行期行为**：仓库内**没有** C1 插件 SDK（`desktop/Capture_One_Plugin_SDK_(Mac)_v1.0.1` 不存在），`make` 真实编译在沙箱内也因 clang module cache 权限失败 ⇒ 只能做静态检查（`open` 返回值已检查、bundle id 已改），**未编译、未运行**。
- **#3 断电/磁盘故障注入**：实现了原子替换与失败保留并用「备份缺失」注入验证了失败路径；真正的替换中断电、`replaceItemAt` 中途失败未注入。
- **#4 关闭时序**：「停机超过 10 秒后路由关闭 DB，而执行器仍在跑」这一具体时序未构造；并发压力已覆盖基本竞态。
- **图形/无障碍矩阵**：窄/宽窗口、中英、浅深色、Reduce Transparency、全键盘、VoiceOver、大库/空库/长名称——本环境无法驱动 GUI（此前已记录 SkyComputerUseService 崩溃）。
- **真实 RAW 格式全覆盖、万级库长期性能、签名/公证/安装升级、Intel 与 macOS 14/26 实机**：均未覆盖。
