// desktop/native/gather-app/Tests/GatherAppTests/DeliveryRecipeEditorTests.swift
// P0-6（Wave2 / task-10）：交付配方编辑器（OutputRecipe ↔ ExportOptions ↔ UI 状态）。
//
// 覆盖：
// - 配方字段（含 task-7 新增的色彩空间/DPI/锐化）编解码往返与旧 JSON 兼容；
// - 编辑入口（updateDeliveryRecipe / setDeliveryRecipeFormat）与格式切换清理；
// - 字段校验（空名/重名/权衡参数/命名模板/子目录）与中文提示；
// - 新建配方是可编辑的默认值，且改动经既有 output.recipes 通道落盘；
// - makeDeliveryInput 的子目录解析、artifacts 汇总、联系表/画廊参数透传；
// - 交付预检与 OutputService 映射同源（配方新字段真的进 ExportOptions）。
//
// 边界：全部用测试替身（B6bExportAPIStub / B8SessionAPIStub / B8SettingsAPIStub），
// 不触碰真实 settings/磁盘。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@MainActor
@Suite("交付配方编辑器（P0-6）")
struct DeliveryRecipeEditorTests {
    private func recipeJSON(_ recipes: [OutputRecipe]) throws -> String {
        String(decoding: try JSONEncoder().encode(recipes), as: UTF8.self)
    }

    /// 带一个可编辑配方的 VM（settings 里已有 output.recipes）。
    private func makeViewModel(
        recipe: OutputRecipe = OutputRecipe(
            id: "r1", name: "客户交付", format: .jpeg, quality: 85, maxDimension: 2048,
            naming: ExportNaming(pattern: "{original}"))
    ) async throws -> (ExportViewModel, B8SettingsAPIStub) {
        let settings = B8SettingsAPIStub(
            values: ["output.recipes": try recipeJSON([recipe])])
        let viewModel = ExportViewModel(
            sessionId: "s1",
            export: B6bExportAPIStub(),
            session: B8SessionAPIStub(),
            settings: settings)
        await viewModel.loadDeliveryRecipes()
        return (viewModel, settings)
    }

    // MARK: - 编解码

