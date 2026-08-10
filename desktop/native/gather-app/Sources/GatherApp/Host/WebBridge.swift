// desktop/native/gather-app/Sources/GatherApp/Host/WebBridge.swift
// Phase 3.0 宿主与桥：WKScriptMessageHandler 桥核心。
// TS 源: desktop/src/preload/index.ts（白名单语义镜像）+ main/index.ts 事件广播。
//
// 职责（与 preload 三层校验逐一对应）：
//   1. 命令白名单（ALLOWED_COMMANDS，116 个，镜像 core.ts:431）
//   2. params 必须为 JSON object（isRecord 语义）
//   3. destructive 命令必须带 params.confirmed === true（30 个，core.ts:459）
// 事件推送：Swift 侧主动 evaluateJavaScript 调 window.__gatherDispatchEvent。
// 命令路由：已移植领域服务（GatherCore）直连；未移植命令返回
// `ok:false` + "NOT_IMPLEMENTED"（渐进式接线，页面可优雅降级）。
//
// 信封（复用 HelperProtocol 约定，JSON 化）：
//   WebRequest  { id: String, command: String, params: GatherCore.JSONValue? }
//   WebResponse { id: String, ok: Bool, data: GatherCore.JSONValue?, error: String? }
// 响应经 WKScriptMessageHandler 双向通道回传（callback 按 id 配对）。
import Foundation
import WebKit
import GatherCore

/// 桥响应信封（对应 IPC_CONTRACT.md 的 Response<T>）。
public struct WebResponse: Codable, Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let data: GatherCore.JSONValue?
    public let error: String?

    public init(id: String, ok: Bool, data: GatherCore.JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
    }
}

/// 命令路由（渐进式接线）：已移植命令 → GatherCore 服务；未移植 → NOT_IMPLEMENTED。
public protocol CommandRouter {
    /// 同步命令：返回 data 或抛错（错误 message 为 GatherErrorCode 字符串）。
    func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue
    /// 异步命令（长任务，如 session.create_from_directory / 各 analyze）：
    /// 完成回调返回 WebResponse（支持流式进度时单独走事件通道）。
    func executeAsync(_ command: String, params: [String: GatherCore.JSONValue], completion: @escaping (WebResponse) -> Void)
}

/// preload 白名单语义的 Swift 镜像（源：packages/shared/src/protocol/core.ts）。
/// 三张表以 core.ts 为唯一事实源，测试守 parity（ProtocolContractTests 模式）。
public enum BridgeContract {
    /// TS: ALLOWED_COMMANDS（core.ts:431）。
    public static let allowedCommands: Set<String> = [
        "session.create", "session.create_from_directory", "session.delete", "session.delete_many", "session.list", "session.get", "session.update", "session.add_photos",
        "fkw.analyze", "fkw.recluster", "fkw.cancel_analysis", "fkw.clusters", "fkw.bind", "fkw.unbind", "fkw.merge",
        "fkw.remove_member", "fkw.preview", "fkw.writeback", "fkw.confirm_sync", "fkw.cleanup", "fkw.confirm_cleanup",
        "face.models_status",
        "sim.analyze", "sim.cancel_analysis", "sim.result", "sim.recluster",
        "sim.preview_writeback", "sim.writeback", "sim.writeback_items", "sim.retry_failed_writeback",
        "sim.confirm_sync", "sim.cleanup",
        "image.preload_thumbnails", "image.preload_previews", "image.get_dimensions", "image.prioritize_thumbnail",
        "photo.list", "photo.list_page",
        "settings.get_all", "settings.get", "settings.set", "settings.reset", "settings.get_ml_status", "settings.set_language",
        "person.list", "person.get", "person.create", "person.update", "person.delete", "person.merge", "person.remove_photo", "person.search_photos",
        "metadata.get", "metadata.set", "metadata.batch_set", "metadata.conflicts", "metadata.resolve_conflict", "metadata.orphans", "metadata.resolve_orphan",
        "dup.scan", "dup.groups", "dup.resolve", "dup.resolve_member",
        "filter.photos", "filter.photos_global", "filter.suggest",
        "album.create", "album.list", "album.get", "album.update", "album.delete", "album.get_photos",
        "export.preview", "export.execute", "export.cancel", "export.report",
        "template.create", "template.list", "template.get", "template.update", "template.delete", "template.apply",
        "culling.groups", "culling.decide", "culling.batch_decide", "culling.summary", "culling.writeback",
        "culling.list_page", "culling.update", "culling.batch_update", "culling.decide_group", "culling.sync_status", "culling.flush", "culling.retry_sync", "culling.finalize_sync",
        "culling.retry_failed_writeback", "culling.confirm_sync", "culling.cleanup", "culling.reset", "culling.history", "culling.apply_history",
        "jobs.list", "jobs.cancel", "jobs.retry", "jobs.clear_completed",
        "workspace.status",
        "assets.candidates", "assets.accept_candidate", "assets.reject_candidate", "assets.volumes", "assets.relink_root",
        "index.scan",
        "quality.analyze", "quality.get", "navigation.analyze", "navigation.list", "navigation.split", "navigation.merge",
    ]

