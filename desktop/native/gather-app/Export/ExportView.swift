// Phase 3.6：导出、预览、取消和报告 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Export/index.tsx + export.ipc.ts。
// UI 对齐（§十一 11.4）：实时进度、命名预览、空间不足警告、原图格式控件门控。
import SwiftUI
import AppKit
import GatherCore

/// 进入导出页的入口意图（N05）：决定首次打开时的默认导出范围。
///
/// 为什么需要它：控制中心的「已挑片但尚未导出 → 去导出」在语义上是
/// 「把挑片成果导出」，但页面默认范围是「工作区全部照片」——用户点着
/// 「挑片成果」进来，看到的却是包含未决策照片的全量范围。
public enum ExportRangeIntent: Equatable, Sendable {
    /// 挑片成果入口：默认只导出保留片（挑片决策 = keep）。
    case picks
    /// 通用入口（工具栏页签直接进入）：默认工作区全部照片，由用户显式选择。
    case allPhotos
}

@MainActor
@Observable
public final class ExportViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var preview: ExportPreview?
    private(set) public var result: ExportResult?
    private(set) public var report: ReportData?
    private(set) public var isWorking = false
    private(set) public var isPreviewing = false
    private(set) public var isExporting = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    // 实时导出进度（events.job-progress 驱动）。
    private(set) public var exportProgress: (current: Int, total: Int)?
    // 当前导出文件名（从事件 checkpoint 的 destinations/completedPhotoIds 推导，
    // 路由只透传 current/total/message/checkpoint，未直接带 fileName）。
    private(set) public var currentFileName: String?
    // 行内错误定位（旧版行内红字；Banner 之外在对应字段附近重复提示）。
    public enum ExportFieldError: Equatable {
        case destination
        case quality
        case maxDimension
        case watermark
    }
    private(set) public var fieldError: ExportFieldError?
    // {session} 占位符的会话名（session.get 可选加载；失败保持「工作区」）。
    private(set) public var sessionName: String?

    public var format: ExportFormat = .original
    public var variantPolicy: ExportVariantPolicy = .preferred
    /// 导出范围（F04）。默认「保留片」不可行（未挑片时会导出 0 张），
    /// 因此默认「工作区全部照片」，由界面把两个范围与张数摆在一起让用户显式选择；
    /// 从控制中心「挑片已完成」进入时页面会突出保留片范围（见 ExportRangeSection）。
    public var scope: ExportScope = .session
    public var quality = "85"
    public var maxDimension = ""
    public var includeXmp = true
    public var namingPattern = "{original}"
    public var tiffCompression: ExportTiffCompression = .lzw
    public var watermarkEnabled = false
    public var watermarkText = ""
    public var watermarkPosition: ExportWatermarkPosition = .bottomRight
    public var watermarkOpacity = 0.5
    public var watermarkFontSize = "24"
    public var destination = ""

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    /// 应用一次入口意图（N05 / V2 审计 P1）。
    ///
    /// 语义是「事件」而不是「一次性播种」：外壳在每次入口点击时把意图交给页面，
    /// 页面应用后立刻通知外壳清空。这样
    ///   · 先前经过页签进过导出页，不会让之后的「去导出」失效；
    ///   · 后续从页签进入（意图为 nil）不会重复套用上一次的意图；
    ///   · 用户手动改过范围后再点「去导出」，仍然按这次点击的意图走。
    public func applyRangeIntent(_ intent: ExportRangeIntent?) {
        guard intent == .picks else { return }
        scope = .filtered
    }

    public var destinationIsEmpty: Bool {
        destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 对齐 TS：仅非原图格式参与尺寸/水印（原图格式下控件不渲染，UI 不可触达
    /// EXPORT_ORIGINAL_NO_TRANSFORM）。
    public var transformsAllowed: Bool { format != .original }

    /// TS export.tsx namingPreview：占位符实时替换预览 + 扩展名。
    public var namingPreview: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"
        let time = timeFormatter.string(from: Date())
        var name = namingPattern
        name = name.replacingOccurrences(of: "{date}", with: date)
        name = name.replacingOccurrences(of: "{time}", with: time)
        name = name.replacingOccurrences(of: "{counter}", with: "0001")
        name = name.replacingOccurrences(of: "{original}", with: "IMG_1234")
        // 会话名可取则用之；取不到（session.get 失败）保持「工作区」。
        name = name.replacingOccurrences(of: "{session}", with: sessionName ?? GatherLocalization.l("工作区"))
        switch format {
        case .jpeg: name += ".jpg"
        case .tiff: name += ".tiff"
        case .original: name += GatherLocalization.l(".扩展名")
        }
        return name
    }

    /// 预览空间不足（TS export.tsx:320-325 红色警告）；freeSpaceBytes<0 时
    /// 服务端未测得可用空间，不误报。
    public var spaceInsufficient: Bool {
        guard let preview, preview.freeSpaceBytes >= 0 else { return false }
        return preview.totalSizeBytes > preview.freeSpaceBytes
    }

    /// 对齐 TS export.tsx：progressPercent = Math.round(current/total*100)。
    public var progressPercent: Int? {
        guard let progress = exportProgress, progress.total > 0 else { return nil }
        return Int((Double(progress.current) / Double(progress.total) * 100).rounded())
    }

    /// 加载会话名供命名预览 {session} 占位（session.get 失败静默保持 nil）。
    public func loadSessionName() {
        guard sessionName == nil else { return }
        sessionName = try? client.execute("session.get", params: [
            "sessionId": .string(sessionId),
        ]).decoded(as: SessionData.self).name
    }

    /// events.job-progress 消费：仅当前工作区 export.execute 任务的进度帧。
    /// export.execute 的 checkpoint 携带 destinations（photoId → 导出文件名）
    /// 与按完成顺序追加的 completedPhotoIds；最近完成的 photoId 即当前文件。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .exportExecute,
              event.job.scopeId == sessionId else { return }
        if let current = event.update.current, let total = event.update.total {
            exportProgress = (current, total)
            currentFileName = Self.fileName(from: event.update.checkpoint)
        }
        if event.isTerminal {
            exportProgress = nil
            currentFileName = nil
            if event.job.status == .succeeded {
                // F2/E-2（审计 1/5）：终态帧只应在**本次结果还没落地**时兜一句文案。
                // 旧实现无条件改写：部分失败（任务状态仍是 succeeded）的
                //「成功 N 失败 M」会被事后覆盖成「导出任务已完成」，零项文案同理；
                // 同一 session 的其它导出终态帧也会污染本页 notice。
                if result == nil {
                    notice = Self.succeededNotice(from: event.update.checkpoint)
                }
            }
        }
    }

    /// 终态帧的完成文案（F3）：有交付摘要时按实际计数说清楚，而不是笼统一句「已完成」。
    private static func succeededNotice(from checkpoint: [String: GatherCore.JSONValue]?) -> String {
        let exported = Int(checkpoint?["exported"]?.numberValue ?? 0)
        let failed = Int(checkpoint?["failed"]?.numberValue ?? 0)
        let totalFiles = Int(checkpoint?["totalFiles"]?.numberValue ?? 0)
        if failed > 0 {
            return String(
                format: GatherLocalization.l("导出完成：成功 %lld 张，失败 %lld 张，请在结果中查看失败原因。"),
                exported,
                failed
            )
        }
        if totalFiles == 0 {
            return GatherLocalization.l("当前范围没有可导出的照片，未写入任何文件。")
        }
        return GatherLocalization.l("导出任务已完成")
    }

    private static func fileName(from checkpoint: [String: GatherCore.JSONValue]?) -> String? {
        guard let checkpoint,
              let photoId = checkpoint["completedPhotoIds"]?.arrayElements?.last?.stringValue,
              !photoId.isEmpty else { return nil }
        return checkpoint["destinations"]?.objectValue?[photoId]?.stringValue
    }

    public func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = GatherLocalization.l("选择导出目录")
        panel.message = GatherLocalization.l("请勿选择工作区导入目录或其子目录，否则导出的文件会被重新导入当前工作区")
        // 非阻塞：不再用 runModal()（会阻塞主线程并开嵌套 runloop），
        // 改用 begin 的 async 形式，返回后在 MainActor 上回填字段。
        Task { @MainActor in
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            destination = url.path
            errorMessage = nil
            fieldError = nil
        }
    }

    /// 拖放设置导出目录（与 chooseDestination 一致：写入并清除行内/横幅错误）。
    public func setDestinationPath(_ path: String) {
        destination = path
        errorMessage = nil
        fieldError = nil
    }

    /// 手动「预览」：B3（9-30 审查）——必须与自动刷新走**同一套**参数快照 + 请求序号，
    /// 否则「慢的手动预览 A」会覆盖「已经生效的自动预览 B」，屏幕上的清单属于旧参数，
    /// 而 isPlanStale 还认为计划有效（plannedSignature 也没被 A 更新）。
    public func previewExport() async {
        guard !destinationIsEmpty else {
            await run(isPreviewing: true) { throw ExportServiceError.destinationInvalid }
            return
        }
        let signature = planSignature
        let request: [String: GatherCore.JSONValue]
        do {
            request = try parameters()
        } catch {
            fieldError = Self.fieldError(for: error)
            errorMessage = NativeCommandClient.message(for: error)
            return
        }
        planGeneration += 1
        let generation = planGeneration
        await run(isPreviewing: true) {
            let data = try await self.client.executeAsync("export.preview", params: request)
            // 过期响应（期间用户改了参数或已有更新的预览请求）整份丢弃。
            guard self.planGeneration == generation, self.planSignature == signature else { return }
            self.preview = try data.decoded(as: ExportPreview.self)
            self.plannedSignature = signature
            self.planError = nil
            self.result = nil
            self.notice = GatherLocalization.l("预览已更新")
        }
    }

    /// 计划计算中（范围/目录变化后的静默刷新）。
    private(set) public var isPlanning = false
    /// 计划计算失败原因（行内展示，不进横幅：目录未设置是正常状态）。
    private(set) public var planError: String?
    /// 已计算出的计划的参数指纹（nil = 还没有有效计划）。
    private(set) public var plannedSignature: String?
    /// 请求代数：过期响应直接丢弃，避免「先发的慢请求」覆盖后发的新选择（N03）。
    private var planGeneration = 0

    /// 影响导出计划的全部参数指纹（N03）。
    ///
    /// 旧实现只监听范围和目录：把「变体」从首选改成 JPEG 后，页面仍显示上一个
    /// 计划的 NEF 与数量，直到手动点「预览」。凡是能改变导出文件集合的参数
    /// （范围/变体/格式/目录/命名/水印/XMP）都必须进入指纹。
    public var planSignature: String {
        let destinationKey = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let watermarkKey = (watermarkEnabled && transformsAllowed)
            ? "w:\(watermarkText):\(watermarkPosition.rawValue):\(watermarkOpacity):\(watermarkFontSize)"
            : "w:-"
        return [
            scope.rawValue,
            variantPolicy.rawValue,
            format.rawValue,
            destinationKey,
            namingPattern,
            includeXmp ? "xmp:1" : "xmp:0",
            watermarkKey,
        ].joined(separator: "|")
    }

    /// 当前屏幕上的计划是否已经过期（参数变过但还没重算完）。
    public var isPlanStale: Bool {
        preview == nil || plannedSignature != planSignature
    }

    /// 静默刷新导出计划（F04 / N03）：任何影响计划的参数变化后重算
    /// 「本次将导出多少张 + 文件清单」。
    ///
    /// 与 previewExport 的区别：不改写 notice、不弹错误横幅，失败只在范围区
    /// 行内说明。先把上一次的 preview 作废——宁可短暂显示「正在计算」，
    /// 也不能把旧参数的文件数留在屏幕上冒充当前选择。
    /// 去抖窗口内为 true（D-9 文案缺口：pending 期间摘要行会整行消失）。
    private(set) public var isPlanRefreshScheduled = false

    /// 视图的 300ms 去抖一调度就置位（refreshPlan 开始时清位）。
    func markPlanRefreshScheduled() {
        isPlanRefreshScheduled = true
    }

    public func refreshPlan() async {
        isPlanRefreshScheduled = false
        preview = nil
        plannedSignature = nil
        planError = nil
        guard !destinationIsEmpty else { return }
        let signature = planSignature
        planGeneration += 1
        let generation = planGeneration
        isPlanning = true
        defer { if planGeneration == generation { isPlanning = false } }
        do {
            let data = try await client.executeAsync("export.preview", params: try parameters())
            // 过期响应（用户已经改了参数）直接丢弃，绝不覆盖更新的选择。
            guard planGeneration == generation, planSignature == signature else { return }
            preview = try data.decoded(as: ExportPreview.self)
            plannedSignature = signature
            result = nil
        } catch {
            guard planGeneration == generation, planSignature == signature else { return }
            planError = NativeCommandClient.message(for: error)
        }
    }

    /// 组装「开始导出」确认载荷：先跑与 executeExport 同一套参数校验，
    /// 失败就地写行内错误并返回 nil（不弹确认、不发命令）。
    ///
    /// F04：确认弹窗里的文件数必须来自**当前范围**的真实导出计划。
    /// 旧实现直接取上次手动「预览」的缓存（没预览过就是 0），用户可能据此
    /// 确认一个与范围不符的导出。现在先重算计划，算不出来就不弹确认。
    /// 确认流程是否在进行中（D03：确认计算期间禁止重复发起）。
    private(set) public var isConfirming = false

    public func exportConfirmation() async -> ExportConfirmation? {
        // D03：先把**完整请求参数**冻结成一份快照，之后预览、展示、执行全部只用它。
        // 旧实现在 await 前后各读一次可变状态：等待预览期间用户改了目录/范围，弹窗
        // 就会把新目录和旧文件数拼在一起，执行时又读第三份参数。
        let request: [String: GatherCore.JSONValue]
        do {
            request = try parameters()
        } catch {
            fieldError = Self.fieldError(for: error)
            errorMessage = NativeCommandClient.message(for: error)
            return nil
        }
        let signature = planSignature
        let destinationSnapshot = destination
        let scopeSnapshot = scope
        guard !isConfirming else { return nil }
        isConfirming = true
        defer { isConfirming = false }
        do {
            let data = try await client.executeAsync("export.preview", params: request)
            // 计划返回后参数又被改过：这份计划已经不是用户点确认时看到的那份，
            // 丢弃确认并让自动刷新去算新计划（下一次点击会用新快照）。
            guard signature == planSignature else {
                errorMessage = nil
                notice = GatherLocalization.l("导出参数已变化，请确认新的导出计划")
                return nil
            }
            preview = try data.decoded(as: ExportPreview.self)
            plannedSignature = signature
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = Self.fieldError(for: error)
            return nil
        }
        return ExportConfirmation(
            destination: destinationSnapshot,
            // D09：确认文案用物理文件数（照片 + 边车）。
            fileCount: preview?.physicalFileCount ?? 0,
            scopeLabel: ExportConfirmation.scopeLabel(for: scopeSnapshot),
            planSignature: signature,
            request: request
        )
    }

    /// 确认弹窗取消：写可见文案（不静默 return），不发命令。
    public func reportExportCancelled() {
        notice = GatherLocalization.l("已取消导出")
        fieldError = nil
    }

    /// 执行导出。confirmed 只能由视图确认分支传 true；未确认时不下发确认载荷，
    /// 由路由门禁拒绝（EXPORT_CONFIRMATION_REQUIRED）——UI 不得自证确认。
    /// - Parameter request: 确认弹窗冻结的参数（D03）。传入时执行的就是被确认的
    ///   那一份，不再重新读界面状态；为 nil（无确认路径）则现读当前参数。
    public func executeExport(confirmed: Bool, request: [String: GatherCore.JSONValue]? = nil) async {
        exportProgress = nil
        currentFileName = nil
        await run {
            self.isExporting = true
            defer { self.isExporting = false }
            var params = try request ?? self.parameters()
            // 防御：调用方（视图）只能在确认分支传 confirmed: true；未确认时不下发载荷，
            // 由路由门禁拒绝（EXPORT_CONFIRMATION_REQUIRED）——UI 不得自证确认。
            if confirmed {
                params["confirmed"] = .bool(true)
            }
            let data = try await self.client.executeAsync("export.execute", params: params)
            let result = try data.decoded(as: ExportResult.self)
            self.result = result
            // D02：部分失败不得只报「已完成」——成功/失败数量都要说清楚，否则用户会
            // 以为本次交付完整（全失败由 EXPORT_ALL_FAILED 走错误横幅）。
            self.notice = result.failed > 0
                ? String(
                    format: GatherLocalization.l("导出完成：成功 %lld 张，失败 %lld 张，请在结果中查看失败原因。"),
                    result.exported,
                    result.failed
                )
                : (result.totalFiles == 0
                    // 零项（范围为空）：说「已完成」会让用户以为交付过了——明确说明没导出任何东西。
                    ? GatherLocalization.l("当前范围没有可导出的照片，未写入任何文件。")
                    : GatherLocalization.l("导出任务已完成"))
        }
        exportProgress = nil
        currentFileName = nil
    }

    public func cancelExport() {
        do {
            // export.cancel 在路由端恒返回 true（SessionCommandRouter.swift:1408-1412），
            // 无法区分 no-op（无导出任务时同样返回 true），因此保持提示展示。
            _ = try client.execute("export.cancel", params: [
                "sessionId": .string(sessionId),
            ])
            notice = GatherLocalization.l("已请求取消导出")
            fieldError = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = nil
        }
    }

    public func generateReport(format: ReportFormat) {
        do {
            report = try client.execute("export.report", params: [
                "sessionId": .string(sessionId),
                "reportType": .string("session_summary"),
                "format": .string(format.rawValue),
            ]).decoded(as: ReportData.self)
            notice = String(format: GatherLocalization.l("报告已生成：%@"), report?.path ?? "")
            fieldError = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = nil
        }
    }

    /// 对齐旧版 export.tsx:251 的 min=1：提交（回车/失焦）时把最长边钳制到 ≥1；
    /// 非数字前缀保持原值，交由现有字段校验提示。
    public func commitMaxDimension() {
        let trimmed = maxDimension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed.prefix(while: \.isNumber)) else { return }
        maxDimension = String(max(1, value))
    }

    /// 对齐旧版 export.tsx:277：字号输入 min=8 max=200，非法输入回退 24。
    public func commitWatermarkFontSize() {
        guard let value = Int(watermarkFontSize.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            watermarkFontSize = "24"
            return
        }
        watermarkFontSize = String(min(max(value, 8), 200))
    }

    /// 对齐 TS translateErrorLine：`filename: <错误码>` 行尾错误码翻译。
    /// 无法解析结构的行也整体走 errorText（未知诊断回退通用文案），
    /// 原始细节由 ExportService/日志承载，不经 UI 直显。
    public static func translateErrorLine(_ line: String) -> String {
        guard let separator = line.range(of: ": ") else {
            return GatherLocalization.errorText(line)
        }
        let tail = line[separator.upperBound...]
        return "\(line[..<separator.lowerBound]): \(GatherLocalization.errorText(String(tail)))"
    }

    private func parameters() throws -> [String: GatherCore.JSONValue] {
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportServiceError.destinationInvalid
        }
        let parsedQuality: Double?
        if format == .jpeg {
            guard let value = Double(quality), value.rounded() == value else {
                throw ExportServiceError.qualityInvalid
            }
            parsedQuality = value
        } else {
            parsedQuality = nil
        }
        let parsedDimension: Int?
        if format == .original {
            parsedDimension = nil
        } else if maxDimension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedDimension = nil
        } else if let value = Int(maxDimension.prefix(while: \.isNumber)), value > 0 {
            // 对齐 TS parseInt(maxDimension, 10)：小数截断（"12.5"→12）；
            // 非数字前缀 → nil → maxDimensionInvalid，保持安全路径。
            parsedDimension = value
        } else {
            throw ExportServiceError.maxDimensionInvalid
        }
        let options = ExportOptions(
            scope: scope,
            variantPolicy: variantPolicy,
            format: format,
            quality: parsedQuality,
            maxDimension: parsedDimension,
            tiffCompression: format == .tiff ? tiffCompression : nil,
            // 对齐 TS export.tsx:67-75：watermarkEnabled && watermarkText 才发送；
            // 勾选但文本为空时不发 watermark，不再以 EXPORT_WATERMARK_TEXT_EMPTY 阻断。
            watermark: transformsAllowed && watermarkEnabled && !watermarkText.isEmpty ? try watermark() : nil,
            // TS export.tsx:60-61：counterStart 1 / dateFormat YYYY-MM-DD。
            naming: ExportNaming(pattern: namingPattern, counterStart: 1, dateFormat: "YYYY-MM-DD"),
            includeXmp: includeXmp,
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return [
            "sessionId": .string(sessionId),
            "options": try GatherCore.JSONValue(from: options),
        ]
    }

    private func watermark() throws -> ExportWatermark {
        let text = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExportServiceError.watermarkTextEmpty }
        guard let fontSize = Double(watermarkFontSize), fontSize > 0 else {
            throw ExportServiceError.watermarkFontSizeInvalid
        }
        return ExportWatermark(
            type: .text,
            content: text,
            position: watermarkPosition,
            opacity: watermarkOpacity,
            fontSize: fontSize
        )
    }

    /// 对齐旧版行内错误定位：参数校验错误映射到对应字段附近展示。
    private static func fieldError(for error: Error) -> ExportFieldError? {
        switch error {
        case ExportServiceError.destinationInvalid,
             ExportServiceError.destinationAbsoluteRequired,
             ExportServiceError.destinationRootForbidden,
             ExportServiceError.destinationInsideSession:
            return .destination
        case ExportServiceError.qualityInvalid:
            return .quality
        case ExportServiceError.maxDimensionInvalid:
            return .maxDimension
        case ExportServiceError.watermarkTextEmpty,
             ExportServiceError.watermarkFontSizeInvalid,
             ExportServiceError.watermarkOpacityInvalid:
            return .watermark
        default:
            break
        }
        // 路由/桥接层错误按错误码前缀兜底（如 EXPORT_DIR_INSIDE_SESSION）。
        // 注：Error 到 CustomStringConvertible 的条件转换恒成功（编译器 #alwaysSucceeds），
        // 且 String(describing:) 对实现了 description 的类型即取该 description，语义等价。
        let text = String(describing: error)
        if text.contains("EXPORT_DIR") || text.contains("DESTINATION") { return .destination }
        if text.contains("QUALITY") { return .quality }
        if text.contains("MAX_DIMENSION") { return .maxDimension }
        if text.contains("WATERMARK") { return .watermark }
        return nil
    }

    private func run(isPreviewing: Bool = false, _ operation: @escaping () async throws -> Void) async {
        isWorking = true
        if isPreviewing { self.isPreviewing = true }
        errorMessage = nil
        fieldError = nil
        defer {
            isWorking = false
            if isPreviewing { self.isPreviewing = false }
        }
        do {
            try await operation()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            fieldError = Self.fieldError(for: error)
        }
    }
}

