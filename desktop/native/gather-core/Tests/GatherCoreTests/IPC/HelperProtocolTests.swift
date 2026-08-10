// desktop/native/gather-core/Tests/GatherCoreTests/IPC/HelperProtocolTests.swift
// 1.3 helper 线协议核心逻辑单测：echo 往返、未知命令、session:mock 往返、非法 JSON。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherCore

struct HelperProtocolTests {

    // MARK: - echo

    @Test func echoRoundTripsPlainStringPayload() throws {
        // 冒烟便捷形态：payload 为普通 JSON 字符串（按 UTF-8 字节承载）。
        let line = #"{"id":"1","command":"echo","payload":"{\"v\":1}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "1")
        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.payload == Data(#"{"v":1}"#.utf8))
    }

    @Test func echoRoundTripsBase64Payload() throws {
        // 标准形态：payload 为 base64 编码的 Data。
        let payload = Data(#"{"v":1}"#.utf8)
        let request = HelperRequest(id: "2", command: "echo", payload: payload)
        let line = try #require(String(data: HelperWire.encode(request), encoding: .utf8))
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "2")
        #expect(response.ok)
        #expect(response.payload == payload)
    }

    @Test func echoWithNilPayload() throws {
        let request = HelperRequest(id: "3", command: "echo")
        let line = try #require(String(data: HelperWire.encode(request), encoding: .utf8))
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "3")
        #expect(response.ok)
        #expect(response.payload == nil)
    }

    // MARK: - 路由

    @Test func unknownCommandReturnsError() throws {
        let line = #"{"id":"4","command":"frobnicate"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.id == "4")
        #expect(response.payload == nil)
        #expect(response.error?.contains("unknown command") == true)
    }

