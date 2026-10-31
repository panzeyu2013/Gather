# V1 自动化预演结论（2026-10-31）

- 工具：`scripts/validation/run-v1-fixtures.sh` + `V1FixtureRoundTripTests.swift`（运行时临时复制进 GatherAppTests，跑完删除，不改变常驻测试目录）。
- 样本：`fixtures-matrix` 100 张（A-full 30 / B-iptc 20 / C-xmp 20 / D-unicode 10 / E-large 10 / F-bare 10）。
- 每个样本执行：写 rating/label/keywords/caption/copyright/title/city/triage → 读回 → 清空 → 再读。
- 结果：**100/100 通过**；所有写入/清空后 scan SHA 与写前相同；非 XMP/APP13 段逐字节不变；无 `.gather-embedded-*` 残留。
- 负向样本 E-large：修复前 10/10 “写成功”（只改首段、保留第二段，Bridge 会看到旧值）；修复后统一抛 `EMBEDDED_LAYOUT_UNSUPPORTED`，原片字节不变。
- 修复：`08bf00b`（多个 0x0404 IIM 时拒绝写回），回归用例在 `JPEGSegmentsTests`；test-catalog 收紧到 2481/11454。
- 限制：本预演直接调用 `EmbeddedJPEGSession`，不经过导入/DB/交付队列；Bridge/C1/真实 RAW 仍需 V1/V2 实机项。
