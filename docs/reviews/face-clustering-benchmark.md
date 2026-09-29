# 人脸识别与聚类：本仓现状 vs Immich / PhotoPrism / digiKam

> 方法：1 个代理只读盘点本仓（证据为 `文件:行号`），2 个代理用官方文档 + 源码 + issue 调研竞品（结论附 URL）。本文把三份报告整理为**可执行的对标结论**。
> 竞品基线：Immich v3.2.2（2026-09-15）、PhotoPrism 官方文档与 `internal/ai/face/README.md`、digiKam 官方文档。

## 0. 一句话结论

**我们的工程骨架（表结构、状态机、写回影响面预览、断点恢复）不弱于竞品，但"人脸识别"的**算法核心**落后一代**：没有关键点对齐、没有专用人脸嵌入模型（用的是通用图像特征）、没有质量筛选、没有人脸级模型版本治理。竞品真正值得学的是这四件事，而不是它们的 UI 皮肤。

## 1. 本仓现状（as-is）

| 环节 | 实现 | 证据 |
| --- | --- | --- |
| 检测 | Vision `VNDetectFaceRectanglesRequest`；`conf ≥ 0.5`、单图最多 100；NMS 0.4 字段保留 | `core/Face/Encoder.swift:78,55,91`、`Face/Provider.swift:49-52` |
| 对齐 | **无关键点、无对齐**，直接按 bbox 裁剪 | `core/Face/Encoder.swift:92-101` |
| 嵌入 | `VNGenerateImageFeaturePrintRequest` **rev2（通用图像特征，非人脸识别模型）**，实测 768 维 float32、L2 归一化；代码注释里的契约是 512 维 | `core/Face/Encoder.swift:117-149`、`Face/Provider.swift:55` |
| 度量/匹配 | cosine；匹配线 = `persons.match_threshold`，默认 **0.65** | `core/Face/Matcher.swift:189-206,216`、`FaceKwService.swift:1241` |
| 向量索引 | ≤2 万暴力扫描；>2 万走 angular-LSH（bits16/tables6/probe2 + 精确复核）；HNSW 仅基准/测试引用 | `core/Face/Matcher.swift:104`、`Face/VectorIndex.swift:545-581,104` |
| 聚类 | DBSCAN：`eps`=相似度下限 **0.6**（越大越严）、`minPts=2`；>2 万走 LSH；参数经 settings `default_eps`/`default_min_samples` | `core/Face/Clusterer.swift:63-68,129,164`、`FaceKwService.swift:540-541` |
| 落库 | `face_observations`(bbox/embedding/confidence)、`face_clusters`(**status 仅 unbound\|bound**)、`persons`、`person_embeddings`(quality)、`person_photos` | `core/Database/Schema.swift:210-252,347-386` |
| 绑定/合并 | `bindCluster`→`updateBinding`→`PersonRepo.bindRole`+向量入库；解绑=确认+受保护词过滤+`removeOwnedFaceKeywords`；合并 `fkw.merge`；剔成员 `remove_member`；**无 split**；重聚类按照片重叠迁移绑定 | `FaceKwService.swift:926-971,989-1025,1028,1046,1252-1287` |
| 跨会话建议 | 写 `matched_person_id`/`match_confidence`，不覆盖已绑定 | `FaceKwService.swift:1209-1246` |
| 写回 | **仅 `dc:subject` 扁平关键词**；全仓无 `mwg-rs` 区域；去重 `orderedUnion`；写前 `.gather-backup-UUID` + restore | `core/Services/SidecarXMPProvider.swift:436-443,173-200`、`WritebackService.swift:706,641-647` |
| 性能 | 人脸推理并行 ≤2、解码窗 4；跨会话复用 observation；相似度解码 4 | `FaceKwService.swift:700,726,778,660-682`、`SimilarityService.swift:315` |
| 评测 | 只有性能基准 + `召回 ≥ 0.95` 对账测试；**无标注集准确率** | `core/Sources/GatherCoreBenchmarks/main.swift:145-287`、`Tests/.../MatcherReconciliationTests.swift:136` |

**能力缺口清单**：质量筛选 ❌（仅 conf ≥ 0.5；`QualityService.faceQuality` 已算但未参与过滤，`QualityService.swift:281,443-469`）· 隐藏/待确认状态 ❌（status 只有 unbound/bound）· 区域写回 ❌ · 人脸级模型版本 ❌（`analysis_signature` 有模型指纹但 observation 行没有 model_id/version，`FaceKwService.swift:597-606`）· 增量人脸聚类 ❌（每次全量重算；相似度侧已有增量，`SimilarityService.swift:720-765`）· 拆分 ❌。**风险**：768 维实测 vs 512 维契约不一致；换模型无迁移路径（`FaceKwService.swift:649-652,1338-1359`）。

