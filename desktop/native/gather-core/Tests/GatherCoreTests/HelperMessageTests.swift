// desktop/native/gather-core/Tests/GatherCoreTests/HelperMessageTests.swift
// 线协议编解码对账测试。注：本机为 CLT-only 环境（无 Xcode/XCTest），
// 测试框架使用 Swift Testing（`import Testing`），语义与原 XCTest 版本一致。

import Foundation
import Testing
@testable import GatherCore

struct HelperMessageTests {
    @Test func requestRoundTrip() throws {
        let request = HelperRequest(id: "abc", command: "image.decode", payload: Data([1, 2, 3]))
        let data = try HelperWire.encode(request)
        let decoded = try HelperWire.decode(HelperRequest.self, from: data)
        #expect(decoded == request)
    }

    @Test func responseRoundTrip() throws {
        let response = HelperResponse(id: "abc", ok: false, error: "decode failed")
        let data = try HelperWire.encode(response)
        let decoded = try HelperWire.decode(HelperResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test func nilOptionalFieldsRoundTrip() throws {
        let request = HelperRequest(id: "1", command: "ping")
        let data = try HelperWire.encode(request)
        let decoded = try HelperWire.decode(HelperRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.payload == nil)
    }

    @Test func nilFieldsAreOmittedFromJSON() throws {
        let response = HelperResponse(id: "1", ok: true)
        let json = String(data: try HelperWire.encode(response), encoding: .utf8) ?? ""
        #expect(!json.contains("payload"))
        #expect(!json.contains("error"))
    }
}
