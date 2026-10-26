// desktop/native/gather-app/Sources/GatherHost/APIs/AppServices.swift
// Cut 1 / 阶段 B1+B2+B3a+B4a+B5a+B6a+B7a：Live API 组合根（session / job /
// settings / photo / asset / album / navigation / culling / face / similarity /
// duplicate / quality / export / metadata / person / template 十七个域）。
//
// 装配只负责“把共享服务包成 Live API”，不重新构造服务实例（JobService 的
// 执行器注册、SettingsService 的缓存都必须与组合根共用同一实例，否则任务不
// 执行 / 设置双缓存；Photo/Album/Navigation 的 Repo 同理，避免第二个数据库连接
// 看到不同快照）。
//
// WP4c：17 个 Live API 工厂已拆到 Composition/FeatureAPIs.swift，装配入口
// 委托 Composition/Root.swift（AppServicesRoot）；9 个零引用可选覆盖参数与
// 9 个 makeX 随之删除。本文件只保留 AppServices 的存储与唯一公开入口
// live(composition:)，不构造服务。
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
import GatherApplication
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
    /// P0 / B0：备份/恢复/诊断（第 17 协议；测试/Preview 可为 nil）。
    public let maintenance: (any MaintenanceAPI)?
    /// Cut 1 / B8.3b-1：宿主运行时（与组合根共用同一 db/JobService/
    /// DeliveryCoordinator 的**唯一**实例）。GatherApp 用它驱动
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
        maintenance: (any MaintenanceAPI)? = nil,
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
        self.maintenance = maintenance
        self.runtime = runtime
    }

    /// 生产装配（B8.3b-2a 起的唯一入口）：全部 Live API 直接包装组合根构造的
    /// 服务/Repo 实例（16 个工厂见 Composition/FeatureAPIs.swift）。
    ///
    /// 本方法不构造业务服务、不打开数据库、不注册 executor：JobService、
    /// SettingsService、PersonRepo、DeliveryRepo 等都是
    /// composition 里的同一份实例（AppRuntime 也来自 composition.runtime）。
    /// WP4c：装配流程委托 Composition/Root.swift（AppServicesRoot）。
    public static func live(composition: AppComposition) -> AppServices {
        AppServicesRoot.make(composition: composition)
    }
}

/// B2 Live API 的共享错误收敛：
/// - 任何 CodedError（PersistenceError / NavigationError / 域枚举）直接取 code，
///   不再按字符串反解 DBError.message；
/// - 其余错误原样抛出（D-030：非域错误由 UI 通用文案兜底，不伪造业务码）。
enum LiveAPIErrorMapping {
    static func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as GatherError {
            throw error
        } catch let error as CodedError {
            // P1-2 / R1：码即类型（PersistenceError / NavigationError / 域枚举）。
            throw GatherError(code: error.code, underlying: String(describing: error))
        }
    }

    /// Live API 的通用错误收敛（B05-5）：GatherError 直传；JobServiceError.jobFailed
    /// 与 DBError.message 的错误码转成 GatherError。无法收敛时返回 nil，交给各 API
    /// 的域臂继续处理（域错误类型不在本函数枚举）。
    static func translateCommon(_ error: Error) -> Error? {
        switch error {
        case let gather as GatherError:
            return gather
        case let coded as CodedError:
            return GatherError(code: coded.code, underlying: String(describing: coded))
        case let job as JobServiceError:
            // allow: string-code（任务失败原因以文本落库 job.error 列，非类型化错误，R1 例外）
            if case .jobFailed(_, let message) = job,
               let code = GatherErrorCode(rawValue: message) {
                return GatherError(code: code, underlying: message)
            }
            return nil
        default:
            return nil
        }
    }

    /// 域臂公共收敛（P2-5）：6 个 Live API 的通用臂已统一在 translateCommon；
    /// 这里再套一层「通用臂优先、域臂兜底、不命中则原样抛」的固定顺序，各 API
    /// 只保留自己的域错误分支（D-030：不伪造业务码）。
    static func translateDomain(
        _ error: Error,
        domain: (Error) -> Error?
    ) -> Error {
        if let common = translateCommon(error) { return common }
        return domain(error) ?? error
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
