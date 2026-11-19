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
import GatherTestSupport
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
        // Wave2 收尾：旧 JSON 没有迁移标记键 → nil（由 load 时的迁移补上）。
        #expect(decoded.artifactsMigrationVersion == nil)
        #expect(decoded.artifacts == [.photos])
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
            // Wave2：新增规格字段也走同一条 output.recipes 持久化通道。
            recipe.subdirectory = ExportSubdirectory(
                template: "{client}/{event}", client: "ACME", event: "婚礼")
            recipe.contactSheet = OutputContactSheetOptions(
                title: "客户样片", columns: 3, rows: 2, margin: 40)
            recipe.gallery = OutputGalleryOptions(
                title: "婚礼画廊", thumbnailMaxDimension: 640, largeMaxDimension: 2560)
            recipe.watermark = ExportWatermark(
                type: .image, content: "/tmp/logo.png", position: .bottomLeft,
                opacity: 0.6, imageScale: 0.2, imageMargin: 0.02)
        }
        // task-23 起 load 会为老配方落一次迁移写；这里要等的是「编辑之后」的那次写，
        // 否则可能拿到迁移快照（旧值）。
        let writesBeforeEdit = settings.setInputs.count
        viewModel.persistDeliveryRecipes()
        let wrote = await waitUntilAsync {
            settings.setInputs.count > writesBeforeEdit
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
        #expect(saved.subdirectory == ExportSubdirectory(
            template: "{client}/{event}", client: "ACME", event: "婚礼"))
        #expect(saved.contactSheet?.columns == 3)
        #expect(saved.contactSheet?.margin == 40)
        #expect(saved.gallery?.largeMaxDimension == 2560)
        #expect(saved.watermark?.type == .image)
        #expect(saved.watermark?.imageScale == 0.2)
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

    @Test("配方级联系表/画廊参数与相对目录解析进 makeDeliveryInput")
    func deliveryInputResolvesOptionsAndDestination() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.updateDeliveryRecipe(id: id) { recipe in
            recipe.destination = "客户A/2026-11-11"
            recipe.contactSheet = OutputContactSheetOptions(
                title: "客户样片", subtitle: "副标题", footer: "页脚", columns: 3, rows: 4,
                margin: 48, fields: [.filename, .rating], captionTemplate: "{filename}",
                showLabelChip: false, showPickBorder: true)
            recipe.gallery = OutputGalleryOptions(
                title: "婚礼画廊", subtitle: "", footer: "",
                thumbnailMaxDimension: 640, largeMaxDimension: 2560, fields: [.rating])
            recipe.artifacts = [.photos, .contactSheet, .gallery]
        }
        viewModel.deliveryRoot = "/tmp/gather-delivery"
        let input = try #require(await viewModel.prepareDeliveryInput())

        let recipe = try #require(input.recipes.first)
        #expect(recipe.destination
            == "/tmp/gather-delivery/客户A/2026-11-11", "相对子目录要解析成交付根下的绝对路径")
        #expect(recipe.artifacts == [.photos, .contactSheet, .gallery])
        // Wave2：联系表/画廊参数属于配方，不再占用 run 级字段。
        #expect(input.contactSheet == nil)
        #expect(input.gallery == nil)

        let sheet = try #require(recipe.contactSheet)
        #expect(sheet.columns == 3)
        #expect(sheet.rows == 4)
        #expect(sheet.margin == 48)
        #expect(sheet.subtitle == "副标题")
        #expect(sheet.captionTemplate == "{filename}")
        #expect(sheet.fields == [.filename, .rating])
        #expect(sheet.showLabelChip == false)
        #expect(sheet.showPickBorder)

        let gallery = try #require(recipe.gallery)
        #expect(gallery.thumbnailMaxDimension == 640)
        #expect(gallery.largeMaxDimension == 2560)
        #expect(gallery.fields == [.rating])
        #expect(gallery.title == "婚礼画廊")
    }

    @Test("交付预检与 OutputService 同源：配方新字段进 ExportOptions")
    func deliveryPreflightCarriesRecipeSpecs() async throws {
        let settings = B8SettingsAPIStub(values: [
            "output.recipes": try recipeJSON([
                OutputRecipe(
                    id: "r1", name: "Spec", format: .jpeg, quality: 90,
                    maxDimension: 1600, colorSpace: .displayP3, dpi: 300,
                    sharpening: ExportSharpening(radius: 1.5, intensity: 0.8),
                    subdirectory: ExportSubdirectory(
                        template: "{client}/{yyyy}", client: "ACME")),
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
        #expect(options.subdirectory?.template == "{client}/{yyyy}",
                "Wave2：子目录规则必须进预检（确认弹窗与真实写盘同源）")
    }

    // MARK: - Wave2（task-16）：子目录 / 联系表画廊 / 图片水印

    @Test("Wave2：子目录规则编辑、示例与非法 token 校验")
    func subdirectoryEditingAndValidation() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.setDeliverySubdirectoryTemplate(
            id: id, template: "{client}/{yyyy}-{MM}-{dd}")
        viewModel.updateDeliverySubdirectory(id: id) { $0.client = "ACME" }
        let recipe = try #require(viewModel.deliveryRecipes.first)
        #expect(recipe.subdirectory?.template == "{client}/{yyyy}-{MM}-{dd}")
        #expect(recipe.subdirectory?.client == "ACME")
        #expect(viewModel.deliveryRecipeIssues(recipe).isEmpty)

        // 未知 token / 路径穿越 → 中文提示（复用协议层唯一校验实现）。
        viewModel.setDeliverySubdirectoryTemplate(id: id, template: "{unknown}")
        let invalid = try #require(viewModel.deliveryRecipes.first)
        #expect(viewModel.deliveryRecipeIssues(invalid).contains {
            $0.hasPrefix("子目录规则无效")
        })
        // 清空模板 → 整个规则移除（回到"直接写交付目录"）。
        viewModel.setDeliverySubdirectoryTemplate(id: id, template: "   ")
        #expect(viewModel.deliveryRecipes.first?.subdirectory == nil)
    }

    @Test("Wave2：配方级联系表/画廊参数编辑与产物开关")
    func contactSheetGalleryEditing() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.setDeliveryRecipeArtifact(id: id, .contactSheet, isEnabled: true)
        viewModel.updateDeliveryContactSheet(id: id) {
            $0.columns = 3
            $0.rows = 4
            $0.margin = 48
            $0.title = "客户样片"
        }
        viewModel.setDeliveryRecipeArtifact(id: id, .gallery, isEnabled: true)
        viewModel.updateDeliveryGallery(id: id) {
            $0.thumbnailMaxDimension = 640
            $0.largeMaxDimension = 2560
            $0.title = "婚礼画廊"
        }
        let recipe = try #require(viewModel.deliveryRecipes.first)
        #expect(recipe.artifacts.contains(.contactSheet))
        #expect(recipe.artifacts.contains(.gallery))
        #expect(recipe.contactSheet?.columns == 3)
        #expect(recipe.contactSheet?.margin == 48)
        #expect(recipe.gallery?.largeMaxDimension == 2560)
        #expect(viewModel.deliveryRecipeIssues(recipe).isEmpty)

        // artifacts 顺序稳定（会进配方指纹）；关闭联系表 → 只留照片 + 画廊。
        viewModel.setDeliveryRecipeArtifact(id: id, .contactSheet, isEnabled: false)
        let updated = try #require(viewModel.deliveryRecipes.first)
        #expect(updated.artifacts == [.photos, .gallery])
        // 越界参数仍被拦下。
        viewModel.updateDeliveryContactSheet(id: id) { $0.columns = 0 }
        viewModel.setDeliveryRecipeArtifact(id: id, .contactSheet, isEnabled: true)
        #expect(viewModel.deliveryRecipeIssues(
            viewModel.deliveryRecipes[0]).contains("联系表列数必须在 1 到 12 之间"))
    }

    @Test("Wave2：图片水印编辑与形状校验（不访问磁盘）")
    func imageWatermarkEditingAndValidation() async throws {
        let (viewModel, _) = try await makeViewModel()
        let id = try #require(viewModel.deliveryRecipes.first?.id)
        viewModel.updateDeliveryRecipe(id: id) { recipe in
            recipe.watermark = ExportWatermark(
                type: .image, content: "", position: .bottomRight,
                opacity: 0.7, imageScale: 0.15, imageMargin: 0.03)
        }
        var recipe = try #require(viewModel.deliveryRecipes.first)
        #expect(viewModel.deliveryRecipeIssues(recipe).contains("水印图片不能为空"))

        viewModel.updateDeliveryWatermark(id: id) {
            $0.content = "/tmp/logo.png"
            $0.imageScale = 0.25
        }
        recipe = try #require(viewModel.deliveryRecipes.first)
        let issues = viewModel.deliveryRecipeIssues(recipe)
        #expect(issues.isEmpty, "合法图片水印不应有编辑期错误: \(issues)")
        // 版式越界 → 中文提示。
        viewModel.updateDeliveryWatermark(id: id) { $0.imageScale = 2 }
        #expect(viewModel.deliveryRecipeIssues(
            viewModel.deliveryRecipes[0]).contains("水印宽度比例必须在 2% 到 100% 之间"))
    }

    // MARK: - Wave2 收尾：旧配方产物清单一次性迁移（task-23）

    @Test("旧配方迁移：Wave1 默认 Web 形态补 gallery；自定义 artifacts 只写 marker")
    func legacyRecipesMigrateConservatively() async throws {
        let webDefault = OutputRecipe(
            id: "web1", name: "Web 2048", format: .jpeg, quality: 82,
            maxDimension: 2048, artifacts: [.photos, .contactSheet])
        let custom = OutputRecipe(id: "custom1", name: "客户交付", artifacts: [.photos])
        let settings = B8SettingsAPIStub(
            values: ["output.recipes": try recipeJSON([webDefault, custom])])
        let viewModel = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings)
        await viewModel.loadDeliveryRecipes()

        let recipes = viewModel.deliveryRecipes
        #expect(recipes[0].artifacts == [.photos, .contactSheet, .gallery])
        #expect(recipes[0].artifactsMigrationVersion == 1)
        // 规则 3：无法精确判定为历史默认的形态一律不补，只写 marker。
        #expect(recipes[1].artifacts == [.photos])
        #expect(recipes[1].artifactsMigrationVersion == 1)

        // load 内部 await 到迁移写完，这里直接读即可。
        let persisted = try #require(settings.values["output.recipes"],
                                    "迁移必须落盘，否则下次启动会重跑")
        let decoded = try JSONDecoder().decode(
            [OutputRecipe].self, from: Data(persisted.utf8))
        #expect(decoded[0].artifacts.contains(.gallery))
        #expect(decoded[0].artifactsMigrationVersion == 1)
        #expect(decoded[1].artifacts == [.photos])
    }

    @Test("旧配方迁移：仅 [photos] + 历史 Web 名才补 contactSheet+画廊")
    func legacyWebOnlyRecipeMigratesByName() async throws {
        let webOnly = OutputRecipe(id: "web2", name: "Web 2048", artifacts: [.photos])
        let renamed = OutputRecipe(id: "web3", name: "我的 Web 预设", artifacts: [.photos])
        let settings = B8SettingsAPIStub(
            values: ["output.recipes": try recipeJSON([webOnly, renamed])])
        let viewModel = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings)
        await viewModel.loadDeliveryRecipes()

        #expect(viewModel.deliveryRecipes[0].artifacts == [.photos, .contactSheet, .gallery])
        #expect(viewModel.deliveryRecipes[1].artifacts == [.photos],
                "改名后的自定义配方不能按历史默认名推测")
        #expect(viewModel.deliveryRecipes[1].artifactsMigrationVersion == 1)
    }

    @Test("迁移幂等：第二次 load 不再迁移、不再写回")
    func migrationIsIdempotent() async throws {
        let legacy = OutputRecipe(
            id: "web1", name: "Web 2048", artifacts: [.photos, .contactSheet])
        let settings1 = B8SettingsAPIStub(
            values: ["output.recipes": try recipeJSON([legacy])])
        let first = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings1)
        await first.loadDeliveryRecipes()
        let persisted = try #require(settings1.values["output.recipes"])

        let settings2 = B8SettingsAPIStub(values: ["output.recipes": persisted])
        let second = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings2)
        await second.loadDeliveryRecipes()
        #expect(second.deliveryRecipes.first?.artifactsMigrationVersion == 1)
        #expect(second.deliveryRecipes.first?.artifacts
                == [.photos, .contactSheet, .gallery])
        // 负向观察窗口：重复 load 不得产生任何 output.recipes 写。
        await awaitNegativeWindow(.milliseconds(100))
        #expect(!settings2.setInputs.contains { $0.key.value == "output.recipes" },
                "已迁移配方重复 load 不得再写回 settings")
    }

    @Test("用户显式取消不被迁移补回（marker=1 + 缺 gallery）")
    func explicitArtifactRemovalIsPreserved() async throws {
        var recipe = OutputRecipe(
            id: "web1", name: "Web 2048", artifacts: [.photos, .contactSheet])
        recipe.artifactsMigrationVersion = 1
        let settings = B8SettingsAPIStub(
            values: ["output.recipes": try recipeJSON([recipe])])
        let viewModel = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings)
        await viewModel.loadDeliveryRecipes()

        #expect(viewModel.deliveryRecipes.first?.artifacts == [.photos, .contactSheet],
                "用户取消勾选的 gallery 不能因为缺字段被补回")
        #expect(viewModel.deliveryRecipes.first?.artifactsMigrationVersion == 1)
        // 负向观察窗口：内容未变化时迁移不得写回。
        await awaitNegativeWindow(.milliseconds(150))
        #expect(!settings.setInputs.contains { $0.key.value == "output.recipes" },
                "内容未变化时迁移不得写回")
    }

    @Test("新建配方与勾选/取消产物都写 marker；取消后重载不复活")
    func artifactToggleStampsMigrationMarker() async throws {
        let (viewModel, settings) = try await makeViewModel()
        // 默认配方在 load 时走过迁移（规则 3），marker 已写。
        #expect(viewModel.deliveryRecipes.first?.artifactsMigrationVersion == 1)

        viewModel.addDeliveryRecipe()
        let added = try #require(viewModel.deliveryRecipes.last)
        #expect(added.artifactsMigrationVersion == 1)
        viewModel.setDeliveryRecipeArtifact(id: added.id, .gallery, isEnabled: false)
        let toggled = try #require(viewModel.deliveryRecipes.last)
        #expect(toggled.artifactsMigrationVersion == 1)
        #expect(!toggled.artifacts.contains(.gallery))
        // 面板的 .onChange 会调度落盘；测试里直接触发同一通道并等写完。
        viewModel.persistDeliveryRecipes()
        await viewModel.persistWriteTask?.value
        let persisted = try #require(settings.values["output.recipes"])

        let settings2 = B8SettingsAPIStub(values: ["output.recipes": persisted])
        let reloaded = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings2)
        await reloaded.loadDeliveryRecipes()
        let restored = try #require(reloaded.deliveryRecipes.last)
        #expect(!restored.artifacts.contains(.gallery), "显式取消在重载后必须保留")
        #expect(restored.artifactsMigrationVersion == 1)
    }

    // MARK: - Review P0-1：读失败不得覆盖磁盘配方

    @Test("settings 读失败 / 坏 JSON：不得把默认配方落盘覆盖用户数据")
    func loadFailureDoesNotOverwriteRecipes() async throws {
        let payload = try recipeJSON([OutputRecipe(
            id: "r1", name: "用户配方", format: .jpeg,
            naming: ExportNaming(pattern: "{original}"))])

        // ① 读取抛错（瞬时 settings 故障）
        let settings = B8SettingsAPIStub(values: ["output.recipes": payload])
        settings.getError = NSError(domain: "test", code: 1)
        let viewModel = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: settings)
        await viewModel.loadDeliveryRecipes()
        #expect(settings.setInputs.isEmpty, "读失败时不得落盘（否则会用默认配方覆盖用户数据）")
        #expect(viewModel.deliveryRecipes.isEmpty)

        // ② 坏 JSON
        let corrupt = B8SettingsAPIStub(values: ["output.recipes": "{not-json"])
        let corruptViewModel = ExportViewModel(
            sessionId: "s1", export: B6bExportAPIStub(),
            session: B8SessionAPIStub(), settings: corrupt)
        await corruptViewModel.loadDeliveryRecipes()
        #expect(corrupt.setInputs.isEmpty, "坏 JSON 也不得落盘（保留原值供人工恢复）")
        #expect(corruptViewModel.deliveryRecipes.isEmpty)
    }
}
