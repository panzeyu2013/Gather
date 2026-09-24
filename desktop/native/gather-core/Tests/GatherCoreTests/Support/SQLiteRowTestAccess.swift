// desktop/native/gather-core/Tests/GatherCoreTests/Support/SQLiteRowTestAccess.swift
// 测试专用：按 SELECT 列序访问行值（生产代码一律用命名列，禁止依赖列序）。

import Foundation
@testable import GatherCore

extension SQLiteRow {
    /// 第 index 列文本值（测试断言用）。
    func text(at index: Int) -> String? {
        values[columnOrder[index]]?.textValue
    }

    /// 第 index 列整数值（测试断言用）。
    func int(at index: Int) -> Int64? {
        values[columnOrder[index]]?.intValue
    }

    /// 第 index 列浮点值（测试断言用）。
    func double(at index: Int) -> Double? {
        values[columnOrder[index]]?.doubleValue
    }
}
