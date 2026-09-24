// Tests/GatherCoreTests/API/DuplicateCommandsImplTests.swift
// R5：duplicate 域命令实现直测（批次 B5，R5 最后一个未实现域）。
// 覆盖旧路由分支语义：scan 建 duplicate.scan 作业（dedupeKey / checkpoint 逐字）
// 并等结果、空结果以 jobFailed 失败；groups 返回该会话全部重复组；
// resolve / resolve_member 的 confirmed 门控（DUP_RESOLVE_CONFIRM_REQUIRED /
// DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED，门控失败不落库）与运行时错误透传。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身

/// 作业入参捕获（actor：executor 闭包由作业运行器跨任务调用）。
private actor DuplicateJobCapture {
    private var jobs: [AnalysisJobData] = []

    func record(_ job: AnalysisJobData) {
        jobs.append(job)
    }

    func first() -> AnalysisJobData? {
        jobs.first
    }
}

// MARK: - 基座

private struct DuplicateCommandsHarness {
    let impl: DuplicateCommandsImpl
    let runtime: DuplicateRuntime
    let jobs: JobRunner
    let db: SQLiteDatabase
    let sessionId: String
    let storePath: String

    func cleanup() { removeStoreFiles(storePath) }
}

private func makeHarness(
    executor: @escaping JobRunner.JobExecutor = { _, _ in nil }
) async throws -> DuplicateCommandsHarness {
    let storePath = storeTempPath("duplicate-commands")
    let db = try await makeMigratedStore(path: storePath)
    let session = try await SQLiteSessionStore(database: db).create(
        name: "Duplicate", source: "manual", sourcePath: "", truncatedImport: false)
    let runtime = DuplicateRuntime(store: SQLiteDuplicateStore(database: db))
    let jobs = JobRunner(jobStore: SQLiteJobStore(database: db))
    await jobs.registerExecutor(type: .duplicateScan, executor: executor)
    return DuplicateCommandsHarness(
        impl: DuplicateCommandsImpl(duplicate: runtime, jobs: jobs),
        runtime: runtime,
        jobs: jobs,
        db: db,
        sessionId: session.id,
        storePath: storePath
    )
}

/// 种子一组精确重复（rebuildGroups 会插 photos/组/成员行）。
@discardableResult
private func seedExactGroup(
    _ harness: DuplicateCommandsHarness,
    photoIds: [String] = ["p1", "p2"]
) async throws -> Int {
    for photoId in photoIds {
        try await insertPhoto(harness.db, id: photoId, sessionId: harness.sessionId)
    }
    let groupIds = try await SQLiteDuplicateStore(database: harness.db).rebuildGroups(
        sessionId: harness.sessionId,
        exact: [DuplicateExactGroupInput(checksum: "sum-a", photoIds: photoIds)],
        visual: [],
        fileInfo: [:],
        createdAt: "2026-01-01T00:00:00.000Z"
    )
    return try #require(groupIds.exact.first)
}

// MARK: - 用例

@Suite("API/DuplicateCommandsImpl (R5)")
struct DuplicateCommandsImplTests {
    @Test("scan 建 duplicate.scan 作业并把作业结果原样返回")
    func scanCreatesJobAndReturnsResult() async throws {
        let capture = DuplicateJobCapture()
        let expected = DuplicateScanResult(
            exactGroups: [DuplicateGroup(
                id: 7,
                groupType: .exact,
                checksum: "sum-a",
                hashHex: nil,
                memberCount: 2,
                members: [],
                resolution: nil,
                createdAt: "2026-01-01T00:00:00.000Z"
            )],
            visualGroups: [],
            totalDuplicates: 2
        )
        let harness = try await makeHarness(executor: { job, _ in
            await capture.record(job)
            return expected
        })
        defer { harness.cleanup() }

        let result = try await harness.impl.scan(DupScanParams(
            sessionId: harness.sessionId, visualThreshold: 0.85))

        #expect(result == expected)
        let job = await capture.first()
        #expect(job?.type == .duplicateScan)
        #expect(job?.scopeType == "session")
        #expect(job?.scopeId == harness.sessionId)
        #expect(job?.dedupeKey == "duplicate.scan:\(harness.sessionId):0.85")
        #expect(job?.checkpoint["visualThreshold"] == .number(0.85))
        let stored = try await harness.jobs.list(status: .succeeded)
        #expect(stored.count == 1)
    }

    @Test("scan 缺省 visualThreshold：dedupeKey 用 default、checkpoint 为 null")
    func scanDefaultsVisualThreshold() async throws {
        let capture = DuplicateJobCapture()
        let harness = try await makeHarness(executor: { job, _ in
            await capture.record(job)
            return DuplicateScanResult(exactGroups: [], visualGroups: [], totalDuplicates: 0)
        })
        defer { harness.cleanup() }

        _ = try await harness.impl.scan(DupScanParams(sessionId: harness.sessionId))

        let job = await capture.first()
        #expect(job?.dedupeKey == "duplicate.scan:\(harness.sessionId):default")
        #expect(job?.checkpoint["visualThreshold"] == .null)
    }

