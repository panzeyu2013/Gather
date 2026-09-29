// desktop/native/gather-core/Sources/GatherCore/Protocol/Core.swift
// TS 源: packages/shared/src/protocol/core.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
//
// 映射决策:
// - TS string-literal 联合 → Swift `String` 原始值枚举，rawValue 与 TS 字符串逐一对应；
//   不做 unknown 兜底 —— 解码失败即契约漂移，由对账测试捕获。
// - TS 可选字段 `?` → Swift `Optional`，缺省即 nil；编码时 nil 不输出 key（与 TS 一致）。
// - TS `Record<string, unknown>` → `[String: JSONValue]`（JSONValue 为任意 JSON 值的枚举）。

import Foundation

// ── 状态枚举 ──
// TS: SessionStatus / AnalysisStatus / WritebackStatus（core.ts）

public enum SessionStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case draft
    case photosLoaded = "photos_loaded"
    case analyzing
    case review
    case completed
}

public enum AnalysisStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case done
    case failed
    case cancelled
}

public enum WritebackStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case done
    case partial
    case cleaned
}

// ── 目录扫描结果 ──
// TS: ScanResult（core.ts）—— app:scan-directory 返回值
public struct ScanResult: Codable, Equatable, Sendable {
    public var files: [String]
    public var truncated: Bool
    public var scannedTotal: Int
    public var limit: Int

    public init(files: [String], truncated: Bool, scannedTotal: Int, limit: Int) {
        self.files = files
        self.truncated = truncated
        self.scannedTotal = scannedTotal
        self.limit = limit
    }
}

// ── 事件数据类型 ──
// TS: ProgressData（core.ts）—— `progress` 事件
public struct ProgressData: Codable, Equatable, Sendable {
    public var sessionId: String
    public var current: Int
    public var total: Int
    public var message: String
    public var status: AnalysisStatus? // TS: status?: AnalysisStatus

    public init(sessionId: String, current: Int, total: Int, message: String, status: AnalysisStatus? = nil) {
        self.sessionId = sessionId
        self.current = current
        self.total = total
        self.message = message
        self.status = status
    }
}

// TS: EngineStatusData（core.ts）—— `engine:status` 事件
public struct EngineStatusData: Codable, Equatable, Sendable {
    public var status: String // TS: 'connecting' | 'ready' | 'disconnected'
    public var version: String? // TS: version?: string

    public init(status: String, version: String? = nil) {
        self.status = status
        self.version = version
    }
}

// ── 任意 JSON 值 ──
// TS: Record<string, unknown> / 响应 error.params 里的 value 类型
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解码 JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// ── JSONValue 访问器 ──
// 供宿主（gather-app）等消费方安全读取，避免在模块外做 case 模式匹配
// （macOS 26 SDK Foundation 自带同名 JSONValue，模块外 .object 等模式
// 会解析到 Foundation 版本导致编译错误；访问器集中在本模块内实现）。
// 注意：stringValue/arrayValue 已有 RepositorySupport.swift 的重载（String
// /[String] 语义），此处不重复定义。
public extension JSONValue {
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// 原始数组元素（RepositorySupport.arrayValue 是 [String]? 便捷版）。
    var arrayElements: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

// ── 响应 id 字段 ──
// TS: id?: number | string（ResponseOk / ResponseErr 共用）
public enum ResponseID: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

// TS: ResponseErr.error 联合的第二个成员
// { type: string; message: string; params?: Record<string, unknown> }
public struct ErrorDetail: Codable, Equatable, Sendable {
    public var type: String
    public var message: String
    public var params: [String: JSONValue]? // TS: params?: Record<string, unknown>

    public init(type: String, message: String, params: [String: JSONValue]? = nil) {
        self.type = type
        self.message = message
        self.params = params
    }
}

// TS: ResponseErr.error —— string（错误码，见 GatherErrorCode）| ErrorDetail
public enum ResponseErrorBody: Codable, Equatable, Sendable {
    case code(String)
    case detail(ErrorDetail)

