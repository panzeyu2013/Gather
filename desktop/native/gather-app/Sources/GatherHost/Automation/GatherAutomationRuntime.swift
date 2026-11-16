// desktop/native/gather-app/Sources/GatherHost/Automation/GatherAutomationRuntime.swift
// Wave3 / task-21：Shortcuts / App Intents 的宿主运行时。
//
// 边界：
// - 只把已有 typed API（SessionAPI / ExportAPI / CullingAPI / PhotoAPI）包成可注入的闭包，
//   不新造服务、不复制业务规则；App Intents（GatherApp target）只依赖本文件的
//   public struct，因此 intents 不需要 import 四层 core；
// - 运行时由 AppBootstrap 在 scene 发布前安装（进程内唯一），未启动时
//   registry.current == nil，intents 显式报 runtimeUnavailable；
// - 所有闭包 @Sendable；错误沿用各 API 的渗错误（GatherError / 域错误），
//   App Intent 只负责把错误表面化。
//
// Wave5 batch5（task-24，复核报告 05 §2 / F3 自动化第二层）：自动化面从「只能被推」
// 扩到「脚本能查、能写判断」两类命令：
//   · queryPhotos      只读查询（工作区 + 可选关键词/最低星级 + limit）→ photoIds/total/示例文件名；
//   · applyDecisions   按 photoIds 批量写 rating / 色标 / pick（keep|reject），
//                      复用 CullingAPI.batchUpdate，不引入删除/移动等破坏性动作。
//   两个命令同时供 App Intents 与 gather:// URL scheme 使用（同一份归一化/校验）。
import Foundation
import os
import GatherProtocol

/// Shortcuts 动作的运行时能力面（闭包注入，测试可直接构造假实现）。
public struct GatherAutomationRuntime: Sendable {
    /// 新建工作区并导入给定文件（返回 sessionId）。files 为绝对路径。
    public var createWorkspaceAndImport: @Sendable (_ name: String?, _ filepaths: [String]) async throws -> String
    /// 按工作区执行导出（返回 ExportResult）。
    public var exportSession: @Sendable (
        _ sessionId: String, _ destination: String, _ format: String,
        _ quality: Double?, _ maxDimension: Int?
    ) async throws -> ExportResult
    /// 按工作区写回元数据（rating / color_label / keyword）。
    public var writebackMetadata: @Sendable (_ sessionId: String, _ target: String) async throws -> GatherAutomationWritebackSummary
    /// 查询工作区状态（只读）。
    public var sessionStatus: @Sendable (_ sessionId: String) async throws -> GatherAutomationSessionStatus
    /// Wave5 batch5：查询照片（只读；按工作区 + 可选关键词/最低星级 + limit）。
    public var queryPhotos: @Sendable (_ query: GatherAutomationPhotoQuery) async throws -> GatherAutomationPhotoQueryResult
    /// Wave5 batch5：按 photoIds 批量写判断（rating / 色标 / pick）。
    public var applyDecisions: @Sendable (
        _ sessionId: String, _ photoIds: [String], _ patch: GatherAutomationDecisionPatch
    ) async throws -> GatherAutomationDecisionSummary

    public init(
        createWorkspaceAndImport: @escaping @Sendable (_ name: String?, _ filepaths: [String]) async throws -> String,
        exportSession: @escaping @Sendable (
            _ sessionId: String, _ destination: String, _ format: String,
            _ quality: Double?, _ maxDimension: Int?
        ) async throws -> ExportResult,
        writebackMetadata: @escaping @Sendable (_ sessionId: String, _ target: String) async throws -> GatherAutomationWritebackSummary,
        sessionStatus: @escaping @Sendable (_ sessionId: String) async throws -> GatherAutomationSessionStatus,
        queryPhotos: @escaping @Sendable (_ query: GatherAutomationPhotoQuery) async throws -> GatherAutomationPhotoQueryResult,
        applyDecisions: @escaping @Sendable (
            _ sessionId: String, _ photoIds: [String], _ patch: GatherAutomationDecisionPatch
        ) async throws -> GatherAutomationDecisionSummary
    ) {
        self.createWorkspaceAndImport = createWorkspaceAndImport
        self.exportSession = exportSession
        self.writebackMetadata = writebackMetadata
        self.sessionStatus = sessionStatus
        self.queryPhotos = queryPhotos
        self.applyDecisions = applyDecisions
    }
}

