# 9-30 原生版审查（B1–B7）修复台账

> 来源：外部审查报告（2026-09-30，当前工作树、隔离 bundle/DB/照片副本）。
> 本轮不引用旧台账与旧截图作为证据；每条修复给出实现位置与回归。

## 已修

| 编号 | 问题 | 修复 | 回归 |
| --- | --- | --- | --- |
| **B1** | 相似度「返回」跳错页（工作台 → 控制中心 → 浏览 → 相似度 → 返回 落到工作台） | 新增 `previousDestination`（**完整** Destination，含 sessionId 与页签）与通用 `goBack`：返回优先精确恢复上一个页面，没有记录才退回粗粒度来源；相似度/图库/会话页共用同一条返回路径 | `backFromSimilarityReturnsToGallery`（浏览→相似度→回浏览；控制中心→相似度→回控制中心）、`sessionBackLeavesSessionRegion`（同会话页签切换不改变返回目标 = E-P0 语义）、`crossSessionBackReturnsToPreviousSessionPage` |
| **B2** | 离开图库后 `workspace.status` 轮询仍在跑（条件构建销毁 ≠ `isActive` 变化） | `GalleryView` 加 `.onDisappear { stopIndexStatusPolling() }`；RootView 离开 `.gallery` 目的地时显式停止同一个 VM 的轮询（双保险） | 结构性（两条路径都停） |
| **B3** | 慢的手动预览可覆盖更新的自动预览（且不更新 `plannedSignature`） | `previewExport` 与 `refreshPlan` 统一：**参数快照 + 请求序号（planGeneration）+ 返回后双重校验**，过期响应整份丢弃；发布时间时登记 `plannedSignature` | `manualPreviewPublishesSignature`（手动预览必须登记指纹） |
| **B4** | 人物被其它窗口删除后详情栏仍显示已删除人物（拿失效 ID 可发命令） | `PersonsViewModel.load()` 收敛选择：选中项仍在则保留；否则选第一个；列表为空则清空 | `reloadClearsSelectionForDeletedPerson`、`reloadKeepsExistingSelection` |
| **B5** | 缩略图过期判定比较的是**旧 self 快照**（值类型捕获），晚返回的旧图会覆盖新图；`Task.detached` 不继承取消 | 两个缩略图视图各加共享 `@State activeLoadKey`：`.task(id:)` 启动时写入当前键，解码返回后与该**共享**键比较并检查 `Task.isCancelled`；缓存命中路径同样校验 | 结构性（等待真机双色图快速切换复验） |
| **B6** | `check-command-surface.sh` 在 `LC_ALL=C.UTF-8` 下 unbound variable（变量紧接全角括号）；CI 未运行该门禁 | 变量加 `${}` 花括号；脚本显式 `export LC_ALL=en_US.UTF-8`；CI 的 boundary job 增加 Command surface scan 步骤 | 手动验证 `LC_ALL=C.UTF-8` 与 `LC_ALL=C` 两种 locale 均 exit 0 |
| **B7** | 草稿缓存不是真 LRU（命中不刷新顺序） | 四个 getter 命中时也 `noteAccess`；淘汰时跳过**当前活动工作区** | 结构性（A–H → 重访 A → 新建 I 时淘汰 B） |

## 查看器细节解码（用户实测问题，本批修复）

### 1. 问题确认

审片台与灯箱的解码尺寸原先**写死**（`2560` / `2048`），放大只对同一张位图做 `scaleEffect`——
放到 4×/8× 等于在 Retina 上把 2560px 拉到 5000+ 设备像素，细节全靠插值。
证据：`Culling/CullingView.swift`（原 `size: 2560`）、`Gallery/GalleryView.swift`（原 `size: 2048`）；
`PhotoThumbnailDecoder.decode` → `RAWDecoder.getPreview(maxDimension:)` →
`CGImageSourceCreateThumbnailAtIndex(kCGImageSourceThumbnailMaxPixelSize:)`。

### 2. 修复：只解码可见区域（tiled detail）

**core**：`RAWDecoder.decodeRegion(path:normalizedRect:maxPixel:quality:)`
（`desktop/native/gather-core/Sources/GatherCore/Image/RAWDecoder.swift`）：
- 图像源：RAW 走 `CIRAWFilter(imageURL:)`，其它格式走 `CIImage(contentsOf:options:[.applyOrientationProperty: true])`；
- 归一化矩形（左上原点）→ CIImage 像素矩形（翻转 y）→ 求交钳制 → `cropped(to:)`；
- 只渲染这一块：`CIContext.createCGImage(output, from:)`，输出尺寸按 `maxPixel` **只缩不放**；
- 返回 `RAWRegionDecodeResult`（区域 JPEG + 区域像素 + 整图像素）；共享 `CIContext` 复用 GPU 管线；
- 整条路径受 `#if canImport(CoreImage)` 保护（Linux 构建不受影响）。

