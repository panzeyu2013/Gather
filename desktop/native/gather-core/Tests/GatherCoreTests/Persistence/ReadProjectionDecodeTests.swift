// desktop/native/gather-core/Tests/GatherCoreTests/Persistence/ReadProjectionDecodeTests.swift
// 下一轮 / M10 解码测试：GatherProtocol 只读投影类型的 DBRow 解码契约。
//
// 守护：init(row:)/init(columns:row:) 的列序与字段映射（含 null 容忍、列数不足 fail-closed）。
// 这些类型已从 Persistence 上移到 Protocol（M10 + D2 批次），解码仍留在 Persistence extension；
// 本测试只用 public 解码入口（普通 import，可在 Linux 对真实模块 typecheck）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence

@Suite("只读投影 DBRow 解码")
struct ReadProjectionDecodeTests {
    @Test("CullingDecisionRow：11 列位置解码与 null 容忍")
    func cullingDecisionRowDecodes() {
        let row: DBRow = [
            .int(7), .text("s1"), .text("p1"), .text("g1"), .text("keep"),
            .int(4), .text("red"), .text("manual"), .int(3), .text("t0"), .null,
        ]
        let decoded = CullingDecisionRow(row: row)
        #expect(decoded.id == 7)
        #expect(decoded.sessionId == "s1")
        #expect(decoded.photoId == "p1")
        #expect(decoded.decision == "keep")
        #expect(decoded.rating == 4)
        #expect(decoded.colorLabel == "red")
        #expect(decoded.revision == 3)
        #expect(decoded.updatedAt == "")
    }

    @Test("PhotoPageRow：13 列解码 + 列数不足 fail-closed")
    func photoPageRowDecodes() throws {
        let row: DBRow = [
            .int(1), .text("p1"), .text("s1"), .text("/v/a.xmp"), .text("a.xmp"),
            .text("indexed"), .null, .null, .int(6000), .int(4000),
            .text("sum"), .text("c0"), .text("u0"),
        ]
        let decoded = try PhotoPageRow(row: row)
        #expect(decoded.rowid == 1)
        #expect(decoded.id == "p1")
        #expect(decoded.sessionId == "s1")
        #expect(decoded.filepath == "/v/a.xmp")
        #expect(decoded.width == 6000)
        #expect(decoded.height == 4000)
        #expect(decoded.checksum == "sum")
        #expect(decoded.assetId == nil)
        #expect(throws: DBError.self) { _ = try PhotoPageRow(row: Array(row.prefix(12))) }
    }

    @Test("MetadataCacheRow：23 列解码 + keywords JSON 派生")
    func metadataCacheRowDecodes() {
        var row: DBRow = Array(repeating: .null, count: 23)
        row[0] = .int(9)
        row[1] = .text("p1")
        row[2] = .text("s1")
        row[11] = .int(5)
        row[12] = .text("green")
        row[15] = .int(6000)
        row[19] = .text("[\"a\",\"b\"]")
        row[22] = .text("{}")
        let decoded = MetadataCacheRow(row: row)
        #expect(decoded.id == 9)
        #expect(decoded.photoId == "p1")
        #expect(decoded.rating == 5)
        #expect(decoded.label == "green")
        #expect(decoded.width == 6000)
        #expect(decoded.keywords == ["a", "b"])
    }

    @Test("DeliveryItemRow：按列名映射解码（columns + row）")
    func deliveryItemRowDecodes() throws {
        let columns = DeliveryItemRow.columnNames
        var values: [String: DBValue] = [:]
        for name in columns { values[name] = .null }
        values["id"] = .int(3)
        values["delivery_id"] = .int(2)
        values["photo_id"] = .text("p1")
        values["module"] = .text("metadata")
        values["status"] = .text("pending")
        values["keywords"] = .text("[\"x\"]")
        values["xmp_path"] = .text("/v/a.xmp")
        let row: DBRow = columns.map { values[$0] ?? .null }
        let decoded = try DeliveryItemRow(columns: columns, row: row)
        #expect(decoded.id == 3)
        #expect(decoded.deliveryId == 2)
        #expect(decoded.photoId == "p1")
        #expect(decoded.module == "metadata")
        #expect(decoded.typedModule == .metadata)
        #expect(decoded.typedStatus == .pending)
        #expect(decoded.xmpPath == "/v/a.xmp")
        #expect(decoded.keywordList == ["x"])
    }

    @Test("FaceClusterRow：10 列解码 + 列数不足 fail-closed")
    func faceClusterRowDecodes() throws {
        let row: DBRow = [
            .int(11), .text("s1"), .text("簇 A"), .int(4), .text("open"),
            .text("/thumbs/11.jpg"), .text("person-1"), .real(0.93),
            .text("c0"), .text("u0"),
        ]
        let decoded = try FaceClusterRow(row: row)
        #expect(decoded.id == 11)
        #expect(decoded.sessionId == "s1")
        #expect(decoded.label == "簇 A")
        #expect(decoded.memberCount == 4)
        #expect(decoded.matchedPersonId == "person-1")
        #expect(decoded.matchConfidence == 0.93)
        #expect(decoded.members == nil)
        #expect(throws: DBError.self) { _ = try FaceClusterRow(row: Array(row.prefix(9))) }
    }
}
