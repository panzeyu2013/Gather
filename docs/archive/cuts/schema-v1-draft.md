# SchemaV1 设计草案（Cut 2 前置）

> 状态：**草案（draft）**，唯一产出物 = 本文件；未修改任何源码、脚本或其他文档。
> 依据：`docs/cleanup-backlog.md` §3（44 表 / 391 列 / 62 索引 / 63 FK 审计）、
> `docs/reviews/refactor-design-breaking-2026-10-21.md` §4（SchemaV1 / delivery / Database.open）、
> `docs/refactor-decisions.md` D-003（迁移测试处置）、D-008（smart_albums / workflow_templates 暂不删除），
> `desktop/native/gather-core/Sources/GatherCore/Database/{Schema,Migrations}.swift`、`Database/Repositories/*.swift` 的内联 SQL。
> 证据口径与行号来自 2026-10-21 的静态扫描；行号会漂移，引用前请重新 `read` 核对。

## 0. 审计口径修正（先读这一节）

本草案在动笔前对 `cleanup-backlog` §1 的「44 / 391 / 62 / 63」做了逐项复算（命令在下方，输出 `44 394`）。**列数基线错了**，而它正是 SchemaV1 的唯一对照表：

| 指标 | backlog | 复算 | 差异原因 |
| --- | --- | --- | --- |
| 表 | 44 | **44** | 一致（`Schema.swift` 与 `schema.snapshot.json` 集合相同） |
| 列 | 391 | **394**（`Schema.swift`）/ **396**（迁移后真实 schema） | ① 391 是**行级计数**：`face_identity_feedback` 把 `bbox_x..bbox_h` 四列写在一行（`Schema.swift:240`），只算了 1 个 → 少 3；② `face_clusters.synced_to_library`、`face_clusters.match_confidence` 只由 `Migrations.swift:160/162` 的 `ALTER TABLE ADD COLUMN` 创建，**不在 `Schema.swift` 里** → 少 2 |
| 索引 | 62 | **62** | 一致（`indexSQL` 61 + `uniquePhotoPathIndexSQL` 1） |
| 外键 | 63 | **63** | 一致（`REFERENCES` 计数，含 `writeback_items` 的 2 个表级 FK） |

**结论：SchemaV1 的对照基线必须是「迁移后的有效 schema」= 396 列**，不能拿 `Schema.swift` 的 394 列或 backlog 的 391 列当唯一对照——这正是 §8 R1（列级对账遗漏）的根因。

下方脚本的原样输出是 `44 394`：**44 表对，394 列不是最终值**（迁移再 +2 → 396）。

复现命令：

```bash
python3 - <<'PY'
import re
s = open('desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift').read()
schema = s.split('public static let schemaSQL = """')[1].split('"""')[0]
# 括号感知切分：行级正则会把 "bbox_x .. bbox_h" 同行四列算成 1 列（backlog 的 391 就是漏在这里）
def split_top(b):
    out, d, cur = [], 0, ''
    for ch in b:
        d += (ch == '(') - (ch == ')')
        if ch == ',' and d == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur); return out
tables = {}
for m in re.finditer(r'CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\n    \);', schema, re.S):
    body = re.sub(r'--[^\n]*', '', m.group(2))
    cols = [p.strip().split()[0] for p in split_top(body)
            if p.strip() and not re.match(r'(PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK|CONSTRAINT)\b', p.strip(), re.I)]
    tables[m.group(1)] = cols
print(len(tables), sum(len(c) for c in tables.values()))
PY
# 迁移独有列（不在 Schema.swift 里）
grep -n 'addColumn(db, "face_clusters"' desktop/native/gather-core/Sources/GatherCore/Database/Migrations.swift
```

---

## 1. 最终表清单（44 → 43）

处置口径：**删除** = V1 不建该表；**替换** = 由 delivery 模型接管；**保留** = 原表（可减列）进入 V1。
`smart_albums` / `workflow_templates` 按 **D-008** 保留（仅命令面可达、UI 未接线，但已有 typed API 计划，不计入死代码删除）。

| # | 表 | 处置 | 旧列 → 新列 | 一句话职责 |
| --- | --- | --- | --- | --- |
| 1 | sessions | 保留（−3） | 13 → 10 | 工作区会话：导入范围、索引代次（`index_seq`）、reload-ack 与照片计数。 |
| 2 | analysis_runs | 保留（+created_at） | 9 → 10 | 一次分析运行的不可变记录（kind/index_seq 快照），用于「结果是否过期」判定。 |
| 3 | photos | 保留（−2） | 16 → 14 | 会话内的一张照片行：路径、校验和、处理状态、所属逻辑资产/资产文件。 |
| 4 | assets | 保留（−1） | 5 → 4 | 逻辑资产（一组 RAW/JPEG 变体），承载「资产级」状态与生命周期。 |
| 5 | asset_files | 保留 | 14 → 14 | 物理文件行（卷 + 规范化路径 + file identity + 在线状态）。 |
| 6 | asset_members | 保留（+created_at） | 6 → 7 | 资产↔文件的多对多成员关系与主文件标记、绑定来源。 |
| 7 | asset_link_candidates | 保留 | 9 → 9 | 待人工确认的资产合并候选（RAW/JPEG 配对）与其裁决状态。 |
| 8 | session_assets | 保留 | 5 → 5 | 会话↔资产的出现关系（含展示文件与导入序）。 |
| 9 | sidecar_bindings | 保留 | 7 → 7 | sidecar（XMP）绑定：一张 XMP 对应哪些文件的归一化键。 |
| 10 | sidecar_binding_files | 保留（+created_at） | 2 → 3 | sidecar 绑定↔物理文件的关联行。 |
| 11 | sidecar_metadata_state | 保留 | 6 → 6 | sidecar 可写元数据的当前值（rating/label/keywords）与内容指纹。 |
| 12 | asset_backfill_state | 保留（−2） | 11 → 9 | 资产回填游标与批次统计（断点续跑）。 |
| 13 | analysis_jobs | 保留 | 24 → 24 | 异步任务队列：去重键、租约/心跳、进度、checkpoint、错误。 |
| 14 | asset_analysis | 保留 | 11 → 11 | 文件级分析结果（技术质量等）与输入指纹，按指纹去重。 |
| 15 | face_observations | 保留（−2） | 19 → 17 | 单张人脸的几何/嵌入/质量/模型版本（派生数据）。 |
| 16 | face_identity_feedback | 保留 | 11 → 11 | 用户对「这张脸是不是此人」的确认/否决，供下次匹配复用。 |
| 17 | face_analysis_state | 保留 | 6 → 6 | 每张照片的人脸分析输入指纹（size/mtime/signature），陈旧判定**唯一真相源**。 |
| 18 | face_cluster_state | 保留 | 3 → 3 | 会话级人脸聚类签名，决定是否需要重聚类。 |
| 19 | face_clusters | 保留（−3） | 12 → 9 | 人脸簇（派生数据）与「簇→身份」的显式链接（用户数据）。 |
| 20 | face_cluster_members | 保留 | 7 → 7 | 簇↔观察的成员关系（含 bbox 快照）。 |
| 21 | role_bindings | 保留 | 7 → 7 | 用户把簇绑定为某个角色/身份的关键词映射（用户数据）。 |
| 22 | similarity_hashes | 保留 | 6 → 6 | 感知哈希 + 文件指纹（文件变化即失效）。 |
| 23 | similarity_results | 保留 | 7 → 7 | 一次相似度分析的分组结果快照（JSON + 参数）。 |
| 24 | similarity_result_members | 保留 | 4 → 4 | 结果快照↔照片的展开行（供分页/筛选）。 |
| 25 | similarity_cluster_state | 保留 | 5 → 5 | 增量聚类的逐照片分量（photo_id **刻意无 FK**，见 §3.4）。 |
| 26 | similarity_cluster_meta | 保留 | 8 → 8 | 会话级聚类参数与版本（增量更新的基准）。 |
| 27 | app_settings | 保留 | 2 → 2 | 键值设置（唯一真相源，UI 与 PRAGMA 都读它）。 |
| 28 | persons | 保留 | 8 → 8 | 身份实体（姓名/关键词/备注/匹配阈值）。 |
| 29 | person_embeddings | 保留（−2） | 9 → 7 | 身份级向量库（供人脸匹配），observation 溯源。 |
| 30 | person_photos | 保留 | 7 → 7 | 身份↔照片的显式落库关系（含 bbox/置信度）。 |
| 31 | photo_metadata_cache | 保留 | 22 → 22 | **唯一元数据镜像读模型**（EXIF/评分/色标/关键词），供 FilterEngine 过滤排序。 |
| 32 | duplicate_groups | 保留 | 8 → 8 | 重复/相似照片组（exact / visual）及其裁决。 |
| 33 | duplicate_group_members | 保留 | 8 → 8 | 组成员、保留标记与逐成员裁决。 |
| 34 | culling_decisions | 保留 | 11 → 11 | 挑片决策（keep/reject/pending）+ 评分/色标 + 修订号。 |
| 35 | culling_history | 保留 | 5 → 5 | 可撤销的挑片操作日志。 |
| 36 | navigation_groups | 保留 | 10 → 10 | 连拍/场景分组的导航结果（含 lead photo 与解释）。 |
| 37 | metadata_keyword_origins | 保留 | 6 → 6 | 关键词来源归属（face-keyword / culling / similarity / template），用于安全撤回。 |
| 38 | smart_albums | 保留（D-008，改名 1 列） | 10 → 10 | 保存的筛选条件（智能相册）。 |
| 39 | workflow_templates | 保留（D-008） | 6 → 6 | 可复用的挑片模板配置。 |
| 40 | **asset_file_metadata** | **删除** | 15 → — | 上一代 EXIF 镜像表，全仓 0 读写（`grep` 见 §1.1）。 |
| 41 | **schema_version** | **删除** | 2 → — | 迁移版本表，由 `PRAGMA user_version` 取代。 |
| 42 | **metadata_outbox** | **替换** → deliveries / delivery_items | 16 → — | 交互式 XMP 写回队列（旧状态机）。 |
| 43 | **metadata_outbox_sessions** | **替换** → delivery_sessions | 4 → — | sidecar↔会话的确认关系。 |
| 44 | **writeback_items** | **替换** → delivery_items | 14 → — | 批量写回项（第二套状态机）。 |
| 45 | **deliveries**（新） | 新增 | — → 14 | 以 XMP sidecar 为单位的交付聚合（状态/基线/备份/租约）。 |
| 46 | **delivery_sessions**（新） | 新增 | — → 4 | 交付↔会话的确认关系（多对多）。 |
| 47 | **delivery_items**（新） | 新增 | — → 11 | 交付内逐（照片, 模块）的写回项与状态。 |
| 48 | **delivery_intents**（新） | 新增 | — → 8 | 跨事务的意图日志（prepared/fileDone/applied），供崩溃回放。 |

**合计：43 表 / 373 列**（44 − 2 删除 − 3 替换 + 4 新增；Cut 5 / 5b-2b 给 similarity_cluster_meta +3 列）。

核对式：`396（有效基线） − 51（随表消失） − 15（保留表删列） + 3（新增 created_at：analysis_runs / asset_members / sidecar_binding_files） + 37（4 张新表列） + 3（5b-2b 状态版本列：algorithm_version / input_signature / state_digest） = 373`。

### 1.1 删除表的证据

```bash
# asset_file_metadata：核心源与测试均 0 引用（排除 DDL/迁移）
grep -rn 'asset_file_metadata' --include=*.swift desktop/native | grep -v 'Schema.swift\|Migrations.swift'   # → 0 行
# schema_version：迁移设施（Migrations.swift:65-84），业务零引用
grep -rn 'schema_version' --include=*.swift desktop/native/gather-core/Sources | grep -v 'Migrations.swift\|Schema.swift'
# smart_albums / workflow_templates 仅命令面可达（D-008 保留）
grep -rn 'SELECT \* FROM workflow_templates' --include=*.swift desktop/native/gather-core/Sources
```

**`asset_file_metadata` 的 15 列没有任何消费方**：EXIF 的读模型是 `photo_metadata_cache`（`MetadataCacheRepo.swift:130-180` upsert、`FilterEngine.swift:89` `LEFT JOIN photo_metadata_cache`），两者同构，V1 不再保留上一代镜像。

---

## 2. 最终列清单（396 → 373）

### 2.1 保留表上的 15 个删列（逐列证据）

**判定规则**：写入点为常量/镜像 → 有写入无读取；或读取方已迁走。任一条成立且**无 WHERE 谓词**才判死。

