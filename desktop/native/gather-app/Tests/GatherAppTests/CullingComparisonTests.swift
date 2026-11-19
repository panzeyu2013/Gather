// desktop/native/gather-app/Tests/GatherAppTests/CullingComparisonTests.swift
// Wave5 批次 1（B1 + B2）：对比/Survey 的决策目标 + 切布局的续页计划（纯函数）。
//
// 背景（历史复评 20-culling-viewer；文档已随 2026-11-18 文档清理移除）：
// - B1：为构造 2/3/4 图对比或多图 Survey 必须先多选；旧实现让同一个选择集同时
//   充当「写入目标」，于是 Survey 里盯着 A 按 X 会批量标掉 B…I。这里把目标解析
//   钉成纯函数：对比类布局默认只写当前照片，批量必须显式开开关。
// - B2：切布局会改页大小（网格 200 / 其余 500）；旧实现无条件整页 reset，当前
//   照片越过新页大小就被踢回第一张。续页计划钉住「不动已加载窗口」的判定。
//
// 本文件只测纯逻辑；视图接线（信息条 Toggle / 网格初始 scrollTo）不在单测范围。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("对比/Survey 决策目标与切布局续页（Wave5 批次1）")
struct CullingComparisonTests {
    // MARK: - B1：决策目标

