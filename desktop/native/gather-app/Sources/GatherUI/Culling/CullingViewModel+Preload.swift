// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Preload.swift
// P0-4（Wave1 竞品缺口评审 20-culling-browse #4）：翻片速度链路的邻张预取接线。
//
// 背景：PhotoAPI.preloadThumbnails / preloadPreviews / prioritizeThumbnail 与
// ImagePreloadService 早已实现，但 GatherUI 里零调用——翻一张 = 现解一次 RAW
// （RAW 100–800ms），2000 张的活会被推回 Photo Mechanic / FastRawViewer。
//
// 本文件只有两块：
// 1) 纯逻辑 CullingPreloadPlanner：当前照片 + 已加载页 → ±2 邻张计划（可单测，
//    不触 I/O）；近邻（±1）是翻片主力方向、远邻（±2）是投机预热、下一张单独
//    作为宿主缩略图优先级信号。
// 2) 调度 scheduleNeighborPreload：去抖后为最后一张当前照片预热；切图/切布局/
//    离开页面/隐藏时取消未完成的预取。
//
// 两条预热通道（分工，不重复解同一批的同一档位）：
// - 近邻（±1）：走与查看器**完全同键**的 PhotoThumbnailDecoder.decodeAsync
//   （2560 preview）并写入 PhotoThumbnailCache——这是唯一能让"按 → 立刻出图"
//   成立的机制（灯箱 LightboxView.prefetchAdjacent 的既有正确做法：命中即跳过、
//   受解码闸门去重、顺带落磁盘缓存；宿主 RAWDecoder 不解码进 GUI 缓存）。
// - 远邻（±2）/下一张：调宿主既有 API（preloadPreviews / prioritizeThumbnail）
//   作为 OS 页缓存预热与优先级信号；远邻不在 GUI 解码，避免与显示档位抢闸门。
//
// 取消语义：预取任务 defer 到 Task 取消；切页/关闭由 VM 的 shutdown() /
// setVisible(false) 取消；页面隐藏期不发命令（外壳既有约定）。
import AppKit
import Foundation
import GatherProtocol

// MARK: - 纯逻辑：预取计划

/// 一张待预取的邻张（纯数据）。
struct CullingPreloadCandidate: Equatable, Sendable {
    let photoId: String
    let path: String
    /// 相对当前照片的偏移（+1 = 下一张，-1 = 上一张）。
    let offset: Int
}

/// 一次翻片要预取的对象分组（纯数据，不含任何 I/O）。
struct CullingPreloadPlan: Equatable, Sendable {
    /// 近邻（±1）：必须进显示缓存，翻过去要零等待。
    let nearRing: [CullingPreloadCandidate]
    /// 远邻（±2）：投机预热，交给宿主侧（不占 GUI 解码闸门）。
    let farRing: [CullingPreloadCandidate]
    /// 下一张：宿主侧缩略图优先级信号（用户按 → 时把目标排到队首）。
    let nextTarget: CullingPreloadCandidate?

    var isEmpty: Bool { nearRing.isEmpty && farRing.isEmpty && nextTarget == nil }
}

/// 预取计划换算（纯逻辑；不读文件、不碰缓存，便于单测）。
enum CullingPreloadPlanner {
    /// 邻张半径（±2）。
    static let radius = 2

    /// 由「当前照片 + 已加载页」算出预取计划。
    ///
    /// - 顺序：+1 → −1 → +2 → −2（翻片主力方向优先，解码名额先给正向）。
    /// - 跳过：当前照片自身、越界偏移、路径为空（未索引/已移出工作区）。
    static func plan(
        assets: [CullingAsset],
        currentPhotoId: String?,
        radius: Int = CullingPreloadPlanner.radius
    ) -> CullingPreloadPlan {
        plan(
            assets: assets,
            currentPhotoIndex: currentIndex(assets: assets, currentPhotoId: currentPhotoId),
            radius: radius)
    }

