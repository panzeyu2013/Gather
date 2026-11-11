# 感知级相似/重复：标注评估与立项决策（ROADMAP 决策 A 评估物）

- 日期：2026-11-11；任务：Wave3 / task-19（评估任务，**不改产品行为**）
- 关联：`20-culling-browse.md`（#5 找相似只能找到连拍）、`50-ai-culling.md`（§3 #8 感知级去重缺失）
- 交付物：① 标注集规范 + 本地采样脚本；② `gather-triage-eval similarity-eval` 评估工具（含 `--self-test`）；③ 本报告（决策规则、阈值先验、失败类型、成本）
- 状态：**工具与规范已完成、可复现；真实数据集尚未标注/跑批**。本报告的确定性结论只到"评估口径与决策门槛"为止，不上填任何未跑出来的数字。

---

## 0. 结论先行

1. **现在还不能对"是否值得立项 embedding"下结论**——缺的不是技术判断，而是**标注数据**。ROADMAP §六 要求的四个问题（连拍是否该合并 / 同场景不同人物是否该合并 / 不同客户构图相似是否误合并 / 阈值档的 precision/recall/过度合并率）没有任何一项有 ground truth 数据支撑，凭印象立项或否决都不合格。
2. 本任务把"可复现"补齐：一条 `sample-similarity-annotation.sh` 产标注脚手架，一条 `similarity-eval` 命令把标好的集跑成**阈值曲线 + 过度合并率 + 聚类 ARI + 失败样例**，并自动给出 dHash 基线对照。**同一标注集 + 同一命令 = 同一结论**（数据集指纹写进报告）。
3. **建议的决策框架（先定门槛，再看数据）**：如果 embedding 通道在"连拍"上相对 dHash 的 recall 提升 < 10pp，或在"不同客户构图相似"上过度合并率高于 dHash，则**不立项**；如果提升显著且失败样例可归入"可接受/可打标"的类型，则先做 **A1：Vision FeaturePrint 免费通道 + 用户反馈闭环**，把"自训模型/CLIP"留到 A2（需新模型资产，违反现有零模型约束）。
4. **阈值不写死**：推荐点由曲线自动给出（在 precision ≥ 0.95 约束下取 recall 最大）。先验锚点：dHash 产品阈值 = 汉明 ≤4（≈ 相似度 0.9375），语义索引默认余弦 0.92；据此**候选区间 0.90–0.96**，但最终以曲线 + 过度合并率共同决定。
5. **成本量级**：标注 2–3 人日（4 类 × ≥5 组 × ~6 张 ≈ 120 张 + 双人复核），评估跑批 0.5 人日；若立项，生产化（embedding 管线上线 + 回填 + 阈值档 + UI/API 接入）约 **1.5–3 周（L）**，可复用现有 `Face/VectorIndex.swift`（LSH）与 `SemanticIndex` 的 Float16 存储。

---

## 1. 问题与现状基线（代码证据）

### 1.1 现在的"相似/重复"只有 64 位 dHash
- 唯一的感知指纹是 dHash：9×8 灰度逐行比较、64 位：`desktop/native/gather-core/Sources/GatherAnalysis/Similarity/Hash.swift:20`（`bitCount = 64`）。
- 视觉重复 = 256px 缩略图 → dHash → 汉明距离聚类，**默认阈值 4**：`desktop/native/gather-core/Sources/GatherApplication/Services/DuplicateService.swift:94-113`（`thumbnailProvider(photo.filepath, 256)`）、`:270`（`visualThreshold ?? 4`）。
- 相似度分析（相似页的"同场景不同机位"）复用同一套 dHash 域与阈值档，**不是 embedding**：`GatherProtocol/API/SimilarityAPI.swift:21-30`、`SimilarityService`。
- ROADMAP 自己承认的现状："找相似只能找到连拍"（`docs/ROADMAP.md:14`），embedding 方案待标注评估（`:26`）。

