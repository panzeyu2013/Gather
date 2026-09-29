// desktop/native/gather-core/Sources/GatherCore/Face/ClusteringImpact.swift
// 聚类参数只读试算（竞品对标：改参数前先报"会发生什么"，不写库、不改状态、不触发任务）。
//
// 本文件是纯函数层：输入现有观测 + 当前分配 + 当前参数 + 拟用参数，输出计数与差值。
// 聚类语义完全复用 FaceClusterer.clusterEmbeddings（参数已存在），本文件不复制、
// 不修改 DBSCAN/质量门槛/retry 的任何判定，只做"结果 → 可比较的稳定映射"与计数。
//
// ── 计数只对传入观测集成立（最重要的一条）────────────────────────
// 所有 before/after 计数都只用 observations 里的条目计算：currentAssignment 中
// 指向不在 observations 里的陈旧条目被忽略，试算也只在这批观测上跑。因此
// **子集试算 ≠ 全库试算**，两边的簇数/噪声数/最大簇可以全面分叉：真实库 10 簇、
// 只传其中 2 簇成员时 clusterCountBefore = 2（不是 10）；minPts = 3 时全库可能聚成
// 1 簇，而只传少量互相不成簇的成员时试算会报 0 簇 —— 两个数字都没有错，只是量纲
// 不同。
// 机器可判：结果字段 isSubsetOfLibrary（Bool?）依据调用方传入的库规模判定，只有
// true / nil 两态，**不存在 false 这个结论**：
//   - true（确定是子集）：传 libraryFaceCount 且 observations.count < libraryFaceCount；
//     或未传 libraryFaceCount、只传 libraryClusterCount 且 clusterCountBefore <
//     libraryClusterCount（试算集没有覆盖库里全部现簇）。
//   - nil（无法判定）：未提供任何库规模，或传入数 ≥ 库计数。库计数可能过期，且
//     「传入条目数 ≥ 库计数」**不足以证明**这批观测就是全库（重复 id、库侧增删、
//     陈旧计数都会造成这种局面）——所以不得据此断言"已覆盖全库"。
// UI 必须把 nil 按"可能不是全库"提示，不得把计数当全库结论展示。
//
// ── 参数刻度：与生产对齐（不再对 floor/retry 抛错）──────────────
// 生产路径 FaceKwService.clusterOptions(from:) 对 coreQualityFloor 做
// min(max(v, 0), 1) 夹取，对 retryMinSamples 把 < 2 一律归一为 nil（关闭）；只有
// eps/minPts 在 validateFaceClusteringParameters 里硬性拒绝（eps 非有限或越界
// 0...1、minPts 非整数或 < 1）。本函数同刻度：
//   - 抛错只有两种：.epsOutOfRange（eps 非有限或越界）、.minPtsOutOfRange（< 1）。
//   - coreQualityFloor 不抛错，按生产同款表达式 min(max(v, 0), 1) 夹取（±∞ 分别
//     落到 0/1）；retryMinSamples < 2（含 0/负数）归一为 nil。
//   - current 与 proposed 都做同样的归一化；parametersChanged 比较归一化后的值，
//     因此 floor -0.5 与 0、retry 1 与 nil 不会误报"参数变了"。
//   - 实际会用的参数放在 normalizedParameters（proposed 归一化后的值）。
//
// ── 规范簇 id（只在单次调用内稳定）──────────────────────────────
// 一个簇的规范 id = 该簇全体成员中最小的 observationId。选择最小 id 而不是
// 簇在结果数组里的下标（FaceClusterer 按 BFS 发现顺序输出，输入顺序变化或
// 边界点归属变化都会让下标漂移），这样"同一划分"在任意输入顺序下得到同一组
// 规范 id，不会把纯粹的顺序差异误报成"簇变了"。
// 旧侧同样规范化：currentAssignment 的 value 是 DB 簇 id（与试算结果的规范 id
// 不同刻度、不可直接比较），先把当前观测按 DB 簇 id 分组，再取每组最小
// observationId 作为该旧簇的规范 id。两侧由此落在同一比较尺度上。
// 稳定性边界（不可越界使用）：
//   - 规范 id 只在**单次 estimate 调用内**稳定，跨调用不可比较：照片重分析会重建
//     observation（新 observationId），旧行残留时同一张脸换 id，规范 id 随之漂移。
//   - 它不是持久键：不得写库、不得跨调用 join、不得与 DB 簇 id 混用。
//   - 簇内最小成员离开该簇时，剩余成员会被标成新的规范 id：一次"整簇改名"会看起来
//     像"旧簇消失 + 新簇出现"（见 appeared/disappeared 的已知合并行为）。
//
// ── changedClusterCount 的精确定义（冻结）────────────────────────
// 以"每个 observation 所属簇的规范 id"为键，把新、旧两侧都表达成
// 规范 id → 成员集合（Set<observationId>）；缺席一侧按空集处理。
//   changedClusterCount = |{ k ∈ keys(旧) ∪ keys(新) : oldMembers[k] ≠ newMembers[k] }|
// 即"成员集合发生变化的簇数"，覆盖：成员增删、整体消失（只在旧侧）、
// 整体新增（只在新侧）。空集 → 0。该定义只看集合内容，与簇输出顺序无关。
// 同一次比较另给两个精确拆分（同刻度）：
//   appearedClusterCount    = |keys(新)  keys(旧)|
//   disappearedClusterCount = |keys(旧) \ keys(新)|
// 已知合并行为：规范 id 改名（上一节）会让"改名"同时计入 disappeared 与 appeared；
// 没有持久身份可用时这是无法再拆细的边界，不做猜测性修正。
//
// ── reassignedFaceCount 与 changedClusterCount 的关系（不是互补）──
// reassignedFaceCount 逐条目比较"旧规范 id vs 新规范 id"（噪声 = 缺席），不同即
// 计数：含噪声进簇、簇回噪声、换到别的簇。两个字段不是"互补"，而是同一信号的两个
// 粒度，且**同零或同正**：
//   - changed > 0 ⟹ reassigned > 0：成员集合变化的簇里取一个落在对称差里的
//     observation，它不可能两侧映射到同一规范 id（若新侧仍映射到 k 就属于
//     newMembers[k]），必被计一次。
//   - reassigned > 0 ⟹ changed > 0：某条脸换了规范归属，它离开的簇与加入的簇至少
//     有一侧成员集合不同。
// 因此 clusterCountBefore == clusterCountAfter 也不代表划分没变（成员可以整批换人）。
//
// ── parametersChanged / partitionChanged（UI 怎么用）──────────────
// - parametersChanged：归一化后的 current ≠ 归一化后的 proposed。
// - partitionChanged = reassignedFaceCount > 0 || changedClusterCount > 0（由上一节，
//   二者同零同正，写成 OR 只是冻结口径）。
// UI 语义：
//   - partitionChanged == true → 需要真正的重聚类（删簇重建）。
//   - parametersChanged && !partitionChanged → 只提示"参数已改、划分预计不变"，
//     **不要触发昂贵的删簇重建**。
//   - 两者都 false → 无变化，禁用"重算"。
//   - 以上都只针对传入观测集；全库是否变仍需全库试算判定（见第一节）。
// requiresRecluster 已删除：它把"参数变"和"划分变"混在一个布尔里，接 UI 会在划分
// 完全没变时也触发删簇重建。
//
// ── 成本、可取消性与进度 ─────────────────────────────────────────
// 成本完全由 FaceClusterer.clusterEmbeddings 决定：
//   - n ≤ CosineLshIndex.lshMinPoints（20_000；启用条件为严格 n > minPoints）走精确
//     分支，O(n²·d) 次点积；n = 20_000 恰好落在这一侧。
//   - 实测参考：2_000 条约 28.5s（debug 构建）；20_000 条在生产规模上不可接受，
//     调用方必须先做规模判断/降采样，或明确告知用户耗时。
//   - 本函数同步：单次 estimate 在调用线程跑完整趟聚类，**中途不可取消**（内核没有
//     取消检查点，本文件不能改 Clusterer）。只在入口与内核返回后各做一次
//     Task.checkCancellation()；已取消则抛 CancellationError，避免把约 28s 前算出的
//     陈旧结果当新结果返回。
//   - 接 UI 前必须改造：放到后台/独立任务执行，用 onProgress 报进度，取消时丢弃结果；
//     若要内核中途真正中止，需要在 Clusterer 内部加取消检查点。
//   - onProgress：(已完成, 总数) 透传内核，单调不回退；在调用线程同步回调，不要在
//     闭包里做重活，也不要把它当取消机制。
//
// ── 其他字段口径 ─────────────────────────────────────────────────
// - faceCount：输入观测的条目数（observationId 预期唯一，见下）。
// - clusterCountBefore：传入观测在 currentAssignment 中覆盖的不同 DB 簇数（按
//   observations 过滤，陈旧条目不计入；**不是全库簇数**）。
// - noiseCountBefore：observations 中在 currentAssignment 里无映射的条目数。
// - clusterCountAfter / noiseCountAfter / largestClusterAfter：直接取自试算结果
//   （簇数按规范 id 去重；最大簇 = 成员最多的簇的成员数，无簇为 0）。
// - normalizedParameters：proposed 归一化后的实际参数。
//
// ── 边界与前置条件 ───────────────────────────────────────────────
// - 空观测集：参数校验通过后短路返回全 0；parametersChanged 照常按归一化比较，
//   partitionChanged = false（没有可重算的脸）。isSubsetOfLibrary 仍按传入规模判定
//   （无法判定时为 nil，见文件头：本字段不存在 false）。
// - 非法参数（eps 非有限或越界、minPts < 1）抛 FaceClusteringImpactError；校验先于
//   空集短路，即使观测为空也拒绝非法参数。current 与 proposed 都校验。
// - 取消：入口与内核返回后可能抛 CancellationError。
// - observationId 预期唯一（DB 主键）。重复 id 属调用方错误：本函数不抛错，
//   faceCount/noise 按条目计数，规范映射对重复 id 取最小规范 id 收敛（仍确定）。
// - 纯函数、无 IO、无全局状态、无随机性；不写库、不改状态、不触发任务。
import Foundation

