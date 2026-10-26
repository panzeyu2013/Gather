// desktop/native/gather-core/Sources/GatherPersistence/Support/BestEffort.swift
// P0 / B0：best-effort 文件/状态操作的统一收敛点。
//
// 目的：把「失败不致命、但必须可观测」的操作从调用点的 try? 收敛到一处，
// 用 do/catch + 日志替代静默吞错；关键路径（备份/恢复校验）仍必须 throws。
import Foundation
import GatherProtocol

public enum BestEffort {
    /// 执行一个不致命操作；失败只记 warn 日志，返回是否成功。
    @discardableResult
    public static func attempt(_ operation: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            log(operation, error: error)
            return false
        }
    }

    /// 返回可选值；失败记日志并返回 nil。
    public static func optional<T>(_ operation: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            log(operation, error: error)
            return nil
        }
    }

    /// 返回默认值；失败记日志。
    public static func value<T>(_ operation: String, default fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            log(operation, error: error)
            return fallback
        }
    }

    /// 异步不致命操作；取消不记日志。
    public static func run(_ operation: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch is CancellationError {
            // 取消是正常路径。
        } catch {
            log(operation, error: error)
        }
    }

    /// 可取消的等待；取消不记日志。
    public static func sleep(seconds: Double) async {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch is CancellationError {
        } catch {
            log("sleep", error: error)
        }
    }

    public static func pause(milliseconds: Int) async {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch is CancellationError {
        } catch {
            log("pause", error: error)
        }
    }

    private static func log(_ operation: String, error: Error) {
        GatherLogger.log("best_effort_failed op=\(operation) error=\(error)", level: .warn)
    }
}
