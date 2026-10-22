// desktop/native/gather-core/Tests/GatherCoreTests/Services/SettingsNumberTests.swift
// `Double.safeInt(fallback:)`：设置表被手改成 NaN/inf 时不得让进程崩溃。
// 依据：Swift 的 `Int(Double.infinity)` 是 **trap**（SIGTRAP），不是抛错——
// 对抗验证 V2 实测 `Int(getNumber("face_core_retry_min_samples"))` 遇 1e999 直接崩。

import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherDomain

@Suite("设置数值安全转换")
struct SettingsNumberTests {
    @Test("NaN / ±inf 回退到默认值（旧写法直接 trap）")
    func nonFiniteFallsBackToDefault() {
        #expect(Double.nan.safeInt(fallback: 7) == 7)
        #expect(Double.infinity.safeInt(fallback: 2) == 2)
        #expect((-Double.infinity).safeInt(fallback: 2) == 2)
        #expect(Double.infinity.safeInt() == 0, "无 fallback 时回退 0，而不是崩溃")
    }

    @Test("超大有限值夹到 Int 边界（不 trap）")
    func hugeFiniteValuesClamp() {
        #expect(Double(1e300).safeInt() == Int.max)
        #expect(Double(-1e300).safeInt() == Int.min)
    }

    @Test("正常值语义与 Int(...) 逐位一致（截断，不是四舍五入）")
    func normalValuesMatchTruncation() {
        #expect(Double(1.9).safeInt() == Int(1.9))
        #expect(Double(-1.9).safeInt() == Int(-1.9))
        #expect(Double(0).safeInt() == 0)
        #expect(Double(2048).safeInt() == 2048)
    }
}