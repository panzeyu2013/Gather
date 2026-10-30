# V1 夹具结论（2026-10-30）

- 生成器：`scripts/validation/fixtures.py`（Pillow 12.2；系统 sRGB ICC）。
- 矩阵：100 张，A-full 30 / B-iptc 20 / C-xmp 20 / D-unicode 10 / E-large 10 / F-bare 10；3.9 MB。
- 结构校验：`verify` PASS（段数/SHA256/scan SHA/EXIF/Pillow ICC/XMP XML 标题与关键词）。
- 独立回读：`scripts/validation/inspect_jpeg.swift`（ImageIO）抽查 A/B/C/D/E/F 各 1 张；A–D 的 caption/keywords/title 可读，F 无描述性元数据，E 只读到其中一段。
- **负向发现**：>64KB IIM 拆成两条 0x0404 不是可移植形态——ImageIO 只读一段，App 读首段；E 因此只作“显式/可解释、不静默丢”的负向样本，不作互操作基线，也不要求全量往返。
- 缺口：真实相机 JPEG、20 组 RAW+JPEG 仍需用户提供；生成夹具不含真实噪声/人脸。

证据：`manifest.json`、`SHA256SUMS`、`verify-summary.txt`、`imageio-probe.txt`。
