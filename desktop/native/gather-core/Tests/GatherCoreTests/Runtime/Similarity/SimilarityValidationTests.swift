// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityValidationTests.swift
// W2c 步骤 1：SimilarityValidation 纯函数测试（无数据库：最小输入 + 直接断言）。
//
// 语义对照旧 Services/SimilarityServiceTests.swift（W2c 完成后随之删除）：
// - rejects invalid threshold and minGroupSize（rejectsInvalid）
// - accepts the full dHash threshold range and a valid group size（acceptsValid）
// - collapses one representative per linked RAW/JPEG asset preferring RAW
//   （collapsePreferRaw —— 资产折叠仍由纯助手 PhotoAssets.collapse 承载，
//    SimilarityAssembler.ungrouped 消费同一入口）
// - analyze rejects a corrupt settings value instead of crashing
//   （analyzeSurvivesNanSettings → 纯函数版：getNumber 注入 NaN）
// - maps every case to its TS error code（mapsToGatherCodes → 新增 description 文案）
// 其余为搬移后补充的解析边界守护（显式默认值 / 整数化 / 顺序）。

import Foundation
import Testing
@testable import GatherCore

@Suite("SimilarityValidation")
struct SimilarityValidationTests {

    // MARK: 参数校验（旧 rejectsInvalid / acceptsValid）

