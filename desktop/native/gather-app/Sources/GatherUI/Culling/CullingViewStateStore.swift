// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewStateStore.swift
// B3 / 浏览状态恢复（20-culling-viewer §1.1 #12）：按 sessionId 持久化挑片查看状态。
//
// 为什么独立存档：settings 表是**用户偏好**（跨会话、跨工作区），而"这个会话看到哪"
// 是每次会话的浏览状态（scope/filters/sort/当前照片/参考槽/布局/面板）。混进 settings
// 会让"换会话"无法隔离，也会污染设置页。这里用 UserDefaults + JSON + version 字段，
// 每个会话一个键；损坏或旧版本一律当作没有存档（fail-safe 回默认，不崩、不阻塞进页）。
//
// 保存时机：页面 disappear / 切布局 / 切筛选范围 / 换当前照片 / 参考槽变化后 0.5s
// 节流（CullingViewStateSaveThrottle：只保留最新一份）；shutdown 时 flush。恢复
// 期间（isViewStateRestorationFinished=false）不写盘，防止首屏默认值覆盖存档。
import Foundation
import GatherProtocol

// MARK: - 存档纯值

/// 筛选六维的落盘投影。
///
/// 只存 raw 字符串（与 FilterState 的 UI 枚举解耦）：存档格式不依赖 UI 类型，
/// 旧版本/未知枚举值恢复时逐项丢弃而不是整份失败。
struct CullingViewFilters: Codable, Equatable, Sendable {
    var unreviewedOnly = false
    var pickState: String?
    var rating: Int?
    var colorLabel: String?
    var qualityStatus: String?
    var metadataConflictOnly = false
    var triageVerdicts: [String]?
}

/// 参考槽（照片 id + 预览路径 + 展示名）。
///
/// 查看器只读展示用：恢复时按 id/路径重新取预览；照片被删/移出会话时查看器
/// 自己显示占位，不因参考槽过期阻断进页。
struct CullingViewReference: Codable, Equatable, Sendable {
    var photoId: String
    var filepath: String
    var filename: String

    init(photoId: String, filepath: String, filename: String = "") {
        self.photoId = photoId
        self.filepath = filepath
        self.filename = filename
    }
}

/// 一个会话的挑片查看状态（纯值；字段全部是可编解码的基础类型）。
struct CullingViewState: Codable, Equatable, Sendable {
    /// 存档格式版本：不匹配时整份丢弃（不做猜测式迁移）。
    static let currentVersion = 1

    var version: Int
    /// ScopeMode.rawValue（all / filtered / similarityGroup）。
    var scope: String
    var filters: CullingViewFilters
    /// CullingSort.rawValue。
    var sort: String
    /// CullingLayoutMode.rawValue。
    var layout: String
    /// CullingGridDensity.rawValue。
    var density: String
    /// 上次停留的照片；nil = 没有当前照片（空会话/上次就是首张且未落盘）。
    var currentPhotoId: String?
    var reference: CullingViewReference?
    /// 相似度范围下的组 id（scope=similarityGroup 时才有意义）。
    var similarityGroupId: String?
    var filmstripExpanded: Bool
    var inspectorVisible: Bool

    init(
        version: Int = CullingViewState.currentVersion,
        scope: String,
        filters: CullingViewFilters = CullingViewFilters(),
        sort: String,
        layout: String,
        density: String,
        currentPhotoId: String? = nil,
        reference: CullingViewReference? = nil,
        similarityGroupId: String? = nil,
        filmstripExpanded: Bool = true,
        inspectorVisible: Bool = true
    ) {
        self.version = version
        self.scope = scope
        self.filters = filters
        self.sort = sort
        self.layout = layout
        self.density = density
        self.currentPhotoId = currentPhotoId
        self.reference = reference
        self.similarityGroupId = similarityGroupId
        self.filmstripExpanded = filmstripExpanded
        self.inspectorVisible = inspectorVisible
    }
}

// MARK: - 存档读写（每个会话一个键）

