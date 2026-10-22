// desktop/native/gather-app/Sources/GatherHost/APIs/AppServices.swift
// Cut 1 / 阶段 B1+B2+B3a+B4a+B5a+B6a+B7a：Live API 组合根（session / job /
// settings / photo / asset / album / navigation / culling / face / similarity /
// duplicate / quality / export / metadata / person / template 十六个域）。
//
// 命名稳定性：B3-B7 会在此扩展 media/delivery/analysis 等分组，本批的七个字段名
// 保持不变。装配只负责“把共享服务包成 Live API”，不重新构造服务实例（JobService
// 的执行器注册、SettingsService 的缓存都必须与组合根共用同一实例，否则任务不
// 执行 / 设置双缓存；Photo/Album/Navigation 的 Repo 同理，避免第二个数据库连接
// 看到不同快照）。
//
// B8.3b-2a/B8.3b-2b/B8.4：装配入口只有 AppServices.live(composition:)；本文件只把
// 组合根已构造好的实例包成 Live API（db / JobService / SettingsService /
// 协调器 / Repo 都只有一份，不在装配阶段 new 服务）。旧 live(router:) 六个
// 重载与字符串命令面已删除，生产路径只从组合根取服务。
//
// 错误展示：保留原有“码 -> 本地化文案 / 未知回退通用文案”的语义。
// APIErrorPresentation 是唯一漏斗（SessionServiceError / BridgeError /
// APIError / RouterCommandError / NSError 的行为完全不变），不反向依赖
// 任何字符串命令客户端。Cut 3 / 3b-0 起该漏斗已搬到
// Support/APIErrorPresentation.swift（同 target，本文件不再声明它）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
import GatherDelivery
import GatherUI

public struct AppServices: Sendable {
    public let session: any SessionAPI
    public let job: any JobAPI
    public let settings: any SettingsAPI
    public let photo: any PhotoAPI
    public let asset: any AssetAPI
    public let album: any AlbumAPI
    public let navigation: any NavigationAPI
    /// B3a：挑片域（17 个方法 / 19 条命令）；B3b 已替换 CullingView 的调用点。
    public let culling: any CullingAPI
    /// B4a：人脸关键字域（13 个方法 / 14 条命令）。B4b 才把
    /// FaceKeywordingView 的调用点切过来，暂不传给页面。
    public let face: any FaceAPI
    /// B4a：相似度域（10 个方法 / 10 条命令）。生产 RootView 直接注入
    /// SimilarityViewModel；旧的 LiveSimilarityDataProvider 已删除。
    public let similarity: any SimilarityAPI
    /// B5a：重复检测域（4 个方法 / 4 条命令）。B5b 才迁移 DuplicatesView，
    /// 暂不传给页面。
    public let duplicate: any DuplicateAPI
    /// B5a：画质域（2 个方法 / 2 条命令）。B5b 才迁移 ControlCenter 的
    /// quality 调用点，暂不传给页面。
    public let quality: any QualityAPI
    /// B6a：导出域（4 个方法 / 4 条命令）。B6b 才迁移 ExportView 的调用点，
    /// 暂不传给页面；执行走组合根注册的 exportExecute 执行器。
    public let export: any ExportAPI
    /// B6a：元数据域（7 个方法 / 7 条命令）。B6b 才迁移 LibraryViewModel
    /// （orphans）与 CullingView（conflicts）的调用点，暂不传给页面。
    public let metadata: any MetadataAPI
    /// B7a：人物库域（8 个方法 / 8 条命令）。B7b 才迁移 PersonsViewModel
    /// 与 LivePersonsDataProvider，暂不传给页面。
    public let person: any PersonAPI
    /// B7a：工作流模板域（6 个方法 / 6 条命令）。当前 UI 0 调用（D-008），
    /// B7b 视产品结论决定是否接页面，暂不传给页面。
    public let template: any TemplateAPI
    /// Cut 1 / B8.3b-1：宿主运行时（与组合根共用同一 db/JobService/
    /// MetadataSyncCoordinator 的**唯一**实例）。GatherApp 用它驱动
    /// start()/shutdown()，CaptureOne reload ack 也经它落库；这里只暴露引用，
    /// 不构造任何服务（禁止第二套运行时）。
    public let runtime: AppRuntime

