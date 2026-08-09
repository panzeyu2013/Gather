// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/Harness.swift
// 对账测试框架（Phase 1 任务 1.5）公共设施：加载入库 fixture。
//
// 对账模式：fixture 由 TS 侧生成器（scripts/reconciliation/）产出并入库，
// TS 生成器 --check 与 Swift 测试双跑同一 JSON（TS vitest ↔ Swift XCTest 语义，
// 本包使用 Swift Testing）。见同目录 README.md。

import Foundation

enum FixtureLoader {
    /// 读取 Reconciliation/Fixtures/ 下入库的 fixture 文件。
    static func loadJSON(named name: String) throws -> Data {
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return try Data(contentsOf: fixturesDir.appendingPathComponent(name))
    }
}

/// dHash 对账 fixture 结构，与 generate-hash-fixtures.mjs 输出一致：
/// {"seed":42,"cases":[{"pixels":[...72 数...],"expected":"16 位 hex"}]}
struct DHashFixture: Decodable {
    struct Case: Decodable {
        let pixels: [UInt8]
        let expected: String
    }

    let seed: Int
    let cases: [Case]
}