/// 按 sessionId 读写挑片查看状态。
///
/// internal + 可注入 UserDefaults：生产用 .standard；测试用独立 suite 隔离，
/// 不污染真实用户默认值。
struct CullingViewStateStore {
    /// 键前缀带版本：格式升级时旧键自然失效（不会把旧结构当新结构解码）。
    static let keyPrefix = "culling.viewState.v1."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ sessionId: String) -> String {
        keyPrefix + sessionId
    }

    /// 读取存档；无存档 / 损坏 / 旧版本一律返回 nil（并清掉坏键，避免每次进页重试）。
    func load(sessionId: String) -> CullingViewState? {
        guard !sessionId.isEmpty else { return nil }
        let storageKey = Self.key(sessionId)
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let state = try JSONDecoder().decode(CullingViewState.self, from: data)
            guard state.version == CullingViewState.currentVersion else {
                // 旧版本不猜测迁移：丢弃回默认，下次保存写新版本。
                defaults.removeObject(forKey: storageKey)
                return nil
            }
            return state
        } catch {
            // 损坏存档不能挡住进页：丢弃 + 记 warn（不弹错误、不崩）。
            defaults.removeObject(forKey: storageKey)
            GatherLogger.log(
                "culling viewState dropped (decode failed): \(error)", level: .warn)
            return nil
        }
    }

    /// 写入存档（UserDefaults 即时落盘；编码失败只记日志，不影响 UI）。
    func save(_ state: CullingViewState, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.key(sessionId))
        } catch {
            GatherLogger.log(
                "culling viewState failed to encode: \(error)", level: .warn)
        }
    }

    /// 清理整个会话的存档（重置挑片/会话删除时可用；当前流程只清当前照片字段）。
    func clear(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        defaults.removeObject(forKey: Self.key(sessionId))
    }

    /// 只清"上次停留的照片"（照片被删/筛选变化导致找不到时）。
    /// 保留筛选/排序/布局等其余字段，下次进页仍按上次筛选打开。
    func clearCurrentPhoto(sessionId: String) {
        guard var state = load(sessionId: sessionId) else { return }
        state.currentPhotoId = nil
        save(state, sessionId: sessionId)
    }
}

// MARK: - 保存节流（纯逻辑，可单测）

/// 保存去抖/合并：只保留最新一份待写状态，代数用来丢弃过期的睡眠任务。
///
/// 挑片是 2–3 拍/秒的连按流，每次按键都写 UserDefaults 既无必要也会让主线程
/// 抖动；这里合并成"停顿 0.5s 写最后一次"。
struct CullingViewStateSaveThrottle: Equatable, Sendable {
    /// 默认去抖（毫秒）。
    static let defaultDebounceMilliseconds = 500

    private(set) var pending: CullingViewState?
    private(set) var generation = 0

    var hasPending: Bool { pending != nil }

    /// 登记最新状态并返回本次代数；调用方把代数交给睡眠任务，过期即丢弃。
    mutating func enqueue(_ state: CullingViewState) -> Int {
        pending = state
        generation &+= 1
        return generation
    }

    /// 取走待写状态（仅当代数仍是最新时；过期返回 nil）。
    mutating func take(expectedGeneration: Int) -> CullingViewState? {
        guard expectedGeneration == generation else { return nil }
        return take()
    }

