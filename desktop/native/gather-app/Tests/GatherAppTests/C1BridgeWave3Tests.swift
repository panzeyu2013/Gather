// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave3Tests.swift
// Wave3 / task-18 回归测试：变体级 C1 写回（脚本契约/报告解析/降级）、color tag 双向映射、
// C1 Session 三目录识别与去重规划、Hot Folder 能力边界（不假装检测）。
//
// Wave5 / task-11（2026-11-11，Batch1 C1 写回正确性）增补：
//   · R1 写前回读变体数（variantCountReadScript / parseVariantCounts /
//     partitionVariantTargets + "多变体跳过不写 ack"的报告结构断言）；
//   · R3 notFound 按唯一父目录 browse 后重试一次（browseScript + 两个行为用例：
//     切集合后写回成功、browse 失败保留 notFound 且不写 ack）；
//   · R12 select 前先 deselect（脚本文本断言；行为侧在 Wave4b 套件）。
//
// 全程不 spawn osascript（注入 CaptureOneBridge.appleScriptRunner），不连真 C1；
// 目录识别用注入的目录列举接缝，不碰真实文件系统（R3 用例建临时目录，测完即删——
// browse 重试要求照片与父目录真实存在）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication
@testable import GatherHost
@testable import GatherUI
import GatherTestSupport

// MARK: - 写回脚本契约（G4/G5）

@Suite("C1BridgeWave3 变体级写回脚本契约（G4/G5）")
struct C1BridgeWave3ScriptContractTests {
    private func script(_ items: [C1VariantWritebackItem]) -> String {
        CaptureOneBridge.variantWritebackScript(appName: "Capture One", items: items)
    }

    @Test("路径→多 variant 展开：按 image.path 匹配，目标 variant 优先已 pick，否则 position 1")
    func expandsPathToVariants() {
        let script = script([
            C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 3, colorTag: 1, pick: true),
        ])
        #expect(script.contains("every image of targetDoc whose path is \"/shoot/a.cr2\""))
        #expect(script.contains("variants of theImage"))
        #expect(script.contains("if pick of v then set targetVariant to v"))
        #expect(script.contains("variant 1 of theImage"))
    }

    @Test("只写目标 variant 的属性；不写关键词、不调 reload metadata")
    func writesOnlyTargetVariantProperties() {
        let script = script([
            C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 4, colorTag: 4, pick: true),
        ])
        #expect(script.contains("set rating of targetVariant to 4"))
        #expect(script.contains("set color tag of targetVariant to 4"))
        #expect(script.contains("set pick of targetVariant to true"))
        // G4：pick/reject 用 C1 原生布尔位表达，绝不写关键词污染词库。
        #expect(!script.contains("apply keyword"))
        #expect(!script.contains("culling:keep"))
        // 写的是 catalog 本身，不触发 reload metadata（会把盘上旧 XMP 读回覆盖）。
        #expect(!script.contains("reload metadata"))
    }

    /// A3：C1 只有布尔 pick、没有 reject 位。写回**只表达 keep**：
    /// reject（false 旧口径）与 unreviewed 都不写 pick，保留 C1 现值。
    @Test("A3：reject/unreviewed 不写 pick（C1 无 reject 位，keep-only）")
    func writesPickOnlyForKeep() {
        let rejectScript = script([
            C1VariantWritebackItem(photoPath: "/shoot/r.cr2", rating: 0, colorTag: 0, pick: false),
        ])
        #expect(!rejectScript.contains("set pick"))
        let unreviewedScript = script([
            C1VariantWritebackItem(photoPath: "/shoot/u.cr2", rating: 2, colorTag: 1, pick: nil),
        ])
        #expect(!unreviewedScript.contains("set pick"))
        #expect(unreviewedScript.contains("set rating of targetVariant to 2"))
    }

    @Test("unreviewed 不写 pick；rating 越界钳制；非法 color tag 回落 None(0)")
    func clampsAndSkipsUnreviewedPick() {
        let script = script([
            C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 9, colorTag: 8, pick: nil),
        ])
        #expect(script.contains("set rating of targetVariant to 5"))
        #expect(script.contains("set color tag of targetVariant to 0"))
        #expect(!script.contains("set pick of targetVariant"))
    }

    // MARK: - Wave5 / R1：写前回读变体数（只读）

    @Test("R1：写前回读脚本只读 variant 数量（不改属性、不写关键词、不 reload）")
    func variantCountReadScriptIsReadOnly() {
        let script = CaptureOneBridge.variantCountReadScript(
            appName: "Capture One", paths: ["/shoot/a.cr2"])
        // 与写回脚本同一套路径匹配口径（variant 没有 path，经 parent image 反查）。
        // 注意：回读脚本是**一次循环**读全部路径（路径在 repeat 列表里，不是逐条内联
        // 到 whose 子句），因此断言"列表里有该路径 + 循环体按路径匹配"。
        #expect(script.contains("repeat with p in {\"/shoot/a.cr2\"}"))
        #expect(script.contains("every image of targetDoc whose path is p"))
        #expect(script.contains("count of (variants of theImage)"))
        // 只读：绝不写入任何属性/关键词，也不 reload（回读不能改 C1）。
        #expect(!script.contains("set rating of"))
        #expect(!script.contains("set color tag of"))
        #expect(!script.contains("set pick of"))
        #expect(!script.contains("apply keyword"))
        #expect(!script.contains("reload metadata"))
    }

    @Test("R1：回读报告解析：行数=请求数、只接受非负整数，其它形状 nil")
    func parsesVariantCounts() {
        #expect(CaptureOneBridge.parseVariantCounts("1\n0\n3", expected: 3) == [1, 0, 3])
        #expect(CaptureOneBridge.parseVariantCounts(" 2 \n", expected: 1) == [2])
        // 行数不等 / 非整数 / 负数都是契约漂移：nil（调用方抛 C1_SCRIPT_FAILED，不盲写）。
        #expect(CaptureOneBridge.parseVariantCounts("1", expected: 2) == nil)
        #expect(CaptureOneBridge.parseVariantCounts("1\nx", expected: 2) == nil)
        #expect(CaptureOneBridge.parseVariantCounts("1\n-1", expected: 2) == nil)
    }

    @Test("R1 分区：0→不在集合、1→唯一目标可写、多 variant→整条跳过（绝不猜目标）")
    func partitionsVariantTargets() {
        let items = [
            C1VariantWritebackItem(photoPath: "/a.cr2", rating: 1, colorTag: 0, pick: nil),
            C1VariantWritebackItem(photoPath: "/b.cr2", rating: 2, colorTag: 1, pick: true),
            C1VariantWritebackItem(photoPath: "/c.cr2", rating: 3, colorTag: 2, pick: nil),
        ]
        let partition = CaptureOneBridge.partitionVariantTargets(items: items, counts: [1, 3, 0])
        #expect(partition.writable.map(\.photoPath) == ["/a.cr2"])
        #expect(partition.multiVariant == ["/b.cr2"])
        #expect(partition.notFound.map(\.photoPath) == ["/c.cr2"])
    }

    // MARK: - Wave5 / R3：browse 切集合（sdef:678-684）

    @Test("R3：browse 脚本按 sdef 契约（document 直接参数 + to path），失败回 error: 报告")
    func browseScriptMatchesBrowseCommand() {
        let script = CaptureOneBridge.browseScript(
            appName: "Capture One", path: "/Volumes/Shoot/2026")
        // sdef:678-684：browse 的直接参数是 document，folder 走具名参数 "to path"。
        #expect(script.contains("current document"))
        #expect(script.contains("browse targetDoc to path \"/Volumes/Shoot/2026\""))
        // 失败必须写成 error: 报告（调用方据此记 warn，不吞错）。
        #expect(script.contains("error:"))
    }
}