## 2. 竞品技术对照

| 维度 | 本仓 | Immich | PhotoPrism | digiKam |
| --- | --- | --- | --- | --- |
| 检测模型 | Vision 矩形（无关键点） | InsightFace SCRFD（640×640 letterbox、NMS 0.4） | YuNet（ONNX，640 输入、5 关键点） | 深度模型（可下载） |
| 对齐 | **无** | 5 点 Umeyama → 112×112 | 5 关键点 → 112×112 | 有检测/识别两阶段 |
| 嵌入 | 通用 FeaturePrint rev2，768 维 | ArcFace，512 维 | SFace 128 维（旧库 FaceNet 512） | 深度模型 |
| 运行时 | Apple Vision（系统框架，零依赖） | Python/FastAPI + ONNX Runtime | ONNX Runtime（+CoreML/CUDA） | 本机模型 |
| GPU | Apple 神经引擎（Vision 内部） | CUDA/ROCm/OpenVINO/CoreML/ARM NN/RKNN | `PHOTOPRISM_ONNX_PROVIDER=cpu\|cuda`；macOS 原生 CoreML | 无 |
| 可调参数 | 阈值 `match_threshold`、`default_eps`、`default_min_samples` | 3 个（minScore 0.7 / maxDistance 0.5 / minFaces 3）+ 模型 | **几乎全部**（SCORE/SIZE/OVERLAP/CORE/DIST/MATCH_MARGIN…） | 相似度阈值未开放 |
| 聚类 | DBSCAN（eps/minPts）全量重算 | 增量 KNN-DBSCAN（pgvector + HNSW，ef 300/m 16） | DBSCAN 变体（CORE=5、DIST=0.72）+ 二次 pass | 增量扫描/全量重建 |
| 模型切换 | 无迁移，observation 无版本 | 需 force 重跑；换模型重排 All | `faces migrate`（全库重算 + 先备份） | Maintenance 重建/重置 |
| 增量 | ❌（人脸） | ✅ + 夜间任务 | ✅（随索引，`FACE_RUN=auto`） | ✅ |

