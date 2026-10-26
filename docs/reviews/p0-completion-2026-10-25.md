# Gather P0 验收报告（2026-10-25）

> 范围：G0 网格挑片、T0 技术质量初筛、K0 通用关键词、F0 人脸拆分/复核、B0 备份/恢复/诊断、X0 契约与门禁。
> 设计基线：[docs/design/p0/README.md](../design/p0/README.md)；契约：[x0-contracts.md](../design/p0/x0-contracts.md)。

## 1. 结论

**工程实现完成，全部仓库门禁、核心/应用测试、2GB 备份与 20k/50k 基准绿；唯一未执行的是 T0 真实集质量门，不能当作已通过。**

- 5 个工作流均已贯通“核心 → 服务 → API → UI”。
- Schema V3 上线：45 表 / 389 列 / 72 索引 / 65 外键，`user_version=3`，V1/V2 线性迁移。
- 协议面：17 协议 / 121 方法（Cut 1 基线 16/110）。
- core 1252 tests / 187 suites；app 687 tests / 78 suites；8 道 strict 门禁全绿。
- 全量 Review 与修复记录：[p0-full-review-2026-10-26.md](p0-full-review-2026-10-26.md)。
- 第二轮全量扫描与残留 P2 修复：[p0-second-scan-2026-10-26.md](p0-second-scan-2026-10-26.md)。
- 实现审计与修复记录：[p0-implementation-audit-2026-10-25.md](p0-implementation-audit-2026-10-25.md)（P0 隐藏选择、T0 指纹、F0 约束、B0 日志/恢复等）。
- 20k/50k 核心基准（release）已通过；unsigned `release/Gather.app` 已组装（arm64 / 3.0.0）。
- 未做：400 张真实照片双人标注评估、20k 网格真机性能、截图级视觉回归。

## 2. 交付范围

| 工作流 | 用户可见能力 | 关键位置 |
|---|---|---|
| G0 网格挑片 | 挑片页第 4 布局（单图/2/4/网格）、四角信息 + 最多 2 chip、500/200 分页、排序（import/capture/rating/triage）、⌘/⇧ 多选、键盘流、全屏、nextCursor | `GatherUI/Culling/CullingGrid.swift`、`CullingViewModel+Grid.swift` |
| T0 技术质量初筛 | 建议生成/过期重算、建议卡、网格徽标、复核队列（低置信优先）、应用决策（source=ai、可撤销、不写 XMP） | `Services/Triage/*`、`CullingTriageCard.swift` |
| K0 通用关键词 | 检查器关键词面板、批量加/删、只读预览（冲突可见）、delta 写回、生成词保护、自动补全 | `Protocol/KeywordEdit.swift`、`CullingKeywordPanel.swift` |
| F0 人脸拆分/复核 | 待复核 Badge、成员多选拆分（仅未绑定簇）、重聚类后保持、cohesion/低质/小脸/未解析标记、分页 | `FaceKwService+Split/+Constraints`、`FaceReviewMemberRowView.swift` |
| B0 备份/恢复/诊断 | 立即备份/备份列表/保留 N、跨进程恢复（journal+swap+回滚）、自动备份调度、20MB 脱敏诊断包 | `MaintenanceService`、`SettingsView+MaintenanceSection.swift` |
| X0 契约/门禁 | V3 迁移、typed cursor、错误码/设置键、l10n、ADR-031..033 | `docs/design/p0/*`、`docs/ADR.md` |

## 3. 契约与数据

- **Schema V3**：新增 `triage_suggestions`（10 列）、`face_cluster_constraints`（6 列，含 `peer_keys_json`）、3 索引；不改既有表。
- **迁移**：V1→V2→V3 线性；迁移前 `SchemaBackup`（`VACUUM INTO` + 校验），失败整体回滚；无 down migration，回退用 `.pre-v3-*`。
- **协议**：`CullingAPI` +2、`MetadataAPI` +3、`FaceAPI` +2、`MaintenanceAPI` 新 4；17/121。
- **错误码**：204（P0 新增 25：2 Culling / 4 Triage / 1 Keyword / 6 Face / 12 Maintenance）。
- **恢复语义**：`restore` 只写 journal 并退出；下次 `Database.open` 前 swap，旧库 `pre-restore-*` 保留 2 份；恢复后首次启动不回放旧 delivery。

## 4. 验证

### 4.1 测试

| 套件 | 结果 |
|---|---|
| gather-core | **1252 tests / 187 suites** 绿（含 T0 质量门指标 4 条 + 审计回归） |
| gather-app（`--no-parallel`） | **687 tests / 78 suites** 绿 |
| T0 质量门工具 | `gather-triage-eval` 编译通过；指标纯函数 4 tests 绿；3 照片临时夹具端到端 `--strict` 通过（仅工具自检） |
| P0 filtered（Culling/Triage/Keyword/Face/Maintenance/Contract） | 全绿；T0 20、K0 12、F0 4、B0 5、B0 UI 7、G0 8、T0 UI 5 |
| 20k 排序分页（env 门控） | `GATHER_CULLING_PERF=1`：capture/rating/triage p95 46.5 / 34.3 / 34.4ms |
| 迁移（V1→V3 / V2→V3 / 回滚 / 备份保留 / 指纹） | 绿 |

### 4.2 门禁

