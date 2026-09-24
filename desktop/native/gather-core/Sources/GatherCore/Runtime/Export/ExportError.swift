import Foundation

// 自 Services/ExportService.swift 迁移（R2/W2d-4 语义承接）：导出错误码与文案逐字保留。

public enum ExportError: Error, Equatable, CustomStringConvertible, LocalizedError {
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
    case exportPathInvalid
    case formatUnsupported
    case rawConvertUnsupported
    case xmpConflict
    case cancelled

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
        case .exportPathInvalid: return "EXPORT_PATH_INVALID"
        case .formatUnsupported: return "EXPORT_FORMAT_UNSUPPORTED"
        case .rawConvertUnsupported: return "EXPORT_RAW_CONVERT_UNSUPPORTED"
        case .xmpConflict: return "EXPORT_XMP_CONFLICT"
        case .cancelled: return "CANCELLED"
        }
    }

    public var errorDescription: String? { description }
}
