import Foundation

/// 一个工作区页面的唯一身份。
///
/// 取代旧的 `SessionTab` / `SessionWorkspace.Page` 并行建模（旧类型已删除）。
/// 保留现有 case 名（gallery / faceKw）以减少工作区可见性路由的迁移面；
/// 展示名由视图层按语言解析，枚举本身不持有 L10n。
public enum SessionPage: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case gallery
    case similarity
    case control
    case faceKw = "face-kw"
    case duplicates
    case culling
    case export

    public var id: String { rawValue }

    /// 页签展示顺序：浏览 → 相似度 → 控制中心 → 人脸 → 重复 → 挑片 → 导出。
    public static let tabOrder: [SessionPage] = [
        .gallery, .similarity, .control, .faceKw, .duplicates, .culling, .export,
    ]

    /// 中文原文 key（英文表在 en.lproj 里查）。
    public var titleKey: String {
        switch self {
        case .gallery: return "浏览"
        case .similarity: return "相似度"
        case .control: return "控制中心"
        case .faceKw: return "人脸"
        case .duplicates: return "重复"
        case .culling: return "挑片"
        case .export: return "导出"
        }
    }

}
