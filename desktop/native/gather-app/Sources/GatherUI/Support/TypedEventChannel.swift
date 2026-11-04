// desktop/native/gather-app/Sources/GatherUI/Support/TypedEventChannel.swift
// 类型化事件通道（#11 第二步）：把「字符串通道名 + Any 载荷」收成「一类型一通道」。
//
// 为什么不上自研 EventBus：调研结论是收益等价、代价高一个数量级（20+ 文件重写、
// 8 个测试要改、每个 VM 都得接替身）。这里只把**类型**补齐，传输仍是
// NotificationCenter——所以现有的观察者、测试直发、@MainActor 语义全部不变。
//
// 唯一的强制转型收在这一个文件里：名字与载荷类型在构造时绑定，as? 结构性不可能失败。
// 将来真要换 EventBus，只需把 publisher 换成 PassthroughSubject，17 个消费点一行不改。
import Combine
import Foundation

public struct TypedEventChannel<Payload: Sendable>: Sendable {
    public let name: Notification.Name

    public init(_ name: Notification.Name) {
        self.name = name
    }

    /// 强类型发布。
    public func post(_ payload: Payload) {
        NotificationCenter.default.post(name: name, object: payload)
    }

    /// 强类型订阅：消费端拿到的就是 Payload，不再需要 `as?` 下转。
    public var publisher: AnyPublisher<Payload, Never> {
        NotificationCenter.default.publisher(for: name).compactMap { $0.object as? Payload }
            .eraseToAnyPublisher()
    }
}
