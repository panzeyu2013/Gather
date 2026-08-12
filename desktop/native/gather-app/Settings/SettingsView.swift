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
//   轮询 sync-state）。写回队列 6 格与最近同步时间依赖 c1:sync-state 命令，原生
//   路由未接线 → 显示占位并说明（限制见任务报告）。
// - 模型路径编辑：detector_model_path/encoder_model_path 可编辑输入框 + 保存后
//   重查 settings.get_ml_status。
// - 语言切换：settings.set_language 持久化后本页文案跟随 ui_language。
//   限制：应用菜单在 GatherAppDelegate.installMenu（private）内构建，本任务
//   文件清单不含 GatherAppDelegate.swift，无法重建菜单，仅设置页内文案联动。
import SwiftUI
import AppKit
import GatherCore

// MARK: - 页面文案（zh-CN.json settings.* / c1.health.* 键 + 英文对照）

public struct PageCopy {
    public let zh: String
    public let en: String
    public init(zh: String, en: String) {
        self.zh = zh
        self.en = en
    }
}

// MARK: - 分组设置与滑杆定义（对齐 TS Settings/index.tsx GROUPS / 滑杆段）

public struct SelectOption: Identifiable, Equatable {
    public let value: String
    public let labelZh: String
    public let labelEn: String
    public var id: String { value }
    public init(value: String, labelZh: String, labelEn: String) {
        self.value = value
        self.labelZh = labelZh
        self.labelEn = labelEn
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
    public let enLabel: String
    public let zhDesc: String
    public let enDesc: String
    public var id: String { key }
    public init(key: String, type: SettingFieldType, zhLabel: String, enLabel: String, zhDesc: String, enDesc: String) {
        self.key = key
        self.type = type
        self.zhLabel = zhLabel
        self.enLabel = enLabel
        self.zhDesc = zhDesc
        self.enDesc = enDesc
    }
}

public struct SettingGroup: Identifiable {
    public let id: String
    public let titleZh: String
    public let titleEn: String
    public let fields: [SettingField]
    public init(id: String, titleZh: String, titleEn: String, fields: [SettingField]) {
        self.id = id
        self.titleZh = titleZh
        self.titleEn = titleEn
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
    public let enLabel: String
    public let zhDesc: String
    public let enDesc: String
    public var id: String { key }
    public init(key: String, min: Double, max: Double, step: Double, isInteger: Bool, defaultValue: Double, zhLabel: String, enLabel: String, zhDesc: String, enDesc: String) {
        self.key = key
        self.min = min
        self.max = max
        self.step = step
        self.isInteger = isInteger
        self.defaultValue = defaultValue
        self.zhLabel = zhLabel
        self.enLabel = enLabel
        self.zhDesc = zhDesc
        self.enDesc = enDesc
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
    /// 下载 → 解压；进度条文案按此切换「正在下载模型…/正在解压…」）。
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

    public var isChinese: Bool { language == "zh-CN" }

    public func text(_ copy: PageCopy) -> String {
        isChinese ? copy.zh : copy.en
    }

    // MARK: - 数据加载

    public func load() {
        do {
            values = try client.execute("settings.get_all").decoded(as: [String: String].self)
            modelStatus = try client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["onnx_provider"] ?? "auto"
            edits = values
            seedSliderValues()
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
            notice = value == "en" ? "Language saved" : "语言已保存"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 推理后端

    public func setBackend(_ value: String) {
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string("onnx_provider"),
                "value": .string(value),
            ])
            backend = value
            values["onnx_provider"] = value
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            notice = text(PageCopy(zh: "推理后端已保存", en: "Inference backend saved"))
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 分组设置（含类型约束：数值 min/max 校验，非法值禁止保存）

    public func saveField(_ field: SettingField) {
        let raw = (edits[field.key] ?? values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            errorMessage = text(PageCopy(
                zh: "「\(field.zhLabel)」不能为空",
                en: "\(field.enLabel) must not be empty"
            ))
            return
        }
        switch field.type {
        case .text:
            save(key: field.key, value: raw)
        case .number(let min, let max):
            guard let parsed = Double(raw), parsed.isFinite else {
                errorMessage = text(PageCopy(
                    zh: "「\(field.zhLabel)」必须是数字",
                    en: "\(field.enLabel) must be a number"
                ))
                return
            }
            if let min, parsed < min {
                errorMessage = text(PageCopy(
                    zh: "「\(field.zhLabel)」不能小于 \(Self.numberText(min))",
                    en: "\(field.enLabel) must not be below \(Self.numberText(min))"
                ))
                return
            }
            if let max, parsed > max {
                errorMessage = text(PageCopy(
                    zh: "「\(field.zhLabel)」不能大于 \(Self.numberText(max))",
                    en: "\(field.enLabel) must not exceed \(Self.numberText(max))"
                ))
                return
            }
            save(key: field.key, value: raw)
        case .select:
            break
        }
    }

    public func saveSelect(_ field: SettingField, value: String) {
        save(key: field.key, value: value)
    }

    // MARK: - 模型路径编辑（保存后重查模型状态）

    public func saveModelPath(key: String) {
        let raw = (edits[key] ?? values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            errorMessage = text(PageCopy(zh: "模型路径不能为空", en: "Model path must not be empty"))
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

    private func save(key: String, value: String) {
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string(key),
                "value": .string(value),
            ])
            values[key] = value
            edits[key] = value
            notice = text(PageCopy(zh: "已保存 \(key)", en: "Saved \(key)"))
            errorMessage = nil
            if key == "detector_model_path" || key == "encoder_model_path" || key == "onnx_provider" {
                modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 目录与重置

    public func openModelDirectory() {
        guard let path = modelStatus?.modelResourcesDir, !path.isEmpty else {
            errorMessage = text(PageCopy(zh: "模型目录不可用", en: "Model directory is unavailable"))
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
            errorMessage = text(PageCopy(zh: "模型路径不可用", en: "Model path is unavailable"))
            return
        }
        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        NSWorkspace.shared.open(URL(fileURLWithPath: parent, isDirectory: true))
    }

    public func reset() {
        do {
            values = try client.execute("settings.reset").decoded(as: [String: String].self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["onnx_provider"] ?? "auto"
            edits = values
            seedSliderValues()
            notice = text(PageCopy(zh: "设置已恢复默认值", en: "Settings restored to defaults"))
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
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
                _ = try await runAppleScript(Self.documentProbeScript(appName: appName), timeout: 3)
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

    private static func documentProbeScript(appName: String) -> String {
        """
        tell application "\(appName)"
          get name of current document
        end tell
        """
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
        } catch {
            syncStateError = true
        }
    }

    /// 最近同步时间：优先 reloadAckedAt（对齐 C1HealthPanel.tsx:147-155，
    /// 语义为 Capture One 最后一次 reload 确认时间），否则回退队列项
    /// updatedAt 的最大值（最后一次写回活动的近似）。
    public var lastSyncDate: Date? {
        if let ack = syncReloadAckedAt, !ack.isEmpty, let date = Self.parseISO8601(ack) {
            return date
        }
        guard let syncStatus else { return nil }
        return syncStatus.items.compactMap { Self.parseISO8601($0.updatedAt) }.max()
    }

    private static func mostRecentSession(_ sessions: [SessionData]) -> SessionData? {
        sessions.max { a, b in
            (parseISO8601(a.updatedAt) ?? .distantPast) < (parseISO8601(b.updatedAt) ?? .distantPast)
        }
    }

    /// ISO8601（含/不含小数秒）解析，对齐 DashboardView.parseISO8601。
    public static func parseISO8601(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// 本地化时间文案：zh 环境 `yyyy年M月d日 HH:mm`，其余按系统区域模板
    /// （与 PersonDetail 的时间戳展示保持一致）。
    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMd HH:mm")
        }
        return formatter.string(from: date)
    }

    // MARK: - 模型下载（旧版 model-downloader.ts 的 Swift 移植）

    public var isDownloading: Bool {
        if case .downloading = downloadPhase { return true }
        return false
    }

    public func startModelDownload() async {
        guard !isDownloading else { return }
        let configured = (values["model_download_url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: configured.isEmpty ? ModelInstaller.packageURL : configured) else {
            downloadPhase = .error
            errorMessage = text(PageCopy(zh: "模型下载地址无效", en: "Invalid model download URL"))
            try? await Task.sleep(for: .seconds(3))
            if downloadPhase == .error { downloadPhase = .idle }
            return
        }
        guard let modelsDir = modelStatus?.modelResourcesDir, !modelsDir.isEmpty else {
            downloadPhase = .error
            errorMessage = text(PageCopy(zh: "模型目录不可用", en: "Model directory is unavailable"))
            try? await Task.sleep(for: .seconds(3))
            if downloadPhase == .error { downloadPhase = .idle }
            return
        }
        downloadPhase = .downloading(filename: "buffalo_l.zip", percent: 0, step: .downloading)
        do {
            try await ModelInstaller.install(url: url, modelsDir: modelsDir) { step, filename, percent in
                self.downloadPhase = .downloading(filename: filename, percent: percent, step: step)
            }
            downloadPhase = .done
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            // 对齐旧版：完成态停留 2s 后回 idle（模型仍缺失则横幅保留）。
            try? await Task.sleep(for: .seconds(2))
            if downloadPhase == .done { downloadPhase = .idle }
        } catch {
            downloadPhase = .error
            errorMessage = text(PageCopy(
                zh: "模型下载失败：\(error.localizedDescription)",
                en: "Model download failed: \(error.localizedDescription)"
            ))
            // 对齐旧版：错误态停留 3s 后回 idle。
            try? await Task.sleep(for: .seconds(3))
            if downloadPhase == .error { downloadPhase = .idle }
        }
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

    /// 人脸分析常规参数（TS index.tsx L227-286）。
    public static let generalSliders: [SliderSetting] = [
        SliderSetting(
            key: "detect_confidence", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.5,
            zhLabel: "检测敏感度", enLabel: "Detection confidence",
            zhDesc: "低于此置信度的人脸将被忽略", enDesc: "Faces below this confidence are ignored"
        ),
        SliderSetting(
            key: "default_eps", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.6,
            zhLabel: "聚类半径", enLabel: "Cluster radius",
            zhDesc: "值越大，不同人脸越容易被归为同一人", enDesc: "Higher values cluster different faces together more easily"
        ),
        SliderSetting(
            key: "default_min_samples", min: 1, max: 20, step: 1, isInteger: true, defaultValue: 2,
            zhLabel: "最小样本数", enLabel: "Min samples",
            zhDesc: "一个人至少出现 N 张照片才形成聚类", enDesc: "A person must appear in at least N photos to form a cluster"
        ),
    ]

    /// 人脸分析高级参数（TS index.tsx L457-512）。
    public static let advancedSliders: [SliderSetting] = [
        SliderSetting(
            key: "nms_threshold", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.4,
            zhLabel: "NMS 阈值", enLabel: "NMS threshold",
            zhDesc: "重叠人脸的过滤阈值", enDesc: "Overlap filtering threshold for detections"
        ),
        SliderSetting(
            key: "max_detections", min: 1, max: 500, step: 1, isInteger: true, defaultValue: 100,
            zhLabel: "最大检测数", enLabel: "Max detections",
            zhDesc: "单张图片最多检测的人脸数", enDesc: "Maximum faces detected per image"
        ),
        SliderSetting(
            key: "onnx_threads", min: 1, max: 16, step: 1, isInteger: true, defaultValue: 4,
            zhLabel: "ONNX 线程", enLabel: "ONNX threads",
            zhDesc: "推理并行线程数", enDesc: "Parallel inference threads"
        ),
    ]

    /// 分组设置（TS index.tsx L25-74；min/max 抄 input 约束 + 描述文案约束）。
    public static let settingGroups: [SettingGroup] = [
        SettingGroup(id: "cache", titleZh: "缓存", titleEn: "Cache", fields: [
            SettingField(
                key: "memory_cache_size", type: .number(min: 1, max: nil),
                zhLabel: "内存缓存条目数", enLabel: "Memory cache entries",
                zhDesc: "内存中缓存的缩略图最大数量", enDesc: "Maximum thumbnails cached in memory"
            ),
            SettingField(
                key: "memory_cache_max_size_mb", type: .number(min: 32, max: 2048),
                zhLabel: "内存缓存上限 (MB)", enLabel: "Memory cache cap (MB)",
                zhDesc: "缩略图和预览内存缓存的最大空间，防止高分辨率图片占满内存",
                enDesc: "Maximum memory for thumbnails and previews, preventing high-res images from exhausting RAM"
            ),
            SettingField(
                key: "disk_cache_dir", type: .text,
                zhLabel: "磁盘缓存目录", enLabel: "Disk cache directory",
                zhDesc: "磁盘缓存存储路径（留空使用默认）", enDesc: "Disk cache storage path (empty for default)"
            ),
            SettingField(
                key: "disk_cache_max_size_gb", type: .number(min: 0, max: nil),
                zhLabel: "磁盘缓存上限 (GB)", enLabel: "Disk cache cap (GB)",
                zhDesc: "磁盘缓存占用硬盘的最大空间", enDesc: "Maximum disk space used by the cache"
            ),
            SettingField(
                key: "disk_cache_eviction_policy", type: .select([
                    SelectOption(value: "lru", labelZh: "LRU（最近最少使用）", labelEn: "LRU (least recently used)"),
                    SelectOption(value: "fifo", labelZh: "FIFO（先进先出）", labelEn: "FIFO (first in, first out)"),
                    SelectOption(value: "lfu", labelZh: "LFU（最不经常使用）", labelEn: "LFU (least frequently used)"),
                ]),
                zhLabel: "淘汰策略", enLabel: "Eviction policy",
                zhDesc: "lru=LRU（最近最少使用）, fifo=FIFO（先进先出）, lfu=LFU（最不经常使用）",
                enDesc: "lru=LRU (least recently used), fifo=FIFO (first in, first out), lfu=LFU (least frequently used)"
            ),
        ]),
        SettingGroup(id: "image", titleZh: "图片处理", titleEn: "Image Processing", fields: [
            SettingField(
                key: "thumbnail_size", type: .number(min: 256, max: 2048),
                zhLabel: "缩略图尺寸", enLabel: "Thumbnail size",
                zhDesc: "画廊缓存分辨率（建议 1024；内部按 256/1024/2048 三级复用）",
                enDesc: "Gallery cache resolution (1024 recommended; reused at 256/1024/2048)"
            ),
            SettingField(
                key: "thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "缩略图质量", enLabel: "Thumbnail quality",
                zhDesc: "缩略图的 JPEG 压缩质量 (0-100)", enDesc: "JPEG compression quality of thumbnails (0-100)"
            ),
            SettingField(
                key: "thumbnail_concurrency", type: .number(min: 1, max: maxConcurrency),
                zhLabel: "缩略图生成并发数", enLabel: "Thumbnail concurrency",
                zhDesc: "同时生成缩略图的任务数（RAW 建议 2-4，最大 8）",
                enDesc: "Concurrent thumbnail tasks (2-4 for RAW, max 8)"
            ),
            SettingField(
                key: "face_thumbnail_size", type: .number(min: 1, max: nil),
                zhLabel: "人脸缩略图尺寸", enLabel: "Face thumbnail size",
                zhDesc: "人脸缩略图的宽高像素值", enDesc: "Width/height in pixels of face thumbnails"
            ),
            SettingField(
                key: "face_thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "人脸缩略图质量", enLabel: "Face thumbnail quality",
                zhDesc: "人脸缩略图的 JPEG 压缩质量 (0-100)", enDesc: "JPEG compression quality of face thumbnails (0-100)"
            ),
        ]),
        SettingGroup(id: "db", titleZh: "数据库", titleEn: "Database", fields: [
            SettingField(
                key: "db_cache_size_mb", type: .number(min: 1, max: nil),
                zhLabel: "缓存大小 (MB)", enLabel: "Cache size (MB)",
                zhDesc: "SQLite 数据库的页面缓存大小", enDesc: "SQLite page cache size"
            ),
            SettingField(
                key: "db_synchronous", type: .select([
                    SelectOption(value: "off", labelZh: "OFF（关闭）", labelEn: "OFF"),
                    SelectOption(value: "normal", labelZh: "NORMAL（正常）", labelEn: "NORMAL"),
                    SelectOption(value: "full", labelZh: "FULL（完整）", labelEn: "FULL"),
                ]),
                zhLabel: "同步模式", enLabel: "Sync mode",
                zhDesc: "off=OFF（关闭）, normal=NORMAL（正常）, full=FULL（完整）",
                enDesc: "off=OFF, normal=NORMAL, full=FULL"
            ),
        ]),
        SettingGroup(id: "c1", titleZh: "Capture One 集成", titleEn: "Capture One Integration", fields: [
            SettingField(
                key: "c1_timeout_ms", type: .number(min: 1, max: nil),
                zhLabel: "超时时间 (ms)", enLabel: "Timeout (ms)",
                zhDesc: "与 Capture One 通信的超时毫秒数", enDesc: "Communication timeout with Capture One, in milliseconds"
            ),
            SettingField(
                key: "c1_retries", type: .number(min: 0, max: nil),
                zhLabel: "重试次数", enLabel: "Retries",
                zhDesc: "与 Capture One 通信的最大重试次数", enDesc: "Maximum retries when communicating with Capture One"
            ),
            SettingField(
                key: "c1_reload_delay_ms", type: .number(min: 0, max: nil),
                zhLabel: "重载延迟 (ms)", enLabel: "Reload delay (ms)",
                zhDesc: "重载元数据后的等待延迟毫秒数", enDesc: "Wait delay in milliseconds after reloading metadata"
            ),
        ]),
        SettingGroup(id: "metadata", titleZh: "元数据", titleEn: "Metadata", fields: [
            SettingField(
                key: "metadata_write_mode", type: .select([
                    SelectOption(value: "auto", labelZh: "自动（RAW侧边栏，成品格式内嵌）", labelEn: "Auto (sidecar for RAW, embedded for finished formats)"),
                    SelectOption(value: "sidecar", labelZh: "XMP Sidecar", labelEn: "XMP Sidecar"),
                    SelectOption(value: "embedded", labelZh: "Embedded", labelEn: "Embedded"),
                ]),
                zhLabel: "写入方式", enLabel: "Write mode",
                zhDesc: "auto=自动（RAW侧边栏，成品格式内嵌）, sidecar=XMP Sidecar, embedded=Embedded",
                enDesc: "auto=sidecar for RAW and embedded for finished formats, sidecar=XMP Sidecar, embedded=Embedded"
            ),
            SettingField(
                key: "metadata_write_debounce_ms", type: .number(min: 1, max: nil),
                zhLabel: "后台写入防抖 (ms)", enLabel: "Writeback debounce (ms)",
                zhDesc: "连续评级或改色后等待多久合并写入，建议 300-800",
                enDesc: "Debounce for coalescing consecutive rating or color edits; 300-800 recommended"
            ),
            SettingField(
                key: "capture_one_color_compatibility", type: .select([
                    SelectOption(value: "label_and_urgency", labelZh: "Label + Urgency（推荐，兼容更多版本）", labelEn: "Label + Urgency (recommended, more compatible)"),
                    SelectOption(value: "label_only", labelZh: "仅标准 xmp:Label", labelEn: "Standard xmp:Label only"),
                ]),
                zhLabel: "Capture One 颜色兼容", enLabel: "C1 color compatibility",
                zhDesc: "label_and_urgency=Label + Urgency（推荐，兼容更多版本）, label_only=仅标准 xmp:Label",
                enDesc: "label_and_urgency=Label + Urgency (recommended), label_only=standard xmp:Label only"
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
private enum ModelInstaller {
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

        var errorDescription: String? {
            switch self {
            case .badStatus: "模型下载返回了非 2xx 状态码"
            case .extractFailed: "MODEL_EXTRACT_FAILED"
            case .toolFailed(let tool): "解压工具执行失败：\(tool)"
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.badStatus
        }
        let total = http.expectedContentLength > 0 ? Double(http.expectedContentLength) : 0
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
        try fileManager.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        for (source, dest) in fileMap {
            let sourceURL = extractDir.appendingPathComponent(source)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destURL = URL(fileURLWithPath: modelsDir).appendingPathComponent(dest)
            try? fileManager.removeItem(at: destURL)
            try fileManager.moveItem(at: sourceURL, to: destURL)
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

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var confirmReset = false

    public init(router: CommandRouter) {
        _viewModel = State(initialValue: SettingsViewModel(router: router))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: "操作失败：\(error)", color: GatherTheme.error) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelCard
                    c1HealthCard
                    faceAnalysisCard
                    groupsCard
                }
                .padding(24)
            }
        }
        .background(Color.gatherBackground)
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
        .confirmationDialog(
            viewModel.text(PageCopy(zh: "恢复所有设置默认值？", en: "Reset all settings to defaults?")),
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button(viewModel.text(PageCopy(zh: "恢复默认", en: "Reset")), role: .destructive) {
                viewModel.reset()
            }
            Button(viewModel.text(PageCopy(zh: "取消", en: "Cancel")), role: .cancel) {}
        } message: {
            Text(viewModel.text(PageCopy(
                zh: "模型路径、后端、缓存和写回参数都会恢复默认值。",
                en: "Model paths, backend, cache and writeback settings will be restored to defaults."
            )))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.text(PageCopy(zh: "设置", en: "Settings")))
                    .font(.system(size: 24, weight: .bold))
                Text(viewModel.text(PageCopy(
                    zh: "原生宿主配置、推理后端和模型状态",
                    en: "Native host configuration, inference backend and model status"
                )))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(viewModel.text(PageCopy(zh: "刷新", en: "Refresh")), systemImage: "arrow.clockwise") {
                viewModel.load()
            }
            Button(viewModel.text(PageCopy(zh: "恢复默认", en: "Reset to defaults")), systemImage: "arrow.counterclockwise") {
                confirmReset = true
            }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 模型与推理

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.text(PageCopy(zh: "模型与推理", en: "Models & Inference")))
                .font(.title3.weight(.semibold))
            if let model = viewModel.modelStatus {
                LabeledContent(viewModel.text(PageCopy(zh: "平台", en: "Platform")), value: model.platform)
                LabeledContent(viewModel.text(PageCopy(zh: "后端", en: "Backend")), value: model.autoBackendLabel)
                LabeledContent(viewModel.text(PageCopy(zh: "Provider", en: "Provider")), value: model.provider)
                // 对齐旧版 settings.modelInfoText 参数表（双尺度检测 / 预览 /
                // 编码输入 / 特征维度），补齐原仅展示 Embedding 的缺口。
                LabeledContent(
                    viewModel.text(PageCopy(zh: "检测输入尺寸", en: "Detect input size")),
                    value: "\(model.modelInfo.secondaryDetectInputSize)×\(model.modelInfo.secondaryDetectInputSize) + \(model.modelInfo.detectInputSize)×\(model.modelInfo.detectInputSize)"
                )
                LabeledContent(
                    viewModel.text(PageCopy(zh: "分析预览最长边", en: "Preview max dimension")),
                    value: "\(model.modelInfo.previewMaxDimension)px"
                )
                LabeledContent(
                    viewModel.text(PageCopy(zh: "编码输入尺寸", en: "Encoder input size")),
                    value: "\(model.modelInfo.encoderInputSize)×\(model.modelInfo.encoderInputSize)"
                )
                LabeledContent(
                    viewModel.text(PageCopy(zh: "特征维度", en: "Embedding dimension")),
                    value: "\(model.modelInfo.embeddingDim) 维"
                )
                modelStatusRow(
                    label: PageCopy(zh: "检测模型", en: "Detector model"),
                    presence: model.detectorModel
                )
                modelStatusRow(
                    label: PageCopy(zh: "编码模型", en: "Encoder model"),
                    presence: model.encoderModel
                )
                modelPathRow(key: "detector_model_path", label: PageCopy(zh: "检测模型路径", en: "Detector model path"))
                modelPathRow(key: "encoder_model_path", label: PageCopy(zh: "编码模型路径", en: "Encoder model path"))
                if !model.detectorModel.exists || !model.encoderModel.exists {
                    installBanner(model)
                }
                Picker(viewModel.text(PageCopy(zh: "语言", en: "Language")), selection: Binding(
                    get: { viewModel.language },
                    set: { viewModel.setLanguage($0) }
                )) {
                    Text("简体中文").tag("zh-CN")
                    Text("English").tag("en")
                }
                Picker(viewModel.text(PageCopy(zh: "推理后端", en: "Inference backend")), selection: Binding(
                    get: { viewModel.backend },
                    set: { viewModel.setBackend($0) }
                )) {
                    Text(viewModel.text(PageCopy(zh: "自动", en: "Auto"))).tag("auto")
                    ForEach(model.availableBackends, id: \.value) { backend in
                        Text(backend.label).tag(backend.value)
                    }
                }
                HStack {
                    Text(viewModel.text(PageCopy(zh: "模型目录", en: "Model directory")))
                        .foregroundStyle(.secondary)
                    Text(model.modelResourcesDir).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button(viewModel.text(PageCopy(zh: "打开", en: "Open"))) {
                        viewModel.openModelDirectory()
                    }
                }
            } else {
                Text(viewModel.text(PageCopy(zh: "正在读取模型状态…", en: "Reading model status…")))
                    .foregroundStyle(.secondary)
            }
        }
        .nativeCard()
    }

    private func modelStatusRow(label: PageCopy, presence: MLModelPresence) -> some View {
        HStack {
            Text(viewModel.text(label))
            Spacer()
            if presence.exists {
                Text("✓ " + viewModel.text(PageCopy(zh: "可用", en: "Available")))
                    .foregroundStyle(.green)
            } else {
                Text("✗ " + viewModel.text(PageCopy(zh: "未找到", en: "Not found")))
                    .foregroundStyle(.red)
            }
        }
    }

    /// 模型路径编辑（任务 7）：输入框 + 保存（保存后重查模型状态）+ 打开所在目录。
    private func modelPathRow(key: String, label: PageCopy) -> some View {
        HStack(spacing: 6) {
            Text(viewModel.text(label))
                .frame(width: 120, alignment: .leading)
            // 空占位 TextField：用 label 作为 placeholder（补无障碍标签）。
            TextField(viewModel.text(label), text: Binding(
                get: { viewModel.edits[key] ?? viewModel.values[key] ?? "" },
                set: { viewModel.edits[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            Button(viewModel.text(PageCopy(zh: "保存", en: "Save"))) {
                viewModel.saveModelPath(key: key)
            }
            Button(viewModel.text(PageCopy(zh: "打开", en: "Open"))) {
                viewModel.openModelPathDirectory(key: key)
            }
        }
    }

    /// 对齐旧版 installBanner：模型缺失时显示文案 + 打开文件夹/下载按钮 +
    /// 下载进度（filename: percent）与完成/失败态。
    private func installBanner(_ model: MLStatusData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.text(PageCopy(
                zh: "模型文件未找到。请将 ONNX 模型文件放入以下文件夹：",
                en: "Model files not found. Put the ONNX model files in the following folder:"
            )))
            .font(.callout)
            Text(model.modelResourcesDir).font(.caption.monospaced())
            HStack(spacing: 8) {
                Button(viewModel.text(PageCopy(zh: "打开模型文件夹", en: "Open model folder"))) {
                    viewModel.openModelDirectory()
                }
                Button(downloadButtonTitle) {
                    Task { await viewModel.startModelDownload() }
                }
                .disabled(viewModel.isDownloading)
            }
            switch viewModel.downloadPhase {
            case .downloading(let filename, let percent, let step):
                ProgressView(value: min(1, max(0, percent / 100)))
                // 对齐旧版 Settings/index.tsx:384-390：下载阶段显示相位文案
                // （旧版 translatePhase），进度行保留 filename: percent。
                Text(viewModel.text(step == .extracting
                    ? PageCopy(zh: "正在解压…", en: "Extracting…")
                    : PageCopy(zh: "正在下载模型…", en: "Downloading model…")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(filename): \(Int(percent))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .done:
                Text(viewModel.text(PageCopy(zh: "人脸模型已安装", en: "Face models installed")))
                    .font(.caption)
                    .foregroundStyle(.green)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private var downloadButtonTitle: String {
        switch viewModel.downloadPhase {
        case .downloading(_, _, _):
            viewModel.text(PageCopy(zh: "下载中…", en: "Downloading…"))
        case .error:
            viewModel.text(PageCopy(zh: "下载失败", en: "Download failed"))
        case .done:
            viewModel.text(PageCopy(zh: "已安装", en: "Installed"))
        case .idle:
            viewModel.text(PageCopy(zh: "自动下载模型", en: "Download models automatically"))
        }
    }

    // MARK: Capture One 健康面板（对齐 C1HealthPanel.tsx）

    private var c1HealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.text(PageCopy(zh: "Capture One 健康", en: "Capture One Health")))
                .font(.title3.weight(.semibold))
            HStack {
                Text(viewModel.text(PageCopy(zh: "四层连接预检", en: "Four-layer connection preflight")))
                    .font(.callout.weight(.medium))
                Spacer()
                Button(viewModel.c1Checking
                       ? viewModel.text(PageCopy(zh: "检测中…", en: "Checking…"))
                       : viewModel.text(PageCopy(zh: "重新检测", en: "Re-check"))) {
                    Task { await viewModel.checkC1Health() }
                }
                .disabled(viewModel.c1Checking)
            }
            if viewModel.c1HealthError {
                Text(viewModel.text(PageCopy(
                    zh: "预检失败：无法连接 Capture One 自动化通道",
                    en: "Preflight failed: cannot reach the Capture One automation channel"
                )))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let health = viewModel.c1Health {
                checkRow(zh: "Capture One 可达", en: "Capture One reachable", passed: health.reachable)
                checkRow(zh: "Capture One 运行中", en: "Capture One running", passed: health.appRunning)
                checkRow(zh: "文档已打开", en: "Document open", passed: health.documentOpen)
                checkRow(zh: "自动化权限已授权", en: "Automation authorized", passed: health.automationAuthorized)
            } else {
                Text(viewModel.text(PageCopy(zh: "正在检测…", en: "Detecting…")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text(viewModel.text(PageCopy(zh: "写回队列计数", en: "Writeback queue counts")))
                .font(.callout.weight(.medium))
            if let sync = viewModel.syncStatus {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    queueCell(zh: "待写入", en: "Pending", value: sync.pending)
                    queueCell(zh: "写入中", en: "Writing", value: sync.writing)
                    queueCell(zh: "已写入", en: "Written", value: sync.written)
                    queueCell(zh: "已同步", en: "Synced", value: sync.synced)
                    queueCell(zh: "失败", en: "Failed", value: sync.failed)
                    queueCell(zh: "冲突", en: "Conflict", value: sync.conflict)
                }
            } else if viewModel.syncStateError {
                Text(viewModel.text(PageCopy(
                    zh: "同步状态读取失败",
                    en: "Could not read sync state"
                )))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if viewModel.syncSessionId == nil {
                Text(viewModel.text(PageCopy(
                    zh: "无工作区，写回队列来自当前会话",
                    en: "No workspace; the writeback queue comes from the current session"
                )))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(viewModel.text(PageCopy(zh: "读取中", en: "Reading")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            LabeledContent(
                viewModel.text(PageCopy(zh: "最近一次命令耗时", en: "Last command latency")),
                value: viewModel.c1Health.flatMap { $0.latencyMs }.map { "\($0) ms" } ?? "—"
            )
            LabeledContent(
                viewModel.text(PageCopy(zh: "最近同步时间", en: "Last sync time")),
                value: viewModel.lastSyncDate.map(SettingsViewModel.dateText) ?? "—"
            )
        }
        .nativeCard()
    }

    private func checkRow(zh: String, en: String, passed: Bool) -> some View {
        HStack(spacing: 8) {
            // 对齐 C1HealthPanel.module.css：16×16 圆形软底 ✓/✗ 徽标（主题色）。
            ZStack {
                Circle().fill(passed ? Color.green.opacity(0.14) : Color.red.opacity(0.12))
                Text(passed ? "✓" : "✗")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(passed ? Color.green : Color.red)
            }
            .frame(width: 16, height: 16)
            Text(viewModel.text(PageCopy(zh: zh, en: en)))
        }
    }

    private func queueCell(zh: String, en: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.callout.monospaced().weight(.medium))
            Text(viewModel.text(PageCopy(zh: zh, en: en)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 人脸分析滑杆

    private var faceAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(viewModel.text(PageCopy(zh: "人脸分析", en: "Face Analysis")))
                .font(.title3.weight(.semibold))
            Text(viewModel.text(PageCopy(zh: "常规参数", en: "General")))
                .font(.headline)
            ForEach(SettingsViewModel.generalSliders) { slider in
                sliderRow(slider)
            }
            Divider()
            Text(viewModel.text(PageCopy(zh: "高级参数", en: "Advanced")))
                .font(.headline)
            ForEach(SettingsViewModel.advancedSliders) { slider in
                sliderRow(slider)
            }
        }
        .nativeCard()
    }

    private func sliderRow(_ slider: SliderSetting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.text(PageCopy(zh: slider.zhLabel, en: slider.enLabel)))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(viewModel.sliderValueText(slider))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(viewModel.text(PageCopy(zh: slider.zhDesc, en: slider.enDesc)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { viewModel.sliderValue(for: slider.key, defaultValue: slider.defaultValue) },
                set: { viewModel.sliderValues[slider.key] = $0 }
            ), in: slider.min...slider.max, step: slider.step) { editing in
                if !editing { viewModel.commitSlider(slider) }
            }
        }
    }

    // MARK: 分组设置（缓存/图片处理/数据库/C1 集成/元数据）

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(SettingsViewModel.settingGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.text(PageCopy(zh: group.titleZh, en: group.titleEn)))
                        .font(.headline)
                    ForEach(group.fields) { field in
                        fieldRow(field)
                    }
                }
            }
        }
        .nativeCard()
    }

    @ViewBuilder
    private func fieldRow(_ field: SettingField) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.text(PageCopy(zh: field.zhLabel, en: field.enLabel)))
                    .font(.callout.weight(.medium))
                Text(viewModel.text(PageCopy(zh: field.zhDesc, en: field.enDesc)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            switch field.type {
            case .text:
                HStack(spacing: 6) {
                    TextField(viewModel.text(PageCopy(zh: field.zhLabel, en: field.enLabel)), text: Binding(
                        get: { viewModel.edits[field.key] ?? viewModel.values[field.key] ?? "" },
                        set: { viewModel.edits[field.key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    Button(viewModel.text(PageCopy(zh: "保存", en: "Save"))) {
                        viewModel.saveField(field)
                    }
                }
            case .number:
                HStack(spacing: 6) {
                    TextField(viewModel.text(PageCopy(zh: field.zhLabel, en: field.enLabel)), text: Binding(
                        get: { viewModel.edits[field.key] ?? viewModel.values[field.key] ?? "" },
                        set: { viewModel.edits[field.key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    Button(viewModel.text(PageCopy(zh: "保存", en: "Save"))) {
                        viewModel.saveField(field)
                    }
                }
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
                    Text(viewModel.text(PageCopy(zh: "请选择", en: "Choose"))).tag(String?.none)
                    ForEach(options) { option in
                        Text(viewModel.text(PageCopy(zh: option.labelZh, en: option.labelEn)))
                            .tag(String?.some(option.value))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
        }
        .padding(.vertical, 4)
    }
}

extension View {
    func nativeCard() -> some View {
        padding(18)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gatherSurface))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1)
            )
    }
}
