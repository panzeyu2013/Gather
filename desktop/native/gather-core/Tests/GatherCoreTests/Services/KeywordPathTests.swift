// desktop/native/gather-core/Tests/GatherCoreTests/Services/KeywordPathTests.swift
// P1 下一波 §3.6.2/§3.6.6：层级关键词的编解码金样。
//
// 覆盖：A|B / 叶子 / 空段 / 重复 / 大小写 / NFC；两套列表合并；dc:subject 两种风格；
// lr:hierarchicalSubject 只含层级路径；facet 桶（首段 / 下钻下一段）。
import Foundation
import Testing
@testable import GatherProtocol

@Suite("关键词层级编解码")
struct KeywordPathTests {

    @Test("解析：空段丢弃而非整词丢弃，纯分隔符返回 nil")
    func parsesSegments() {
        #expect(KeywordPath("A|B|C")?.segments == ["A", "B", "C"])
        #expect(KeywordPath("A||B")?.segments == ["A", "B"], "空段丢弃，前后段保留")
        #expect(KeywordPath("  A | B  ")?.serialized == "A|B", "段 trim")
        #expect(KeywordPath("|") == nil)
        #expect(KeywordPath("   ") == nil)
        #expect(KeywordPath("") == nil)
        #expect(KeywordPath.parse("A|B")?.serialized == "A|B", "parse 与 init? 同义")
    }

    @Test("NFC 归一化：组合字符与预组合字符等价")
    func normalizesNFC() {
        let decomposed = "Cafe\u{301}"      // e + combining acute
        let precomposed = "Caf\u{E9}"       // é
        #expect(KeywordPath(decomposed)?.serialized == precomposed)
        #expect(KeywordPath(decomposed)?.foldedKey == KeywordPath(precomposed)?.foldedKey)
    }

    @Test("折叠键：大小写与宽度不敏感，但序列化保留原拼写")
    func foldsWithoutRewriting() {
        let upper = KeywordPath("Travel|Paris")
        let lower = KeywordPath("travel|paris")
        #expect(upper?.foldedKey == lower?.foldedKey)
        #expect(upper?.serialized == "Travel|Paris")
        #expect(lower?.serialized == "travel|paris")
    }

    @Test("叶子 / 祖先 / 深度 / 继承关系")
    func hierarchyHelpers() throws {
        let path = try #require(KeywordPath("A|B|C"))
        #expect(path.leaf == "C")
        #expect(path.ancestors == ["A", "B"])
        #expect(path.topSegment == "A")
        #expect(path.depth == 3)
        #expect(path.parent?.serialized == "A|B")
        let root = try #require(KeywordPath("A"))
        #expect(path.isDescendant(of: root))
        #expect(path.isDescendant(of: path))
        #expect(!root.isDescendant(of: path))
        let lowerRoot = try #require(KeywordPath("a"))
        #expect(try #require(KeywordPath("A|B")).isDescendant(of: lowerRoot),
                "下钻判定大小写不敏感")
    }

    @Test("两套列表合并：层级优先、叶子并回路径、平铺词保留")
    func mergesFlatAndHierarchical() {
        let merged = KeywordCodec.merge(
            flat: ["Paris", "flat", "travel|paris"],
            hierarchical: ["Travel|Paris", "travel|paris"])
        #expect(merged.map(\.serialized) == ["Travel|Paris", "flat"],
                "dc 里的 \"Paris\" 是 Travel|Paris 的展开（不是独立关键词）；")
        #expect(!merged.contains { $0.serialized == "Paris" })
        #expect(merged.contains { $0.serialized == "flat" }, "真正的平铺词保留")
    }

    @Test("往返稳定：写 [\"A|B\"]（leaf 风格）后读回仍是 [\"A|B\"]")
    func roundTripsWithoutLeafNoise() {
        let paths = KeywordCodec.parse(["A|B", "flat"])
        let encoded = KeywordCodec.encoded(["A|B", "flat"], style: .leaf)
        let readBack = KeywordCodec.merge(flat: encoded.dc, hierarchical: encoded.hierarchical)
        #expect(readBack.map(\.serialized) == paths.map(\.serialized),
                "写盘 → 读回必须相等（否则每轮写回都会多出叶子关键词）")
    }

    @Test("dc:subject 风格：leaf 只写叶子，path 写完整路径")
    func encodesDCSubjectByStyle() {
        let paths = KeywordCodec.parse(["Travel|Paris", "Travel|Paris|Louvre", "flat"])
        #expect(KeywordCodec.dcSubject(for: paths, style: .leaf) == ["Paris", "Louvre", "flat"])
        #expect(KeywordCodec.dcSubject(for: paths, style: .path)
            == ["Travel|Paris", "Travel|Paris|Louvre", "flat"])
    }

    @Test("lr:hierarchicalSubject 只写含层级的路径")
    func encodesHierarchicalOnly() {
        let paths = KeywordCodec.parse(["Travel|Paris", "flat"])
        #expect(KeywordCodec.hierarchicalSubject(for: paths) == ["Travel|Paris"],
                "平铺词写进 lr 会被当成一级路径，必须排除")
    }

    @Test("encoded 是写侧与写后校验的唯一编码")
    func encodesBothLists() {
        let encoded = KeywordCodec.encoded(["A|B", "flat", "a|b"], style: .leaf)
        #expect(encoded.dc == ["B", "flat"])
        #expect(encoded.hierarchical == ["A|B"])
        #expect(KeywordCodec.encoded([], style: .leaf).dc.isEmpty)
        #expect(KeywordCodec.encoded([], style: .leaf).hierarchical.isEmpty)
    }

    @Test("wire 列表规范化：NFC / trim / 丢空段 / 去重")
    func normalizesWireList() {
        #expect(KeywordCodec.normalized(["A||B", " a|b ", "A|B", "  "]) == ["A|B"])
        #expect(KeywordCodec.normalized([]).isEmpty)
    }

    @Test("facet 桶：顶级取首段，下钻取前缀之后的下一段")
    func computesChildBuckets() throws {
        let paths = KeywordCodec.parse([
            "Travel", "Travel|Paris", "Travel|Paris|Louvre",
            "Travel|Tokyo", "People|Alice"])
        #expect(KeywordCodec.childBuckets(of: paths, under: nil)
            == ["Travel", "People"], "顶级桶 = 首段，去重保序")
        let travel = try #require(KeywordPath("Travel"))
        let paris = try #require(KeywordPath("Travel|Paris"))
        let nope = try #require(KeywordPath("Nope"))
        let partial = try #require(KeywordPath("tra"))
        #expect(KeywordCodec.childBuckets(of: paths, under: travel) == ["Paris", "Tokyo"])
        #expect(KeywordCodec.childBuckets(of: paths, under: paris) == ["Louvre"])
        #expect(KeywordCodec.childBuckets(of: paths, under: nope).isEmpty)
        #expect(KeywordCodec.childBuckets(of: paths, under: partial).isEmpty,
                "前缀不是完整段时不匹配（tra 不是 Travel）")
    }

    @Test("KeywordDCSubjectStyle 的 rawValue 稳定（设置键 keyword_dc_style 的取值）")
    func styleRawValues() {
        #expect(KeywordDCSubjectStyle(rawValue: "leaf") == .leaf)
        #expect(KeywordDCSubjectStyle(rawValue: "path") == .path)
        #expect(KeywordDCSubjectStyle(rawValue: "LEAF") == nil)
    }
}
