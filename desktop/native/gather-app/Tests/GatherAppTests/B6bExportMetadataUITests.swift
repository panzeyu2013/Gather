// desktop/native/gather-app/Tests/GatherAppTests/B6bExportMetadataUITests.swift
// Cut 1 / B6b：页面视图模型 -> ExportAPI / MetadataAPI 的调用点测试。
//
// 覆盖：
// - ExportViewModel：preview 走 ExportAPI.preview（参数快照含 destination/scope）；
//   确认弹窗冻结 ExportOptions，execute 只从确认分支构造 Confirmed(.userDialog)；
//   未确认时本地以 EXPORT_CONFIRMATION_REQUIRED 拒绝且不发请求；cancel 按
//   sessionId 调用 ExportAPI.cancel；report 的 format 用 ReportFormat 透传。
// - 错误漏斗：GatherError 按码值本地化（不直出原始诊断）。
//
// 真实服务/JobService 行为由 APIExportMetadataTests（B6a）覆盖；本文件只钉
// 「页面不再发字符串命令、确认只来自弹窗」这一层。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@MainActor
@Suite("B6b ExportView -> ExportAPI")
struct B6bExportViewModelTests {
    private func makeViewModel(
        export: B6bExportAPIStub = B6bExportAPIStub()
    ) -> (ExportViewModel, B6bExportAPIStub) {
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: export,
            session: B8SessionAPIStub()
        )
        viewModel.destination = "/tmp/gather-b6b-export"
        return (viewModel, export)
    }

    @Test("preview：走 ExportAPI.preview，参数快照与计划指纹同源")
    func previewUsesExportAPI() async throws {
        let (viewModel, export) = makeViewModel()
        export.previewResult = ExportPreview(
            totalFiles: 3,
            totalSizeBytes: 3_072,
            freeSpaceBytes: 100_000,
            files: [
                ExportPreviewFile(photoId: "p1", filename: "a.jpg", fileSize: 1_024),
                ExportPreviewFile(photoId: "p2", filename: "b.jpg", fileSize: 1_024),
                ExportPreviewFile(photoId: "p3", filename: "c.jpg", fileSize: 1_024),
            ]
        )
        viewModel.scope = .filtered
        viewModel.includeXmp = false

        await viewModel.previewExport()

        let input = try #require(export.previewInputs.first)
        #expect(input.sessionId == "s1")
        #expect(input.options?.destination == "/tmp/gather-b6b-export")
        #expect(input.options?.scope == .filtered)
        #expect(input.options?.includeXmp == false)
        #expect(viewModel.preview?.totalFiles == 3)
        #expect(viewModel.plannedSignature == viewModel.planSignature)
        #expect(viewModel.isPlanStale == false)

        // Cut 4 / 4b-2h：命名预览的「工作区」/「.扩展名」按显式 L10n 渲染
        // （VM 不读进程全局语言；en 用例失败即说明又走了 GatherLocalization.l）。
        viewModel.namingPattern = "{session}-{original}"
        viewModel.format = .original
        #expect(viewModel.namingPreview(with: L10n(language: .zhCN)) == "工作区-IMG_1234.扩展名")
        #expect(viewModel.namingPreview(with: L10n(language: .en)) == "Workspace-IMG_1234.Extension")
    }

    /// P0-5 / Wave1：三个输出规格控件必须真正进入 ExportOptions 与计划指纹；
    /// 原图格式（字节复制）不得携带任何转换参数。
    @Test("P0-5：色彩空间/DPI/输出锐化进入 ExportOptions 与计划指纹")
    func outputSpecsFlowIntoOptionsAndPlanSignature() throws {
        let (viewModel, _) = makeViewModel()
        viewModel.format = .jpeg
        viewModel.outputColorSpace = .displayP3
        viewModel.dpi = "300"
        viewModel.outputSharpeningEnabled = true
        viewModel.outputSharpeningRadius = 1.5
        viewModel.outputSharpeningIntensity = 0.8
        let options = try viewModel.exportOptions()
        #expect(options.colorSpace == .displayP3)
        #expect(options.dpi == 300)
        #expect(options.sharpening == ExportSharpening(radius: 1.5, intensity: 0.8))

        // 改参数必须改变计划指纹（否则计划区不会重算、确认弹窗拿旧参数）。
        let signature = viewModel.planSignature
        viewModel.outputColorSpace = .sRGB
        #expect(viewModel.planSignature != signature, "色彩空间变化必须重算计划")
        let srgbSignature = viewModel.planSignature
        viewModel.dpi = "240"
        #expect(viewModel.planSignature != srgbSignature, "DPI 变化必须重算计划")

        // 原图格式：只做字节复制，三项一律不发送。
        viewModel.format = .original
        let original = try viewModel.exportOptions()
        #expect(original.colorSpace == nil)
        #expect(original.dpi == nil)
        #expect(original.sharpening == nil)
    }

    @Test("execute：确认弹窗冻结的参数原样下发，source = userDialog")
    func executeUsesFrozenConfirmedInput() async throws {
        let (viewModel, export) = makeViewModel()
        export.previewResult = ExportPreview(
            totalFiles: 1,
            totalSizeBytes: 1_024,
            freeSpaceBytes: 10_000,
            files: [ExportPreviewFile(photoId: "p1", filename: "a.jpg", fileSize: 1_024)],
            physicalFileCount: 1
        )
        export.executeResult = ExportResult(
            totalFiles: 1, exported: 1, failed: 0, skipped: 0, errors: []
        )
        viewModel.scope = .filtered

        let confirmation = try #require(await viewModel.exportConfirmation())
        #expect(confirmation.request.scope == .filtered)
        #expect(confirmation.request.destination == "/tmp/gather-b6b-export")
        #expect(confirmation.fileCount == 1)

        // Cut 4 / 4b-2h：范围文案以 LocalizedText 存进确认载荷，渲染期按显式 L10n 解析；
        // id 用 key（不随语言变化），否则切语言后同一份确认会被当成新载荷。
        #expect(confirmation.scopeLabel.key == "保留片（挑片决策为保留）")
        #expect(confirmation.scopeLabel.resolve(with: L10n(language: .en))
            == "Picks only (culling decision: keep)")
        #expect(confirmation.id.contains(confirmation.scopeLabel.key))
        #expect(!confirmation.id.contains("Picks only"))

        await viewModel.executeExport(confirmed: true, request: confirmation.request)

        let confirmed = try #require(export.executeInputs.first)
        #expect(confirmed.source == .userDialog)
        #expect(confirmed.value.sessionId == "s1")
        #expect(confirmed.value.options?.scope == .filtered)
        #expect(confirmed.value.options?.destination == "/tmp/gather-b6b-export")
        #expect(viewModel.result?.exported == 1)
        #expect(viewModel.isExporting == false)
    }

    @Test("execute：未确认不发请求，错误码收敛为 EXPORT_CONFIRMATION_REQUIRED")
    func unconfirmedExecuteIsRejectedLocally() async {
        let (viewModel, export) = makeViewModel()

        await viewModel.executeExport(confirmed: false)

        #expect(export.executeInputs.isEmpty)
        #expect(viewModel.errorMessage?.code == "EXPORT_CONFIRMATION_REQUIRED")
        #expect(viewModel.isExporting == false)
    }

    @Test("cancel：按 sessionId 调用 ExportAPI.cancel 并保留提示")
    func cancelUsesExportAPI() async {
        let (viewModel, export) = makeViewModel()
        export.cancelResult = true

        await viewModel.cancelExport()

        #expect(export.cancelCalls == ["s1"])
        #expect(viewModel.notice != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("report：format 以 ReportFormat 透传，reportType 保持 session_summary")
    func reportUsesReportFormat() async throws {
        let (viewModel, export) = makeViewModel()
        export.reportResult = ReportData(path: "/tmp/gather-b6b.csv", content: "a,b", format: .csv)

        await viewModel.generateReport(format: .csv)

        let input = try #require(export.reportInputs.first)
        #expect(input.sessionId == "s1")
        #expect(input.reportType == "session_summary")
        #expect(input.format == .csv)
        #expect(viewModel.report?.path == "/tmp/gather-b6b.csv")
        #expect(viewModel.notice != nil)
    }

    @Test("错误：GatherError 走码值本地化，不直出原始诊断")
    func gatherErrorMapsThroughPresentation() async {
        let (viewModel, export) = makeViewModel()
        let error = GatherError(
            code: .EXPORT_DIR_ABSOLUTE_REQUIRED,
            underlying: "sensitive raw diagnostic"
        )
        export.previewError = error

        await viewModel.previewExport()

        #expect(viewModel.errorMessage?.code == "EXPORT_DIR_ABSOLUTE_REQUIRED")
        #expect(viewModel.errorMessage?.diagnostic == "sensitive raw diagnostic")
        #expect(viewModel.errorMessage?.code != "sensitive raw diagnostic")
        #expect(viewModel.fieldError == .destination)
    }
}
