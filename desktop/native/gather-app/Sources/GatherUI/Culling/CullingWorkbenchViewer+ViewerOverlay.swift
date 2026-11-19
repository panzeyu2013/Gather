// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer+ViewerOverlay.swift
// M13（Wave5 / task-9）：CullingWorkbenchViewer 的扩展——叠加层 / 预览分析 / 参考槽
//（对比网格渲染见 +ViewerGrid.swift）。
//
// 纯搬移：成员实现逐行未改；仅去掉 private 以便跨文件（同 target）访问，逐条见报告。
import SwiftUI
import GatherProtocol

extension CullingWorkbenchViewer {
    /// 本次键盘决策是否只写当前照片（B1）。
    ///
    /// 解析规则见 CullingDecisionScope.target：对比类布局默认只写当前照片，
    /// 只有用户显式打开「作用于全部选中 N 张」才退回批量分支（与网格/检查器一致）。
    var decisionCurrentOnly: Bool {
        switch CullingDecisionScope.target(
            isComparisonLayout: CullingDecisionScope.isComparisonLayout(
                compareCount: compareCount, isSurvey: isSurvey),
            // 用 currentAsset（= commit 实际会写的那张）：currentPhotoId 若已失效，
            // currentAsset 会回退到页首，回显与写入必须同一口径。
            currentPhotoId: viewModel.currentAsset?.photo.id,
            selectedPhotoIds: viewModel.selectedPhotoIds,
            writesToSelection: writesDecisionToSelection
        ) {
        case .current:
            return true
        case .selection, nil:
            return false
        }
    }

    /// 提交一拍决策：在按键落下时就冻结「是否只写当前照片」（加载期间的排队拍
    /// 会原样重放这个收窄，不在 flush 时重新解析）。
    func commitDecision(_ patch: CullingUpdatePatch, shouldAdvance: Bool = true) {
        let currentOnly = decisionCurrentOnly
        Task {
            await viewModel.commit(
                patch: patch, shouldAdvance: shouldAdvance, currentOnly: currentOnly)
        }
    }

    /// 单/2/3/4 图：显式选中的对应张数优先，否则当前照片 ± 相邻（避免第 100 张
    /// 对比列表第 1 张）。Survey（#6）：张数由选择集决定，选片规则见
    /// CullingComparison.surveyAssets（选择不足 2 张时回退当前 + 邻接补足）。
    func comparisonAssets() -> [CullingAsset] {
        if isSurvey {
            return CullingComparison.surveyAssets(
                current: currentAsset,
                assets: assets,
                selectedIds: viewModel.selectedPhotoIds,
                limit: compareCount)
        }
        return CullingComparison.assets(
            current: currentAsset,
            assets: assets,
            selectedIds: viewModel.selectedPhotoIds,
            compareCount: compareCount)
    }

    /// 来源标签（对齐 TS sourceLabel：template/face-keyword/similarity/AI/导入/人工）。
    func sourceLabel(_ asset: CullingAsset) -> String {
        switch asset.metadataSource {
        case .template: return l10n("模板元数据")
        case .faceKeyword: return l10n("人脸关键词")
        case .similarity: return l10n("相似组关键词")
        case .manual, .culling: break
        case .none: break
        }
        if asset.quality?.status == .succeeded { return l10n("AI 技术分析") }
        // source=.imported 同时是「没有决策行」的哨兵值：只有真正落过决策（revision>0）
        // 的 imported 才是客户校样回传，否则仍是「人工调整」。
        if asset.state.source == .imported {
            return asset.state.revision > 0 ? l10n("客户选择") : l10n("导入元数据")
        }
        return l10n("人工调整")
    }

    /// 徽标正文（告警标记由 ViewerBadge.showsWarning 单独渲染，避免拼接）。
    func qualityBadgeText(_ quality: CullingQuality) -> String {
        if quality.status == .failed { return l10n("分析失败") }
        return l10n.format("质量 %lld", Int(quality.score * 100))
    }

    func qualityHelpText(_ quality: CullingQuality) -> String {
        if quality.status == .failed {
            // 上屏走错误码漏斗（原始诊断已由 logQualityFailures 写日志），
            // 不把分析器的结构化描述直接铺在 tooltip 里。
            guard let raw = quality.errorMessage, !raw.isEmpty else {
                return l10n("质量分析失败")
            }
            return CullingViewModel.funnelErrorText(raw, with: l10n)
        }
        let sharpness = Int((quality.subjectSharpness ?? quality.sharpness) * 100)
        let exposure = Int(quality.exposure * 100)
        return l10n.format("AI 技术分析：清晰度 %lld%%，曝光 %lld%%", sharpness, exposure)
    }

