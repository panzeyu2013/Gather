// desktop/native/gather-core/Tests/GatherCoreTests/Services/IngestServiceTests.swift
// P1 / D：摄取计划/执行——模板分配、校验、冲突不覆盖、第二目的地。

import Foundation
import Testing
@testable import GatherApplication

@Suite("摄取执行")
struct IngestServiceTests {
    private func makeSource(_ names: [String], contents: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-ingest-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            try Data((contents[name] ?? name).utf8).write(to: URL(fileURLWithPath: path))
        }
        return dir
    }

    private func makeDestination() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-dest-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("计划：按模板分配连续序号，扩展名/原名保留")
    func planAssignsSequence() throws {
        let source = try makeSource(["b.CR3", "a.CR3"], contents: [:])
        let dest = try makeDestination()
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: dest)
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let plan = try service.plan(
            sourcePaths: [source],
            options: IngestOptions(destinationRoot: dest, renameTemplate: "{orig}-{seq:3}.{ext}")
        )
        #expect(plan.items.count == 2)
        #expect(plan.items[0].destPath.hasSuffix("a-001.CR3"), "按文件名排序后分配序号")
        #expect(plan.items[1].destPath.hasSuffix("b-002.CR3"))
    }

    @Test("执行：复制 + 校验 + 第二目的地都成功")
    func executeCopiesAndVerifies() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "payload-a"])
        let dest = try makeDestination()
        let second = try makeDestination()
        defer {
            [source, dest, second].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}", secondDestinationRoot: second
        )
        let plan = try service.plan(sourcePaths: [source], options: options)
        let result = service.execute(plan, options: options)

        #expect(result.failed.isEmpty)
        #expect(result.copied.count == 1)
        #expect(result.secondCopied.count == 1)
        let copied = try String(contentsOfFile: result.copied[0], encoding: .utf8)
        #expect(copied == "payload-a")
        #expect(result.registeredDirectories.count == 1)
    }

    @Test("模板里的 ../ 不得把文件写到目的地根目录之外")
    func rejectsPathTraversalTemplate() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "x"])
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let plan = try service.plan(
            sourcePaths: [source],
            options: IngestOptions(destinationRoot: dest, renameTemplate: "../{orig}.{ext}")
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unreadable.count == 1, "逃逸路径必须在计划阶段被拒绝")
    }

    @Test("移动模式 + 校验：源文件被移走且目标内容完整（不得先移后校验导致丢源）")
    func executeMovesAndVerifies() throws {
        let source = try makeSource(["move.CR3"], contents: ["move.CR3": "move-payload"])
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}", moveInsteadOfCopy: true)
        let plan = try service.plan(sourcePaths: [source], options: options)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plan.items[0].sourcePath), "移动后源文件应消失")
        #expect(try String(contentsOfFile: result.copied[0], encoding: .utf8) == "move-payload")
    }

    @Test("XMP 侧车随照片一起搬（主目的地与第二目的地都带上）")
    func sidecarTravelsWithPhoto() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "raw"])
        let sidecar = (source as NSString).appendingPathComponent("a.xmp")
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecar))
        let dest = try makeDestination()
        let second = try makeDestination()
        defer {
            [source, dest, second].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}", secondDestinationRoot: second)
        let plan = try service.plan(sourcePaths: [source], options: options)
        #expect(plan.items.first?.sidecarPath != nil)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: (dest as NSString).appendingPathComponent("a.xmp")))
        #expect(FileManager.default.fileExists(
            atPath: (second as NSString).appendingPathComponent("a.xmp")))
    }

    @Test("已导入校验和命中 → 计划阶段跳过（不重复占盘）")
    func existingChecksumSkipsDuplicate() throws {
        let source = try makeSource(["dup.CR3"], contents: ["dup.CR3": "dup-payload"])
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let path = (source as NSString).appendingPathComponent("dup.CR3")
        let sum = try service.checksum(path)
        let plan = try service.plan(
            sourcePaths: [source],
            options: IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}"),
            existingChecksums: [sum: "existing-photo"])
        #expect(plan.items.isEmpty)
        #expect(plan.skipped.count == 1)
    }

    @Test("RAW+JPEG 共享侧车：第二张不因源侧车已被第一张移走而假失败")
    func sharedSidecarDoesNotFakeFailure() throws {
        let source = try makeSource(["a.CR3", "a.JPG"], contents: ["a.CR3": "raw", "a.JPG": "jpg"])
        let sidecar = (source as NSString).appendingPathComponent("a.xmp")
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecar))
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        let plan = try service.plan(sourcePaths: [source], options: options)
        #expect(plan.items.count == 2)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        #expect(result.copied.count == 2)
        #expect(FileManager.default.fileExists(
            atPath: (dest as NSString).appendingPathComponent("a.xmp")))
    }

    @Test("{seq} 模板下 RAW+JPEG 共享侧车仍只复制一份，目标侧车复用第一张")
    func sharedSidecarWithSequenceTemplate() throws {
        let source = try makeSource(["a.CR3", "a.JPG"], contents: ["a.CR3": "raw", "a.JPG": "jpg"])
        let sidecar = (source as NSString).appendingPathComponent("a.xmp")
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecar))
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(destinationRoot: dest, renameTemplate: "{seq}.{ext}")
        let plan = try service.plan(sourcePaths: [source], options: options)
        #expect(plan.items.count == 2)
        #expect(Set(plan.items.compactMap(\.destSidecarOverride)).count == 1)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        let xmps = try FileManager.default.contentsOfDirectory(atPath: dest)
            .filter { $0.hasSuffix(".xmp") }
        #expect(xmps.count == 1, "共享侧车不能在目标端分裂成两份")
    }

    @Test("目标已有不同内容 → 冲突，执行时跳过且绝不覆盖")
    func conflictIsNotOverwritten() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "new"])
        let dest = try makeDestination()
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: dest)
        }
        let existing = (dest as NSString).appendingPathComponent("a.CR3")
        try Data("old".utf8).write(to: URL(fileURLWithPath: existing))

        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        let plan = try service.plan(sourcePaths: [source], options: options)
        #expect(plan.conflictCount == 1)

        let result = service.execute(plan, options: options)
        #expect(result.copied.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")
    }

    @Test("目标是同内容 → 计划阶段直接跳过（幂等重跑）")
    func identicalDestinationIsSkipped() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "same"])
        let dest = try makeDestination()
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: dest)
        }
        let existing = (dest as NSString).appendingPathComponent("a.CR3")
        try Data("same".utf8).write(to: URL(fileURLWithPath: existing))

        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let plan = try service.plan(
            sourcePaths: [source],
            options: IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        )
        #expect(plan.items.isEmpty)
        #expect(plan.skipped.count == 1)
    }
}
