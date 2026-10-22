// desktop/native/gather-app/Tests/GatherAppTests/APIDuplicateQualityTests.swift
// Cut 1 / B5a：LiveDuplicateAPI（4 方法）与 LiveQualityAPI（2 方法）的行为测试。
//
// 覆盖：
// - duplicate：scan 的 job 建单（dedupeKey/checkpoint 与旧命令面 逐字一致）、
//   活跃 job 去重、终态后新 job、DUPLICATE_SCAN_BUSY 的错误映射；
//   groups 的排序/成员投影；resolve/resolveMember 的 Confirmed<T> 边界与
//   落库结果；参数错误（INVALID_PARAM / DUP_THRESHOLD_INVALID）；
// - quality：analyze 建 qualityScore job 并立即返回、同 dedupeKey 活跃 job
//   复用、缺省 photoIds 的 all/null 形状；results 的“每照片最新一条”与会话
//   过滤；参数错误（空 photoIds、空白 sessionId/photoId）。
//
// 夹具用内存 SQLite + 迁移 + 真实 DuplicateService/QualityService/JobService；
// duplicate.scan / quality.score 的执行器用 stub 替换（真实扫描/解码需要文件
// 系统与图片，本批只断言 API 边界的 job 形状与等待语义）。重复组/质量结果
// 直接按既有表结构种入，避免把服务层用例复制一遍。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具

private enum DuplicateQualityFixtureError: Error {
    case jobNotCreated
}

private struct DuplicateQualityFixture {
    let db: DBConnection
    let sessionId: String
    let jobService: JobService
    let duplicateAPI: LiveDuplicateAPI
    let qualityAPI: LiveQualityAPI

    init(
        duplicateResult: DuplicateScanResult = DuplicateScanResult(
            exactGroups: [], visualGroups: [], totalDuplicates: 0
        ),
        duplicateGate: AsyncGate? = nil,
        duplicateScanBusy: Bool = false,
        qualityGate: AsyncGate? = nil
    ) throws {
        let db = try makeGatherTestDB()
        let session = try SessionRepo(connection: db).create(name: "B5a", source: "test")
        let now = "2026-01-01T00:00:00.000Z"
        for photoId in ["p1", "p2", "p3"] {
            let path = "/shoot/\(photoId).jpg"
            _ = try db.prepare("""
                INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
              """).run([
                .text("af-\(photoId)"), .text(path), .text("\(photoId).jpg"),
                .text(now), .text(now),
            ])
            _ = try db.prepare("""
                INSERT INTO photos (
                  id, session_id, filepath, filename, asset_file_id, width, height,
                  created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, 100, 80, ?, ?)
              """).run([
                .text(photoId), .text(session.id), .text(path), .text("\(photoId).jpg"),
                .text("af-\(photoId)"), .text(now), .text(now),
              ])
        }

        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        jobService.registerExecutor(type: .duplicateScan) { _, _ in
            if duplicateScanBusy { throw DuplicateServiceError.scanBusy }
            if let duplicateGate { await duplicateGate.wait() }
            return duplicateResult
        }
        jobService.registerExecutor(type: .qualityScore) { _, _ in
            if let qualityGate { await qualityGate.wait() }
            return [QualityResult]()
        }
        jobService.start()

        self.db = db
        self.sessionId = session.id
        self.jobService = jobService
        self.duplicateAPI = LiveDuplicateAPI(
            duplicateService: DuplicateService(connection: db),
            jobService: jobService
        )
        self.qualityAPI = LiveQualityAPI(
            qualityService: QualityService(
                photoRepo: PhotoRepo(connection: db),
                connection: db
            ),
            jobService: jobService
        )
    }