/// 写回结果的可读摘要（App Intent 的 dialog 用它，不需要感知 WritebackResult 全量字段）。
public struct GatherAutomationWritebackSummary: Equatable, Sendable {
    public var sessionId: String
    public var target: String
    public var written: Int
    public var failed: Int
    public var skipped: Int

    public init(sessionId: String, target: String, written: Int, failed: Int, skipped: Int) {
        self.sessionId = sessionId
        self.target = target
        self.written = written
        self.failed = failed
        self.skipped = skipped
    }
}

/// 工作区状态摘要（只读动作的返回值）。
public struct GatherAutomationSessionStatus: Equatable, Sendable {
    public var sessionId: String
    public var name: String
    public var photoCount: Int
    public var pendingXmp: Int
    public var writtenXmp: Int
    public var failedXmp: Int
    public var conflictXmp: Int
    public var reloadAckedAt: String?

    public init(
        sessionId: String,
        name: String,
        photoCount: Int,
        pendingXmp: Int,
        writtenXmp: Int,
        failedXmp: Int,
        conflictXmp: Int,
        reloadAckedAt: String?
    ) {
        self.sessionId = sessionId
        self.name = name
        self.photoCount = photoCount
        self.pendingXmp = pendingXmp
        self.writtenXmp = writtenXmp
        self.failedXmp = failedXmp
        self.conflictXmp = conflictXmp
        self.reloadAckedAt = reloadAckedAt
    }
}

// MARK: - Wave5 batch5：查询照片（只读）

/// 查询照片的归一化条件（App Intents / URL scheme / 运行时共用同一份校验与映射）。
///
/// 过滤条件不是在这里发明的新查询语言：映射到既有检索 DSL
/// （PhotoAPI.search 的 FilterGroup），关键词走 `keywords contains_any`、
/// 最低星级走 `rating gte`，与图库/检索页同一口径（FilterEngine）。
public struct GatherAutomationPhotoQuery: Equatable, Sendable {
    /// 缺省返回张数：与 filter.photos 的缺省一致（PageRequest.filterDefaultLimit）。
    public static let defaultLimit = 100
    /// 上限：与 filter.photos 的钳制上限一致（PageRequest.filterMaxLimit）。
    public static let maxLimit = 500
    /// keyword 长度上限（与 PhotoSuggestionQuery.keyword 同口径）。
    public static let maxKeywordLength = 256

    public var sessionId: String
    /// nil/空 = 不按关键词过滤。
    public var keyword: String?
    /// nil = 不按星级过滤；0…5。
    public var minRating: Int?
    /// 1...maxLimit。
    public var limit: Int

    public init(
        sessionId: String,
        keyword: String? = nil,
        minRating: Int? = nil,
        limit: Int = GatherAutomationPhotoQuery.defaultLimit
    ) throws {
        let trimmedId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, trimmedId.count <= 128 else {
            throw GatherAutomationError.invalidQuery("sessionId 必须非空且不超过 128 字符")
        }
        self.sessionId = trimmedId
        let trimmedKeyword = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKeyword.isEmpty {
            self.keyword = nil
        } else {
            guard trimmedKeyword.count <= Self.maxKeywordLength else {
                throw GatherAutomationError.invalidQuery(
                    "关键词过长（上限 \(Self.maxKeywordLength) 字符）")
            }
            self.keyword = trimmedKeyword
        }
        if let minRating {
            guard (0...5).contains(minRating) else {
                throw GatherAutomationError.invalidQuery("minRating 必须是 0…5 的整数")
            }
            self.minRating = minRating
        } else {
            self.minRating = nil
        }
        guard (1...Self.maxLimit).contains(limit) else {
            throw GatherAutomationError.invalidQuery("limit 必须在 1…\(Self.maxLimit) 之间")
        }
        self.limit = limit
    }