// MARK: - 写回报告解析 + 降级

private struct Wave3AckState { var ids: [String] = [] }

/// 写前回读脚本里 `repeat with p in {路径, 路径…}` 的请求条目数。
///
/// 为什么不能数 `whose path is`：回读脚本是**一次循环**读全部路径（只有一处 whose
/// 子句，路径在 repeat 列表），写回脚本才是逐条内联。按列表里的逗号数推断即可
///（测试路径不含逗号；逗号在 AppleScript 字面量里才会出现，测试不构造这种路径）。
private func wave3CountScriptPathCount(_ script: String) -> Int {
    guard let start = script.range(of: "repeat with p in {"),
          let end = script.range(of: "}", range: start.upperBound..<script.endIndex) else {
        return 0
    }
    return script[start.upperBound..<end.lowerBound].split(separator: ",").count
}

private func makeWave3Bridge(
    ack: LockedBox<Wave3AckState>,
    // R1（Wave5）：写前回读脚本的回复；默认每条请求都是单 variant（"1" × N）。
    countLines: @escaping @Sendable (String) -> String = { script in
        String(repeating: "1\n", count: wave3CountScriptPathCount(script))
    },
    scriptOutput: @escaping @Sendable (String) throws -> String
) -> CaptureOneBridge {
    CaptureOneBridge(
        recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
        appleScriptRunner: { script in
            if script.contains("System Events") { return "Capture One" }
            // R1 写前回读：必须是只读的变体数脚本（写回脚本没有这个表达式）。
            if script.contains("count of (variants of theImage)") { return countLines(script) }
            // R3 切集合默认成功（需要真实目录的用例自己注入 browse 脚本回复）。
            if script.contains("browse targetDoc to path") { return "1" }
            return try scriptOutput(script)
        })
}

/// R3 用例需要真实存在的目录与照片：browse 重试只对"文件在盘上、父目录唯一"生效。
private func makeWave3PhotoDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-wave5-c1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeWave3Directory(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch { }
}

@Suite("C1BridgeWave3 写回报告与降级")
struct C1BridgeWave3WritebackTests {
    @Test("报告解析：行数必须等于请求条目数、每行只能是 1/0")
    func parsesReport() {
        #expect(CaptureOneBridge.parseVariantWritebackReport("1\n0", expected: 2) == ["1", "0"])
        #expect(CaptureOneBridge.parseVariantWritebackReport(" 1 \n 0 ", expected: 2) == ["1", "0"])
        #expect(CaptureOneBridge.parseVariantWritebackReport("1", expected: 2) == nil)
        #expect(CaptureOneBridge.parseVariantWritebackReport("1\nx", expected: 2) == nil)
    }

