// desktop/native/gather-app/Tests/GatherAppTests/MetadataScanJobFactoryTests.swift
// R1 P1-3：index.scan（metadata.scan）建任务规则的单源工厂回归。
// dedupeKey 决定 job 去重（写错 → 同会话重复扫描 / 命中不到终态行），
// checkpoint["requestedPaths"] 决定续跑范围（写错 → 全树重扫或扫错目录）；
// 两者都是服务端私有规则，只能在协议层工厂定义，故在此逐字段钉住。

import Foundation
import Testing
import GatherProtocol

@Suite("metadata.scan 工厂（index.scan 语义单源）")
struct MetadataScanJobFactoryTests {
    @Test("工厂固定 type/scopeType/scopeId 与 dedupeKey")
    func factoryPinsJobIdentity() {
        let request = JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: nil)
        #expect(request.type == .metadataScan)
        #expect(request.scopeType == "session")
        #expect(request.scopeId == "s1")
        #expect(request.dedupeKey == "metadata.scan:s1")
        #expect(request.dedupeKey == JobCreateParams.metadataScanDedupeKey(sessionId: "s1"))
    }

    @Test("requestedPaths=nil/空数组 = 目录全树（空 checkpoint，续跑交给 dedupeKey 继承）")
    func factoryFullTreeScopeHasEmptyCheckpoint() {
        let cases: [[String]?] = [nil, []]
        for paths in cases {
            let request = JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: paths)
            #expect(request.checkpoint == [:])
            #expect(request.checkpoint?[JobCreateParams.metadataScanRequestedPathsKey] == nil)
        }
    }

    @Test("requestedPaths 数组 = 显式集合作用域（键与顺序逐位保留）")
    func factoryCarriesRequestedPaths() {
        let paths = ["/tmp/b.jpg", "/tmp/a.jpg", "/tmp/目录/c.jpg"]
        let request = JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: paths)
        #expect(
            request.checkpoint == [
                JobCreateParams.metadataScanRequestedPathsKey: .array(paths.map { .string($0) })
            ]
        )
        #expect(
            request.checkpoint?[JobCreateParams.metadataScanRequestedPathsKey]?
                .arrayElements?.compactMap(\.stringValue) == paths
        )
    }
}
