# P0 实现审计与修复（2026-10-25）

> 范围：G0/T0/K0/F0/B0 的**代码实现**，不是真实集质量验收。方法：五路只读 subagent 审计 + 主代理逐条复核/修复；每条都以代码路径与可复现条件为准，未把设计文档承诺当成实现。

## 1. 结论

主路径可用，但审计确认了 **1 个 P0 + 16 个 P1 + 若干 P2**。P0 是“筛选/排序后隐藏选择仍被提交”，会写到不可见照片；本轮已修复并补回归测试。16 个 P1 均已修复（T0 设置接线见 §2）。修复后 core **1252 tests / 187 suites**、app **687 tests / 78 suites** 全绿，8 道 strict 门禁全绿。

## 2. 已修复（按工作流）

| 工作流 | 缺陷 | 修复 | 回归 |
|---|---|---|---|
| G0 | **P0** reset 先与旧 loaded 求交，筛选后隐藏选择仍被 commit | 筛选/排序/范围变化清空选择；commit 再与当前已加载页求交 | `filterClearsHiddenSelection` |
| G0 | P1 方向键只改 current，不改变选择 | `advanceCurrent/retreatCurrent` 同步单选 | `arrowSyncsSelection` |
| G0 | P1 右键菜单未先绑定 cell，决策落到旧 selection | 菜单先 `gridClick(cell)` 再执行 | 代码路径 |
| G0 | P1 每页全量读取整会话 triage（20k 每页 20k 行） | `triageRows(sessionId:photoIds:)` 按本页分块查询；service 页模式使用 | `triageRowsPageScoped` |
| G0 | P2 坏 reasons JSON 静默跳过 | 记录 warn 日志后降级 | 代码路径 |
| G0 | P2 `.all` + filters 被静默忽略 | `CullingPageQuery` 拒绝携带有谓词的 `.all` | `allScopeRejectsFilters` |
| G0 | P2 末页不足一页仍返回 cursor | 仅 `groups.count == limit` 时返回 | 相关 cursor 断言 |
| T0 | P2 summary 为 nil 时生成结果被丢弃 | `summary?.triage = value` 安全回填 | 代码路径 |
| T0 | P1 指纹漏输入：新增未分析照片/人工决策/人脸重跑不 stale | 指纹加入代表行数/资产数、人工决策 revision、face count/maxId；AI 应用不改指纹 | `fingerprintTracksNewInputs` |
| T0 | P2 人工决策只看代表行 | 按 gid 折叠任一变体 manual，整条资产跳过 | `manualVariantProtectsAsset` |
| T0 | P2 人脸信号只看代表行，变体有观测会丢 | 按 gid 聚合、每个变体取 max，既不双计也不丢 | 代码路径 |
| T0 | P2 空会话 generate 与 summary stale 不一致 | 0 照片时 summary stale=false；有照片无行才 stale | `emptySessionNotStale` |
| T0 | P2 generate/apply 无串行化 | service 内 `NSLock` 串行 generate/apply | 代码路径 |
| K0 | P1 生成词 origin 只覆盖 face_kw | culling/similarity/template/face_kw 全部映射并在 converge 记 origin | `generatedKeywordSourcesMap` |
| K0 | P1 连续 add→remove 丢净意图，X 残留 | cumulativeAdded/Removed 按本次 plan 双向过滤 | `deltaAddThenRemoveIsNet` |
| K0 | P1 blocked 预览不可见，确认后整批失败 | 面板显示“不可写/来源受保护/读取失败”，禁用确认 | 代码 + en 本地化 |
| F0 | P1 modelMode 含 unresolved 空 model，有效成员被误判 incompatible | 只用已解析、有向量、quality 达标的成员算众数 | `unresolvedMembersDoNotPoisonModelMode` |
| F0 | P1 merge/split 约束按“任意照片相交”删除，误删外部/内部约束 | merge 只删 source×target 跨侧 separate；split 只删跨两侧 together | `mergeKeepsExternalSeparate` / `splitKeepsInternalTogether` |
| F0 | P1 applyClusterConstraints 失败只记日志，可能留下半套约束 | 用嵌套事务（SAVEPOINT）包住约束应用，失败只回滚约束 | 代码路径 |
| B0 | P1 LogFileSink.install 返回值被丢弃，weak self 立即失效，文件日志不落盘 | AppBootstrap 静态强持有 sink | `installWritesLogFile` |
| B0 | P1 restore 不校验 journal 的 backupSHA256 | apply 前 `BackupVerifier.verify` + SHA 比对；不一致拒绝安装 | `restoreRejectsChangedBackup` |
| B0 | P1 launch 模式仍受 24h 守卫且写 autoDaily | launch 一次性 `.autoLaunch`，不走 24h；daily 保持 | 代码路径 |
| B0 | P1 诊断脱敏只覆盖 /Users、/Volumes | 统一绝对路径正则：/private /tmp /var /opt /mnt /home /root /Applications /Library | 代码路径 |
| B0 | P1 旧版本 2GB 恢复只预留 backup+128MB，迁移备份可能 ENOSPC | 旧 schema 额外预留一份备份大小 | 代码路径 |
| T0 | P1 `triage_enabled` / policy / 三个 confidence 未接设置页与 composition | 设置默认 0；`TriagePolicy.fromSettings`、service enabled gate、设置分组、工作区异步读取并隐藏卡片 | `settingsPolicyAndDisabled` |
| F0 | P2 单簇 review 返回的 summaries 覆盖其他簇 Badge | 全量替换、单簇按 id 合并 | 代码路径 |
| F0 | P2 review 游标找不到成员时按 cohesion 回退，可能跳/重 | 找不到即 `FACE_REVIEW_CURSOR_INVALID`，不再数值回退 | 代码路径 |
| F0 | P2 复核每页重算全部 embedding/cohesion | `reviewRevision` 聚合版本 + 会话/簇/阈值缓存；拆分后 revision 变化自动失效 | 拆分前后 review 测试 |
| K0 | P2 100 词限额按归一化前计数 | 先去重归一化再限额 | `editLimitAfterNormalization` |
| K0 | P2 共享侧车只回填首张照片 cache | 按 xmp 分组回填全部变体 | 代码路径 |
| K0 | P2 跨 session apply 只 flush 最后一个 session | 明确拒绝跨 session（`photoIds must belong to one session`） | 代码路径 |
| G0 | P2 Esc 只清选择，不退出全屏 | 全屏时先 `toggleFullScreen`，否则清选择 | 代码路径 |
| G0 | P2 service 只校验 cursor.sort/rowId，不校验 keyKind | service 层补 import/date/number key 校验，缺失即 `CULLING_CURSOR_INVALID` | `listPageValidation` |
| G0 | P2 无 20k UI 首屏基线 | 新增 `GATHER_UI_PERF=1`：离屏渲染 28.0ms、真实 NSWindow 首帧 27.2ms（200/20k） | `gridFirstPaint200Of20k` / `gridWindowFirstFrame` |
| T0 | P2 “已分析 X/Y” 用建议总数当分母，人工排除时偏差 | 改为按 coverage 显示百分比，不再伪造资产总数 | 代码路径 |
| T0 | P2 质量分析完成不自动生成建议 | `triage_auto_generate`（默认 0）+ 质量成功后可选 `generateTriage` | `autoGenerateTriageAfterQuality` |
| B0 | P2 多实例备份无目录锁，可能争同一 partial/最终名 | `BackupLock`（flock）跨进程互斥；备份全程持有 | `backupLockIsExclusive` |
| B0 | P2 保留份数无 UI，用户只能依赖默认 5 | 设置页 Picker（1...20）+ `saveBackupRetention` clamp | `saveBackupRetention` |
| B0 | P2 诊断包超 20MB 直接失败，不裁剪日志 | 超限时丢最旧日志重新打包（最多 3 轮），仍超限才失败；阈值可注入测试 | `diagnosticsTrimsOversizedBundle` |
| B0 | P2 2GB 备份仅 opt-in，默认/CI 不跑 | `nightly.yml` 增加 `GATHER_BACKUP_PERF=1` + 20k 分页性能门 | YAML 校验 |
| B0 | P2 恢复“稍后”后无 pending banner | 设置页新增“待完成恢复”区（备份名 + 退出按钮）；VM `restoreReceipt` 保持 | 代码路径 |
| B0 | P2 待恢复无法取消，journal 一直阻塞后续恢复/备份 | `RestoreCoordinator.cancelPending`（仅 prepared/opened）+ SceneState 闭包 + 设置页“取消待恢复” | `cancelPendingRestore`（core + app） |

## 3. 验证

- core：**1252 / 187** 绿；app：**687 / 78** 绿（`--no-parallel`）。
- 8 道 strict 门禁全绿：protocol、cleanup、design、docs、layering、no-legacy、test-catalog、preview。
- 新增回归覆盖：隐藏选择、箭头目标、页级 triage、指纹三类输入、变体人工决策、空会话、net delta、origin 映射、unresolved model、merge/split 约束、日志落盘、恢复 SHA。

## 4. 保留项（未在本轮修）

| 级 | 项 | 原因 / 建议 |
|---|---|---|
| P2 | 20k UI 真实窗口缩略图解码/滚动/键动作 p95 | 性能（首帧布局已测 27.2ms） |

## 5. 边界

- T0 真实集质量门仍未跑；本轮**不宣称**误杀率 <1%。
- 20k UI 真实窗口缩略图/滚动/键动作仍未测；离屏 SwiftUI 布局 p95 27.5ms，service 分页 8.7ms。
- 上述修复不改变 Schema V3 / 17 协议 / 121 方法；RC 需按修复后代码重建。