/// 一组人脸聚类参数（与 settings 同刻度；语义见 FaceClusterer 文件头）。
/// eps 是相似度下限（越大越严格，0...1）；minPts = DBSCAN 核心点邻域阈值（≥ 1）；
/// coreQualityFloor = 核心点质量门槛（0...1，0 = 不设限）；retryMinSamples = 二遍
/// 核心点阈值（nil = 关闭）。floor/retry 在落到内核前会按生产规则归一化，见 normalized()。
public struct FaceClusteringParameters: Equatable, Sendable {
    /// 相似度下限（越大越严），值域 0...1。
    public var eps: Double
    /// DBSCAN minPts，≥ 1。
    public var minPts: Int
    /// 核心点质量门槛；生产会夹取到 0...1（0 = 不设限）。
    public var coreQualityFloor: Double
    /// 二遍核心点阈值；nil = 关闭（生产刻度下 < 2 等价关闭）。
    public var retryMinSamples: Int?

    public init(eps: Double, minPts: Int, coreQualityFloor: Double = 0, retryMinSamples: Int? = nil) {
        self.eps = eps
        self.minPts = minPts
        self.coreQualityFloor = coreQualityFloor
        self.retryMinSamples = retryMinSamples
    }

    /// 归一化到生产实际使用的刻度（与 FaceKwService.clusterOptions(from:) 同规则）：
    /// - coreQualityFloor = min(max(v, 0), 1)（生产同款表达式；±∞ 分别夹到 0/1）
    /// - retryMinSamples < 2（含 0/负数）→ nil（生产把 < 2 一律视为关闭）
    /// eps/minPts 不归一化：生产入口对它们是硬性拒绝（见 estimate 的抛错）。
    public func normalized() -> FaceClusteringParameters {
        let floor = min(max(coreQualityFloor, 0), 1)
        var retry: Int? = nil
        if let value = retryMinSamples, value >= 2 { retry = value }
        return FaceClusteringParameters(
            eps: eps, minPts: minPts, coreQualityFloor: floor, retryMinSamples: retry)
    }
}