    /// TS: DESTRUCTIVE_COMMANDS（core.ts:459）—— 必须 confirmed:true。
    public static let destructiveCommands: Set<String> = [
        "session.delete", "session.delete_many",
        "fkw.writeback", "fkw.cleanup", "fkw.confirm_cleanup",
        "sim.writeback", "sim.retry_failed_writeback", "sim.cleanup",
        "person.delete", "person.merge", "person.remove_photo",
        "dup.resolve", "dup.resolve_member",
        "culling.writeback", "culling.retry_failed_writeback", "culling.cleanup", "culling.reset",
        "culling.finalize_sync",
        "metadata.set", "metadata.batch_set", "metadata.resolve_conflict", "metadata.resolve_orphan",
        "jobs.clear_completed",
        "assets.accept_candidate", "assets.reject_candidate", "assets.relink_root",
        "template.delete",
        "album.delete",
        "export.execute", "template.apply",
    ]

    /// TS: ALLOWED_EVENTS（core.ts:475）。
    public static let allowedEvents: Set<String> = [
        "progress",
        "engine:status",
        "c1:import-trigger",
        "c1:plugin-import",
        "export:progress",
        "models:download-progress",
        "jobs:progress",
        "gather:notification",
        "culling:sync-status",
    ]

    /// TS: isRecord（core.ts）—— params 必须为纯 JSON object。
    public static func isRecord(_ value: GatherCore.JSONValue?) -> Bool {
        value?.isObject == true
    }
}

/// 桥核心：收 WKScriptMessage → 三层校验 → 路由 → 回传。
/// 与 preload 一致：校验失败即返回错误响应（渲染层无需感知差异）。
public final class WebBridge: NSObject, WKScriptMessageHandler {
    public static let messageHandlerName = "gatherBridge"

    private let router: CommandRouter
    private weak var webView: WKWebView?

    /// 响应出口（测试注入捕获帧；默认 evaluateJavaScript 回传渲染层）。
    public var responseSink: ((WebResponse) -> Void)?

    public init(router: CommandRouter, webView: WKWebView?) {
        self.router = router
        self.webView = webView
    }

    // MARK: WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let command = body["command"] as? String
        else {
            return
        }
        let params: GatherCore.JSONValue?
        if let raw = body["params"] {
            params = try? JSONDecoder().decode(GatherCore.JSONValue.self, from: JSONSerialization.data(withJSONObject: raw))
        } else {
            params = nil
        }
        handle(id: id, command: command, params: params)
    }

    /// 单命令处理：三层校验 → 路由 → 回传。
    func handle(id: String, command: String, params: GatherCore.JSONValue?) {
        // ① 命令白名单（preload: "Unknown command" 抛错）
        guard BridgeContract.allowedCommands.contains(command) else {
            respond(id: id, ok: false, error: "UNKNOWN_COMMAND")
            return
        }
        // ② params 必须为纯 JSON object（preload isRecord）
        if params != nil && !BridgeContract.isRecord(params) {
            respond(id: id, ok: false, error: "INVALID_PARAMS")
            return
        }
        // ③ destructive 命令必须 confirmed:true
        let record = params?.objectValue ?? [:]
        if BridgeContract.destructiveCommands.contains(command) {
            guard record["confirmed"]?.boolValue == true else {
                respond(id: id, ok: false, error: "CONFIRMATION_REQUIRED")
                return
            }
        }
        // 路由：异步命令走 executeAsync，其余同步执行。
        let asyncCommands: Set<String> = [
            "session.create_from_directory",
            "fkw.analyze", "fkw.recluster",
            "sim.analyze", "sim.recluster",
            "dup.scan", "index.scan", "quality.analyze", "navigation.analyze",
            "export.preview", "export.execute",
            "culling.writeback", "culling.flush", "culling.retry_sync",
            "metadata.resolve_conflict", "metadata.resolve_orphan",
        ]
        if asyncCommands.contains(command) {
            router.executeAsync(command, params: record) { [weak self] response in
                self?.respond(id: id, ok: response.ok, data: response.data, error: response.error)
            }
            return
        }
        do {
            let data = try router.execute(command, params: record)
            respond(id: id, ok: true, data: data)
        } catch {
            // 错误 message 保持 GatherErrorCode 字符串（renderer translateError 映射）。
            let message: String
            if let bridgeError = error as? BridgeError {
                message = bridgeError.description
            } else {
                let nsError = error as NSError
                message = nsError.userInfo[NSLocalizedDescriptionKey] as? String
                    ?? nsError.localizedDescription
                    ?? "\(error)"
            }
            respond(id: id, ok: false, error: message)
        }
    }

    /// 事件推送（等价主进程 webContents.send('gather:event', event, data)）：
    /// 校验事件白名单后调注入脚本的 window.__gatherDispatchEvent(event, data)。
    public func dispatchEvent(_ event: String, data: GatherCore.JSONValue?) {
        guard BridgeContract.allowedEvents.contains(event) else { return }
        let json = (try? JSONEncoder().encode(data ?? .null)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let script = "window.__gatherDispatchEvent && window.__gatherDispatchEvent(\(String(reflecting: event)), \(json))"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: 回传

    private func respond(id: String, ok: Bool, data: GatherCore.JSONValue? = nil, error: String? = nil) {
        let response = WebResponse(id: id, ok: ok, data: data, error: error)
        if let responseSink {
            responseSink(response)
            return
        }
        guard let encoded = try? JSONEncoder().encode(response),
              let json = String(data: encoded, encoding: .utf8)
        else { return }
        let script = "window.__gatherBridgeResolve && window.__gatherBridgeResolve(\(json))"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}
