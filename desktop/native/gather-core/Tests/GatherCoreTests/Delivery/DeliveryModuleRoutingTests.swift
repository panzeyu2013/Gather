// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryModuleAdapterTests.swift
// WP2b：模块适配器的路由与 feature 差异。
//
// 覆盖：
// 1. 5 个适配器方法把 module 固定传给引擎（culling/face/similarity 逐一验证）；
// 2. capability 矩阵显式表达 feature 差异（culling 多 finalize/metadataSummary）；
// 3. 越权调用抛 unsupportedCapability（不是静默走错模块）；
// 4. 旧端口（14 个名字）转发到同一个适配器，Coordinator 不再声明模块方法。

import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence
@testable import GatherProtocol

private final class RecordingDeliveryEngine: DeliveryEngine, @unchecked Sendable {
    struct Call: Equatable {
        let operation: String
        let module: DeliveryModule?
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    var calls: [Call] {
        lock.withLock { storage }
    }

    func operations() -> [String] {
        calls.map(\.operation)
    }

    private func record(_ operation: String, module: DeliveryModule?) {
        lock.withLock { storage.append(Call(operation: operation, module: module)) }
    }

    func confirm(sessionId: String, module: DeliveryModule) throws -> DeliveryConfirmSummary {
        record("confirm", module: module)
        return DeliveryConfirmSummary(
            scope: .module, confirmedLinks: 0, deliveriesSynced: 0,
            itemsSynced: 0, unconfirmedSessionIds: []
        )
    }

    func cleanup(sessionId: String, module: DeliveryModule) async throws -> DeliveryCleanupSummary {
        record("cleanup", module: module)
        return DeliveryCleanupSummary(
            deletedCount: 0, conflictedCount: 0, skippedCount: 0, errors: [])
    }

    func finalize(sessionId: String, module: DeliveryModule) async throws -> DeliveryFinalizeSummary {
        record("finalize", module: module)
        return DeliveryFinalizeSummary(deletedCount: 0, skippedCount: 0, errors: [])
    }

    func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        record("mirrorWriteback", module: module)
        return DeliveryMirrorSummary(deliveryCount: 0, itemCount: items.count, errors: [])
    }

    func metadataSummary(
        sessionId: String,
        module: DeliveryModule?
    ) throws -> MetadataSyncSummary {
        record("metadataSummary", module: module)
        return MetadataSyncSummary(
            sessionId: sessionId, pending: 0, writing: 0, written: 0,
            failed: 0, conflict: 0, synced: 0, items: []
        )
    }

    func replay() async throws -> DeliveryReplaySummary {
        record("replay", module: nil)
        return DeliveryReplaySummary(
            appliedCount: 0, skippedCount: 0, failedCount: 0, errors: [])
    }
}

