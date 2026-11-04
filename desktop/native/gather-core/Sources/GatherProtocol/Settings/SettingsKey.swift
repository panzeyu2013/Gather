// desktop/native/gather-core/Sources/GatherProtocol/Settings/SettingsKey.swift
// 设置键的单一真相源（#9 / SettingsPort 地基）。
//
// 为什么需要：设置键此前是 73 个字符串字面量，散落在 5 个模块、21 个闭包注入点、
// 38 个 Host 调用点、36 个测试注入点；默认值重复 73 份，且已经漂了 3 处
// （default_eps 调用点 0.6 vs 注册表 0.65、embedding_dim 调用点 512 vs 128）。
// 键一旦有类型，「拼错键名」从运行期静默（get 回落默认值、set 抛 unknownKey）
// 变成编译错误；默认值也能从「谁写着算谁」收敛到唯一一张表。
//
// 归属 GatherProtocol：这是唯一能被 GatherPersistence（DB 读 PRAGMA）、
// GatherApplication（服务读参数）与 GatherUI（设置页）同时 import 的最底层。
// 放 Persistence 会让 UI 无法 import（check-layering.sh 明令）。
//
// 覆盖范围：与 SettingsService.getDefaults() 的 68 个已注册键一一对应。
// 5 个「幽灵键」（import_concurrency / asset_read_mode / similarity_* 三个）
// 仍不在本枚举内 —— 它们今天不可写（set 抛 unknownKey），转正会改变 set 语义，
// 属于独立决策，不混进这次纯重构。
import Foundation

/// settings 表的键（TEXT 主键）。
///
/// rawValue 必须与库里的字符串逐字一致（老库/脚本直接改库的场景）。
/// 新增键：加 case + 在 defaultValue 里给默认值（switch 穷尽，漏写编译不过），
/// 再在 SettingsService 的 reset scope 分类里登记（否则 resetScope 返回 nil，
/// reset 会 fail-closed 保留现值，SettingsServiceTests 会红）。
public enum SettingsKey: String, CaseIterable, Sendable, Hashable {
    case detectorModelPath = "detector_model_path"
    case encoderModelPath = "encoder_model_path"
    case detectConfidence = "detect_confidence"
    case detectInputSize = "detect_input_size"
    case detectSecondaryInputSize = "detect_secondary_input_size"
    case facePreviewMaxDimension = "face_preview_max_dimension"
    case encoderInputSize = "encoder_input_size"
    case embeddingDim = "embedding_dim"
    case faceComputeUnits = "face_compute_units"
    case defaultEps = "default_eps"
    case defaultMinSamples = "default_min_samples"
    case faceCoreQuality = "face_core_quality"
    case faceCoreRetryMinSamples = "face_core_retry_min_samples"
    case faceMatchMargin = "face_match_margin"
    case faceReviewCohesionFloor = "face_review_cohesion_floor"
    case faceReviewRelativeMAD = "face_review_relative_mad"
    case faceReviewMinQuality = "face_review_min_quality"
    case faceReviewFaceSizeMin = "face_review_face_size_min"
    case faceIncrementalClustering = "face_incremental_clustering"
    case faceEmbeddingModelPath = "face_embedding_model_path"
    case faceEmbeddingModelVersion = "face_embedding_model_version"
    case nmsThreshold = "nms_threshold"
    case maxDetections = "max_detections"
    case onnxThreads = "onnx_threads"
    case defaultThreshold = "default_threshold"
    case defaultMinGroupSize = "default_min_group_size"
    case modelDownloadURL = "model_download_url"
    case thumbnailSize = "thumbnail_size"
    case thumbnailQuality = "thumbnail_quality"
    case diskCacheDir = "disk_cache_dir"
    case faceDecodeConcurrency = "face_decode_concurrency"
    case faceInferenceParallelWorkers = "face_inference_parallel_workers"
    case dbCacheSizeMB = "db_cache_size_mb"
    case dbSynchronous = "db_synchronous"
    case metadataWriteMode = "metadata_write_mode"
    case uiLanguage = "ui_language"
    case lazyChecksum = "lazy_checksum"
    case gridDefaultSort = "grid_default_sort"
    case gridDensity = "grid_density"
    case triageEnabled = "triage_enabled"
    case outputRecipes = "output.recipes"
    case outputDeliveryRoot = "output.deliveryRoot"
    case triageModelReview = "triage_model_review"
    case triageAutoApply = "triage_auto_apply"
    case triageAutoGenerate = "triage_auto_generate"
    case triagePolicy = "triage_policy"
    case triageKeepConfidenceMin = "triage_keep_confidence_min"
    case triageRejectConfidenceMin = "triage_reject_confidence_min"
    case triageMinExecutableConfidence = "triage_min_executable_confidence"
    case metadataTemplates = "metadata.templates"
    case metadataTemplatesCorrupt = "metadata.templates.corrupt"
    case metadataApplyBatches = "metadata.applyBatches"
    case metadataApplyBatchesCorrupt = "metadata.applyBatches.corrupt"
    case watchLastEventIDs = "watch.lastEventIDs"
    case backupDir = "backup_dir"
    case backupRetention = "backup_retention"
    case backupAuto = "backup_auto"
    case diagnosticsIncludePaths = "diagnostics_include_paths"
    case metadataBackupRetentionDays = "metadata_backup_retention_days"
    case metadataSyncAutoConfirm = "metadata_sync_auto_confirm"
    case metadataSyncAutoFinalize = "metadata_sync_auto_finalize"
    case embeddedFastPath = "embedded_fast_path"
    case keywordDCSubjectStyle = "keyword_dc_style"
    case gallerySavedSearchLimit = "gallery_saved_search_limit"
    case proofFeedbackApplyRating = "proof_feedback_apply_rating"
    case c1AutoReload = "c1_auto_reload"
    case triageCalibrationMinSamples = "triage_calibration_min_samples"
    case semanticIndexEnabled = "semantic_index_enabled"

