// Tests/GatherAppTests/SettingsTestSupport.swift
// R1/R5：路由测试的设置/模板依赖（迁移后的库 + 类型化 API 与默认值快照）。
import Foundation
import GatherCore

/// 构建测试用 API 依赖：临时库先经旧 MigrationRunner 迁移（同步、复用既有
/// core 迁移路径），再以 SQLiteDatabase 打开并包装为 GatherAPI 命名空间。
func makeTestSettings(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> (snapshot: SettingsSnapshot, api: SettingsAPI, templates: TemplatesAPI) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-app-settings-\(UUID().uuidString).sqlite").path
    let bootstrap = try DBConnection(path: path)
    try MigrationRunner().migrate(bootstrap)
    let database = try SQLiteDatabase(path: path)
    let api = GatherAPI(container: AppContainer(database: database))
    return (SettingsSnapshot(values: SettingsAPI.defaults), api.settings, api.templates)
}
