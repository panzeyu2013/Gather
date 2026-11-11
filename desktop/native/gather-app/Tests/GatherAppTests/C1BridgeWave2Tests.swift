// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave2Tests.swift
// Wave2 / task-11（G3）回归测试：C1 变体级判断的只读脚本契约、解析与降级、
// C1→Gather 映射表、落库（photo_metadata_cache / culling_decisions / 关键词索引），
// 以及 AppImport 的 afterCreate 钩子（顺序 / 异常不冒泡）。
//
// 全程不 spawn osascript（注入 CaptureOneBridge.appleScriptRunner），不碰真实 C1；
// 落库用例用内存 SQLite（GatherTestSupport.makeTestDB），与生产同一套 Repo/SQL。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherApplication
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

// MARK: - 脚本契约

@Suite("C1BridgeWave2 脚本契约（G3）")
struct C1BridgeWave2ScriptContractTests {
    @Test("判断读取脚本：application 级 selected variants + parent image.path + 四个 variant 属性")
    func judgementScriptUsesSdefSurface() {
        let script = CaptureOneBridge.selectedVariantJudgementsScript(appName: "Capture One")
        // sdef: selected variants 在 application（CaptureOne.sdef:244-247）。
        #expect(script.contains("selected variants"))
        #expect(script.contains("parent image of v"))
        // rating/color tag/pick 是 variant 属性（:1097/:1096/:1084）；关键词经 keyword.name（:966）。
        #expect(script.contains("rating of v as text"))
        #expect(script.contains("color tag of v as text"))
        #expect(script.contains("pick of v"))
        #expect(script.contains("keywords of v"))
        #expect(script.contains("name of k"))
        // 行式记录 + TAB 字段分隔 + 反斜杠转义（路径/关键词可含任意字符）。
        #expect(script.contains("escapeField"))
        #expect(script.contains("& tab &"))
        #expect(script.contains("& linefeed"))
        // 失败必须上浮（导入侧据此降级为仅文件导入），不允许 on error 吞成空串。
        #expect(!script.contains("on error"))
    }
}

// MARK: - 解析（纯函数）

@Suite("C1BridgeWave2 判断解析（纯函数）")
struct C1BridgeWave2ParsingTests {
    @Test("标准输出：P 行字段 + 紧随其后的 W 行关键词")
    func parsesStandardRecords() {
        let output = [
            "P/shoot/a.cr2\tR3\tT1\tK1",
            "W婚礼",
            "WWedding|Ceremony",
            "P/shoot/b b.cr2\tR0\tT9\tK0",
        ].joined(separator: "\n")
        let parsed = CaptureOneBridge.parseVariantJudgements(output)
        #expect(parsed.malformedLines.isEmpty)
        #expect(parsed.judgements.count == 2)
        guard parsed.judgements.count == 2 else { return }
        #expect(parsed.judgements[0].photoPath == "/shoot/a.cr2")
        #expect(parsed.judgements[0].rating == 3)
        #expect(parsed.judgements[0].colorTag == 1)
        #expect(parsed.judgements[0].pick)
        #expect(parsed.judgements[0].keywords == ["婚礼", "Wedding|Ceremony"])
        #expect(parsed.judgements[1].photoPath == "/shoot/b b.cr2")
        #expect(parsed.judgements[1].colorTag == 9)
        #expect(!parsed.judgements[1].pick)
    }

    @Test("转义字段：反斜杠 / 换行 / 回车 / TAB 按脚本 escapeField 的规则还原")
    func parsesEscapedFields() {
        // 原始输出里是字面量反斜杠序列：\t → TAB、\n → 换行、\\ → 单个反斜杠。
        let output = [
            "P/shoot/a\\tb\\\\c\\nd.cr2\tR2\tT0\tK0",
            "Wtag\\twith\\ttab",
        ].joined(separator: "\n")
        let parsed = CaptureOneBridge.parseVariantJudgements(output)
        #expect(parsed.malformedLines.isEmpty)
        guard let judgement = parsed.judgements.first else {
            Issue.record("应解析出 1 条判断")
            return
        }
        #expect(judgement.photoPath == "/shoot/a\tb\\c\nd.cr2")
        #expect(judgement.keywords == ["tag\twith\ttab"])
    }

