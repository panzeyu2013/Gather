// desktop/native/gather-app/Sources/GatherHost/SimilarityWritebackBridge.swift
// SimilarityService 的 SimilarityWritebackProvider 适配器（Cut 2 / S5c-2b-3b-1）。
//
// LiveSimilarityAPI 只依赖 SimilarityService；本文件把旧 WritebackService 的
// 相似度写回面接到服务接缝上（module 固定 "similarity"）。S5c-2b-3b-2 删除旧
// 服务时，只把这里的实现换成交付执行器，API 与服务的调用形状不变。
//
// 只做等值搬运，不改 JSON 形状/状态语义。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class SimilarityWritebackBridge: SimilarityWritebackProvider {
    /// 旧写回模块名（落库/summary 的 module 维度）。
    public static let module = "similarity"

    private let writebackService: WritebackService

    public init(writebackService: WritebackService) {
        self.writebackService = writebackService
    }

    public func preview(sessionId: String) async throws -> WritebackPreview {
        try await writebackService.preview(sessionId: sessionId, module: Self.module)
    }

    public func persistKeywords(items: [WritebackItem]) throws {
        try writebackService.persistKeywords(items: items)
    }

    public func getItems(sessionId: String, status: String?) throws -> [WritebackItem] {
        try writebackService.getItems(sessionId: sessionId, module: Self.module, status: status)
    }

    public func execute(sessionId: String, items: [WritebackItem]) async throws -> WritebackResult {
        try await writebackService.execute(sessionId: sessionId, module: Self.module, items: items)
    }

    public func retryFailed(sessionId: String) async throws -> WritebackResult {
        try await writebackService.retryFailed(sessionId: sessionId, module: Self.module)
    }
}
