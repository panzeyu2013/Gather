// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Delivery.swift
// W3：整套交付的视图模型动作（配方默认值 / 运行 / 汇总）。
//
// 配方持久化到 settings 的 output.recipes（空列表也会落盘，删除最后一个配方不会“复活”）；
// 运行走 ExportAPI.runRecipes（job output.run，服务端逐配方执行）。
// P0-6（Wave2）：配方编辑（字段更新 / 格式切换清理 / 中文校验 / 子目录解析）与
// OutputRunInput 冻结（联系表/画廊参数、相对子目录 → 绝对路径）。
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
        if let key = try? SettingsKeyInput("output.deliveryRoot"),
           let saved = try? await settingsAPI.get(key) {
            deliveryRoot = saved
        }
        do {
            let key = try SettingsKeyInput("output.recipes")
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

    /// 新建配方的默认值（P0-6）：只是默认值 —— 创建后所有字段都能在配方编辑器里改
    /// （旧实现是硬编码 85/2048 且不可编辑，这才是缺口本身）。
    static let newRecipeDefaults = OutputRecipe(
        name: "Recipe", format: .jpeg, quality: 85, maxDimension: 2048,
        includeMetadata: true, artifacts: [.photos, .contactSheet, .gallery])

    public func addDeliveryRecipe() {
        guard deliveryRecipes.count < 32 else { return }
        hasLoadedDeliveryRecipes = true
        var index = deliveryRecipes.count + 1
        var name = "Recipe \(index)"
        while deliveryRecipes.contains(where: { $0.name == name }) {
            index += 1
            name = "Recipe \(index)"
        }
        var recipe = Self.newRecipeDefaults
        recipe.name = name
        deliveryRecipes.append(recipe)
        persistDeliveryRecipes()
    }

    // MARK: - 配方编辑器（P0-6）

    /// 统一编辑入口：按 id 改一条配方（找不到 id 时 no-op）。
    ///
    /// 所有编辑器控件都走它，而不是各自 firstIndex + 下标写：
    /// ① 落盘由 ExportView+Delivery 的 .onChange(of: deliveryRecipes) 统一触发，
    ///    避免每条控件自己调度防抖任务；② 行视图只拿得到配方快照，不会写错下标。
    public func updateDeliveryRecipe(id: String, _ mutate: (inout OutputRecipe) -> Void) {
        guard let index = deliveryRecipes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&deliveryRecipes[index])
    }

    /// 切换格式时清掉该格式不成立的字段（P0-6 校验的一部分）：
    /// - 原图 = 字节复制：质量/长边/水印/色彩空间/DPI/锐化都不成立；
    /// - TIFF 不用 JPEG 质量参数；
    /// - 回到 JPEG 时给一个可编辑的默认质量（不是写死的唯一值）。
    public func setDeliveryRecipeFormat(id: String, format: ExportFormat) {
        updateDeliveryRecipe(id: id) { recipe in
            recipe.format = format
            switch format {
            case .original:
                recipe.quality = nil
                recipe.maxDimension = nil
                recipe.watermark = nil
                recipe.colorSpace = nil
                recipe.dpi = nil
                recipe.sharpening = nil
            case .jpeg:
                if recipe.quality == nil { recipe.quality = 85 }
            case .tiff:
                recipe.quality = nil
            }
        }
    }

    /// 水印字段编辑（内容/位置/透明度/字号）：没有水印时 no-op。
    /// 嵌套 optional 的读改写收在 VM，UI 只传增量，不重复解包。
    public func updateDeliveryWatermark(
        id: String, _ mutate: (inout ExportWatermark) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            guard var watermark = recipe.watermark else { return }
            mutate(&watermark)
            recipe.watermark = watermark
        }
    }

    /// 锐化参数编辑（半径/强度）：没有锐化时 no-op。
    public func updateDeliverySharpening(
        id: String, _ mutate: (inout ExportSharpening) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            guard var sharpening = recipe.sharpening else { return }
            mutate(&sharpening)
            recipe.sharpening = sharpening
        }
    }

    /// 命名模板编辑（pattern/counterStart/dateFormat）。
    public func updateDeliveryNaming(
        id: String, _ mutate: (inout ExportNaming) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            var naming = recipe.naming
            mutate(&naming)
            recipe.naming = naming
        }
    }

    // MARK: - Wave2：配方级联系表/画廊/子目录

    /// 联系表字段编辑：配方里还没有参数时按默认值物化一份再改。
    public func updateDeliveryContactSheet(
        id: String, _ mutate: (inout OutputContactSheetOptions) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            var value = recipe.contactSheet ?? OutputContactSheetOptions()
            mutate(&value)
            recipe.contactSheet = value
        }
    }

    /// 画廊字段编辑（同上）。
    public func updateDeliveryGallery(
        id: String, _ mutate: (inout OutputGalleryOptions) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            var value = recipe.gallery ?? OutputGalleryOptions()
            mutate(&value)
            recipe.gallery = value
        }
    }

    /// 配方级「是否产出联系表/画廊」：写 artifacts（顺序稳定 —— 会进配方指纹与
    /// job dedupeKey，不能靠 Set 遍历序）。
    public func setDeliveryRecipeArtifact(
        id: String, _ kind: OutputArtifactKind, isEnabled: Bool
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            var artifacts = Set(recipe.artifacts)
            if isEnabled {
                artifacts.insert(kind)
            } else {
                artifacts.remove(kind)
            }
            recipe.artifacts = OutputArtifactKind.allCases.filter { artifacts.contains($0) }
        }
    }

    /// 子目录模板编辑：清空模板 = 整个规则置 nil（旧配方兼容路径）。
    public func setDeliverySubdirectoryTemplate(id: String, template: String) {
        updateDeliveryRecipe(id: id) { recipe in
            let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                recipe.subdirectory = nil
                return
            }
            var value = recipe.subdirectory ?? ExportSubdirectory(template: template)
            value.template = template
            recipe.subdirectory = value
        }
    }

    /// 子目录 token 取值编辑（{client} / {event}）。
    public func updateDeliverySubdirectory(
        id: String, _ mutate: (inout ExportSubdirectory) -> Void
    ) {
        updateDeliveryRecipe(id: id) { recipe in
            guard var value = recipe.subdirectory else { return }
            mutate(&value)
            recipe.subdirectory = value
        }
    }

    /// 单个配方的字段校验（行内红字 + 交付前置门禁共用）。
    /// 返回中文字符串（即 l10n key），空数组 = 合法。
    public func deliveryRecipeIssues(_ recipe: OutputRecipe) -> [String] {
        var issues: [String] = []
        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("配方名不能为空")
        }
        if recipe.format == .original {
            // 原图格式只复制文件：转换类参数一律不成立（与 ExportService.validate 同口径）。
            if recipe.quality != nil || recipe.maxDimension != nil || recipe.watermark != nil
                || recipe.colorSpace != nil || recipe.dpi != nil || recipe.sharpening != nil {
                issues.append("原图格式只复制文件，不能设置质量、长边、水印、色彩空间、DPI 或锐化")
            }
        } else {
            if let quality = recipe.quality,
               quality.rounded() != quality || quality < 1 || quality > 100 {
                issues.append("JPEG 质量必须是 1 到 100 之间的整数")
            }
            if let dimension = recipe.maxDimension, dimension < 1 {
                issues.append("最长边必须是大于等于 1 的整数")
            }
            if let dpi = recipe.dpi, dpi < 1 || dpi > 2400 {
                issues.append("DPI 必须是 1 到 2400 之间的整数")
            }
            if let sharpening = recipe.sharpening {
                if !sharpening.radius.isFinite || sharpening.radius < 0.1
                    || sharpening.radius > 10 {
                    issues.append("锐化半径必须在 0.1 到 10 之间")
                }
                if !sharpening.intensity.isFinite || sharpening.intensity < 0
                    || sharpening.intensity > 2 {
                    issues.append("锐化强度必须在 0 到 2 之间")
                }
            }
            if let watermark = recipe.watermark {
                switch watermark.type {
                case .text:
                    if watermark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        issues.append("水印文字不能为空")
                    }
                    if let fontSize = watermark.fontSize,
                       !fontSize.isFinite || fontSize < 1 || fontSize > 1000 {
                        issues.append("水印字号必须在 1 到 1000 之间")
                    }
                case .image:
                    // Wave2：logo 存在性/可解码性由 ExportService.validate 在预检/执行
                    // 时强制校验；这里只做编辑期的形状与区间校验（不访问磁盘）。
                    if watermark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        issues.append("水印图片不能为空")
                    }
                    if let scale = watermark.imageScale,
                       !scale.isFinite || scale < 0.02 || scale > 1 {
                        issues.append("水印宽度比例必须在 2% 到 100% 之间")
                    }
                    if let margin = watermark.imageMargin,
                       !margin.isFinite || margin < 0 || margin > 0.25 {
                        issues.append("水印边距必须在 0% 到 25% 之间")
                    }
                }
                if !watermark.opacity.isFinite || watermark.opacity < 0
                    || watermark.opacity > 1 {
                    issues.append("水印透明度必须在 0 到 1 之间")
                }
            }
        }
        let pattern = recipe.naming.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty {
            issues.append("命名模式不能为空")
        }
        if recipe.naming.pattern.contains("/")
            || recipe.naming.pattern.contains("\\")
            || recipe.naming.pattern.contains("\0") {
            issues.append("命名模式不能包含路径分隔符")
        }
        if let counter = recipe.naming.counterStart, counter < 0 {
            issues.append("起始序号不能为负数")
        }
        if !Self.isValidDeliveryDestination(recipe.destination) {
            issues.append("子目录必须是交付根内的相对路径，且不能包含 ..")
        }
        // Wave2：子目录 token 规则复用协议层的唯一校验实现（不复制一套 token 表）。
        if let subdirectory = recipe.subdirectory,
           ExportSubdirectory.validationReason(for: subdirectory.template) != nil {
            // 提示文案用固定 key：具体原因（unknownToken/absolutePath/…）只进执行期
            // 错误 params，不拼进可翻译文案（否则 en 表无法覆盖）。
            issues.append(
                "子目录规则无效：只支持 {yyyy} {MM} {dd} {client} {event} {orig}，不能含绝对路径、.. 或未知 token")
        }
        if let sheet = recipe.contactSheet {
            if sheet.columns < 1 || sheet.columns > 12 {
                issues.append("联系表列数必须在 1 到 12 之间")
            }
            if sheet.rows < 1 || sheet.rows > 20 {
                issues.append("联系表行数必须在 1 到 20 之间")
            }
            if let margin = sheet.margin, !margin.isFinite || margin < 0 || margin > 200 {
                issues.append("联系表边距必须在 0 到 200 之间")
            }
        }
        if let gallery = recipe.gallery {
            if gallery.thumbnailMaxDimension < 160 || gallery.thumbnailMaxDimension > 2048 {
                issues.append("画廊缩略图长边必须在 160 到 2048 之间")
            }
            if gallery.largeMaxDimension < 320 || gallery.largeMaxDimension > 8192 {
                issues.append("画廊大图长边必须在 320 到 8192 之间")
            }
        }
        return issues
    }

    /// 整批校验（交付前置门禁）：逐配方字段 + 跨配方唯一性。
    /// - Parameter root: 交付根目录（把「空串 = 根/配方名」与相对子目录都解析成
    ///   绝对路径后再判重，等价于 OutputService.resolveDestinations 的冲突口径）。
    public func deliveryValidationIssues(root: String) -> [String] {
        var issues: [String] = []
        var seenNames = Set<String>()
        var seenDestinations = Set<String>()
        for recipe in deliveryRecipes {
            issues.append(contentsOf: deliveryRecipeIssues(recipe))
            let name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !seenNames.insert(name.lowercased()).inserted {
                issues.append("配方名不能重复")
            }
            let rawDestination = recipe.destination
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: String?
            if rawDestination.isEmpty {
                resolved = URL(fileURLWithPath: root)
                    .appendingPathComponent(name.isEmpty ? recipe.id : name)
                    .standardizedFileURL.path
            } else {
                resolved = resolvedDeliveryDestination(rawDestination, root: root)
            }
            if let resolved, !seenDestinations.insert(resolved).inserted {
                issues.append("两个配方写入了同一个输出目录")
            }
        }
        return issues
    }

    /// 配方输出目录解析（P0-6 子目录）：空串交给编排器（root/配方名）；
    /// 绝对路径原样（旧配方兼容）；相对子目录拼到交付根下。
    /// 非法相对路径返回 nil（由 deliveryRecipeIssues 给出中文提示）。
    func resolvedDeliveryDestination(_ destination: String, root: String) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") { return trimmed }
        guard Self.isValidRelativeSubdirectory(trimmed) else { return nil }
        return URL(fileURLWithPath: root)
            .appendingPathComponent(trimmed)
            .standardizedFileURL.path
    }

    /// 相对子目录是否安全：不能绝对、不能含 ..、空段、反斜杠或空字符。
    /// 空串合法（= 使用 root/配方名）。允许 {session}/{recipe}/{date}/{time} 占位符。
    static func isValidRelativeSubdirectory(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            return false
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// 配方目录字段的整体合法性：空串、绝对路径（旧配方）或安全相对子目录。
    static func isValidDeliveryDestination(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix("/") { return true }
        return isValidRelativeSubdirectory(trimmed)
    }

    public func removeDeliveryRecipe(id: String) {
        deliveryRecipes.removeAll { $0.id == id }
        persistDeliveryRecipes()
    }

    static var defaultRecipes: [OutputRecipe] {
        // Wave2：联系表/画廊改由每条配方自己的 artifacts 决定（旧实现是 run 级开关
        // 强行覆盖所有配方）；默认配方保留"Web 配方同时出联系表 + 画廊"的旧观感。
        [
            OutputRecipe(name: "Web 2048", format: .jpeg, quality: 82,
                         maxDimension: 2048, includeMetadata: true,
                         artifacts: [.photos, .contactSheet, .gallery]),
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

    /// 配方落盘（internal：配方编辑器测试直接调用，避免依赖 400ms 防抖定时器）。
    func persistDeliveryRecipes() {
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
            // #11：导入客户校样写的是 culling 决策（星级/色标/勾选），挑片页必须立刻看到。
            GatherEventCenter.postDomainChange(.culling, sessionId: sessionId)
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
    // DOMAIN-EVENT: none — 产物写 WebDAV，落在应用外；无常驻页消费者
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
    ///
    /// Wave2：联系表/画廊参数已迁到配方级（OutputRecipe.contactSheet/gallery），
    /// 页面不再传 run 级草稿；旧配方缺参数时在这里物化默认值（标题回落工作区名）。
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
        // P0-6：交付前置门禁——非法配方参数在这里显式中断并给中文原因，
        // 而不是让 OutputService/ExportService 跑到一半才失败。
        if let first = deliveryValidationIssues(root: root).first {
            errorMessage = CommandError.localized(first)
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
                // Wave2：子目录规则也要进预检，否则确认弹窗的文件名与真实写盘不一致。
                subdirectory: recipe.subdirectory,
                // P0-6：预检必须与 OutputService.run 的映射同源，否则确认 sheet 报的
                // 结果与真正执行的参数不同（配方编辑器里改色彩空间/DPI/锐化就失配）。
                colorSpace: recipe.colorSpace,
                dpi: recipe.dpi,
                sharpening: recipe.sharpening,
                tiffCompression: recipe.format == .tiff ? .lzw : nil,
                watermark: recipe.watermark,
                naming: recipe.naming,
                includeXmp: recipe.includeXmp || recipe.includeMetadata,
                // 与 OutputService.resolveDestinations 同口径：配方自带目录用它，
                // 否则用交付根（编排器再补 root/<配方名>）。旧实现一律用交付根，
                // 多配方写到不同子目录时预检的重名/空间诊断会与实际执行不一致。
                destination: recipe.destination.isEmpty
                    ? input.destinationRoot
                    : recipe.destination)
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
    // DOMAIN-EVENT: none — 导出产物落到目标目录，落在应用外；无常驻页消费者
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

    /// 冻结成 OutputRunInput（确认前唯一构造点）。
    ///
    /// Wave2：这里把**编辑器记法**翻译成协议契约：
    /// - 配方 destination 为相对子目录时 → 拼到交付根下的绝对路径
    ///   （协议 destination 契约要求绝对路径）；
    /// - 联系表/画廊参数已按配方保存；缺参数但勾了产物时物化默认值
    ///   （标题回落工作区名，与迁移前观感一致）；
    /// - 子目录 token 规则（recipe.subdirectory）原样透传给编排器逐字段转发。
    func makeDeliveryInput(root: String) -> OutputRunInput {
        let recipes = deliveryRecipes.map { recipe -> OutputRecipe in
            var updated = recipe
            // 相对子目录 → 绝对路径；非法值已被 prepareDeliveryInput 前置门禁拦下。
            if let resolved = resolvedDeliveryDestination(recipe.destination, root: root) {
                updated.destination = resolved
            }
            // 旧配方只有 artifacts、没有 per-recipe 参数：按 run 级默认物化一份，
            // 保证 OutputService 拿到的永远是「配方自带参数」。
            if updated.artifacts.contains(.contactSheet), updated.contactSheet == nil {
                var sheet = OutputContactSheetOptions()
                if sheet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sheet.title = sessionName ?? ""
                }
                updated.contactSheet = sheet
            }
            if updated.artifacts.contains(.gallery), updated.gallery == nil {
                var gallery = OutputGalleryOptions()
                if gallery.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    gallery.title = sessionName ?? "Gallery"
                }
                updated.gallery = gallery
            }
            // 顺序必须稳定：artifacts 会进配方指纹/job dedupeKey。
            let keptArtifacts = updated.artifacts
            updated.artifacts = OutputArtifactKind.allCases.filter { keptArtifacts.contains($0) }
            return updated
        }
        // run 级 contactSheet/gallery 留空：新协议下参数属于配方；OutputService 仍保留
        // 「配方 nil → run 级」的回落路径给旧 checkpoint 用。
        return OutputRunInput(
            sessionId: sessionId,
            scope: scope,
            selectedPhotoIds: scope == .selected ? selectedPhotoIds : nil,
            destinationRoot: root,
            recipes: recipes,
            contactSheet: nil,
            gallery: nil)
    }
}