    @Test("A1：全部命中才写 durable reload-ack")
    func writesAndAcksOnlyWhenFullyWritten() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack) { _ in "1\n1" }
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [
                C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 3, colorTag: 1, pick: true),
                C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 0, colorTag: 0, pick: nil),
            ])
        #expect(report.written == 2)
        #expect(report.notFound.isEmpty)
        #expect(report.skipped == 0)
        #expect(ack.lock.withLock { ack.ids } == ["s1"])
    }

    /// A1 回归：部分成功**不得**写 ack（旧实现 written>0 即 ack，会让 confirm/finalize 在
    /// C1 仍显示旧值时推进并清理备份）。
    @Test("A1：部分 notFound 不写 reload-ack（门禁保持锁定）")
    func partialWritebackDoesNotAck() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack) { _ in "1\n0" }
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [
                C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 3, colorTag: 1, pick: true),
                C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 0, colorTag: 0, pick: nil),
            ])
        #expect(report.written == 1)
        #expect(report.notFound == ["/shoot/b.cr2"])
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    /// A1 回归：超单次上限被跳过（skipped>0）同样不解门禁。
    @Test("A1：超上限 skipped 不写 reload-ack")
    func skippedItemsDoNotAck() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack) { _ in
            (0..<CaptureOneBridge.maxVariantWritebackItems)
                .map { _ in "1" }
                .joined(separator: "\n")
        }
        let items = (0...CaptureOneBridge.maxVariantWritebackItems).map { index in
            C1VariantWritebackItem(
                photoPath: "/shoot/p\(index).cr2", rating: 1, colorTag: 0, pick: nil)
        }
        let report = try await bridge.writeVariantJudgements(sessionId: "s1", items: items)
        #expect(report.written == CaptureOneBridge.maxVariantWritebackItems)
        #expect(report.skipped == 1)
        #expect(report.notFound.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("无 sessionId 不写 ack；非法路径进 notFound；脚本失败上浮")
    func degradesOnErrors() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack) { _ in "1" }
        let noAck = try await bridge.writeVariantJudgements(
            sessionId: nil,
            items: [C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 0, colorTag: 0, pick: nil)])
        #expect(noAck.written == 1)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)

        let invalid = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [C1VariantWritebackItem(photoPath: "relative/a.cr2", rating: 0, colorTag: 0, pick: nil)])
        #expect(invalid.written == 0)
        #expect(invalid.notFound == ["relative/a.cr2"])
        #expect(ack.lock.withLock { ack.ids }.isEmpty)

        let failing = makeWave3Bridge(ack: ack) { _ in
            throw CaptureOneBridgeError.scriptFailed("Can't set rating of variant")
        }
        do {
            _ = try await failing.writeVariantJudgements(
                sessionId: "s1",
                items: [C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 3, colorTag: 0, pick: nil)])
            Issue.record("脚本失败必须上浮，由 UI 退回 XMP 通道")
        } catch let error as CaptureOneBridgeError {
            #expect(error == .scriptFailed("Can't set rating of variant"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }

    @Test("报告行数与请求不符 → C1_SCRIPT_FAILED（保留原文诊断）")
    func rejectsMalformedReport() async {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack) { _ in "1" }
        do {
            _ = try await bridge.writeVariantJudgements(
                sessionId: "s1",
                items: [
                    C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 1, colorTag: 0, pick: nil),
                    C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 1, colorTag: 0, pick: nil),
                ])
            Issue.record("报告形状不符必须当脚本失败")
        } catch let error as CaptureOneBridgeError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("期望 scriptFailed，实际 \(error)")
                return
            }
            #expect(message.contains("unexpected variant writeback report"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }

    // MARK: - Wave5 / R1：多变体不猜目标

    /// R1 的核心回归：同一 image 有多个 variant 时**不写**（写错 variant 不可逆），
    /// 进 skippedMultiVariant，并且不写 durable reload-ack（门禁保持锁定）。
    @Test("R1：多 variant 跳过（不猜目标）且不写 reload-ack；单 variant 照常写")
    func multiVariantIsSkippedWithoutAck() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(
            ack: ack,
            countLines: { _ in "1\n3\n" }
        ) { _ in "1" }
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [
                C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 4, colorTag: 0, pick: nil),
                C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 4, colorTag: 0, pick: nil),
            ])
        #expect(report.written == 1)
        #expect(report.skippedMultiVariant == ["/shoot/b.cr2"])
        #expect(report.notFound.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty,
                "有请求未写进 C1（多变体跳过）时不得解除 reload-ack 门禁")
    }

    /// 全部都是多变体：一次写回脚本都不发，报告只有 skippedMultiVariant。
    @Test("R1：全部多变体时不发写回脚本（只回报告）")
    func allMultiVariantSkipsWriteScript() async throws {
        let ack = LockedBox(Wave3AckState())
        let scripts = LockedBox(Wave3ScriptLog())
        let bridge = CaptureOneBridge(
            recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
            appleScriptRunner: { script in
                scripts.lock.withLock { scripts.scripts.append(script) }
                if script.contains("System Events") { return "Capture One" }
                if script.contains("count of (variants of theImage)") { return "2\n2\n" }
                return "1\n1"
            })
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [
                C1VariantWritebackItem(photoPath: "/shoot/a.cr2", rating: 2, colorTag: 0, pick: nil),
                C1VariantWritebackItem(photoPath: "/shoot/b.cr2", rating: 2, colorTag: 0, pick: nil),
            ])
        #expect(report.written == 0)
        #expect(report.skippedMultiVariant == ["/shoot/a.cr2", "/shoot/b.cr2"])
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
        let all = scripts.lock.withLock { scripts.scripts }
        #expect(!all.contains { $0.contains("set rating of targetVariant") },
                "多 variant 时不得发出写回脚本")
    }

    /// R1 失败面：拿不到变体数 = 无法安全判定目标 → 上浮 C1_SCRIPT_FAILED，绝不盲写。
    @Test("R1：写前回读失败上浮（不盲写、不写 ack）")
    func variantCountFailurePropagates() async {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeWave3Bridge(ack: ack, countLines: { _ in "not-a-count" }) { _ in "1" }
        do {
            _ = try await bridge.writeVariantJudgements(
                sessionId: "s1",
                items: [C1VariantWritebackItem(
                    photoPath: "/shoot/a.cr2", rating: 1, colorTag: 0, pick: nil)])
            Issue.record("回读形状不认识必须当脚本失败（不能盲写 variant）")
        } catch let error as CaptureOneBridgeError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("期望 scriptFailed，实际 \(error)")
                return
            }
            #expect(message.contains("unexpected variant count report"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    // MARK: - Wave5 / R3：notFound → browse 唯一父目录后重试一次

    /// R3 的核心回归：照片在盘上、父目录唯一、C1 当前集合不含它 → browse 切集合后
    /// **重读一次变体数**再写回（用户点一次写回就能跨集合生效）。
    @Test("R3：notFound 按唯一父目录 browse 后重写一次（成功写 + ack）")
    func browsesToParentDirectoryAndWrites() async throws {
        let directory = try makeWave3PhotoDirectory()
        defer { removeWave3Directory(directory) }
        let paths = [directory.appendingPathComponent("a.cr2").path,
                     directory.appendingPathComponent("b.cr2").path]
        for path in paths {
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        }
        let ack = LockedBox(Wave3AckState())
        let logs = LockedBox(Wave3ScriptLog())
        let bridge = CaptureOneBridge(
            recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
            appleScriptRunner: { script in
                logs.lock.withLock { logs.scripts.append(script) }
                if script.contains("System Events") { return "Capture One" }
                if script.contains("browse targetDoc to path") { return "1" }
                if script.contains("count of (variants of theImage)") {
                    // 第一次（切换前）两张都不在当前集合；browse 后回读为单 variant。
                    let call = logs.lock.withLock { () -> Int in
                        logs.countCalls += 1
                        return logs.countCalls
                    }
                    return call == 1 ? "0\n0\n" : "1\n1\n"
                }
                return "1\n1"
            })
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: paths.map {
                C1VariantWritebackItem(photoPath: $0, rating: 4, colorTag: 0, pick: nil)
            })
        #expect(report.written == 2)
        #expect(report.notFound.isEmpty)
        #expect(ack.lock.withLock { ack.ids } == ["s1"])
        let scripts = logs.lock.withLock { logs.scripts }
        #expect(scripts.contains {
            $0.contains("browse targetDoc to path \"\(directory.path)\"")
        }, "切集合必须指向 notFound 的唯一父目录")
    }

    /// R3 失败面：browse 失败**不吞错** —— 不切集合、不重读、不写 ack，notFound 如实上报。
    @Test("R3：browse 失败保留 notFound（不吞错、不写 ack）")
    func browseFailureKeepsNotFound() async throws {
        let directory = try makeWave3PhotoDirectory()
        defer { removeWave3Directory(directory) }
        let path = directory.appendingPathComponent("a.cr2").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        let ack = LockedBox(Wave3AckState())
        let logs = LockedBox(Wave3ScriptLog())
        let bridge = CaptureOneBridge(
            recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
            appleScriptRunner: { script in
                logs.lock.withLock { logs.scripts.append(script) }
                if script.contains("System Events") { return "Capture One" }
                if script.contains("browse targetDoc to path") { return "error:Can't browse folder" }
                if script.contains("count of (variants of theImage)") { return "0\n" }
                return "1"
            })
        let report = try await bridge.writeVariantJudgements(
            sessionId: "s1",
            items: [C1VariantWritebackItem(photoPath: path, rating: 3, colorTag: 0, pick: nil)])
        #expect(report.written == 0)
        #expect(report.notFound == [path])
        #expect(report.skippedMultiVariant.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
        let scripts = logs.lock.withLock { logs.scripts }
        #expect(scripts.contains { $0.contains("browse targetDoc to path") })
        // browse 已经报错，不得再发写回脚本（没有目标可写）。
        #expect(!scripts.contains { $0.contains("set rating of targetVariant") })
    }
}

