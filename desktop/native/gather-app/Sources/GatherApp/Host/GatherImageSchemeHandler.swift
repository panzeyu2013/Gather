// desktop/native/gather-app/Sources/GatherApp/Host/GatherImageSchemeHandler.swift
// Phase 3.0 宿主与桥：gather-image:// 自定义协议（WKURLSchemeHandler）。
// TS 源: desktop/src/main/index.ts 76–86 + 407–432（protocol.handle，重写）。
//
// renderer 的 image.ts 用 `gather-image://thumbnail|preview?path=&size=` 作
// <img src>。WKWebView 不识该 scheme，须注册 handler 直出 JPEG NSData
// （二进制走 evaluateJavaScript 会极慢，URL scheme 直出是正解）。
import Foundation
import WebKit
import GatherCore

/// gather-image://thumbnail?path=...&size=128
/// gather-image://preview?path=...&maxDimension=2048
/// 语义对齐主进程 protocol.handle：校验 path 在库内 → RAWDecoder 出 JPEG。
public final class GatherImageSchemeHandler: NSObject, WKURLSchemeHandler {
    public func webView(
        _ webView: WKWebView,
        start urlSchemeTask: WKURLSchemeTask
    ) {
        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            urlSchemeTask.didFailWithError(NSError(domain: "gather-image", code: 400))
            return
        }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        let path = value("path") ?? ""
        // 文件必须存在（等价主进程校验 path 在库内；库归属校验随 3.x 权限
        // 模型接入，当前至少拒绝不存在路径）。
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            urlSchemeTask.didFailWithError(NSError(domain: "gather-image", code: 404))
            return
        }
        do {
            let result: RAWDecodeResult
            if components.host == "thumbnail", let size = Int(value("size") ?? "0"), size > 0 {
                result = try RAWDecoder.getThumbnail(path: path, size: size)
            } else if components.host == "preview", let maxDim = Int(value("maxDimension") ?? "0"), maxDim > 0 {
                result = try RAWDecoder.getPreview(path: path, maxDimension: maxDim)
            } else {
                // 默认缩略图（renderer 传 size 通常 128–512）。
                result = try RAWDecoder.getThumbnail(path: path, size: 512)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg", "Content-Length": "\(result.buffer.count)"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(result.buffer)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 无长任务：无需取消处理。
    }
}
