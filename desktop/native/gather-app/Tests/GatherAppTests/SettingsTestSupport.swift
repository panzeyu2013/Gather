// Tests/GatherAppTests/SettingsTestSupport.swift
// R1/R5：路由测试的设置/模板/相册/工作区/人物/人脸/元数据依赖（迁移后的库 + 类型化 API 与默认值快照）。
import Foundation
import GatherCore

/// 构建测试用 API 依赖：临时库经 StoreMigrator 迁移后，包装为 GatherAPI 命名空间。
func makeTestSettings(
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> (
    snapshot: SettingsSnapshot,
    api: SettingsAPI,
    templates: TemplatesAPI,
    albums: AlbumsAPI,
    workspace: WorkspaceAPI,
    persons: PersonsAPI,
    personStore: any PersonStore,
    faceStore: any FaceStore,
    metadataStore: any MetadataStore,
    cullingStore: any CullingStore,
    similarityStore: any SimilarityStore,
    writebackStore: any WritebackStore
) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-app-settings-\(UUID().uuidString).sqlite").path
    let database = try await makeMigratedStore(path: path)
    let api = GatherAPI(container: AppContainer(database: database))
    return (
        SettingsSnapshot(values: SettingsAPI.defaults),
        api.settings,
        api.templates,
        api.albums,
        api.workspace,
        api.persons,
        api.container.persons,
        api.container.faces,
        api.container.metadata,
        api.container.culling,
        api.container.similarity,
        api.container.writeback
    )
}


/// Store schema 临时库：SQLiteDatabase + StoreMigrator 建表（legacy 迁移器已退役）。
@discardableResult
func makeMigratedStore(path: String) async throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: path)
    try await StoreMigrator().migrate(database)
    return database
}
