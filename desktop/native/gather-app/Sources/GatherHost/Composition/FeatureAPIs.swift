// desktop/native/gather-app/Sources/GatherHost/Composition/FeatureAPIs.swift
// WP4c / 组合根阶段 3：16 个 Live API 工厂。
//
// 每个工厂只把 CompositionCore 的共享实例包成 Live API，不构造业务服务、
// 不打开数据库、不注册 executor：JobService / SettingsService / PersonRepo /
// DeliveryRepo 等必须与组合根同实例。工厂按拆分前 AppServices.assemble 的
// 求值顺序（job → session → settings → photo → asset → album → navigation →
// 其余九个域）构造，被 AppServicesRoot（Root.swift）组装成 AppServices。
import Foundation
import GatherProtocol
import GatherPersistence

/// 16 个 Live API 的工厂集合；`init(composition:)` 保持原装配顺序。
struct FeatureAPIs {
    let session: any SessionAPI
    let job: any JobAPI
    let settings: any SettingsAPI
    let photo: any PhotoAPI
    let asset: any AssetAPI
    let album: any AlbumAPI
    let navigation: any NavigationAPI
    let culling: any CullingAPI
    let face: any FaceAPI
    let similarity: any SimilarityAPI
    let duplicate: any DuplicateAPI
    let quality: any QualityAPI
    let export: any ExportAPI
    let metadata: any MetadataAPI
    let person: any PersonAPI
    let maintenance: any MaintenanceAPI

    init(composition: AppComposition) {
        let job = Self.makeJob(composition)
        self.job = job
        self.session = Self.makeSession(composition)
        self.settings = Self.makeSettings(composition)
        self.photo = Self.makePhoto(composition, job: job)
        self.asset = Self.makeAsset(composition)
        self.album = Self.makeAlbum(composition)
        self.navigation = Self.makeNavigation(composition)
        self.culling = Self.makeCulling(composition)
        self.face = Self.makeFace(composition)
        self.similarity = Self.makeSimilarity(composition)
        self.duplicate = Self.makeDuplicate(composition)
        self.quality = Self.makeQuality(composition)
        self.export = Self.makeExport(composition)
        self.metadata = Self.makeMetadata(composition)
        self.person = Self.makePerson(composition)
        self.maintenance = Self.makeMaintenance(composition)
    }

    private static func makeMaintenance(_ composition: AppComposition) -> any MaintenanceAPI {
        LiveMaintenanceAPI(service: composition.maintenanceService)
    }

    private static func makeJob(_ composition: AppComposition) -> any JobAPI {
        LiveJobAPI(jobService: composition.jobService)
    }

    private static func makeSession(_ composition: AppComposition) -> any SessionAPI {
        LiveSessionAPI(
            sessionService: composition.sessionService,
            workspaceStatusService: composition.workspaceStatusService,
            jobService: composition.jobService
        )
    }

    private static func makeSettings(_ composition: AppComposition) -> any SettingsAPI {
        LiveSettingsAPI(settingsService: composition.settingsService)
    }

    private static func makePhoto(
        _ composition: AppComposition, job: any JobAPI
    ) -> any PhotoAPI {
        LivePhotoAPI(
            photoRepo: composition.photoRepo,
            assetRepo: composition.assetRepo,
            faceKwService: composition.faceKwService,
            filterEngine: composition.filterEngine,
            imagePreloadService: composition.imagePreloadService,
            settingsService: composition.settingsService,
            jobAPI: job,
            facetQuery: FacetQuery(connection: composition.db)
        )
    }

    private static func makeAsset(_ composition: AppComposition) -> any AssetAPI {
        LiveAssetAPI(assetRepo: composition.assetRepo)
    }

    private static func makeAlbum(_ composition: AppComposition) -> any AlbumAPI {
        LiveAlbumAPI(
            albumRepo: composition.smartAlbumRepo,
            filterEngine: composition.filterEngine
        )
    }

    private static func makeNavigation(_ composition: AppComposition) -> any NavigationAPI {
        LiveNavigationAPI(navigationService: composition.navigationService)
    }

    /// 只包装组合根的 CullingService（会话级更新上下文缓存、写回端口都只有一份）。
    private static func makeCulling(_ composition: AppComposition) -> any CullingAPI {
        LiveCullingAPI(
            cullingService: composition.cullingService,
            triageService: composition.triageService,
            sessionRepo: SessionRepo(connection: composition.db),
            photoRepo: composition.photoRepo,
            relocateAfterMove: { photoId, oldPath, newPath in
                try composition.assetRepo.relocatePhotoPathsAfterMove(
                    photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
                    timestamp: nowISOString())
            },
            fileLock: composition.xmpFileLock
        )
    }

    private static func makeFace(_ composition: AppComposition) -> any FaceAPI {
        LiveFaceAPI(
            faceKwService: composition.faceKwService,
            jobService: composition.jobService,
            settingsService: composition.settingsService
        )
    }

    private static func makeSimilarity(_ composition: AppComposition) -> any SimilarityAPI {
        LiveSimilarityAPI(
            similarityService: composition.similarityService,
            jobService: composition.jobService,
            settingsService: composition.settingsService
        )
    }

    private static func makeDuplicate(_ composition: AppComposition) -> any DuplicateAPI {
        LiveDuplicateAPI(
            duplicateService: composition.duplicateService,
            jobService: composition.jobService
        )
    }

    private static func makeQuality(_ composition: AppComposition) -> any QualityAPI {
        LiveQualityAPI(
            qualityService: composition.qualityService,
            jobService: composition.jobService
        )
    }

    private static func makeExport(_ composition: AppComposition) -> any ExportAPI {
        LiveExportAPI(
            exportService: composition.exportService,
            jobService: composition.jobService
        )
    }

    private static func makeMetadata(_ composition: AppComposition) -> any MetadataAPI {
        LiveMetadataAPI(
            metadataService: composition.metadataService,
            deliveryRepo: composition.deliveryRepo,
            xmp: composition.xmpProvider,
            fileLock: composition.xmpFileLock,
            settingsService: composition.settingsService
        )
    }

    private static func makePerson(_ composition: AppComposition) -> any PersonAPI {
        LivePersonAPI(personRepo: composition.personRepo)
    }

}
