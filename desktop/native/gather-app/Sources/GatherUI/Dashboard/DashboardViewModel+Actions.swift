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
            // 默认名（目录 basename / "导入照片"）只在这里解析一次：API 与
            // 测试端口共用同一个落库值。
            let resolvedName = Self.directorySessionName(
                name: name, sourcePath: sourcePath, with: l10n)
            // Provider 的 createSession 契约 = 建会话 + 入队 metadata.scan
            //（目录分支由 LiveSessionAPI 内部完成；入队失败回滚会话）。
            let session = try await provider.createSession(
                name: resolvedName, source: "local", sourcePath: sourcePath)
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
            // R7：路径规则已下沉 GatherProtocol（唯一真相源），UI 直调，无 registry。
            let selectedPaths = normalizeImportFilepaths(files)
            let parentDirectory = commonParentDirectory(filepaths: selectedPaths)
            let sessionName = name.isEmpty
                ? (parentDirectory.isEmpty ? l10n("Capture One 导入") : TSPath.basename(parentDirectory))
                : name
            // Provider 的 createSessionFromFiles 契约 = 建会话 + addPhotos +
            // metadata.scan（checkpoint.requestedPaths = 本次选中集合）；job 入队
            // 失败时由 LiveSessionAPI 回滚会话行（TS session.ipc.ts L52-62）。
            let outcome = try await provider.createSessionFromFiles(
                name: sessionName,
                source: SessionSource.captureOne.rawValue,
                filepaths: selectedPaths
            )
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
            try await provider.retryIndexScan(sessionId: sessionId)
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
        // 未确认路径在 VM 显式失败，语义与旧 SessionService.deleteNotConfirmed
        // 完全一致（UI 只在确认后传 true）；Provider 仍接收 confirmed 原样透传，
        // VM 不替 Provider 自证确认。
        guard confirmed else {
            actionError = CommandError(GatherError(code: .SESSION_DELETE_NOT_CONFIRMED))
            return false
        }
        guard !sessionIds.isEmpty else { return true }
        do {
            try await provider.deleteSessions(sessionIds, confirmed: confirmed)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            // 生产实现（LiveSessionAPI）批量删除是单事务：成功 = 全部落库删除，
            // 故成功时逐 id 交接。
            notifySessionsDeleted(sessionIds)
            return true
        } catch {
            actionError = CommandError(error)
            // 端口契约：deleteSessions 是原子的（生产实现为单事务），抛错 = 一个
            // 都没删。不得用失败后的列表反推「已删 id」——查询失败/夹具空表都会
            // 把存活会话误判成已删，从而误清 workspace。
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
            _ = try await provider.cancelJob(jobId)
            await refreshJobs()
        } catch {
            actionError = CommandError(error)
        }
    }

    func retryJob(_ jobId: String) async {
        do {
            _ = try await provider.retryJob(jobId)
            await refreshJobs()
        } catch {
            actionError = CommandError(error)
        }
    }

    func clearCompletedJobs() async {
        do {
            _ = try await provider.clearCompletedJobs()
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
