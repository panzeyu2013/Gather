// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel.swift
// Cut 4 / 4c-2f：从 ExportView.swift 抽出导出页视图模型（原 27-624 行）。
// 本文件只放状态 + 跨文件共享成员；行为按域拆到四个 extension：
//   +Preview（手动预览）/ +Plan（计划指纹与静默刷新）/ +Execute（确认/执行/取消）/
//   +Report（报告）。跨文件 extension 需要写回的属性 setter 由 private(set)
//   放宽为 internal(set)，声明、默认值与文案逐字未动——行为不变。
//
// Cut 1 / B6b：export.preview / execute / cancel / report 走 AppServices.export
// （ExportAPI），execute 只接收 Confirmed<ExportInput>，确认分支是唯一调用点。
// Cut 1 / B8.2a：命名预览的 {session} 占位走 SessionAPI.get（loadSessionName）。
import SwiftUI
import AppKit
import GatherProtocol

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
public final class ExportViewModel: PageVisibility {
    // Cut 1 / B6b：导出域走类型化 API（preview/execute/cancel/report）。
    let exportAPI: any ExportAPI
    /// W3：客户校样回传（可选；nil = 未接线，导入按钮隐藏）。
    let cullingAPI: (any CullingAPI)?
    /// W3：交付配方持久化（settings output.recipes）；nil = 不持久化（预览/测试）。
    let settingsAPI: (any SettingsAPI)?
    /// Cut 1 / B8.2a：会话名（命名预览的 {session} 占位）走 SessionAPI.get。
    private let sessionAPI: any SessionAPI
    public let sessionId: String
    public internal(set) var preview: ExportPreview?
    public internal(set) var result: ExportResult?
    public internal(set) var report: ReportData?
    private(set) public var isWorking = false
    private(set) public var isPreviewing = false
    public internal(set) var isExporting = false
    public internal(set) var errorMessage: CommandError?
    public internal(set) var notice: LocalizedText?
    // 实时导出进度（events.job-progress 驱动）。
    public internal(set) var exportProgress: (current: Int, total: Int)?
    // W3：整套交付（多配方 + 联系表）的状态。
    public var deliveryRoot = ""
    public var deliveryRecipes: [OutputRecipe] = []
    public var deliveryIncludeContactSheet = true
    public var deliveryIncludeGallery = true
    /// 配方是否已从 settings 载入（区分“从未保存”与“保存了空数组”）。
    public internal(set) var hasLoadedDeliveryRecipes = false
    /// 配方编辑的防抖持久化任务。
    var persistTask: Task<Void, Never>?
    /// 配方落盘的串行链尾：保证「删了配方」不会被更早的快照覆盖回来。
    var persistWriteTask: Task<Void, Never>?
    public internal(set) var clientSelectionImport: ClientSelectionImportResult?
    public internal(set) var isImportingSelection = false
    public internal(set) var webDAVPublish: WebDAVPublishSummary?
    public internal(set) var isPublishing = false
    /// 发布进度（已完成 / 总数）：长任务必须有可见进度，否则按钮只停在「正在发布…」。
    public internal(set) var publishProgress: (done: Int, total: Int)?
    public internal(set) var deliverySummary: OutputRunSummary?
    public internal(set) var isDelivering = false
    // 当前导出文件名（从事件 checkpoint 的 destinations/completedPhotoIds 推导，
    // 路由只透传 current/total/message/checkpoint，未直接带 fileName）。
    public internal(set) var currentFileName: String?
    // 行内错误定位（旧版行内红字；Banner 之外在对应字段附近重复提示）。
    public enum ExportFieldError: Equatable {
        case destination
        case quality
        case maxDimension
        case watermark
    }
    public internal(set) var fieldError: ExportFieldError?
    // {session} 占位符的会话名（session.get 可选加载；失败保持「工作区」）。
    private(set) public var sessionName: String?

    /// 可见性门控（Cut 4 / 4a-2c）：导出页的重算去抖 Task 由 View 持有，
    /// VM 侧只落可见性，供 SessionWorkspace.setVisible 统一扇出。
    /// WP4d：默认不可见（PageVisibility 契约），只读给生命周期矩阵断言。
    private(set) var isVisible = false
    /// 关闭终态（SessionWorkspace.close 扇出）：不再接受可见性切换。
    public private(set) var isShutdown = false

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

    public init(
        sessionId: String,
        export: any ExportAPI,
        session: any SessionAPI,
        culling: (any CullingAPI)? = nil,
        settings: (any SettingsAPI)? = nil
    ) {
        self.sessionId = sessionId
        self.exportAPI = export
        self.sessionAPI = session
        self.cullingAPI = culling
        self.settingsAPI = settings
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2c）

    /// 可见性唯一入口（PageVisibility）：默认不可见，重复调用幂等；
    /// shutdown 之后 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown, transitionVisibility(&isVisible, to: visible) else { return }
    }