### 1.2 已经有一份"零成本"的语义向量可用（但不是产品行为）
- Vision FeaturePrint（~2048 维）+ top-8 分类标签已经在语义索引里采集，Float16 压缩存储约 4KB/张：`GatherApplication/Services/Semantic/SemanticIndex.swift:1-10`、`:70-73`（Float16 依据）、`:627-678`（`ImageSemanticsExtractor.observe`）。
- 图搜图默认余弦 0.92、场景分组 0.92/标签 Jaccard 0.5：`SemanticIndex.swift:267-270`。
- 但**默认关闭且只在质量分析时顺带采集**：`SettingsKey.swift:182`（`semantic_index_enabled = "0"`）、`ModelReviewService.swift:10-13`。所以它现在是"评估用临时向量"的最佳候选：不新增模型资产、不引入云、和在产品里已跑过的解码路径一致（1280 预览）。

### 1.3 决策 A 的原文要求（评估口径的唯一来源）
- `docs/ROADMAP.md:24-32`：dHash 打底 + Embedding 分层；**价值假设未经标注数据证实，先做 §六 评估，再建管线**。
- `docs/ROADMAP.md:61-65`（§六 产品假设验证）：评估"连拍是否应合并；同场景不同人物是否应合并；不同客户但构图相似是否误合并；时间/文件夹/相机与 EXIF 是否参与融合；高/中/低三档阈值的 precision、recall 与过度合并率"。

> 结论：本评估物的四类标注就是 §六 的前三项的直接映射；第五项（三档阈值的 P/R/过度合并率）由工具输出的曲线覆盖。

---

## 2. 标注集规范（①）

### 2.1 四类与 ground truth 语义

| class | 定义 | 预期 ground truth | 为什么要有 |
|---|---|---|---|
| `burst` | 同一瞬间的连续帧（连拍） | **merge**（保留最佳帧） | embedding 立项的第一收益点：dHash 对"位移/表情变化"的连拍常常漏合并 |
| `same_scene_different_time` | 同地点/光线但不同时刻 | **separate** | 防"同场景一刀切"；dHash 反而容易误合并（背景一致） |
| `same_scene_different_people` | 构图近似但主体人物不同 | **separate** | 婚礼/活动最痛的误合并；语义向量可能因"场景一致"而翻车 |
| `different_client_similar_composition` | 跨客户/跨会话的构图撞车 | **separate** | 证明"跨会话合并"绝不能做；也是 dHash 的已知误合并来源 |

- 组内 pair 的标签由 `groundTruth` 决定：`merge` → 正样本；`separate` → 负样本；**跨组 pair 一律负样本**（不同组不许合并）。
- 每类 **≥5 组**（工具不强制、报告里会显示每类 pair 数；<5 组的结论按"样本不足"处理）；每组建议 **4–8 张**（组越大 pair 越多，O(n²) 成本越高）。

### 2.2 JSON 格式（工具首选）

```json
{
  "version": 1,
  "generatedBy": "sample-similarity-annotation.sh",
  "groups": [
    {"id": "g001", "class": "burst", "groundTruth": "merge",
     "photos": ["/abs/a.CR3", "/abs/b.CR3", "/abs/c.CR3"]},
    {"id": "g002", "class": "same_scene_different_people", "groundTruth": "separate",
     "photos": ["/abs/x.CR3", "/abs/y.CR3"]}
  ]
}
```

规则（工具会显式失败，不静默少算）：
- `version` 可省（默认 1）；`generatedBy` 可省；
- `id` 唯一；`photos` ≥2 张且同组内不重复；
- `class` 必须四类之一；`groundTruth` 必须 `merge`/`separate`（采样脚本产出 `null`，必须人工填）；
- 相对路径按**标注文件所在目录**解析；绝对路径原样。

### 2.3 CSV 格式（表格工具/人工标注用）

```csv
group_id,class,ground_truth,photo_path
g001,burst,merge,/abs/a.CR3
g001,burst,merge,/abs/b.CR3
g002,same_scene_different_people,separate,/abs/x.CR3
```

表头可省；`#` 开头为注释；同一 `group_id` 的 class/ground_truth 必须一致（否则显式失败）。

### 2.4 本地采样脚本

```bash
scripts/sample-similarity-annotation.sh \
  --root ~/Pictures/wedding-2026-05 \
  --class burst --gap 2 --max-groups 20 --per-group 6 \
  --format json --out /tmp/ann-burst.json
```