    @Test("rejects invalid threshold and minGroupSize")
    func rejectsInvalid() {
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.validate(threshold: -1, minGroupSize: 2)
        }
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.validate(threshold: 65, minGroupSize: 2)
        }
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.validate(threshold: 10.5, minGroupSize: 2)
        }
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.validate(threshold: .nan, minGroupSize: 2)
        }
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.validate(threshold: .infinity, minGroupSize: 2)
        }
        #expect(throws: SimilarityError.minGroupInvalid) {
            try SimilarityValidation.validate(threshold: 10, minGroupSize: 1)
        }
        #expect(throws: SimilarityError.minGroupInvalid) {
            try SimilarityValidation.validate(threshold: 10, minGroupSize: 2.5)
        }
        #expect(throws: SimilarityError.minGroupInvalid) {
            try SimilarityValidation.validate(threshold: 10, minGroupSize: .infinity)
        }
    }

    @Test("accepts the full dHash threshold range and a valid group size")
    func acceptsValid() {
        #expect(throws: Never.self) { try SimilarityValidation.validate(threshold: 0, minGroupSize: 2) }
        #expect(throws: Never.self) { try SimilarityValidation.validate(threshold: 64, minGroupSize: 10) }
        // 整数化 Double（TS Number.isInteger(10.0) === true）。
        #expect(throws: Never.self) { try SimilarityValidation.validate(threshold: 10.0, minGroupSize: 2.0) }
    }

    // MARK: 参数解析（旧 analyze 开头 196-202 行）

    @Test("resolves nil parameters from the injected settings source")
    func resolvesFromSettings() throws {
        let params = try SimilarityValidation.resolved(
            threshold: nil,
            minGroupSize: nil,
            groupingMode: nil,
            getNumber: { key, defaultValue in
                switch key {
                case SimilarityValidation.defaultThresholdKey: return 12
                case SimilarityValidation.defaultMinGroupSizeKey: return 3
                default: return defaultValue
                }
            }
        )
        #expect(params.threshold == 12)
        #expect(params.minGroupSize == 3)
        #expect(params.groupingMode == .global)
    }

    @Test("uses the TS fallbacks when the settings source returns its defaults")
    func resolvesFallbacks() throws {
        let params = try SimilarityValidation.resolved(
            threshold: nil, minGroupSize: nil, groupingMode: nil,
            getNumber: { _, defaultValue in defaultValue }
        )
        #expect(params.threshold == 10)
        #expect(params.minGroupSize == 2)
        #expect(params.groupingMode == .global)
    }

    @Test("resolves explicit parameters and keeps the requested grouping mode")
    func resolvesExplicit() throws {
        let params = try SimilarityValidation.resolved(
            threshold: 6, minGroupSize: 4, groupingMode: .sequential,
            getNumber: { _, defaultValue in defaultValue }
        )
        #expect(params.threshold == 6)
        #expect(params.minGroupSize == 4)
        #expect(params.groupingMode == .sequential)
    }

    @Test("rejects a corrupt settings value instead of trapping")
    func rejectsCorruptSettings() {
        // TS：Number.isInteger(NaN) === false → SIM_THRESHOLD_INVALID；Swift
        // 同样抛错而非 Int(NaN) 崩溃（旧 analyzeSurvivesNanSettings 的纯函数版）。
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.resolved(
                threshold: nil, minGroupSize: nil, groupingMode: nil,
                getNumber: { key, _ in key == SimilarityValidation.defaultThresholdKey ? .nan : 2 }
            )
        }
        #expect(throws: SimilarityError.minGroupInvalid) {
            try SimilarityValidation.resolved(
                threshold: nil, minGroupSize: nil, groupingMode: nil,
                getNumber: { key, _ in key == SimilarityValidation.defaultThresholdKey ? 10 : .nan }
            )
        }
        #expect(throws: SimilarityError.thresholdInvalid) {
            try SimilarityValidation.resolved(
                threshold: nil, minGroupSize: nil, groupingMode: nil,
                getNumber: { key, _ in key == SimilarityValidation.defaultThresholdKey ? 10.5 : 2 }
            )
        }
    }

    @Test("integerizes validated Double parameters")
    func integerizesValidatedValues() throws {
        let params = try SimilarityValidation.resolved(
            threshold: 10.0, minGroupSize: 2.0, groupingMode: nil
        )
        #expect(params.threshold == 10)
        #expect(params.minGroupSize == 2)
    }

    // MARK: 资产折叠（旧 collapsePreferRaw）

    @Test("collapses one representative per linked RAW/JPEG asset preferring RAW")
    func collapsePreferRaw() {
        struct Candidate: PhotoAssetCandidate {
            let id: String
            let assetId: String?
            let filename: String
        }
        let rows: [Candidate] = [
            Candidate(id: "jpeg", assetId: "asset", filename: "A001.JPG"),
            Candidate(id: "raw", assetId: "asset", filename: "A001.NEF"),
            Candidate(id: "standalone", assetId: nil, filename: "A002.JPG"),
        ]

        let collapsed = PhotoAssets.collapse(rows)
        #expect(collapsed.map(\.id) == ["raw", "standalone"])
    }

    // MARK: 错误码 / 消息（旧 mapsToGatherCodes）

    @Test("maps every case to its TS error code and message")
    func mapsToGatherCodes() {
        #expect(SimilarityError.thresholdInvalid.gatherCode == .SIM_THRESHOLD_INVALID)
        #expect(SimilarityError.minGroupInvalid.gatherCode == .SIM_MIN_GROUP_INVALID)
        #expect(SimilarityError.analysisRunning.gatherCode == .SIM_ANALYSIS_RUNNING)
        #expect(SimilarityError.noPhotos.gatherCode == .SIM_NO_PHOTOS)
        #expect(SimilarityError.noHashData.gatherCode == .SIM_NO_HASH_DATA)
        #expect(SimilarityError.noResults.gatherCode == .SIM_NO_RESULTS)
        #expect(SimilarityError.noHashRecluster.gatherCode == .SIM_NO_HASH_RECLUSTER)

        // description 与旧 SimilarityServiceError 逐字一致（JobService 落库用）。
        #expect(SimilarityError.thresholdInvalid.description == "SIM_THRESHOLD_INVALID")
        #expect(SimilarityError.minGroupInvalid.description == "SIM_MIN_GROUP_INVALID")
        #expect(SimilarityError.analysisRunning.description == "SIM_ANALYSIS_RUNNING")
        #expect(SimilarityError.noPhotos.description == "SIM_NO_PHOTOS")
        #expect(SimilarityError.noHashData.description == "SIM_NO_HASH_DATA")
        #expect(SimilarityError.noResults.description == "SIM_NO_RESULTS")
        #expect(SimilarityError.noHashRecluster.description == "SIM_NO_HASH_RECLUSTER")
    }
}
