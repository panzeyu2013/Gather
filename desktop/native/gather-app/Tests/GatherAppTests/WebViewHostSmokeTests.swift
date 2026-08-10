// desktop/native/gather-app/Tests/GatherAppTests/WebViewHostSmokeTests.swift
// Phase 3.0 宿主与桥端到端冒烟：真实 WKWebView + 真实 React 产物 + 真实桥。
//
// 验证链路：注入脚本 → window.gather.sendCommand → messageHandlers →
// WebBridge 三层校验 → SessionCommandRouter（真实 SQLite）→ 回传 →
// JS Promise 解析。等价 Electron e2e 的桥冒烟段（tests/e2e/app.spec.ts）。
//
// 前置：desktop/ 下 `npm run build` 产出 dist/renderer（vite 纯静态）。

import Foundation
import Testing
import WebKit
@testable import GatherApp
@testable import GatherCore

/// 真实 WKWebView 冒烟（AppKit 主线程约束：跳 MainActor 执行）。
@MainActor
@Suite("WebViewHostSmoke")
struct WebViewHostSmokeTests {
    /// 定位 renderer 产物：桌面端 desktop/dist/renderer（相对本文件上溯）。
    private static func rendererDir() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        // 此时位于 desktop/native/gather-app 的 4 级父（desktop/）…
        return url.appendingPathComponent("dist/renderer")
    }

    /// 加载页面并等待注入脚本就绪（window.gather 存在）。
    private func makeLoadedHost() async throws -> WebViewHost {
        let dir = Self.rendererDir()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            throw SmokeError.missingRenderer
        }
        // 真实路由：临时 SQLite + 全部已移植服务。
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-app-smoke-\(UUID().uuidString).sqlite")
        let db = try DBConnection(path: dbURL.path)
        try MigrationRunner().migrate(db)
        let router = SessionCommandRouter.makeDefault(db: db)
        let host = WebViewHost(rendererDir: dir, router: router)
        host.viewDidLoad()
        return host
    }

    /// 等待 window.gather 注入完成。
    private func waitForBridge(_ host: WebViewHost) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = await host.webViewForEvaluation()?.evalSync("typeof window.gather")
            if value == "object" { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// JS 求值（同步版，String 化）。
    private func eval(_ host: WebViewHost, _ script: String) async -> String? {
        await host.webViewForEvaluation()?.evalSync(script)
    }

    /// 发起异步 JS 操作并轮询读取全局结果（macOS 26 WebKit 的
    /// callAsyncJavaScript 返回 nil，改同步求值 + 全局变量轮询）。
    private func evalWithPolling(_ host: WebViewHost, _ script: String) async -> String? {
        let deadline = Date().addingTimeInterval(5)
        _ = await eval(host, script)
        while Date() < deadline {
            if let value = await eval(host, "window.__lastBridgeResult") {
                return value
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    // MARK: 用例

    // 冒烟：页面加载 → window.gather 注入 → session.list 经桥回路返回信封。
    @Test func bridgeRoundTripOverRealWebView() async throws {
        let host = try await makeLoadedHost()
        let ready = await waitForBridge(host)
        #expect(ready, "注入脚本未就绪")

        let result = await evalWithPolling(
            host,
            "window.gather.sendCommand('session.list', {})"
                + ".then(function(r){ window.__lastBridgeResult = JSON.stringify(r); })"
                + ".catch(function(e){ window.__lastBridgeResult = 'ERR:' + e.message; })"
        )
        #expect(result?.contains("ok") == true, "桥回路未返回信封，实际: \(result ?? "nil")")
    }

    // 冒烟：destructive 无 confirmed → JS 侧 reject。
    @Test func destructiveRequiresConfirmationOverWebView() async throws {
        let host = try await makeLoadedHost()
        _ = await waitForBridge(host)
        let result = await evalWithPolling(
            host,
            "window.gather.sendCommand('session.delete', {sessionId:'x'})"
                + ".then(function(){ window.__lastBridgeResult = 'resolved'; })"
                + ".catch(function(e){ window.__lastBridgeResult = 'rejected:' + e.type + ':' + e.message; })"
        )
        #expect(result?.hasPrefix("rejected:") == true, "应被拒绝，实际: \(result ?? "nil")")
    }

    // 冒烟：未知命令 → reject。
    @Test func unknownCommandRejectedOverWebView() async throws {
        let host = try await makeLoadedHost()
        _ = await waitForBridge(host)
        let result = await evalWithPolling(
            host,
            "window.gather.sendCommand('nope.nothing', {})"
                + ".then(function(){ window.__lastBridgeResult = 'resolved'; })"
                + ".catch(function(e){ window.__lastBridgeResult = 'rejected:' + e.message; })"
        )
        #expect(result?.hasPrefix("rejected:") == true, "应被拒绝，实际: \(result ?? "nil")")
    }
}

enum SmokeError: Error {
    case missingRenderer
}

// MARK: - 辅助

extension WebViewHost {
    /// 测试用：暴露 webView 供 JS 求值。
    func webViewForEvaluation() -> WKWebView? {
        self.webView
    }
}

extension WKWebView {
    /// 同步 evaluateJavaScript（String 结果；macOS 26 下 callAsyncJavaScript
    /// 返回 nil，同步版可靠；Promise 结果用全局变量轮询模式）。
    func evalSync(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }
}
