// desktop/native/gather-app/Tests/GatherAppTests/Support/StubAPIs.swift
// Cut 1 / B5b 测试共享：DuplicateAPI / QualityAPI / JobAPI 的可配置替身。
//
// 与 APIFaceUITests / APISimilarityUITests 的私有 JobAPI 替身同款结构：
// final class + LockedBox（@unchecked Sendable），方法可在任意隔离域调用；
// 记录调用参数供断言。生产页面只依赖协议，测试注入这些替身即可覆盖
// "扫描/解决/建任务/轮询/取消" 的 API 边界。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain

// MARK: - 任务数据工厂

/// 构造一份字段完整的 AnalysisJobData（测试断言只关心少数字段）。
func b5bJobData(
    id: String,
    type: AnalysisJobType = .metadataScan,
    status: AnalysisJobStatus = .queued,
    scopeId: String = "s1",
    dedupeKey: String = "",
    progressCurrent: Int = 0,
    progressTotal: Int = 0,
    progressMessage: String = "",
    errorCode: String = "",
    errorMessage: String = ""
) -> AnalysisJobData {
    AnalysisJobData(
        id: id,
        type: type,
        scopeType: "session",
        scopeId: scopeId,
        dedupeKey: dedupeKey,
        status: status,
        priority: 0,
        progressCurrent: progressCurrent,
        progressTotal: progressTotal,
        progressMessage: progressMessage,
        inputFingerprint: "",
        modelId: "",
        modelVersion: "",
        checkpoint: [:],
        attemptCount: 0,
        leaseOwner: "",
        heartbeatAt: "",
        errorCode: errorCode,
        errorMessage: errorMessage,
        createdAt: "2026-01-01T00:00:00.000Z",
        startedAt: "",
        finishedAt: "",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

// MARK: - JobAPI

private struct StubJobState {
    var jobs: [AnalysisJobData] = []
    var listError: (any Error)?
    var cancelError: (any Error)?
    var retryError: (any Error)?
    var startError: (any Error)?
    var cancelResult = true
    var retryResult = true
    var startJob: AnalysisJobData?
    var listFilters: [JobListFilter] = []
    var cancelledIds: [String] = []
    var retriedIds: [String] = []
    var startRequests: [JobRequest] = []
    var clearInputs: [Confirmed<ClearCompletedInput>] = []
}

/// 可配置 JobAPI：默认 list 返回空、cancel/retry 返回 true、start 返回空事件流。
final class B5bJobAPIStub: JobAPI, @unchecked Sendable {
    private let box = LockedBox(StubJobState())

    var jobs: [AnalysisJobData] {
        get { box.lock.withLock { box.jobs } }
        set { box.lock.withLock { box.jobs = newValue } }
    }

    var listError: (any Error)? {
        get { box.lock.withLock { box.listError } }
        set { box.lock.withLock { box.listError = newValue } }
    }

    var cancelError: (any Error)? {
        get { box.lock.withLock { box.cancelError } }
        set { box.lock.withLock { box.cancelError = newValue } }
    }

    var retryError: (any Error)? {
        get { box.lock.withLock { box.retryError } }
        set { box.lock.withLock { box.retryError = newValue } }
    }

    var startError: (any Error)? {
        get { box.lock.withLock { box.startError } }
        set { box.lock.withLock { box.startError = newValue } }
    }

    var cancelResult: Bool {
        get { box.lock.withLock { box.cancelResult } }
        set { box.lock.withLock { box.cancelResult = newValue } }
    }

    var retryResult: Bool {
        get { box.lock.withLock { box.retryResult } }
        set { box.lock.withLock { box.retryResult = newValue } }
    }

    /// start 返回的 job id/数据（默认按请求生成）。
    var startJob: AnalysisJobData? {
        get { box.lock.withLock { box.startJob } }
        set { box.lock.withLock { box.startJob = newValue } }
    }

    var listFilters: [JobListFilter] { box.lock.withLock { box.listFilters } }
    var cancelledIds: [String] { box.lock.withLock { box.cancelledIds } }
    var retriedIds: [String] { box.lock.withLock { box.retriedIds } }
    var startRequests: [JobRequest] { box.lock.withLock { box.startRequests } }
    var clearInputs: [Confirmed<ClearCompletedInput>] { box.lock.withLock { box.clearInputs } }

    func list(_ filter: JobListFilter) async throws -> [AnalysisJobData] {
        let (error, jobs): ((any Error)?, [AnalysisJobData]) = box.lock.withLock {
            box.listFilters.append(filter)
            return (box.listError, box.jobs)
        }
        if let error { throw error }
        return jobs
    }

    func cancel(_ jobId: String) async throws -> Bool {
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.cancelledIds.append(jobId)
            return (box.cancelError, box.cancelResult)
        }
        if let error { throw error }
        return result
    }

    func retry(_ jobId: String) async throws -> Bool {
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.retriedIds.append(jobId)
            return (box.retryError, box.retryResult)
        }
        if let error { throw error }
        return result
    }

    func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int {
        box.lock.withLock { box.clearInputs.append(input) }
        return 0
    }

    func start(_ request: JobRequest) async throws -> JobHandle {
        let (error, configured): ((any Error)?, AnalysisJobData?) = box.lock.withLock {
            box.startRequests.append(request)
            return (box.startError, box.startJob)
        }
        if let error { throw error }
        let job = configured ?? b5bJobData(
            id: "job-\(request.type.rawValue)-started",
            type: request.type,
            status: .queued,
            scopeId: request.scopeId,
            dedupeKey: request.dedupeKey
        )
        let stream = AsyncStream<JobEvent> { continuation in continuation.finish() }
        return JobHandle(id: job.id, events: stream)
    }
}