实现要点（都会在 stderr 打印，避免"采样偏差被静默吞掉"）：
- 文件按路径排序后用**相机拍摄时间**（macOS `mdls kMDItemContentCreationDate`）切组，gap 默认 2 秒；
- EXIF 缺失时退回文件 mtime，并打印"mtime 兜底 N 张"（这类组的时间相邻性不可信，标注时应排除或改成同场景类）；
- `--stride` 等距抽样保证**可复现**（同目录同参数 = 同一脚手架）；`--max-groups`/`--per-group` 控制规模；
- **只产脚手架**：`groundTruth: null` 等人工填；不重命名/不移动照片。

### 2.5 标注流程与质量规则
1. 每个拍摄日抽 1–2 类（不要在同一目录里硬凑四类——不同客户类要**混两个拍摄的目录**）；
2. 单组标注：先看整组 6 张，决定"是否应该合并成一张逻辑资产"，再填 merge/separate；
3. 双人复核：第二人只看第一人的结论 + 缩略图，不一致的组标记 `disputed` 并从评估集剔除（工具不认 disputed，请在 JSON 里删掉该组）；
4. 冻结版本：标完把文件放进仓库外的工作目录，**记录 sha256**（工具输出 `datasetHash` 会自动写进报告）；
5. 禁止用"结果好看"的组回填——标注必须独立于阈值扫描（否则阈值曲线自证）。

### 2.6 常见坑
- **RAW+JPEG 变体**：同一张的两种格式在产品里是"同一逻辑资产的不同文件"（`asset_id` 合并），不属于本标注的"相似组"；采样时按 `--root` 选一个格式目录。
- 输出图/截图/手机图混入：先用产品现有的工具图判定排除（`ModelReview` 的 `isUtilityImage`），否则它们会污染 burst 类。
- 跨会话类（`different_client_similar_composition`）必须放**两个不同会话的照片**，报告要注明"产品当前不支持跨会话合并"，它衡量的是"是否会被误合并"而不是"是否能合并"。
- 时间戳全相同（某些相机连拍）时 gap 切组会整段并成一组，改用 `--per-group` 截断 + 人工拆组。

---

## 3. 评估工具（②）

### 3.1 用法

```bash
# 0) 纯逻辑自检（不需要图片；Lead 可在 CI 里跑）
swift run --package-path desktop/native/gather-core gather-triage-eval \
  similarity-eval --self-test

# 1) FeaturePrint 通道（临时向量，零模型资产）
swift run --package-path desktop/native/gather-core gather-triage-eval \
  similarity-eval --annotations /path/ann.json --source featureprint \
  --min-precision 0.95 --json /tmp/fp.json --markdown /tmp/fp.md

# 2) dHash 基线（产品现状；用作对照）
swift run --package-path desktop/native/gather-core gather-triage-eval \
  similarity-eval --annotations /path/ann.json --source dhash \
  --json /tmp/dhash.json

# 3) 只跑基线对照（featureprint 报告里会自动附 dHash 对照，--no-baseline 可关）
```

参数：`--thresholds 0.70:0.99:0.01`（或逗号列表；dhash 默认按汉明位 k=0..16 换算）、`--limit-pairs`（跨组 pair 上限，组内 pair 恒保留）、`--min-precision`（推荐点目标）。

### 3.2 指标口径（与 ROADMAP §六 对齐）
- **pair 级**：`precision = TP/(TP+FP)`、`recall = TP/(TP+FN)`、`F1`；**过度合并率 = FP/(TP+FP)**（"判合并的对里有多少其实不该合并"——用户可见形态就是"两张不同照片被并成一张"）。
- **聚类级**（比 pair 级更接近用户感受）：把 predicted merge 边做并查集，与 ground-truth 分区比较：
  - 过度合并真组数（多个真组被连成一片）、漏合并真组数（真组被拆开）、完全一致真组数、ARI；
  - 例：一对 FP 可能只毁一个组，但如果它把"不同客户"两组连起来，ARI 会明显掉——这是 pair 级 precision 看不到的。
