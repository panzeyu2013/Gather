// desktop/native/gather-core/Sources/GatherApplication/Services/FaceKwService.swift
// TS 源: desktop/src/main/services/face-kw/face-kw.service.ts（Phase 3.5 移植，
// 全量：analyze / recluster / getClusters / bind / unbind / merge / remove_member /
// preview / writeback / confirmSync / cleanup / cancel）
//
// 移植差异说明（均为有意取舍，行为对账以 TS 单测为基线）：
// - 推理与解码经注入的 inferenceProvider / decodeProvider 接入（对齐
//   SimilarityService 的 thumbnailProvider 模式）。默认 provider 走
//   FaceInferenceEngine（Vision feature print，768 维）与 RAWDecoder；
//   Vision 不可用且未注入时抛 FACE_WORKERS_INIT_FAILED（TS 的 worker init
//   失败聚合路径；Vision 无模型加载，该分支只在缺注入时触发）。
// - TS 的滑动窗口解码预取与 per-worker 背压（MAX_IN_FLIGHT_BATCHES_PER_WORKER）
//   是 sharp/worker 延迟优化；Swift 侧逐张解码、按 decodeWindow 攒批、批内
//   单图失败不拖垮整批（TS worker 语义保留），不做预取（注入解码为纯函数，
//   无去重需求）。face_inference_parallel_workers 仍按 TS 语义读取并轮询分配，
//   但默认 provider 内部共用单引擎（Vision 无 ONNX 线程池可分）。
// - TS 的 fs.stat 区分 ENOENT（缺失照片清理）与其他错误（算检测失败）；Swift
//   用 POSIX stat + errno 复刻该分支。
// - 取消语义对齐 SimilarityService：聚类为同步调用，abort 在聚类返回后补查
//   抛取消（TS worker 可中途拒绝；Swift 更严格，取消不落库）。
// - analysis_runs.params 经 JSONEncoder 编码，键序不保证与 TS JSON.stringify
//   的插入序一致；消费方按 JSON 语义解析。
// - 写回（fkw.unbind 的 removeOwnedFaceKeywords、fkw.preview / writeback）
//   经注入的 FaceWritebackProvider 调用；宿主已注入 WritebackService 适配器。
//   S5c-2b-2 起：writeback 执行后按 xmpPath 镜像 deliveries（module=face-keyword），
//   confirm_sync / confirm_cleanup / cleanup 改由 DeliveryModuleAdapter
//   （module=.faceKeyword）执行。未注入 provider 时 writeback 仍明确抛出
//   WRITEBACK_PROVIDER_NOT_INJECTED，避免误报写回成功。
// - TS 侧 analyze/错误路径会 invalidateSessionLookup（culling 缓存）；Swift
//   侧通过原生挑片页面重新加载 session 数据，保持同进程状态一致。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol


/// TS: FaceKwService（desktop/src/main/services/face-kw/face-kw.service.ts）。
public final class FaceKwService {
    /// TS: onProgress({ current, total, phase })。
    public typealias ProgressHandler = (Int, Int, String) -> Void
    /// TS: imageService.getPreview(filepath, maxDimension, 0, false) → buffer；
    /// 解码失败返回 nil（对应 getPreview reject）。
    public typealias DecodeProvider = (String, Int) async -> Data?
    /// TS: FaceInferenceWorker.analyzeBatch(images, config, signal) →
    /// 逐图 FaceInferenceBatchItem（与输入序对齐；单图失败不拖垮整批）。
    public typealias FaceInferenceProvider = ([Data], FaceInferenceConfig, JobAbortSignal?) async throws -> [FaceInferenceItem]
    /// TS: clusterFacesInWorker（eps/minPts 聚类，同步 CPU 实现）。
    /// options 携带"质量核心点门槛 / 二遍核心点阈值"（竞品对标新增，语义见 FaceClusterOptions）。
    /// 末位参数是 Cut 5 / 5c-2 注入的取消检查闭包（B 阶段调用方 = FaceKwService 的
    /// JobAbortSignal；默认实现把它转发进 FaceClusterer 的 DBSCAN 检查点）。
    public typealias FaceClusterProvider = ([EmbeddingEntry], Double, Int, FaceClusterOptions, ((Int, Int) -> Void)?, (() throws -> Void)?) throws -> FaceClusterResult

    /// 聚类调参（竞品对标：PhotoPrism 的 CLUSTER_CORE / CLUSTER_CORE_RETRY）。
    /// 默认 `disabled` 使既有调用语义逐位不变；服务层按 settings 组装具体值。
    public struct FaceClusterOptions: Sendable {
        /// 只有 quality ≥ 此值的点能成为核心点或扩展簇（0 = 不设门槛）。
        /// 低质量点仍可被吸收为边界点——不会从结果里消失，只是不能"带簇"。
        public var coreQualityFloor: Double
        /// 第二遍核心点 minPts（≥ 2；nil = 关闭）。用于恢复被严格首遍漏掉的小簇。
        public var retryMinSamples: Int?

        public static let disabled = FaceClusterOptions(coreQualityFloor: 0, retryMinSamples: nil)

