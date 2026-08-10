// desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
// Phase 3.0 宿主与桥：命令路由（渐进式接线）。
// 已移植领域服务（GatherCore）直连；未移植命令返回 NOT_IMPLEMENTED，
// 渲染层按 ok:false 优雅降级（页面可先展示，功能逐个点亮）。
//
// 接线清单（截至 2026-08-10，对应 NATIVE-DEVELOPMENT-ANALYSIS.md §10.4/§10.6）：
//   同步（execute）：
//     session.* / photo.list → SessionService + PhotoRepo（3.2 服务层）
//     workspace.status → WorkspaceStatusService（3.1 服务层）
//     jobs.list / jobs.cancel / jobs.retry / jobs.clear_completed → JobService
//     image.get_dimensions → RAWDecoder（2.1；注意 TS 为 paths[] 批量形态，
//       当前按单 path 形态保留，字段名一致）
//     face.models_status → FaceInferenceConfig 占位（2.2）
//     settings.get_all / get / set / reset / set_language / get_ml_status
//       → SettingsService（3.6；TS 源 settings.ipc.ts）
//     filter.photos / photos_global / suggest → FilterEngine（3.6；
//       TS 源 filter.ipc.ts，limit/offset 钳制语义在 IPC 层）
//     navigation.list / split / merge → NavigationService（3.6；
//       TS 源 navigation.ipc.ts）
//     sim.result（同步查询）/ sim.cancel_analysis → SimilarityService（3.3；
//       TS 源 similarity.ipc.ts）
//     photo.list_page → PhotoRepo.getAssetPage + 资产装配（TS 源 photo.ipc.ts）
//     assets.candidates → AssetRepo.listCandidates（TS 源 assets.ipc.ts）
//     dup.groups / dup.resolve / dup.resolve_member → DuplicateService（3.6；
//       TS 源 duplicate.ipc.ts）
//   异步（executeAsync）：
//     navigation.analyze → NavigationService.analyze（TS 源 navigation.ipc.ts，
//       TS 侧为 async wrapper 内同步执行，Swift 同步直连）
//     sim.recluster → SimilarityService.recluster（TS 侧 await worker）
//     sim.analyze / dup.scan → JobService executor + waitForResult（TS 源
//       similarity.ipc.ts / duplicate.ipc.ts）
//   未接线（依赖未移植服务，保持 NOT_IMPLEMENTED）：
//     image.preload_thumbnails / preload_previews / prioritize_thumbnail
//       （需 ImageService 缩略图任务编排）
//     fkw.* / person.* / metadata.* / album.* / export.* /
//       template.* / culling.* / quality.* / index.scan /
//       session.create_from_directory / assets.accept_candidate /
//       assets.reject_candidate / assets.volumes / assets.relink_root
import Foundation
import GatherCore

/// 路由实现：注入 GatherCore 服务。
public final class SessionCommandRouter: CommandRouter {
    /// 公开服务访问器（3.1 起供 RootView/DashboardViewModel 同进程直连）。
    public let sessionService: SessionService
    public let workspaceStatusService: WorkspaceStatusService
    public let jobService: JobService
    private let photoRepo: PhotoRepo
    private let settingsService: SettingsService
    private let filterEngine: FilterEngine
    private let navigationService: NavigationService
    private let similarityService: SimilarityService
    private let duplicateService: DuplicateService
    private let assetRepo: AssetRepo
    private let db: DBConnection

    public init(
        db: DBConnection,
        sessionService: SessionService,
        workspaceStatusService: WorkspaceStatusService,
        jobService: JobService,
        photoRepo: PhotoRepo,
        settingsService: SettingsService,
        filterEngine: FilterEngine,
        navigationService: NavigationService,
        similarityService: SimilarityService,
        duplicateService: DuplicateService,
        assetRepo: AssetRepo
    ) {
        self.db = db
        self.sessionService = sessionService
        self.workspaceStatusService = workspaceStatusService
        self.jobService = jobService
        self.photoRepo = photoRepo
        self.settingsService = settingsService
        self.filterEngine = filterEngine
        self.navigationService = navigationService
        self.similarityService = similarityService
        self.duplicateService = duplicateService
        self.assetRepo = assetRepo
        registerExecutors()
    }

