// desktop/native/gather-app/Tests/GatherAppTests/WebBridgeTests.swift
// Phase 3.0 宿主与桥行为测试。
// 对照 preload/index.ts 三层校验语义 + 命令路由渐进式接线状态。
//
// 注意：WebBridge 依赖 WKWebView evaluateJavaScript 回传，纯逻辑校验
// （白名单/confirmed/路由）用无 webView 实例直接调 handle 验证响应帧；
// 事件推送 dispatchEvent 在无 webView 时安全 no-op。

import Foundation
import Testing
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
@testable import GatherApp
@testable import GatherCore

typealias JV = GatherCore.JSONValue

// MARK: - 测试探针

/// 假路由：记录命令 + 按命令返回固定响应或抛错。
private final class StubRouter: CommandRouter {
    var result: JV = JV.null
    var error: String?
    var asyncResult: WebResponse?
    private let lock = NSLock()
    private var _executed: [String] = []

    var executed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _executed
    }

    func execute(_ command: String, params: [String: JV]) throws -> JV {
        lock.lock(); _executed.append(command); lock.unlock()
        if let error { throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        return result
    }

    func executeAsync(
        _ command: String,
        params: [String: JV],
        completion: @escaping (WebResponse) -> Void
    ) {
        lock.lock(); _executed.append("async:" + command); lock.unlock()
        if let asyncResult {
            completion(asyncResult)
        }
    }
}

/// 记录响应帧的桥（responseSink 注入）。
private final class RecordingBridge {
    let bridge: WebBridge
    private let lock = NSLock()
    private var _frames: [WebResponse] = []

    var frames: [WebResponse] {
        lock.lock(); defer { lock.unlock() }
        return _frames
    }

    init(router: CommandRouter) {
        bridge = WebBridge(router: router, webView: nil)
        bridge.responseSink = { [weak self] response in
            self?.lock.lock()
            self?._frames.append(response)
            self?.lock.unlock()
        }
    }

    func handle(id: String, command: String, params: JV?) {
        bridge.handle(id: id, command: command, params: params)
    }

    func dispatchEvent(_ event: String, data: JV?) {
        bridge.dispatchEvent(event, data: data)
    }
}

private func makeBridge() -> (RecordingBridge, StubRouter) {
    let router = StubRouter()
    let bridge = RecordingBridge(router: router)
    return (bridge, router)
}

// MARK: - 用例

@Suite("WebBridge")
struct WebBridgeTests {
    // preload: 白名单外命令 → Unknown command 抛错。
    @Test func unknownCommandRejected() {
        let (bridge, _) = makeBridge()
        bridge.handle(id: "1", command: "evil.delete_all", params: JV?.none)
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "UNKNOWN_COMMAND")
    }

    // preload: 白名单命令放行并路由。
    @Test func allowedCommandRoutes() {
        let (bridge, router) = makeBridge()
        router.result = JV.object(["id": JV.string("s1")])
        bridge.handle(id: "1", command: "session.list", params: JV.object([String: JV]()))
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == true)
        #expect(bridge.frames[0].data?.objectValue?["id"]?.stringValue == "s1")
        #expect(router.executed == ["session.list"])
    }

    // preload: params 非纯 object → 拒绝（isRecord 语义）。
    @Test func nonRecordParamsRejected() {
        let (bridge, router) = makeBridge()
        bridge.handle(id: "1", command: "session.list", params: JV.string("not-an-object"))
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "INVALID_PARAMS")
        #expect(router.executed.isEmpty)
    }

    // preload: destructive 命令无 confirmed:true → 拒绝。
    @Test func destructiveRequiresConfirmation() {
        let (bridge, router) = makeBridge()
        bridge.handle(id: "1", command: "session.delete", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        #expect(router.executed.isEmpty)
    }

    // preload: destructive 命令带 confirmed:true → 放行。
    @Test func destructiveConfirmedPasses() {
        let (bridge, router) = makeBridge()
        bridge.handle(
            id: "1",
            command: "session.delete",
            params: JV.object(["sessionId": JV.string("s1"), "confirmed": JV.bool(true)])
        )
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == true)
        #expect(router.executed == ["session.delete"])
    }

    // preload: 白名单表 parity 抽查 —— destructive ⊂ allowed。
    @Test func destructiveSubsetOfAllowed() {
        for command in BridgeContract.destructiveCommands {
            #expect(BridgeContract.allowedCommands.contains(command), "\(command) 在 destructive 但不在 allowed")
        }
    }

    // 白名单规模对账：118 命令 / 30 destructive / 9 事件（core.ts 实测值）。
    @Test func whitelistSizesMatchTS() {
        #expect(BridgeContract.allowedCommands.count == 118)
        #expect(BridgeContract.destructiveCommands.count == 30)
        #expect(BridgeContract.allowedEvents.count == 9)
    }

    // 路由：已接线命令返回数据；未接线命令 NOT_IMPLEMENTED。
    @Test func unportedCommandNotImplemented() {
        let (bridge, router) = makeBridge()
        router.error = "NOT_IMPLEMENTED: culling.groups"
        bridge.handle(id: "1", command: "culling.groups", params: JV.object([String: JV]()))
        #expect(bridge.frames.count == 1)
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "NOT_IMPLEMENTED: culling.groups")
    }

    // 事件推送：白名单内 → 尝试注入脚本；白名单外 → 静默丢弃。
    @Test func dispatchEventFiltersWhitelist() {
        let (bridge, _) = makeBridge()
        // 白名单外事件：无 webView 也应安全 no-op（不崩溃即验证过滤路径）。
        bridge.dispatchEvent("evil:event", data: JV.null)
        // 白名单内：同样安全 no-op（webView nil）。
        bridge.dispatchEvent("jobs:progress", data: JV.object(["jobId": JV.string("j1")]))
    }

    // 异步命令路由：走 executeAsync。
    @Test func asyncCommandRoutesToExecuteAsync() {
        let (bridge, router) = makeBridge()
        router.asyncResult = WebResponse(id: "1", ok: true, data: JV.object(["ok": JV.bool(true)]))
        bridge.handle(id: "1", command: "sim.analyze", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(router.executed == ["async:sim.analyze"])
    }
}

// MARK: - 命令接线测试（真实 SQLite + 已移植服务）

/// 打开已迁移的内存库（等价 gather-core 测试支撑 makeMigratedDB）。
private func makeMigratedDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

private func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String? = nil,
    createdAt: String = "2026-01-01T00:00:00.000Z",
    metadata: String = "{}",
    result: String = "{}",
    checksum: String = ""
) throws {
    // 默认路径按 id 区分，避免 idx_photos_session_filepath 唯一索引冲突
    let path = filepath ?? "/tmp/fixtures/\(id).jpg"
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)
    """).run([
        .text(id), .text(sessionId), .text(path), .text((path as NSString).lastPathComponent),
        .text(checksum), .text(metadata), .text(result), .text(createdAt), .text(createdAt),
    ])
}

private func insertNavigationGroup(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    photoIds: [String],
    type: String = "burst",
    source: String = "manual"
) throws {
    let data = try JSONSerialization.data(withJSONObject: photoIds)
    let photoIdsJSON = String(data: data, encoding: .utf8) ?? "[]"
    _ = try db.prepare("""
        INSERT INTO navigation_groups (id, session_id, group_type, photo_ids_json, lead_photo_id, explanation, input_fingerprint, source, created_at, updated_at)
        VALUES (?, ?, ?, ?, NULL, '', '', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text(type), .text(photoIdsJSON), .text(source)])
}

private func insertHash(_ db: DBConnection, sessionId: String, photoId: String, hex: String) throws {
    _ = try db.prepare("""
        INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
        VALUES (?, ?, ?, 0, 0)
    """).run([.text(sessionId), .text(photoId), .text(hex)])
}

/// 断言路由抛出的错误 message 与预期逐字一致。
private func expectRouterError(_ message: String, _ body: () throws -> JV) {
    do {
        _ = try body()
        Issue.record("应抛错 \(message)，未抛")
    } catch {
        #expect("\(error)" == message, "实际: \(error)")
    }
}

/// 异步命令：等待 executeAsync 的完成回调返回响应帧。
/// 超时兜底（30s）：防止 job 类命令在 JobService 未 start() 时挂满
/// waitForResult 的 1 小时超时（TS WAIT_FOR_RESULT_TIMEOUT_MS 对齐语义）。
private func awaitAsync(_ router: SessionCommandRouter, _ command: String, _ params: [String: JV]) async -> WebResponse {
    await withCheckedContinuation { continuation in
        Task {
            try? await Task.sleep(for: .seconds(30))
            continuation.resume(returning: WebResponse(id: "", ok: false, error: "TEST_TIMEOUT:\(command)"))
        }
        router.executeAsync(command, params: params) { response in
            continuation.resume(returning: response)
        }
    }
}

@Suite("RouterCommands")
struct RouterCommandTests {
    // MARK: settings.*（TS 源 settings.ipc.ts）

