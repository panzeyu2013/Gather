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
    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            // 桥接层已耐久写入 sessions.reload_acked_at；内存值只是投影，
            // 随后 refreshSyncStatus 会从耐久字段重建（冷启动同样有效）。
            reloadAcked = true
            notice = CullingNotice("Capture One 已重新加载元数据，现在可以确认同步")
            postMetadataChange()
            await refreshSyncStatus()
        } catch {
            errorMessage = CommandError(error)
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
