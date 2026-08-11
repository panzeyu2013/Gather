# Gather 测试与验收清单

本清单针对当前 macOS 原生 Swift/SwiftUI 版本。自动化测试验证代码和服务链路；
真实照片的人脸质量、签名/公证安装和商业信号不在本轮重构验收范围。

## 一、环境准备

- [ ] macOS 14+，安装 Xcode 或 Swift 5.9+ 工具链
- [ ] 工作区位于可写磁盘目录
- [ ] 如验证 Capture One 联动，再安装兼容版本的 Capture One
- [ ] 如验证真实人脸结果，另备真实素材和模型；结果质量仅作外部实验，不作为本轮
      重构通过条件

不需要 Node.js、npm、Electron、浏览器端口或 Python 运行时。

## 二、自动化门禁

在仓库根目录执行：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-core

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-app

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  ./desktop/native/build.sh
```

验收记录至少包含：

- gather-core 测试总数、套件数和失败数；
- gather-app 测试总数、套件数和失败数；
- `.app` 是否成功组装及可执行文件是否存在；
- fixture-dependent skip、环境限制和未执行的外部验收项。

## 三、应用启动与导航

- [ ] `dist/native/Gather.app` 可启动，主窗口显示 Dashboard
- [ ] Dashboard、Library、Gallery、Similarity、Persons 页面可互相导航
- [ ] Jobs、Settings、Control Center 可从原生菜单/页面打开
- [ ] session 页面切换不会串用其他 session 的数据
- [ ] 关闭窗口和 `Cmd+Q` 遵循 macOS 应用生命周期
- [ ] 应用启动不依赖本地 HTTP 服务或浏览器渲染层

## 四、工作区与图库

- [ ] 选择本地文件夹后创建 session
- [ ] 导入后 session 立即出现，并自动提交 `metadata.scan`
- [ ] 任务中心展示扫描进度、完成状态、失败信息和重试入口
- [ ] 导入路径含中文、空格和特殊字符时仍能建立资产记录
- [ ] Library 能分页加载照片并显示缩略图、星级和色标
- [ ] Gallery 能查看照片详情、执行保留/淘汰、星级和色标操作
- [ ] 撤销/重做后 UI 状态和持久化状态一致
- [ ] 空 session、空图库和无结果筛选有明确空状态

## 五、相似度、重复与挑片

- [ ] Similarity 页面能启动和取消分析任务
- [ ] 分析完成后显示分组、成员数和代表缩略图
- [ ] 阈值、最小组大小和分组模式修改后结果状态一致
- [ ] Duplicates 页面区分精确重复和视觉重复
- [ ] 破坏性重复处理需要确认，并能在失败时报告原因
- [ ] Culling 页面能保存挑片结果并触发元数据同步
- [ ] 同一 session 重复提交分析不会产生不可控的重复任务

## 六、人脸关键词与人物

本节只验收代码链路、状态管理和写回安全，不评价真实人脸推理质量。

- [ ] Face Keywording 页面能显示分析任务状态、簇和审核状态
- [ ] Persons 页面能创建/编辑人物并绑定到审核结果
- [ ] 可预览待写回关键词，确认后进入 metadata outbox
- [ ] 写回失败显示可诊断错误，并可重试
- [ ] 应用重启后未完成 outbox 事务仍可恢复
- [ ] 无脸、损坏图片和缺少可选模型时有明确错误/跳过状态

## 七、导出、任务和元数据

- [ ] Export 页面能配置输出目录、格式、质量和命名
- [ ] 导出任务显示进度，支持取消、失败报告和重试
- [ ] JPEG/TIFF 转换、XMP 复制和目录创建失败时不会静默成功
- [ ] 导出目标不能覆盖未授权的源资产
- [ ] Jobs 页面能区分 pending、running、completed、failed 和 cancelled
- [ ] 重启应用后可恢复可恢复任务，不重复写入已完成结果
- [ ] XMP 写回支持 outbox 重试、冲突提示和清理

## 八、错误、安全与数据保护

- [ ] 未知原生命令返回结构化错误
- [ ] 缺少 session、photo 或任务记录时不崩溃
- [ ] 无效路径、权限不足和磁盘空间不足均有可诊断提示
- [ ] 写回、删除、移动和覆盖操作均有明确确认边界
- [ ] 资产路径来自数据库授权记录，不接受 UI 任意路径直接执行破坏性操作
- [ ] SQLite 迁移失败时保留错误信息，不删除用户照片或 XMP
- [ ] 并发任务之间不共享错误的 session 状态

## 九、原生边界残留扫描

```bash
test "$(rg --files desktop/src packages/shared tests scripts | wc -l | tr -d ' ')" = 0
! rg -n '^(import (WebKit|JavaScriptCore)|.*WKWebView|.*WebViewHost|.*WebBridge)' \
  desktop/native --glob '*.swift'
! test -e package.json
! test -e package-lock.json
! test -e desktop/package.json
```

扫描应以当前工作树为准；未暂存的删除仍会被 `git ls-files` 列出，不能据此判断
文件仍然存在。

## 十、回归与发布边界

每次提交至少重跑“自动化门禁”和“原生边界残留扫描”。发生数据层、任务层、元数据
写回或导出改动时，再执行对应的第六至第八节手工检查。

本轮明确跳过：

- 真实照片上的人脸检测/嵌入质量与模型效果；
- Apple 签名、公证、安装包、升级和卸载验证；
- 商业信号、真实材料性能和大规模生产数据基准；
- 可选遥测、发布运营和市场反馈。

这些项目仍可作为后续发布阶段的独立验收门，但不能阻塞本轮代码重构验收。

## 附：本轮已验证结果

2026-08-11 在当前工作树已验证：

- gather-core：760 个测试、98 个套件通过；其中
  `VectorIndexReconciliationTests` 因现有 fixture 条件按测试自身规则跳过；
- gather-app：78 个测试、7 个套件通过；
- `desktop/native/build.sh` 成功组装 `dist/native/Gather.app`；
- `desktop/src`、`packages/shared`、`tests`、`scripts` 当前无工作树文件，原生代码无
  WebKit/JavaScriptCore/WKWebView/WebViewHost/WebBridge 引用；
- `.app` 保持未签名，符合本轮明确排除的发布边界。