    /// 调用方已用 O(1) 索引定位当前照片时的入口（VM 热路径：不再扫整页）。
    /// 语义与 `plan(assets:currentPhotoId:)` 完全一致（单测仍走旧入口）。
    static func plan(
        assets: [CullingAsset],
        currentPhotoIndex: Int?,
        radius: Int = CullingPreloadPlanner.radius
    ) -> CullingPreloadPlan {
        let safeRadius = max(1, radius)
        guard !assets.isEmpty, let index = currentPhotoIndex,
              assets.indices.contains(index) else {
            return CullingPreloadPlan(nearRing: [], farRing: [], nextTarget: nil)
        }
        func candidate(_ offset: Int) -> CullingPreloadCandidate? {
            let target = index + offset
            guard assets.indices.contains(target) else { return nil }
            let asset = assets[target]
            let path = asset.photo.filepath
            guard !path.isEmpty else { return nil }
            return CullingPreloadCandidate(photoId: asset.photo.id, path: path, offset: offset)
        }
        var order: [Int] = []
        for distance in 1...safeRadius {
            order.append(distance)
            order.append(-distance)
        }
        var nearRing: [CullingPreloadCandidate] = []
        var farRing: [CullingPreloadCandidate] = []
        for offset in order {
            guard let item = candidate(offset) else { continue }
            if abs(offset) == 1 {
                nearRing.append(item)
            } else {
                farRing.append(item)
            }
        }
        return CullingPreloadPlan(
            nearRing: nearRing,
            farRing: farRing,
            nextTarget: candidate(1)
        )
    }

    /// 页集合签名（Wave4b / P2：预取去抖只在**页集合真变化**时重置）。
    ///
    /// 为什么不用 pageVersion：决策回显每次 applyDecisionStates 都会 +1，用它当
    /// 触发键会让 120ms 去抖在快速连按（<120ms/拍）时被反复取消，恰好饿死预取。
    /// 这里只取 O(1) 的页身份（数量 + 首/中/尾 id），决策回显不改变这些值。
    static func pageSignature(assets: [CullingAsset]) -> String {
        guard !assets.isEmpty else { return "empty" }
        let first = assets[0].photo.id
        let middle = assets[assets.count / 2].photo.id
        let last = assets[assets.count - 1].photo.id
        return "\(assets.count)|\(first)|\(middle)|\(last)"
    }

    /// 当前照片下标；currentPhotoId 为空/不在页内时回退 0（与查看器 currentIndex 同口径）。
    static func currentIndex(assets: [CullingAsset], currentPhotoId: String?) -> Int? {
        guard !assets.isEmpty else { return nil }
        guard let currentPhotoId else { return 0 }
        return assets.firstIndex(where: { $0.photo.id == currentPhotoId }) ?? 0
    }
}

// MARK: - 调度（VM extension）

extension CullingViewModel {
    /// 预取用的显示档位：与查看器底层整图位图同键（PhotoDetailTier.baseDimension）。
    nonisolated static let preloadPreviewDimension = PhotoDetailTier.baseDimension
    /// 宿主侧远邻预热的档位（Wave4b / P2-4）：远邻是投机预热，**不再整解显示档
    /// 2560**——宿主解码结果本来就不进 GUI 缓存，整解只是和近邻/当前图抢 CPU。
    /// 降到 1024 仅用于喂 OS 页缓存/ImageIO，真正的"翻过去零等待"由近邻 GUI
    /// 预热负责（那一档与显示完全同键）。
    static let preloadHostWarmDimension = 1024
    /// 宿主缩略图优先级信号使用的缩略图档位（胶片条/首屏小图档）。
    static let preloadPriorityThumbnailSize = 256

