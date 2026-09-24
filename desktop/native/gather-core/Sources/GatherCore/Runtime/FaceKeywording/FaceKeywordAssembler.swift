// desktop/native/gather-core/Sources/GatherCore/Runtime/FaceKeywording/FaceKeywordAssembler.swift
// W2d-6 步骤①：FaceKeywording 纯函数层（Services/FaceKwService.swift 的纯逻辑下沉）。
//
// 来源与边界：
// - 逐字移植 FaceKwService.swift 中的纯逻辑：聚类参数校验
//   （validateFaceClusteringParameters）、聚类入口分片（embeddingEntries 的非零
//   向量过滤）、聚类结果映射（clusterInputs 的 "Person N" 标签与观察回填）、
//   集群签名格式（clusterSignature）、角色名归一化（normalizedRoleName）与关键词
//   合并去重（normalizedKeywords/deduplicatedKeywords）、重聚类绑定迁移评分
//   （planBindingMigrations / 成员照片集 memberPhotoIdsByCluster）、写回关键词
//   规划（buildFaceKeywordAdditions）、分析签名 JSON 构造（makeAnalysisSignature
//   与 jsonKey/jsonField/jsonEscape）、缓存判定（isCacheValid）、BLOB Float32
//   视图（floats(from:)）、bbox JSON 解析（parseBbox）与预览成员窗口常量
//   （maxPreviewMembers）。
// - 本文件自身不发起 Store/SQL/文件系统操作：输入均为值类型（String/Data/
//   FaceObservationRecord/FaceAnalysisStateRecord/FaceClusterRecord/
//   FaceBindingDetail 等值袋），只做集合、字符串与数值运算。唯一例外是
//   validateFaceClusteringParameters 抛出 Services 层的 FaceKwServiceError
//   （与 Runtime/Culling/CullingRuntime.swift 引用 CullingServiceError 的既有
//   分层一致）。模型指纹的文件 stat（modelFingerprint/tsStat）与推理/解码
//   provider 均留在服务层，本层以注入值接收。
// - 设计文档门禁：Runtime/** 内不得出现 SQL 语句文本或数据库连接类型（本文件
//   既不 import C SQLite，也不持有连接）。
//
// 命名注记（设计文档 §2 计划名 vs 本步骤实际）：
// - 设计文档计划把 FaceKeywording 纯逻辑拆为 FaceClusterPlanner /
//   FaceKeywordNormalizer / FaceSignatureBuilder 等容器；本步骤①按任务要求先
//   合并为单一 caseless enum FaceKeywordAssembler（对齐 Runtime/Indexer/
//   IndexAssembler.swift、Runtime/Export/ExportAssembler.swift 形态），后续如需
//   分域可机械拆分，当前不做推测性拆分。
//
// 行为保持（审计要点）：
// - 所有函数与旧实现逐字等价，含：eps ∈ [0,1] 且 minPts 为整数 >= 1；非零向量
//   判定 contains(where: { $0 != 0 })；clusterInputs 的 "Person \(index + 1)"
//   枚举序与 bbox 四元回填（缺失观察回落 0）；绑定迁移 candidates 的构造顺序、
//   sort { $0.overlap > $1.overlap }、claimedClusters / migratedBindings 双集合
//   的跳过序；关键词去重保留首次出现序；additions 按 cluster 顺序累积去重；
//   isCacheValid 的 abs(mtime 差) < 1 与 nil state 即失效；floats 的
//   count = data.count / MemoryLayout<Float>.size 与空 Data 返回 []；
//   parseBbox 只取 .number 且保序。
// - 服务侧仅把内联表达式改为调用本层函数（不保留第二份实现），调用序与捕获序
//   不变，行为逐字不变。
// - 唯一签名变化：makeAnalysisSignature 把旧实现内部调用的 modelFingerprint
//   （文件 stat）注入为 detectorFingerprint / encoderFingerprint 参数；服务侧以
//   modelFingerprint(path) 回填（先 detector 后 encoder，与旧实现取值序一致），
//   签名串逐字不变。

import Foundation

/// TS: face-kw.service.ts / face-kw.ipc.ts 的纯函数面（Store 读写、文件 stat、
/// 推理与解码 provider 均不在此文件）。
public enum FaceKeywordAssembler {

    // MARK: - 常量（旧 FaceKwService.maxPreviewMembers）

    /// TS: MAX_PREVIEW_MEMBERS（getClusters 的成员截断窗口）。
    public static let maxPreviewMembers = 4

    // MARK: - 聚类参数校验

