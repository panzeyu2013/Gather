// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+Load.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出加载与支持数据（原 395-586 行）。
// 纯搬移：加载顺序（sessions -> support -> 首页照片）、支持数据单项失败不阻塞
// 图库主查询、智能相册/资产关联/孤立 XMP/离线卷的破坏性 confirmed 门控与
// 事件广播逐字未动。
import Foundation
import AppKit
import GatherProtocol

extension LibraryViewModel {

    // MARK: 加载

    func load() async {
        phase = .loading
        await reloadSessions()
        await reloadSupport()
        await reload()
    }

    func reloadSessions() async {
        do {
            sessions = try await provider.listSessions()
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 加载 Library 页面除照片分页外的三组支持数据。
    /// 任一组失败不会阻塞图库主查询，但会保留可见错误，避免静默降级。
    /// B6b：孤立 XMP 列表走 MetadataAPI.orphans（async），因此本方法改为 async；
    /// 其余三组保持同步、顺序与错误语义不变。
    public func reloadSupport() async {
        do { albums = try await provider.listAlbums() }
        catch { actionError = CommandError(error) }
        do { assetCandidates = try await provider.listAssetCandidates() }
        catch { actionError = CommandError(error) }
        do { metadataOrphans = try await provider.listMetadataOrphans() }
        catch { actionError = CommandError(error) }
        do { assetVolumes = try await provider.listAssetVolumes() }
        catch { actionError = CommandError(error) }
    }

    /// 智能相册选择沿用 TS 的页码归零和 query key 语义。
    public func selectAlbum(_ albumId: String?) {
        guard selectedAlbumId != albumId else { return }
        selectedAlbumId = albumId
        page = 0
        // D06：相册与筛选共用同一个写入入口，条件变化同样要作废在途响应。
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(0, isFirst: true)
        }
    }

    public func createAlbum(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await performSupportMutation {
            _ = try await self.provider.createAlbum(
                name: trimmed,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try await self.provider.listAlbums()
            Self.postLibraryChange()
        }
    }

    public func updateSelectedAlbum() async {
        guard let albumId = selectedAlbumId else { return }
        await performSupportMutation {
            try await self.provider.updateAlbum(
                albumId: albumId,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try await self.provider.listAlbums()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 删除智能相册（破坏性：删除相册规则本身，不删除照片文件）。
    /// confirmed 由视图确认弹窗注入：true 只能从确认分支到达（见 LibraryView
    /// 的 pendingDeleteAlbum + gatherDestructiveConfirm）。
    public func deleteAlbum(id: String, confirmed: Bool) async {
        await performSupportMutation {
            try await self.provider.deleteAlbum(albumId: id, confirmed: confirmed)
            if self.selectedAlbumId == id { self.selectedAlbumId = nil }
            self.albums = try await self.provider.listAlbums()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 关联候选决策（accept = 合并为一个资产；reject = 拒绝/拆分）。
    /// 两者都在命令层受 confirmed 门控，故同样由确认动作注入。
    public func updateCandidate(
        _ candidate: AssetLinkCandidateData,
        accept: Bool,
        confirmed: Bool
    ) async {
        await performSupportMutation {
            try await self.provider.updateAssetCandidate(
                candidateId: candidate.id,
                accept: accept,
                confirmed: confirmed
            )
            self.assetCandidates = try await self.provider.listAssetCandidates()
            self.assetVolumes = try await self.provider.listAssetVolumes()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 孤立 XMP 处置。restore（恢复原片）会用备份覆盖照片文件、不可撤销 →
    /// 必须来自确认弹窗；retry/keep 是可逆决策，按下的按钮本身就是用户决定。
    ///
    /// B6b：MetadataAPI 只接收 Confirmed<T>；未确认时在 VM 本地以
    /// METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED 拒绝（与旧路由门禁同码），
    /// 不发任何请求、也不伪造确认来源。
    public func resolveOrphan(
        _ orphan: MetadataOrphan,
        action: MetadataOrphanAction,
        confirmed: Bool
    ) async {
        await performSupportMutation {
            guard confirmed else {
                throw GatherError(code: .METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED)
            }
            let input = try MetadataResolveOrphanInput(xmpPath: orphan.xmpPath, action: action)
            self.metadataOrphans = try await self.provider.resolveMetadataOrphan(
                Confirmed(input, source: .userDialog)
            )
            Self.postMetadataChange()
        }
    }

    /// 只负责让用户选新根目录并返回结果，**不发命令**：调用方拿到新旧根后再弹
    /// 确认（确认文案需要同时写清 oldRoot → newRoot 与影响范围）。
    /// Cut 4 / 4b-2d：VM 没有语言源，面板文案由调用方（带 environment 的页面）
    /// 以显式 l10n 传入——不在 VM 里读进程级语言，也不做 allowlist 例外。
    public func chooseRelinkRoot(with l10n: L10n) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l10n("选择新目录")
        // 第三轮审计 F：runModal 会阻塞主线程并开嵌套 runloop（同库其它面板
        // 早已改成 begin）。这里用 async 版本，等待期间界面保持响应。
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// 重新关联存储卷根（破坏性：改写该根下全部文件的路径记录）。
    public func relinkVolume(root oldRoot: String, newRoot: String, confirmed: Bool) async {
        await performSupportMutation {
            _ = try await self.provider.relinkAssetRoot(
                oldRoot: oldRoot,
                newRoot: newRoot,
                confirmed: confirmed
            )
            self.assetVolumes = try await self.provider.listAssetVolumes()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 本页发出的事件标识：监听方据此跳过自己触发的刷新（避免自触发重查）。
    public static let changeOrigin = "library"

    /// 库级写成功后的广播（相册/资产/离线卷）：常驻页按域刷新自己的数据。
    private static func postLibraryChange() {
        GatherEventCenter.postDomainChange(.library, sessionId: nil, origin: Self.changeOrigin)
    }

    /// 元数据写成功后的广播（孤立 XMP 处置等 XMP 写回族）。
    private static func postMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: nil, origin: Self.changeOrigin)
    }

    /// 用户取消破坏性操作：写可见文案（不静默 return），且**不发任何命令**。
    public func reportActionCancelled() {
        actionError = CommandError.localized("已取消：未执行任何破坏性操作。")
    }

    private func performSupportMutation(_ operation: @escaping () async throws -> Void) async {
        guard !isSupportBusy else { return }
        isSupportBusy = true
        defer { isSupportBusy = false }
        do {
            try await operation()
            actionError = nil
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 按当前已提交筛选取第一页（offset 0）。
    private func reload() async {
        await fetchPage(0, isFirst: true)
    }
}
