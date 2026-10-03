// Phase 3.6：设置与模型状态 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Settings/index.tsx + C1HealthPanel.tsx。
//
// 对齐项：
// - 分组设置（GROUPS：缓存/图片处理/数据库/C1 集成/元数据），label/描述抄
//   locales/zh-CN.json（settings.* 键）；数值字段带 min/max 校验，非法值禁止保存。
// - 人脸分析滑杆：常规（detect_confidence/default_eps/default_min_samples）+
//   高级（nms_threshold/max_detections/onnx_threads），范围抄 index.tsx
//   L227-286 / L457-512，保存经 settings.set。
// - Capture One 健康面板：四层预检（reachable/appRunning/documentOpen/
//   automationAuthorized）——复用 CaptureOneBridge.checkHealth（System Events
//   进程探测）作为 reachable/appRunning 层，本文件内 osascript 文档探测补
//   documentOpen/automationAuthorized 层；✓/✗ 徽标、重新检测按钮（检测中禁用）、
//   挂载时检测一次（对齐 TS checkHealth：仅挂载时 + 手动重检，12s 定时器只
//   轮询 sync-state）。写回队列 6 格与最近同步时间经 culling.sync_status
//   （响应含 reloadAckedAt）接线，非占位。
// - 模型路径编辑：detector_model_path/encoder_model_path 可编辑输入框 + 保存后
//   重查 settings.get_ml_status。
// - 人脸算法参数（ADR-029 原生扩展）：核心点质量门槛/二遍最小样本数/歧义判定间隔三个
//   滑杆 + 「人脸模型」分组（专用模型路径/版本标签/增量聚类开关）。这些键都必须在
//   SettingsService.getDefaults() 里注册，否则 settings.set 会按白名单拒绝——由
//   Tests/GatherAppTests/SettingsCatalogTests 守住。
// - 语言切换：settings.set_language 持久化后本页文案跟随 ui_language，并广播
//   languageChanged 由 GatherAppDelegate 重建菜单（全站文案联动）。
import SwiftUI
import AppKit
import GatherCore

// MARK: - 分组设置与滑杆定义（对齐 TS Settings/index.tsx GROUPS / 滑杆段）

public struct SelectOption: Identifiable, Equatable {
    public let value: String
    public let labelZh: String
    public var id: String { value }
    public init(value: String, labelZh: String) {
        self.value = value
        self.labelZh = labelZh
    }
}

public enum SettingFieldType: Equatable {
    case text
    case number(min: Double?, max: Double?)
    case select([SelectOption])
}

public struct SettingField: Identifiable {
    public let key: String
    public let type: SettingFieldType
    public let zhLabel: String
    public let zhDesc: String
    public var id: String { key }
    public init(key: String, type: SettingFieldType, zhLabel: String, zhDesc: String) {
        self.key = key
        self.type = type
        self.zhLabel = zhLabel
        self.zhDesc = zhDesc
    }
}

public struct SettingGroup: Identifiable {
    public let id: String
    public let titleZh: String
    public let fields: [SettingField]
    public init(id: String, titleZh: String, fields: [SettingField]) {
        self.id = id
        self.titleZh = titleZh
        self.fields = fields
    }
}

public struct SliderSetting: Identifiable {
    public let key: String
    public let min: Double
    public let max: Double
    public let step: Double
    public let isInteger: Bool
    public let defaultValue: Double
    public let zhLabel: String
    public let zhDesc: String
    public var id: String { key }
    public init(key: String, min: Double, max: Double, step: Double, isInteger: Bool, defaultValue: Double, zhLabel: String, zhDesc: String) {
        self.key = key
        self.min = min
        self.max = max
        self.step = step
        self.isInteger = isInteger
        self.defaultValue = defaultValue
        self.zhLabel = zhLabel
        self.zhDesc = zhDesc
    }
}

@MainActor
@Observable
public final class SettingsViewModel {
    private let client: NativeCommandClient
    private let captureOne: CaptureOneBridge
    private(set) public var values: [String: String] = [:]
    /// 分组设置行的编辑缓冲（未保存）。
    public var edits: [String: String] = [:]
    /// 滑杆拖动中的临时值（提交时才落库）。
    public var sliderValues: [String: Double] = [:]
    private(set) public var modelStatus: MLStatusData?
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    public var language = "zh-CN"
    public var backend = "auto"

    // MARK: Capture One 健康面板

    public private(set) var c1Health: C1HealthSnapshot?
    public private(set) var c1HealthError = false
    public private(set) var c1Checking = false

    // MARK: Capture One 写回队列（对齐 C1HealthPanel：culling.sync_status + 12s 轮询）

    public private(set) var syncStatus: MetadataSyncSummary?
    /// 轮询目标会话：session.list 中 updatedAt 最新者（旧版
    /// sessionStore.currentSessionId 的会话级替代——设置页无当前会话上下文，
    /// 按旧版工作区页面的会话列表取最近会话）；nil = 无工作区。
    public private(set) var syncSessionId: String?
    /// culling.sync_status 响应中的 reloadAckedAt（旧版 c1:sync-state 载荷字段，
    /// 对齐 C1HealthPanel 的最近同步时间；原生响应暂无该字段时为 nil）。
    public private(set) var syncReloadAckedAt: String?
    public private(set) var syncStateError = false

    // MARK: 模型下载（对齐旧版 installBanner + models.download_default）

    /// 安装流水线阶段（对齐旧版主进程 downloadDefaultModels 的 phase 语义：
    /// 下载 → 解压；进度条文案按此切换「已下载 xx%（文件名）/正在解压…」）。
    public enum ModelInstallStep: Equatable {
        case downloading
        case extracting
    }

    public enum ModelDownloadPhase: Equatable {
        case idle
        case downloading(filename: String, percent: Double, step: ModelInstallStep)
        case done
        case error
    }

    public private(set) var downloadPhase: ModelDownloadPhase = .idle

    public init(router: CommandRouter) {
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
    }
    // MARK: - 数据加载