    @Test("同一 parent image 的多个 variant 各自成条（合并在应用层）")
    func keepsMultipleVariantsPerPath() {
        let output = [
            "P/shoot/a.cr2\tR1\tT1\tK0",
            "P/shoot/a.cr2\tR5\tT4\tK1",
        ].joined(separator: "\n")
        let parsed = CaptureOneBridge.parseVariantJudgements(output)
        #expect(parsed.judgements.count == 2)
        #expect(parsed.judgements.map(\.rating) == [1, 5])
        #expect(parsed.judgements.map(\.pick) == [false, true])
    }

    @Test("畸形行跳过并计数：缺字段 / 数字非法 / 未知前缀 / W 行没有 P 记录")
    func skipsMalformedLines() {
        let output = [
            "Worphan",
            "Ponly-path",
            "P/shoot/bad\tRabc\tT0\tK0",
            "Xwhat",
            "P/shoot/good.cr2\tR4\tT2\tK1",
            "Wok",
        ].joined(separator: "\n")
        let parsed = CaptureOneBridge.parseVariantJudgements(output)
        #expect(parsed.malformedLines.count == 4)
        #expect(parsed.judgements.count == 1)
        #expect(parsed.judgements.first?.photoPath == "/shoot/good.cr2")
        #expect(parsed.judgements.first?.keywords == ["ok"])
    }

    @Test("rating 越界按 0…5 钳制；空输出无条目")
    func clampsRatingAndHandlesEmpty() {
        let parsed = CaptureOneBridge.parseVariantJudgements("P/shoot/a.cr2\tR9\tT0\tK0")
        #expect(parsed.judgements.first?.rating == 5)
        let empty = CaptureOneBridge.parseVariantJudgements("")
        #expect(empty.judgements.isEmpty)
        #expect(empty.malformedLines.isEmpty)
    }
}

// MARK: - 选中快照（注入 AppleScript 运行器）

private func makeWave2Bridge(
    scriptOutput: @escaping @Sendable (String) throws -> String
) -> CaptureOneBridge {
    CaptureOneBridge(
        recordReloadAck: { _ in },
        appleScriptRunner: { script in
            if script.contains("System Events") { return "Capture One" }
            return try scriptOutput(script)
        })
}