    /// 种入一个重复组（成员按传入顺序，id 递增）。
    @discardableResult
    func seedDuplicateGroup(photoIds: [String], type: String = "exact") throws -> Int {
        _ = try db.prepare("""
            INSERT INTO duplicate_groups (
              session_id, group_type, checksum, hash_hex, member_count, resolution, created_at
            ) VALUES (?, ?, 'checksum', NULL, ?, NULL, ?)
          """).run([
            .text(sessionId), .text(type), .int(Int64(photoIds.count)),
            .text("2026-01-01T00:00:00.000Z"),
          ])
        let groupId = Int(db.lastInsertRowid)
        for (index, photoId) in photoIds.enumerated() {
            _ = try db.prepare("""
                INSERT INTO duplicate_group_members (
                  group_id, photo_id, session_id, is_kept, file_size, file_mtime
                ) VALUES (?, ?, ?, 1, ?, ?)
              """).run([
                .int(Int64(groupId)), .text(photoId), .text(sessionId),
                .int(Int64(1000 + index)),
                .text("2026-01-01T00:00:0\(index).000Z"),
            ])
        }
        return groupId
    }

    /// 种入一条 technical_quality 结果（updatedAt 决定 get 的“最新”选择）。
    func seedQualityResult(photoId: String, score: Double, updatedAt: String) throws {
        let assetFileId = "af-\(photoId)"
        let fingerprint = "fp-\(photoId)-\(updatedAt)"
        let payload = try JSONEncoder().encode(QualityResult(
            photoId: photoId,
            assetFileId: assetFileId,
            status: .succeeded,
            qualityScore: score,
            sharpness: score,
            exposure: 1,
            warnings: [],
            modelId: "b5a",
            modelVersion: "1",
            inputFingerprint: fingerprint,
            updatedAt: updatedAt
        ))
        _ = try db.prepare("""
            INSERT INTO asset_analysis (
              photo_id, asset_file_id, analysis_type, result_json, warnings_json,
              model_id, model_version, input_fingerprint, created_at, updated_at
            ) VALUES (?, ?, 'technical_quality', ?, '[]', 'b5a', '1', ?, ?, ?)
          """).run([
            .text(photoId), .text(assetFileId),
            .text(String(decoding: payload, as: UTF8.self)),
            .text(fingerprint), .text("2026-01-01T00:00:00.000Z"), .text(updatedAt),
          ])
    }
}

// MARK: - 等待与错误辅助

