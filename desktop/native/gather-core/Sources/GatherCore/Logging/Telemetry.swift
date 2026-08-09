// desktop/native/gather-core/Sources/GatherCore/Logging/Telemetry.swift
// 轻量遥测（Phase 1 · 任务 1.4）：Swift 侧基准指标采集。
//
// 输出格式对齐 scripts/application-scale-benchmark.mjs：
//  - 该脚本每完成一个 size 即向 stdout 写一行紧凑 JSON（第 243 行
//    `process.stdout.write(`${JSON.stringify({ size, result })}\n`)`），
//    行尾再输出带 host 元信息的聚合对象（第 245 行起）。
//  - Telemetry 沿用"每指标一行紧凑 JSON（NDJSON）"：每条指标独立成行，
//    采集方可逐行 parse，并按 name/tags 归并聚合，与脚本逐行输出的风格一致。
//  - 键名沿用脚本的 camelCase + 单位后缀约定：脚本耗时键为 importMs /
//    firstWindowMs / interactionP95Ms 等，本模块时间戳与 duration 同样
//    以毫秒计（键 tsMs），与脚本字段同量纲。
//  - 脚本 result 内为扁平数值字段；本模块通过 type 字段区分三类指标
//    （duration / counter / gauge），使同一行 schema 可类型化解析。
//
// 开关与线程模型：
//  - 默认关闭；设置环境变量 GATHER_TELEMETRY=1（或 true）开启。
//  - output 可注入，与 GatherLogger 同模式（静态闭包 + NSRecursiveLock）；
//    所有静态可变状态（output / enabledOverride / counters）均受 stateLock
//    保护，emission 持锁进行；measure 的计时 body 不持锁，只读一次开关。
//  - counter 为进程内累加器：count(name:by:) 在锁内累加并输出当前累计值，
//    并发调用由锁串行化，无丢失更新（累计值语义便于基准脚本直接读总数）。

import Dispatch
import Foundation

public enum Telemetry {
    /// 指标类型，对应输出行中的 `type` 字段。
    public enum MetricType: String, Sendable {
        /// 耗时指标，value 为毫秒（Double，单调钟测量）。
        case duration
        /// 计数指标，value 为进程内累计值（Int64）。
        case counter
        /// 一次性快照（gauge），value 为瞬时数值（Double）。
        case gauge
    }

    /// 输出通道，默认 stdout（print）。注入/切换须持有 stateLock。
    public static var output: (String) -> Void = { print($0) }

    /// 内部开关覆盖（测试用）；nil 表示回退到环境变量判断。
    static var enabledOverride: Bool?

    /// 计数器累计表（name+tags 归一化 key → 累计值），仅锁内访问。
    static var counters: [String: Int64] = [:]

    /// 与 GatherLogger.stateLock 同模式：保护 output/enabledOverride/counters。
    /// 测试通过 @testable 访问，并在 capture 期间持有同一把锁。
    static let stateLock = NSRecursiveLock()

    /// 遥测是否开启：优先 enabledOverride，否则读 GATHER_TELEMETRY 环境变量。
    public static var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isEnabledUnlocked()
    }

    /// 包裹耗时：body 成功返回后输出一条 duration 指标（毫秒，单调钟）。
    /// body 抛错时不输出指标，错误原样向上传播。
    public static func measure<T>(
        name: String,
        tags: [String: String] = [:],
        body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        emit(type: .duration, name: name, value: durationMs, tags: tags)
        return result
    }

    /// 计数：进程内按 name(+tags) 累加并输出当前累计值。
    public static func count(
        name: String,
        by: Int64 = 1,
        tags: [String: String] = [:]
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabledUnlocked() else { return }
        let key = counterKey(name: name, tags: tags)
        let total = (counters[key] ?? 0) + by
        counters[key] = total
        if let line = serializeLine(type: .counter, name: name, value: total, tags: tags) {
            output(line)
        }
    }

    /// 一次性快照（gauge）：立即输出一个瞬时数值。
    public static func gauge(
        name: String,
        value: Double,
        tags: [String: String] = [:]
    ) {
        guard isEnabled else { return }
        emit(type: .gauge, name: name, value: value, tags: tags)
    }

    // MARK: - 内部

    private static func isEnabledUnlocked() -> Bool {
        if let override = enabledOverride { return override }
        switch ProcessInfo.processInfo.environment["GATHER_TELEMETRY"]?.lowercased() {
        case "1", "true":
            return true
        default:
            return false
        }
    }

    private static func emit(
        type: MetricType,
        name: String,
        value: Any,
        tags: [String: String]
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabledUnlocked() else { return }
        if let line = serializeLine(type: type, name: name, value: value, tags: tags) {
            output(line)
        }
    }

    private static func serializeLine(
        type: MetricType,
        name: String,
        value: Any,
        tags: [String: String]
    ) -> String? {
        var object: [String: Any] = [
            "name": name,
            "tsMs": Date().timeIntervalSince1970 * 1000,
            "type": type.rawValue,
            "value": value,
        ]
        if !tags.isEmpty {
            object["tags"] = tags
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 计数器 key：name + 排序后的 tags，同 name 不同 tags 各自累计。
    private static func counterKey(name: String, tags: [String: String]) -> String {
        guard !tags.isEmpty else { return name }
        let tagPart = tags
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "\(name)\u{0}\(tagPart)"
    }
}