@Suite("C1BridgeWave2 选中快照（G3）")
struct C1BridgeWave2SnapshotTests {
    @Test("只保留存在且绝对路径的条目；畸形行被忽略；同路径多 variant 保留多条判断")
    func buildsSnapshotFromExistingPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
        let a = directory.appendingPathComponent("gather-c1-\(UUID().uuidString).cr2").path
        let b = directory.appendingPathComponent("gather-c1-\(UUID().uuidString) 中文.cr2").path
        #expect(FileManager.default.createFile(atPath: a, contents: Data()))
        #expect(FileManager.default.createFile(atPath: b, contents: Data()))
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }
        let output = [
            "P\(a)\tR3\tT1\tK1",
            "W婚礼",
            "P\(a)\tR2\tT0\tK0",
            "P\(b)\tR0\tT2\tK0",
            "P/definitely/not/exists.cr2\tR5\tT5\tK1",
            "malformed-line",
        ].joined(separator: "\n")
        let bridge = makeWave2Bridge { _ in output }
        let snapshot = try await bridge.selectedVariantSnapshot()
        #expect(snapshot.paths == [a, b])
        #expect(snapshot.judgements.count == 3)
        let forA = snapshot.judgements.filter { $0.photoPath == a }.map(\.rating)
        #expect(forA == [3, 2])
        #expect(snapshot.judgements.first?.keywords == ["婚礼"])
    }

    @Test("脚本失败上浮（调用方负责降级为仅文件导入），不返回伪造空快照")
    func scriptFailureThrows() async {
        let bridge = makeWave2Bridge { _ in
            throw CaptureOneBridgeError.scriptFailed("Can't get keywords of variant")
        }
        do {
            _ = try await bridge.selectedVariantSnapshot()
            Issue.record("脚本失败必须上抛，由导入侧降级")
        } catch let error as CaptureOneBridgeError {
            #expect(error == .scriptFailed("Can't get keywords of variant"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }
}
// MARK: - 映射表

@Suite("C1BridgeWave2 映射表（C1 → Gather）")
struct C1BridgeWave2MappingTests {
    @Test("color tag 0…7 按 C1 UI 顺序映射；越界返回 nil（不猜）")
    func mapsColorTags() {
        let expected: [CaptureOneColorLabel] = [.none, .red, .orange, .yellow, .green, .blue, .pink, .purple]
        for (raw, label) in expected.enumerated() {
            #expect(C1ImportJudgementMapping.mapColorTag(raw) == label)
        }
        #expect(C1ImportJudgementMapping.mapColorTag(8) == nil)
        #expect(C1ImportJudgementMapping.mapColorTag(-1) == nil)
    }

    @Test("pick 映射：true=keep，false=unreviewed（不臆造淘汰）")
    func mapsPickWithoutInventingRejects() {
        #expect(C1ImportJudgementMapping.mapPick(true) == .picked)
        #expect(C1ImportJudgementMapping.mapPick(false) == .unreviewed)
        #expect(C1ImportJudgementMapping.decisionValue(true) == .keep)
        #expect(C1ImportJudgementMapping.decisionValue(false) == .pending)
    }

    @Test("多 variant 合并：rating 取最大、pick 取 or、色标取首个非 None、关键词并集、路径归一")
    func mergesVariantsPerPath() {
        let judgements = [
            C1VariantJudgement(photoPath: "/shoot/./a.cr2", rating: 2, colorTag: 0, pick: false, keywords: ["婚礼"]),
            C1VariantJudgement(photoPath: "/shoot/a.cr2", rating: 9, colorTag: 4, pick: true, keywords: ["婚礼", "精选"]),
            C1VariantJudgement(photoPath: "/shoot/b.cr2", rating: 0, colorTag: 8, pick: false, keywords: []),
        ]
        let merged = C1ImportJudgementMapping.merge(judgements)
        #expect(merged.count == 2)
        #expect(merged[0].photoPath == "/shoot/a.cr2")
        #expect(merged[0].rating == 5)
        #expect(merged[0].pick)
        #expect(merged[0].colorTag == .green)
        #expect(merged[0].keywords == ["婚礼", "精选"])
        #expect(merged[1].photoPath == "/shoot/b.cr2")
        #expect(merged[1].colorTag == nil)
    }
}

// MARK: - 落库（内存 SQLite）

private struct Wave2JudgementFixture {
    let db: DBConnection
    let sessionId: String
    let photoIds: [String]
    let cache: MetadataCacheRepo
    let decisions: CullingDecisionRepo
    let keywordRepo: KeywordRepo
    let service: C1ImportJudgementService

    init() throws {
        let db = try makeTestDB()
        let session = try SessionRepo(connection: db).create(name: "wave2-c1", source: "capture-one")
        let photoRepo = PhotoRepo(connection: db)
        let added = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: ["/shoot/a.cr2", "/shoot/b.cr2"].map {
                PhotoAddInput(filepath: $0, width: 10, height: 10)
            },
            "capture-one")
        let cache = MetadataCacheRepo(connection: db)
        let decisions = CullingDecisionRepo(connection: db)
        let keywordRepo = KeywordRepo(connection: db)
        self.db = db
        self.sessionId = session.id
        self.photoIds = added.ids
        self.cache = cache
        self.decisions = decisions
        self.keywordRepo = keywordRepo
        self.service = C1ImportJudgementService(
            photos: photoRepo,
            cache: cache,
            decisions: decisions,
            keywordIndex: KeywordIndexSync(index: keywordRepo, metadata: cache),
            transactions: db)
    }

    /// 两条判断 + 一条找不到的照片 + 一条越界色标。
    func judgements() -> [C1VariantJudgement] {
        [
            C1VariantJudgement(photoPath: "/shoot/a.cr2", rating: 4, colorTag: 1, pick: true, keywords: ["婚礼", "精选"]),
            C1VariantJudgement(photoPath: "/shoot/b.cr2", rating: 0, colorTag: 2, pick: false, keywords: ["Wedding|Ceremony"]),
            C1VariantJudgement(photoPath: "/shoot/missing.cr2", rating: 5, colorTag: 9, pick: true, keywords: ["x"]),
        ]
    }
}