| # | 表.列 | 写入 | 读取 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | assets.capture_fingerprint | 恒写 `''`（`AssetRepo.swift:1126`、`:997`） | 0 | 删 |
| 2 | asset_backfill_state.path_conflicts | 0 | 0 | 删（backlog §3.3-A 已列） |
| 3 | asset_backfill_state.sidecar_conflicts | 0 | 0 | 删（同上） |
| 4 | face_clusters.member_count | `FaceRepo.swift:678/708/1004` | 读取一律 `(SELECT COUNT(*) …)`（`:743`） | 删（列被同名列遮蔽） |
| 5 | face_clusters.synced_to_library | 仅 `Migrations.swift:160` 建列 | 0 | 删（**迁移独有列**） |
| 6 | face_clusters.thumbnail_base64 | 恒写 `''`（`FaceRepo.swift:708`） | 仅 `FaceRepo.swift:744` 行映射 → `FaceKwService.swift:1056` → Router 命令面（Cut 1 删除） | 删（Cut 1 后 0 消费者） |
| 7 | face_observations.source_file_size | 逐观察写入（`FaceRepo.swift:424`） | 0（陈旧判定走 `face_analysis_state`，`FaceRepo.swift:357/392`） | 删（写镜像） |
| 8 | face_observations.source_file_mtime_ms | 同上 | 同上 | 删（写镜像） |
| 9 | person_embeddings.quality | `PersonRepo.swift:404-406/725-736` | 0（阈值过滤用 `fo.quality`，`:752`） | 删（backlog 已列） |
| 10 | person_embeddings.face_bbox | 同上 | 0 | 删（backlog 已列） |
| 11 | photos.metadata | 仅 INSERT 常量 `'{}'`（`PhotoRepo.swift:294`） | 仅投影透传（`FilterEngine.swift:86`、`CullingService.swift`） | 删（值恒空） |
| 12 | photos.result | 同上 | 同上 | 删（值恒空） |
| 13 | sessions.writeback_status | `SessionRepo.swift:74/91/150` | 仅行投影 + 测试 | 删（delivery 接管） |
| 14 | sessions.failed_writeback_count | `SessionRepo.swift:75/91/155` | 仅行投影 + 测试 | 删（`delivery_items.status='failed'` 现算） |
| 15 | sessions.import_source | `SessionRepo.swift:52/91` | 生产 0（7 处均在测试） | 删 |

### 2.2 与 backlog §3.3-A「13 列」的差异（必须显式记录的 6 项修正）

| 项 | backlog 结论 | 本草案结论 | 证据 |
| --- | --- | --- | --- |
| `assets.status` | 死列（"恒 active"） | **保留** | 写入 3 个值：`AssetRepo.swift:1127/1153`（`offline_unverified`）、`SessionService.swift:125/142`（`orphan`）；且有 `WHERE status != 'orphan'` 谓词 |
| `face_clusters.synced_to_library` | 未提及 | **删** | 仅 `Migrations.swift:160` 建列，全仓 0 读点 |
| `face_clusters.thumbnail_base64` | 未提及 | **删** | 恒空 + 唯一消费者随 Cut 1 消失 |
| `face_observations.source_file_size/mtime_ms` | "保留（读路径依赖）" | **删** | 读路径实际是 `face_analysis_state`（`FaceRepo.swift:355-369/391-398`）；观察表上的两列只被 `INSERT…SELECT` 原样拷贝 |
| `persons.thumbnail_base64` | 未提及 | **保留（疑似死列 · 需产品确认）** | 从未写入（`PersonRepo.swift:297` INSERT 不含该列），但 UI 有 base64 回退分支（`PersonsView.swift:232/449`）；删列 = 删能力，交产品决定 |
| `sessions` 3 列 | "delivery 落地后删" | **V1 即删** | delivery 模型与 SchemaV1 同一 Cut 落地，双状态机不再并存 |

> 13 − 1（assets.status）+ 1（synced_to_library）+ 1（fc.thumbnail_base64）+ 2（face_observations）+ 3（sessions）= **19**；
> 其中 4 列（`metadata_outbox.owner_session_id/created_by_session_id`、`schema_version.applied_at`、`writeback_items.backup_path`）随表消失，故**保留表上的删列 = 15**。

### 2.3 改名列（2 个，其余一律不改名）

| 旧名 | 新名 | 理由 | 需同步的站点 |
| --- | --- | --- | --- |
| `analysis_runs.params` | `analysis_runs.params_json` | 与 `*_json` 命名统一，避免误当字符串参数 | `SimilarityService.swift:854`、`FaceKwService.swift:1775`（+ 读点） |
| `smart_albums.schema_version` | `smart_albums.filter_schema_version` | 与已删除的 `schema_version` 表同名，易误读为 DB 版本 | `SmartAlbumRepo` |

**明确不改名**（虽然同名不同域）：`duplicate_groups.resolution` 与 `duplicate_group_members.resolution`（组级 vs 成员级）、`photo_metadata_cache.file_mtime`（TEXT，过滤字段）。理由：156 处内联 SQL 测试按列名逐字绑定，改名的收益低于连带改动风险；两者记入 §8 R1（改名列的连带风险与删列同级）。

### 2.4 old → new 列映射表（V1 中**不再存在**的 63 个旧列）

这一节是「146/156 个内联 SQL 用例」的对照表：**任何出现在左列的 SQL 字面量在 V1 都会 `prepare` 失败（no such column）**——失败是响亮的，不是静默的。

| 表 | 旧列 | V1 处置 | 新位置 / 替代查询 |
| --- | --- | --- | --- |
| sessions | writeback_status | 删除 | 会话级写回态改由 `deliveries` 聚合：`SELECT status, COUNT(*) FROM deliveries d JOIN delivery_sessions ds ON ds.delivery_id=d.id WHERE ds.session_id=?` |
| sessions | failed_writeback_count | 删除 | `COUNT(*) FROM delivery_items di JOIN delivery_sessions ds … WHERE di.status='failed'` |
| sessions | import_source | 删除 | 无替代（`source_path`/`truncated_import` 保留） |
| photos | metadata | 删除 | 无替代（恒 `'{}'`；历史行本来就无内容） |
| photos | result | 删除 | 同上 |
| assets | capture_fingerprint | 删除 | 无替代（恒 `''`） |
| asset_backfill_state | path_conflicts | 删除 | 无替代（从未写入） |
| asset_backfill_state | sidecar_conflicts | 删除 | 无替代（从未写入） |
| face_clusters | member_count | 删除 | `(SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id=c.id)`（现有读法不变） |
| face_clusters | synced_to_library | 删除 | 无替代（0 读点） |
| face_clusters | thumbnail_base64 | 删除 | `thumbnail_path` |
| face_observations | source_file_size | 删除 | `JOIN face_analysis_state s ON s.photo_id = fo.photo_id AND s.session_id = fo.session_id` |
| face_observations | source_file_mtime_ms | 删除 | 同上 |
| person_embeddings | quality | 删除 | `JOIN face_observations fo ON fo.id = pe.face_observation_id → fo.quality` |
| person_embeddings | face_bbox | 删除 | `JOIN face_cluster_members fcm ON fcm.observation_id = pe.face_observation_id → fcm.bbox` |
| asset_file_metadata | file_id, date_taken, camera_make, camera_model, lens_model, focal_length, f_number, exposure_time, iso, gps_latitude, gps_longitude, width, height, cached_at, updated_at（15） | 整表删除 | `photo_metadata_cache`（唯一镜像） |
| schema_version | version | 整表删除 | `PRAGMA user_version`（= 1） |
| schema_version | applied_at | 整表删除 | 无替代（0 读点） |
| metadata_outbox | xmp_path | 替换 | `deliveries.xmp_path`（UNIQUE） |
| metadata_outbox | owner_session_id | 替换 | `delivery_sessions.session_id`（多对多） |
| metadata_outbox | created_by_session_id | 替换 | `delivery_sessions.session_id`（同上；归属不再用两列表达） |
| metadata_outbox | photo_path | 替换 | `deliveries.photo_path` |
| metadata_outbox | patch_json | 替换 | `delivery_items.attributes_json`（按 module 拆分，见 §5.3） |
| metadata_outbox | dirty_fields | 替换（派生） | `attributes_json` 的键集合，**不落列** |
| metadata_outbox | source_module | 替换 | `delivery_items.module`（结构化归属，替代 `__owners__`） |
| metadata_outbox | revision | 替换 | `deliveries.revision` |
| metadata_outbox | persisted_revision | 合并 | `deliveries.revision`（`written` 时的值；summary DTO 的 `persistedRevision` 直接取它） |
| metadata_outbox | base_fingerprint | 替换 | `deliveries.base_fingerprint` |
| metadata_outbox | base_values_json | 替换 | `deliveries.base_values_json` |
| metadata_outbox | backup_path | 替换 | `deliveries.backup_path` |
| metadata_outbox | status | 替换 | `deliveries.status`（`clean`/`cleaned` 二值废弃，见 §4.5） |
| metadata_outbox | attempt_count | 替换 | `deliveries.attempt_count` |
| metadata_outbox | error_message | 替换 | `deliveries.error_message` |
| metadata_outbox | updated_at | 替换 | `deliveries.updated_at` |
| metadata_outbox_sessions | xmp_path | 替换 | `delivery_sessions.delivery_id` |
| metadata_outbox_sessions | session_id | 替换 | `delivery_sessions.session_id` |
| metadata_outbox_sessions | confirmed_at | 替换 | `delivery_sessions.confirmed_at` |
| metadata_outbox_sessions | linked_at | 替换 | `delivery_sessions.created_at` |
| writeback_items | id | 替换 | `delivery_items.id` |
| writeback_items | photo_id | 替换 | `delivery_items.photo_id` |
| writeback_items | session_id | 替换 | `delivery_sessions.session_id`（经 `delivery_id` 关联，**不再冗余存两份**） |
| writeback_items | module | 替换 | `delivery_items.module` |
| writeback_items | keywords | 替换 | `delivery_items.keywords` |
| writeback_items | attributes_json | 替换 | `delivery_items.attributes_json` |
| writeback_items | photo_path | 替换 | `deliveries.photo_path` |
| writeback_items | xmp_path | 替换 | `deliveries.xmp_path` |
| writeback_items | backup_path | 替换 | `deliveries.backup_path`（backlog 判死列，随表消失） |
| writeback_items | xmp_status | 替换 | `delivery_items.status` |
| writeback_items | error_message | 替换 | `delivery_items.error_message` |
| writeback_items | attempt_count | 替换 | `delivery_items.attempt_count` |
| writeback_items | last_attempt_at | 合并 | `delivery_items.updated_at`（两者只在 `updateStatus` 同一语句写入，语义等价） |
| writeback_items | created_at | 替换 | `delivery_items.created_at` |

**新增列（40）**：`analysis_runs.created_at`、`asset_members.created_at`、`sidecar_binding_files.created_at`（3 个审计列，值由 DDL 的 `strftime` 默认值生成，不新增写入点）+ `deliveries`(14) + `delivery_sessions`(4) + `delivery_items`(11) + `delivery_intents`(8) = 40。

### 2.5 内联 SQL 测试的受影响面（量化）

复算命令与结果（`prepare(` 计数、`@Test` 块内含 `prepare(` 的块数）：

```bash
grep -rn 'prepare(' --include=*.swift desktop/native/*/Tests | wc -l          # 400（42 个文件）
python3 - <<'PY'
import re, glob
n = 0
for f in glob.glob('desktop/native/*/Tests/**/*.swift', recursive=True):
    for ch in open(f).read().split('@Test')[1:]:
        n += bool(re.search(r'\bprepare\(', ch))
print(n)
PY
```

- **实测 156 个用例块含内联 SQL**（`test-audit.md:244` 的 146 未给复现命令，口径可能不同；V1 验收以 156 为基线）。
- 命中的删列站点（SQL 字面量精确匹配，`/` 前为核心源、后为测试）：

| 删列 | 核心源 | 核心测试 | app 测试 |
| --- | --- | --- | --- |
| sessions.writeback_status | 3 | 7 | 4 |
| sessions.import_source | 2 | 7 | 4 |
| sessions.failed_writeback_count | 3 | 4 | 0 |
| photos.metadata | 1 | 24 | 4 |
| photos.result | 1 | 23 | 4 |
| assets.capture_fingerprint | 2 | 9 | 1 |
| face_clusters.member_count | 5 | 6 | 0 |
| person_embeddings.quality | 3 | 3 | 0 |
| person_embeddings.face_bbox | 2 | 3 | 0 |
| asset_backfill_state.path_conflicts/sidecar_conflicts | 0 | 0 | 0 |

> 其中 `photos.metadata/result`（合计 52 处）是最大改动面：`FilterEngine.swift:86` 的投影、`CullingService` 的 `CullingPhotoRow` 透传字段、以及大量测试的 `INSERT INTO photos (…, metadata, result, …)`。建议 Cut 2 用 `sed` 类脚本一次性删除这些列引用，而不是逐个手改。

### 2.6 列序（row mapper）风险

**删列会改变 `SELECT *` 的行偏移**：核心源有 **42 处 `SELECT *`**，行类型按**位置下标**取值，例如 `AnalysisJobRepo.swift:52-64` 的 `id=row[0] … updatedAt=row[23]`、`PhotoRepo.swift:195`（`SELECT * FROM photos` → `PhotoRow(row:)`）、`AssetRepo.swift:145` 的 `SELECT rowid AS migration_rowid, *`。

V1 的强制要求（写进 Cut 2 验收）：

1. 所有 `SELECT *` 改为**显式列清单**（Row 类型不再依赖表内位置）；
2. `SchemaV1Tests` 断言 `PRAGMA table_info(t)` 的列名数组与 §7 的 DDL 逐字一致（防止「新库列序」与「mapper 假设」分叉）；
3. 行类型初始化改为 `init(row:)` 内按列名查找（或保留位置但由测试锁定列序）。

