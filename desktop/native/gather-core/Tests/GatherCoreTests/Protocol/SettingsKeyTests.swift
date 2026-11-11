// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SettingsKeyTests.swift
// #9：类型化设置键的回归。
//
// 迁移的硬约束是「纯重构、不改任何默认值」：枚举的 defaultValue 必须与迁移前
// SettingsService.getDefaults() 的 68 项逐字一致。默认值一旦漂移，未设置的键
// 会悄悄换行为（例如 default_eps 0.65 vs 调用点 0.6 会让聚类阈值变宽）。
//
// 因此这里把迁移前的那张表原文抄下来当 oracle：它可以被删除，但不能被修改——
// 要改默认值，必须同时改这条用例并在 PR 里点名行为变更。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherApplication

@Suite("SettingsKey（类型化设置键）")
struct SettingsKeyTests {
    /// 迁移前 SettingsService.getDefaults() 的逐字快照（oracle，不随实现改）。
    private static let legacyDefaults: [String: String] = [
        "detector_model_path": "models/face_detector.onnx",
        "encoder_model_path": "models/face_encoder.onnx",
        "detect_confidence": "0.5",
        "detect_input_size": "640",
        "detect_secondary_input_size": "128",
        "face_preview_max_dimension": "2048",
        "encoder_input_size": "112",
        "embedding_dim": "128",
        "face_compute_units": "auto",
        "default_eps": "0.65",
        "default_min_samples": "2",
        "face_core_quality": "0.35",
        "face_core_retry_min_samples": "2",
        "face_match_margin": "0.01",
        "face_review_cohesion_floor": "0.35",
        "face_review_relative_mad": "2.5",
        "face_review_min_quality": "0.35",
        "face_review_face_size_min": "48",
        "face_incremental_clustering": "1",
        "face_embedding_model_path": "",
        "face_embedding_model_version": "",
        "nms_threshold": "0.4",
        "max_detections": "100",
        "onnx_threads": "4",
        "default_threshold": "10",
        "default_min_group_size": "2",
        "model_download_url": "",
        "thumbnail_size": "1024",
        "thumbnail_quality": "80",
        "disk_cache_dir": "",
        "face_decode_concurrency": "4",
        "face_inference_parallel_workers": "1",
        "db_cache_size_mb": "64",
        "db_synchronous": "normal",
        "metadata_write_mode": "auto",
        "ui_language": "",
        "lazy_checksum": "true",
        "grid_default_sort": "import",
        "grid_density": "m",
        "triage_enabled": "0",
        "output.recipes": "",
        "output.deliveryRoot": "",
        "triage_model_review": "1",
        "triage_auto_apply": "0",
        "triage_auto_generate": "0",
        "triage_policy": "triage-v2",
        "triage_keep_confidence_min": "0.60",
        "triage_reject_confidence_min": "0.75",
        "triage_min_executable_confidence": "0.55",
        "metadata.templates": "[]",
        "metadata.templates.corrupt": "",
        "metadata.applyBatches": "[]",
        "metadata.applyBatches.corrupt": "",
        "watch.lastEventIDs": "{}",
        "backup_dir": "",
        "backup_retention": "5",
        "backup_auto": "off",
        "diagnostics_include_paths": "0",
        "metadata_backup_retention_days": "7",
        "metadata_sync_auto_confirm": "1",
        "metadata_sync_auto_finalize": "0",
        "embedded_fast_path": "1",
        "keyword_dc_style": "leaf",
        "gallery_saved_search_limit": "50",
        "proof_feedback_apply_rating": "0",
        "c1_auto_reload": "1",
        "triage_calibration_min_samples": "50",
        "semantic_index_enabled": "0",
        // Wave3 / task-21：导出后命令钩子（新键，oracle 追加；不改旧键默认值）。
        "export_post_command": "",
        "export_post_command_timeout_seconds": "30",
        // #9 转正的幽灵键（此前不在默认表里，永远读调用点硬编码默认值）。
        "import_concurrency": "8",
        "asset_read_mode": "dual",
        "similarity_cluster_convergence_interval": "10",
        "similarity_decode_concurrency": "4",
        "similarity_preview_max_dimension": "256",
    ]

    @Test("枚举键集合与历史默认值表完全一致")
    func coversLegacyTable() {
        let rawValues = Set(SettingsKey.allCases.map(\.rawValue))
        #expect(rawValues == Set(Self.legacyDefaults.keys))
        #expect(SettingsKey.allCases.count == Self.legacyDefaults.count)
    }

    @Test("每个键的默认值与历史表逐字一致")
    func defaultsMatchLegacyTable() {
        for (raw, expected) in Self.legacyDefaults {
            guard let key = SettingsKey(rawValue: raw) else {
                Issue.record("枚举缺少键 \(raw)")
                continue
            }
            #expect(key.defaultValue == expected, "key=\(raw) 默认值漂移")
        }
    }

    @Test("SettingsService.getDefaults() 与枚举同源")
    func serviceDefaultsDerivedFromEnum() {
        let derived = Dictionary(
            uniqueKeysWithValues: SettingsKey.allCases.map { ($0.rawValue, $0.defaultValue) })
        #expect(SettingsService.getDefaults() == derived)
        #expect(SettingsService.knownSettingKeys == Set(derived.keys))
    }

    @Test("SettingsReading：未命中回默认值、非有限值不 trap、布尔方言兼容")
    func readingSemantics() {
        let empty = ClosureSettingsReader { _ in nil }
        #expect(empty.string(.dbSynchronous) == "normal")
        #expect(empty.int(.dbCacheSizeMB) == 64)
        #expect(empty.double(.defaultEps) == 0.65)
        #expect(empty.bool(.triageEnabled) == false)
        // bool 严格只认 "1"（仓里有测试钉住「非 1 视为关闭」）；"true"/"false" 方言的键
        // （lazy_checksum）自己用 string 比较，不共用这个折叠。
        #expect(empty.bool(.lazyChecksum) == false)
        #expect(empty.string(.lazyChecksum) == "true")

        let broken = ClosureSettingsReader { key in
            switch key {
            case .detectInputSize: return "1e999"
            case .dbCacheSizeMB: return "abc"
            case .triageEnabled: return "1"
            case .lazyChecksum: return "false"
            default: return nil
            }
        }
        #expect(broken.int(.detectInputSize) == 640, "非有限值必须回落默认，否则 Int(Double) 会 trap")
        #expect(broken.int(.dbCacheSizeMB) == 64)
        #expect(broken.bool(.triageEnabled))
        #expect(!broken.bool(.lazyChecksum))
        #expect(broken.string(.lazyChecksum) == "false")
    }
}
