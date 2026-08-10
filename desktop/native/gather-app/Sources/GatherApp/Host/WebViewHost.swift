// desktop/native/gather-app/Sources/GatherApp/Host/WebViewHost.swift
// Phase 3.0 宿主与桥：WKWebView 托管残余 React 页。
// TS 源: desktop/src/main/index.ts（BrowserWindow 配置段，重写）。
//
// 对应关系：
//   - loadFileURL(index.html, allowingReadAccessTo: rendererDir)  ≈ loadFile(renderer/index.html)
//   - WKUserScript(document start) 注入 BridgeScript ≈ preload/index.js
//   - WKURLSchemeHandler 注册 gather-image ≈ main/index.ts protocol.handle
//   - 导航策略（禁外跳）≈ setWindowOpenHandler deny + will-navigate preventDefault
//   - 事件推送：webBridge.dispatchEvent ≈ webContents.send('gather:event', ...)
import Foundation
import WebKit
import AppKit
import GatherCore

/// WKWebView 托管宿主：加载 renderer 静态产物并接线桥。
public final class WebViewHost: NSViewController, WKNavigationDelegate {
    public let webBridge: WebBridge
    private let rendererDir: URL
    /// 内部可见（测试 JS 求值探针）。
    var webView: WKWebView!

    /// rendererDir: desktop/dist/renderer（vite build 产物）。
    public init(rendererDir: URL, router: CommandRouter) {
        self.rendererDir = rendererDir
        let configuration = WKWebViewConfiguration()
        // gather-image:// 自定义协议（renderer 的 <img src> 直出 JPEG）。
        let imageHandler = GatherImageSchemeHandler()
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: "gather-image")
        // 注入 window.gather shim（document start，等价 preload）。
        let userScript = WKUserScript(
            source: BridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.webBridge = WebBridge(router: router, webView: webView)
        configuration.userContentController.add(webBridge, name: WebBridge.messageHandlerName)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        view = NSView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        loadRenderer()
    }

    /// 加载 React 静态产物（等价 Electron 生产 loadFile）。
    private func loadRenderer() {
        let index = rendererDir.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else {
            GatherLogger.log("renderer index.html not found at \(index.path); run `npm run build` in desktop/", level: .error)
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: rendererDir)
    }

    // MARK: WKNavigationDelegate —— 禁外跳（等价 setWindowOpenHandler deny）

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        GatherLogger.log("renderer navigation failed: \(error)", level: .error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        GatherLogger.log("renderer provisional navigation failed: \(error)", level: .error)
    }

    /// 事件推送入口（等价主进程 webContents.send）。
    public func dispatchEvent(_ event: String, data: GatherCore.JSONValue?) {
        webBridge.dispatchEvent(event, data: data)
    }

    /// 外部路由跳转：SwiftUI 壳切到残余 React 页时把 HashRouter 带到目标
    /// 路由（等价 React Router navigate；route 如 "/library" 或 "/sessions/x"）。
    public func navigate(to route: String) {
        let script = "location.hash = '#\(route)'"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}