---

## 3. 最终索引 / 外键清单

### 3.1 索引总账：62 → 69

| 处置 | 数量 | 明细 |
| --- | --- | --- |
| 逐字保留 | 50 | 语义与查询形态都成立，名称不变（`EXPLAIN QUERY PLAN` 校准项见 3.3） |
| 重定义 | 1 | `idx_asset_candidates_status(status)` → `idx_asset_candidates_relation_status(relation_type, status)`（唯一读法是 `relation_type='raw_jpeg' AND status='pending'`，`AssetRepo.swift:243/593/598/608`） |
| **删除（死索引 · 保留表上）** | **2** | `idx_asset_backfill_status`（只按 PK 查询，`AssetRepo.swift:129/188`）；`idx_similarity_cluster_state_component`（读法是 `WHERE session_id=? ORDER BY rowid`，`SimilarityClusterStateRepo.swift:109-110`） |
| **删除（死索引 · 随替换表消失）** | **2** | `idx_metadata_outbox_session_status`、`idx_metadata_outbox_owner_module`（前导列 `owner_session_id` 本身也要删，索引无支撑） |
| **删除（冗余）** | **4** | 被更宽的 UNIQUE/PK 前导列覆盖：`idx_photos_session`（→ `unique(session_id, filepath)`）、`idx_asset_members_asset`（→ `PK(asset_id, file_id)`）、`idx_similarity_hashes_session`（→ `unique(session_id, photo_id)`）、`idx_person_photos_person`（→ `unique(person_id, photo_id)`） |
| 随替换表消失（非死） | 3 | `idx_writeback_items_session`、`idx_writeback_items_photo`、`idx_metadata_outbox_sessions_session`（`idx_writeback_items_photo` 的 FK 级联职责由 `idx_delivery_items_photo` 接管） |
| **新增** | **18** | ① FK 级联缺口 13 个（见 3.4）；② delivery 5 个（`idx_deliveries_status`、`idx_delivery_sessions_session`（由 `idx_metadata_outbox_sessions_session` 平移）、`idx_delivery_items_photo`、`idx_delivery_items_module_status`、`idx_delivery_intents_phase`） |

对账：`62（旧） = 50 保留 + 1 重定义 + 2 死 + 2 死（随表） + 4 冗余 + 3 随表`；`69（V1） = 50 保留 + 1 重定义（改名）+ 18 新增`。与 backlog §3.4 的「死索引 4 个」逐项对应。

**索引审计必须区分「查询索引」与「FK 级联索引」**（backlog §3.4 的结论）：`include` 在 `PRAGMA foreign_keys = ON` 下，删父行时 SQLite 会对每个子表做「按子列查找」的动作（CASCADE 删除/SET NULL 置空），子列**没有前导索引就是全表扫**。

### 3.2 外键策略：63 → 62

| 动作 | 数量 | 适用范围 |
| --- | --- | --- |
| **ON DELETE CASCADE** | **56** | 一切「派生数据」与「会话/照片/簇/交付域内的从属行」：`analysis_runs`、`photos`、`asset_members`、`asset_link_candidates`、`session_assets`、`sidecar_binding_files`、`sidecar_metadata_state`、`asset_backfill_state`、`asset_analysis.asset_file_id`、`face_observations`、`face_identity_feedback`、`face_analysis_state`、`face_cluster_state`、`face_clusters`、`face_cluster_members`、`role_bindings`、`similarity_*`、`person_embeddings`、`person_photos`、`photo_metadata_cache`、`duplicate_*`、`culling_decisions/history`、`navigation_groups`、`delivery_sessions`、`delivery_items` |
| **ON DELETE SET NULL** | **6** | 关系型/弱引用：`photos.asset_id`、`photos.asset_file_id`（照片仍在，只是暂时无资产）、`session_assets.display_file_id`（展示文件消失不删归属）、`asset_analysis.photo_id`（文件级分析可脱离照片存在）、`face_clusters.matched_person_id`（身份删了但簇还在）、`navigation_groups.lead_photo_id`（lead 消失不删组） |
| **无 FK（刻意）** | 5 列 | `person_embeddings.face_observation_id`（`Schema.swift:385-392` 的理由：派生数据整批 DELETE+INSERT，加 FK 会阻断「先删向量再删观察」）、`similarity_cluster_state.photo_id`（`Schema.swift:324-326`：残留行是增量 diff 的「已移除」依据）、`analysis_jobs.scope_id`（多态作用域）、`metadata_keyword_origins.xmp_path`、`delivery_intents.xmp_path`（意图必须能在交付行删除后存活，这正是回放的前提） |

旧口径对照（可复算）：`63 = 46 CASCADE + 15 NO ACTION + 2 SET NULL`；V1 把这 15 个 NO ACTION 拆成 **11 个 CASCADE + 4 个 SET NULL**（原本 2 个 SET NULL 不动），加上删除 3 张被替换表的 5 个 FK、新增 delivery 的 4 个，得 `62 = 56 + 6`。

**这一条改动的收益**：`SessionService.deleteSessionDependencies`（`SessionService.swift:152-169`）今天必须按 6 步手写顺序删（簇→观察→相似度→person_embeddings→person_photos→metadata_cache→writeback→jobs→photos），注释明确写着「必须先于 photoRepo.deleteBySession」。V1 之后该方法收缩为一次 `DELETE FROM sessions WHERE id = ?`，删除顺序由 FK 图决定。

**FK 顺序仍有 3 个坑**（写进 Cut 2 测试）：

1. **同一子行有两个父**：`face_cluster_members` 同时是 `face_clusters`/`sessions`/`photos`/`face_observations` 的子表，任一父删除都会级联；`role_bindings` 是**用户数据**，今天靠「先删绑定再删簇」保护（`FaceRepo.swift:914/1001`），改 CASCADE 后 `DELETE FROM face_clusters` 会静默带走绑定——必须保留「解除绑定」作为显式业务动作，不能靠级联表达。
2. **SET NULL 与 CASCADE 混用**：删 `sessions` → `photos` CASCADE → `asset_analysis.photo_id` SET NULL（行留下）；而删 `asset_files` → `asset_analysis.asset_file_id` CASCADE（行删掉）。同一张表两种结局，测试要分别覆盖。
3. **递归深度**：`sessions → photos → face_observations → face_cluster_members`、`sessions → face_clusters → role_bindings` 是两条独立路径，SQLite 按语句粒度执行，不需要手写顺序，但**要求所有 FK 都显式写动作**（默认 NO ACTION 会让删除中途失败并回滚整条语句）。

### 3.3 需 `EXPLAIN QUERY PLAN` 校准的 4 个索引（Cut 2 门禁）

`idx_photos_created_at`（仅 `sortBy=created_at` 排序）、`idx_metadata_cache_camera_make`（FilterEngine suggest 的 LIKE 前缀）、`idx_similarity_members_result_group`、`idx_analysis_jobs_scope`（仅 `scope_type+scope_id` 等值）。校准不通过就删，不保留"可能有用"的索引。

### 3.4 FK 级联索引缺口（V1 补齐 13 个）

旧 schema 有 15 个 FK 没有对应的子列前导索引，删父行时退化为全表扫。V1 新增：

| 新增索引 | 服务的 FK / 查询 |
| --- | --- |
| `idx_asset_candidates_left` / `idx_asset_candidates_right` | `asset_link_candidates.left_file_id / right_file_id` → asset_files CASCADE |
| `idx_face_identity_feedback_photo` / `_person` | CASCADE from photos / persons |
| `idx_face_cluster_members_photo` / `_observation` | CASCADE from photos / face_observations |
| `idx_similarity_members_photo` | CASCADE from photos |
| `idx_person_embeddings_photo` / `_session` | CASCADE from photos / sessions |
| `idx_duplicate_members_session` | CASCADE from sessions |
| `idx_culling_decisions_photo` | CASCADE from photos |
| `idx_role_bindings_session` | CASCADE from sessions |
| `idx_navigation_groups_lead` | SET NULL from photos（"找出要置空的行"同样需要索引） |
| `idx_delivery_items_photo` | CASCADE from photos（同时服务照片粒度页面） |
| `idx_delivery_items_module_status` | `getItems(sessionId, module, status)` 的新查询形态 |
| `idx_delivery_sessions_session` | 由 `idx_metadata_outbox_sessions_session` 平移 |
| `idx_deliveries_status` | 租约恢复/清理扫描（`WHERE status='writing'`） |
| `idx_delivery_intents_phase` | 启动回放：`WHERE phase IN ('prepared','fileDone') ORDER BY id` |

> 代价：索引从 62 → 69（写放大约 +10%）。取舍：这些索引同时是**删除性能**与**新的照片粒度交付页**的支撑；若 Cut 2 基准显示写放大不可接受，优先砍 `idx_asset_candidates_left/right`（该表写入频率最低、删除频率也最低）。

---

## 4. CHECK 约束：状态列与 Swift enum 对齐

### 4.1 规则

1. **每个 CHECK 的取值集合必须由 Swift enum 的 `allCases.map(\.rawValue)` 生成**（`SchemaV1.swift` 里拼 SQL 片段），测试断言 `Set(enum.allCases) == Set(CHECK 集合)` —— 双向相等，任一侧漂移即红。
2. 权限分层：**转移合法性只在 Swift 状态机里定义**（`canTransition`），DB 的 CHECK 只兜「非法字符串」，不兜「非法转移」。
3. 单值集合（如 `sidecar_bindings.status = 'active'`）也要写 CHECK：新增值必须同 PR 改 enum + CHECK。

### 4.2 状态列对照表（`value` 全部来自源码实测）

| 列 | Swift enum | 合法值 | 证据 |
| --- | --- | --- | --- |
| `sessions.status` | `SessionStatus`（已有） | `draft`, `photos_loaded`, `analyzing`, `review`, `completed` | `Protocol/Core.swift:16-22` |
| `sessions.truncated_import` | Bool | `0`, `1` | `SessionRepo` 写入 |
| `photos.status` | `PhotoStatus`（**新建**） | `pending`, `ready`, `removed`, `missing` | `PhotoRepo.swift:294`（pending）、`DuplicateService.swift:673/689/709`（removed/ready）、`PhotoRepo.swift:346`（missing） |
| `assets.status` | `AssetStatus`（**新建**） | `active`, `orphan`, `offline_unverified` | `AssetRepo.swift:1127/1153`、`SessionService.swift:125/142` |
| `asset_files.media_type` | `AssetMediaType`（**新建**） | `unknown`, `image`, `raw` | `AssetRepo.swift:1207-1212` |
| `asset_files.online_status` | `AssetOnlineStatus`（**新建**） | `online`, `offline` | `IndexerService.swift:523/744`、`AssetRepo.swift:438/537` |
| `asset_members.member_role` | `AssetMemberRole`（**新建**） | `raw`, `camera_jpeg`, `rendered_tiff`, `unknown` | `AssetRepo.swift:1214-1219` |
| `asset_members.binding_source` | `AssetBindingSource`（**新建**） | `import`, `backfill`, `manual_split` | `Schema.swift:85` 默认 `import`、`AssetRepo.swift:1132/1001` |
| `asset_link_candidates.relation_type` | `AssetLinkRelation`（**新建**） | `raw_jpeg` | `AssetRepo.swift:243/593/608/904` |
| `asset_link_candidates.status` | `AssetLinkStatus`（**新建**） | `pending`, `accepted`, `rejected` | `AssetRepo.swift:564/580/593` |
| `sidecar_bindings.status` | `SidecarBindingStatus`（**新建**） | `active` | `PhotoAssetResolver.swift:84` 谓词；唯一写入值 |
| `asset_backfill_state.status` | `BackfillStatus`（**新建**） | `running`, `completed`, `failed` | `AssetRepo.swift:135/188/195` |
| `analysis_jobs.type` | `AnalysisJobType`（已有） | `metadata.scan`, `thumbnail.build`, `similarity.analyze`, `duplicate.scan`, `face.analyze`, `quality.score`, `export.execute`, `checksum.backfill` | `Protocol/Jobs.swift:9-18` |
| `analysis_jobs.status` | `AnalysisJobStatus`（已有） | `queued`, `running`, `succeeded`, `failed`, `cancelled`, `interrupted`, `cancelling` | `Protocol/Jobs.swift:21-29` |
| `analysis_runs.kind` | `AnalysisRunKind`（**新建**） | `face`, `similarity` | `FaceKwService.swift:640`、`SimilarityService.swift:256` |
| `analysis_runs.status` | `AnalysisRunStatus`（**新建**） | `running`, `ok`, `failed` | `SimilarityService.swift:855`（running）、`:865-866`（ok/failed） |
| `face_clusters.status` | `FaceClusterStatus`（**新建**） | `unbound`, `bound` | `FaceRepo.swift:909/915/929`、`PersonRepo.swift:495` |
| `face_identity_feedback.decision` | `FaceFeedbackDecision`（**新建**） | `confirmed`, `rejected` | 既有 CHECK（`Schema.swift:242`） |
| `similarity_cluster_meta.grouping_mode` | `SimilarityGroupingMode`（已有） | `sequential`, `global` | `Protocol/Similarity.swift`、`SimilarityService.swift:729` |
| `duplicate_groups.group_type` | `DuplicateGroupType`（**新建**） | `exact`, `visual` | `DuplicateService.swift:488/791` |
| `duplicate_groups.resolution` | `DupResolution`（已有） | `keep_all`, `keep_one`, NULL | `Protocol/Duplicate.swift:35-36`、`DuplicateService.swift:657-659` |
| `duplicate_group_members.resolution` | 同上 | `keep_all`, `keep_one`, NULL | `DuplicateService.swift:598/657-659` |
| `culling_decisions.decision` | `CullingDecisionValue`（已有） | `keep`, `reject`, `pending` | `Protocol/Culling.swift:24-28` |
| `culling_decisions.color_label` | `CaptureOneColorLabel`（已有） | `None`, `Red`, `Orange`, `Yellow`, `Green`, `Blue`, `Pink`, `Purple` | `Protocol/Culling.swift:39-48` + 既有 CHECK |
| `culling_decisions.decision_source` | `CullingDecisionSource`（已有） | `manual`, `ai`, `template`, `imported` | `Protocol/Culling.swift:31-36` |
| `navigation_groups.group_type` | `NavigationGroupType`（**新建**） | `burst`, `scene` | 既有 CHECK（`Schema.swift:506`） |
| `navigation_groups.source` | `NavigationGroupSource`（已有） | `automatic`, `manual` | `Protocol/Navigation.swift`、`NavigationService.swift:402/431` |
| `metadata_keyword_origins.source` | `MetadataKeywordSource`（**新建**） | `face-keyword`, `culling`, `similarity`, `template` | `Migrations.swift:801` 的来源集合 + `WritebackService.swift:557/575` |
| `deliveries.status` | `DeliveryStatus`（**新建**） | `pending`, `writing`, `written`, `synced`, `failed`, `conflict`, `cleaned` | §4.5 + §5.2 |
| `delivery_items.status` | `DeliveryItemStatus`（**新建**） | `pending`, `written`, `synced`, `failed` | `WritebackRepo.swift:76/179`、`WritebackService.swift:507/516` |
| `delivery_items.module` | `DeliveryModule`（**新建**） | `culling`, `face-keyword`, `similarity`, `template`, `metadata` | `WritebackService.swift:557`（face-keyword）+ `CullingService.swift:1262`（culling）+ `Migrations.swift:801` |
| `delivery_intents.kind` | `DeliveryIntentKind`（**新建**） | `cleanup`, `write` | §5.2 |
| `delivery_intents.phase` | `DeliveryIntentPhase`（**新建**） | `prepared`, `fileDone`, `applied` | §5.2 |

