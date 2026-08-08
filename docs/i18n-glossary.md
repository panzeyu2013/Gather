# i18n 术语表 / i18n Glossary

> 状态：已冻结（P0）。问题四第 4.4.3 节"术语表先行"的产出。
> 所有后续页面级迁移（i18n P1）必须使用下表映射，不得为同一术语另起翻译；
> zh-CN / en 两语言文件术语必须与此表一致（验收标准：问题四第 7 节抽查）。

## 冻结术语

| 中文 | English | 约束说明 |
|------|---------|----------|
| 浏览 | Gallery | 照片浏览模块/页签 |
| 挑片 | Culling | 选片决策模块；动词形态用 "cull" |
| 写回 | Writeback | 元数据写回 Capture One |
| 冲突 | Conflict | XMP/元数据冲突；复数形态 "conflicts" 用 count 参数化 |
| 工作区 | Workspace | 会话级工作区（Control Center） |
| 索引 | Index | 后台文件索引；动词 "index"，进度态 "indexing" |
| 相似度 | Similarity | 相似照片分组 |
| 人脸 | Face | 人脸识别模块 |
| 重复 | Duplicate | 重复照片检测 |
| 导出 | Export | 导出模块；动词 "export" |
| 元数据 | Metadata | XMP 元数据 |

## Key 规范（对齐 4.4.1）

- 点分命名，按页面/域分组：`workspace.stage.imported`、`inbox.action.analyze`、`error.import.folderEmpty`。
- 文案含数字一律用 i18next `count` 参数（`culling.confirm.count` 等），禁止字符串拼接。
- 错误消息走错误码 + 渲染层映射，禁止主进程返回拼接文案。
- 新术语先补充本表，再在语言文件中落 key（冻结后再迁移）。