    public init(
        session: any SessionAPI,
        job: any JobAPI,
        settings: any SettingsAPI,
        photo: any PhotoAPI,
        asset: any AssetAPI,
        album: any AlbumAPI,
        navigation: any NavigationAPI,
        culling: any CullingAPI,
        face: any FaceAPI,
        similarity: any SimilarityAPI,
        duplicate: any DuplicateAPI,
        quality: any QualityAPI,
        export: any ExportAPI,
        metadata: any MetadataAPI,
        person: any PersonAPI,
        template: any TemplateAPI,
        runtime: AppRuntime
    ) {
        self.session = session
        self.job = job
        self.settings = settings
        self.photo = photo
        self.asset = asset
        self.album = album
        self.navigation = navigation
        self.culling = culling
        self.face = face
        self.similarity = similarity
        self.duplicate = duplicate
        self.quality = quality
        self.export = export
        self.metadata = metadata
        self.person = person
        self.template = template
        self.runtime = runtime
    }

    /// 生产装配（B8.3b-2a 起的唯一入口）：全部 Live API 直接包装组合根构造的
    /// 服务/Repo 实例。
    ///
    /// 本方法不构造业务服务、不打开数据库、不注册 executor：JobService、
    /// SettingsService、PersonRepo、TemplateService、MetadataSyncCoordinator 等
    /// 都是 composition 里的同一份实例（AppRuntime 也来自 composition.runtime）。
    public static func live(composition: AppComposition) -> AppServices {
        assemble(composition: composition)
    }


    /// 唯一装配函数：composition 提供共享服务，显式注入的域覆盖默认包装。
    /// 所有默认 Live API 都只包装 composition 的实例，不构造服务。
    private static func assemble(
        composition: AppComposition,
        culling: (any CullingAPI)? = nil,
        face: (any FaceAPI)? = nil,
        similarity: (any SimilarityAPI)? = nil,
        duplicate: (any DuplicateAPI)? = nil,
        quality: (any QualityAPI)? = nil,
        export: (any ExportAPI)? = nil,
        metadata: (any MetadataAPI)? = nil,
        person: (any PersonAPI)? = nil,
        template: (any TemplateAPI)? = nil
    ) -> AppServices {
        let job = LiveJobAPI(jobService: composition.jobService)
        let session = LiveSessionAPI(
            sessionService: composition.sessionService,
            workspaceStatusService: composition.workspaceStatusService,
            jobService: composition.jobService
        )
        let settings = LiveSettingsAPI(settingsService: composition.settingsService)
        let photo = LivePhotoAPI(
            photoRepo: composition.photoRepo,
            assetRepo: composition.assetRepo,
            faceKwService: composition.faceKwService,
            filterEngine: composition.filterEngine,
            imagePreloadService: composition.imagePreloadService,
            settingsService: composition.settingsService,
            jobAPI: job
        )
        let asset = LiveAssetAPI(assetRepo: composition.assetRepo)
        let album = LiveAlbumAPI(
            albumRepo: composition.smartAlbumRepo,
            filterEngine: composition.filterEngine
        )
        let navigation = LiveNavigationAPI(navigationService: composition.navigationService)
        return AppServices(
            session: session,
            job: job,
            settings: settings,
            photo: photo,
            asset: asset,
            album: album,
            navigation: navigation,
            culling: culling ?? makeCulling(composition),
            face: face ?? makeFace(composition),
            similarity: similarity ?? makeSimilarity(composition),
            duplicate: duplicate ?? makeDuplicate(composition),
            quality: quality ?? makeQuality(composition),
            export: export ?? makeExport(composition),
            metadata: metadata ?? makeMetadata(composition),
            person: person ?? makePerson(composition),
            template: template ?? makeTemplate(composition),
            runtime: composition.runtime
        )
    }

    /// 默认 culling 装配：只包装组合根的 CullingService（会话级更新上下文缓存、
    /// MetadataSyncCoordinator/WritebackService 端口都只有一份），不重建服务。
    private static func makeCulling(_ composition: AppComposition) -> any CullingAPI {
        LiveCullingAPI(
            cullingService: composition.cullingService,
            sessionRepo: SessionRepo(connection: composition.db)
        )
    }

    /// 默认 face 装配：FaceKwService/JobService/SettingsService 全部复用组合根
    /// 实例（job executor、设置缓存与分析互斥都依赖单实例）。
    private static func makeFace(_ composition: AppComposition) -> any FaceAPI {
        LiveFaceAPI(
            faceKwService: composition.faceKwService,
            jobService: composition.jobService,
            settingsService: composition.settingsService
        )
    }

