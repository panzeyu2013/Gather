# Gather — Capture One 智能照片组织工具

基于视觉相似度分组和人脸关键词标注，帮助摄影师高效整理 Capture One 照片集。

---

## 功能

### 挑片工作台
- 无需先运行相似度分析，即可挑选工作区内全部照片
- Pick / Reject、0～5 星和 Capture One 英文颜色标签彼此独立
- 支持自动前进、筛选/相似组范围、批量操作和撤销/重做
- 支持单图、双图、四图对比，同步缩放和平移，并可按已有检测结果对齐人脸
- 星级和颜色先可靠保存到 SQLite，再由可恢复队列合并写入 XMP；失败可重试，同字段外部修改会停止覆盖

### 相似度分组
- dHash 感知哈希 + 层次聚类，发现视觉相似的图片
- 可调阈值（4–20）+ 最少成组数量，实时更新分组结果
- 按组执行 XMP 写回（关键词、文件名前缀、相册标记）

### 人脸关键词标注
- MediaPipe 人脸检测 → 特征编码 → DBSCAN 聚类
- 5 步向导：导入分析 → 簇浏览 → 角色绑定 → 预览 → 写回
- 支持人脸簇合并、成员移除、角色绑定/跳过
- 写回 `dc:subject` XMP 关键词，完成后可确认同步 + 清理

### 原生桌面体验
- 独立 Electron 窗口，无需浏览器
- 从 Capture One 直接导入选中照片（AppleScript 桥接）
- 暗色主题、Toast 通知、步骤导航

---

## 安装

### 下载安装

当前版本的人脸分析使用 Electron 主进程内的 ONNX Runtime，不需要单独的
Python 运行时。

### 从源码构建

```bash
npm install
npm run build
npm run electron
```

如需打包 macOS 安装包，执行
`npm run dist:mac --workspace=desktop`，产物位于 `desktop/release/`。

---

## 使用

### 挑片
1. 从文件夹或 Capture One 选中项创建工作区。
2. 打开“挑片”；相似度分析不是前置条件。
3. 使用 `P` 保留、`X` 淘汰、`0`～`5` 设置星级、方向键前后切换，
   `Cmd/Ctrl+Z` 撤销；需要连续挑片时开启“自动前进”。
4. 使用双图/四图检查连拍照片；“人脸对齐”直接复用已有的人脸检测框，不会重新运行模型。
5. 星级和颜色会在后台合并写入 sidecar；如需立即完成，点击“立即写入 XMP”，并先处理失败或冲突项。
6. 在 Capture One 中执行“图像 → 加载元数据”（或设置单向 Auto Sync =
   Load）。确认 Capture One 已读取后，再回到 Gather 确认同步并按需恢复/移除临时 XMP。

### 相似度分组
1. 在 Capture One 中选中照片
2. 打开 Gather，点击 **Import from Capture One** 或 `Cmd+Shift+I`
3. 进入 **Similarity** 页面，点击 **Start Similarity Analysis**
4. 调整阈值和最少成组数量，确认分组
5. 勾选写回选项，点击 **Execute Writeback**

### 人脸关键词标注
1. 导入照片（同上）
2. 进入 **Face KW**，点击 **Start Face Analysis**
3. 在人脸簇网格中浏览、筛选（All / Unbound / Bound / Skipped）
4. 选中簇 → 绑定角色名和关键词（Enter/逗号添加）
5. 预览所有照片的关键词分配
6. 执行写回，按提示在 Capture One 中 **Load Metadata**
7. 返回 Gather，点击 **Confirm Sync**

---

## 技术架构

```
Electron Desktop App
  ├── Main Process (SQLite / ONNX Runtime / XMP / Image Pipeline)
  ├── Preload (contextBridge, 安全隔离)
  └── Renderer (React 18 + Vite)
```

- 通信：类型化 `gather:command` IPC（零 HTTP、零端口）
- 安全：`contextIsolation: true`，`sandbox: true`，`nodeIntegration: false`
- 打包：electron-builder → `.dmg`（macOS）

---

## 开发

```bash
npm install
npm run dev          # 启动开发模式
npm run build        # 构建共享契约与桌面应用
npm run typecheck    # TypeScript 类型检查
npm run lint         # ESLint
npm run test:vitest  # 单元测试
npm run test:e2e     # 正式构建 Electron 冒烟流程
npm run electron     # 构建并启动本地正式应用
```

人脸标注端到端测试需要 ONNX 模型与含人脸的 RAW 照片（两者不可入库）。
先运行 `node scripts/setup-local-face-fixtures.mjs` 软链接模型，再向
`tests/fixtures/local/raw/` 放入（或软链接）2+ 张含人脸的 RAW，之后
`npm run test:e2e` 会自动执行该测试，否则自动跳过。
详见 [tests/fixtures/local-fixtures.md](../tests/fixtures/local-fixtures.md)。

相关文档：[DEVELOPMENT.md](DEVELOPMENT.md) | [TEST.md](TEST.md)

---

## 许可证

MIT License — 详见 [LICENSE](LICENSE)
