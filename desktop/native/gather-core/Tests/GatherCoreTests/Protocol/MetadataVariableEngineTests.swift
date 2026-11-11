// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/MetadataVariableEngineTests.swift
// Wave2 task-13：元数据文案变量引擎的纯逻辑用例。
//
// 覆盖：可用变量全集、{seq:width} 序号语义、client/相机/拍摄日期取值、
// 未知变量与缺值变量（unresolved 可枚举、原文保留）、花括号转义、非法占位符
// 按字面量处理、两种日期分隔符。
import Foundation
import Testing
@testable import GatherProtocol

@Suite("元数据变量引擎")
struct MetadataVariableEngineTests {

    private func photo(
        filename: String = "ACME_0142.CR3",
        camera: String? = "X-T5",
        dateTaken: String? = "2026:05:01 10:00:00"
    ) -> MetadataVariablePhoto {
        MetadataVariablePhoto(filename: filename, camera: camera, dateTaken: dateTaken)
    }

    @Test func expandsSupportedVariables() {
        let scope = MetadataVariableScope(client: "ACME", sequenceStart: 1)
        let expansion = MetadataVariableEngine.expand(
            "{client} / {year}-{month}-{day} / {filename} / {name}.{ext} / {camera} / {seq}",
            scope: scope, photo: photo(), sequence: 3)
        #expect(expansion.unresolved.isEmpty)
        #expect(expansion.text == "ACME / 2026-05-01 / ACME_0142.CR3 / ACME_0142.CR3 / X-T5 / 3")
    }

    @Test func padsSequenceWhenWidthGiven() {
        let expansion = MetadataVariableEngine.expand(
            "第 {seq:4} 张", scope: MetadataVariableScope(), photo: photo(), sequence: 7)
        #expect(expansion.text == "第 0007 张")
        #expect(expansion.unresolved.isEmpty)
    }

    @Test func sequenceIsClampedToAtLeastOne() {
        let expansion = MetadataVariableEngine.expand(
            "{seq}", scope: MetadataVariableScope(), photo: photo(), sequence: 0)
        #expect(expansion.text == "1")
    }

    @Test func missingValuesAreUnresolvedAndKeptLiteral() {
        let expansion = MetadataVariableEngine.expand(
            "{client}-{camera}-{year}", scope: MetadataVariableScope(client: "  "),
            photo: photo(camera: nil, dateTaken: nil), sequence: 1)
        #expect(expansion.text == "{client}-{camera}-{year}")
        #expect(Set(expansion.unresolved.map(\.name)) == Set(["client", "camera", "year"]))
        #expect(expansion.unresolved.count == 3)
    }

    @Test func unknownVariablesAreEnumerableWithoutPhotoContext() {
        #expect(MetadataVariableEngine.unknownVariables(
            in: "{client}/{project}/{seq}") == ["project"])
        #expect(MetadataVariableEngine.unknownVariables(in: "{seq}") == [])
    }

    @Test func unknownVariableIsUnresolvedDuringExpansion() {
        let expansion = MetadataVariableEngine.expand(
            "{project}", scope: MetadataVariableScope(), photo: photo(), sequence: 1)
        #expect(expansion.text == "{project}")
        #expect(expansion.unresolved.map(\.name) == ["project"])
        #expect(expansion.unresolved.map(\.raw) == ["{project}"])
    }

    @Test func escapesLiteralBraces() {
        let expansion = MetadataVariableEngine.expand(
            "{{seq}} 与 {{client}}", scope: MetadataVariableScope(client: "ACME"),
            photo: photo(), sequence: 2)
        #expect(expansion.text == "{seq} 与 {client}")
        #expect(expansion.unresolved.isEmpty)
    }

    @Test func malformedPlaceholdersStayLiteral() {
        let expansion = MetadataVariableEngine.expand(
            "{seq:0} {seq:} {seq} { }", scope: MetadataVariableScope(), photo: photo(), sequence: 1)
        // "{seq:0}"（宽度非法）、"{seq:}"、"{ }" 都按字面量；只有合法的 {seq} 展开。
        #expect(expansion.text == "{seq:0} {seq:} 1 { }")
        #expect(expansion.unresolved.isEmpty)
    }

    @Test func dateAcceptsDashFormat() {
        let expansion = MetadataVariableEngine.expand(
            "{year}/{month}/{day}",
            scope: MetadataVariableScope(),
            photo: photo(dateTaken: "2025-12-31T23:59:59+08:00"), sequence: 1)
        #expect(expansion.text == "2025/12/31")
        #expect(expansion.unresolved.isEmpty)
    }

    @Test func invalidDateBecomesUnresolved()  {
        let expansion = MetadataVariableEngine.expand(
            "{year}", scope: MetadataVariableScope(),
            photo: photo(dateTaken: "not a date"), sequence: 1)
        #expect(expansion.text == "{year}")
        #expect(expansion.unresolved.map(\.name) == ["year"])
    }
}