### 4.3 布尔 / 数值 CHECK

`is_primary`, `is_kept`, `active`, `undone`, `truncated_import` ∈ (0,1)；`rating` ∈ [0,5]（三处，沿用既有 CHECK）；`quality` ∈ [0,1]（`FaceQuality.swift:5` 明确「质量分 [0,1] 存入 face_observations.quality」）；`revision`/`attempt_count`/`photo_count`/`index_seq`/`progress_*`/`import_order`/`member_count` >= 0；`param_threshold` ∈ [0,64]（64 位 dHash 的汉明距离上界，**Cut 2 需在 API 层同步钳制**，见 D-012）；`param_min_group_size` >= 1。

### 4.4 明确**不加** CHECK 的列（避免发明值域）

`asset_analysis.analysis_type`（自由字符串，如 `technical_quality`，无 enum）、`sidecar_metadata_state.label` / `photo_metadata_cache.label`（XMP sidecar 可能含任意标签值）、`analysis_jobs.scope_type`（当前只写 `'session'`，但作用域尚未收敛为 enum，V1 只加非空约束，Cut 3 引入 `JobScopeType` 后再收紧）、`binding_rule`（当前只写 `same_basename`，但属规则引擎输入，留扩展）、`confidence` 各列（无文档化值域）。

### 4.5 状态机与 enum 漂移（现存 3 处，V1 必须一并清掉）

1. **`SessionStatus` 之外的 `indexed`**：`TemplateServiceTests.swift:175` 断言错误文案里出现 `"indexed"`，但 enum 无此值——旧测试会随 Cut 1/2 改写；若 UI 仍有写入点，V1 的 CHECK 会在运行期直接报错（这是我们要的：把静默漂移变成响亮失败）。
2. **`MetadataSyncStatus` 有 8 值（含 `clean`/`cleaned`）**：`MetadataOutboxRepo.swift:27-30` 注释确认 `clean`/`cleaned` 是「历史版本终态，当前代码不再产生」。V1 的 `deliveries.status` 只保留 7 值（去 `clean`），`MetadataSyncStatus` 随之收敛为 `DeliveryStatus`。
3. **`writeback_items.xmp_status` 是 String 而非 enum**：`WritebackRepo.updateStatus(status: String)`（`:116`）允许任意字符串。V1 用 `DeliveryItemStatus` 收敛，Repo 签名改类型化 enum。

---

## 5. 统一 delivery 模型

### 5.1 为什么要合并（现状证据）

- 两套状态机：`MetadataOutboxStatus`（`MetadataOutboxRepo.swift:20-59`，8 值 + 迁移表）与 `writeback_items.xmp_status`（无 enum，String）。
- 两条互不相交的"确认"：`CullingService.confirmSync`（`CullingService.swift:1273-1278`）= `metadataSync.confirmSync` **然后** `writeback.confirmSync`，两次独立提交，期间崩溃 → 一半已确认一半没有。
- 两条互不相交的"清理"：`cleanup`（`:1282-1290`）= 协调器清理 **然后** 写回清理，结果相加。
- 同一份事实写两处：`AssetRepo.relocateMetadataState`（`:687-746`）要同时迁 `metadata_outbox`、`metadata_outbox_sessions`、`writeback_items`、`metadata_keyword_origins` 四张表；`sessions.writeback_status` 只有 1 处 UPDATE（`SessionRepo.swift:150`），UI 却按两套表分别查询（`WorkspaceStatusService.swift:178-192`）。

### 5.2 DDL（V1 实际建表语句，已在 §7 全文中）

```sql
CREATE TABLE deliveries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  xmp_path TEXT NOT NULL UNIQUE,
  photo_path TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','writing','written','synced','failed','conflict','cleaned')),
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  base_fingerprint TEXT NOT NULL DEFAULT '',
  base_values_json TEXT NOT NULL DEFAULT '{}',
  backup_path TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  lease_owner TEXT NOT NULL DEFAULT '',
  heartbeat_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE delivery_sessions (
  delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  confirmed_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (delivery_id, session_id)
);

CREATE TABLE delivery_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  module TEXT NOT NULL CHECK (module IN ('culling','face-keyword','similarity','template','metadata')),
  attributes_json TEXT NOT NULL DEFAULT '{}',
  keywords TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','written','synced','failed')),
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (delivery_id, photo_id, module)
);

CREATE TABLE delivery_intents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('cleanup','write')),
  xmp_path TEXT NOT NULL,
  phase TEXT NOT NULL DEFAULT 'prepared' CHECK (phase IN ('prepared','fileDone','applied')),
  payload_json TEXT NOT NULL DEFAULT '{}',
  error_message TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

### 5.3 与方案 §4.3 的 4 处偏离（每处都有理由，需 owner 确认）

| # | §4.3 的写法 | V1 的写法 | 理由 |
| --- | --- | --- | --- |
| 1 | `deliveries.xmp_path TEXT PRIMARY KEY` | `id INTEGER PK` + `xmp_path TEXT NOT NULL UNIQUE` | **xmp_path 会变**：`AssetRepo.relocateMetadataState`（`:687`）在照片改名时会迁移 sidecar 键，TEXT 主键意味着「改父键 + 改全部子行」，而 `ON DELETE CASCADE` 会让「删旧行」把子行一起带走。代理键把改名降为一条 `UPDATE deliveries SET xmp_path=?`。 |
| 2 | 无 `photo_path` | 加 `deliveries.photo_path` | `writeback_items.photo_path`（`WritebackRepo.swift:80`）与 `metadata_outbox.photo_path` 都是既有列，改名迁移需要它（`AssetRepo.swift:729/739` 直接 UPDATE 该列）。 |
| 3 | `deliveries.source_module` | **不加** | 归属已由 `delivery_items.module` 结构化表达；再加一个"主模块"列就会变成下一条死列（正是 `owner_session_id` 的教训）。`WorkspaceStatusService.swift:192` 的 `o.source_module='culling'` 谓词改为 `delivery_items.module='culling'`。 |
| 4 | `revison`/`persisted_revision` 两列 | 只留 `revision` | `persisted_revision` 的唯一消费方是 `MetadataSyncSummary.persistedRevision`（`Culling.swift:484`），无 UI 读取（app 侧 grep 为 0），语义上就是「最后一次成功写盘的 revision」，取 `deliveries.revision` 即可。 |

**归属语义的改变（重要）**：旧模型用 `patch_json.__owners__`（字段 → 模块的 JSON 映射，`MetadataOutboxRepo.swift:102-109`）表达字段级归属，跨模块 `discard` 要读 JSON 再逐字段剔除；V1 把归属**提升为行**（`delivery_items.module`），`discardModule(sessionId, module)` 变成 `DELETE FROM delivery_items WHERE module = ?`，不再有 JSON 结构损坏（`corruptOwners`）这一类错误码。

### 5.4 confirm 事务（单事务，无 await）

```swift
// DeliveryRepo.confirm(sessionId:) —— 一个 connection.transaction，闭包内禁止 await
func confirm(sessionId: String) throws -> DeliveryConfirmSummary {
  try connection.transaction {
    let now = nowISOString()
    // 1. 本会话在共享 sidecar 上的全部链接行置确认（语义：per-(session, delivery) 视图，
    //    不是 per 字段归属；否则非归属会话永远无法确认，行永远停在 written）
    UPDATE delivery_sessions SET confirmed_at = ? WHERE session_id = ?
    // 2. 只有「所有关联会话都确认」的 written 交付才翻 synced
    UPDATE deliveries SET status = 'synced', updated_at = ?
     WHERE status = 'written'
       AND EXISTS (SELECT 1 FROM delivery_sessions ds WHERE ds.delivery_id = deliveries.id)
       AND NOT EXISTS (SELECT 1 FROM delivery_sessions ds
                        WHERE ds.delivery_id = deliveries.id AND ds.confirmed_at = '')
    // 3. 同一事务内把命中交付的 items 一起推到 synced（旧模型里这一步在另一张表、另一个事务）
    UPDATE delivery_items SET status = 'synced', updated_at = ?
     WHERE status = 'written'
       AND delivery_id IN (SELECT id FROM deliveries WHERE status = 'synced')
    // 4. 读回 summary（affected 计数 + 未确认的跨会话列表）供 UI/审计
  }
}
```

要点：

1. **跨会话门禁必须先读后写同一事务**：`unconfirmedLinkedSessions`（`MetadataOutboxRepo.swift:834-853`）今天是独立读，V1 把它放进同一事务的 `SELECT`，避免「读到时全确认、写入时新会话又链上」。
2. **`reload_acked_at` 仍参与门禁**：`requireReloadAck` 分支保留（`sessions.reload_acked_at` 保留，不删）。
3. **一次提交**：`deliveries` + `delivery_items` + `delivery_sessions` 的状态翻转必须同 `COMMIT`；任何一步失败整体回滚，不会再出现「会话已确认但 items 还 pending」。
4. 事务预算：单会话 confirm 的影响行数 = 会话内的交付行（实测 `getBySession` 上限为会话照片数），< 2,000 行，符合 §4.4 预算。

### 5.5 cleanup 事务与 intent 回放

cleanup 的不可原子部分是**文件恢复**（把 `backup_path` 的内容写回 XMP），DB 只是记账。V1 用 `delivery_intents` 把「文件已做」与「DB 已改」分开记录：

```text
阶段 A（事务 1）：INSERT delivery_intents(kind='cleanup', xmp_path, phase='prepared',
                    payload_json={backup_path, delivery_id, revision})
阶段 B（事务外）： 文件恢复（把 backup 复制回 xmp，或删除刚写入的内容）
阶段 C（事务 2）：UPDATE delivery_intents SET phase='fileDone'      -- 只改 intent
阶段 D（事务 3）：DELETE FROM delivery_items WHERE delivery_id = ?  -- CASCADE 亦可
                  DELETE FROM delivery_sessions WHERE delivery_id = ?
                  DELETE FROM deliveries WHERE id = ? AND revision = ?   -- revision 守卫
                  UPDATE delivery_intents SET phase='applied' WHERE id = ?
