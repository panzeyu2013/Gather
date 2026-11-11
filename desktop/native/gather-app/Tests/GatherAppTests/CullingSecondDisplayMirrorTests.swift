// desktop/native/gather-app/Tests/GatherAppTests/CullingSecondDisplayMirrorTests.swift
// Wave4a / B3：第二屏镜像细节贴片的纯逻辑回归（可见性策略 / 几何 / 预算）。
//
// 背景：第二屏此前只画 2560 基准位图再 scaleEffect 放大，共享 zoom>1 时旁屏是糊的，
// "客户在第二屏看 1:1 判合焦"失效。修复后第二屏按与主查看器同一套
// PhotoViewerGeometry/PhotoDetailTier 给可见区细节贴片；第二屏只读（无 hover），
// 因此 >2 格只给当前格贴片。本文件钉住策略、fit 档不贴片、缩放后的几何与预算。
import CoreGraphics
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("第二屏镜像细节贴片（Wave4a B3）", .serialized)
@MainActor
struct CullingSecondDisplayMirrorTests {
    private func asset(_ id: String, width: Int, height: Int) -> CullingAsset {
        var value = b8CullingAsset(id)
        value.photo.width = width
        value.photo.height = height
        return value
    }

    @Test("可见性策略：≤2 格全格贴片；>2 格只当前格（第二屏无 hover）")
    func mirrorTilePolicy() {
        #expect(CullingSecondDisplayMirror.showsTile(visibleCount: 1, isCurrent: false))
        #expect(CullingSecondDisplayMirror.showsTile(visibleCount: 2, isCurrent: false),
                "2 图并排是判焦主战场：两格都要细节")
        #expect(!CullingSecondDisplayMirror.showsTile(visibleCount: 3, isCurrent: false))
        #expect(CullingSecondDisplayMirror.showsTile(visibleCount: 3, isCurrent: true))
        #expect(!CullingSecondDisplayMirror.showsTile(visibleCount: 9, isCurrent: false))
    }

    @Test("与主查看器策略同源：镜像只是把 hover 固定为 false")
    func mirrorPolicyMatchesMainViewer() {
        for visible in [1, 2, 3, 4, 9] {
            #expect(
                CullingSecondDisplayMirror.showsTile(visibleCount: visible, isCurrent: false)
                    == CullingDetailTilePolicy.showsTile(
                        compareCount: visible, isCurrent: false, isHovered: false))
            #expect(
                CullingSecondDisplayMirror.showsTile(visibleCount: visible, isCurrent: true)
                    == CullingDetailTilePolicy.showsTile(
                        compareCount: visible, isCurrent: true, isHovered: false))
        }
    }

    @Test("fit 档不贴片：2560 基准位图已经覆盖屏幕像素")
    func mirrorNoTileAtFit() {
        let image = asset("p1", width: 4000, height: 3000)
        #expect(CullingSecondDisplayMirror.tile(
            asset: image,
            cellSize: CGSize(width: 400, height: 300),
            zoom: 1,
            offset: .zero) == nil)
    }

    @Test("zoom>1：贴片归一化矩形落在图像内且非空")
    func mirrorTileGeometryAtZoom() throws {
        let image = asset("p1", width: 4000, height: 3000)
        let cell = CGSize(width: 400, height: 300)
        let tile = try #require(CullingSecondDisplayMirror.tile(
            asset: image, cellSize: cell, zoom: 8, offset: .zero))
        #expect(tile.viewRect.width > 1 && tile.viewRect.height > 1)
        #expect(tile.normalizedRect.width > 0.05 && tile.normalizedRect.width <= 1)
        #expect(tile.normalizedRect.height > 0.05 && tile.normalizedRect.height <= 1)
        #expect(tile.normalizedRect.minX >= 0 && tile.normalizedRect.minY >= 0)
        #expect(tile.normalizedRect.maxX <= 1.0001 && tile.normalizedRect.maxY <= 1.0001)
        // 可见区贴片必须和单元格相交（否则只是整图矩形，等于没做细节层）。
        let cellRect = CGRect(origin: .zero, size: cell)
        #expect(tile.viewRect.intersects(cellRect))
    }

    @Test("平移会移动可见区贴片（镜像与主窗口共享 offset）")
    func mirrorTileFollowsPan() throws {
        let image = asset("p1", width: 4000, height: 3000)
        let cell = CGSize(width: 400, height: 300)
        let centered = try #require(CullingSecondDisplayMirror.tile(
            asset: image, cellSize: cell, zoom: 8, offset: .zero))
        let panned = try #require(CullingSecondDisplayMirror.tile(
            asset: image, cellSize: cell, zoom: 8, offset: CGSize(width: 80, height: 0)))
        #expect(centered.normalizedRect != panned.normalizedRect,
                "offset 变化必须换一块可见区，否则镜像平移时细节层不动")
    }

    @Test("目标像素受限：预算越小目标越小，且不低于量化下限")
    func mirrorTargetPixelRespectsBudget() throws {
        let image = asset("p1", width: 4000, height: 3000)
        let tile = try #require(CullingSecondDisplayMirror.tile(
            asset: image,
            cellSize: CGSize(width: 400, height: 300),
            zoom: 8,
            offset: .zero))
        let high = CullingSecondDisplayMirror.targetPixel(tile: tile, budgetDimension: 8192)
        let low = CullingSecondDisplayMirror.targetPixel(tile: tile, budgetDimension: 1024)
        #expect(high >= 256)
        #expect(low >= 256)
        #expect(low <= 1024, "预算 1024 必须能夹住目标像素")
        #expect(low <= high, "预算越小、目标像素不应更大")
    }
}
