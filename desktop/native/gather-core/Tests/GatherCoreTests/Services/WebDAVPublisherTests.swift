// desktop/native/gather-core/Tests/GatherCoreTests/Services/WebDAVPublisherTests.swift
// WebDAV 发布：请求序列、已存在目录、瞬态重试、认证中止、Content-Type 与本地收集。

import Foundation
import Testing
@testable import GatherApplication

private actor FakeWebDAVTransport: WebDAVTransport {
    private(set) var requests: [WebDAVRequest] = []
    private var responses: [Result<WebDAVResponse, Error>]

    init(_ responses: [Result<WebDAVResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        requests.append(request)
        guard !responses.isEmpty else { return WebDAVResponse(status: 200) }
        let next = responses.removeFirst()
        switch next {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

private struct FakeTransportError: Error {}

@Suite("WebDAV 发布")
struct WebDAVPublisherTests {
    private func makeTree() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-webdav-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("b".utf8).write(to: root.appendingPathComponent("thumbs/0001.jpg"))
        return root.path
    }

    private func configuration() -> WebDAVConfiguration {
        WebDAVConfiguration(
            baseURL: URL(string: "https://dav.example.com/dav/")!,
            username: "alice", password: "secret", remoteFolder: "client/Wedding")
    }

    @Test("目录递归上传：MKCOL 一次 + 两个 PUT，带 Basic 认证头")
    func uploadsTree() async throws {
        let local = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: local) }
        // 逐级 MKCOL：base / client / Wedding / thumbs 各一次，再两个 PUT。
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
        ])
        let publisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let result = try await publisher.publish(
            localPath: local, configuration: configuration())
        #expect(result.isSuccess)
        #expect(result.uploaded == 2)
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests.filter { $0.method == .mkcol }.count == 4)
        #expect(requests.filter { $0.method == .put }.count == 2)
        #expect(requests.allSatisfy { $0.headers["Authorization"]?.hasPrefix("Basic ") == true })
        #expect(requests.last?.url.path.contains("thumbs/0001.jpg") == true)
        #expect(requests.first { $0.method == .put }?.headers["Content-Type"] == "text/html; charset=utf-8")
    }

    @Test("MKCOL 405（已存在）视为成功")
    func existingDirectoryIsSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-webdav-flat-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.jpg"))
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 405)),
            .success(WebDAVResponse(status: 204)),
        ])
        let publisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let result = try await publisher.publish(
            localPath: root.path, configuration: configuration())
        #expect(result.isSuccess)
        #expect(result.uploaded == 1)
    }

    @Test("瞬态 500 会重试，第二次成功")
    func retriesTransientFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-webdav-retry-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.jpg"))
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 201)),  // MKCOL base
            .success(WebDAVResponse(status: 201)),  // MKCOL client
            .success(WebDAVResponse(status: 201)),  // MKCOL Wedding
            .success(WebDAVResponse(status: 500)),  // PUT fail
            .success(WebDAVResponse(status: 201)),  // PUT retry ok
        ])
        let publisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let result = try await publisher.publish(
            localPath: root.path, configuration: configuration())
        #expect(result.isSuccess)
        #expect(result.uploaded == 1)
    }

    @Test("401 立即中止，不再继续上传")
    func abortsOnAuthFailure() async throws {
        let local = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: local) }
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 401)),
        ])
        let publisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let result = try await publisher.publish(
            localPath: local, configuration: configuration())
        #expect(result.abortedOnAuth)
        #expect(result.uploaded == 0)
        #expect(await transport.requests.count == 1, "认证失败后不得继续发请求")
    }

    @Test("本地路径不存在显式报错；Content-Type 映射")
    func validatesLocalPathAndContentTypes() async {
        let publisher = WebDAVPublisher(transport: FakeWebDAVTransport([]), sleep: { _ in })
        await #expect(throws: WebDAVError.self) {
            _ = try await publisher.publish(
                localPath: "/nope/missing", configuration: configuration())
        }
        #expect(WebDAVPublisher.contentType("a.jpg") == "image/jpeg")
        #expect(WebDAVPublisher.contentType("a.pdf") == "application/pdf")
        #expect(WebDAVPublisher.contentType("a.bin") == "application/octet-stream")
    }


    @Test("白名单前缀：只上传匹配的文件；无匹配显式报错")
    func includePrefixesFiltersFiles() async throws {
        let local = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: local) }
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
        ])
        let publisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let result = try await publisher.publish(
            localPath: local, configuration: configuration(), includePrefixes: ["thumbs"])
        #expect(result.uploaded == 1, "只应上传 thumbs/0001.jpg")
        let requests = await transport.requests
        #expect(requests.filter { $0.method == .put }.count == 1)
        #expect(requests.last?.url.path.contains("thumbs/0001.jpg") == true)

        let emptyTransport = FakeWebDAVTransport([])
        let emptyPublisher = WebDAVPublisher(transport: emptyTransport, sleep: { _ in })
        await #expect(throws: WebDAVError.self) {
            _ = try await emptyPublisher.publish(
                localPath: local, configuration: configuration(),
                includePrefixes: ["no-such-dir"])
        }
    }
}