    @Test("scan 空作业结果以 jobFailed 失败（错误路径）")
    func scanFailsOnEmptyResult() async throws {
        let harness = try await makeHarness(executor: { _, _ in nil })
        defer { harness.cleanup() }

        do {
            _ = try await harness.impl.scan(DupScanParams(sessionId: harness.sessionId))
            Issue.record("空作业结果应以 jobFailed 失败")
        } catch let error as JobRunnerError {
            guard case .jobFailed(_, let message) = error else {
                Issue.record("期望 jobFailed，实际 \(error)")
                return
            }
            #expect(message == "empty duplicate.scan result")
        }
    }

    @Test("groups 返回该会话全部重复组，未知会话为空")
    func groupsReturnsSessionGroups() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        try await seedExactGroup(harness)

        let groups = try await harness.impl.groups(DupGroupsParams(sessionId: harness.sessionId))

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.groupType == .exact)
        #expect(group.checksum == "sum-a")
        #expect(group.memberCount == 2)
        #expect(Set(group.members.map(\.photoId)) == Set(["p1", "p2"]))
        #expect(try await harness.impl.groups(DupGroupsParams(sessionId: "ghost")).isEmpty)
    }

    @Test("resolve 未确认：DUP_RESOLVE_CONFIRM_REQUIRED 且不落库")
    func resolveRequiresConfirmation() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let groupId = try await seedExactGroup(harness)

        await #expect(throws: DuplicateCommandsError.resolveConfirmRequired) {
            try await harness.impl.resolve(DupResolveParams(
                groupId: groupId, resolution: .keepOne, confirmed: false))
        }
        #expect(String(describing: DuplicateCommandsError.resolveConfirmRequired)
            == "DUP_RESOLVE_CONFIRM_REQUIRED")
        #expect(DuplicateCommandsError.resolveConfirmRequired.gatherCode
            == GatherErrorCode.DUP_RESOLVE_CONFIRM_REQUIRED)
        let groups = try await harness.impl.groups(DupGroupsParams(sessionId: harness.sessionId))
        #expect(groups.first?.resolution == nil, "门控失败不应写 resolution")
    }

    @Test("resolve keep_one：落库 resolution 且只保留一个成员")
    func resolveKeepOneAppliesResolution() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let groupId = try await seedExactGroup(harness)

        try await harness.impl.resolve(DupResolveParams(
            groupId: groupId, resolution: .keepOne, confirmed: true))

        let groups = try await harness.impl.groups(DupGroupsParams(sessionId: harness.sessionId))
        let group = try #require(groups.first)
        #expect(group.resolution == "keep_one")
        #expect(group.members.filter(\.isKept).count == 1)
        #expect(group.members.allSatisfy { $0.resolution == "keep_one" })
    }

    @Test("resolve 未知组透传 groupNotFound（错误路径）")
    func resolveSurfacesGroupNotFound() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: DuplicateError.groupNotFound(9_999)) {
            try await harness.impl.resolve(DupResolveParams(
                groupId: 9_999, resolution: .keepAll, confirmed: true))
        }
    }

    @Test("resolveMember 未确认：DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED 且不落库")
    func resolveMemberRequiresConfirmation() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let groupId = try await seedExactGroup(harness)
        let members = try await SQLiteDuplicateStore(database: harness.db).members(groupId: groupId)
        let member = try #require(members.first)

        await #expect(throws: DuplicateCommandsError.resolveMemberConfirmRequired) {
            try await harness.impl.resolveMember(DupResolveMemberParams(
                memberId: member.id, isKept: false, confirmed: false))
        }
        #expect(String(describing: DuplicateCommandsError.resolveMemberConfirmRequired)
            == "DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED")
        #expect(DuplicateCommandsError.resolveMemberConfirmRequired.gatherCode
            == GatherErrorCode.DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED)
        let groups = try await harness.impl.groups(DupGroupsParams(sessionId: harness.sessionId))
        #expect(groups.first?.members.allSatisfy(\.isKept) == true, "门控失败不应改成员")
    }

    @Test("resolveMember isKept=false：成员移除、写 keep_one、照片置 removed")
    func resolveMemberRemovesMember() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let groupId = try await seedExactGroup(harness)
        let members = try await SQLiteDuplicateStore(database: harness.db).members(groupId: groupId)
        let member = try #require(members.first)

        try await harness.impl.resolveMember(DupResolveMemberParams(
            memberId: member.id, isKept: false, confirmed: true))

        let groups = try await harness.impl.groups(DupGroupsParams(sessionId: harness.sessionId))
        let group = try #require(groups.first)
        let stored = try #require(group.members.first { $0.id == member.id })
        #expect(stored.isKept == false)
        #expect(stored.resolution == "keep_one")
        let status = try await harness.db.queryOne(
            "SELECT status FROM photos WHERE id = ?", [.text(member.photoId)])?.text(at: 0)
        #expect(status == "removed")
    }

    @Test("resolveMember 未知成员透传 memberNotFound（错误路径）")
    func resolveMemberSurfacesMemberNotFound() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: DuplicateError.memberNotFound(9_999)) {
            try await harness.impl.resolveMember(DupResolveMemberParams(
                memberId: 9_999, isKept: true, confirmed: true))
        }
    }
}
