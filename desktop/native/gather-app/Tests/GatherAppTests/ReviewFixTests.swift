// desktop/native/gather-app/Tests/GatherAppTests/ReviewFixTests.swift
// 本轮 UI 审查修复的回归测试（F05 / F07 / F08 / F13）：
//   · F08 同步状态阶梯：written > 0 时不得说「全部同步」（与 C1 胶囊同口径）；
//   · F07 当前任务分层：活跃 / 需处理 / 已完成历史不得混在一个列表里；
//   · F05 人脸裁切换算：bbox 必须落在裁切框中心，非法 bbox 回退整图；
//   · F13 人脸簇计数单位：size 是人脸样本数，不是照片数。
import Foundation
import Testing
import AppKit
import SwiftUI
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

/// Cut 4 / 4a-2a-2：`SessionControlView(workspace:)` 的生产装配需要完整
/// SessionWorkspace；本文件只关心 control VM，其余 6 个 VM 用空桩。
private struct ReviewGalleryProviderStub: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}

@MainActor
@Suite("review fixes")
struct ReviewFixTests {

    // MARK: F08 同步状态阶梯

    private func sync(
        pending: Int = 0,
        writing: Int = 0,
        written: Int = 0,
        failed: Int = 0,
        conflict: Int = 0,
        synced: Int = 0
    ) -> MetadataSyncSummary {
        MetadataSyncSummary(
            sessionId: "s1",
            pending: pending,
            writing: writing,
            written: written,
            failed: failed,
            conflict: conflict,
            synced: synced,
            items: []
        )
    }

    /// Cut 4 / 4a-2a-2：页面 VM 从 workspace 取（生产形状）；本文件只用到
    /// control VM，其余 6 个 VM 用类型化空桩。
    private func controlWorkspace() -> SessionWorkspace {
        SessionWorkspace(
            sessionId: "s1",
            culling: CullingViewModel(
                sessionId: "s1",
                culling: B8CullingAPIStub(),
                navigation: B8NavigationAPIStub(),
                metadata: B6bMetadataAPIStub(),
                jobs: B5bJobAPIStub(),
                quality: B5bQualityAPIStub(),
                captureOne: CaptureOneBridge()
            ),
            duplicates: DuplicatesViewModel(
                sessionId: "s1",
                duplicate: B5bDuplicateAPIStub(),
                jobs: B5bJobAPIStub()
            ),
            export: ExportViewModel(
                sessionId: "s1",
                export: B6bExportAPIStub(),
                session: B8SessionAPIStub()
            ),
            face: FaceKeywordingViewModel(
                sessionId: "s1",
                face: B8FaceAPIStub(),
                jobs: B5bJobAPIStub(),
                captureOne: CaptureOneBridge()
            ),
            control: SessionControlViewModel(
                sessionId: "s1",
                session: B8SessionAPIStub(),
                culling: B8CullingAPIStub(),
                jobAPI: B5bJobAPIStub(),
                qualityAPI: B5bQualityAPIStub()
            ),
            gallery: GalleryViewModel(
                sessionId: "s1",
                provider: ReviewGalleryProviderStub(),
                job: B5bJobAPIStub()
            ),
            similarity: SimilarityViewModel(
                sessionId: "s1",
                similarity: B8SimilarityAPIStub(),
                jobs: B5bJobAPIStub(),
                pollInterval: .seconds(3600),
                captureOne: CaptureOneBridge()
            )
        )
    }

    /// Cut 4 / 4b-2f：状态句由**显式传入**的 L10n 解析（裸 View 无 languageStore
    /// env，不读进程全局语言）；语言可参数化以便同一条阶梯在 zh/en 下都验到。
    private func statusText(
        _ summary: MetadataSyncSummary,
        language: L10n.Language = .zhCN
    ) -> String {
        SessionControlView(
            workspace: controlWorkspace(),
            culling: B8CullingAPIStub()
        )
        .syncStatusText(summary, with: L10n(language: language))
    }

    @Test("F08：已写入待 C1 读取时不再宣称「全部同步」")
    func writtenWaitsForCaptureOne() {
        let text = statusText(sync(written: 1))
        #expect(text.contains("已写入"))
        #expect(text.contains("等待"))
        #expect(!text.contains("已同步"))
    }

    @Test("F08：全部确认才说已同步")
    func syncedOnlyWhenConfirmed() {
        #expect(statusText(sync(synced: 3)).contains("已同步"))
    }

    @Test("F08：冲突/失败优先于其他状态")
    func conflictAndFailureTakePriority() {
        #expect(statusText(sync(written: 2, conflict: 1)).contains("冲突"))
        #expect(statusText(sync(pending: 2, failed: 1)).contains("失败"))
    }

    @Test("F08：待写入与写入中是两个不同阶段")
    func pendingAndWritingAreDistinct() {
        #expect(statusText(sync(pending: 2)).contains("待写入"))
        #expect(statusText(sync(writing: 2)).contains("正在写入"))
    }

    @Test("F08：没有任何待同步项时不谎报同步完成")
    func emptyQueueIsHonest() {
        #expect(!statusText(sync()).contains("全部同步"))
    }

