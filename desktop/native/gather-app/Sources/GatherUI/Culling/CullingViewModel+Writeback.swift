// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Writeback.swift
// Cut 4 / 4c-2a：写回 / 同步队列 / 结清清理 / 冲突裁决（原 CullingView.swift 1285-1582 行）。
import Foundation
import GatherProtocol


extension CullingViewModel {
    /// culling.writeback 的返回类型是 WritebackResult（不是 MetadataSyncSummary）。
    /// B3b：破坏性入口用 Confirmed<CullingWritebackInput>，确认来源固定为用户弹窗。
    /// Cut 4 / 4b-2a：目标名与计数只在事件点传给 CommandError（错误载体按 4b-1
    /// 约定只持有字符串参数）；成功文案不在这里格式化，交给 CullingNotice 存结构。
    public func writeback(target: CullingWritebackTarget, confirmed: Bool, l10n: L10n) async {
        guard confirmed else {
            errorMessage = CommandError.localized("写回必须先经确认")
            return
        }
        do {
            let payload = try CullingWritebackInput(sessionId: sessionId, target: target)
            let result = try await cullingAPI.writeback(Confirmed(payload, source: .userDialog))
            // loadPage 末尾会清 errorMessage：先刷新页面，再落结果文案，
            // 否则「写回成功但 3 项失败」的原因会被刚刷新的页面清掉。
            postMetadataChange()
            await loadPage(reset: true)
            applyWritebackResult(result, label: Self.targetLabel(target), l10n: l10n)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    /// 写回结果逐项可见：失败数 > 0 或存在逐条原因时进 errorMessage（不吞），
    /// 全成功才进 notice。
    private func applyWritebackResult(_ result: WritebackResult, label: LocalizedText, l10n: L10n) {
        if result.failed > 0 || !result.errors.isEmpty {
            logWritebackFailures(label: l10n.resolve(label), errors: result.errors)
            notice = nil
            // Cut 4 / 4a-3b-1：计数由模板在渲染期本地化（params 按占位符顺序插入）；
            // 逐条原因仍写日志，并以 diagnostic 留档（失败清单块属 4b 的结构化改造）。
            errorMessage = CommandError.localized(
                "%@：成功 %lld，失败 %lld，跳过 %lld",
                params: [
                    l10n.resolve(label),
                    "\(result.written)",
                    "\(result.failed)",
                    "\(result.skipped)",
                ],
                // 诊断只进日志/tooltip：原样保留逐条描述即可，不必在 VM 里本地化。
                diagnostic: result.errors.joined(separator: "；")
            )
        } else {
            errorMessage = nil
            notice = CullingNotice(
                writebackLabel: label,
                written: result.written,
                failed: result.failed,
                skipped: result.skipped
            )
        }
    }

    /// 写回失败明细写日志（原始诊断不上屏，界面只展示漏斗后的文案）。
    private func logWritebackFailures(label: String, errors: [String]) {
        guard !errors.isEmpty else { return }
        GatherLogger.log(
            "culling.writeback \(label) errors: \(errors.joined(separator: " | "))",
            level: .warn
        )
    }

    /// 原因摘要：最多 3 条漏斗后文案 + 其余计数（完整明细在日志与失败面板）。
    static func reasonSummary(_ reasons: [String], with l10n: L10n) -> String {
        let head = reasons.prefix(3).map { funnelErrorText($0, with: l10n) }
        var text = head.joined(separator: "；")
        if reasons.count > head.count {
            text += l10n.format("；另有 %lld 条", reasons.count - head.count)
        }
        return text
    }

    /// 错误码漏斗：从「路径: XMP_WRITE_FAILED / 原因」这类结构化描述里抽出错误码
    /// token 走 L10n.errorText（渲染期按当前语言解析）；抽不到码值时交回
    /// errorText 的通用文案。诊断原文只进日志（见 applySyncStatus/applyWritebackResult），
    /// 不直接铺在界面上。
    ///
    /// Cut 4 / 4b-1：语言由调用方（View 的 l10n）显式传入，不再读进程全局。
    static func funnelErrorText(_ raw: String, with l10n: L10n) -> String {
        l10n.errorText(errorCode(in: raw) ?? raw)
    }

    private static func errorCode(in raw: String) -> String? {
        // 手工扫描最大的「大写 + 数字 + 下划线」连续段（≥4 字符）作为码值候选：
        // 比 split 的泛型重载更确定，且不会把路径/散文误当码值。
        var candidate = ""
        for character in raw {
            if character.isUppercase || character.isNumber || character == "_" {
                candidate.append(character)
            } else {
                if candidate.count >= 4 { return candidate }
                candidate = ""
            }
        }
        return candidate.count >= 4 ? candidate : nil
    }

    public func flush(retry: Bool = false) async {
        do {
            let summary: MetadataSyncSummary
            if retry {
                summary = try await cullingAPI.retrySync(sessionId)
            } else {
                summary = try await cullingAPI.flush(sessionId)
            }
            applySyncStatus(summary)
            notice = CullingNotice(retry ? "已重试同步队列" : "已刷新同步队列")
            postMetadataChange()
            await loadPage(reset: true)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    /// retry_failed_writeback 同样返回 WritebackResult（旧实现按摘要解码 → 静默失败）。
    public func retryFailedWriteback(confirmed: Bool, l10n: L10n) async {
        guard confirmed else {
            errorMessage = CommandError.localized("重试失败写回必须先经确认")
            return
        }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let result = try await cullingAPI.retryFailedWriteback(
                Confirmed(reference, source: .userDialog)
            )
            postMetadataChange()
            await loadPage(reset: true)
            applyWritebackResult(result, label: LocalizedText("重试写回"), l10n: l10n)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    /// 手动 reload（同步条按钮，§3.10.1 保留的手动入口）。
    ///
    /// 注入了协调器（C1RoundTripReloading）时走它的串行队列：手动点击不会与
    /// 后台的自动 reload 并发，也不会绕过失败抑制/观测。未注入时退回桥直连（旧行为）。
    public func reloadCaptureOne() async {
        do {
            try await reloadCaptureOneThrowing()
            notice = CullingNotice("Capture One 已重新加载元数据，现在可以确认同步")
            errorMessage = nil
        } catch {
            errorMessage = c1CommandError(error)
        }
    }

    /// reload 的抛错版本（G9：元数据/模板写回页也走同一条串行队列）。
    ///
    /// 状态同步（reloadAcked 投影 + 领域广播）收在这里：手动按钮与元数据状态条
    /// 共用同一实现，不会出现"按钮置位了但别的页面没收到"。错误统一转成
    /// CommandError（调用方只需上屏，不再猜错误类型）。
    func reloadCaptureOneThrowing() async throws {
        do {
            try await reloadMetadataThroughRoundTrip()
        } catch {
            throw c1CommandError(error)
        }
        // 桥接层已耐久写入 sessions.reload_acked_at；内存值只是投影，
        // 随后 refreshSyncStatus 会从耐久字段重建（冷启动同样有效）。
        reloadAcked = true
        clearC1AutoReloadFailure()
        postMetadataChange()
        GatherEventCenter.shared.postC1SyncStatusChange(sessionId: sessionId)
        await refreshSyncStatus()
    }

    /// P0 / G2：reload 失败的人工兜底 —— 用户已在 C1 执行 Load Metadata，显式记 ack。
    ///
    /// 门禁语义是"Capture One 还没看到新值"；用户亲眼确认 C1 已加载后，
    /// 这是解除 confirm/finalize 死锁（XMP_CONFIRM_REQUIRES_SYNC）的唯一出口。
    public func acknowledgeManualReload() async {
        do {
            try await acknowledgeManualReloadThrowing()
            notice = CullingNotice(
                "已记录：你在 Capture One 中手动加载了元数据，现在可以确认同步")
            errorMessage = nil
        } catch {
            errorMessage = c1CommandError(error)
        }
    }

    /// 手动 ack 的抛错版本（G9 元数据状态条自己上屏错误）。
    ///
    /// 写的是 sessions.reload_acked_at（与脚本成功同一列），并广播给其它页面
    ///（C1 状态胶囊/设置页都订阅 c1-sync-status）。
    func acknowledgeManualReloadThrowing() async throws {
        do {
            _ = try await cullingAPI.acknowledgeManualReload(sessionId)
        } catch {
            throw c1CommandError(error)
        }
        reloadAcked = true
        clearC1AutoReloadFailure()
        postMetadataChange()
        GatherEventCenter.shared.postC1SyncStatusChange(sessionId: sessionId)
        await refreshSyncStatus()
    }

    /// reload 的唯一出口：协调器优先，桥直连兜底。
    func reloadMetadataThroughRoundTrip() async throws {
        if let coordinator = captureOne as? any C1RoundTripReloading {
            try await coordinator.reloadMetadata(sessionId: sessionId)
            return
        }
        try await captureOne.reloadMetadata(sessionId: sessionId)
    }

    /// 自动 reload 失败通知（`.c1AutoReloadFailed`，object 为 sessionId）的处理：
    /// 变成非阻塞提示 + 保留同步条上的手动重试按钮；绝不弹窗、不阻塞交付结果。
    public func handleC1AutoReloadFailure() {
        guard let coordinator = captureOne as? any C1RoundTripReloading,
              let failure = coordinator.currentAutoReloadFailure(),
              failure.sessionId == sessionId else { return }
        notice = nil
        // G2：reload 是 per-variant 的，C1 里没有选中项时脚本必然无从执行。
        // 这时给出可执行的下一步（先把照片交给 C1 选中，再重载），而不是笼统的"手动 Load"。
        if failure.code == GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue {
            errorMessage = CommandError.localized(
                "Capture One 没有选中的照片：点「同步… → 在 Capture One 中显示」把照片选中后再试",
                diagnostic: failure.message)
            return
        }
        errorMessage = CommandError.localized(
            "Capture One 未自动重载（%@），请在 C1 手动 Load Metadata",
            params: [failure.code],
            diagnostic: failure.message)
    }

    /// 自动 reload 成功后清掉失败提示（同步条恢复常态）。
    public func clearC1AutoReloadFailure() {
        (captureOne as? any C1RoundTripReloading)?.clearAutoReloadFailure()
    }

    /// P1 / G10：在 Capture One 中选中这些照片（selectVariants 早已实现，此前无 UI 入口）。
    ///
    /// 目标集：有选择集 → 选择集；否则当前照片。只改 C1 选中、不导入；脚本能力
    /// 不足时桥层退化为 open -a（**可能触发 C1 导入**），结果 method 已注明来源，
    /// 文案上必须区分，不能让用户以为只是改了选中。
    public func showInCaptureOne() async {
        let paths = captureOneTargetPaths
        guard !paths.isEmpty else {
            errorMessage = CommandError.localized("请先选择照片（或让当前照片可见）")
            return
        }
        guard let roundTrip = captureOne as? any C1RoundTripExtending else {
            errorMessage = CommandError.localized("「在 Capture One 中显示」未接线")
            return
        }
        do {
            let outcome = try await roundTrip.selectVariants(paths: paths)
            errorMessage = nil
            switch outcome.method {
            case .appleScript:
                if outcome.notFound.isEmpty {
                    notice = CullingNotice(
                        "已在 Capture One 中显示 %lld 张照片",
                        params: ["\(outcome.paths.count)"])
                } else {
                    notice = CullingNotice(
                        "已在 Capture One 中显示 %lld 张，%lld 张不在当前目录",
                        params: ["\(outcome.paths.count)", "\(outcome.notFound.count)"])
                }
            case .workspace:
                notice = CullingNotice(
                    "已在 Capture One 中打开 %lld 张照片（可能触发导入）",
                    params: ["\(outcome.paths.count)"])
            }
        } catch {
            errorMessage = c1CommandError(error)
        }
    }

    /// C1 选中目标：有选择集用选择集（保持页面顺序），否则当前照片；去重保序。
    var captureOneTargetPaths: [String] {
        let assets = page?.assets ?? []
        let targets: [CullingAsset]
        if !selectedPhotoIds.isEmpty {
            targets = assets.filter { selectedPhotoIds.contains($0.photo.id) }
        } else if let currentAsset {
            targets = [currentAsset]
        } else {
            targets = []
        }
        var seen = Set<String>()
        return targets.compactMap { asset in
            let path = (asset.photo.filepath as NSString).standardizingPath
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// C1 错误 → UI 错误载体（码值搬运的唯一出口）。
    ///
    /// C1RoundTripError 不满足 CodedError（code 是 String），CommandError 的既有
    /// 分支也认不出它；不显式转码会退化成 NSError 的英文描述（界面只剩通用文案）。
    private func c1CommandError(_ error: Error) -> CommandError {
        if let command = error as? CommandError { return command }
        if let roundTrip = error as? C1RoundTripError {
            return CommandError(code: roundTrip.code, diagnostic: roundTrip.description)
        }
        return CommandError(error)
    }

    // MARK: - Wave3 / G4：变体级写回（在线通道；XMP 写回仍是离线兜底）

    /// 把当前选择集（无选择时当前照片）的文件级判断按 variant 写回 C1。
    ///
    /// 与「写回 XMP…」的分工：C1 运行中时直接写 catalog 的 variant 属性（rating/
    /// color tag/pick），无需等 Load Metadata；C1 未运行/脚本不可用时仍走 XMP 写回
    ///（同一个菜单，行为不变）。pick 用 C1 原生布尔位表达 keep/reject，**不写关键词**
    ///（G4：不污染 C1 词库）。写回成功后 bridge 已写入 durable reload-ack，
    /// confirm/finalize 门禁照常放行。
    ///
    /// 收口口径（2026-11-11 已确认）：写的是 C1 catalog（权威），**不再** reload metadata
    ///（会把盘上旧 XMP 读回覆盖判断）；失败/未接线时统一提示可执行的下一步：
    /// 改用「写回 XMP…」+ 在 C1 手动 Load Metadata（或点「我已在 C1 手动加载元数据」）。
    public func writeVariantJudgementsToCaptureOne() async {
        let items = variantWritebackItems
        guard !items.isEmpty else {
            errorMessage = CommandError.localized("请先选择照片（或让当前照片可见）")
            return
        }
        do {
            let report = try await captureOne.writeVariantJudgements(
                sessionId: sessionId, items: items)
            if let unsupported = report.unsupportedReason {
                // 未接线（预览/旧宿主）：给出可执行的下一步（XMP 写回 + 手动 Load），不伪造成功。
                errorMessage = CommandError.localized(
                    "变体级写回未完成（%@）：请改用「写回 XMP…」写盘，再在 Capture One 手动 Load Metadata（或点「我已在 Capture One 手动加载元数据」）",
                    params: [unsupported])
                return
            }
            errorMessage = nil
            if report.notFound.isEmpty {
                notice = CullingNotice(
                    "已在 Capture One 中写回 %lld 个变体",
                    params: ["\(report.written)"])
            } else {
                notice = CullingNotice(
                    "已写回 %lld 个变体，%lld 个不在当前目录",
                    params: ["\(report.written)", "\(report.notFound.count)"])
            }
            if report.skipped > 0 {
                GatherLogger.log(
                    "c1.variant_writeback skipped=\(report.skipped)（超过单次上限，需分批）",
                    level: .warn)
            }
        } catch {
            // 失败同样给出可执行下一步（改用 XMP 写回 + 手动 Load），不能只报错。
            let code: String
            if let bridge = error as? CaptureOneBridgeError {
                code = bridge.description
            } else if let command = error as? CommandError, !command.code.isEmpty {
                code = command.code
            } else if let roundTrip = error as? C1RoundTripError {
                code = roundTrip.code
            } else {
                code = String(describing: error)
            }
            errorMessage = CommandError.localized(
                "变体级写回未完成（%@）：请改用「写回 XMP…」写盘，再在 Capture One 手动 Load Metadata（或点「我已在 Capture One 手动加载元数据」）",
                params: [code],
                diagnostic: String(describing: error))
        }
    }


    /// 写回目标：选择集（保持页面顺序）或当前照片；路径去重保序。
    ///
    /// rating/colorLabel/pickState 都取当前资产的决策状态（缓存投影），不查库：
    /// 用户看到什么就写回什么。unreviewed 不写 pick（避免把 C1 已有 pick 清掉）。
    var variantWritebackItems: [C1VariantWritebackItem] {
        let assets = page?.assets ?? []
        let targets: [CullingAsset]
        if !selectedPhotoIds.isEmpty {
            targets = assets.filter { selectedPhotoIds.contains($0.photo.id) }
        } else if let currentAsset {
            targets = [currentAsset]
        } else {
            targets = []
        }
        var seen = Set<String>()
        return targets.compactMap { asset in
            let path = asset.photo.filepath
            guard path.hasPrefix("/"),
                  seen.insert(ScanPath.canonical(path)).inserted else { return nil }
            let pick: Bool?
            switch asset.state.pickState {
            case .picked: pick = true
            case .rejected: pick = false
            case .unreviewed: pick = nil
            }
            return C1VariantWritebackItem(
                photoPath: path,
                rating: Int(asset.state.rating.rounded()),
                colorTag: C1ColorTagMapping.rawValue(for: asset.state.colorLabel),
                pick: pick)
        }
    }

    public func confirmSync() async {
        do {
            _ = try await cullingAPI.confirmSync(sessionId)
            notice = CullingNotice("已确认 Capture One 同步")
            postMetadataChange()
            await loadPage(reset: true)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    public func finalizeSync(confirmed: Bool) async {
        guard confirmed else {
            errorMessage = CommandError.localized("结束同步必须先经确认")
            return
        }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let summary = try await cullingAPI.finalizeSync(
                Confirmed(reference, source: .userDialog)
            )
            applySyncStatus(summary)
            notice = CullingNotice("已完成元数据同步（%lld 项已确认加载）", params: ["\(summary.synced)"])
            postMetadataChange()
            await loadPage(reset: true)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    /// import 返回 CleanupResult：deletedCount 与逐条 errors 都必须呈现
    ///（旧实现丢弃返回值 → cleanup 标 conflict 后用户看不到任何原因）。
    public func cleanup(confirmed: Bool, l10n: L10n) async {
        guard confirmed else {
            errorMessage = CommandError.localized("清理备份必须先经确认")
            return
        }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let result = try await cullingAPI.cleanup(
                Confirmed(reference, source: .userDialog)
            )
            if !result.errors.isEmpty {
                GatherLogger.log(
                    "culling.cleanup errors: \(result.errors.joined(separator: " | "))",
                    level: .warn
                )
            }
            // 同上：先刷新页面再落文案。
            postMetadataChange()
            await loadPage(reset: true)
            if result.errors.isEmpty {
                notice = CullingNotice("已清理 %lld 项可安全删除的备份", params: ["\(result.deletedCount)"])
                errorMessage = nil
            } else {
                notice = nil
                errorMessage = CommandError.localized(
                    "清理了 %lld 项，%lld 项失败：%@",
                    params: [
                        "\(result.deletedCount)",
                        "\(result.errors.count)",
                        Self.reasonSummary(result.errors, with: l10n),
                    ]
                )
            }
        } catch {
            errorMessage = CommandError(error)
        }
    }
    public func reset(confirmed: Bool) async {
        guard confirmed else {
            errorMessage = CommandError.localized("重置挑片状态必须先经确认")
            return
        }
        do {
            let payload = try CullingResetInput(sessionId: sessionId)
            _ = try await cullingAPI.reset(Confirmed(payload, source: .userDialog))
            notice = CullingNotice("已重置挑片状态")
            postCullingChange()
            await loadPage(reset: true)
        } catch {
            errorMessage = CommandError(error)
        }
    }
    /// 冲突裁决（唯一出口）：confirmed 只能来自确认弹窗；choices 为空 =
    /// 显式结清（保留 Gather 值并以当前磁盘状态为新基线重写）。
    ///
    /// B6b：MetadataAPI 只接收 Confirmed<T>。输入类型禁止空 choices（B6a 的
    /// G5/G6 校验），而协调器以「空 choices」表达第三条出口，因此这里把空
    /// choices 归一化为逐字段 keep_local：协调器 remaining 仍为全部 dirty 字段，
    /// 走「保留本地、以当前磁盘状态为新基线重写」分支，语义与旧路由一致。
    public func resolve(
        _ conflict: MetadataConflict,
        choices: [MetadataField: MetadataConflictChoice],
        confirmed: Bool
    ) async {
        guard confirmed else {
            errorMessage = CommandError.localized("冲突裁决必须先经确认")
            return
        }
        do {
            let input = try MetadataResolveConflictInput(
                sessionId: sessionId,
                xmpPath: conflict.xmpPath,
                choices: Self.apiChoices(for: conflict, choices: choices)
            )
            _ = try await metadataAPI.resolveConflict(
                Confirmed(input, source: .userDialog)
            )
            notice = CullingNotice("已处理元数据冲突")
            errorMessage = nil
            postMetadataChange()
            await loadPage(reset: true)
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 空 choices（界面「保留 Gather 并结清」）→ 逐字段 keep_local。
    ///
    /// 极端情况下冲突行没有任何可裁决字段（dirty 字段为空的数据损坏行）：
    /// 输入类型不允许空 choices，这里给一个 keep_local 让协调器走 remaining
    /// 为空的结清分支（不写任何字段），保持旧版「直接结清」可达。
    nonisolated static func apiChoices(
        for conflict: MetadataConflict,
        choices: [MetadataField: MetadataConflictChoice]
    ) -> [MetadataField: MetadataConflictChoice] {
        guard choices.isEmpty else { return choices }
        let fields = conflict.fields.map(\.field)
        if fields.isEmpty {
            return [.rating: .keepLocal]
        }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0, MetadataConflictChoice.keepLocal) })
    }



    /// P2-5：对当前全部冲突使用同一策略。单个失败不中断其余；完成后统一刷新。
    public func resolveAllConflicts(
        choice: MetadataConflictChoice,
        confirmed: Bool
    ) async {
        guard confirmed else {
            errorMessage = CommandError.localized("冲突裁决必须先经确认")
            return
        }
        let targets = conflicts
        guard !targets.isEmpty else { return }
        var failed = 0
        for conflict in targets {
            do {
                let input = try MetadataResolveConflictInput(
                    sessionId: sessionId,
                    xmpPath: conflict.xmpPath,
                    choices: Self.apiChoices(
                        for: conflict,
                        choices: Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) }))
                )
                _ = try await metadataAPI.resolveConflict(
                    Confirmed(input, source: .userDialog))
            } catch {
                failed += 1
            }
        }
        if failed == targets.count {
            errorMessage = CommandError.localized("批量冲突裁决全部失败，请逐个重试")
        } else {
            errorMessage = nil
            notice = CullingNotice(
                "已批量处理 %lld 个冲突（失败 %lld）",
                params: ["\(targets.count - failed)", "\(failed)"])
        }
        postMetadataChange()
        await loadPage(reset: true)
    }

    /// 逐字段选择一次应用（面板「应用选择」）。
    public func resolve(_ conflict: MetadataConflict, choice: MetadataConflictChoice, confirmed: Bool) async {
        await resolve(
            conflict,
            choices: Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) }),
            confirmed: confirmed
        )
    }
    /// 确认弹窗取消时的可见文案（不静默 return，也不发命令）。
    /// 4b-2a：动作以 key 形式入档（`LocalizedText`），渲染期才查表——
    /// 旧实现把已解析的中文塞进 `%@` 参数，切到 en 后动作名仍是中文。
    public func noteCancelledAction(_ action: LocalizedText) {
        errorMessage = nil
        notice = CullingNotice(cancelled: action)
    }

    private static func targetLabel(_ target: CullingWritebackTarget) -> LocalizedText {
        switch target {
        case .rating: return LocalizedText("评分")
        case .colorLabel: return LocalizedText("颜色标签")
        case .keyword: return LocalizedText("关键字")
        }
    }
}