@Suite("C1BridgeWave2 落库（photo_metadata_cache / culling_decisions / 关键词索引）")
struct C1BridgeWave2ApplyTests {
    @Test("apply：写缓存投影、imported 决策与层级关键词索引；找不到的照片计数为 missing")
    func appliesJudgementsToTables() throws {
        let fixture = try Wave2JudgementFixture()
        let report = try fixture.service.apply(sessionId: fixture.sessionId, judgements: fixture.judgements())
        #expect(report.applied == 2)
        #expect(report.missing == 1)
        #expect(report.ratings == 1)
        #expect(report.labels == 2)
        #expect(report.keeps == 1)
        #expect(report.keywords == 2)
        #expect(report.unmappedColorTags == 1)
        #expect(report.errors.isEmpty)

        let idA = fixture.photoIds[0]
        let idB = fixture.photoIds[1]
        let cacheRowA = try fixture.cache.get(idA)
        let cacheA = try #require(cacheRowA)
        #expect(cacheA.rating == 4)
        #expect(cacheA.label == "Red")
        #expect(cacheA.keywords == ["婚礼", "精选"])
        let cacheRowB = try fixture.cache.get(idB)
        let cacheB = try #require(cacheRowB)
        #expect(cacheB.rating == 0) // C1 rating 0 = 未评级，不覆盖
        #expect(cacheB.label == "Orange")

        let decisionRowA = try fixture.decisions.getDecision(
            sessionId: fixture.sessionId, photoId: idA)
        let decisionA = try #require(decisionRowA)
        #expect(decisionA.decision == "keep")
        #expect(decisionA.decisionSource == CullingDecisionSource.imported.rawValue)
        #expect(decisionA.rating == 4)
        #expect(decisionA.colorLabel == "Red")
        // 未 pick 的照片不写决策行：C1 的 pick=false 是默认值，写 imported 决策会让
        // isHumanDecision 把它当成人工已决策（AI 初审永远无法覆盖，属真回归）。
        #expect(try fixture.decisions.getDecision(sessionId: fixture.sessionId, photoId: idB) == nil)

        #expect(try fixture.keywordRepo.photoKeywordPaths(photoId: idA) == ["婚礼", "精选"])
        #expect(try fixture.keywordRepo.photoKeywordPaths(photoId: idB) == ["Wedding|Ceremony"])
        // 层级索引：父级也被物化（facet/词库树依赖父行）。
        #expect(try fixture.keywordRepo.keyword(path: "Wedding") != nil)
    }

    @Test("重复 apply 幂等：不重复插关键词行、决策 revision 递增")
    func applyIsIdempotent() throws {
        let fixture = try Wave2JudgementFixture()
        _ = try fixture.service.apply(sessionId: fixture.sessionId, judgements: fixture.judgements())
        let second = try fixture.service.apply(sessionId: fixture.sessionId, judgements: fixture.judgements())
        #expect(second.applied == 2)
        #expect(try fixture.keywordRepo.photoKeywordPaths(photoId: fixture.photoIds[0]).count == 2)
        let decisionRow = try fixture.decisions.getDecision(
            sessionId: fixture.sessionId, photoId: fixture.photoIds[0])
        let decision = try #require(decisionRow)
        #expect(decision.revision == 2)
    }