/// 「开始导出」确认载荷：弹窗文案的事实来源（目的地 + 范围 + 本次将写入的文件数）。
public struct ExportConfirmation: Equatable, Identifiable {
    public var destination: String
    public var fileCount: Int
    /// 范围文案（F04）：导出范围必须出现在确认文案里，不能让用户靠猜。
    public var scopeLabel: String
    /// 计划指纹（D03）：确认的是**哪一份计划**；执行前参数若已变化，这份确认作废。
    public var planSignature: String
    /// **冻结的请求参数**（D03）：确认后执行的就是这一份，不再重新读界面状态。
    ///
    /// 旧实现只保存展示用的目录/数目/范围文案，确认回调再调 executeExport，由它
    /// 重新读一遍 ViewModel 的可变参数：用户在预览等待期间改了目录或范围，
    /// 弹窗显示「新目录 + 旧文件数」，执行的又是第三份参数。
    public var request: [String: GatherCore.JSONValue]
    public var id: String { destination + "|" + scopeLabel + "|" + planSignature }

    public init(
        destination: String,
        fileCount: Int,
        scopeLabel: String,
        planSignature: String,
        request: [String: GatherCore.JSONValue]
    ) {
        self.destination = destination
        self.fileCount = fileCount
        self.scopeLabel = scopeLabel
        self.planSignature = planSignature
        self.request = request
    }

