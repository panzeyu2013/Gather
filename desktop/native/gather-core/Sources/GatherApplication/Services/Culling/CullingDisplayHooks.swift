// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingDisplayHooks.swift
// 挑片域的展示钩子（#6 S8：把 settings 读取与 Triage 展示策略合成一个依赖）。
//
// 为什么合成：两者都是「按需问宿主」的钩子，且都只在读路径用（分页/富化/列表）。
// 合并后决策服务的依赖从 14 降到 13，而两条语义都原样保留。
//
// 为什么是闭包而不是快照：`assembleAssets` 在 `photos.map` **内部**逐张取这两个值，
// 语义是「每次现读设置」。若在装配期求值成 Int，运行中改设置就不再生效——
// 那是行为变更，不在重构范围内。
//
// 为什么 nil 不能折叠成 0：`analysisMax = 0` 会让 `analysisScale = 0`，
// 进而 analysisWidth/Height = 0，老数据的人脸框换算会全部 clamp 成 1.0。
// 所以两个闭包返回 `Int?`，由调用点保留原有默认值。
import Foundation
import GatherProtocol

/// 注意：本类型**不是** Sendable —— `triageDisplayPolicy` 捕获的是 TriageService（不可 Sendable）。
/// 决策服务本身也不是 Sendable，所以持有它没有额外代价；写成 @Sendable 会逼调用方硬包一层。
public struct CullingDisplayHooks {
    /// 检测输入边长（设置 `detect_input_size`）；缺省值由 SettingsKey 的默认值兜底，
    /// 与拆分前的 `settings.int(_:)` 语义一致（那个 API 不会返回 nil）。
    public let detectInputSize: () -> Int
    /// 人脸预览最大边（设置 `face_preview_max_dimension`）。
    public let facePreviewMaxDimension: () -> Int
    /// T0 建议展示策略（nil = 兼容模式：不接 T0 的调用方保持原有读行为）。
    public let triageDisplayPolicy: ((String) throws -> TriageDisplayPolicy)?

    public init(
        detectInputSize: @escaping () -> Int,
        facePreviewMaxDimension: @escaping () -> Int,
        triageDisplayPolicy: ((String) throws -> TriageDisplayPolicy)? = nil
    ) {
        self.detectInputSize = detectInputSize
        self.facePreviewMaxDimension = facePreviewMaxDimension
        self.triageDisplayPolicy = triageDisplayPolicy
    }

    /// 缺省钩子：与拆分前「不注入 settings」等价（默认值来自 SettingsKey）。
    public static var defaults: CullingDisplayHooks {
        let reader = ClosureSettingsReader { _ in nil }
        return CullingDisplayHooks(
            detectInputSize: { reader.int(.detectInputSize) },
            facePreviewMaxDimension: { reader.int(.facePreviewMaxDimension) })
    }

    /// 从设置端口构造：每次调用都经 settings 现读（保持原有的实时语义）。
    public static func live(settings: any SettingsReading) -> CullingDisplayHooks {
        CullingDisplayHooks(
            detectInputSize: { settings.int(.detectInputSize) },
            facePreviewMaxDimension: { settings.int(.facePreviewMaxDimension) })
    }
}