    @Test("对比布局：选择集只用来构造画面，默认只写当前照片")
    func comparisonDefaultsToCurrentPhoto() {
        // 2 图对比：用户选了 p1/p2，当前 p1 —— 按 X 只能写 p1。
        #expect(CullingDecisionScope.target(
            isComparisonLayout: true,
            currentPhotoId: "p1",
            selectedPhotoIds: ["p1", "p2"],
            writesToSelection: false
        ) == .current(photoId: "p1"))

        // Survey：当前照片可能不在选择集里（选片规则会把它补在首位），
        // 这正是「盯着 A 按 X、写的是 B…I」的原始缺口——目标必须仍是当前。
        #expect(CullingDecisionScope.target(
            isComparisonLayout: true,
            currentPhotoId: "p9",
            selectedPhotoIds: ["p1", "p2", "p3"],
            writesToSelection: false
        ) == .current(photoId: "p9"))
    }

    @Test("对比布局 + 显式开关：才批量写选择集")
    func comparisonBatchesOnlyWhenExplicitlyEnabled() {
        #expect(CullingDecisionScope.target(
            isComparisonLayout: true,
            currentPhotoId: "p1",
            selectedPhotoIds: ["p1", "p2", "p3"],
            writesToSelection: true
        ) == .selection)
    }

    @Test("单图/网格：选择集非空仍批量（批量入口保留给网格/检查器）")
    func gridAndSingleKeepLegacyBatchSemantics() {
        // 网格多选后按 P：旧语义就是批量写选择集，B1 不改这条。
        #expect(CullingDecisionScope.target(
            isComparisonLayout: false,
            currentPhotoId: "p1",
            selectedPhotoIds: ["p1", "p2"],
            writesToSelection: false
        ) == .selection)

        // 单图无选择：写当前照片（与旧实现的第一条分支一致）。
        #expect(CullingDecisionScope.target(
            isComparisonLayout: false,
            currentPhotoId: "p1",
            selectedPhotoIds: [],
            writesToSelection: false
        ) == .current(photoId: "p1"))
    }

    @Test("没有可写目标时返回 nil（不猜目标、不写没看过的照片）")
    func noTargetReturnsNil() {
        #expect(CullingDecisionScope.target(
            isComparisonLayout: true,
            currentPhotoId: nil,
            selectedPhotoIds: ["p1", "p2"],
            writesToSelection: false
        ) == nil, "对比布局没有当前照片：宁可不写，也不批量写到没在看的照片上")
        #expect(CullingDecisionScope.target(
            isComparisonLayout: false,
            currentPhotoId: nil,
            selectedPhotoIds: [],
            writesToSelection: true
        ) == nil)
    }

    @Test("对比类布局判定：2/3/4 图与 Survey；单图/网格不算")
    func comparisonLayoutDetection() {
        for mode in [CullingLayoutMode.compare2, .compare3, .compare4, .survey] {
            #expect(CullingDecisionScope.isComparisonLayout(mode), "\(mode.rawValue) 是对比类布局")
        }
        for mode in [CullingLayoutMode.single, .grid] {
            #expect(!CullingDecisionScope.isComparisonLayout(mode), "\(mode.rawValue) 沿用批量语义")
        }
        // 查看器入口（只有格数/是否 Survey）与布局枚举入口必须同义。
        for mode in CullingLayoutMode.allCases {
            let byCompareCount = CullingDecisionScope.isComparisonLayout(
                compareCount: mode.effectiveCompareCount(selectionCount: 2),
                isSurvey: mode == .survey)
            #expect(byCompareCount == CullingDecisionScope.isComparisonLayout(mode),
                    "两个入口口径必须一致：\(mode.rawValue)")
        }
    }

    // MARK: - B2：布局页大小与续页计划

    @Test("页大小：网格 200，其余布局 500")
    func layoutPageLimits() {
        #expect(CullingLayoutMode.grid.pageLimit == 200)
        #expect(CullingLayoutMode.single.pageLimit == 500)
        #expect(CullingLayoutMode.compare2.pageLimit == 500)
        #expect(CullingLayoutMode.compare3.pageLimit == 500)
        #expect(CullingLayoutMode.compare4.pageLimit == 500)
        #expect(CullingLayoutMode.survey.pageLimit == 500)
    }

    @Test("页变小且当前照片仍在已加载窗口：保持窗口，不重取首页")
    func shrinkKeepsLoadedWindow() {
        // 单图翻到第 301 张（index 300）切网格（500→200）：旧实现整页 reset 后
        // 当前照片不在新页内，被踢回第一张。
        #expect(CullingPageContinuation.plan(
            loadedCount: 500, currentIndex: 300, newLimit: 200) == .keepLoadedWindow)
        #expect(CullingPageContinuation.plan(
            loadedCount: 500, currentIndex: 300, newLimit: 200).reloadLimit == nil)
        // 窗口内任意位置（含首页边界）都不该重取。
        #expect(CullingPageContinuation.plan(
            loadedCount: 200, currentIndex: 199, newLimit: 200) == .keepLoadedWindow)
        #expect(CullingPageContinuation.plan(
            loadedCount: 2_500, currentIndex: 0, newLimit: 200) == .keepLoadedWindow)
    }

    @Test("页变大：重取一次首页，limit = 新页大小（当前照片必然仍在新页内）")
    func growReloadsWithNewLimit() {
        #expect(CullingPageContinuation.plan(
            loadedCount: 200, currentIndex: 50, newLimit: 500) == .reload(limit: 500))
        // 当前照片不在已加载窗口的旧值里也走「按新页取首页」——首页必然包含 index 0。
        #expect(CullingPageContinuation.plan(
            loadedCount: 0, currentIndex: nil, newLimit: 200) == .reload(limit: 200))
        #expect(CullingPageContinuation.plan(
            loadedCount: 0, currentIndex: 3, newLimit: 200) == .reload(limit: 200))
    }

    @Test("当前照片不在已加载窗口（防御分支）：按页对齐重取覆盖它的那一页")
    func missingCurrentReloadsAlignedPage() {
        // index 700 在第 4 页（0-based page 3）：请求 800 条才能覆盖整页。
        #expect(CullingPageContinuation.plan(
            loadedCount: 10, currentIndex: 700, newLimit: 200) == .reload(limit: 800))
        // 页对齐条数超出单次请求上限（2000）时退回新页大小（无法一次覆盖）。
        #expect(CullingPageContinuation.plan(
            loadedCount: 10, currentIndex: 2_500, newLimit: 200) == .reload(limit: 200))
        // 没有当前照片（首屏）：按新页大小取首页。
        #expect(CullingPageContinuation.plan(
            loadedCount: 500, currentIndex: nil, newLimit: 200) == .reload(limit: 200))
    }

    @Test("页对齐换算与请求上限")
    func pageAlignedLimitMath() {
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 0, limit: 200) == 200)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 199, limit: 200) == 200)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 200, limit: 200) == 400)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 1_999, limit: 2_000) == 2_000)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 2_000, limit: 2_000) == nil)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: -1, limit: 200) == nil)
        #expect(CullingPageContinuation.pageAlignedLimit(covering: 5, limit: 0) == nil)
    }
}