/// 试算结果（全部为计数与差值，不含 embedding）。
public struct FaceClusteringImpact: Equatable, Sendable {
    /// 参与试算的观测条目数。
    public let faceCount: Int
    /// 传入观测在 currentAssignment 中覆盖的簇数（按规范 id 去重；**不是全库簇数**）。
    public let clusterCountBefore: Int
    /// 试算结果簇数（同一次调用内，也只覆盖传入观测）。
    public let clusterCountAfter: Int
    /// 当前处于噪声的观测条目数。
    public let noiseCountBefore: Int
    /// 试算后处于噪声的观测条目数。
    public let noiseCountAfter: Int
    /// 与"当前分配"相比换了簇的脸数（含从噪声进簇、从簇回噪声）。
    public let reassignedFaceCount: Int
    /// 与"当前分配"相比成员集合变化的规范簇数（含新增/消失簇；口径见文件头）。
    public let changedClusterCount: Int
    /// 新侧有、旧侧没有的规范簇数（精确拆分，口径见文件头）。
    public let appearedClusterCount: Int
    /// 旧侧有、新侧没有的规范簇数（精确拆分，口径见文件头）。
    public let disappearedClusterCount: Int
    /// 试算结果中最大簇的成员数（无簇为 0）。
    public let largestClusterAfter: Int
    /// 归一化后的 current ≠ 归一化后的 proposed（floor/retry 按生产刻度比较）。
    public let parametersChanged: Bool
    /// reassignedFaceCount > 0 || changedClusterCount > 0（划分是否真的变了）。
    public let partitionChanged: Bool
    /// proposed 归一化后的实际参数（库侧真正会用的刻度）。
    public let normalizedParameters: FaceClusteringParameters
    /// 试算集相对全库是否为子集：true = 已证明是子集；nil = 无法判定（未提供库规模，
    /// 或传入数 ≥ 库计数——库计数可能过期，传入数不小于库数并不证明覆盖全库）。
    /// 不存在 false 这个结论：本类型不把「计数 ≥ 库数」当作已覆盖全库的证据。
    public let isSubsetOfLibrary: Bool?

