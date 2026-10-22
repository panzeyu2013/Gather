// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/JobOutputs.swift
// Cut 1 / 阶段 1A：JobAPI 的句柄与事件（设计 §3.2：AsyncStream，不用回调）。
//
// 职责：
// - JobHandle：建 job 后的稳定句柄（id + 事件流），取代 executeAsync(completion:)；
// - JobEvent：JobService 事件的最小公共形状（进度 / 终态）。
// 校验归属：无（纯输出）。
//
// 说明：1B 的 LiveJobAPI 负责把 JobService 的进度回调适配成 AsyncStream；
// 事件中心只保留领域变更（不再有 NotificationCenter 的 jobs:progress 双通道）。

import Foundation

public enum JobEvent: Sendable, Equatable {
    case progress(JobProgressUpdate)
    case finished(AnalysisJobData)
}

public struct JobHandle: Sendable {
    public let id: String
    public let events: AsyncStream<JobEvent>

    public init(id: String, events: AsyncStream<JobEvent>) {
        self.id = id
        self.events = events
    }
}
