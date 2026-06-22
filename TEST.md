# Gather 测试清单

---

## 环境准备

### 前置条件
- [ ] macOS 13+，Capture One 23/24/25 已安装
- [ ] Gather 已安装（或源码 `npm run dev` 启动，需先在根目录执行 `uv sync`）
- [ ] Python 3.10+ 可用，仓库根目录已执行 `uv sync`

### 测试素材
准备 30-50 张测试照片，放入 Capture One Catalog：

| 类别 | 数量 | 照片要求 | 测试目标 |
|------|------|----------|----------|
| 连拍照 | 6-10 张 | 同一场景连拍，构图高度相似 | 相似度分组 |
| 单人肖像 | 6-8 张 | 2-3 个不同人物，各 2-3 张 | 人脸聚类 |
| 多人合照 | 3-5 张 | 每张含 2-5 人 | 多脸检测 |
| 无关照片 | 10-15 张 | 风景、静物等无人脸照片 | 噪音处理 |

推荐目录结构：
```
~/Desktop/GatherTest/
├── burst/        # 连拍照
├── portraits/    # 单人人像
├── groups/       # 多人合照
└── misc/         # 杂项
```

### Capture One 设置
- [ ] 新建 Catalog → `~/Desktop/GatherTest/GatherTest.cocatalog`
- [ ] 导入上述所有测试照片
- [ ] 确认所有照片可正常查看

---

## 一、启动与进程管理

### 1.1 正常启动
- [ ] 终端执行 `npm run dev`（desktop 目录下，需先执行 `uv sync`）
- [ ] 终端输出 `[main]` 编译成功 + `[renderer]` Webpack 启动
- [ ] 自动弹出 **Electron 窗口**（非浏览器标签页）
- [ ] 窗口标题显示 "Gather"
- [ ] Dashboard 页面正常渲染，无白屏

### 1.2 启动异常处理
- [ ] **Python 缺失**：未安装 `uv sync` 时启动 → 窗口弹出错误提示（而非崩溃）
- [ ] **端口占用**：5173 端口被占用时 → Webpack Dev Server 报错，不静默回退

### 1.3 进程生命周期
- [ ] 关闭窗口 → Python 子进程同步退出，`ps aux | grep "engine.py"` 无残留
- [ ] 强制 `kill` Electron 主进程 → Python 子进程 5 秒内退出
- [ ] 重新打开（macOS Dock 图标点击）→ 窗口重建 + Python 重新 spawn，Dashboard 正常
- [ ] 快捷键 `Cmd+Q` 正常退出

---

## 二、Dashboard（首页）

### 2.1 页面渲染
- [ ] 页面标题显示 "Gather"
- [ ] "Import from Capture One" 与 "Import Files…" 按钮可见
- [ ] 顶部步骤导航（Dashboard → Similarity → Face KW）正常显示

### 2.2 Session 管理
- [ ] **创建（Capture One）**：C1 选中 ≥5 张图片 → 点击 "Import from Capture One" → session 卡片出现在列表中
- [ ] **创建（文件选择）**：点击 "Import Files…" → 选择多张图片 → session 卡片出现在列表中
- [ ] **删除**：点击卡片 Delete 按钮 → 确认弹窗 → 卡片消失
- [ ] **取消删除**：点击卡片 Delete 按钮 → 弹窗选 Cancel → 卡片保留

### 2.3 Capture One 导入
- [ ] C1 选中 ≥5 张图片 → Gather 点击 "Import from Capture One" → session 卡片显示正确照片数
- [ ] C1 不选任何图片 → 点击 Import → Toast 提示"未选中图片"
- [ ] 本地文件选择 ≥5 张图片 → Gather 点击 "Import Files…" → session 卡片显示正确照片数
- [ ] Import 过程中点击其他按钮 → 不会触发冲突
- [ ] 快捷键 `Cmd+Shift+I` 触发导入 → 功能等同于点击 "Import from Capture One"
- [ ] 导入完成后，session 卡片照片数实时更新

### 2.4 Session 列表
- [ ] 多个 session 按创建时间排序（最新在上）
- [ ] 每个卡片显示：名称、照片数、创建时间
- [ ] 点击卡片 → 跳转到对应功能页面

### 2.5 空状态
- [ ] 无 session 时 → 显示空状态提示 "No sessions yet"
- [ ] 导入引导文案清晰可见

---

## 三、相似度分组（Similarity）

### 3.1 页面导航与渲染
- [ ] Dashboard 点击 session 卡片 → 跳转到 Similarity 页面
- [ ] 页面顶部显示 session 名称
- [ ] "← Dashboard" 返回链接正常跳转

### 3.2 参数调节
- [ ] Threshold 滑块范围 4–20，拖动时数值实时更新
- [ ] Min Group Size 输入框可输入 2–10
- [ ] 滑块和输入框互不干扰

