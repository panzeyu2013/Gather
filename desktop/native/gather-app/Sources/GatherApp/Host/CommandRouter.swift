// Native command boundary shared by SwiftUI pages and the legacy bridge tests.
// It deliberately has no WebKit dependency so the app can build without a
// renderer host.
import Foundation
import GatherCore

public struct WebResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let data: GatherCore.JSONValue?
    public let error: String?

    public init(ok: Bool, data: GatherCore.JSONValue? = nil, error: String? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }
}

/// Swift 6 迁移：完成回调声明为 `@Sendable` —— SessionCommandRouter 的 async 分支
/// 在 `Task { }` 中延后回调（可能跨线程），非 Sendable 的闭包会被并发发送检查拒绝
/// （32 处 [#RegionIsolation::SendingClosureRisksDataRace]）。回调只传值
/// WebResponse（Sendable），加 @Sendable 不改变分发语义与响应信封。
///
/// 路由实现（SessionCommandRouter）在构造后不再变更任何存储属性，
/// 是纯 let 不可变的最终类，跨隔离域传递安全；协议声明为 Sendable 后，持有
/// router 的 Live provider（Gallery/Similarity/Library）经协议继承自动获得
/// Sendable 一致性，无需再逐个标注。
public protocol CommandRouter: Sendable {
    func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue
    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping @Sendable (WebResponse) -> Void
    )
}

/// SessionCommandRouter 的 @unchecked Sendable 依据（GatherCore 中若干服务类型
/// 未标注 Sendable，编译期无法自动验证）：
/// 1) 本类零可变存储属性 —— 全部存储属性（db、sessionService、workspaceStatusService、
///    jobService、photoRepo、settingsService、filterEngine、navigationService、
///    similarityService、duplicateService、assetRepo、faceKwService、personRepo、
///    templateService、qualityService、indexerService、metadataService、
///    metadataSyncCoordinator、metadataMutationService、writebackService、
///    smartAlbumRepo、cullingService、exportService、imagePreloadService）均为
///    不可变 let，仅 init 赋值一次，构造后不再变更；
/// 2) 本类不持有跨调用可变状态，也不在实例字段上缓存请求数据：可变状态都在被注入
///    的 core 服务内部，由各服务自己的具名锁（JobService/WalkChannel/DBConnection
///    等）保护，本类只做命令分发；
/// 3) 故跨隔离域共享本实例不引入新的数据竞争 —— 信任边界是「被注入服务自身线程
///    安全」，与既有 executeAsync 在 DispatchQueue.global 执行同步命令的用法一致。
extension SessionCommandRouter: @unchecked Sendable {}
