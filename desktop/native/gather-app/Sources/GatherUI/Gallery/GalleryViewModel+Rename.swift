// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Rename.swift
// Wave5（Batch4 / task-19）：图库「批量重命名 / 移动到文件夹」的 VM 动作。
//
// 分工：
// - 预览是只读（previewRename），不弹 Confirmed；
// - 执行是破坏性（写盘 + 改 photos.filepath）：Confirmed 只在用户点开 sheet 里的
//   确认按钮后构造，source 固定 .userDialog（取消分支不发命令）；
// - 成功后的统一收尾只有一处：缩略图缓存失效（路径变了）+ .library 域事件
//   （其它页读取照片路径）+ 就地刷新当前页（不切 loading、不清选择集）。
import Foundation
import GatherProtocol

extension GalleryViewModel {
    // MARK: - 预览（只读）

    /// 模板 → 旧/新/冲突。nil = 失败（原因已进 actionError）。
    func previewPhotoRename(photoIds: [String], template: String) async -> PhotoRenamePreview? {
        guard let photoAPI else {
            actionError = CommandError.localized("批量文件操作未接线（宿主未注入 PhotoAPI）。")
            return nil
        }
        do {
            let preview = try await photoAPI.previewRename(PhotoRenamePreviewInput(
                sessionId: sessionId, photoIds: photoIds, template: template))
            actionError = nil
            return preview
        } catch {
            actionError = CommandError(error)
            return nil
        }
    }

    // MARK: - 执行（破坏性：Confirmed 由 sheet 的确认分支构造）

    func performPhotoRename(
        photoIds: [String], template: String, policy: PhotoFileConflictPolicy
    ) async -> PhotoRenameResult? {
        guard let photoAPI else {
            actionError = CommandError.localized("批量文件操作未接线（宿主未注入 PhotoAPI）。")
            return nil
        }
        let input = PhotoRenameInput(
            sessionId: sessionId, photoIds: photoIds,
            template: template, conflictPolicy: policy)
        do {
            let result = try await photoAPI.renamePhotos(
                Confirmed(input, source: .userDialog))
            actionError = nil
            postLibraryChange()
            await refreshAfterFileOperation()
            return result
        } catch {
            actionError = CommandError(error)
            return nil
        }
    }

    func performPhotoMove(
        photoIds: [String], destinationRoot: String, policy: PhotoFileConflictPolicy
    ) async -> PhotoMoveResult? {
        guard let photoAPI else {
            actionError = CommandError.localized("批量文件操作未接线（宿主未注入 PhotoAPI）。")
            return nil
        }
        let input = PhotoMoveInput(
            sessionId: sessionId, photoIds: photoIds,
            destinationRoot: destinationRoot, conflictPolicy: policy)
        do {
            let result = try await photoAPI.movePhotos(
                Confirmed(input, source: .userDialog))
            actionError = nil
            postLibraryChange()
            await refreshAfterFileOperation()
            return result
        } catch {
            actionError = CommandError(error)
            return nil
        }
    }

    // MARK: - 收尾

    /// 写盘成功后的刷新收尾（域广播已在写函数体内发出，见 check-domain-writes R3）。
    ///
    /// 缩略图缓存按路径作键：改名/移动后旧键失效、新键未命中，必须整体失效一次。
    /// 不清选择集：photoId 未变（只是路径变了），refreshOnEvent 会按"仍存在"收敛；
    /// 清掉会让用户失去刚操作的那批照片的上下文。
    private func refreshAfterFileOperation() async {
        PhotoThumbnailCache.invalidateAll()
        await refresh()
    }
}
