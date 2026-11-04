// desktop/native/gather-core/Sources/GatherApplication/Services/CullingServiceFactory.swift
// 挑片域的装配工厂（#6 收尾）：门面不接触任何仓储，装配集中在这里。
//
// 为什么独立成文件而不是留在门面上：判据是「门面文件里不出现任何仓储标识符」。
// 只要装配体还在门面文件里，这条判据就永远为假——哪怕它不在 init 里。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public enum CullingServiceFactory {
    /// 兼容 init（#6 S5 第二阶段临时）：与拆分前同签名，内部装配 decision + sync + 门面。
    /// 6 处构造点因此零改动；S6 会把它挪到测试支持与组合根，门面只留 init(decision:sync:)。
    public static func make(
        photoRepo: any PhotoRepository,
        cullingDecisionRepo: any CullingDecisionRepository,
        similarityResultRepo: any SimilarityRepository,
        metadataCacheRepo: any MetadataRepository,
        pageQuery: any CullingPageReading,
        richQuery: any CullingRichReading,
        deliveryItems: any DeliveryRowReading,
        transactions: any TransactionRunner,
        metadataMutations: any MetadataMutationPort,
        writeback: any CullingWritebackPort,
        cullingHistoryRepo: (any CullingHistoryRepository)? = nil,
        hooks: CullingDisplayHooks = .defaults,
        delivery: any DeliveryModuleAdapter
    ) -> CullingService {
        let decision = CullingDecisionService(
            photoRepo: photoRepo, cullingDecisionRepo: cullingDecisionRepo,
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo, pageQuery: pageQuery,
            richQuery: richQuery, deliveryItems: deliveryItems,
            transactions: transactions, metadataMutations: metadataMutations,
            cullingHistoryRepo: cullingHistoryRepo,
            hooks: hooks)
        // 复用决策服务已构造的那份 core：两个服务共享同一个结构体实例，
        // 将来 core 若加入状态（文件头明确警告不要加），也不会出现「各持一份、半写」的局面。
        let sync = CullingSyncService(
            core: decision.core, writeback: writeback, delivery: delivery, decisions: decision)
        return CullingService(decision: decision, sync: sync)
    }
}
