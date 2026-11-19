// desktop/native/gather-core/Tests/GatherCoreTests/Services/Wave5FakeAssemblyTests.swift
// Wave 5 / M8：全 fake 装配冒烟。
//
// 目标：不打开 DBConnection、不创建临时 SQLite，仅用内存 fake 端口构造 >=3 个
// Application 服务，断言服务的公开行为确实经端口（fake 记录的调用/入参）而不是触库。
// 这样端口漂移（服务绕过端口直接摸 DB）会在不碰磁盘的前提下暴露为「fake 没被调用」。
//
// 覆盖服务：SettingsService(1 依赖) / NavigationService(1 依赖) / QualityService(2 依赖)
// ——都是构造依赖最少的公开 Application 服务；其余 fake（DeliveryReadStore /
// MetadataKeywordReading / MetadataDeliveryReading / DeliverySummaryReading /
// CullingDecisionLiteReading）只做替身记录，等对应服务拆分后再接入。
//
// 验证上限：本文件 import GatherApplication（依赖 GatherAnalysis/ImageIO），
// Linux 无法 typecheck，仅语法解析；需 macOS 首跑（见交付报告）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherApplication

@Suite("Wave5 全 fake 装配冒烟")
struct Wave5FakeAssemblyTests {
    @Test("SettingsService：构造只经端口载入、写回只经端口 upsert")
    func settingsServiceAssemblesWithFakeRepo() throws {
        let key = SettingsKey.thumbnailSize.rawValue
        let repo = PortFakeSettingsRepo(storage: [key: "640"])
        let service = SettingsService(repo: repo)

        // 构造期 loadCache 只走 repo.getAll，且没有任何 DBConnection 参与。
        #expect(repo.getAllCalls == 1)
        #expect(service.get(key) == "640")

        try service.set(key, value: "512")
        #expect(repo.upserts.count == 1)
        #expect(repo.upserts.first?.key == key)
        #expect(repo.upserts.first?.value == "512")
        #expect(service.getNumber(key, defaultValue: 0) == 512)
    }

    @Test("NavigationService：空会话读路径只经端口，analyze(dryRun) 不落库")
    func navigationServiceAssemblesWithFakeRepo() throws {
        let repo = PortFakeNavigationRepo()
        let service = NavigationService(navigationRepo: repo)

        let groups = try service.analyze(sessionId: "s1", dryRun: true)
        #expect(groups.isEmpty)
        #expect(repo.captureRowsCalls == ["s1"])
        // dryRun 不得触发自动分组的写路径。
        #expect(repo.replaceAutomaticGroupsCalls.isEmpty)

        let listed = try service.list(sessionId: "s1")
        #expect(listed.isEmpty)
        #expect(repo.listGroupsCalls == ["s1"])
    }

    @Test("QualityService：空会话 analyze 只经照片/质量端口，空结果不产生 INSERT 行")
    func qualityServiceAssemblesWithFakeRepos() async throws {
        let photoRepo = PortFakePhotoRepo()
        let qualityRepo = PortFakeQualityRepo()
        // 非 nil 空组：模拟「相似分析已跑过、无组」，避免 applyRelativeRanks 的
        // 「nil 再读一次」兜底（这与真实 repo 行为一致，但会让调用次数翻倍）。
        qualityRepo.similarityGroups = [Int: [String]]()
        let service = QualityService(photoRepo: photoRepo, qualityRepo: qualityRepo)

        let results = try await service.analyze(sessionId: "s1")
        #expect(results.isEmpty)
        // 输入读取、缓存/人脸预载、落库、相对排名读模型都必须经端口。
        #expect(photoRepo.projectionCalls == 1)
        #expect(qualityRepo.cachedResultsCalls.count == 1)
        #expect(qualityRepo.maxFaceBoxesCalls.count == 1)
        #expect(qualityRepo.maxFaceBoxesCalls.first?.photoIds.isEmpty == true)
        #expect(qualityRepo.insertResultsCalls.count == 1)
        #expect(qualityRepo.insertResultsCalls.first?.inserts.isEmpty == true)
        #expect(qualityRepo.latestSimilarityGroupsCalls == ["s1"])
    }

