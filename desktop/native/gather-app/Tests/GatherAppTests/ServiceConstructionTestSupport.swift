// desktop/native/gather-app/Tests/GatherAppTests/ServiceConstructionTestSupport.swift
// WP3b-1 测试接线：与 core 侧同一策略——旧 connection: 签名装配为 Repo 端口。
import Foundation
import GatherPersistence
import GatherProtocol
import GatherDelivery
@testable import GatherApplication

extension SessionService {
    convenience init(
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        faceRepo: FaceRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        dimensionsProvider: @escaping (String) throws -> (width: Int, height: Int) = { _ in
            throw SessionServiceError.sourceNotDir
        },
        assetRepo: AssetRepo? = nil
    ) {
        self.init(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            faceRepo: faceRepo,
            personRepo: PersonRepo(connection: connection),
            metadataCacheRepo: MetadataCacheRepo(connection: connection),
            jobRepo: AnalysisJobRepo(connection: connection),
            assetRepo: assetRepo,
            deliverySummary: DeliverySummaryQuery(connection: connection),
            transactions: connection,
            getNumber: getNumber,
            dimensionsProvider: dimensionsProvider
        )
    }
}

extension TemplateService {
    convenience init(connection: DBConnection, settings: SettingsService) {
        self.init(templates: TemplateRepo(connection: connection), settings: settings)
    }
}

extension WorkspaceStatusService {
    convenience init(
        connection: DBConnection,
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.init(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            jobRepo: AnalysisJobRepo(connection: connection),
            deliverySummary: DeliverySummaryQuery(connection: connection),
            clock: clock
        )
    }
}

extension MetadataService {
    convenience init(
        metadataCacheRepo: MetadataCacheRepo,
        xmp: any XMPProvider,
        connection: DBConnection,
        mutations: any MetadataMutationPort,
        flushPending: MetadataQueueFlush? = nil,
        assetResolver: PhotoAssetResolver? = nil,
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil
    ) {
        self.init(
            metadataCacheRepo: metadataCacheRepo,
            xmp: xmp,
            photoRepo: PhotoRepo(connection: connection),
            transactions: connection,
            mutations: mutations,
            flushPending: flushPending,
            assetResolver: assetResolver,
            exif: exif,
            dimensions: dimensions,
            embeddedReader: embeddedReader
        )
    }
}

extension ExportService {
    convenience init(photoRepo: PhotoRepo, sessionRepo: SessionRepo, connection: DBConnection) {
        self.init(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            reports: ExportReportRepo(connection: connection)
        )
    }
}

extension QualityService {
    convenience init(
        photoRepo: PhotoRepo,
        connection: DBConnection,
        imageProvider: @escaping ImageMetricsProvider = QualityService.defaultImageProvider,
        statProvider: @escaping StatProvider = QualityService.defaultStat,
        invalidateCullingLookup: ((String) -> Void)? = nil
    ) {
        self.init(
            photoRepo: photoRepo,
            qualityRepo: QualityRepo(connection: connection),
            imageProvider: imageProvider,
            statProvider: statProvider,
            invalidateCullingLookup: invalidateCullingLookup
        )
    }
}

extension NavigationService {
    convenience init(connection: DBConnection) {
        self.init(navigationRepo: NavigationRepo(connection: connection))
    }
}

extension FilterEngine {
    convenience init(connection: DBConnection) {
        self.init(query: PhotoFilterQuery(connection: connection))
    }
}