    /// Shortcuts/URL 的字符串入口（参数一律 String；空串 = 未设置）。
    ///
    /// 校验与上方 init 完全同源：字符串解析失败一律 `.invalidQuery`，不静默回落默认值
    /// （短路成默认值会让脚本以为"过滤生效了"）。
    public static func parse(
        sessionId: String,
        keyword: String,
        minRating: String,
        limit: String
    ) throws -> GatherAutomationPhotoQuery {
        let ratingRaw = minRating.trimmingCharacters(in: .whitespacesAndNewlines)
        var rating: Int?
        if !ratingRaw.isEmpty {
            guard let parsed = Int(ratingRaw) else {
                throw GatherAutomationError.invalidQuery("minRating 必须是 0…5 的整数：\(ratingRaw)")
            }
            rating = parsed
        }
        let limitRaw = limit.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedLimit = GatherAutomationPhotoQuery.defaultLimit
        if !limitRaw.isEmpty {
            guard let parsed = Int(limitRaw) else {
                throw GatherAutomationError.invalidQuery("limit 必须是整数：\(limitRaw)")
            }
            resolvedLimit = parsed
        }
        return try GatherAutomationPhotoQuery(
            sessionId: sessionId, keyword: keyword, minRating: rating, limit: resolvedLimit)
    }

    /// 过滤条件映射（唯一实现：与图库检索同一套 FilterEngine 字段/操作符）。
    public var criteria: FilterGroup {
        var conditions: [FilterCondition] = []
        if let keyword {
            conditions.append(.rule(FilterRule(
                field: "keywords", operator: .containsAny, value: .array([.string(keyword)]))))
        }
        if let minRating {
            conditions.append(.rule(FilterRule(
                field: "rating", operator: .gte, value: .number(Double(minRating)))))
        }
        return FilterGroup(logic: .and, conditions: conditions)
    }
}

/// 查询结果里的示例条目（dialog/日志用：只给文件名，不给绝对路径）。
public struct GatherAutomationPhotoSample: Equatable, Sendable {
    public var photoId: String
    public var filename: String

    public init(photoId: String, filename: String) {
        self.photoId = photoId
        self.filename = filename
    }
}

/// 查询照片的结果：ID 列表（受 limit 约束）+ 匹配总数 + 前几个示例文件名。
public struct GatherAutomationPhotoQueryResult: Equatable, Sendable {
    /// 示例条目上限（dialog 只展示前几个，不把几百行塞进 Shortcuts 结果）。
    public static let maxSamples = 5

    public var sessionId: String
    /// 本次返回的照片 ID（去重保序，count <= limit）。
    public var photoIds: [String]
    /// 匹配条件的工作区总数（不受 limit 影响）。
    public var total: Int
    public var samples: [GatherAutomationPhotoSample]

    public init(
        sessionId: String,
        photoIds: [String],
        total: Int,
        samples: [GatherAutomationPhotoSample] = []
    ) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.total = total
        self.samples = Array(samples.prefix(Self.maxSamples))
    }
}

// MARK: - Wave5 batch5：写判断（rating / 色标 / pick）

/// 批量写判断的补丁（已归一化；直接映射到 CullingUpdatePatch）。
///
/// 边界（与挑片域一致）：
/// - rating 0…5 的整数（CullingBatchUpdateInput 也会校验，这里提前给出可读错误）；
/// - colorLabel 取 CaptureOneColorLabel 的 rawValue（None 表示清空色标）；
/// - pickState 支持 keep/reject；不传 = 不改。**不是破坏性动作**（不删文件、不移动），
///   与 moveRejected/rename/move 这类 Confirmed 入口区分。
public struct GatherAutomationDecisionPatch: Equatable, Sendable {
    public var rating: Double?
    public var colorLabel: CaptureOneColorLabel?
    public var pickState: PickState?

    public init(
        rating: Double? = nil,
        colorLabel: CaptureOneColorLabel? = nil,
        pickState: PickState? = nil
    ) {
        self.rating = rating
        self.colorLabel = colorLabel
        self.pickState = pickState
    }

    /// 补丁是否为空（空补丁会被 CullingAPI 拒绝；调用方应先报 .invalidDecision）。
    public var isEmpty: Bool {
        rating == nil && colorLabel == nil && pickState == nil
    }

    /// 可复用色标名（URL/Shortcuts 的字符串取值；小写）。
    public static let colorLabelNames: [String] = CaptureOneColorLabel.allCases.map {
        $0.rawValue.lowercased()
    }
    /// 可复用 pick 取值（只表达 keep/reject；不传 = 不改，'unreviewed' 由"不传"表达）。
    public static let pickNames: [String] = ["keep", "reject"]