```

**启动回放 `replay()`**（`Database.open` 成功后、服务启动前调用一次）：

| intent 相位 | 回放动作 |
| --- | --- |
| `prepared` | 文件操作**重做**（备份复制是幂等的，覆盖写）+ 事务 B/C/D |
| `fileDone` | **只补 DB 段**（C→D），绝不重放文件（文件已经是目标状态，再删一次会删掉用户新写的内容） |
| `applied` | 删除 intent 行（终态） |

**三条硬规则**：

1. 回放**只对 `phase='fileDone'` 跳过文件**，其余一律"重做文件 + 重做 DB"——因为文件操作只有"覆盖成备份内容"这一种幂等形态。
2. `deliveries` 删除带 `revision` 守卫（等价于今天的 `deleteIfRevision`，`MetadataOutboxRepo.swift:858`）：期间产生了新输入就不删，把 intent 标 `applied` 并记 warn（新输入必须保留）。
3. intent 行本身**没有 FK**：父行被删掉后 intent 仍需存在，否则回放丢失上下文。

### 5.6 仓储迁移面（Cut 2 删除清单）

| 旧 | 新 |
| --- | --- |
| `Repositories/MetadataOutboxRepo.swift`（897 行） | `Repositories/DeliveryRepo.swift`（confirm/claim/write/conflict/cleanup/replay） |
| `Repositories/WritebackRepo.swift`（205 行） | 合并进 `DeliveryRepo`（items 的 upsert/updateStatus/查询） |
| `Services/WritebackService.swift`（828 行） | 保留服务层职责，底层换 `DeliveryRepo`；`WritebackItem` DTO 的 `xmpStatus`→`DeliveryItemStatus` |
| `Services/MetadataSyncCoordinator.swift`（1,230 行） | 保留调度/去抖/租约，状态读写换 `DeliveryRepo`；`recoverInterrupted`/`recoverExpiredLeases` 改为 deliveries 的 `writing` 租约恢复 |
| `CullingService.confirmSync/cleanup`（两次独立调用） | 各一次 `DeliveryRepo` 调用（单事务） |

---

## 6. Database.open 行为

### 6.1 打开流程（伪码 + 错误语义）

```swift
public static func open(at url: URL, options: Options = .default) throws -> Database {
    // 1) 打开（READWRITE|CREATE|FULLMUTEX）
    let conn = try SQLiteConnection.open(url)                 // :memory: 见 6.3
    try conn.exec("PRAGMA foreign_keys = ON")                 // 必须在任何 DDL/DML 之前
    try conn.exec("PRAGMA busy_timeout = 5000")
    let version = try conn.scalarInt("PRAGMA user_version")   // 0 = 全新/空库

    switch version {
    case 1:  break                                             // 正常
    case 0 where try conn.isEmptySchema:                       // 空库：建表
        try conn.transaction {
            try SchemaV1.create(conn)                          // 43 张表 + 索引 + CHECK
            try conn.exec("PRAGMA user_version = 1")           // 同一事务内写版本
        }
    default:                                                   // 0 但有表 / 非 1 / 未来版本 / 非 SQLite 文件
        try conn.close()
        try resetIncompatibleDatabase(url)                     // 6.2
        return try open(at: url, options: options)             // 递归一次，最多一层
    }

    // 2) 连接级 PRAGMA（WAL 必须在写事务之外设置）
    try conn.exec("PRAGMA journal_mode = WAL")
    try conn.exec("PRAGMA synchronous = NORMAL")               // 可被 app_settings.db_synchronous 覆盖
    try conn.exec("PRAGMA cache_size = -65536")                // 64MB，可被 db_cache_size_mb 覆盖
    try conn.exec("PRAGMA temp_store = MEMORY")

    // 3) 不变量自检（失败即抛，不降级）
    try SchemaV1.assertUserVersion(conn, 1)                    // 防止上面事务半途而废
    try conn.exec("PRAGMA foreign_key_check")                  // 空库恒通过，用于自检 DDL
    return Database(writer: conn, ...)                         // readers: 6.4
}
```

**关键点**

- `user_version` 在**建表的同一事务**里写，杜绝「表建好了但版本是 0」的半成品（下次启动会被判为不兼容）。SQLite 的 `PRAGMA user_version = N` 可在事务内执行（写 `sqlite_master` 的头部字段）。
- **不做 ALTER、不做数据搬运、不做 down migration**（方案 §4.1）。
- `foreign_keys` 是**连接级**开关，且不能在事务内改变；打开后第一件事就是置 ON，并写进 `DatabasePragmaTests` 断言（现有 `Database/DB.swift:82` 已是该行为）。
- 版本不匹配是**预期路径**，不是错误：日志 `warn` 一条 `schema_reset oldVersion=… new=1 backup=…`，UI 侧只在首次启动时提示一次（见 §8 风险 4）。

### 6.2 旧库移走（reset）

```text
gather.sqlite                    → gather.sqlite.incompatible-<yyyyMMdd-HHmmss>
gather.sqlite-wal                → 同名 -wal（若存在，必须一起移走）
gather.sqlite-shm                → 同名 -shm（若存在）
```

**必须连 `-wal`/`-shm` 一起移走**：只移主库时，新库打开会看到残留的 WAL 文件（同名前缀），SQLite 可能据此恢复出旧页，出现「新 schema + 旧数据」的错位。移走后 `FileManager.moveItem` 失败要显式抛错（不能吞），并在 UI 提示「请手动备份后重试」。

保留策略：最多保留 3 份（与现有迁移备份 `pruneMigrationBackups` 同策略），按时间戳淘汰；`.gitignore` 已有 `*.sqlite.incompatible-*`（CL-15）。

### 6.3 `:memory:` 单连接

内存库**必须单连接**：`sqlite3_open_v2(":memory:")` 每次调用都是**一个新的空库**，多连接等于多份互不相干的数据。因此：

- `options.inMemory == true` 时 `Database` 只持有一个 writer 连接，`read { }` 与 `write { }` 复用同一连接（同一把 `NSRecursiveLock`）；
- `journal_mode = WAL` 对内存库返回 `memory`，**不视为错误**（`exec` 返回的值忽略，不 assert）；
- 测试用的 `makeTestDatabase()`（D-003 重命名）直接 `Database.openInMemory()`，不再走 `MigrationRunner`；
- 生产路径禁止 `:memory:`：`GatherApp.bootstrap`（`GatherApp.swift:107`）只接受文件路径。

### 6.4 WAL / busy_timeout / foreign_keys / readers

| 项 | writer | readers |
| --- | --- | --- |
| flags | `READWRITE｜CREATE｜FULLMUTEX` | `READONLY｜FULLMUTEX` |
| `journal_mode` | `WAL` | **不设置**（`query_only=ON`） |
| `busy_timeout` | `5000` | `5000` |
| `foreign_keys` | `ON` | `ON`（只读连接也要，否则 `foreign_key_check` 无效） |
| `synchronous` | `NORMAL`（可配） | 不设置 |
| `cache_size` | `-65536` | `-16384` |
| `query_only` | 关 | `ON`（防御性：任何写语句立即报错） |

- WAL 的 `wal_autocheckpoint` 保持默认（1000 页）；批量分析结束后调用 `checkpoint(TRUNCATE)`（现有 ADR-005 的迁移前检查逻辑保留在 `checkpoint` 方法里）。
- **`Database.open` 不做备份**（迁移已删），备份职责下移到 `checkpoint` 之前的显式 `backup`（可选，Cut 2 决定是否保留）。

---

## 7. 完整 SchemaV1.sql（可执行）

```bash
# 提取 + 验证（命令与结果见 7.2）
```

### 7.1 DDL 全文

<!-- SCHEMA_V1_SQL_BEGIN -->
```sql
-- SchemaV1 · Gather 本地库最终形态（43 表 / 373 列 / 69 索引 / 62 外键）
-- 约定：时间戳为 ISO-8601 TEXT（与 nowISOString 同格式）；布尔为 INTEGER 0/1；mtime 为 REAL 毫秒。
-- 约束分层：CHECK 只兜「非法值」，状态转移合法性由 Swift 状态机负责。

PRAGMA foreign_keys = ON;