    public func load() {
        do {
            values = try client.execute("settings.get_all").decoded(as: [String: String].self)
            modelStatus = try client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["face_compute_units"] ?? "auto"
            edits = values
            seedSliderValues()
            reconcileDownloadPhaseWithModelStatus()
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    private func seedSliderValues() {
        for slider in Self.generalSliders + Self.advancedSliders {
            sliderValues[slider.key] = sliderValue(for: slider.key, defaultValue: slider.defaultValue)
        }
    }

    public func sliderValue(for key: String, defaultValue: Double) -> Double {
        sliderValues[key] ?? Double(values[key] ?? "") ?? defaultValue
    }

    public func sliderValueText(_ slider: SliderSetting) -> String {
        let value = sliderValue(for: slider.key, defaultValue: slider.defaultValue)
        return slider.isInteger ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }

    // MARK: - 语言（settings.set_language 持久化 + 页内文案联动）

    public func setLanguage(_ value: String) {
        do {
            _ = try client.execute("settings.set_language", params: ["language": .string(value)])
            language = value
            values["ui_language"] = value
            notice = value == "en" ? "Language saved" : GatherLocalization.l("语言已保存")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 推理后端

    public func setBackend(_ value: String) {
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string("face_compute_units"),
                "value": .string(value),
            ])
            backend = value
            values["face_compute_units"] = value
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            notice = GatherLocalization.l("推理后端已保存")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 首屏日常分组（F11）：图片处理、Capture One 集成、元数据、缓存。
    /// 顺序即首屏顺序——日常设置在前，实现细节在后。
    public static var primaryGroups: [SettingGroup] {
        let primaryIds = ["image", "c1", "metadata", "cache"]
        return primaryIds.compactMap { id in settingGroups.first { $0.id == id } }
    }

    /// 高级分组（F11）：数据库、人脸模型参数——折叠在「高级」里，默认不占首屏。
    public static var advancedGroups: [SettingGroup] {
        let advancedIds = ["face", "db"]
        return advancedIds.compactMap { id in settingGroups.first { $0.id == id } }
    }

    // MARK: - 分组设置（含类型约束：数值 min/max 校验，非法值禁止保存）

    public func saveField(_ field: SettingField) {
        let raw = (edits[field.key] ?? values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            // 空值规则：只有"默认值本身为空"的键才允许清空——例如
            // face_embedding_model_path 清空 = 回到内置 SFace 身份模型（合法操作），
            // 而 detector_model_path 留空没有语义，仍按无效输入拒绝。
            guard Self.defaultValueIsEmpty(field.key) else {
                errorMessage = String(format: GatherLocalization.l("「%@」不能为空"), GatherLocalization.l(field.zhLabel))
                return
            }
            save(key: field.key, value: "")
            return
        }
        switch field.type {
        case .text:
            // 专用人脸模型路径：保存时只做**廉价**校验（展开 ~、解析软链、存在性、
            // 扩展名），不加载模型、不做整包哈希——256 MiB 模型在 @MainActor 上
            // 加载+哈希实测 48.4s，界面会假死（对抗审查 V1 探针 I）。
            // 失败原因复用 core 的 FaceEmbeddingError.description（逐字一致）；
            // "能否真正加载"由分析路径负责（fkw.analyze 的错误现在已能上屏）。
            if field.key == FaceEmbeddingModelFactory.modelPathSetting,
               let reason = Self.faceEmbeddingModelPathError(raw) {
                errorMessage = reason
                return
            }
            save(key: field.key, value: raw)
        case .number(let min, let max):
            guard let parsed = Double(raw), parsed.isFinite else {
                errorMessage = String(format: GatherLocalization.l("「%@」必须是数字"), GatherLocalization.l(field.zhLabel))
                return
            }
            if let min, parsed < min {
                errorMessage = String(format: GatherLocalization.l("「%@」不能小于 %@"), GatherLocalization.l(field.zhLabel), Self.numberText(min))
                return
            }
            if let max, parsed > max {
                errorMessage = String(format: GatherLocalization.l("「%@」不能大于 %@"), GatherLocalization.l(field.zhLabel), Self.numberText(max))
                return
            }
            save(key: field.key, value: raw)
        case .select:
            break
        }
    }

    /// 人脸嵌入模型路径的廉价校验（纯 FileManager/URL，不加载、不哈希）：
    /// 返回 nil = 可保存；否则是与 core 逐字一致的中文拒绝原因。
    /// 规则对齐 core FaceEmbeddingModelFactory.make / CoreMLFaceEmbedder：
    /// 空/纯空白 → 合法（回到内置 Vision，由调用方空值分支处理）；
    /// 展开 `~` → 解析软链 → 文件必须存在 → 扩展名必须 .mlmodel/.mlmodelc；
    /// 目录为空（core 的 stat 指纹为空）同样按"模型不存在"拒绝。
    /// 不做的事：MLModel.compileModel / MLModel(contentsOf:) / 内容指纹哈希。
    static func faceEmbeddingModelPathError(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return FaceEmbeddingError.modelNotFound(url.path).description
        }
        switch url.pathExtension {
        case "mlmodel", "mlpackage", "mlmodelc":
            break
        default:
            return FaceEmbeddingError.unsupportedModelFormat(url.pathExtension).description
        }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.isEmpty {
                return FaceEmbeddingError.modelNotFound(url.path).description
            }
        }
        return nil
    }

    public func saveSelect(_ field: SettingField, value: String) {
        save(key: field.key, value: value)
    }

    // MARK: - 模型路径编辑（保存后重查模型状态）

    public func saveModelPath(key: String) {
        let raw = (edits[key] ?? values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || key == "face_embedding_model_path" else {
            errorMessage = GatherLocalization.l("模型路径不能为空")
            return
        }
        if key == FaceEmbeddingModelFactory.modelPathSetting, !raw.isEmpty,
           let reason = Self.faceEmbeddingModelPathError(raw) {
            errorMessage = reason
            return
        }
        save(key: key, value: raw)
    }

    // MARK: - 滑杆提交

    public func commitSlider(_ slider: SliderSetting) {
        guard let raw = sliderValues[slider.key] else { return }
        let clamped = min(slider.max, max(slider.min, raw))
        sliderValues[slider.key] = clamped
        let formatted = slider.isInteger
            ? String(Int(clamped.rounded()))
            : String(format: "%.2f", clamped)
        save(key: slider.key, value: formatted)
    }

    func save(key: String, value: String) {
        // F11：文本框改为「失焦或回车」提交后，保存会被频繁触发（用户 Tab 穿过
        // 一个没改过的字段也会触发）。值没变就什么都不做：不写库、不弹提示。
        if values[key] == value, edits[key] == value { return }
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string(key),
                "value": .string(value),
            ])
            values[key] = value
            edits[key] = value
            // 提示用人类可读标签（zhLabel），不是内部键：审查发现「已保存 thumbnail_size」
            // 这类提示让用户无法确认自己改的是哪一项。
            notice = String(format: GatherLocalization.l("已保存 %@"), Self.label(for: key))
            errorMessage = nil
            if key == FaceEmbeddingModelFactory.modelPathSetting || key == "face_compute_units" || key == "face_embedding_model_version" {
                modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 目录与重置

    public func openModelDirectory() {
        guard let path = modelStatus?.modelResourcesDir, !path.isEmpty else {
            errorMessage = GatherLocalization.l("模型目录不可用")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func openModelPathDirectory(key: String) {
        let resolved: String?
        if key == "detector_model_path" {
            resolved = modelStatus?.detectorModel.resolvedPath
        } else {
            resolved = modelStatus?.encoderModel.resolvedPath
        }
        guard let resolved, !resolved.isEmpty else {
            errorMessage = GatherLocalization.l("模型路径不可用")
            return
        }
        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        NSWorkspace.shared.open(URL(fileURLWithPath: parent, isDirectory: true))
    }

    /// 恢复默认（破坏性：模型路径、推理后端、缓存、写回参数等全部设置重置）。
    /// `confirmed` 只能由确认弹窗传入 true；未确认不发命令。
    public func reset(confirmed: Bool) {
        guard confirmed else {
            notice = GatherLocalization.l("未确认，已取消恢复默认设置")
            return
        }
        do {
            values = try client.execute("settings.reset").decoded(as: [String: String].self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["face_compute_units"] ?? "auto"
            edits = values
            seedSliderValues()
            notice = GatherLocalization.l("设置已恢复默认值")
            // 不广播 .settings：设置写入无常驻页消费者（各页在重新可见/加载时
            // 自行读取最新设置值），发布只会留下无人订阅的死事件。
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = GatherLocalization.cancellationNotice(action)
        errorMessage = nil
    }

    // MARK: - Capture One 四层预检

    /// 对齐 TS c1-health.ts：reachable/appRunning 复用 CaptureOneBridge
    /// checkHealth（System Events 进程探测）；documentOpen/automationAuthorized
    /// 由本文件内 osascript 文档探测补充（失败分类与 TS errors.ts 一致：
    /// -1743/not authorized → 未授权；no document → 事件已到达应用但无文档 →
    /// automationAuthorized=true；-1712/timed out → 自动化通道不可用）。
    public func checkC1Health() async {
        c1Checking = true
        defer { c1Checking = false }
        let started = Date()
        let result = await captureOne.checkHealth()
        switch result {
        case .success(let appName):
            var snapshot = C1HealthSnapshot(
                reachable: true,
                appRunning: true,
                documentOpen: false,
                automationAuthorized: false,
                appName: appName,
                latencyMs: nil,
                lastError: nil
            )
            do {
                _ = try await runAppleScript(CaptureOneBridge.documentProbeScript(appName: appName), timeout: 3)
                snapshot.documentOpen = true
                snapshot.automationAuthorized = true
            } catch let probe as C1ProbeError {
                snapshot.documentOpen = false
                // 事件到达应用（无文档/应用侧错误）说明 TCC 已通过；
                // 未授权与超时则自动化通道不可用。
                snapshot.automationAuthorized = (probe != .notAuthorized && probe != .timedOut)
                snapshot.lastError = String(describing: probe)
            } catch {
                snapshot.documentOpen = false
                snapshot.automationAuthorized = false
                snapshot.lastError = String(describing: error)
            }
            snapshot.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            c1Health = snapshot
            c1HealthError = false
        case .failure(let error):
            c1Health = C1HealthSnapshot(
                reachable: false,
                appRunning: false,
                documentOpen: false,
                automationAuthorized: false,
                appName: nil,
                latencyMs: nil,
                lastError: error.description
            )
            c1HealthError = true
        }
    }

    private func runAppleScript(_ script: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let gate = C1ProbeGate(continuation: continuation)
            process.terminationHandler = { process in
                let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    gate.finish(.success(stdout))
                } else {
                    gate.finish(.failure(Self.classifyProbe(stderr)))
                }
            }

            do {
                try process.run()
            } catch {
                gate.finish(.failure(Self.classifyProbe(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                gate.finish(.failure(C1ProbeError.timedOut))
            }
        }
    }

    /// 对齐 TS capture-one/errors.ts 的 classifyCaptureOneError：timeout 优先于
    /// denied 判定（hung app 不能误判为拒绝）。
    nonisolated private static func classifyProbe(_ message: String) -> C1ProbeError {
        let lowercased = message.lowercased()
        if lowercased.contains("-1712") || lowercased.contains("timed out") {
            return .timedOut
        }
        if lowercased.contains("-1743") || lowercased.contains("not authorized") || lowercased.contains("not authorised") {
            return .notAuthorized
        }
        if lowercased.contains("no document") || lowercased.contains("no current document") {
            return .noDocument
        }
        return .scriptFailed(message.isEmpty ? "osascript failed" : message)
    }

    // MARK: - 写回队列（culling.sync_status + 12s 轮询）

    /// 对齐 C1HealthPanel.refreshSync：经 session.list 取最近会话，再读
    /// culling.sync_status；无会话时置空（UI 显示「无工作区」）。
    public func refreshSyncState() {
        do {
            let sessions = try client.execute("session.list").decoded(as: [SessionData].self)
            guard let session = Self.mostRecentSession(sessions) else {
                syncSessionId = nil
                syncStatus = nil
                syncReloadAckedAt = nil
                syncStateError = false
                recomputeLastSyncDate()
                return
            }
            syncSessionId = session.id
            let response = try client.execute("culling.sync_status", params: [
                "sessionId": .string(session.id),
            ])
            syncStatus = try response.decoded(as: MetadataSyncSummary.self)
            // 旧版 C1HealthPanel 以 c1:sync-state 的 reloadAckedAt 为准；原生
            // 路由响应若携带该字段则优先使用，缺失时回退 items.updatedAt。
            syncReloadAckedAt = response.objectValue?["reloadAckedAt"]?.stringValue
            syncStateError = false
            recomputeLastSyncDate()
        } catch {
            syncStateError = true
        }
    }

    /// 最近同步时间：优先 reloadAckedAt（对齐 C1HealthPanel.tsx:147-155，
    /// 语义为 Capture One 最后一次 reload 确认时间），否则回退队列项
    /// updatedAt 的最大值（最后一次写回活动的近似）。
    /// 计算一次并缓存（C-1 性能审计）：旧实现是计算属性且直接写在 body 里，
    /// 每次 body 都要对该会话**全部** outbox 行逐项 ISO 解析（无 LIMIT），
    /// 叠加 12s 轮询 ⇒ 开着设置窗就是每 12 秒一次秒级主线程停顿。
    public private(set) var lastSyncDate: Date?

    /// refreshSyncState 成功后调用（含 12s 轮询与终态事件两条路径）。
    func recomputeLastSyncDate() {
        if let ack = syncReloadAckedAt, !ack.isEmpty, let date = parseISO8601Date(ack) {
            lastSyncDate = date
            return
        }
        guard let syncStatus else {
            lastSyncDate = nil
            return
        }
        var newest: Date?
        for item in syncStatus.items {
            guard let date = parseISO8601Date(item.updatedAt) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        lastSyncDate = newest
    }

    private static func mostRecentSession(_ sessions: [SessionData]) -> SessionData? {
        sessions.max { a, b in
            (parseISO8601Date(a.updatedAt) ?? .distantPast) < (parseISO8601Date(b.updatedAt) ?? .distantPast)
        }
    }

    /// 本地化时间文案：zh 环境 `yyyy年M月d日 HH:mm`，其余按系统区域模板
    /// （与 PersonDetail 的时间戳展示保持一致）。
    public static func dateText(_ date: Date) -> String {
        // C-1（性能审计）：缓存实例，输出与旧实现逐字节一致（见 DisplayDateFormatters 注释）。
        let zh = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
        return DisplayDateFormatters.shared.localizedMinute(date, zh: zh)
    }

    // MARK: - 模型下载（旧版 model-downloader.ts 的 Swift 移植）

    public var isDownloading: Bool {
        if case .downloading = downloadPhase { return true }
        return false
    }

    public func startModelDownload() async {
        guard !isDownloading else { return }
        errorMessage = nil
        let configured = (values["model_download_url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: configured.isEmpty ? ModelInstaller.packageURL : configured) else {
            downloadPhase = .error
            errorMessage = GatherLocalization.l("模型下载地址无效")
            return
        }
        guard let modelsDir = modelStatus?.modelResourcesDir, !modelsDir.isEmpty else {
            downloadPhase = .error
            errorMessage = GatherLocalization.l("模型目录不可用")
            return
        }
        downloadPhase = .downloading(filename: "buffalo_l.zip", percent: 0, step: .downloading)
        do {
            try await ModelInstaller.install(url: url, modelsDir: modelsDir) { step, filename, percent in
                self.downloadPhase = .downloading(filename: filename, percent: percent, step: step)
            }
            downloadPhase = .done
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            reconcileDownloadPhaseWithModelStatus()
        } catch {
            downloadPhase = .error
            // 诊断不直显：非错误码走 errorText 通用回退（与全局错误漏斗一致）。
            let nsError = error as NSError
            let raw = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
            errorMessage = String(format: GatherLocalization.l("模型下载失败：%@"), GatherLocalization.errorText(raw))
        }
    }

    private func reconcileDownloadPhaseWithModelStatus() {
        guard downloadPhase == .done, let model = modelStatus,
              !(model.detectorModel.exists && model.encoderModel.exists) else { return }
        downloadPhase = .idle
    }

    // MARK: - 静态配置表（对齐 TS GROUPS / 滑杆段）

    /// TS: Math.max(1, Math.min(8, cpuCount - 1))。
    public static var maxConcurrency: Double {
        let cores = ProcessInfo.processInfo.processorCount
        return Double(max(1, min(8, cores - 1)))
    }

    public static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// 设置键 → 界面标签（滑杆或分组字段里找到就用 zhLabel；否则退回键名）。
    /// 用于保存提示，避免把内部键暴露给用户。
    public static func label(for key: String) -> String {
        if let slider = (generalSliders + advancedSliders).first(where: { $0.key == key }) {
            return GatherLocalization.l(slider.zhLabel)
        }
        for group in settingGroups {
            if let field = group.fields.first(where: { $0.key == key }) {
                return GatherLocalization.l(field.zhLabel)
            }
        }
        return key
    }

    /// 该键在 core 默认表里是否为空串（决定"清空输入框"是否为合法操作）。
    public static func defaultValueIsEmpty(_ key: String) -> Bool {
        (SettingsService.getDefaults()[key] ?? "").isEmpty
    }

    /// 人脸分析常规参数（TS index.tsx L227-286）。
    public static let generalSliders: [SliderSetting] = [
        SliderSetting(
            key: "detect_confidence", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.5,
            zhLabel: "检测敏感度",
            zhDesc: "低于此置信度的人脸将被忽略"
        ),
        SliderSetting(
            key: "default_eps", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.65,
            zhLabel: "同一人相似度下限",
            zhDesc: "仅相似度不低于该值的人脸才归为同一人；值越大越严格"
        ),
        SliderSetting(
            key: "default_min_samples", min: 1, max: 20, step: 1, isInteger: true, defaultValue: 2,
            zhLabel: "最小样本数",
            zhDesc: "一个人至少出现 N 张照片才形成聚类"
        ),
    ]

    /// 原生分析实际使用的高级参数；旧 ONNX/NMS 设置仅保留存储兼容。
    public static let advancedSliders: [SliderSetting] = [
        SliderSetting(
            key: "max_detections", min: 1, max: 500, step: 1, isInteger: true, defaultValue: 100,
            zhLabel: "最大检测数",
            zhDesc: "单张图片最多检测的人脸数"
        ),
        SliderSetting(
            key: "face_decode_concurrency", min: 1, max: 8, step: 1, isInteger: true, defaultValue: 4,
            zhLabel: "照片解码并发数", zhDesc: "同时准备的照片数；内存紧张时调低"
        ),
        // 原生质量与匹配参数。
        SliderSetting(
            key: "face_core_quality", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.35,
            zhLabel: "核心点质量门槛",
            zhDesc: "质量低于此值的人脸不能带动聚类（只可能被并入），0 = 不设限；调高可减少模糊/侧脸造成的误聚"
        ),
        SliderSetting(
            key: "face_core_retry_min_samples", min: 1, max: 10, step: 1, isInteger: true, defaultValue: 2,
            zhLabel: "二遍最小样本数",
            zhDesc: "首遍漏掉的小簇在二遍中恢复；小于 2 视为关闭"
        ),
        SliderSetting(
            key: "face_match_margin", min: 0, max: 0.2, step: 0.005, isInteger: false, defaultValue: 0.01,
            zhLabel: "歧义判定间隔",
            zhDesc: "最相似与次相似人物的差距小于此值时不自动绑定身份，留给人工确认；0 = 总是绑定最相似者"
        ),
    ]

    /// 分组设置（TS index.tsx L25-74；min/max 抄 input 约束 + 描述文案约束）。
    public static let settingGroups: [SettingGroup] = [
        SettingGroup(id: "cache", titleZh: "缓存", fields: [
            SettingField(
                key: "memory_cache_size", type: .number(min: 1, max: nil),
                zhLabel: "内存缓存条目数",
                zhDesc: "内存中缓存的缩略图最大数量"
            ),
            SettingField(
                key: "memory_cache_max_size_mb", type: .number(min: 32, max: 2048),
                zhLabel: "内存缓存上限 (MB)",
                zhDesc: "缩略图和预览内存缓存的最大空间，防止高分辨率图片占满内存"
            ),
            SettingField(
                key: "disk_cache_dir", type: .text,
                zhLabel: "磁盘缓存目录",
                zhDesc: "磁盘缓存存储路径（留空使用默认）"
            ),
            SettingField(
                key: "disk_cache_max_size_gb", type: .number(min: 0, max: nil),
                zhLabel: "磁盘缓存上限 (GB)",
                zhDesc: "磁盘缓存占用硬盘的最大空间"
            ),
            SettingField(
                key: "disk_cache_eviction_policy", type: .select([
                    SelectOption(value: "lru", labelZh: "LRU（最近最少使用）"),
                    SelectOption(value: "fifo", labelZh: "FIFO（先进先出）"),
                    SelectOption(value: "lfu", labelZh: "LFU（最不经常使用）"),
                ]),
                zhLabel: "淘汰策略",
                zhDesc: "lru=LRU（最近最少使用）, fifo=FIFO（先进先出）, lfu=LFU（最不经常使用）"
            ),
        ]),
        SettingGroup(id: "image", titleZh: "图片处理", fields: [
            SettingField(
                key: "thumbnail_size", type: .number(min: 256, max: 2048),
                zhLabel: "缩略图尺寸",
                zhDesc: "画廊缓存分辨率（建议 1024；内部按 256/1024/2048 三级复用）"
            ),
            SettingField(
                key: "thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "缩略图质量",
                zhDesc: "缩略图的 JPEG 压缩质量 (0-100)"
            ),
            SettingField(
                key: "thumbnail_concurrency", type: .number(min: 1, max: maxConcurrency),
                zhLabel: "缩略图生成并发数",
                zhDesc: "同时生成缩略图的任务数（RAW 建议 2-4，最大 8）"
            ),
            SettingField(
                key: "face_thumbnail_size", type: .number(min: 1, max: nil),
                zhLabel: "人脸缩略图尺寸",
                zhDesc: "人脸缩略图的宽高像素值"
            ),
            SettingField(
                key: "face_thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "人脸缩略图质量",
                zhDesc: "人脸缩略图的 JPEG 压缩质量 (0-100)"
            ),
        ]),
        SettingGroup(id: "db", titleZh: "数据库", fields: [
            SettingField(
                key: "db_cache_size_mb", type: .number(min: 1, max: 1024),
                zhLabel: "缓存大小 (MB)",
                zhDesc: "SQLite 数据库的页面缓存大小"
            ),
            SettingField(
                key: "db_synchronous", type: .select([
                    SelectOption(value: "off", labelZh: "OFF（关闭）"),
                    SelectOption(value: "normal", labelZh: "NORMAL（正常）"),
                    SelectOption(value: "full", labelZh: "FULL（完整）"),
                ]),
                zhLabel: "同步模式",
                zhDesc: "off=OFF（关闭）, normal=NORMAL（正常）, full=FULL（完整）"
            ),
        ]),
        SettingGroup(id: "c1", titleZh: "Capture One 集成", fields: [
            SettingField(
                key: "c1_timeout_ms", type: .number(min: 1, max: nil),
                zhLabel: "超时时间 (ms)",
                zhDesc: "与 Capture One 通信的超时毫秒数"
            ),
            SettingField(
                key: "c1_retries", type: .number(min: 0, max: nil),
                zhLabel: "重试次数",
                zhDesc: "与 Capture One 通信的最大重试次数"
            ),
            SettingField(
                key: "c1_reload_delay_ms", type: .number(min: 0, max: nil),
                zhLabel: "重载延迟 (ms)",
                zhDesc: "重载元数据后的等待延迟毫秒数"
            ),
        ]),
        SettingGroup(id: "metadata", titleZh: "元数据", fields: [
            SettingField(
                key: "metadata_write_mode", type: .select([
                    SelectOption(value: "auto", labelZh: "自动（RAW侧边栏，成品格式内嵌）"),
                    SelectOption(value: "sidecar", labelZh: "XMP Sidecar"),
                    SelectOption(value: "embedded", labelZh: "Embedded"),
                ]),
                zhLabel: "写入方式",
                zhDesc: "auto=自动（RAW侧边栏，成品格式内嵌）, sidecar=XMP Sidecar, embedded=Embedded"
            ),
            SettingField(
                key: "metadata_write_debounce_ms", type: .number(min: 1, max: nil),
                zhLabel: "后台写入防抖 (ms)",
                zhDesc: "连续评级或改色后等待多久合并写入，建议 300-800"
            ),
            SettingField(
                key: "capture_one_color_compatibility", type: .select([
                    SelectOption(value: "label_and_urgency", labelZh: "Label + Urgency（推荐，兼容更多版本）"),
                    SelectOption(value: "label_only", labelZh: "仅标准 xmp:Label"),
                ]),
                zhLabel: "Capture One 颜色兼容",
                zhDesc: "label_and_urgency=Label + Urgency（推荐，兼容更多版本）, label_only=仅标准 xmp:Label"
            ),
        ]),
        SettingGroup(id: "face", titleZh: "人脸模型", fields: [
            SettingField(
                key: "face_embedding_model_path", type: .text,
                zhLabel: "专用人脸模型路径",
                zhDesc: "留空使用应用内置 SFace 身份模型；也可选择 112×112 图像输入的 CoreML 模型。换模型后需要全量重新分析，已有人工身份与纠错记录会保留。"
            ),
            SettingField(
                key: "face_embedding_model_version", type: .text,
                zhLabel: "模型版本标签",
                zhDesc: "仅用于记录与追溯（写入人脸观测，便于区分换模型前后的数据）；换模型时建议同时更新，例如 arcface-r100-w600k"
            ),
            SettingField(
                key: "face_incremental_clustering", type: .select([
                    SelectOption(value: "1", labelZh: "开（推荐，保留已绑定身份）"),
                    SelectOption(value: "0", labelZh: "关（每次全量重聚类）"),
                ]),
                zhLabel: "增量聚类",
                zhDesc: "开=优先处理新增照片；模型或人工约束变化时会重新聚类。关=每次重新聚类。两种方式都会保留人工身份与纠错记录。"
            ),
        ]),
    ]
}

// MARK: - 预检结果与 osascript 探测辅助

public struct C1HealthSnapshot: Equatable, Sendable {
    public var reachable: Bool
    public var appRunning: Bool
    public var documentOpen: Bool
    public var automationAuthorized: Bool
    public var appName: String?
    public var latencyMs: Int?
    public var lastError: String?

    public init(
        reachable: Bool,
        appRunning: Bool,
        documentOpen: Bool,
        automationAuthorized: Bool,
        appName: String?,
        latencyMs: Int?,
        lastError: String?
    ) {
        self.reachable = reachable
        self.appRunning = appRunning
        self.documentOpen = documentOpen
        self.automationAuthorized = automationAuthorized
        self.appName = appName
        self.latencyMs = latencyMs
        self.lastError = lastError
    }
}

public enum C1ProbeError: Error, Equatable, Sendable {
    case notAuthorized
    case noDocument
    case timedOut
    case scriptFailed(String)
}

/// 保证 continuation 只 resume 一次（termination handler 与超时竞争）。
private final class C1ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

// MARK: - 模型下载器（旧版 model-downloader.ts 的 Swift 移植）

/// 下载默认模型包（zip）→ 解压 → 按 fileMap 改名到模型目录。
/// 原生路由无 models.download_default 命令（face.models_status 恒
/// modelsPresent=true/downloading=false，Vision provider 不需要模型资产），
/// 故在设置页内用 Foundation 能力自给：settings.model_download_url 缺省
/// 用旧版 MODEL_CONFIG.download.packageUrl。
enum ModelInstaller {
    /// TS model-config.ts：MODEL_CONFIG.download.packageUrl。
    static let packageURL = "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
    /// TS fileMap：压缩包内文件名 → 模型目录目标名。
    static let fileMap: [String: String] = [
        "det_10g.onnx": "face_detector.onnx",
        "w600k_r50.onnx": "face_encoder.onnx",
    ]

    enum InstallError: LocalizedError {
        case badStatus
        case extractFailed
        case toolFailed(String)
        /// 问题 9：包缺必需文件 / 文件为空 —— 必须明确报错，不能静默继续。
        case missingFile(String)
        case emptyFile(String)

        var errorDescription: String? {
            switch self {
            case .badStatus: GatherLocalization.l("模型下载返回了非 2xx 状态码")
            case .extractFailed: "MODEL_EXTRACT_FAILED"
            case .toolFailed(let tool): String(format: GatherLocalization.l("解压工具执行失败：%@"), tool)
            case .missingFile(let name):
                String(format: GatherLocalization.l("模型包缺少必需文件：%@"), name)
            case .emptyFile(let name):
                String(format: GatherLocalization.l("模型包中的文件为空：%@"), name)
            }
        }
    }

    static func install(
        url: URL,
        modelsDir: String,
        onProgress: @escaping @MainActor @Sendable (SettingsViewModel.ModelInstallStep, String, Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let http = response as? HTTPURLResponse
        if let http {
            guard (200..<300).contains(http.statusCode) else { throw InstallError.badStatus }
        } else if !url.isFileURL {
            // 非 HTTP 且非本地文件（问题 9 验收：允许 file:// 本地包，便于离线安装与测试）。
            throw InstallError.badStatus
        }
        let total = (http?.expectedContentLength).flatMap { $0 > 0 ? Double($0) : nil } ?? 0
        let tmpZip = fileManager.temporaryDirectory.appendingPathComponent("gather-models-\(UUID().uuidString).zip")
        let extractDir = fileManager.temporaryDirectory.appendingPathComponent("gather-models-extract-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: tmpZip)
            try? fileManager.removeItem(at: extractDir)
        }
        fileManager.createFile(atPath: tmpZip.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpZip)
        var downloaded: Double = 0
        do {
            // URLSession.AsyncBytes 逐字节产出：攒满一个块再写盘。
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    downloaded += Double(buffer.count)
                    await onProgress(.downloading, "buffalo_l.zip", total > 0 ? min(100, downloaded / total * 100) : 0)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                downloaded += Double(buffer.count)
                await onProgress(.downloading, "buffalo_l.zip", total > 0 ? min(100, downloaded / total * 100) : 0)
            }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()

        // 下载完成进入解压阶段（tar/unzip 无逐字节进度，保持 100% 与阶段文案）。
        await onProgress(.extracting, "buffalo_l.zip", 100)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        do {
            try Self.runTool("/usr/bin/tar", arguments: ["-xf", tmpZip.path, "-C", extractDir.path])
        } catch {
            do {
                try Self.runTool("/usr/bin/unzip", arguments: ["-o", tmpZip.path, "-d", extractDir.path])
            } catch {
                throw InstallError.extractFailed
            }
        }
        // 问题 9（第三轮审查）：旧实现「缺任一必需文件就 continue」，会把不完整
        // 的包当成功安装；且先删目标再 move，第二步失败会留下半套模型。
        // 这里：① 全部必需文件先校验存在且非空；② 先把全部文件搬到同目录暂存；
        // ③ 全部就绪后再逐个原子替换（replaceItemAt），任一步失败保留旧模型。
        var staged: [(staged: URL, dest: URL)] = []
        do {
            for (source, dest) in fileMap {
                let sourceURL = extractDir.appendingPathComponent(source)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw InstallError.missingFile(source)
                }
                let size = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw InstallError.emptyFile(source) }
                staged.append((sourceURL, URL(fileURLWithPath: modelsDir).appendingPathComponent(dest)))
            }
            try fileManager.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
            let stagingDir = extractDir.appendingPathComponent(".gather-staging", isDirectory: true)
            try? fileManager.removeItem(at: stagingDir)
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var moved: [(staged: URL, dest: URL)] = []
            for item in staged {
                let target = stagingDir.appendingPathComponent(item.dest.lastPathComponent)
                try? fileManager.removeItem(at: target)
                try fileManager.moveItem(at: item.staged, to: target)
                moved.append((target, item.dest))
            }
            // D7（深审）：单文件原子性 ≠ 整套原子性。逐个替换时第二个失败会留下
            // 「第一个新、第二个旧」的混合版本。改为：先把旧文件移出到同目录备份，
            // 全部就绪后依次放入；任一步失败即用备份**整体回滚**。
            var applied: [(dest: URL, backup: URL?)] = []
            do {
                for item in moved {
                    var backup: URL?
                    if fileManager.fileExists(atPath: item.dest.path) {
                        let backupURL = stagingDir.appendingPathComponent("prev-" + item.dest.lastPathComponent)
                        try? fileManager.removeItem(at: backupURL)
                        try fileManager.moveItem(at: item.dest, to: backupURL)
                        backup = backupURL
                    }
                    do {
                        try fileManager.moveItem(at: item.staged, to: item.dest)
                    } catch {
                        if let backup { try? fileManager.moveItem(at: backup, to: item.dest) }
                        throw error
                    }
                    applied.append((item.dest, backup))
                }
            } catch {
                // 整体回滚：已替换的恢复旧文件，本次新建的删除，保证「全旧或全新」。
                for entry in applied.reversed() {
                    if let backup = entry.backup {
                        try? fileManager.removeItem(at: entry.dest)
                        try? fileManager.moveItem(at: backup, to: entry.dest)
                    } else {
                        try? fileManager.removeItem(at: entry.dest)
                    }
                }
                try? fileManager.removeItem(at: extractDir.appendingPathComponent(".gather-staging"))
                throw error
            }
        } catch {
            // 失败：清理暂存，旧模型保持原样。
            try? fileManager.removeItem(at: extractDir.appendingPathComponent(".gather-staging"))
            throw error
        }
    }

    private static func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.toolFailed(path)
        }
    }
}

// MARK: - 页面

/// 模型覆盖安装确认：下载解压会覆盖模型目录中的同名文件。
private struct PendingModelInstall: Identifiable {
    let modelDir: String

    var id: String { "model-install-\(modelDir)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将从网络下载模型包并解压到 %@；同名模型文件会被覆盖，旧文件不可恢复。取消不会下载任何内容。"),
            modelDir
        )
    }
}

/// 恢复默认设置的确认上下文：影响范围 = 将被重置的设置项数量。
private struct PendingSettingsReset: Identifiable {
    let keyCount: Int

    var id: String { "settings-reset-\(keyCount)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将把当前 %lld 项设置恢复为默认值（模型路径、推理后端、缓存与写回参数等）；不会删除照片或 XMP 文件。取消不改变任何设置。"),
            keyCount
        )
    }
}

/// 应用设置（原生版）。
///
/// 原生化要点：
/// - 由真正的 Settings scene 承载（⌘, 由系统提供，最小化/缩放自动变灰）；
/// - Form + .formStyle(.grouped)：标签列、控件列、行内边距、选中高亮、
///   分组圆角与无障碍关联全部由系统负责。取代旧版「手搓 HStack + Spacer +
///   900pt 空白走廊 + 四个魔法宽度 + 每个字段一个保存按钮」；
/// - 编辑即生效：回车（onSubmit）或选择文件即落库；
/// - 排版走系统文本样式（不再有 10pt 正文与三级同号的 .title3 标题）；
/// - 状态行用 Label + SF Symbol + 语义色，不再用 ✓/✗ 字形与纯颜色信号。
public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var pendingReset: PendingSettingsReset?
    @State private var pendingModelInstall: PendingModelInstall?
    /// 正在用文件选择器编辑的设置项（目录项选文件夹，其余选文件）。
    @State private var pickingField: SettingField?
    /// 正在用文件选择器编辑的模型路径键。
    @State private var pickingModelPathKey: String?
    /// 高级设置展开状态（F11：默认收起，普通用户首屏看不到技术参数）。
    @State private var showAdvancedSettings = false
    /// 当前获得焦点的设置项键（F11：失焦即提交，避免「看起来改了其实没写」）。
    @FocusState private var focusedFieldKey: String?

    public init(router: CommandRouter) {
        _viewModel = State(initialValue: SettingsViewModel(router: router))
    }

    public var body: some View {
        Form {
            banners
            // F11 分块规则：首屏只放日常设置——语言、Capture One 状态、
            // 图片处理 / 写回 / 元数据 / 缓存；模型路径、输入尺寸、特征维度、
            // 数据库与人脸算法参数折叠进「高级」（默认收起）。
            saveRuleHint
            languageSection
            c1HealthSection
            ForEach(SettingsViewModel.primaryGroups) { group in
                settingsSection(group)
            }
            faceAnalysisSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 480)
        .navigationTitle(GatherLocalization.l("设置"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.load()
                } label: {
                    Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
                }
                .help(GatherLocalization.l("重新读取全部设置项"))

                Button {
                    pendingReset = PendingSettingsReset(keyCount: viewModel.values.count)
                } label: {
                    Label(GatherLocalization.l("恢复默认"), systemImage: "arrow.counterclockwise")
                }
                .help(GatherLocalization.l("把所有设置项恢复为默认值（会先确认）"))
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingField != nil },
                set: { if !$0 { pickingField = nil } }
            ),
            allowedContentTypes: (pickingField?.key.hasSuffix("_dir") ?? false) ? [.folder] : [.item],
            allowsMultipleSelection: false
        ) { result in
            guard let field = pickingField else { return }
            pickingField = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            viewModel.edits[field.key] = url.path
            viewModel.saveField(field)
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingModelPathKey != nil },
                set: { if !$0 { pickingModelPathKey = nil } }
            ),
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: false
        ) { result in
            guard let key = pickingModelPathKey else { return }
            pickingModelPathKey = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            viewModel.edits[key] = url.path
            viewModel.saveModelPath(key: key)
        }
        .task { viewModel.load() }
        // 对齐 C1HealthPanel.tsx：挂载时检测一次；重检走"重新检测"按钮
        // （TS checkHealth 仅挂载时 + 手动触发，12s 定时器只轮询 sync-state）。
        .task { await viewModel.checkC1Health() }
        // 对齐 C1HealthPanel.tsx：culling.sync_status 每 12s 轮询刷新。
        .task {
            viewModel.refreshSyncState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                viewModel.refreshSyncState()
            }
        }
        // 写路径广播（XMP/同步队列）：立即刷新 C1 写回队列，不再等 12s 轮询。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.domain == .metadata else { return }
            viewModel.refreshSyncState()
        }
        .gatherDestructiveConfirm(
            pending: $pendingReset,
            title: GatherLocalization.l("恢复所有设置默认值？"),
            confirmLabel: { _ in GatherLocalization.l("恢复默认") },
            confirmRole: { _ in .destructive },
            message: { $0.scopeText },
            onConfirm: { _ in viewModel.reset(confirmed: true) },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("恢复默认设置")) }
        )
        // 模型覆盖安装：同名文件会被覆盖且不可恢复，先确认。
        .gatherDestructiveConfirm(
            pending: $pendingModelInstall,
            title: GatherLocalization.l("确认下载并安装人脸模型？"),
            confirmLabel: { _ in GatherLocalization.l("下载并覆盖") },
            confirmRole: { _ in .destructive },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.startModelDownload() } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("下载并安装人脸模型")) }
        )
    }

    // MARK: 提示条

    @ViewBuilder
    private var banners: some View {
        if viewModel.errorMessage != nil || viewModel.notice != nil {
            Section {
                if let error = viewModel.errorMessage {
                    NativeBanner(
                        text: String(format: GatherLocalization.l("操作失败：%@"), error),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.error
                    )
                }
                if let notice = viewModel.notice {
                    NativeBanner(
                        text: notice,
                        systemImage: "checkmark.circle.fill",
                        color: GatherTheme.success
                    )
                }
            }
        }
    }

    // MARK: 保存规则说明（F11）

    /// 统一保存规则说明：文本/数字「离开输入框或回车」保存，选择项立即保存，
    /// 每次保存都有「已保存 X」提示。用户不必先猜回车语义再改设置。
    private var saveRuleHint: some View {
        Section {
            Label(
                GatherLocalization.l("文本与数字在离开输入框或按回车时保存；下拉选择立即保存，结果会显示在顶部提示条。"),
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 高级设置（F11：默认收起）

    /// 高级设置：模型与推理 + 数据库 + 人脸算法参数。
    /// 这些是**实现细节**，摄影工作流里几乎不需要在首屏看到。
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvancedSettings) {
                VStack(alignment: .leading, spacing: 14) {
                    modelRows
                    ForEach(SettingsViewModel.advancedGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(GatherLocalization.l(group.titleZh))
                                .font(.headline)
                            ForEach(group.fields) { field in
                                fieldRow(field)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label(GatherLocalization.l("模型、推理与性能参数"), systemImage: "gearshape.2")
            }
        }
    }

    // MARK: 模型与推理

    /// 模型与推理行（由 advancedSection 在折叠面板内渲染，不再自带 Section 头）。
    @ViewBuilder
    private var modelRows: some View {
        Group {
            if let model = viewModel.modelStatus {
                presenceRow(GatherLocalization.l("检测模型"), presence: model.detectorModel)
                presenceRow(GatherLocalization.l("编码模型"), presence: model.encoderModel)

                modelPathRow(key: FaceEmbeddingModelFactory.modelPathSetting, label: GatherLocalization.l("专用人脸模型路径"))

                if !model.detectorModel.exists || !model.encoderModel.exists {
                    installBlock(model)
                }

                LabeledContent(GatherLocalization.l("模型信息")) {
                    Text(modelInfoText(model))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent(GatherLocalization.l("推理后端")) {
                    Picker("", selection: Binding(
                        get: { viewModel.backend },
                        set: { viewModel.setBackend($0) }
                    )) {
                        Text(GatherLocalization.l("自动")).tag("auto")
                        ForEach(model.availableBackends, id: \.value) { backend in
                            Text(backend.label).tag(backend.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                LabeledContent(GatherLocalization.l("模型目录")) {
                    HStack(spacing: 8) {
                        Text(model.modelResourcesDir)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(GatherLocalization.l("在访达中显示")) {
                            viewModel.openModelDirectory()
                        }
                    }
                }
            } else {
                LabeledContent(GatherLocalization.l("模型状态")) {
                    Text(GatherLocalization.l("正在读取模型状态…"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelInfoText(_ model: MLStatusData) -> String {
        if model.modelInfo.embeddingDim > 0 {
            return String(format: GatherLocalization.l("Vision 人脸检测 · CoreML 身份识别 · 112×112 对齐输入 · %lld 维特征"),
                          Int64(model.modelInfo.embeddingDim))
        }
        return GatherLocalization.l("Vision 人脸检测 · CoreML 身份识别 · 112×112 对齐输入 · 自定义模型")
    }

    /// 模型存在性：Label + SF Symbol + 语义色（不再是 ✓/✗ 字形 + 纯颜色信号）。
    private func presenceRow(_ label: String, presence: MLModelPresence) -> some View {
        LabeledContent(label) {
            Label(
                presence.exists ? GatherLocalization.l("可用") : GatherLocalization.l("未找到"),
                systemImage: presence.exists ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(presence.exists ? GatherTheme.success : GatherTheme.error)
            .accessibilityValue(presence.exists ? GatherLocalization.l("可用") : GatherLocalization.l("未找到"))
        }
    }

    private func modelPathRow(key: String, label: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { viewModel.edits[key] ?? viewModel.values[key] ?? "" },
                    set: { viewModel.edits[key] = $0 }
                ))
                .font(.body.monospaced())
                // N06：模型路径原先只响应回车，与首屏「文本与数字在离开输入框
                // 或按回车时保存」的承诺不一致（Tab 走开看起来改了、其实没写库）。
                // 这里与普通字段同一套语义：失焦提交 + 回车提交。
                .focused($focusedFieldKey, equals: key)
                .onSubmit { commitModelPath(key: key) }
                .onChange(of: focusedFieldKey) { previous, current in
                    if previous == key, current != key {
                        viewModel.saveModelPath(key: key)
                    }
                }
                .frame(minWidth: 180, maxWidth: 280)

                Button(GatherLocalization.l("选择…")) { pickingModelPathKey = key }
                Button(GatherLocalization.l("打开")) { viewModel.openModelPathDirectory(key: key) }
                    .help(GatherLocalization.l("在访达中显示该模型所在目录"))
            }
        }
    }

    /// 模型缺失横幅：SF Symbol + 语义色底 + 原生进度条。
    private func installBlock(_ model: MLStatusData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                GatherLocalization.l("人脸模型未找到。请恢复内置 SFace，或选择有效的 CoreML 模型。"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(GatherTheme.warning)

            Text(model.modelResourcesDir)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(GatherLocalization.l("打开模型文件夹")) {
                    viewModel.openModelDirectory()
                }
                Button(GatherLocalization.l("使用内置 SFace")) {
                    viewModel.save(key: FaceEmbeddingModelFactory.modelPathSetting, value: "")
                }
            }

            switch viewModel.downloadPhase {
            case .downloading(let filename, let percent, let step):
                ProgressView(value: min(1, max(0, percent / 100))) {
                    Text(step == .extracting
                        ? GatherLocalization.l("正在解压…")
                        : String(format: GatherLocalization.l("已下载 %d%%（%@）"), Int(percent), filename))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .done:
                Label(GatherLocalization.l("人脸模型已安装"), systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(GatherTheme.success)
                    .font(.callout)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(GatherTheme.warning.opacity(0.10))
        )
    }

    private var downloadButtonTitle: String {
        switch viewModel.downloadPhase {
        case .downloading(_, _, _):
            return GatherLocalization.l("下载中…")
        case .error:
            return GatherLocalization.l("下载失败")
        case .done:
            return GatherLocalization.l("已安装")
        case .idle:
            return GatherLocalization.l("自动下载模型")
        }
    }

    // MARK: Capture One 健康

    private var c1HealthSection: some View {
        Section(GatherLocalization.l("Capture One 健康")) {
            LabeledContent(GatherLocalization.l("四层连接预检")) {
                Button(viewModel.c1Checking
                       ? GatherLocalization.l("检测中…")
                       : GatherLocalization.l("重新检测")) {
                    Task { await viewModel.checkC1Health() }
                }
                .disabled(viewModel.c1Checking)
            }

            if viewModel.c1HealthError {
                checkLine(
                    GatherLocalization.l("预检失败：无法连接 Capture One 自动化通道"),
                    tone: GatherTheme.error,
                    symbol: "xmark.circle.fill"
                )
            } else if let health = viewModel.c1Health {
                checkRow(zh: GatherLocalization.l("Capture One 可达"), passed: health.reachable)
                checkRow(zh: GatherLocalization.l("Capture One 运行中"), passed: health.appRunning)
                checkRow(zh: GatherLocalization.l("文档已打开"), passed: health.documentOpen)
                checkRow(zh: GatherLocalization.l("自动化权限已授权"), passed: health.automationAuthorized)
            } else {
                Text(GatherLocalization.l("正在检测…"))
                    .foregroundStyle(.secondary)
            }

            LabeledContent(
                GatherLocalization.l("最近一次命令耗时"),
                value: viewModel.c1Health.flatMap { $0.latencyMs }.map { "\($0) ms" } ?? "—"
            )
            LabeledContent(
                GatherLocalization.l("最近同步时间"),
                value: viewModel.lastSyncDate.map(SettingsViewModel.dateText) ?? "—"
            )

            queueGrid
        }
    }

    /// 预检结果行：Label + 语义色 + VoiceOver 值（旧版是 ✓/✗ 字形 + 纯颜色）。
    private func checkRow(zh: String, passed: Bool) -> some View {
        checkLine(
            zh,
            tone: passed ? GatherTheme.success : GatherTheme.error,
            symbol: passed ? "checkmark.circle.fill" : "xmark.circle.fill",
            value: passed ? GatherLocalization.l("通过") : GatherLocalization.l("未通过")
        )
    }

    private func checkLine(_ text: String, tone: Color, symbol: String, value: String? = nil) -> some View {
        Label(text, systemImage: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tone)
            .accessibilityValue(value ?? "")
    }

    /// 写回队列计数：原生 Grid，需要行动的数字用语义色。
    @ViewBuilder
    private var queueGrid: some View {
        if let sync = viewModel.syncStatus {
            Grid(horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    queueCell(GatherLocalization.l("待写入"), sync.pending)
                    queueCell(GatherLocalization.l("写入中"), sync.writing)
                    queueCell(GatherLocalization.l("已写入"), sync.written)
                }
                GridRow {
                    queueCell(GatherLocalization.l("已同步"), sync.synced)
                    queueCell(GatherLocalization.l("失败"), sync.failed, alert: true)
                    queueCell(GatherLocalization.l("冲突"), sync.conflict, alert: true)
                }
            }
            .gridColumnAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.syncStateError {
            Text(GatherLocalization.l("同步状态读取失败"))
                .foregroundStyle(.secondary)
        } else if viewModel.syncSessionId == nil {
            Text(GatherLocalization.l("无工作区，写回队列来自当前会话"))
                .foregroundStyle(.secondary)
        } else {
            Text(GatherLocalization.l("读取中"))
                .foregroundStyle(.secondary)
        }
    }

    private func queueCell(_ label: String, _ value: Int, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value, format: .number)
                .font(.title3.monospacedDigit())
                .foregroundStyle(alert && value > 0 ? GatherTheme.warning : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: 语言

    private var languageSection: some View {
        Section(GatherLocalization.l("语言")) {
            LabeledContent(GatherLocalization.l("界面语言")) {
                Picker("", selection: Binding(
                    get: { viewModel.language },
                    set: { viewModel.setLanguage($0) }
                )) {
                    Text(GatherLocalization.l("简体中文")).tag("zh-CN")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Text(GatherLocalization.l("切换语言后菜单与全部页面文案立即更新，并持久化保存。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 人脸分析

    private var faceAnalysisSection: some View {
        Section(GatherLocalization.l("人脸分析")) {
            ForEach(SettingsViewModel.generalSliders) { slider in
                sliderRow(slider)
            }
            ForEach(SettingsViewModel.advancedSliders) { slider in
                sliderRow(slider)
            }
        }
    }

    private func sliderRow(_ slider: SliderSetting) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { viewModel.sliderValue(for: slider.key, defaultValue: slider.defaultValue) },
                    set: { viewModel.sliderValues[slider.key] = $0 }
                ), in: slider.min...slider.max, step: slider.step) { editing in
                    if !editing { viewModel.commitSlider(slider) }
                }
                .accessibilityLabel(GatherLocalization.l(slider.zhLabel))
                .accessibilityValue(Text(sliderValueWithUnit(slider)))

                Text(sliderValueWithUnit(slider))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        } label: {
            settingLabel(slider.zhLabel, description: slider.zhDesc)
        }
    }

    private func sliderValueWithUnit(_ slider: SliderSetting) -> String {
        let value = viewModel.sliderValueText(slider)
        switch slider.key {
        case "max_detections", "default_min_samples":
            return String(format: GatherLocalization.l("%@ 张"), value)
        case "onnx_threads":
            return String(format: GatherLocalization.l("%@ 线程"), value)
        default:
            return value
        }
    }

    // MARK: 分组设置（缓存 / 图片处理 / 数据库 / C1 集成 / 元数据）

    @ViewBuilder
    private func settingsSection(_ group: SettingGroup) -> some View {
        Section(GatherLocalization.l(group.titleZh)) {
            ForEach(group.fields) { field in
                fieldRow(field)
            }
        }
    }

    /// 标签列：标题 + 次要说明（说明在标签下方，不再把控件推到窗口最右）。
    private func settingLabel(_ title: String, description: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(GatherLocalization.l(title))
            if let description, !description.isEmpty {
                Text(GatherLocalization.l(description))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 回车提交：先结束焦点（触发同一套失焦提交逻辑），再显式保存一次——
    /// 空值/越界等非法输入仍由 saveField 给出错误并保留编辑值。
    private func commitFieldOnSubmit(_ field: SettingField) {
        focusedFieldKey = nil
        viewModel.saveField(field)
    }

    /// 模型路径的回车提交（与普通字段同一套语义，N06）。
    private func commitModelPath(key: String) {
        focusedFieldKey = nil
        viewModel.saveModelPath(key: key)
    }

    private func fieldBinding(_ field: SettingField) -> Binding<String> {
        Binding(
            get: { viewModel.edits[field.key] ?? viewModel.values[field.key] ?? "" },
            set: { viewModel.edits[field.key] = $0 }
        )
    }

    @ViewBuilder
    private func fieldRow(_ field: SettingField) -> some View {
        let isPathField = field.key.contains("dir") || field.key.contains("path")
        LabeledContent {
            switch field.type {
            case .text:
                HStack(spacing: 6) {
                    TextField("", text: fieldBinding(field))
                        .font(isPathField ? .body.monospaced() : .body)
                        .focused($focusedFieldKey, equals: field.key)
                        .onSubmit { commitFieldOnSubmit(field) }
                        // F11：失焦即提交。旧实现只在回车时保存，用户 Tab 走开时
                        // 输入看起来已经生效、实际没写库（而下拉选择立即保存）——
                        // 同一屏两套保存语义。
                        .onChange(of: focusedFieldKey) { previous, current in
                            if previous == field.key, current != field.key {
                                viewModel.saveField(field)
                            }
                        }
                        .frame(minWidth: 160, maxWidth: isPathField ? 280 : 220)
                    if isPathField {
                        Button(GatherLocalization.l("选择…")) { pickingField = field }
                    }
                }
            case .number:
                TextField("", text: fieldBinding(field))
                    .multilineTextAlignment(.trailing)
                    .focused($focusedFieldKey, equals: field.key)
                    .onSubmit { commitFieldOnSubmit(field) }
                    .onChange(of: focusedFieldKey) { previous, current in
                        if previous == field.key, current != field.key {
                            viewModel.saveField(field)
                        }
                    }
                    .frame(width: 110)
            case .select(let options):
                // 对齐旧版 Settings/index.tsx:623：select 带 disabled 的
                // 「请选择」占位 option（value=""，映射 nil）。当前值缺失/未知
                // 时展示占位；占位不可重新选中（set(nil) 不落库），对齐旧版
                // disabled 语义，避免静默回退到第一个选项。
                Picker("", selection: Binding<String?>(
                    get: {
                        let current = viewModel.values[field.key] ?? ""
                        return options.contains(where: { $0.value == current }) ? current : nil
                    },
                    set: { selected in
                        guard let selected else { return }
                        viewModel.saveSelect(field, value: selected)
                    }
                )) {
                    Text(GatherLocalization.l("请选择")).tag(String?.none)
                    ForEach(options) { option in
                        Text(GatherLocalization.l(option.labelZh))
                            .tag(String?.some(option.value))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        } label: {
            settingLabel(field.zhLabel, description: field.zhDesc)
        }
    }
}