/// 等 JobService 出现指定类型的 job（替代固定 sleep）。
private func waitForJob(
    _ jobService: JobService,
    type: AnalysisJobType,
    timeout: TimeInterval = 2
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try jobService.list(includeCheckpoint: false).contains(where: { $0.type == type }) {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DuplicateQualityFixtureError.jobNotCreated
}

private func gatherError<T>(_ body: () throws -> T) -> GatherError? {
    do {
        _ = try body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

private func asyncGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

private func asyncError<T>(_ body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

// MARK: - Duplicate

@Suite("B5a Live Duplicate API")
struct APIDuplicateTests {
    @Test("scan：建 duplicateScan job，dedupeKey/checkpoint 沿用旧命令面")
    func scanCreatesJob() async throws {
        let expected = DuplicateScanResult(
            exactGroups: [], visualGroups: [], totalDuplicates: 2
        )
        let fixture = try DuplicateQualityFixture(duplicateResult: expected)

        let result = try await fixture.duplicateAPI.scan(
            DuplicateScanInput(sessionId: fixture.sessionId, visualThreshold: 8)
        )

        #expect(result == expected)
        let job = try #require(
            try fixture.jobService.list().first { $0.type == .duplicateScan }
        )
        #expect(job.scopeId == fixture.sessionId)
        #expect(job.dedupeKey == "duplicate.scan:\(fixture.sessionId):8.0")
        #expect(job.checkpoint["visualThreshold"]?.numberValue == 8)
    }

    @Test("scan 缺省阈值：dedupeKey 用 default，checkpoint 写 null")
    func scanWithDefaultThreshold() async throws {
        let fixture = try DuplicateQualityFixture()
        _ = try await fixture.duplicateAPI.scan(
            DuplicateScanInput(sessionId: fixture.sessionId)
        )

        let job = try #require(
            try fixture.jobService.list().first { $0.type == .duplicateScan }
        )
        #expect(job.dedupeKey == "duplicate.scan:\(fixture.sessionId):default")
        #expect(job.checkpoint["visualThreshold"] == .null)
    }

    @Test("scan：活跃 job 同参数复用（单飞去重），只建一条 job")
    func scanDedupesActiveJob() async throws {
        let gate = AsyncGate()
        let expected = DuplicateScanResult(
            exactGroups: [], visualGroups: [], totalDuplicates: 1
        )
        let fixture = try DuplicateQualityFixture(
            duplicateResult: expected,
            duplicateGate: gate
        )

        let input = try DuplicateScanInput(
            sessionId: fixture.sessionId,
            visualThreshold: 4
        )
        // 只捕获 Live API（@unchecked Sendable）与 Sendable 输入，避免 Task
        // 闭包连带捕获测试夹具。
        let api = fixture.duplicateAPI
        let first = Task { try await api.scan(input) }
        try await waitForJob(fixture.jobService, type: .duplicateScan)

        let second = Task { try await api.scan(input) }
        // 给第二个 Task 进入 jobService.create（拿到同一活跃 job）并阻塞在
        // waitForResult 的机会；门未放行前第一个 job 不会终态。500ms 是并行
        // 套件调度下的余量（不是断言窗口）。
        try await Task.sleep(for: .milliseconds(500))
        gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == expected)
        #expect(secondResult == expected)
        let jobs = try fixture.jobService.list().filter { $0.type == .duplicateScan }
        #expect(jobs.count == 1)
    }

    @Test("scan：终态 job 不占活跃去重位，同参数再扫创建新 job")
    func scanAfterCompletionCreatesNewJob() async throws {
        let fixture = try DuplicateQualityFixture()
        let input = try DuplicateScanInput(sessionId: fixture.sessionId)
        _ = try await fixture.duplicateAPI.scan(input)
        _ = try await fixture.duplicateAPI.scan(input)

        let jobs = try fixture.jobService.list().filter { $0.type == .duplicateScan }
        #expect(jobs.count == 2)
    }

    @Test("scan：executor 抛 DUPLICATE_SCAN_BUSY 时收敛为同名 GatherError")
    func scanBusyMapsToGatherError() async throws {
        let fixture = try DuplicateQualityFixture(duplicateScanBusy: true)
        let error = await asyncGatherError {
            try await fixture.duplicateAPI.scan(
                DuplicateScanInput(sessionId: fixture.sessionId)
            )
        }
        #expect(error?.code == .DUPLICATE_SCAN_BUSY)
    }

    @Test("groups：按 group_type,id 排序并投影成员文件信息")
    func groupsReadsSeededRows() async throws {
        let fixture = try DuplicateQualityFixture()
        let visualId = try fixture.seedDuplicateGroup(photoIds: ["p3", "p2"], type: "visual")
        let exactId = try fixture.seedDuplicateGroup(photoIds: ["p1", "p2"], type: "exact")

        let groups = try await fixture.duplicateAPI.groups(fixture.sessionId)

        #expect(groups.map(\.id) == [exactId, visualId])
        let exact = try #require(groups.first)
        #expect(exact.groupType == .exact)
        #expect(exact.memberCount == 2)
        #expect(exact.members.map(\.photoId) == ["p1", "p2"])
        #expect(exact.members.first?.filepath == "/shoot/p1.jpg")
    }

    @Test("resolve：Confirmed<DuplicateResolveInput> 驱动 keep_one 落库")
    func resolveThroughConfirmed() async throws {
        let fixture = try DuplicateQualityFixture()
        let groupId = try fixture.seedDuplicateGroup(photoIds: ["p1", "p2"])
        let payload = try DuplicateResolveInput(groupId: groupId, resolution: .keepOne)

        let ok = try await fixture.duplicateAPI.resolve(
            Confirmed(payload, source: .test)
        )

        #expect(ok)
        let group = try #require(
            try await fixture.duplicateAPI.groups(fixture.sessionId).first
        )
        #expect(group.resolution == "keep_one")
        #expect(group.members.filter(\.isKept).count == 1)
    }

    @Test("resolveMember：Confirmed 载荷驱动单成员保留/移除")
    func resolveMemberThroughConfirmed() async throws {
        let fixture = try DuplicateQualityFixture()
        let groupId = try fixture.seedDuplicateGroup(photoIds: ["p1", "p2"])
        let group = try #require(
            try await fixture.duplicateAPI.groups(fixture.sessionId).first
        )
        #expect(group.id == groupId)
        let member = try #require(group.members.first { $0.photoId == "p1" })
        let payload = try DuplicateResolveMemberInput(memberId: member.id, isKept: false)

        let ok = try await fixture.duplicateAPI.resolveMember(
            Confirmed(payload, source: .test)
        )

        #expect(ok)
        let updated = try #require(
            try await fixture.duplicateAPI.groups(fixture.sessionId).first
        )
        let byPhoto = Dictionary(
            uniqueKeysWithValues: updated.members.map { ($0.photoId, $0) }
        )
        #expect(byPhoto["p1"]?.isKept == false)
        #expect(byPhoto["p1"]?.resolution == "keep_one")
    }

    @Test("resolve/resolveMember：不存在的 id 保留域错误（无协议码）")
    func resolveMissingIdsKeepsDomainError() async throws {
        let fixture = try DuplicateQualityFixture()

        let groupError = await asyncError {
            try await fixture.duplicateAPI.resolve(
                Confirmed(
                    try DuplicateResolveInput(groupId: 9999, resolution: .keepAll),
                    source: .test
                )
            )
        }
        #expect((groupError as? DuplicateServiceError) == .groupNotFound(9999))

        let memberError = await asyncError {
            try await fixture.duplicateAPI.resolveMember(
                Confirmed(
                    try DuplicateResolveMemberInput(memberId: 9999, isKept: false),
                    source: .test
                )
            )
        }
        #expect((memberError as? DuplicateServiceError) == .memberNotFound(9999))
    }
}