-- 1. 工作区会话
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','photos_loaded','analyzing','review','completed')),
  source_path TEXT NOT NULL DEFAULT '',
  truncated_import INTEGER NOT NULL DEFAULT 0 CHECK (truncated_import IN (0,1)),
  reload_acked_at TEXT,
  index_seq INTEGER NOT NULL DEFAULT 0 CHECK (index_seq >= 0),
  photo_count INTEGER NOT NULL DEFAULT 0 CHECK (photo_count >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 2. 逻辑资产
CREATE TABLE assets (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','orphan','offline_unverified')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 3. 物理文件
CREATE TABLE asset_files (
  id TEXT PRIMARY KEY,
  volume_id TEXT NOT NULL DEFAULT '',
  file_identity TEXT NOT NULL DEFAULT '',
  normalized_path TEXT NOT NULL,
  filename TEXT NOT NULL,
  extension TEXT NOT NULL DEFAULT '',
  media_type TEXT NOT NULL DEFAULT 'unknown'
    CHECK (media_type IN ('unknown','image','raw')),
  file_size INTEGER NOT NULL DEFAULT 0 CHECK (file_size >= 0),
  file_mtime_ms REAL NOT NULL DEFAULT 0,
  checksum TEXT NOT NULL DEFAULT '',
  online_status TEXT NOT NULL DEFAULT 'online'
    CHECK (online_status IN ('online','offline')),
  last_seen_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 4. 照片行
CREATE TABLE photos (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  filepath TEXT NOT NULL,
  filename TEXT NOT NULL DEFAULT '',
  checksum TEXT NOT NULL DEFAULT '',
  checksum_file_size INTEGER NOT NULL DEFAULT 0,
  checksum_file_mtime_ms REAL NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','ready','removed','missing')),
  asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  asset_file_id TEXT REFERENCES asset_files(id) ON DELETE SET NULL,
  width INTEGER NOT NULL DEFAULT 0 CHECK (width >= 0),
  height INTEGER NOT NULL DEFAULT 0 CHECK (height >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 5. 分析运行记录
CREATE TABLE analysis_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('face','similarity')),
  photo_count INTEGER NOT NULL CHECK (photo_count >= 0),
  index_seq INTEGER NOT NULL CHECK (index_seq >= 0),
  started_at TEXT NOT NULL,
  finished_at TEXT NOT NULL DEFAULT '',
  params_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'running'
    CHECK (status IN ('running','ok','failed')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 6. 资产成员
CREATE TABLE asset_members (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  member_role TEXT NOT NULL
    CHECK (member_role IN ('raw','camera_jpeg','rendered_tiff','unknown')),
  is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0,1)),
  confidence REAL NOT NULL DEFAULT 1.0,
  binding_source TEXT NOT NULL DEFAULT 'import'
    CHECK (binding_source IN ('import','backfill','manual_split')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (asset_id, file_id),
  UNIQUE (file_id)
);

-- 7. 资产配对候选
CREATE TABLE asset_link_candidates (
  id TEXT PRIMARY KEY,
  left_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  right_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL CHECK (relation_type IN ('raw_jpeg')),
  confidence REAL NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','accepted','rejected')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 8. 会话↔资产
CREATE TABLE session_assets (
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  display_file_id TEXT REFERENCES asset_files(id) ON DELETE SET NULL,
  import_order INTEGER NOT NULL DEFAULT 0 CHECK (import_order >= 0),
  added_at TEXT NOT NULL,
  PRIMARY KEY (session_id, asset_id)
);

-- 9. sidecar 绑定
CREATE TABLE sidecar_bindings (
  id TEXT PRIMARY KEY,
  xmp_path TEXT NOT NULL,
  normalized_xmp_path TEXT NOT NULL UNIQUE,
  binding_rule TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 10. sidecar↔文件
CREATE TABLE sidecar_binding_files (
  sidecar_binding_id TEXT NOT NULL REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
  file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (sidecar_binding_id, file_id)
);

-- 11. sidecar 元数据现值
CREATE TABLE sidecar_metadata_state (
  sidecar_binding_id TEXT PRIMARY KEY REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
  rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
  label TEXT,
  keywords TEXT NOT NULL DEFAULT '[]',
  fingerprint TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

-- 12. 资产回填游标
CREATE TABLE asset_backfill_state (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  last_photo_rowid INTEGER NOT NULL DEFAULT 0 CHECK (last_photo_rowid >= 0),
  total_photos INTEGER NOT NULL DEFAULT 0 CHECK (total_photos >= 0),
  migrated_photos INTEGER NOT NULL DEFAULT 0 CHECK (migrated_photos >= 0),
  offline_files INTEGER NOT NULL DEFAULT 0 CHECK (offline_files >= 0),
  candidate_links INTEGER NOT NULL DEFAULT 0 CHECK (candidate_links >= 0),
  automatic_merges INTEGER NOT NULL DEFAULT 0 CHECK (automatic_merges >= 0),
  status TEXT NOT NULL DEFAULT 'running'
    CHECK (status IN ('running','completed','failed')),
  updated_at TEXT NOT NULL
);

-- 13. 异步任务队列
CREATE TABLE analysis_jobs (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN (
    'metadata.scan','thumbnail.build','similarity.analyze','duplicate.scan',
    'face.analyze','quality.score','export.execute','checksum.backfill')),
  scope_type TEXT NOT NULL CHECK (length(scope_type) > 0),
  scope_id TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('queued','running','succeeded','failed','cancelled','interrupted','cancelling')),
  priority INTEGER NOT NULL DEFAULT 0,
  progress_current INTEGER NOT NULL DEFAULT 0 CHECK (progress_current >= 0),
  progress_total INTEGER NOT NULL DEFAULT 0 CHECK (progress_total >= 0),
  progress_message TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  model_id TEXT NOT NULL DEFAULT '',
  model_version TEXT NOT NULL DEFAULT '',
  checkpoint_json TEXT NOT NULL DEFAULT '{}',
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  lease_owner TEXT NOT NULL DEFAULT '',
  heartbeat_at TEXT NOT NULL DEFAULT '',
  cancel_requested_at TEXT NOT NULL DEFAULT '',
  error_code TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT '',
  finished_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

-- 14. 文件级分析结果
CREATE TABLE asset_analysis (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
  asset_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  analysis_type TEXT NOT NULL,
  result_json TEXT NOT NULL DEFAULT '{}',
  warnings_json TEXT NOT NULL DEFAULT '[]',
  model_id TEXT NOT NULL DEFAULT '',
  model_version TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (asset_file_id, analysis_type, model_id, model_version, input_fingerprint)
);

-- 15. 人脸观察
CREATE TABLE face_observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  bbox_x REAL NOT NULL,
  bbox_y REAL NOT NULL,
  bbox_w REAL NOT NULL,
  bbox_h REAL NOT NULL,
  embedding BLOB NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  analysis_signature TEXT NOT NULL DEFAULT '',
  quality REAL NOT NULL DEFAULT 0 CHECK (quality BETWEEN 0 AND 1),
  face_size_px REAL NOT NULL DEFAULT 0 CHECK (face_size_px >= 0),
  roll_degrees REAL NOT NULL DEFAULT 0,
  model_id TEXT NOT NULL DEFAULT '',
  model_version TEXT NOT NULL DEFAULT '',
  embedding_dim INTEGER NOT NULL DEFAULT 0 CHECK (embedding_dim >= 0),
  created_at TEXT NOT NULL DEFAULT ''
);

-- 16. 人脸分析输入指纹（陈旧判定唯一真相源）
CREATE TABLE face_analysis_state (
  photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_file_size INTEGER NOT NULL,
  source_file_mtime_ms REAL NOT NULL,
  analysis_signature TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 17. 身份反馈
CREATE TABLE face_identity_feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  bbox_x REAL NOT NULL,
  bbox_y REAL NOT NULL,
  bbox_w REAL NOT NULL,
  bbox_h REAL NOT NULL,
  person_id TEXT REFERENCES persons(id) ON DELETE CASCADE,
  decision TEXT NOT NULL CHECK (decision IN ('confirmed','rejected')),
  keywords TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL
);

-- 18. 人脸聚类签名
CREATE TABLE face_cluster_state (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  cluster_signature TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 19. 人脸簇（+ 用户绑定的身份）
CREATE TABLE face_clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  label TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'unbound' CHECK (status IN ('unbound','bound')),
  thumbnail_path TEXT NOT NULL DEFAULT '',
  matched_person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
  match_confidence REAL,
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

-- 20. 簇成员
CREATE TABLE face_cluster_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL REFERENCES face_clusters(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  bbox TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  observation_id INTEGER REFERENCES face_observations(id) ON DELETE CASCADE
);

-- 21. 角色绑定（用户数据）
CREATE TABLE role_bindings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL UNIQUE REFERENCES face_clusters(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role_name TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

-- 22. 感知哈希
CREATE TABLE similarity_hashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  hash_hex TEXT NOT NULL,
  file_size INTEGER NOT NULL DEFAULT 0,
  file_mtime_ms REAL NOT NULL DEFAULT 0
);

-- 23. 相似度结果快照
CREATE TABLE similarity_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  groups_json TEXT NOT NULL,
  stats_json TEXT NOT NULL DEFAULT '{}',
  param_threshold INTEGER NOT NULL CHECK (param_threshold BETWEEN 0 AND 64),
  param_min_group_size INTEGER NOT NULL DEFAULT 2 CHECK (param_min_group_size >= 1),
  created_at TEXT NOT NULL
);

-- 24. 结果快照成员
CREATE TABLE similarity_result_members (
  result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_index INTEGER NOT NULL CHECK (group_index >= 0),
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  PRIMARY KEY (result_id, photo_id)
);

-- 25. 增量聚类分量（photo_id 刻意无 FK：残留行是「已移除」的依据）
CREATE TABLE similarity_cluster_state (
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL,
  hash_hex TEXT NOT NULL,
  component_index INTEGER NOT NULL,
  group_seed TEXT,
  PRIMARY KEY (session_id, photo_id)
);

-- 26. 聚类参数与版本
-- Cut 5 / 5b-2b：三列状态版本化（开发期直接改 V1）。
-- algorithm_version 是状态语义版本（旧实现落的行按版本不符失效）；input_signature
-- 是参数指纹（阈值/组大小/模式 + 算法版本），state_digest 是内容摘要（规范序、
-- 与行序无关）。三者任一不符即视为旧/损坏 state：不得增量复用，必须全量覆盖。
-- 默认值只为兼容「显式省略三列」的插入（空签名/空摘要永远不等于真实指纹）。
CREATE TABLE similarity_cluster_meta (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  param_threshold INTEGER NOT NULL CHECK (param_threshold BETWEEN 0 AND 64),
  param_min_group_size INTEGER NOT NULL DEFAULT 2 CHECK (param_min_group_size >= 1),
  grouping_mode TEXT NOT NULL CHECK (grouping_mode IN ('sequential','global')),
  member_count INTEGER NOT NULL DEFAULT 0 CHECK (member_count >= 0),
  version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
  incremental_updates INTEGER NOT NULL DEFAULT 0 CHECK (incremental_updates >= 0),
  updated_at TEXT NOT NULL,
  algorithm_version INTEGER NOT NULL DEFAULT 1 CHECK (algorithm_version >= 1),
  input_signature TEXT NOT NULL DEFAULT '',
  state_digest TEXT NOT NULL DEFAULT ''
);

-- 27. 身份
CREATE TABLE persons (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  thumbnail_base64 TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  match_threshold REAL NOT NULL DEFAULT 0.65 CHECK (match_threshold BETWEEN 0 AND 1),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 28. 身份向量（face_observation_id 刻意无 FK）
CREATE TABLE person_embeddings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  embedding BLOB NOT NULL,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  face_observation_id INTEGER,
  created_at TEXT NOT NULL
);

-- 29. 身份↔照片
CREATE TABLE person_photos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  face_bbox TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  created_at TEXT NOT NULL
);

-- 30. 元数据镜像读模型（唯一）
CREATE TABLE photo_metadata_cache (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL UNIQUE REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  date_taken TEXT,
  camera_make TEXT,
  camera_model TEXT,
  lens_model TEXT,
  focal_length REAL,
  f_number REAL,
  exposure_time TEXT,
  iso INTEGER,
  rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
  label TEXT,
  gps_latitude REAL,
  gps_longitude REAL,
  width INTEGER,
  height INTEGER,
  file_size INTEGER,
  file_mtime TEXT,
  keywords TEXT NOT NULL DEFAULT '[]',
  cached_at TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT ''
);

-- 31. 重复组
CREATE TABLE duplicate_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_type TEXT NOT NULL CHECK (group_type IN ('exact','visual')),
  checksum TEXT,
  hash_hex TEXT,
  member_count INTEGER NOT NULL DEFAULT 0 CHECK (member_count >= 0),
  resolution TEXT CHECK (resolution IS NULL OR resolution IN ('keep_all','keep_one')),
  created_at TEXT NOT NULL
);

-- 32. 重复组成员
CREATE TABLE duplicate_group_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id INTEGER NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  is_kept INTEGER NOT NULL DEFAULT 1 CHECK (is_kept IN (0,1)),
  file_size INTEGER,
  file_mtime TEXT,
  resolution TEXT CHECK (resolution IS NULL OR resolution IN ('keep_all','keep_one'))
);

-- 33. 挑片决策
CREATE TABLE culling_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  group_id TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending'
    CHECK (decision IN ('keep','reject','pending')),
  rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
  color_label TEXT NOT NULL DEFAULT 'None'
    CHECK (color_label IN ('None','Red','Orange','Yellow','Green','Blue','Pink','Purple')),
  decision_source TEXT NOT NULL DEFAULT 'manual'
    CHECK (decision_source IN ('manual','ai','template','imported')),
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  UNIQUE (session_id, photo_id)
);

-- 34. 挑片历史
CREATE TABLE culling_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  operation_json TEXT NOT NULL DEFAULT '[]',
  undone INTEGER NOT NULL DEFAULT 0 CHECK (undone IN (0,1)),
  created_at TEXT NOT NULL
);

