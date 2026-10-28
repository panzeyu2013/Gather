// desktop/native/gather-core/Sources/GatherApplication/Services/ExportService.swift
// Phase 3.6：原生导出管线。
//
// 该服务刻意保持在 GatherApplication：预览、文件规划、断点续作、原图复制、
// ImageIO 转码与报告生成必须由同一条受控路径完成，不能让 WebView 直接
// 访问任意文件系统路径。命令层只负责参数解码和 JobService 编排。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

public struct NativeExportProgress: Equatable, Sendable {
    public let sessionId: String
    public let current: Int
    public let total: Int
    public let fileName: String
    public let bytesWritten: Int
    public let status: String
    public let errorMessage: String?

    public init(
        sessionId: String,
        current: Int,
        total: Int,
        fileName: String,
        bytesWritten: Int,
        status: String,
        errorMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.current = current
        self.total = total
        self.fileName = fileName
        self.bytesWritten = bytesWritten
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct NativeExportResumeState {
    public var destinations: [String: String]
    public var completedPhotoIds: Set<String>
    /// 每张已完成照片**当时**的 sidecar 版本（问题 1，第三轮审查）：只记录
    /// completedPhotoIds 无法区分「目标 XMP 已存在」与「目标 XMP 仍是最新」——
    /// 源 XMP 改过之后必须重新交付，而不是静默跳过。
    public var sidecarVersions: [String: String]
    public var onPlanned: ((String, String) -> Void)?
    public var onPlanReady: (() -> Void)?
    public var onCompleted: ((String, String) -> Void)?

    public init(
        destinations: [String: String] = [:],
        completedPhotoIds: Set<String> = [],
        sidecarVersions: [String: String] = [:],
        onPlanned: ((String, String) -> Void)? = nil,
        onPlanReady: (() -> Void)? = nil,
        onCompleted: ((String, String) -> Void)? = nil
    ) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
        self.sidecarVersions = sidecarVersions
        self.onPlanned = onPlanned
        self.onPlanReady = onPlanReady
        self.onCompleted = onCompleted
    }
}

public enum ExportServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case destinationInvalid
    case destinationAbsoluteRequired
    case destinationRootForbidden
    case destinationInsideSession
    case formatInvalid
    case variantPolicyInvalid
    case originalTransformNotAllowed
    case namingEmpty
    case namingInvalidCharacters
    case qualityInvalid
    case maxDimensionInvalid
    case startIndexInvalid
    case watermarkTypeUnsupported
    case watermarkTextEmpty
    case watermarkOpacityInvalid
    case watermarkFontSizeInvalid
    case scopeUnsupported
    case sessionNotFound
    case sourceMissing(String)
    /// 源文件存在但不可读（权限 / 卷离线）：计划诊断与执行共用同一码（P2-9 审计 3）。
    case sourceUnreadable(String)
    case exportPathInvalid
    case formatUnsupported
    case rawConvertUnsupported
    case xmpConflict
    case cancelled
    /// 本次交付零成功且存在失败项（审查 D02）：执行器原先正常返回，JobService 因此
    /// 记 succeeded、工作区推导出「已导出」——全失败被当成交付完成。
    case allFilesFailed(Int)

    public var description: String {
        switch self {
        case .destinationInvalid: return "EXPORT_DIR_INVALID"
        case .destinationAbsoluteRequired: return "EXPORT_DIR_ABSOLUTE_REQUIRED"
        case .destinationRootForbidden: return "EXPORT_DIR_ROOT_FORBIDDEN"
        case .destinationInsideSession: return "EXPORT_DIR_INSIDE_SESSION"
        case .formatInvalid: return "EXPORT_FORMAT_INVALID"
        case .variantPolicyInvalid: return "EXPORT_VARIANT_POLICY_INVALID"
        case .originalTransformNotAllowed: return "EXPORT_ORIGINAL_NO_TRANSFORM"
        case .namingEmpty: return "EXPORT_NAMING_EMPTY"
        case .namingInvalidCharacters: return "EXPORT_NAMING_INVALID_CHARS"
        case .qualityInvalid: return "EXPORT_JPEG_QUALITY_INVALID"
        case .maxDimensionInvalid: return "EXPORT_MAX_DIMENSION_INVALID"
        case .startIndexInvalid: return "EXPORT_START_INDEX_INVALID"
        case .watermarkTypeUnsupported: return "EXPORT_WATERMARK_TYPE_UNSUPPORTED"
        case .watermarkTextEmpty: return "EXPORT_WATERMARK_TEXT_EMPTY"
        case .watermarkOpacityInvalid: return "EXPORT_WATERMARK_OPACITY_INVALID"
        case .watermarkFontSizeInvalid: return "EXPORT_WATERMARK_FONT_SIZE_INVALID"
        case .scopeUnsupported: return "EXPORT_SCOPE_UNSUPPORTED"
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .sourceMissing: return "EXPORT_SOURCE_MISSING"
        case .sourceUnreadable: return "EXPORT_SOURCE_UNREADABLE"
        case .exportPathInvalid: return "EXPORT_PATH_INVALID"
        case .formatUnsupported: return "EXPORT_FORMAT_UNSUPPORTED"
        case .rawConvertUnsupported: return "EXPORT_RAW_CONVERT_UNSUPPORTED"
        case .xmpConflict: return "EXPORT_XMP_CONFLICT"
        case .cancelled: return "CANCELLED"
        case .allFilesFailed: return "EXPORT_ALL_FAILED"
        }
    }

    public var errorDescription: String? { description }
}

/// 导出服务：原图安全复制、JPEG/TIFF 转码、断点续作和报告。
public final class ExportService {
    let photoRepo: any PhotoRepository
    let sessionRepo: any SessionRepository
    let reports: any ExportReportRepository
    let cancelLock = NSLock()
    /// 取消状态按**每次执行**（runId）而不是按会话（问题 2，第三轮审查）：
    /// 旧实现把取消位挂在 sessionId 上，同一会话并行导出两个目录时，
    /// B 开始会清掉 A 的取消位、取消 A 又会中断 B。
    var cancelledRuns = Set<String>()
    /// sessionId → 该会话当前在跑的 runId（供「取消本会话全部导出」使用）。
    var sessionRuns: [String: Set<String>] = [:]

    public init(
        photoRepo: any PhotoRepository,
        sessionRepo: any SessionRepository,
        reports: any ExportReportRepository
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.reports = reports
    }

    /// 只取消指定 run（问题 2 的验收：同会话并行导出时，取消 A 不得影响 B）。
    public func cancel(runId: String) {
        cancelLock.lock()
        cancelledRuns.insert(runId)
        cancelLock.unlock()
    }

    public func cancel(sessionId: String) {
        cancelLock.lock()
        // 会话级取消 = 枚举该会话当前在跑的所有 run（调度器语义）。
        for runId in sessionRuns[sessionId] ?? [] {
            cancelledRuns.insert(runId)
        }
        cancelLock.unlock()
    }
}
