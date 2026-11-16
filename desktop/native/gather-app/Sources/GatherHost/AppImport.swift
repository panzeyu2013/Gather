// desktop/native/gather-app/Sources/GatherHost/AppImport.swift
// Cut 3 / 3b-1：原生导入入口（从 GatherApp.swift 抽出）。
//
// 覆盖三条共用同一实现的入口：菜单/Finder/deep-link（`importFiles`）、
// C1 菜单导入（source = "capture-one"）与工作台导入。失败展示仍走
// importCompleted 通知的 failedCount/examples（RootView toast），日志走 GatherLogger。
//
// R1 P1-3：metadata.scan 的 dedupeKey/checkpoint 规则已上移到 GatherProtocol
//（JobCreateParams.metadataScan）；本文件只传 sessionId + requestedPaths。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherUI

enum AppImport {
    /// 文件打开、菜单导入和 deep-link 共用同一条原生导入路径。
    ///
    /// **导入范围 === 用户显式选择集合**，目录导入与文件导入是两条明确语义：
    ///   · 目录导入：选择集合恰好是一个目录 → source_path = 该目录（唯一允许
    ///     递归的范围），扫描集合 = 该目录全树（job 不带 requestedPaths）；
    ///     照片由索引 job 发现，此处不预写照片行。
    ///   · 文件导入：其余情况（含「文件 + 目录」混合选择）→ source_path 留空，
    ///     扫描集合 = 用户选择的路径集合，由 job checkpoint 的 requestedPaths
    ///     携带；目录条目由索引器在其自身范围内展开。
    /// 历史缺陷：以所选文件的公共父目录充当 source_path，再入队不带路径的
    /// metadata.scan → 选 3 张照片等于递归扫描整个目录树（可上溯到 home）。
    /// 公共父目录现在**只用于取名**，绝不落库为 source_path。
    ///
    /// source/sourceLabel：C1 菜单导入传 "capture-one"/"Capture One 文件"
    /// （对齐旧版 c1:plugin-import 的来源标记与失败提示文案）；其余为
    /// "local"/"文件"。Cut 4 / 4b-3：两条文案都由调用方的 l10n 解析
    /// （en 界面分别是 capture-one / "Capture One Files"/"File"），本类型
    /// 不再读进程级 appLanguage。
    ///
    /// 成功建库后统一 post importCompleted（菜单/C1/deep-link 都走到这里），
    /// userInfo 键名见 GatherAppDelegate 的 GatherAppImportUserInfoKey。
    /// internal（非 private）：GatherAppDelegateTests 需要直调以断言通知内容。
    /// @MainActor：与拆分前 GatherApp.importFiles 的隔离一致（App 成员推断）。
    ///
    /// Cut 4 / 4b-3：`l10n` 由调用方（宿主装配的闭包）在**动作发生时**从
    /// LanguageStore 取当前语言传入——本类型不读进程全局，默认建库名（"C1 导入
    /// M/D H:mm" / "导入照片"）因此跟随界面语言。
    ///
    /// Wave2 / G3：`afterCreate` 是「建库+照片行落库之后、importCompleted 之前」的
    /// 可选钩子（默认 nil ⇒ 其余导入入口行为零变化）。C1 判断数据需要 sessionId 才
    /// 能按路径映射，本入口因此提供这个接缝；钩子的失败**不得影响导入结果**
    ///（额外数据是可选增强，导入已经成功）。
    @MainActor
    static func importFiles(
        _ files: [String],
        sessionAPI: any SessionAPI,
        source: String = "local",
        sourceLabel: String = "",
        l10n: L10n,
        afterCreate: (@MainActor (SessionCreateResult) async throws -> Void)? = nil
    ) async {
        let normalized = normalizeImportFilepaths(files)
        guard !normalized.isEmpty else { return }
        do {
            let input: SessionCreateInput
            if normalized.count == 1, isDirectory(normalized[0]) {
                // 目录作用域：name 取目录名（旧实现传空由 SessionService 取名，等价）。
                let base = URL(fileURLWithPath: normalized[0]).lastPathComponent
                input = try SessionCreateInput(
                    name: base.isEmpty ? Self.defaultImportName(source: source, l10n: l10n) : base,
                    source: source,
                    sourcePath: normalized[0]
                )
            } else {
                // 目录条目不写照片行（避免把目录当成一张「解码失败的照片」上报），
                // 交给索引器在 requestedPaths 范围内展开。
                let parent = commonParentDirectory(filepaths: normalized)
                let base = parent.isEmpty
                    ? URL(fileURLWithPath: normalized[0]).deletingPathExtension().lastPathComponent
                    : URL(fileURLWithPath: parent).lastPathComponent
                input = try SessionCreateInput(
                    name: base.isEmpty ? Self.defaultImportName(source: source, l10n: l10n) : base,
                    source: source,
                    filepaths: normalized
                )
            }
            // P1（复审）：建库/加照片/入队走 typed API（nonisolated async，不在主线程）；
            // 入队失败由 LiveSessionAPI 补偿删除，不会留下“永远不会被扫描”的半成品。
            let result = try await sessionAPI.create(input)
            // G3：可选后置钩子（C1 判断数据）。顺序刻意放在 importCompleted 通知之前，
            // 但实现方必须自己异步化、立即返回（本入口不能因此变慢/失败）。
            if let afterCreate {
                do {
                    try await afterCreate(result)
                } catch {
                    GatherLogger.log("import afterCreate hook failed: \(error)", level: .warn)
                }
            }
            // 任一目录作用域（单目录或目录+文件）都可能有异步索引，不能用 added==0 判空。
            let directoryImport = normalized.contains(where: isDirectory)
            let failedFiles = result.failedFiles
            if !failedFiles.isEmpty {
                GatherLogger.log("import skipped \(failedFiles.count) files", level: .warn)
            }
            let examples = failedFiles
                .prefix(3)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "、")
            NotificationCenter.default.post(
                name: GatherAppNotification.importCompleted,
                object: nil,
                userInfo: [
                    GatherAppImportUserInfoKey.sessionId: result.session.id,
                    GatherAppImportUserInfoKey.failedCount: failedFiles.count,
                    GatherAppImportUserInfoKey.addedCount: result.added,
                    GatherAppImportUserInfoKey.sourceLabel: sourceLabel,
                    GatherAppImportUserInfoKey.examples: examples,
                    GatherAppImportUserInfoKey.directoryImport: directoryImport,
                ]
            )
        } catch {
            GatherLogger.log("native import failed: \(error)", level: .error)
            // P1-2：失败必须可见。object 用 CommandError 搬运码/参数/诊断；
            // RootView 渲染期按当前语言解析，不把英文诊断直接上屏。
            NotificationCenter.default.post(
                name: GatherAppNotification.importFailed,
                object: CommandError(error),
                userInfo: [GatherAppImportUserInfoKey.retryFiles: normalized]
            )
        }
    }

    /// Wave3 / task-21：把文件加入**已有工作区**（gather://import?session=<id> /
    /// App Intents 共用）。成功/失败都走既有 importCompleted / importFailed 通知，
    /// RootView 因此仍然只认一条导入完成契约（自动落图库、Toast 失败计数）。
    /// Wave5 batch2（E1）：`afterAdd` 是「照片行已落库 + 索引已入队」之后的可选钩子
    /// （默认 nil ⇒ 其余调用方行为零变化）。自动初审用它把"加照片到已有工作区"也
    /// 纳入导入入口覆盖；钩子失败不影响导入结果。
    @MainActor
    static func importFiles(
        _ files: [String],
        into sessionId: String,
        sessionAPI: any SessionAPI,
        jobAPI: any JobAPI,
        source: String = "shortcuts",
        sourceLabel: String = "",
        l10n: L10n,
        afterAdd: (@MainActor (String) async throws -> Void)? = nil
    ) async {
        let normalized = normalizeImportFilepaths(files)
        guard !normalized.isEmpty else { return }
        do {
            let input = try SessionAddPhotosInput(
                sessionId: sessionId, filepaths: normalized, source: source)
            let result = try await sessionAPI.addPhotos(input)
            // 只扫本次新增的文件集合（job 的 dedupeKey/checkpoint 继承既有语义）。
            do {
                _ = try await jobAPI.start(
                    JobCreateParams.metadataScan(sessionId: sessionId, requestedPaths: normalized))
            } catch {
                // 入队失败不是导入失败：照片行已落库，用户可以重试索引；必须可见。
                GatherLogger.log("import-into-session scan failed: \(error)", level: .warn)
            }
            // Wave5 batch2：加照片到已有工作区同样属于"导入完成"入口（自动初审）。
            // 钩子必须立即返回：真正调度在宿主侧异步执行，不能拖慢/拖红导入。
            if let afterAdd {
                do {
                    try await afterAdd(sessionId)
                } catch {
                    GatherLogger.log("import afterAdd hook failed: \(error)", level: .warn)
                }
            }
            let examples = result.failedFiles
                .prefix(3)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "、")
            NotificationCenter.default.post(
                name: GatherAppNotification.importCompleted,
                object: nil,
                userInfo: [
                    GatherAppImportUserInfoKey.sessionId: sessionId,
                    GatherAppImportUserInfoKey.failedCount: result.failedFiles.count,
                    GatherAppImportUserInfoKey.addedCount: result.added,
                    GatherAppImportUserInfoKey.sourceLabel: sourceLabel,
                    GatherAppImportUserInfoKey.examples: examples,
                    GatherAppImportUserInfoKey.directoryImport: false,
                ]
            )
        } catch {
            GatherLogger.log("import into session failed: \(error)", level: .error)
            NotificationCenter.default.post(
                name: GatherAppNotification.importFailed,
                object: CommandError(error),
                userInfo: [GatherAppImportUserInfoKey.retryFiles: normalized]
            )
        }
    }

    /// Phase 4.3 一次性迁移：Vision feature print rev2 为 768 维，不能与
    /// 旧 512 维向量混用。首次启动原生宿主时切换 native
    /// embedding_dim，并为已有工作区排入 face.analyze；JobService 的
    /// dedupe/checkpoint 保证重启可续。真实照片集的 ARI/NMI 仍需发布前离线
    /// 验收，不在启动阶段伪造通过。
    @MainActor
    static func prepareNativeEmbeddingRerun(
        composition: AppComposition,
        settings: any SettingsAPI,
        databasePath: String
    ) async {
        let marker = "vision-feature-print-rev2-768-v1"
        // Scope the marker to the database. A global UserDefaults marker would
        // incorrectly skip the migration when a second library is opened.
        let markerKey = "gather.nativeEmbeddingVersion.\(databasePath)"
        guard UserDefaults.standard.string(forKey: markerKey) != marker else { return }
        do {
            // Cut 1 / B8.2d：settings.set 走 SettingsAPI（字符串命令不再出现在
            // 宿主；校验/错误语义与旧命令面分支一致：未知 key → INVALID_PARAM）。
            try await settings.set(SettingsSetInput(key: "embedding_dim", value: "768"))
            for session in try composition.sessionService.listSessions() where session.photoCount > 0 {
                _ = try composition.jobService.create(JobCreateParams(
                    type: .faceAnalyze,
                    scopeType: "session",
                    scopeId: session.id,
                    dedupeKey: "face.analyze:native-embedding:\(session.id)",
                    checkpoint: [
                        "detectorPath": .string("vision"),
                        "encoderPath": .string("vision-feature-print-rev2"),
                    ]
                ))
            }
            UserDefaults.standard.set(marker, forKey: markerKey)
        } catch {
            GatherLogger.log("native embedding migration deferred: \(error)", level: .warn)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 对齐旧版 app.c1ImportName：C1 导入无公共父目录时使用
    /// 「C1 导入 M/D H:mm」（分钟补零）；其他来源回退「导入照片」。
    /// internal（非 private）：GatherAppDelegateTests 断言语言注入后的命名。
    static func defaultImportName(source: String, l10n: L10n) -> String {
        guard source == "capture-one" else { return l10n("导入照片") }
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return l10n.format(
            "C1 导入 %@",
            "\(month)/\(day) \(hour):\(String(format: "%02d", minute))"
        )
    }

    // MARK: - Wave5 batch7（A2/R5）：C1 导入的统一语义

    /// C1 导入的统一来源标记（菜单 / Dashboard / 深链三个入口共用同一字符串）。
    static let captureOneSource = "capture-one"

    /// C1 文件导入的统一入口：capture-one 来源标 + 「Capture One 文件」失败提示标签 +
    /// 判断数据落库（三个 C1 入口共用，来源/命名/判断语义只有这一份）。
    ///
    /// 顺序：AppImport.importFiles 建库 → 外层 afterCreate（如自动初审）→ coordinator
    /// 按导入路径取回暂存判断并调度落库。判断落库失败不影响导入结果（协调器自己收敛）。
    @MainActor
    static func importCaptureOneFiles(
        _ importPaths: [String],
        sessionAPI: any SessionAPI,
        coordinator: C1ImportCoordinator,
        l10n: L10n,
        afterCreate: (@MainActor (SessionCreateResult) async throws -> Void)? = nil
    ) async {
        // 与 importFiles 的归一化口径对齐：判断按**实际导入路径集合**暂存/取回，
        // 避免入口路径里有被过滤项时 take 失配（判断会静默丢失）。
        let normalizedPaths = normalizeImportFilepaths(importPaths)
        guard !normalizedPaths.isEmpty else { return }
        await importFiles(
            normalizedPaths,
            sessionAPI: sessionAPI,
            source: captureOneSource,
            sourceLabel: l10n("Capture One 文件"),
            l10n: l10n,
            afterCreate: { result in
                // 外层钩子（如自动初审）失败也要保证判断落库调度照常执行：
                // 两者互不依赖，任何一方失败都不影响导入结果。
                if let afterCreate {
                    do {
                        try await afterCreate(result)
                    } catch {
                        GatherLogger.log(
                            "c1.import afterCreate hook failed: \(error)", level: .warn)
                    }
                }
                coordinator.finishCreate(sessionId: result.session.id, paths: normalizedPaths)
            }
        )
    }
}

// MARK: - C1 判断数据随导入的统一入口（Wave5 batch7 / A2 / R5）
//
// 从 AppBootstrap 的菜单闭包下沉到这里：三个 C1 入口（菜单 ⌘⇧I / Dashboard 新建工作区
// source=capture-one / gather://import?source=capture-one）共用同一份「快照 → 暂存 →
// 建库后落库（等待 metadata.scan 终态，跳过登记 pending 重放）」语义。

/// C1 判断快照的待应用队列：按「归一化路径集合」暂存，等建库后取回。
///
/// key 用路径集合而不是 sessionId：读快照时还没有 session（新建工作区），而两次 C1
/// 导入可能在 await 之间交错（各自独立 Task）；按文件集关联，A 的判断不会被应用到 B 的
/// 新会话。所有调用都在 MainActor 上，因此不需要锁；同文件集的并发导入共用同一份快照
/// （内容一致、幂等）。
@MainActor
final class C1PendingJudgements {
    private var byPathSet: [String: [C1VariantJudgement]] = [:]

    func store(_ paths: [String], judgements: [C1VariantJudgement]) {
        // 上限防御：用户连续取消/失败导入时不留无限增长的残留（超过 8 批直接清空，
        // 代价只是丢掉还没被消费的旧判断——导入仍会正常进行）。
        if byPathSet.count >= 8 { byPathSet.removeAll() }
        byPathSet[Self.key(paths: paths)] = judgements
    }

    func take(paths: [String]) -> [C1VariantJudgement] {
        byPathSet.removeValue(forKey: Self.key(paths: paths)) ?? []
    }

    func reset() {
        byPathSet.removeAll()
    }

    static func key(paths: [String]) -> String {
        paths.map(ScanPath.canonical).sorted().joined(separator: "\u{1F}")
    }
}

/// C1 判断数据随导入的统一协调器（三个 C1 入口共用）。
///
/// 职责：
/// - capturePaths：读 selectedVariantSnapshot，把判断按**导入路径集合**暂存，并返回
///   本次要导入的路径（入口已确定路径时以入口为准；否则用快照路径）。读不到判断
///   → 退回 fallback 路径并广播 C1_JUDGEMENTS_UNAVAILABLE（导入照常进行，G3 降级口径）；
/// - finishCreate：建库后取回该路径集合的判断，交给注入的 scheduler
///   （生产 = 等 metadata.scan 终态后落库；跳过时由 AppBootstrap 登记 C1PendingJudgementReplay）。
///
/// 不持 DB / 桥（全部闭包注入），因此可单测；判断落库的任何失败都不影响导入结果。
@MainActor
struct C1ImportCoordinator {
    typealias SnapshotProvider = @MainActor () async throws -> C1SelectionSnapshot
    typealias PathProvider = @MainActor () async throws -> [String]
    typealias ApplyScheduler = @MainActor (_ sessionId: String, _ judgements: [C1VariantJudgement]) -> Void

    private let snapshotProvider: SnapshotProvider
    private let fallbackPathProvider: PathProvider
    private let scheduleApply: ApplyScheduler
    private let journal: C1PendingJudgements

    init(
        snapshotProvider: @escaping SnapshotProvider,
        fallbackPathProvider: @escaping PathProvider,
        scheduleApply: @escaping ApplyScheduler,
        journal: C1PendingJudgements = C1PendingJudgements()
    ) {
        self.snapshotProvider = snapshotProvider
        self.fallbackPathProvider = fallbackPathProvider
        self.scheduleApply = scheduleApply
        self.journal = journal
    }

    /// 读快照 → 暂存判断 → 返回本次要导入的路径。
    ///
    /// - Parameter expectedPaths: 入口已经确定的导入路径（Dashboard / 深链）。nil = 菜单
    ///   语义，用快照的路径。给了 expectedPaths 时只保留与之（canonical 归一后）相交的
    ///   判断——导入范围始终以入口为准，快照只提供判断数据。
    /// - Throws: 快照失败时退回 fallback 路径（不抛）；**两条路都失败**才抛出，
    ///   由调用方决定是否继续导入（深链会退化为仅按文件导入）。
    func capturePaths(expectedPaths: [String]? = nil) async throws -> [String] {
        let snapshot: C1SelectionSnapshot
        do {
            snapshot = try await snapshotProvider()
        } catch {
            // G3 降级：判断数据是可选增强，绝不能让"读不到判断"变成"导入失败"。
            let paths = try await fallbackPathProvider()
            journal.store(paths, judgements: [])
            NotificationCenter.default.post(
                name: GatherAppNotification.captureOneError,
                object: GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE.rawValue)
            return paths
        }
        if snapshot.malformedLines > 0 {
            // P2（Wave4b）：畸形行不再静默丢弃（契约漂移要能在日志里看见）。
            GatherLogger.log(
                "c1.judgements parse malformedLines=\(snapshot.malformedLines)"
                    + " paths=\(snapshot.paths.count)（可能 C1 字典/脚本契约变化）",
                level: .warn)
        }
        let importPaths = expectedPaths ?? snapshot.paths
        guard !importPaths.isEmpty else { return [] }
        let allowed = Set(importPaths.map(ScanPath.canonical))
        let judgements = snapshot.judgements.filter {
            allowed.contains(ScanPath.canonical($0.photoPath))
        }
        journal.store(importPaths, judgements: judgements)
        return importPaths
    }

    /// 建库后取回判断并调度落库（无判断 = no-op；同一路径集合只消费一次）。
    func finishCreate(sessionId: String, paths: [String]) {
        let judgements = journal.take(paths: paths)
        guard !judgements.isEmpty else { return }
        scheduleApply(sessionId, judgements)
    }

    /// 测试/停机：丢弃尚未消费的暂存判断。
    func reset() {
        journal.reset()
    }
}
