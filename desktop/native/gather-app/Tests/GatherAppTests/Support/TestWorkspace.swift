// desktop/native/gather-app/Tests/GatherAppTests/Support/TestWorkspace.swift
// Cut 4 / 4a-2c：测试用 SessionWorkspace 装配器。
//
// 页面在 4a-2c 只保留 package init(workspace:...)（兼容 init 已删除），
// 因此测试需要按生产形状组装 7 个 VM。本文件只做装配：全部用现有类型化替身，
// 不建库、不启动轮询（similarity 轮询间隔拉到 1 小时）。
import Foundation
import GatherProtocol
import GatherUI
import GatherHost

private struct TestWorkspaceGalleryProviderStub: GalleryDataProvider {
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

/// 组装一个完整的 SessionWorkspace；调用方可替换任意一个 VM。
@MainActor
func makeTestSessionWorkspace(
    sessionId: String = "s1",
    culling: CullingViewModel? = nil,
    duplicates: DuplicatesViewModel? = nil,
    export: ExportViewModel? = nil,
    face: FaceKeywordingViewModel? = nil,
    control: SessionControlViewModel? = nil,
    gallery: GalleryViewModel? = nil,
    similarity: SimilarityViewModel? = nil
) -> SessionWorkspace {
    SessionWorkspace(
        sessionId: sessionId,
        culling: culling ?? CullingViewModel(
            sessionId: sessionId,
            culling: B8CullingAPIStub(),
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        ),
        duplicates: duplicates ?? DuplicatesViewModel(
            sessionId: sessionId,
            duplicate: B5bDuplicateAPIStub(),
            jobs: B5bJobAPIStub()
        ),
        export: export ?? ExportViewModel(
            sessionId: sessionId,
            export: B6bExportAPIStub(),
            session: B8SessionAPIStub()
        ),
        face: face ?? FaceKeywordingViewModel(
            sessionId: sessionId,
            face: B8FaceAPIStub(),
            jobs: B5bJobAPIStub(),
            captureOne: CaptureOneBridge()
        ),
        control: control ?? SessionControlViewModel(
            sessionId: sessionId,
            session: B8SessionAPIStub(),
            culling: B8CullingAPIStub(),
            jobAPI: B5bJobAPIStub(),
            qualityAPI: B5bQualityAPIStub()
        ),
        gallery: gallery ?? GalleryViewModel(
            sessionId: sessionId,
            provider: TestWorkspaceGalleryProviderStub(),
            job: B5bJobAPIStub()
        ),
        similarity: similarity ?? SimilarityViewModel(
            sessionId: sessionId,
            similarity: B8SimilarityAPIStub(),
            jobs: B5bJobAPIStub(),
            pollInterval: .seconds(3600),
            captureOne: CaptureOneBridge()
        )
    )
}

/// 三个「文案推导」单测只需要 control 页宿主；其余 6 个 VM 用空桩。
@MainActor
func makeTestControlWorkspace(sessionId: String = "s1") -> SessionWorkspace {
    makeTestSessionWorkspace(
        sessionId: sessionId,
        control: SessionControlViewModel(
            sessionId: sessionId,
            session: B8SessionAPIStub(),
            culling: B8CullingAPIStub(),
            jobAPI: B5bJobAPIStub(),
            qualityAPI: B5bQualityAPIStub()
        )
    )
}
