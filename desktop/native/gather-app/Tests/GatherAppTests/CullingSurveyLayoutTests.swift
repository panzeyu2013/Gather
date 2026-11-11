// desktop/native/gather-app/Tests/GatherAppTests/CullingSurveyLayoutTests.swift
// Wave2（20-culling-browse #3/#6/#7/#8）：对比多格贴片 + 3 图/Survey + 叠加层键位。
//
// 本批改动的四块纯逻辑都在这里钉住（视图层只做接线，不再复述公式）：
// 1) CullingLayoutMode：compare3 / survey 的固定格数 vs 选择集驱动格数；
// 2) CullingViewerGridLayout：1/2/3/4/Survey 的列行数与单格尺寸；
// 3) CullingComparison.surveyAssets：Survey 的选片规则（选择集优先、回退邻接、上限 9）；
// 4) CullingDetailTilePolicy / PhotoDetailTier.budget：多格贴片可见性与解码预算；
// 5) CullingViewerShortcutKey：H/F/R/C 键位（⇧F = 专注模式，裸 F = 合焦掩膜）。
import CoreGraphics
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("Survey/3 图布局与对比选片（Wave2）", .serialized)
@MainActor
struct CullingSurveyLayoutTests {
    private func makeAssets(_ ids: [String]) -> [CullingAsset] {
        ids.map { b8CullingAsset($0) }
    }

    // MARK: - 布局枚举

