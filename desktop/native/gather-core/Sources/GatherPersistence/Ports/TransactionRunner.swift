// desktop/native/gather-core/Sources/GatherPersistence/Ports/TransactionRunner.swift
// WP3b-1：事务边界端口。
//
// 应用服务需要在多个 Repository 调用之间保持原子性（会话级联删除、批量决策、
// 分析结果落库）。这些场景不应让 Application 重新持有 DBConnection，也不应把
// 业务编排搬进 Persistence；因此只注入一个「事务作用域」能力：
//
//   - DBConnection 是唯一实现（单连接 + NSRecursiveLock + SAVEPOINT 嵌套）。
//   - 端口故意不暴露 prepare/exec/query：Application 无法借此重新长回 SQL。
//   - 事务体内仍只调用 Repository 方法；嵌套事务退化为 SAVEPOINT，语义与
//     SessionService/SimilarityService 旧实现一致。
/// #8：加 Sendable——Application 的 Sendable 值类型（CurationService）要把它存成字段。
/// 唯一生产实现 DBConnection 已是 @unchecked Sendable；测试 fake 用锁盒实现真正的
/// Sendable，避免再吃掉 @unchecked 的 cleanup 预算。
public protocol TransactionRunner: Sendable {
    func transaction<T>(_ body: () throws -> T) throws -> T
}

extension DBConnection: TransactionRunner {
    /// 端口要求的最简签名；转发到带 file/line 的诊断重载。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(body, file: #fileID, line: #line, function: #function)
    }
}
