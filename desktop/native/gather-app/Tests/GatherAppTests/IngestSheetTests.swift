// desktop/native/gather-app/Tests/GatherAppTests/IngestSheetTests.swift
// Wave5 batch3（task-19）：导入一次配置 —— 预设持久化 / 结果完整可见 / 摄取后 AI 初审。
//
// 覆盖（不依赖真实 AppBootstrap / 文件系统 / 数据库）：
// 1. IngestPreset 编解码往返；损坏 / 空串 / 旧载荷回退；
// 2. 预设纯逻辑：同名覆盖、上限、删除、字段匹配、最近使用读写；
// 3. 预检 / 结果 DTO 新字段的旧载荷兜底（目标路径 / 冲突源 / 第二目的地计数）；
// 4. 「只重试失败项」的源路径映射（ingest 失败项的 photoId 即源路径）；
// 5. TriageSchedulingSessionAPI：ingest 成功且 registered>0 才调度，失败不调度。
import Foundation
import Testing
@testable import GatherHost
@testable import GatherUI
import GatherProtocol

// MARK: - 夹具：SettingsAPI（只实现预设读写用到的方法）

private final class IngestSettingsStub: SettingsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func all() async throws -> [String: String] {
        lock.withLock { values }
    }

    func get(_ key: SettingsKeyInput) async throws -> String {
        lock.withLock { values[key.value] ?? "" }
    }

    func set(_ input: SettingsSetInput) async throws {
        lock.withLock { values[input.key.value] = input.value.value }
    }

    func reset() async throws -> [String: String] {
        lock.withLock {
            values = [:]
            return values
        }
    }

    func previewReset() async throws -> SettingsResetImpact {
        SettingsResetImpact(preferenceCount: 0, templateCount: 0, batchCount: 0, recipeCount: 0)
    }

    func reset(_ input: Confirmed<SettingsResetInput>) async throws -> SettingsResetResult {
        lock.withLock {
            values = [:]
            return SettingsResetResult(values: [:], resetKeys: [], preservedKeys: [])
        }
    }

    func setLanguage(_ language: InterfaceLanguage) async throws -> InterfaceLanguage {
        language
    }

    func mlStatus() async throws -> MLStatusData {
        throw GatherError.invalidParameter(field: "mlStatus", reason: "stub")
    }
}

// MARK: - 夹具：SessionAPI（只让 ingest 可配置，其余方法视为误调用）

private struct IngestSchedulingSessionStub: SessionAPI {
    var ingestResult: SessionIngestResult
    var previewResult: SessionIngestPreview? = nil
    var ingestShouldThrow: Bool = false

    func list() async throws -> [SessionData] { throw Self.unused() }
    func get(_ sessionId: String) async throws -> SessionData { throw Self.unused() }
    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        throw Self.unused()
    }
    func update(_ input: SessionUpdateParams) async throws -> SessionData { throw Self.unused() }
    func delete(_ input: Confirmed<SessionDeleteInput>) async throws { throw Self.unused() }
    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        throw Self.unused()
    }
    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        if ingestShouldThrow { throw Self.unused() }
        return ingestResult
    }
    func previewIngest(_ input: SessionIngestInput) async throws -> SessionIngestPreview {
        guard let previewResult else { throw Self.unused() }
        return previewResult
    }
    func setSourceRoot(
        _ input: Confirmed<SessionSetSourceRootInput>
    ) async throws -> SessionData { throw Self.unused() }
    func status(_ sessionId: String) async throws -> WorkspaceStatus { throw Self.unused() }

    private static func unused() -> GatherError {
        GatherError.invalidParameter(field: "sessionAPI", reason: "stub only supports ingest")
    }
}

private final class IngestScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        ids.append(sessionId)
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
}

private func makeIngestConfirmed(
    source: String = "/tmp/gather-ingest-preset-source.jpg"
) throws -> Confirmed<SessionIngestInput> {
    let input = try SessionIngestInput(
        sessionId: "s1",
        sourcePaths: [source],
        destinationRoot: "/tmp/gather-ingest-preset-dest")
    return Confirmed(input, source: .test)
}

@Suite("导入预设与摄取结果可见性（Wave5 batch3）")
struct IngestSheetTests {
    // MARK: 预设编解码

    @Test func presetJSONRoundTrip() throws {
        let preset = IngestPreset(
            id: "p1",
            name: "婚礼",
            renameTemplate: "{yyyy}/{MM}/{dd}/{orig}.{ext}",
            secondDestinationRoot: "/Volumes/Backup",
            verifyChecksum: false,
            duplicatePolicy: .coexist,
            metadataTemplateID: "tpl-1")
        let raw = IngestPresetStore.encodePresets([preset])
        #expect(IngestPresetStore.decodePresets(raw) == [preset])
    }

