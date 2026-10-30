# 合并后评审记录：interaction → main（2026-10-30）

> 范围：把 `interaction` 分支（`148f62cb`，交互与样式整改）合入 `main`（`72b9188a`）后的全量只读评审。
> 合并提交 `a9a34e31`；冲突仅 `docs/DEVELOPMENT.md`、`docs/README.md`、`docs/ROADMAP.md`，均采 main 收敛版正文。
> 评审方式：6 路只读 subagent 分面（交互状态机 / 相似度与缓存 / 设计系统与可访问性 / Shell 生命周期 / 合并与文档 / 测试与门禁），
> 主 agent 独占构建、测试与门禁并逐条核实修复。

## 评审结论

合并本身是干净的并集（55 文件与 interaction 侧逐项相等，main 侧 220 文件零丢失）。交互整改的主线
（commit 串行化、就地刷新、相似度回页保留、缩略图失效、去工具感样式）方向成立，但第一版实现存在
4 个 P1：三连击仍并发提交、就地刷新不推进取页代数、缩略图失效不重启在屏视图、挑片失败横幅可关掉唯一
重试出口；另有若干 P2（状态口径、可访问性、测试与门禁缺口）。均已在合并后修复。

## 发现与处置

| 编号 | 级别 | 问题 | 处置 |
| --- | --- | --- | --- |
| R1-F1 | P1 | `commit` 先 await 前驱再登记，第三拍与第二拍同时续行 | 先快照前驱再登记链；新增三连击回归测试 |
| R1-F2 | P1 | 网格/检查器色标提交默认自动前进，与查看器「6–9 不前进」相反 | 三处统一 `shouldAdvance: false`；网格补裸 6–9 |
| R1-F3 | P1 | `refreshOnEvent` 只 cancel 不推进 `fetchGeneration`，旧游标页可 append 回来 | 刷新自增代数；新增代数回归测试 |
| R2-F2 | P1 | 回页保留只比 group id，成员/参数变化时旧预览与 token 残留 | 改比分组内容 + 写回参数 |
| R2-F3 | P1 | `invalidateAll` 不改变 key，在屏单元格不重解、在途解码写回旧图 | 缓存代进 key，失效即换键 |
| R3-F1 | P1 | Toast 的 VoiceOver 公告未带 userInfo，实际不朗读 | 改 `NSAccessibility.post(element: NSApp, userInfo: [.announcement, .priority])` |
| R3-F2 | P1 | 清理后胶囊「已同步」与信息条「尚未写回」同屏矛盾 | 信息条按 `reloadAcked` 与胶囊同口径，无记录用中性点 |
| R4-1 | P1 | 挑片首载失败点横幅「×」后错误被清 → 永久「正在载入…」且无重试 | 仅 `page != nil` 时允许关闭横幅 |
| R2-F6 | P2 | 回页 load() 无条件用主结果覆盖当前结果，View 又清展开态 | 已有结果不再覆盖；展开态只在分组集合变化时重置 |
| R2-F7 | P2 | 全局图库/相似度/重复/人脸刷新不清缩略图 | 四个手动刷新入口补 `invalidateAll()` |
| R3-F3/F4/F5 | P2 | 折叠分区用 `isSelected` 表达展开、关闭按钮无标签、空态注释与实现不符 | 改 `accessibilityValue/Hint`、隐藏 chevron、补关闭标签与 `.isHeader`、同步文档 |
| R4-5/6/7 | P2 | 工作台无 Return 打开、重置确认移走 Return 后键盘不可达、错误 Toast 5s 消失 | List 加 Return；改 ⌘↩；错误 Toast 15s + 堆叠上限 3 |
| R5 | P1/P2 | 审计文档仍写 13 门禁/check-docs、失效路径与越界行号、两处 EOF 空行 | 加合并后校正块、修路径、去空行、同步计数 |
| R6 | P1/P2 | 新行为 0 回归测试；@Suite ratchet 正则漏计；clean 脚本会删模型目录 | 补 9 个用例；修正则并收紧 2,264/249/10,509；排除 `gather-models-*` |

## 验证矩阵（合并后工作树，2026-10-30）

| 项 | 结果 |
| --- | --- |
| `./scripts/test.sh core` | 1,434（并行主批）+ 25（串行状态批）= **1,459 tests / 217 suites**，exit 0 |
| `./scripts/test.sh app` | **805 tests / 91 suites**，exit 0 |
| 12 个 `check-*.sh`（strict 可用者带 `--strict`，含 `check-warnings`） | **12/12 PASS** |
| `git diff --check` | 干净 |

## 已知残余（未在本次修复）

1. **相似度写回面板的报告与同步入口仍与草案绑定**：写回后改关键词/点分组会清掉报告（TS 同语义），
   「确认同步/清理」入口随之消失；彻底解耦需要同步态独立数据源，属后续产品决定。
2. **C1 状态胶囊只统计 culling 模块**：相似度写回后仍显示「尚未写回」；需要 session 级交付汇总 API（协议面变更）。
3. **焦点交接**：关键词输入后不自动把焦点还给查看器；工作台双击与 List 多选的竞争、页签交叉淡入是否连 chrome 一起淡，
   均需实机确认（本环境不能跑 GUI）。
4. **Toast 悬停暂停/去重**、**test.sh 按 mtime 清理可能误删并发进程临时目录**（已排除 `gather-models-*`），留待下一轮。
5. 真实照片/人脸质量、签名公证、GUI 观感不属于本记录能证明的范围。
