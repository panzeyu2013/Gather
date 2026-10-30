# 功能性与易用性三轮评审收口（features → main）

- 日期：2026-10-30
- 合并提交：`e3f1276d`；残留修复：`9420b867`、`96f14acb`（`fix(residual): 补齐预览令牌/错误码/摄取与导出残余`）
- 基线：features `c77c3a57` + 未提交整改工作树；主分支合并前为 `a2030b51`
- 结果：features 分支已合入 main；备份 worktree / `.review` 已移除，当前仅 main worktree。

## 结论

三轮 12 路子评审（6+4+2）完成评审与修复。第一轮 9 个 P1 用户路径闭合；第二轮修掉 3 个 P1（⇧ 锚点、根修复监听单入口、alreadyPresent 第二目的地）；第三轮无 P0。残留修复已补相似度与元数据模板的 preview token / METADATA_PREVIEW_STALE。当前无已知 P1；剩余为 P2（inline/triage 直接写回、FSEvents 在途旧根竞态、人物多 dialog）与 GUI 未验收。

## 主要修复

- 导入/摄取：目录导入恒建 root、失败可见、0 张反馈、摄取 Job 化（进度/取消）、无根 fail-closed、根修复后重建监听、崩溃恢复 `alreadyPresent` 登记与第二目的地（含 sidecar）补拷。
- 挑片：普通点击收敛单选、自动前进同步选择、稳定 `selectionAnchorId`（连续 ⇧ 不丢段）、跨页选择 hash/count 绑定与 states 就地回显、相似组完整影响面确认、同步入口布局无关。
- 写回/设置：人脸 preview token（成员集合入指纹）、分级 reset + Confirmed + systemLanguage、偏好键白名单、设置缓存只并重置键。
- 导出/任务：selected 范围贯通并进入输出 job 身份、交付确认/预检、`executeDelivery`/reset 只收 Confirmed、批量 O(n²) 与同步态 N+1 修复、Gallery 全选代数守卫。
- 文档/门禁：协议/错误码/en 计数同步，新增 check-warnings，设计文档记录未做项。

## 验证（合并后 main）

- core：`1459 tests / 217 suites`，exit 0（`swift test --no-parallel`）
- app：`796 tests / 90 suites`，exit 0（`swift test --no-parallel`）
- 门禁：13/13 exit 0（12 个既有 + `check-warnings.sh`）
- schema 44/386/72/65、user_version=1；协议 344 类型/1990 声明；错误码 209；en 1862 键
- `git diff --check` 干净；残留修复 36 个文件，+467/−82

## 第二轮残留修复（2026-10-30）

- 新增预览令牌：相似度 `expectedPreviewToken`（结果 stats + 组员 + 交付项）与元数据模板 `expectedPreviewToken`（模板字段 + 照片集 + policy），服务端复算；新增 `METADATA_PREVIEW_STALE`。
- 摄取失败 DTO 增加 `code/retryable`，新增 `INGEST_CHECKSUM_MISMATCH` / `INGEST_DESTINATION_EXISTS` / `INGEST_PATH_INVALID` / `INGEST_TRANSFER_FAILED`。
- `PhotoAPI.select` 改为一次 CTE（20k），不再 500/页循环；摄取去重按源文件 size 预筛未回填 checksum。
- 交付 notice 增加 success/info/warning 语义色，预检增加忙碌态与按钮禁用。
- 错误码 209 / en 1862；Protocol 基线按 `--allow-growth` 从 1985 → 1990（5 个新码），已记账。

## 残余

1. **P2**：元数据 inline apply / triage writeback 是直接写回，没有 preview 阶段；若未来要求“预览→提交”同 token，需要补对应输入。
2. **P2**：人物合并/移除仍是同一 body 链上的多个 `.confirmationDialog`，存在宿主抢占风险；FSEvents `stop→start` 在途旧根竞态窗口仍在。
3. **未验收**：GUI 焦点、三布局、符号链接根、FSEvents、20k 批量体感未实机；x86_64/签名/公证未覆盖。
