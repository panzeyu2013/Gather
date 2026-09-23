// Tests/GatherAppTests/SettingsTestSupport.swift
// R1/R5：路由测试的设置依赖（迁移后的库 + SettingsAPI 与默认值快照）。
import Foundation
import GatherCore

/// 构建测试用设置依赖：临时库先经旧 MigrationRunner 迁移（同步、复用既有
/// core 迁移路径），再以 SQLiteDatabase 打开并包装为 SettingsAPI。
func makeTestSettings(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> (snapshot: SettingsSnapshot, api: SettingsAPI) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-app-settings-\(UUID().uuidString).sqlite").path
    let bootstrap = try DBConnection(path: path)
    try MigrationRunner().migrate(bootstrap)
    let database = try SQLiteDatabase(path: path)
    let api = SettingsAPI(store: SQLiteSettingsStore(database: database))
    return (SettingsSnapshot(values: SettingsAPI.defaults), api)
}
