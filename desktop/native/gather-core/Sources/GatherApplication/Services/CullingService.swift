// desktop/native/gather-core/Sources/GatherDomain/Services/CullingService.swift
// TS 源: desktop/src/main/services/culling/culling.service.ts（1902 行，逐字移植）
// + culling.ipc.ts（387 行）的命令面（writeback/sync_status/flush/retry_sync/
// finalize_sync/retry_failed_writeback/confirm_sync/cleanup 的确认校验与委托）。
//
// Culling 服务：资产列表（含 RAW/JPEG 变体折叠与 asset 分组分页）、decide
// （星级/标签/关键词选择）、批量操作、summary、history/apply_history（undo/redo
// 历史栈）、reset、写回协作。写回引擎不在此重写——经 CullingWritebackPort
// （WritebackService 已移植接口）注入，测试可注入替身。
//
// S5c-2b-3b-2b-1：旧 MetadataSyncCoordinator 依赖已整段移除（CullingSyncPort
// 协议/扩展删除）。syncStatus/flush/retry/finalize/confirm/cleanup 只走交付模型；
// 同步态读 deliveries（交付行优先），手动 rating/label 的旧 outbox 队列不再读取。
//
// 注入点：
// - CullingWritebackPort = TS WritebackService 的 culling.ipc.ts 用到的最小面
//   （preview/persistAttributes/execute/retryFailed/getItems/confirmSync/cleanup）。
//   文件写入仍由它执行（execute/retryFailed）；getItems 供交付镜像读取行状态。
// - DeliveryModuleAdapter（module=.culling，WP2c 起直接注入）：
//   confirm/cleanup/finalize、syncStatus 读模型、flush/retry 的 replay（engine）、
//   writeback 结果镜像全部走它；交付适配器由组合根注入（本服务不持 connection）。
// - MetadataMutationPort = TS MetadataMutationService（queuePhotoValues）。
// - getNumber = TS SettingsService.getNumber（detect_input_size /
//   face_preview_max_dimension 兜底，测试注入）。
// - cullingHistoryRepo 与 TS 一样是可选依赖（老装配缺省时历史栈禁用）。
//
// 错误消息与 TS 逐字一致：CullingServiceError.description 即 TS `new Error(code)`
// 的 message；CULLING_REVISION_CONFLICT 带 expected/current 插值参数。
//
// 缓存注记：TTL 缓存（sessionLookup/sessionUpdate）与 TS 同语义——主进程单线程
// 同步 SQLite，Swift 侧服务实例同样按会话单线程使用，Map 无需加锁（与
// SimilarityResultRepo 的 photoGroupMapCache 同款决策）。
//
// ── 挑片状态单一真相源（禁止双真相源）────────────────────────────────
// 星级 / 色标：唯一真相源是 photo_metadata_cache（全应用范围的 XMP 投影）。
//   读取（rowToState / list / listPage / getSummary）、写入（updateState /
//   applyHistory）、reset、写回计划全部围绕它；culling_decisions.rating /
//   color_label 只是同事务写下的镜像列，任何读取路径都不得读它们
//   （见 CullingDecisionRepo 文件头注）。
// 取舍（pick/reject/pending）：唯一真相源是 culling_decisions.decision。
//
// ── 侧车/xmp 路径口径（写回内核已冻结）────────────────────────────
// 一切交付键、linkedByXmp 键统一走
// DeliveryPath.sidecar(photo) = TSPath.xmpSidecarPath(ScanPath.canonical(photo))
// （helper 名沿用旧 outbox 命名，但只做路径归一化，不读写旧表）。
// 禁止裸拼 TSPath.xmpSidecarPath（符号链接/相对路径/已是侧车三种输入下与内核键
// 不一致，会查不到行或造出重复行）。

import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

/// TS: CullingService。
public final class CullingService {
    // MARK: - 常量（TS 文件头部）

    /// TS: COLOR_LABELS。
    static let colorLabels: Set<CaptureOneColorLabel> = [
        .none, .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]

