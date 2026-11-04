// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Triage.swift
// P0 / T0：技术质量建议的 UI 状态与动作（生成 / 应用 / 复核队列）。
//
// 边界：
//   - 建议只写 Gather 决策（服务层 source=ai），本文件不触发任何 XMP 写回；
//   - 生成/应用都必须带当前 fingerprint；stale 时禁止应用；
//   - 应用是破坏性但可撤销的动作，确认由 View 的确认 sheet 提供，VM 不伪造 Confirmed。
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// 当前会话的建议摘要；未生成时为 nil（不是 0）。
    public var triageSummary: TriageSummary? { summary?.triage }

    /// 建议是否已过期（指纹/策略不一致）。
    public var isTriageStale: Bool { triageSummary?.stale == true }

    /// 可应用的 keep/reject 建议数（review 不参与）。
    public var triageApplicableCount: Int {
        guard let counts = triageSummary?.counts else { return 0 }
        return counts.keep + counts.reject
    }

    /// 已完成技术质量分析的占比（0...100）。
    /// 建议只覆盖无人工决策的逻辑资产，不能拿 suggestions.total 当分母。
    public var triageCoveragePercent: Int {
        guard let coverage = triageSummary?.counts.coverage else { return 0 }
        return min(100, max(0, Int((coverage * 100).rounded())))
    }

    public var canGenerateTriage: Bool { !isTriageBusy && !sessionId.isEmpty }

    public var canApplyTriage: Bool {
        !isTriageBusy && !isTriageStale && !triageApplied && triageApplicableCount > 0
    }

    /// 当前策略是否真的使用模型信号（v1 下卡片不展示芯片，避免误导）。
    public var triageUsesModelSignals: Bool {
        triageSummary?.policyVersion == "triage-v2"
    }

    /// W1：读取当前照片的模型级信号（检查器卡片用）。失败/未接线 = nil，不弹错。
    public func loadModelReview() async {
        guard triageEnabled, let photoId = currentAsset?.photo.id else {
            currentModelReview = nil
            return
        }
        // 换照片时先清掉上一张的信号：`await` 期间界面已经按新 asset 渲染，
        // 旧值会被当成新照片的「主体闭眼/微笑/审美」，快速翻图时张冠李戴。
        if currentModelReview?.photoId != photoId { currentModelReview = nil }
        do {
            let review = try await cullingAPI.modelReview(photoId)
            // 快速翻图：晚到的旧照片结果不能盖到新照片上。
            guard currentAsset?.photo.id == photoId else { return }
            currentModelReview = review
        } catch {
            guard currentAsset?.photo.id == photoId else { return }
            currentModelReview = nil
        }
    }

    /// 生成/重新生成建议。成功后刷新 summary 与当前页角标。
    public func generateTriage(force: Bool = false) async {
        guard canGenerateTriage else { return }
        isTriageBusy = true
        triageError = nil
        var autoApplyRequested = false
        defer {
            isTriageBusy = false
            // 自动应用必须在 busy 复位之后：applyTriage 的 canApplyTriage
            // 要求 !isTriageBusy，直接在本函数里调会静默 no-op。
            if autoApplyRequested {
                Task { @MainActor [weak self] in
                    _ = await self?.applyTriage()
                }
            }
        }
        do {
            let result = try await cullingAPI.generateTriage(
                TriageGenerateInput(sessionId: sessionId, force: force)
            )
            triageApplied = false
            mergeTriageSummary(result)
            notice = CullingNotice("技术质量建议已生成")
            await loadPage(reset: true)
            // 生成结果是本次请求的权威值；summary 查询可能落后一帧，回填防抖动。
            mergeTriageSummary(result)
            // 自动应用（默认关）：门槛由服务端策略的 executionFloor 决定。
            if let provider = triageAutoApplyProvider, await provider() {
                autoApplyRequested = true
            }
        } catch {
            triageError = CommandError(error)
        }
    }

    /// 应用 keep/reject 建议。调用方必须已经过确认 sheet；失败时返回 nil 并保留错误。
    @discardableResult
    public func applyTriage(
        verdicts: [TriageVerdict] = [.keep, .reject],
        minConfidence: Double? = nil
    ) async -> TriageApplyResult? {
        guard canApplyTriage, let summary = triageSummary else {
            if isTriageStale {
                triageError = CommandError.localized("技术质量建议已过期，请重新生成")
            }
            return nil
        }
        isTriageBusy = true
        triageError = nil
        defer { isTriageBusy = false }
        do {
            let input = TriageApplyInput(
                sessionId: sessionId,
                verdicts: verdicts,
                minConfidence: minConfidence,
                fingerprint: summary.inputFingerprint
            )
            let result = try await cullingAPI.applyTriage(Confirmed(input))
            triageApplied = true
            triageHistoryOperationId = result.historyOperationId
            triageError = nil
            notice = CullingNotice(
                "已应用 %lld 条建议",
                params: ["\(result.appliedAssets)"]
            )
            postCullingChange()
            await loadPage(reset: true)
            return result
        } catch {
            triageError = CommandError(error)
            return nil
        }
    }

    /// 进入复核队列：只看待复核、低置信度优先、网格布局由调用方设置。
    // MARK: - P1 / E：把建议写回成可移植信号

    /// 准备写回输入（只分页读取，不写盘）。确认弹窗由 View 持有：
    /// VM 不得自行构造 Confirmed（D-011：破坏性入口的类型层确认）。
    public func prepareTriageWriteback(
        policy: TriageWritebackPolicy = .ratingOnlyWhenEmpty,
        ratingMode: TriageRatingMode? = nil
    ) async -> TriageWritebackInput? {
        var items: [TriageWritebackItem] = []
        var seen = Set<String>()
        var cursor: CullingPageCursor?
        var pages = 0
        do {
            repeat {
                let query = try CullingPageQuery(
                    sessionId: sessionId,
                    scope: .filtered,
                    filters: CullingFilters(triageVerdicts: [.keep, .reject]),
                    sort: .importOrder,
                    cursor: cursor,
                    limit: 200
                )
                let result = try await cullingAPI.page(query)
                for asset in result.assets {
                    guard let triage = asset.triage else { continue }
                    guard triage.verdict == .keep || triage.verdict == .reject else { continue }
                    guard seen.insert(asset.photo.id).inserted else { continue }
                    // 人工已决策（manual 且非 unreviewed）→ 服务端绝不写 rating，但信号仍记录。
                    let manuallyDecided = asset.state.source == .manual
                        && asset.state.pickState != .unreviewed
                    do {
                        items.append(try TriageWritebackItem(
                            photoId: asset.photo.id,
                            verdict: triage.verdict.rawValue,
                            manuallyDecided: manuallyDecided))
                    } catch {
                        // 显式校验失败不能被 try? 吞成"按钮没反应"。
                        triageError = CommandError(error)
                        return nil
                    }
                }
                cursor = result.nextCursor
                pages += 1
            } while cursor != nil && pages < 500   // 500×200 = 100k，与输入上限一致
        } catch {
            triageError = CommandError(error)
            return nil
        }
        guard !items.isEmpty else { return nil }
        do {
            return try TriageWritebackInput(
                policy: policy, ratingMode: ratingMode ?? triageRatingMode, items: items)
        } catch {
            triageError = CommandError(error)
            return nil
        }
    }

    /// 执行已确认的写回（Confirmed 只能由 View 的确认弹窗构造）。
    public func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async {
        do {
            let result = try await metadataAPI.applyTriageWriteback(input)
            if let failure = result.failed.first {
                triageError = CommandError(APIError.failed(failure.message))
            }
            // P1：用 undoAvailable 而不是 written.isEmpty —— 回读失败（uncertain）
            // 的照片可能已写盘，批次仍在，界面必须保留撤销入口。
            lastTriageWritebackBatchId = result.undoAvailable ? result.batchId : nil
            if !result.skipped.isEmpty {
                notice = CullingNotice(
                    "已处理；%lld 张无需写入（已有星级或人工决策）",
                    params: ["\(result.skipped.count)"])
            }
            await loadPage(reset: true)
        } catch {
            triageError = CommandError(error)
        }
    }

    /// 撤销最近一次建议写回（rating/关键词还原，私有信号清除）。
    public func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async {
        do {
            let result = try await metadataAPI.undoTriageWriteback(input)
            if result.failed.isEmpty {
                lastTriageWritebackBatchId = nil
            }
            if let failure = result.failed.first {
                triageError = CommandError(APIError.failed(failure.message))
            }
            // P1：星级因"盘上已被人工改动"跳过时必须可见，否则用户以为已还原。
            if !result.skipped.isEmpty {
                notice = CullingNotice(
                    "已撤销；%lld 张的星级已被人工改动，保留现值",
                    params: ["\(result.skipped.count)"])
            }
            await loadPage(reset: true)
        } catch {
            triageError = CommandError(error)
        }
    }

    public func showTriageReviewQueue() async {
        sortMode = .triageConfidenceAsc
        scopeMode = .filtered
        var next = FilterState()
        next.triageVerdicts = [.review]
        filterState = next
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// 从生成结果回填 summary（不覆盖其他 CullingSummary 字段）。
    func mergeTriageSummary(_ value: TriageSummary) {
        // 生成/应用可能发生在首帧 summary 尚未加载时；此时必须创建承载对象，
        // 否则 optional chaining 会静默丢掉本次生成结果。
        if var current = summary {
            current.triage = value
            summary = current
        } else {
            summary = CullingSummary(
                totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0,
                pending: 0, rated: 0, labeled: 0, triage: value)
        }
    }
}