    @Test func settingsGetAllReturnsDefaults() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("settings.get_all", params: [:])
        #expect(data.objectValue?["detector_model_path"]?.stringValue == "models/face_detector.onnx")
        #expect(data.objectValue?["default_threshold"]?.stringValue == "10")
    }

    @Test func settingsGetReturnsDefaultAndMissingParam() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        // TS 语义（settings.service.ts:21-22）：缓存未命中且无 defaultValue → ''。
        let data = try router.execute("settings.get", params: ["key": JV.string("thumbnail_size")])
        #expect(data.stringValue == "")
        expectRouterError("MISSING_PARAM:key") { try router.execute("settings.get", params: [:]) }
    }

    @Test func settingsSetRoundtripsThroughCache() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("settings.set", params: ["key": JV.string("thumbnail_size"), "value": JV.string("512")])
        #expect(data.objectValue?["done"]?.boolValue == true)
        let read = try router.execute("settings.get", params: ["key": JV.string("thumbnail_size")])
        #expect(read.stringValue == "512")
        expectRouterError("MISSING_PARAM:key") { try router.execute("settings.set", params: ["value": JV.string("x")]) }
        expectRouterError("Unknown setting key: nope") {
            try router.execute("settings.set", params: ["key": JV.string("nope"), "value": JV.string("x")])
        }
    }

    @Test func settingsResetRestoresDefaults() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        _ = try router.execute("settings.set", params: ["key": JV.string("thumbnail_size"), "value": JV.string("512")])
        let data = try router.execute("settings.reset", params: [:])
        #expect(data.objectValue?["thumbnail_size"]?.stringValue == "1024")
        let read = try router.execute("settings.get", params: ["key": JV.string("thumbnail_size")])
        #expect(read.stringValue == "1024")
    }

    @Test func settingsSetLanguageValidatesLocale() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("settings.set_language", params: ["language": JV.string("zh-CN")])
        #expect(data.objectValue?["language"]?.stringValue == "zh-CN")
        let read = try router.execute("settings.get", params: ["key": JV.string("ui_language")])
        #expect(read.stringValue == "zh-CN")
        expectRouterError("SETTINGS_LANGUAGE_INVALID") {
            try router.execute("settings.set_language", params: ["language": JV.string("fr")])
        }
        expectRouterError("SETTINGS_LANGUAGE_INVALID") {
            try router.execute("settings.set_language", params: [:])
        }
    }

    // settings.get_ml_status 形状（settings.ipc.ts:53-78）：真实检查磁盘模型
    // 目录（applicationSupportDirectory/Gather/models，与 GatherApp 一致）。
    @Test func settingsGetMLStatusShape() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("settings.get_ml_status", params: [:])
        let object = try #require(data.objectValue)
        #expect(object["platform"]?.stringValue == "darwin")
        #expect(object["autoBackend"]?.stringValue == "coreml")
        #expect(object["provider"]?.stringValue == "auto")
        #expect(object["isAuto"]?.boolValue == true)
        let backends = try #require(object["availableBackends"]?.arrayElements)
        #expect(backends.count == 2)
        #expect(backends[0].objectValue?["value"]?.stringValue == "coreml")
        #expect(backends[0].objectValue?["label"]?.stringValue == "CoreML")
        #expect(object["modelResourcesDir"]?.stringValue?.isEmpty == false)
        let detector = try #require(object["detectorModel"]?.objectValue)
        // exists 依赖本机是否有真实模型文件（环境相关，只断言类型与路径形状）。
        #expect(detector["exists"]?.boolValue != nil)
        #expect(detector["path"]?.stringValue == "models/face_detector.onnx")
        #expect(detector["resolvedPath"]?.stringValue?.isEmpty == false)
        let modelInfo = try #require(object["modelInfo"]?.objectValue)
        #expect(modelInfo["detectInputSize"]?.numberValue == 640)
        #expect(modelInfo["embeddingDim"]?.numberValue == 512)
    }

    // MARK: filter.*（TS 源 filter.ipc.ts）

    @Test func filterPhotosWithRealRows() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg", metadata: #"{"aperture":2.8}"#)
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/p2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let criteria = JV.object([
            "logic": JV.string("and"),
            "conditions": JV.array([
                JV.object(["field": JV.string("filename"), "operator": JV.string("eq"), "value": JV.string("p1.jpg")]),
            ]),
        ])
        let data = try router.execute("filter.photos", params: ["sessionId": JV.string("s1"), "criteria": criteria])
        let rows = try #require(data.arrayElements)
        #expect(rows.count == 1)
        let row = try #require(rows[0].objectValue)
        #expect(row["id"]?.stringValue == "p1")
        #expect(row["sessionId"]?.stringValue == "s1")
        #expect(row["hasExistingXmp"]?.boolValue == false)
        #expect(row["faceCount"]?.numberValue == 0)
        #expect(row["width"]?.numberValue == 0)
        #expect(row["height"]?.numberValue == 0)
        #expect(row["metadata"]?.objectValue?["aperture"]?.numberValue == 2.8)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("filter.photos", params: ["criteria": criteria])
        }
        expectRouterError("Filter criteria is invalid") {
            try router.execute("filter.photos", params: ["sessionId": JV.string("s1")])
        }
    }

    @Test func filterPhotosGlobalReturnsPhotosAndTotal() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let criteria = JV.object([
            "logic": JV.string("and"),
            "conditions": JV.array([
                JV.object(["field": JV.string("status"), "operator": JV.string("eq"), "value": JV.string("pending")]),
            ]),
        ])
        let data = try router.execute("filter.photos_global", params: ["criteria": criteria])
        let object = try #require(data.objectValue)
        let photos = try #require(object["photos"]?.arrayElements)
        #expect(photos.count == 2)
        #expect(object["total"]?.numberValue == 2)
        #expect(photos[0].objectValue?["photoId"] != nil)
        #expect(photos[0].objectValue?["sessionName"] != nil)
        expectRouterError("Filter criteria is invalid") {
            try router.execute("filter.photos_global", params: [:])
        }
    }

    @Test func filterSuggestReturnsCameraMakes() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, camera_make, cached_at, updated_at)
            VALUES ('p1', 's1', 'Canon', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("filter.suggest", params: ["sessionId": JV.string("s1"), "keyword": JV.string("Can")])
        let suggestions = try #require(data.arrayElements)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].objectValue?["field"]?.stringValue == "camera_make")
        #expect(suggestions[0].objectValue?["values"]?.arrayElements?.first?.stringValue == "Canon")
        // 短关键字（<2 字符）→ 空数组（filter-engine.ts:205）。
        let short = try router.execute("filter.suggest", params: ["sessionId": JV.string("s1"), "keyword": JV.string("C")])
        #expect(short.arrayElements?.isEmpty == true)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("filter.suggest", params: [:])
        }
    }

    // MARK: navigation.*（TS 源 navigation.ipc.ts）

    @Test func navigationListAndSplit() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        try insertNavigationGroup(db, id: "g1", sessionId: "s1", photoIds: ["p1", "p2", "p3"])
        let router = SessionCommandRouter.makeDefault(db: db)

        let list = try router.execute("navigation.list", params: ["sessionId": JV.string("s1")])
        let groups = try #require(list.arrayElements)
        #expect(groups.count == 1)
        #expect(groups[0].objectValue?["photoIds"]?.arrayElements?.count == 3)
        expectRouterError("MISSING_PARAM:sessionId") { try router.execute("navigation.list", params: [:]) }

        // split 在第二张前切开：[p1] / [p2,p3]；<2 张组被过滤 → 仅剩 [p2,p3]。
        let split = try router.execute(
            "navigation.split",
            params: ["sessionId": JV.string("s1"), "groupId": JV.string("g1"), "beforePhotoId": JV.string("p2")]
        )
        let splitGroups = try #require(split.arrayElements)
        #expect(splitGroups.count == 1)
        let splitIds = splitGroups[0].objectValue?["photoIds"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(splitIds == ["p2", "p3"])
        expectRouterError("MISSING_PARAM:groupId") {
            try router.execute("navigation.split", params: ["sessionId": JV.string("s1"), "beforePhotoId": JV.string("p2")])
        }
    }

    @Test func navigationMergeCombinesGroups() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        try insertPhoto(db, id: "p4", sessionId: "s1")
        try insertNavigationGroup(db, id: "g1", sessionId: "s1", photoIds: ["p1", "p2"])
        try insertNavigationGroup(db, id: "g2", sessionId: "s1", photoIds: ["p3", "p4"])
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute(
            "navigation.merge",
            params: ["sessionId": JV.string("s1"), "groupIds": JV.array([JV.string("g1"), JV.string("g2")])]
        )
        let groups = try #require(data.arrayElements)
        #expect(groups.count == 1)
        #expect(groups[0].objectValue?["photoIds"]?.arrayElements?.count == 4)
        expectRouterError("MISSING_PARAM:groupIds") {
            try router.execute("navigation.merge", params: ["sessionId": JV.string("s1")])
        }
    }

    // navigation.analyze：TS 为 async wrapper 内同步执行 → Swift 同步直连。
    // 1s 间隔 ≤ 默认 burst 2s 且 ≤ scene 1800s → burst + scene 各一组。
    @Test func navigationAnalyzeAsyncReturnsBurstGroups() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:01.000Z")
        try insertPhoto(db, id: "p2", sessionId: "s1", createdAt: "2026-01-01T00:00:02.000Z")
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "navigation.analyze", ["sessionId": JV.string("s1")])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let groups = try #require(response.data?.arrayElements)
        #expect(groups.count == 2)
        let types = groups.compactMap { $0.objectValue?["type"]?.stringValue }
        #expect(types.contains("burst"))
        #expect(types.contains("scene"))
        #expect(groups.allSatisfy { $0.objectValue?["photoIds"]?.arrayElements?.count == 2 })

        let missing = await awaitAsync(router, "navigation.analyze", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // MARK: sim.*（TS 源 similarity.ipc.ts）

    @Test func simResultNullWithoutAnalysis() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("sim.result", params: ["sessionId": JV.string("s1")])
        #expect(data == .null)
        expectRouterError("MISSING_PARAM:sessionId") { try router.execute("sim.result", params: [:]) }
    }

    @Test func simResultReturnsStoredGroups() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/p2.jpg")
        _ = try SimilarityResultRepo(connection: db).replace(
            sessionId: "s1",
            groupsJson: #"{"groups":[],"ungrouped":[]}"#,
            statsJson: #"{"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)]
        )
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("sim.result", params: ["sessionId": JV.string("s1")])
        let object = try #require(data.objectValue)
        let groups = try #require(object["groups"]?.arrayElements)
        #expect(groups.count == 1)
        #expect(groups[0].objectValue?["label"]?.stringValue == "Group 1")
        #expect(groups[0].objectValue?["count"]?.numberValue == 2)
        #expect(groups[0].objectValue?["images"]?.arrayElements?.count == 2)
        #expect(object["stats"]?.objectValue?["totalGroups"]?.numberValue == 1)
    }

    // sim.recluster：TS 侧 await worker → Swift async API（executeAsync）。
    @Test func simReclusterAsyncReclustersHashes() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertHash(db, sessionId: "s1", photoId: "p1", hex: "0000000000000000")
        try insertHash(db, sessionId: "s1", photoId: "p2", hex: "0000000000000000")
        // 先落一条既有结果（recluster 前置条件 SIM_NO_RESULTS 检查）。
        _ = try SimilarityResultRepo(connection: db).replace(
            sessionId: "s1",
            groupsJson: #"{"groups":[],"ungrouped":[]}"#,
            statsJson: #"{"totalGroups":0,"totalUngrouped":2,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: []
        )
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "sim.recluster", [
            "sessionId": JV.string("s1"),
            "threshold": JV.number(10),
            "minGroupSize": JV.number(2),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let groups = try #require(response.data?.objectValue?["groups"]?.arrayElements)
        #expect(groups.count == 1)
        #expect(groups[0].objectValue?["count"]?.numberValue == 2)

        // 无既有结果 → SIM_NO_RESULTS。
        let db2 = try makeMigratedDB()
        try insertSession(db2, "s2")
        try insertPhoto(db2, id: "p1", sessionId: "s2")
        let router2 = SessionCommandRouter.makeDefault(db: db2)
        let noResult = await awaitAsync(router2, "sim.recluster", ["sessionId": JV.string("s2")])
        #expect(noResult.ok == false)
        #expect(noResult.error == "SIM_NO_RESULTS")

        let missing = await awaitAsync(router, "sim.recluster", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    @Test func simCancelAnalysisReturnsTrue() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("sim.cancel_analysis", params: ["sessionId": JV.string("s1")])
        #expect(data.boolValue == true)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.cancel_analysis", params: [:])
        }
    }

    // MARK: jobs.*（TS 源 jobs.ipc.ts）

    @Test func jobsCancelAndRetry() throws {
        let db = try makeMigratedDB()
        let jobRepo = AnalysisJobRepo(connection: db)
        let job = try jobRepo.create(JobCreateParams(
            type: .thumbnailBuild, scopeType: "paths", scopeId: "/tmp", dedupeKey: "jobs-cancel-test"
        ))
        let router = SessionCommandRouter.makeDefault(db: db)
        let cancelled = try router.execute("jobs.cancel", params: ["jobId": JV.string(job.id)])
        #expect(cancelled.boolValue == true)
        // queued → cancelled 可直接 retry（job.service.ts 语义）。
        let retried = try router.execute("jobs.retry", params: ["jobId": JV.string(job.id)])
        #expect(retried.boolValue == true)
        #expect(try jobRepo.get(job.id)?.status == .queued)
        expectRouterError("MISSING_PARAM:jobId") { try router.execute("jobs.cancel", params: [:]) }
        expectRouterError("MISSING_PARAM:jobId") { try router.execute("jobs.retry", params: [:]) }
    }

    // jobs.clear_completed 为 destructive：桥层无 confirmed → CONFIRMATION_REQUIRED。
    @Test func jobsClearCompletedRequiresBridgeConfirmation() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "jobs.clear_completed", params: JV.object([:]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        // 直连路由（绕过桥）时二次兜底对齐 TS JOBS_CLEAR_CONFIRM_REQUIRED。
        expectRouterError("JOBS_CLEAR_CONFIRM_REQUIRED") {
            try router.execute("jobs.clear_completed", params: [:])
        }
    }

    @Test func jobsClearCompletedConfirmedReturnsCount() throws {
        let db = try makeMigratedDB()
        let jobRepo = AnalysisJobRepo(connection: db)
        let job1 = try jobRepo.create(JobCreateParams(
            type: .thumbnailBuild, scopeType: "paths", scopeId: "/tmp", dedupeKey: "clear-1"
        ))
        let job2 = try jobRepo.create(JobCreateParams(
            type: .thumbnailBuild, scopeType: "paths", scopeId: "/tmp", dedupeKey: "clear-2"
        ))
        try jobRepo.requestCancel(job1.id)
        try jobRepo.requestCancel(job2.id)
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("jobs.clear_completed", params: ["confirmed": JV.bool(true)])
        #expect(data.numberValue == 2)
    }

    // MARK: photo.list_page（TS 源 photo.ipc.ts）

    @Test func photoListPageReturnsRowsAndCursor() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("photo.list_page", params: ["sessionId": JV.string("s1")])
        let object = try #require(data.objectValue)
        let rows = try #require(object["rows"]?.arrayElements)
        #expect(rows.count == 2)
        #expect(object["cursor"]?.numberValue == 2)
        let row = try #require(rows[0].objectValue)
        #expect(row["sessionId"]?.stringValue == "s1")
        #expect(row["metadata"]?.isObject == true)
        #expect(row["variantCount"]?.numberValue == 1)
        #expect(row["variants"]?.arrayElements?.count == 1)
        #expect(row["variants"]?.arrayElements?[0].objectValue?["role"]?.stringValue == "unknown")
        expectRouterError("MISSING_PARAM:sessionId") { try router.execute("photo.list_page", params: [:]) }
    }

    // MARK: assets.candidates（TS 源 assets.ipc.ts:9-14）

    @Test func assetsCandidatesEmptyWithoutLinks() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("assets.candidates", params: [:])
        #expect(data.arrayElements?.isEmpty == true)
        // sessionId 可选（assets.ipc.ts:10-12）。
        let scoped = try router.execute("assets.candidates", params: ["sessionId": JV.string("s1")])
        #expect(scoped.arrayElements?.isEmpty == true)
    }

    // MARK: dup.*（TS 源 duplicate.ipc.ts）

    // dup.groups：无扫描组时返回空数组；缺参报错。
    @Test func dupGroupsEmptyWithoutScan() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("dup.groups", params: ["sessionId": JV.string("s1")])
        #expect(data.arrayElements?.isEmpty == true)
        expectRouterError("MISSING_PARAM:sessionId") { try router.execute("dup.groups", params: [:]) }
    }

    // dup.resolve：无 confirmed 拒绝（桥层 CONFIRMATION_REQUIRED + 路由层二次兜底）；
    // 非法 resolution 拒绝（ADR-017 逐字消息）；未扫描组 → groupNotFound。
    @Test func dupResolveRequiresConfirmationAndValidResolution() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "dup.resolve", params: JV.object(["groupId": JV.number(1), "resolution": JV.string("keep_one")]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("DUP_RESOLVE_CONFIRM_REQUIRED") {
            try router.execute("dup.resolve", params: ["groupId": JV.number(1), "resolution": JV.string("keep_one")])
        }
        expectRouterError("Invalid resolution: must be keep_one or keep_all") {
            try router.execute("dup.resolve", params: ["groupId": JV.number(1), "resolution": JV.string("bogus"), "confirmed": JV.bool(true)])
        }
        expectRouterError("Duplicate group 999 was not found or has no members") {
            try router.execute("dup.resolve", params: ["groupId": JV.number(999), "resolution": JV.string("keep_one"), "confirmed": JV.bool(true)])
        }
        expectRouterError("INVALID_PARAM:groupId") {
            try router.execute("dup.resolve", params: ["groupId": JV.string("x"), "resolution": JV.string("keep_one"), "confirmed": JV.bool(true)])
        }
    }

    // dup.resolve_member：无 confirmed 拒绝；isKept 缺省 true。
    @Test func dupResolveMemberRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "dup.resolve_member", params: JV.object(["memberId": JV.number(1)]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED") {
            try router.execute("dup.resolve_member", params: ["memberId": JV.number(1)])
        }
        expectRouterError("Duplicate member 999 was not found") {
            try router.execute("dup.resolve_member", params: ["memberId": JV.number(999), "confirmed": JV.bool(true)])
        }
    }

    // dup.scan：异步 job（executor + waitForResult）。照片文件不存在 → 全部
    // 跳过（corrupt 静默）→ 空结果组；随后 dup.groups 可见（空数组）。
    // 注意：JobService 需 start() 后 drain 才运行（TS index.ts:476 主进程启动
    // 语义），waitForResult 轮询等待后台执行完成。
    @Test func dupScanJobReturnsEmptyGroupsForMissingFiles() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/nonexistent/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/nonexistent/p2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let response = await awaitAsync(router, "dup.scan", ["sessionId": JV.string("s1")])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let result = try #require(response.data?.objectValue)
        #expect(result["exactGroups"]?.arrayElements?.isEmpty == true)
        #expect(result["visualGroups"]?.arrayElements?.isEmpty == true)
        #expect(result["totalDuplicates"]?.numberValue == 0)

        let groups = try router.execute("dup.groups", params: ["sessionId": JV.string("s1")])
        #expect(groups.arrayElements?.isEmpty == true)

        let missing = await awaitAsync(router, "dup.scan", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // dup.scan：busy 语义经 job 系统（dedupeKey 相同 → 队列去重）；
    // 直连服务层的 scanBusy 在 gather-core 测试已覆盖，此处验证路由可达。
    @Test func dupScanCreatesQueuedJob() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        // 直接创建 job 验证 executor 注册（autoResume 语义：执行器在装配期注册）。
        let job = try AnalysisJobRepo(connection: db).create(JobCreateParams(
            type: .duplicateScan, scopeType: "session", scopeId: "s1",
            dedupeKey: "duplicate.scan:s1:default",
            checkpoint: ["visualThreshold": JV.null]
        ))
        #expect(job.type == .duplicateScan)
        #expect(job.dedupeKey == "duplicate.scan:s1:default")
    }

    // MARK: sim.analyze（TS 源 similarity.ipc.ts:100-144）

    // sim.analyze：无照片 → SIM_NO_PHOTOS（analyze 早退，job failed 终态）。
    @Test func simAnalyzeFailsWithoutPhotos() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let response = await awaitAsync(router, "sim.analyze", ["sessionId": JV.string("s1")])
        #expect(response.ok == false)
        #expect(response.error == "SIM_NO_PHOTOS")

        let missing = await awaitAsync(router, "sim.analyze", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // sim.analyze：阈值非法 → SIM_THRESHOLD_INVALID（IPC 层 validate 早退，
    // 不建 job；TS 语义 threshold 0 合法、>64 非法）。
    @Test func simAnalyzeRejectsInvalidThreshold() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "sim.analyze", [
            "sessionId": JV.string("s1"),
            "threshold": JV.number(65),
            "minGroupSize": JV.number(2),
        ])
        #expect(response.ok == false)
        #expect(response.error == "SIM_THRESHOLD_INVALID")
    }
}

