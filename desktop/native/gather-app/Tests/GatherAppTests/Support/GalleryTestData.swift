// desktop/native/gather-app/Tests/GatherAppTests/Support/GalleryTestData.swift
// app 测试共享夹具：空 Gallery 数据端口（task-36 收口）。
//
// 装配 RootShellDependencies / SessionWorkspace / GalleryViewModel 时只需要
// 「存在且不触碰真实库」的 provider：不会话、空页、缩略图桶走协议默认实现。
// 原先 FactoryTests / GalleryFilterSearchStringTests / LayoutBudgetTests /
// ReviewFixTests / StackAndVolumeWiringTests / TestWorkspace 各自复制了同构的
// 私有空桩，统一到本类型；语义不同（记录页请求/统计 status 调用）的
// StubGalleryProvider / CountingGalleryProvider 保留在原文件。
import Foundation
import GatherProtocol
import GatherUI

/// GalleryDataProvider 的最小空实现：getSession → nil，photoPage → 空页。
struct EmptyGalleryProvider: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}
