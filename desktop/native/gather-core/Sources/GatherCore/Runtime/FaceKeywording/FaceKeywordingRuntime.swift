// desktop/native/gather-core/Sources/GatherCore/Runtime/FaceKeywording/FaceKeywordingRuntime.swift
// W2d-6 步骤②：FaceKeywordingRuntime actor 最小骨架（签署接口；行为随后续
// 步骤自 Services/FaceKwService.swift 迁入）。
//
// 边界（逐步填充）：
// - 本文件零 SQL、零文件系统调用、不持有数据库连接类型（设计文档门禁：
//   Runtime/** 不得出现 SQL 文本或连接对象）；后续写库一律经 Store 协议。
// - 依赖经 Dependencies 值类型注入；四个 Store 协议均继承 Sendable，设置
//   读取闭包为 @Sendable，故 Dependencies 可安全跨 actor 边界传递。
// - 纯逻辑（聚类入口/签名/缓存判定等）已下沉 Runtime/FaceKeywording/
//   FaceKeywordAssembler.swift；本 actor 只负责编排与 Store 往返。
// - 契约类型复用 Services/FaceKwService.swift 的公开定义
//   （FaceAnalysisResult）；错误用本文件新增的最小 FaceKeywordingRuntimeError，
//   与 IndexerRuntimeError 同构（骨架期只有 notImplemented 类目）。
//
// 迁移计划（仅记录，不在本步骤实现）：
// - analyze / recluster / getClusters / bind / unbind / merge / remove_member /
//   preview / writeback / confirmSync / cleanup / cancel 依次迁入；迁入完成前
//   Services/FaceKwService.swift 保持唯一行为来源。

import Foundation

/// 人脸关键词运行时错误（骨架期占位；实现迁入后按需增删）。
public enum FaceKeywordingRuntimeError: Error, Equatable {
    /// 入口已签署、行为尚未迁入（operation 为入口名，便于对账测试断言）。
    case notImplemented(operation: String)
}

/// 人脸关键词运行时（actor 骨架；迁入完成前行为仍由 FaceKwService 承担）。
public actor FaceKeywordingRuntime {
    /// 运行时依赖（对齐旧服务构造参数并去掉写库细节：不含数据库连接类型，
    /// 需要的读写一律经 Store 协议）。
    public struct Dependencies: Sendable {
        public let photoStore: any PhotoStore
        public let sessionStore: any SessionStore
        public let faceStore: any FaceStore
        public let personStore: any PersonStore
        /// 设置读取（旧服务的 getNumber 注入；默认回退 defaultValue）。
        public let getNumber: @Sendable (String, Double) -> Double
        /// 设置读取（旧服务的 getString 注入；默认回退 defaultValue）。
        public let getString: @Sendable (String, String) -> String

        public init(
            photoStore: any PhotoStore,
            sessionStore: any SessionStore,
            faceStore: any FaceStore,
            personStore: any PersonStore,
            getNumber: @escaping @Sendable (String, Double) -> Double = { _, defaultValue in defaultValue },
            getString: @escaping @Sendable (String, String) -> String = { _, defaultValue in defaultValue }
        ) {
            self.photoStore = photoStore
            self.sessionStore = sessionStore
            self.faceStore = faceStore
            self.personStore = personStore
            self.getNumber = getNumber
            self.getString = getString
        }
    }

    private let deps: Dependencies

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// TS: analyze（fkw.analyze）。骨架期只签署签名并抛 notImplemented；
    /// 行为随 W2d-6 后续步骤自 FaceKwService.analyze 迁入。
    public func analyze(
        sessionId: String,
        detectorPath: String,
        encoderPath: String,
        eps: Double? = nil,
        minPts: Double? = nil
    ) async throws -> FaceAnalysisResult {
        throw FaceKeywordingRuntimeError.notImplemented(operation: "analyze")
    }
}
