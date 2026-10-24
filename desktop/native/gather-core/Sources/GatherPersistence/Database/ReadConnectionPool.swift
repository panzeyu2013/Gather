// desktop/native/gather-core/Sources/GatherPersistence/Database/ReadConnectionPool.swift
// R6：只读连接池。WAL 下读不阻塞写；把 UI 的 SELECT 从写连接锁里解耦。
//
// 语义：
// - 只由写连接懒建（首次 SELECT 时，schema 已就绪）；":memory:" 永不建池
//   （每条连接是独立内存库，读会看不到写）；
// - 无空闲连接时 acquire 返回 nil，调用方回退到写连接 —— 正确性优先于并发；
// - busy/cache 预算由 Write 连接的 Database.Options 传入（R6 批 2：读路径不再固定值）；
// - close 只关**空闲**连接；已借出的连接在释放时关闭（不阻塞 shutdown 等在飞 SELECT）。
//
// @unchecked Sendable 依据：available/isClosed 只在 lock 内读写；池内 DBConnection
// 自身以递归锁串行其 SQL。
import Foundation

final class ReadConnectionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [DBConnection]
    private var isClosed = false

    init(
        path: String,
        size: Int,
        busyTimeoutMilliseconds: Int,
        cacheSizeMB: Int
    ) throws {
        precondition(size > 0, "只读池大小必须为正")
        var made: [DBConnection] = []
        do {
            for _ in 0..<size {
                made.append(try DBConnection(
                    path: path,
                    mode: .readOnly,
                    busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                    cacheSizeMB: cacheSizeMB
                ))
            }
        } catch {
            made.forEach { $0.close() }
            throw error
        }
        available = made
    }

    func acquire() -> DBConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !available.isEmpty else { return nil }
        return available.removeLast()
    }

    func release(_ connection: DBConnection) {
        lock.lock()
        if isClosed {
            lock.unlock()
            // close 之后归还：该连接不再入池，直接关闭。
            connection.close()
            return
        }
        available.append(connection)
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let idle = available
        available.removeAll()
        lock.unlock()
        idle.forEach { $0.close() }
    }
}