/// Wave5 用例的脚本记录器（LockedBox 的动态成员只能映射到 State 的具名属性）。
private struct Wave3ScriptLog {
    var scripts: [String] = []
    var countCalls = 0
}

// MARK: - color tag 双向映射

@Suite("C1BridgeWave3 color tag 双向映射")
struct C1BridgeWave3ColorTagTests {
    @Test("0…7 双向可逆；越界返回 nil；none 不落进 Optional.none")
    func mappingIsReversible() {
        let labels: [CaptureOneColorLabel] = [.none, .red, .orange, .yellow, .green, .blue, .pink, .purple]
        for (raw, label) in labels.enumerated() {
            #expect(C1ColorTagMapping.label(for: raw) == label)
            #expect(C1ColorTagMapping.rawValue(for: label) == raw)
            #expect(C1ColorTagMapping.isReversible(raw))
        }
        // 关键回归：0 必须映射到 .none 而不是 nil（Optional.none 陷阱）。
        #expect(C1ColorTagMapping.label(for: 0) == CaptureOneColorLabel.none)
        #expect(C1ColorTagMapping.label(for: 8) == nil)
        #expect(C1ColorTagMapping.label(for: -1) == nil)
    }
}

// MARK: - A3：pick/reject 往返（keep-only 约定）

@Suite("C1BridgeWave3 pick 往返（A3 keep-only）")
struct C1BridgeWave3PickRoundTripTests {
    @Test("写回只表达 keep：picked→true；reject/unreviewed→nil（不写）")
    func writesKeepOnly() {
        #expect(C1PickMapping.pickToWrite(for: .picked) == true)
        #expect(C1PickMapping.pickToWrite(for: .rejected) == nil)
        #expect(C1PickMapping.pickToWrite(for: .unreviewed) == nil)
    }

    @Test("往返：keep 可逆；reject 不写回 C1，读回只能是 unreviewed（不误杀）")
    func roundTripKeepsOnly() {
        // keep：写 true → 读回 picked（可逆）。
        let keep = C1PickMapping.pickToWrite(for: .picked)
        #expect(keep == true)
        #expect(C1PickMapping.pickState(from: keep ?? false) == .picked)
        // reject：不写 → C1 保持原值；即使读到 false 也只能当 unreviewed。
        #expect(C1PickMapping.pickToWrite(for: .rejected) == nil)
        #expect(C1PickMapping.pickState(from: false) == .unreviewed)
        // 与导入侧同一事实源（Wave2 mapPick 委托 C1PickMapping）。
        #expect(C1ImportJudgementMapping.mapPick(true) == .picked)
        #expect(C1ImportJudgementMapping.mapPick(false) == .unreviewed)
    }
}