来源：[Immich facial-recognition](https://docs.immich.app/features/facial-recognition)、[PhotoPrism face-recognition](https://docs.photoprism.app/user-guide/ai/face-recognition/)、[PhotoPrism face README](https://github.com/photoprism/photoprism/blob/develop/internal/ai/face/README.md)、[digiKam People](https://docs.digikam.org/en/left_sidebar/people_view.html)。

## 3. 聚类质量与参数治理

| 议题 | 竞品做法 | 对我们的启示 |
| --- | --- | --- |
| 歧义脸 | PhotoPrism `MATCH_MARGIN=0.01`：夹在两人之间的脸**保持未分配**而非猜 | 我们"取最近且 ≥ 阈值即绑定"是个隐患；应加 margin + "待确认"态 |
| 低质量脸 | PhotoPrism `FACE_SIZE=25`（重试 10）、`FACE_SCORE=65`、OVERLAP、二次 pass；Immich 无尺寸参数 | 我们只按 conf ≥ 0.5 过滤；应引入尺寸/清晰度/角度门槛并用 `faceQuality` 参与排序 |
| 聚类参数 | PhotoPrism 全暴露 + `faces update --force`；Immich 只 3 个且"只对新 job 生效" | 我们已有 settings 但缺"改参数需重算"的**显式提示与预览**；建议做"重算影响预估" |
| 增量 | Immich 增量 + nightly；大库官方建议临时调大 core 再重置（**代价是丢命名**） | 我们每次全量重算；可复用已有 HNSW/LSH + `IncrementalClusterer` 做增量指派 |
| 模型治理 | PhotoPrism 换模型需 `faces migrate`（不可逆）；Immich 重跑会删已检测人脸（issue #12769） | 我们要**先**补 observation 的 model_id/version 与维度守卫，再谈换模型 |

竞品官方承认的短板（供我们避坑）：PhotoPrism 儿童/跨年识别差（[#1587](https://github.com/photoprism/photoprism/issues/1587)）、旋转 ±30° 起下降、90° 全漏、索引人脸内存异常增长（[#5394](https://github.com/photoprism/photoprism/issues/5394)）；Immich 把狗/风景误聚成人（[#12450](https://github.com/immich-app/immich/issues/12450)）、向量索引升级后查询退化（[#31826](https://github.com/immich-app/immich/issues/31826)）、重跑删脸（[#12769](https://github.com/immich-app/immich/issues/12769)）。

## 4. 交互与产品化对照

| 能力 | Immich | PhotoPrism | digiKam | 本仓 |
| --- | --- | --- | --- | --- |
| 人物页 | People 列表 + 无限滚动 + 搜索 + 生日显示年龄 | Recognized / **New Faces** 分区 | People 标签即人脸标签 | `Persons` 列表（仅 CRUD） |
| 合并 | `POST /people/merge`（按序取首个非空名/生日） | 手动指认 + "报告错误匹配"触发重算 | 拖拽 + 快捷键批量确认 | 有 `fkw.merge`／`person.merge`（后者**无 UI**） |
| 拆分 | 无独立按钮 = 在人脸侧栏 **reassign** 到他人/新建 | 改派 | 手动画框 | **无**（只能逐条 `remove_member`，且成员被截断为前 4） |
| 隐藏/忽略 | `isHidden`、`/people/manage` 批量显隐 | 隐藏人/簇、Private/Hidden（对 Guest 隐姓名，非加密） | `Ignored` 状态 | 无（status 仅 unbound/bound） |
| 置信度 | **不展示**，只存 bbox | 不展示 | 不展示 | 已算 `match_confidence` 但 **UI 零引用** |
| 按人检索 | 搜索过滤器 personIds | `person:"John"`、`faces:3` | People 标签筛选 | 有 `person.search_photos` 命令，**无 UI** |
| 未识别脸 | `face_unassigned`，可在资产详情指派 | New Faces 分区 | Unknown/Unconfirmed | 无专门入口 |

**结论**：我们在"置信度已算未用""合并有命令无 UI""按人检索无 UI"三处是**纯前端补齐**即可超过竞品（它们大多不展示置信度）；而"拆分/隐藏/未识别入口"需要在 core 加状态。

## 5. 数据去向：是否污染原始文件（重要）

| 产品 | 是否写回原文件 | 人脸区域 | 备注 |
| --- | --- | --- | --- |
| **本仓** | 写回 **XMP 侧车**（不碰原图），仅 `dc:subject` 扁平词 | ❌ 无 mwg-rs | 有 `.gather-backup-UUID` + restore 可回滚 |
| PhotoPrism | **不写回**（除方向）：结果在 DB + 可读 YAML sidecar | 读取 MWG/Adobe/digiKam 区域需显式开 `PHOTOPRISM_XMP_FACES`（默认 false） | ["does not yet offer … write … back"](https://docs.photoprism.app/user-guide/library/metadata/) |
| Immich | 只写 `.xmp` sidecar（Description/Rating/DateTime/Location/Tags） | ❌（PR [#30704](https://github.com/immich-app/immich/pull/30704) 的 mwg-rs 导出已关闭未合并） | 互相操作弱（[#31629](https://github.com/immich-app/immich/issues/31629)） |
| digiKam | **默认写回**（tag 路径 + 人脸矩形，通常 XMP/MWG）；可关 | ✅ | 可配置为"只写 sidecar" |

**建议**：保持"默认只写 `dc:subject`、不写区域"的保守策略；若要互操作，做成**显式 opt-in 的 MWG-rs 区域导出**（参考 digiKam 的可配置模型），并复用现有备份/回滚机制。

## 6. 可学项（按投入产出比排序）

| # | 学什么 | 为什么 | 成本 | 预期收益 |
| --- | --- | --- | --- | --- |
| 1 | **关键点对齐 + 专用人脸嵌入**（Vision `VNDetectFaceLandmarksRequest` 做 5 点仿射 → 112×112，再用 CoreML 跑 ArcFace/SFace 类模型） | 当前用通用 FeaturePrint 且未对齐；这是准确率的**数量级**差异来源 | 中-高（模型 + 迁移 + 维度守卫） | 大幅提升，尤其侧脸/旋转 |
| 2 | **质量筛选 + 质量参与聚类**（尺寸/清晰度/角度入 observation，`faceQuality` 参与 core point 选择） | 竞品都做；我们字段已有却未用 | 低（字段在，加过滤与排序） | 减少误聚 |
| 3 | **歧义脸不猜**（margin 判定 + `pending` 状态） | PhotoPrism `MATCH_MARGIN` 的直接借鉴 | 低-中（加状态 + UI 入口） | 减少误绑定，给"待确认"漏斗 |
| 4 | **把已算好的置信度与建议显示出来**（`matchedPersonName`/`match_confidence` + 一键采纳/否决） | 竞品**都不展示**置信度，我们可借此做出差异 | 低（纯 UI + 已入库字段） | 审核效率显著提升 |
| 5 | **拆分/改派/隐藏**（`face_clusters.status` 扩展为 unbound/bound/hidden + reassign） | 误聚类目前不可修（成员截断 + 无 split） | 中（命令面 + UI） | 误聚类可修，是"可用/不可用"的分界 |
| 6 | **模型版本治理**（observation 加 model_id/version + 维度守卫 + "换模型需重算"提示） | 竞品换模型都不可逆或需全量重算；我们连字段都没有 | 低-中（迁移 + 提示） | 避免换模型时静默污染 |
| 7 | **增量人脸聚类**（复用 HNSW/LSH + `IncrementalClusterer` 思路，新脸只做最近邻指派；夜间全量校正） | Immich/PhotoPrism 都增量；我们每次全量 | 中-高 | 大库可用性 |
| 8 | **参数变更的"重算影响预估"**（改 eps/minPts 时显示"预计重算 N 张、影响 M 个簇"） | 竞品只有"须 --force"或"只对新 job 生效" | 低（复用现有统计） | 参数可调但不惊吓 |
| 9 | **标注集准确率基线**（少量标注 fixture + precision/recall 报告） | 我们只有召回对账与性能基准；Immich 用 buffalo_s/l 对比证明模型选择的价值 | 低-中（fixture + 脚本） | 让 #1 的收益可被证明 |
| 10 | **可选 MWG-rs 区域导出**（opt-in + 备份） | digiKam 是唯一默认写区域的；互操作需要它 | 中 | 与 Lightroom/digiKam 互操作 |

## 7. 不建议照抄的部分

1. **Immich 的跨用户 cluster group（v3）**：引入"共享人脸聚类"的隐私面与跨用户合并缺陷（[#31117](https://github.com/immich-app/immich/issues/31117)、[#31514](https://github.com/immich-app/immich/issues/31514)）；我们是单用户桌面工具，无需这一层。
2. **PhotoPrism 的"结果完全数据库化 + 不写回"**：它的取舍是 Web 多端一致性；我们的价值主张恰是**与 Capture One 的双向元数据同步**，不能放弃可回滚的写回能力。
3. **默认写回人脸区域**：digiKam 的做法会修改原始文件；我们保持 opt-in（且已有备份/回滚）。
4. **先上 ONNX/GPU 大模型再谈精度**：Vision 是零依赖且走 Apple 神经引擎；正确顺序是**先修对齐与质量筛选**，再评估是否引入专用模型（CoreML 亦可承载）。
5. **无限暴露参数**：PhotoPrism 有 10+ 个聚类旋钮，官方 issue 里大量"调参后不可逆/需 force 重算"的困惑；我们应暴露**少而可解释**的参数 + 影响预估。

## 8. 参考来源

- Immich：[facial-recognition](https://docs.immich.app/features/facial-recognition) · [ml-hardware-acceleration](https://docs.immich.app/features/ml-hardware-acceleration) · [better-facial-clusters](https://docs.immich.app/guides/better-facial-clusters) · [xmp-sidecars](https://docs.immich.app/features/xmp-sidecars) · 源码 `machine-learning/immich_ml/models/facial_recognition/*`、`server/src/services/person.service.ts`（v3.2.2）
- PhotoPrism：[user-guide/ai/face-recognition](https://docs.photoprism.app/user-guide/ai/face-recognition/) · [developer-guide/vision/face-recognition](https://docs.photoprism.app/developer-guide/vision/face-recognition/) · [config-options](https://docs.photoprism.app/getting-started/config-options/) · [known-issues](https://docs.photoprism.app/known-issues/) · [internal/ai/face README](https://github.com/photoprism/photoprism/blob/develop/internal/ai/face/README.md)
- digiKam：[People View](https://docs.digikam.org/en/left_sidebar/people_view.html) · [Metadata settings](https://docs.digikam.org/en/setup_application/metadata_settings.html) · [Maintenance Faces](https://docs.digikam.org/en/maintenance_tools/maintenance_faces.html)
- 本仓证据：见第 1 节各行 `文件:行号`。

---

*本文档由 3 份代理报告汇总（1 份本仓只读盘点 + 2 份竞品调研）。竞品结论均附官方来源；本仓结论均可按 `文件:行号` 复核。*
