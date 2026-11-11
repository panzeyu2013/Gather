// desktop/native/gather-core/Tests/GatherCoreTests/MetadataIO/IPTCIIMTests.swift
// Wave5（batch2）收口：IPTC-IIM 2:40 Special Instructions 的键、映射与编码往返。
//
// 覆盖：
// 1. 键值（2:40）与 DescriptiveField.instructions 的映射；
// 2. 其余新增字段（EventId / release id）在 IIM 无 dataset，映射必须返回 nil（不编造号）；
// 3. updates 有值写入 / 空串删除；4. 编码往返 + 非 ASCII 补 UTF-8 标志；
// 5. 手工 IIM 字节（外部工具形态）能解析出 2:40。
import Foundation
import Testing
import GatherProtocol
@testable import GatherMetadataIO

@Suite("IPTC-IIM 2:40（Instructions）")
struct IPTCIIMTests {

    @Test("键与映射：instructions → 2:40；其余 Wave5 字段不编造 dataset")
    func instructionsMapsToSpecialInstructions() {
        #expect(IIMKey.specialInstructions == IIMKey(record: 2, dataset: 40))
        #expect(IPTCIIMMapping.key(for: .instructions) == .specialInstructions)
        #expect(IPTCIIMMapping.key(for: .eventIdentifier) == nil)
        #expect(IPTCIIMMapping.key(for: .modelReleaseID) == nil)
        #expect(IPTCIIMMapping.key(for: .propertyReleaseID) == nil)
        // 既有映射不受影响（回归锚点）。
        #expect(IPTCIIMMapping.key(for: .location) == IIMKey(record: 2, dataset: 27))
        #expect(IPTCIIMMapping.key(for: .scene) == IIMKey(record: 2, dataset: 202))
    }

    @Test("updates：有值写 2:40，空串 = 删 dataset")
    func updatesWriteAndClear() {
        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("仅限一次使用"), for: .instructions)
        let written = IPTCIIMMapping.updates(for: descriptive, keywords: nil)
        #expect(written[.specialInstructions] == ["仅限一次使用"])

        descriptive.set(.text(""), for: .instructions)
        let cleared = IPTCIIMMapping.updates(for: descriptive, keywords: nil)
        #expect(cleared[.specialInstructions] == [], "空数组 = 删除 2:40")
        // 其余三个字段不进 updates（没有 dataset）。
        #expect(!cleared.keys.contains(.byline))
    }

    @Test("编码往返：2:40 持久化；非 ASCII 自动补 UTF-8 标志")
    func encodedRoundTripKeepsUTF8Flag() throws {
        let encoded = try IPTCIIM().replacing([.specialInstructions: ["禁发至 2026-12-01"]])
        let decoded = try IPTCIIM.parse(try encoded.encoded())
        #expect(decoded.values(for: .specialInstructions) == ["禁发至 2026-12-01"])
        #expect(decoded.datasets.contains { $0.key == .codedCharacterSet })
    }

    @Test("手工 IIM 字节：外部工具写的 2:40 能解析")
    func parsesExternalSpecialInstructions() throws {
        // 0x1C(标记) 0x02(record) 0x28(40, dataset) + u16 长度 + payload
        var data = Data([0x1C, 0x02, 40, 0x00, 0x06])
        data.append(Data("EMBARG".utf8))
        let parsed = try IPTCIIM.parse(data)
        #expect(parsed.values(for: .specialInstructions) == ["EMBARG"])
    }
}