    // MARK: - #9 转正：原先只读不写的「幽灵键」
    //
    // 这 5 个键此前不在默认值表里，于是 set() 必抛 unknownKey、UI 也改不了，
    // 生产读到的永远是调用点硬编码的默认值——等于一个不可配置的常量。
    // 转正后它们与其它键同权（可写、可 reset、进 getAll），
    // 默认值取调用点此前的硬编码值（行为不变，只是从此真的可配置）。
    case importConcurrency = "import_concurrency"
    case assetReadMode = "asset_read_mode"
    case similarityClusterConvergenceInterval = "similarity_cluster_convergence_interval"
    case similarityDecodeConcurrency = "similarity_decode_concurrency"
    case similarityPreviewMaxDimension = "similarity_preview_max_dimension"

    /// 缺省值：settings 表是 TEXT，默认值一律以字符串形态保存（与旧
    /// SettingsService.getDefaults() 逐字一致）。
    ///
    /// 为什么挂在 case 上而不是独立表：读取点必须在「键未设置」时回落到默认值，
    /// 独立表会让「新增 case 忘记登记默认值」退化成空字符串而不是编译错误。
    public var defaultValue: String {
        switch self {
        case .detectorModelPath: "models/face_detector.onnx"
        case .encoderModelPath: "models/face_encoder.onnx"
        case .detectConfidence: "0.5"
        case .detectInputSize: "640"
        case .detectSecondaryInputSize: "128"
        case .facePreviewMaxDimension: "2048"
        case .encoderInputSize: "112"
        case .embeddingDim: "128"
        case .faceComputeUnits: "auto"
        case .defaultEps: "0.65"
        case .defaultMinSamples: "2"
        case .faceCoreQuality: "0.35"
        case .faceCoreRetryMinSamples: "2"
        case .faceMatchMargin: "0.01"
        case .faceReviewCohesionFloor: "0.35"
        case .faceReviewRelativeMAD: "2.5"
        case .faceReviewMinQuality: "0.35"
        case .faceReviewFaceSizeMin: "48"
        case .faceIncrementalClustering: "1"
        case .faceEmbeddingModelPath: ""
        case .faceEmbeddingModelVersion: ""
        case .nmsThreshold: "0.4"
        case .maxDetections: "100"
        case .onnxThreads: "4"
        case .defaultThreshold: "10"
        case .defaultMinGroupSize: "2"
        case .modelDownloadURL: ""
        case .thumbnailSize: "1024"
        case .thumbnailQuality: "80"
        case .diskCacheDir: ""
        case .faceDecodeConcurrency: "4"
        case .faceInferenceParallelWorkers: "1"
        case .dbCacheSizeMB: "64"
        case .dbSynchronous: "normal"
        case .metadataWriteMode: "auto"
        case .uiLanguage: ""
        case .lazyChecksum: "true"
        case .gridDefaultSort: "import"
        case .gridDensity: "m"
        case .triageEnabled: "0"
        case .outputRecipes: ""
        case .outputDeliveryRoot: ""
        case .triageModelReview: "1"
        case .triageAutoApply: "0"
        case .triageAutoGenerate: "0"
        case .triagePolicy: "triage-v2"
        case .triageKeepConfidenceMin: "0.60"
        case .triageRejectConfidenceMin: "0.75"
        case .triageMinExecutableConfidence: "0.55"
        case .metadataTemplates: "[]"
        case .metadataTemplatesCorrupt: ""
        case .metadataApplyBatches: "[]"
        case .metadataApplyBatchesCorrupt: ""
        case .watchLastEventIDs: "{}"
        case .backupDir: ""
        case .backupRetention: "5"
        case .backupAuto: "off"
        case .diagnosticsIncludePaths: "0"
        case .metadataBackupRetentionDays: "7"
        case .metadataSyncAutoConfirm: "1"
        case .metadataSyncAutoFinalize: "0"
        case .embeddedFastPath: "1"
        case .keywordDCSubjectStyle: "leaf"
        case .gallerySavedSearchLimit: "50"
        case .proofFeedbackApplyRating: "0"
        case .c1AutoReload: "1"
        case .triageCalibrationMinSamples: "50"
        case .semanticIndexEnabled: "0"
        case .importConcurrency: "8"
        case .assetReadMode: "dual"
        case .similarityClusterConvergenceInterval: "10"
        case .similarityDecodeConcurrency: "4"
        case .similarityPreviewMaxDimension: "256"
        }
    }
}
