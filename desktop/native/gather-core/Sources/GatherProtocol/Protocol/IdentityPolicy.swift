import Foundation

/// Identity decisions are independent of detection, clustering and storage.
/// A rejected runner-up still competes: acceptance thresholds must not erase ambiguity.
public enum FaceIdentityPolicy {
    public enum Decision: Equatable, Sendable {
        case accepted(personId: String, score: Double)
        case ambiguous
        case unknown
    }

    public static func decide(scores: [String: Double], thresholds: [String: Double],
                              defaultThreshold: Double = 0.65, margin: Double = 0.01) -> Decision {
        let ranked = scores.filter { $0.value.isFinite }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let winner = ranked.first,
              winner.value >= (thresholds[winner.key] ?? defaultThreshold) else { return .unknown }
        // 设计不变量（测试钉住）：被拒绝的亚军仍参与歧义判定——验收阈值不得
        // 抹掉“存在相近候选”这一事实，否则会出现过度自信的自动绑定。
        if ranked.count > 1, winner.value - ranked[1].value < max(0, margin) { return .ambiguous }
        return .accepted(personId: winner.key, score: winner.value)
    }

    /// Geometry survives observation row replacement and changes in model dimension.
    public static func overlap(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == 4, rhs.count == 4,
              (lhs + rhs).allSatisfy(\.isFinite), lhs[2] > 0, lhs[3] > 0,
              rhs[2] > 0, rhs[3] > 0 else { return 0 }
        let width = max(0, min(lhs[0] + lhs[2], rhs[0] + rhs[2]) - max(lhs[0], rhs[0]))
        let height = max(0, min(lhs[1] + lhs[3], rhs[1] + rhs[3]) - max(lhs[1], rhs[1]))
        let intersection = width * height
        return intersection / max(.leastNonzeroMagnitude, lhs[2] * lhs[3] + rhs[2] * rhs[3] - intersection)
    }

    public static func modelSpace(analysisSignature: String) -> String {
        guard let parsed = try? JSONValue.parse(analysisSignature) else { return "" }
        return parsed["embeddingSpec"]?.stringValue ?? ""
    }
}
