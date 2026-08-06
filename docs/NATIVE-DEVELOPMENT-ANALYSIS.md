# macOS 与 Windows 原生开发分析报告

> 版本：v1（2026-08-05）
> 目的：评估 Gather 在"保持/升级 Electron"之外的原生开发路径——macOS 原生、
> Windows 原生、跨平台框架，并结合当前仓库现状给出结论与分阶段建议。
> 配套文档：[ROADMAP.md](ROADMAP.md)。

---

## 一、现状盘点：哪些能力已经平台相关

| 能力 | 现状 | 平台耦合度 |
|---|---|---|
| 应用外壳 | Electron 3 进程（main/preload/renderer），React 18 + Vite | 跨平台，无分支 |
| RAW/图片解码 | sharp（libvips）为主，sips（macOS 系统工具）兜底 | **darwin-only**（`di/init.ts:94-105`） |
| 人脸推理 | ONNX Runtime；provider 层**已有 win32 分支**：`win32 → DirectML`（`face-kw/provider.ts:43-103`） | 已双平台就绪 |
| 检测执行提供方 | macOS 固定 CPU（SCRFD 双尺度输出在 CoreML 失败，`provider.ts:60-63`） | macOS 限制 |
| Capture One 集成 | `capture-one.ts` 走 **osascript/AppleScript**；`GatherLink.coplugin`（Swift，COOpenWithPlugin SDK v1.0.1） | **darwin-only** |
| 深链 | `gather://`（Electron `setAsDefaultProtocolClient` 语义，`index.ts:69` 起） | 需按平台注册 |
| 数据库 | better-sqlite3（原生模块） | 跨平台（需重编译） |
| XMP 写回 | fast-xml-parser（纯 JS） | 跨平台 |
| 文件监控 | Node `fs.watch`（`index.service.ts:170`） | 跨平台（Windows 上为 ReadDirectoryChangesW，目录级） |
| 打包 | electron-builder → `.dmg` | macOS 完成；Windows 需补 NSIS/msi 配置 |

**结论：代码已经为"Electron 内双平台"做了相当铺垫（provider 的 win32 分支、
decoder 组合根解耦），真正 macOS-only 的硬依赖只有三处：sips 兜底解码、AppleScript
桥、C1 插件（Swift）。**

---

## 二、macOS 原生开发路径

### 2.1 目标与动机

- 动机：Electron 内存占用（基准可见数百 MB RSS）、启动速度、长列表挑片的渲染
  性能、与 macOS 系统能力（Vision/Metal/QuickLook）的融合。
- 目标形态：Swift + SwiftUI 原生应用，或"Swift 内核 + 现有 Electron UI 壳"的混合。

### 2.2 关键系统能力（原生独占或显著优势）

| 能力 | 框架 | 与现状的对比 |
|---|---|---|
| 人脸检测/识别 | **Vision**（`VNDetectFaceRectanglesRequest`/`VNGenerateFaceEmbeddings`） | 免费、Metal 加速、无需 ONNX 模型下载；可直接替换 MediaPipe+ArcFace 管线 |
| 神经网络推理 | CoreML + ANE（`MLModel`） | 替代 onnxruntime-node 的 coreml EP；检测模型换固定尺度后可全链 CoreML |
| RAW 解码 | CoreImage + `CIDataProvider`/ImageIO | 系统级 RAW 支持，支持新机型快；替代 sharp 的 RAW 依赖（libraw） |
| 缩略图 | ImageIO `CGImageSourceCreateThumbnailAtIndex` | 内嵌预览秒级读取，替代双解码 |
| 文件同步 | `NSFileCoordinator` / FileProvider | 比 `fs.watch` 可靠，防丢事件（对应增量索引痛点） |
| UI | SwiftUI（iOS 同源）+ Metal 加速 | 挑片滚动流畅度上限高；但完整重写 UI 工作量大 |

### 2.3 成本与风险

1. **全量重写**：现有 28k+ 行 TS（主进程）+ React 全部重写，2-3 人年量级；
   IPC 契约、状态机、写回可靠性工程（outbox/冲突检测）全部要重做；
2. **模型资产**：Vision 无法复用当前 ONNX 模型与已产出的 embedding（需重跑历史分析）；
3. **C1 插件**：Swift 插件可保留（独立于外壳），深链继续可用；
4. **混合形态的现实选择**：Swift 仅替换"解码 + 人脸 + 聚类"热路径（做成 helper
   binary / XPC / NSExtension），Electron 保留 UI 与数据库——收益中等、成本可控。

**结论**：macOS 全原生是"重写"决策，仅当（a）商业模型验证成功且（b）Electron
性能成为用户流失主因时才值得立项；优先走"内核原生化"混合路线（见第四节）。

---

## 三、Windows 原生开发路径

### 3.1 目标与动机

- 动机：Capture One 的 Windows 用户群（商业棚拍、影楼）是 Gather 潜在的第二市场；
  Windows 原生可提供 DirectML GPU、WIC 解码、更低的资源占用。
- 目标形态：C++/WinUI 3 或 .NET 8（WPF/WinUI）原生应用。

### 3.2 关键系统能力