    public init(from decoder: Decoder) throws {
        if let code = try? String(from: decoder) {
            self = .code(code)
        } else {
            self = .detail(try ErrorDetail(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .code(let code): try code.encode(to: encoder)
        case .detail(let detail): try detail.encode(to: encoder)
        }
    }
}

// ── 响应 ──
// TS: ResponseOk<T> = { id?: number | string; ok: true; data: T }
// `ok` 恒为 true：解码校验、编码强制输出 true。
public struct ResponseOk<T: Codable>: Codable, Equatable, Sendable where T: Equatable & Sendable {
    public var id: ResponseID?
    public let ok: Bool
    public let data: T

    public init(id: ResponseID? = nil, data: T) {
        self.id = id
        self.ok = true
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(ResponseID.self, forKey: .id)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard ok else {
            throw DecodingError.dataCorruptedError(
                forKey: .ok, in: container, debugDescription: "ResponseOk 的 ok 必须为 true")
        }
        self.ok = true
        self.data = try container.decode(T.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(true, forKey: .ok)
        try container.encode(data, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, data
    }
}

// TS: ResponseErr = { id?: number | string; ok: false; error: string | {...} }
public struct ResponseErr: Codable, Equatable, Sendable {
    public var id: ResponseID?
    public let ok: Bool
    public let error: ResponseErrorBody

    public init(id: ResponseID? = nil, error: ResponseErrorBody) {
        self.id = id
        self.ok = false
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(ResponseID.self, forKey: .id)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard !ok else {
            throw DecodingError.dataCorruptedError(
                forKey: .ok, in: container, debugDescription: "ResponseErr 的 ok 必须为 false")
        }
        self.ok = false
        self.error = try container.decode(ResponseErrorBody.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(false, forKey: .ok)
        try container.encode(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, error
    }
}

// TS: Response<T> = ResponseOk<T> | ResponseErr
public enum Response<T: Codable>: Codable, Equatable, Sendable where T: Equatable & Sendable {
    case ok(ResponseOk<T>)
    case err(ResponseErr)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .ok(try ResponseOk<T>(from: decoder))
        } else {
            self = .err(try ResponseErr(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ok(let ok): try ok.encode(to: encoder)
        case .err(let err): try err.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok
    }
}

// ── 错误码 ──
// TS: GatherErrorCode（packages/shared/src/errors.ts，GATHER_ERROR_CODES as const）
// 映射决策：case 名与 TS 码同名（Swift 允许大写 case 名），String rawValue 自动等于 case 名，
// 因此 rawValue 与 TS 字符串逐字一致，无需显式 rawValue 与 `// TS:` 重命名标注。
public enum GatherErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    // C1 集成
    case C1_NOT_RUNNING
    case C1_NO_DOCUMENT
    case C1_NOT_AUTHORIZED
    case C1_SCRIPT_FAILED
    /// Capture One AppleScript 调用超时（宿主桥 `.timedOut`）。
    case C1_SCRIPT_TIMEOUT
    /// 导入时 Capture One 未选中任何照片（AppDelegate 通知载荷）。
    case C1_NO_SELECTED_PHOTOS
    case SCAN_INVALID_DIR
    case SCAN_READ_FAILED
    // XMP / metadata 同步协调 + writeback
    case XMP_CONFLICT_RESOLUTION_REQUIRED
    case XMP_CONFIRM_INCOMPLETE
    case XMP_CLEANUP_REQUIRES_LOADED
    case XMP_CONFIRM_REQUIRES_SYNC
    /// 结清时仍有未确认的关联会话：不得谎报成功（审查 N2/声明 12）。
    case XMP_CONFIRM_OTHER_SESSION_PENDING
    case XMP_EXTERNALLY_MODIFIED
    case XMP_BACKUP_MISSING
    // 侧车文档本身的读写故障（SidecarXMPProvider 抛出，客户端按键分流处理）
    case XMP_DOCUMENT_CORRUPT
    case XMP_DOCUMENT_UNSUPPORTED
    case XMP_DOCUMENT_READ_FAILED
    case XMP_WRITE_FAILED
    case XMP_WRITE_VERIFICATION_FAILED
    case XMP_BACKUP_FAILED
    case XMP_RESTORE_FAILED
    case XMP_CLEANUP_ABORTED_EXTERNAL_EDIT
    case XMP_EXTERNAL_EDIT_CONFLICT
    case XMP_RELOAD_NOT_ACKED
    case XMP_CONFLICT_NOT_FOUND
    case XMP_CONFLICT_DETAILS_UNAVAILABLE
    case XMP_CHOICE_MISSING
    case XMP_CONFLICT_DETAILS_INVALID
    case XMP_ORPHAN_NOT_FOUND
    case XMP_ORPHAN_NOT_RETRYABLE
    case XMP_WRITER_TIMEOUT
    case WRITEBACK_OTHER_MODULE_ACTIVE
    case WRITEBACK_UNDO_FACE_FAILED
    case WRITEBACK_FAILURES_PENDING
    case WRITEBACK_GROUP_NOT_IN_SESSION
    // Export 校验
    case EXPORT_PARAMS_INVALID
    case EXPORT_CONFIRMATION_REQUIRED
    case EXPORT_DIR_INVALID
    case EXPORT_DIR_ABSOLUTE_REQUIRED
    case EXPORT_DIR_ROOT_FORBIDDEN
    case EXPORT_DIR_INSIDE_SESSION
    case EXPORT_FORMAT_INVALID
    case EXPORT_FORMAT_UNSUPPORTED
    case EXPORT_VARIANT_POLICY_INVALID
    case EXPORT_ORIGINAL_NO_TRANSFORM
    case EXPORT_NAMING_EMPTY
    case EXPORT_NAMING_INVALID_CHARS
    case EXPORT_JPEG_QUALITY_INVALID
    case EXPORT_MAX_DIMENSION_INVALID
    case EXPORT_START_INDEX_INVALID
    case EXPORT_WATERMARK_TYPE_UNSUPPORTED
    case EXPORT_WATERMARK_TEXT_EMPTY
    case EXPORT_WATERMARK_OPACITY_INVALID
    case EXPORT_WATERMARK_FONT_SIZE_INVALID
    case EXPORT_XMP_CONFLICT
    case EXPORT_PATH_INVALID
    case EXPORT_SCOPE_UNSUPPORTED
    case EXPORT_SCOPE_UNKNOWN
    case EXPORT_RAW_CONVERT_UNSUPPORTED
    case EXPORT_UNKNOWN_ERROR
    // Navigation
    case NAV_BURST_GAP_INVALID
    case NAV_SCENE_GAP_INVALID
    case NAV_GROUP_NOT_FOUND
    case NAV_MERGE_MIN_TWO
    case NAV_MERGE_TYPE_MISMATCH
    case NAV_SPLIT_OUT_OF_GROUP
    // Culling + culling history
    case CULLING_EMPTY_SELECTION
    case CULLING_PHOTOS_NOT_IN_SESSION
    case CULLING_HISTORY_NOT_FOUND
    case CULLING_HISTORY_ALREADY_UNDONE
    case CULLING_HISTORY_NOT_UNDONE
    case CULLING_HISTORY_DIVERGED
    case CULLING_HISTORY_STALE
    case CULLING_HISTORY_CORRUPT
    case CULLING_UNDO_NOT_LATEST
    case CULLING_REDO_OUT_OF_ORDER
    case CULLING_NO_SIMILARITY
    case CULLING_GROUP_TOO_SMALL
    case CULLING_KEEP_NOT_IN_GROUP
    // Asset relink
    case ASSET_RELINK_XMP_BUSY
    case ASSET_RELINK_OUTBOX_CONFLICT
    case ASSET_RELINK_XMP_CONFLICT
    /// 重链接根目录校验（缺陷⑥）：同根 / 两向嵌套 / 根下无登记文件 / 无候选
    /// 通过身份校验 —— 一律显式失败，绝不用 0 冒充成功。
    case ASSET_RELINK_SAME_ROOT
    case ASSET_RELINK_NESTED_ROOT
    case ASSET_RELINK_NO_FILES_REGISTERED
    case ASSET_RELINK_NO_VERIFIED_FILE
    // Face 关键字服务 + 模型下载
    case FACE_EPS_INVALID
    case FACE_MIN_CLUSTER_INVALID
    case FACE_NO_PHOTOS
    case FACE_SELF_MERGE
    case FACE_MODEL_DETECTOR_CORRUPT
    case FACE_MODEL_ENCODER_CORRUPT
    // Similarity
    case SIM_THRESHOLD_INVALID
    case SIM_MIN_GROUP_INVALID
    case SIM_WRITEBACK_EMPTY
    case SIM_WRITEBACK_INVALID_ITEM
    case SIM_ANALYSIS_MISSING
    case SIM_THRESHOLD_NO_RESULTS
    case SIM_PREVIEW_REQUIRED
    case SIM_PREVIEW_STALE
    // Session 来源 + 身份
    case SESSION_SOURCE_NOT_DIR
    case SESSION_SOURCE_ROOT_FORBIDDEN
    case SESSION_NOT_FOUND
    case SESSION_IDS_REQUIRED
    // Culling
    case CULLING_PHOTO_NOT_IN_SESSION
    case CULLING_REVISION_CONFLICT
    case CULLING_PATCH_INVALID
    case CULLING_INVALID_SCOPE
    case CULLING_FINALIZE_CONFIRM_REQUIRED
    case CULLING_RESET_CONFIRM_REQUIRED
    case CULLING_NO_DECISIONS
    // Writeback / cleanup 确认
    case WRITEBACK_CONFIRM_REQUIRED
    case WRITEBACK_RETRY_CONFIRM_REQUIRED
    case WRITEBACK_CLEANUP_CONFIRM_REQUIRED
    case FKW_UNBIND_CONFIRM_REQUIRED
    case FKW_CLEANUP_CONFIRM_REQUIRED
    // Face 关键字服务
    case FKW_NO_OBSERVATIONS
    case FKW_ANALYSIS_RUNNING
    case FKW_CLUSTER_NOT_FOUND
    case FKW_CLUSTER_NOT_IN_SESSION
    case FKW_CLUSTER_MEMBER_NOT_FOUND
    case FKW_ROLE_NAME_EMPTY
    case FKW_KEYWORDS_INVALID
    case FKW_ITEMS_INVALID
    // Similarity
    case SIM_ANALYSIS_RUNNING
    case SIM_NO_PHOTOS
    case SIM_NO_HASH_DATA
    case SIM_NO_HASH_RECLUSTER
    case SIM_NO_RESULTS
    case SIM_ASSIGNMENT_INVALID
    case SIM_GROUPING_MODE_INVALID
    // Duplicate / metadata / jobs / settings / quality / index / asset
    case DUP_RESOLVE_CONFIRM_REQUIRED
    case DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED
    /// 视觉阈值非法（§4.2 P2）：必须是 0...64 的整数。
    case DUP_THRESHOLD_INVALID
    case DUPLICATE_SCAN_BUSY
    case METADATA_SET_CONFIRM_REQUIRED
    case METADATA_BATCH_SET_CONFIRM_REQUIRED
    case METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED
    case METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED
    case METADATA_KEYWORDS_INVALID
    case METADATA_PATCH_INVALID
    case METADATA_RATING_INVALID
    case METADATA_LABEL_INVALID
    case METADATA_KEYWORDS_OP_INVALID
    case METADATA_PATCH_EMPTY
    case METADATA_MUTATION_EMPTY
    case JOBS_CLEAR_CONFIRM_REQUIRED
    case SETTINGS_LANGUAGE_INVALID
    case QUALITY_NO_ASSET_FILE
    case INDEX_SESSION_NO_SOURCE
    case ASSET_LINK_CANDIDATE_NOT_FOUND
    case ASSET_FILE_NOT_LINKED
    case ASSET_MIGRATION_INCOMPLETE
    case SESSION_DELETE_NOT_CONFIRMED
    case MODEL_EXTRACT_FAILED
    case FACE_WORKERS_INIT_FAILED
    case FILTER_CRITERIA_INVALID
    case FILTER_FIELD_UNKNOWN
    case FILTER_SCHEMA_UNSUPPORTED
    case TEMPLATE_NOT_FOUND
    case TEMPLATE_CONFIG_INVALID
    case TEMPLATE_DELETE_CONFIRM_REQUIRED
    case TEMPLATE_APPLY_CONFIRM_REQUIRED
    case ALBUM_DELETE_CONFIRM_REQUIRED
    case ALBUM_NOT_FOUND
    case PERSON_NOT_FOUND
    case PERSON_DELETE_CONFIRM_REQUIRED
    case PERSON_MERGE_CONFIRM_REQUIRED
    case PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED
    case ASSET_LINK_ACCEPT_CONFIRM_REQUIRED
    case ASSET_LINK_REJECT_CONFIRM_REQUIRED
    case ASSET_RELINK_CONFIRM_REQUIRED
}

// ── 共享的 writeback / cleanup 类型（core.ts:35-105）──
// face.ts import type { WritebackOptions, WritebackItem } from './core'，
// 这些类型属 core.ts 归属，Face.swift 直接引用。

// TS: WritebackAttributes（core.ts:35-40）
public struct WritebackAttributes: Codable, Equatable, Sendable {
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?

    public init(keywords: [String]? = nil, rating: Double? = nil, label: String? = nil) {
        self.keywords = keywords
        self.rating = rating
        self.label = label
    }
}

// TS: GroupData（core.ts:41-45）
public struct GroupData: Codable, Equatable, Sendable {
    public struct ImageRef: Codable, Equatable, Sendable {
        public var path: String

        public init(path: String) {
            self.path = path
        }
    }

    public var id: ResponseID // TS: id: number | string
    public var images: [ImageRef]
    public var label: String? // TS: label?

    public init(id: ResponseID, images: [ImageRef], label: String? = nil) {
        self.id = id
        self.images = images
        self.label = label
    }
}

// TS: WritebackOptions（core.ts:47-52）
public struct WritebackOptions: Codable, Equatable, Sendable {
    public var createAlbums: Bool? // TS: createAlbums?
    public var addPrefix: Bool? // TS: addPrefix?
    public var markUngrouped: Bool? // TS: markUngrouped?
    public var writeIPTC: Bool? // TS: writeIPTC?

    public init(createAlbums: Bool? = nil, addPrefix: Bool? = nil, markUngrouped: Bool? = nil, writeIPTC: Bool? = nil) {
        self.createAlbums = createAlbums
        self.addPrefix = addPrefix
        self.markUngrouped = markUngrouped
        self.writeIPTC = writeIPTC
    }
}

// TS: WritebackPreview（core.ts:54-58）
public struct WritebackPreview: Codable, Equatable, Sendable {
    public var items: [WritebackItem]
    public var totalCount: Int
    public var affectedPhotos: Int

    public init(items: [WritebackItem], totalCount: Int, affectedPhotos: Int) {
        self.items = items
        self.totalCount = totalCount
        self.affectedPhotos = affectedPhotos
    }
}

// TS: WritebackItem.preview.dirtyFields（core.ts 内联联合 'rating' | 'label' | 'keywords'）
public enum WritebackDirtyField: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case label
    case keywords
}

// TS: WritebackItem.preview（core.ts:76-84 内联匿名对象）
public struct WritebackItemPreview: Codable, Equatable, Sendable {
    public var dirtyFields: [WritebackDirtyField]
    public var before: WritebackAttributes
    public var after: WritebackAttributes
    public var source: String
    public var sharedPhotoCount: Int
    public var externalChanged: Bool
    public var willCreate: Bool

    public init(dirtyFields: [WritebackDirtyField], before: WritebackAttributes, after: WritebackAttributes, source: String, sharedPhotoCount: Int, externalChanged: Bool, willCreate: Bool) {
        self.dirtyFields = dirtyFields
        self.before = before
        self.after = after
        self.source = source
        self.sharedPhotoCount = sharedPhotoCount
        self.externalChanged = externalChanged
        self.willCreate = willCreate
    }
}

// TS: WritebackItem（core.ts:60-84）
public struct WritebackItem: Codable, Equatable, Sendable {
    public var id: Int? // TS: id?
    public var photoId: String
    public var photoPath: String
    public var sessionId: String
    public var module: String
    public var keywords: [String]
    public var attributes: WritebackAttributes? // TS: attributes?
    public var xmpPath: String
    public var backupPath: String
    public var xmpStatus: String
    public var errorMessage: String
    public var attemptCount: Int
    public var lastAttemptAt: String
    public var preview: WritebackItemPreview? // TS: preview?

    public init(
        id: Int? = nil,
        photoId: String,
        photoPath: String,
        sessionId: String,
        module: String,
        keywords: [String],
        attributes: WritebackAttributes? = nil,
        xmpPath: String,
        backupPath: String,
        xmpStatus: String,
        errorMessage: String,
        attemptCount: Int,
        lastAttemptAt: String,
        preview: WritebackItemPreview? = nil
    ) {
        self.id = id
        self.photoId = photoId
        self.photoPath = photoPath
        self.sessionId = sessionId
        self.module = module
        self.keywords = keywords
        self.attributes = attributes
        self.xmpPath = xmpPath
        self.backupPath = backupPath
        self.xmpStatus = xmpStatus
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.preview = preview
    }
}

// TS: WritebackResult（core.ts:85-93）
public struct WritebackResult: Codable, Equatable, Sendable {
    public var totalAffected: Int
    public var written: Int
    public var failed: Int
    public var skipped: Int
    public var errors: [String]
    public var failedItems: [WritebackItem]
    public var report: String

    public init(
        totalAffected: Int,
        written: Int,
        failed: Int,
        skipped: Int,
        errors: [String],
        failedItems: [WritebackItem],
        report: String
    ) {
        self.totalAffected = totalAffected
        self.written = written
        self.failed = failed
        self.skipped = skipped
        self.errors = errors
        self.failedItems = failedItems
        self.report = report
    }
}

// TS: CleanupResult（core.ts:95-98）
public struct CleanupResult: Codable, Equatable, Sendable {
    public var deletedCount: Int
    public var errors: [String]

    public init(deletedCount: Int, errors: [String]) {
        self.deletedCount = deletedCount
        self.errors = errors
    }
}

// TS: AddPhotoResult（core.ts:100-104）
public struct AddPhotoResult: Codable, Equatable, Sendable {
    public var added: Int
    public var skipped: Int
    public var total: Int
    public var failedFiles: [String]

    public init(added: Int, skipped: Int, total: Int, failedFiles: [String]) {
        self.added = added
        self.skipped = skipped
        self.total = total
        self.failedFiles = failedFiles
    }
}
