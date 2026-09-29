// desktop/native/gather-core/Tests/GatherCoreTests/Face/ClusteringImpactTests.swift
// 聚类参数只读试算行为测试（9 组）：
//   1. 参数不变 → parametersChanged/partitionChanged 均 false、换簇 0
//      （旧侧用非规范 DB id 构造，证明比较落在规范簇 id 上）
//   2. 收紧 eps（0.6 → 0.95）→ 簇数增加、换簇 > 0，且与直接调用 FaceClusterer 一致
//   3. 质量门槛提高（0 → 0.5）→ 低质量样本转噪声/边界（数字断言）
//   4. retryMinSamples nil → 2 → 噪声减少、簇数增加且不合并原有簇
//   5. 边界：空观测、非法参数（含空观测也抛错）、单个观测（噪声）
//   6. 打乱 observations 顺序 → 结果逐字段不变（规范 id 而非顺序）
//   7. 子集标记（只有 true/nil，从不存在 false）：库规模由调用方传入，faceCount
//      优先，clusterCount 只能证"是子集"；"传入数 ≥ 库数"只是无法判定，不是覆盖证据
//   8. 归一化与生产同刻度：floor 夹取 0...1、retry < 2 → nil（对照 FaceKwService）
//   9. 取消：入口已取消 → 抛 CancellationError（内核中途仍不可取消，见文件头）
// 全部断言为可复现的整数/布尔量；向量取可精确表示的 0/1 与 [1,1,0,0]（余弦 0.7071…）。

import Testing
@testable import GatherCore

struct ClusteringImpactTests {
    // MARK: - 夹具

    private static func observation(
        _ id: Int, _ embedding: [Float], quality: Double = 1.0
    ) -> FaceImpactObservation {
        FaceImpactObservation(
            observationId: id, photoId: "p\(id)", embedding: embedding, quality: quality)
    }

    private static func entries(_ observations: [FaceImpactObservation]) -> [EmbeddingEntry] {
        observations.map { observation in
            EmbeddingEntry(
                observationId: observation.observationId,
                photoId: observation.photoId,
                embedding: observation.embedding,
                quality: observation.quality)
        }
    }

    /// 模拟"当前已落库"的 observationId → 簇 id 映射（用给定参数跑一遍内核）。
    /// opaqueBase = nil 时簇 id 取规范 id（簇内最小 observationId）；非 nil 时用
    /// opaqueBase + 簇序号，模拟与规范 id 不同刻度的 DB 簇 id。
    private static func assignment(
        for observations: [FaceImpactObservation],
        parameters: FaceClusteringParameters,
        opaqueBase: Int? = nil
    ) throws -> [Int: Int] {
        let result = try FaceClusterer.clusterEmbeddings(
            entries: entries(observations),
            eps: parameters.eps,
            minPts: parameters.minPts,
            coreQualityFloor: parameters.coreQualityFloor,
            retryMinSamples: parameters.retryMinSamples)
        var mapping: [Int: Int] = [:]
        for (index, cluster) in result.clusters.enumerated() {
            let clusterId = opaqueBase.map { $0 + index } ?? cluster.map(\.observationId).min() ?? 0
            for entry in cluster { mapping[entry.observationId] = clusterId }
        }
        return mapping
    }

    /// 捕获 estimate 抛出的 FaceClusteringImpactError（非本类型错误记为测试失败）。
    private static func capturedError(
        observations: [FaceImpactObservation] = [],
        currentAssignment: [Int: Int] = [:],
        current: FaceClusteringParameters = FaceClusteringParameters(eps: 0.6, minPts: 2),
        proposed: FaceClusteringParameters
    ) -> FaceClusteringImpactError? {
        do {
            _ = try FaceClusteringImpactEstimator.estimate(
                observations: observations,
                currentAssignment: currentAssignment,
                current: current,
                proposed: proposed)
            return nil
        } catch let error as FaceClusteringImpactError {
            return error
        } catch {
            Issue.record("抛出了非 FaceClusteringImpactError 的错误")
            return nil
        }
    }

    // MARK: - 1. 参数不变

