// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Actions.swift
// Cut 4 / 4c-2i：DashboardViewModel 的动作分区（自 DashboardViewModel.swift 原样移出）。
// 行为不变：创建（本地/C1）、删除、索引重试、任务 cancel/retry/clear 与导入提示。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    // MARK: 动作

    /// 新建工作区：校验目录、创建 session 并启动 metadata.scan，
    /// 让用户一次点击完成建库与索引启动。
    func createSession(name: String, sourcePath: String, with l10n: L10n) async -> SessionData? {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let session: SessionData
            // 默认名（目录 basename / "导入照片"）只在这里解析一次：两条分支
            // （async API 与同步 Provider）共用同一个落库值。
            let resolvedName = LiveDashboardDataProvider.directorySessionName(
                name: name, sourcePath: sourcePath, with: l10n)
            if let sessionAPI {
                // LiveSessionAPI 的目录分支内部完成 create + metadata.scan
                //（入队失败回滚会话，与 C1/filepaths 分支同一契约）；VM 不再
                // 重复入队或自行回滚，只消费 API 的副作用。
                let input = try SessionCreateInput(
                    name: resolvedName, source: "local", sourcePath: sourcePath)
                session = try await sessionAPI.create(input).session
            } else {
                let created = try provider.createSession(
                    name: resolvedName, source: "local", sourcePath: sourcePath)
                do {
                    try provider.enqueueIndexScan(sessionId: created.id, requestedPaths: nil)
                } catch {
                    try? provider.deleteSession(created.id, confirmed: true)
                    throw error
                }
                session = created
            }
            setImportNotice(session: session, with: l10n)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return session
        } catch {
            createError = CommandError(error)
            return nil
        }
    }

    /// TS handleCreate（capture-one 分支）：创建前再跑一次四层预检，全部通过
    /// 才读取选中照片；未选中 → "请先在 Capture One 中选择照片"（L192-194）；
    /// 创建成功带 failedFiles 计数横幅。
    func createSessionFromCaptureOne(name: String, with l10n: L10n) async -> SessionData? {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        guard let bridge = captureOne else {
            createError = CommandError.localized("Capture One 导入不可用，请稍后重试")
            return nil
        }
        let status = await bridge.preflight()
        let preflightResult = C1PreflightResult.build(from: status)
        c1Preflight = .finished(preflightResult)
        guard preflightResult.passed else { return nil }
        do {
            let files = try await bridge.selectedPhotoPaths()
            if files.isEmpty {
                createError = CommandError.localized("请先在 Capture One 中选择至少一张照片")
                return nil
            }
            // 导入范围 = 本次选中集合（与 GatherApp.importFiles 同一契约）：
            // 公共父目录只用于取名，绝不落库为 source_path，否则监听器与
            // 「全量兜底」扫描会重新递归整个父目录树（历史 P0：选 3 张照片
            // 等于扫描整棵目录树，最坏上溯到主目录）。
            // E-19 相邻：路径规则经 ImportPathRules 端口（GatherHost 注册，
            // 真相源在 GatherDomain/SessionService 与 GatherPersistence/TSPath）。
            let pathRules = try ImportPathRulesRegistry.current()
            let selectedPaths = pathRules.normalizedImportFilepaths(files)
            let parentDirectory = pathRules.importCommonParentDirectory(filepaths: selectedPaths)
            let sessionName = name.isEmpty
                ? (parentDirectory.isEmpty ? l10n("Capture One 导入") : pathRules.basename(parentDirectory))
                : name
            let outcome: CreateSessionOutcome
            if let sessionAPI {
                // LiveSessionAPI 的 filepaths 分支内部完成 create + addPhotos +
                // metadata.scan（checkpoint.requestedPaths = 本次选中集合），
                // job 入队失败时由 API 回滚会话行。
                let input = try SessionCreateInput(
                    name: sessionName,
                    source: SessionSource.captureOne.rawValue,
                    filepaths: selectedPaths
                )
                let result = try await sessionAPI.create(input)
                outcome = CreateSessionOutcome(
                    session: result.session,
                    failedFiles: result.failedFiles,
                    added: result.added
                )
            } else {
                outcome = try provider.createSessionFromFiles(
                    name: sessionName,
                    source: SessionSource.captureOne.rawValue,
                    filepaths: selectedPaths
                )
                do {
                    try provider.enqueueIndexScan(sessionId: outcome.session.id, requestedPaths: selectedPaths)
                } catch {
                    // TS session.ipc.ts L52-62：入队失败回滚已建 session（含已
                    // 写入照片），避免半成品工作区残留在列表。补偿删除同上传 true。
                    try? provider.deleteSession(outcome.session.id, confirmed: true)
                    throw error
                }
            }
            setImportNotice(
                session: outcome.session,
                failedFiles: outcome.failedFiles,
                added: outcome.added,
                with: l10n
            )
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return outcome.session
        } catch {
            createError = CommandError(error)
            return nil
        }
    }

    /// 索引失败卡片重试：重新入队 metadata.scan（dedupeKey 复用终态行，
    /// TS retryScan L361-371）。
    func retryScan(sessionId: String) async {
        do {
            // requestedPaths 传 nil：JobService 的 checkpoint 继承会保留原扫描
            // 作用域（文件/C1 导入的 requestedPaths 随重跑续用，重跑=续跑）；
            // 目录会话终态 checkpoint 无该键，仍按目录全树重扫。
            if let jobAPI {
                let handle = try await jobAPI.start(
                    Self.metadataScanRequest(sessionId: sessionId, requestedPaths: nil))
                handle.drain()
            } else {
                try provider.enqueueIndexScan(sessionId: sessionId, requestedPaths: nil)
            }
            scanJobs[sessionId] = DashboardScanJob(status: "queued", current: 0, total: 0)
            await refreshJobs()
        } catch {
            // TS retryScan L364-370：失败把快照回退为 failed（卡片保留重试
            // 入口），而不是停留在 queued 假象。
            scanJobs[sessionId] = DashboardScanJob(status: "failed", current: 0, total: 0)
            actionError = CommandError(error)
        }
    }

    @discardableResult
    func deleteSession(_ sessionId: String, confirmed: Bool) async -> Bool {
        await deleteSessions([sessionId], confirmed: confirmed)
    }

    /// 批量删除（TS deleteManyMutation → sessionApi.deleteMany 带 confirmed）。
    @discardableResult
    func deleteSessions(_ sessionIds: [String], confirmed: Bool) async -> Bool {
        if let sessionAPI {
            // 类型化 API 只接收 Confirmed：未确认路径在这里显式失败，语义与
            // 旧 SessionService.deleteNotConfirmed 完全一致（UI 只在确认后传 true）。
            guard confirmed else {
                actionError = CommandError(GatherError(code: .SESSION_DELETE_NOT_CONFIRMED))
                return false
            }
            guard !sessionIds.isEmpty else { return true }
            do {
                let input = try SessionDeleteInput(sessionIds: sessionIds)
                try await sessionAPI.delete(Confirmed(input, source: .userDialog))
                lastFullRefreshAt = .distantPast
                await refreshAll()
                // LiveSessionAPI 的批量删除是单事务（SessionService.deleteSessions）：
                // 成功 = 全部落库删除，失败 = 整体回滚，故成功时逐 id 交接。
                notifySessionsDeleted(sessionIds)
                return true
            } catch {
                actionError = CommandError(error)
                // 单事务回滚：一个都没删，不清任何 workspace 状态。
                return false
            }
        }
        // stub/测试路径：confirmed 原样透传，VM 不替 Provider 自证确认。
        do {
            try provider.deleteSessions(sessionIds, confirmed: confirmed)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            notifySessionsDeleted(sessionIds)
            return true
        } catch {
            actionError = CommandError(error)
            // 同步 Provider 的 deleteSessions 默认实现逐条删除，失败前可能已删掉
            // 一部分：以「服务端仍存在」为准，只交接真正消失的 id（失败不清）；
            // 列表读不到时保守不清，宁可残留 workspace 也不误杀。
            if let remaining = try? await listSessions() {
                let remainingIds = Set(remaining.map(\.id))
                notifySessionsDeleted(sessionIds.filter { !remainingIds.contains($0) })
            }
            return false
        }
    }

    /// 删除成功后的状态层交接：逐个 id 交给宿主注入的 `onSessionDeleted`。
    /// active/pinned/lastSessionId 清理与 workspace.close 全部由
    /// `SessionStore.endSession` 完成（VM 不持有 store，也不直接 close）。
    private func notifySessionsDeleted(_ sessionIds: [String]) {
        guard let onSessionDeleted else { return }
        for sessionId in sessionIds {
            onSessionDeleted(sessionId)
        }
    }

    func cancelJob(_ jobId: String) async {
        do {
            if let jobAPI {
                _ = try await jobAPI.cancel(jobId)
            } else {
                _ = try provider.cancelJob(jobId)
            }
            await refreshJobs()
        } catch {
            actionError = CommandError(error)
        }
    }

    func retryJob(_ jobId: String) async {
        do {
            if let jobAPI {
                _ = try await jobAPI.retry(jobId)
            } else {
                _ = try provider.retryJob(jobId)
            }
            await refreshJobs()
        } catch {
            actionError = CommandError(error)
        }
    }

    func clearCompletedJobs() async {
        do {
            if let jobAPI {
                _ = try await jobAPI.clearCompleted(Confirmed(ClearCompletedInput()))
            } else {
                _ = try provider.clearCompletedJobs()
            }
            await refreshJobs()
        } catch {
            actionError = CommandError(error)
        }
    }

    /// TS handleCreate 成功路径的 Toast（truncatedToast L208-213 /
    /// importFailureMessage L214-219）：走全局 Toast 系统 5s 自动消退。
    /// 4b-2e：toast 在动作发生时用调用方（View）当前的 l10n 解析——VM 不读全局。
    private func setImportNotice(
        session: SessionData,
        failedFiles: [String] = [],
        added: Int = 0,
        with l10n: L10n
    ) {
        if session.truncatedImport {
            GatherToastCenter.shared.show(
                type: .warning,
                message: l10n("目录超过 50,000 张照片，已导入前 50,000 张，剩余照片将在后台索引中补齐")
            )
        }
        if !failedFiles.isEmpty {
            GatherToastCenter.shared.show(
                type: .warning,
                message: Self.importFailureMessage(added: added, failedFiles: failedFiles, with: l10n)
            )
        }
    }

    /// TS importFailureMessage：{{added}} 张照片已导入；文件读取失败：
    /// 前 3 个文件名 + 超出的 " 等 N 个"（对齐 sessionImportFailure 文案）。
    static func importFailureMessage(added: Int, failedFiles: [String], with l10n: L10n) -> String {
        let examples = failedFiles.prefix(3)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: "、")
        let remaining = failedFiles.count > 3 ? l10n.format(" 等 %lld 个", failedFiles.count) : ""
        return l10n.format("%lld 张照片已导入；文件读取失败：%@%@", added, examples, remaining)
    }
}
