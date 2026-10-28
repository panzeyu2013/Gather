// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Delivery.swift
// W3：整套交付的视图模型动作（配方默认值 / 运行 / 汇总）。
//
// 配方持久化到 settings 的 output.recipes（空列表也会落盘，删除最后一个配方不会“复活”）；
// 运行走 ExportAPI.runRecipes（job output.run，服务端逐配方执行）。
import Foundation
import GatherProtocol

extension ExportViewModel {
    /// 交付根目录：留空时沿用当前导出目标目录。
    public var effectiveDeliveryRoot: String {
        deliveryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? destination : deliveryRoot
    }

    /// 首次进入：先读 settings output.recipes；只有“从未保存/坏 JSON”才种默认配方。
    /// 保存过空数组时保持空（删除最后一个配方不得在下次运行被复活）。
    public func loadDeliveryRecipes() async {
        guard deliveryRecipes.isEmpty, !hasLoadedDeliveryRecipes else { return }
        hasLoadedDeliveryRecipes = true
        if let settingsAPI {
            // 交付目录与配方一起载入：下次进来不用再手打绝对路径。
            if deliveryRoot.isEmpty, let key = try? SettingsKey("output.deliveryRoot") {
                if let saved = try? await settingsAPI.get(key), !saved.isEmpty {
                    deliveryRoot = saved
                }
            }
            do {
                let key = try SettingsKey("output.recipes")
                let raw = try await settingsAPI.get(key)
                if !raw.isEmpty, let data = raw.data(using: .utf8) {
                    let recipes = try JSONDecoder().decode([OutputRecipe].self, from: data)
                    deliveryRecipes = recipes
                    return
                }
            } catch {
                GatherLogger.log("output.recipes load failed: \(error)", level: .debug)
            }
        }
        deliveryRecipes = Self.defaultRecipes
    }

    public func addDeliveryRecipe() {
        guard deliveryRecipes.count < 32 else { return }
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
        guard let settingsAPI else { return }
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

    /// 导入客户校样（selection.json 原文）：勾选项写成 imported 决策。
    public func importClientSelection(json: String) async {
        guard let cullingAPI, !isImportingSelection else { return }
        isImportingSelection = true
        clientSelectionImport = nil
        errorMessage = nil
        defer { isImportingSelection = false }
        do {
            clientSelectionImport = try await cullingAPI.importClientSelection(
                Confirmed(ClientSelectionImportInput(sessionId: sessionId, json: json)))
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 发布到 WebDAV：先存凭据（Keychain），再上传目录。
    public func publishToWebDAV(
        localPath: String,
        baseURL: String,
        username: String,
        password: String,
        remoteFolder: String,
        includePrefixes: [String]? = nil
    ) async {
        guard !isPublishing else { return }
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
                    includePrefixes: includePrefixes)),
                onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        self?.publishProgress = (done: done, total: total)
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

    public func runDelivery() async {
        guard !isDelivering else { return }
        let root = effectiveDeliveryRoot
        guard !root.isEmpty else {
            errorMessage = CommandError.localized("请先选择交付目录")
            return
        }
        if !hasLoadedDeliveryRecipes { await loadDeliveryRecipes() }
        guard !deliveryRecipes.isEmpty else {
            deliverySummary = nil
            errorMessage = CommandError.localized("没有可用的交付配方，请先添加")
            return
        }
        persistDeliveryRecipes()
        isDelivering = true
        deliverySummary = nil
        errorMessage = nil
        defer { isDelivering = false }
        do {
            // 开关直接落到每条配方的 artifacts：编排层只按 artifacts 建联系表/画廊，
            // 不传就等于开关无效（曾经的 blocker）。
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
                // 顺序必须稳定：artifacts 会进配方指纹/job dedupeKey，
                // Set 的迭代顺序随进程哈希种子变化，会让“再交付一次”算出新键。
                updated.artifacts = OutputArtifactKind.allCases.filter { artifacts.contains($0) }
                return updated
            }
            let input = OutputRunInput(
                sessionId: sessionId,
                scope: scope,
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
            deliverySummary = try await exportAPI.runRecipes(Confirmed(input))
        } catch {
            // 取消不是失败：partial manifest 已由服务端写出，成片就在交付目录里。
            // 旧实现落一条「操作失败：发生未知错误」，同时让结果区（manifest/联系表/
            // 画廊/发布入口）整块消失，用户以为交付没发生过。
            if Self.isCancellation(error) {
                notice = LocalizedText("交付已取消；已写出的成片仍在交付目录中")
            } else {
                errorMessage = CommandError(error)
            }
        }
    }
}