| 能力 | 框架 | 说明 |
|---|---|---|
| GPU 推理 | **DirectML**（ONNX Runtime EP 已支持） | 代码已预留 `win32 → dml` 分支，迁移成本低 |
| 图片解码 | **WIC**（Windows Imaging Component） | 需相机厂商/系统 RAW Codec；HEIF/HEIC 需 Microsoft Store HEIF 扩展（依赖用户安装，有部署成本） |
| 人脸检测 | `Windows.Media.FaceAnalysis.FaceDetector`（Win10+） | 速度一般、无 embedding；仅可作辅助，主推 ONNX DirectML |
| 深链 | `AppUserModelID` + URI scheme 注册（注册表 `HKCU\Software\Classes\gather`) | Electron 语义一致，注册表写法 |
| Capture One 集成 | C1 插件 API（COOpenWithPlugin 是 C1 官方插件类型，Windows 版 C1 同样支持）；**AppleScript 无对应物**，需用 COM/UIAutomation 或插件内嵌启动 Gather | 核心迁移点 |
| 文件监控 | ReadDirectoryChangesW（Node 已封装，目录级事件） | 需自己处理"目录事件→文件集合变更"的展开，丢事件风险更高，更需要周期对账 |
| 打包/分发 | MSIX / NSIS / Squirrel | electron-builder 已支持 |

### 3.3 成本与风险

1. **RAW 解码是最大坑**：Windows 没有系统级通用 RAW 解码（WIC 依赖厂商 codec），
   目前 sharp/libraw 路线反而是跨平台可靠的——原生化后仍需捆绑 libraw/WIC 双路径；
2. **C1 集成深度下降**：Windows 无 AppleScript 桥，"导入选中照片"只能靠插件
   （Send to Gather 已实现）与文件对话框，快捷键导入（Cmd+Shift+I 的 AppleScript
   路径）需要 UIAutomation 或干脆放弃；
3. **双平台 UI 维护**：WinUI 3 与 SwiftUI 是两套 UI 代码，长期双倍维护；
4. **开发人才**：Windows 原生（C++/WinRT）门槛与调试成本高于 Electron。

**结论**：Windows 原生**全量重写**性价比最低；"Electron 内支持 Windows"（sharp +
DirectML + 插件）的增量成本远低于原生重写，应作为 Windows 支持的默认路径。

---

## 四、跨平台框架选项对比

| 选项 | 解码 | 人脸推理 | DB | UI | 重写量 | 与现状差距 |
|---|---|---|---|---|---|---|
| **维持 Electron（推荐基线）** | sharp/sips→sharp | onnxruntime-node（DML 已预留） | better-sqlite3 | React 已建 | 零 | 性能受 V8/Chromium 上限约束 |
| **Tauri 2（Rust）** | image/libvips crate | ort + DirectML/CoreML | rusqlite | Web 前端复用 | 主进程全重写 | 包体/内存减半，Rust 生态成熟，IPC 需重构 |
| **Qt（digiKam 同路线）** | Qt ImageFormats + libraw | ONNX Runtime C++ | QSql | QML/Widgets 重写 | 全重写 | 成熟 DAM 基建，跨平台最稳，但 UI 与现代观感差距 |
| **Flutter desktop** | 第三方插件（弱） | TFLite/onnxruntime Dart | drift | Dart 重写 | 全重写 | RAW 生态弱，不推荐 |
| **Rust + egui/iced** | 同 Tauri | 同 Tauri | 同 Tauri | 自绘重写 | 全重写 | 体积最小但 UI 工期最长 |
| **Swift（macOS 全原生）** | ImageIO/CoreImage | Vision/CoreML | SQLite.swift | SwiftUI 重写 | 全重写 | 见 §2，macOS 体验上限最高，Windows 另起炉灶 |
| **C++/WinUI 3（Windows 全原生）** | WIC+libraw | DirectML | SQLite C API | WinUI 重写 | 全重写 | 见 §3，仅 Windows |

### 关键中间路线：内核原生化（混合）

- 把热路径（解码/哈希/embedding/聚类/人脸）下沉为单一 Rust 或 C++ 核心库
  （CLI/FFI 两种形态），外壳可同时服务于 Electron（现状）、Tauri（未来）、
  Swift（未来 macOS 壳）、WinUI（未来 Windows 壳）。
- 收益：性能可控 + 平台能力（CoreML/DirectML）由核心库统一暴露 + 将来外壳可换。
- 成本：性能审计报告中的 P0/P1 修复会先暴露核心库边界；分两步——先 Phase 0-2
  在 Electron 内修好，再按热路径逐个下沉，每步可独立发布。

---

## 五、结论与建议

1. **短期（0-6 个月）**：留在 Electron。性能审计的 P0/P1 问题与框架无关，先修；
   双平台铺垫已完成大半（provider win32 分支、decoder 组合根），顺手补 Windows
   打包配置与 sips 的 Windows 等价回退（sharp 已够用），即可获得"Windows 可用"。
2. **中期（6-18 个月）**：按 ROI 排序——(a) 内核原生化立项（Rust core，Electron
   外壳），同步推进 Windows 支持；(b) macOS 混合增强：Vision 人脸作为可切换
   provider（免费 GPU 检测，替代 ONNX 检测的 CPU 限制）；(c) C1 Windows 插件
   集成验证（COOpenWithPlugin SDK 是否支持 Windows 需要向 PhaseOne 确认）。
3. **长期（商业模式验证后）**：若原生体验成为差异化卖点，再评估 Swift 全原生
   （macOS 旗舰）或 Tauri 替换外壳；不建议同时做两套全原生 UI。
4. **不建议**：现阶段任何"全量原生重写"——性能报告证明瓶颈在算法与数据结构
   （O(n²)、全量扫描、全量序列化），不在框架；重写外壳不会解决 P0/P1，反而
   丢掉成熟的写回可靠性工程。
