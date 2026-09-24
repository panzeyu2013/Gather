// desktop/native/gather-app/Sources/GatherApp/App/MLStatusBuilder.swift
// settings.get_ml_status 的宿主侧实现：把设置快照 + 模型文件探测投影为协议 DTO。
// 逻辑自旧宿主路由层原样搬迁（平台/后端/模型路径探测语义不变）。
import Foundation
import GatherCore

enum MLStatusBuilder {
    /// TS settings.get_ml_status：平台 = darwin；auto 后端 = coreml；
    /// 模型存在性按 resolveModelPath 解析后的路径探测。
    static func build(settings: SettingsSnapshot) -> MLStatusData {
        let provider = settings.value("onnx_provider", default: "auto")
        let modelsDir = modelResourcesDir()
        let detectorPath = settings.value("detector_model_path", default: "models/face_detector.onnx")
        let encoderPath = settings.value("encoder_model_path", default: "models/face_encoder.onnx")
        let detectorResolved = resolveModelPath(detectorPath, modelsDir: modelsDir)
        let encoderResolved = resolveModelPath(encoderPath, modelsDir: modelsDir)
        return MLStatusData(
            platform: "darwin",
            autoBackend: "coreml",
            autoBackendLabel: GatherLocalization.l("CoreML（失败自动回退 CPU）"),
            provider: provider,
            isAuto: provider == "auto",
            availableBackends: [
                MLBackendOption(value: "coreml", label: "CoreML"),
                MLBackendOption(value: "cpu", label: "CPU"),
            ],
            modelResourcesDir: modelsDir,
            detectorModel: MLModelPresence(
                path: detectorPath,
                resolvedPath: detectorResolved,
                exists: modelUsable(detectorResolved)
            ),
            encoderModel: MLModelPresence(
                path: encoderPath,
                resolvedPath: encoderResolved,
                exists: modelUsable(encoderResolved)
            ),
            modelInfo: MLModelInfo(
                detectInputSize: Int(settings.number("detect_input_size", default: 640)),
                secondaryDetectInputSize: Int(settings.number("detect_secondary_input_size", default: 128)),
                previewMaxDimension: Int(settings.number("face_preview_max_dimension", default: 2048)),
                encoderInputSize: Int(settings.number("encoder_input_size", default: 112)),
                embeddingDim: Int(settings.number("embedding_dim", default: 512))
            )
        )
    }

    /// TS provider.ts getModelResourcesDir：userData/models（best-effort 创建）。
    private static func modelResourcesDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Gather/models", isDirectory: true).path ?? "models"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// TS provider.ts resolveModelPath：绝对路径直取；相对路径依次尝试
    /// userData/models/<filename>（resourcesPath 候选 Swift 无等价物，跳过）。
    private static func resolveModelPath(_ modelPath: String, modelsDir: String) -> String {
        if modelPath.hasPrefix("/") { return modelPath }
        if FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath).standardizedFileURL.path
        }
        let filename = modelPath.replacingOccurrences(
            of: "^models[/\\\\]",
            with: "",
            options: .regularExpression
        )
        return (modelsDir as NSString).appendingPathComponent(filename)
    }

    /// TS provider.ts modelIsUsable（isValidOnnxModel）的近似：存在且非零字节。
    private static func modelUsable(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }
}
