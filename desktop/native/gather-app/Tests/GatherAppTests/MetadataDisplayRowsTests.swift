// desktop/native/gather-app/Tests/GatherAppTests/MetadataDisplayRowsTests.swift
// P1 / IPTC：只读面板行投影（格式化的唯一实现，纯函数直测）。

import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("MetadataDisplay 行投影")
struct MetadataDisplayRowsTests {
    private let identity: (String) -> String = { $0 }

    @Test("exif 行：空字段不出行，数值按人读格式")
    func exifRowsFormatting() {
        let exif = PhotoExifSnapshot(
            dateTaken: "2026:10:25 10:20:30",
            cameraMake: "FUJIFILM", cameraModel: "X-T5",
            lensModel: "XF23mmF1.4", focalLength: 23, fNumber: 2.8,
            exposureTime: "1/250", iso: 400, gpsLatitude: 31.2304, gpsLongitude: 121.4737,
            width: 7728, height: 5152, fileSize: 26_214_400, fileMtime: "2026-10-25T02:20:30Z"
        )
        let rows = MetadataDisplay.exifRows(exif, l10n: identity)
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(map["机身"] == "FUJIFILM X-T5")
        #expect(map["焦距"] == "23 mm")
        #expect(map["光圈"] == "f/2.8")
        #expect(map["ISO"] == "400")
        #expect(map["尺寸"] == "7728 × 5152")
        #expect(map["文件大小"] == "25.0 MB")
        #expect(map["位置"] == "31.230400, 121.473700")
        #expect(rows.count == 11)
    }

    @Test("exif 行：全空快照不产生任何行")
    func exifRowsEmptySnapshot() {
        #expect(MetadataDisplay.exifRows(PhotoExifSnapshot(), l10n: identity).isEmpty)
    }

    @Test("iptc 行：只显示已填写字段，列表用顿号连接")
    func iptcRowsFormatting() {
        let metadata = DescriptiveMetadata(
            title: "落日",
            creator: ["张三", "李四"],
            city: "上海",
            contactInfo: DescriptiveContact(email: "a@b.c", telephone: "123"),
            personInImage: ["王五"]
        )
        let rows = MetadataDisplay.iptcRows(metadata, l10n: identity)
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(map["标题"] == "落日")
        #expect(map["作者"] == "张三、李四")
        #expect(map["城市"] == "上海")
        #expect(map["画面人物"] == "王五")
        #expect(map["联系方式"] == "a@b.c · 123")
        #expect(map["国家/地区"] == nil)
        #expect(rows.count == 5)
    }

    @Test("全字段面板：未填写字段也出行（isFilled=false），Core/Extension 分组完整")
    func fieldRowsIncludeEmptyFields() {
        let metadata = DescriptiveMetadata(title: "落日")
        let core = MetadataDisplay.fieldRows(
            MetadataDisplay.iptcCoreFields, metadata, l10n: identity)
        let ext = MetadataDisplay.fieldRows(
            MetadataDisplay.iptcExtensionFields, metadata, l10n: identity)
        #expect(core.count == 22)
        #expect(ext.count == 10)
        #expect(core.filter(\.isFilled).count == 1)
        #expect(core.first { $0.label == "标题" }?.isFilled == true)
        #expect(core.first { $0.label == "城市" }?.isFilled == false)
        #expect(core.first { $0.label == "城市" }?.value == "")
    }

    @Test("文件大小分级与整数化")
    func fileSizeUnits() {
        #expect(MetadataDisplay.fileSize(512) == "512 B")
        #expect(MetadataDisplay.fileSize(2048) == "2.0 KB")
        #expect(MetadataDisplay.fileSize(5 * 1024 * 1024) == "5.0 MB")
        #expect(MetadataDisplay.number(23.0) == "23")
        #expect(MetadataDisplay.number(2.85) == "2.9")
    }
}