    /// Shortcuts/URL 的字符串入口（参数一律 String；空串 = 未设置）。
    ///
    /// 校验失败一律 `.invalidDecision`（不静默忽略非法值：脚本拼错色标名时应该报错，
    /// 而不是"看起来成功但什么都没写"）。三个字段全空同样报错，避免空写。
    public static func parse(rating: String, label: String, pick: String) throws -> GatherAutomationDecisionPatch {
        let ratingRaw = rating.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedRating: Double?
        if !ratingRaw.isEmpty {
            guard let value = Int(ratingRaw), (0...5).contains(value) else {
                throw GatherAutomationError.invalidDecision(
                    "rating 必须是 0…5 的整数：\(ratingRaw)")
            }
            parsedRating = Double(value)
        }
        let labelRaw = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parsedLabel: CaptureOneColorLabel?
        if !labelRaw.isEmpty {
            guard let label = CaptureOneColorLabel.allCases.first(where: {
                $0.rawValue.lowercased() == labelRaw
            }) else {
                throw GatherAutomationError.invalidDecision(
                    "不支持的色标：\(labelRaw)（可用：\(colorLabelNames.joined(separator: "/"))）")
            }
            parsedLabel = label
        }
        let pickRaw = pick.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parsedPick: PickState?
        if !pickRaw.isEmpty {
            switch pickRaw {
            case "keep": parsedPick = .picked
            case "reject": parsedPick = .rejected
            default:
                throw GatherAutomationError.invalidDecision(
                    "不支持的 pick：\(pickRaw)（可用：keep/reject）")
            }
        }
        let patch = GatherAutomationDecisionPatch(
            rating: parsedRating, colorLabel: parsedLabel, pickState: parsedPick)
        guard !patch.isEmpty else {
            throw GatherAutomationError.invalidDecision("至少需要 rating / label / pick 之一")
        }
        return patch
    }
}

/// 写判断的结果摘要（written = 实际更新的照片数；skipped = 请求里未落库的张数）。
public struct GatherAutomationDecisionSummary: Equatable, Sendable {
    public var sessionId: String
    public var written: Int
    public var skipped: Int

    public init(sessionId: String, written: Int, skipped: Int) {
        self.sessionId = sessionId
        self.written = written
        self.skipped = skipped
    }
}

/// 运行时安装点：进程内唯一（AppBootstrap 启动后写入；退出不清理，进程结束即释放）。
///
/// 用 OSAllocatedUnfairLock 而不是全局 var：Swift 6 禁止可变全局状态；
/// 锁保护的是 Sendable 值（整个 struct 都是 @Sendable 闭包/值类型）。
public enum GatherAutomationRuntimeRegistry {
    private static let storage = OSAllocatedUnfairLock<GatherAutomationRuntime?>(initialState: nil)

    public static var current: GatherAutomationRuntime? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// 测试/启动失败清理。
    public static func reset() {
        storage.withLock { $0 = nil }
    }
}

/// Shortcuts 动作的稳定错误（App Intents 直接抛这个，UI 显示 errorDescription）。
public enum GatherAutomationError: Error, LocalizedError, Equatable, Sendable {
    case runtimeUnavailable
    case noFiles
    case unsupportedFormat(String)
    case unsupportedTarget(String)
    /// Wave5 batch5：查询条件非法（sessionId/关键词/星级/limit）。
    case invalidQuery(String)
    /// Wave5 batch5：判断补丁非法（rating 越界 / 未知色标 / 未知 pick / 空补丁）。
    case invalidDecision(String)
    /// Wave5 batch5：写判断没有给任何照片 ID。
    case noPhotoIds

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Gather 尚未完成启动；请先打开应用再运行此动作。"
        case .noFiles:
            return "没有可导入的文件。"
        case .unsupportedFormat(let raw):
            return "不支持的导出格式：\(raw)。"
        case .unsupportedTarget(let raw):
            return "不支持的写回目标：\(raw)。"
        case .invalidQuery(let reason):
            return "查询条件无效：\(reason)。"
        case .invalidDecision(let reason):
            return "写判断参数无效：\(reason)。"
        case .noPhotoIds:
            return "没有指定照片 ID。"
        }
    }
}