    /// TS: validateFaceClusteringParameters。minPts 为 Double 对齐 TS number：
    /// Number.isInteger 校验（拒绝 NaN/∞/小数），通过后调用方再安全转 Int。
    public static func validateFaceClusteringParameters(eps: Double, minPts: Double) throws {
        if eps.isNaN || eps.isInfinite || eps < 0 || eps > 1 {
            throw FaceKwServiceError.epsInvalid
        }
        if minPts.isNaN || minPts.isInfinite || minPts.rounded() != minPts || minPts < 1 {
            throw FaceKwServiceError.minClusterInvalid
        }
    }

    // MARK: - 聚类分组（观察 → 入口 / 结果 → FaceClusterInput）

    /// 旧 clusterStoredObservations 的 entries 构造：BLOB 转 Float32 视图后仅保留
    /// 存在非零分量的观察（全零向量不参与聚类）。
    public static func embeddingEntries(from observations: [FaceObservationRecord]) -> [EmbeddingEntry] {
        var entries: [EmbeddingEntry] = []
        for observation in observations {
            let embedding = floats(from: observation.embedding)
            if embedding.contains(where: { $0 != 0 }) {
                entries.append(EmbeddingEntry(
                    observationId: Int(observation.id),
                    photoId: observation.photoId,
                    embedding: embedding
                ))
            }
        }
        return entries
    }

    /// 旧 clusterStoredObservations 的 clusterInputs 映射：label 按枚举序
    /// "Person N"（N 从 1 起），成员按聚类内序回填观察 bbox/confidence；
    /// 观察缺失时 bbox 全 0、confidence 0。
    public static func clusterInputs(
        clustered: FaceClusterResult,
        observationsById: [Int64: FaceObservationRecord],
        photoPathsById: [String: String]
    ) -> [FaceClusterInput] {
        clustered.clusters.enumerated().map { index, cluster in
            FaceClusterInput(
                label: "Person \(index + 1)",
                members: cluster.map { entry in
                    let observation = observationsById[Int64(entry.observationId)]
                    return FaceClusterMemberInput(
                        photoId: entry.photoId,
                        photoPath: photoPathsById[entry.photoId] ?? "",
                        bbox: [
                            observation?.bboxX ?? 0,
                            observation?.bboxY ?? 0,
                            observation?.bboxW ?? 0,
                            observation?.bboxH ?? 0,
                        ],
                        confidence: observation?.confidence ?? 0,
                        observationId: Int64(entry.observationId)
                    )
                }
            )
        }
    }

    /// 旧 analyze / recluster 的集群签名（"\(eps):\(Int(minPts))"）。
    public static func clusterSignature(eps: Double, minPts: Int) -> String {
        "\(eps):\(minPts)"
    }

    // MARK: - 角色名归一化 / 关键词合并与去重

