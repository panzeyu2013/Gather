// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/DimensionsReconciliationTests.swift
// 图片尺寸对账测试（Phase 2 任务 2.1「解码 + 缩略图」）。
//
// fixture 由 scripts/reconciliation/generate-dimensions-fixtures.mjs 生成
// （参照实现 = fast-dimensions.ts 逐字照抄；expected 手工按规范算好，生成时
// 与参照实现互验一致），本测试逐 case 解码 base64 后以 ImageDimensions.read
// 重算，与 expected 逐一相等（null 也断言）。

import Foundation
import Testing
@testable import GatherCore

struct DimensionsReconciliationTests {

    private struct Fixture: Decodable {
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let ext: String
            let dataBase64: String
            let expected: [Int]?
        }
    }

    private static func loadFixture() throws -> Fixture {
        let data = try FixtureLoader.loadJSON(named: "dimensions-fixtures.json")
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    @Test func dimensionsMatchFixture() throws {
        let fixture = try Self.loadFixture()
        for c in fixture.cases {
            guard let data = Data(base64Encoded: c.dataBase64) else {
                Issue.record("case \(c.name): base64 解码失败")
                continue
            }
            let actual = ImageDimensions.read(data, ext: c.ext)
            if let expected = c.expected {
                guard expected.count == 2 else {
                    Issue.record("case \(c.name): expected 长度 != 2")
                    continue
                }
                guard let dims = actual else {
                    Issue.record("case \(c.name): 期望 [\(expected[0]), \(expected[1])]，得到 nil")
                    continue
                }
                #expect(dims.width == expected[0], "case \(c.name): width 漂移")
                #expect(dims.height == expected[1], "case \(c.name): height 漂移")
            } else {
                #expect(actual == nil, "case \(c.name): 期望 null，得到 \(String(describing: actual))")
            }
        }
    }
}
