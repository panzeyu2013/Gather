// DomainEventsTests.swift
// P2：声明式事件 modifier 的域/会话/origin 过滤契约（纯过滤，不挂 UI）。
import Testing
@testable import GatherUI

@MainActor
@Suite("DomainEvents")
struct DomainEventsTests {
    @Test("只接受命中的域 + 会话 + 非自身 origin")
    func filtersDomainSessionAndOrigin() {
        let filter = DomainEventFilter(
            domains: [.library],
            sessionId: "s1",
            excludingOrigin: "self"
        )

        #expect(!filter.accepts(GatherApplicationChange(domain: .metadata, sessionId: "s1")))
        #expect(!filter.accepts(GatherApplicationChange(domain: .library, sessionId: "s2")))
        #expect(!filter.accepts(GatherApplicationChange(domain: .library, sessionId: "s1", origin: "self")))
        #expect(filter.accepts(GatherApplicationChange(domain: .library, sessionId: "s1", origin: "other")))
    }

    @Test("全局事件（sessionId=nil）命中任意会话")
    func globalEventMatchesAnySession() {
        let filter = DomainEventFilter(
            domains: [.library],
            sessionId: "s1",
            excludingOrigin: nil
        )
        #expect(filter.accepts(GatherApplicationChange(domain: .library)))
    }

    @Test("不限定 session/domain 时不过滤")
    func noFiltersAcceptsEverything() {
        let filter = DomainEventFilter(domains: Set(GatherChangeDomain.allCases), sessionId: nil, excludingOrigin: nil)
        for domain in GatherChangeDomain.allCases {
            #expect(filter.accepts(GatherApplicationChange(domain: domain, sessionId: "any")))
        }
    }
}