    /// 便捷装配：单 DB 连接构建全部已移植服务。
    public static func makeDefault(db: DBConnection) -> SessionCommandRouter {
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let similarityService = SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: SimilarityResultRepo(connection: db),
            connection: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            }
        )
        return SessionCommandRouter(
            db: db,
            sessionService: SessionService(
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                faceRepo: FaceRepo(connection: db),
                connection: db,
                dimensionsProvider: { path in
                    let dims = try RAWDecoder.getDimensions(path: path)
                    return (dims.width, dims.height)
                },
                assetRepo: AssetRepo(connection: db)
            ),
            workspaceStatusService: WorkspaceStatusService(
                connection: db,
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                outboxRepo: MetadataOutboxRepo(connection: db)
            ),
            jobService: JobService(repo: AnalysisJobRepo(connection: db)),
            photoRepo: photoRepo,
            settingsService: settingsService,
            filterEngine: FilterEngine(connection: db),
            navigationService: NavigationService(connection: db),
            similarityService: similarityService,
            duplicateService: DuplicateService(
                connection: db,
                thumbnailProvider: { path, size in
                    RAWDecoder.pixels9x8(path: path, maxPixel: size)
                },
                clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                    try ClusterEngine.clusterByHash(
                        entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                        mode: mode, onProgress: onProgress)
                }
            ),
            assetRepo: AssetRepo(connection: db)
        )
    }

    /// TS di/init.ts 的 executor 注册段（similarity.analyze / duplicate.scan）。
    /// JobService 恢复 interrupted 任务时依赖 autoResume 注册表，故装配期
    /// 同步注册（autoResume 默认 true）。
    private func registerExecutors() {
        jobService.registerExecutor(type: .similarityAnalyze) { [similarityService] job, context in
            // TS similarity.ipc.ts:100-121：abort 时同步取消相似度占用
            // （session 列仅在真正持有者取消时写入，见 SimilarityService.cancel）。
            if context.signal.aborted {
                try? similarityService.cancel(sessionId: job.scopeId, markStatus: false)
            }
            let checkpoint = job.checkpoint
            try await similarityService.analyze(
                sessionId: job.scopeId,
                threshold: checkpoint["threshold"]?.numberValue,
                minGroupSize: checkpoint["minGroupSize"]?.numberValue,
                groupingMode: checkpoint["groupingMode"]?.stringValue == "sequential" ? .sequential : .global,
                onProgress: { current, total, phase in
                    context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: checkpoint))
                }
            )
            return true
        }

        jobService.registerExecutor(type: .duplicateScan) { [duplicateService] job, context in
            // TS duplicate.ipc.ts:11-20：checkpoint.visualThreshold 为 number
            // 时透传，否则 undefined。
            let result = try await duplicateService.scanDuplicates(
                sessionId: job.scopeId,
                visualThreshold: job.checkpoint["visualThreshold"]?.numberValue.map(Int.init),
                signal: context.signal,
                onProgress: { current, total, phase in
                    context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: job.checkpoint))
                }
            )
            return result
        }
    }

    // MARK: CommandRouter

    public func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue {
        switch command {
        // ── session.*（3.2 服务层）──

        case "session.list":
            let sessions = try sessionService.listSessions()
            return try GatherCore.JSONValue(from: sessions)

        case "session.get":
            let id = try requiredString(params, "sessionId")
            guard let session = try sessionService.getSession(id) else {
                throw BridgeError.notFound("SESSION_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: session)

        case "session.create":
            let name = try requiredString(params, "name")
            let source = try optionalString(params, "source") ?? "folder"
            let sourcePath = try optionalString(params, "sourcePath") ?? ""
            let session = try sessionService.createSession(name: name, source: source, sourcePath: sourcePath)
            return try GatherCore.JSONValue(from: session)

        case "session.delete":
            let id = try requiredString(params, "sessionId")
            try sessionService.deleteSession(id, confirmed: confirmed(params))
            return .null

        case "session.delete_many":
            let ids = try requiredStringArray(params, "sessionIds")
            _ = try sessionService.deleteSessions(ids, confirmed: confirmed(params))
            return .null

        case "session.update":
            let id = try requiredString(params, "sessionId")
            let name = try requiredString(params, "name")
            let session = try sessionService.updateSession(sessionId: id, name: name)
            return try GatherCore.JSONValue(from: session)

        case "session.add_photos":
            let id = try requiredString(params, "sessionId")
            let filepaths = try requiredStringArray(params, "filepaths")
            let source = try optionalString(params, "source") ?? "import"
            let result = try sessionService.addPhotos(sessionId: id, filepaths: filepaths, source: source)
            return .object([
                "added": .number(Double(result.added)),
                "skipped": .number(Double(result.skipped)),
                "total": .number(Double(result.total)),
                "failedFiles": .array(result.failedFiles.map(GatherCore.JSONValue.string)),
            ])

        // ── photo.*（3.2 服务层）──

        case "photo.list":
            let sessionId = try requiredString(params, "sessionId")
            let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            // 轻投影列（列名与 TS PhotoProjectionRow 逐字一致，见 PhotoRepo.swift）。
            return .array(photos.map { row in
                .object([
                    "id": .string(row.id),
                    "session_id": .string(row.sessionId),
                    "filepath": .string(row.filepath),
                    "filename": .string(row.filename),
                    "checksum": .string(row.checksum),
                    "checksum_file_size": .number(Double(row.checksumFileSize)),
                    "checksum_file_mtime_ms": .number(row.checksumFileMtimeMs),
                    "status": .string(row.status),
                    "width": .number(Double(row.width)),
                    "height": .number(Double(row.height)),
                    "created_at": .string(row.createdAt),
                    "updated_at": .string(row.updatedAt),
                ])
            })

        // TS 源: photo.ipc.ts:96-112（键集分页；PAGE_SIZE=200 / MAX=1000）。
        case "photo.list_page":
            let sessionId = try requiredString(params, "sessionId")
            let limit = clampedLimit(params, default: 200, max: 1_000)
            let afterFirstRowid: Int64?
            if let raw = try optionalNumber(params, "afterFirstRowid"), raw.isFinite {
                afterFirstRowid = Int64(raw)
            } else {
                afterFirstRowid = nil
            }
            let expandVariants = optionalBool(params, "expandVariants") ?? false
            let page = try photoRepo.getAssetPage(sessionId: sessionId, afterFirstRowid: afterFirstRowid, limit: limit)
            return .object([
                "rows": .array(assemblePhotoRows(page.rows, sessionId: sessionId, expandVariants: expandVariants)),
                "cursor": page.cursor.map { .number(Double($0)) } ?? .null,
            ])

        // ── workspace（3.1 服务层）──

        case "workspace.status":
            let sessionId = try optionalString(params, "sessionId") ?? ""
            guard let status = try workspaceStatusService.getStatus(sessionId: sessionId) else {
                throw BridgeError.notFound("SESSION_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: status)

        // ── jobs.*（3.1 服务层）──

        case "jobs.list":
            let jobs = try jobService.list()
            return try GatherCore.JSONValue(from: jobs)

        // TS 源: jobs.ipc.ts:11 —— ok(jobs.cancel(jobId))。
        case "jobs.cancel":
            let jobId = try requiredString(params, "jobId")
            return .bool(try jobService.cancel(jobId))

        // TS 源: jobs.ipc.ts:12 —— ok(jobs.retry(jobId))。
        case "jobs.retry":
            let jobId = try requiredString(params, "jobId")
            return .bool(try jobService.retry(jobId))

        // TS 源: jobs.ipc.ts:13-19 —— destructive（confirmed 由 WebBridge 校验；
        // 直连路由时二次兜底，对齐 TS JOBS_CLEAR_CONFIRM_REQUIRED）。
        case "jobs.clear_completed":
            guard confirmed(params) else {
                throw BridgeError.badParams("JOBS_CLEAR_CONFIRM_REQUIRED")
            }
            return .number(Double(try jobService.clearCompleted()))

        // ── settings.*（3.6 服务层；TS 源 settings.ipc.ts）──

        case "settings.get_all":
            // settings.ipc.ts:11 —— ok(svc.getAll())：Record<string, string>。
            return .object(settingsService.getAll().mapValues(GatherCore.JSONValue.string))

        case "settings.get":
            // settings.ipc.ts:13-16 —— key 校验后 ok(svc.get(key))。
            let key = try validatedString(params, "key", maxLength: 256)
            return .string(settingsService.get(key))

        case "settings.set":
            // settings.ipc.ts:18-23 —— ok({ done: true })；value 允许空串。
            let key = try validatedString(params, "key", maxLength: 256)
            let value = try validatedString(params, "value", maxLength: 4096, allowEmpty: true)
            try settingsService.set(key, value: value)
            return .object(["done": .bool(true)])

        case "settings.reset":
            // settings.ipc.ts:25-32 —— 重置后 ok(svc.getAll())（菜单重建属
            // Electron 主进程职责，Swift 宿主无原生菜单，跳过）。
            try settingsService.reset()
            return .object(settingsService.getAll().mapValues(GatherCore.JSONValue.string))

        case "settings.set_language":
            // settings.ipc.ts:38-46 —— 非 'zh-CN'/'en' 抛 SETTINGS_LANGUAGE_INVALID。
            guard let language = try optionalString(params, "language"),
                  language == "zh-CN" || language == "en"
            else {
                throw BridgeError.badParams("SETTINGS_LANGUAGE_INVALID")
            }
            try settingsService.set("ui_language", value: language)
            return .object(["language": .string(language)])

        case "settings.get_ml_status":
            // settings.ipc.ts:48-79 —— 形状见 Protocol/Settings.swift MLStatusData。
            return try GatherCore.JSONValue(from: buildMLStatus())

        // ── filter.*（3.6 服务层；TS 源 filter.ipc.ts）──

        case "filter.photos":
            // filter.ipc.ts:39-69 —— 引擎内不钳制，IPC 层钳制 limit 1..500/offset ≥0
            // （默认 100/0），返回 PhotoData[]。
            let sessionId = try requiredString(params, "sessionId")
            let criteria = try parseFilterCriteria(params)
            let sortBy = try optionalString(params, "sortBy")
            let sortOrder = try optionalString(params, "sortOrder")
            let limit = clampedLimit(params, default: 100, max: 500)
            let offset = clampedOffset(params)
            let photos = try filterEngine.filterPhotos(
                sessionId: sessionId,
                criteria: criteria,
                sortBy: sortBy,
                sortOrder: sortOrder,
                limit: limit,
                offset: offset
            )
            return .array(photos.map(filterPhotoDataJSON))

        case "filter.photos_global":
            // filter.ipc.ts:71-94 —— ok({ photos, total })；total 为全局计数。
            let criteria = try parseFilterCriteria(params)
            let sessionId = try optionalString(params, "sessionId")
            let limit = clampedLimit(params, default: 100, max: 500)
            let offset = clampedOffset(params)
            let photos = try filterEngine.filterGlobally(
                criteria: criteria,
                limit: limit,
                offset: offset,
                sessionId: sessionId
            )
            let total = try filterEngine.countGlobally(criteria: criteria, sessionId: sessionId)
            return .object([
                "photos": try .array(photos.map { try GatherCore.JSONValue(from: $0) }),
                "total": .number(Double(total)),
            ])

        case "filter.suggest":
            // filter.ipc.ts:96-104 —— FilterSuggestion[]；keyword 非 string → ''。
            let sessionId = try requiredString(params, "sessionId")
            let keyword = try optionalString(params, "keyword") ?? ""
            let suggestions = try filterEngine.suggest(sessionId, keyword: keyword)
            return try .array(suggestions.map { try GatherCore.JSONValue(from: $0) })

        // ── navigation.*（3.6 服务层；TS 源 navigation.ipc.ts）──

        case "navigation.list":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: navigationService.list(sessionId: sessionId))

        case "navigation.split":
            let sessionId = try requiredString(params, "sessionId")
            let groupId = try requiredString(params, "groupId")
            let beforePhotoId = try requiredString(params, "beforePhotoId")
            return try GatherCore.JSONValue(
                from: navigationService.split(sessionId: sessionId, groupId: groupId, beforePhotoId: beforePhotoId)
            )

        case "navigation.merge":
            // ADR-017：服务内部重校验（组数 ≥2 / 同类型），IPC 仅做数组解析。
            let sessionId = try requiredString(params, "sessionId")
            let groupIds = try requiredStringArray(params, "groupIds")
            return try GatherCore.JSONValue(from: navigationService.merge(sessionId: sessionId, groupIds: groupIds))

        // ── sim.*（3.3 服务层；TS 源 similarity.ipc.ts）──

        case "sim.result":
            // similarity.ipc.ts:159-167 —— 同步查询；无结果返回 null（TS ok(null)）。
            let sessionId = try requiredString(params, "sessionId")
            let threshold = try optionalNumber(params, "threshold").map(Int.init)
            guard let result = try similarityService.getResult(sessionId: sessionId, threshold: threshold) else {
                return .null
            }
            return try GatherCore.JSONValue(from: result)

        case "sim.cancel_analysis":
            // similarity.ipc.ts:146-157 —— jobs.cancelScope + cancel(markStatus:false)，
            // 同步返回 ok(true)。
            let sessionId = try requiredString(params, "sessionId")
            _ = try jobService.cancelScope(type: .similarityAnalyze, scopeId: sessionId)
            try similarityService.cancel(sessionId: sessionId, markStatus: false)
            return .bool(true)

        // ── assets.*（3.2 服务层；TS 源 assets.ipc.ts:9-14）──

        case "assets.candidates":
            let sessionId = try optionalString(params, "sessionId")
            return try GatherCore.JSONValue(from: assetRepo.listCandidates(sessionId: sessionId))

        // ── dup.*（3.6 服务层；TS 源 duplicate.ipc.ts）──

        // TS: duplicate.ipc.ts:46-55 —— ok(getGroups(sessionId))。
        case "dup.groups":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: duplicateService.getGroups(sessionId: sessionId))

        // TS: duplicate.ipc.ts:57-75 —— destructive（confirmed 由 WebBridge 校验；
        // 直连路由时二次兜底）；resolution 仅 keep_one/keep_all（ADR-017）。
        case "dup.resolve":
            guard confirmed(params) else {
                throw BridgeError.badParams("DUP_RESOLVE_CONFIRM_REQUIRED")
            }
            let groupId = try requiredNumber(params, "groupId")
            let resolutionRaw = try requiredString(params, "resolution")
            guard let resolution = DupResolution(rawValue: resolutionRaw) else {
                throw BridgeError.badParams("Invalid resolution: must be keep_one or keep_all")
            }
            try duplicateService.resolveGroup(groupId: Int(groupId), resolution: resolution)
            return .bool(true)

        // TS: duplicate.ipc.ts:77-92 —— destructive；isKept 缺省 true。
        case "dup.resolve_member":
            guard confirmed(params) else {
                throw BridgeError.badParams("DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED")
            }
            let memberId = try requiredNumber(params, "memberId")
            let isKept = optionalBool(params, "isKept") ?? true
            try duplicateService.resolveMember(memberId: Int(memberId), isKept: isKept)
            return .bool(true)

        // ── image / face ──

        case "image.get_dimensions":
            let path = try requiredString(params, "path")
            let dims = try RAWDecoder.getDimensions(path: path)
            return .object([
                "width": .number(Double(dims.width)),
                "height": .number(Double(dims.height)),
            ])

        case "face.models_status":
            // 2.2 决议：Vision 无需模型资产 → 恒 vision provider、无需下载。
            return .object([
                "provider": .string(FaceProvider.vision.rawValue),
                "fallbackToOnnxEnabled": .bool(FaceInferenceConfig().fallbackToOnnxEnabled),
                "modelsPresent": .bool(true),
                "downloading": .bool(false),
            ])

        default:
            throw BridgeError.notImplemented(command)
        }
    }

    public func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        switch command {
        // TS 源: navigation.ipc.ts:6-15 —— async wrapper 内同步执行 analyze；
        // Swift 同步直连（与 TS 一致：主进程事件循环内同步 CPU + 同步 SQLite）。
        case "navigation.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(id: "", ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let burstGapSeconds = try? optionalNumber(params, "burstGapSeconds")
            let sceneGapSeconds = try? optionalNumber(params, "sceneGapSeconds")
            let dryRun = optionalBool(params, "dryRun") ?? false
            do {
                let groups = try navigationService.analyze(
                    sessionId: sessionId,
                    burstGapSeconds: burstGapSeconds ?? 2,
                    sceneGapSeconds: sceneGapSeconds ?? 1_800,
                    dryRun: dryRun
                )
                let data = try GatherCore.JSONValue(from: groups)
                completion(WebResponse(id: "", ok: true, data: data))
            } catch {
                completion(WebResponse(id: "", ok: false, error: Self.errorMessage(error)))
            }

        // TS 源: similarity.ipc.ts:169-187 —— 阈值重聚类（await worker）。
        case "sim.recluster":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(id: "", ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let threshold = (try? optionalNumber(params, "threshold"))
                        ?? settingsService.getNumber("default_threshold", defaultValue: 10)
                    let minGroupSize = (try? optionalNumber(params, "minGroupSize"))
                        ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
                    let groupingMode: SimilarityGroupingMode
                    if let raw = try? optionalString(params, "groupingMode"), raw == "sequential" {
                        groupingMode = .sequential
                    } else {
                        groupingMode = .global
                    }
                    try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
                    let result = try await similarityService.recluster(
                        sessionId: sessionId,
                        threshold: threshold,
                        minGroupSize: minGroupSize,
                        groupingMode: groupingMode
                    )
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(id: "", ok: true, data: data))
                } catch {
                    completion(WebResponse(id: "", ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: similarity.ipc.ts:100-144 —— 建 job 走 executor + waitForResult。
        // 阈值/组大小缺省走设置（默认 10/2），checkpoint/dedupeKey 逐字对齐 TS。
        case "sim.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(id: "", ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let threshold = try? optionalNumber(params, "threshold")
            let minGroupSize = try? optionalNumber(params, "minGroupSize")
            let groupingMode: SimilarityGroupingMode
            if let raw = try? optionalString(params, "groupingMode"), raw == "sequential" {
                groupingMode = .sequential
            } else {
                groupingMode = .global
            }
            Task {
                do {
                    try validateSimilarityParameters(
                        threshold: threshold ?? settingsService.getNumber("default_threshold", defaultValue: 10),
                        minGroupSize: minGroupSize ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
                    )
                    // TS: threshold ?? 'default'（undefined 时不输出数值）。
                    let dedupeThreshold = threshold.map { String($0) } ?? "default"
                    let dedupeMinGroupSize = minGroupSize.map { String($0) } ?? "default"
                    let job = try jobService.create(JobCreateParams(
                        type: .similarityAnalyze,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "similarity.analyze:\(sessionId):\(dedupeThreshold):\(dedupeMinGroupSize):\(groupingMode.rawValue)",
                        checkpoint: [
                            "threshold": threshold.map { .number($0) } ?? .null,
                            "minGroupSize": minGroupSize.map { .number($0) } ?? .null,
                            "groupingMode": .string(groupingMode.rawValue),
                        ]
                    ))
                    _ = try await jobService.waitForResult(jobId: job.id) as Any?
                    completion(WebResponse(id: "", ok: true, data: .bool(true)))
                } catch {
                    completion(WebResponse(id: "", ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: duplicate.ipc.ts:11-20（executor）+ 21-44（dup.scan 命令）——
        // checkpoint.visualThreshold 为 number 时透传；结果原样返回。
        case "dup.scan":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(id: "", ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let visualThreshold = try? optionalNumber(params, "visualThreshold")
            Task {
                do {
                    let job = try jobService.create(JobCreateParams(
                        type: .duplicateScan,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "duplicate.scan:\(sessionId):\(visualThreshold.map { "\($0)" } ?? "default")",
                        checkpoint: [
                            "visualThreshold": visualThreshold.map { .number($0) } ?? .null,
                        ]
                    ))
                    let result: DuplicateScanResult? = try await jobService.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobServiceError.jobFailed(job.id, "empty duplicate.scan result")
                    }
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(id: "", ok: true, data: data))
                } catch {
                    completion(WebResponse(id: "", ok: false, error: Self.errorMessage(error)))
                }
            }

        default:
            // 长任务（analyze/create_from_directory 等）随服务层逐个移植接入；
            // 当前未接线 → NOT_IMPLEMENTED。
            completion(WebResponse(id: "", ok: false, error: "NOT_IMPLEMENTED: \(command)"))
        }
    }

    // MARK: 参数读取

    private func requiredString(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> String {
        guard case .string(let value) = params[key] else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        return value
    }

    private func optionalString(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> String? {
        guard case .string(let value) = params[key] else { return nil }
        return value
    }

    /// TS helpers.validateString 语义：非 string 抛错；超长抛错；非 allowEmpty
    /// 时空白视为无效并 trim（allowEmpty 时原样返回）。
    private func validatedString(
        _ params: [String: GatherCore.JSONValue],
        _ key: String,
        maxLength: Int = 4096,
        allowEmpty: Bool = false
    ) throws -> String {
        let value = try requiredString(params, key)
        if value.count > maxLength {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        if !allowEmpty && value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return allowEmpty ? value : value.trimmingCharacters(in: .whitespaces)
    }

    private func requiredStringArray(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> [String] {
        guard case .array(let values) = params[key] else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
    }

    private func optionalNumber(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> Double? {
        guard case .number(let value) = params[key], value.isFinite else { return nil }
        return value
    }

    /// TS helpers.validateNumber 语义：非 number 抛错；NaN/Infinity 视为非法。
    private func requiredNumber(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> Double {
        guard case .number(let value) = params[key], value.isFinite else {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return value
    }

    private func optionalBool(_ params: [String: GatherCore.JSONValue], _ key: String) -> Bool? {
        guard case .bool(let value) = params[key] else { return nil }
        return value
    }

    private func confirmed(_ params: [String: GatherCore.JSONValue]) -> Bool {
        if case .bool(true) = params["confirmed"] { return true }
        return false
    }

    /// TS filter.ipc.ts 钳制：limit 1..upperBound（floor），缺省 defaultValue。
    private func clampedLimit(_ params: [String: GatherCore.JSONValue], default defaultValue: Int, max upperBound: Int) -> Int {
        guard let raw = try? optionalNumber(params, "limit") else { return defaultValue }
        return Swift.max(1, Swift.min(upperBound, Int(floor(raw))))
    }

    /// TS filter.ipc.ts 钳制：offset ≥ 0（floor），缺省 0。
    private func clampedOffset(_ params: [String: GatherCore.JSONValue]) -> Int {
        guard let raw = try? optionalNumber(params, "offset") else { return 0 }
        return max(0, Int(floor(raw)))
    }

    // MARK: 参数装配

    /// TS filter.ipc.ts parseFilterCriteria：schemaVersion 仅 1；结构由
    /// FilterGroup 解码校验（logic ∈ and/or、conditions 数组、递归 rule/group）。
    private func parseFilterCriteria(_ params: [String: GatherCore.JSONValue], schemaVersion: Int = 1) throws -> FilterGroup {
        guard schemaVersion == 1 else {
            throw BridgeError.badParams("FILTER_SCHEMA_UNSUPPORTED")
        }
        guard let value = params["criteria"],
              let data = try? JSONEncoder().encode(value)
        else {
            throw BridgeError.badParams("Filter criteria is invalid")
        }
        do {
            return try JSONDecoder().decode(FilterGroup.self, from: data)
        } catch {
            // TS 消息逐字一致（filter.ipc.ts:21-33 的校验失败路径）。
            throw BridgeError.badParams("Filter criteria is invalid")
        }
    }

    /// TS filter-engine.ts rowToPhotoData（filter.ipc.ts 直接透传）：metadata/
    /// result 为 JSON.parse 后的对象；width/height 恒 0（SELECT 未含该列）。
    private func filterPhotoDataJSON(_ photo: FilteredPhotoData) -> GatherCore.JSONValue {
        .object([
            "id": .string(photo.id),
            "sessionId": .string(photo.sessionId),
            "filepath": .string(photo.filepath),
            "filename": .string(photo.filename),
            "checksum": .string(photo.checksum),
            "hasExistingXmp": .bool(photo.hasExistingXmp),
            "faceCount": .number(Double(photo.faceCount)),
            "width": .number(Double(photo.width)),
            "height": .number(Double(photo.height)),
            "metadata": parseJSONObject(photo.metadata),
            "result": parseJSONObject(photo.result),
            "status": .string(photo.status),
            "createdAt": .string(photo.createdAt),
            "updatedAt": .string(photo.updatedAt),
        ])
    }

    /// TS photo.ipc.ts assemblePhotos：按逻辑资产分组（asset_id ?? "photo:<id>"），
    /// expandVariants=false 时每组取 raw → camera_jpeg → 首行，并带成员角色与
    /// 人脸计数（三次小查询，页级成本）。
    private func assemblePhotoRows(
        _ rows: [PhotoPageRow],
        sessionId: String,
        expandVariants: Bool
    ) -> [GatherCore.JSONValue] {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return [] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        var memberRoles: [String: String] = [:]
        if let roleRows = try? db.prepare("""
            SELECT p.id AS photo_id, am.member_role
            FROM photos p
            LEFT JOIN asset_members am ON am.file_id = p.asset_file_id
            WHERE p.session_id = ? AND p.id IN (\(placeholders))
        """).query([.text(sessionId)] + ids.map(DBValue.text)) {
            for row in roleRows {
                guard let photoId = row[0].textValue else { continue }
                memberRoles[photoId] = row[1].textValue ?? "unknown"
            }
        }
        var faceCounts: [String: Int] = [:]
        if let countRows = try? db.prepare("""
            SELECT photo_id, COUNT(*) as cnt FROM face_observations
            WHERE session_id = ? AND photo_id IN (\(placeholders)) GROUP BY photo_id
        """).query([.text(sessionId)] + ids.map(DBValue.text)) {
            for row in countRows {
                guard let photoId = row[0].textValue else { continue }
                faceCounts[photoId] = Int(row[1].intValue ?? 0)
            }
        }

        func toPhotoData(_ row: PhotoPageRow, variants: [PhotoPageRow]) -> GatherCore.JSONValue {
            var object: [String: GatherCore.JSONValue] = [
                "id": .string(row.id),
                "sessionId": .string(row.sessionId),
                "filepath": .string(row.filepath),
                "filename": .string(row.filename),
                "checksum": .string(row.checksum ?? ""),
                "hasExistingXmp": .bool(false),
                "faceCount": .number(Double(faceCounts[row.id] ?? 0)),
                "width": .number(Double(row.width)),
                "height": .number(Double(row.height)),
                "metadata": .object([:]),
                "result": .object([:]),
                "status": .string(row.status),
                "variantCount": .number(Double(variants.count)),
                "variants": .array(variants.map { variant in
                    .object([
                        "photoId": .string(variant.id),
                        "filepath": .string(variant.filepath),
                        "filename": .string(variant.filename),
                        "role": .string(memberRoles[variant.id] ?? "unknown"),
                    ])
                }),
                "createdAt": .string(row.createdAt),
                "updatedAt": .string(row.updatedAt),
            ]
            // TS: assetId: row.asset_id ?? undefined —— nil 时不输出 key。
            if let assetId = row.assetId {
                object["assetId"] = .string(assetId)
            }
            return .object(object)
        }

        var groups: [String: [PhotoPageRow]] = [:]
        var order: [String] = []
        for row in rows {
            let key = row.assetId ?? "photo:\(row.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        if expandVariants {
            return rows.map { toPhotoData($0, variants: groups[$0.assetId ?? "photo:\($0.id)"] ?? [$0]) }
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            let preferred = variants.first { memberRoles[$0.id] == "raw" }
                ?? variants.first { memberRoles[$0.id] == "camera_jpeg" }
                ?? variants[0]
            return toPhotoData(preferred, variants: variants)
        }
    }

    /// TS JSON.parse 语义：字符串解析为对象，失败回退 {}。
    private func parseJSONObject(_ json: String) -> GatherCore.JSONValue {
        let parsed = (try? GatherCore.JSONValue.parse(json)) ?? .object([:])
        if case .object = parsed { return parsed }
        return .object([:])
    }

    // MARK: settings.get_ml_status（TS 源 settings.ipc.ts:48-79 + provider.ts）

    /// 形状逐字段对齐 settings.ipc.ts:53-78；差异（已在注释标注）：
    /// - modelIsUsable 用「存在且非零字节」近似 TS isValidOnnxModel 的结构校验
    /// - resolveModelPath 无 process.resourcesPath 候选（Swift 无等价物）
    /// - autoBackendLabel 内联 mainCopy 双语文案（locale-copy.ts:107/164）
    private func buildMLStatus() throws -> MLStatusData {
        let provider = settingsService.get("onnx_provider", defaultValue: "auto")
        let locale = effectiveAppLocale()
        let modelsDir = modelResourcesDir()
        let detectorPath = settingsService.get("detector_model_path", defaultValue: "models/face_detector.onnx")
        let encoderPath = settingsService.get("encoder_model_path", defaultValue: "models/face_encoder.onnx")
        let detectorResolved = resolveModelPath(detectorPath, modelsDir: modelsDir)
        let encoderResolved = resolveModelPath(encoderPath, modelsDir: modelsDir)
        return MLStatusData(
            platform: "darwin",
            autoBackend: "coreml",
            autoBackendLabel: locale == "zh-CN"
                ? "CoreML（失败自动回退 CPU）"
                : "CoreML (falls back to CPU on failure)",
            provider: provider,
            isAuto: provider == "auto",
            availableBackends: [
                MLBackendOption(value: "coreml", label: "CoreML"),
                MLBackendOption(value: "cpu", label: "CPU"),
            ],
            modelResourcesDir: modelsDir,
            detectorModel: MLModelPresence(
                path: detectorPath,
                resolvedPath: detectorResolved,
                exists: modelUsable(detectorResolved)
            ),
            encoderModel: MLModelPresence(
                path: encoderPath,
                resolvedPath: encoderResolved,
                exists: modelUsable(encoderResolved)
            ),
            modelInfo: MLModelInfo(
                detectInputSize: Int(settingsService.getNumber("detect_input_size", defaultValue: 640)),
                secondaryDetectInputSize: Int(settingsService.getNumber("detect_secondary_input_size", defaultValue: 128)),
                previewMaxDimension: Int(settingsService.getNumber("face_preview_max_dimension", defaultValue: 2048)),
                encoderInputSize: Int(settingsService.getNumber("encoder_input_size", defaultValue: 112)),
                embeddingDim: Int(settingsService.getNumber("embedding_dim", defaultValue: 512))
            )
        )
    }

    /// TS locale-app.ts effectiveAppLocale：ui_language 覆盖 > 系统语言（近似
    /// app.getLocale()）> 'en'；非 zh 前缀一律 'en'。
    private func effectiveAppLocale() -> String {
        let uiLanguage = settingsService.get("ui_language", defaultValue: "")
        if uiLanguage == "zh-CN" || uiLanguage == "en" { return uiLanguage }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? "zh-CN" : "en"
    }

    /// TS provider.ts getModelResourcesDir：userData/models（best-effort 创建）。
    private func modelResourcesDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Gather/models", isDirectory: true).path ?? "models"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// TS provider.ts resolveModelPath：绝对路径直取；相对路径依次尝试
    /// userData/models/<filename>（resourcesPath 候选 Swift 无等价物，跳过）。
    private func resolveModelPath(_ modelPath: String, modelsDir: String) -> String {
        if modelPath.hasPrefix("/") { return modelPath }
        if FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath).standardizedFileURL.path
        }
        let filename = modelPath.replacingOccurrences(
            of: "^models[/\\\\]",
            with: "",
            options: .regularExpression
        )
        return (modelsDir as NSString).appendingPathComponent(filename)
    }

    /// TS provider.ts modelIsUsable（isValidOnnxModel）的近似：存在且非零字节。
    private func modelUsable(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    // MARK: 错误消息

    /// 错误 message 保持 GatherErrorCode 字符串（renderer translateError 映射）。
    private static func errorMessage(_ error: Error) -> String {
        if let bridgeError = error as? BridgeError {
            return bridgeError.description
        }
        // 各已移植服务的错误 description 与 TS 错误消息逐字一致。
        if let settingsError = error as? SettingsError { return settingsError.description }
        if let navigationError = error as? NavigationError { return navigationError.description }
        if let filterError = error as? FilterEngineError { return filterError.description }
        if let similarityError = error as? SimilarityServiceError { return similarityError.gatherCode.rawValue }
        if let assetError = error as? PhotoAssetResolverError { return assetError.gatherCode.rawValue }
        if let duplicateError = error as? DuplicateServiceError {
            return duplicateError.description
        }
        // JobService.waitForResult 失败终态：message 即 TS errorMessage
        // （executor 抛错经 String(describing:) 记录，错误枚举 description 对齐 TS）。
        if case JobServiceError.jobFailed(_, let message) = error { return message }
        if error is JobCancelledError { return "CANCELLED" }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String
            ?? nsError.localizedDescription
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case notImplemented(String)
    case badParams(String)
    case notFound(String)

    var description: String {
        switch self {
        case .notImplemented(let command): return "NOT_IMPLEMENTED: \(command)"
        case .badParams(let message): return message
        case .notFound(let code): return code
        }
    }
}

extension GatherCore.JSONValue {
    init<T: Encodable>(from value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(GatherCore.JSONValue.self, from: data)
    }
}