    @Test("人工决策优先：C1 导入不再覆盖人工星级 / 越权改决策")
    func preservesManualDecisions() throws {
        let fixture = try Wave2JudgementFixture()
        let idA = fixture.photoIds[0]
        _ = try fixture.service.apply(sessionId: fixture.sessionId, judgements: fixture.judgements())
        // 模拟用户在 Gather 里手动改成 5 星/绿标/keep（镜像列同事务同值）。
        try fixture.cache.updateRating(photoId: idA, rating: 5)
        try fixture.cache.updateLabel(photoId: idA, label: CaptureOneColorLabel.green.rawValue)
        try fixture.decisions.upsertState(
            sessionId: fixture.sessionId,
            photoId: idA,
            groupId: "",
            state: CullingDecisionStateInput(
                decision: CullingDecisionValue.keep.rawValue,
                rating: 5,
                colorLabel: CaptureOneColorLabel.green.rawValue,
                revision: 9,
                source: CullingDecisionSource.manual.rawValue))
        let report = try fixture.service.apply(sessionId: fixture.sessionId, judgements: fixture.judgements())
        #expect(report.preservedManualDecisions == 1)
        #expect(try fixture.cache.get(idA)?.rating == 5)
        #expect(try fixture.cache.get(idA)?.label == CaptureOneColorLabel.green.rawValue)
        #expect(try fixture.decisions.getDecision(sessionId: fixture.sessionId, photoId: idA)?.decisionSource
            == CullingDecisionSource.manual.rawValue)
    }

    @Test("applyAfterIndexing：扫描终态后才写；超时也落库并标记 timedOut")
    func waitsForScanWithTimeoutFallback() async throws {
        let fixture = try Wave2JudgementFixture()
        // 1) 扫描已终态：不等待、不超时。
        let done = await fixture.service.applyAfterIndexing(
            sessionId: fixture.sessionId,
            judgements: fixture.judgements(),
            scanStatus: { _ in AnalysisJobStatus.succeeded.rawValue },
            pollInterval: .milliseconds(10),
            timeout: .seconds(1),
            sleep: { _ in })
        #expect(!done.indexingTimedOut)
        #expect(!done.waitedForIndexing)
        #expect(done.applied == 2)

        // 2) 永远 running：超时降级（判断仍落库）。
        let timedOut = await fixture.service.applyAfterIndexing(
            sessionId: fixture.sessionId,
            judgements: fixture.judgements(),
            scanStatus: { _ in AnalysisJobStatus.running.rawValue },
            pollInterval: .milliseconds(10),
            timeout: .milliseconds(20),
            sleep: { _ in })
        #expect(timedOut.indexingTimedOut)
        #expect(timedOut.waitedForIndexing)
        #expect(timedOut.applied == 2)

        // 3) 先 running 后 succeeded：等到终态。
        let sequence = LockedBox(Wave2ScanSequence(statuses: [
            AnalysisJobStatus.running.rawValue,
            AnalysisJobStatus.succeeded.rawValue,
        ]))
        let waited = await fixture.service.applyAfterIndexing(
            sessionId: fixture.sessionId,
            judgements: fixture.judgements(),
            scanStatus: { _ in sequence.lock.withLock {
                sequence.statuses.isEmpty ? AnalysisJobStatus.succeeded.rawValue : sequence.statuses.removeFirst()
            } },
            pollInterval: .milliseconds(10),
            timeout: .seconds(1),
            sleep: { _ in })
        #expect(waited.waitedForIndexing)
        #expect(!waited.indexingTimedOut)
        #expect(waited.applied == 2)
    }

    @Test("空判断：不写任何表，isEmpty")
    func emptyJudgementsIsNoOp() throws {
        let fixture = try Wave2JudgementFixture()
        let report = try fixture.service.apply(sessionId: fixture.sessionId, judgements: [])
        #expect(report.isEmpty)
        #expect(try fixture.cache.get(fixture.photoIds[0]) == nil)
    }
}

private struct Wave2ScanSequence { var statuses: [String] }
// MARK: - 判断快照队列 + 导入钩子 + 新错误码

@Suite("C1BridgeWave2 判断快照队列（C1PendingJudgements）")
@MainActor
struct C1BridgeWave2PendingTests {
    @Test("按归一化路径集合 key：不同文件集不串、take 后清空")
    func keysByCanonicalPathSet() {
        let store = C1PendingJudgements()
        let judgement = C1VariantJudgement(
            photoPath: "/shoot/a.cr2", rating: 1, colorTag: 0, pick: false, keywords: [])
        store.store(["/shoot/a.cr2"], judgements: [judgement])
        #expect(store.take(paths: ["/shoot/b.cr2"]).isEmpty)
        // 等价写法（./、重复/排序）命中同一 key；take 是消费语义。
        #expect(store.take(paths: ["/shoot/./a.cr2"]).count == 1)
        #expect(store.take(paths: ["/shoot/a.cr2"]).isEmpty)
    }
}