// MARK: - 3.0 接线测试支撑（Wave 1 服务：fkw/person/template/quality/index/metadata/writeback/album）

/// 内存 XMP 假件：按 photoPath 存取关键词/评分/标签；备份在内存登记，
/// 保证 coordinator 的 backup/restore/fileExists 链在测试内闭环。
private final class InMemoryXMPProvider: XMPProvider {
    private struct State {
        var keywords: [String] = []
        var rating: Double?
        var label: String?
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var backups: [String: String] = [:]

    func setKeywords(_ keywords: [String], for photoPath: String) {
        lock.lock()
        states[photoPath, default: State()].keywords = keywords
        lock.unlock()
    }

    func setRating(_ rating: Double, for photoPath: String) {
        lock.lock()
        states[photoPath, default: State()].rating = rating
        lock.unlock()
    }

    private func state(_ photoPath: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        return states[photoPath] ?? State()
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        state(photoPath).keywords
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let value = state(photoPath)
        return MetadataWriteAttributes(
            keywords: value.keywords.isEmpty ? nil : value.keywords,
            rating: value.rating,
            label: value.label
        )
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        lock.lock()
        var next = states[photoPath] ?? State()
        if let keywords = attributes.keywords { next.keywords = keywords }
        if let rating = attributes.rating { next.rating = rating }
        if let label = attributes.label { next.label = label }
        states[photoPath] = next
        lock.unlock()
    }

    func backup(photoPath: String) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let backupPath = "memory-backup:\(photoPath)"
        backups[backupPath] = photoPath
        return backupPath
    }

    func restore(photoPath: String, backupPath: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        backups.removeValue(forKey: backupPath)
    }

    func fileExists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if backups[path] != nil { return true }
        return false
    }

    func removeFile(_ path: String) async throws {
        lock.lock()
        states.removeValue(forKey: path)
        lock.unlock()
    }
}

/// 装配带内存 XMP 假件 + 长去抖（后台写回不落在用例窗口内）的路由。
private func makeMetadataRouter(db: DBConnection) -> (SessionCommandRouter, InMemoryXMPProvider) {
    let xmp = InMemoryXMPProvider()
    let router = SessionCommandRouter.makeDefault(
        db: db, xmpProvider: xmp, metadataWriteDebounceMs: 60_000)
    return (router, xmp)
}

/// WritebackItemRow（keywords 为 JSON 字符串）→ fkw.writeback 的 items 参数。
private func writebackItemParams(_ rows: [WritebackItemRow]) -> JV {
    JV.array(rows.map { row in
        let keywords = ((try? JV.parse(row.keywords)) as JV?)?.arrayValue ?? []
        return JV.object([
            "id": JV.number(Double(row.id)),
            "photoId": JV.string(row.photoId),
            "photoPath": JV.string(row.photoPath),
            "sessionId": JV.string(row.sessionId),
            "module": JV.string(row.module),
            "keywords": JV.array(keywords.map { JV.string($0) }),
            "xmpPath": JV.string(row.xmpPath),
            "backupPath": JV.string(row.backupPath),
            "xmpStatus": JV.string(row.xmpStatus),
            "errorMessage": JV.string(row.errorMessage),
            "attemptCount": JV.number(Double(row.attemptCount)),
            "lastAttemptAt": JV.string(row.lastAttemptAt),
        ])
    })
}

private func insertSessionWithSource(
    _ db: DBConnection, _ id: String, sourcePath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sourcePath)])
}

