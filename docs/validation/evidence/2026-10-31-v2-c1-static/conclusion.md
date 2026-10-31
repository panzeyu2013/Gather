# V2 C1 静态冒烟（2026-10-31）

- C1：**16.7.8.16**（`com.phaseone.captureone`）。
- 用 `sdef` 读安装版 AppleScript 字典（不执行脚本、不触发 TCC），确认 Gather 脚本依赖的
  对象/命令都在：
  - `current document` 属性；
  - `selected variants` 属性（字典标注 deprecated/hidden，但存在）；
  - `reload metadata` 命令；
  - `select` 命令；
  - variant 的 `path` 属性。
- 插件：`GatherLink.coplugin` 嵌入 release app，二进制 `x86_64 arm64`。
- 证据：`versions.txt`、`sdef-matches.txt`（原始 XML 在 `.build/validation/logs/v2-c1-sdef.xml`）。

## 未覆盖（需人工）

- Apple Events/TCC 授权与实际 `osascript` 执行；
- Gather 写回 → C1 自动 reload → 星级/关键词/色标可见；
- 裁剪叠层、无 C1 机器 0 次 osascript。

结论：**字典兼容性静态通过**，不能替代 V2 实机互操作。
