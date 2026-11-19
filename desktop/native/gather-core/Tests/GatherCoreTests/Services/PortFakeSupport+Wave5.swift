// desktop/native/gather-core/Tests/GatherCoreTests/Services/PortFakeSupport+Wave5.swift
// Wave 5 / M8：端口 fake 补齐（第二批，8 个）。
//
// 覆盖差集来源：GatherPersistence/Ports 下 43 个 public protocol，PortFakeSupport.swift 的
// 22 个替身覆盖其中 20 个；本文件补 8 个「无 fake + 方法面小 + 有真实消费者」的端口。
// 选择原则：优先 Application/Delivery 有唯一消费者、且能在不触库的前提下断言调用事实的端口。
//
// 约定（与 PortFakeSupport.swift 同风格，但错误类型独立，避免两轮 fake 互相耦合）：
// - 每个替身记录调用次数/入参，供「服务确实经端口读」的断言；
// - 未模拟的写路径统一抛 Wave5FakeUnimplemented（不依赖 PortFakeError），测试走到即失败；
// - 3 个 Sendable 端口（DeliveryReadStore / MetadataKeywordReading / MetadataDeliveryReading）
//   用 Synchronization.Mutex 锁盒承载可变状态——与 Sources 既有锁盒写法一致，
//   不新增 @unchecked Sendable（预算 60/60 已满）；Mutex 属标准库，Linux 可 typecheck。
import Foundation
import Synchronization
import GatherProtocol
import GatherPersistence

/// Wave 5 fake 的未实现路径错误：和 PortFakeSupport 的 PortFakeError 分开，
/// 便于单测按消息前缀区分是「第一批」还是「第二批」替身漏了路径。
enum Wave5FakeUnimplemented: Error, CustomStringConvertible {
    case path(String)

    var description: String {
        switch self {
        case .path(let name): return "WAVE5_FAKE_UNIMPLEMENTED: \(name)"
        }
    }
}

// MARK: - 交付层窄读（R8 端口）

/// DeliveryReadStore：1 方法读端口（消费者 DeliveryMirrorWriter）。
/// Sendable：状态收进 Mutex；行由测试注入（fake 不建 DBRow）。
final class PortFakeDeliveryReadStore: DeliveryReadStore, Sendable {
    private struct State: Sendable {
        var rowsByXmpPath: [String: DeliveryRow] = [:]
        var requestedPaths: [String] = []
    }

    private let state = Mutex(State())

    func setRow(_ row: DeliveryRow, forXmpPath xmpPath: String) {
        state.withLock { $0.rowsByXmpPath[xmpPath] = row }
    }

    func get(_ xmpPath: String) throws -> DeliveryRow? {
        state.withLock { state in
            state.requestedPaths.append(xmpPath)
            return state.rowsByXmpPath[xmpPath]
        }
    }

    /// 调用次数（镜像写手「只读一次当前行」的断言点）。
    var callCount: Int { state.withLock { $0.requestedPaths.count } }
    var requestedPaths: [String] { state.withLock { $0.requestedPaths } }
}

/// PhotoReadStore：1 方法读端口（消费者 WritebackService 的写回计划）。
final class PortFakePhotoReadStore: PhotoReadStore {
    var projectionRows: [PhotoProjectionRow] = []
    private(set) var projectionCalls: [String] = []

    func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow] {
        projectionCalls.append(sessionId)
        return projectionRows
    }
}

/// MetadataKeywordReading：1 方法读端口（消费者 KeywordIndexSync）。
/// Sendable：状态收进 Mutex；photo_metadata_cache 行缺失 = nil 是真实语义。
final class PortFakeMetadataKeywordReader: MetadataKeywordReading, Sendable {
    private struct State: Sendable {
        var keywordsByPhotoId: [String: [String]] = [:]
        var requestedPhotoIds: [String] = []
    }

    private let state = Mutex(State())

    /// 注入缓存行关键词；nil = 删除该行（读回 nil）。
    func setKeywords(_ keywords: [String]?, forPhotoId photoId: String) {
        state.withLock { state in
            if let keywords {
                state.keywordsByPhotoId[photoId] = keywords
            } else {
                state.keywordsByPhotoId[photoId] = nil
            }
        }
    }

    func keywords(photoId: String) throws -> [String]? {
        state.withLock { state in
            state.requestedPhotoIds.append(photoId)
            return state.keywordsByPhotoId[photoId]
        }
    }

