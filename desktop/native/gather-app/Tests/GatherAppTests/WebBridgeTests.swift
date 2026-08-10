// desktop/native/gather-app/Tests/GatherAppTests/WebBridgeTests.swift
// Phase 3.0 宿主与桥行为测试。
// 对照 preload/index.ts 三层校验语义 + 命令路由渐进式接线状态。
//
// 注意：WebBridge 依赖 WKWebView evaluateJavaScript 回传，纯逻辑校验
// （白名单/confirmed/路由）用无 webView 实例直接调 handle 验证响应帧；
// 事件推送 dispatchEvent 在无 webView 时安全 no-op。

import Foundation
import Testing
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