- **基线对照**：dHash 用同一批 pair、同一套指标；产品阈值 k≤4（相似度 0.9375）与"dHash 最佳 F1 点"都会列出；**embedding 必须相对这两个点都有可见收益才值得立项**。

### 3.3 输出
- markdown（stdout + `--markdown`）：参数与数据集指纹、阈值曲线表、推荐工作点（是否达标）、聚类级、四类分类表现、前 5 FP/前 5 FN 样例、dHash 基线对照、复现命令；
- JSON（`--json`）：同样的数字，供回归/二期对比（`datasetHash` 用于声明"同一份标注"）。

### 3.4 自检覆盖（`--self-test`，本次交付即验证点）
- pair 指标：合成 4 组（3 张 merge / 2 张 merge / 2 张 separate 高相似 / 2 张 separate 低相似）断言 TP/FP/FN/TN、precision=0.8、recall=1.0、过度合并率=0.2；
- 阈值曲线：3 个阈值升序、逐点混淆矩阵（0.50/0.90/0.97 三档的 TP/FP/FN/TN 与 P/R）；推荐点选择分两条路径验证——**达标路径**（干净样例里 0.95 与 0.97 都满足 P≥0.95，必须取 recall 更大的 0.95）与**回退路径**（合成样例最高点 P=0.5 达不到目标，回退到 F1 最大点 0.90）；
- 聚类级：ARI=1.0 的理想情形、高阈值下漏合并 >0；过度合并计数；
- 标注解码：JSON（camelCase + snake_case）与 CSV（含表头）各一组，非法组/缺 groundTruth 显式报错；
- 向量数学：cosine（含空向量 -1）、汉明距离、dHash→相似度换算（k=4 ⇒ 0.9375）。

### 3.5 已知近似与已知限制（写进报告，避免过度解读）
- 临时向量来自 **1280 预览**（与 `ModelReviewService.previewMaxDimension` 一致），不是 RAW 全分辨率；与线上语义索引同源，因此"能代表线上语义检索"，但不代表"全分辨率下的可判定性"；
- 缩略图兜底解码**不做 EXIF 方向摆正**（HEIC/PSD 无内嵌缩略图时）：评估只看相对相似度，报告需注明；
- 跨会话类只评估"是否误合并"，产品当前没有跨会话合并能力（`SemanticIndex` 按 sessionId 建）；
- Vision 不可用/图片解码失败会计入 `vectorFailures` 并在报告里显示前 5 张，不静默丢样本；
- **采样脚本的时间分组依赖 macOS `mdls`**（`kMDItemContentCreationDate` 读 EXIF 拍摄时间）：EXIF 缺失/不可读（跨平台拷贝、导出图、部分手机 HEIC、被剥离元数据的文件）时**退回文件 mtime** 并打印"mtime 兜底 N 张"。mtime 受拷卡/复制/传输顺序影响，可能与真实拍摄顺序不一致——这类组**不能直接当 `burst` 的 ground truth**，必须人工复核或改归"同场景"类；`burst` 类建议只采"mdls 命中、无兜底"的组（脚本 stderr 会给出兜底计数）。
- 采样脚本只在 macOS 上验证（依赖 `mdls`/`stat -f`）；Linux/CI 上不能跑采样，但**评估工具本身不依赖 `mdls`**，只依赖已标好的 JSON/CSV。

---

## 4. 决策规则（先定门槛，再看数据）

建议在跑真实集**之前**把下面的门槛写进评审记录，避免"跑完之后再找解释"：

| 立项门槛（embedding / A1） | 要求 | 理由 |
|---|---|---|
| `burst` 类 recall | 相对 dHash 最佳点 **+10pp 以上** | 连拍是 embedding 声明的第一收益；不显著就没必要换管线 |
| `same_scene_different_people` + `different_client_similar_composition` 的过度合并率 | **不高于 dHash 基线** | 产品红线：宁可漏合并（用户手动并），不可错合并（毁交付） |
| 聚类级 | 过度合并真组数 = 0 或 ≤1/类 | 一个组毁掉就是一张交付事故 |
| 失败样例类型 | 全部能归入"可打标/可解释"的类型（见 §6）；不允许出现"随机失败" | 门槛之外要能说清"为什么错" |
| 成本 | A1 管线（复用 Vision FeaturePrint）≤ 2 周；A2（自训/CLIP）需新模型资产 → 单独决策门 | 现有零模型资产的约束不能悄悄破 |