struct DeliveryModuleAdapterTests {
    @Test func adapterRoutesEveryOperationToItsModule() async throws {
        let engine = RecordingDeliveryEngine()
        for module in [DeliveryModule.culling, .faceKeyword, .similarity] {
            let adapter = CoordinatorDeliveryAdapter(engine: engine, module: module)
            _ = try adapter.confirm(sessionId: "s1")
            _ = try await adapter.cleanup(sessionId: "s1")
            _ = try adapter.mirrorWriteback(sessionId: "s1", items: [])
            if module == .culling {
                _ = try await adapter.finalize(sessionId: "s1")
                _ = try adapter.metadataSummary(sessionId: "s1")
            }
        }

        let cullingCalls = engine.calls.filter { $0.module == .culling }
        #expect(cullingCalls.map(\.operation) == [
            "confirm", "cleanup", "mirrorWriteback", "finalize", "metadataSummary",
        ])
        let faceCalls = engine.calls.filter { $0.module == .faceKeyword }
        #expect(faceCalls.map(\.operation) == ["confirm", "cleanup", "mirrorWriteback"])
        let similarityCalls = engine.calls.filter { $0.module == .similarity }
        #expect(similarityCalls.map(\.operation) == ["confirm", "cleanup", "mirrorWriteback"])
    }

    @Test func capabilityMatrixExpressesFeatureDifferences() {
        #expect(
            DeliveryModuleCapability.capabilities(for: .culling) == Set([
                .confirm, .cleanup, .finalize, .mirrorWriteback, .metadataSummary,
            ]))
        for module in [DeliveryModule.faceKeyword, .similarity] {
            #expect(
                DeliveryModuleCapability.capabilities(for: module)
                    == Set([.confirm, .cleanup, .mirrorWriteback]),
                "\(module.rawValue) 不应有 finalize/metadataSummary")
        }
    }

    @Test func unsupportedCapabilityFailsExplicitly() async throws {
        let engine = RecordingDeliveryEngine()
        let face = CoordinatorDeliveryAdapter(engine: engine, module: .faceKeyword)

        await #expect(throws: DeliveryModuleAdapterError.unsupportedCapability(
            module: .faceKeyword, capability: .finalize
        )) {
            _ = try await face.finalize(sessionId: "s1")
        }
        #expect(throws: DeliveryModuleAdapterError.unsupportedCapability(
            module: .faceKeyword, capability: .metadataSummary
        )) {
            _ = try face.metadataSummary(sessionId: "s1")
        }
        #expect(engine.calls.isEmpty, "越权调用不得转发到引擎")
    }

    @Test func legacyCullingPortForwardsThroughSingleAdapter() async throws {
        let engine = RecordingDeliveryEngine()
        let port: any CullingDeliveryPort = CoordinatorDeliveryAdapter(
            engine: engine, module: .culling)

        _ = try port.confirmCulling(sessionId: "s1")
        _ = try await port.cleanupCulling(sessionId: "s1")
        _ = try await port.finalizeCulling(sessionId: "s1")
        _ = try port.mirrorCullingWriteback(sessionId: "s1", items: [])
        _ = try port.cullingMetadataSummary(sessionId: "s1")
        _ = try await port.replayPendingDeliveries()

        #expect(engine.operations() == [
            "confirm", "cleanup", "finalize", "mirrorWriteback",
            "metadataSummary", "replay",
        ])
        #expect(engine.calls.filter { $0.operation != "replay" }.allSatisfy {
            $0.module == .culling
        })
    }

    @Test func legacyFaceAndSimilarityPortsForwardThroughSameAdapter() async throws {
        let engine = RecordingDeliveryEngine()
        let face: any FaceKwDeliveryPort = CoordinatorDeliveryAdapter(
            engine: engine, module: .faceKeyword)
        _ = try face.confirmFaceKeyword(sessionId: "s1")
        _ = try await face.cleanupFaceKeyword(sessionId: "s1")
        _ = try face.mirrorFaceKeywordWriteback(sessionId: "s1", items: [])
        _ = try await face.replayPendingDeliveries()

        let similarity: any SimilarityDeliveryPort = CoordinatorDeliveryAdapter(
            engine: engine, module: .similarity)
        _ = try similarity.confirmSimilarity(sessionId: "s1")
        _ = try await similarity.cleanupSimilarity(sessionId: "s1")
        _ = try similarity.mirrorSimilarityWriteback(sessionId: "s1", items: [])
        _ = try await similarity.replayPendingDeliveries()

        #expect(engine.calls.filter { $0.module == .faceKeyword }.map(\.operation) == [
            "confirm", "cleanup", "mirrorWriteback",
        ])
        #expect(engine.calls.filter { $0.module == .similarity }.map(\.operation) == [
            "confirm", "cleanup", "mirrorWriteback",
        ])
        #expect(engine.operations().filter { $0 == "replay" }.count == 2)
    }

    @Test func coordinatorFactoryProducesAdapterWithMatchingModule() throws {
        let coordinator = DeliveryCoordinator(
            connection: try DeliveryTestSupport.makeDB(),
            files: DeliveryTestFilePort()
        )
        let adapter = coordinator.adapter(for: .similarity)
        #expect(adapter.module == .similarity)
        #expect(adapter.engine is DeliveryCoordinator)
    }
}
