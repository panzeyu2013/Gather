// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/RepositorySupportTests.swift
// 仓库层共享支撑契约：时间戳文本格式（SQL 里按文本比较 → 格式即语义）与
// ISO8601 解析的唯一实现（tsParseISODate / tsDateParse / parseTimestamp 同源）。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

struct RepositorySupportTests {
    /// isoString/nowISOString 必须输出 UTC 毫秒 ISO8601：analysis_jobs 的
    /// heartbeat_at < cutoff（租约过期判定）与 sessions 列表排序都是**文本**比较，
    /// 格式一旦漂移（缺毫秒、本地时区、非固定宽度）语义即改变。
    @Test func isoStringIsUTCMillisecondISO8601() {
        #expect(isoString(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(isoString(Date(timeIntervalSince1970: 1.5)) == "1970-01-01T00:00:01.500Z")
        #expect(isoString(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500Z")
        #expect(isoString(Date(timeIntervalSince1970: 1_234_567_890.1234)) == "2009-02-13T23:31:30.123Z")
        #expect(isoString(Date(timeIntervalSince1970: 4_102_444_800)) == "2100-01-01T00:00:00.000Z")
    }

    /// 同一格式下文本序 == 时间序（SQL 的 ORDER BY updated_at / heartbeat_at < ? 前提）。
    @Test func isoStringTextOrderMatchesChronology() {
        let epoch = isoString(Date(timeIntervalSince1970: 0))
        let laterSameSecond = isoString(Date(timeIntervalSince1970: 0.001))
        let nextSecond = isoString(Date(timeIntervalSince1970: 1))
        #expect(epoch < laterSameSecond)
        #expect(laterSameSecond < nextSecond)
    }

    /// 解析唯一实现的边界输入：空串/非法输入 → nil；带毫秒优先；回退不带毫秒。
    @Test func isoParseHandlesFractionalPlainAndInvalidInput() {
        #expect(tsParseISODate("") == nil)
        #expect(tsParseISODate("not-a-date") == nil)
        #expect(tsDateParse("") == nil)
        #expect(tsDateParse("2026-13-45T99:99:99Z") == nil)
        #expect(tsParseISODate("1970-01-01T00:00:00.000Z") == Date(timeIntervalSince1970: 0))
        #expect(tsParseISODate("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(tsDateParse("1970-01-01T00:00:00.500Z") == 500)
        // tsDateParse = tsParseISODate 的毫秒投影（两者不得各自维护解析器）。
        for raw in ["2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00Z", "bad", ""] {
            #expect(tsDateParse(raw) == tsParseISODate(raw).map { $0.timeIntervalSince1970 * 1000 })
        }
    }
}