// MARK: - C1 Session 三目录识别（G6）

private func wave3Lister(_ tree: [String: [String]]) -> C1SessionDirectoryResolver.DirectoryLister {
    { path in tree[path] }
}

@Suite("C1BridgeWave3 Session 三目录识别（G6）")
struct C1BridgeWave3SessionDirectoryTests {
    private static let sessionRoot = "/Volumes/Shoot/2026-11-11 Wedding"

    private var tree: [String: [String]] {
        [
            Self.sessionRoot: ["Capture", "Selects", "Trash", "Output"],
            Self.sessionRoot + "/Capture": ["A.CR2", "B.CR2"],
            Self.sessionRoot + "/Selects": ["a.cr2", "C.CR2"],
            Self.sessionRoot + "/Trash": ["D.CR2"],
        ]
    }

    @Test("识别根目录：Capture/Selects/Trash 角色、扫描根 = Capture、排除清单")
    func recognizesSessionRoot() throws {
        let layout = try #require(C1SessionDirectoryResolver.detect(
            root: Self.sessionRoot, listDirectory: wave3Lister(tree)))
        #expect(layout.isCaptureOneSession)
        #expect(layout.root == Self.sessionRoot)
        #expect(layout.capture == Self.sessionRoot + "/Capture")
        #expect(layout.selects == Self.sessionRoot + "/Selects")
        #expect(layout.trash == Self.sessionRoot + "/Trash")
        #expect(layout.scanRoot == Self.sessionRoot + "/Capture")
        #expect(layout.excludedPaths == [
            Self.sessionRoot + "/Trash",
            Self.sessionRoot + "/Selects",
        ])
        #expect(layout.role(of: Self.sessionRoot + "/Capture/A.CR2") == .capture)
        #expect(layout.role(of: Self.sessionRoot + "/Selects/a.cr2") == .selects)
        #expect(layout.role(of: Self.sessionRoot + "/Trash/D.CR2") == .trash)
        #expect(layout.role(of: Self.sessionRoot) == .root)
        #expect(layout.role(of: "/elsewhere/x.cr2") == .other)
    }

    @Test("传入 Capture 子目录（session.sourcePath 常见形态）也能上溯识别")
    func recognizesCaptureSubdirectory() throws {
        let layout = try #require(C1SessionDirectoryResolver.detect(
            root: Self.sessionRoot + "/Capture", listDirectory: wave3Lister(tree)))
        #expect(layout.root == Self.sessionRoot)
        #expect(layout.scanRoot == Self.sessionRoot + "/Capture")
    }

    @Test("普通目录/不可读目录不识别（保持旧的目录导入行为）")
    func ignoresPlainDirectories() {
        #expect(C1SessionDirectoryResolver.detect(
            root: "/tmp/plain", listDirectory: wave3Lister(["/tmp/plain": ["sub"]])) == nil)
        #expect(C1SessionDirectoryResolver.detect(
            root: "/tmp/missing", listDirectory: wave3Lister([:])) == nil)
    }

    @Test("目录名大小写不敏感（C1 首字母大写，用户可能重命名）")
    func matchesCaseInsensitively() throws {
        let root = "/tmp/session-lower"
        let lister = wave3Lister([root: ["capture", "selects", "trash"]])
        let layout = try #require(C1SessionDirectoryResolver.detect(root: root, listDirectory: lister))
        #expect(layout.capture == root + "/capture")
        #expect(layout.scanRoot == root + "/capture")
    }

    // A5：两条导入入口（导入文件夹 / 新建工作区）共用同一规划。
    @Test("A5 importPlan：Session 根 → 扫描根 Capture；普通目录 → nil")
    func importPlanRedirectsSessionRoot() throws {
        let plan = try #require(C1SessionDirectoryResolver.importPlan(
            root: Self.sessionRoot, listDirectory: wave3Lister(tree)))
        #expect(plan.originalRoot == Self.sessionRoot)
        #expect(plan.layout.root == Self.sessionRoot)
        #expect(plan.scanRoot == Self.sessionRoot + "/Capture")
        #expect(plan.scansCaptureOnly)
        #expect(plan.layout.isCaptureOneSession)
        #expect(C1SessionDirectoryResolver.importPlan(
            root: "/tmp/plain", listDirectory: wave3Lister(["/tmp/plain": ["sub"]])) == nil)
    }

    @Test("A5 importPlan：传入 Capture 子目录也能上溯，扫描根仍是 Capture")
    func importPlanAcceptsCaptureSubdirectory() throws {
        let capture = Self.sessionRoot + "/Capture"
        let plan = try #require(C1SessionDirectoryResolver.importPlan(
            root: capture, listDirectory: wave3Lister(tree)))
        #expect(plan.originalRoot == capture)
        #expect(plan.layout.root == Self.sessionRoot)
        #expect(plan.scanRoot == capture)
        #expect(plan.scansCaptureOnly)
    }

    // P2（Wave4b）：dedupe helper 已删除（Selects 不入扫描根，无需同名去重），
    // 原用例随实现删除；importPlan 用例已覆盖"只扫 Capture"的核心承诺。
}

// MARK: - 能力边界 / 默认降级

@Suite("C1BridgeWave3 能力边界")
struct C1BridgeWave3CapabilityTests {
    @Test("Hot Folder 不可检测：不假装已检测（G12）")
    func hotFolderIsUndetectable() {
        #expect(C1HotFolderCaveat.canDetect == false)
        #expect(!C1HotFolderCaveat.undetectedReason.isEmpty)
    }

    @Test("未接线的实现返回 unsupported（UI 明确退回 XMP 写回），不抛错")
    func unwiredBridgeDegrades() async throws {
        let report = try await Wave3StubBridge().writeVariantJudgements(
            sessionId: "s1",
            items: [C1VariantWritebackItem(photoPath: "/a.cr2", rating: 1, colorTag: 0, pick: true)])
        #expect(report.written == 0)
        #expect(report.unsupportedReason != nil)
    }
}

