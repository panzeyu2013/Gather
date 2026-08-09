// desktop/native/gather-core/Sources/GatherCore/IPC/HelperProtocol.swift
// 1.3 helper 线协议核心逻辑：单行 JSON 请求 → 单行 JSON 响应。
// 与 IO 解耦（main.swift 只做 stdin/stdout 胶水），便于单测。

import Foundation

public enum HelperProtocol {
    // session:mock 命令返回的示例会话（冒烟/验收用，字段值可任意）。
    public static let mockSession = SessionData(
        id: "mock-1",
        name: "Mock Session",
        status: .review,
        photoCount: 12,
        analysisStatus: .done,
        writebackStatus: .idle,
        importSource: "manual",
        sourcePath: "/mock/photos",
        failedWritebackCount: 0,
        truncatedImport: false,
        createdAt: "2025-01-01T00:00:00.000Z",
        updatedAt: "2025-01-02T00:00:00.000Z"
    )

    /// 处理一行请求文本，返回编码后的响应 JSON（不含换行）。
    /// - 空/空白行返回 nil（不产生响应）；
    /// - 非法 JSON 行返回 ok=false 且 id="" 的响应（请求 id 无法还原）；
    /// - payload 兼容两种形态：base64（HelperRequest.payload 的 Data 标准编码）
    ///   与普通 JSON 字符串（冒烟便捷形态，按 UTF-8 字节承载）。
    public static func handleLine(_ line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let request = decodeRequest(from: trimmed) else {
            return encode(HelperResponse(id: "", ok: false, error: "invalid request JSON"))
        }
        return encode(respond(to: request))
    }

    /// 按 command 路由请求（纯函数，可测）。未知命令返回 ok=false + error。
    public static func respond(to request: HelperRequest) -> HelperResponse {
        switch request.command {
        case "echo":
            return HelperResponse(id: request.id, ok: true, payload: request.payload)
        case "session:mock":
            guard let payload = try? HelperWire.encode(mockSession) else {
                return HelperResponse(id: request.id, ok: false, error: "session:mock payload encode failed")
            }
            return HelperResponse(id: request.id, ok: true, payload: payload)
        default:
            return HelperResponse(id: request.id, ok: false, error: "unknown command: \(request.command)")
        }
    }

    // 先按标准 HelperRequest 解码（payload 为 base64 Data）；失败时兼容
    // 冒烟形态：payload 为普通 JSON 字符串时按 UTF-8 字节承载。
    private static func decodeRequest(from line: String) -> HelperRequest? {
        if let request = try? HelperWire.decode(HelperRequest.self, from: Data(line.utf8)) {
            return request
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
        guard let dict = object as? [String: Any],
            let id = dict["id"] as? String,
            let command = dict["command"] as? String
        else { return nil }
        let payload: Data?
        if let payloadString = dict["payload"] as? String {
            payload = Data(payloadString.utf8)
        } else if dict["payload"] == nil || dict["payload"] is NSNull {
            payload = nil
        } else {
            return nil
        }
        return HelperRequest(id: id, command: command, payload: payload)
    }

    private static func encode(_ response: HelperResponse) -> Data? {
        try? HelperWire.encode(response)
    }
}