        public init(coreQualityFloor: Double = 0, retryMinSamples: Int? = nil) {
            self.coreQualityFloor = coreQualityFloor
            self.retryMinSamples = retryMinSamples
        }
    }

    /// TS: MAX_PREVIEW_MEMBERS（getClusters 的成员截断窗口）。
    /// 簇卡片携带的成员上限。仓库层已把成员全量取出（ClusterMember 不含缩略图，
    /// 单条约 250 B），12 ≈ 3 KB/簇，远小于一张预览图；上限只影响**载荷裁剪**，
    /// 不影响聚类/合并/绑定语义（按成员计数的地方都在仓库层）。
    static let maxPreviewMembers = 12

    /// P1-1：仓储依赖一律走 Persistence 端口（any XxxRepository），具体 SQLite
    /// Repo 只在组合根构造；测试可用 fake 替换。
    let photoRepo: any PhotoRepository
    let sessionRepo: any SessionRepository
    let faceRepo: any FaceRepository
    let personRepo: any PersonRepository
    /// WP3b-2：身份反馈、簇成员写、analysis_runs、交付项读取全部下沉到 Persistence；
    /// 事务经 TransactionRunner（嵌套退化为 SAVEPOINT）。
    let feedback: any FaceFeedbackRepository
    let analysisRuns: any AnalysisRunRepository
    let deliveryItems: any DeliveryRepository
    let transactions: any TransactionRunner
    /// TS: SettingsService.getNumber 注入。
    let getNumber: (String, Double) -> Double
    /// TS: SettingsService.get 注入（onnx_provider 等字符串设置）。
    let getString: (String, String) -> String
    /// TS: imageService 注入。
    let decodeProvider: DecodeProvider?
    /// TS: FaceInferenceWorker 注入（默认走 FaceInferenceEngine）。
    let inferenceProvider: FaceInferenceProvider?
    /// TS: clusterFacesInWorker 注入。
    let clusterProvider: FaceClusterProvider
    /// TS: writebackService 注入（3.4 Wave 实现）。
    let writebackProvider: FaceWritebackProvider?
    /// 交付适配器（WP2c：module 固定 .faceKeyword）：writeback 镜像 + confirm/cleanup。
    let delivery: any DeliveryModuleAdapter

    /// TS: controllers（Map<sessionId, AbortController>）。
    var controllers: [String: JobAbortSignal] = [:]
    let controllersLock = NSLock()

    /// F0 复核缓存：key 含 session/cluster/includeResolved/thresholds；value 带
    /// 廉价 DB revision，写入路径变化后 key 版本不匹配即自动 miss。
    struct ReviewCacheEntry {
        let revision: String
        let summaries: [FaceReviewClusterSummary]
        let sortedItems: [FaceReviewItem]
        /// memberId → 在 sortedItems 中的位置：翻页时 O(1) 定位，不再每页 O(n) 扫。
        let indexByMemberId: [Int: Int]
        let suspectTotal: Int
    }
    var reviewCache: [String: ReviewCacheEntry] = [:]
    let reviewCacheLock = NSLock()

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    func controller(for sessionId: String) -> JobAbortSignal? {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        return controllers[sessionId]
    }

    func claimController(_ signal: JobAbortSignal, for sessionId: String) throws {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        guard controllers[sessionId] == nil else { throw FaceKwServiceError.analysisRunning }
        controllers[sessionId] = signal
    }

    func removeControllerIfCurrent(_ signal: JobAbortSignal, for sessionId: String) {
        controllersLock.lock()
        if controllers[sessionId] === signal {
            controllers.removeValue(forKey: sessionId)
        }
        controllersLock.unlock()
    }

    public init(
        photoRepo: any PhotoRepository,
        sessionRepo: any SessionRepository,
        faceRepo: any FaceRepository,
        personRepo: any PersonRepository,
        feedback: any FaceFeedbackRepository,
        analysisRuns: any AnalysisRunRepository,
        deliveryItems: any DeliveryRepository,
        transactions: any TransactionRunner,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        getString: @escaping (String, String) -> String = { _, defaultValue in defaultValue },
        decodeProvider: DecodeProvider? = nil,
        inferenceProvider: FaceInferenceProvider? = nil,
        clusterProvider: @escaping FaceClusterProvider = { entries, eps, minPts, options, onProgress, isCancelled in
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
        delivery: any DeliveryModuleAdapter
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.faceRepo = faceRepo
        self.personRepo = personRepo
        self.feedback = feedback
        self.analysisRuns = analysisRuns
        self.deliveryItems = deliveryItems
        self.transactions = transactions
        self.getNumber = getNumber
        self.getString = getString
        self.decodeProvider = decodeProvider
        self.inferenceProvider = inferenceProvider
        self.clusterProvider = clusterProvider
        self.writebackProvider = writebackProvider
        // WP3b-2：不再按 connection 自建 coordinator（Application 不持 DBConnection）。
        // 组合根注入交付适配器；测试经 ServiceConstructionTestSupport 的兼容 init 装配。
        self.delivery = delivery
    }
}