    public init(
        faceCount: Int,
        clusterCountBefore: Int,
        clusterCountAfter: Int,
        noiseCountBefore: Int,
        noiseCountAfter: Int,
        reassignedFaceCount: Int,
        changedClusterCount: Int,
        appearedClusterCount: Int,
        disappearedClusterCount: Int,
        largestClusterAfter: Int,
        parametersChanged: Bool,
        partitionChanged: Bool,
        normalizedParameters: FaceClusteringParameters,
        isSubsetOfLibrary: Bool?
    ) {
        self.faceCount = faceCount
        self.clusterCountBefore = clusterCountBefore
        self.clusterCountAfter = clusterCountAfter
        self.noiseCountBefore = noiseCountBefore
        self.noiseCountAfter = noiseCountAfter
        self.reassignedFaceCount = reassignedFaceCount
        self.changedClusterCount = changedClusterCount
        self.appearedClusterCount = appearedClusterCount
        self.disappearedClusterCount = disappearedClusterCount
        self.largestClusterAfter = largestClusterAfter
        self.parametersChanged = parametersChanged
        self.partitionChanged = partitionChanged
        self.normalizedParameters = normalizedParameters
        self.isSubsetOfLibrary = isSubsetOfLibrary
    }
}

/// 试算输入的一条观测（id/photoId/embedding/quality，不含簇归属）。
public struct FaceImpactObservation: Equatable, Sendable {
    public let observationId: Int
    public let photoId: String
    public let embedding: [Float]
    public let quality: Double

    public init(observationId: Int, photoId: String, embedding: [Float], quality: Double) {
        self.observationId = observationId
        self.photoId = photoId
        self.embedding = embedding
        self.quality = quality
    }
}

/// 试算参数非法（与生产入口 validateFaceClusteringParameters 同刻度：eps/minPts 硬性
/// 拒绝，floor/retry 归一化而不抛错）。
public enum FaceClusteringImpactError: Error, Equatable, Sendable {
    /// eps（相似度下限）越界或非有限；合法域 FaceClusterer.similarityThresholdRange = 0...1。
    case epsOutOfRange(Double)
    /// minPts < 1（DBSCAN 核心点邻域阈值至少 1）。
    case minPtsOutOfRange(Int)
}