-- 35. 导航分组
CREATE TABLE navigation_groups (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_type TEXT NOT NULL CHECK (group_type IN ('burst','scene')),
  photo_ids_json TEXT NOT NULL DEFAULT '[]',
  lead_photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
  explanation TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'automatic' CHECK (source IN ('automatic','manual')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 36. 关键词来源归属
CREATE TABLE metadata_keyword_origins (
  xmp_path TEXT NOT NULL,
  source TEXT NOT NULL
    CHECK (source IN ('face-keyword','culling','similarity','template')),
  keyword TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (xmp_path, source, keyword)
);

-- 37. 设置
CREATE TABLE app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- 38. 智能相册（D-008 保留）
CREATE TABLE smart_albums (
  id TEXT PRIMARY KEY,
  filter_schema_version INTEGER NOT NULL DEFAULT 1 CHECK (filter_schema_version >= 1),
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  filter_criteria TEXT NOT NULL,
  sort_by TEXT NOT NULL DEFAULT 'date_taken',
  sort_order TEXT NOT NULL DEFAULT 'desc' CHECK (sort_order IN ('asc','desc')),
  icon TEXT NOT NULL DEFAULT '📁',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 39. 工作流模板（D-008 保留）
CREATE TABLE workflow_templates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  config TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 40. 交付聚合（XMP sidecar 为单位的单一状态机）
CREATE TABLE deliveries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  xmp_path TEXT NOT NULL UNIQUE,
  photo_path TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','writing','written','synced','failed','conflict','cleaned')),
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  base_fingerprint TEXT NOT NULL DEFAULT '',
  base_values_json TEXT NOT NULL DEFAULT '{}',
  backup_path TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  lease_owner TEXT NOT NULL DEFAULT '',
  heartbeat_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 41. 交付↔会话确认
CREATE TABLE delivery_sessions (
  delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  confirmed_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (delivery_id, session_id)
);

-- 42. 交付项（逐照片 × 模块）
CREATE TABLE delivery_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  module TEXT NOT NULL
    CHECK (module IN ('culling','face-keyword','similarity','template','metadata')),
  attributes_json TEXT NOT NULL DEFAULT '{}',
  keywords TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','written','synced','failed')),
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (delivery_id, photo_id, module)
);

-- 43. 交付意图日志（xmp_path 刻意无 FK：父行删除后仍需存活以便回放）
CREATE TABLE delivery_intents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('cleanup','write')),
  xmp_path TEXT NOT NULL,
  phase TEXT NOT NULL DEFAULT 'prepared'
    CHECK (phase IN ('prepared','fileDone','applied')),
  payload_json TEXT NOT NULL DEFAULT '{}',
  error_message TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- ─────────────────────────────── 索引 ───────────────────────────────
-- photos
CREATE UNIQUE INDEX idx_photos_session_filepath ON photos(session_id, filepath);
CREATE INDEX idx_photos_filepath ON photos(filepath);
CREATE INDEX idx_photos_created_at ON photos(created_at);
CREATE INDEX idx_photos_asset ON photos(asset_id);
CREATE INDEX idx_photos_asset_file ON photos(asset_file_id);
CREATE INDEX idx_photos_asset_group ON photos(session_id, COALESCE(NULLIF(asset_id, ''), id));

-- asset_files / assets / 关系表
CREATE UNIQUE INDEX idx_asset_files_volume_path ON asset_files(volume_id, normalized_path);
CREATE UNIQUE INDEX idx_asset_files_volume_identity
  ON asset_files(volume_id, file_identity) WHERE file_identity != '';
CREATE INDEX idx_asset_files_checksum ON asset_files(checksum);
CREATE INDEX idx_asset_files_volume_status ON asset_files(volume_id, online_status);
CREATE INDEX idx_asset_candidates_relation_status ON asset_link_candidates(relation_type, status);
CREATE INDEX idx_asset_candidates_left ON asset_link_candidates(left_file_id);
CREATE INDEX idx_asset_candidates_right ON asset_link_candidates(right_file_id);
CREATE INDEX idx_session_assets_asset ON session_assets(asset_id);
CREATE INDEX idx_sidecar_binding_files_file ON sidecar_binding_files(file_id);

-- analysis
CREATE INDEX idx_analysis_jobs_status_priority ON analysis_jobs(status, priority, updated_at);
CREATE INDEX idx_analysis_jobs_scope ON analysis_jobs(scope_type, scope_id);
CREATE INDEX idx_analysis_runs_session_kind ON analysis_runs(session_id, kind, status, id DESC);
CREATE UNIQUE INDEX idx_analysis_jobs_active_dedupe
  ON analysis_jobs(dedupe_key)
  WHERE status IN ('queued', 'running', 'cancelling');
CREATE INDEX idx_asset_analysis_photo_type ON asset_analysis(photo_id, analysis_type);
CREATE INDEX idx_asset_analysis_file_type ON asset_analysis(asset_file_id, analysis_type);

-- face
CREATE INDEX idx_face_observations_session ON face_observations(session_id);
CREATE INDEX idx_face_observations_photo ON face_observations(photo_id);
CREATE INDEX idx_face_analysis_state_session ON face_analysis_state(session_id);
CREATE INDEX idx_face_identity_feedback_session ON face_identity_feedback(session_id, photo_id);
CREATE INDEX idx_face_identity_feedback_photo ON face_identity_feedback(photo_id);
CREATE INDEX idx_face_identity_feedback_person ON face_identity_feedback(person_id);
CREATE INDEX idx_face_clusters_session ON face_clusters(session_id);
CREATE INDEX idx_face_clusters_matched_person ON face_clusters(matched_person_id);
CREATE INDEX idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
CREATE INDEX idx_face_cluster_members_session ON face_cluster_members(session_id);
CREATE INDEX idx_face_cluster_members_photo ON face_cluster_members(photo_id);
CREATE INDEX idx_face_cluster_members_observation ON face_cluster_members(observation_id);
CREATE INDEX idx_role_bindings_session ON role_bindings(session_id);

-- similarity
CREATE INDEX idx_similarity_hashes_photo ON similarity_hashes(photo_id);
CREATE UNIQUE INDEX idx_similarity_hashes_session_photo ON similarity_hashes(session_id, photo_id);
CREATE INDEX idx_similarity_results_session ON similarity_results(session_id);
CREATE INDEX idx_similarity_members_session_photo ON similarity_result_members(session_id, photo_id);
CREATE INDEX idx_similarity_members_result_group ON similarity_result_members(result_id, group_index);
CREATE INDEX idx_similarity_members_photo ON similarity_result_members(photo_id);

-- persons
CREATE INDEX idx_persons_name ON persons(name);
CREATE INDEX idx_person_embeddings_person ON person_embeddings(person_id);
CREATE UNIQUE INDEX idx_person_embeddings_obs ON person_embeddings(face_observation_id);
CREATE INDEX idx_person_embeddings_photo ON person_embeddings(photo_id);
CREATE INDEX idx_person_embeddings_session ON person_embeddings(session_id);
CREATE INDEX idx_person_photos_photo ON person_photos(photo_id);
CREATE INDEX idx_person_photos_session ON person_photos(session_id);
CREATE UNIQUE INDEX idx_person_photos_person_photo ON person_photos(person_id, photo_id);

-- metadata cache
CREATE INDEX idx_metadata_cache_session ON photo_metadata_cache(session_id);
CREATE INDEX idx_metadata_cache_session_date ON photo_metadata_cache(session_id, date_taken);
CREATE INDEX idx_metadata_cache_session_rating ON photo_metadata_cache(session_id, rating);
CREATE INDEX idx_metadata_cache_session_label ON photo_metadata_cache(session_id, label);
CREATE INDEX idx_metadata_cache_camera_make ON photo_metadata_cache(camera_make);

-- duplicates / culling / navigation
CREATE INDEX idx_duplicate_groups_session ON duplicate_groups(session_id);
CREATE INDEX idx_duplicate_members_group ON duplicate_group_members(group_id);
CREATE INDEX idx_duplicate_members_photo ON duplicate_group_members(photo_id);
CREATE INDEX idx_duplicate_members_session ON duplicate_group_members(session_id);
CREATE UNIQUE INDEX idx_culling_session_photo_unique ON culling_decisions(session_id, photo_id);
CREATE INDEX idx_culling_group ON culling_decisions(session_id, group_id);
CREATE INDEX idx_culling_decisions_photo ON culling_decisions(photo_id);
CREATE INDEX idx_culling_history_session ON culling_history(session_id, id);
CREATE INDEX idx_navigation_groups_session_type ON navigation_groups(session_id, group_type, updated_at);
CREATE INDEX idx_navigation_groups_lead ON navigation_groups(lead_photo_id);
CREATE INDEX idx_metadata_keyword_origins_source_active
  ON metadata_keyword_origins(source, active, updated_at);

-- delivery
CREATE INDEX idx_deliveries_status ON deliveries(status, updated_at);
CREATE INDEX idx_delivery_sessions_session ON delivery_sessions(session_id, delivery_id);
CREATE INDEX idx_delivery_items_photo ON delivery_items(photo_id);
CREATE INDEX idx_delivery_items_module_status ON delivery_items(module, status);
CREATE INDEX idx_delivery_intents_phase ON delivery_intents(phase, id);
```
<!-- SCHEMA_V1_SQL_END -->

### 7.2 验证命令与结果

```bash
# ① 从本文件提取 DDL（标记之间），② 系统 sqlite3 内存库/临时库验证
python3 - <<'PY' > /tmp/gather_schema_v1.sql
doc = open('docs/schema-v1-draft.md').read()
block = doc.split('<!-- SCHEMA_V1_SQL_BEGIN -->')[1].split('<!-- SCHEMA_V1_SQL_END -->')[0]
fence = chr(96) * 3   # 三个反引号
print('\n'.join(l for l in block.split('\n') if not l.strip().startswith(fence)).strip())
PY
sqlite3 :memory: < /tmp/gather_schema_v1.sql && echo "DDL OK"
sqlite3 --version
```

**实测环境**：`/usr/bin/sqlite3` 3.54.0（2026-04-09），macOS。真实运行时用的是 SDK 自带 CSQLite（`DB.swift:8` `import CSQLite`），版本可能更低；**所有特性均落在 SQLite 3.24+ 的基础语法内**（`strftime` 默认值、部分索引、表达式索引、`PRAGMA user_version`），无 3.35+ 的 `STRICT`/`RETURNING` 依赖。Cut 2 必须用 `CSQLite` 再跑一遍同一脚本（见 §8 风险 2）。

**执行结果（完整输出）**：

```text
== 1) 建表 ==
tables=43
indexes=69
autoindexes=32
foreign_key_check=clean

== 2) 正向插入（合法值链）==
rows: photos=1 deliveries=1 delivery_items=1

== 3) CHECK 拒绝（13 项，期望全部 CHECK constraint failed）==
  sessions.status              REJECT OK
  photos.status                REJECT OK
  analysis_jobs.type           REJECT OK
  analysis_jobs.status         REJECT OK
  deliveries.status            REJECT OK
  delivery_items.status        REJECT OK
  delivery_intents.phase       REJECT OK
  culling.color_label          REJECT OK
  duplicate_groups.resolution  REJECT OK
  face_clusters.status         REJECT OK
  keyword_origins.source       REJECT OK
  navigation.group_type        REJECT OK
  asset_members.member_role    REJECT OK

== 4) FK 拒绝非法引用 ==
Error near line 2: FOREIGN KEY constraint failed

== 5) 会话删除级联（CASCADE）==
after delete: photos=0 delivery_sessions=0 delivery_items=0 deliveries=1

== 6) SET NULL（删 assets）==
photos.asset_id is null: yes

== 7) 孤儿交付清扫 ==
deliveries=0

== 8) user_version ==
1

== RESULT: FAIL=0 ==
```

**验证脚本**（与上面输出一一对应，可直接复跑；`FAIL=0` 即全部通过）：

```bash
#!/bin/bash
# /tmp/validate_schema_v1.sh —— 依赖上一步生成的 /tmp/gather_schema_v1.sql
set -u; DB=/tmp/gather_v1.db; BAD=/tmp/gather_bad.db; FAIL=0
rm -f $DB $BAD

echo "== 1) 建表 =="
sqlite3 $DB < /tmp/gather_schema_v1.sql || FAIL=1
sqlite3 $DB "SELECT 'tables=' || COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
sqlite3 $DB "SELECT 'indexes=' || COUNT(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';"
sqlite3 $DB "SELECT 'autoindexes=' || COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'sqlite_autoindex%';"
sqlite3 $DB "SELECT CASE WHEN COUNT(*)=0 THEN 'foreign_key_check=clean' ELSE 'foreign_key_check=DIRTY' END FROM pragma_foreign_key_check;"

echo "== 2) 正向插入（合法值链）=="
sqlite3 $DB <<'SQL'
PRAGMA foreign_keys = ON;
INSERT INTO sessions (id,name,status,created_at,updated_at) VALUES ('s1','w','photos_loaded','t','t');
INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a1','active','t','t');
INSERT INTO photos (id,session_id,filepath,status,asset_id,created_at,updated_at)
  VALUES ('p1','s1','/x/1.NEF','pending','a1','t','t');
INSERT INTO deliveries (id,xmp_path,photo_path,status,created_at,updated_at)
  VALUES (1,'/x/1.xmp','/x/1.NEF','written','t','t');
INSERT INTO delivery_sessions (delivery_id,session_id,confirmed_at) VALUES (1,'s1','t');
INSERT INTO delivery_items (delivery_id,photo_id,module,status,created_at,updated_at)
  VALUES (1,'p1','culling','written','t','t');
INSERT INTO analysis_jobs (id,type,scope_type,scope_id,dedupe_key,status,created_at,updated_at)
  VALUES ('j1','face.analyze','session','s1','k1','queued','t','t');
SELECT 'rows: photos=' || (SELECT COUNT(*) FROM photos)
     || ' deliveries=' || (SELECT COUNT(*) FROM deliveries)
     || ' delivery_items=' || (SELECT COUNT(*) FROM delivery_items);
SQL

echo "== 3) CHECK 拒绝（13 项）=="
sqlite3 $BAD < /tmp/gather_schema_v1.sql
run_bad() {
  out=$(printf "PRAGMA foreign_keys=ON;\n%s\n" "$2" | sqlite3 $BAD -bail 2>&1 | head -1)
  if echo "$out" | grep -q "CHECK constraint failed"; then printf '  %-28s REJECT OK\n' "$1"
  else printf '  %-28s FAIL -> %s\n' "$1" "$out"; FAIL=1; fi
}
run_bad sessions.status            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b1','indexed','t','t');"
run_bad photos.status              "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b0','draft','t','t'); INSERT INTO photos (id,session_id,filepath,status,created_at,updated_at) VALUES ('bp','b0','/p','imported','t','t');"
run_bad analysis_jobs.type         "INSERT INTO analysis_jobs (id,type,scope_type,scope_id,dedupe_key,status,created_at,updated_at) VALUES ('bj','thumbnail','session','s','k','queued','t','t');"
run_bad analysis_jobs.status       "INSERT INTO analysis_jobs (id,type,scope_type,scope_id,dedupe_key,status,created_at,updated_at) VALUES ('bj2','face.analyze','session','s','k2','done','t','t');"
run_bad deliveries.status          "INSERT INTO deliveries (xmp_path,status,created_at,updated_at) VALUES ('/b.xmp','clean','t','t');"
run_bad delivery_items.status      "INSERT INTO deliveries (id,xmp_path,created_at,updated_at) VALUES (9,'/b9.xmp','t','t'); INSERT INTO delivery_items (delivery_id,photo_id,module,status,created_at,updated_at) VALUES (9,'bp','culling','cleaned','t','t');"
run_bad delivery_intents.phase     "INSERT INTO delivery_intents (kind,xmp_path,phase,created_at,updated_at) VALUES ('cleanup','/b.xmp','done','t','t');"
run_bad culling.color_label        "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b2','draft','t','t'); INSERT INTO photos (id,session_id,filepath,status,created_at,updated_at) VALUES ('bp3','b2','/q','pending','t','t'); INSERT INTO culling_decisions (session_id,photo_id,group_id,color_label,updated_at) VALUES ('b2','bp3','g','Black','t');"
run_bad duplicate_groups.resolution "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b3','draft','t','t'); INSERT INTO duplicate_groups (session_id,group_type,resolution,created_at) VALUES ('b3','exact','keep_some','t');"
run_bad face_clusters.status       "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b4','draft','t','t'); INSERT INTO face_clusters (session_id,status) VALUES ('b4','orphan');"
run_bad keyword_origins.source     "INSERT INTO metadata_keyword_origins (xmp_path,source,keyword,created_at,updated_at) VALUES ('/k.xmp','manual','kw','t','t');"
run_bad navigation.group_type      "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('b5','draft','t','t'); INSERT INTO navigation_groups (id,session_id,group_type,created_at,updated_at) VALUES ('n1','b5','scene2','t','t');"
run_bad asset_members.member_role  "INSERT INTO assets (id,status,created_at,updated_at) VALUES ('ba','active','t','t'); INSERT INTO asset_files (id,normalized_path,filename,created_at,updated_at) VALUES ('f1','/n','n','t','t'); INSERT INTO asset_members (asset_id,file_id,member_role) VALUES ('ba','f1','jpeg');"

echo "== 4) FK 拒绝非法引用 =="
printf "PRAGMA foreign_keys=ON;\nINSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('px','nope','/p','t','t');\n" \
  | sqlite3 $BAD -bail 2>&1 | head -1

