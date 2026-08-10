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

    // ── image:thumbnail / image:preview（2.1 剩余，macOS 专属）──

    /// 解码请求：path 为源文件路径；scale 为缩放目标像素（thumbnail: size，
    /// preview: maxDimension）。
    public struct DecodeRequest: Codable, Equatable {
        public let path: String
        public let scale: Int

        public init(path: String, scale: Int) {
            self.path = path
            self.scale = scale
        }
    }

    /// 解码结果 payload：JPEG base64 + 输出宽高（对齐 TS DecodeResult 字段语义）。
    public struct DecodeResultPayload: Codable, Equatable {
        public let bufferBase64: String
        public let format: String
        public let width: Int
        public let height: Int

        public init(bufferBase64: String, format: String, width: Int, height: Int) {
            self.bufferBase64 = bufferBase64
            self.format = format
            self.width = width
            self.height = height
        }
    }

    /// 处理 image:thumbnail：{ path, size } → JPEG 缩略图（CGImageSource 缩略）。
    public static func thumbnail(request: HelperRequest) -> HelperResponse {
        decodeScaled(request: request, command: "image:thumbnail")
    }

    /// 处理 image:preview：{ path, maxDimension } → JPEG 预览（fit-inside）。
    public static func preview(request: HelperRequest) -> HelperResponse {
        decodeScaled(request: request, command: "image:preview")
    }

    private static func decodeScaled(request: HelperRequest, command: String) -> HelperResponse {
        guard let payload = request.payload,
            let decoded = try? HelperWire.decode(DecodeRequest.self, from: payload) else {
            return HelperResponse(id: request.id, ok: false, error: "\(command): invalid payload")
        }
        let result: RAWDecodeResult
        do {
            if command == "image:thumbnail" {
                result = try RAWDecoder.getThumbnail(path: decoded.path, size: decoded.scale)
            } else {
                result = try RAWDecoder.getPreview(path: decoded.path, maxDimension: decoded.scale)
            }
        } catch let error as RAWDecoderError {
            return HelperResponse(id: request.id, ok: false, error: "\(command): \(errorDescription(error))")
        } catch {
            return HelperResponse(id: request.id, ok: false, error: "\(command): \(error.localizedDescription)")
        }
        guard let encoded = try? HelperWire.encode(DecodeResultPayload(
            bufferBase64: result.buffer.base64EncodedString(),
            format: result.format,
            width: result.width,
            height: result.height
        )) else {
            return HelperResponse(id: request.id, ok: false, error: "\(command): payload encode failed")
        }
        return HelperResponse(id: request.id, ok: true, payload: encoded)
    }

    private static func errorDescription(_ error: RAWDecoderError) -> String {
        switch error {
        case .unsupportedExtension(let ext):
            return "unsupported extension \(ext)"
        case .cannotOpenSource(let path):
            return "cannot open source \(path)"
        case .noImage(let path):
            return "no image at \(path)"
        case .dimensionsUnavailable(let path):
            return "dimensions unavailable \(path)"
        case .jpegEncodeFailed(let path):
            return "jpeg encode failed \(path)"
        }
    }
}
