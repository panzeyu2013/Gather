// desktop/native/gather-core/Tests/GatherCoreTests/Services/IngestRenameTemplateTests.swift
// P1 / D：摄取重命名模板（纯函数）——占位符、序号宽度、未知占位符保留、相机名清洗。

import Foundation
import Testing
@testable import GatherApplication

@Suite("摄取重命名模板")
struct IngestRenameTemplateTests {
    private var date: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 25
        components.hour = 10; components.minute = 20; components.second = 30
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    @Test("标准模板：日期层级 + 原名 + 4 位序号 + 扩展名")
    func standardTemplate() {
        let name = IngestRenameTemplate.expand(
            "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
            originalName: "DSC_0001.CR3", date: date, sequence: 7, cameraModel: nil
        )
        #expect(name == "2026/10/25/DSC_0001-0007.CR3")
    }

    @Test("序号宽度可调；{seq} 默认 4 位")
    func sequenceWidth() {
        #expect(IngestRenameTemplate.expand("{seq:2}", originalName: "a.jpg", date: date, sequence: 5, cameraModel: nil) == "05")
        #expect(IngestRenameTemplate.expand("{seq}", originalName: "a.jpg", date: date, sequence: 5, cameraModel: nil) == "0005")
    }

    @Test("未知占位符原样保留（让用户看得见写错了什么）")
    func unknownTokenPreserved() {
        let name = IngestRenameTemplate.expand("{yyyy}-{bogus}", originalName: "a.jpg", date: date, sequence: 1, cameraModel: nil)
        #expect(name == "2026-{bogus}")
    }

    @Test("相机名里的路径分隔符被清洗")
    func cameraSanitized() {
        let name = IngestRenameTemplate.expand(
            "{camera}", originalName: "a.jpg", date: date, sequence: 1,
            cameraModel: "FUJI/X-T5:Pro"
        )
        #expect(name == "FUJI_X-T5_Pro")
    }
}