**分阶段建议**
- **A0（本评估）**：只跑数据、出报告；结论写入 `docs/ROADMAP.md` §六 的下方，决策 A 状态改为"已评估/待决策"。
- **A1（若门槛通过）**：把 Vision FeaturePrint 从"语义索引"扩成产品级相似/去重通道——复用 `SemanticIndex` 的 Float16 存储（4KB/张）、`Face/VectorIndex` 的 LSH 候选、`SimilarityService` 的阈值档与分组骨架；加"embedding 候选 + 人工确认"的复核流程。**不新增模型资产、不联网。**
- **A2（仅当 A1 数据仍不够）**：自训/CLIP 模型评估——需要新模型资产与标注规模升级，单独评审（当前 ROADMAP 的零模型约束下默认不做）。
- **否决条件**：任一门槛不达标 → 维持 dHash + 现有人工复核；在 20 册 #5 处更新为"已评估，不立项"，避免同一问题反复立项。

---

## 5. 建议阈值（先验 + 由数据决定）

- **不要写死一个数**：工具输出的是"给定 min-precision 的推荐点"；产品化时用**两个档位**（保守/激进）而不是单阈值，与现有"相似度阈值档 T±4/T±8"的产品习惯一致。
- 先验锚点（**不是结论**）：
  - dHash 产品阈值 = 汉明 ≤4 ⇒ 相似度 0.9375（`DuplicateService.swift:270`）；
  - 语义索引默认余弦 0.92（`SemanticIndex.swift:267-270`）；
  - 因此"候选区间 0.90–0.96"，非常像"约 0.94 ±0.02"。但必须同时看**过度合并率**：0.90 在婚礼场景很可能把"同场景不同人物"并掉——这类误合并比漏合并贵得多。
- 报告里的推荐点若显示"min-precision 0.95 未达标（回退 F1 最大点）"，说明该通道在这一类上还不够稳，应直接触发否决条件，而不是调低精度目标。

---

## 6. 失败案例类型（按机理，标注时要专门凑样本）

| # | 类型 | 机理 | 预期表现（待数据验证） | 归到哪类标注 |
|---|---|---|---|---|
| 1 | 裁切/构图微移 | dHash 是对齐后的 9×8 梯度，**裁切会重排整块网格** | dHash 漏合并；featureprint 通常仍高 | burst |
| 2 | 轻微旋转/翻转 | dHash 不做旋转不变性 | 两者都漏（翻转几乎必漏） | burst |
| 3 | 焦距/景深变化（同机位换镜头） | 背景一致、主体比例不同 | dHash 可能误合并；featureprint 视主体占比 | same_scene_different_time |
| 4 | 曝光/白平衡差异 | 梯度结构保留，dHash 不敏感 | dHash 误合并风险高 | burst（同瞬间的曝光包围） |
| 5 | 同构图不同人物 | 场景语义一致、身份不同 | **featureprint 误合并风险最高**（语义向量编码场景） | same_scene_different_people |
| 6 | 同场景不同时刻（人走动/换姿势） | 构图保持、主体位置变 | 两者都可能误合并 | same_scene_different_time |
| 7 | 跨会话/不同客户构图撞车 | 场景/构图高度相似 | 语义向量误合并；且产品**不该有**跨会话合并 | different_client_similar_composition |
| 8 | RAW+JPEG / 不同尺寸同图 | 缩放/压缩 | dHash 多数仍能命中（9×8 粗粒度）；featureprint 视解码 | （不算相似组；用于验证"精确重复"通道） |
| 9 | 截图/输出图/带字图 | 高对比度文字边缘 | dHash 因文字结构误合并；审美/工具图判定可先滤 | burst（混入物） |

> 标注时每个类型至少留 1 组（共 9 组以外，四类要求 ≥5 组仍按 §2.1）；工具报告的"前 5 FP/FN"会自然落在这些类型上，回填报告时按上表归类。

---

## 7. 成本估计