    public static func scopeLabel(for scope: ExportScope) -> String {
        switch scope {
        case .filtered: return GatherLocalization.l("保留片（挑片决策为保留）")
        case .session: return GatherLocalization.l("工作区全部照片")
        case .selected: return GatherLocalization.l("所选照片")
        }
    }
}

public struct ExportView: View {
    /// 由外壳注入（N04：跨页签保留导出草稿），或本页自建（独立预览/测试）。
    /// 计划重算去抖任务（D-9）。
    @State private var planDebounceTask: Task<Void, Never>?

    @State private var viewModel: ExportViewModel
    /// 入口意图（N05）：控制中心的「去导出」= 挑片成果，默认保留片。
    private let rangeIntent: ExportRangeIntent?
    /// 消费完意图后通知外壳清空（V2 审计 P1：意图是「每次入口点击」的事件）。
    private let onConsumeRangeIntent: () -> Void
    /// 非空即弹确认；confirmed 载荷只在确认分支写出（UI 不得自证确认）。
    @State private var pendingExport: ExportConfirmation?
    @FocusState private var maxDimensionFocused: Bool
    @FocusState private var watermarkFontSizeFocused: Bool
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void

    /// 外壳注入 VM 的初始化器：同一工作区的导出草稿（目录/格式/命名/范围/预览）
    /// 在切换页签后原样恢复（N04），而不是每次重新建一个 ViewModel。
    init(
        viewModel: ExportViewModel,
        router: CommandRouter,
        rangeIntent: ExportRangeIntent? = nil,
        onConsumeRangeIntent: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.rangeIntent = rangeIntent
        self.onConsumeRangeIntent = onConsumeRangeIntent
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    init(
        sessionId: String,
        router: CommandRouter,
        rangeIntent: ExportRangeIntent? = nil,
        onConsumeRangeIntent: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: ExportViewModel(sessionId: sessionId, router: router))
        self.rangeIntent = rangeIntent
        self.onConsumeRangeIntent = onConsumeRangeIntent
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 行内字段错误已就近定位（fieldError），横幅仅展示行内不可见的一般错误，
            // 避免同源重复提示。
            if let error = viewModel.errorMessage, viewModel.fieldError == nil {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if let notice = viewModel.notice {
                NativeBanner(text: notice, color: GatherTheme.success)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            // 导出选项/预览/结果全部走系统分组表单（行标签由系统对齐）。
            Form {
                exportProgressSection
                // 范围先于输出细节（F04）：先回答「导出哪些照片」，再问格式/命名。
                rangeSection
                optionsSection
                previewSection
                resultSection
            }
            .formStyle(.grouped)
        }
        .background(GatherTheme.windowBackground)
        .task {
            viewModel.loadSessionName()
            // N05：应用本次入口意图（挑片成果 → 默认保留片），随后通知外壳清空。
            viewModel.applyRangeIntent(rangeIntent)
            onConsumeRangeIntent()
            await viewModel.refreshPlan()
        }
        // F04 + N03：任何影响导出计划的参数变化都重算计划
        //（范围 / 变体 / 格式 / 目录 / 命名 / 水印 / 复制 XMP），
        // 保证摘要、清单、确认弹窗与实际输出始终同源。
        // D-9/C-P0-2（性能审计）：planSignature 含命名模式与水印文字，旧实现
        // 每键入一个字符就全量 export.preview（1 万张 ≈5 万次 syscall/字符）。
        // 这里 300ms 去抖：停止输入后才重算；预览/确认按钮仍会即时刷新。
        // P1：离开页面即取消挂起的计划重算（否则切页后仍会发一次全量 preview）。
        .onDisappear {
            planDebounceTask?.cancel()
        }
        .onChange(of: viewModel.planSignature) { _, _ in
            planDebounceTask?.cancel()
            viewModel.markPlanRefreshScheduled()
            planDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await viewModel.refreshPlan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .gatherDestructiveConfirm(
            pending: $pendingExport,
            title: GatherLocalization.l("开始导出？"),
            confirmLabel: { _ in GatherLocalization.l("开始导出") },
            message: { request in
                // D09：承诺的文件数必须是**物理文件数**（照片 + XMP 边车），
                // 旧实现只报照片数，勾选「复制 XMP」时承诺与实际不符。
                String(
                    format: GatherLocalization.l("范围「%@」：将向「%@」写入 %lld 个文件；重名文件会自动改名，不会覆盖已有文件。"),
                    request.scopeLabel,
                    request.destination,
                    request.fileCount
                )
            },
            onConfirm: { confirmation in
                // confirmed: true 只能从这个确认分支到达；执行的参数就是用户确认的
                // 那份快照（D03），不再重读界面状态。
                Task { await viewModel.executeExport(confirmed: true, request: confirmation.request) }
            },
            onCancel: { _ in viewModel.reportExportCancelled() }
        )
        .sessionPageChrome(
            subtitle: GatherLocalization.l("按统一格式、命名规则导出照片及元数据"),
            selection: .tab(.export),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack()
                } label: {
                    Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
                }
                .help(GatherLocalization.l("返回到上一页"))
            }
            // 页面级动作（预览 / 开始导出 / 取消导出）上移到工具栏，
            // 取代旧版自绘 sticky actionBar 卡片。
            ToolbarItemGroup(placement: .primaryAction) {
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(viewModel.isPreviewing ? GatherLocalization.l("正在计算…") : GatherLocalization.l("预览"), systemImage: "eye") {
                    // P1（第二轮验证）：预览会自己在 VM 里发起 preview，若留着
                    // 待触发的去抖任务，它 300ms 后还会 refreshPlan（入口先清空 preview）
                    // → 用户看到清单「自己消失一个往返」。
                    planDebounceTask?.cancel()
                    Task { await viewModel.previewExport() }
                }
                .disabled(viewModel.isWorking || viewModel.destinationIsEmpty)
                .help(GatherLocalization.l("预览本次导出的文件清单与空间占用"))
                // 对齐旧版 export.tsx:192：仅导出进行中禁用，预览不互斥（旧版可并发）。
                Button(viewModel.isExporting ? GatherLocalization.l("正在导出…") : GatherLocalization.l("开始导出"), systemImage: "square.and.arrow.up.fill") {
                    // 参数校验通过、且当前范围能算出导出计划，才弹确认；
                    // 确认载荷只在 onConfirm 分支下发（F04：文件数与范围同源）。
                    Task { pendingExport = await viewModel.exportConfirmation() }
                }
                // 唯一的 primary action，固定放尾侧（HIG Toolbars）。
                .gatherPrimaryActionButton()
                .disabled(viewModel.isExporting || viewModel.destinationIsEmpty)
                // 对齐旧版 export.tsx:195：取消仅在导出进行中可用（预览期间禁用）。
                // F06：改为只在导出进行中出现——禁用态常驻只会白白占掉工具栏预算。
                if viewModel.isExporting {
                    Button(GatherLocalization.l("取消导出"), systemImage: "stop.circle") {
                        viewModel.cancelExport()
                    }
                    .help(GatherLocalization.l("取消正在进行的导出"))
                }
            }
        }
    }