    @Test func sessionMockRoundTrip() throws {
        let line = #"{"id":"5","command":"session:mock"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "5")
        #expect(response.ok)
        #expect(response.error == nil)
        let session = try HelperWire.decode(SessionData.self, from: try #require(response.payload))
        #expect(session == HelperProtocol.mockSession)
        #expect(session.status == .review)
        #expect(session.photoCount == 12)
    }

    // MARK: - image:dimensions

    @Test func imageDimensionsReadsJpegHeader() throws {
        // 冒烟便捷形态（payload 为普通 JSON 字符串）：合法 JPEG SOF0 头 → 240×120。
        let line = #"{"id":"7","command":"image:dimensions","payload":"{\"ext\":\".jpg\",\"dataBase64\":\"/9j/wAALCAB4APABIgAA\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "7")
        #expect(response.ok)
        #expect(response.error == nil)
        let result = try HelperWire.decode(ImageCommands.DimensionsResult.self, from: try #require(response.payload))
        #expect(result == ImageCommands.DimensionsResult(width: 240, height: 120))
    }

    @Test func imageDimensionsStandardWireForm() throws {
        // 标准形态（payload 为 base64 Data）：合法 PNG IHDR → 512×480。
        let payload = Data(#"{"ext":".png","dataBase64":"iVBORw0KGgoAAAANSUhEUgAAAgAAAAHgCAYAAAAAAAAA"}"#.utf8)
        let request = HelperRequest(id: "8", command: "image:dimensions", payload: payload)
        let line = try #require(String(data: HelperWire.encode(request), encoding: .utf8))
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "8")
        #expect(response.ok)
        #expect(response.error == nil)
        let result = try HelperWire.decode(ImageCommands.DimensionsResult.self, from: try #require(response.payload))
        #expect(result == ImageCommands.DimensionsResult(width: 512, height: 480))
    }

    @Test func imageDimensionsCorruptDataReturnsNullPayload() throws {
        // 损坏数据（magic 不匹配）：尺寸不可读，ok=true + payload JSON null。
        let line = #"{"id":"9","command":"image:dimensions","payload":"{\"ext\":\".jpg\",\"dataBase64\":\"AAAAAAAAAAAAAAAA\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "9")
        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.payload == ImageCommands.dimensionsNullPayload)
    }

    @Test func imageDimensionsUnknownExtensionReturnsNullPayload() throws {
        // 未知扩展且无匹配 magic（ext 兜底只认 .tif/.tiff）→ null。
        let line = #"{"id":"10","command":"image:dimensions","payload":"{\"ext\":\".xyz\",\"dataBase64\":\"AAAAAAAAAAAAAAAA\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "10")
        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.payload == ImageCommands.dimensionsNullPayload)
    }

    @Test func imageDimensionsExtIgnoredWhenMagicMatches() throws {
        // 未知扩展但 JPEG magic 可识别：尺寸仍返回（与 TS detectFormat 语义一致）。
        let line = #"{"id":"12","command":"image:dimensions","payload":"{\"ext\":\".xyz\",\"dataBase64\":\"/9j/wAALCAB4APABIgAA\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.ok)
        let result = try HelperWire.decode(ImageCommands.DimensionsResult.self, from: try #require(response.payload))
        #expect(result == ImageCommands.DimensionsResult(width: 240, height: 120))
    }

    @Test func imageDimensionsMissingFieldReturnsError() throws {
        // payload 缺 dataBase64 字段 → ok=false + error。
        let line = #"{"id":"13","command":"image:dimensions","payload":"{\"ext\":\".jpg\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.id == "13")
        #expect(response.error?.contains("image:dimensions") == true)
    }

    @Test func imageDimensionsInvalidBase64ReturnsError() throws {
        // dataBase64 非法 → ok=false + error。
        let line = #"{"id":"14","command":"image:dimensions","payload":"{\"ext\":\".jpg\",\"dataBase64\":\"%%%\"}"}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.id == "14")
        #expect(response.error?.contains("image:dimensions") == true)
    }

    // MARK: - image:thumbnail / image:preview

    @Test func imageThumbnailDecodesRealJpeg() throws {
        // 真实 JPEG 文件 → 缩略图（标准线协议形态，payload 为 base64 Data）。
        let url = try makeTestJPEG(width: 1200, height: 800)
        defer { cleanup([url]) }
        let payload = Data(#"{"path":"\#(url.path)","scale":256}"#.utf8)
        let request = HelperRequest(id: "20", command: "image:thumbnail", payload: payload)
        let line = try #require(String(data: HelperWire.encode(request), encoding: .utf8))
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.id == "20")
        #expect(response.ok)
        #expect(response.error == nil)
        let result = try HelperWire.decode(ImageCommands.DecodeResultPayload.self, from: try #require(response.payload))
        #expect(result.format == "jpeg")
        #expect(result.width <= 256 && result.height <= 256)
        let jpeg = try #require(Data(base64Encoded: result.bufferBase64))
        #expect(jpeg.count > 2)
        #expect(jpeg[0] == 0xFF && jpeg[1] == 0xD8)
    }

    @Test func imagePreviewFitsInside() throws {
        let url = try makeTestJPEG(width: 4000, height: 2000)
        defer { cleanup([url]) }
        let payload = Data(#"{"path":"\#(url.path)","scale":2048}"#.utf8)
        let request = HelperRequest(id: "21", command: "image:preview", payload: payload)
        let line = try #require(String(data: HelperWire.encode(request), encoding: .utf8))
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(response.ok)
        let result = try HelperWire.decode(ImageCommands.DecodeResultPayload.self, from: try #require(response.payload))
        #expect(result.format == "jpeg")
        #expect(result.width <= 2048 && result.height <= 2048)
    }

    @Test func imageThumbnailUnsupportedExtensionReturnsError() {
        let payload = Data(#"{"path":"/tmp/foo.gif","scale":256}"#.utf8)
        let request = HelperRequest(id: "22", command: "image:thumbnail", payload: payload)
        let line = try! String(data: HelperWire.encode(request), encoding: .utf8)!
        let data = HelperProtocol.handleLine(line)!
        let response = try! HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.error?.contains("unsupported extension") == true)
    }

    @Test func imageThumbnailMissingFileReturnsError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-helper-missing-\(UUID().uuidString).jpg")
        let payload = Data(#"{"path":"\#(missing.path)","scale":256}"#.utf8)
        let request = HelperRequest(id: "23", command: "image:thumbnail", payload: payload)
        let line = try! String(data: HelperWire.encode(request), encoding: .utf8)!
        let data = HelperProtocol.handleLine(line)!
        let response = try! HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.id == "23")
        #expect(response.error != nil)
    }

    // MARK: - 测试图片工具

    /// 生成纯色 JPEG 文件（HelperProtocolTests 内复用，避免跨套件共享状态）。
    private func makeTestJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-helper-\(UUID().uuidString).jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError("CGContext failed") }
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError("makeImage failed") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestError("destination failed") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestError("finalize failed") }
        try (data as Data).write(to: url)
        return url
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private struct TestError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    // MARK: - 非法输入

    @Test func invalidJSONLineReturnsError() throws {
        let data = try #require(HelperProtocol.handleLine("this is not json"))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.id == "")
        #expect(response.payload == nil)
        #expect(response.error?.contains("invalid request JSON") == true)
    }

    @Test func invalidPayloadShapeReturnsError() throws {
        // payload 存在但不是字符串形态（对象/数字等），无法承载 Data，视为非法。
        let line = #"{"id":"6","command":"echo","payload":{"v":1}}"#
        let data = try #require(HelperProtocol.handleLine(line))
        let response = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(!response.ok)
        #expect(response.error?.contains("invalid request JSON") == true)
    }

    @Test func blankLineProducesNoResponse() {
        #expect(HelperProtocol.handleLine("") == nil)
        #expect(HelperProtocol.handleLine("   ") == nil)
    }
}