// MARK: - QualityAPI

private struct StubQualityState {
    var analyzeResult: AnalysisJobData?
    var analyzeError: (any Error)?
    var results: [QualityResult] = []
    var resultsError: (any Error)?
    var analyzeInputs: [QualityAnalyzeInput] = []
    var resultsQueries: [QualityGetParams] = []
}

/// 可配置 QualityAPI：默认 analyze 返回 qualityScore job，results 返回空。
final class B5bQualityAPIStub: QualityAPI, @unchecked Sendable {
    private let box = LockedBox(StubQualityState())

    var analyzeResult: AnalysisJobData? {
        get { box.lock.withLock { box.analyzeResult } }
        set { box.lock.withLock { box.analyzeResult = newValue } }
    }

    var analyzeError: (any Error)? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var results: [QualityResult] {
        get { box.lock.withLock { box.results } }
        set { box.lock.withLock { box.results = newValue } }
    }

    var resultsError: (any Error)? {
        get { box.lock.withLock { box.resultsError } }
        set { box.lock.withLock { box.resultsError = newValue } }
    }

    var analyzeInputs: [QualityAnalyzeInput] { box.lock.withLock { box.analyzeInputs } }
    var resultsQueries: [QualityGetParams] { box.lock.withLock { box.resultsQueries } }

    func analyze(_ input: QualityAnalyzeInput) async throws -> AnalysisJobData {
        let (error, configured): ((any Error)?, AnalysisJobData?) = box.lock.withLock {
            box.analyzeInputs.append(input)
            return (box.analyzeError, box.analyzeResult)
        }
        if let error { throw error }
        return configured ?? b5bJobData(
            id: "job-quality-started",
            type: .qualityScore,
            status: .queued,
            scopeId: input.sessionId,
            dedupeKey: "quality.score:\(input.sessionId):all"
        )
    }

    func results(_ query: QualityGetParams) async throws -> [QualityResult] {
        let (error, results): ((any Error)?, [QualityResult]) = box.lock.withLock {
            box.resultsQueries.append(query)
            return (box.resultsError, box.results)
        }
        if let error { throw error }
        return results
    }
}

// MARK: - DuplicateAPI

private struct StubDuplicateState {
    var scanResult = DuplicateScanResult(exactGroups: [], visualGroups: [], totalDuplicates: 0)
    var scanError: (any Error)?
    var groups: [DuplicateGroup] = []
    var groupsError: (any Error)?
    var resolveResult = true
    var resolveError: (any Error)?
    var resolveMemberResult = true
    var resolveMemberError: (any Error)?
    var scanInputs: [DuplicateScanInput] = []
    var groupsCalls: [String] = []
    var resolveInputs: [Confirmed<DuplicateResolveInput>] = []
    var resolveMemberInputs: [Confirmed<DuplicateResolveMemberInput>] = []
}

