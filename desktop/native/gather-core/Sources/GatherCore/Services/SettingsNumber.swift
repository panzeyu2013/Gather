// desktop/native/gather-core/Sources/GatherCore/Services/SettingsNumber.swift
// 设置表 → Int 的安全转换。
//
// 为什么需要：settings 表可以被用户/脚本直接改库，出现 NaN/inf/超大值是现实场景，
// 而 `Int(Double.infinity)` 在 Swift 里**直接 trap（进程崩溃）**，不是抛错——
// 一个手改的数值设置就能让分析/相似度/写回整条链路崩掉（对抗验证 V2 实测：
// `Int(getNumber("face_core_retry_min_samples"))` 遇 1e999 → SIGTRAP）。
//
// 语义：正常范围内与旧代码**逐位一致**（截断，`Int(1.9) == 1`）；非有限值回退到调用方
// 给的默认值；超出 Int 范围的有限值夹到边界（不 trap）。

public extension Double {
    /// 安全截断为 Int：NaN/inf → fallback；±∞ 之外的超大有限值 → Int 边界。
    func safeInt(fallback: Int = 0) -> Int {
        guard isFinite else { return fallback }
        if self >= Double(Int.max) { return Int.max }
        if self <= Double(Int.min) { return Int.min }
        return Int(self)
    }
}