public enum FaceClusteringImpactEstimator {
    /// 只读试算：用现有观测跑一遍聚类（不写库），与当前分配对比。
    /// - Parameters:
    ///   - observations: 现有观测（id/photoId/embedding/quality）；**所有计数只对这批
    ///     条目成立**，子集试算不等于全库试算（见文件头）。
    ///   - currentAssignment: observationId → 现有簇 id（无 = 噪声）
    ///   - current: 当前参数（先归一化再与 proposed 比较；eps/minPts 非法即抛错）
    ///   - proposed: 拟用参数（floor/retry 归一化，eps/minPts 非法即抛错）
    ///   - libraryFaceCount: 库内全部观测条目数（可选；仅在小于传入条目数时证明
    ///     "是子集"，否则不足以判定——库计数可能过期）
    ///   - libraryClusterCount: 库内现有簇总数（可选；同样只能证明"是子集"）
    ///   - onProgress: (已完成, 总数) 透传内核；同步回调，不改变计数
    ///   - lshOptions: 内核 LSH 开关（n > minPoints 才启用，默认 20_000）
    /// - Throws: FaceClusteringImpactError（eps/minPts 非法）、CancellationError
    ///   （入口或内核返回后发现任务已取消）。
    public static func estimate(
        observations: [FaceImpactObservation],
        currentAssignment: [Int: Int],
        current: FaceClusteringParameters,
        proposed: FaceClusteringParameters,
        libraryFaceCount: Int? = nil,
        libraryClusterCount: Int? = nil,
        onProgress: ((Int, Int) -> Void)? = nil,
        lshOptions: ClusterLshOptions = .default
    ) throws -> FaceClusteringImpact {
        // 单次调用同步跑完整趟聚类，内核中途没有取消点；入口/出口各检查一次。
        try Task.checkCancellation()

        // 参数校验先于空集短路：非法参数永远显式拒绝。floor/retry 不校验（归一化）。
        try validate(proposed)
        try validate(current)

        let normalizedProposed = proposed.normalized()
        let parametersChanged = current.normalized() != normalizedProposed

        let faceCount = observations.count
        if faceCount == 0 {
            return FaceClusteringImpact(
                faceCount: 0,
                clusterCountBefore: 0,
                clusterCountAfter: 0,
                noiseCountBefore: 0,
                noiseCountAfter: 0,
                reassignedFaceCount: 0,
                changedClusterCount: 0,
                appearedClusterCount: 0,
                disappearedClusterCount: 0,
                largestClusterAfter: 0,
                parametersChanged: parametersChanged,
                partitionChanged: false,
                normalizedParameters: normalizedProposed,
                isSubsetOfLibrary: subsetFlag(
                    faceCount: 0,
                    clusterCountBefore: 0,
                    libraryFaceCount: libraryFaceCount,
                    libraryClusterCount: libraryClusterCount))
        }

        let entries = observations.map { observation in
            EmbeddingEntry(
                observationId: observation.observationId,
                photoId: observation.photoId,
                embedding: observation.embedding,
                quality: observation.quality)
        }
        let result = try FaceClusterer.clusterEmbeddings(
            entries: entries,
            eps: normalizedProposed.eps,
            minPts: normalizedProposed.minPts,
            coreQualityFloor: normalizedProposed.coreQualityFloor,
            retryMinSamples: normalizedProposed.retryMinSamples,
            onProgress: onProgress,
            lshOptions: lshOptions)

        // 长耗时调用返回后再检查一次：已取消就不把陈旧结果当新结果返回。
        try Task.checkCancellation()

        // 新侧：规范 id = 簇内最小 observationId。members 用 Set 表达，比较只看集合内容。
        var newCanonicalByObservation: [Int: Int] = [:]
        var newMembersByCluster: [Int: Set<Int>] = [:]
        for cluster in result.clusters {
            let ids = cluster.map(\.observationId)
            guard let canonicalId = ids.min() else { continue }
            newMembersByCluster[canonicalId, default: []].formUnion(ids)
            for id in ids {
                if let existing = newCanonicalByObservation[id] {
                    newCanonicalByObservation[id] = min(existing, canonicalId)
                } else {
                    newCanonicalByObservation[id] = canonicalId
                }
            }
        }

        // 旧侧：先把观测按 DB 簇 id 分组，再取每组最小 observationId 作为旧规范 id
        //（与试算结果同尺度比较）。currentAssignment 中不属于 observations 的条目忽略。
        var rawOldMembers: [Int: Set<Int>] = [:]
        var noiseCountBefore = 0
        for observation in observations {
            guard let rawClusterId = currentAssignment[observation.observationId] else {
                noiseCountBefore += 1
                continue
            }
            rawOldMembers[rawClusterId, default: []].insert(observation.observationId)
        }
        var oldCanonicalByObservation: [Int: Int] = [:]
        var oldMembersByCluster: [Int: Set<Int>] = [:]
        for members in rawOldMembers.values {
            guard let canonicalId = members.min() else { continue }
            oldMembersByCluster[canonicalId, default: []].formUnion(members)
            for id in members { oldCanonicalByObservation[id] = canonicalId }
        }

        // 逐条目：旧的规范簇 id vs 新的规范簇 id（噪声 = 缺席），不同即换簇。
        var reassignedFaceCount = 0
        for observation in observations {
            if oldCanonicalByObservation[observation.observationId]
                != newCanonicalByObservation[observation.observationId] {
                reassignedFaceCount += 1
            }
        }

        // 逐规范 id：成员集合变化即计入（含只在旧侧 / 只在新侧的簇）。
        let allCanonicalIds = Set(oldMembersByCluster.keys).union(newMembersByCluster.keys)
        var changedClusterCount = 0
        for canonicalId in allCanonicalIds {
            let before = oldMembersByCluster[canonicalId] ?? []
            let after = newMembersByCluster[canonicalId] ?? []
            if before != after { changedClusterCount += 1 }
        }
        let appearedClusterCount = Set(newMembersByCluster.keys)
            .subtracting(oldMembersByCluster.keys).count
        let disappearedClusterCount = Set(oldMembersByCluster.keys)
            .subtracting(newMembersByCluster.keys).count

        let largestClusterAfter = newMembersByCluster.values.map(\.count).max() ?? 0
        let clusterCountBefore = oldMembersByCluster.count
        let partitionChanged = reassignedFaceCount > 0 || changedClusterCount > 0

        return FaceClusteringImpact(
            faceCount: faceCount,
            clusterCountBefore: clusterCountBefore,
            clusterCountAfter: newMembersByCluster.count,
            noiseCountBefore: noiseCountBefore,
            noiseCountAfter: result.noise.count,
            reassignedFaceCount: reassignedFaceCount,
            changedClusterCount: changedClusterCount,
            appearedClusterCount: appearedClusterCount,
            disappearedClusterCount: disappearedClusterCount,
            largestClusterAfter: largestClusterAfter,
            parametersChanged: parametersChanged,
            partitionChanged: partitionChanged,
            normalizedParameters: normalizedProposed,
            isSubsetOfLibrary: subsetFlag(
                faceCount: faceCount,
                clusterCountBefore: clusterCountBefore,
                libraryFaceCount: libraryFaceCount,
                libraryClusterCount: libraryClusterCount))
    }