**app**：
- `PhotoViewerGeometry.detailTile(...)`：与渲染**同一套坐标模型**（fit 居中 + scaleEffect 绕中心 + offset）算出
  「真正可见的图像归一化矩形」与「它在视图里的落位」，含 12% 余量（平移时不至于立刻重解）；
  `tilePixelSize(viewRect:budgetDimension:)` 按视图矩形 × Retina 缩放取目标像素并量化到 256（提高缓存复用）。
- `PhotoDetailTileView`：只解这一块；未就绪/失败渲染 `Color.clear`（**绝不遮挡**底层图）；
  缓存键 = 路径 + 量化矩形 + 目标像素，复用 `PhotoThumbnailCache`（按 RGBA 计费、512MB 上限）。
- 审片台与灯箱：底层整图保持**基准档**（2560，负责构图/手势/立即显示），细节层叠加在上面；
  缩放或平移停止 150ms 后重算可见矩形（去抖，拖动过程不排重解码队列）；
  `resetTransform` 清掉细节层；区域解码不可用时回调退回整图高档位（`PhotoDetailTier.target` 保留为兜底）。
- 对比模式：预算按可见格数收窄（1 格 8192 / 2 格 5120 / ≥3 格 4096）。

### 3. 回归

| 用例 | 断言 |
| --- | --- |
| `regionDecodeRendersOnlyVisibleArea`（core） | 4000×3000 四象限图只解右上 1/4：输出 ≤512px（而非 4000）、整图尺寸仍报 4000×3000、中心像素是**绿**象限 |
| `regionDecodeClampsAndHandlesInvalidInput`（core） | 越界矩形被钳制、不支持的扩展名抛明确错误码 |
| `detailTileInactiveWhenZoomedOut` | 1.2× 时返回 nil（底层位图够用，不解码细节层） |
| `detailTileCoversVisibleArea` | 4× 时可见区域 <40%、归一化矩形在 [0,1] 内、落位**覆盖**整个视图且余量有界 |
| `detailTileFollowsPan` | 平移改变可见区域（向右拖图 → 视口看到更靠左的图像区域） |
| `detailTilePixelBudget` | 目标像素量化到 256、不突破调用方预算 |
| `detailTierGrowsWithZoom` / `detailTierClamps` / `detailTierIsDiscrete` | 整图兜底档位：单调、不超采样、离散、对比模式受限 |

验证：gather-core **961 tests / 134 suites**（+2）；gather-app **286 tests / 29 suites**（+4）；
门禁 check-no-legacy 与 check-command-surface（C 与 C.UTF-8 两种 locale）均通过。

剩一步（真机）：连续缩放/平移下的解码排队与视觉衔接需要真机确认（本环境无法驱动 GUI）。
## 未修（需要产品口径 / 真机）

- **外观与信息层级**（报告第 3 节 2–4 条）：浏览检查器默认收起/合并、控制中心阶段条压缩为 48–64pt 摘要并把待办前置、相似度参数区限宽 560–680pt、术语统一（浏览/图库、人物/人脸/角色）——这些是设计取舍，需要与产品确认优先级后单独一轮做，避免与功能修复混在同一批。
- **显式「显示/隐藏检查器」按钮**：报告指出 AX 树中未见开关，而现有注释假设系统自动提供。需要在真机确认 SwiftUI `.inspector` 的实际按钮暴露情况；若确实缺失，再补一个带可访问标签与快捷键的显式按钮。
- **A10/A11（上一轮遗留）**：离线计数（行级）与列表（资产首选行）、冲突计数（outbox 行）与筛选（首选变体 filepath）粒度不同，需产品决定按行还是按资产。
- **真机验收**：860×560 / 1180×780、侧栏最大宽度、检查器同时打开、中英切换、浅深色、增强对比度、降低透明度、Tab 顺序与 VoiceOver（报告明确未完成）。

## 验证

- gather-app：**279 tests / 29 suites 通过**（本轮 +6：B1×3、B3×1、B4×2）。
- gather-core：959 tests / 134 suites（唯一失败为沙箱禁止写 home 的波浪号用例，环境性）。
- 门禁：check-no-legacy 通过；check-command-surface 在 C 与 C.UTF-8 两种 locale 下均通过（并已接入 CI）。
