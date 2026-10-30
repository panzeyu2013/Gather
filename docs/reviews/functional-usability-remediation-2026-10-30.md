# 功能性与易用性三轮评审收口（features → main）

- 日期：2026-10-30
- 合并提交：`e3f1276d`（`merge: 合入功能性与易用性整改（三轮评审收口）`）
- 基线：features `c77c3a57` + 未提交整改工作树；主分支合并前为 `a2030b51`
- 结果：features 工作树已快进到 `e3f1276d`，备份 worktree / `.review` 已移除

## 结论

三轮 12 路子评审（6+4+2）完成评审与修复。第一轮 9 个 P1 用户路径闭合；第二轮修掉 3 个 P1（⇧ 锚点、根修复监听单入口、alreadyPresent 第二目的地）；第三轮无 P0，保留 1 项设计层 P1：相似度/元数据写回无服务端预览令牌（仅人脸 token 链闭合）。其余为 P2 / GUI 未验收。

## 主要修复

- 导入/摄取：目录导入恒建 root、失败可见、0 张反馈、摄取 Job 化（进度/取消）、无根 fail-closed、根修复后重建监听、崩溃恢复 `alreadyPresent` 登记与第二目的地（含 sidecar）补拷。
- 挑片：普通点击收敛单选、自动前进同步选择、稳定 `selectionAnchorId`（连续 ⇧ 不丢段）、跨页选择 hash/count 绑定与 states 就地回显、相似组完整影响面确认、同步入口布局无关。
- 写回/设置：人脸 preview token（成员集合入指纹）、分级 reset + Confirmed + systemLanguage、偏好键白名单、设置缓存只并重置键。
- 导出/任务：selected 范围贯通并进入输出 job 身份、交付确认/预检、`executeDelivery`/reset 只收 Confirmed、批量 O(n²) 与同步态 N+1 修复、Gallery 全选代数守卫。
- 文档/门禁：协议/错误码/en 计数同步，新增 check-warnings，设计文档记录未做项。

## 验证（合并后 main）

- core：`1459 tests / 217 suites`，exit 0（`swift test --no-parallel`）
- app：`794 tests / 90 suites`，exit 0（`swift test --no-parallel`）
- 门禁：13/13 exit 0（12 个既有 + `check-warnings.sh`）
- schema 44/386/72/65、user_version=1；协议 344 类型/1985 声明；错误码 198；en 1849 键
- `git diff --check` 干净；diff 171 个已跟踪文件 + 15 个新文件，+4437/−633

## 残余

1. **P1（设计层）**：相似度/元数据写回无 `expectedPreviewToken` 与服务端复算，`METADATA_PREVIEW_STALE` 未落地；重聚类/并发分析后旧预览仍可能写旧关键词/字段。
2. **P2**：`TEMPLATE_*` / `DUP_*` 错误码与域映射仍缺；摄取失败 DTO 无 code/retryable；`PhotoAPI.select` 仍 500/页循环；摄取去重未按 size/mtime 预筛。
3. **P2/未验收**：交付 notice 无 severity、预检无忙碌态；人物多 dialog 同节点；FSEvents stop→start 在途旧根竞态；焦点/三布局/符号链接根/GUI 未实机。