`check-protocol-surface --strict`、`check-cleanup-ratchet`、`check-design-system`、
`check-docs --strict`、`check-layering`、`check-no-legacy`、`check-test-catalog --strict`、
`check-preview-surface`：**全绿**。

- cleanup：`try_optional 229/230`、`unchecked_sendable 54/54`、`services_prepare 0/0`。
- 测试目录：198 文件，skip 11（全部 `.enabled`），缺文件头 0。
- 预览面：14 个 `#Preview`，12 个 PreviewSupport 文件。

## 5. 基准

**release 全档（2026-10-25 实测，`swift run -c release --disable-sandbox gather-core-benchmarks`）**

| 档位 | 耗时 | 关键指标 |
|---|---:|---|
| 20k dHash 聚类 | 174.6ms | 50 组 / 0 未分组 / 114,533 张/秒 |
| 50k dHash 聚类 | 5,795.7ms | 50 组 / 0 未分组 / 8,627 张/秒 |
| 20k embedding 聚类 | 995.9ms | 50 组 / 0 噪声 / 20,082 张/秒 |
| 50k embedding 聚类 | 5,400.3ms | 50 组 / 0 噪声 / 9,259 张/秒 |
| 20k LSH | 40.8ms（build 34.4 / query 6.4） | selfRecall@0.85 = 1.0000 |
| 50k LSH | 102.5ms（build 86.1 / query 16.3） | selfRecall@0.85 = 1.0000 |
| 全档总耗时 | **12.8s** | 20k+50k 全部通过 |

- debug 默认档在本机交互窗口（120s）内未完成，已停止；性能验收以 release 为准。
- 多档单趟（2k/20k dHash）：逐档一致、speedup 1.93 / 1.44。
- **20k 排序分页（SQL 读路径，2026-10-25）**：`GATHER_CULLING_PERF=1` 的 20k 内存库、200/页、连续 10 页，p95：capture **49.1ms**、rating **37.2ms**、triage **37.6ms**（debug；多次运行会波动）。
- **20k service 分页（2026-10-25）**：同一 env 门控下 `CullingService.listPage` 10 页 p95 **9.3ms**（debug，含富化装配；页面级 triage 已按页查询）。
- **20k UI 首屏渲染（2026-10-25）**：`GATHER_UI_PERF=1`，200 张/页（会话 total 20k）：
  - 离屏 `ImageRenderer` p95 **28.0ms**；
  - 真实 `NSWindow` + `cacheDisplay` 首帧 p95 **27.2ms**；
  - 两者均不含缩略图解码/滚动/键动作。
- **2GB 备份（2026-10-25）**：`GATHER_BACKUP_PERF=1`，2,014,154,752 字节库 → 备份 2,013,667,328 字节，**3.01s**（复跑；范围 3.0–3.9s），`verified=true`（预算 30s）。
- **仍未测**：真实窗口的缩略图解码/滚动/键动作 p95；首帧布局已有 27.2ms 基线。

```bash
cd desktop/native/gather-core
swift run --disable-sandbox gather-core-benchmarks
```

> 20k 网格真机未测；不得以核心基准替代 UI 性能验收。

## 6. 未完成 / 外部验收

1. **T0 真实集质量门**：需要 400 张真实照片 + 2 名摄影师独立标注（婚礼/活动、人像、体育、商品/风光各 100），按 t0-triage-policy §10 计算误杀率/复核率/覆盖率。**质量门 CLI 与指标已实现**（[操作手册](triage-quality-gate.md)，`gather-triage-eval --strict`），但真实标注集尚未提供，**不能宣称误杀率 <1%**。
2. **20k 网格性能**：未测 UI 首屏/键动作 p95；核心聚类与排序分页读路径已有基准。
3. **截图/真机交互**：未做视觉回归；键盘焦点依赖网格获焦。
4. **自动备份即时生效**：模式变更下次启动生效（UI 已明示）。

## 7. 升级与回滚

- 升级：V1/V2 库首次启动自动备份并迁移到 V3；不兼容库 fail-closed。
- 回滚：退出应用，用同目录 `gather.sqlite.pre-v3-*` 覆盖主库并移除 `-wal/-shm`，再用旧构建启动。
- 恢复：仅 `Backups/` 内托管备份；恢复前保留 `pre-restore-*`；恢复后首次启动不回放旧 intent。
- 打包：`CONFIGURATION=release ./desktop/native/build.sh` → `release/Gather.app`（2026-10-25 重建：arm64 / 3.0.0 / unsigned / not notarized；`Gather` 二进制 SHA-256 前缀 `591e5b5c…`（第二轮扫描全部产品 P2 修复后重建）；签名与公证属独立发布活动）。

## 8. 结论与建议

P0 的工程目标已达成，RC 已完成 unsigned 打包，可进入内测；**T0 对外承诺仍应保持“技术质量建议（Beta）”**，直到真实集质量门通过。建议下一轮优先：

1. 用真实 400 张集跑 T0 质量门并决定是否保留 Beta 标签；
2. 跑 20k 网格首屏/键动作真机基准；
3. 开启 Beta 后做 T0 真机交互验收；
4. 签名/公证/更新通道（独立发布活动）。

---

*本报告只记录本次 P0 代码与门禁结果；真实素材质量与商业信号属于外部验收。*
