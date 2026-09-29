// 跨页面共享的 URL 判定与 Finder 定位辅助。
// 合并来源：RootView / DashboardView / ExportView 的 isDirectoryURL（×3），
// SimilarityView / LibraryView / CullingView 的 finderURL(for path:)（×3）。
import Foundation

/// 拖放目录判定：Finder 拖入的目录 URL 通常带尾斜杠；无尾斜杠时回退资源值探测。
func isDirectoryURL(_ url: URL) -> Bool {
    if url.hasDirectoryPath { return true }
    return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
}

/// 右键「在 Finder 中显示」的 URL：路径为空或仅空白时返回 nil（跳过该项）。
/// 命名带 `ForPath` 以免与各视图内的同名成员（如 `GalleryView.finderURL(for:)`）发生重载歧义。
func finderURLForPath(_ path: String) -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
}
