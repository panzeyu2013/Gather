# 全仓审查（2026-09-30，11 项）修复台账

> 来源：外部全仓审查报告（基准 df86849d，Swift 原生侧 + 插件/脚本/CI）。
> 本轮逐条修复并补回归；每条给出实现位置、修复方式与验证边界。

| # | 级别 | 问题 | 修复 | 回归 |
| --- | --- | --- | --- | --- |
| 1 | P1 | 改 XMP 后导出续跑仍交付旧元数据（指纹不含 sidecar 版本；续跑只检查照片存在） | `deliveryFingerprint` 每张加入 `sidecarVersion(forSource:)`（毫秒 mtime+size，缺省 "none"）；续跑跳过条件增加「需要 XMP 时必须确认目标 sidecar 存在」 | `deliveryFingerprintIncludesPhotoIdAndSidecarVersion`（改 XMP / 删 XMP 都改变指纹） |
| 2 | P1 | 同会话不同导出互相影响取消（取消位按 session；execute 入口清公共标志） | 取消改为 **run 级**：`execute(..., runId:)` 由路由传 `job.id`；`cancel(runId:)` 精确取消；`cancel(sessionId:)` 保留为「取消本会话全部 run」 | `cancellingOneRunDoesNotAffectAnotherForSameSession`（A 取消留 skipped、B 完整导出 4/4） |
| 3 | P1 | 迁移回滚先删活库再 move，存在「路径无数据库」窗口；WAL 在替换前被删 | 改为同卷 `replaceItemAt`（失败保留原库、重开连接）；WAL/SHM 只在替换成功后清理；临时库 0 字节拒绝替换 | 代码级；无崩溃/磁盘故障注入（见下） |
| 4 | P1 | `close()` 不取连接锁；`DBStatement` 在连接关闭后把 stmt 指针当 db 指针（静默返回 0） | `close()`/`open()` 纳入同一把锁；新增 `isClosed`；`query/run/get` 入口与 `bind` 都校验；删除 ownerHandle 回退，错误消息与 `sqlite3_changes` 只用 db 句柄 | `statementsFailAfterClose`（prepare/run/get 关闭后必须抛 DBError）——该测试还发现「无参数语句绕过检查」的真实缺口并已修 |
| 5 | P2 | 指纹里 `photo.id` 是字面量（漏插值），不同照片身份可能碰撞 | 修正插值（并与 #1 一起编码 sidecar 版本） | `deliveryFingerprintSeparatesPhotoIdsWithIdenticalContent` |
| 6 | P2 | 非有限数值设置（inf/1e999）会让 `Int(Double)` trap | `SettingsService.getNumber` 过滤 `isFinite`；路由新增 `clampedInt(_:fallback:range:)`，模型信息与缩略图尺寸全部改为分界安全转换 | `nonFiniteNumericSettingsFallBack`（inf/-inf/1e999/nan 全部回落默认） |
| 7 | P2 | Capture One 桥接只在 terminationHandler 读管道，大批量路径写满 pipe 会卡死 | `run` 之前挂两条管道的 `readabilityHandler` 持续排空，退出后再读残余；缓冲用锁保护的引用盒子（Swift 6 并发安全） | 编译级；真实 C1 大量选片未验证 |
| 8 | P2 | 图库返回仍未用统一 `goBack`（gallery/similarity/dashboard 合并成回工作台） | `backFromGallery()` 改用 `goBack(sessionId:)`（精确恢复到上一个完整页面） | `galleryBackReturnsToPreviousTabNotDashboard`（控制中心 → 图库 → 返回 = 控制中心） |
| 9 | P2 | 模型包安装缺文件仍 continue；先删目标再 move，失败留半套模型 | 先校验**全部**必需文件存在且非空（`missingFile`/`emptyFile` 明确报错）→ 暂存目录 → 全部就绪后逐个 `replaceItemAt`；失败清理暂存并保留旧模型 | 代码级；未用真实不完整 zip 验证 |
| 10 | P2 | C1 插件忽略 `NSWorkspace.open` 返回值、固定 success；图标用旧 bundle id | 按返回值上报 `status`（失败不再 suppress 通知）；图标优先 `com.gather.desktop.native`、回退旧版 | 编译级；真实 C1/Launch Services 多 handler 场景未验证 |
| 11 | P2 | 插件 Makefile 无源码/plist 依赖，产物目录存在即不重编译 | 真实目标拆分为二进制/plist/架构戳；切 `TARGET_ARCH` 强制重编 | `make -n` 四情形实测：就绪无动作 / 改源码出 swiftc / 改 plist 出 cp / 切架构出 swiftc |

## 验证

- gather-app：**291 tests / 29 suites 通过**（+1）。
- gather-core：**970 tests / 136 suites**（+5；唯一失败为沙箱禁止写 home 的环境性用例）。
- 门禁：`check-command-surface`（两种 locale）/ `check-no-legacy` 通过。

## 未完成 / 未验证（诚实边界）

- **#3 无故障注入**：实现了原子替换与失败保留，但未在磁盘故障/断电窗口实测；启动时识别「恢复残留」也未加。
- **#4 无并发压力测试**：关闭与执行器并发的压力场景未跑；「停机超过 10 秒后路由关连接」仍依赖执行器自行退出（未加「关连接前等待执行器」）。
- **#7 真实 Capture One 未验证**：管道排空是机制修复；真实大量选片、超时/取消后无僵尸子进程都需真机。
- **#9 未用真实不完整包验证**；且报告中指出的「下载 ONNX 流程与实际 CoreML/Vision 推理配置不一致」属产品/配置口径，本轮未动。
- **#6 仅收敛了设置来源的整数转换**；分页游标与恢复 checkpoint 的范围校验未审计。
- **#10 插件真实行为未验证**（无 handler / 多 handler / 原生 app 未启动）。
- 视觉/VoiceOver/Intel/macOS 14/26 实机矩阵、签名公证安装升级：本轮均未覆盖。