// MARK: - Quality

@Suite("B5a Live Quality API")
struct APIQualityTests {
    @Test("analyze：建 qualityScore job 并立即返回；同 dedupeKey 活跃 job 复用")
    func analyzeCreatesJobAndDedupes() async throws {
        let gate = AsyncGate()
        let fixture = try DuplicateQualityFixture(qualityGate: gate)
        defer { gate.release() }

        let input = try QualityAnalyzeInput(
            sessionId: fixture.sessionId,
            photoIds: ["p2", "p1"]
        )
        let first = try await fixture.qualityAPI.analyze(input)
        let second = try await fixture.qualityAPI.analyze(input)

        #expect(first.id == second.id)
        let jobs = try fixture.jobService.list().filter { $0.type == .qualityScore }
        #expect(jobs.count == 1)
        let job = try #require(jobs.first)
        #expect(job.scopeId == fixture.sessionId)
        #expect(job.dedupeKey == "quality.score:\(fixture.sessionId):p1,p2")
        #expect(
            job.checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue)
                == ["p2", "p1"]
        )
    }

    @Test("analyze 缺省 photoIds：dedupeKey 用 all，checkpoint 写 null")
    func analyzeDefaultsToAll() async throws {
        let fixture = try DuplicateQualityFixture()
        let job = try await fixture.qualityAPI.analyze(
            try QualityAnalyzeInput(sessionId: fixture.sessionId)
        )

        #expect(job.type == .qualityScore)
        #expect(job.dedupeKey == "quality.score:\(fixture.sessionId):all")
        #expect(job.checkpoint["photoIds"] == .null)
    }

    @Test("results：每照片最新一条，会话/photoIds 过滤")
    func resultsReadsLatestPerPhoto() async throws {
        let fixture = try DuplicateQualityFixture()
        try fixture.seedQualityResult(
            photoId: "p1", score: 0.4, updatedAt: "2026-01-01T00:00:00.000Z"
        )
        try fixture.seedQualityResult(
            photoId: "p1", score: 0.9, updatedAt: "2026-01-02T00:00:00.000Z"
        )
        try fixture.seedQualityResult(
            photoId: "p2", score: 0.5, updatedAt: "2026-01-01T00:00:00.000Z"
        )

        let all = try await fixture.qualityAPI.results(
            QualityGetParams(sessionId: fixture.sessionId)
        )
        #expect(all.count == 2)
        let p1 = try #require(all.first { $0.photoId == "p1" })
        #expect(p1.qualityScore == 0.9)

        let subset = try await fixture.qualityAPI.results(
            QualityGetParams(sessionId: fixture.sessionId, photoIds: ["p1"])
        )
        #expect(subset.map(\.photoId) == ["p1"])

        let empty = try await fixture.qualityAPI.results(
            QualityGetParams(sessionId: fixture.sessionId, photoIds: [])
        )
        #expect(empty.isEmpty)
    }

    @Test("results：未知会话返回空结果（服务层会话过滤）")
    func resultsUnknownSessionIsEmpty() async throws {
        let fixture = try DuplicateQualityFixture()
        let results = try await fixture.qualityAPI.results(
            QualityGetParams(sessionId: "unknown-session")
        )
        #expect(results.isEmpty)
    }
}

