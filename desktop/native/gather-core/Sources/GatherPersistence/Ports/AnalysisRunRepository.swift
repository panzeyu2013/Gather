// desktop/native/gather-core/Sources/GatherPersistence/Ports/AnalysisRunRepository.swift
// WP3b-2：analysis_runs 写端口（分析 run 的 start/finish）。
import Foundation

public protocol AnalysisRunRepository {
    @discardableResult
    func start(
        sessionId: String,
        kind: String,
        photoCount: Int,
        indexSeq: Int,
        paramsJson: String
    ) throws -> Int64
    func finish(runId: Int64, status: String) throws
}

extension AnalysisRunRepo: AnalysisRunRepository {}