| 项 | 估算 | 说明 |
|---|---|---|
| 标注（4 类 × ≥5 组 × 4–8 张 ≈ 120 张 + 双人复核） | **2–3 人日** | 大头是"跨客户构图撞车"要翻两个拍摄；标注质量决定结论可信度 |
| 本评估物（脚本 + 工具 + 报告） | **已完成** | 纯工具/文档，不触产品行为 |
| 跑批 + 复跑（含 dHash 基线） | 0.5 人日 | 120 张 × 2 通道 ≈ 分钟级；O(n²) 有 `--limit-pairs` 保护 |
| A1 立项后的生产化（若通过） | **1.5–3 周（L）** | 复用 `SemanticIndex` 存储/余弦、`Face/VectorIndex` LSH、`SimilarityService` 分组；新增 embedding 通道 + 阈值档 + 回填 job + 复核 UI 接线；存储 4KB/张（20k ≈ 80MB） |
| A2（自训/CLIP） | **XL（>1 月）** | 新模型资产、标注规模升级、离线约束评审；默认不做 |

风险：模型体积/离线约束（`SFace.mlpackage` 已 37MB，再加图像 embedding 资产需评审）；跨会话合并不可做；Vision 系统版本差异导致向量不可比（`SemanticIndex` 已用 `model_version` + 维度校验兜底）。

---

## 8. 验收清单（Lead 执行）

1. `swift build --disable-sandbox`（gather-core）：新文件编译通过；
2. `swift run --package-path desktop/native/gather-core gather-triage-eval similarity-eval --self-test` → 打印 PASS、exit 0；
3. 旧 CLI 不回归：`gather-triage-eval --help` 仍是原用法（子命令仅在首参为 `similarity-eval` 时生效）；
4. 标注集齐后跑 §3.1 两条命令，产出 `/tmp/fp.json`、`/tmp/dhash.json`；
5. 把两张 JSON 的关键行回填到本报告"§0 结论 + §5 阈值建议"，并在 `docs/ROADMAP.md` §六 更新决策 A 状态（已评估/立项/不立项）。

未验证项（必须等真实数据）：
- 四类各自的 P/R 与过度合并率、聚类 ARI、embedding 相对 dHash 的 delta；
- `0.90–0.96` 候选区间里哪个值在"婚礼 + 家庭 + 校园"三类拍摄上稳定；
- Vision FeaturePrint 与自训 embedding 的差距（本报告只评估前者，后者需 A2）。

---

## 9. 附录：本次新增文件与自检

新增/修改（全部在 `GatherTriageEval` 工具 target 与 `scripts/`，无产品行为改动）：
- `desktop/native/gather-core/Sources/GatherTriageEval/SimilarityAnnotation.swift`：标注集 JSON/CSV 解码 + 校验 + 数据集指纹（sha256）；
- `.../SimilarityMetrics.swift`：pair 指标/阈值曲线/推荐点/聚类过度合并/ARI + `selfTest()`；
- `.../SimilarityVectors.swift`：FeaturePrint（1280 预览，复用 `ImageSemanticsExtractor`）与 dHash（复用 `computeVisualHashes` + 同 `pixels9x8` 算法）两条通道；
- `.../SimilarityEvalCommand.swift`：`similarity-eval` 子命令（参数解析、评估、markdown/JSON 渲染、自检入口）；
- `.../main.swift`：仅加"首参 = similarity-eval"的分派（旧 CLI 行为不变）；
- `scripts/sample-similarity-annotation.sh`：本地采样（mdls 拍摄时间 + gap 切组 + 确定性抽样 + JSON/CSV 脚手架）。

自检断言（`--self-test`）覆盖：pair 混淆矩阵与 P/R/F1/过度合并率、阈值曲线排序与推荐点选择（含不可达目标回退）、聚类 ARI/过度合并/漏合并、JSON+CSV 标注解码与非法输入报错、cosine/汉明/相似度换算。

已知近似与边界（重申）：1280 预览而非 RAW 全分辨率；无 EXIF 方向摆正的兜底解码；跨会话只评"误合并"；**采样脚本依赖 macOS `mdls`，EXIF 缺失时退回 mtime 且该组不得当 `burst` 真值**；真实数值待标注数据。
