// Tests/GatherCoreTests/API/SettingsCommandsImplTests.swift
// R5：settings 域命令实现直测（批次 B2）。
// 覆盖旧路由分支语义：get_all/get/set/reset/set_language 的读写与错误码，
// set 的 key/value 边界，set_language 白名单，get_ml_status 的提供者注入。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/SettingsCommandsImpl (R5)")
struct SettingsCommandsImplTests {
    /// 目录直连 harness：SettingsAPI 与命令实现共享同一临时库。
    private func makeHarness() async throws -> (impl: SettingsCommandsImpl, path: String) {
        let path = storeTempPath("settings-commands")
        let db = try await makeMigratedStore(path: path)
        let api = SettingsAPI(store: SQLiteSettingsStore(database: db))
        return (SettingsCommandsImpl(settings: api), path)
    }

    @Test("getAll returns defaults and reflects a set value")
    func getAllAndSetRoundtrip() async throws {
        let (impl, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        let defaults = try await impl.getAll()
        #expect(defaults["onnx_provider"] == "auto")
        #expect(defaults["detector_model_path"] == "models/face_detector.onnx")

        try await impl.set(key: "detector_model_path", value: "models/custom.onnx")
        #expect(try await impl.get(key: "detector_model_path") == "models/custom.onnx")
        let updated = try await impl.getAll()
        #expect(updated["detector_model_path"] == "models/custom.onnx")
    }

    @Test("get trims the key and falls back to an empty string for an unknown key")
    func getTrimsAndFallsBack() async throws {
        let (impl, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        try await impl.set(key: "ui_language", value: "en")

        #expect(try await impl.get(key: "  ui_language  ") == "en")
        #expect(try await impl.get(key: "not_a_setting") == "")
    }

    @Test("set validates key and value bounds with INVALID_PARAM codes")
    func setValidation() async throws {
        let (impl, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: SettingsCommandsError.invalidParam("key")) {
            try await impl.set(key: "   ", value: "x")
        }
        await #expect(throws: SettingsCommandsError.invalidParam("key")) {
            try await impl.set(key: String(repeating: "k", count: 257), value: "x")
        }
        await #expect(throws: SettingsCommandsError.invalidParam("value")) {
            try await impl.set(key: "ui_language", value: String(repeating: "v", count: 4097))
        }
        await #expect(throws: SettingsError.unknownKey("not_a_setting")) {
            try await impl.set(key: "not_a_setting", value: "x")
        }

        // value 允许空串（旧分支 allowEmpty: true）。
        try await impl.set(key: "ui_language", value: "")
        #expect(try await impl.get(key: "ui_language") == "")
    }

    @Test("reset restores defaults and returns the reset snapshot")
    func resetRestoresDefaults() async throws {
        let (impl, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        try await impl.set(key: "ui_language", value: "en")

        let snapshot = try await impl.reset()
        #expect(snapshot["ui_language"] == "")
        #expect(snapshot["onnx_provider"] == "auto")
        #expect(try await impl.get(key: "ui_language") == "")
    }

    @Test("setLanguage accepts the whitelist and persists ui_language")
    func setLanguageWhitelist() async throws {
        let (impl, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        #expect(try await impl.setLanguage(language: "en") == "en")
        #expect(try await impl.get(key: "ui_language") == "en")
        #expect(try await impl.setLanguage(language: "zh-CN") == "zh-CN")

        await #expect(throws: SettingsCommandsError.languageInvalid) {
            try await impl.setLanguage(language: "fr")
        }
    }

    @Test("getMLStatus delegates to the injected provider and fails loudly when unwired")
    func getMLStatusProvider() async throws {
        let (unwired, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        await #expect(throws: SettingsCommandsError.mlStatusProviderUnavailable) {
            try await unwired.getMLStatus()
        }

        let stub = MLStatusData(
            platform: "darwin",
            autoBackend: "coreml",
            autoBackendLabel: "CoreML",
            provider: "auto",
            isAuto: true,
            availableBackends: [
                MLBackendOption(value: "coreml", label: "CoreML"),
                MLBackendOption(value: "cpu", label: "CPU"),
            ],
            modelResourcesDir: "/tmp/models",
            detectorModel: MLModelPresence(path: "d.onnx", resolvedPath: "/tmp/models/d.onnx", exists: true),
            encoderModel: MLModelPresence(path: "e.onnx", resolvedPath: nil, exists: false),
            modelInfo: MLModelInfo(
                detectInputSize: 640, secondaryDetectInputSize: 128,
                previewMaxDimension: 2048, encoderInputSize: 112, embeddingDim: 512)
        )
        let wiredPath = storeTempPath("settings-commands-ml")
        defer { removeStoreFiles(wiredPath) }
        let wiredDB = try await makeMigratedStore(path: wiredPath)
        let wired = SettingsCommandsImpl(
            settings: SettingsAPI(store: SQLiteSettingsStore(database: wiredDB)),
            mlStatusProvider: { stub }
        )

        let status = try await wired.getMLStatus()
        #expect(status == stub)
    }
}