/// 只实现协议必备成员的最小桥（writeVariantJudgements 走协议扩展默认实现）。
/// 用 struct（无状态）：Sendable 由编译器隐式满足，不需要 @unchecked。
private struct Wave3StubBridge: CaptureOneBridging {
    func selectedPhotoPaths() async throws -> [String] { [] }
    func reloadMetadata(sessionId: String) async throws {}
    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("stub") }
    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: false, appRunning: false, automationAuthorized: false,
            documentOpen: false, timedOut: false)
    }
    nonisolated static func documentProbeScript(appName: String) -> String { "stub:" + appName }
}

// MARK: - Wave5 batch6 / R6：淘汰的红标约定（C1 无 reject 位）

/// 红标脚本里每条路径一个内联块 → 用 "every image of targetDoc whose path is" 计数。
private func wave6RedScriptPathCount(_ script: String) -> Int {
    script.components(separatedBy: "every image of targetDoc whose path is").count - 1
}

/// 红标写回的桥：runner 按脚本种类分流（红标脚本也含 variant 数判断，必须先识别）。
private func makeRejectedColorTagBridge(
    ack: LockedBox<Wave3AckState>,
    scripts: LockedBox<Wave3ScriptLog>? = nil,
    countLines: @escaping @Sendable (String) -> String = { script in
        String(repeating: "1\n", count: wave3CountScriptPathCount(script))
    },
    browseSucceeds: Bool = true,
    reportLines: (@Sendable (String) -> String)? = nil
) -> CaptureOneBridge {
    CaptureOneBridge(
        recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
        appleScriptRunner: { script in
            if let scripts { scripts.lock.withLock { scripts.scripts.append(script) } }
            if script.contains("System Events") { return "Capture One" }
            if script.contains("browse targetDoc to path") {
                return browseSucceeds ? "1" : "error:browse failed"
            }
            // 红标脚本必须先于回读脚本识别：它里面也有 count of (variants of theImage)。
            if script.contains("set color tag of (variant 1 of theImage)") {
                if let reportLines { return reportLines(script) }
                return String(repeating: "1\n", count: wave6RedScriptPathCount(script))
            }
            if script.contains("count of (variants of theImage)") { return countLines(script) }
            return "1"
        })
}

@Suite("C1BridgeWave6 淘汰红标：脚本契约与报告")
struct C1BridgeWave6RejectedColorTagScriptTests {
    @Test("脚本只改色标为红（raw 1）：不写 pick/rating/关键词、不 reload、不写 culling 关键词")
    func scriptWritesOnlyRedColorTag() {
        let script = CaptureOneBridge.rejectedColorTagScript(
            appName: "Capture One", paths: ["/shoot/a.cr2"])
        #expect(script.contains("every image of targetDoc whose path is \"/shoot/a.cr2\""))
        #expect(script.contains("set color tag of (variant 1 of theImage) to 1"))
        // 只写色标：其它判断一律不碰（C1 无 reject 位，红标是唯一的淘汰表达）。
        #expect(!script.contains("set pick"))
        #expect(!script.contains("set rating"))
        #expect(!script.contains("apply keyword"))
        #expect(!script.contains("culling:"))
        #expect(!script.contains("reload metadata"))
        // 多变体防御：写入瞬间不是单 variant 就报 "2"（不猜目标）。
        #expect(script.contains("if (count of (variants of theImage)) is 1 then"))
    }

    @Test("红色 raw 值来自 C1ColorTagMapping（唯一事实源，不硬编码魔法数）")
    func redRawValueComesFromMapping() {
        #expect(C1ColorTagMapping.rawValue(for: .red) == 1)
        let script = CaptureOneBridge.rejectedColorTagScript(
            appName: "Capture One", paths: ["/shoot/a.cr2"])
        #expect(script.contains("to \(C1ColorTagMapping.rawValue(for: .red))"))
    }

    @Test("报告解析：只接受 0/1/2；行数必须等于请求数")
    func parsesReport() {
        #expect(CaptureOneBridge.parseRejectedColorTagReport("1\n0\n2", expected: 3) == ["1", "0", "2"])
        #expect(CaptureOneBridge.parseRejectedColorTagReport(" 1 \n 2 ", expected: 2) == ["1", "2"])
        #expect(CaptureOneBridge.parseRejectedColorTagReport("1", expected: 2) == nil)
        #expect(CaptureOneBridge.parseRejectedColorTagReport("1\nx", expected: 2) == nil)
        #expect(CaptureOneBridge.parseRejectedColorTagReport("3\n", expected: 1) == nil)
    }

    @Test("分区：0→notFound；1→可写；多 variant→整条跳过（不猜目标）")
    func partitionsTargets() {
        let partition = CaptureOneBridge.partitionRejectedColorTagPaths(
            paths: ["/a.cr2", "/b.cr2", "/c.cr2"], counts: [1, 3, 0])
        #expect(partition.writable == ["/a.cr2"])
        #expect(partition.multiVariant == ["/b.cr2"])
        #expect(partition.notFound == ["/c.cr2"])
        // 回读数量不足按"当前集合里没有"处理（保守，绝不按未知盲写）。
        let short = CaptureOneBridge.partitionRejectedColorTagPaths(
            paths: ["/a.cr2"], counts: [])
        #expect(short.notFound == ["/a.cr2"])
        #expect(short.writable.isEmpty)
    }
}