    /// TS: PREFERRED_RAW_EXTENSIONS —— RAW 判定只用共享表 PhotoRepo.rawExtensions
    ///（与 preferredRowOrderSQL 里 LIKE 链的同一份数据），本文件不另立扩展名表。
    /// 内存态代表行选择为何不能直接调用 SQL 排序，见 assembleAssets 的注释。
    static let preferredRawExtensions: Set<String> = Set(PhotoRepo.rawExtensions)

    /// TS: LOOKUP_TTL_MS / LOOKUP_CACHE_MAX / UPDATE_TTL_MS / UPDATE_CACHE_MAX。
    static let lookupTTLSeconds: TimeInterval = 5
    static let lookupCacheMax = 8
    static let updateTTLSeconds: TimeInterval = 5
    static let updateCacheMax = 8

    /// TS: withChunkedIds 的分块大小（SQLite 参数上限以内，同其他批量读）。
    private static let chunkSize = 800

    /// TS: culling.ipc.ts 的 limit 校验区间。
    public static let pageLimitMax = 2_000
    public static let batchMax = 10_000

    // MARK: - 依赖

    let photoRepo: PhotoRepo
    let cullingDecisionRepo: CullingDecisionRepo
    let similarityResultRepo: SimilarityResultRepo
    let metadataCacheRepo: MetadataCacheRepo
    /// WP3b-2：分页/计数/富查询 SQL 下沉到 Persistence（CullingPageQuery /
    /// CullingReadQuery）；交付行读取与事务经端口。
    let pageQuery: any CullingPageReading
    let richQuery: any CullingRichReading
    let deliveryItems: any DeliveryRepository
    let transactions: any TransactionRunner
    let metadataMutations: any MetadataMutationPort
    let writeback: any CullingWritebackPort
    /// 交付适配器（WP2c：module 固定 .culling）：confirm/cleanup/finalize/镜像/读模型。
    let delivery: any DeliveryModuleAdapter
    let cullingHistoryRepo: CullingHistoryRepo?
    let getNumber: (String, Double) -> Double

    public init(
        photoRepo: PhotoRepo,
        cullingDecisionRepo: CullingDecisionRepo,
        similarityResultRepo: SimilarityResultRepo,
        metadataCacheRepo: MetadataCacheRepo,
        pageQuery: any CullingPageReading,
        richQuery: any CullingRichReading,
        deliveryItems: any DeliveryRepository,
        transactions: any TransactionRunner,
        metadataMutations: any MetadataMutationPort,
        writeback: any CullingWritebackPort,
        cullingHistoryRepo: CullingHistoryRepo? = nil,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        delivery: any DeliveryModuleAdapter
    ) {
        self.photoRepo = photoRepo
        self.cullingDecisionRepo = cullingDecisionRepo
        self.similarityResultRepo = similarityResultRepo
        self.metadataCacheRepo = metadataCacheRepo
        self.pageQuery = pageQuery
        self.richQuery = richQuery
        self.deliveryItems = deliveryItems
        self.transactions = transactions
        self.metadataMutations = metadataMutations
        self.writeback = writeback
        self.cullingHistoryRepo = cullingHistoryRepo
        self.getNumber = getNumber
        // WP3b-2：不再按 connection 自建 coordinator（Application 不持 DBConnection）。
        // 组合根注入交付适配器；测试经 ServiceConstructionTestSupport 的兼容 init 装配。
        self.delivery = delivery
    }

    // MARK: - 会话查找缓存（TS SessionLookupEntry / SessionUpdateEntry）

    /// TS: sessionLookupCache —— 版本键控的会话查找条目（见 SessionLookupEntry）。
    var sessionLookupCache: [String: SessionLookupEntry] = [:]
    /// TS: sessionUpdateCache —— 会话级更新上下文（见 SessionUpdateEntry）。
    var sessionUpdateCache: [String: SessionUpdateEntry] = [:]
}
