// desktop/native/gather-core/Tests/GatherCoreTests/Similarity/ClusterStateVersioningTests.swift
// Cut 5 / 5b-2b：可落库簇状态的版本 / 参数指纹 / 内容摘要 / 行级 diff 门禁。
//
// 这一组是纯函数用例（不碰数据库）：签名与摘要必须确定性、对语义变化敏感、
// 对输入序/行序不敏感；diff 必须恰好给出 added / changed / removed，且
// “同一状态再 diff 一次”为空（apply 幂等的逻辑前提）。

import Foundation
import Testing
@testable import GatherAnalysis
import GatherProtocol

// MARK: - 夹具

private func clusterState(
    components: [[String]],
    groups: [[String]],
    hashes: [String: String]
) -> ClusterState {
    ClusterState(components: components, groups: groups, hashes: hashes)
}

private let baseState = clusterState(
    components: [["p1", "p2"], ["p3"]],
    groups: [["p1", "p2"]],
    hashes: ["p1": "aaaa", "p2": "bbbb", "p3": "cccc"]
)

// MARK: - 测试

@Suite("ClusterState 版本 / 指纹 / 行级 diff")
struct ClusterStateVersioningTests {
    @Test("currentAlgorithmVersion 钉在 1（写库口径，升级需显式改这里）")
    func algorithmVersionIsPinned() {
        #expect(ClusterStateVersioning.currentAlgorithmVersion == 1)
    }

    @Test("input_signature：确定性、含算法版本、对阈值/组大小/模式敏感")
    func inputSignatureIsStableAndSensitive() {
        let base = ClusterStateVersioning.inputSignature(
            threshold: 10, minGroupSize: 2, groupingMode: "global"
        )
        // 同一输入重复计算必须逐字节相同（apply 与 reads 两侧独立调用）。
        #expect(base == ClusterStateVersioning.inputSignature(
            threshold: 10, minGroupSize: 2, groupingMode: "global"
        ))
        #expect(base.contains("v1"), "签名必须携带算法版本")

        #expect(base != ClusterStateVersioning.inputSignature(
            threshold: 11, minGroupSize: 2, groupingMode: "global"
        ))
        #expect(base != ClusterStateVersioning.inputSignature(
            threshold: 10, minGroupSize: 3, groupingMode: "global"
        ))
        #expect(base != ClusterStateVersioning.inputSignature(
            threshold: 10, minGroupSize: 2, groupingMode: "sequential"
        ))
    }

    @Test("state_digest：重复计算稳定、对分量/成员/哈希的行序不敏感")
    func digestIsStableAndOrderIndependent() {
        let digest = ClusterStateVersioning.stateDigest(baseState)
        #expect(digest == ClusterStateVersioning.stateDigest(baseState))
        #expect(digest.hasPrefix("fnv1a64:"), "摘要带算法前缀，空串/旧值不会被误认")

        // 同一语义、不同容器顺序（DB 行序还原可能给出不同分量顺序）必须同摘要。
        let reordered = clusterState(
            components: [["p3"], ["p2", "p1"]],
            groups: [["p1", "p2"]],
            hashes: ["p3": "cccc", "p2": "bbbb", "p1": "aaaa"]
        )
        #expect(ClusterStateVersioning.stateDigest(reordered) == digest, "行序不得影响摘要")
    }

    @Test("state_digest：分量归属 / 组种子 / 哈希任一变化都会变")
    func digestSensitiveToContent() {
        let digest = ClusterStateVersioning.stateDigest(baseState)

        // p3 并入 p1/p2 的分量 → 划分变化。
        let merged = clusterState(
            components: [["p1", "p2", "p3"]],
            groups: [["p1", "p2"]],
            hashes: baseState.hashes
        )
        #expect(ClusterStateVersioning.stateDigest(merged) != digest)

        // 组种子从 p1 换成 p2 → 组内序/代表图语义变化。
        let reseeded = clusterState(
            components: baseState.components,
            groups: [["p2", "p1"]],
            hashes: baseState.hashes
        )
        #expect(ClusterStateVersioning.stateDigest(reseeded) != digest)

        // 哈希变化 → diff 需要重算该行。
        var hashes = baseState.hashes
        hashes["p2"] = "dddd"
        let rehashed = clusterState(
            components: baseState.components,
            groups: baseState.groups,
            hashes: hashes
        )
        #expect(ClusterStateVersioning.stateDigest(rehashed) != digest)
    }

    @Test("diff：old = nil 时全部 added（首次全量），行映射到分量/种子")
    func diffFromNilAddsEveryRow() {
        let diff = ClusterStateDiff(old: nil, new: baseState)
        #expect(diff.added.count == 3)
        #expect(diff.changed.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.unchangedCount == 0)
        #expect(diff.upserts.count == 3)

        let byId = Dictionary(uniqueKeysWithValues: diff.added.map { ($0.photoId, $0) })
        #expect(byId["p1"]?.hashHex == "aaaa")
        #expect(byId["p1"]?.componentIndex == 0)
        #expect(byId["p1"]?.groupSeed == "p1")
        #expect(byId["p2"]?.groupSeed == "p1")
        #expect(byId["p3"]?.componentIndex == 1)
        #expect(byId["p3"]?.groupSeed == nil)
    }

    @Test("diff：新增 / 删除 / 变更 / 未变四种行各归其位")
    func diffClassifiesRows() {
        let old = clusterState(
            components: [["a", "b"], ["c", "e"]],
            groups: [["a", "b"]],
            hashes: ["a": "1111", "b": "2222", "c": "3333", "e": "5555"]
        )
        let new = clusterState(
            components: [["a", "b"], ["c"], ["d"]],
            groups: [["a", "b"]],
            hashes: ["a": "1111", "b": "baad", "c": "3333", "d": "4444"]
        )

        let diff = ClusterStateDiff(old: old, new: new)
        #expect(diff.changed.map(\.photoId) == ["b"], "只有哈希变化的 b 是 changed")
        #expect(diff.changed.first?.hashHex == "baad")
        #expect(diff.added.map(\.photoId) == ["d"])
        #expect(diff.added.first?.componentIndex == 2)
        #expect(diff.added.first?.groupSeed == nil)
        #expect(diff.removed == ["e"], "旧行里消失的 id 按升序删除")
        #expect(diff.unchangedCount == 2, "a / c 的四个列值完全相同，不得进入 upserts")
        #expect(diff.upserts.map(\.photoId) == ["d", "b"], "upserts = added + changed（各自保持规范序）")
    }

    @Test("diff：同一状态再 diff 为空；重复 apply 同一 diff 不产生行级写")
    func repeatedDiffIsIdempotent() {
        let old = clusterState(
            components: [["a", "b"]],
            groups: [["a", "b"]],
            hashes: ["a": "1111", "b": "2222"]
        )
        let new = clusterState(
            components: [["a"], ["b"]],
            groups: [["b"]],
            hashes: ["a": "1111", "b": "2222"]
        )

        let first = ClusterStateDiff(old: old, new: new)
        #expect(!first.isEmpty)
        // apply 成功后库里就是 new；再次 apply 同一个 new 必须是空 diff。
        let second = ClusterStateDiff(old: new, new: new)
        #expect(second.isEmpty)
        #expect(second.upserts.isEmpty)
        #expect(second.unchangedCount == 2)
    }
}