    /// 当前照片 / 页变化后调度邻张预取（去抖后只为最后一张当前照片预热）。
    ///
    /// 去抖还承担一个关键职责：**当前图自己的解码先跑**。预取若与切图同时
    /// 进解码闸门，就会把当前图挤到队列后面（用户感知到的仍是"翻片要等"）。
    public func scheduleNeighborPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        guard !isShutdown, isActive, let assets = page?.assets, !assets.isEmpty else { return }
        preloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(self.preloadDebounceMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled, !self.isShutdown, self.isActive else { return }
            await self.runNeighborPreload()
        }
    }

    /// 取消未完成的邻张预取（离开查看器/切到网格/隐藏/关闭时调用）。
    public func cancelNeighborPreload() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    /// 执行一次邻张预取（去抖后的实际工作；internal 供测试直接驱动，不等去抖）。
    func runNeighborPreload() async {
        guard !isShutdown, !isCancelledPreload() else { return }
        guard let assets = page?.assets, !assets.isEmpty else { return }
        let plan = CullingPreloadPlanner.plan(
            assets: assets,
            currentPhotoIndex: currentPageIndex()
        )
        guard !plan.isEmpty else { return }

        // 先按「当前缓存状态」算出未命中集合：预热开始后再判定会把刚预热成功的
        // 也算成命中，宿主侧通道就永远不发（也会掩盖真正的重复解码）。
        // task-17：探测（含磁盘 stat/读）放到后台，避免主线程同步 I/O。
        // 评审 R5-06：await 回来后若页/当前照片已变，计划与 miss 集合都已过期，
        // 继续消费会把预热/宿主优先级信号发到旧目标（浪费且干扰新页）。
        let plannedAssignment = pageAssignmentCount
        let plannedCurrentPhotoID = currentPhotoId
        let misses = await Self.computePreloadMisses(
            near: plan.nearRing,
            far: plan.farRing,
            next: plan.nextTarget
        )
        guard !Task.isCancelled, !isShutdown,
              plannedAssignment == pageAssignmentCount,
              plannedCurrentPhotoID == currentPhotoId else { return }
        let nearMisses = misses.nearMisses
        let farMisses = misses.farMisses
        let nextIsMiss = misses.nextIsMiss

        // 下一张：先发宿主缩略图优先级信号（按 → 时把目标排到宿主队列前的既有语义）。
        // 放在近邻预热之前：这是"优先级"信号，晚发就等于没发。
        if let next = plan.nextTarget, nextIsMiss,
           !hostPreloadedPaths.contains(preloadThumbnailKey(next.path)) {
            hostPreloadedPaths.insert(preloadThumbnailKey(next.path))
            await prioritizeThumbnail(path: next.path)
            guard !Task.isCancelled, !isShutdown else { return }
        }

        // 近邻：把显示缓存预热到与查看器完全相同的键；命中即跳过（不重复解码）。
        for item in nearMisses {
            guard !Task.isCancelled, !isShutdown else { return }
            guard await warmViewerPreview(path: item.path) else { return }
        }
        guard !Task.isCancelled, !isShutdown else { return }

        // 远邻：GUI 不解码这一档（避免与显示档位抢解码闸门），投机预热交给宿主
        // （OS 页缓存 / ImageIO 预热）；同一页内同路径只发一次。
        var farPaths: [String] = []
        for item in farMisses {
            guard !hostPreloadedPaths.contains(preloadHostKey(item.path)) else { continue }
            hostPreloadedPaths.insert(preloadHostKey(item.path))
            farPaths.append(item.path)
        }
        if !farPaths.isEmpty {
            await preloadHostPreviews(paths: farPaths)
        }
    }

    // MARK: - 通道实现

    /// 与查看器同键的显示缓存命中判定（size = baseDimension、preview = true）。
    ///
    /// Wave4b / P2-5：内存未命中时还要查**磁盘缓存**——GUI 显示路径本来就会命中
    /// ThumbnailDiskCache（PhotoThumbnailView.load），只查内存会把"上次已解好落盘"
    /// 的图判成 miss：近邻白排一次 decodeAsync（虽然会命中磁盘），远邻还会让宿主
    /// 整解 RAW 一遍。
    func isViewerPreviewCached(path: String) -> Bool {
        Self.isViewerPreviewCached(
            path: path,
            memoryHit: { key in PhotoThumbnailCache.image(for: key) != nil },
            diskHit: { path, size, preview in
                ThumbnailDiskCache.data(path: path, size: size, preview: preview) != nil
            })
    }

    /// 在**主线程外**计算近邻/远邻/下一张的缓存未命中集合（perf-ui task-17）。
    ///
    /// 旧实现在 MainActor 上逐条 `isViewerPreviewCached`：磁盘探针会 stat + 读整张
    /// 预览 JPEG（baseDimension 2560，可达数 MB）并 touch mtime，一次翻片最多 5 条
    /// ⇒ 主线程同步 I/O。内存 NSCache 与 ThumbnailDiskCache 都自带锁，可安全在
    /// 后台查询；查询结果只用于"要不要预热"，跳过与否不影响正确性。
    nonisolated static func computePreloadMisses(
        near: [CullingPreloadCandidate],
        far: [CullingPreloadCandidate],
        next: CullingPreloadCandidate?
    ) async -> (nearMisses: [CullingPreloadCandidate], farMisses: [CullingPreloadCandidate], nextIsMiss: Bool) {
        await Task.detached(priority: .utility) {
            func cached(_ path: String) -> Bool {
                Self.isViewerPreviewCached(
                    path: path,
                    memoryHit: { key in PhotoThumbnailCache.image(for: key) != nil },
                    diskHit: { p, s, preview in
                        ThumbnailDiskCache.data(path: p, size: s, preview: preview) != nil
                    })
            }
            return (
                near.filter { !cached($0.path) },
                far.filter { !cached($0.path) },
                next.map { !cached($0.path) } ?? false
            )
        }.value
    }

    /// 命中判定的纯形式（注入内存/磁盘探针）：内存命中直接 true；否则还必须查
    /// 磁盘缓存——GUI 显示路径本来就会先命中 ThumbnailDiskCache，只查内存会把
    /// "上次已解好落盘"的图判成 miss（Wave4b / P2-5）。
    nonisolated static func isViewerPreviewCached(
        path: String,
        memoryHit: (String) -> Bool,
        diskHit: (String, Int, Bool) -> Bool
    ) -> Bool {
        let key = PhotoThumbnailCache.key(
            path: path,
            size: preloadPreviewDimension,
            preview: true)
        if memoryHit(key) { return true }
        return diskHit(path, preloadPreviewDimension, true)
    }

    /// 把一张近邻解码进查看器显示缓存。返回 false = 任务被取消/已关闭（调用方退出）。
    private func warmViewerPreview(path: String) async -> Bool {
        do {
            let data = try await PhotoThumbnailDecoder.decodeAsync(
                path: path,
                size: Self.preloadPreviewDimension,
                preview: true
            )
            guard !Task.isCancelled, !isShutdown else { return false }
            let key = PhotoThumbnailCache.key(
                path: path,
                size: Self.preloadPreviewDimension,
                preview: true
            )
            // 解码期间查看器可能已经自己解完并写进缓存：有值就不再覆盖。
            if PhotoThumbnailCache.image(for: key) == nil, let image = NSImage(data: data) {
                PhotoThumbnailCache.setImage(image, for: key)
            }
        } catch {
            // 单张失败不阻断其余邻张：文件缺失/格式不支持由查看器自己显示失败态。
            GatherLogger.log("culling preload skipped \(path): \(error)", level: .debug)
        }
        return true
    }

    /// 宿主侧预览预热（既有 IPC 命令 image.preload_previews；不落 GUI 缓存）。
    ///
    /// Wave4b / P2-4：只解 preloadHostWarmDimension（1024），不再与近邻显示档
    /// 重复整解 2560；同一文件在 GUI 侧真正需要的显示档由近邻预热负责。
    private func preloadHostPreviews(paths: [String]) async {
        guard let photoAPI else { return }
        do {
            let input = try PreviewPreloadInput(
                paths: paths,
                maxDimension: Self.preloadHostWarmDimension
            )
            try await photoAPI.preloadPreviews(input)
        } catch {
            GatherLogger.log("culling preload_previews failed: \(error)", level: .debug)
        }
    }

    /// 宿主侧缩略图优先级信号（既有 IPC 命令 image.prioritize_thumbnail）。
    private func prioritizeThumbnail(path: String) async {
        guard let photoAPI else { return }
        do {
            let input = try ThumbnailPrioritizeInput(
                path: path,
                size: Self.preloadPriorityThumbnailSize
            )
            try await photoAPI.prioritizeThumbnail(input)
        } catch {
            GatherLogger.log("culling prioritize_thumbnail failed: \(error)", level: .debug)
        }
    }

    private func preloadHostKey(_ path: String) -> String { "preview:\(path)" }
    private func preloadThumbnailKey(_ path: String) -> String { "thumb:\(path)" }
    private func isCancelledPreload() -> Bool {
        preloadTask?.isCancelled ?? false
    }
}