    /// 默认 similarity 装配：SimilarityService（会话占用槽）必须与组合根共用
    /// 同一实例；写回执行器已由服务内部的 provider 接缝注入（S5c-2b-3b-1）。
    private static func makeSimilarity(_ composition: AppComposition) -> any SimilarityAPI {
        LiveSimilarityAPI(
            similarityService: composition.similarityService,
            jobService: composition.jobService,
            settingsService: composition.settingsService
        )
    }

    /// 默认 duplicate 装配：DuplicateService 的扫描单飞状态与 duplicate.scan
    /// 执行器必须与组合根共用同一实例，禁止在调用方重建。
    private static func makeDuplicate(_ composition: AppComposition) -> any DuplicateAPI {
        LiveDuplicateAPI(
            duplicateService: composition.duplicateService,
            jobService: composition.jobService
        )
    }

    /// 默认 quality 装配：QualityService 只读结果，但仍复用组合根实例，保证与
    /// quality.score 执行器同一组合根。
    private static func makeQuality(_ composition: AppComposition) -> any QualityAPI {
        LiveQualityAPI(
            qualityService: composition.qualityService,
            jobService: composition.jobService
        )
    }

    /// 默认 export 装配：ExportService（取消位/续跑）与 JobService
    /// （exportExecute 执行器 + 去重键）必须与组合根共用同一实例。
    private static func makeExport(_ composition: AppComposition) -> any ExportAPI {
        LiveExportAPI(
            exportService: composition.exportService,
            jobService: composition.jobService
        )
    }

    /// 默认 metadata 装配：MetadataService（缓存指纹/写入）、DeliveryRepo
    /// （conflicts/orphans 的交付读入口）与宿主 XMPProvider（冲突 remote 读 /
    /// 孤儿 restore）都复用组合根实例，不重建任何服务。
    ///
    /// S5c-2b-3b-2b-2：MetadataSyncCoordinator 已从组合根删除，本方法随之改传
    /// deliveryRepo/xmpProvider（父任务批准的唯一一处跨清单改动）。
    private static func makeMetadata(_ composition: AppComposition) -> any MetadataAPI {
        LiveMetadataAPI(
            metadataService: composition.metadataService,
            deliveryRepo: composition.deliveryRepo,
            xmp: composition.xmpProvider
        )
    }

    /// 默认 person 装配（D-058 预授权）：PersonRepo 只持有共享 DBConnection，
    /// 但同一实例可避免第二个 Repo 缓存/连接观察差异。
    private static func makePerson(_ composition: AppComposition) -> any PersonAPI {
        LivePersonAPI(personRepo: composition.personRepo)
    }

    /// 默认 template 装配（D-058 预授权）：TemplateService 持有 SettingsService
    /// 的内存缓存（apply 必须同步缓存），只能有一份。
    private static func makeTemplate(_ composition: AppComposition) -> any TemplateAPI {
        LiveTemplateAPI(templateService: composition.templateService)
    }
}

/// B2 Live API 的共享错误收敛：
/// - DBError.message 若本身就是 GatherErrorCode（如 ASSET_RELINK_SAME_ROOT、
///   ALBUM_NOT_FOUND、ASSET_LINK_CANDIDATE_NOT_FOUND），转成带 code 的 GatherError；
/// - NavigationError.description 与错误码同名，按 rawValue 收敛；
/// - 其余错误原样抛出（D-030：非域错误暂由 UI 通用文案兜底，不伪造业务码）。
enum LiveAPIErrorMapping {
    static func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as GatherError {
            throw error
        } catch let error as DBError {
            if case .message(let message) = error, let code = GatherErrorCode(rawValue: message) {
                throw GatherError(code: code, underlying: message)
            }
            throw error
        } catch let error as NavigationError {
            if let code = GatherErrorCode(rawValue: error.description) {
                throw GatherError(code: code, underlying: error.description)
            }
            throw error
        }
    }

    /// FilterEngine 的字段未知错误带参数（旧命令面 返回 CODE::field）；API 边界
    /// 转成 (code, params)，其余过滤错误保持原样。
    static func mapFilter<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch FilterEngineError.fieldUnknown(let field) {
            throw GatherError(code: .FILTER_FIELD_UNKNOWN, params: ["field": field])
        } catch FilterEngineError.unsupportedOperatorForField(let field, let op) {
            throw GatherError.invalidParameter(
                field: "criteria",
                reason: "unsupported operator \(op) for \(field)"
            )
        }
    }
}

// Cut 3 / 3b-3：JobHandle.drain() 的唯一定义已移到 GatherUI（UI 的页面
// 视图模型也要用它；Host 现成地复用同一扩展）。
