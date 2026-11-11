// desktop/native/gather-core/Tests/GatherCoreTests/Services/OutputShareProofPageTests.swift
// Wave4c（task-47）：legacy share=nil 发布 × 新 proof.js fail-closed 回归。
//
// 覆盖：GalleryBuilder 默认标记 data-gather-expect-share="0"；严格发布（share != nil）
// 时 WebDAV/S3 上传的 proof.html 标记被改成 "1"，legacy 发布保持 "0"；标记注入只
// 命中 proof.html。

import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol

private actor ProofMarkerWebDAVTransport: WebDAVTransport {
    private(set) var requests: [WebDAVRequest] = []

    func send(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        requests.append(request)
        return WebDAVResponse(status: 200)
    }
}

private actor ProofMarkerS3Transport: S3HTTPTransport {
    private(set) var requests: [S3HTTPRequest] = []

    func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
        requests.append(request)
        return S3HTTPResponse(status: 200)
    }
}

@Suite("分享校样页标记（legacy × fail-closed）")
struct OutputShareProofPageTests {
    private let proofHTML = #"<html lang="zh" data-gather-expect-share="0"><body>proof</body></html>"#

    private func makeTree() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-proof-marker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("gallery"), withIntermediateDirectories: true)
        try Data(proofHTML.utf8).write(
            to: root.appendingPathComponent("gallery/proof.html"))
        try Data("index".utf8).write(
            to: root.appendingPathComponent("gallery/index.html"))
        return root.path
    }

    @Test("标记注入只命中 proof.html：0→1；其他文件/无标记/坏编码原样")
    func markingOnlyProofPage() throws {
        let marked = OutputShareProofPage.declaringSharePolicy(
            Data(proofHTML.utf8), relativePath: "gallery/proof.html")
        let markedText = try #require(String(data: marked, encoding: .utf8))
        #expect(markedText.contains(#"data-gather-expect-share="1""#))
        #expect(!markedText.contains(#"data-gather-expect-share="0""#))

        let indexData = Data("index".utf8)
        #expect(OutputShareProofPage.declaringSharePolicy(
            indexData, relativePath: "gallery/index.html") == indexData)

        let oldProof = Data(#"<html><body>old</body></html>"#.utf8)
        #expect(OutputShareProofPage.declaringSharePolicy(
            oldProof, relativePath: "gallery/proof.html") == oldProof)

        let invalid = Data([0xFF, 0xFE])
        #expect(OutputShareProofPage.declaringSharePolicy(
            invalid, relativePath: "gallery/proof.html") == invalid)
    }

    @Test("WebDAV：严格发布改标记为 1；legacy（share=nil）保持 0 且无 share.json")
    func webDAVLegacyVsStrictMarker() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        let configuration = WebDAVConfiguration(
            baseURL: URL(string: "https://dav.example.com/dav/")!,
            username: "u", password: "p", remoteFolder: "client")
        let strictTransport = ProofMarkerWebDAVTransport()
        let strictPublisher = WebDAVPublisher(transport: strictTransport, sleep: { _ in })
        _ = try await strictPublisher.publish(
            localPath: tree, configuration: configuration,
            includePrefixes: ["gallery"],
            share: OutputShareOptions(allowDownload: false))
        let strictRequests = await strictTransport.requests
        let strictProof = try #require(strictRequests.first {
            $0.method == .put && $0.url.path.hasSuffix("proof.html")
        })
        let strictBody = try #require(strictProof.body.flatMap {
            String(data: $0, encoding: .utf8)
        })
        #expect(strictBody.contains(#"data-gather-expect-share="1""#))
        #expect(strictRequests.contains {
            $0.method == .put && $0.url.path.hasSuffix("share.json")
        })

        let legacyTransport = ProofMarkerWebDAVTransport()
        let legacyPublisher = WebDAVPublisher(transport: legacyTransport, sleep: { _ in })
        _ = try await legacyPublisher.publish(
            localPath: tree, configuration: configuration,
            includePrefixes: ["gallery"])
        let legacyRequests = await legacyTransport.requests
        let legacyProof = try #require(legacyRequests.first {
            $0.method == .put && $0.url.path.hasSuffix("proof.html")
        })
        let legacyBody = try #require(legacyProof.body.flatMap {
            String(data: $0, encoding: .utf8)
        })
        #expect(legacyBody.contains(#"data-gather-expect-share="0""#),
                "legacy 发布不能声明分享策略（否则新 proof.js 会锁死无 share.json 页面）")
        #expect(!legacyRequests.contains {
            $0.method == .put && $0.url.path.hasSuffix("share.json")
        })
    }

    @Test("S3：严格发布改标记为 1；legacy（share=nil）保持 0 且无 share.json")
    func s3LegacyVsStrictMarker() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        func request(share: OutputShareOptions?) -> OutputSharePublishRequest {
            OutputSharePublishRequest(
                localPath: tree, transport: .s3, endpoint: "https://s3.example.com",
                accessKeyID: "AK", secret: "SK", remoteFolder: "p",
                bucket: "photos", region: "us-east-1",
                includePrefixes: ["gallery"], share: share)
        }
        let strictTransport = ProofMarkerS3Transport()
        let strictPublisher = S3ShareTransport(transport: strictTransport, sleep: { _ in })
        _ = try await strictPublisher.publish(
            request(share: OutputShareOptions(allowDownload: false)), onProgress: nil)
        let strictRequests = await strictTransport.requests
        let strictProof = try #require(strictRequests.first {
            $0.method == "PUT" && $0.url.path.hasSuffix("proof.html")
        })
        let strictBody = try #require(strictProof.body.flatMap {
            String(data: $0, encoding: .utf8)
        })
        #expect(strictBody.contains(#"data-gather-expect-share="1""#))
        #expect(strictRequests.contains {
            $0.method == "PUT" && $0.url.path.hasSuffix("share.json")
        })

        let legacyTransport = ProofMarkerS3Transport()
        let legacyPublisher = S3ShareTransport(transport: legacyTransport, sleep: { _ in })
        _ = try await legacyPublisher.publish(
            request(share: nil), onProgress: nil)
        let legacyRequests = await legacyTransport.requests
        let legacyProof = try #require(legacyRequests.first {
            $0.method == "PUT" && $0.url.path.hasSuffix("proof.html")
        })
        let legacyBody = try #require(legacyProof.body.flatMap {
            String(data: $0, encoding: .utf8)
        })
        #expect(legacyBody.contains(#"data-gather-expect-share="0""#))
        #expect(!legacyRequests.contains {
            $0.method == "PUT" && $0.url.path.hasSuffix("share.json")
        })
    }
}