    /// 无条件取走待写状态（flush 用；无待写返回 nil）。
    mutating func take() -> CullingViewState? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - 恢复参数

/// 恢复当前照片时的定位预算。
///
/// 分页是键集游标（没有 offset），无法"直接跳到第 N 页"；这里用服务端单次
/// 上限 2000 的大页向前续读，覆盖用户上次停留的位置。10 页 = 首屏 500 + 2 万张，
/// 与 CullingSelectionQuery.maxIds（20_000）同量级；超出则当作"找不到"回退首张。
enum CullingViewStateRestore {
    static let seekPageLimit = 2_000
    static let maxSeekPages = 10
}

// MARK: - CullingViewModel：恢复 / 保存 / 定位

extension CullingViewModel {
    /// 进页第一步：读本会话存档。
    ///
    /// - 返回非 nil：页面据此恢复 chrome（布局/密度/检查器/胶片条）；VM 同时已
    ///   应用 scope/filters/sort/相似组，并记住待定位的当前照片。
    /// - 返回 nil：没有可用存档（含损坏/旧版本），并立即进入"可保存"态。
    ///
    /// 只生效一次（hasAttemptedViewStateRestore）；同一次运行内回到页签时内存
    /// 状态即真相，只用存档恢复页面 chrome。
    @discardableResult
    func takeSavedViewState() -> CullingViewState? {
        guard !hasAttemptedViewStateRestore, !sessionId.isEmpty else { return nil }
        hasAttemptedViewStateRestore = true
        guard let saved = viewStateStore.load(sessionId: sessionId) else {
            isViewStateRestorationFinished = true
            return nil
        }

        // 页面 chrome 先落 VM（保存时与业务状态一起写）。
        savedViewLayout = CullingLayoutMode(rawValue: saved.layout) ?? savedViewLayout
        savedViewDensity = CullingGridDensity(rawValue: saved.density) ?? savedViewDensity
        savedViewInspectorVisible = saved.inspectorVisible
        savedViewFilmstripExpanded = saved.filmstripExpanded
        viewerReference = saved.reference

        guard page == nil else {
            // 同一次运行内回到页签：筛选/当前照片已内存态，不重新套存档。
            return saved
        }

        // 首载前应用范围/筛选/排序：首页请求必须按恢复后的条件发出。
        scopeMode = ScopeMode(rawValue: saved.scope) ?? .all
        filterState = FilterState(restored: saved.filters)
        sortMode = CullingSort(rawValue: saved.sort) ?? sortMode
        // 用户显式恢复的排序优先于设置默认值，别被 refreshGridDefaults 覆盖。
        isSortUserSet = true
        selectedSimilarityGroupId = saved.similarityGroupId ?? ""
        // 与 setScope 同语义：筛选只在"按筛选"范围生效；其余范围不携带筛选。
        if scopeMode != .filtered {
            filterState = FilterState()
        } else if !filterState.isActive {
            scopeMode = .all
        }
        pendingRestoredCurrentPhotoId = saved.currentPhotoId
        isRestoringViewState = true
        return saved
    }

    /// 页面把 chrome 状态同步给 VM（布局/密度/检查器/胶片条）。
    ///
    /// 不在这里直接写盘：调用方（页面 onChange / 进页 task）随后调
    /// scheduleViewStateSave()，让"进页对齐"这类非用户操作也能节流合并。
    func noteViewChrome(
        layout: CullingLayoutMode,
        density: CullingGridDensity,
        inspectorVisible: Bool,
        filmstripExpanded: Bool
    ) {
        savedViewLayout = layout
        savedViewDensity = density
        savedViewInspectorVisible = inspectorVisible
        savedViewFilmstripExpanded = filmstripExpanded
    }

    /// 状态变化后调度一次节流保存（0.5s 内的多次变化只写最后一次）。
    func scheduleViewStateSave() {
        guard !isShutdown, isViewStateRestorationFinished, !isRestoringViewState else { return }
        let generation = viewStateSaveThrottle.enqueue(currentViewStateSnapshot())
        viewStateSaveTask?.cancel()
        let milliseconds = max(0, viewStateDebounceMilliseconds)
        let sleep = viewStateSleep
        viewStateSaveTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.milliseconds(milliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushViewStateSave(expectedGeneration: generation)
        }
    }

    /// 立即写掉待保存状态（页面离开 / VM 关闭 / 测试用）。
    ///
    /// - Parameter expectedGeneration: 由睡眠任务传入；代数过期说明有更新的
    ///   状态在后，不写旧值。nil = 无条件 flush（离开/关闭路径）。
    func flushViewStateSave(expectedGeneration: Int? = nil) {
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        guard isViewStateRestorationFinished else { return }
        let state: CullingViewState?
        if let expectedGeneration {
            state = viewStateSaveThrottle.take(expectedGeneration: expectedGeneration)
        } else {
            state = viewStateSaveThrottle.take()
        }
        guard let state else { return }
        viewStateStore.save(state, sessionId: sessionId)
    }

