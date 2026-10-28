// desktop/native/gather-core/Tests/GatherCoreTests/Services/IngestServiceTests.swift
// P1 / D：摄取计划/执行——模板分配、校验、冲突不覆盖、第二目的地。

import Foundation
import Testing
import GatherProtocol
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

    private func recursiveFiles(_ root: String) throws -> [String] {
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                let full = (root as NSString).appendingPathComponent(relative)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir),
                   !isDir.boolValue {
                    files.append(full)
                }
            }
        }
        return files.sorted()
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

    @Test("{seq} 模板下 RAW+JPEG 共享侧车：兄弟共用同一目标 stem，只复制一份侧车")
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
        // 兄弟必须同 stem：侧车按 stem 推导，stem 不同会让第二张解析到不存在的 .xmp，
        // RAW/JPEG 的配对键（stem）也会一起失配。
        #expect(Set(plan.items.map { TSPath.stem($0.destPath) }).count == 1,
                "RAW+JPEG 兄弟必须落在同一目标 stem 上")
        #expect(Set(plan.items.map { TSPath.xmpSidecarPath($0.destPath) }).count == 1,
                "同源侧车的目标路径必须一致")
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty)
        let xmps = try FileManager.default.contentsOfDirectory(atPath: dest)
            .filter { $0.hasSuffix(".xmp") }
        #expect(xmps.count == 1, "共享侧车不能在目标端分裂成两份")
        #expect(result.copied.count == 2)
    }

    @Test("第二目的地撞名：整张回滚，源文件保留且不会同时进 copied 与 failed")
    func secondDestinationConflictRollsBack() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "payload"])
        let dest = try makeDestination()
        let second = try makeDestination()
        defer {
            [source, dest, second].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        // 第二目的地已有同名文件 → 执行阶段失败（计划阶段还没写主副本）。
        let existingSecond = (second as NSString).appendingPathComponent("a.CR3")
        try Data("other".utf8).write(to: URL(fileURLWithPath: existingSecond))
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(
            destinationRoot: dest, renameTemplate: "{orig}.{ext}", secondDestinationRoot: second)
        let plan = try service.plan(sourcePaths: [source], options: options)
        let result = service.execute(plan, options: options)
        #expect(result.failed.count == 1)
        #expect(result.copied.isEmpty, "失败项不得同时进 copied（否则会被登记成幽灵）")
        #expect(result.secondCopied.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: (source as NSString).appendingPathComponent("a.CR3")), "复制模式失败也要保留源")
        #expect(!FileManager.default.fileExists(
            atPath: (dest as NSString).appendingPathComponent("a.CR3")), "主副本必须回滚")
        #expect(try String(contentsOfFile: existingSecond, encoding: .utf8) == "other",
                "既有第二目的地文件不得被覆盖")
    }

    @Test("侧车目标已存在且内容不同：整张失败并回滚，不覆盖既有侧车")
    func sidecarContentConflictRollsBack() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "payload"])
        try Data("<xmp>new</xmp>".utf8).write(
            to: URL(fileURLWithPath: (source as NSString).appendingPathComponent("a.xmp")))
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let existingSidecar = (dest as NSString).appendingPathComponent("a.xmp")
        try Data("<xmp>old</xmp>".utf8).write(to: URL(fileURLWithPath: existingSidecar))
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        let plan = try service.plan(sourcePaths: [source], options: options)
        let result = service.execute(plan, options: options)
        #expect(result.failed.count == 1)
        #expect(result.copied.isEmpty)
        #expect(try String(contentsOfFile: existingSidecar, encoding: .utf8) == "<xmp>old</xmp>",
                "既有侧车不得被覆盖")
        #expect(try String(contentsOfFile: (source as NSString).appendingPathComponent("a.CR3"),
                           encoding: .utf8) == "payload", "失败后源文件必须仍在")
    }

    @Test("默认模板 + 第二目的地 + RAW/JPEG 成对：第二张不假失败，二目的地只有一份侧车")
    func secondDestinationWithSharedSidecar() throws {
        let source = try makeSource(["a.CR3", "a.JPG"], contents: ["a.CR3": "raw", "a.JPG": "jpg"])
        try Data("<xmp/>".utf8).write(
            to: URL(fileURLWithPath: (source as NSString).appendingPathComponent("a.xmp")))
        let dest = try makeDestination()
        let second = try makeDestination()
        defer {
            [source, dest, second].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        // 默认模板就含 {seq:4}，兄弟必然共用目标 stem。
        let options = IngestOptions(destinationRoot: dest, secondDestinationRoot: second)
        let plan = try service.plan(sourcePaths: [source], options: options)
        #expect(plan.items.count == 2)
        let result = service.execute(plan, options: options)
        #expect(result.failed.isEmpty, "共享侧车 + 第二目的地不得让第二张假失败")
        #expect(result.copied.count == 2)
        #expect(result.secondCopied.count == 2)
        let xmps = try recursiveFiles(second).filter { $0.hasSuffix(".xmp") }
        #expect(xmps.count == 1, "第二目的地也只能有一份共享侧车")
    }

    @Test("同一 plan 重复执行：目标已存在时失败，但绝不删除既有文件")
    func reexecuteDoesNotDeleteExistingFile() throws {
        let source = try makeSource(["a.CR3"], contents: ["a.CR3": "payload"])
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let options = IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        let plan = try service.plan(sourcePaths: [source], options: options)
        let first = service.execute(plan, options: options)
        #expect(first.copied.count == 1)
        let second = service.execute(plan, options: options)
        #expect(second.failed.count == 1)
        #expect(second.copied.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.copied[0]),
                "回滚只允许删本张自己产出的文件")
        #expect(try String(contentsOfFile: first.copied[0], encoding: .utf8) == "payload")
    }

    @Test("目录与其内文件同时传入：同一文件只计划一次")
    func dedupesNestedSources() throws {
        let source = try makeSource(["a.CR3", "b.CR3"], contents: [:])
        let dest = try makeDestination()
        defer {
            [source, dest].forEach { try? FileManager.default.removeItem(atPath: $0) }
        }
        let service = IngestService(now: { Date(timeIntervalSince1970: 0) })
        let plan = try service.plan(
            sourcePaths: [source, (source as NSString).appendingPathComponent("a.CR3")],
            options: IngestOptions(destinationRoot: dest, renameTemplate: "{orig}.{ext}")
        )
        #expect(plan.items.count == 2, "枚举结果与显式参数重复时必须去重")
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
