// desktop/native/gather-app/Sources/GatherHost/APIs/LiveAPIInput.swift
// Live API 的入参校验：原先 6 个 Live API（Duplicate/Face/Similarity/Culling/
// Metadata/Export）各有一份逐字相同的 private requireSessionId；收敛为单一实现，
// 错误码与 reason 文案不变（field: "sessionId" / length ≤128 / 非空白）。
import GatherProtocol

enum LiveAPIInput {
    /// sessionId 入参：长度上限 128，且去空白后不得为空。
    static func requireSessionId(_ value: String) throws -> String {
        guard value.count <= 128 else {
            throw GatherError.invalidParameter(
                field: "sessionId",
                reason: "length must be at most 128"
            )
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: "sessionId", reason: "must not be blank")
        }
        return value
    }
}
