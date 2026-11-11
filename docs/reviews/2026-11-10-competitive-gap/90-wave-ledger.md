# 修复台账：Wave 1（2026-11-11）

> 目标：`goal-eb78f289-3807-4129-bad0-74b03e45a5da`（推进 Wave 1–3）。
> 口径：本文件只记"已修/未修/证据/基线变更"，产品结论见 [00-synthesis.md](00-synthesis.md)，缺口明细见各分册。
> 验证纪律：**构建与测试只由 Lead 执行**（多 agent 各自编译会占满机器）；子代理只做静态实现与静态自查。

## 1. 本轮已修（Wave 1）

| 缺口 | 修复要点 | 关键文件 |
| --- | --- | --- |
| P0-1（30 册 G1） | C1 选中读取改为 application 级 `selected variants` + `parent image.path`；删除 `on error` 吞错，失败上浮 `C1_SCRIPT_FAILED`；`select` 用 document+variants 形式 | `gather-app/Sources/GatherHost/CaptureOneBridge.swift`、`gather-core/Sources/GatherProtocol/Protocol/C1.swift` |
| P0-2（G2） | `reload metadata` 改为按选中 variant 循环；无选中报 `C1_NO_SELECTED_PHOTOS`（不盲发、不写假 ack）；新增 `CullingAPI.acknowledgeManualReload` + 同步菜单「我已在 Capture One 手动加载元数据」 | 同上 + `API/CullingAPI.swift`、`Host/APIs/LiveCullingAPI.swift`、`GatherUI/Culling/CullingSyncControls.swift` |
| P0-4（20 册 #4） | 预取接线：±1 用与显示同键的 UI 缓存预热、±2 走 `preloadPreviews`、下一张 `prioritizeThumbnail`；`isLoading` 早退改单槽 pending commit + 忙碌角标 | `GatherUI/Culling/CullingViewModel+Preload.swift`、`CullingViewModel+Actions.swift`、`CullingWorkbench*.swift` |
| 20 册 #1/#2 | 专注模式（隐藏检查器+胶片条+窗口全屏，F / 菜单 / 按钮）；真 1:1 缩放（⌘1、⌘⌥0），⌘0 修正为"适配窗口" | `CullingView.swift`、`CullingWorkbenchViewer.swift`、`Interaction/CullingFocusModeActions.swift`、`GatherAppCommands.swift` |
| P0-8（05 册 §3.1） | `.heic/.heif/.psd` 进解码白名单 + CGImageSource 整图兜底（PSD 取合成扁平图），失败抛 `unsupportedExtension` 不崩 | `GatherAnalysis/Image/RAWDecoder.swift` |
| P0-5（40 册 #2） | 导出色彩空间（sRGB/P3/Adobe RGB）、DPI（JPEG/TIFF 元数据）、输出锐化（unsharp）；`ExportOptions`/`OutputRecipe` 可选字段（旧 JSON 兼容）+ 配方→导出的透传 | `Protocol/Export.swift`、`Protocol/Output.swift`、`ExportService+Run/Plan.swift`、`Output/OutputService.swift`、`ExportView+Options.swift` |
| 05 册 §1.3（堆栈） | 堆栈管理接线：新建/加入/移出/重命名/取消堆叠（右键菜单 + 选择栏），破坏性动作走 Confirmed | `GatherUI/Gallery/GalleryStackActions.swift`、`GalleryViewModel+Load.swift`、`GalleryGrid.swift` |
| 05 册 §1.4（卷重连） | 更正原判（能力早已由 `LiveLibraryDataProvider` 接线）；补 relink 结果可见性（N 个 / 0 个匹配） | `Library/LibraryViewModel+Load.swift`、`LibraryView.swift` |
| G9（30 册） | 元数据页「待 C1 重载」时给 reload + 手动 ack，复用挑片 VM 串行队列 | `GatherUI/Metadata/MetadataSyncBar.swift` |
| G10（30 册） | 同步菜单新增「在 Capture One 中显示」（区分 open -a 兜底"可能导入"语义） | `CullingSyncControls.swift`、`CullingViewModel+Writeback.swift` |

## 2. Lead 验证证据（2026-11-11）

- 构建：`gather-core` / `gather-app` `swift build --disable-sandbox` 均 Build complete（app 11.75s，无 warning；`check-warnings.sh` PASS）。
- 测试（只跑窄 filter）：
  - core：`--filter "RAWDecoderTests|ExportServiceTests|OutputServiceTests|ExportContractTests|OutputContractTests|ErrorCodeContractTests"` → **71 tests / 9 suites passed**。
  - app：`--filter "C1BridgeWave1|Culling|StackAndVolumeWiring|LocalizationParity|ErrorLocalizationCoverage|GalleryViewModel|LibraryViewModel|C1RoundTrip|APICulling|C1StatusCapsule|CullingSyncFlow"` → **244 tests / 29 suites passed**。
- 门禁：design-system PASS；cleanup-ratchet OK（未涨）；test-catalog OK(--strict)；layering OK；coded-errors OK；no-legacy OK；select-star OK；domain-events OK；domain-writes OK；duplicate-symbols OK；preview-surface PASS；warnings PASS。

## 3. 基线变更（必须有账）

| 基线 | 变更 | 原因 |
| --- | --- | --- |
| `docs/protocol-surface-baseline.json` | public_types 415 → **418**；public_declarations 2460 → **2475**；protocol_lines 12625 → 12759 | Wave 1 新增：`ExportColorSpace`/`ExportSharpening`、`CaptureOneBridgeError.noSelection`、`CullingAPI.acknowledgeManualReload`、`C1RoundTripError` 上移、若干字段成员。用 `--write-baseline --allow-growth` 写入。 |
| 其余基线 | 未变 | design-system / cleanup / test-catalog 均未上涨。 |

## 4. 遗留与真机门（未完成，别当成已验收）

1. **C1 真机矩阵未跑**：脚本契约按本机 `CaptureOne.sdef`（16.7.8.16）文本钉死，仍需真机验「选 10 张 → 导入 / 写回 → reload / 无选中 → C1_NO_SELECTED_PHOTOS / 手动 Load → ack → confirm+finalize」。见 30 册 §4.1 验收清单。
2. **专注模式/⌘⌥0**：未实机点验（全屏与 ESC 互操作、组合键是否被 AppKit 吞）。
3. **预取收益未实测**：链路已接线，但"按 → 到清晰图"的秒数未测（20 册遗留）。
4. **PSD 只支持合成扁平图**；HEIC 解码失败时保持占位符不崩。
5. **输出锐化是 CPU 盒式模糊近似**（确定性、可单测），>20MP 大图多一次全图缓冲。
6. **P0-3（C1 变体级读取）** 与 **P0-6（配方编辑器）** 拆到 Wave 1.5（task-11 / task-10）。
7. **P0-7（托管式客户交付）** 留在 Wave 3（task 待建）：需要设计签名链接/口令/到期，属 L。

## 5. 下一批（已排）

- task-10：交付配方编辑器（依赖本轮 OutputRecipe 新字段）。
- task-11：C1 变体级读取（rating/色标/pick/关键词 → 导入即带判断）。
- task-12：对比多格清晰 + 3 图/Survey + 直方图/合焦键位。
- task-13：关键词库/变量/批量直改/检索覆盖。
- task-14：AI 初审接入导入 + 场景标签闭环。
- task-15：集合层级 + 集合运算 + 跨会话导入去重。
- task-16：导出/交付规格补齐（图片水印/子目录/联系表参数）。