echo "== 5) 会话删除级联（CASCADE）=="
sqlite3 $DB <<'SQL'
PRAGMA foreign_keys = ON;
DELETE FROM sessions WHERE id = 's1';
SELECT 'after delete: photos=' || (SELECT COUNT(*) FROM photos)
     || ' delivery_sessions=' || (SELECT COUNT(*) FROM delivery_sessions)
     || ' delivery_items=' || (SELECT COUNT(*) FROM delivery_items)
     || ' deliveries=' || (SELECT COUNT(*) FROM deliveries);
SQL

echo "== 6) SET NULL（删 assets）=="
sqlite3 $DB <<'SQL'
PRAGMA foreign_keys = ON;
INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s2','draft','t','t');
INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a2','active','t','t');
INSERT INTO photos (id,session_id,filepath,asset_id,created_at,updated_at) VALUES ('p2','s2','/2.NEF','a2','t','t');
DELETE FROM assets WHERE id = 'a2';
SELECT 'photos.asset_id is null: ' || (SELECT CASE WHEN asset_id IS NULL THEN 'yes' ELSE 'no' END FROM photos WHERE id='p2');
SQL

echo "== 7) 孤儿交付清扫 =="
sqlite3 $DB "DELETE FROM deliveries WHERE NOT EXISTS (SELECT 1 FROM delivery_sessions d WHERE d.delivery_id = deliveries.id) AND NOT EXISTS (SELECT 1 FROM delivery_items i WHERE i.delivery_id = deliveries.id); SELECT 'deliveries=' || COUNT(*) FROM deliveries;"

echo "== 8) user_version =="
sqlite3 $DB "PRAGMA user_version = 1; PRAGMA user_version;"

echo "== RESULT: FAIL=$FAIL =="
```

### 7.3 结果解读

1. **DDL 可建**：43 张表、69 个显式索引、32 个自动索引（PK/UNIQUE 隐含），`PRAGMA foreign_key_check` 干净——说明 62 个 FK 的父键都存在（`REFERENCES` 指向的列全部是 PK 或 UNIQUE，否则建表不会报错但插入会报 `foreign key mismatch`）。
2. **CHECK 生效**：13 个非法值全部被拒，且错误信息是 `CHECK constraint failed`（可映射到 `GatherErrorCode` 的 DB 约束错误）。
3. **FK 生效**：非法 `session_id` 被拒（`FOREIGN KEY constraint failed`）。
4. **级联正确**：删 `sessions` 一行 → `photos`/`delivery_sessions`/`delivery_items` 全清；`deliveries` **保留 1 行**（刻意：交付是文件级事实，见 §5.5 的孤儿清扫）。
5. **SET NULL 正确**：删 `assets` 后 `photos.asset_id` 变 NULL，照片行不丢。
6. **`user_version` 可读写**：写入 1 后读回 1（`PRAGMA` 在事务内有效，见 §6.1）。


## 8. 风险

按「会不会静默坏数据」排序。P0 = 会造成静默错误或不可恢复的数据丢失；P1 = 会造成功能回退但可观测；P2 = 性能/维护成本。

### R1（P0）列级对账遗漏

- **触发**：SchemaV1 一次成型，没有迁移链兜底；对照基线（391 列）本身少 5 列（§0）；`SELECT *` 行映射按**位置**取值（42 处，如 `AnalysisJobRepo.swift:52-64`），删列后 `row[i]` 会静默读到隔壁列（`textValue` 对 INTEGER 返回 nil → 字段变空串，**不报错**）。
- **影响**：字段错位、界面空白、分析结果写错列，且测试可能仍然绿（断言只覆盖部分字段）。
- **缓解**（全部写进 Cut 2 验收）：
  1. 生成「有效 schema 快照」：`SchemaV1.create` 建库后 `PRAGMA table_info` 全表导出 JSON，与 §7 的 DDL 逐列比对；
  2. 42 处 `SELECT *` → 显式列清单（Row 类型不再依赖位置）；
  3. `SchemaV1Tests` 用 `@Test(arguments: 43 张表)` 断言「列名 + 列序 + 默认值 + NOT NULL」三项一致；
  4. 删列清单（§2.4 的 63 行）逐行勾选，PR 模板附 `grep` 输出证明引用已清零。

### R2（P0）FK 顺序与级联语义变化

- **触发**：15 个原本 `NO ACTION` 的 FK 中 11 个改 `CASCADE`、4 个改 `SET NULL`（§3.2）。行为差异在**删除路径**上最明显，且新行为是「自动成功」而不是「报错」，比失败更难被发现。
- **具体坑**：
  1. `role_bindings.cluster_id` 改 CASCADE 后，任何 `DELETE FROM face_clusters` 都会静默删除用户绑定（`FaceRepo.swift:914/1001` 今天靠「先删绑定」保护）。业务上「解除绑定」必须是显式动作，不能由级联代替。
  2. 同一张 `asset_analysis` 有两个父：`photo_id` SET NULL（行保留）、`asset_file_id` CASCADE（行删除），两种结局都要有测试。
  3. `PRAGMA foreign_keys` 是**连接级**开关且不能在事务内切换；`Database.open` 之后任何新开连接（含只读连接）都必须重设。
  4. 部分索引 / `strftime` 默认值 / 表达式索引在 SDK 的 CSQLite 上需实测（§7.2 只验证了系统 sqlite3 3.54）。
- **缓解**：`SchemaV1Tests` 增加「删除矩阵」：对 6 个父表（sessions / photos / assets / asset_files / persons / deliveries）各跑一次删除，断言子表行数与预期一致（第 5、6 项已验证的形态扩展成表驱动）。

### R3（P1）CHECK 与 Swift enum 漂移

- **触发**：§4.2 有 **33 行 CHECK 对照**，涉及 **31 个 Swift enum**，其中 **22 个是本次新建**（`PhotoStatus`、`AssetStatus`、`AssetMediaType`、`AssetOnlineStatus`、`AssetMemberRole`、`AssetBindingSource`、`AssetLinkRelation`、`AssetLinkStatus`、`SidecarBindingStatus`、`BackfillStatus`、`AnalysisRunKind`、`AnalysisRunStatus`、`FaceClusterStatus`、`FaceFeedbackDecision`、`DuplicateGroupType`、`NavigationGroupType`、`MetadataKeywordSource`、`DeliveryStatus`、`DeliveryItemStatus`、`DeliveryModule`、`DeliveryIntentKind`、`DeliveryIntentPhase`），CHECK 字面量与 enum 是两份文本。
- **现状证据**：`TemplateServiceTests.swift:175` 已经出现 enum 之外的 `"indexed"`；`WritebackRepo.updateStatus(status: String)` 允许任意字符串。
- **后果**：V1 上线后非法值会从「静默入库」变成「写入抛错」——这是**期望**，但必须在 UI 侧把 DB 约束错误映射成明确文案，否则用户看到的是原始 `CHECK constraint failed`。
- **缓解**：CHECK 片段由 `enum.allCases.map(\.rawValue)` 生成（`SchemaV1.swift`），测试双向断言 `Set(enum.allCases) == Set(CHECK 集合)`；新增值必须同 PR 改两处。

### R4（P1）旧库重置的用户提示

- **触发**：`user_version` 不匹配 → 移走库 + 新建。开发期约定「换 schema 即重置」，但**真实用户**会丢：会话、挑片决策、身份绑定、相似度/人脸缓存。
- **不丢**：照片与 XMP 文件（库外）、已写盘的 XMP 内容、`gather.sqlite.incompatible-*` 备份文件。
- **必须做的提示**：
  1. 首次启动检测到 reset → 一次性对话框（不是 Toast）：说明「数据库已升级为 v1，旧数据已备份到 …，照片与 XMP 不受影响」；
  2. `app_settings` 里写 `db.last_reset_at` / `db.last_reset_backup`，设置页可查；
  3. 日志一条 `warn`，含旧 `user_version` 与备份路径；
  4. 不自动删除备份（保留 3 份后按时间戳淘汰）。
- **额外坑**：只移主库不移 `-wal`/`-shm` 会让新库看到旧页（§6.2），表现为「新 schema + 旧数据」的错位崩溃。

### R5（P1）delivery 迁移期的双写与回放幂等

- **触发**：Cut 2 内 `metadata_outbox` / `writeback_items` 与 `deliveries` 并存一天，就会出现两套状态机同时写。
- **纪律**：**同一个 PR 内删旧表 + 删旧 Repo + 删旧测试**（与 CL-03 的验收一致）；不做双写过渡。
- **回放幂等**：`phase='fileDone'` 只补 DB 段；`prepared` 重做文件 + DB；`deliveries` 删除带 `revision` 守卫（期间有新输入就保留 + intent 记 warn）。
- **孤儿交付**：删会话后 `deliveries` 行会残留（文件级事实，没有 session FK），必须由 cleanup 的清扫语句收尾：
  ```sql
  DELETE FROM deliveries
   WHERE NOT EXISTS (SELECT 1 FROM delivery_sessions d WHERE d.delivery_id = deliveries.id)
     AND NOT EXISTS (SELECT 1 FROM delivery_items i WHERE i.delivery_id = deliveries.id);
  ```
  （§7.2 第 7 步已验证：执行后 `deliveries=0`。）

### R6（P2）索引增加带来的写放大与 EQP 变化

- 索引 62 → 69，其中 13 个是 FK 级联索引（删除性能）。写入路径（导入/分析批量插入）会多维护 18 个索引。
- 缓解：Cut 2 用 10k 照片导入基准对比；`idx_photos_created_at`、`idx_metadata_cache_camera_make`、`idx_similarity_members_result_group`、`idx_analysis_jobs_scope` 用 `EXPLAIN QUERY PLAN` 校准，不通过就删（§3.3）。

---

## 9. 附录

### 9.1 每表列数（V1 实测，与 §7 DDL 一致）

| 表 | 列数 | 表 | 列数 | 表 | 列数 |
| --- | --- | --- | --- | --- | --- |
| sessions | 10 | face_clusters | 9 | duplicate_groups | 8 |
| assets | 4 | face_cluster_members | 7 | duplicate_group_members | 8 |
| asset_files | 14 | role_bindings | 7 | culling_decisions | 11 |
| photos | 14 | similarity_hashes | 6 | culling_history | 5 |
| analysis_runs | 10 | similarity_results | 7 | navigation_groups | 10 |
| asset_members | 7 | similarity_result_members | 4 | metadata_keyword_origins | 6 |
| asset_link_candidates | 9 | similarity_cluster_state | 5 | app_settings | 2 |
| session_assets | 5 | similarity_cluster_meta | 11 | smart_albums | 10 |
| sidecar_bindings | 7 | persons | 8 | workflow_templates | 6 |
| sidecar_binding_files | 3 | person_embeddings | 7 | deliveries | 14 |
| sidecar_metadata_state | 6 | person_photos | 7 | delivery_sessions | 4 |
| asset_backfill_state | 9 | photo_metadata_cache | 22 | delivery_items | 11 |
| analysis_jobs | 24 | asset_analysis | 11 | delivery_intents | 8 |
| face_observations | 17 | face_analysis_state | 6 | （合计 43 表 / 373 列） | |
| face_identity_feedback | 11 | face_cluster_state | 3 | | |

### 9.2 复算命令（只读，Reviewer 自证）

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
# 旧 schema 的行数（44 表 / 63 FK / 62 索引）
grep -c 'CREATE TABLE IF NOT EXISTS' desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift   # 44
grep -c 'REFERENCES'                 desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift   # 63
grep -c 'CREATE INDEX\|CREATE UNIQUE INDEX' \
  desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift                                      # 62
# 迁移独有列（Schema.swift 里没有，只在 ALTER TABLE 里）
grep -n 'addColumn(db, "face_clusters"' desktop/native/gather-core/Sources/GatherCore/Database/Migrations.swift
# SELECT * 行映射（删列风险面）
grep -rn 'SELECT \*' --include=*.swift desktop/native/gather-core/Sources | wc -l                            # 42
# 内联 SQL 测试面
grep -rn 'prepare(' --include=*.swift desktop/native/*/Tests | wc -l                                        # 400（42 文件）
```

### 9.3 Cut 2 验收清单（本草案的落点）

| # | 验收 | 命令 / 测试 |
| --- | --- | --- |
| 1 | SchemaV1 建表 = 本文件 §7.1 逐字一致 | `sqlite3 :memory: < SchemaV1.sql` + `PRAGMA table_info` 快照比对 |
| 2 | 43/373/69/62 四个数字 | `check-schema-v1.sh`（新增门禁，断言四个计数） |
| 3 | 每个 CHECK 与 enum 双向相等 | `SchemaV1Tests.enumMatchesCheck`（参数化 31 个 enum / 33 行 CHECK） |
| 4 | 死表/死列/死索引引用 = 0 | `grep -rn 'asset_file_metadata\|schema_version\|metadata_outbox\|writeback_items\|capture_fingerprint\|path_conflicts' Sources` = 0 |
| 5 | 删除矩阵（6 父表 × 期望行数） | `SchemaV1Tests.cascadeMatrix` |
| 6 | 156 个内联 SQL 用例全部改到新列集 | `swift test`（core + app） |
| 7 | 旧库重置路径 | `DatabaseOpenTests`（user_version 0/1/2/非 SQLite 文件四种输入） |
| 8 | 56 个 CASCADE / 6 个 SET NULL 逐项有测试 | `SchemaV1Tests.foreignKeyActions` |
