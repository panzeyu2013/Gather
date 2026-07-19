# Gather — Capture One 智能照片组织工具

基于视觉相似度分组和人脸关键词标注，帮助摄影师高效整理 Capture One 照片集。

---

## 功能

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

当前仓库支持将 Python 解释器和依赖一并打包进应用包（通过 `bundle-python.sh`）。
如果你直接使用源码或自行构建，请先准备本地 Python 环境并执行 `uv sync`。

### 从源码构建

```bash
uv sync
cd desktop
npm install
npm run dist:mac
```

构建产物在 `desktop/release/` 目录。打包产物内嵌 Python venv，用户无需手动安装 Python 依赖。

---

## 使用

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
  ├── Main Process (Node.js)
  │   ├── Python Bridge (子进程 stdin/stdout, MessagePack)
  │   └── Capture One Bridge (osascript)
  ├── Preload (contextBridge, 安全隔离)
  └── Renderer (Chromium SPA, 直载本地 HTML)

Python Engine (子进程)
  ├── FaceKeywordingService  (MediaPipe / DBSCAN / lxml XMP)
  ├── SimilarityService      (dHash / 层次聚类)
  └── SessionManager         (SQLite WAL)
```

- 通信：长度前缀 MessagePack over stdin/stdout（零 HTTP、零端口、零 CSRF）
- 安全：`contextIsolation: true`，`sandbox: true`，`nodeIntegration: false`
- 打包：electron-builder → `.dmg`（macOS）

---

## 开发

```bash
uv sync             # 在仓库根目录安装 Python 依赖
cd desktop
npm install         # 安装 Node 依赖
npm run dev         # 启动开发模式（热重载）
npm run typecheck   # TypeScript 类型检查
npm run dist:mac    # 构建 macOS .dmg
```

相关文档：[DEVELOPER.md](DEVELOPER.md) | [TEST.md](TEST.md)

---

## 许可证

MIT License — 详见 [LICENSE](LICENSE)