@Suite("C1BridgeWave6 淘汰红标：写回行为")
struct C1BridgeWave6RejectedColorTagWriteTests {
    @Test("单 variant：全部标红；**不写 reload-ack**（红标不是需要 C1 重载的元数据）")
    func writesAndDoesNotAck() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeRejectedColorTagBridge(ack: ack)
        let report = try await bridge.writeRejectedColorTags(
            paths: ["/shoot/a.cr2", "/shoot/b.cr2"])
        #expect(report.written == 2)
        #expect(report.notFound.isEmpty)
        #expect(report.skippedMultiVariant.isEmpty)
        #expect(report.unsupportedReason == nil)
        #expect(ack.lock.withLock { ack.ids }.isEmpty, "红标不写 reload-ack")
    }

    @Test("多变体：整条跳过、一次写脚本都不发、也不写 ack")
    func multiVariantSkipsWithoutWriting() async throws {
        let ack = LockedBox(Wave3AckState())
        let scripts = LockedBox(Wave3ScriptLog())
        let bridge = makeRejectedColorTagBridge(
            ack: ack, scripts: scripts, countLines: { _ in "2\n2\n" })
        let report = try await bridge.writeRejectedColorTags(
            paths: ["/shoot/a.cr2", "/shoot/b.cr2"])
        #expect(report.written == 0)
        #expect(report.skippedMultiVariant == ["/shoot/a.cr2", "/shoot/b.cr2"])
        let sent = scripts.lock.withLock { scripts.scripts }
        #expect(!sent.contains { $0.contains("set color tag of (variant 1 of theImage)") },
                "多 variant 时不得发出红标写脚本（写错 variant 不可逆）")
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("无淘汰项：空报告、完全不碰 C1（不打任何脚本）")
    func emptyPathsDoNothing() async throws {
        let ack = LockedBox(Wave3AckState())
        let scripts = LockedBox(Wave3ScriptLog())
        let bridge = makeRejectedColorTagBridge(ack: ack, scripts: scripts)
        let report = try await bridge.writeRejectedColorTags(paths: [])
        #expect(report.written == 0)
        #expect(report.notFound.isEmpty)
        #expect(scripts.lock.withLock { scripts.scripts }.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("脚本内防御位 \"2\"（写入瞬间变多 variant）→ 进 skippedMultiVariant，不算 notFound")
    func scriptLevelMultiVariantDefense() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeRejectedColorTagBridge(ack: ack, reportLines: { _ in "2\n" })
        let report = try await bridge.writeRejectedColorTags(paths: ["/shoot/a.cr2"])
        #expect(report.written == 0)
        #expect(report.skippedMultiVariant == ["/shoot/a.cr2"])
        #expect(report.notFound.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("notFound → browse 唯一父目录后重试一次（成功写，仍不写 ack）")
    func browsesToParentDirectoryAndRetries() async throws {
        let directory = try makeWave3PhotoDirectory()
        defer { removeWave3Directory(directory) }
        let paths = ["a.cr2", "b.cr2"].map {
            directory.appendingPathComponent($0).path
        }
        for path in paths {
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        }
        let ack = LockedBox(Wave3AckState())
        let scripts = LockedBox(Wave3ScriptLog())
        let bridge = CaptureOneBridge(
            recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
            appleScriptRunner: { script in
                scripts.lock.withLock { scripts.scripts.append(script) }
                if script.contains("System Events") { return "Capture One" }
                if script.contains("browse targetDoc to path") { return "1" }
                if script.contains("set color tag of (variant 1 of theImage)") {
                    return String(
                        repeating: "1\n", count: wave6RedScriptPathCount(script))
                }
                if script.contains("count of (variants of theImage)") {
                    // 第一次（切换前）都不在当前集合；browse 后回读为单 variant。
                    let call = scripts.lock.withLock { () -> Int in
                        scripts.countCalls += 1
                        return scripts.countCalls
                    }
                    return call == 1 ? "0\n0\n" : "1\n1\n"
                }
                return "1"
            })
        let report = try await bridge.writeRejectedColorTags(paths: paths)
        #expect(report.written == 2)
        #expect(report.notFound.isEmpty)
        let sent = scripts.lock.withLock { scripts.scripts }
        #expect(sent.contains { $0.contains("browse targetDoc to path \"\(directory.path)\"") },
                "切集合必须指向 notFound 的唯一父目录")
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("相对路径进 notFound（不 fallback）；报告形状漂移 → C1_SCRIPT_FAILED")
    func degradesOnBadInputAndContractDrift() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeRejectedColorTagBridge(ack: ack)
        let invalid = try await bridge.writeRejectedColorTags(paths: ["relative/a.cr2"])
        #expect(invalid.written == 0)
        #expect(invalid.notFound == ["relative/a.cr2"])

        let malformed = makeRejectedColorTagBridge(ack: ack, reportLines: { _ in "1\n1\n" })
        do {
            _ = try await malformed.writeRejectedColorTags(paths: ["/shoot/a.cr2"])
            Issue.record("报告行数与请求不符必须当脚本失败，不能猜")
        } catch let error as CaptureOneBridgeError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("期望 scriptFailed，实际 \(error)")
                return
            }
            #expect(message.contains("unexpected rejected color tag report"))
        }
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("超单次上限：只写上限内、其余进 skipped（不静默丢，也不写 ack）")
    func overLimitIsSkipped() async throws {
        let ack = LockedBox(Wave3AckState())
        let bridge = makeRejectedColorTagBridge(ack: ack)
        let paths = (0...CaptureOneBridge.maxVariantWritebackItems).map { "/shoot/p\($0).cr2" }
        let report = try await bridge.writeRejectedColorTags(paths: paths)
        #expect(report.written == CaptureOneBridge.maxVariantWritebackItems)
        #expect(report.skipped == 1)
        #expect(report.notFound.isEmpty)
        #expect(report.skippedMultiVariant.isEmpty)
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }
}

// MARK: - Wave5 batch7（A2/R5）：C1 判断随导入的统一入口

