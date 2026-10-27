// desktop/native/gather-core/Tests/GatherCoreTests/Services/SettingsServiceTests.swift
// SettingsService 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/face-kw/face-settings.test.ts + settings.service.ts
// 行为契约（用例逐一对应，见文件末尾对照表）：
//   - 缓存语义：构造时全量灌入，get 只读缓存不回库
//   - set 白名单校验（未知 key 抛 Unknown setting key）
//   - getNumber parseFloat/NaN 回退
//   - getAll 默认值打底 + 缓存覆盖
//   - reset 恢复默认值（库 + 缓存）
//   - 默认值表 40 键规模与关键值

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

private struct Harness {
    let db: DBConnection
    let repo: SettingsRepo
    let service: SettingsService
}

private func makeHarness() throws -> Harness {
    let db = try makeTestDB()
    let repo = SettingsRepo(connection: db)
    let service = SettingsService(repo: repo)
    return Harness(db: db, repo: repo, service: service)
}

@Suite("SettingsService")
struct SettingsServiceTests {
    // TS: face-settings.test.ts "accepts face_decode_concurrency" —— 注册键可 set。
    @Test func setRegisteredKeyPersists() throws {
        let harness = try makeHarness()
        try harness.service.set("face_decode_concurrency", value: "6")
        #expect(harness.service.getNumber("face_decode_concurrency", defaultValue: 4) == 6)
        // 同时落库（repo.upsert 双写）。
        #expect(try harness.repo.get(key: "face_decode_concurrency")?.value == "6")
    }

    // TS: face-settings.test.ts "accepts face_inference_parallel_workers"。
    @Test func setParallelWorkers() throws {
        let harness = try makeHarness()
        try harness.service.set("face_inference_parallel_workers", value: "2")
        #expect(harness.service.getNumber("face_inference_parallel_workers", defaultValue: 1) == 2)
    }

    // TS: face-settings.test.ts "falls back to the default when not persisted"。
    @Test func getNumberFallsBackToDefault() throws {
        let harness = try makeHarness()
        #expect(harness.service.getNumber("face_decode_concurrency", defaultValue: 4) == 4)
    }

    // TS: face-settings.test.ts "includes the key in getAll()"。
    @Test func getAllIncludesDefaults() throws {
        let harness = try makeHarness()
        #expect(harness.service.getAll()["face_decode_concurrency"] == "4")
    }

    // TS: set 未知 key 抛 "Unknown setting key: <key>"。
    @Test func setUnknownKeyThrows() throws {
        let harness = try makeHarness()
        #expect(throws: (any Error).self) {
            try harness.service.set("no_such_key", value: "x")
        }
    }

    // TS: get 未命中 → defaultValue ?? ''。
    @Test func getFallsBackToDefaultOrEmpty() throws {
        let harness = try makeHarness()
        #expect(harness.service.get("no_such_key") == "")
        #expect(harness.service.get("no_such_key", defaultValue: "fallback") == "fallback")
    }

    // TS: getNumber NaN 回退默认值。
    @Test func getNumberNaNfallsBackToDefault() throws {
        let harness = try makeHarness()
        try harness.service.set("onnx_threads", value: "not-a-number")
        #expect(harness.service.getNumber("onnx_threads", defaultValue: 4) == 4)
    }

    // TS: getAll 默认值打底 + 缓存覆盖（set 后返回新值）。
    @Test func getAllMergesCacheOverDefaults() throws {
        let harness = try makeHarness()
        try harness.service.set("thumbnail_size", value: "2048")
        let all = harness.service.getAll()
        #expect(all["thumbnail_size"] == "2048")
        #expect(all["thumbnail_quality"] == "80")
    }

    // TS: reset 恢复默认值（库 + 缓存）。
    @Test func resetRestoresDefaults() throws {
        let harness = try makeHarness()
        try harness.service.set("thumbnail_size", value: "2048")
        try harness.service.set("ui_language", value: "en")
        try harness.service.reset()
        #expect(harness.service.get("thumbnail_size") == "1024")
        #expect(harness.service.get("ui_language") == "")
        // 库也恢复。
        #expect(try harness.repo.get(key: "thumbnail_size")?.value == "1024")
    }

    // TS: 默认值表规模与关键值对齐；删除 14 个无消费者的旧 Node 缓存/C1/防抖键后为 49，
    // 之后随 P0/P1 迭代增补至 52；2026-10-27 增加 metadata.applyBatches.corrupt
    // （仅作批次 JSON 解析失败的留证，无 UI 消费者）→ 53。
    // set 的键校验直接由此表派生，少一个键就意味着对应设置永远写不进去。
    @Test func defaultsMatchTS() {
        let defaults = SettingsService.getDefaults()
        #expect(defaults.count == 53)
        #expect(defaults["grid_default_sort"] == "import")
        #expect(defaults["grid_density"] == "m")
        #expect(defaults["triage_enabled"] == "0")
        #expect(defaults["triage_auto_generate"] == "0")
        #expect(defaults["triage_policy"] == "triage-v1")
        #expect(defaults["triage_reject_confidence_min"] == "0.75")
        #expect(defaults["triage_min_executable_confidence"] == "0.55")
        #expect(defaults["face_core_quality"] == "0.35")
        #expect(defaults["face_core_retry_min_samples"] == "2")
        #expect(defaults["face_match_margin"] == "0.01")
        // 增量聚类默认开（"1"；界面下拉的推荐项同值）。
        #expect(defaults["face_incremental_clustering"] == "1")
        // 嵌入模型键默认空 = 内置 Vision 特征（不强制用户准备模型文件）。
        #expect(defaults["face_embedding_model_path"] == "")
        #expect(defaults["face_embedding_model_version"] == "")
        #expect(defaults["lazy_checksum"] == "true")
        #expect(defaults["db_synchronous"] == "normal")
        #expect(defaults["metadata_write_mode"] == "sidecar")
        #expect(defaults["ui_language"] == "")
    }

    // TS: 已知键白名单与默认值表键一一对应。
    @Test func knownKeysDeriveFromDefaults() {
        #expect(SettingsService.knownSettingKeys == Set(SettingsService.getDefaults().keys))
    }

    // TS: 缓存不回库语义 —— set 后直接改库，get 仍返回缓存旧值。
    @Test func cacheIsReadOnlyAfterLoad() throws {
        let harness = try makeHarness()
        try harness.service.set("thumbnail_size", value: "1024")
        // 绕过服务直接改库。
        try harness.repo.upsert(key: "thumbnail_size", value: "9999")
        // 服务缓存仍持有旧值（构造后永不回库读）。
        #expect(harness.service.get("thumbnail_size") == "1024")
        // 新实例重新加载看到库值。
        let fresh = SettingsService(repo: harness.repo)
        #expect(fresh.get("thumbnail_size") == "9999")
    }
}

// TS↔Swift 用例对照：
// - face-settings.test.ts（4 用例）→ setRegisteredKeyPersists /
//   setParallelWorkers / getNumberFallsBackToDefault / getAllIncludesDefaults
// - settings.service.ts 行为补充（本文件新增）→ setUnknownKeyThrows /
//   getFallsBackToDefaultOrEmpty / getNumberNaN / getAllMergesCacheOverDefaults /
//   resetRestoresDefaults / defaultsMatchTS / thumbnailConcurrencyClamp /
//   knownKeysDeriveFromDefaults / cacheIsReadOnlyAfterLoad
