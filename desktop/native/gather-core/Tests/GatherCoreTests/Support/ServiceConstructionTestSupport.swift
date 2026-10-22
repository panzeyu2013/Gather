// desktop/native/gather-core/Tests/GatherCoreTests/Support/ServiceConstructionTestSupport.swift
// WP3b-1 测试接线：Application 服务改为注入 Repo 端口后，测试仍按旧签名
// （connection: DBConnection）构造。这里只做「DBConnection → 具体 Repo/事务端口」
// 的显式装配，所有调用都落到生产 init，不改变服务行为，也不伪造依赖。
import Foundation
import GatherPersistence
import GatherProtocol
import GatherDelivery
import GatherAnalysis
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

// MARK: - WP3b-2：Similarity（hash/run/交付项端口）

extension SimilarityService {
    convenience init(
        photoRepo: PhotoRepo,
        sessionRepo: SessionRepo,
        similarityResultRepo: SimilarityResultRepo,
        clusterStateRepo: SimilarityClusterStateRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        thumbnailProvider: @escaping ThumbnailProvider = { _, _ in nil },
        clusterProvider: @escaping ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            // 与生产 init 的默认值逐字一致（Cut 5 / 5b-2a 唯一实现）。
            try ClusterGraphPipeline.run(
                entries: entries, threshold: threshold,
                minGroupSize: minGroupSize, mode: mode, onProgress: onProgress)
        },
        multiClusterProvider: @escaping MultiClusterProvider = {
            entries, thresholds, minGroupSize, mode, onProgress in
            // 与生产 init 的默认值逐字一致。
            try ClusterGraphPipeline.runTiers(
                entries: entries, thresholds: thresholds,
                minGroupSize: minGroupSize, mode: mode, onProgress: onProgress)
        },
        writebackProvider: (any SimilarityWritebackProvider)? = nil,
        delivery: (any SimilarityDeliveryPort)? = nil
    ) {
        self.init(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: similarityResultRepo,
            clusterStateRepo: clusterStateRepo,
            hashes: SimilarityHashRepo(connection: connection),
            analysisRuns: AnalysisRunRepo(connection: connection),
            deliveryItems: DeliveryRepo(connection: connection),
            transactions: connection,
            getNumber: getNumber,
            thumbnailProvider: thumbnailProvider,
            clusterProvider: clusterProvider,
            multiClusterProvider: multiClusterProvider,
            writebackProvider: writebackProvider,
            // 旧默认：宿主未注入时按同一 connection 自建 coordinator（行为不变）。
            delivery: delivery ?? CoordinatorDeliveryAdapter(
                engine: DeliveryCoordinator(
                    connection: connection,
                    files: FileSystemDeliveryFilePort()
                ),
                module: .similarity
            )
        )
    }

    /// 旧静态入口（测试直调）：hash 端口 + 事务端口由同一连接装配。
    static func reuseSimilarityHashes(
        connection: DBConnection,
        sessionId: String,
        photos: [PhotoProjectionRow],
        sourceStats: [String: (size: Int, mtimeMs: Double)],
        existingHashMap: inout [String: String]
    ) throws -> Int {
        try reuseSimilarityHashes(
            hashes: SimilarityHashRepo(connection: connection),
            transactions: connection,
            sessionId: sessionId,
            photos: photos,
            sourceStats: sourceStats,
            existingHashMap: &existingHashMap
        )
    }
}


// MARK: - WP3b-2：FaceKw（feedback / 簇成员写 / run / 交付项端口）

extension FaceKwService {
    convenience init(
        photoRepo: PhotoRepo,
        sessionRepo: SessionRepo,
        faceRepo: FaceRepo,
        personRepo: PersonRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        getString: @escaping (String, String) -> String = { _, defaultValue in defaultValue },
        decodeProvider: DecodeProvider? = nil,
        inferenceProvider: FaceInferenceProvider? = nil,
        clusterProvider: @escaping FaceClusterProvider = { entries, eps, minPts, options, onProgress, isCancelled in
            // 与生产 init 的默认值逐字一致。
            try FaceClusterer.clusterEmbeddings(
                entries: entries,
                eps: eps,
                minPts: minPts,
                coreQualityFloor: options.coreQualityFloor,
                retryMinSamples: options.retryMinSamples,
                onProgress: onProgress,
                isCancelled: isCancelled)
        },
        writebackProvider: FaceWritebackProvider? = nil,
        delivery: (any FaceKwDeliveryPort)? = nil
    ) {
        self.init(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: faceRepo,
            personRepo: personRepo,
            feedback: FaceFeedbackRepo(connection: connection),
            analysisRuns: AnalysisRunRepo(connection: connection),
            deliveryItems: DeliveryRepo(connection: connection),
            transactions: connection,
            getNumber: getNumber,
            getString: getString,
            decodeProvider: decodeProvider,
            inferenceProvider: inferenceProvider,
            clusterProvider: clusterProvider,
            writebackProvider: writebackProvider,
            // 旧默认：宿主未注入时按同一 connection 自建 coordinator（行为不变）。
            delivery: delivery ?? CoordinatorDeliveryAdapter(
                engine: DeliveryCoordinator(
                    connection: connection,
                    files: FileSystemDeliveryFilePort()
                ),
                module: .faceKeyword
            )
        )
    }
}


// MARK: - WP3b-2：Culling（分页/富查询/交付项/事务端口）

extension CullingService {
    convenience init(
        photoRepo: PhotoRepo,
        cullingDecisionRepo: CullingDecisionRepo,
        similarityResultRepo: SimilarityResultRepo,
        metadataCacheRepo: MetadataCacheRepo,
        connection: DBConnection,
        metadataMutations: any MetadataMutationPort,
        writeback: any CullingWritebackPort,
        cullingHistoryRepo: CullingHistoryRepo? = nil,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        delivery: (any CullingDeliveryPort)? = nil
    ) {
        self.init(
            photoRepo: photoRepo,
            cullingDecisionRepo: cullingDecisionRepo,
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo,
            pageQuery: CullingAssetPageQuery(connection: connection),
            richQuery: CullingReadQuery(connection: connection),
            deliveryItems: DeliveryRepo(connection: connection),
            transactions: connection,
            metadataMutations: metadataMutations,
            writeback: writeback,
            cullingHistoryRepo: cullingHistoryRepo,
            getNumber: getNumber,
            // 旧默认：宿主未注入时按同一 connection 自建 coordinator（行为不变）。
            delivery: delivery ?? CoordinatorDeliveryAdapter(
                engine: DeliveryCoordinator(
                    connection: connection,
                    files: FileSystemDeliveryFilePort()
                ),
                module: .culling
            )
        )
    }
}


// MARK: - WP3b-2：Indexer（扫描写路径 / 事务端口）

extension IndexerService {
    convenience init(
        connection: DBConnection,
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        assetRepo: AssetRepo,
        faceRepo: FaceRepo? = nil,
        getDimensions: @escaping DimensionsProvider = IndexerService.defaultDimensions,
        getSetting: @escaping SettingReader = { _, defaultValue in defaultValue },
        warmMetadata: @escaping MetadataWarmup = { _ in }
    ) {
        self.init(
            indexer: IndexerRepo(connection: connection),
            transactions: connection,
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            faceRepo: faceRepo,
            getDimensions: getDimensions,
            getSetting: getSetting,
            warmMetadata: warmMetadata
        )
    }
}