### 3.3 分析流程
- [ ] 点击 "Start Analysis" → 按钮变为 disabled → 进度条出现
- [ ] 进度条从 0% 平滑推进到 100%
- [ ] 分析期间进度文字更新（"Computing hashes" → "Clustering"）
- [ ] 完成后进度条消失，分组结果出现
- [ ] 按钮恢复可用

### 3.4 分组结果
- [ ] 每组一张卡片，显示缩略图 + 成员数
- [ ] 连拍照（burst）出现在同一组内
- [ ] 组数合理（非全量为 1 组，也非每个单独成组）
- [ ] 调整 Threshold → Recluster → 分组变化符合预期
- [ ] Threshold=4（严格）：组数变少，组内相似度高
- [ ] Threshold=18（宽松）：组数变多，组内相似度低

### 3.5 轮询机制
- [ ] 分析期间刷新页面 → 不会导致重复轮询
- [ ] 分析完成后 → 不再有 pending 轮询
- [ ] 切换到 Dashboard 再切回 → 结果正确保留或重新加载

### 3.6 写回
- [ ] 写回选项面板可见：createAlbums / addPrefix / markUngrouped / writeIPTC
- [ ] "Select All" 勾选时 → **所有**选项被选中（不是只选 createAlbums）
- [ ] 单独勾选/取消各选项 → 选框状态正确
- [ ] 点击 "Execute Writeback" → 二次确认弹窗
- [ ] 确认后 → 进度条推进 → 完成后显示 Written / Failed / Skipped 数量
- [ ] **C1 验证**：选中处理后图片 → Image → Load Metadata → Keywords 字段出现 Gather 写入的内容
- [ ] 失败记录有错误信息（如有）

---

## 四、人脸标注（Face KW）

### 4.1 页面导航与渲染
- [ ] Dashboard 点击 Face Keywording → 进入 5 步向导
- [ ] 顶部 5 步 stepper 完整显示：① Import ② Clusters ③ Bind ④ Preview ⑤ Writeback
- [ ] 页面标题显示 session 名称
- [ ] "← Dashboard" 返回链接正常跳转
- [ ] "Delete Session" 按钮 → 确认后删除并跳回 Dashboard

### 4.2 Step 1 — 导入分析
- [ ] 显示照片数 / 人脸数 / 聚类数统计（初始为 "-"）
- [ ] 点击 "Start Face Analysis" → 按钮禁用 → 进度条出现
- [ ] 进度条推进 → 进度文字描述阶段（"Detecting faces" → "Clustering" → ...）
- [ ] 完成后 → Step 1 stepper 标记为 ✅ done → "Next: Clusters" 按钮可用
- [ ] 统计数据更新为实际值

### 4.3 Step 2 — 簇浏览
- [ ] 人脸簇网格渲染，每人一个卡片（人脸缩略图 + 成员数 + 聚类 ID）
- [ ] 簇按成员数降序排列
- [ ] 提示文字 "Click to select & bind" 显示

**筛选**：
- [ ] All → 显示所有簇
- [ ] Unbound → 仅显示未绑定的簇
- [ ] Bound → 仅显示已绑定角色名的簇
- [ ] Skipped → 仅显示跳过的簇

**选中**：
- [ ] 点击人脸卡片 → 卡片添加 selected 样式（高亮边框/背景色变化）
- [ ] "Next: Bind" 按钮变为可用

**Merge**：
- [ ] 点击 "Merge Mode" → 按钮高亮，提示 "Merge: Select Source"
- [ ] 点击第一个卡片（source）→ 卡片显示选中标记 → "Merge" 按钮出现
- [ ] 点击第二个卡片（target）→ 确认 target 选中
- [ ] 点击 "Merge" → 两个簇合并 → 网格刷新 → toast 提示成功
- [ ] 再次点击 "Merge Mode" 退出合并模式

### 4.4 Step 3 — 角色绑定
- [ ] 选中的簇信息显示：人脸预览图 + 成员数
- [ ] 成员列表列出所有成员文件名
- [ ] 成员旁有 "Remove" 按钮

**绑定角色名与关键词**：
- [ ] Role Name 输入框可输入（如 "Alice"）
- [ ] Keywords：输入框输入关键词 + Enter → 标签出现
- [ ] 逗号（`,`）分隔关键词也生效
- [ ] 点击标签 × → 标签移除
- [ ] "Save & Next" → 绑定成功 toast → 自动跳下一个未绑定簇
- [ ] 空角色名 → 点击 Save → toast 提示 "Enter a role name"

**跳过**：
- [ ] 点击 "Skip" → 当前簇标记为 Skipped → 自动跳下一个
- [ ] Skipped 簇在 Step 2 筛选 "Skipped" 中可见