    /// 恢复收尾：允许后续保存；若仍在恢复中则清掉待定位目标。
    func finishViewStateRestore() {
        guard isRestoringViewState else {
            isViewStateRestorationFinished = true
            return
        }
        isRestoringViewState = false
        isViewStateRestorationFinished = true
        pendingRestoredCurrentPhotoId = nil
        // 恢复后的真实状态立刻落一份（首次进页即存档；找不到照片时也把回退
        // 结果写掉，下次不会重复 seek 一张已不存在的照片）。
        scheduleViewStateSave()
    }

    /// 首载完成后定位存档里的当前照片。
    ///
    /// - 在首页内：直接选中并收敛选择集（与单击语义一致；**不恢复多选**）。
    /// - 不在首页：用服务端单次上限的大页向前续读，最多 maxSeekPages 页。
    /// - 仍找不到（照片被删/筛选后不在范围）：回退首张并清掉存档里的当前照片字段。
    func resolveRestoredCurrentPhoto() async {
        guard let target = pendingRestoredCurrentPhotoId else { return }
        guard let page, !page.assets.isEmpty else {
            // 空会话：没有"当前照片"可定位，清字段后收尾。
            pendingRestoredCurrentPhotoId = nil
            viewStateStore.clearCurrentPhoto(sessionId: sessionId)
            return
        }
        if page.assets.contains(where: { $0.photo.id == target }) {
            pendingRestoredCurrentPhotoId = nil
            applyRestoredCurrentPhoto(target)
            return
        }

        let originalLimit = pageLimit
        pageLimit = CullingViewStateRestore.seekPageLimit
        defer { pageLimit = originalLimit }

        var requests = 0
        var allLoaded = page.assets.count >= page.total
        while !allLoaded, requests < CullingViewStateRestore.maxSeekPages {
            let before = self.page?.assets.count ?? 0
            await loadPage(reset: false)
            requests += 1
            guard let currentPage = self.page else { break }
            if currentPage.assets.contains(where: { $0.photo.id == target }) {
                pendingRestoredCurrentPhotoId = nil
                applyRestoredCurrentPhoto(target)
                return
            }
            // 没有新数据 / 已读到 total：后面不可能再有目标。
            allLoaded = currentPage.assets.count >= currentPage.total
                || currentPage.assets.count == before
            if allLoaded { break }
        }

        // 找不到：回退首张（loadPage 已保证 currentPhotoId 在首页内），清存档字段。
        pendingRestoredCurrentPhotoId = nil
        viewStateStore.clearCurrentPhoto(sessionId: sessionId)
        GatherLogger.log(
            "culling viewState: restored photo \(target) not found; fallback to first", level: .debug)
    }

    /// 查看器把参考槽变化回写 VM（R 设置/取消后调用；清空时写 nil）。
    func recordViewerReference(photoId: String?, filepath: String?, filename: String?) {
        guard isViewStateRestorationFinished else { return }
        if let photoId, let filepath, !photoId.isEmpty, !filepath.isEmpty {
            viewerReference = CullingViewReference(
                photoId: photoId, filepath: filepath, filename: filename ?? "")
        } else {
            viewerReference = nil
        }
        scheduleViewStateSave()
    }

    // MARK: 私有

    private func applyRestoredCurrentPhoto(_ photoId: String) {
        currentPhotoId = photoId
        // 只恢复"看哪张"：多选是批次/对比的构造状态，任务明确不持久化；
        // 收敛成单张与单击胶片条的语义一致。
        selectedPhotoIds = [photoId]
        selectionAnchorId = photoId
        selectionSnapshot = nil
    }

    private func currentViewStateSnapshot() -> CullingViewState {
        CullingViewState(
            scope: scopeMode.rawValue,
            filters: filterState.savedViewFilters,
            sort: sortMode.rawValue,
            layout: savedViewLayout.rawValue,
            density: savedViewDensity.rawValue,
            currentPhotoId: currentPhotoId ?? currentAsset?.photo.id,
            reference: viewerReference,
            similarityGroupId: scopeMode == .similarityGroup ? selectedSimilarityGroupId : nil,
            filmstripExpanded: savedViewFilmstripExpanded,
            inspectorVisible: savedViewInspectorVisible)
    }
}