    @Test("配方字段（色彩空间/DPI/锐化/水印/命名/子目录）编解码往返")
    func recipeOutputSpecsRoundTrip() throws {
        let recipe = OutputRecipe(
            id: "r1",
            name: "Print 300dpi",
            format: .tiff,
            quality: nil,
            maxDimension: 6000,
            colorSpace: .adobeRGB1998,
            dpi: 300,
            sharpening: ExportSharpening(radius: 2, intensity: 0.8),
            watermark: ExportWatermark(
                type: .text, content: "© Gather", position: .bottomLeft,
                opacity: 0.4, fontSize: 32),
            naming: ExportNaming(pattern: "{session}-{counter}", counterStart: 5),
            includeXmp: true,
            includeMetadata: false,
            destination: "客户A/2026",
            artifacts: [.photos, .contactSheet])
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(OutputRecipe.self, from: data) == recipe)
    }

    @Test("旧配方 JSON（无新增字段键）仍可解码，nil = 旧行为")
    func legacyRecipeJSONStillDecodes() throws {
        let legacy = #"{"id":"r1","name":"旧配方","format":"jpeg","quality":85,"naming":{"pattern":"{original}"},"includeXmp":false,"includeMetadata":true,"destination":"","artifacts":["photos"]}"#
        let decoded = try JSONDecoder().decode(
            OutputRecipe.self, from: Data(legacy.utf8))
        #expect(decoded.colorSpace == nil)
        #expect(decoded.dpi == nil)
        #expect(decoded.sharpening == nil)
        #expect(decoded.watermark == nil)
    }

    // MARK: - 编辑与格式切换

    @Test("编辑配方全部字段并落盘（既有 output.recipes 通道）")
    func editsPersistThroughRecipesChannel() async throws {
        let (viewModel, settings) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.updateDeliveryRecipe(id: id) { recipe in
            recipe.quality = 92
            recipe.maxDimension = 1600
            recipe.colorSpace = .displayP3
            recipe.dpi = 300
            recipe.sharpening = ExportSharpening(radius: 1.5, intensity: 0.8)
            recipe.destination = "客户A/2026-11-11"
            recipe.includeXmp = true
        }
        viewModel.persistDeliveryRecipes()
        let wrote = await waitUntilAsync {
            settings.setInputs.contains { $0.key.value == "output.recipes" }
        }
        #expect(wrote)
        let last = try #require(
            settings.setInputs.last { $0.key.value == "output.recipes" })
        let decoded = try JSONDecoder().decode(
            [OutputRecipe].self, from: Data(last.value.value.utf8))
        let saved = try #require(decoded.first)
        #expect(saved.quality == 92)
        #expect(saved.maxDimension == 1600)
        #expect(saved.colorSpace == .displayP3)
        #expect(saved.dpi == 300)
        #expect(saved.sharpening == ExportSharpening(radius: 1.5, intensity: 0.8))
        #expect(saved.destination == "客户A/2026-11-11")
        #expect(saved.includeXmp)
    }

    @Test("格式切到原图会清掉转换参数（回到 JPEG 给可编辑默认质量）")
    func formatSwitchClearsTransforms() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.updateDeliveryRecipe(id: id) { recipe in
            recipe.colorSpace = .sRGB
            recipe.dpi = 240
            recipe.sharpening = ExportSharpening(radius: 1, intensity: 0.5)
            recipe.watermark = ExportWatermark(
                type: .text, content: "样片", position: .center, opacity: 0.5, fontSize: 24)
        }
        viewModel.setDeliveryRecipeFormat(id: id, format: .original)
        let original = try #require(viewModel.deliveryRecipes.first)
        #expect(original.format == .original)
        #expect(original.quality == nil)
        #expect(original.maxDimension == nil)
        #expect(original.watermark == nil)
        #expect(original.colorSpace == nil)
        #expect(original.dpi == nil)
        #expect(original.sharpening == nil)
        #expect(viewModel.deliveryRecipeIssues(original).isEmpty)

        viewModel.setDeliveryRecipeFormat(id: id, format: .jpeg)
        let jpeg = try #require(viewModel.deliveryRecipes.first)
        #expect(jpeg.format == .jpeg)
        #expect(jpeg.quality == 85, "回到 JPEG 必须有可编辑的默认质量")
    }

    @Test("新建配方是可编辑的默认值（不再是不可改的 85/2048）")
    func newRecipeDefaultsAreEditable() async throws {
        let (viewModel, _) = try await makeViewModel()
        let before = viewModel.deliveryRecipes.count
        viewModel.addDeliveryRecipe()
        #expect(viewModel.deliveryRecipes.count == before + 1)
        let added = try #require(viewModel.deliveryRecipes.last)
        #expect(added.quality == 85)
        #expect(added.maxDimension == 2048)
        viewModel.updateDeliveryRecipe(id: added.id) { recipe in
            recipe.quality = 90
            recipe.maxDimension = 1600
            recipe.colorSpace = .sRGB
        }
        let edited = try #require(viewModel.deliveryRecipes.last)
        #expect(edited.quality == 90)
        #expect(edited.maxDimension == 1600)
        #expect(edited.colorSpace == .sRGB)
    }

    // MARK: - 校验

    @Test("非法字段给出中文提示；默认配方全部合法")
    func validationReportsChineseMessages() async throws {
        let (viewModel, _) = try await makeViewModel()
        #expect(viewModel.deliveryValidationIssues(root: "/tmp/gather-delivery").isEmpty,
                "默认配方与默认目录必须合法")

        var recipe = try #require(viewModel.deliveryRecipes.first)
        recipe.name = "   "
        #expect(viewModel.deliveryRecipeIssues(recipe).contains("配方名不能为空"))

        recipe.name = "ok"
        recipe.format = .original
        recipe.colorSpace = .sRGB
        #expect(viewModel.deliveryRecipeIssues(recipe)
            .contains("原图格式只复制文件，不能设置质量、长边、水印、色彩空间、DPI 或锐化"))

        recipe.format = .jpeg
        recipe.colorSpace = nil
        recipe.dpi = 5000
        #expect(viewModel.deliveryRecipeIssues(recipe)
            .contains("DPI 必须是 1 到 2400 之间的整数"))

        recipe.dpi = nil
        recipe.sharpening = ExportSharpening(radius: 20, intensity: 0.5)
        #expect(viewModel.deliveryRecipeIssues(recipe)
            .contains("锐化半径必须在 0.1 到 10 之间"))

        recipe.sharpening = nil
        recipe.naming = ExportNaming(pattern: "a/b")
        #expect(viewModel.deliveryRecipeIssues(recipe)
            .contains("命名模式不能包含路径分隔符"))

        recipe.naming = ExportNaming(pattern: "{original}")
        recipe.destination = "../escape"
        #expect(viewModel.deliveryRecipeIssues(recipe)
            .contains("子目录必须是交付根内的相对路径，且不能包含 .."))

        recipe.destination = ""
        recipe.watermark = ExportWatermark(
            type: .text, content: "  ", position: .center, opacity: 0.5, fontSize: 24)
        #expect(viewModel.deliveryRecipeIssues(recipe).contains("水印文字不能为空"))
    }

    @Test("跨配方校验：重名与同一输出目录都要拦下")
    func crossRecipeValidation() async throws {
        let (viewModel, _) = try await makeViewModel()
        var first = try #require(viewModel.deliveryRecipes.first)
        first.name = "同一名字"
        var second = first
        second.id = "r2"
        viewModel.deliveryRecipes = [first, second]
        let duplicateNameIssues = viewModel.deliveryValidationIssues(root: "/tmp/gather-delivery")
        #expect(duplicateNameIssues.contains("配方名不能重复"))

        second.name = "另一个名字"
        first.destination = "客户A"
        second.destination = "客户A"
        viewModel.deliveryRecipes = [first, second]
        let duplicateDestinationIssues = viewModel.deliveryValidationIssues(
            root: "/tmp/gather-delivery")
        #expect(duplicateDestinationIssues.contains("两个配方写入了同一个输出目录"))
    }

    // MARK: - makeDeliveryInput / 预检同源

    @Test("子目录解析、artifacts 汇总与联系表/画廊参数透传")
    func deliveryInputResolvesSubdirectoryAndOptions() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.updateDeliveryRecipe(id: id) { $0.destination = "客户A/2026-11-11" }
        viewModel.deliveryRoot = "/tmp/gather-delivery"
        viewModel.deliveryIncludeContactSheet = true
        viewModel.deliveryIncludeGallery = true
        let contactSheet = OutputContactSheetOptions(
            title: "", subtitle: "副标题", footer: "页脚", columns: 3, rows: 4,
            fields: [.filename, .rating], captionTemplate: "{filename}",
            showLabelChip: false, showPickBorder: true)
        let gallery = OutputGalleryOptions(
            title: "", subtitle: "", footer: "",
            thumbnailMaxDimension: 640, largeMaxDimension: 2560, fields: [.rating])
        let input = try #require(await viewModel.prepareDeliveryInput(
            contactSheetOptions: contactSheet, galleryOptions: gallery))

        let recipe = try #require(input.recipes.first)
        #expect(recipe.destination
            == "/tmp/gather-delivery/客户A/2026-11-11", "相对子目录要解析成交付根下的绝对路径")
        #expect(recipe.artifacts.contains(.photos))
        #expect(recipe.artifacts.contains(.contactSheet))
        #expect(recipe.artifacts.contains(.gallery))

        let resolvedSheet = try #require(input.contactSheet)
        #expect(resolvedSheet.columns == 3)
        #expect(resolvedSheet.rows == 4)
        #expect(resolvedSheet.subtitle == "副标题")
        #expect(resolvedSheet.captionTemplate == "{filename}")
        #expect(resolvedSheet.fields == [.filename, .rating])
        #expect(resolvedSheet.showLabelChip == false)
        #expect(resolvedSheet.showPickBorder)

        let resolvedGallery = try #require(input.gallery)
        #expect(resolvedGallery.thumbnailMaxDimension == 640)
        #expect(resolvedGallery.largeMaxDimension == 2560)
        #expect(resolvedGallery.fields == [.rating])
        #expect(resolvedGallery.title == "Gallery", "标题留空回落升级前的默认文案")
    }

    @Test("交付预检与 OutputService 同源：配方新字段进 ExportOptions")
    func deliveryPreflightCarriesRecipeSpecs() async throws {
        let settings = B8SettingsAPIStub(values: [
            "output.recipes": try recipeJSON([
                OutputRecipe(
                    id: "r1", name: "Spec", format: .jpeg, quality: 90,
                    maxDimension: 1600, colorSpace: .displayP3, dpi: 300,
                    sharpening: ExportSharpening(radius: 1.5, intensity: 0.8)),
            ]),
        ])
        let export = B6bExportAPIStub()
        export.previewResult = ExportPreview(
            totalFiles: 1, totalSizeBytes: 100, freeSpaceBytes: 1_000, files: [])
        let viewModel = ExportViewModel(
            sessionId: "s1", export: export, session: B8SessionAPIStub(),
            settings: settings)
        await viewModel.loadDeliveryRecipes()
        viewModel.deliveryRoot = "/tmp/gather-delivery"
        let input = try #require(await viewModel.prepareDeliveryInput())
        _ = await viewModel.deliveryPreflight(for: input)

        let options = try #require(export.previewInputs.last?.options)
        #expect(options.colorSpace == .displayP3)
        #expect(options.dpi == 300)
        #expect(options.sharpening == ExportSharpening(radius: 1.5, intensity: 0.8))
        #expect(options.quality == 90)
        #expect(options.maxDimension == 1600)
    }
}