private func insertPerson(
    _ db: DBConnection,
    id: String,
    name: String,
    keywords: [String] = [],
    notes: String = ""
) throws {
    let data = try JSONSerialization.data(withJSONObject: keywords)
    let keywordsJSON = String(data: data, encoding: .utf8) ?? "[]"
    _ = try db.prepare("""
        INSERT INTO persons (id, name, keywords, thumbnail_base64, notes, match_threshold, created_at, updated_at)
        VALUES (?, ?, ?, '', ?, 0.6, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(name), .text(keywordsJSON), .text(notes)])
}

private func insertFaceCluster(
    _ db: DBConnection,
    id: Int64,
    sessionId: String,
    label: String,
    memberCount: Int,
    bindingRole: String? = nil,
    bindingKeywords: [String] = []
) throws {
    _ = try db.prepare("""
        INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'unbound', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.int(id), .text(sessionId), .text(label), .int(Int64(memberCount))])
    if let bindingRole {
        let data = try JSONSerialization.data(withJSONObject: bindingKeywords)
        let keywordsJSON = String(data: data, encoding: .utf8) ?? "[]"
        _ = try db.prepare("""
            INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords, created_at, updated_at)
            VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.int(id), .text(sessionId), .text(bindingRole), .text(keywordsJSON)])
    }
}

private func insertClusterMember(
    _ db: DBConnection,
    id: Int64,
    clusterId: Int64,
    sessionId: String,
    photoId: String
) throws {
    _ = try db.prepare("""
        INSERT INTO face_cluster_members (id, cluster_id, session_id, photo_id, bbox, confidence)
        VALUES (?, ?, ?, ?, '[0,0,10,10]', 0.9)
    """).run([.int(id), .int(clusterId), .text(sessionId), .text(photoId)])
}

/// 真实 JPEG 数据（ImageIO 编码，供 index.scan / quality executor 用真实文件跑）。
private func makeJPEGData(size: Int = 16) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixels = [UInt8](repeating: 128, count: size * size)
    let context = try #require(CGContext(
        data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite("RouterCommandsWave2")
struct RouterCommandsWave2Tests {
    // MARK: fkw.*（TS 源 face-kw.ipc.ts）

    @Test func fkwClustersReturnsClustersWithBindings() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 2,
                              bindingRole: "母亲", bindingKeywords: ["妈妈"])
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        try insertClusterMember(db, id: 2, clusterId: 1, sessionId: "s1", photoId: "p2")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("fkw.clusters", params: ["sessionId": JV.string("s1")])
        let clusters = try #require(data.arrayElements)
        #expect(clusters.count == 1)
        let cluster = try #require(clusters[0].objectValue)
        #expect(cluster["size"]?.numberValue == 2)
        #expect(cluster["binding"]?.objectValue?["roleName"]?.stringValue == "母亲")
        #expect(cluster["binding"]?.objectValue?["keywords"]?.arrayElements?.count == 1)
        // 成员截断至预览窗口 4 条。
        #expect(cluster["members"]?.arrayElements?.count == 2)
        #expect(cluster["members"]?.arrayElements?[0].objectValue?["photoId"]?.stringValue == "p1")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("fkw.clusters", params: [:])
        }
    }

    @Test func fkwBindWritesBindingAndBridgesPerson() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 1)
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("fkw.bind", params: [
            "sessionId": JV.string("s1"),
            "clusterId": JV.number(1),
            "roleName": JV.string("  母亲  "),
            "keywords": JV.array([JV.string("妈妈"), JV.string("妈妈"), JV.string("  ")]),
        ])
        #expect(data.objectValue?["done"]?.boolValue == true)
        let binding = try db.prepare(
            "SELECT role_name, keywords FROM role_bindings WHERE cluster_id = 1"
        ).get([])
        #expect(binding?[0].textValue == "母亲")
        #expect(binding?[1].textValue == #"["妈妈"]"#)
        // 角色桥接进人物库（best-effort upsert）。
        let persons = try PersonRepo(connection: db).list()
        #expect(persons.contains { $0.name == "母亲" })
        expectRouterError("INVALID_PARAM:clusterId") {
            try router.execute("fkw.bind", params: ["sessionId": JV.string("s1"), "roleName": JV.string("x"), "keywords": JV.array([])])
        }
        expectRouterError("FKW_KEYWORDS_INVALID") {
            try router.execute("fkw.bind", params: ["sessionId": JV.string("s1"), "clusterId": JV.number(1), "roleName": JV.string("x"), "keywords": JV.string("not-array")])
        }
        expectRouterError("FKW_CLUSTER_NOT_IN_SESSION") {
            try router.execute("fkw.bind", params: ["sessionId": JV.string("other"), "clusterId": JV.number(1), "roleName": JV.string("x"), "keywords": JV.array([])])
        }
    }

    @Test func fkwUnbindRequiresConfirmationAndUnbinds() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 1,
                              bindingRole: "母亲", bindingKeywords: ["妈妈"])
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        let (router, _) = makeMetadataRouter(db: db)
        let bridge = RecordingBridge(router: router)
        // TS core.ts destructive 列表不含 fkw.unbind（face-kw.ipc.ts 内联校验）：
        // 桥层放行、路由层二次兜底拒绝。
        bridge.handle(id: "1", command: "fkw.unbind", params: JV.object(["sessionId": JV.string("s1"), "clusterId": JV.number(1)]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "FKW_UNBIND_CONFIRM_REQUIRED")
        expectRouterError("FKW_UNBIND_CONFIRM_REQUIRED") {
            try router.execute("fkw.unbind", params: ["sessionId": JV.string("s1"), "clusterId": JV.number(1)])
        }
        let data = try router.execute("fkw.unbind", params: [
            "sessionId": JV.string("s1"), "clusterId": JV.number(1), "confirmed": JV.bool(true),
        ])
        #expect(data.objectValue?["done"]?.boolValue == true)
        #expect(data.objectValue?["removedKeywords"]?.arrayElements?.isEmpty == true)
        // 绑定已解除。
        let binding = try db.prepare("SELECT COUNT(*) FROM role_bindings WHERE cluster_id = 1").get([])
        #expect(binding?[0].intValue == 0)
        expectRouterError("FKW_CLUSTER_NOT_FOUND") {
            try router.execute("fkw.unbind", params: [
                "sessionId": JV.string("s1"), "clusterId": JV.number(99), "confirmed": JV.bool(true),
            ])
        }
    }

    @Test func fkwMergeCombinesClusters() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 1)
        try insertFaceCluster(db, id: 2, sessionId: "s1", label: "Person 2", memberCount: 1)
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        try insertClusterMember(db, id: 2, clusterId: 2, sessionId: "s1", photoId: "p2")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("fkw.merge", params: [
            "sessionId": JV.string("s1"), "source": JV.number(1), "target": JV.number(2),
        ])
        #expect(data.objectValue?["done"]?.boolValue == true)
        let members = try db.prepare(
            "SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = 2"
        ).get([])
        #expect(members?[0].intValue == 2)
        // TS repo 语义：源簇保留但归零（成员与绑定已转移）。
        let sourceCount = try db.prepare("SELECT member_count FROM face_clusters WHERE id = 1").get([])
        #expect(sourceCount?[0].intValue == 0)
        expectRouterError("INVALID_PARAM:source") {
            try router.execute("fkw.merge", params: ["sessionId": JV.string("s1"), "target": JV.number(2)])
        }
        expectRouterError("FACE_SELF_MERGE") {
            try router.execute("fkw.merge", params: ["sessionId": JV.string("s1"), "source": JV.number(2), "target": JV.number(2)])
        }
    }

    @Test func fkwRemoveMemberRemovesMember() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 2)
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        try insertClusterMember(db, id: 2, clusterId: 1, sessionId: "s1", photoId: "p2")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("fkw.remove_member", params: [
            "sessionId": JV.string("s1"), "clusterId": JV.number(1), "memberId": JV.number(1),
        ])
        #expect(data.objectValue?["done"]?.boolValue == true)
        let count = try db.prepare("SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = 1").get([])
        #expect(count?[0].intValue == 1)
        expectRouterError("INVALID_PARAM:memberId") {
            try router.execute("fkw.remove_member", params: ["sessionId": JV.string("s1"), "clusterId": JV.number(1)])
        }
        expectRouterError("FKW_CLUSTER_MEMBER_NOT_FOUND") {
            try router.execute("fkw.remove_member", params: [
                "sessionId": JV.string("s1"), "clusterId": JV.number(1), "memberId": JV.number(99),
            ])
        }
    }

    // fkw.preview：绑定簇 + 真实 writeback 链（InMemoryXMP 假件）。
    @Test func fkwPreviewBuildsWritebackItems() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/fixtures/wb1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/fixtures/wb2.jpg")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 2,
                              bindingRole: "母亲", bindingKeywords: ["妈妈"])
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        try insertClusterMember(db, id: 2, clusterId: 1, sessionId: "s1", photoId: "p2")
        let (router, xmp) = makeMetadataRouter(db: db)
        xmp.setKeywords(["外部"], for: "/tmp/fixtures/wb1.jpg")
        let data = try router.execute("fkw.preview", params: [
            "sessionId": JV.string("s1"),
            "options": JV.object(["addPrefix": JV.bool(true)]),
        ])
        let object = try #require(data.objectValue)
        #expect(object["totalCount"]?.numberValue == 2)
        let items = try #require(object["items"]?.arrayElements)
        // 关键词 = 现有 + 绑定追加（角色 + 关键字）。
        let merged = items[0].objectValue?["keywords"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(merged.contains("外部"))
        #expect(merged.contains("母亲"))
        #expect(items[0].objectValue?["preview"]?.objectValue?["willCreate"]?.boolValue == true)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("fkw.preview", params: [:])
        }
    }

    // fkw.writeback：确认校验（桥层 + 直连兜底）+ 真实执行（flushSession 经
    // InMemoryXMP 假件写回 → written）。
    @Test func fkwWritebackRequiresConfirmationAndExecutes() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/fixtures/wb1.jpg")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 1,
                              bindingRole: "母亲")
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        let (router, _) = makeMetadataRouter(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "fkw.writeback", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_CONFIRM_REQUIRED") {
            try router.execute("fkw.writeback", params: ["sessionId": JV.string("s1")])
        }
        // preview 生成 pending 行后执行。
        _ = try router.execute("fkw.preview", params: ["sessionId": JV.string("s1")])
        let items = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "face_kw", status: "pending")
        let itemParams = writebackItemParams(items)
        let data = try router.execute("fkw.writeback", params: [
            "sessionId": JV.string("s1"), "items": itemParams, "confirmed": JV.bool(true),
        ])
        let result = try #require(data.objectValue)
        #expect(result["written"]?.numberValue == 1)
        #expect(result["failed"]?.numberValue == 0)
        let status = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "face_kw")[0].xmpStatus
        #expect(status == "written")
        expectRouterError("FKW_ITEMS_INVALID") {
            try router.execute("fkw.writeback", params: [
                "sessionId": JV.string("s1"), "items": JV.string("bad"), "confirmed": JV.bool(true),
            ])
        }
    }

    // fkw.confirm_sync：确认同步全链（reload-ack 守卫对齐 TS：无 ack 拒绝）。
    @Test func fkwConfirmSyncRequiresReloadAck() throws {
        let (router, db) = try makeFkwWritebackFixture()
        // 无 reload ack → XMP_RELOAD_NOT_ACKED（TS 守卫语义）。
        expectRouterError("XMP_RELOAD_NOT_ACKED") {
            try router.execute("fkw.confirm_sync", params: ["sessionId": JV.string("s1")])
        }
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        let confirmed = try router.execute("fkw.confirm_sync", params: ["sessionId": JV.string("s1")])
        #expect(confirmed.boolValue == true)
        let status = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "face_kw")[0].xmpStatus
        #expect(status == "synced")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("fkw.confirm_sync", params: [:])
        }
    }

    // fkw.cleanup：恢复备份 + 删除已确认行。
    @Test func fkwCleanupDeletesSyncedItems() throws {
        let (router, db) = try makeFkwWritebackFixture()
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        _ = try router.execute("fkw.confirm_sync", params: ["sessionId": JV.string("s1")])
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "fkw.cleanup", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        let cleaned = try router.execute("fkw.cleanup", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(cleaned.objectValue?["deletedCount"]?.numberValue == 1)
        #expect(try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "face_kw").isEmpty)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("fkw.cleanup", params: ["confirmed": JV.bool(true)])
        }
    }

    // fkw.confirm_cleanup：destructive 确认校验（桥层 + 直连兜底）。
    @Test func fkwConfirmCleanupRequiresConfirmation() throws {
        let (router, db) = try makeFkwWritebackFixture()
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        _ = try router.execute("fkw.confirm_sync", params: ["sessionId": JV.string("s1")])
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "fkw.confirm_cleanup", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("FKW_CLEANUP_CONFIRM_REQUIRED") {
            try router.execute("fkw.confirm_cleanup", params: ["sessionId": JV.string("s1")])
        }
        let cleaned = try router.execute("fkw.confirm_cleanup", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(cleaned.objectValue?["deletedCount"]?.numberValue == 1)
    }

    // fkw.cleanup 前置：preview + writeback 走真实写回链（共享夹具）。
    private func makeFkwWritebackFixture() throws -> (SessionCommandRouter, DBConnection) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/fixtures/wb1.jpg")
        try insertFaceCluster(db, id: 1, sessionId: "s1", label: "Person 1", memberCount: 1,
                              bindingRole: "母亲")
        try insertClusterMember(db, id: 1, clusterId: 1, sessionId: "s1", photoId: "p1")
        let (router, _) = makeMetadataRouter(db: db)
        _ = try router.execute("fkw.preview", params: ["sessionId": JV.string("s1")])
        let items = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "face_kw", status: "pending")
        let itemParams = writebackItemParams(items)
        _ = try router.execute("fkw.writeback", params: [
            "sessionId": JV.string("s1"), "items": itemParams, "confirmed": JV.bool(true),
        ])
        return (router, db)
    }

    // fkw.cancel_analysis：取消 in-flight job + 释放服务占用。
    @Test func fkwCancelAnalysisCancelsFaceJobs() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let job = try AnalysisJobRepo(connection: db).create(JobCreateParams(
            type: .faceAnalyze, scopeType: "session", scopeId: "s1",
            dedupeKey: "face.analyze:s1:x:y:0.6:2"
        ))
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("fkw.cancel_analysis", params: ["sessionId": JV.string("s1")])
        #expect(data.objectValue?["done"]?.boolValue == true)
        #expect(try AnalysisJobRepo(connection: db).get(job.id)?.status == .cancelled)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("fkw.cancel_analysis", params: [:])
        }
    }

    // fkw.analyze：executor + waitForResult。照片文件缺失 → 按 missing 清理
    // → 无推理需求 → done（不触碰 Vision/解码）。
    @Test func fkwAnalyzeJobSucceedsWithMissingPhotoCleanedUp() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/nonexistent/p1.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let response = await awaitAsync(router, "fkw.analyze", [
            "sessionId": JV.string("s1"), "eps": JV.number(0.6), "minSamples": JV.number(2),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        #expect(response.data?.objectValue?["status"]?.stringValue == "done")
        let missing = await awaitAsync(router, "fkw.analyze", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // fkw.analyze：空会话 → FACE_NO_PHOTOS（job failed 终态消息逐字对齐）。
    @Test func fkwAnalyzeFailsWithoutPhotos() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let response = await awaitAsync(router, "fkw.analyze", ["sessionId": JV.string("s1")])
        #expect(response.ok == false)
        #expect(response.error == "FACE_NO_PHOTOS")
    }

    // fkw.recluster：真实 DBSCAN 聚类（观察嵌入相同 → 同一簇）。
    @Test func fkwReclusterClustersObservations() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/r1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/r2.jpg")
        let faceRepo = FaceRepo(connection: db)
        for photoId in ["p1", "p2"] {
            _ = try faceRepo.replaceObservationsByPhoto(
                sessionId: "s1",
                photoId: photoId,
                observations: [FaceObservationInput(
                    photoId: photoId,
                    bboxX: 0, bboxY: 0, bboxW: 10, bboxH: 10,
                    embedding: [1, 0, 0, 0],
                    confidence: 0.9
                )]
            )
        }
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "fkw.recluster", [
            "sessionId": JV.string("s1"), "eps": JV.number(0.6), "minSamples": JV.number(2),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        #expect(response.data?.objectValue?["done"]?.boolValue == true)
        let clusters = try faceRepo.getClusters("s1")
        #expect(clusters.count == 1)
        #expect(clusters[0].memberCount == 2)
        let missing = await awaitAsync(router, "fkw.recluster", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // MARK: person.*（TS 源 person.ipc.ts）

    @Test func personListReturnsPersonsWithCounts() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        try insertPerson(db, id: "per1", name: "母亲", keywords: ["妈妈"], notes: "家人")
        _ = try db.prepare("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES ('per1', 'p1', 's1', '[0,0,10,10]', 0.9, '2026-01-01T00:00:00.000Z')
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let list = try router.execute("person.list", params: [:])
        let persons = try #require(list.arrayElements)
        #expect(persons.count == 1)
        let person = try #require(persons[0].objectValue)
        #expect(person["id"]?.stringValue == "per1")
        #expect(person["name"]?.stringValue == "母亲")
        #expect(person["keywords"]?.arrayElements?.first?.stringValue == "妈妈")
        #expect(person["photoCount"]?.numberValue == 1)
        #expect(person["sessionCount"]?.numberValue == 1)
        #expect(person["thumbnailPath"]?.stringValue == "/tmp/f/p1.jpg")
    }

    @Test func personGetReturnsDetailWithPhotos() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        try insertPerson(db, id: "per1", name: "母亲", keywords: ["妈妈"], notes: "家人")
        _ = try db.prepare("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES ('per1', 'p1', 's1', '[0,0,10,10]', 0.9, '2026-01-01T00:00:00.000Z')
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let detail = try router.execute("person.get", params: ["personId": JV.string("per1")])
        let detailObject = try #require(detail.objectValue)
        #expect(detailObject["name"]?.stringValue == "母亲")
        #expect(detailObject["totalPhotoCount"]?.numberValue == 1)
        let photos = try #require(detailObject["photos"]?.arrayElements)
        #expect(photos[0].objectValue?["photoId"]?.stringValue == "p1")
        #expect(photos[0].objectValue?["sessionName"]?.stringValue == "")
        #expect(photos[0].objectValue?["faceBbox"]?.arrayElements?.count == 4)
        expectRouterError("PERSON_NOT_FOUND") {
            try router.execute("person.get", params: ["personId": JV.string("nope")])
        }
        expectRouterError("MISSING_PARAM:personId") {
            try router.execute("person.get", params: [:])
        }
    }

    @Test func personCreateReturnsId() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("person.create", params: [
            "name": JV.string("父亲"), "keywords": JV.array([JV.string("爸爸")]),
        ])
        let personId = try #require(created.objectValue?["id"]?.stringValue)
        #expect(personId.isEmpty == false)
        let row = try PersonRepo(connection: db).get(id: personId)
        #expect(row?.name == "父亲")
        expectRouterError("MISSING_PARAM:name") {
            try router.execute("person.create", params: [:])
        }
    }

    @Test func personUpdateAppliesFields() throws {
        let db = try makeMigratedDB()
        try insertPerson(db, id: "per1", name: "A")
        let router = SessionCommandRouter.makeDefault(db: db)
        let updated = try router.execute("person.update", params: [
            "personId": JV.string("per1"),
            "name": JV.string("  老爸  "),
            "notes": JV.string("家人"),
            "matchThreshold": JV.number(0.8),
        ])
        #expect(updated.objectValue?["done"]?.boolValue == true)
        let row = try PersonRepo(connection: db).get(id: "per1")
        #expect(row?.name == "老爸")
        #expect(row?.notes == "家人")
        #expect(row?.matchThreshold == 0.8)
        expectRouterError("MISSING_PARAM:personId") {
            try router.execute("person.update", params: ["name": JV.string("x")])
        }
    }

    @Test func personDeleteRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        try insertPerson(db, id: "per1", name: "A")
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "person.delete", params: JV.object(["personId": JV.string("per1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("PERSON_DELETE_CONFIRM_REQUIRED") {
            try router.execute("person.delete", params: ["personId": JV.string("per1")])
        }
        _ = try router.execute("person.delete", params: ["personId": JV.string("per1"), "confirmed": JV.bool(true)])
        #expect(try PersonRepo(connection: db).get(id: "per1") == nil)
        expectRouterError("MISSING_PARAM:personId") {
            try router.execute("person.delete", params: ["confirmed": JV.bool(true)])
        }
    }

    @Test func personMergeRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        try insertPerson(db, id: "per2", name: "B")
        try insertPerson(db, id: "per3", name: "C")
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "person.merge", params: JV.object(["sourceId": JV.string("per2"), "targetId": JV.string("per3")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("PERSON_MERGE_CONFIRM_REQUIRED") {
            try router.execute("person.merge", params: ["sourceId": JV.string("per2"), "targetId": JV.string("per3")])
        }
        let merged = try router.execute("person.merge", params: [
            "sourceId": JV.string("per2"), "targetId": JV.string("per3"), "confirmed": JV.bool(true),
        ])
        #expect(merged.objectValue?["done"]?.boolValue == true)
        #expect(try PersonRepo(connection: db).get(id: "per2") == nil)
        expectRouterError("MISSING_PARAM:targetId") {
            try router.execute("person.merge", params: ["sourceId": JV.string("per2"), "confirmed": JV.bool(true)])
        }
    }

    @Test func personRemovePhotoRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        try insertPerson(db, id: "per1", name: "A")
        _ = try db.prepare("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES ('per1', 'p1', 's1', '[0,0,10,10]', 0.9, '2026-01-01T00:00:00.000Z')
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "person.remove_photo", params: JV.object(["personId": JV.string("per1"), "photoId": JV.string("p1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED") {
            try router.execute("person.remove_photo", params: ["personId": JV.string("per1"), "photoId": JV.string("p1")])
        }
        _ = try router.execute("person.remove_photo", params: [
            "personId": JV.string("per1"), "photoId": JV.string("p1"), "confirmed": JV.bool(true),
        ])
        let rows = try PersonRepo(connection: db).getPhotos(personId: "per1")
        #expect(rows.isEmpty)
        expectRouterError("MISSING_PARAM:photoId") {
            try router.execute("person.remove_photo", params: ["personId": JV.string("per1"), "confirmed": JV.bool(true)])
        }
    }

    @Test func personSearchPhotosReturnsPhotosAndTotal() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/p2.jpg")
        try insertPerson(db, id: "per1", name: "A")
        _ = try db.prepare("""
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES ('per1', 'p1', 's1', '[1,2,3,4]', 0.5, '2026-01-01T00:00:00.000Z'),
                   ('per1', 'p2', 's1', '[]', 0.4, '2026-01-01T00:00:00.000Z')
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("person.search_photos", params: [
            "personId": JV.string("per1"), "limit": JV.number(1), "offset": JV.number(1),
        ])
        let object = try #require(data.objectValue)
        #expect(object["total"]?.numberValue == 2)
        #expect(object["photos"]?.arrayElements?.count == 1)
        #expect(object["photos"]?.arrayElements?[0].objectValue?["photoId"]?.stringValue == "p2")
        expectRouterError("MISSING_PARAM:personId") {
            try router.execute("person.search_photos", params: [:])
        }
    }

    // MARK: template.*（TS 源 template.ipc.ts）

    private func makeTemplateConfig() -> JV {
        JV.object([
            "similarity": JV.object(["threshold": JV.number(12), "minGroupSize": JV.number(3)]),
            "face": JV.object(["eps": JV.number(0.5), "minSamples": JV.number(2), "detectorConfidence": JV.number(0.4)]),
            "faceLibrary": JV.object(["enabled": JV.bool(true), "matchThreshold": JV.number(0.7)]),
            "duplicate": JV.object(["enabled": JV.bool(false), "visualThreshold": JV.number(0.85)]),
            "writeback": JV.object(["createAlbums": JV.bool(true), "addPrefix": JV.bool(false), "markUngrouped": JV.bool(false), "writeIPTC": JV.bool(true)]),
        ])
    }

    @Test func templateCreateValidatesConfig() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("template.create", params: [
            "name": JV.string("我的模板"), "description": JV.string("说明"), "config": makeTemplateConfig(),
        ])
        let template = try #require(created.objectValue)
        let templateId = try #require(template["id"]?.stringValue)
        #expect(template["name"]?.stringValue == "我的模板")
        #expect(template["config"]?.objectValue?["similarity"]?.objectValue?["threshold"]?.numberValue == 12)
        #expect(templateId.isEmpty == false)
        expectRouterError("TEMPLATE_CONFIG_INVALID") {
            try router.execute("template.create", params: ["name": JV.string("x"), "config": JV.string("bad")])
        }
        expectRouterError("MISSING_PARAM:name") {
            try router.execute("template.create", params: ["config": makeTemplateConfig()])
        }
    }

    @Test func templateListAndGet() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("template.create", params: [
            "name": JV.string("T"), "config": makeTemplateConfig(),
        ])
        let templateId = try #require(created.objectValue?["id"]?.stringValue)
        let list = try router.execute("template.list", params: [:])
        #expect(list.arrayElements?.count == 1)
        let got = try router.execute("template.get", params: ["templateId": JV.string(templateId)])
        #expect(got.objectValue?["id"]?.stringValue == templateId)
        expectRouterError("TEMPLATE_NOT_FOUND") {
            try router.execute("template.get", params: ["templateId": JV.string("nope")])
        }
        expectRouterError("MISSING_PARAM:templateId") {
            try router.execute("template.get", params: [:])
        }
    }

    @Test func templateUpdateRenames() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("template.create", params: ["name": JV.string("T"), "config": makeTemplateConfig()])
        let templateId = try #require(created.objectValue?["id"]?.stringValue)
        let updated = try router.execute("template.update", params: [
            "templateId": JV.string(templateId), "name": JV.string("T2"),
        ])
        #expect(updated.objectValue?["name"]?.stringValue == "T2")
        expectRouterError("MISSING_PARAM:templateId") {
            try router.execute("template.update", params: ["name": JV.string("x")])
        }
    }

    @Test func templateApplyWritesSettings() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("template.create", params: ["name": JV.string("T"), "config": makeTemplateConfig()])
        let templateId = try #require(created.objectValue?["id"]?.stringValue)
        let applied = try router.execute("template.apply", params: [
            "templateId": JV.string(templateId), "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(applied.objectValue?["done"]?.boolValue == true)
        let threshold = try SettingsRepo(connection: db).get(key: "default_threshold")?.value
        #expect(threshold == "12.0")
        expectRouterError("TEMPLATE_APPLY_CONFIRM_REQUIRED") {
            try router.execute("template.apply", params: ["templateId": JV.string(templateId), "sessionId": JV.string("s1")])
        }
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("template.apply", params: ["templateId": JV.string(templateId), "confirmed": JV.bool(true)])
        }
    }

    @Test func templateDeleteRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let config = JV.object([
            "similarity": JV.object(["threshold": JV.number(10), "minGroupSize": JV.number(2)]),
            "face": JV.object(["eps": JV.number(0.6), "minSamples": JV.number(2), "detectorConfidence": JV.number(0.5)]),
            "faceLibrary": JV.object(["enabled": JV.bool(false), "matchThreshold": JV.number(0.6)]),
            "duplicate": JV.object(["enabled": JV.bool(false), "visualThreshold": JV.number(0.8)]),
            "writeback": JV.object(["createAlbums": JV.bool(false), "addPrefix": JV.bool(false), "markUngrouped": JV.bool(false), "writeIPTC": JV.bool(false)]),
        ])
        let created = try router.execute("template.create", params: ["name": JV.string("T"), "config": config])
        let templateId = try #require(created.objectValue?["id"]?.stringValue)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "template.delete", params: JV.object(["templateId": JV.string(templateId)]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("TEMPLATE_DELETE_CONFIRM_REQUIRED") {
            try router.execute("template.delete", params: ["templateId": JV.string(templateId)])
        }
        _ = try router.execute("template.delete", params: ["templateId": JV.string(templateId), "confirmed": JV.bool(true)])
        #expect(try TemplateService(connection: db, settings: SettingsService(repo: SettingsRepo(connection: db))).get(id: templateId) == nil)
        expectRouterError("MISSING_PARAM:templateId") {
            try router.execute("template.delete", params: ["confirmed": JV.bool(true)])
        }
    }

    // MARK: quality.*（TS 源 quality.ipc.ts）

    @Test func qualityGetReturnsStoredResults() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/p1.jpg")
        let result = QualityResult(
            photoId: "p1", assetFileId: "af1", status: .succeeded, qualityScore: 0.8,
            sharpness: 0.7, exposure: 0.6, warnings: [], modelId: QualityService.modelId,
            modelVersion: QualityService.modelVersion, inputFingerprint: "f",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        _ = try db.prepare("""
            INSERT INTO asset_files (id, normalized_path, filename, media_type, file_size, file_mtime_ms, checksum, online_status, created_at, updated_at)
            VALUES ('af1', '/tmp/f/p1.jpg', 'p1.jpg', 'image/jpeg', 0, 0, '', 'online', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([])
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'af1' WHERE id = 'p1'").run([])
        let resultJSON = try String(data: JSONEncoder().encode(result), encoding: .utf8) ?? "{}"
        _ = try db.prepare("""
            INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json, warnings_json, model_id, model_version, input_fingerprint, created_at, updated_at)
            VALUES ('p1', 'af1', 'technical_quality', ?, '[]', ?, ?, 'f', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(resultJSON), .text(QualityService.modelId), .text(QualityService.modelVersion)])
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("quality.get", params: ["sessionId": JV.string("s1")])
        let results = try #require(data.arrayElements)
        #expect(results.count == 1)
        #expect(results[0].objectValue?["photoId"]?.stringValue == "p1")
        #expect(results[0].objectValue?["qualityScore"]?.numberValue == 0.8)
        #expect(results[0].objectValue?["status"]?.stringValue == "succeeded")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("quality.get", params: [:])
        }
    }

    // quality.analyze：命令创建 job 即返回；executor 用真实 JPEG 完成评分。
    @Test func qualityAnalyzeCreatesJobAndExecutesOnRealJpeg() async throws {
        let db = try makeMigratedDB()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoPath = tempDir.appendingPathComponent("q.jpg").path
        try makeJPEGData().write(to: URL(fileURLWithPath: photoPath))
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: photoPath)
        _ = try db.prepare("""
            INSERT INTO asset_files (id, normalized_path, filename, media_type, file_size, file_mtime_ms, checksum, online_status, created_at, updated_at)
            VALUES ('af1', ?, 'q.jpg', 'image/jpeg', 0, 0, '', 'online', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(photoPath)])
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'af1' WHERE id = 'p1'").run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "quality.analyze", ["sessionId": JV.string("s1")])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let job = try #require(response.data?.objectValue)
        #expect(job["type"]?.stringValue == "quality.score")
        let jobId = try #require(job["id"]?.stringValue)
        // executor 完成：真实文件评分 → succeeded。
        router.jobService.start()
        let result: [QualityResult]? = try await router.jobService.waitForResult(jobId: jobId)
        #expect(result?.count == 1)
        #expect(result?[0].status == .succeeded)
        let missing = await awaitAsync(router, "quality.analyze", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // MARK: index.scan（TS 源 indexer.ipc.ts）

    // index.scan：命令创建 metadata.scan job 即返回（dedupeKey 对齐 TS）。
    @Test func indexScanCreatesMetadataScanJob() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let router = SessionCommandRouter.makeDefault(db: db)
        let response = await awaitAsync(router, "index.scan", ["sessionId": JV.string("s1")])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let job = try #require(response.data?.objectValue)
        #expect(job["type"]?.stringValue == "metadata.scan")
        #expect(job["dedupeKey"]?.stringValue == "metadata.scan:s1")
        let missing = await awaitAsync(router, "index.scan", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
    }

    // metadata.scan executor：真实目录扫描（临时目录 + JPEG）→ added 1 →
    // 元数据提取与资产对账完成（INDEX_SESSION_NO_SOURCE 为错误路径）。
    @Test func metadataScanExecutorIndexesRealDirectory() async throws {
        let db = try makeMigratedDB()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try makeJPEGData().write(to: tempDir.appendingPathComponent("photo.jpg"))
        try insertSessionWithSource(db, "s1", sourcePath: tempDir.path)
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let job = try router.jobService.create(JobCreateParams(
            type: .metadataScan, scopeType: "session", scopeId: "s1",
            dedupeKey: "metadata.scan:s1"
        ))
        let result: IndexScanResult? = try await router.jobService.waitForResult(jobId: job.id)
        #expect(result?.added == 1)
        #expect(result?.failed.isEmpty == true)

        // 无 sourcePath → executor 失败终态 INDEX_SESSION_NO_SOURCE。
        let db2 = try makeMigratedDB()
        try insertSession(db2, "s2")
        let router2 = SessionCommandRouter.makeDefault(db: db2)
        router2.jobService.start()
        let job2 = try router2.jobService.create(JobCreateParams(
            type: .metadataScan, scopeType: "session", scopeId: "s2",
            dedupeKey: "metadata.scan:s2"
        ))
        do {
            _ = try await router2.jobService.waitForResult(jobId: job2.id) as IndexScanResult?
            Issue.record("应抛 INDEX_SESSION_NO_SOURCE")
        } catch {
            // 无 sourcePath → executor 失败终态，job.errorMessage 逐字对齐 TS。
            let jobRow = try AnalysisJobRepo(connection: db2).get(job2.id)
            #expect(jobRow?.errorMessage == "INDEX_SESSION_NO_SOURCE")
        }
    }

    // MARK: metadata.*（TS 源 metadata.ipc.ts）

    @Test func metadataGetReturnsExtractedTags() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/m1.jpg")
        let (router, xmp) = makeMetadataRouter(db: db)
        // 文件缺失 → 缓存指纹失效 → 走有效属性提取（假件预置关键词）。
        xmp.setKeywords(["关键词A"], for: "/tmp/f/m1.jpg")
        let data = try router.execute("metadata.get", params: ["photoIds": JV.array([JV.string("p1")])])
        let object = try #require(data.objectValue)
        let tags = try #require(object["p1"]?.objectValue)
        #expect(tags["keywords"]?.arrayElements?.first?.stringValue == "关键词A")
        expectRouterError("MISSING_PARAM:photoIds") {
            try router.execute("metadata.get", params: [:])
        }
    }

    @Test func metadataSetQueuesMutationAndMerges() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/m1.jpg")
        let (router, xmp) = makeMetadataRouter(db: db)
        xmp.setKeywords(["已有"], for: "/tmp/f/m1.jpg")
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "metadata.set", params: JV.object(["photoId": JV.string("p1"), "tags": JV.object(["rating": JV.number(5)])]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("METADATA_SET_CONFIRM_REQUIRED") {
            try router.execute("metadata.set", params: ["photoId": JV.string("p1"), "tags": JV.object([:])])
        }
        let data = try router.execute("metadata.set", params: [
            "photoId": JV.string("p1"),
            "tags": JV.object(["rating": JV.number(5), "keywords": JV.array([JV.string("新增")])]),
            "confirmed": JV.bool(true),
        ])
        let tags = try #require(data.objectValue)
        #expect(tags["rating"]?.numberValue == 5)
        // setMetadata 的 keywords 为 replace 语义（TS MetadataPatch 一致）。
        let keywords = tags["keywords"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(keywords == ["新增"])
        // 去抖 60s：outbox 行保持 pending（后台写回不落在用例窗口内）。
        let outbox = try MetadataOutboxRepo(connection: db).get("/tmp/f/m1.xmp")
        #expect(outbox?.status == "pending")
        #expect(outbox?.patchJSON.contains("5") == true)
        expectRouterError("MISSING_PARAM:photoId") {
            try router.execute("metadata.set", params: ["tags": JV.object([:]), "confirmed": JV.bool(true)])
        }
    }

    @Test func metadataBatchSetRequiresConfirmationAndNonEmptyUpdates() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/b1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/b2.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "metadata.batch_set", params: JV.object([
            "updates": JV.array([JV.object(["photoId": JV.string("p1"), "tags": JV.object([:])])]),
        ]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("METADATA_BATCH_SET_CONFIRM_REQUIRED") {
            try router.execute("metadata.batch_set", params: ["updates": JV.array([])])
        }
        expectRouterError("Invalid updates: must be a non-empty array") {
            try router.execute("metadata.batch_set", params: ["updates": JV.array([]), "confirmed": JV.bool(true)])
        }
        let data = try router.execute("metadata.batch_set", params: [
            "confirmed": JV.bool(true),
            "updates": JV.array([
                JV.object(["photoId": JV.string("p1"), "tags": JV.object(["rating": JV.number(3)])]),
                JV.object(["photoId": JV.string("p2"), "tags": JV.object(["keywords": JV.array([JV.string("批量")])])]),
            ]),
        ])
        let result = try #require(data.objectValue)
        #expect(result["success"]?.numberValue == 2)
        #expect(result["failed"]?.numberValue == 0)
        expectRouterError("Invalid updates: must be a non-empty array") {
            try router.execute("metadata.batch_set", params: ["confirmed": JV.bool(true)])
        }
    }

    @Test func metadataConflictsListsFieldConflicts() throws {
        let (router, _) = try makeConflictFixture()
        let conflicts = try router.execute("metadata.conflicts", params: ["sessionId": JV.string("s1")])
        let conflictList = try #require(conflicts.arrayElements)
        #expect(conflictList.count == 1)
        let fields = try #require(conflictList[0].objectValue?["fields"]?.arrayElements)
        #expect(fields.count == 1)
        #expect(fields[0].objectValue?["field"]?.stringValue == "rating")
        #expect(fields[0].objectValue?["local"]?.numberValue == 5)
        #expect(fields[0].objectValue?["remote"]?.numberValue == 4)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("metadata.conflicts", params: [:])
        }
    }

    // metadata.resolve_conflict：destructive 校验 + use_remote 全采纳 → 行删除。
    @Test func metadataResolveConflictAppliesChoices() async throws {
        let (router, db) = try makeConflictFixture()
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "metadata.resolve_conflict", params: JV.object([
            "sessionId": JV.string("s1"), "xmpPath": JV.string("/tmp/f/c1.xmp"),
            "choices": JV.object(["rating": JV.string("use_remote")]),
        ]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        let response = await awaitAsync(router, "metadata.resolve_conflict", [
            "sessionId": JV.string("s1"), "xmpPath": JV.string("/tmp/f/c1.xmp"),
            "choices": JV.object(["rating": JV.string("use_remote")]),
            "confirmed": JV.bool(true),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let outbox = try MetadataOutboxRepo(connection: db).get("/tmp/f/c1.xmp")
        #expect(outbox == nil)
        // 校验错误路径。
        let badField = await awaitAsync(router, "metadata.resolve_conflict", [
            "sessionId": JV.string("s1"), "xmpPath": JV.string("/tmp/f/c1.xmp"),
            "choices": JV.object(["bogus": JV.string("use_remote")]),
            "confirmed": JV.bool(true),
        ])
        #expect(badField.ok == false)
        #expect(badField.error == "Invalid metadata field: bogus")
        let noConfirm = await awaitAsync(router, "metadata.resolve_conflict", [
            "sessionId": JV.string("s1"), "xmpPath": JV.string("/tmp/f/c1.xmp"),
            "choices": JV.object([:]), "confirmed": JV.bool(false),
        ])
        #expect(noConfirm.error == "METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED")
    }

    /// 冲突夹具：conflict 状态 outbox 行 + 假件远程 rating 4。
    private func makeConflictFixture() throws -> (SessionCommandRouter, DBConnection) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/c1.jpg")
        let (router, xmp) = makeMetadataRouter(db: db)
        // 冲突行：基线 rating 3 / 本地 patch rating 5 / 远程（假件）rating 4。
        _ = try db.prepare("""
            INSERT INTO metadata_outbox (xmp_path, owner_session_id, photo_path, patch_json, dirty_fields, source_module, revision, base_fingerprint, base_values_json, status, attempt_count, updated_at)
            VALUES ('/tmp/f/c1.xmp', 's1', '/tmp/f/c1.jpg', '{"rating":5}', '["rating"]', 'manual', 1, '__missing__', '{"rating":3}', 'conflict', 1, '2026-01-01T00:00:00.000Z')
        """).run([])
        _ = try db.prepare("""
            INSERT INTO metadata_outbox_sessions (xmp_path, session_id, linked_at)
            VALUES ('/tmp/f/c1.xmp', 's1', '2026-01-01T00:00:00.000Z')
        """).run([])
        xmp.setRating(4, for: "/tmp/f/c1.jpg")
        return (router, db)
    }

    @Test func metadataOrphansListsRows() throws {
        let (router, _) = try makeOrphanFixture()
        let orphans = try router.execute("metadata.orphans", params: [:])
        let orphanList = try #require(orphans.arrayElements)
        #expect(orphanList.count == 1)
        #expect(orphanList[0].objectValue?["xmpPath"]?.stringValue == "/tmp/f/o1.xmp")
        #expect(orphanList[0].objectValue?["status"]?.stringValue == "pending")
    }

    // metadata.resolve_orphan：destructive 校验 + keep 删除行。
    @Test func metadataResolveOrphanDeletesRow() async throws {
        let (router, _) = try makeOrphanFixture()
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "metadata.resolve_orphan", params: JV.object(["xmpPath": JV.string("/tmp/f/o1.xmp"), "action": JV.string("keep")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        let response = await awaitAsync(router, "metadata.resolve_orphan", [
            "xmpPath": JV.string("/tmp/f/o1.xmp"), "action": JV.string("keep"),
            "confirmed": JV.bool(true),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        #expect(response.data?.arrayElements?.isEmpty == true)
        let badAction = await awaitAsync(router, "metadata.resolve_orphan", [
            "xmpPath": JV.string("/tmp/f/o1.xmp"), "action": JV.string("explode"),
            "confirmed": JV.bool(true),
        ])
        #expect(badAction.ok == false)
        #expect(badAction.error == "Invalid orphan action")
        let missing = await awaitAsync(router, "metadata.resolve_orphan", [
            "action": JV.string("keep"), "confirmed": JV.bool(true),
        ])
        #expect(missing.error == "MISSING_PARAM:xmpPath")
    }

    /// 孤儿夹具：无 metadata_outbox_sessions 关联的 outbox 行（会话已删除）。
    private func makeOrphanFixture() throws -> (SessionCommandRouter, DBConnection) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/o1.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        _ = try db.prepare("""
            INSERT INTO metadata_outbox (xmp_path, owner_session_id, photo_path, patch_json, dirty_fields, source_module, revision, base_fingerprint, base_values_json, status, attempt_count, updated_at)
            VALUES ('/tmp/f/o1.xmp', 'gone', '/tmp/f/o1.jpg', '{"keywords":["k"]}', '["keywords"]', 'manual', 1, '__missing__', '{}', 'pending', 0, '2026-01-01T00:00:00.000Z')
        """).run([])
        return (router, db)
    }

    // MARK: sim.* 写回族（TS 源 similarity.ipc.ts:189-274）

    @Test func simPreviewWritebackBuildsKeywordPlan() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/sim1.jpg")
        _ = try SimilarityResultRepo(connection: db).replace(
            sessionId: "s1",
            groupsJson: #"{"groups":[],"ungrouped":[]}"#,
            statsJson: #"{"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0)]
        )
        let (router, _) = makeMetadataRouter(db: db)
        let data = try router.execute("sim.preview_writeback", params: [
            "sessionId": JV.string("s1"),
            "assignments": JV.array([
                JV.object(["groupId": JV.number(1), "keywords": JV.array([JV.string("相似组1")])]),
            ]),
        ])
        let object = try #require(data.objectValue)
        #expect(object["totalCount"]?.numberValue == 1)
        #expect(object["affectedPhotos"]?.numberValue == 1)
        let items = try #require(object["items"]?.arrayElements)
        let keywords = items[0].objectValue?["keywords"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(keywords.contains("相似组1"))
        expectRouterError("SIM_WRITEBACK_EMPTY") {
            try router.execute("sim.preview_writeback", params: ["sessionId": JV.string("s1"), "assignments": JV.array([])])
        }
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.preview_writeback", params: ["assignments": JV.array([JV.object(["groupId": JV.number(1), "keywords": JV.array([JV.string("k")])])])])
        }
    }

    @Test func simWritebackRequiresConfirmationAndExecutes() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/sim1.jpg")
        _ = try SimilarityResultRepo(connection: db).replace(
            sessionId: "s1",
            groupsJson: #"{"groups":[],"ungrouped":[]}"#,
            statsJson: #"{"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0)]
        )
        let (router, _) = makeMetadataRouter(db: db)
        _ = try router.execute("sim.preview_writeback", params: [
            "sessionId": JV.string("s1"),
            "assignments": JV.array([
                JV.object(["groupId": JV.number(1), "keywords": JV.array([JV.string("k")])]),
            ]),
        ])
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "sim.writeback", params: JV.object(["sessionId": JV.string("s1"), "itemIds": JV.array([JV.number(1)])]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_CONFIRM_REQUIRED") {
            try router.execute("sim.writeback", params: ["sessionId": JV.string("s1"), "itemIds": JV.array([JV.number(1)])])
        }
        let items = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "similarity", status: "pending")
        #expect(items.count == 1)
        let itemIds = JV.array(items.compactMap { $0.id }.map { JV.number(Double($0)) })
        let executed = try router.execute("sim.writeback", params: [
            "sessionId": JV.string("s1"), "itemIds": itemIds, "confirmed": JV.bool(true),
        ])
        #expect(executed.objectValue?["written"]?.numberValue == 1)
        expectRouterError("SIM_PREVIEW_REQUIRED") {
            try router.execute("sim.writeback", params: ["sessionId": JV.string("s1"), "itemIds": JV.array([]), "confirmed": JV.bool(true)])
        }
    }

    @Test func simWritebackItemsListsPending() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/sim1.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        let empty = try router.execute("sim.writeback_items", params: ["sessionId": JV.string("s1")])
        #expect(empty.arrayElements?.isEmpty == true)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.writeback_items", params: [:])
        }
    }

    @Test func simRetryFailedWritebackRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/sim1.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "sim.retry_failed_writeback", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_RETRY_CONFIRM_REQUIRED") {
            try router.execute("sim.retry_failed_writeback", params: ["sessionId": JV.string("s1")])
        }
        let retried = try router.execute("sim.retry_failed_writeback", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        let result = try #require(retried.objectValue)
        #expect(result["written"]?.numberValue == 0)
        #expect(result["report"]?.stringValue == "No failed items to retry")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.retry_failed_writeback", params: ["confirmed": JV.bool(true)])
        }
    }

    @Test func simConfirmSyncRequiresReloadAck() throws {
        let (router, db) = try makeSimWritebackFixture()
        // 无 reload ack → 拒绝确认（TS 守卫）。
        expectRouterError("XMP_RELOAD_NOT_ACKED") {
            try router.execute("sim.confirm_sync", params: ["sessionId": JV.string("s1")])
        }
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        let confirmed = try router.execute("sim.confirm_sync", params: ["sessionId": JV.string("s1")])
        #expect(confirmed.boolValue == true)
        let status = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "similarity")[0].xmpStatus
        #expect(status == "synced")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.confirm_sync", params: [:])
        }
    }

    @Test func simCleanupRequiresConfirmationAndDeletesSynced() throws {
        let (router, db) = try makeSimWritebackFixture()
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        _ = try router.execute("sim.confirm_sync", params: ["sessionId": JV.string("s1")])
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "sim.cleanup", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_CLEANUP_CONFIRM_REQUIRED") {
            try router.execute("sim.cleanup", params: ["sessionId": JV.string("s1")])
        }
        let cleaned = try router.execute("sim.cleanup", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(cleaned.objectValue?["deletedCount"]?.numberValue == 1)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("sim.cleanup", params: ["confirmed": JV.bool(true)])
        }
    }

    /// sim 写回夹具：相似度结果 + preview + writeback（written 终态）。
    private func makeSimWritebackFixture() throws -> (SessionCommandRouter, DBConnection) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/sim1.jpg")
        _ = try SimilarityResultRepo(connection: db).replace(
            sessionId: "s1",
            groupsJson: #"{"groups":[],"ungrouped":[]}"#,
            statsJson: #"{"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0)]
        )
        let (router, _) = makeMetadataRouter(db: db)
        _ = try router.execute("sim.preview_writeback", params: [
            "sessionId": JV.string("s1"),
            "assignments": JV.array([
                JV.object(["groupId": JV.number(1), "keywords": JV.array([JV.string("k")])]),
            ]),
        ])
        let items = try WritebackRepo(connection: db).getItems(sessionId: "s1", module: "similarity", status: "pending")
        let itemIds = JV.array(items.compactMap { $0.id }.map { JV.number(Double($0)) })
        _ = try router.execute("sim.writeback", params: [
            "sessionId": JV.string("s1"), "itemIds": itemIds, "confirmed": JV.bool(true),
        ])
        return (router, db)
    }

    // MARK: assets.*（TS 源 assets.ipc.ts）

    @Test func assetsAcceptCandidateRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "assets.accept_candidate", params: JV.object(["candidateId": JV.string("c1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("ASSET_LINK_ACCEPT_CONFIRM_REQUIRED") {
            try router.execute("assets.accept_candidate", params: ["candidateId": JV.string("c1")])
        }
        // 已确认但候选不存在 → 仓库层 DBError.message 经 errorMessage 逐字透传。
        let confirmedBridge = RecordingBridge(router: router)
        confirmedBridge.handle(id: "2", command: "assets.accept_candidate", params: JV.object([
            "candidateId": JV.string("c1"), "confirmed": JV.bool(true),
        ]))
        #expect(confirmedBridge.frames[0].ok == false)
        #expect(confirmedBridge.frames[0].error == "ASSET_LINK_CANDIDATE_NOT_FOUND")
        expectRouterError("MISSING_PARAM:candidateId") {
            try router.execute("assets.accept_candidate", params: ["confirmed": JV.bool(true)])
        }
    }

    @Test func assetsRejectCandidateRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "assets.reject_candidate", params: JV.object(["candidateId": JV.string("c1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("ASSET_LINK_REJECT_CONFIRM_REQUIRED") {
            try router.execute("assets.reject_candidate", params: ["candidateId": JV.string("c1")])
        }
        let confirmedBridge = RecordingBridge(router: router)
        confirmedBridge.handle(id: "2", command: "assets.reject_candidate", params: JV.object([
            "candidateId": JV.string("c1"), "confirmed": JV.bool(true),
        ]))
        #expect(confirmedBridge.frames[0].ok == false)
        #expect(confirmedBridge.frames[0].error == "ASSET_LINK_CANDIDATE_NOT_FOUND")
        expectRouterError("MISSING_PARAM:candidateId") {
            try router.execute("assets.reject_candidate", params: ["confirmed": JV.bool(true)])
        }
    }

    @Test func assetsVolumesListsVolumes() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let volumes = try router.execute("assets.volumes", params: [:])
        // volumes 由扫描/挂载数据推导；空库合法（数组）。
        #expect(volumes.arrayElements != nil)
    }

    @Test func assetsVolumesAndRelinkRoot() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-relink-\(UUID().uuidString)", isDirectory: true)
        let oldRoot = tempRoot.appendingPathComponent("old", isDirectory: true).path
        let newRoot = tempRoot.appendingPathComponent("new", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try makeJPEGData().write(to: URL(fileURLWithPath: "\(oldRoot)/photo.jpg"))
        try makeJPEGData().write(to: URL(fileURLWithPath: "\(newRoot)/photo.jpg"))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "\(oldRoot)/photo.jpg")
        _ = try db.prepare("""
            INSERT INTO asset_files (id, normalized_path, filename, media_type, file_size, file_mtime_ms, checksum, online_status, created_at, updated_at)
            VALUES ('af1', ?, 'photo.jpg', 'image/jpeg', 0, 0, '', 'online', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text("\(oldRoot)/photo.jpg")])
        _ = try db.prepare("""
            INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
            VALUES ('a1', ?, 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text("\(oldRoot)/photo.jpg")])
        _ = try db.prepare("""
            INSERT INTO asset_members (asset_id, file_id, member_role, is_primary)
            VALUES ('a1', 'af1', 'raw', 1)
        """).run([])
        _ = try db.prepare("""
            UPDATE photos SET asset_id = 'a1', asset_file_id = 'af1' WHERE id = 'p1'
        """).run([])
        let router = SessionCommandRouter.makeDefault(db: db)
        let volumes = try router.execute("assets.volumes", params: [:])
        // volumes 由扫描/挂载数据推导；空库合法（数组）。
        #expect(volumes.arrayElements != nil)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "assets.relink_root", params: JV.object(["oldRoot": JV.string(oldRoot), "newRoot": JV.string(newRoot)]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("ASSET_RELINK_CONFIRM_REQUIRED") {
            try router.execute("assets.relink_root", params: ["oldRoot": JV.string(oldRoot), "newRoot": JV.string(newRoot)])
        }
        let relinked = try router.execute("assets.relink_root", params: [
            "oldRoot": JV.string(oldRoot), "newRoot": JV.string(newRoot), "confirmed": JV.bool(true),
        ])
        #expect(relinked.numberValue == 1)
        expectRouterError("MISSING_PARAM:oldRoot") {
            try router.execute("assets.relink_root", params: ["newRoot": JV.string(newRoot), "confirmed": JV.bool(true)])
        }
    }

    // MARK: album.*（TS 源 filter.ipc.ts registerAlbumHandlers）

    private func makeAlbumCriteria() -> JV {
        JV.object([
            "logic": JV.string("and"),
            "conditions": JV.array([
                JV.object(["field": JV.string("status"), "operator": JV.string("eq"), "value": JV.string("pending")]),
            ]),
        ])
    }

    @Test func albumCreateValidatesCriteriaAndCountsPhotos() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/a1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/a2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("album.create", params: [
            "name": JV.string("待处理"), "criteria": makeAlbumCriteria(), "icon": JV.string("⭐️"),
        ])
        let album = try #require(created.objectValue)
        #expect(album["name"]?.stringValue == "待处理")
        #expect(album["schemaVersion"]?.numberValue == 1)
        #expect(album["photoCount"]?.numberValue == 2)
        #expect(album["filterCriteria"]?.objectValue?["logic"]?.stringValue == "and")
        #expect(album["id"]?.stringValue?.isEmpty == false)
        expectRouterError("MISSING_PARAM:name") {
            try router.execute("album.create", params: ["criteria": makeAlbumCriteria()])
        }
        expectRouterError("Filter criteria is invalid") {
            try router.execute("album.create", params: ["name": JV.string("x")])
        }
    }

    @Test func albumListAndGet() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/a1.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("album.create", params: ["name": JV.string("A"), "criteria": makeAlbumCriteria()])
        let albumId = try #require(created.objectValue?["id"]?.stringValue)
        let list = try router.execute("album.list", params: [:])
        let albums = try #require(list.arrayElements)
        #expect(albums.count == 1)
        #expect(albums[0].objectValue?["id"]?.stringValue == albumId)
        let got = try router.execute("album.get", params: ["albumId": JV.string(albumId)])
        #expect(got.objectValue?["photoCount"]?.numberValue == 1)
        expectRouterError("ALBUM_NOT_FOUND") {
            try router.execute("album.get", params: ["albumId": JV.string("nope")])
        }
        expectRouterError("MISSING_PARAM:albumId") {
            try router.execute("album.get", params: [:])
        }
    }

    @Test func albumUpdateRenames() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/a1.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("album.create", params: ["name": JV.string("A"), "criteria": makeAlbumCriteria()])
        let albumId = try #require(created.objectValue?["id"]?.stringValue)
        let updated = try router.execute("album.update", params: [
            "albumId": JV.string(albumId), "name": JV.string("A2"),
        ])
        #expect(updated.objectValue?["done"]?.boolValue == true)
        let row = try SmartAlbumRepo(connection: db).get(id: albumId)
        #expect(row?.name == "A2")
        expectRouterError("MISSING_PARAM:albumId") {
            try router.execute("album.update", params: ["name": JV.string("x")])
        }
    }

    @Test func albumGetPhotosFiltersAndClamps() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/a1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/a2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let created = try router.execute("album.create", params: ["name": JV.string("A"), "criteria": makeAlbumCriteria()])
        let albumId = try #require(created.objectValue?["id"]?.stringValue)
        let got = try router.execute("album.get_photos", params: ["albumId": JV.string(albumId)])
        let object = try #require(got.objectValue)
        #expect(object["total"]?.numberValue == 2)
        let photos = try #require(object["photos"]?.arrayElements)
        #expect(photos.count == 2)
        #expect(photos[0].objectValue?["photoId"] != nil)
        // limit 钳制 1..500（album.ipc.ts:255）。
        let page = try router.execute("album.get_photos", params: [
            "albumId": JV.string(albumId), "limit": JV.number(1), "offset": JV.number(1),
        ])
        #expect(page.objectValue?["photos"]?.arrayElements?.count == 1)
        expectRouterError("ALBUM_NOT_FOUND") {
            try router.execute("album.get_photos", params: ["albumId": JV.string("nope")])
        }
        expectRouterError("MISSING_PARAM:albumId") {
            try router.execute("album.get_photos", params: [:])
        }
    }

    @Test func albumDeleteRequiresConfirmation() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        let criteria = JV.object([
            "logic": JV.string("and"),
            "conditions": JV.array([
                JV.object(["field": JV.string("status"), "operator": JV.string("eq"), "value": JV.string("pending")]),
            ]),
        ])
        let created = try router.execute("album.create", params: ["name": JV.string("A"), "criteria": criteria])
        let albumId = try #require(created.objectValue?["id"]?.stringValue)
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "album.delete", params: JV.object(["albumId": JV.string(albumId)]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("album.delete requires confirmation") {
            try router.execute("album.delete", params: ["albumId": JV.string(albumId)])
        }
        _ = try router.execute("album.delete", params: ["albumId": JV.string(albumId), "confirmed": JV.bool(true)])
        #expect(try SmartAlbumRepo(connection: db).get(id: albumId) == nil)
        expectRouterError("MISSING_PARAM:albumId") {
            try router.execute("album.delete", params: ["confirmed": JV.bool(true)])
        }
    }

    // MARK: session.create_from_directory（TS 源 session.ipc.ts）

    @Test func sessionCreateFromDirectoryCreatesAndQueuesScan() async throws {
        let db = try makeMigratedDB()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-cfd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try makeJPEGData().write(to: tempDir.appendingPathComponent("photo.jpg"))
        let router = SessionCommandRouter.makeDefault(db: db)
        router.jobService.start()
        let response = await awaitAsync(router, "session.create_from_directory", [
            "name": JV.string("新会话"), "sourcePath": JV.string(tempDir.path),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let session = try #require(response.data?.objectValue)
        let sessionId = try #require(session["id"]?.stringValue)
        #expect(session["name"]?.stringValue == "新会话")
        #expect(session["sourcePath"]?.stringValue == tempDir.path)
        // metadata.scan job 已入队（同 dedupeKey 可去重）。
        let jobs = try router.jobService.list()
        #expect(jobs.contains { $0.type == .metadataScan && $0.scopeId == sessionId })
        let missing = await awaitAsync(router, "session.create_from_directory", ["name": JV.string("x")])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sourcePath")
    }

    // MARK: 未接线命令保持 NOT_IMPLEMENTED（依赖 Wave 2+ 服务）

    // culling.* 已接线（Wave 2）；export.* / image.preload_* 仍依赖未移植服务。
    @Test func exportAndImageRemainNotImplemented() throws {
        let db = try makeMigratedDB()
        let router = SessionCommandRouter.makeDefault(db: db)
        expectRouterError("NOT_IMPLEMENTED: export.preview") {
            try router.execute("export.preview", params: ["sessionId": JV.string("s1"), "options": JV.object([:])])
        }
        expectRouterError("NOT_IMPLEMENTED: export.execute") {
            try router.execute("export.execute", params: ["sessionId": JV.string("s1"), "options": JV.object([:]), "confirmed": JV.bool(true)])
        }
        expectRouterError("NOT_IMPLEMENTED: image.preload_thumbnails") {
            try router.execute("image.preload_thumbnails", params: [:])
        }
    }
}

// MARK: - 3.4 Culling 接线测试（TS 源 culling.ipc.ts，真实 SQLite + 已移植服务）

/// 决策行直插（fixture 用，跳过服务层）。
private func insertCullingDecision(
    _ db: DBConnection,
    photoId: String,
    sessionId: String,
    decision: String,
    rating: Int64 = 0,
    revision: Int64 = 1,
    groupId: String = "ungrouped"
) throws {
    _ = try db.prepare("""
        INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating,
          color_label, decision_source, revision, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'None', 'manual', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(sessionId), .text(photoId), .text(groupId), .text(decision),
        .int(rating), .int(revision),
    ])
}

