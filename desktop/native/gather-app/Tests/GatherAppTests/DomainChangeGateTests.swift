// desktop/native/gather-app/Tests/GatherAppTests/DomainChangeGateTests.swift
// R4：domainChanged 的 revision 分配与 DomainChangeGate 去重/落后判定。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("R4 domain change revision", .serialized)
@MainActor
struct DomainChangeGateTests {
    @Test("postDomainChange 按域单调递增，currentRevision 同步")
    func revisionsAreMonotonicPerDomain() {
        GatherEventCenter.resetRevisionsForTesting()
        let before = GatherEventCenter.currentRevision(.culling)
        GatherEventCenter.postDomainChange(.culling)
        GatherEventCenter.postDomainChange(.culling)
        GatherEventCenter.postDomainChange(.library)
        #expect(GatherEventCenter.currentRevision(.culling) == before + 2)
        #expect(GatherEventCenter.currentRevision(.library) == 1)
    }

    @Test("gate 丢弃重复/过期 revision，跨域互不影响")
    func gateDropsStale() {
        let gate = DomainChangeGate()
        #expect(gate.applyIfNewer(GatherApplicationChange(domain: .culling, revision: 2)))
        #expect(!gate.applyIfNewer(GatherApplicationChange(domain: .culling, revision: 2)))
        #expect(!gate.applyIfNewer(GatherApplicationChange(domain: .culling, revision: 1)))
        #expect(gate.applyIfNewer(GatherApplicationChange(domain: .culling, revision: 3)))
        #expect(gate.applyIfNewer(GatherApplicationChange(domain: .library, revision: 1)))
    }
}
