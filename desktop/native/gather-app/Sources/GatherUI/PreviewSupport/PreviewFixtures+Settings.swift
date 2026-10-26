#if DEBUG
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Settings.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（设置 / ML 状态）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 设置（Settings）

    static let settings: [String: String] = [
        "ui_language": "zh-CN",
        "face_compute_units": "auto",
        "thumbnail_size": "1024",
        "thumbnail_quality": "85",
        "disk_cache_dir": "/Users/preview/Library/Caches/Gather/Thumbnails",
        "db_cache_size_mb": "64",
        "db_synchronous": "normal",
        "metadata_write_mode": "xmp",
        "detect_confidence": "0.5",
        "default_eps": "0.65",
        "default_min_samples": "2",
        "face_decode_concurrency": "4",
        "face_core_quality": "0.35",
        "face_core_retry_min_samples": "2",
        "face_match_margin": "0.01",
        "face_embedding_model_path": "",
        "face_embedding_model_version": "sface-1.0",
        "face_incremental_clustering": "1",
    ]

    static let mlStatus = MLStatusData(
        platform: "macOS",
        autoBackend: "coreml",
        autoBackendLabel: "Core ML",
        provider: "vision",
        isAuto: true,
        availableBackends: [
            MLBackendOption(value: "auto", label: "自动"),
            MLBackendOption(value: "coreml", label: "Core ML"),
            MLBackendOption(value: "onnx", label: "ONNX Runtime"),
        ],
        modelResourcesDir: "/Applications/Gather.app/Contents/Resources/Models",
        detectorModel: MLModelPresence(
            path: "face_detector.mlmodelc",
            resolvedPath: "/Applications/Gather.app/Contents/Resources/Models/face_detector.mlmodelc",
            exists: true
        ),
        encoderModel: MLModelPresence(
            path: "sface.mlmodelc",
            resolvedPath: "/Applications/Gather.app/Contents/Resources/Models/sface.mlmodelc",
            exists: true
        ),
        modelInfo: MLModelInfo(
            detectInputSize: 640,
            secondaryDetectInputSize: 320,
            previewMaxDimension: 2048,
            encoderInputSize: 112,
            embeddingDim: 128
        )
    )
}
#endif