private func wave7Judgement(_ path: String, rating: Int = 3) -> C1VariantJudgement {
    C1VariantJudgement(photoPath: path, rating: rating, colorTag: 1, pick: true, keywords: ["kw"])
}

private func wave7Snapshot(
    _ paths: [String],
    judgements: [C1VariantJudgement],
    malformedLines: Int = 0
) -> C1SelectionSnapshot {
    C1SelectionSnapshot(
        paths: paths, judgements: judgements, malformedLines: malformedLines)
}

/// 纯逻辑套件：协调器不持 DB/桥，全闭包注入（快照/路径/调度都可替身）。
@Suite("C1BridgeWave7 判断随导入统一入口（A2/R5）")
@MainActor
struct C1ImportCoordinatorTests {
    private final class Recorder: @unchecked Sendable {
        struct Applied: Equatable {
            let sessionId: String
            let paths: [String]
        }
        var applied: [Applied] = []
    }

    @Test("菜单语义（expectedPaths=nil）：返回快照路径；建库后按该集合调度一次")
    func menuSemanticsSchedulesOnce() async throws {
        let recorder = Recorder()
        let a = "/shoot/a.cr2"
        let b = "/shoot/b.cr2"
        let coordinator = C1ImportCoordinator(
            snapshotProvider: {
                wave7Snapshot([a, b], judgements: [wave7Judgement(a), wave7Judgement(b)])
            },
            fallbackPathProvider: { [] },
            scheduleApply: { sessionId, judgements in
                recorder.applied.append(.init(
                    sessionId: sessionId, paths: judgements.map(\.photoPath)))
            })
        let paths = try await coordinator.capturePaths()
        #expect(paths == [a, b])
        coordinator.finishCreate(sessionId: "s1", paths: paths)
        #expect(recorder.applied == [.init(sessionId: "s1", paths: [a, b])])
        // 同一路径集合只消费一次：重复 finishCreate 不得重复落库/重复历史。
        coordinator.finishCreate(sessionId: "s1", paths: paths)
        #expect(recorder.applied.count == 1)
        coordinator.reset()
    }

    @Test("入口已给路径（Dashboard/深链）：返回入口路径，只保留相交判断")
    func expectedPathsAreAuthoritative() async throws {
        let recorder = Recorder()
        let a = "/shoot/a.cr2"
        let b = "/shoot/b.cr2"
        let coordinator = C1ImportCoordinator(
            snapshotProvider: {
                wave7Snapshot([a, b], judgements: [wave7Judgement(a), wave7Judgement(b, rating: 5)])
            },
            fallbackPathProvider: { [] },
            scheduleApply: { sessionId, judgements in
                recorder.applied.append(.init(
                    sessionId: sessionId, paths: judgements.map(\.photoPath)))
            })
        // 入口只导入 a：判断也只应用 a（快照里多出来的 b 不得越界落到别的会话）。
        let paths = try await coordinator.capturePaths(expectedPaths: [a])
        #expect(paths == [a])
        coordinator.finishCreate(sessionId: "s2", paths: paths)
        #expect(recorder.applied == [.init(sessionId: "s2", paths: [a])])
        // 未暂存的路径集合（b）没有可落判断：不调度。
        coordinator.finishCreate(sessionId: "s3", paths: [b])
        #expect(recorder.applied.count == 1)
    }

    @Test("入口路径为空：返回空且不暂存（由调用方决定是否导入）")
    func emptyExpectedPathsAreNoOp() async throws {
        let recorder = Recorder()
        let coordinator = C1ImportCoordinator(
            snapshotProvider: { wave7Snapshot(["/shoot/a.cr2"], judgements: []) },
            fallbackPathProvider: { [] },
            scheduleApply: { sessionId, _ in
                recorder.applied.append(.init(sessionId: sessionId, paths: []))
            })
        let paths = try await coordinator.capturePaths(expectedPaths: [])
        #expect(paths.isEmpty)
        coordinator.finishCreate(sessionId: "s1", paths: [])
        #expect(recorder.applied.isEmpty)
    }

    @Test("快照失败：退回 fallback 路径 + C1_JUDGEMENTS_UNAVAILABLE；导入照常（不抛）")
    func snapshotFailureFallsBackToPaths() async throws {
        let recorder = Recorder()
        final class Box: @unchecked Sendable {
            var posted: String?
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.captureOneError, object: nil, queue: nil
        ) { notification in
            box.posted = notification.object as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let fallback = "/shoot/fallback.cr2"
        let coordinator = C1ImportCoordinator(
            snapshotProvider: { throw CaptureOneBridgeError.scriptFailed("boom") },
            fallbackPathProvider: { [fallback] },
            scheduleApply: { sessionId, judgements in
                recorder.applied.append(.init(
                    sessionId: sessionId, paths: judgements.map(\.photoPath)))
            })
        let paths = try await coordinator.capturePaths()
        #expect(paths == [fallback])
        #expect(box.posted == GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE.rawValue)
        // 降级导入没有判断数据可落：不调度、不报错。
        coordinator.finishCreate(sessionId: "s1", paths: paths)
        #expect(recorder.applied.isEmpty)
    }

    @Test("快照与 fallback 都失败：抛出（由调用方决定是否继续导入）")
    func bothProvidersFailThrows() async {
        let coordinator = C1ImportCoordinator(
            snapshotProvider: { throw CaptureOneBridgeError.scriptFailed("snapshot") },
            fallbackPathProvider: { throw CaptureOneBridgeError.notRunning },
            scheduleApply: { _, _ in
                Issue.record("失败路径不得调度判断落库")
            })
        do {
            _ = try await coordinator.capturePaths()
            Issue.record("快照与 fallback 都失败时必须抛出（不能静默返回空路径）")
        } catch let error as CaptureOneBridgeError {
            guard case .notRunning = error else {
                Issue.record("期望 fallback 的 notRunning 上浮，实际 \(error)")
                return
            }
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }
}