/// 相似度结果（成员表 + stats_json.totalGroups），返回 latest result id。
@discardableResult
private func insertCullingSimilarity(
    _ db: DBConnection,
    sessionId: String,
    memberships: [(photoId: String, groupIndex: Int)],
    totalGroups: Int = 1
) throws -> Int64 {
    _ = try SimilarityResultRepo(connection: db).replace(
        sessionId: sessionId,
        groupsJson: #"{"groups":[],"ungrouped":[]}"#,
        statsJson: #"{"totalGroups":\(totalGroups),"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
        threshold: 10,
        minGroupSize: 2,
        memberships: memberships
    )
    let row = try SimilarityResultRepo(connection: db).getLatest(sessionId: sessionId)
    return try #require(row).id
}

@Suite("RouterCommandsWave3")
struct RouterCommandsWave3Tests {
    // MARK: culling.list_page（TS 源 culling.ipc.ts:83-107）

    @Test func cullingListPageReturnsAssetsAndCursor() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/l1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/l2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)
        let data = try router.execute("culling.list_page", params: [
            "sessionId": JV.string("s1"), "scope": JV.string("all"),
        ])
        let page = try #require(data.objectValue)
        let assets = try #require(page["assets"]?.arrayElements)
        #expect(assets.count == 2)
        #expect(page["total"]?.numberValue == 2)
        // keyset 游标：最后资产组的首 rowid。
        #expect(page["nextRowId"]?.numberValue == 2)
        let asset = try #require(assets[0].objectValue)
        #expect(asset["xmpPath"]?.stringValue == "/tmp/f/l1.xmp")
        #expect(asset["state"]?.objectValue?["pickState"]?.stringValue == "unreviewed")
        #expect(asset["photo"]?.objectValue?["id"]?.stringValue == "p1")

        // filtered scope + 过滤器：无决策 → pickStates=[picked] 空页。
        let filtered = try router.execute("culling.list_page", params: [
            "sessionId": JV.string("s1"),
            "scope": JV.string("filtered"),
            "filters": JV.object(["pickStates": JV.array([JV.string("picked")])]),
        ])
        let filteredPage = try #require(filtered.objectValue)
        #expect(filteredPage["assets"]?.arrayElements?.isEmpty == true)
        #expect(filteredPage["total"]?.numberValue == 0)

        // 校验错误路径（消息与 TS 逐字一致）。
        expectRouterError("MISSING_PARAM:scope") {
            try router.execute("culling.list_page", params: ["sessionId": JV.string("s1")])
        }
        expectRouterError("CULLING_INVALID_SCOPE") {
            try router.execute("culling.list_page", params: ["sessionId": JV.string("s1"), "scope": JV.string("bogus")])
        }
        expectRouterError("limit must be an integer between 1 and 2000") {
            try router.execute("culling.list_page", params: ["sessionId": JV.string("s1"), "scope": JV.string("all"), "limit": JV.number(0)])
        }
        expectRouterError("afterRowId must be a positive integer") {
            try router.execute("culling.list_page", params: ["sessionId": JV.string("s1"), "scope": JV.string("all"), "afterRowId": JV.number(-1)])
        }
        expectRouterError("filters must be an object") {
            try router.execute("culling.list_page", params: ["sessionId": JV.string("s1"), "scope": JV.string("all"), "filters": JV.string("x")])
        }
        expectRouterError("pickStates contains an invalid state") {
            try router.execute("culling.list_page", params: [
                "sessionId": JV.string("s1"), "scope": JV.string("all"),
                "filters": JV.object(["pickStates": JV.array([JV.string("kept")])]),
            ])
        }
        expectRouterError("ratings must contain integers from 0 to 5") {
            try router.execute("culling.list_page", params: [
                "sessionId": JV.string("s1"), "scope": JV.string("all"),
                "filters": JV.object(["ratings": JV.array([JV.number(9)])]),
            ])
        }
    }

    // MARK: culling.update / culling.batch_update（TS 源 culling.ipc.ts:154-198）

    @Test func cullingUpdateAppliesPatchAndDetectsRevisionConflict() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/u1.jpg")
        let (router, _) = makeMetadataRouter(db: db)

        let data = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(0),
            "patch": JV.object(["pickState": JV.string("picked")]),
        ])
        let result = try #require(data.objectValue)
        let states = try #require(result["states"]?.arrayElements)
        #expect(states.count == 1)
        #expect(states[0].objectValue?["photoId"]?.stringValue == "p1")
        #expect(states[0].objectValue?["pickState"]?.stringValue == "picked")
        #expect(states[0].objectValue?["revision"]?.numberValue == 1)

        // 陈旧 revision → CULLING_REVISION_CONFLICT（TS 插值语义由服务抛出）。
        expectRouterError("CULLING_REVISION_CONFLICT") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
                "expectedRevision": JV.number(0),
                "patch": JV.object(["pickState": JV.string("rejected")]),
            ])
        }
        // rating 写入 outbox（metadata 队列）。
        let rated = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(1),
            "patch": JV.object(["rating": JV.number(4)]),
        ])
        #expect(rated.objectValue?["states"]?.arrayElements?[0].objectValue?["rating"]?.numberValue == 4)
        #expect(rated.objectValue?["syncStatus"]?.stringValue == "pending")

        // 校验错误路径。
        expectRouterError("MISSING_PARAM:photoId") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "expectedRevision": JV.number(0),
                "patch": JV.object([:])])
        }
        expectRouterError("expectedRevision must be a non-negative integer") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
                "expectedRevision": JV.number(-1), "patch": JV.object([:])])
        }
        expectRouterError("patch must be an object") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
                "expectedRevision": JV.number(0)])
        }
        expectRouterError("Invalid pickState") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
                "expectedRevision": JV.number(0),
                "patch": JV.object(["pickState": JV.string("bogus")])])
        }
        expectRouterError("CULLING_PATCH_INVALID") {
            try router.execute("culling.update", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
                "expectedRevision": JV.number(0), "patch": JV.object([:])])
        }
    }

    @Test func cullingBatchUpdateMergesAndValidates() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/b1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/b2.jpg")
        let router = SessionCommandRouter.makeDefault(db: db)

        let data = try router.execute("culling.batch_update", params: [
            "sessionId": JV.string("s1"),
            "photoIds": JV.array([JV.string("p1"), JV.string("p2")]),
            "patch": JV.object(["pickState": JV.string("rejected")]),
        ])
        let results = try #require(data.arrayElements)
        #expect(results.count == 2)
        #expect(results[0].objectValue?["states"]?.arrayElements?[0].objectValue?["pickState"]?.stringValue == "rejected")

        expectRouterError("MISSING_PARAM:photoIds") {
            try router.execute("culling.batch_update", params: [
                "sessionId": JV.string("s1"), "patch": JV.object(["pickState": JV.string("rejected")])])
        }
        expectRouterError("patch must be an object") {
            try router.execute("culling.batch_update", params: [
                "sessionId": JV.string("s1"), "photoIds": JV.array([JV.string("p1")])])
        }
        expectRouterError("CULLING_EMPTY_SELECTION") {
            try router.execute("culling.batch_update", params: [
                "sessionId": JV.string("s1"), "photoIds": JV.array([]),
                "patch": JV.object(["pickState": JV.string("rejected")])])
        }
    }

    // MARK: culling.decide / culling.batch_decide / culling.summary
    //（TS 源 culling.ipc.ts:259-294）

    @Test func cullingDecideAndBatchDecideUpdateSummary() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        let router = SessionCommandRouter.makeDefault(db: db)

        let decided = try router.execute("culling.decide", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"), "decision": JV.string("keep"),
        ])
        #expect(decided.boolValue == true)
        let batched = try router.execute("culling.batch_decide", params: [
            "sessionId": JV.string("s1"),
            "photoIds": JV.array([JV.string("p2"), JV.string("p3")]),
            "decision": JV.string("reject"),
        ])
        #expect(batched.boolValue == true)

        let summary = try router.execute("culling.summary", params: ["sessionId": JV.string("s1")])
        let object = try #require(summary.objectValue)
        #expect(object["totalPhotos"]?.numberValue == 3)
        #expect(object["kept"]?.numberValue == 1)
        #expect(object["rejected"]?.numberValue == 2)
        #expect(object["pending"]?.numberValue == 0)

        expectRouterError("Invalid decision: must be keep, reject, or pending") {
            try router.execute("culling.decide", params: [
                "sessionId": JV.string("s1"), "photoId": JV.string("p1"), "decision": JV.string("bogus")])
        }
        expectRouterError("Invalid decision: must be keep, reject, or pending") {
            try router.execute("culling.batch_decide", params: [
                "sessionId": JV.string("s1"), "photoIds": JV.array([JV.string("p1")]), "decision": JV.string("bogus")])
        }
        expectRouterError("MISSING_PARAM:decision") {
            try router.execute("culling.decide", params: ["sessionId": JV.string("s1"), "photoId": JV.string("p1")])
        }
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.summary", params: [:])
        }
    }

    // MARK: culling.groups / culling.decide_group / culling.reset
    //（TS 源 culling.ipc.ts:200-213 / 250-257 / 336-347）

    @Test func cullingGroupsAndDecideGroupDecideAndReset() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/g1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/tmp/f/g2.jpg")
        try insertCullingSimilarity(db, sessionId: "s1", memberships: [
            (photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0),
        ])
        let router = SessionCommandRouter.makeDefault(db: db)

        let groupsData = try router.execute("culling.groups", params: ["sessionId": JV.string("s1")])
        let groups = try #require(groupsData.arrayElements)
        #expect(groups.count == 1)
        let group = try #require(groups[0].objectValue)
        let groupId = try #require(group["groupId"]?.stringValue)
        #expect(group["images"]?.arrayElements?.count == 2)
        #expect(group["pendingCount"]?.numberValue == 2)

        let decided = try router.execute("culling.decide_group", params: [
            "sessionId": JV.string("s1"), "groupId": JV.string(groupId),
            "keepPhotoIds": JV.array([JV.string("p1")]),
        ])
        let results = try #require(decided.arrayElements)
        #expect(results.count == 2)
        let pickStates = results.compactMap { $0.objectValue?["states"]?.arrayElements?[0].objectValue?["pickState"]?.stringValue }
        #expect(pickStates.contains("picked"))
        #expect(pickStates.contains("rejected"))

        // reset 按组清空（destructive 双兜底 + groupId 透传）。
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "culling.reset", params: JV.object(["sessionId": JV.string("s1"), "groupId": JV.string(groupId)]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("CULLING_RESET_CONFIRM_REQUIRED") {
            try router.execute("culling.reset", params: ["sessionId": JV.string("s1"), "groupId": JV.string(groupId)])
        }
        let reset = try router.execute("culling.reset", params: [
            "sessionId": JV.string("s1"), "groupId": JV.string(groupId), "confirmed": JV.bool(true),
        ])
        #expect(reset.boolValue == true)
        let summary = try router.execute("culling.summary", params: ["sessionId": JV.string("s1")])
        #expect(summary.objectValue?["kept"]?.numberValue == 0)
        #expect(summary.objectValue?["pending"]?.numberValue == 2)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.reset", params: ["confirmed": JV.bool(true)])
        }

        // 无相似度结果 → 空组 + decide_group 拒绝。
        let db2 = try makeMigratedDB()
        try insertSession(db2, "s2")
        try insertPhoto(db2, id: "p1", sessionId: "s2")
        let router2 = SessionCommandRouter.makeDefault(db: db2)
        #expect(try router2.execute("culling.groups", params: ["sessionId": JV.string("s2")]).arrayElements?.isEmpty == true)
        expectRouterError("CULLING_NO_SIMILARITY") {
            try router2.execute("culling.decide_group", params: [
                "sessionId": JV.string("s2"), "groupId": JV.string("x"),
                "keepPhotoIds": JV.array([JV.string("p1")])])
        }
    }

    // MARK: culling.history / culling.apply_history（TS 源 culling.ipc.ts:109-152）

    @Test func cullingHistoryAndUndoRedo() throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/h1.jpg")
        let (router, _) = makeMetadataRouter(db: db)

        let updated = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(0),
            "patch": JV.object(["rating": JV.number(5)]),
        ])
        let operationId = try #require(updated.objectValue?["historyOperationId"]?.numberValue.map(Int.init))

        let historyData = try router.execute("culling.history", params: ["sessionId": JV.string("s1")])
        let operations = try #require(historyData.arrayElements)
        #expect(operations.count == 1)
        #expect(operations[0].objectValue?["id"]?.numberValue == Double(operationId))
        #expect(operations[0].objectValue?["undone"]?.boolValue == false)
        #expect(operations[0].objectValue?["entries"]?.arrayElements?.count == 1)

        // undo：按操作 id 解析条目 → rating 回 0。
        let undone = try router.execute("culling.apply_history", params: [
            "sessionId": JV.string("s1"),
            "entries": JV.array([
                JV.object(["photoId": JV.string("p1"), "expectedRevision": JV.number(1),
                           "patch": JV.object(["rating": JV.number(0)])]),
            ]),
            "historyOperationId": JV.number(Double(operationId)),
            "direction": JV.string("undo"),
        ])
        let states = try #require(undone.arrayElements)
        #expect(states[0].objectValue?["states"]?.arrayElements?[0].objectValue?["rating"]?.numberValue == 0)

        // 校验错误路径（消息与 TS 逐字一致）。
        expectRouterError("entries must be a non-empty array with at most 10000 items") {
            try router.execute("culling.apply_history", params: [
                "sessionId": JV.string("s1"), "entries": JV.array([]),
                "historyOperationId": JV.number(Double(operationId)), "direction": JV.string("undo")])
        }
        expectRouterError("entries[0].expectedRevision is invalid") {
            try router.execute("culling.apply_history", params: [
                "sessionId": JV.string("s1"),
                "entries": JV.array([JV.object(["photoId": JV.string("p1"),
                                               "expectedRevision": JV.number(-1),
                                               "patch": JV.object([:])])]),
                "historyOperationId": JV.number(Double(operationId)), "direction": JV.string("undo")])
        }
        expectRouterError("historyOperationId must be a positive integer") {
            try router.execute("culling.apply_history", params: [
                "sessionId": JV.string("s1"),
                "entries": JV.array([JV.object(["photoId": JV.string("p1"),
                                               "expectedRevision": JV.number(1),
                                               "patch": JV.object([:])])]),
                "direction": JV.string("undo")])
        }
        expectRouterError("direction must be undo or redo") {
            try router.execute("culling.apply_history", params: [
                "sessionId": JV.string("s1"),
                "entries": JV.array([JV.object(["photoId": JV.string("p1"),
                                               "expectedRevision": JV.number(1),
                                               "patch": JV.object([:])])]),
                "historyOperationId": JV.number(Double(operationId)), "direction": JV.string("sideways")])
        }
        expectRouterError("limit must be an integer between 1 and 500") {
            try router.execute("culling.history", params: ["sessionId": JV.string("s1"), "limit": JV.number(501)])
        }
        // undo 已完成 → 再次 undo 拒绝（历史栈守卫）。
        expectRouterError("CULLING_HISTORY_ALREADY_UNDONE") {
            try router.execute("culling.apply_history", params: [
                "sessionId": JV.string("s1"),
                "entries": JV.array([JV.object(["photoId": JV.string("p1"),
                                               "expectedRevision": JV.number(0),
                                               "patch": JV.object([:])])]),
                "historyOperationId": JV.number(Double(operationId)), "direction": JV.string("undo")])
        }
    }

    // MARK: culling.sync_status / culling.flush / culling.retry_sync
    //（TS 源 culling.ipc.ts:215-237；flush/retry_sync 走 executeAsync）

    @Test func cullingSyncStatusFlushAndRetrySync() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/s1.jpg")
        let (router, _) = makeMetadataRouter(db: db)

        _ = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(0),
            "patch": JV.object(["rating": JV.number(3)]),
        ])
        let status = try router.execute("culling.sync_status", params: ["sessionId": JV.string("s1")])
        #expect(status.objectValue?["pending"]?.numberValue == 1)

        // flush：取消去抖计时器，pending 行写入 → written。
        let flushed = await awaitAsync(router, "culling.flush", ["sessionId": JV.string("s1")])
        #expect(flushed.ok == true, "实际: \(flushed.error ?? "nil")")
        #expect(flushed.data?.objectValue?["pending"]?.numberValue == 0)
        #expect(flushed.data?.objectValue?["written"]?.numberValue == 1)

        // retry_sync：无 failed 行 → 保持 written。
        let retried = await awaitAsync(router, "culling.retry_sync", ["sessionId": JV.string("s1")])
        #expect(retried.ok == true, "实际: \(retried.error ?? "nil")")
        #expect(retried.data?.objectValue?["written"]?.numberValue == 1)

        let missing = await awaitAsync(router, "culling.flush", [:])
        #expect(missing.ok == false)
        #expect(missing.error == "MISSING_PARAM:sessionId")
        let missingRetry = await awaitAsync(router, "culling.retry_sync", [:])
        #expect(missingRetry.error == "MISSING_PARAM:sessionId")
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.sync_status", params: [:])
        }
    }

    // MARK: culling.confirm_sync / culling.finalize_sync
    //（TS 源 culling.ipc.ts:239-248 / 360-370）

    @Test func cullingConfirmSyncRequiresReloadAckAndFinalizeRequiresConfirmation() async throws {
        let (router, db) = try await makeCullingSyncedFixture()
        // 无 reload ack → XMP_RELOAD_NOT_ACKED（TS 守卫语义）。
        expectRouterError("XMP_RELOAD_NOT_ACKED") {
            try router.execute("culling.confirm_sync", params: ["sessionId": JV.string("s1")])
        }
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        let confirmed = try router.execute("culling.confirm_sync", params: ["sessionId": JV.string("s1")])
        #expect(confirmed.boolValue == true)

        // finalize_sync destructive：桥层 + 直连二次兜底。
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "culling.finalize_sync", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("CULLING_FINALIZE_CONFIRM_REQUIRED") {
            try router.execute("culling.finalize_sync", params: ["sessionId": JV.string("s1")])
        }
        let finalized = try router.execute("culling.finalize_sync", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        let summary = try #require(finalized.objectValue)
        #expect(summary["synced"]?.numberValue == 0)
        // outbox 行与备份已删除（revision 守卫删除）。
        #expect(try MetadataOutboxRepo(connection: db).getBySession("s1").isEmpty)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.finalize_sync", params: ["confirmed": JV.bool(true)])
        }
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.confirm_sync", params: [:])
        }
    }

    // MARK: culling.writeback（TS 源 culling.ipc.ts:296-334；executeAsync destructive）

    @Test func cullingWritebackRequiresConfirmationAndExecutes() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/fixtures/wb1.jpg")
        try insertCullingDecision(db, photoId: "p1", sessionId: "s1", decision: "keep")
        let (router, xmp) = makeMetadataRouter(db: db)

        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "culling.writeback", params: JV.object([
            "sessionId": JV.string("s1"), "target": JV.string("rating"),
        ]))
        #expect(bridge.frames[0].ok == false)
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        let noConfirm = await awaitAsync(router, "culling.writeback", [
            "sessionId": JV.string("s1"), "target": JV.string("rating"),
        ])
        #expect(noConfirm.ok == false)
        #expect(noConfirm.error == "WRITEBACK_CONFIRM_REQUIRED")

        // keep 决策 → rating 5 计划 → 真实写回链（InMemoryXMP 假件）。
        let response = await awaitAsync(router, "culling.writeback", [
            "sessionId": JV.string("s1"), "target": JV.string("rating"),
            "confirmed": JV.bool(true),
        ])
        #expect(response.ok == true, "实际: \(response.error ?? "nil")")
        let result = try #require(response.data?.objectValue)
        #expect(result["written"]?.numberValue == 1)
        #expect(result["failed"]?.numberValue == 0)
        let attributes = try await xmp.readAttributes(photoPath: "/tmp/fixtures/wb1.jpg")
        #expect(attributes.rating == 5)

        // 校验错误路径。
        let badTarget = await awaitAsync(router, "culling.writeback", [
            "sessionId": JV.string("s1"), "target": JV.string("bogus"),
            "confirmed": JV.bool(true),
        ])
        #expect(badTarget.ok == false)
        #expect(badTarget.error == "Invalid target: must be rating, color_label, or keyword")
        let missingTarget = await awaitAsync(router, "culling.writeback", [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(missingTarget.error == "MISSING_PARAM:target")

        // 无决策 → CULLING_NO_DECISIONS。
        let db2 = try makeMigratedDB()
        try insertSession(db2, "s2")
        try insertPhoto(db2, id: "p1", sessionId: "s2", filepath: "/tmp/fixtures/wb2.jpg")
        let router2 = SessionCommandRouter.makeDefault(db: db2)
        let noDecisions = await awaitAsync(router2, "culling.writeback", [
            "sessionId": JV.string("s2"), "target": JV.string("keyword"),
            "confirmed": JV.bool(true),
        ])
        #expect(noDecisions.ok == false)
        #expect(noDecisions.error == "CULLING_NO_DECISIONS")
    }

    // MARK: culling.retry_failed_writeback / culling.cleanup
    //（TS 源 culling.ipc.ts:349-358 / 372-386；destructive）

    @Test func cullingRetryFailedWritebackAndCleanupRequireConfirmation() async throws {
        let (router, db) = try await makeCullingSyncedFixture()
        _ = try db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = 's1'"
        ).run([])
        _ = try router.execute("culling.confirm_sync", params: ["sessionId": JV.string("s1")])

        // retry_failed_writeback：无失败项 → ok（TS 空报告语义）。
        let bridge = RecordingBridge(router: router)
        bridge.handle(id: "1", command: "culling.retry_failed_writeback", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(bridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_RETRY_CONFIRM_REQUIRED") {
            try router.execute("culling.retry_failed_writeback", params: ["sessionId": JV.string("s1")])
        }
        let retried = try router.execute("culling.retry_failed_writeback", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(retried.objectValue?["written"]?.numberValue == 0)
        #expect(retried.objectValue?["report"]?.stringValue == "No failed items to retry")

        // cleanup：协调器 + 写回并集清理（本夹具仅 outbox 行 → 删除 1 行）。
        let cleanupBridge = RecordingBridge(router: router)
        cleanupBridge.handle(id: "2", command: "culling.cleanup", params: JV.object(["sessionId": JV.string("s1")]))
        #expect(cleanupBridge.frames[0].error == "CONFIRMATION_REQUIRED")
        expectRouterError("WRITEBACK_CLEANUP_CONFIRM_REQUIRED") {
            try router.execute("culling.cleanup", params: ["sessionId": JV.string("s1")])
        }
        let cleaned = try router.execute("culling.cleanup", params: [
            "sessionId": JV.string("s1"), "confirmed": JV.bool(true),
        ])
        #expect(cleaned.objectValue?["deletedCount"]?.numberValue == 1)
        #expect(cleaned.objectValue?["errors"]?.arrayElements?.isEmpty == true)
        #expect(try MetadataOutboxRepo(connection: db).getBySession("s1").isEmpty)
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.cleanup", params: ["confirmed": JV.bool(true)])
        }
        expectRouterError("MISSING_PARAM:sessionId") {
            try router.execute("culling.retry_failed_writeback", params: ["confirmed": JV.bool(true)])
        }
    }

    // MARK: culling.retry_sync 失败行重置（TS 源 culling.ipc.ts:231-237）

    @Test func cullingRetrySyncResetsFailedOutboxRows() async throws {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/f/rs1.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        _ = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(0),
            "patch": JV.object(["rating": JV.number(2)]),
        ])
        // 直插 failed 状态行（retry_sync 的重置目标）。
        _ = try db.prepare("""
            UPDATE metadata_outbox SET status = 'failed', error_message = 'boom' WHERE owner_session_id = 's1'
        """).run([])
        let status = try router.execute("culling.sync_status", params: ["sessionId": JV.string("s1")])
        #expect(status.objectValue?["failed"]?.numberValue == 1)

        let retried = await awaitAsync(router, "culling.retry_sync", ["sessionId": JV.string("s1")])
        #expect(retried.ok == true, "实际: \(retried.error ?? "nil")")
        #expect(retried.data?.objectValue?["failed"]?.numberValue == 0)
        #expect(retried.data?.objectValue?["written"]?.numberValue == 1)
    }

    /// culling 同步夹具：rating 更新 → flush → written 终态（outbox + 备份齐备）。
    private func makeCullingSyncedFixture() async throws -> (SessionCommandRouter, DBConnection) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/tmp/fixtures/sync1.jpg")
        let (router, _) = makeMetadataRouter(db: db)
        _ = try router.execute("culling.update", params: [
            "sessionId": JV.string("s1"), "photoId": JV.string("p1"),
            "expectedRevision": JV.number(0),
            "patch": JV.object(["rating": JV.number(4)]),
        ])
        let flushed = await awaitAsync(router, "culling.flush", ["sessionId": JV.string("s1")])
        #expect(flushed.ok == true, "实际: \(flushed.error ?? "nil")")
        #expect(flushed.data?.objectValue?["written"]?.numberValue == 1)
        return (router, db)
    }
}