    /// 关闭：导出页没有 VM 持有的长任务（计划重算 Task 归 View），
    /// 这里只落终态；已排队的重算在关闭后不再被重新置可见。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
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
    /// Cut 4 / 4b-2h：文案（"工作区" / ".扩展名"）由调用方传入的 L10n 在渲染期解析，
    /// VM 不读进程级 appLanguage。
    public func namingPreview(with l10n: L10n) -> String {
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
        name = name.replacingOccurrences(of: "{session}", with: sessionName ?? l10n("工作区"))
        switch format {
        case .jpeg: name += ".jpg"
        case .tiff: name += ".tiff"
        case .original: name += l10n(".扩展名")
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
    ///
    /// B8.2a：SessionAPI.get 只有 async 形态；原先的同步命令调用改由页面 .task
    /// await（失败语义不变：不打断导出表单，{session} 继续显示「工作区」）。
    public func loadSessionName() async {
        guard sessionName == nil else { return }
        sessionName = try? await sessionAPI.get(sessionId).name
    }

    // MARK: - 计划 / 确认状态（行为在 +Plan / +Execute）

    /// 计划计算中（范围/目录变化后的静默刷新）。
    public internal(set) var isPlanning = false
    /// 计划计算失败原因（行内展示，不进横幅：目录未设置是正常状态）。
    public internal(set) var planError: CommandError?
    /// 已计算出的计划的参数指纹（nil = 还没有有效计划）。
    public internal(set) var plannedSignature: String?
    /// 请求代数：过期响应直接丢弃，避免「先发的慢请求」覆盖后发的新选择（N03）。
    var planGeneration = 0
    /// 去抖窗口内为 true（D-9 文案缺口：pending 期间摘要行会整行消失）。
    public internal(set) var isPlanRefreshScheduled = false
    /// 确认流程是否在进行中（D03：确认计算期间禁止重复发起）。
    public internal(set) var isConfirming = false

    /// events.job-progress 消费：仅当前工作区 output.run 任务的进度帧。
    /// output.run 的 checkpoint 携带 destinations（photoId → 导出文件名）
    /// 与按完成顺序追加的 completedPhotoIds；最近完成的 photoId 即当前文件。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .outputRun,
              event.job.scopeId == sessionId else { return }
        // 整套交付与单张导出共用 job 类型：批量 job 的终态帧会把本页改成
        // “当前范围没有可导出的照片”，这里按 checkpoint 标记过滤。
        if event.job.checkpoint["outputRun"]?.boolValue == true { return }
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
    private static func succeededNotice(from checkpoint: [String: JSONValue]?) -> LocalizedText {
        let exported = Int(checkpoint?["exported"]?.numberValue ?? 0)
        let failed = Int(checkpoint?["failed"]?.numberValue ?? 0)
        let totalFiles = Int(checkpoint?["totalFiles"]?.numberValue ?? 0)
        if failed > 0 {
            return LocalizedText(
                "导出完成：成功 %lld 张，失败 %lld 张，请在结果中查看失败原因。",
                params: ["\(exported)", "\(failed)"]
            )
        }
        if totalFiles == 0 {
            return LocalizedText("当前范围没有可导出的照片，未写入任何文件。")
        }
        return LocalizedText("导出任务已完成")
    }

    private static func fileName(from checkpoint: [String: JSONValue]?) -> String? {
        guard let checkpoint,
              let photoId = checkpoint["completedPhotoIds"]?.arrayElements?.last?.stringValue,
              !photoId.isEmpty else { return nil }
        return checkpoint["destinations"]?.objectValue?[photoId]?.stringValue
    }

    /// Cut 4 / 4b-2h：NSOpenPanel 的 prompt/message 由调用方传入的 L10n 渲染
    /// （VM 不读进程全局语言）；面板文案在打开瞬间固定，与系统面板生命周期一致。
    public func chooseDestination(with l10n: L10n) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l10n("选择导出目录")
        panel.message = l10n("请勿选择工作区导入目录或其子目录，否则导出的文件会被重新导入当前工作区")
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
    public static func translateErrorLine(_ line: String, with l10n: L10n) -> String {
        guard let separator = line.range(of: ": ") else {
            return l10n.errorText(line)
        }
        let tail = line[separator.upperBound...]
        return "\(line[..<separator.lowerBound]): \(l10n.errorText(String(tail)))"
    }

    /// 对齐旧版行内错误定位：参数校验错误映射到对应字段附近展示。
    static func fieldError(for error: Error) -> ExportFieldError? {
        // Cut 3 / 3b-3（E-19 相邻）：按 GatherError 码定位字段。UI 自身校验与
        // ExportAPI 返回的校验错误现在同为 GatherError，分支只需一套。
        if let gather = error as? GatherError {
            switch gather.code {
            case .EXPORT_DIR_INVALID,
                 .EXPORT_DIR_ABSOLUTE_REQUIRED,
                 .EXPORT_DIR_ROOT_FORBIDDEN,
                 .EXPORT_DIR_INSIDE_SESSION:
                return .destination
            case .EXPORT_JPEG_QUALITY_INVALID:
                return .quality
            case .EXPORT_MAX_DIMENSION_INVALID:
                return .maxDimension
            case .EXPORT_WATERMARK_TEXT_EMPTY,
                 .EXPORT_WATERMARK_FONT_SIZE_INVALID,
                 .EXPORT_WATERMARK_OPACITY_INVALID:
                return .watermark
            default:
                break
            }
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

    // Cut 4 / 4a-3b-1：删除 VM 内的文案漏斗——错误只以 CommandError 落地，
    // 文案统一在 View 渲染期经 L10n 解析（原始诊断只进日志）。

    func run(isPreviewing: Bool = false, _ operation: @escaping () async throws -> Void) async {
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
            errorMessage = CommandError(error)
            fieldError = Self.fieldError(for: error)
        }
    }
}
