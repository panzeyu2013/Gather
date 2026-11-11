// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave3Tests.swift
// Wave3 / task-18 回归测试：变体级 C1 写回（脚本契约/报告解析/降级）、color tag 双向映射、
// C1 Session 三目录识别与去重规划、Hot Folder 能力边界（不假装检测）。
//
// 全程不 spawn osascript（注入 CaptureOneBridge.appleScriptRunner），不连真 C1；
// 目录识别用注入的目录列举接缝，不碰真实文件系统。
import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication
@testable import GatherHost
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
}

// MARK: - 写回报告解析 + 降级

private struct Wave3AckState { var ids: [String] = [] }

private func makeWave3Bridge(
    ack: LockedBox<Wave3AckState>,
    scriptOutput: @escaping @Sendable (String) throws -> String
) -> CaptureOneBridge {
    CaptureOneBridge(
        recordReloadAck: { sessionId in ack.lock.withLock { ack.ids.append(sessionId) } },
        appleScriptRunner: { script in
            if script.contains("System Events") { return "Capture One" }
            return try scriptOutput(script)
        })
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