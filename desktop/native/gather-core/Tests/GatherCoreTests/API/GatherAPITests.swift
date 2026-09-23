// Tests/GatherCoreTests/API/GatherAPITests.swift
// R5 基座测试：组合根迁移 + 类型化 API（settings 的默认值/白名单/缓存语义与 sessions 冒烟）。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/GatherAPI (R1-R5 基座)")
struct GatherAPITests {
    private func makeAPI() async throws -> (GatherAPI, String) {
        let path = storeTempPath("api")
        let api = try await GatherAPI.open(path: path)
        return (api, path)
    }

    @Test func openMigratesFreshDatabaseAndSessionsWork() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        // 组合根打开即迁移到当前 schema 版本。
        let version = try await api.container.database.scalarInt(
            "SELECT MAX(version) FROM schema_version"
        )
        #expect(version == 33)

        #expect(try await api.sessions.list().isEmpty)
        let created = try await api.sessions.create(name: "Wedding", source: "folder", sourcePath: "/photos")
        #expect(created.name == "Wedding")
        #expect(created.status == "draft")
        #expect(try await api.sessions.get(id: created.id)?.sourcePath == "/photos")
        #expect(try await api.sessions.list().map(\.id) == [created.id])

        #expect(try await api.sessions.rename(id: created.id, name: "Wedding 2026"))
        #expect(try await api.sessions.get(id: created.id)?.name == "Wedding 2026")
        try await api.sessions.updateStatus(id: created.id, status: "photos_loaded")
        #expect(try await api.sessions.get(id: created.id)?.status == "photos_loaded")

        #expect(try await api.sessions.delete(id: created.id))
        #expect(try await api.sessions.list().isEmpty)
    }

    @Test func settingsDefaultsAndWhitelist() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        let defaults = SettingsAPI.defaults
        #expect(defaults.count == 40, "TS 默认值表 40 键")
        #expect(SettingsAPI.knownSettingKeys == Set(defaults.keys))
        #expect(defaults["detect_confidence"] == "0.5")
        #expect(defaults["default_threshold"] == "10")
        #expect(defaults["metadata_write_mode"] == "sidecar")
        #expect(defaults["lazy_checksum"] == "true")
        #expect(defaults["ui_language"] == "")
        #expect(SettingsAPI.thumbnailConcurrencyDefault >= 1)
        #expect(SettingsAPI.thumbnailConcurrencyDefault <= 4)
        #expect(defaults["thumbnail_concurrency"] == String(SettingsAPI.thumbnailConcurrencyDefault))
    }

    @Test func settingsSetPersistsAcrossInstances() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        try await api.settings.set("default_threshold", value: "42")
        #expect(await api.settings.value("default_threshold") == "42")
        #expect(await api.settings.number("default_threshold", default: 1) == 42)

        // 同一路径重开：值来自数据库而非进程缓存。
        let reopened = try await GatherAPI.open(path: path)
        #expect(await reopened.settings.value("default_threshold") == "42")

        await #expect(throws: SettingsError.unknownKey("nope")) {
            try await api.settings.set("nope", value: "1")
        }
    }

    @Test func settingsGetNumberAndFallbacks() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        #expect(await api.settings.value("default_threshold") == "", "未落库时 value 默认为空串")
        #expect(await api.settings.value("default_threshold", default: "fallback") == "fallback")
        #expect(await api.settings.number("default_threshold", default: 7) == 7, "缺省 → 默认值")

        try await api.settings.set("default_threshold", value: "not-a-number")
        #expect(await api.settings.number("default_threshold", default: 7) == 7, "NaN → 默认值")
        try await api.settings.set("default_threshold", value: "12.5")
        #expect(await api.settings.number("default_threshold", default: 7) == 12.5)
    }

    @Test func settingsAllMergesDefaultsAndReset() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        var all = await api.settings.all()
        #expect(all.count == 40, "默认值打底")
        #expect(all["default_eps"] == "0.6")

        try await api.settings.set("default_eps", value: "0.9")
        all = await api.settings.all()
        #expect(all["default_eps"] == "0.9", "缓存覆盖默认值")

        try await api.settings.reset()
        all = await api.settings.all()
        #expect(all["default_eps"] == "0.6")
        #expect(try await api.container.database.scalarInt(
            "SELECT COUNT(*) FROM app_settings WHERE key = 'default_eps' AND value = '0.6'"
        ) == 1, "reset 全量写回默认值")
    }

    @Test func settingsCacheIsReadOnlyAfterLoad() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        try await api.settings.set("default_eps", value: "0.7")
        #expect(await api.settings.value("default_eps") == "0.7", "触发缓存装载")

        // 绕过 API 直接改库：缓存已装载则不再回读（TS 语义）。
        try await api.container.database.run(
            "UPDATE app_settings SET value = '0.1' WHERE key = 'default_eps'"
        )
        #expect(await api.settings.value("default_eps") == "0.7")

        // 同一 store 上的新 API 实例重新装载 → 看到库中值（旧 SettingsService 语义）。
        let fresh = SettingsAPI(store: api.container.settings)
        #expect(await fresh.value("default_eps") == "0.1")
    }
}
