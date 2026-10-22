// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/template.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct TemplateContractTests {

    private static let sampleConfig = WorkflowTemplateConfig(
        similarity: WorkflowTemplateSimilarity(threshold: 0.8, minGroupSize: 3),
        face: WorkflowTemplateFace(eps: 0.4, minSamples: 5, detectorConfidence: 0.9),
        faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.72),
        duplicate: WorkflowTemplateDuplicate(enabled: false, visualThreshold: 0.95),
        writeback: WorkflowTemplateWriteback(
            createAlbums: true, addPrefix: false, markUngrouped: true, writeIPTC: true
        )
    )

    // MARK: - WorkflowTemplateConfig

    @Test func workflowTemplateConfigRoundTripAndKeys() throws {
        let data = try JSONEncoder().encode(Self.sampleConfig)
        let decoded = try JSONDecoder().decode(WorkflowTemplateConfig.self, from: data)
        #expect(decoded == Self.sampleConfig)

        let expected = ["similarity", "face", "faceLibrary", "duplicate", "writeback"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "WorkflowTemplateConfig JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("face_library"))
    }

    @Test func workflowTemplateConfigNestedKeys() throws {
        let object = try jsonObject(of: JSONEncoder().encode(Self.sampleConfig))

        let similarity = try #require(object["similarity"] as? [String: Any])
        #expect(Set(similarity.keys) == ["threshold", "minGroupSize"])

        let face = try #require(object["face"] as? [String: Any])
        #expect(Set(face.keys) == ["eps", "minSamples", "detectorConfidence"])

        let faceLibrary = try #require(object["faceLibrary"] as? [String: Any])
        #expect(Set(faceLibrary.keys) == ["enabled", "matchThreshold"])

        let duplicate = try #require(object["duplicate"] as? [String: Any])
        #expect(Set(duplicate.keys) == ["enabled", "visualThreshold"])

        let writeback = try #require(object["writeback"] as? [String: Any])
        #expect(Set(writeback.keys) == ["createAlbums", "addPrefix", "markUngrouped", "writeIPTC"])
    }

    // MARK: - TemplateData

    @Test func templateDataRoundTripAndKeys() throws {
        let original = TemplateData(
            id: "tpl_1", name: "街头默认", description: "d",
            config: Self.sampleConfig,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-02T00:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TemplateData.self, from: data)
        #expect(decoded == original)

        let expected = ["id", "name", "description", "config", "createdAt", "updatedAt"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected))
        #expect(!Set(try jsonKeys(of: data)).contains("created_at"))
    }

    // MARK: - Params

    @Test func templateCreateParamsRoundTrip() throws {
        let params = TemplateCreateParams(name: "街头默认", description: "d", config: Self.sampleConfig)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(TemplateCreateParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["name", "description", "config"])
    }

    @Test func templateUpdateParamsOptionality() throws {
        let full = TemplateUpdateParams(
            templateId: "tpl_1", name: "新名字", description: "d2", config: Self.sampleConfig
        )
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["templateId", "name", "description", "config"])

        let minimal = TemplateUpdateParams(templateId: "tpl_1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["templateId"], "未设置的 TS 可选字段必须省略")
    }
    private func jsonKeys(of data: Data) throws -> [String] {
        Array(try jsonObject(of: data).keys)
    }

    private func jsonObject(of data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return object
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