    @Test("Wave5 fake：未实现写路径抛 Wave5FakeUnimplemented，且调用仍被记录")
    func waveFiveFakeThrowsOnUnimplementedWrite() throws {
        let repo = PortFakeNavigationRepo()
        #expect(throws: Wave5FakeUnimplemented.self) {
            try repo.replaceAutomaticGroups(sessionId: "s1", groups: [])
        }
        #expect(repo.replaceAutomaticGroupsCalls == ["s1/0"])
    }

    @Test("Wave5 fake：Sendable 窄端口替身记录调用与作用域入参")
    func waveFiveSendableFakesRecordCalls() throws {
        let delivery = PortFakeDeliveryReadStore()
        let row = try delivery.get("/v/IMG_1.xmp")
        #expect(row == nil)
        #expect(delivery.callCount == 1)
        #expect(delivery.requestedPaths == ["/v/IMG_1.xmp"])

        let metadata = PortFakeMetadataDeliveryReader()
        _ = try metadata.projections(sessionId: "s1")
        _ = try metadata.backupPaths(sessionId: nil)
        _ = try metadata.backupPaths(sessionId: "s1")
        #expect(metadata.projectionCallCount == 1)
        #expect(metadata.backupPathCallCount == 2)
        // nil 作用域 = 全库引用集，必须原样记录，不能被作用域调用掩盖。
        #expect(metadata.backupPathScopes == [nil, "s1"])
    }

    @Test("Wave5 fake：4 个未接入服务的窄替身可独立驱动（记录 + 未实现语义）")
    func waveFiveNarrowFakesAreDriveable() throws {
        // PhotoReadStore：1 方法读端口，记录 session 入参并返回注入行（空集合法）。
        let photo = PortFakePhotoReadStore()
        #expect(try photo.getBySessionProjection(sessionId: "s1").isEmpty)
        #expect(photo.projectionCalls == ["s1"])

        // MetadataKeywordReading：nil = 缓存行缺失（真实语义），setKeywords(nil) 覆盖删除。
        let keywords = PortFakeMetadataKeywordReader()
        keywords.setKeywords(["a"], forPhotoId: "p1")
        keywords.setKeywords(nil, forPhotoId: "p2")
        #expect(try keywords.keywords(photoId: "p1") == ["a"])
        #expect(try keywords.keywords(photoId: "p2") == nil)
        #expect(keywords.requestedPhotoIds == ["p1", "p2"])

        // CullingDecisionLiteReading：按会话返回注入决策，记录调用。
        let decisions = PortFakeCullingDecisionLiteReader()
        #expect(try decisions.getDecisions(sessionId: "s1").isEmpty)
        #expect(decisions.getDecisionsCalls == ["s1"])

        // DeliverySummaryReading：未注入摘要行时抛未实现（不静默返回假摘要），
        // hasWrittenBackItem 走布尔注入 + 记录。
        let summary = PortFakeDeliverySummaryReader()
        #expect(throws: Wave5FakeUnimplemented.self) {
            try summary.summary(sessionId: "s1", module: nil)
        }
        #expect(throws: Wave5FakeUnimplemented.self) {
            try summary.metadataSummary(sessionId: "s1", module: nil)
        }
        #expect(try summary.hasWrittenBackItem(sessionId: "s1", module: .metadata) == false)
        #expect(summary.summaryCalls.count == 1)
        #expect(summary.metadataSummaryCalls.count == 1)
        #expect(summary.hasWrittenBackCalls.count == 1)
    }

    @Test("端口实效化：10 端口的高依赖服务可纯 fake 装配（类型系统保证不触真实 DB）")
    func highDependencyServiceAssemblesFromPortsOnly() {
        // CullingDecisionService 的 init 只接受端口（无 DBConnection/Database 参数）：
        // 能构造出来本身就是「服务不依赖真实库」的类型级证明；这里再用 conformance
        // 断言它仍满足读端口契约（CullingDecisionLiteReading），防止拆分后漏 conformance。
        let service = CullingDecisionService(
            photoRepo: PortFakePhotoRepo(),
            cullingDecisionRepo: PortFakeCullingDecisionRepo(),
            similarityResultRepo: PortFakeSimilarityRepo(),
            metadataCacheRepo: PortFakeMetadataRepo(),
            pageQuery: PortFakeCullingPageReading(),
            richQuery: PortFakeCullingRichReading(),
            deliveryItems: PortFakeDeliveryRepo(),
            transactions: PortFakeTransactionRunner(),
            metadataMutations: RecordingMetadataMutation())
        #expect(service is any CullingDecisionLiteReading)
    }
}
