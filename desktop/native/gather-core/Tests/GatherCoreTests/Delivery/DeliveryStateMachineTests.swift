// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryStateMachineTests.swift
// WP2b：显式迁移表与 Persistence 的 canTransition 必须逐边一致。
//
// 这是「唯一状态机」的结构门禁：Delivery 编排层（本刀新增）先判定，
// Persistence 的 CAS 再兜底；两边任何一边新增/删除一条边都会先在这里变红。

import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence

struct DeliveryStateMachineTests {
    @Test func deliveryTableMatchesPersistenceTransitionTable() {
        for from in DeliveryStatus.allCases {
            for to in DeliveryStatus.allCases {
                #expect(
                    DeliveryStateMachine.allows(from, to) == from.canTransition(to: to),
                    "delivery \(from.rawValue) -> \(to.rawValue) 与 DeliveryStatus.canTransition 不一致"
                )
            }
        }
    }

    @Test func itemTableMatchesPersistenceTransitionTable() {
        for from in DeliveryItemStatus.allCases {
            for to in DeliveryItemStatus.allCases {
                #expect(
                    DeliveryStateMachine.allows(from, to) == from.canTransition(to: to),
                    "item \(from.rawValue) -> \(to.rawValue) 与 DeliveryItemStatus.canTransition 不一致"
                )
            }
        }
    }

    @Test func namedTransitionsCoverEveryTargetWithExplicitSources() {
        #expect(DeliveryStateMachine.Transition.allCases.count == 7)
        for transition in DeliveryStateMachine.Transition.allCases {
            #expect(
                DeliveryStateMachine.sources(for: transition.target) == transition.sources,
                "\(transition.rawValue) 的来源态集合与迁移表不一致"
            )
            #expect(transition.sources.contains(transition.target), "自迁移必须显式允许（幂等重放）")
        }
        #expect(DeliveryStateMachine.ItemTransition.allCases.count == 4)
        for transition in DeliveryStateMachine.ItemTransition.allCases {
            #expect(
                DeliveryStateMachine.itemTable[transition.target] == transition.sources,
                "item \(transition.target.rawValue) 的来源态集合与迁移表不一致"
            )
        }
    }

    @Test func orchestrationPredicatesMatchFeatureSurface() {
        #expect(DeliveryStateMachine.isCleanupCandidate(.synced))
        for status in DeliveryStatus.allCases where status != .synced {
            #expect(!DeliveryStateMachine.isCleanupCandidate(status), "\(status.rawValue) 不是清理候选")
        }

        #expect(DeliveryStateMachine.isConfirmReady(.written))
        #expect(!DeliveryStateMachine.isConfirmReady(.pending))
        #expect(!DeliveryStateMachine.isConfirmReady(.synced))

        #expect(DeliveryStateMachine.reopenSources == [.written, .synced, .failed, .conflict])
        #expect(DeliveryStateMachine.shouldReopenForInput(.written))
        #expect(DeliveryStateMachine.shouldReopenForInput(.conflict))
        #expect(!DeliveryStateMachine.shouldReopenForInput(.pending))
        #expect(!DeliveryStateMachine.shouldReopenForInput(.writing))
        #expect(!DeliveryStateMachine.shouldReopenForInput(.cleaned))
        #expect(!DeliveryStateMachine.shouldReopenForInput(nil))

        #expect(DeliveryStateMachine.isTerminalForNewInput(.cleaned))
        #expect(!DeliveryStateMachine.isTerminalForNewInput(.synced))

        #expect(DeliveryStateMachine.isMirrorableItemStatus(.written))
        #expect(DeliveryStateMachine.isMirrorableItemStatus(.failed))
        #expect(!DeliveryStateMachine.isMirrorableItemStatus(.pending))
        #expect(!DeliveryStateMachine.isMirrorableItemStatus(.synced))
        #expect(!DeliveryStateMachine.isMirrorableItemStatus(nil))
    }

    @Test func everySourceSetIsANonEmptySubsetOfAllCases() {
        for target in DeliveryStatus.allCases {
            let sources = DeliveryStateMachine.sources(for: target)
            #expect(!sources.isEmpty, "\(target.rawValue) 没有来源态")
            #expect(sources.isSubset(of: Set(DeliveryStatus.allCases)))
        }
    }
}