    /// 缩放/平移/尺寸变化后重算**所有会显示贴片的格**的可见区域细节层
    /// （逐格 150ms 去抖：拖动过程不排重解码队列）。Wave2（#3）：不再只算当前格。
    func scheduleDetailTileUpdateForVisibleCells() {
        let visible = comparisonAssets()
        let count = max(1, visible.count)
        for asset in visible {
            let isCurrent = asset.photo.id == currentAsset?.photo.id
            let isHovered = asset.photo.id == hoveredCellId
            guard CullingDetailTilePolicy.showsTile(
                compareCount: count,
                isCurrent: isCurrent,
                isHovered: isHovered
            ) else { continue }
            scheduleDetailTileUpdate(for: asset.photo.id)
        }
    }

    /// 为某一格重算细节贴片。几何用**该格自己的**单元格尺寸与该照片宽高；
    /// 缩放/平移仍是全屏共享的一套（同步缩放语义不变）。
    func scheduleDetailTileUpdate(for photoId: String) {
        guard let size = cellSizes[photoId],
              size.width > 0, size.height > 0,
              let asset = viewModel.pageAsset(forPhotoId: photoId) else { return }
        let imageSize = CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
        let zoom = effectiveZoom
        let align = faceAlign ? alignOffset(for: asset, imageSize: imageSize, cellSize: size) : .zero
        let pan = CGSize(width: offset.width + align.width, height: offset.height + align.height)
        detailTileTasks[photoId]?.cancel()
        detailTileTasks[photoId] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let tile = PhotoViewerGeometry.detailTile(
                imageSize: imageSize,
                viewSize: size,
                zoom: Double(zoom),
                panOffset: pan,
                backingPixelBudget: detailBaseSize
            )
            // 缩回 1× 或细节层不再需要时清掉（避免留下过期贴片）。
            detailTiles[photoId] = tile
        }
    }

    /// 清掉所有在途/已落地的贴片（切图、切布局、离开查看器时调用）。
    func clearDetailTiles() {
        for task in detailTileTasks.values { task.cancel() }
        detailTileTasks.removeAll(keepingCapacity: true)
        detailTiles.removeAll(keepingCapacity: true)
    }

    /// 当前渲染用的缩放级（人脸对齐时会把倍率抬到至少 2×）。
    var effectiveZoom: Double {
        faceAlign ? max(2, scale) : scale
    }

    /// 某一格的人脸对齐位移（与 cellView 内计算的是同一个模型）。
    func alignOffset(for asset: CullingAsset, imageSize: CGSize, cellSize: CGSize) -> CGSize {
        guard faceAlign, let face = asset.faceBboxes.first else { return .zero }
        return FaceAlign.offset(
            imageSize: imageSize,
            cellSize: cellSize,
            face: face,
            zoom: max(2, scale)
        )
    }

    /// 适配显示尺寸的最长边（pt）——与 contentMode .fit 的几何一致。
    /// 用于「区域解码不可用」时的整图高档位兜底（见 cellView 的 onUnavailable）。
    /// .fit 图像在缩放/平移后的显示矩形（归一化叠加层映射的唯一几何源）。
    static func displayedImageRect(
        imageSize: CGSize, cellSize: CGSize, zoom: CGFloat, offset: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              cellSize.width > 0, cellSize.height > 0 else { return .zero }
        let fitScale = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
        let width = imageSize.width * fitScale * zoom
        let height = imageSize.height * fitScale * zoom
        return CGRect(
            x: cellSize.width / 2 - width / 2 + offset.width,
            y: cellSize.height / 2 - height / 2 + offset.height,
            width: width, height: height)
    }

    // （原「整图渐进档位」的调度已由可见区域细节层取代；整图高档位仅在区域解码
    //   不可用时作为兜底，见 cellView 的 onUnavailable 回调。）

    // MARK: - §3.9 叠加层：状态与调度

    /// 预览分析的触发键：照片或开关一变就重算（.task(id:) 自动取消上一次）。
    var analysisKey: String {
        "\(viewModel.currentPhotoId ?? "-")|\(overlayState.histogramVisible)|\(overlayState.focusMaskVisible)"
    }

    /// 重算直方图/合焦掩膜/AF 点。
    ///
    /// 像素来源：查看器自己已经显示的那张预览（PhotoThumbnailCache 里的 NSImage）。
    /// 缓存未命中时最多等 6×150ms（图片解码是异步的），仍没有就保持空态——
    /// 不为叠加层单独解码一张图（§3.9 开头"不新增解码"）。
    func refreshPreviewAnalysis() async {
        guard overlayState.histogramVisible || overlayState.focusMaskVisible else {
            histogram = nil
            focusMask = nil
            return
        }
        guard let asset = currentAsset else {
            histogram = nil
            focusMask = nil
            return
        }
        guard let port = PreviewAnalysisRegistry.current() else {
            // 宿主未注册分析端口：保持空态（叠加层自己会画"无数据"提示）。
            histogram = nil
            focusMask = nil
            return
        }
        // 先清空上一张的叠加数据，避免取消/取不到预览时继续显示旧照片的直方图与合焦图。
        histogram = nil
        focusMask = nil
        guard let image = await waitForPreviewImage(path: asset.photo.filepath) else { return }
        guard !Task.isCancelled, viewModel.currentPhotoId == asset.photo.id else { return }
        // 栅格化在主线程完成（NSImage 非 Sendable）；只有纯像素计算下放到后台。
        let rasterized = PreviewPixelRasterizer.rgbaPixels(
            from: image,
            maxDimension: Self.analysisSampleDimension
        )
        guard let pixels = rasterized, pixels.isWellFormed else { return }
        let wantsHistogram = overlayState.histogramVisible
        let wantsFocus = overlayState.focusMaskVisible
        let computed = await Task.detached(priority: .utility) {
            () -> (PreviewHistogram?, FocusMask?) in
            let histogramValue = wantsHistogram
                ? port.histogram(pixels, bins: PreviewHistogram.defaultBins)
                : nil
            let mask = wantsFocus
                ? port.focusMask(pixels, parameters: FocusMaskParameters())
                : nil
            return (histogramValue, mask)
        }.value
        guard !Task.isCancelled else { return }
        histogram = computed.0
        focusMask = computed.1
    }

    /// 分析用像素的长边上限（§3.9.2：1280）。与 PhotoDetailTier 无关，只用于降采样。
    static let analysisSampleDimension = 1280

    /// 等查看器自己的预览进入内存缓存（不触发第二次解码）。
    func waitForPreviewImage(path: String) async -> NSImage? {
        guard !path.isEmpty else { return nil }
        let candidateSizes = [PhotoDetailTier.baseDimension, 2048, 1280, 1024, 512]
        for attempt in 0..<6 {
            for size in candidateSizes {
                let key = PhotoThumbnailCache.key(path: path, size: size, preview: true)
                if let image = PhotoThumbnailCache.image(for: key) { return image }
            }
            if attempt == 5 { break }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return nil
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// 裁剪标记的数据源：CullingAPI.adjustmentHint 读 sidecar 的 crs:Crop*。
    /// 无 sidecar/无裁剪 → nil（不画），绘制路径本身不变。
    var currentCrop: CropFrame? { cropFrame }

    /// AF 点：camera_model 已透传；AF 索引仍无 ExifAux/MakerNote 数据源，
    /// 机型表为空时只走"人脸中心"回退——设计里明确的降级路径，不伪造相机 AF。
    func currentAFPoint() -> AFPoint? {
        guard let port = PreviewAnalysisRegistry.current(), let asset = currentAsset else {
            return nil
        }
        let camera = asset.photo.metadata["camera_model"]?.stringValue ?? ""
        return port.afPoint(faceBoxes: asset.faceBboxes, cameraModel: camera, afIndex: nil)
    }

    // MARK: 开关方法（供工具栏与后续键位表调用；本文件不硬编码裸键）

    /// 直方图开关（键位表将来分配 H）。
    func toggleHistogram() {
        overlayState.toggleHistogram()
    }

    /// 合焦提示开关（键位表将来分配 F）。
    func toggleFocusMask() {
        overlayState.toggleFocusMask()
    }

    /// 裁剪标记开关（键位表将来分配 C/O 之外的位置；O 是"显示全图"）。
    func toggleCropFrame() {
        overlayState.toggleCropFrame()
    }

    /// "显示全图"（临时去掉裁剪蒙版）。
    func toggleFullFrame() {
        overlayState.toggleFullFrame()
    }

    /// 把当前照片设为参考 / 取消参考（R）。
    func toggleReference() {
        guard let asset = currentAsset else { return }
        overlayState.toggleReference(
            photoId: asset.photo.id,
            filepath: asset.photo.filepath,
            filename: asset.photo.filename
        )
        // B3：参考槽变化回写会话状态（清空时写 nil；0.5s 节流后落盘）。
        viewModel.recordViewerReference(
            photoId: overlayState.referencePhotoId,
            filepath: overlayState.referenceFilepath,
            filename: overlayState.referenceFilename)
    }

    /// B3：把会话存档里的参考槽套到当前叠加层状态（已有参考时不覆盖）。
    ///
    /// 存档由页面 .task 异步注入（可能晚于查看器 onAppear），因此同时挂在
    /// onAppear 与 viewerReference 的 onChange 上；两条路径都幂等。
    func restoreViewerReferenceIfNeeded() {
        guard !overlayState.hasReference,
              let reference = viewModel.viewerReference,
              !reference.photoId.isEmpty,
              !reference.filepath.isEmpty else { return }
        overlayState.referencePhotoId = reference.photoId
        overlayState.referenceFilepath = reference.filepath
        overlayState.referenceFilename = reference.filename
    }

    /// 参考对比模式循环（C：并排 → 分割 → 叠加）。
    func cycleReferenceMode() {
        overlayState.cycleReferenceMode()
    }

    /// 交换主/参考（\）。
    func swapReference() {
        overlayState.swapReference()
    }

}