    /// TS: bindCluster 的角色名 trim（空串由调用方抛 FKW_ROLE_NAME_EMPTY）。
    public static func normalizedRoleName(_ roleName: String) -> String {
        roleName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 关键词规范化：trim + 丢弃空串，保序且不去重（旧 unbind 的受保护扫描与
    /// 写回条目过滤语义）。
    public static func normalizedKeywords(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 关键词规范化 + 保序去重（旧 bindCluster keywords 与
    /// buildFaceKeywordAdditions 的 seen.insert 语义）。
    public static func deduplicatedKeywords(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - 绑定迁移（重叠度评分）

    /// 旧 migrateBindings 实际执行的绑定迁移项（每项一次 updateBinding）。
    public struct BindingMigration: Equatable, Sendable {
        public let clusterId: Int64
        public let roleName: String
        public let keywords: [String]

        public init(clusterId: Int64, roleName: String, keywords: [String]) {
            self.clusterId = clusterId
            self.roleName = roleName
            self.keywords = keywords
        }
    }

    /// 旧 clusterStoredObservations 的 membersByCluster：新集群 id 与成员照片 id
    /// 集一一配对（空 photoId 过滤）。
    public static func memberPhotoIdsByCluster(
        clusterIds: [Int64],
        clusterInputs: [FaceClusterInput]
    ) -> [(clusterId: Int64, photoIds: Set<String>)] {
        clusterIds.enumerated().map { index, clusterId in
            (
                clusterId: clusterId,
                photoIds: Set(
                    clusterInputs[index].members.map(\.photoId).filter { !$0.isEmpty }
                )
            )
        }
    }

    /// TS: migrateBindings 的纯评分计划 —— 按照片 id 重叠度把角色绑定挂回新集群；
    /// 重叠 > 0 才入候选，重叠降序认领（竞争由更优匹配者获胜），消失的脸对应的
    /// 绑定被丢弃；每集群/每绑定至多认领一次，计划顺序即旧实现的更新顺序。
    public static func planBindingMigrations(
        previousBindings: [FaceBindingDetail],
        newMembers: [(clusterId: Int64, photoIds: Set<String>)]
    ) -> [BindingMigration] {
        var candidates: [(binding: FaceBindingDetail, clusterId: Int64, overlap: Int)] = []
        for binding in previousBindings {
            let memberPhotos = Set(binding.memberPhotoIds)
            for candidate in newMembers {
                var overlap = 0
                for photoId in candidate.photoIds where memberPhotos.contains(photoId) {
                    overlap += 1
                }
                if overlap > 0 {
                    candidates.append((binding, candidate.clusterId, overlap))
                }
            }
        }
        candidates.sort { $0.overlap > $1.overlap }
        var claimedClusters = Set<Int64>()
        var migratedBindings = Set<Int64>()
        var plan: [BindingMigration] = []
        for candidate in candidates {
            if claimedClusters.contains(candidate.clusterId) { continue }
            if migratedBindings.contains(candidate.binding.clusterId) { continue }
            claimedClusters.insert(candidate.clusterId)
            migratedBindings.insert(candidate.binding.clusterId)
            plan.append(BindingMigration(
                clusterId: candidate.clusterId,
                roleName: candidate.binding.roleName,
                keywords: candidate.binding.keywords
            ))
        }
        return plan
    }

    // MARK: - 写回规划（关键词合并）

    /// TS: buildFaceKeywordAdditions（fkw.preview 的写回规划）。角色名并入关键词
    /// 头部，逐集群规范化去重后按成员照片合并（已存在关键词不重复追加）。
    public static func buildFaceKeywordAdditions(_ clusters: [FaceClusterRecord]) -> [String: [String]] {
        var additions: [String: [String]] = [:]
        for cluster in clusters {
            guard let binding = cluster.binding else { continue }
            let keywords = deduplicatedKeywords([binding.roleName] + binding.keywords)
            for member in cluster.members ?? [] {
                var merged = additions[member.photoId] ?? []
                for keyword in keywords where !merged.contains(keyword) {
                    merged.append(keyword)
                }
                additions[member.photoId] = merged
            }
        }
        return additions
    }

    // MARK: - 分析签名（JSON 构造）与缓存判定

    /// TS: analysisSignature 构造（face-kw.service.ts:139-158）。键序与 TS
    /// JSON.stringify 的插入序逐字一致；preprocessingVersion 恒为 2。模型指纹
    /// （文件 stat）由服务侧以 modelFingerprint(path) 注入。
    public static func makeAnalysisSignature(
        detectorFingerprint: String,
        encoderFingerprint: String,
        primaryDetectionSize: Int,
        secondaryDetectionSize: Int,
        confidenceThreshold: Double,
        encoderInputSize: Int,
        embeddingDim: Int,
        previewMaxDimension: Int
    ) -> String {
        let fields = [
            jsonField("detector", detectorFingerprint),
            jsonField("encoder", encoderFingerprint),
            "\(jsonKey("primaryDetectionSize")):\(primaryDetectionSize)",
            "\(jsonKey("secondaryDetectionSize")):\(secondaryDetectionSize)",
            "\(jsonKey("confidenceThreshold")):\(confidenceThreshold)",
            "\(jsonKey("encoderInputSize")):\(encoderInputSize)",
            "\(jsonKey("embeddingDim")):\(embeddingDim)",
            "\(jsonKey("previewMaxDimension")):\(previewMaxDimension)",
            "\(jsonKey("preprocessingVersion")):2",
        ]
        return "{\(fields.joined(separator: ","))}"
    }

    /// TS: JSON.stringify 的键引号（签名键均为字面常量）。
    public static func jsonKey(_ key: String) -> String { "\"\(key)\"" }

    /// TS: JSON.stringify 的字符串字段。
    public static func jsonField(_ key: String, _ value: String) -> String {
        "\"\(key)\":\"\(jsonEscape(value))\""
    }

    /// TS: JSON.stringify 的最小等价转义（签名只含路径/整数，控制字符按
    /// \uXXXX 转义；JSON.parse 侧无感知差异）。
    public static func jsonEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// TS: isCacheValid（观察/状态与文件状态、签名一致）。
    public static func isCacheValid(
        _ state: FaceAnalysisStateRecord?,
        sourceSize: Int64,
        sourceMtimeMs: Double,
        analysisSignature: String
    ) -> Bool {
        guard let state else { return false }
        return state.sourceFileSize == sourceSize &&
            abs(state.sourceFileMtimeMs - sourceMtimeMs) < 1 &&
            state.analysisSignature == analysisSignature
    }

    // MARK: - 编解码辅助

    /// 存储 BLOB 的 Float32 视图（TS: Float32Array 视图，零拷贝语义）。
    public static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }

    /// TS: JSON.parse(m.bbox)。
    public static func parseBbox(_ raw: String) -> [Double] {
        guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
        return items.compactMap {
            if case .number(let v) = $0 { return v }
            return nil
        }
    }
}