    @Test func corruptAndEmptyPresetPayloadFallsBackToEmpty() {
        #expect(IngestPresetStore.decodePresets("") == [])
        #expect(IngestPresetStore.decodePresets("   ") == [])
        #expect(IngestPresetStore.decodePresets("not json") == [])
        #expect(IngestPresetStore.decodePresets("{}") == [])
    }

    @Test func legacyPresetPayloadFillsDefaults() throws {
        // 旧/手写载荷只有 name：id 自动生成，可选字段回落默认值。
        let raw = #"[{"name":"旧预设"}]"#
        let presets = IngestPresetStore.decodePresets(raw)
        #expect(presets.count == 1)
        #expect(presets[0].name == "旧预设")
        #expect(!presets[0].id.isEmpty)
        #expect(presets[0].verifyChecksum)
        #expect(presets[0].duplicatePolicy == .skip)
        #expect(presets[0].secondDestinationRoot == nil)
    }

    // MARK: 预设纯逻辑

    @Test func upsertReplacesSameNameAndEnforcesLimit() throws {
        let first = IngestPreset(name: "A", renameTemplate: "{orig}.{ext}")
        let updated = IngestPreset(name: "A", renameTemplate: "new/{orig}.{ext}")
        let replaced = try IngestPresetStore.upserting(updated, in: [first])
        #expect(replaced.count == 1)
        #expect(replaced[0].renameTemplate == "new/{orig}.{ext}")

        let full = (0..<IngestPresetStore.maxPresets).map {
            IngestPreset(name: "P\($0)")
        }
        #expect(throws: IngestPresetStoreError.self) {
            _ = try IngestPresetStore.upserting(IngestPreset(name: "extra"), in: full)
        }
        // 同名覆盖在满额时仍允许（不是新增）。
        #expect(try IngestPresetStore.upserting(
            IngestPreset(name: "P0", renameTemplate: "x"), in: full).count
            == IngestPresetStore.maxPresets)
    }

    @Test func removingPresetKeepsOthers() {
        let a = IngestPreset(id: "a", name: "A")
        let b = IngestPreset(id: "b", name: "B")
        #expect(IngestPresetStore.removing(id: "a", from: [a, b]) == [b])
        #expect(IngestPresetStore.removing(id: "missing", from: [a, b]) == [a, b])
    }

    @Test func presetMatchesCurrentFields() {
        let preset = IngestPreset(
            name: "A", renameTemplate: "{orig}.{ext}",
            secondDestinationRoot: nil, verifyChecksum: true, duplicatePolicy: .skip)
        #expect(IngestPresetStore.matches(
            preset, renameTemplate: "{orig}.{ext}", secondDestinationRoot: "",
            verifyChecksum: true, duplicatePolicy: .skip), "nil 与空串语义一致")
        #expect(!IngestPresetStore.matches(
            preset, renameTemplate: "{date}.{ext}", secondDestinationRoot: nil,
            verifyChecksum: true, duplicatePolicy: .skip))
        #expect(!IngestPresetStore.matches(
            preset, renameTemplate: "{orig}.{ext}", secondDestinationRoot: nil,
            verifyChecksum: false, duplicatePolicy: .skip))
    }

    @Test func saveAndLoadPresetsThroughSettingsAPI() async throws {
        let settings = IngestSettingsStub()
        let preset = IngestPreset(id: "p1", name: "客户 A", renameTemplate: "{client}/{orig}.{ext}")
        try await IngestPresetStore.save(
            IngestPresetSnapshot(presets: [preset], lastUsedPresetID: "p1"),
            settings: settings)

        let loaded = await IngestPresetStore.load(settings)
        #expect(loaded.presets == [preset])
        #expect(loaded.lastUsedPresetID == "p1")

        // 最近使用按"存在才回填"：指向已删除 id 时视为未选择。
        try await IngestPresetStore.saveLastUsed("gone", settings: settings)
        let stale = await IngestPresetStore.load(settings)
        #expect(stale.lastUsedPresetID == nil)
        #expect(stale.presets == [preset])
    }

    // MARK: 预检 / 结果 DTO

    @Test func legacyPreviewPayloadDefaultsNewSamplePaths() throws {
        let legacy = #"""
        {"totalCount":3,"newCount":2,"libraryDuplicateCount":1,
         "conflictCount":0,"unreadableCount":0,"policy":"skip"}
        """#
        let preview = try JSONDecoder().decode(
            SessionIngestPreview.self, from: Data(legacy.utf8))
        #expect(preview.targetSamplePaths.isEmpty)
        #expect(preview.conflictSamplePaths.isEmpty)
        #expect(preview.unsupportedFormats.count == 0)
    }

    @Test func previewAndResultSampleFieldsRoundTrip() throws {
        let preview = SessionIngestPreview(
            totalCount: 2, newCount: 1, libraryDuplicateCount: 0,
            conflictCount: 1, unreadableCount: 0, policy: .skip,
            targetSamplePaths: ["/dest/a.CR3"],
            conflictSamplePaths: ["/card/b.CR3"])
        let previewData = try JSONEncoder().encode(preview)
        #expect(try JSONDecoder().decode(SessionIngestPreview.self, from: previewData) == preview)

        let result = SessionIngestResult(
            registered: 1, copiedButUnregistered: [], skipped: [], failed: [],
            secondDestinationCopied: 1)
        let resultData = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(
            SessionIngestResult.self, from: resultData).secondDestinationCopied == 1)
    }

    @Test func legacyResultPayloadDefaultsSecondDestinationCount() throws {
        let legacy = #"""
        {"registered":2,"copiedButUnregistered":[],"skipped":[],"unreadable":[],"failed":[]}
        """#
        let result = try JSONDecoder().decode(
            SessionIngestResult.self, from: Data(legacy.utf8))
        #expect(result.secondDestinationCopied == nil)
        #expect(result.unsupportedFormats == nil)
    }

    @Test func retrySourcePathsUseFailurePhotoIDs() {
        let result = SessionIngestResult(
            registered: 0, copiedButUnregistered: [], skipped: [],
            failed: [
                MetadataApplyFailureDTO(photoId: "/tmp/a.CR3", message: "x", retryable: true),
                MetadataApplyFailureDTO(photoId: "", message: "empty", retryable: true),
                MetadataApplyFailureDTO(photoId: "/tmp/a.CR3", message: "dup", retryable: true),
                MetadataApplyFailureDTO(photoId: "/tmp/b.CR3", message: "y", retryable: false),
            ])
        #expect(IngestPresetStore.retrySourcePaths(from: result) == ["/tmp/a.CR3", "/tmp/b.CR3"])
    }

    // MARK: 摄取后 AI 初审调度

    @Test func ingestSuccessSchedulesTriageOnlyWhenRegistered() async throws {
        let recorder = IngestScheduleRecorder()
        let wrapper = TriageSchedulingSessionAPI(
            base: IngestSchedulingSessionStub(ingestResult: SessionIngestResult(
                registered: 2, copiedButUnregistered: [], skipped: [], failed: [])),
            onIngestSucceeded: { recorder.record($0) })
        _ = try await wrapper.ingest(try makeIngestConfirmed())
        #expect(recorder.recorded == ["s1"])

        let skipped = TriageSchedulingSessionAPI(
            base: IngestSchedulingSessionStub(ingestResult: SessionIngestResult(
                registered: 0, copiedButUnregistered: [], skipped: ["a"], failed: [])),
            onIngestSucceeded: { recorder.record($0) })
        _ = try await skipped.ingest(try makeIngestConfirmed())
        #expect(recorder.recorded == ["s1"], "全被跳过时不重复调度")
    }

    @Test func ingestFailureDoesNotScheduleTriage() async throws {
        let recorder = IngestScheduleRecorder()
        let wrapper = TriageSchedulingSessionAPI(
            base: IngestSchedulingSessionStub(
                ingestResult: SessionIngestResult(
                    registered: 0, copiedButUnregistered: [], skipped: [], failed: []),
                ingestShouldThrow: true),
            onIngestSucceeded: { recorder.record($0) })
        var threw = false
        do {
            _ = try await wrapper.ingest(try makeIngestConfirmed())
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(recorder.recorded.isEmpty, "失败/取消不得调度 AI 初审")
    }

    @Test func previewDelegatesToBaseSession() async throws {
        let preview = SessionIngestPreview(
            totalCount: 1, newCount: 1, libraryDuplicateCount: 0,
            conflictCount: 0, unreadableCount: 0, policy: .skip,
            targetSamplePaths: ["/tmp/dest/a.CR3"])
        let wrapper = TriageSchedulingSessionAPI(
            base: IngestSchedulingSessionStub(
                ingestResult: SessionIngestResult(
                    registered: 0, copiedButUnregistered: [], skipped: [], failed: []),
                previewResult: preview),
            onIngestSucceeded: { _ in })
        let confirmed = try makeIngestConfirmed()
        let received = try await wrapper.previewIngest(confirmed.value)
        #expect(received.targetSamplePaths == ["/tmp/dest/a.CR3"])
    }
}