    /// 导出中实时进度（TS export.tsx:334-346）：原生线性 ProgressView + 百分比 +
    /// `第 N/N 张 · 文件名`；executeExport 进行中但首帧进度未到（exportProgress
    /// == nil）时显示「正在准备导出…」。
    @ViewBuilder
    private var exportProgressSection: some View {
        if let progress = viewModel.exportProgress {
            Section(GatherLocalization.l("正在导出照片…")) {
                LabeledContent(GatherLocalization.l("进度")) {
                    Text(percentText)
                        .monospacedDigit()
                        .foregroundStyle(GatherTheme.accent)
                }
                ProgressView(value: Double(progress.current) / Double(max(1, progress.total)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(GatherLocalization.l("导出进度"))
                    .accessibilityValue(Text(percentText))
                Text(String(format: GatherLocalization.l("第 %lld/%lld 张%@"), progress.current, progress.total, currentFileSuffix))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.isExporting {
            Section(GatherLocalization.l("正在准备导出…")) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(GatherLocalization.l("导出进度"))
            }
        }
    }

    private var percentText: String {
        viewModel.progressPercent.map { "\($0)%" } ?? ""
    }

    private var currentFileSuffix: String {
        guard let name = viewModel.currentFileName, !name.isEmpty else { return "" }
        return " · \(name)"
    }

    /// 导出范围（F04）：范围决定「哪些照片会被写出」，必须在格式/命名之前先回答，
    /// 并给出与预览、确认弹窗、实际输出**同源**的张数摘要（都来自同一次
    /// export.preview 计划）。旧实现固定发送整个工作区范围，界面却引导用户
    /// 「挑片完成后导出最终成品」，承诺与结果不符。
    private var rangeSection: some View {
        Section(GatherLocalization.l("导出范围")) {
            Picker(GatherLocalization.l("导出范围"), selection: $viewModel.scope) {
                Text(ExportConfirmation.scopeLabel(for: .filtered))
                    .tag(ExportScope.filtered)
                Text(ExportConfirmation.scopeLabel(for: .session))
                    .tag(ExportScope.session)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(GatherLocalization.l("导出范围"))

            // 张数摘要只在计划与当前参数同源时显示（N03）：参数一变，
            // refreshPlan 会立刻把 preview 作废，这里不会残留旧范围的数字。
            if let preview = viewModel.preview, !viewModel.isPlanStale {
                LabeledContent(GatherLocalization.l("本次将导出")) {
                    Text(String(format: GatherLocalization.l("%lld 个文件"), preview.totalFiles))
                        .monospacedDigit()
                }
                if viewModel.scope == .filtered, preview.totalFiles == 0 {
                    Text(GatherLocalization.l("当前没有「保留」的照片：请先在挑片页做出保留决策，或把范围改为「工作区全部照片」。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.destinationIsEmpty {
                Text(GatherLocalization.l("选择导出目录后显示本次将导出的文件数。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if viewModel.isPlanning || viewModel.isPlanRefreshScheduled {
                // 去抖 pending 期间也要占位（否则参数一变摘要行整行消失、无任何提示）。
                Text(GatherLocalization.l("正在计算本次导出的文件数…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let planError = viewModel.planError {
                Text(String(format: GatherLocalization.l("无法计算导出计划：%@"), planError))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
            }
        }
    }

    /// 导出选项：系统分组表单。每行一个 LabeledContent，标签由系统对齐；
    /// Picker 自带标签一律 .labelsHidden()，避免「Text("格式") + Picker("格式")」重复。
    private var optionsSection: some View {
        Section(GatherLocalization.l("导出选项")) {
            LabeledContent(GatherLocalization.l("格式")) {
                Picker(GatherLocalization.l("格式"), selection: $viewModel.format) {
                    Text(GatherLocalization.l("原图")).tag(ExportFormat.original)
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                }
                .labelsHidden()
            }
            LabeledContent(GatherLocalization.l("变体")) {
                Picker(GatherLocalization.l("变体"), selection: $viewModel.variantPolicy) {
                    Text(GatherLocalization.l("首选")).tag(ExportVariantPolicy.preferred)
                    Text("RAW").tag(ExportVariantPolicy.raw)
                    Text("JPEG").tag(ExportVariantPolicy.jpeg)
                    Text(GatherLocalization.l("全部")).tag(ExportVariantPolicy.all)
                }
                .labelsHidden()
            }
            if viewModel.format == .jpeg {
                LabeledContent(GatherLocalization.l("JPEG 质量")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(viewModel.quality) ?? 85 },
                            set: { viewModel.quality = String(Int($0)) }
                        ), in: 1...100, step: 1)
                        .accessibilityLabel(GatherLocalization.l("JPEG 质量"))
                        Text(String(format: GatherLocalization.l("质量： %@"), viewModel.quality))
                            .font(.callout.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                fieldError(.quality)
            }
            if viewModel.transformsAllowed {
                LabeledContent(GatherLocalization.l("最长边")) {
                    // 对齐旧版 export.tsx:251：placeholder「不限制」、min=1（提交时钳制）。
                    TextField(GatherLocalization.l("不限制"), text: $viewModel.maxDimension)
                        .labelsHidden()
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(GatherLocalization.l("最长边"))
                        .focused($maxDimensionFocused)
                        .onSubmit { viewModel.commitMaxDimension() }
                        .onChange(of: maxDimensionFocused) { _, isFocused in
                            if !isFocused { viewModel.commitMaxDimension() }
                        }
                }
                fieldError(.maxDimension)
            }
            LabeledContent(GatherLocalization.l("命名模式")) {
                TextField(
                    GatherLocalization.l("命名模式"),
                    text: $viewModel.namingPattern,
                    prompt: Text("{date}/{time}/{counter}/{original}/{session}")
                )
                .labelsHidden()
            }
            Text(String(format: GatherLocalization.l("示例：%@"), viewModel.namingPreview))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if viewModel.format == .tiff {
                LabeledContent(GatherLocalization.l("TIFF 压缩")) {
                    Picker(GatherLocalization.l("TIFF 压缩"), selection: $viewModel.tiffCompression) {
                        Text(GatherLocalization.l("无压缩")).tag(ExportTiffCompression.none)
                        Text("LZW").tag(ExportTiffCompression.lzw)
                        Text("Deflate").tag(ExportTiffCompression.deflate)
                    }
                    .labelsHidden()
                }
            }
            Toggle(GatherLocalization.l("复制 XMP 侧车文件"), isOn: $viewModel.includeXmp)
            if viewModel.transformsAllowed {
                Toggle(GatherLocalization.l("添加文字水印"), isOn: $viewModel.watermarkEnabled)
                if viewModel.watermarkEnabled {
                    TextField(GatherLocalization.l("水印文字"), text: $viewModel.watermarkText)
                        .accessibilityLabel(GatherLocalization.l("水印文字"))
                    LabeledContent(GatherLocalization.l("位置")) {
                        Picker(GatherLocalization.l("位置"), selection: $viewModel.watermarkPosition) {
                            Text(GatherLocalization.l("居中")).tag(ExportWatermarkPosition.center)
                            Text(GatherLocalization.l("右下")).tag(ExportWatermarkPosition.bottomRight)
                            Text(GatherLocalization.l("左下")).tag(ExportWatermarkPosition.bottomLeft)
                        }
                        .labelsHidden()
                    }
                    LabeledContent(GatherLocalization.l("字号")) {
                        TextField(GatherLocalization.l("字号"), text: $viewModel.watermarkFontSize)
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(GatherLocalization.l("字号"))
                            .focused($watermarkFontSizeFocused)
                            .onSubmit { viewModel.commitWatermarkFontSize() }
                            .onChange(of: watermarkFontSizeFocused) { _, isFocused in
                                if !isFocused { viewModel.commitWatermarkFontSize() }
                            }
                    }
                    LabeledContent(GatherLocalization.l("透明度")) {
                        HStack(spacing: 10) {
                            Slider(value: $viewModel.watermarkOpacity, in: 0.1...1, step: 0.1)
                                .accessibilityLabel(GatherLocalization.l("透明度"))
                            Text("\(Int(viewModel.watermarkOpacity * 100))%")
                                .font(.callout.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    fieldError(.watermark)
                }
            }
            LabeledContent(GatherLocalization.l("导出目录")) {
                HStack(spacing: 8) {
                    // E 报告：占位与下方脚注重复，且过长会在窄窗口被截断。
                    TextField(GatherLocalization.l("选择导出目录"), text: $viewModel.destination)
                        .labelsHidden()
                        .accessibilityLabel(GatherLocalization.l("导出目录"))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first(where: { isDirectoryURL($0) }) else { return false }
                            viewModel.setDestinationPath(url.path)
                            return true
                        }
                    Button(GatherLocalization.l("选择…"), action: viewModel.chooseDestination)
                }
            }
            // 对齐旧版 export.folderHint 警告（TS L301-303）。
            Text(GatherLocalization.l("请选择导出文件夹。不要选择工作区导入目录，否则导出的文件会被重新导入当前工作区。"))
                .font(.callout).foregroundStyle(.secondary)
            fieldError(.destination)
        }
    }

    /// 行内错误（旧版 export.module.css .error 行内红字）；Banner 保留，
    /// 对应字段附近再重复提示一次以就近定位。
    /// 行内错误（旧版 export.module.css .error 行内红字）；Banner 保留，
    /// 对应字段附近再重复提示一次以就近定位。
    @ViewBuilder
    private func fieldError(_ field: ExportViewModel.ExportFieldError) -> some View {
        if viewModel.fieldError == field, let message = viewModel.errorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(GatherTheme.error)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        // P1：去抖窗口内旧参数的文件清单不得继续显示（张数摘要行已有同款守卫）。
        if let preview = viewModel.preview, !viewModel.isPlanStale {
            Section(GatherLocalization.l("预览")) {
                LabeledContent(GatherLocalization.l("文件"), value: "\(preview.totalFiles)")
                LabeledContent(GatherLocalization.l("大小"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.totalSizeBytes), countStyle: .file))
                // TS export.tsx:320-325：freeSpaceBytes<0 时隐藏该行且无警告。
                if preview.freeSpaceBytes >= 0 {
                    LabeledContent(GatherLocalization.l("可用空间"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.freeSpaceBytes), countStyle: .file))
                }
                if viewModel.spaceInsufficient {
                    // warning 对比度不足以做正文前景色：改用原生提示条（图标 + 低透明度底色）。
                    NativeBanner(
                        text: GatherLocalization.l("导出文件所需空间超过磁盘可用空间，请更换目标目录"),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.warning
                    )
                }
                // D09：清单描述**输出**（目标名 + 格式 + 边车），并给出逐项可执行性诊断；
                // 旧实现列的是源文件名 + 源大小，与真正写出的文件无关。
                if preview.sidecarCount > 0 {
                    Text(String(
                        format: GatherLocalization.l("将写入 %lld 张照片 + %lld 个 XMP 边车，共 %lld 个文件。"),
                        preview.photoCount,
                        preview.sidecarCount,
                        preview.physicalFileCount
                    ))
                    .font(.callout)
                }
                if preview.issueCount > 0 {
                    Label(
                        String(format: GatherLocalization.l("其中 %lld 项存在问题，导出时会失败。"), preview.issueCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(GatherTheme.warning)
                }
                ForEach(preview.files.prefix(8), id: \.photoId) { file in
                    HStack(spacing: 6) {
                        Text(file.outputName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.includesXmp {
                            Text("+XMP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let issue = file.issue {
                            Text(GatherLocalization.errorText(issue))
                                .font(.caption)
                                .foregroundStyle(GatherTheme.warning)
                        }
                        Spacer(minLength: 0)
                        Text("\(file.isSizeEstimate ? "≈" : "")" + ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if preview.files.count > 8 {
                    Text(String(format: GatherLocalization.l("还有 %lld 个文件…"), preview.files.count - 8))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result = viewModel.result {
            Section(GatherLocalization.l("结果")) {
                Text(String(format: GatherLocalization.l("导出完成：成功 %lld，失败 %lld，跳过 %lld"), result.exported, result.failed, result.skipped))
                    .font(.callout)
                    .foregroundStyle(result.failed > 0 ? GatherTheme.error : GatherTheme.success)
                // 对齐 TS export.tsx:91：错误明细最多 3 条。
                ForEach(result.errors.prefix(3), id: \.self) { error in
                    Text(ExportViewModel.translateErrorLine(error))
                        .font(.callout)
                        .foregroundStyle(GatherTheme.error)
                }
                HStack(spacing: 8) {
                    Button(GatherLocalization.l("生成 CSV 报告")) { viewModel.generateReport(format: .csv) }
                    Button(GatherLocalization.l("生成 Markdown 报告")) { viewModel.generateReport(format: .md) }
                }
                if let report = viewModel.report {
                    Text(report.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
