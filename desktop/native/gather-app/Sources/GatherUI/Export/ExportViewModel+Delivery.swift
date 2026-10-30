// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Delivery.swift
// W3：整套交付的视图模型动作（配方默认值 / 运行 / 汇总）。
//
// 配方持久化到 settings 的 output.recipes（空列表也会落盘，删除最后一个配方不会“复活”）；
// 运行走 ExportAPI.runRecipes（job output.run，服务端逐配方执行）。
import Foundation
import GatherProtocol


/// P2-1：整套交付预检汇总（只计算结果，不写文件）。
struct DeliveryPreflightSummary: Equatable {
    let recipeCount: Int
    let totalFiles: Int
    let totalSizeBytes: Int
    let freeSpaceBytes: Int
    let issueCount: Int
    let failedRecipeNames: [String]

    var hasEnoughSpace: Bool {
        freeSpaceBytes < 0 || totalSizeBytes <= freeSpaceBytes
    }
}

extension ExportViewModel {
    /// 交付根目录：留空时沿用当前导出目标目录。
    public var effectiveDeliveryRoot: String {
        deliveryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? destination : deliveryRoot
    }

    /// P0：设置变化只作废缓存并原地重读，**不允许先清空数组**。
    ///
    /// 清空会被 ExportView+Delivery 的 `.onChange(of: deliveryRecipes)` 防抖落盘成
    /// "[]"：用户自建配方永久丢失，且「保存过空数组保持空」会让默认配方也不再播种。
    /// 内容没变就不改数组，避免 `onChange` 产生任何写回。
    func invalidateDeliveryRecipes() {
        hasLoadedDeliveryRecipes = false
        recipeReloadTask?.cancel()
        recipeReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recipes = await self.readDeliveryRecipes()
            guard !Task.isCancelled, let recipes else { return }
            self.hasLoadedDeliveryRecipes = true
            if recipes != self.deliveryRecipes { self.deliveryRecipes = recipes }
        }
    }

    /// 首次进入：先读 settings output.recipes；只有“从未保存/坏 JSON”才种默认配方。
    /// 保存过空数组时保持空（删除最后一个配方不得在下次运行被复活）。
    public func loadDeliveryRecipes() async {
        guard deliveryRecipes.isEmpty, !hasLoadedDeliveryRecipes else { return }
        hasLoadedDeliveryRecipes = true
        let recipes = await readDeliveryRecipes() ?? Self.defaultRecipes
        if recipes != deliveryRecipes { deliveryRecipes = recipes }
    }

    /// 只读 settings，不改内存：nil = 读取失败（调用方保留现状），
    /// 空串/坏 JSON 与旧实现一致地回落默认配方。
    private func readDeliveryRecipes() async -> [OutputRecipe]? {
        guard let settingsAPI else { return Self.defaultRecipes }
        // 交付目录与配方一起载入；settingsChanged（reset/清除用户内容）后即使
        // 当前值非空也必须重读，否则已清空的旧目录会在下次交付被写回 settings。
        if let key = try? SettingsKey("output.deliveryRoot"),
           let saved = try? await settingsAPI.get(key) {
            deliveryRoot = saved
        }
        do {
            let key = try SettingsKey("output.recipes")
            let raw = try await settingsAPI.get(key)
            if !raw.isEmpty, let data = raw.data(using: .utf8) {
                do { return try JSONDecoder().decode([OutputRecipe].self, from: data) } catch {
                    // 坏 JSON 与旧实现一致：回落默认配方。
                }
            }
        } catch {
            GatherLogger.log("output.recipes load failed: \(error)", level: .debug)
            return nil
        }
        return Self.defaultRecipes
    }

    public func addDeliveryRecipe() {
        guard deliveryRecipes.count < 32 else { return }
        hasLoadedDeliveryRecipes = true
        var index = deliveryRecipes.count + 1
        var name = "Recipe \(index)"
        while deliveryRecipes.contains(where: { $0.name == name }) {
            index += 1
            name = "Recipe \(index)"
        }
        deliveryRecipes.append(OutputRecipe(
            name: name, format: .jpeg, quality: 85, maxDimension: 2048))
        persistDeliveryRecipes()
    }

    public func removeDeliveryRecipe(id: String) {
        deliveryRecipes.removeAll { $0.id == id }
        persistDeliveryRecipes()
    }

    static var defaultRecipes: [OutputRecipe] {
        [
            OutputRecipe(name: "Web 2048", format: .jpeg, quality: 82,
                         maxDimension: 2048, includeMetadata: true,
                         artifacts: [.photos, .contactSheet]),
            OutputRecipe(name: "Print TIFF", format: .tiff, quality: nil,
                         maxDimension: nil, includeMetadata: true, artifacts: [.photos]),
        ]
    }

    /// 编辑（改名/改格式）后防抖落盘：连续输入只写最后一次，避免乱序覆盖。
    public func schedulePersistDeliveryRecipes() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.persistDeliveryRecipes()
        }
    }

    private func persistDeliveryRecipes() {
        // P0：未完成首次载入前不得落盘——否则会把「尚未读到的空数组」覆盖用户配方。
        guard let settingsAPI, hasLoadedDeliveryRecipes else { return }
        let json: String
        do {
            let data = try JSONEncoder().encode(deliveryRecipes)
            guard let encoded = String(data: data, encoding: .utf8) else { return }
            json = encoded
        } catch {
            GatherLogger.log("output.recipes encode failed: \(error)", level: .warn)
            return
        }
        // 串成单链：每次写等上一次写完，避免两次写乱序（旧快照后落盘会让已删的配方
        // 在下次启动时复活）。只保留最后一份快照，中间态不需要落盘。
        let previous = persistWriteTask
        persistWriteTask = Task {
            _ = await previous?.value
            do {
                try await settingsAPI.set(SettingsSetInput(key: "output.recipes", value: json))
            } catch {
                GatherLogger.log("output.recipes persist failed: \(error)", level: .warn)
            }
        }
    }

    /// 导入客户校样（selection.json 原文，v1/v2 都认）：
    /// 勾选写成 imported 决策，星级/色标按设置入队，评论只落库。
    /// - Returns: 完整导入报告（含冲突/评论数），供调用方弹结果 sheet；失败返回 nil。
    @discardableResult
    public func importClientSelection(json: String) async -> ClientSelectionImportReport? {
        guard let cullingAPI, !isImportingSelection else { return nil }
        isImportingSelection = true
        clientSelectionImport = nil
        errorMessage = nil
        defer { isImportingSelection = false }
        do {
            let report = try await cullingAPI.importClientSelection(
                Confirmed(ClientSelectionImportInput(sessionId: sessionId, json: json)))
            // 旧徽标仍用 v1 形态（picked/applied/skipped/failed），既有文案不变。
            clientSelectionImport = report.selection
            return report
        } catch {
            errorMessage = CommandError(error)
            return nil
        }
    }

    /// 发布到 WebDAV：先存凭据（Keychain），再上传目录。
    ///
    /// 白名单**必填**：空列表说明上层没能从 manifest 推出产物清单，此时宁可不发布，
    /// 也绝不"回退成整目录上传"（会把历史 manifest、成片目录、用户杂物一起传上去）。
    /// allowDownload = false 时只传缩略图与校样页（大图/成片不上传）。
    public func publishToWebDAV(
        localPath: String,
        baseURL: String,
        username: String,
        password: String,
        remoteFolder: String,
        includePrefixes: [String],
        allowDownload: Bool
    ) async {
        guard !isPublishing else { return }
        guard !includePrefixes.isEmpty else {
            // 上一轮的残留结果必须清掉，否则面板会显示上一次的"发布成功"。
            webDAVPublish = nil
            errorMessage = CommandError.localized("无法确定发布清单，已取消发布")
            return
        }
        isPublishing = true
        webDAVPublish = nil
        publishProgress = nil
        errorMessage = nil
        notice = nil
        defer {
            isPublishing = false
            publishProgress = nil
        }
        do {
            // 空密码 = 沿用已保存的凭据；不能用空串覆盖 Keychain（否则第二次发布必 401）。
            if !password.isEmpty {
                _ = try await exportAPI.saveWebDAVCredential(WebDAVCredentialInput(
                    baseURL: baseURL, username: username, password: password))
            }
            webDAVPublish = try await exportAPI.publish(
                Confirmed(WebDAVPublishInput(
                    localPath: localPath, baseURL: baseURL,
                    username: username, remoteFolder: remoteFolder,
                    includePrefixes: includePrefixes,
                    share: OutputShareOptions(
                        allowDownload: allowDownload, remoteSubfolder: remoteFolder))),
                // 外层闭包显式弱持有：内层 Task 的 [weak self] 与外层的强捕获不一致
                // （#ImplicitStrongCapture），也避免发布流程被闭包延长 VM 生命周期。
                onProgress: { [weak self] done, total in
                    Task { @MainActor in
                        // 守卫：只在"仍在发布中 + 结果尚未落地"时更新。取消/成功后
                        // 迟到的进度帧会把已清空的进度条写回「已上传 n/N」。
                        guard let self, self.isPublishing, self.webDAVPublish == nil else {
                            return
                        }
                        self.publishProgress = (done: done, total: total)
                    }
                })
        } catch {
            // 取消是正常终态（用户点了「停止发布」），不落红色错误条。
            if Self.isCancellation(error) {
                notice = LocalizedText("发布已取消")
            } else {
                errorMessage = CommandError(error)
            }
        }
    }

    /// 交付目录落盘（与配方共用串行链，避免乱序覆盖）。
    public func persistDeliveryRoot() {
        guard let settingsAPI else { return }
        let value = deliveryRoot
        let previous = persistWriteTask
        persistWriteTask = Task {
            _ = await previous?.value
            do {
                try await settingsAPI.set(
                    SettingsSetInput(key: "output.deliveryRoot", value: value))
            } catch {
                GatherLogger.log("output.deliveryRoot persist failed: \(error)", level: .warn)
            }
        }
    }

    /// 取消整套交付（job 粒度）：取消 output.run scope 与执行器里的导出任务。
    public func cancelDelivery() async {
        guard isDelivering else { return }
        do {
            _ = try await exportAPI.cancel(sessionId)
        } catch {
            GatherLogger.log("cancel delivery failed: \(error)", level: .warn)
        }
    }

    /// 取消是正常终态（JobCancelledError / CancellationError）：不落红色错误条，
    /// 与 DuplicatesViewModel / FaceKeywordingViewModel 同一口径。
    static func isCancellation(_ error: Error) -> Bool {
        if error is any JobCancellationMarker { return true }
        if error is CancellationError { return true }
        return CommandError(error).code.localizedCaseInsensitiveContains("cancelled")
    }

    /// P2-1：先把交付参数校验/冻结成输入，交给确认 sheet；确认前不执行。
    public func prepareDeliveryInput() async -> OutputRunInput? {
        guard !isDelivering else { return nil }
        let root = effectiveDeliveryRoot
        guard !root.isEmpty else {
            errorMessage = CommandError.localized("请先选择交付目录")
            return nil
        }
        if !hasLoadedDeliveryRecipes { await loadDeliveryRecipes() }
        guard !deliveryRecipes.isEmpty else {
            deliverySummary = nil
            errorMessage = CommandError.localized("没有可用的交付配方，请先添加")
            return nil
        }
        if scope == .selected && selectedPhotoIds.isEmpty {
            errorMessage = CommandError.localized("请选择要交付的照片")
            return nil
        }
        persistDeliveryRecipes()
        return makeDeliveryInput(root: root)
    }


    /// P2-1：逐配方跑一次 export.preview，汇总文件数/体积/空间/可执行性问题。
    /// 预览失败不阻断确认，但会在 sheet 中列出失败配方。
    func deliveryPreflight(for input: OutputRunInput) async -> DeliveryPreflightSummary {
        guard !isPreflighting else {
            return DeliveryPreflightSummary(
                recipeCount: input.recipes.count, totalFiles: 0, totalSizeBytes: 0,
                freeSpaceBytes: -1, issueCount: 0, failedRecipeNames: [])
        }
        isPreflighting = true
        defer { isPreflighting = false }
        var totalFiles = 0
        var totalSize = 0
        var freeSpace = -1
        var issueCount = 0
        var failedRecipes: [String] = []
        for recipe in input.recipes {
            let options = ExportOptions(
                scope: input.scope,
                selectedPhotoIds: input.selectedPhotoIds,
                variantPolicy: .preferred,
                format: recipe.format,
                quality: recipe.quality,
                maxDimension: recipe.maxDimension,
                tiffCompression: recipe.format == .tiff ? .lzw : nil,
                watermark: recipe.watermark,
                naming: recipe.naming,
                includeXmp: recipe.includeXmp || recipe.includeMetadata,
                destination: input.destinationRoot)
            do {
                let preview = try await exportAPI.preview(
                    ExportInput(sessionId: input.sessionId, options: options))
                totalFiles += preview.totalFiles
                totalSize += preview.totalSizeBytes
                if preview.freeSpaceBytes >= 0 {
                    freeSpace = freeSpace < 0
                        ? preview.freeSpaceBytes
                        : min(freeSpace, preview.freeSpaceBytes)
                }
                issueCount += preview.files.filter { $0.issue != nil }.count
            } catch {
                failedRecipes.append(recipe.name)
            }
        }
        return DeliveryPreflightSummary(
            recipeCount: input.recipes.count,
            totalFiles: totalFiles,
            totalSizeBytes: totalSize,
            freeSpaceBytes: freeSpace,
            issueCount: issueCount,
            failedRecipeNames: failedRecipes)
    }

    /// 确认 sheet 的唯一下一动作：执行冻结好的输入（不再重读界面状态）。
    /// 确认 sheet 的唯一执行入口：只能拿到确认分支构造的 Confirmed，VM 不再
    /// 自行“补”用户确认（D-011 / DEVELOPMENT.md §523）。
    public func executeDelivery(_ input: Confirmed<OutputRunInput>) async {
        guard !isDelivering else { return }
        isDelivering = true
        deliverySummary = nil
        errorMessage = nil
        defer { isDelivering = false }
        notice = nil
        noticeKind = .success
        do {
            deliverySummary = try await exportAPI.runRecipes(input)
        } catch {
            // 取消不是失败：partial manifest 已由服务端写出，成片就在交付目录里。
            if Self.isCancellation(error) {
                notice = LocalizedText("交付已取消；已写出的成片仍在交付目录中")
                noticeKind = .info
            } else {
                errorMessage = CommandError(error)
            }
        }
    }

    private func makeDeliveryInput(root: String) -> OutputRunInput {
        // 开关直接落到每条配方的 artifacts：编排层只按 artifacts 建联系表/画廊。
        let recipes = deliveryRecipes.map { recipe -> OutputRecipe in
            var updated = recipe
            var artifacts = Set(updated.artifacts)
            if deliveryIncludeContactSheet {
                artifacts.insert(.contactSheet)
            } else {
                artifacts.remove(.contactSheet)
            }
            if deliveryIncludeGallery {
                artifacts.insert(.gallery)
            } else {
                artifacts.remove(.gallery)
            }
            // 顺序必须稳定：artifacts 会进配方指纹/job dedupeKey。
            updated.artifacts = OutputArtifactKind.allCases.filter { artifacts.contains($0) }
            return updated
        }
        return OutputRunInput(
            sessionId: sessionId,
            scope: scope,
            selectedPhotoIds: scope == .selected ? selectedPhotoIds : nil,
            destinationRoot: root,
            recipes: recipes,
            contactSheet: deliveryIncludeContactSheet
                ? OutputContactSheetOptions(
                    title: sessionName ?? "", subtitle: "", footer: "", columns: 4, rows: 5)
                : nil,
            gallery: deliveryIncludeGallery
                ? OutputGalleryOptions(
                    title: sessionName ?? "Gallery", subtitle: "", footer: "",
                    thumbnailMaxDimension: 480, largeMaxDimension: 1600)
                : nil)
    }
}