    /// 参数校验：只拒绝生产入口也会拒绝的值（eps 非有限或越界、minPts < 1）。
    /// floor/retry 由 normalized() 按生产规则归一化，不在这里抛错。
    private static func validate(_ parameters: FaceClusteringParameters) throws {
        guard parameters.eps.isFinite,
            FaceClusterer.similarityThresholdRange.contains(parameters.eps)
        else {
            throw FaceClusteringImpactError.epsOutOfRange(parameters.eps)
        }
        guard parameters.minPts >= 1 else {
            throw FaceClusteringImpactError.minPtsOutOfRange(parameters.minPts)
        }
    }

    /// 依据调用方提供的库规模判定试算集相对全库的覆盖，只有 true / nil 两态：
    /// - 有 libraryFaceCount 时它是唯一权威：faceCount < libraryFaceCount → true；
    ///   faceCount >= libraryFaceCount → nil。传入数不小于库计数**不构成**"已覆盖
    ///   全库"的证明（库计数可能过期、observations 也可能含重复/陈旧条目），故不返回
    ///   false；给了 libraryFaceCount 就不再回落到簇数维度（避免两维口径混用）。
    /// - 只有 libraryClusterCount 时只能证明"是子集"（覆盖的现簇数更少 → true），
    ///   相等/更大时无法据此判定 → nil（不猜）。
    /// - 两个都没有 → nil。
    private static func subsetFlag(
        faceCount: Int,
        clusterCountBefore: Int,
        libraryFaceCount: Int?,
        libraryClusterCount: Int?
    ) -> Bool? {
        if let libraryFaceCount {
            return faceCount < libraryFaceCount ? true : nil
        }
        if let libraryClusterCount, clusterCountBefore < libraryClusterCount {
            return true
        }
        return nil
    }
}
