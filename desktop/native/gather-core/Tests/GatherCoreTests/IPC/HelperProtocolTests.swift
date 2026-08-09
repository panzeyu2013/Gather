// desktop/native/gather-core/Tests/GatherCoreTests/IPC/HelperProtocolTests.swift
// 1.3 helper 线协议核心逻辑单测：echo 往返、未知命令、session:mock 往返、非法 JSON。

import Foundation
import Testing
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