    // 4b-2f：同一个阶梯在 en 下逐条出英文——语言来自显式 L10n，
    // 而不是 .zhCN 兜底（否则这里会读到中文并变红）。
    @Test("显式 L10n：en 状态阶梯")
    func englishSyncStatusText() {
        #expect(statusText(sync(conflict: 1), language: .en) == "XMP conflicts exist; resolve them first")
        #expect(statusText(sync(failed: 1), language: .en) == "Some writes failed; retry them first")
        #expect(statusText(sync(pending: 2), language: .en)
            == "2 items pending: Gather has not written XMP yet")
        #expect(statusText(sync(writing: 1), language: .en) == "Gather is writing XMP…")
        #expect(statusText(sync(written: 1), language: .en)
            == "Written, awaiting read: waiting for Capture One to read the metadata")
        #expect(statusText(sync(synced: 1), language: .en) == "Synced: Capture One has read the metadata")
        #expect(statusText(sync(), language: .en) == "Nothing to sync")
    }

    // MARK: F07 当前任务分层

    /// 控制中心 load() 会先取 session.get / workspace.status（任一失败就整段跳过，
    /// 包括 jobs.list），因此桩必须三件都可用。
    /// B8.1b：session/workspace 用类型化夹具替身；任务列表走 JobAPI 的 typed 夹具
    ///（不再按命令名塞 JSONValue 行）。
    private func controlViewModel(_ jobs: [(String, AnalysisJobStatus)]) async throws -> SessionControlViewModel {
        let session = SessionData(
            id: "s1",
            name: "Workspace",
            status: .photosLoaded,
            photoCount: jobs.count,
            analysisStatus: .idle,
            writebackStatus: .idle,
            importSource: "local",
            sourcePath: "/shoot",
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        let workspace = WorkspaceStatus(
            sessionId: "s1",
            stage: .analyzed,
            softFlags: WorkspaceSoftFlags(culled: false, exported: false),
            indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .idle),
            staleAnalyses: [],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0,
            failedJobs: [],
            recommendedNext: nil,
            generatedAt: ""
        )
        // B8.2a：session.get / workspace.status / culling.sync_status 全部走类型化
        // API（SessionAPI + CullingAPI）；任务列表走 JobAPI（B5b）。
        let sessionAPI = B8SessionAPIStub(session: session, status: workspace)
        let jobAPI = B5bJobAPIStub()
        jobAPI.jobs = jobs.map { b5bJobData(id: $0.0, status: $0.1) }
        let viewModel = SessionControlViewModel(
            sessionId: "s1",
            session: sessionAPI,
            culling: B8CullingAPIStub(),
            jobAPI: jobAPI,
            qualityAPI: B5bQualityAPIStub()
        )
        await viewModel.load()
        // 任务快照是异步刷新（load() 内起 Task），等它落定再断言。
        #expect(
            await waitUntilAsync { viewModel.jobs.count == jobs.count },
            "任务快照未在超时内落定（期望 \(jobs.count) 条，实际 \(viewModel.jobs.count) 条）"
        )
        return viewModel
    }

    @Test("F07：当前任务只列活跃与失败，历史单独折叠")
    func jobSplitKeepsHistoryOutOfCurrentTasks() async throws {
        let viewModel = try await controlViewModel([
            ("a", .running),
            ("b", .failed),
            ("c", .succeeded),
            ("d", .cancelled),
            ("e", .interrupted),
            ("f", .queued),
        ])
        #expect(viewModel.activeJobs.map(\.id) == ["a", "f"])
        #expect(viewModel.attentionJobs.map(\.id) == ["b", "e"])
        #expect(viewModel.historyJobs.map(\.id) == ["c", "d"])
    }

    @Test("F07：只有历史任务时当前任务区为空")
    func onlyHistoryMeansNoCurrentTasks() async throws {
        let viewModel = try await controlViewModel([("c", .succeeded), ("d", .cancelled)])
        #expect(viewModel.activeJobs.isEmpty)
        #expect(viewModel.attentionJobs.isEmpty)
        #expect(viewModel.historyJobs.count == 2)
    }

    // MARK: F05 人脸裁切换算

    /// 图像在 ZStack 中是**居中**布局：左上角不在 frame 原点。N02 的错因就是把
    /// 「左上角重合」的平移公式用在了居中布局上。这里按真实布局模型复算渲染位置
    /// （真实像素断言见本文件后半的 ImageRenderer 测试）。
    private func renderedCenter(
        _ layout: (displayed: CGSize, offset: CGSize),
        bbox: [Double],
        frame: CGSize
    ) -> CGPoint {
        let topLeading = CGPoint(
            x: (frame.width - layout.displayed.width) / 2,
            y: (frame.height - layout.displayed.height) / 2
        )
        return CGPoint(
            x: topLeading.x + (bbox[0] + bbox[2] / 2) * layout.displayed.width + layout.offset.width,
            y: topLeading.y + (bbox[1] + bbox[3] / 2) * layout.displayed.height + layout.offset.height
        )
    }

    /// 说明（G 报告）：这里原有一条「复述居中公式」的纯换算测试，属于
    /// B 类测试——它把实现里的公式抄进断言，实现换成左上角原点它仍然通过。
    /// 已删除，覆盖工作改由下面的**位图断言**承担（布局模型的改变必然改变像素）。
    ///
    /// 保留一条纯数值不变量：cover 语义下裁切区域必须覆盖整个 frame。
    @Test("F05/N02：cover 语义——裁切区域覆盖整个 frame")
    func faceCropCoversFrame() {
        let layout = FaceCropThumbnailView.layout(
            imageSize: CGSize(width: 1000, height: 500),
            bbox: [0.4, 0.2, 0.1, 0.2],
            frame: CGSize(width: 80, height: 80),
            margin: 0.25
        )
        #expect(layout.displayed.width >= 80 - 0.001)
        #expect(layout.displayed.height >= 80 - 0.001)
    }

    @Test("F05：非法 bbox 回退整图且不产生负尺寸")
    func invalidBoundingBoxFallsBackToWholeImage() {
        let imageSize = CGSize(width: 400, height: 200)
        let frame = CGSize(width: 60, height: 60)
        for bbox in [[], [0.5], [0, 0, 0, 0], [Double.nan, 0.1, 0.2, 0.2]] {
            let layout = FaceCropThumbnailView.layout(
                imageSize: imageSize, bbox: bbox, frame: frame, margin: 0.25
            )
            #expect(layout.displayed.width > 0)
            #expect(layout.displayed.height > 0)
            #expect(layout.displayed.width >= frame.width)
            #expect(layout.displayed.height >= frame.height)
            // 回退必须是「整图居中」：偏移为零，任何错误的平移都会在这里失败。
            #expect(layout.offset == .zero, "非法 bbox 必须回退整图（不产生平移）：\(bbox)")
        }
    }

    @Test("F05：零尺寸 frame 不返回 NaN")
    func zeroFrameIsSafe() {
        let layout = FaceCropThumbnailView.layout(
            imageSize: CGSize(width: 100, height: 100),
            bbox: [0.1, 0.1, 0.2, 0.2],
            frame: .zero,
            margin: 0.25
        )
        #expect(layout.displayed == .zero)
        #expect(layout.offset == .zero)
    }

    // MARK: F05/N02 真实渲染像素验证（不再复述换算公式）

    /// 400×200 蓝底 + 目标人脸区域（归一化左上原点 x 0.45–0.55、y 0.2–0.3）红块。
    /// CGContext 原点在左下，因此红块像素 y 取 140–160（= 1 − 0.3 … 1 − 0.2）。
    private func makeFaceFixtureImage() -> NSImage {
        let width = 400
        let height = 200
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("无法创建测试位图上下文")
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 180, y: 140, width: 40, height: 20))
        guard let cgImage = context.makeImage() else {
            fatalError("无法生成测试位图")
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    @Test("F05/N02：裁切后脸必须落在视图中心（真实渲染像素）")
    func faceCropPutsBoundingBoxAtCenterInRenderedPixels() throws {
        let source = makeFaceFixtureImage()
        let view = FaceCropThumbnailView(previewImage: source, bbox: [0.45, 0.2, 0.1, 0.1])
            .frame(width: 100, height: 100)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: rendered)
        #expect(rep.pixelsWide == 100)
        #expect(rep.pixelsHigh == 100)

        let center = try #require(rep.colorAt(x: 50, y: 50))
        #expect(center.redComponent > 0.7, "视图中心必须是脸（红块），实际 \(center)")
        #expect(center.blueComponent < 0.3)

        // 上下边缘应是图像背景（蓝）：既证明裁切**落在图像内部**（否则会是占位底色），
        // 也证明可见窗口比人脸框略大（不是把整张图糊上去）。
        for point in [(5, 5), (5, 94), (94, 5), (94, 94)] {
            let corner = try #require(rep.colorAt(x: point.0, y: point.1))
            #expect(corner.blueComponent > 0.7, "角落 \(point) 应是图像背景，实际 \(corner)")
        }
    }

    @Test("F05/N02：margin=0 时中心仍被对齐到人脸")
    func faceCropAlignsTightBoundingBox() throws {
        let source = makeFaceFixtureImage()
        let view = FaceCropThumbnailView(previewImage: source, bbox: [0.45, 0.2, 0.1, 0.1], margin: 0)
            .frame(width: 60, height: 60)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: rendered)
        let center = try #require(rep.colorAt(x: 30, y: 30))
        #expect(center.redComponent > 0.7, "margin=0 时中心仍应是人脸，实际 \(center)")
    }

    @Test("F05/N02：代表图蒙太奇按给定宽度渲染为正方形（不再塌成色条）")
    func montageRendersAsSquare() throws {
        let cluster = cluster(size: 2, members: [member(1, "/a/1.NEF"), member(2, "/a/2.NEF")])
        let renderer = ImageRenderer(content: FaceClusterMontage(cluster: cluster))
        renderer.proposedSize = ProposedViewSize(width: 200, height: nil)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        #expect(abs(image.size.width - 200) < 1, "宽度应跟随提案，实际 \(image.size)")
        #expect(image.size.height >= 180, "高度必须接近正方形（塌陷时只有十几点），实际 \(image.size)")
    }

    // MARK: N03 导出计划指纹

    @Test("N03：变体/格式/目录/命名变化都会让旧计划过期")
    func planSignatureCoversPlanAffectingOptions() {
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: B6bExportAPIStub(),
            session: B8SessionAPIStub()
        )
        // 还没有任何计划 → 视为过期（不允许显示张数）。
        #expect(viewModel.isPlanStale)
        let initial = viewModel.planSignature

        viewModel.variantPolicy = .jpeg
        #expect(viewModel.planSignature != initial, "变体必须进入计划指纹")
        let afterVariant = viewModel.planSignature

        viewModel.format = .jpeg
        #expect(viewModel.planSignature != afterVariant, "格式必须进入计划指纹")
        let afterFormat = viewModel.planSignature

        viewModel.destination = "/tmp/gather-plan"
        #expect(viewModel.planSignature != afterFormat, "目录必须进入计划指纹")
        let afterDestination = viewModel.planSignature

        viewModel.namingPattern = "{counter}"
        #expect(viewModel.planSignature != afterDestination, "命名必须进入计划指纹")
    }

    // MARK: N05 导出入口意图

    @Test("N05：挑片成果入口把范围设为保留片")
    func picksIntentSelectsKeepOnlyScope() {
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: B6bExportAPIStub(),
            session: B8SessionAPIStub()
        )
        #expect(viewModel.scope == .session)
        viewModel.applyRangeIntent(.picks)
        #expect(viewModel.scope == .filtered)
    }

    @Test("N05/V2：通用入口（nil / allPhotos）不覆盖用户已选的范围")
    func generalEntryKeepsUserChoice() {
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: B6bExportAPIStub(),
            session: B8SessionAPIStub()
        )
        viewModel.applyRangeIntent(.allPhotos)
        #expect(viewModel.scope == .session)
        // 用户手动选保留片后，从页签再次进入（意图 nil）不得回退成全部。
        viewModel.scope = .filtered
        viewModel.applyRangeIntent(nil)
        #expect(viewModel.scope == .filtered)
        // 显式的「去导出」事件仍然生效（意图是事件，不是一次性播种）。
        viewModel.scope = .session
        viewModel.applyRangeIntent(.picks)
        #expect(viewModel.scope == .filtered)
    }

    @Test("B3（9-30 审查）：手动预览也进入同一套计划发布契约（记录 plannedSignature）")
    func manualPreviewPublishesSignature() async {
        let export = B6bExportAPIStub()
        export.previewResult = ExportPreview(
            totalFiles: 2,
            totalSizeBytes: 2_048,
            freeSpaceBytes: 10_000,
            files: [
                ExportPreviewFile(photoId: "p1", filename: "a.jpg", fileSize: 1_024),
                ExportPreviewFile(photoId: "p2", filename: "b.jpg", fileSize: 1_024),
            ]
        )
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: export,
            session: B8SessionAPIStub()
        )
        viewModel.destination = "/tmp/gather-b3-dest"
        viewModel.includeXmp = false
        let signature = viewModel.planSignature
        #expect(viewModel.plannedSignature == nil)
        await viewModel.previewExport()
        // 旧实现只写 preview/notice，不写 plannedSignature，也不做请求序号校验——
        // 慢的手动预览可以覆盖更新的自动预览而 isPlanStale 仍认为计划有效。
        #expect(export.previewInputs.count == 1)
        #expect(viewModel.preview?.totalFiles == 2)
        #expect(viewModel.plannedSignature == signature, "手动预览必须登记它对应的参数指纹")
        #expect(viewModel.plannedSignature != "stale-from-other-request")
    }

    // MARK: N07 导航记忆与照片跳转

    @Test("N07：离开工作区后侧栏仍保留当前会话入口（lastSessionId 归 SessionStore）")
    func sidebarKeepsLastSession() {
        let store = SessionStore(capacity: 4) { makeTestSessionWorkspace(sessionId: $0) }
        store.activate("s1")
        #expect(store.lastSessionId == "s1")
        // 回到全局页面：只 suspend，最近会话入口保留。
        store.activate(nil)
        #expect(store.activeSessionId == nil)
        #expect(store.lastSessionId == "s1", "最近工作区入口必须保留")
        // 再进另一个工作区才替换最近项。
        store.activate("s2")
        #expect(store.lastSessionId == "s2")
    }

    @Test("N07：图库照片意图 take 取出即清（4a-2c 迁 WorkspaceIntent）")
    func galleryCarriesPendingPhoto() {
        let workspace = makeTestSessionWorkspace(sessionId: "s1")
        workspace.enqueue(.galleryPhoto(id: "p9", path: nil))
        #expect(workspace.take(.galleryPhoto) == .galleryPhoto(id: "p9", path: nil))
        #expect(workspace.take(.galleryPhoto) == nil, "意图是一次性事件，取出即清")
        // 未播种时不凭空产生意图。
        #expect(workspace.take(.galleryPhoto) == nil)
    }

    // MARK: F13 人脸簇计数

    private func cluster(size: Int, members: [ClusterMember]) -> FaceClusterData {
        FaceClusterData(
            id: 1,
            sessionId: "s1",
            label: "Person 1",
            size: size,
            status: "ready",
            thumbnailBase64: "",
            binding: nil,
            thumbnailPhotoId: nil,
            members: members
        )
    }

    private func member(_ index: Int, _ path: String) -> ClusterMember {
        ClusterMember(
            memberId: index,
            photoId: "p-\(index)",
            photoPath: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            bbox: [0.1, 0.1, 0.2, 0.2],
            confidence: 0.9
        )
    }

    @Test("F13：同一张照片的两张脸是人脸样本而不是照片数")
    func sampleCountDistinguishesPhotos() {
        // Cut 4 / 4b-2b：计数文案在渲染期按显式 L10n 解析（不再依赖进程全局语言）。
        let text = cluster(size: 2, members: [member(1, "/a/IMG_1.NEF"), member(2, "/a/IMG_1.NEF")])
            .sampleCountText(with: L10n(language: .zhCN))
        #expect(text.contains("2 个人脸样本"))
        #expect(text.contains("1 张照片"))
    }

    @Test("F13：成员被截断时不猜照片数")
    func truncatedMembersDoNotGuessPhotoCount() {
        let value = cluster(size: 9, members: [member(1, "/a/1.NEF"), member(2, "/a/2.NEF")])
        #expect(value.distinctPhotoCount == nil)
        let text = value.sampleCountText(with: L10n(language: .zhCN))
        #expect(text.contains("9 个人脸样本"))
        #expect(!text.contains("张照片"))
    }

    // MARK: B-C1 / B-C2 查看器几何（第三轮审计）

    /// 复算渲染位置：SwiftUI 的 .scaleEffect(zoom).offset(d) 是**先缩放后平移**，
    /// d 处于未缩放的单元格空间 → p′ = center + zoom·(p − center) + d。
    private func renderedFaceCenter(
        cell: CGSize,
        image: CGSize,
        face: [Double],
        zoom: Double,
        offset: CGSize
    ) -> CGPoint {
        let fit = min(cell.width / image.width, cell.height / image.height)
        let displayed = CGSize(width: image.width * fit, height: image.height * fit)
        let p = CGPoint(
            x: (cell.width - displayed.width) / 2 + (face[0] + face[2] / 2) * displayed.width,
            y: (cell.height - displayed.height) / 2 + (face[1] + face[3] / 2) * displayed.height
        )
        return CGPoint(
            x: cell.width / 2 + zoom * (p.x - cell.width / 2) + offset.width,
            y: cell.height / 2 + zoom * (p.y - cell.height / 2) + offset.height
        )
    }

    @Test("B-C1：人脸对齐后 bbox 中心落在单元格中心（竖构图 + letterbox + 各缩放级）")
    func faceAlignCentersBoundingBox() {
        let cell = CGSize(width: 496, height: 600)
        let image = CGSize(width: 2000, height: 3000)
        let face = [0.2, 0.25, 0.1, 0.1]
        for zoom in [2.0, 4.0, 8.0] {
            let offset = FaceAlign.offset(imageSize: image, cellSize: cell, face: face, zoom: zoom)
            let rendered = renderedFaceCenter(cell: cell, image: image, face: face, zoom: zoom, offset: offset)
            // 失败时把实际渲染点打进控制台（#expect 的 message 只接受字面量）。
            if abs(rendered.x - cell.width / 2) >= 0.5 || abs(rendered.y - cell.height / 2) >= 0.5 {
                print("[faceAlign] zoom =", zoom, "rendered =", rendered)
            }
            #expect(abs(rendered.x - cell.width / 2) < 0.5, "人脸对齐后 x 必须落在单元格中心")
            #expect(abs(rendered.y - cell.height / 2) < 0.5, "人脸对齐后 y 必须落在单元格中心")
        }
    }

    @Test("B-C1 变异守卫：旧公式（单元格尺寸、不乘 zoom）无法居中")
    func faceAlignOldFormulaIsNotSufficient() {
        let cell = CGSize(width: 496, height: 600)
        let image = CGSize(width: 2000, height: 3000)
        let face = [0.2, 0.25, 0.1, 0.1]
        let zoom = 2.0
        let old = CGSize(
            width: (0.5 - (face[0] + face[2] / 2)) * cell.width,
            height: (0.5 - (face[1] + face[3] / 2)) * cell.height
        )
        let fixed = FaceAlign.offset(imageSize: image, cellSize: cell, face: face, zoom: zoom)
        #expect(abs(fixed.width - old.width) > 40, "新公式必须明显区别于旧的单元格近似")
        #expect(abs(fixed.height - old.height) > 60)
        let rendered = renderedFaceCenter(cell: cell, image: image, face: face, zoom: zoom, offset: old)
        #expect(abs(rendered.x - cell.width / 2) > 20, "旧位移下不应居中（本测试必须能抓住回归）")
    }

    @Test("B-C1：图像尺寸未知 / 人脸在中心 / 非法输入都不产生错误位移")
    func faceAlignEdgeCases() {
        let cell = CGSize(width: 400, height: 300)
        // bbox 是左上原点：要让人脸**中心**在 (0.5, 0.5)，左上角应为 (0.45, 0.45)。
        #expect(
            FaceAlign.offset(imageSize: .zero, cellSize: cell, face: [0.45, 0.45, 0.1, 0.1], zoom: 2) == .zero,
            "人脸已在中心时位移必须为零"
        )
        let fallback = FaceAlign.offset(imageSize: .zero, cellSize: cell, face: [0, 0, 0.1, 0.1], zoom: 2)
        #expect(fallback.width.isFinite && fallback.height.isFinite)
        #expect(fallback.width > 0 && fallback.height > 0)
        #expect(FaceAlign.offset(imageSize: cell, cellSize: .zero, face: [0, 0, 0.1, 0.1], zoom: 2) == .zero)
        #expect(FaceAlign.offset(imageSize: cell, cellSize: cell, face: [0, 0], zoom: 2) == .zero)
        #expect(FaceAlign.offset(imageSize: cell, cellSize: cell, face: [0, 0, 0.1, 0.1], zoom: 2).width.isFinite)
    }

    @Test("B-C2：连续拖拽的位移必须累积（旧实现会弹回原点）")
    func panOffsetAccumulatesAcrossGestures() {
        var base = CGSize.zero
        var current = PanOffset.apply(start: base, translation: CGSize(width: 50, height: 30))
        #expect(current == CGSize(width: 50, height: 30))
        base = current
        current = PanOffset.apply(start: base, translation: CGSize(width: 50, height: 30))
        #expect(current == CGSize(width: 100, height: 60), "第二次拖拽必须叠加在第一次之上")
        #expect(current != CGSize(width: 50, height: 30), "旧实现（offset = translation）会退化成这个值")
        base = current
        current = PanOffset.apply(start: base, translation: CGSize(width: -100, height: -60))
        #expect(current == .zero)
    }

    // MARK: 第三轮审计：派生状态与草稿（C-#1 / C-#7）

    @Test("C-#7：改阈值后旧扫描结果必须标记为过期")
    func duplicateScanResultGoesStale() async throws {
        let scanResult = DuplicateScanResult(exactGroups: [], visualGroups: [], totalDuplicates: 3)
        let duplicateAPI = B5bDuplicateAPIStub()
        duplicateAPI.scanResult = scanResult
        let viewModel = DuplicatesViewModel(
            sessionId: "s1",
            duplicate: duplicateAPI,
            jobs: B5bJobAPIStub()
        )
        viewModel.threshold = 4
        await viewModel.scan()
        #expect(viewModel.scanResult != nil)
        #expect(viewModel.scannedThreshold == 4)
        #expect(!viewModel.isScanResultStale, "刚扫完不该是过期状态")

        viewModel.threshold = 7
        #expect(viewModel.isScanResultStale, "阈值变更后旧结果必须标记过期（N03 同类）")
        // 预设切换同样走阈值：恢复到扫描时的档位就不再过期。
        viewModel.threshold = 4
        #expect(!viewModel.isScanResultStale)
    }

    @Test("C-#1：load() 重选同一簇不得冲掉未提交的角色名/关键字草稿")
    func faceDraftSurvivesReloadOfSameCluster() {
        // 生产装配（FaceAPI + JobAPI + CaptureOneBridge）：C-#1 只验证草稿不冲掉，
        // 不需要任何数据加载，故用 typed 替身而非 router。
        let viewModel = FaceKeywordingViewModel(
            sessionId: "s1",
            face: B8FaceAPIStub(),
            jobs: B5bJobAPIStub(),
            captureOne: CaptureOneBridge()
        )
        let bound = cluster(size: 2, members: [member(1, "/a/1.NEF"), member(2, "/a/2.NEF")])
        viewModel.select(bound)
        // 用户开始编辑但还没提交。
        viewModel.roleName = "草稿角色"
        viewModel.keywords = "草稿, 关键字"

        // 绑定/移除成员/合并之后都会 load() → 对同一簇再 select 一次。
        viewModel.select(bound)
        #expect(viewModel.roleName == "草稿角色", "同一簇重选不得覆盖未提交草稿")
        #expect(viewModel.keywords == "草稿, 关键字")

        // 真正切换簇时才用服务端值重置。
        let another = FaceClusterData(
            id: 2,
            sessionId: "s1",
            label: "Person 2",
            size: 1,
            status: "ready",
            thumbnailBase64: "",
            binding: nil,
            thumbnailPhotoId: nil,
            members: [member(3, "/a/3.NEF")]
        )
        viewModel.select(another)
        #expect(viewModel.roleName.isEmpty, "换簇必须回到服务端值")
        #expect(viewModel.keywords.isEmpty)
    }

    // MARK: 第三轮审计：返回来源（E-P0）

    @Test("E-P0：会话页返回回到真实来源，而不是一律回图库")
    func backReturnsToRecordedOrigin() {
        let navigation = RootNavigation()

        navigation.selectDashboard()
        navigation.openSession("s1")
        navigation.backFromSession(sessionId: "s1")
        #expect(navigation.isDashboard, "从工作台进入应返回工作台")

        navigation.selectLibrary()
        navigation.openSession("s1")
        navigation.backFromSession(sessionId: "s1")
        #expect(navigation.isLibrary, "从全局图库进入应返回全局图库")

        navigation.selectWeb(.persons)
        navigation.openSessionTab("s1", .culling)
        navigation.backFromSession(sessionId: "s1")
        #expect(navigation.isPersons, "从人脸库深链进入应返回人脸库")

        // 会话内部的页签切换不得覆盖来源（否则来回切页签就会把来源弄丢）。
        navigation.selectDashboard()
        navigation.openSession("s1")
        navigation.openSessionTab("s1", .culling)
        navigation.openSessionTab("s1", .export)
        navigation.backFromSession(sessionId: "s1")
        #expect(navigation.isDashboard, "会话内部切页签不得覆盖来源")
    }


    @Test("问题 8（第三轮审查）：工作台 → 控制中心 → 图库 → 返回，必须回控制中心")
    func galleryBackReturnsToPreviousTabNotDashboard() {
        let navigation = RootNavigation()
        navigation.selectDashboard()
        navigation.openSession("s1")                      // 控制中心
        navigation.openGallery("s1")                      // 图库
        navigation.backFromGallery()
        #expect(
            navigation.isSessionTab(sessionId: "s1", tab: .control),
            "图库返回必须回到进入前的控制中心（旧实现合并成回工作台）"
        )
    }

    @Test("E-P0：图库返回同样回到来源页")
    func galleryBackReturnsToOrigin() {
        let navigation = RootNavigation()
        navigation.selectLibrary()
        navigation.openGallery("s1")
        navigation.backFromGallery()
        #expect(navigation.isLibrary, "从全局图库进入图库应返回全局图库")

        navigation.selectDashboard()
        navigation.openGallery("s1")
        // 图库内部再次 openGallery（刷新/换照片）不得把来源改成图库自身。
        navigation.openGallery("s1")
        navigation.backFromGallery()
        #expect(navigation.isDashboard)
    }

    // MARK: 9-30 审查：返回语义（B1）

    @Test("B1：工作台 → 控制中心 → 浏览 → 相似度 → 返回，应回浏览页而不是工作台")
    func backFromSimilarityReturnsToGallery() {
        let navigation = RootNavigation()
        navigation.selectDashboard()
        navigation.openSession("s1")
        // 「浏览」是 .gallery 目的地（不是会话页签）。
        navigation.openGallery("s1")
        navigation.openSimilarity("s1")
        navigation.backFromSimilarity(sessionId: "s1")
        #expect(navigation.isGallery(sessionId: "s1"), "返回落点必须是进入相似度之前的浏览页")

        // 从控制中心进入相似度 → 返回控制中心（同层页签切换也要精确恢复）。
        let second = RootNavigation()
        second.selectDashboard()
        second.openSession("s1")
        second.openSessionTab("s1", .control)
        second.openSimilarity("s1")
        second.backFromSimilarity(sessionId: "s1")
        #expect(second.isSessionTab(sessionId: "s1", tab: .control), "应回到控制中心页签")
    }

    @Test("B1/E-P0：会话内部切页签不改变返回目标（返回=离开会话回到来源）")
    func sessionBackLeavesSessionRegion() {
        let navigation = RootNavigation()
        navigation.selectDashboard()
        navigation.openSession("s1")           // 控制中心（页签）
        navigation.openSessionTab("s1", .culling)
        navigation.backFromSession(sessionId: "s1")
        // E-P0 的语义：会话页的「返回」是**离开会话区域**回到进入处，
        // 不是浏览器式的「回到上一个页签」。同会话内的页签切换因此不记录来源。
        #expect(navigation.isDashboard, "应回到进入会话前的工作台")
    }

    @Test("B1：跨会话跳转的返回落在上一个会话页")
    func crossSessionBackReturnsToPreviousSessionPage() {
        let navigation = RootNavigation()
        navigation.selectDashboard()
        navigation.openSession("s1")
        navigation.openSessionTab("s1", .culling)
        // 从会话 A 跳到会话 B（跨工作区）：这是真正的「离开 A」。
        navigation.openSessionTab("s2", .control)
        navigation.backFromSession(sessionId: "s2")
        #expect(navigation.isSessionTab(sessionId: "s1", tab: .culling), "应回到上一个会话的挑片页")
    }

    // MARK: 渐进细节（Bridge/C1 式缩放重解码）

    @Test("档位：1× 用基准档，缩放越高档位越大")
    func detailTierGrowsWithZoom() {
        // 1180 宽窗口下的查看器适配约 720pt（横构图）
        let base = PhotoDetailTier.target(fitPoints: 720, zoom: 1, backingScale: 2, sourceMaxDimension: 6000)
        #expect(base == PhotoDetailTier.baseDimension, "1× 保持基准档（旧行为）")
        let at2 = PhotoDetailTier.target(fitPoints: 720, zoom: 2, backingScale: 2, sourceMaxDimension: 6000)
        let at4 = PhotoDetailTier.target(fitPoints: 720, zoom: 4, backingScale: 2, sourceMaxDimension: 6000)
        let at8 = PhotoDetailTier.target(fitPoints: 720, zoom: 8, backingScale: 2, sourceMaxDimension: 6000)
        #expect(at2 > base && at4 > at2 && at8 >= at4, "档位必须随缩放单调不减")
        // 源图 6000px：8× 需要的 11520px 超过源图能力 → 顶到源图尺寸（不超采样）。
        #expect(at8 == 6000, "不得申请超过源图能力的解码尺寸")
    }

    @Test("档位：不超过源图尺寸、不超过硬上限、非法输入有兜底")
    func detailTierClamps() {
        // 源图只有 2000px：请求再大也不该超采样。
        let small = PhotoDetailTier.target(fitPoints: 720, zoom: 8, backingScale: 2, sourceMaxDimension: 2000)
        #expect(small <= 2560, "不得申请超过源图能力的解码尺寸")
        // 超大源图：仍受 8192 硬上限约束（单张 8192 ≈ 256MB RGBA）。
        let huge = PhotoDetailTier.target(fitPoints: 2000, zoom: 8, backingScale: 2, sourceMaxDimension: 20000)
        #expect(huge == PhotoDetailTier.maxDimension)
        // 非法/退化输入不能崩、也不返回 0。
        #expect(PhotoDetailTier.target(fitPoints: 0, zoom: 8, backingScale: 2, sourceMaxDimension: 6000) == PhotoDetailTier.baseDimension)
        #expect(PhotoDetailTier.target(fitPoints: 720, zoom: .nan, backingScale: 2, sourceMaxDimension: 6000) == PhotoDetailTier.baseDimension)
        #expect(PhotoDetailTier.target(fitPoints: 720, zoom: 4, backingScale: 0, sourceMaxDimension: 6000) > 0)
        // 对比模式（多格）必须收窄单格预算：4 格各 8192px 会瞬时吃掉约 1GB。
        let fourUp = PhotoDetailTier.target(
            fitPoints: 360, zoom: 8, backingScale: 2, sourceMaxDimension: 20000,
            budgetDimension: PhotoDetailTier.budget(forVisibleCells: 4)
        )
        #expect(fourUp <= 4096, "对比模式下单格档位必须受限（实测 4 格：(fourUp)）")
        #expect(PhotoDetailTier.budget(forVisibleCells: 1) == PhotoDetailTier.maxDimension)
        #expect(PhotoDetailTier.budget(forVisibleCells: 2) < PhotoDetailTier.budget(forVisibleCells: 1))
    }

    @Test("档位：离散化把连续捏合折成有限次解码")
    func detailTierIsDiscrete() {
        var seen = Set<Int>()
        for step in 0...80 {
            let zoom = 1 + Double(step) * 0.1   // 1.0 → 9.0
            seen.insert(PhotoDetailTier.target(fitPoints: 720, zoom: zoom, backingScale: 2, sourceMaxDimension: 6000))
        }
        #expect(seen.count <= PhotoDetailTier.tiers.count, "整个缩放区间的解码档位必须是有限集合")
        #expect(seen.count >= 3, "高缩放必须真的换档（否则等于没做渐进细节）")
    }

    // MARK: 可见区域细节层（tiled detail）

    @Test("细节层：缩放不足时不需要（底层位图够用）")
    func detailTileInactiveWhenZoomedOut() {
        let tile = PhotoViewerGeometry.detailTile(
            imageSize: CGSize(width: 4000, height: 3000),
            viewSize: CGSize(width: 720, height: 540),
            zoom: 1.2,
            panOffset: .zero,
            backingPixelBudget: PhotoDetailTier.baseDimension
            )
        #expect(tile == nil, "1.2× 时 2560px 底层位图仍够用，不该解码细节层")
    }

    @Test("细节层：放大后覆盖可见区域，且落在视图内")
    func detailTileCoversVisibleArea() throws {
        let viewSize = CGSize(width: 720, height: 540)
        let tile = try #require(PhotoViewerGeometry.detailTile(
            imageSize: CGSize(width: 4000, height: 3000),
            viewSize: viewSize,
            zoom: 4,
            panOffset: .zero,
            backingPixelBudget: PhotoDetailTier.baseDimension
        ))
        // 4× 放大时可见的归一化区域接近 1/4（余量 +12%）。
        #expect(tile.normalizedRect.width < 0.4 && tile.normalizedRect.height < 0.4)
        #expect(tile.normalizedRect.minX >= 0 && tile.normalizedRect.maxX <= 1.0001)
        #expect(tile.normalizedRect.minY >= 0 && tile.normalizedRect.maxY <= 1.0001)
        // 细节层必须**覆盖**整个视图（含 12% 余量，所以会比视图略大，由裁剪兜住）。
        #expect(tile.viewRect.minX <= 0.5 && tile.viewRect.maxX >= viewSize.width - 0.5)
        #expect(tile.viewRect.minY <= 0.5 && tile.viewRect.maxY >= viewSize.height - 0.5)
        #expect(tile.viewRect.width <= viewSize.width * 1.5, "余量必须有界（不得无限外扩）")
    }

    @Test("细节层：平移后可见区域跟着移动（不是固定中心）")
    func detailTileFollowsPan() throws {
        let viewSize = CGSize(width: 720, height: 540)
        let centered = try #require(PhotoViewerGeometry.detailTile(
            imageSize: CGSize(width: 4000, height: 3000), viewSize: viewSize,
            zoom: 4, panOffset: .zero, backingPixelBudget: PhotoDetailTier.baseDimension
        ))
        let panned = try #require(PhotoViewerGeometry.detailTile(
            imageSize: CGSize(width: 4000, height: 3000), viewSize: viewSize,
            zoom: 4, panOffset: CGSize(width: 300, height: 0),
            backingPixelBudget: PhotoDetailTier.baseDimension
        ))
        // 把图像往右拖（offset 增大）→ 视口相对图像左移。
        #expect(panned.normalizedRect.minX < centered.normalizedRect.minX, "向右拖图应看到更靠左的区域")
        #expect(panned.normalizedRect.width == centered.normalizedRect.width)
    }

    @Test("细节层：像素预算量化到 256 且受上限约束")
    func detailTilePixelBudget() {
        let small = PhotoViewerGeometry.tilePixelSize(
            viewRect: CGRect(x: 0, y: 0, width: 100, height: 80),
            budgetDimension: PhotoDetailTier.maxDimension
        )
        #expect(small % 256 == 0, "量化到 256 便于缓存复用：\(small)")
        #expect(small >= 256)
        let large = PhotoViewerGeometry.tilePixelSize(
            viewRect: CGRect(x: 0, y: 0, width: 4000, height: 3000),
            budgetDimension: 4096
        )
        #expect(large <= 4096, "不得突破调用方预算（对比模式按格数收窄）")
    }

    // MARK: 性能审计修复（磁盘缓存 / 闸门）

    @Test("磁盘缩略图缓存：键含源文件 mtime+size，源文件改动即失效")
    func diskCacheKeyInvalidatesOnSourceChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-diskcache-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        let first = ThumbnailDiskCache.key(path: url.path, size: 256, preview: true)
        #expect(first != nil, "存在的文件必须能算出缓存键")
        // 重新写入（mtime/size 变化）→ 键必须不同，旧缓存自动失效。
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xD9]).write(to: url)
        let second = ThumbnailDiskCache.key(path: url.path, size: 256, preview: true)
        #expect(first != second, "源文件变化后缓存键必须改变")
        // 尺寸档位进入键（不同档位不可互相复用）。
        let otherSize = ThumbnailDiskCache.key(path: url.path, size: 512, preview: true)
        #expect(otherSize != second)
        // 不存在的文件不产生键（避免为离线照片写缓存）。
        #expect(ThumbnailDiskCache.key(path: "/tmp/gather-missing-\(UUID().uuidString).jpg", size: 256, preview: true) == nil)
    }

    @Test("磁盘缓存：写入后可读回、源文件变化即失效（临时目录往返）")
    func diskCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-thumb-cache-\(UUID().uuidString)")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-thumb-src-\(UUID().uuidString).jpg")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: source)
        }
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: source)
        ThumbnailDiskCache.directoryOverride = dir
        ThumbnailDiskCache.isEnabled = true
        defer {
            ThumbnailDiskCache.isEnabled = false
            ThumbnailDiskCache.directoryOverride = nil
        }
        let payload = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0xFF, 0xD9])
        ThumbnailDiskCache.store(payload, path: source.path, size: 512, preview: true)
        #expect(ThumbnailDiskCache.data(path: source.path, size: 512, preview: true) == payload,
                "写入后必须能读回（缓存真正落盘）")
        // 源文件变化 → 键变化 → 旧缓存不再命中。
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9]).write(to: source)
        #expect(ThumbnailDiskCache.data(path: source.path, size: 512, preview: true) == nil,
                "源文件变化后旧缓存必须失效")
    }

    @Test("解码闸门：limit=1 时第二个请求必须排队，释放后获得名额")
    func decodeGateSerializesBeyondLimit() async {
        let gate = PhotoDecodeGate(limit: 1)
        #expect(await gate.acquire() == true)
        let waiter = Task { await gate.acquire() }
        // 名额未释放：等待者仍未被唤醒（sleep 后状态不变即视为排队中）。
        try? await Task.sleep(for: .milliseconds(80))
        await gate.release()
        let second = await waiter.value
        #expect(second == true, "名额释放后排队者必须获得名额")
        await gate.release()
    }

    @Test("解码闸门：等待期间被取消必须立即返回 false（不得永久挂起）")
    func decodeGateCancellationDoesNotHang() async {
        let gate = PhotoDecodeGate(limit: 1)
        #expect(await gate.acquire() == true)
        let waiter = Task { () -> Bool in
            await gate.acquire()
        }
        try? await Task.sleep(for: .milliseconds(40))
        waiter.cancel()
        let acquired = await waiter.value
        #expect(acquired == false, "被取消的等待者必须返回 false（否则 inFlight 永不清理）")
        await gate.release()
    }
}
