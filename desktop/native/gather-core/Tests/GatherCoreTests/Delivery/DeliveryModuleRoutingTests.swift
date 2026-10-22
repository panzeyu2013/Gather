// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryModuleAdapterTests.swift
// WP2b：模块适配器的路由与 feature 差异。
//
// 覆盖：
// 1. 5 个适配器方法把 module 固定传给引擎（culling/face/similarity 逐一验证）；
// 2. capability 矩阵显式表达 feature 差异（culling 多 finalize/metadataSummary）；
// 3. 越权调用抛 unsupportedCapability（不是静默走错模块）；
// 4. 服务层直连适配器（WP2c 删除 14 个旧端口转发）：5 个方法 + engine.replay
//    路由到同一引擎；Coordinator 不再声明任何模块方法。

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

    @Test func cullingAdapterDrivesEveryOperationThroughEngine() async throws {
        let engine = RecordingDeliveryEngine()
        let adapter: any DeliveryModuleAdapter = CoordinatorDeliveryAdapter(
            engine: engine, module: .culling)

        _ = try adapter.confirm(sessionId: "s1")
        _ = try await adapter.cleanup(sessionId: "s1")
        _ = try await adapter.finalize(sessionId: "s1")
        _ = try adapter.mirrorWriteback(sessionId: "s1", items: [])
        _ = try adapter.metadataSummary(sessionId: "s1")
        _ = try await adapter.engine.replay()

        #expect(engine.operations() == [
            "confirm", "cleanup", "finalize", "mirrorWriteback",
            "metadataSummary", "replay",
        ])
        #expect(engine.calls.filter { $0.operation != "replay" }.allSatisfy {
            $0.module == .culling
        })
    }

    @Test func faceAndSimilarityAdaptersDriveTheirModules() async throws {
        let engine = RecordingDeliveryEngine()
        let face: any DeliveryModuleAdapter = CoordinatorDeliveryAdapter(
            engine: engine, module: .faceKeyword)
        _ = try face.confirm(sessionId: "s1")
        _ = try await face.cleanup(sessionId: "s1")
        _ = try face.mirrorWriteback(sessionId: "s1", items: [])
        _ = try await face.engine.replay()

        let similarity: any DeliveryModuleAdapter = CoordinatorDeliveryAdapter(
            engine: engine, module: .similarity)
        _ = try similarity.confirm(sessionId: "s1")
        _ = try await similarity.cleanup(sessionId: "s1")
        _ = try similarity.mirrorWriteback(sessionId: "s1", items: [])
        _ = try await similarity.engine.replay()

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
