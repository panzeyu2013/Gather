// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph.swift
// Cut 5：dHash 聚类的**唯一实现**（5a 建图 / 5b-1 单趟流水线 / 5b-2a 删旧实现）。
//
// 旧 ClusterEngine（753 行）与 IncrementalClusterer 内部的 ParsedHashes /
// ComponentGraph / groupComponent(Scanning) / connectedComponents / buildState
// 已在 5b-2a 整段删除：全仓原本 6 份度门控 BFS 收敛到这里的两形态
// （components = popLast 栈、groups = frontier 波次），聚类实现只剩 ClusterGraph.swift
// 与同目录 ClusterGraph+*.swift，外加 IncrementalClusterer.decide（增量装配）。
//
// 层次：
//   HashEntry / HashGroupingMode / ClusterResult  输入输出 DTO（随引擎迁入）
//   ClusterGraphError                             invalidHash（原 ClusterEngineError）
//   HashGraphTable             hex -> 定宽大端字节 + UInt64 快路径（距离/阈值判定）
//   NeighborhoodGraph          邻接枚举协议（位集图与 streaming 图共用）
//   HashNeighborhoodGraph      n <= defaultMaxBitsetEntries 的位集邻接（单档生产主路径）
//   MultiThresholdHashGraph    多档共享最高档并集行 + 逐档距离核验（预计算档位）
//   StreamingNeighborhoodGraph n > defaultMaxBitsetEntries 的省内存回退（度数 + 按需扫描）
//   DegreeGatedBFS             全仓唯一的分量/度门控分组实现（两形态）
//   ClusterWorkspace           有序结果容器（组序 / 组内序原样保留，可映射 id）
//   ClusterGraphPipeline       单档/多档 + global/sequential 入口（result 与 state 同源）
//   ClusterStateVersioning     状态语义版本 / 参数指纹 / 内容摘要（5b-2b）
//   ClusterStateEntry/Diff     similarity_cluster_state 的行级 diff（5b-2b）
//
// 语义（golden：Reconciliation/Fixtures/cluster-fixtures.json + ClusterGraphTests）：
// - 边：distance(a, b) = popcount(a XOR b) <= threshold，无权重；
// - 分量：连通分量，成员按节点下标升序，分量按首成员升序；
// - 分组：种子按节点下标升序；degree + 1 < minGroupSize 的种子不成组，
//   稀疏节点可以“随组”但不向外扩张；组内首元素恒为种子。
// - 组内序 = 波次（wave）BFS 的发现序：每波按节点下标升序批量采纳，下一波是
//   本波采纳的稠密节点邻域并集（去重后升序）。这正是生产主路径 #3 的顺序；
//   旧的栈式 BFS（#2/#4/#5/#6 的原始顺序）是 DFS 逆序，二者划分相同但组内序
//   不同。ClusterWorkspace.canonicalGroups() 提供 [seed] + 升序成员的规范序，
//   与落库的 ClusterState 口径一致（#6 经 canonicalize 后的可见顺序）。
//
// 并发：全部为不可变值类型 / 无状态 static func；单次 BFS 的临时数组不跨调用
// 共享。位集写入是双向的，聚类 CPU 扫描保持单线程（与 5a 审计 §2.5 一致）。
//
// 内存：HashNeighborhoodGraph 为 count * ceil(count/64) * 8 字节；n = 32,769 时
// 约 134 MB。超过 defaultMaxBitsetEntries 时调用方改用 StreamingNeighborhoodGraph，
// 其额外空间为 O(n)（degrees + 结果），邻接按需扫描。
//
// 文件布局（纯移动：算法 / 边界 / 错误 / 顺序均未改，类型与成员逐字未改）：
//   ClusterGraph.swift                 头部语义 + 输入输出 DTO + 错误（本文件）
//   ClusterGraph+HashTable.swift       HashGraphTable（hex 存储 / 距离 / 度数预扫）
//   ClusterGraph+Neighborhood.swift    NeighborhoodGraph 协议 + 位集 / 多档并集 / streaming 图
//   ClusterGraph+DegreeGatedBFS.swift  DegreeGatedBFS（分量 / 度门控分组唯一实现）
//   ClusterGraph+State.swift           ClusterWorkspace / ClusterGraphOutcome / 版本·指纹·diff
//   ClusterGraph+Pipeline.swift        ClusterGraphPipeline（单档 / 多档 / sequential 入口）

import Foundation
import GatherProtocol

// MARK: - 输入 / 输出 DTO（Cut 5 / 5b-2a：随 ClusterEngine 删除迁入本文件）

/// 一条待聚类条目：照片 id + dHash hex。
public struct HashEntry: Equatable, Sendable {
    public let photoId: String
    public let hash: String

    public init(photoId: String, hash: String) {
        self.photoId = photoId
        self.hash = hash
    }
}

/// 分组模式：global = 阈值图的连通分量（度门控），sequential = 相邻条目连续段。
public enum HashGroupingMode: Sendable {
    case sequential
    case global
}

/// 一次聚类的输出：成组照片（组序 = 种子输入序）+ 未成组照片（输入序）。
public struct ClusterResult: Equatable, Sendable {
    public let groups: [[String]]
    public let ungrouped: [String]

    public init(groups: [[String]], ungrouped: [String]) {
        self.groups = groups
        self.ungrouped = ungrouped
    }
}

// MARK: - 错误

/// 聚类图输入错误（原 ClusterEngineError，5b-2a 随引擎删除迁入）：空串 / 非 hex 字符。
public enum ClusterGraphError: Error, Equatable, Sendable {
    case invalidHash(String)
}