/// 可配置 DuplicateAPI：默认 groups 返回空、resolve/resolveMember 返回 true。
final class B5bDuplicateAPIStub: DuplicateAPI, @unchecked Sendable {
    private let box = LockedBox(StubDuplicateState())

    var scanResult: DuplicateScanResult {
        get { box.lock.withLock { box.scanResult } }
        set { box.lock.withLock { box.scanResult = newValue } }
    }

    var scanError: (any Error)? {
        get { box.lock.withLock { box.scanError } }
        set { box.lock.withLock { box.scanError = newValue } }
    }

    var groups: [DuplicateGroup] {
        get { box.lock.withLock { box.groups } }
        set { box.lock.withLock { box.groups = newValue } }
    }

    var groupsError: (any Error)? {
        get { box.lock.withLock { box.groupsError } }
        set { box.lock.withLock { box.groupsError = newValue } }
    }

    var resolveResult: Bool {
        get { box.lock.withLock { box.resolveResult } }
        set { box.lock.withLock { box.resolveResult = newValue } }
    }

    var resolveError: (any Error)? {
        get { box.lock.withLock { box.resolveError } }
        set { box.lock.withLock { box.resolveError = newValue } }
    }

    var resolveMemberResult: Bool {
        get { box.lock.withLock { box.resolveMemberResult } }
        set { box.lock.withLock { box.resolveMemberResult = newValue } }
    }

    var resolveMemberError: (any Error)? {
        get { box.lock.withLock { box.resolveMemberError } }
        set { box.lock.withLock { box.resolveMemberError = newValue } }
    }

    var scanInputs: [DuplicateScanInput] { box.lock.withLock { box.scanInputs } }
    var groupsCalls: [String] { box.lock.withLock { box.groupsCalls } }
    var resolveInputs: [Confirmed<DuplicateResolveInput>] { box.lock.withLock { box.resolveInputs } }
    var resolveMemberInputs: [Confirmed<DuplicateResolveMemberInput>] { box.lock.withLock { box.resolveMemberInputs } }

    func scan(_ input: DuplicateScanInput) async throws -> DuplicateScanResult {
        let (error, result): ((any Error)?, DuplicateScanResult) = box.lock.withLock {
            box.scanInputs.append(input)
            return (box.scanError, box.scanResult)
        }
        if let error { throw error }
        return result
    }

    func groups(_ sessionId: String) async throws -> [DuplicateGroup] {
        let (error, groups): ((any Error)?, [DuplicateGroup]) = box.lock.withLock {
            box.groupsCalls.append(sessionId)
            return (box.groupsError, box.groups)
        }
        if let error { throw error }
        return groups
    }

    func resolve(_ input: Confirmed<DuplicateResolveInput>) async throws -> Bool {
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.resolveInputs.append(input)
            return (box.resolveError, box.resolveResult)
        }
        if let error { throw error }
        return result
    }

    func resolveMember(_ input: Confirmed<DuplicateResolveMemberInput>) async throws -> Bool {
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.resolveMemberInputs.append(input)
            return (box.resolveMemberError, box.resolveMemberResult)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - 模型夹具

/// 重复组夹具：成员 id 从 1 开始递增，文件大小/时间按序递增（推荐保留最后一张）。
func b5bDuplicateGroup(
    id: Int = 1,
    type: DuplicateGroupType = .exact,
    photoIds: [String] = ["p1", "p2"],
    isKept: Bool = true
) -> DuplicateGroup {
    let members = photoIds.enumerated().map { index, photoId in
        DuplicateGroupMember(
            id: id * 100 + index + 1,
            photoId: photoId,
            isKept: isKept,
            fileSize: 1_000 + index,
            fileMtime: "2026-01-01T00:00:0\(index).000Z",
            filepath: "/shoot/\(photoId).jpg",
            filename: "\(photoId).jpg"
        )
    }
    return DuplicateGroup(
        id: id,
        groupType: type,
        memberCount: members.count,
        members: members,
        createdAt: "2026-01-01T00:00:00.000Z"
    )
}
