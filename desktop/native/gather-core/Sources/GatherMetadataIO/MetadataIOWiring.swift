// desktop/native/gather-core/Sources/GatherMetadataIO/MetadataIOWiring.swift
// 宿主的装配面（#1 Stage 1）。
//
// 为什么需要它：写目标路由（MetadataWriteRouter）是 internal 的——它 conform 到
// XMPProvider 的 8 个 witness 如果全公开，等于把实现细节漏成公开 API。宿主只需要
// 两件事：一个 any XMPProvider，以及「某路径写到哪、算哪种目标」两个只读闭包
// （MetadataTargetResolver 的构造参数就是这两个闭包）。
//
// 因此对外只暴露一个返回闭包组的工厂，而不是类型本身；等 C4/C5 去掉 Application/
// Delivery 依赖后再评估是否升级成协议。
import Foundation
import GatherProtocol

public enum MetadataIOWiring {
    /// 写盘路由器 + 目标解析闭包（Host 用它们构造 Delivery 的 MetadataTargetResolver）。
    ///
    /// - modeProvider: 每次调用都重新读（`metadata_write_mode`），与旧实现一致。
    public static func makeRouter(
        sidecar: SidecarXMPProvider? = nil,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf,
        modeProvider: @escaping @Sendable () -> String = { "sidecar" }
    ) -> (
        xmp: any XMPProvider,
        writePath: @Sendable (String) -> String,
        kind: @Sendable (String) -> MetadataTargetKind
    ) {
        let router = MetadataWriteRouter(
            sidecar: sidecar ?? SidecarXMPProvider(dcSubjectStyle: dcSubjectStyle),
            dcSubjectStyle: dcSubjectStyle,
            modeProvider: modeProvider)
        return (
            router,
            { router.target(for: $0).writePath },
            { router.target(for: $0).kind })
    }
}