    @Test("布局枚举：3 图/多图进入 allCases，固定格数与 Survey 动态格数分开")
    func layoutEnum() {
        #expect(CullingLayoutMode.allCases == [
            .single, .compare2, .compare3, .compare4, .survey, .grid,
        ])
        #expect(CullingLayoutMode.compare3.compareCount == 3)
        #expect(CullingLayoutMode.compare3.fixedCompareCount == 3)
        #expect(CullingLayoutMode.survey.fixedCompareCount == nil)
        #expect(CullingLayoutMode.survey.compareCount == 2, "无选择集信息时兜底至少 2 张")
        #expect(CullingLayoutMode.compare2.effectiveCompareCount(selectionCount: 9) == 2,
                "2/3/4 图不受选择集影响")
        #expect(CullingLayoutMode.compare4.effectiveCompareCount(selectionCount: 0) == 4)
    }

    @Test("Survey 有效格数：选择集驱动，夹在 2...9")
    func surveyEffectiveCount() {
        #expect(CullingLayoutMode.survey.effectiveCompareCount(selectionCount: 0) == 2)
        #expect(CullingLayoutMode.survey.effectiveCompareCount(selectionCount: 1) == 2)
        #expect(CullingLayoutMode.survey.effectiveCompareCount(selectionCount: 5) == 5)
        #expect(CullingLayoutMode.survey.effectiveCompareCount(selectionCount: 12) == 9)
    }

    @Test("布局元数据：每个分支都有标题 key 与 SF Symbol")
    func layoutMetadata() {
        for mode in CullingLayoutMode.allCases {
            #expect(!mode.titleKey.isEmpty, "\(mode.rawValue) 缺标题 key")
            #expect(!mode.systemImage.isEmpty, "\(mode.rawValue) 缺图标")
        }
    }

    // MARK: - 查看器网格换算

    @Test("网格列/行：1 张 1 列、2 张并排、3 张三列、4 张 2×2、Survey 最多 3 列")
    func gridColumnsRows() {
        #expect(CullingViewerGridLayout.columns(for: 1) == 1)
        #expect(CullingViewerGridLayout.columns(for: 2) == 2)
        #expect(CullingViewerGridLayout.columns(for: 3) == 3, "3 图必须是三列（旧的 2+1 不对称布局）")
        #expect(CullingViewerGridLayout.columns(for: 4) == 2)
        #expect(CullingViewerGridLayout.columns(for: 9) == 3)

        #expect(CullingViewerGridLayout.rows(for: 1) == 1)
        #expect(CullingViewerGridLayout.rows(for: 2) == 1)
        #expect(CullingViewerGridLayout.rows(for: 3) == 1, "3 图一排三格")
        #expect(CullingViewerGridLayout.rows(for: 4) == 2)
        #expect(CullingViewerGridLayout.rows(for: 5) == 2)
        #expect(CullingViewerGridLayout.rows(for: 9) == 3)
    }

    @Test("单格尺寸：容器减去间距后均分，退化输入钳到 ≥1pt")
    func gridCellSize() {
        let size = CullingViewerGridLayout.cellSize(
            container: CGSize(width: 1000, height: 600),
            columns: 3,
            rows: 2,
            spacing: 8
        )
        #expect(abs(size.width - 328) < 0.001, "3 列： (1000 − 2×8)/3 = 328")
        #expect(abs(size.height - 296) < 0.001, "2 行： (600 − 8)/2 = 296")

        let single = CullingViewerGridLayout.cellSize(
            container: CGSize(width: 800, height: 500), columns: 1, rows: 1, spacing: 8
        )
        #expect(single == CGSize(width: 800, height: 500), "1 格不扣间距")

        let degenerate = CullingViewerGridLayout.cellSize(
            container: .zero, columns: 3, rows: 3, spacing: 8
        )
        #expect(degenerate.width >= 1 && degenerate.height >= 1, "空容器也要给合法尺寸")
    }

    // MARK: - Survey 选片

    @Test("Survey：显式选择按页内顺序展示，当前照片未被选中时补在首位")
    func surveyUsesSelection() {
        let assets = makeAssets(["p1", "p2", "p3", "p4", "p5"])
        let picked = CullingComparison.surveyAssets(
            current: assets[1], // p2
            assets: assets,
            selectedIds: ["p1", "p3"],
            limit: 5
        )
        #expect(picked.map(\.photo.id) == ["p2", "p1", "p3"])
    }

    @Test("Survey：选择不足 2 张时回退「当前 + 邻接」补足，不会空屏/单张")
    func surveyFallsBackToNeighbors() {
        let assets = makeAssets(["p1", "p2", "p3", "p4", "p5"])
        let fallback = CullingComparison.surveyAssets(
            current: assets[2], // p3
            assets: assets,
            selectedIds: [],
            limit: 4
        )
        #expect(fallback.map(\.photo.id) == ["p2", "p3", "p4", "p5"])

        // 选择只有 1 张也按回退处理（1 张 1:1 判读不是 Survey 的语义）。
        let one = CullingComparison.surveyAssets(
            current: assets[0],
            assets: assets,
            selectedIds: ["p5"],
            limit: 3
        )
        #expect(one.map(\.photo.id) == ["p1", "p2", "p3"])
    }

    @Test("Survey：上限 9 张；超出已加载张数时按已加载的给")
    func surveyCaps() {
        let many = makeAssets((1...12).map { "p\($0)" })
        let capped = CullingComparison.surveyAssets(
            current: many[5], // p6
            assets: many,
            selectedIds: [],
            limit: 20
        )
        #expect(capped.count == CullingLayoutMode.surveyMaxCount)
        #expect(capped.map(\.photo.id) == ["p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12"])

        let few = makeAssets(["p1", "p2", "p3"])
        let loadedOnly = CullingComparison.surveyAssets(
            current: few[0], assets: few, selectedIds: [], limit: 9
        )
        #expect(loadedOnly.count == 3)

        // 选择集已到上限 9 且当前照片不在其中：补当前不能变成 10 格。
        let nine = makeAssets((1...9).map { "p\($0)" })
        let trimmed = CullingComparison.surveyAssets(
            current: b8CullingAsset("cur"),
            assets: nine,
            selectedIds: Set(nine.map { $0.photo.id }),
            limit: 9
        )
        #expect(trimmed.count == CullingLayoutMode.surveyMaxCount, "Survey 同屏绝不超过 9 格")
        #expect(trimmed.first?.photo.id == "cur", "当前照片仍在首位")
    }

    @Test("Survey：没有当前照片 / 没有已加载资产时退化为单张而不是崩溃")
    func surveyDegenerate() {
        #expect(CullingComparison.surveyAssets(
            current: nil, assets: [], selectedIds: [], limit: 9).isEmpty)

        let only = b8CullingAsset("p1")
        let result = CullingComparison.surveyAssets(
            current: only, assets: [], selectedIds: [], limit: 9)
        #expect(result.map(\.photo.id) == ["p1"])
    }

    // MARK: - 贴片可见性与预算

    @Test("贴片可见性：1/2 图全给；3 图/4 图/Survey 只给当前 + hover")
    func detailTilePolicy() {
        #expect(CullingDetailTilePolicy.showsTile(compareCount: 1, isCurrent: false, isHovered: false))
        #expect(CullingDetailTilePolicy.showsTile(compareCount: 2, isCurrent: false, isHovered: false),
                "2 图并排是判焦主战场：两格都要清晰")
        #expect(!CullingDetailTilePolicy.showsTile(compareCount: 3, isCurrent: false, isHovered: false))
        #expect(CullingDetailTilePolicy.showsTile(compareCount: 3, isCurrent: true, isHovered: false))
        #expect(CullingDetailTilePolicy.showsTile(compareCount: 3, isCurrent: false, isHovered: true))
        #expect(!CullingDetailTilePolicy.showsTile(compareCount: 4, isCurrent: false, isHovered: false))
        #expect(CullingDetailTilePolicy.showsTile(compareCount: 9, isCurrent: false, isHovered: true))
    }

    @Test("解码预算按格数单调递减，1 格仍为硬上限")
    func detailBudget() {
        #expect(PhotoDetailTier.budget(forVisibleCells: 1) == PhotoDetailTier.maxDimension)
        #expect(PhotoDetailTier.budget(forVisibleCells: 2) == 6144)
        #expect(PhotoDetailTier.budget(forVisibleCells: 3) == 5120)
        #expect(PhotoDetailTier.budget(forVisibleCells: 4) == 4096)
        #expect(PhotoDetailTier.budget(forVisibleCells: 9) == 3200)

        var previous = Int.max
        for count in 1...9 {
            let budget = PhotoDetailTier.budget(forVisibleCells: count)
            #expect(budget <= previous, "预算必须随格数单调不增（count=\(count)）")
            previous = budget
        }
        // Survey 的贴片档位真的被 3200 夹住（不会按 8192 解 9 块）。
        let surveyTarget = PhotoDetailTier.target(
            fitPoints: 200, zoom: 8, backingScale: 2, sourceMaxDimension: 20000,
            budgetDimension: PhotoDetailTier.budget(forVisibleCells: 9)
        )
        #expect(surveyTarget <= 3200)
    }

    // MARK: - 键位

    @Test("裸键映射：H/F/R/C 落地，⇧F 才是专注模式")
    func shortcutKeys() {
        #expect(CullingViewerShortcutKey.action(characters: "h", shift: false) == .toggleHistogram)
        #expect(CullingViewerShortcutKey.action(characters: "H", shift: true) == .toggleHistogram)
        #expect(CullingViewerShortcutKey.action(characters: "f", shift: false) == .toggleFocusMask)
        #expect(CullingViewerShortcutKey.action(characters: "F", shift: true) == .toggleFocusMode)
        #expect(CullingViewerShortcutKey.action(characters: "r", shift: false) == .toggleReference)
        #expect(CullingViewerShortcutKey.action(characters: "c", shift: false) == .cycleReferenceMode)
        // 未占用的键必须交还给既有决策键（P/X/U/0–9/空格 不受影响）。
        #expect(CullingViewerShortcutKey.action(characters: "x", shift: false) == nil)
        #expect(CullingViewerShortcutKey.action(characters: "1", shift: false) == nil)
        #expect(CullingViewerShortcutKey.action(characters: " ", shift: false) == nil)
    }
}