    var callCount: Int { state.withLock { $0.requestedPhotoIds.count } }
    var requestedPhotoIds: [String] { state.withLock { $0.requestedPhotoIds } }
}

// MARK: - 元数据生命周期 / 交付摘要

/// MetadataDeliveryReading：2 方法读端口（消费者 MetadataDeliveryService）。
/// Sendable：状态收进 Mutex；两方法都以「空结果 = 库里没行」为合法语义。
final class PortFakeMetadataDeliveryReader: MetadataDeliveryReading, Sendable {
    private struct State: Sendable {
        var projectionsBySession: [String: [MetadataLifecycleProjection]] = [:]
        var backupPathsBySession: [String: [String]] = [:]
        var allBackupPaths: [String] = []
        var projectionCalls: [String] = []
        var backupPathCalls: [String?] = []
    }

    private let state = Mutex(State())

    func setProjections(_ projections: [MetadataLifecycleProjection], forSession sessionId: String) {
        state.withLock { $0.projectionsBySession[sessionId] = projections }
    }

    func setBackupPaths(_ paths: [String], forSession sessionId: String) {
        state.withLock { $0.backupPathsBySession[sessionId] = paths }
    }

    /// nil = 全库引用集（备份 GC 口径）。
    func setAllBackupPaths(_ paths: [String]) {
        state.withLock { $0.allBackupPaths = paths }
    }

    func projections(sessionId: String) throws -> [MetadataLifecycleProjection] {
        state.withLock { state in
            state.projectionCalls.append(sessionId)
            return state.projectionsBySession[sessionId] ?? []
        }
    }

    func backupPaths(sessionId: String?) throws -> [String] {
        state.withLock { state in
            state.backupPathCalls.append(sessionId)
            guard let sessionId else { return state.allBackupPaths }
            return state.backupPathsBySession[sessionId] ?? []
        }
    }

    var projectionCallCount: Int { state.withLock { $0.projectionCalls.count } }
    var backupPathCallCount: Int { state.withLock { $0.backupPathCalls.count } }
    /// 作用域入参快照（nil 表示全库调用，是本端口的关键断言点）。
    var backupPathScopes: [String?] { state.withLock { $0.backupPathCalls } }
}

/// DeliverySummaryReading：3 方法读端口（消费者 SessionService / WorkspaceStatusService）。
/// 摘要行不可凭空构造，故 summary/metadataSummary 未注入时抛未实现，防止静默返回假摘要。
final class PortFakeDeliverySummaryReader: DeliverySummaryReading {
    var summaryValue: DeliverySessionSummary?
    var metadataSummaryValue: MetadataSyncSummary?
    var writtenBackValue = false
    private(set) var summaryCalls: [(sessionId: String, module: DeliveryModule?)] = []
    private(set) var metadataSummaryCalls: [(sessionId: String, module: DeliveryModule?)] = []
    private(set) var hasWrittenBackCalls: [(sessionId: String, module: DeliveryModule)] = []

    func summary(sessionId: String, module: DeliveryModule?) throws -> DeliverySessionSummary {
        summaryCalls.append((sessionId, module))
        guard let summaryValue else {
            throw Wave5FakeUnimplemented.path("DeliverySummaryReading.summary")
        }
        return summaryValue
    }

    func metadataSummary(sessionId: String, module: DeliveryModule?) throws -> MetadataSyncSummary {
        metadataSummaryCalls.append((sessionId, module))
        guard let metadataSummaryValue else {
            throw Wave5FakeUnimplemented.path("DeliverySummaryReading.metadataSummary")
        }
        return metadataSummaryValue
    }

    func hasWrittenBackItem(sessionId: String, module: DeliveryModule) throws -> Bool {
        hasWrittenBackCalls.append((sessionId, module))
        return writtenBackValue
    }
}

// MARK: - 挑片 / 导航 / 质量

/// CullingDecisionLiteReading：1 方法读端口（消费者 CullingSyncService 的写回计划）。
final class PortFakeCullingDecisionLiteReader: CullingDecisionLiteReading {
    var decisions: [CullingDecisionLiteRow] = []
    private(set) var getDecisionsCalls: [String] = []

    func getDecisions(sessionId: String) throws -> [CullingDecisionLiteRow] {
        getDecisionsCalls.append(sessionId)
        return decisions
    }
}

