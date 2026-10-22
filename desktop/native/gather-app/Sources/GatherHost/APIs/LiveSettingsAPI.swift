// desktop/native/gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift
// Cut 1 / 阶段 B1：SettingsAPI 的 Live 实现（6 个方法）。
//
// 对应命令（6 条）：settings.get_all / get / set / reset / set_language /
// get_ml_status。
//
// 校验归属：key <= 256 非空白、value <= 4096 允许空串由 SettingsKey /
// SettingsValue 在构造期完成（D-012）；setLanguage 只接受 InterfaceLanguage。
// setLanguage 必须同步 GatherLocalization 并广播 languageChanged（对齐旧
// 旧实现的即时 rebuild 行为；AppDelegate 也会在通知里再次 set，幂等）。
//
// get_ml_status 的形状逐字段对齐旧命令面 buildMLStatus：
// 判定逻辑不复制业务状态，只读 SettingsService 的当前值 + 模型文件存在性。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
import GatherUI

public final class LiveSettingsAPI: SettingsAPI, @unchecked Sendable {
    private let settingsService: SettingsService

    /// @unchecked Sendable 依据：settingsService 为构造后不可变的 let；其缓存由
    /// SettingsService 的 NSLock 保护，repo 由 DBConnection 串行化。
    public init(settingsService: SettingsService) {
        self.settingsService = settingsService
    }

    // MARK: - SettingsAPI

    public func all() async throws -> [String: String] {
        settingsService.getAll()
    }

    public func get(_ key: SettingsKey) async throws -> String {
        settingsService.get(key.value)
    }

    public func set(_ input: SettingsSetInput) async throws {
        do {
            try settingsService.set(input.key.value, value: input.value.value)
        } catch let error as SettingsError {
            throw Self.gatherError(for: error)
        }
    }

    public func reset() async throws -> [String: String] {
        do {
            try settingsService.reset()
        } catch let error as SettingsError {
            throw Self.gatherError(for: error)
        }
        return settingsService.getAll()
    }

    public func setLanguage(_ language: InterfaceLanguage) async throws -> InterfaceLanguage {
        do {
            try settingsService.set("ui_language", value: language.rawValue)
        } catch let error as SettingsError {
            throw Self.gatherError(for: error)
        }
        // 与旧命令面 行为对齐：语言切换的通知消费者是 AppDelegate（AppKit
        // 菜单/标准菜单补齐）与 LanguageStore（唯一写入口：采纳后同步旧全局）。
        // 必须在主线程投递——非隔离 async 实现默认跑在协作线程池，不能假设
        // 调用方是 MainActor。
        //
        // Cut 4 / 4b-1：本 API 只负责持久化 + 广播，不再直接写
        // GatherLocalization.appLanguage（消除第二个写点）。
        await MainActor.run {
            NotificationCenter.default.post(
                name: GatherAppNotification.languageChanged,
                object: language.rawValue
            )
        }
        return language
    }

    public func mlStatus() async throws -> MLStatusData {
        buildMLStatus()
    }

    // MARK: - ML 状态（对齐旧命令面 buildMLStatus）

    private func buildMLStatus() -> MLStatusData {
        let provider = settingsService.get("face_compute_units", defaultValue: "auto")
        let custom = settingsService.get(FaceEmbeddingModelFactory.modelPathSetting, defaultValue: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let encoderURL = custom.isEmpty ? FaceEmbeddingModelFactory.bundledModelURL
            : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let encoderPath = encoderURL?.path ?? "SFace.mlpackage"
        let previewMaxDimension = clampedInt(
            settingsService.getNumber("face_preview_max_dimension", defaultValue: 2048),
            fallback: 2048,
            range: 256...8192
        )
        return MLStatusData(
            platform: "darwin",
            autoBackend: "coreml",
            autoBackendLabel: "Vision + CoreML SFace",
            provider: provider,
            isAuto: provider == "auto",
            availableBackends: [MLBackendOption(value: "cpu", label: "CPU")],
            modelResourcesDir: encoderURL?.deletingLastPathComponent().path ?? modelResourcesDir(),
            detectorModel: MLModelPresence(path: "Apple Vision", resolvedPath: nil, exists: true),
            encoderModel: MLModelPresence(
                path: custom.isEmpty ? "内置 SFace" : custom,
                resolvedPath: encoderPath,
                exists: FileManager.default.fileExists(atPath: encoderPath)
            ),
            modelInfo: MLModelInfo(
                detectInputSize: 0,
                secondaryDetectInputSize: 0,
                previewMaxDimension: previewMaxDimension,
                encoderInputSize: 112,
                embeddingDim: custom.isEmpty ? 128 : 0
            )
        )
    }

    /// TS provider.ts getModelResourcesDir：userData/models（best-effort 创建）。
    private func modelResourcesDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Gather/models", isDirectory: true).path ?? "models"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 设置值可能是外部写入的任意 Double：非有限/越界一律回退默认（与旧
    /// 旧实现的 clampedInt 逐字一致，不允许 trap）。
    private func clampedInt(_ value: Double, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return fallback }
        let rounded = value.rounded()
        if rounded < Double(range.lowerBound) { return range.lowerBound }
        if rounded > Double(range.upperBound) { return range.upperBound }
        return Int(rounded)
    }

    private static func gatherError(for error: SettingsError) -> GatherError {
        switch error {
        case .unknownKey(let key):
            return .invalidParameter(field: "key", reason: "unknown setting key: \(key)")
        }
    }
}
