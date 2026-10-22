// desktop/native/gather-app/Sources/GatherUI/Support/WorkspaceIntent.swift
// Cut 4 / 4a-0 定义、4a-2c 完成迁移：工作区入口意图（§4.2）。
//
// 4a-2c：SessionDraftCache 的 4 个 pending 容器、RootNavigation 的
// pendingGalleryPhotoId/Path 与 faceKwInitialRole 已全部删除，统一收进本枚举；
// 由 SessionWorkspace.pendingIntents 按 Kind 去重（同种意图后到覆盖先到），
// 页面在 .task 中 take 后自行消费（取出即清）。
import Foundation

public enum WorkspaceIntent: Equatable, Sendable {
    /// 进入图库后套用筛选（4a-2c 前是 draftCache.pendingGalleryFilter）。
    case galleryFilter(GalleryFilter)
    /// 进入图库后打开指定照片（id 优先，path 兜底；4a-2c 前是导航的 2 个字段）。
    case galleryPhoto(id: String?, path: String?)
    /// 进入挑片后展开冲突面板（4a-2c 前是 draftCache.pendingCullingConflicts）。
    case cullingConflicts
    /// 进入人脸页后开始分析（4a-2c 前是 draftCache.pendingFaceAnalyze）。
    case faceAnalyze
    /// 进入人脸页后套用角色筛选（4a-2c 前是 faceKwInitialRole 构造参数）。
    case faceRole(String)
    /// 进入导出页后套用范围意图（现：ExportRangeIntent / 控制中心"去导出"）。
    case exportRange(ExportRangeIntent)

    /// 意图种类：pendingIntents 的键；同 Kind 只保留最后一次。
    public enum Kind: String, CaseIterable, Sendable {
        case galleryFilter
        case galleryPhoto
        case cullingConflicts
        case faceAnalyze
        case faceRole
        case exportRange
    }

    public var kind: Kind {
        switch self {
        case .galleryFilter: return .galleryFilter
        case .galleryPhoto: return .galleryPhoto
        case .cullingConflicts: return .cullingConflicts
        case .faceAnalyze: return .faceAnalyze
        case .faceRole: return .faceRole
        case .exportRange: return .exportRange
        }
    }
}