// MARK: - 错误路径

@Suite("B5a Duplicate/Quality 参数错误")
struct APIDuplicateQualityValidationTests {
    @Test("Duplicate 输入类型：sessionId/threshold/groupId/memberId 显式失败")
    func duplicateInputsRejectInvalidShapes() {
        let blankSession = gatherError {
            try DuplicateScanInput(sessionId: "  ", visualThreshold: 8)
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")

        let badThreshold = gatherError {
            try DuplicateScanInput(sessionId: "s", visualThreshold: 65)
        }
        #expect(badThreshold?.code == .DUP_THRESHOLD_INVALID)
        #expect(badThreshold?.params["field"] == "visualThreshold")

        let negativeGroup = gatherError {
            try DuplicateResolveInput(groupId: -1, resolution: .keepOne)
        }
        #expect(negativeGroup?.code == .INVALID_PARAM)
        #expect(negativeGroup?.params["field"] == "groupId")

        let negativeMember = gatherError {
            try DuplicateResolveMemberInput(memberId: -1, isKept: false)
        }
        #expect(negativeMember?.code == .INVALID_PARAM)
        #expect(negativeMember?.params["field"] == "memberId")
    }

    @Test("groups：空白 sessionId 走 invalidParameter")
    func groupsRejectsBlankSession() async throws {
        let fixture = try DuplicateQualityFixture()
        let error = await asyncGatherError {
            try await fixture.duplicateAPI.groups("   ")
        }
        #expect(error?.code == .INVALID_PARAM)
        #expect(error?.params["field"] == "sessionId")
    }

    @Test("Quality 输入类型：空 photoIds、空白 sessionId 显式失败")
    func qualityInputsRejectInvalidShapes() {
        let blankSession = gatherError {
            try QualityAnalyzeInput(sessionId: " ")
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")

        let emptyPhotoIds = gatherError {
            try QualityAnalyzeInput(sessionId: "s", photoIds: [])
        }
        #expect(emptyPhotoIds?.code == .INVALID_PARAM)
        #expect(emptyPhotoIds?.params["field"] == "photoIds")

        let blankPhotoId = gatherError {
            try QualityAnalyzeInput(sessionId: "s", photoIds: ["p1", " "])
        }
        #expect(blankPhotoId?.code == .INVALID_PARAM)
        #expect(blankPhotoId?.params["field"] == "photoIds[1]")
    }

    @Test("results：空白 sessionId / photoId 走 invalidParameter")
    func resultsRejectsBlankParameters() async throws {
        let fixture = try DuplicateQualityFixture()

        let blankSession = await asyncGatherError {
            try await fixture.qualityAPI.results(
                QualityGetParams(sessionId: " ")
            )
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")

        let blankPhotoId = await asyncGatherError {
            try await fixture.qualityAPI.results(
                QualityGetParams(sessionId: fixture.sessionId, photoIds: [""])
            )
        }
        #expect(blankPhotoId?.code == .INVALID_PARAM)
        #expect(blankPhotoId?.params["field"] == "photoIds[0]")
    }
}
