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

    // P1-5：reset 只重置偏好，不删除用户内容（模板/配方/批次历史/备份目录）。
    @Test func resetPreservesUserContentKeys() throws {
        let harness = try makeHarness()
        try harness.service.set("metadata.templates", value: "[\"t1\"]")
        try harness.service.set("metadata.applyBatches", value: "[\"b1\"]")
        try harness.service.set("output.recipes", value: "[\"r1\"]")
        try harness.service.set("backup_dir", value: "/tmp/gather-backups")
        try harness.service.set("thumbnail_size", value: "2048")

        try harness.service.reset()

        #expect(harness.service.get("metadata.templates") == "[\"t1\"]")
        #expect(harness.service.get("metadata.applyBatches") == "[\"b1\"]")
        #expect(harness.service.get("output.recipes") == "[\"r1\"]")
        #expect(harness.service.get("backup_dir") == "/tmp/gather-backups")
        #expect(harness.service.get("thumbnail_size") == "1024",
                "偏好仍必须恢复默认")
    }

    @Test("previewReset 统计模板/批次/配方与偏好数量")
    func previewResetCountsUserContent() throws {
        let harness = try makeHarness()
        try harness.service.set("metadata.templates", value: "[{\"id\":\"t1\"},{\"id\":\"t2\"}]")
        try harness.service.set("metadata.applyBatches", value: "[{\"id\":\"b1\"}]")
        try harness.service.set("output.recipes", value: "[{\"id\":\"r1\"},{\"id\":\"r2\"},{\"id\":\"r3\"}]")
        let impact = harness.service.previewReset()
        #expect(impact.templateCount == 2)
        #expect(impact.batchCount == 1)
        #expect(impact.recipeCount == 3)
        #expect(impact.preferenceCount > 0)
    }

    @Test("分级 reset：偏好/用户内容/语言互不越界")
    func scopedResetSeparatesScopes() throws {
        let harness = try makeHarness()
        try harness.service.set("thumbnail_size", value: "2048")
        try harness.service.set("metadata.templates", value: "[\"t1\"]")
        try harness.service.set("ui_language", value: "en")
        try harness.service.set("watch.lastEventIDs", value: "{\"s1\":42}")

        // 只重置偏好：模板/语言/运行时游标保留（运行时游标按设计总是清理）。
        let pref = try harness.service.reset(input: SettingsResetInput(
            resetPreferences: true, resetUserContent: false, resetLanguage: false))
        #expect(harness.service.get("thumbnail_size") == "1024")
        #expect(harness.service.get("metadata.templates") == "[\"t1\"]")
        #expect(harness.service.get("ui_language") == "en")
        #expect(harness.service.get("watch.lastEventIDs") == "{}")
        #expect(pref.preservedKeys.contains("metadata.templates"))
        #expect(pref.resetKeys.contains("thumbnail_size"))

        // 只清用户内容 + 语言：偏好保持当前值（已是默认，先改回非默认验证）。
        try harness.service.set("thumbnail_size", value: "4096")
        _ = try harness.service.reset(input: SettingsResetInput(
            resetPreferences: false, resetUserContent: true, resetLanguage: true))
        #expect(harness.service.get("metadata.templates") == "[]")
        #expect(harness.service.get("ui_language") == "")
        #expect(harness.service.get("thumbnail_size") == "4096",
                "未勾选偏好时不得重置偏好")
    }

    @Test("reset scope 穷尽：每个 known key 恰属偏好/用户内容/运行时/语言之一")
    func resetScopeCoverage() throws {
        let keys = SettingsService.knownSettingKeys
        let user = SettingsService.userContentKeysPreservedOnReset
        let runtime = SettingsService.runtimeKeysResetAlways
        let language = SettingsService.languageKey
        #expect(user.isSubset(of: keys), "用户内容键必须都在默认值表里")
        #expect(runtime.isSubset(of: keys), "运行时键必须都在默认值表里")
        #expect(keys.contains(language))
        var explicitCount = 0
        for key in keys {
            // 每个 known key 必须有显式分类；新增键漏登记会直接 nil 失败。
            let scope = SettingsService.resetScope(for: key)
            #expect(scope != nil, "键 \(key) 没有 reset scope")
            if scope == .userContent || scope == .runtime || scope == .language {
                explicitCount += 1
            }
        }
        #expect(explicitCount == user.count + runtime.count + 1,
                "显式 scope 集合不能有重叠")
        #expect(SettingsService.resetScope(for: "unknown.key") == nil,
                "未知键不得静默落到偏好 scope")
    }

    // TS: 默认值表规模与关键值对齐；删除 14 个无消费者的旧 Node 缓存/C1/防抖键后为 49，
    // 之后随 P0/P1 迭代增补至 52；2026-10-27 增加 metadata.applyBatches.corrupt
    // （仅作批次 JSON 解析失败的留证，无 UI 消费者）→ 53；2026-10-28 增加
    // metadata.templates.corrupt（模板 JSON 损坏留证）→ 54。
    // P2 交付闭环再补 output.recipes / triage_* / metadata_write_mode 等 → 57；
    // 本轮补 output.deliveryRoot（交付目录记忆，避免每次手打绝对路径）→ 58。
    // set 的键校验直接由此表派生，少一个键就意味着对应设置永远写不进去。
    @Test func defaultsMatchTS() {
        let defaults = SettingsService.getDefaults()
        // #9：5 个幽灵键转正（import_concurrency / asset_read_mode / similarity_* 三个），
        // 默认值取其此前的调用点硬编码值（行为不变，只是从此可写）。
        #expect(defaults.count == 73)
        #expect(defaults["output.deliveryRoot"] == "")
        #expect(defaults["grid_default_sort"] == "import")
        #expect(defaults["grid_density"] == "m")
        #expect(defaults["triage_enabled"] == "0")
        #expect(defaults["triage_auto_generate"] == "0")
        // 2026-10-28 起默认 triage-v2（模型级初审）；v1 仍可在设置里选回。
        #expect(defaults["triage_policy"] == "triage-v2")
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
        #expect(defaults["metadata_write_mode"] == "auto")
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

@Suite("策略默认值")
struct TriagePolicyDefaultTests {
    @Test("空库 fromSettings 默认 triage-v2（与设置页一致）")
    func defaultsToV2() throws {
        let db = try makeTestDB()
        let service = SettingsService(repo: SettingsRepo(connection: db))
        let policy = TriagePolicy.fromSettings(service)
        #expect(policy.version == "triage-v2")
    }

    @Test("显式 v1 仍可切回")
    func explicitV1() throws {
        let db = try makeTestDB()
        let service = SettingsService(repo: SettingsRepo(connection: db))
        try service.set("triage_policy", value: "triage-v1")
        #expect(TriagePolicy.fromSettings(service).version == "triage-v1")
    }
}