    @Test("参数不变：parametersChanged/partitionChanged 均 false、换簇 0（旧侧非规范 DB id 也要识别为同一划分）")
    func unchangedParametersReportNoRecluster() throws {
        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0]),
            Self.observation(5, [0, 1, 0, 0]),
            Self.observation(6, [0, 0, 1, 0]),  // 孤立点 → 噪声
        ]
        let parameters = FaceClusteringParameters(eps: 0.9, minPts: 2)

        // 旧侧故意用 900/901 这种"非规范"簇 id：比较必须规范化到簇内最小 observationId，
        // 否则同一划分会被误判为"全变了"。
        let currentAssignment = try Self.assignment(
            for: observations, parameters: parameters, opaqueBase: 900)
        #expect(currentAssignment == [1: 900, 2: 900, 3: 900, 4: 901, 5: 901])

        let impact = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: parameters)
        #expect(impact.faceCount == 6)
        #expect(impact.clusterCountBefore == 2)
        #expect(impact.clusterCountAfter == 2)
        #expect(impact.noiseCountBefore == 1)
        #expect(impact.noiseCountAfter == 1)
        #expect(impact.reassignedFaceCount == 0)
        #expect(impact.changedClusterCount == 0)
        #expect(impact.appearedClusterCount == 0)
        #expect(impact.disappearedClusterCount == 0)
        #expect(impact.largestClusterAfter == 3)
        #expect(impact.parametersChanged == false)
        #expect(impact.partitionChanged == false)
        #expect(impact.normalizedParameters == parameters)
        #expect(impact.isSubsetOfLibrary == nil, "未提供库规模 → 无法判定")

        // 参数变了但划分恰好不变：parametersChanged=true / partitionChanged=false。
        // UI 只能提示"参数已改、划分预计不变"，不得触发删簇重建。
        let samePartitionNewParams = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: 0.5))
        #expect(samePartitionNewParams.reassignedFaceCount == 0)
        #expect(samePartitionNewParams.changedClusterCount == 0)
        #expect(samePartitionNewParams.parametersChanged, "floor 0 → 0.5 是真实参数变化")
        #expect(samePartitionNewParams.partitionChanged == false, "划分没变 → 不删簇重建")
        #expect(samePartitionNewParams.normalizedParameters.coreQualityFloor == 0.5)
    }

    // MARK: - 2. 收紧 eps

    @Test("收紧 eps 0.6 → 0.95：簇数 1 → 2、换簇 2，与直接调用 FaceClusterer 一致")
    func tightenedEpsSplitsClustersAndMatchesDirectKernel() throws {
        // A = [1,0,0,0]，B = [1,1,0,0]：A·B = 0.7071…，A·A = B·B = 1。
        // eps=0.6 时 A/B 互相是邻居 → 单一簇；eps=0.95 时只剩组内相似 → 两组。
        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 1, 0, 0]),
            Self.observation(4, [1, 1, 0, 0]),
        ]
        let current = FaceClusteringParameters(eps: 0.6, minPts: 2)
        let proposed = FaceClusteringParameters(eps: 0.95, minPts: 2)

        let currentAssignment = try Self.assignment(for: observations, parameters: current)
        #expect(currentAssignment == [1: 1, 2: 1, 3: 1, 4: 1], "0.6 时四点同簇")

        var progressSamples: [(Int, Int)] = []
        let impact = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: current,
            proposed: proposed,
            onProgress: { progressSamples.append(($0, $1)) })
        #expect(impact.faceCount == 4)
        #expect(impact.clusterCountBefore == 1)
        #expect(impact.clusterCountAfter == 2, "收紧 eps → 簇数增加")
        #expect(impact.noiseCountBefore == 0)
        #expect(impact.noiseCountAfter == 0)
        #expect(impact.reassignedFaceCount == 2, "3、4 从规范簇 1 换到规范簇 3")
        #expect(impact.changedClusterCount == 2, "规范簇 1 成员缩减 + 规范簇 3 新增")
        #expect(impact.appearedClusterCount == 1, "规范簇 3 是新出现的")
        #expect(impact.disappearedClusterCount == 0, "规范簇 1 仍在，只是成员缩减")
        #expect(impact.largestClusterAfter == 2)
        #expect(impact.parametersChanged)
        #expect(impact.partitionChanged)
        #expect(impact.normalizedParameters == proposed)
        #expect(progressSamples.isEmpty == false, "onProgress 必须被内核回调")
        #expect(progressSamples.last?.0 == 4, "onProgress 透传内核并收敛到 (n, n)")
        #expect(progressSamples.last?.1 == 4, "onProgress 透传内核并收敛到 (n, n)")

        // 与直接调用内核一致（计数与成员集合）。
        let direct = try FaceClusterer.clusterEmbeddings(
            entries: Self.entries(observations),
            eps: proposed.eps,
            minPts: proposed.minPts,
            coreQualityFloor: proposed.coreQualityFloor,
            retryMinSamples: proposed.retryMinSamples)
        #expect(direct.clusters.count == impact.clusterCountAfter)
        #expect(direct.noise.count == impact.noiseCountAfter)
        #expect((direct.clusters.map(\.count).max() ?? 0) == impact.largestClusterAfter)
        #expect(Set(direct.clusters.map { Set($0.map(\.observationId)) }) == Set([Set([1, 2]), Set([3, 4])]))
    }

    // MARK: - 3. 质量门槛

    @Test("质量门槛 0 → 0.5：低质量对从成簇变噪声，低质量边界点仍被吸收")
    func raisedQualityFloorMovesLowQualityToNoiseOrBorder() throws {
        let noFloor = FaceClusteringParameters(eps: 0.9, minPts: 2)
        let gated = FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: 0.5)

        // (a) 低质量对（q=0.1）在 floor=0 时自成一簇，floor=0.5 时无权带簇 → 噪声。
        let lowQualityPair = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0], quality: 0.1),
            Self.observation(5, [0, 1, 0, 0], quality: 0.1),
        ]
        let pairBefore = try Self.assignment(for: lowQualityPair, parameters: noFloor)
        #expect(pairBefore == [1: 1, 2: 1, 3: 1, 4: 4, 5: 4])

        let pairImpact = try FaceClusteringImpactEstimator.estimate(
            observations: lowQualityPair,
            currentAssignment: pairBefore,
            current: noFloor,
            proposed: gated)
        #expect(pairImpact.clusterCountBefore == 2)
        #expect(pairImpact.clusterCountAfter == 1, "低质量对不再成簇")
        #expect(pairImpact.noiseCountBefore == 0)
        #expect(pairImpact.noiseCountAfter == 2, "4、5 转噪声")
        #expect(pairImpact.reassignedFaceCount == 2)
        #expect(pairImpact.changedClusterCount == 1)
        #expect(pairImpact.appearedClusterCount == 0)
        #expect(pairImpact.disappearedClusterCount == 1, "规范簇 4 整体消失")
        #expect(pairImpact.largestClusterAfter == 3)
        #expect(pairImpact.parametersChanged)
        #expect(pairImpact.partitionChanged)

        let directPair = try FaceClusterer.clusterEmbeddings(
            entries: Self.entries(lowQualityPair), eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(directPair.clusters.count == 1)
        #expect(Set(directPair.noise.map(\.observationId)) == [4, 5])

        // (b) 低质量点（q=0.2）与高质量簇互相相似：floor=0.5 时不能当种子，但被吸收为边界点，
        //     不从结果里消失 —— 划分不变、噪声仍为 0，只是参数变了，UI 只提示不重建。
        let border = [
            Self.observation(11, [1, 0, 0, 0], quality: 0.2),
            Self.observation(12, [1, 0, 0, 0]),
            Self.observation(13, [1, 0, 0, 0]),
        ]
        let borderBefore = try Self.assignment(for: border, parameters: noFloor)
        let borderImpact = try FaceClusteringImpactEstimator.estimate(
            observations: border,
            currentAssignment: borderBefore,
            current: noFloor,
            proposed: gated)
        let directBorder = try FaceClusterer.clusterEmbeddings(
            entries: Self.entries(border), eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(directBorder.noise.isEmpty, "低质量边界点不得被丢弃")
        #expect(directBorder.clusters.count == 1)
        #expect(Set(directBorder.clusters[0].map(\.observationId)) == [11, 12, 13])
        #expect(borderImpact.clusterCountAfter == 1)
        #expect(borderImpact.noiseCountAfter == 0)
        #expect(borderImpact.largestClusterAfter == 3)
        #expect(borderImpact.reassignedFaceCount == 0)
        #expect(borderImpact.changedClusterCount == 0)
        #expect(borderImpact.appearedClusterCount == 0)
        #expect(borderImpact.disappearedClusterCount == 0)
        #expect(borderImpact.parametersChanged, "划分未变但质量门槛变了")
        #expect(borderImpact.partitionChanged == false, "划分未变 → 不删簇重建")
        #expect(borderImpact.normalizedParameters.coreQualityFloor == 0.5)
    }

    // MARK: - 4. retryMinSamples

    @Test("retry nil → 2：噪声 2 → 0、簇数 1 → 2，且不合并原有簇")
    func retryMinSamplesRecoversNoiseWithoutMergingExistingClusters() throws {
        // minPts=3：{1,2,3} 三点互似成簇；{4,5} 只互为邻居（1 < minNeighbors=2）→ noise。
        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0]),
            Self.observation(5, [0, 1, 0, 0]),
        ]
        let current = FaceClusteringParameters(eps: 0.9, minPts: 3)
        let proposed = FaceClusteringParameters(eps: 0.9, minPts: 3, retryMinSamples: 2)

        let currentAssignment = try Self.assignment(for: observations, parameters: current)
        #expect(currentAssignment == [1: 1, 2: 1, 3: 1])

        let impact = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: current,
            proposed: proposed)
        #expect(impact.faceCount == 5)
        #expect(impact.clusterCountBefore == 1)
        #expect(impact.clusterCountAfter == 2)
        #expect(impact.clusterCountAfter >= impact.clusterCountBefore)
        #expect(impact.noiseCountBefore == 2)
        #expect(impact.noiseCountAfter == 0, "retry 把噪声收进新簇")
        #expect(impact.noiseCountAfter < impact.noiseCountBefore)
        #expect(impact.reassignedFaceCount == 2, "4、5 从噪声进簇")
        #expect(impact.changedClusterCount == 1, "原簇成员不变，仅新增一个簇")
        #expect(impact.appearedClusterCount == 1)
        #expect(impact.disappearedClusterCount == 0)
        #expect(impact.largestClusterAfter == 3, "原簇 {1,2,3} 未被合并/扩编")
        #expect(impact.parametersChanged)
        #expect(impact.partitionChanged)
        #expect(impact.normalizedParameters.retryMinSamples == 2)

        // 内核直调核对：第一遍簇原样保留，retry 新簇追加且互不合并。
        let direct = try FaceClusterer.clusterEmbeddings(
            entries: Self.entries(observations), eps: 0.9, minPts: 3, retryMinSamples: 2)
        #expect(direct.noise.isEmpty)
        #expect(Set(direct.clusters.map { Set($0.map(\.observationId)) }) == Set([Set([1, 2, 3]), Set([4, 5])]))
    }

    // MARK: - 5. 边界

    @Test("边界：空观测全 0、非法参数抛错（空观测也抛）、单观测为噪声")
    func emptySingleObservationAndInvalidParameterBoundaries() throws {
        // (a) 空观测：计数全 0、partitionChanged=false（无脸可算）；参数变化照常上报；
        //     不属于输入观测的陈旧映射条目被忽略；未提供库规模 → isSubsetOfLibrary=nil。
        let empty = try FaceClusteringImpactEstimator.estimate(
            observations: [],
            currentAssignment: [42: 7],
            current: FaceClusteringParameters(eps: 0.6, minPts: 2),
            proposed: FaceClusteringParameters(
                eps: 0.95, minPts: 5, coreQualityFloor: 0.5, retryMinSamples: 2))
        #expect(
            empty
                == FaceClusteringImpact(
                    faceCount: 0, clusterCountBefore: 0, clusterCountAfter: 0,
                    noiseCountBefore: 0, noiseCountAfter: 0, reassignedFaceCount: 0,
                    changedClusterCount: 0, appearedClusterCount: 0,
                    disappearedClusterCount: 0, largestClusterAfter: 0,
                    parametersChanged: true, partitionChanged: false,
                    normalizedParameters: FaceClusteringParameters(
                        eps: 0.95, minPts: 5, coreQualityFloor: 0.5, retryMinSamples: 2),
                    isSubsetOfLibrary: nil))

        // (b) 非法参数：即使观测为空也必须抛错（校验先于空集短路）。
        let base = FaceClusteringParameters(eps: 0.6, minPts: 2)
        #expect(
            Self.capturedError(proposed: FaceClusteringParameters(eps: -0.001, minPts: 2))
                == .epsOutOfRange(-0.001))
        #expect(
            Self.capturedError(proposed: FaceClusteringParameters(eps: 1.001, minPts: 2))
                == .epsOutOfRange(1.001))
        #expect(
            Self.capturedError(proposed: FaceClusteringParameters(eps: .infinity, minPts: 2))
                == .epsOutOfRange(.infinity))
        if case .epsOutOfRange(let value)? = Self.capturedError(
            proposed: FaceClusteringParameters(eps: .nan, minPts: 2)) {
            #expect(value.isNaN)
        } else {
            Issue.record("eps = NaN 必须抛 epsOutOfRange")
        }
        #expect(
            Self.capturedError(proposed: FaceClusteringParameters(eps: 0.6, minPts: 0))
                == .minPtsOutOfRange(0))
        #expect(
            Self.capturedError(proposed: FaceClusteringParameters(eps: 0.6, minPts: -3))
                == .minPtsOutOfRange(-3))

        // floor / retry 不再是错误：与生产同刻度，交给归一化（数值见第 8 组）。
        #expect(
            Self.capturedError(
                proposed: FaceClusteringParameters(eps: 0.6, minPts: 2, coreQualityFloor: -0.01))
                == nil, "floor 越界按生产夹取，不抛错")
        #expect(
            Self.capturedError(
                proposed: FaceClusteringParameters(eps: 0.6, minPts: 2, coreQualityFloor: 1.01))
                == nil, "floor 越界按生产夹取，不抛错")
        #expect(
            Self.capturedError(
                proposed: FaceClusteringParameters(eps: 0.6, minPts: 2, retryMinSamples: 1))
                == nil, "retry < 2 按生产归一为 nil，不抛错")

        // current 非法同样拒绝（坏值不该被静默接受）：eps 与 minPts 都拒绝。
        #expect(
            Self.capturedError(
                current: FaceClusteringParameters(eps: 2, minPts: 2), proposed: base)
                == .epsOutOfRange(2))
        #expect(
            Self.capturedError(
                current: FaceClusteringParameters(eps: 0.6, minPts: 0), proposed: base)
                == .minPtsOutOfRange(0))

        // 合法边界：eps 0/1、minPts 1、floor 1、retry 2 都不抛。
        #expect(Self.capturedError(proposed: FaceClusteringParameters(eps: 0, minPts: 1)) == nil)
        #expect(Self.capturedError(proposed: FaceClusteringParameters(eps: 1, minPts: 2)) == nil)
        #expect(
            Self.capturedError(
                proposed: FaceClusteringParameters(eps: 0.6, minPts: 2, coreQualityFloor: 1))
                == nil)
        #expect(
            Self.capturedError(
                proposed: FaceClusteringParameters(eps: 0.6, minPts: 2, retryMinSamples: 2))
                == nil)

        // (c) 单个观测：邻域为空 → 噪声；minPts=1 时才允许单点簇。
        let single = [Self.observation(1, [1, 0, 0, 0])]
        let baseline = try FaceClusteringImpactEstimator.estimate(
            observations: single, currentAssignment: [:], current: base, proposed: base)
        #expect(baseline.faceCount == 1)
        #expect(baseline.clusterCountBefore == 0)
        #expect(baseline.clusterCountAfter == 0)
        #expect(baseline.noiseCountBefore == 1)
        #expect(baseline.noiseCountAfter == 1)
        #expect(baseline.reassignedFaceCount == 0)
        #expect(baseline.changedClusterCount == 0)
        #expect(baseline.appearedClusterCount == 0)
        #expect(baseline.disappearedClusterCount == 0)
        #expect(baseline.largestClusterAfter == 0)
        #expect(baseline.parametersChanged == false)
        #expect(baseline.partitionChanged == false)
        #expect(baseline.normalizedParameters == base)

        let singlePointCluster = try FaceClusteringImpactEstimator.estimate(
            observations: single,
            currentAssignment: [:],
            current: base,
            proposed: FaceClusteringParameters(eps: 0.6, minPts: 1))
        #expect(singlePointCluster.clusterCountAfter == 1)
        #expect(singlePointCluster.noiseCountAfter == 0)
        #expect(singlePointCluster.largestClusterAfter == 1)
        #expect(singlePointCluster.reassignedFaceCount == 1, "噪声 → 单点簇")
        #expect(singlePointCluster.changedClusterCount == 1)
        #expect(singlePointCluster.appearedClusterCount == 1)
        #expect(singlePointCluster.disappearedClusterCount == 0)
        #expect(singlePointCluster.parametersChanged)
        #expect(singlePointCluster.partitionChanged)
        #expect(singlePointCluster.normalizedParameters.minPts == 1)
    }

    // MARK: - 6. 顺序稳定性

    @Test("打乱 observations 顺序：结果逐字段不变（规范簇 id，与输入顺序无关）")
    func permutedObservationsProduceIdenticalImpact() throws {
        // 组内向量完全相同（余弦 1 ≥ 0.9，每点都是核心点），组间余弦 0；6 为孤立噪声。
        // 因此划分本身与遍历顺序无关，任何差异都只可能来自"用下标当簇 id"这类实现错误。
        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0]),
            Self.observation(5, [0, 1, 0, 0]),
            Self.observation(6, [0, 0, 1, 0]),
        ]
        let parameters = FaceClusteringParameters(eps: 0.9, minPts: 2)
        let currentAssignment = try Self.assignment(for: observations, parameters: parameters)
        #expect(currentAssignment == [1: 1, 2: 1, 3: 1, 4: 4, 5: 4])

        let reversed = Array(observations.reversed())
        let permuted = [
            observations[2], observations[0], observations[5],
            observations[1], observations[4], observations[3],
        ]
        let proposedCases = [
            parameters,  // 参数不变
            FaceClusteringParameters(eps: 0.9, minPts: 2, retryMinSamples: 2),  // 参数变、划分不变
        ]
        for proposed in proposedCases {
            let original = try FaceClusteringImpactEstimator.estimate(
                observations: observations,
                currentAssignment: currentAssignment,
                current: parameters,
                proposed: proposed,
                libraryFaceCount: 6)
            let reversedImpact = try FaceClusteringImpactEstimator.estimate(
                observations: reversed,
                currentAssignment: currentAssignment,
                current: parameters,
                proposed: proposed,
                libraryFaceCount: 6)
            let permutedImpact = try FaceClusteringImpactEstimator.estimate(
                observations: permuted,
                currentAssignment: currentAssignment,
                current: parameters,
                proposed: proposed,
                libraryFaceCount: 6)
            #expect(original == reversedImpact, "倒序结果必须逐字段相同")
            #expect(original == permutedImpact, "任意置换结果必须逐字段相同")
            #expect(original.clusterCountAfter == 2)
            #expect(original.noiseCountAfter == 1)
            #expect(original.reassignedFaceCount == 0)
            #expect(original.changedClusterCount == 0)
            #expect(original.largestClusterAfter == 3)
            #expect(
                original.isSubsetOfLibrary == nil,
                "6 条 = 库规模 → 库计数可能过期，不能断言覆盖全库（本字段永不为 false）")
        }

        // 上界两个用例的两个标记：参数不变 false/false；参数变但划分不变 true/false。
        let unchanged = try FaceClusteringImpactEstimator.estimate(
            observations: reversed, currentAssignment: currentAssignment,
            current: parameters, proposed: parameters)
        #expect(unchanged.parametersChanged == false)
        #expect(unchanged.partitionChanged == false)
        let retried = try FaceClusteringImpactEstimator.estimate(
            observations: permuted, currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, retryMinSamples: 2))
        #expect(retried.parametersChanged, "retry 参数变了 → 提示参数变化")
        #expect(retried.partitionChanged == false, "该夹具里噪声 6 仍不成簇，划分不变 → 不重建")
        #expect(retried.clusterCountAfter == 2)
        #expect(retried.noiseCountAfter == 1)
    }

    // MARK: - 7. 子集标记

    @Test("子集标记：库规模由调用方传入；faceCount 优先，clusterCount 只能证子集")
    func subsetCoverageIsReportedFromCallerProvidedLibraryScale() throws {
        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0]),
            Self.observation(5, [0, 1, 0, 0]),
            Self.observation(6, [0, 0, 1, 0]),
        ]
        let parameters = FaceClusteringParameters(eps: 0.9, minPts: 2)
        let currentAssignment = try Self.assignment(
            for: observations, parameters: parameters, opaqueBase: 900)

        func estimate(
            libraryFaceCount: Int? = nil, libraryClusterCount: Int? = nil
        ) throws -> FaceClusteringImpact {
            try FaceClusteringImpactEstimator.estimate(
                observations: observations,
                currentAssignment: currentAssignment,
                current: parameters,
                proposed: parameters,
                libraryFaceCount: libraryFaceCount,
                libraryClusterCount: libraryClusterCount)
        }

        // 不提供规模 → nil（UI 必须按"可能不是全库"提示）。
        let unknown = try estimate()
        #expect(unknown.isSubsetOfLibrary == nil)
        // faceCount：少于库 → true（确定是子集）；等于/大于库 → nil。传入数 ≥ 库计数
        // 不能证明覆盖全库（库计数可能过期、观测可能重复/陈旧）——该字段没有 false 态。
        let fewerFaces = try estimate(libraryFaceCount: 10)
        #expect(fewerFaces.isSubsetOfLibrary == true)
        let allFaces = try estimate(libraryFaceCount: 6)
        #expect(
            allFaces.isSubsetOfLibrary == nil,
            "6 条 = 库规模：计数可能过期 → 无法判定，不得断言覆盖全库")
        // 库比试算集还小属调用方错误口径：同样只是"无法判定"，既不反报"子集"也不断言"覆盖"。
        let inconsistentFaces = try estimate(libraryFaceCount: 5)
        #expect(inconsistentFaces.isSubsetOfLibrary == nil)
        // clusterCount：只覆盖库内部分现簇 → true（能证明是子集）；相等时无法据此证明
        // 覆盖全库 → nil（不猜）。
        let fewerClusters = try estimate(libraryClusterCount: 4)
        #expect(fewerClusters.isSubsetOfLibrary == true)
        let sameClusterCount = try estimate(libraryClusterCount: 2)
        #expect(sameClusterCount.isSubsetOfLibrary == nil)
        // faceCount 优先于 clusterCount：给了 faceCount 就不再回落到簇数维度（本用例
        // clusterCount=4 > clusterCountBefore=2，若回落就会误报 true）。
        let faceCountWins = try estimate(libraryFaceCount: 6, libraryClusterCount: 4)
        #expect(faceCountWins.isSubsetOfLibrary == nil)

        // 规模只影响标记，不参与计数：计数永远只对传入观测集成立。
        for impact in [fewerFaces, allFaces] {
            #expect(impact.faceCount == 6)
            #expect(impact.clusterCountBefore == 2, "只覆盖传入观测的 2 个簇，不是全库 10 簇")
            #expect(impact.clusterCountAfter == 2)
            #expect(impact.noiseCountBefore == 1)
            #expect(impact.noiseCountAfter == 1)
            #expect(impact.parametersChanged == false)
            #expect(impact.partitionChanged == false)
        }
    }

    // MARK: - 8. 归一化（与生产同刻度）

    @Test("归一化：floor 夹取 0...1、retry < 2 → nil，与 FaceKwService.clusterOptions 逐值对照")
    func normalizationMatchesProductionClampAndRetryRules() throws {
        // 生产：coreQualityFloor = min(max(v, 0), 1)；retry 取整后 < 2 一律 → nil。
        let productionLow = FaceKwService.clusterOptions(from: { _, _ in -0.5 })
        let productionHigh = FaceKwService.clusterOptions(from: { _, _ in 2.0 })
        let productionMid = FaceKwService.clusterOptions(from: { _, _ in 0.42 })
        #expect(productionLow.coreQualityFloor == 0)
        #expect(productionHigh.coreQualityFloor == 1)
        #expect(productionMid.coreQualityFloor == 0.42)

        let normalizedLow = FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: -0.5)
            .normalized()
        let normalizedHigh = FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: 2.0)
            .normalized()
        let normalizedMid = FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: 0.42)
            .normalized()
        #expect(normalizedLow.coreQualityFloor == productionLow.coreQualityFloor)
        #expect(normalizedHigh.coreQualityFloor == productionHigh.coreQualityFloor)
        #expect(normalizedMid.coreQualityFloor == productionMid.coreQualityFloor)

        let observations = [
            Self.observation(1, [1, 0, 0, 0]),
            Self.observation(2, [1, 0, 0, 0]),
            Self.observation(3, [1, 0, 0, 0]),
            Self.observation(4, [0, 1, 0, 0]),
            Self.observation(5, [0, 1, 0, 0]),
            Self.observation(6, [0, 0, 1, 0]),
        ]
        let parameters = FaceClusteringParameters(eps: 0.9, minPts: 2)  // floor 0、retry nil
        let currentAssignment = try Self.assignment(for: observations, parameters: parameters)

        // floor -0.5 与 0 在生产里是同一刻度 → 不算参数变化，划分也不变。
        let negativeFloor = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: -0.5))
        #expect(negativeFloor.normalizedParameters.coreQualityFloor == 0)
        #expect(negativeFloor.parametersChanged == false, "-0.5 与 0 同刻度")
        #expect(negativeFloor.partitionChanged == false)

        // floor 2.0 夹到 1.0；夹具 quality 全 1.0 ≥ 1.0 → 核心点资格不变、划分不变，
        // 但参数确实变了 → 只提示，不重建。
        let highFloor = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, coreQualityFloor: 2.0))
        #expect(highFloor.normalizedParameters.coreQualityFloor == 1)
        #expect(highFloor.parametersChanged, "0 → 1.0 是真实参数变化")
        #expect(highFloor.partitionChanged == false)

        // retry 1 → nil，与生产一致：不算参数变化、划分不变、结果里 retryMinSamples 为 nil。
        let productionRetryOne = FaceKwService.clusterOptions(from: { key, _ in
            key == "face_core_retry_min_samples" ? 1 : 0
        })
        #expect(productionRetryOne.retryMinSamples == nil)
        let retryOne = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, retryMinSamples: 1))
        #expect(
            retryOne.normalizedParameters.retryMinSamples
                == productionRetryOne.retryMinSamples, "retry 1 与生产同样归一为 nil")
        #expect(retryOne.normalizedParameters.retryMinSamples == nil)
        #expect(retryOne.parametersChanged == false, "retry 1 与关闭同刻度")
        #expect(retryOne.partitionChanged == false)

        // retry 2 是真实开启：参数变化、结果保留 2；内核行为与 nil 不同见第 4 组。
        let retryTwo = try FaceClusteringImpactEstimator.estimate(
            observations: observations,
            currentAssignment: currentAssignment,
            current: parameters,
            proposed: FaceClusteringParameters(eps: 0.9, minPts: 2, retryMinSamples: 2))
        #expect(retryTwo.normalizedParameters.retryMinSamples == 2)
        #expect(retryTwo.parametersChanged)
    }

    // MARK: - 9. 取消

    @Test("取消：入口已取消 → 抛 CancellationError；内核中途仍不可取消（见文件头）")
    func cancelledTaskThrowsCancellationErrorInsteadOfReturningStaleCounts() async {
        let observations = [Self.observation(1, [1, 0, 0, 0])]
        let parameters = FaceClusteringParameters(eps: 0.9, minPts: 2)
        let cancelled = await Task<Bool, Never> {
            _ = withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try FaceClusteringImpactEstimator.estimate(
                    observations: observations,
                    currentAssignment: [:],
                    current: parameters,
                    proposed: parameters)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled, "已取消的任务必须抛 CancellationError，而不是返回陈旧计数")
    }
}
