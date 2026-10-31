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

## 静态风险（未实机）

- reload metadata 的 sdef direct-parameter 是 variant；App 的 reloadMetadataScript 传的是 current document。AppleScript 可能在运行时抛类型错误（-1700），也可能被 C1 宽松接受。未实机验证前不改脚本；若确认失败，应改为对 selected variants / every variant of current document 逐个 reload。
- 证据：reload-signature.txt。

## 未覆盖（需人工）

- Apple Events/TCC 授权与实际 `osascript` 执行；
- Gather 写回 → C1 自动 reload → 星级/关键词/色标可见；
- 裁剪叠层、无 C1 机器 0 次 osascript。

结论：**字典兼容性静态通过**，不能替代 V2 实机互操作。