**移除成员**：
- [ ] 点击成员旁 "Remove" → 确认弹窗 → 成员从列表中消失
- [ ] 簇成员数更新

**导航**：
- [ ] "← Clusters" 按钮回到 Step 2
- [ ] "Preview →" 按钮进入 Step 4

### 4.5 Step 4 — 预览
- [ ] 顶部 stats 显示总照片数 / 有关键词数 / 无关键词数
- [ ] 表格每行：文件名 | 关键词标签 | 来源角色
- [ ] 同一照片被多个角色关联时 → 行显示多个来源角色标签
- [ ] "← Bind" 回到 Step 3
- [ ] "Write XMP Metadata" 按钮大号突出显示

### 4.6 Step 5 — 写回
- [ ] 点击 "Write XMP Metadata" → 进度条推进 → 完成
- [ ] 结果卡片显示：Written / Failed / Skipped 数量
- [ ] 引导提示出现：如何在 C1 中 Load Metadata
- [ ] 部分失败时 → toast 提示具体错误（不隐藏结果卡片）

**确认同步与清理**：
- [ ] 点击 "Confirm Sync & Cleanup" → 按钮变为 "Confirming…"
- [ ] 完成后 → 按钮变为 "Done"
- [ ] toast 提示 "Cleanup complete"

### 4.7 C1 交叉验证
- [ ] 选中处理后照片 → Image → Load Metadata
- [ ] Metadata 面板 `dc:subject` 字段包含绑定的人名和关键词
- [ ] 多角色照片 → 关键词合并正确

---

## 五、综合测试

### 5.1 多 Session 并发
- [ ] 同时创建 3 个 session，各自导入不同照片
- [ ] A session 运行相似度分析，B session 运行人脸分析
- [ ] 两个分析并行执行，不互相干扰

### 5.2 页面切换
- [ ] Dashboard → Similarity → Dashboard → Face KW → 页面状态各自保持
- [ ] 在两个不同 session 的 Face KW 页面间切换 → 页面内容对应各自的 session

### 5.3 错误处理
- [ ] 断网后启动 → Electron 窗口正常打开（不依赖网络）
- [ ] 损坏的图片文件 → 分析跳过损坏文件，其他正常分析
- [ ] 分析中强制关窗 → 重新打开 → 选择同一 session → 可重新开始
- [ ] 路径含中文/空格/特殊字符的图片 → 正常处理

### 5.4 性能
- [ ] 50 张照片导入 < 3 秒
- [ ] 相似度分析（50 张）< 30 秒
- [ ] 人脸检测（50 张，含人脸）< 2 分钟
- [ ] UI 分析期间保持响应（不卡死）
- [ ] 内存使用 < 1GB（50 张照片场景）

### 5.5 UI 体验
- [ ] 暗色主题全局一致
- [ ] Toast 通知出现 → 3 秒自动消失
- [ ] 按钮 hover / active / disabled 状态视觉反馈正确
- [ ] 进度条动画流畅
- [ ] 错误 toast 红色，成功 toast 绿色，警告 toast 黄色
- [ ] 窗口最小尺寸 480×360 布局正常
- [ ] 窗口全屏 → 布局自适应

### 5.6 快捷键
- [ ] `Cmd+Shift+I` — 触发 Capture One 导入
- [ ] `Cmd+R` — 刷新（开发模式）
- [ ] `Cmd+W` — 关闭窗口（macOS 标准行为：窗口关闭但进程保持）
- [ ] `Cmd+Q` — 退出应用（窗口关闭 + 进程退出）

---

## 六、回归测试清单

每次发布前执行（全量约需 15 分钟）：

- [ ] A1–A5：Dashboard 基础功能
- [ ] B1–B9：相似度分组完整流程
- [ ] C1–C14：人脸标注完整流程
- [ ] D1–D5：边界与异常

**关联 Issue / 修复验证**：

| Issue | 修复描述 | 验证项 |
|-------|----------|--------|
| #– | 写回选项修复 | B7：Select All 行为正确 |
| #– | 成员数计数修复 | C10：Remove 后成员数正确 |
| #– | 轮询竞态修复 | B4、C3：重复分析不重叠 |
| #– | RGBA 缩略图修复 | 含透明通道图片缩略图正常 |
| #– | 空选图片安全处理 | A3 |

---

## 附录

### 调试命令

```bash
# 查看 Python 进程
ps aux | grep engine.py

# 查看 Electron 日志
npm run dev 2>&1 | tee ~/Desktop/gather-debug.log

# 仅运行 Python 后端测试
cd /path/to/Gather && uv run pytest tests/ -v

# 类型检查
cd desktop && npm run typecheck
```

### 已知限制
- 最大消息 100MB，超大 Session（>10 万张照片）会超出
- 无自动保存：分析中断后需重新开始
