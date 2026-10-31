# V8 测试有效性 A/B 变体（2026-10-31）

每个变体：改一处源码 → 跑定向测试（应红）→ `git checkout` 还原 → 再跑（应绿）。

| # | 变体 | 应红测试 | 红结果 | 还原 |
|---|---|---|---|---|
| 1 | 多 IIM guard `<=1` → `<=99` | `multipleIIMResourcesFailClosed` | exit 1，“必须显式失败” issue | exit 0 |
| 2 | half 解码指数 `-15` → `-16` | `halfCodecMatchesNative` | exit 1，61,440 个位模式不一致 | exit 0 |
| 3 | IIM 编辑 `.replace` → `.keep` | `attributesRoundTrip` | exit 1，`XMP_WRITE_VERIFICATION_FAILED field=descriptive` | exit 0 |
| 4 | 删除 `captureone16` bundle id | `C1InstallationTests` | exit 1，`probeInstalled → false` | exit 0 |

结论：三条 P0/P1 行为测试都能判红；还原后全绿，未留下源码改动（`git status` 0 行）。

## 限制

- 这是定向变体，不是完整 mutation testing；保留期删除当前库、scan 拷贝改字节等变体尚未跑。
- 全量 `test.sh all` + 12 门禁 + CI 串行复跑仍属 V8 收口（D13）。
