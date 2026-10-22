// desktop/native/gather-app/Sources/GatherHost/JobProgressSourceBridge.swift
// Cut 3 / 3b-3（E-19 #1）：把 GatherDomain 的 JobService 接到 GatherUI 的
// JobProgressSource 端口。
//
// 端口协议声明在 GatherUI（UI 不能 import Domain）；实现留在 GatherHost，
// 这样「进度帧来源」只有一处注入，且 Host → UI 的依赖方向保持单向。
import GatherApplication
import GatherProtocol
import GatherUI

extension JobService: JobProgressSource {
    /// 端口实现：转发到 JobService 的进度 sink（替换语义不变）。
    public func connectProgressSink(
        _ sink: @escaping (AnalysisJobData, JobProgressUpdate) -> Void
    ) {
        setProgressSink(sink)
    }
}