/// NavigationRepository：7 方法（消费者 NavigationService）。
/// 读路径返回注入值/空集（空会话是合法输入）；三个写路径未模拟 → 抛未实现并记录调用。
final class PortFakeNavigationRepo: NavigationRepository {
    var groups: [NavigationGroupRow] = []
    var captures: [NavigationCaptureRow] = []
    var fingerprint: String?
    var manualGroupRows: [(type: String, photoIdsJSON: String)] = []
    private(set) var listGroupsCalls: [String] = []
    private(set) var captureRowsCalls: [String] = []
    private(set) var cachedFingerprintCalls: [String] = []
    private(set) var manualGroupsCalls: [String] = []
    private(set) var replaceGroupCalls: [String] = []
    private(set) var mergeGroupsCalls: [String] = []
    private(set) var replaceAutomaticGroupsCalls: [String] = []

    func listGroups(sessionId: String) throws -> [NavigationGroupRow] {
        listGroupsCalls.append(sessionId)
        return groups
    }

    func captureRows(sessionId: String) throws -> [NavigationCaptureRow] {
        captureRowsCalls.append(sessionId)
        return captures
    }

    func cachedFingerprint(sessionId: String) throws -> String? {
        cachedFingerprintCalls.append(sessionId)
        return fingerprint
    }

    func replaceGroup(sessionId: String, groupId: String, with groups: [NavigationGroupWrite]) throws {
        replaceGroupCalls.append("\(sessionId)/\(groupId)")
        throw Wave5FakeUnimplemented.path("NavigationRepository.replaceGroup")
    }

    func mergeGroups(sessionId: String, groupIds: [String], into group: NavigationGroupWrite) throws {
        mergeGroupsCalls.append("\(sessionId)/\(groupIds.count)")
        throw Wave5FakeUnimplemented.path("NavigationRepository.mergeGroups")
    }

    func manualGroups(sessionId: String) throws -> [(type: String, photoIdsJSON: String)] {
        manualGroupsCalls.append(sessionId)
        return manualGroupRows
    }

    func replaceAutomaticGroups(sessionId: String, groups: [NavigationGroupWrite]) throws {
        replaceAutomaticGroupsCalls.append("\(sessionId)/\(groups.count)")
        throw Wave5FakeUnimplemented.path("NavigationRepository.replaceAutomaticGroups")
    }
}

/// QualityRepository：5 方法（消费者 QualityService）。
/// 读路径返回注入行/空集；insertResults 记录入参并视为成功（落库效果由调用方断言）。
final class PortFakeQualityRepo: QualityRepository {
    var latestRows: [(photoId: String, resultJson: String)] = []
    var cachedRows: [QualityCachedRow] = []
    var faceBoxes: [QualityFaceRecord] = []
    var similarityGroups: [Int: [String]]?
    private(set) var insertResultsCalls: [(inserts: [QualityAnalysisInsert], modelId: String, modelVersion: String)] = []
    private(set) var latestResultsCalls: [[String]] = []
    private(set) var cachedResultsCalls: [(photoIds: [String], modelId: String, modelVersion: String)] = []
    private(set) var maxFaceBoxesCalls: [(sessionId: String, photoIds: [String])] = []
    private(set) var latestSimilarityGroupsCalls: [String] = []

    func insertResults(
        _ inserts: [QualityAnalysisInsert],
        modelId: String,
        modelVersion: String
    ) throws {
        insertResultsCalls.append((inserts, modelId, modelVersion))
    }

    func latestResults(photoIds: [String]) throws -> [(photoId: String, resultJson: String)] {
        latestResultsCalls.append(photoIds)
        return latestRows
    }

    func cachedResults(
        photoIds: [String],
        modelId: String,
        modelVersion: String
    ) throws -> [QualityCachedRow] {
        cachedResultsCalls.append((photoIds, modelId, modelVersion))
        return cachedRows
    }

    func maxFaceBoxes(sessionId: String, photoIds: [String]) throws -> [QualityFaceRecord] {
        maxFaceBoxesCalls.append((sessionId, photoIds))
        return faceBoxes
    }

    func latestSimilarityGroups(sessionId: String) throws -> [Int: [String]]? {
        latestSimilarityGroupsCalls.append(sessionId)
        return similarityGroups
    }
}
