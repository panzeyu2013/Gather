// desktop/native/gather-app/Tests/GatherAppTests/AppCompositionTests.swift
// Cut 1 / B8.3b-2a/B8.3b-2b：组合根契约。
//
// 覆盖：
// 1. AppComposition.make 只构造一套服务（db / runtime / 服务指针）；
// 2. AppServices.live(composition:) 复用 composition 的 runtime 与服务；
// 3. runtime 生命周期：start 注册 8 个 executor，shutdown 关闭 SQLite。
//
// B8.4：字符串命令面、AppServices.live(router:) 与测试专用 命令面工厂均已删除。
//
// 夹具用内存 SQLite + 真实 GatherCore 服务（与生产组合根等价），
// 不触网、不读写真实 Application Support。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具

private struct CompositionFixture {
    let db: DBConnection
    let composition: AppComposition
    let services: AppServices

    init() throws {
        let db = try makeGatherTestDB()
        let composition = AppComposition.make(db: db)
        let services = AppServices.live(composition: composition)
        self.db = db
        self.composition = composition
        self.services = services
    }

    /// 无论断言成功/抛错都走一次幂等停机，避免 coordinator 计时器泄漏。
    func shutdown() async {
        await composition.runtime.shutdown()
    }
}

private func withCompositionFixture(
    _ body: (CompositionFixture) async throws -> Void
) async throws {
    let fixture = try CompositionFixture()
    do {
        try await body(fixture)
        await fixture.shutdown()
    } catch {
        await fixture.shutdown()
        throw error
    }
}

// MARK: - 用例

@Suite("B8.3b-2a AppComposition")
struct AppCompositionTests {
    @Test("组合根只建一套服务：db / runtime 与 composition 同指针")
    func compositionOwnsSingleServiceGraph() async throws {
        try await withCompositionFixture { fixture in
            let composition = fixture.composition
            #expect(composition.db === fixture.db)
            #expect(composition.runtime.db === composition.db)
            #expect(composition.runtime.jobService === composition.jobService)
        }
    }

    @Test("S5c-2b-3b-2b-2：组合根不再构造 MetadataSyncCoordinator，手动队列落 deliveries")
    func compositionDropsLegacyMetadataCoordinator() async throws {
        try await withCompositionFixture { fixture in
            let composition = fixture.composition
            let sessionRepo = SessionRepo(connection: fixture.db)
            let session = try sessionRepo.create(name: "2b-2 manual", source: "test")
            let photoRepo = PhotoRepo(connection: fixture.db)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gather-2b2-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let photoPath = root.appendingPathComponent("IMG_1.jpg").path
            try Data("x".utf8).write(to: URL(fileURLWithPath: photoPath))
            let photoId = try #require(
                try photoRepo.addPhotos(
                    sessionId: session.id,
                    filepaths: [PhotoAddInput(filepath: photoPath, width: 10, height: 10)],
                    "test"
                ).ids.first
            )

            // 手动 rating/label 只落交付模型（旧 metadata_outbox 已随表删除）。
            _ = try composition.metadataMutationService.queuePhotoValues(
                sessionId: session.id,
                photoId: photoId,
                values: ["rating": .number(4), "label": .string("Green")],
                source: .manual,
                schedule: true
            )

            let deliveryRepo = composition.deliveryRepo
            let xmpPath = TSPath.normalize(TSPath.xmpSidecarPath(photoPath))
            let delivery = try #require(try deliveryRepo.get(xmpPath))
            #expect(delivery.typedStatus == .pending)
            let item = try #require(try deliveryRepo.item(
                xmpPath: xmpPath, photoId: photoId, module: .metadata))
            #expect(item.attributes["rating"] == .number(4))
            #expect(item.attributes["label"] == .string("Green"))
            #expect(item.typedStatus == .pending)

            // LiveMetadataAPI 也不再回读 outbox：无冲突时返回空列表。
            let conflicts = try await fixture.services.metadata.conflicts(session.id)
            #expect(conflicts.isEmpty)
            let orphans = try await fixture.services.metadata.orphans()
            #expect(orphans.isEmpty)
        }
    }

    @Test("AppServices 与组合根共用 runtime")
    func appServicesUsesCompositionRuntime() async throws {
        try await withCompositionFixture { fixture in
            #expect(fixture.services.runtime === fixture.composition.runtime)
        }
    }

    @Test("AppServices.live(composition:) 不重建服务：设置缓存与 JobService 同实例")
    func appServicesWrapsCompositionServices() async throws {
        try await withCompositionFixture { fixture in
            // 若 AppServices 内部 new 了第二个 SettingsService，它的缓存会停在
            // 构造时的默认值（1024），而这里写入的是组合根那一个实例的缓存。
            try await fixture.services.settings.set(
                SettingsSetInput(key: "thumbnail_size", value: "512"))
            #expect(fixture.composition.settingsService.get("thumbnail_size") == "512")

            let job = try fixture.composition.jobService.create(JobCreateParams(
                type: .thumbnailBuild,
                scopeType: "session",
                scopeId: "b8.3b-2a-single-graph",
                dedupeKey: "b8.3b-2a:\(UUID().uuidString)",
                checkpoint: ["paths": .array([]), "size": .number(128)]
            ))
            let listed = try await fixture.services.job.list(JobListFilter(includeCheckpoint: false))
            #expect(listed.contains { $0.id == job.id })
        }
    }

    @Test("composition runtime：start 注册 8 个 executor，shutdown 关闭 SQLite")
    func compositionRuntimeLifecycle() async throws {
        try await withCompositionFixture { fixture in
            let types = try fixture.composition.runtime.start()
            #expect(types.count == 8)
            #expect(Set(types) == Set(AnalysisJobType.allCases))
            #expect(!fixture.db.isClosed)

            await fixture.composition.runtime.shutdown()
            #expect(fixture.db.isClosed)

            // 幂等：夹具收尾再调用一次不会重复 stop/close。
            await fixture.shutdown()
            #expect(fixture.db.isClosed)
        }
    }
}
