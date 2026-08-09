// desktop/native/gather-core/Sources/GatherCore/IPC/ImageCommands.swift
// image:* 命令实现（Phase 2 任务 2.1「image.service 改路由」）。
// 命令逻辑与 HelperProtocol 路由分离，路由处只加一个 case 分支，保持
// HelperProtocol.swift 干净。

import Foundation

public enum ImageCommands {
    /// image:dimensions 请求 payload：ext 为带点扩展名（如 ".jpg"，语义与
    /// fast-dimensions.ts 一致），dataBase64 为图片头字节的 base64 编码。
    public struct DimensionsRequest: Codable, Equatable {
        public let ext: String
        public let dataBase64: String

        public init(ext: String, dataBase64: String) {
            self.ext = ext
            self.dataBase64 = dataBase64
        }
    }

    /// 尺寸可读时的响应 payload：{ width, height }。
    public struct DimensionsResult: Codable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// 尺寸不可读时的响应 payload：JSON null（与 TS readDimensions 返回 null 语义一致）。
    public static let dimensionsNullPayload = Data("null".utf8)

    /// 处理 image:dimensions：
    /// - 请求 payload 缺失/非法/不可解码 → ok=false + error；
    /// - dataBase64 非法 → ok=false + error；
    /// - 数据合法但尺寸不可读（含未知格式）→ ok=true + payload null；
    /// - 成功 → ok=true + payload { width, height }。
    public static func dimensions(request: HelperRequest) -> HelperResponse {
        guard let payload = request.payload,
            let decoded = try? HelperWire.decode(DimensionsRequest.self, from: payload) else {
            return HelperResponse(id: request.id, ok: false, error: "image:dimensions: invalid payload")
        }
        guard let data = Data(base64Encoded: decoded.dataBase64) else {
            return HelperResponse(id: request.id, ok: false, error: "image:dimensions: invalid dataBase64")
        }
        guard let dims = ImageDimensions.read(data, ext: decoded.ext) else {
            return HelperResponse(id: request.id, ok: true, payload: dimensionsNullPayload)
        }
        guard let encoded = try? HelperWire.encode(DimensionsResult(width: dims.width, height: dims.height)) else {
            return HelperResponse(id: request.id, ok: false, error: "image:dimensions: payload encode failed")
        }
        return HelperResponse(id: request.id, ok: true, payload: encoded)
    }
}
