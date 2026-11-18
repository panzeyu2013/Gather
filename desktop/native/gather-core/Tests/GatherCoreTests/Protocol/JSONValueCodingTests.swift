// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift
// 性能审计回归（2026-11-17 perf-core；2026-11-18 评审 R3-T01/R5-02 修正）：
// JSONValue 的共享编解码器（JSONValueCoding.encoder/decoder，被 JSONValue.parse/
// stringify 与 JSONValue.init(encoding:)/decode 复用）必须与「每次新建默认配置
// JSONEncoder/JSONDecoder」**值等价**；损坏输入的抛错语义也不得漂移。
//
// 重要修正：Foundation 的 JSONEncoder 不承诺对含 Dictionary/对象的 JSON 输出稳定
// 字节序（同值跨实例可不同；Linux swift-foundation 实测 encode→decode→encode 会
// 翻转顺序）。因此本文件对对象只做「解析后值等价」，字节比较仅用于标量/数组/
// 无重复键的稳定形态；需要字节断言时两侧都加 .sortedKeys 规范化。
//
// 背景：热路径曾每次调用新建两个 coder（元数据缓存 descriptive 逐行往返、
// keywords/bbox/分析指纹解析）。复用默认配置实例的前提是「无可变状态 + 解码值
// 等价」，本文件用独立 baseline oracle 把该前提钉死。
import Foundation
import Testing
import GatherProtocol

private struct JSONValueCodingFixture: Codable, Equatable {
    let id: Int
    let name: String
    let nested: [String: Int]
    let values: [Double]
    let optional: Bool?
    let unicode: String
}

@Suite("JSONValue 编解码缓存等价性")
struct JSONValueCodingTests {

    /// 独立 baseline oracle：每次新建默认配置 encoder（不复用生产 coder）。
    private func baselineEncode(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func baselineDecode(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    private func fixture() -> JSONValueCodingFixture {
        JSONValueCodingFixture(
            id: 42,
            name: "gather",
            nested: ["a": 1, "b": 2],
            values: [0, 1.5, -2.25, 1e-9],
            optional: nil,
            unicode: "中文/emoji-🎞/规范")
    }

    @Test("stringify 与默认配置 JSONEncoder 值等价（标量/数组字节一致）")
    func stringifyMatchesBaselineEncoder() throws {
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .number(0),
            .number(3.14159),
            .number(-1e-9),
            .string("引号\"反斜杠\\换行\n中文"),
            .array([.number(1), .string("two"), .null, .bool(true)]),
            .object(["a": .number(1), "中文": .string("值"), "nested": .array([.null])]),
        ]
        for value in values {
            let cached = try JSONValue.stringify(value)
            let baseline = try baselineEncode(value)
            #expect(try JSONValue.parse(cached) == JSONValue.parse(baseline),
                    "stringify 解码值漂移：\(value)")
            // 对象键序 Foundation 不承诺稳定，不做裸字节比较；标量/数组仍比字节。
            if case .object = value { continue }
            #expect(cached == baseline, "非对象值 stringify 字节漂移：\(value)")
        }
    }

    @Test("parse 与默认配置 JSONDecoder 解码结果一致（转义/空白/数字/标量）")
    func parseMatchesBaselineDecoder() throws {
        let inputs = [
            "{\"a\":1,\"b\":[true,null,3.5],\"中文\":\"值\"}",
            " { \"pretty\": true, \"nested\": { \"k\": [1, 2.5, -3] } } ",
            "[1,\"two\",false,null,{}]",
            "\"\\u4e2d\\u6587\"",
            "3.5",
            "null",
            "true",
        ]
        for input in inputs {
            let cached = try JSONValue.parse(input)
            let baseline = try baselineDecode(input)
            #expect(cached == baseline, "parse 解码漂移：\(input)")
        }
    }

    @Test("init(encoding:) 与新建 encoder/decoder 路径的 JSONValue 一致")
    func initEncodingMatchesBaseline() throws {
        let model = fixture()
        let cached = try JSONValue(encoding: model)
        let data = try JSONEncoder().encode(model)
        let baseline = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(cached == baseline, "JSONValue(encoding:) 的 JSONValue 形状漂移")
        let decoded = try cached.decode(JSONValueCodingFixture.self)
        #expect(decoded == model, "JSONValue(encoding:) 往返必须无损")
    }

    @Test("decode(_:) 与新建 decoder 的模型往返一致")
    func decodeMatchesBaselineDecoder() throws {
        let model = fixture()
        let value = try JSONValue(encoding: model)
        let cached = try value.decode(JSONValueCodingFixture.self)
        let data = try JSONEncoder().encode(value)
        let baseline = try JSONDecoder().decode(JSONValueCodingFixture.self, from: data)
        #expect(cached == model)
        #expect(cached == baseline)
    }

    @Test("stringify → parse 往返等价，且与 baseline 编码值等价")
    func roundTripMatchesBaseline() throws {
        let value: JSONValue = .object([
            "id": .number(7),
            "tags": .array([.string("x"), .string("y")]),
            "meta": .object(["ok": .bool(true)]),
        ])
        let json = try JSONValue.stringify(value)
        let parsed = try JSONValue.parse(json)
        #expect(parsed == value, "stringify → parse 必须无损")
        let baseline = try baselineEncode(value)
        // 评审 R3-T01：对象键序不保证跨实例稳定，比较解码值而不是裸字节。
        #expect(try JSONValue.parse(baseline) == value, "baseline 解码值必须与原始值一致")
        #expect(try JSONValue.parse(json) == try JSONValue.parse(baseline), "编码值语义必须一致")
    }

    @Test("损坏输入：parse 与新建 decoder 都抛 DecodingError（失败语义不变）")
    func malformedInputThrows() {
        let malformed = ["{", "{bad}", "[1,", "\"unterminated", "tru", ""]
        for input in malformed {
            #expect(throws: DecodingError.self) { _ = try JSONValue.parse(input) }
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
            }
        }
    }
}