private func wave2SessionData(id: String) -> SessionData {
    SessionData(
        id: id,
        name: "C1 导入",
        status: .draft,
        photoCount: 2,
        analysisStatus: .idle,
        writebackStatus: .idle,
        importSource: "capture-one",
        sourcePath: "",
        failedWritebackCount: 0,
        truncatedImport: false,
        createdAt: "2026-11-11T08:00:00.000Z",
        updatedAt: "2026-11-11T08:00:00.000Z")
}

/// 只实现 create/get 的最小 SessionAPI 替身（其余方法显式失败，防误调用）。
private struct Wave2SessionAPIStub: SessionAPI {
    let result: SessionCreateResult

    func list() async throws -> [SessionData] { [] }

    func get(_ sessionId: String) async throws -> SessionData {
        guard sessionId == result.session.id else { throw GatherError(code: .SESSION_NOT_FOUND) }
        return result.session
    }

    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult { result }

    func update(_ input: SessionUpdateParams) async throws -> SessionData {
        throw Self.unsupported("update")
    }

    func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        throw Self.unsupported("delete")
    }

    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        throw Self.unsupported("addPhotos")
    }

    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        throw Self.unsupported("ingest")
    }

    func setSourceRoot(_ input: Confirmed<SessionSetSourceRootInput>) async throws -> SessionData {
        throw Self.unsupported("setSourceRoot")
    }

    func status(_ sessionId: String) async throws -> WorkspaceStatus {
        throw Self.unsupported("status")
    }

    private static func unsupported(_ name: String) -> GatherError {
        .invalidParameter(field: name, reason: "unsupported in test stub")
    }
}

private struct Wave2Events { var names: [String] = [] }
private struct Wave2HookError: Error {}

@Suite("C1BridgeWave2 导入钩子（AppImport afterCreate）")
@MainActor
struct C1BridgeWave2ImportHookTests {
    @Test("afterCreate 在建库后、importCompleted 前调用；其异常不冒泡（导入仍成功）")
    func hookRunsBeforeNotificationAndFailureIsSwallowed() async throws {
        let events = LockedBox(Wave2Events())
        let result = SessionCreateResult(session: wave2SessionData(id: "s-wave2"), added: 2)
        let api = Wave2SessionAPIStub(result: result)
        let completedToken = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importCompleted, object: nil, queue: nil
        ) { _ in
            events.lock.withLock { events.names.append("completed") }
        }
        let failedToken = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importFailed, object: nil, queue: nil
        ) { _ in
            events.lock.withLock { events.names.append("failed") }
        }
        defer {
            NotificationCenter.default.removeObserver(completedToken)
            NotificationCenter.default.removeObserver(failedToken)
        }

        await AppImport.importFiles(
            ["/shoot/a.cr2"],
            sessionAPI: api,
            source: "capture-one",
            sourceLabel: "Capture One 文件",
            l10n: L10n(language: .zhCN),
            afterCreate: { created in
                events.lock.withLock { events.names.append("hook:\(created.session.id)") }
                throw Wave2HookError()
            })

        let names = events.lock.withLock { events.names }
        #expect(names == ["hook:s-wave2", "completed"])
        #expect(!names.contains("failed"))
    }

    @Test("不传钩子：默认路径行为不变（只发 importCompleted）")
    func defaultImportUnchanged() async throws {
        let events = LockedBox(Wave2Events())
        let api = Wave2SessionAPIStub(
            result: SessionCreateResult(session: wave2SessionData(id: "s-plain"), added: 1))
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importCompleted, object: nil, queue: nil
        ) { _ in
            events.lock.withLock { events.names.append("completed") }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await AppImport.importFiles(
            ["/shoot/b.cr2"],
            sessionAPI: api,
            source: "local",
            l10n: L10n(language: .zhCN))
        #expect(events.lock.withLock { events.names } == ["completed"])
    }
}

@Suite("C1BridgeWave2 降级错误码")
struct C1BridgeWave2ErrorCodeTests {
    @Test("C1_JUDGEMENTS_UNAVAILABLE：码值 + 中文文案 + 降级语义（不断言导入失败）")
    func judgementUnavailableCodeIsLocalized() {
        #expect(GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE.rawValue == "C1_JUDGEMENTS_UNAVAILABLE")
        let text = GatherLocalization.errorMessages[GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE.rawValue]
        #expect(text != nil)
        #expect(text?.isEmpty == false)
    }
}
