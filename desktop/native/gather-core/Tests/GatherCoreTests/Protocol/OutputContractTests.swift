// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/OutputContractTests.swift
// 新增 IPC 契约面（W3 整套交付 / 模型初审 / 写目标）的形状守卫。
//
// 背景（合并后评审 P1）：protocol-surface 只数 public 行数，改字段名/类型不会变红；
// 这三份类型是跨进程契约（执行器写 checkpoint、UI 读 checkpoint、宿主按 target 路由写盘），
// 冻结它们是和 GatherErrorCode 清单同一类要求。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherApplication
@testable import GatherDelivery

@Suite("写目标 / 交付 / 模型初审契约")
struct OutputContractTests {
    // MARK: - 写目标

    @Test func metadataTargetKindRawValuesAreFrozen() {
        // 落库（deliveries.target_kind）与 checkpoint 都用 rawValue；改名等于破坏兼容。
        #expect(MetadataTargetKind.sidecar.rawValue == "sidecar")
        #expect(MetadataTargetKind.embedded.rawValue == "embedded")
        #expect(MetadataTargetKind.allCases.count == 2)
    }

    @Test func metadataTargetPolicyTable() {
        // 非 JPEG 一律 sidecar（v1 只做 JPEG 内嵌）。
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.ARW", mode: "embedded", sidecarExists: false, isJPEG: false) == .sidecar)
        // 盘上已有 .xmp 时即使模式为 embedded 也走 sidecar（避免两个真相源）。
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "embedded", sidecarExists: true, isJPEG: true) == .sidecar)
        // 无 sidecar 的独立 JPEG 按模式走内嵌。
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "auto", sidecarExists: false, isJPEG: true) == .embedded)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.JPG", mode: "embedded", sidecarExists: false, isJPEG: true) == .embedded)
        // 显式 sidecar 与未知模式都保守回落 sidecar。
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "sidecar", sidecarExists: false, isJPEG: true) == .sidecar)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "garbage", sidecarExists: false, isJPEG: true) == .sidecar)
        #expect(MetadataTargetPolicy.isJPEG("/a.JPEG"))
        #expect(!MetadataTargetPolicy.isJPEG("/a.tif"))
    }

    // MARK: - 错误码必须来自枚举

    @Test func outputAndWebDAVCodesAreRegistered() {
        // P1 回归：这两个域枚举曾用裸字面量拼码，改一个字符没有任何门禁能拦。
        let registered = Set(GatherErrorCode.allCases)
        let cases: [GatherErrorCode] = [
            OutputServiceError.noRecipes.code,
            OutputServiceError.invalidRoot("/r").code,
            OutputServiceError.invalidDestination("/d").code,
            OutputServiceError.recipeConflict("x").code,
            OutputServiceError.manifestFailed("m").code,
            WebDAVError.invalidBaseURL("u").code,
            WebDAVError.localPathMissing("/p").code,
            WebDAVError.noMatchingFiles.code,
        ]
        for code in cases {
            #expect(registered.contains(code), "\(code.rawValue) 必须在 GatherErrorCode 内")
        }
        // 文案前缀必须与码一致（UI 靠 "CODE: detail" 形态解析插值）。
        #expect(OutputServiceError.invalidRoot("/r").description == "OUTPUT_ROOT_INVALID: /r")
        #expect(WebDAVError.noMatchingFiles.description == "WEBDAV_NO_MATCHING_FILES")
    }

    // MARK: - Codable 往返（跨进程 JSON）

    @Test func modelReviewResultRoundTrip() throws {
        let result = ModelReviewResult(
            photoId: "p1",
            assetFileId: "af1",
            status: .succeeded,
            errorMessage: nil,
            eyesOpenScore: 0.5,
            smileScore: 0.25,
            faceFocusScore: 0.75,
            aestheticScore: 0.6,
            isUtilityImage: false,
            faces: [],
            warnings: ["w"],
            modelId: "m",
            modelVersion: "1",
            inputFingerprint: "fp",
            updatedAt: "2026-10-28T00:00:00Z")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ModelReviewResult.self, from: data)
        #expect(decoded == result)
    }

    @Test func outputRecipeRoundTrip() throws {
        let recipe = OutputRecipe(
            id: "r1",
            name: "Web 2048",
            format: .jpeg,
            quality: 80,
            maxDimension: 2048,
            naming: ExportNaming(pattern: "{recipe}"),
            includeXmp: true,
            destination: "",
            artifacts: [.photos])
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(OutputRecipe.self, from: data)
        #expect(decoded == recipe)
        #expect(OutputArtifactKind.allCases.count >= 2)
    }
}
