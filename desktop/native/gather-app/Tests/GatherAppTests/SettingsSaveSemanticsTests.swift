// desktop/native/gather-app/Tests/GatherAppTests/SettingsSaveSemanticsTests.swift
// 设置保存语义（本轮修复 + 新旋钮可写性）：
//   ① 默认值为空的文本键必须能清空——face_embedding_model_path 清空 = 回到内置 Vision 特征，
//      旧实现一刀切拒绝空值，用户一旦填错模型路径就再也退不回来；
//   ② 默认值非空的键留空仍按无效输入拒绝；
//   ③ 保存提示必须用界面标签（zhLabel）而不是内部键（审查发现「已保存 thumbnail_size」）；
//   ④ 新增的人脸算法参数必须能真正写进去（键在默认表、值过校验、SettingsSetInput 正确）。
//
// B8.1b：断言从「router 记录了 settings.set 命令」改为「SettingsAPI.set 收到
// 类型化 SettingsSetInput」——走页面生产数据路径（settingsAPI 非 nil 分支），
// 不再维护 [命令: JSONValue] 响应表。save 在 API 分支是 Task，故用 waitUntilAsync
// 等落定后再断言（不再依赖同步 旧命令面的隐含时序）。
//
// Cut 4 / 4b-2g：VM/静态表的动态 key 不再读进程全局语言——saveField/save/
// label(for:)/dateText 都收显式 L10n。这里同时断言 zh 与 en：en 用例若实现
// 退回 GatherLocalization/appLanguage，会拿到中文而直接红。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@Suite("settings 保存语义")
@MainActor
struct SettingsSaveSemanticsTests {
    /// 显式语言（不读进程全局）：每个用例按需选 zh / en。
    private let zh = L10n(language: .zhCN)
    private let en = L10n(language: .en)

    private func makeViewModel(
        language: L10n.Language = .zhCN
    ) -> (SettingsViewModel, B8SettingsAPIStub) {
        let settings = B8SettingsAPIStub()
        // B8.2a：设置页改持 typed API（settings 去 optional），不再走 router
        // 的 settings.* 兼容分支。
        // Cut 4 / 4b-2g：语言源也是必填依赖；测试用独立 NotificationCenter，
        // 不订阅进程级 languageChanged。
        let viewModel = SettingsViewModel(
            session: B8SessionAPIStub(),
            settings: settings,
            culling: B8CullingAPIStub(),
            captureOne: CaptureOneBridge(),
            languageStore: LanguageStore(language: language, notificationCenter: NotificationCenter())
        )
        return (viewModel, settings)
    }

    /// 等 API 分支的 Task 落定（save 内部起 Task 调 settingsAPI.set）。
    private func waitForSets(_ settings: B8SettingsAPIStub, count: Int) async {
        #expect(
            await waitUntilAsync { settings.setInputs.count == count },
            "settings.set 未在超时内落定（期望 \(count) 次，实际 \(settings.setInputs.count)）"
        )
    }

    @Test("默认值为空的文本键允许清空（专用人脸模型路径 → 回到内置 Vision）")
    func clearingDefaultEmptyTextKeyIsAllowed() async {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        viewModel.edits["face_embedding_model_path"] = "   "
        viewModel.saveField(field, with: zh)

        await waitForSets(settings, count: 1)
        #expect(viewModel.errorMessage == nil)
        let saved = settings.setInputs.contains { input in
            input.key.value == "face_embedding_model_path" && input.value.value == ""
        }
        #expect(saved, "清空模型路径必须真的写入空串（= 回到内置 Vision）")
    }

    @Test("默认值非空的文本键留空仍被拒绝，且不写入")
    func clearingNonEmptyDefaultKeyIsRejected() {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "detector_model_path", type: .text,
            zhLabel: "检测模型路径", zhDesc: "")
        viewModel.edits["detector_model_path"] = ""
        viewModel.saveField(field, with: zh)

        #expect(viewModel.errorMessage != nil)
        #expect(settings.setInputs.isEmpty)
    }

    @Test("保存提示用人类标签，不暴露内部键")
    func noticeUsesHumanLabel() async {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "face_core_quality", type: .number(min: 0, max: 1),
            zhLabel: "核心点质量门槛", zhDesc: "")
        viewModel.edits["face_core_quality"] = "0.5"
        viewModel.saveField(field, with: zh)
        // save 的 API 分支在 Task 里：先记录入参、后写 notice，故等 notice 落定。
        #expect(await waitUntilAsync { viewModel.notice != nil }, "保存提示未在超时内落定")
        await waitForSets(settings, count: 1)

        let notice = viewModel.notice.map { zh.resolve($0) } ?? ""
        #expect(notice.contains("核心点质量门槛"))
        #expect(!notice.contains("face_core_quality"))
    }

    @Test("数值越界不落库（质量门槛 > 1）")
    func outOfRangeNumberIsRejected() {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "face_core_quality", type: .number(min: 0, max: 1),
            zhLabel: "核心点质量门槛", zhDesc: "")
        viewModel.edits["face_core_quality"] = "1.5"
        viewModel.saveField(field, with: zh)

        #expect(viewModel.errorMessage != nil)
        #expect(settings.setInputs.isEmpty)
    }

    @Test("不存在的模型路径保存即拒绝：固定模板 + 路径参数，且不写入")
    func missingModelPathIsRejectedOnSave() {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        let missing = "/tmp/gather-missing-model-\(UUID().uuidString).mlmodelc"
        viewModel.edits["face_embedding_model_path"] = missing
        viewModel.saveField(field, with: zh)

        // 关键：错误原因直接给用户（此前会潜伏到分析时才以"发生未知错误"爆出）。
        let resolvedPath = URL(fileURLWithPath: missing).resolvingSymlinksInPath().path
        // R5-P1-1：VM 只存固定 key + 参数，不再拼含运行时路径的中文长句。
        #expect(viewModel.errorMessage?.code == SettingsViewModel.FaceModelPathIssue.modelNotFoundKey)
        #expect(viewModel.errorMessage?.params == [resolvedPath])
        #expect((viewModel.errorMessage?.code ?? "").contains("人脸嵌入模型不存在"))
        #expect(settings.setInputs.isEmpty, "不存在的模型路径不得入库")
    }

    @Test("模型路径错误固定 key + 参数：en 文案含真实路径且不含 CJK（R5-P1-1）")
    func modelPathErrorLocalizesWithPathInEnglish() {
        let (viewModel, settings) = makeViewModel(language: .en)
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        let missing = "/tmp/gather-missing-\(UUID().uuidString).mlmodelc"
        viewModel.edits["face_embedding_model_path"] = missing
        viewModel.saveField(field, with: en)

        let resolvedPath = URL(fileURLWithPath: missing).resolvingSymlinksInPath().path
        let text = viewModel.errorMessage.map { CommandErrorText.resolve($0, with: en) } ?? ""
        #expect(text.contains(resolvedPath), "英文错误必须含真实路径，实际：\(text)")
        #expect(text.contains("Face embedding model not found"), "实际：\(text)")
        #expect(!Self.containsCJK(text), "英文错误不得出现中文，实际：\(text)")
        #expect(viewModel.errorMessage?.code == SettingsViewModel.FaceModelPathIssue.modelNotFoundKey)
        #expect(settings.setInputs.isEmpty)
    }

    @Test("模型扩展名错误同样走固定模板：en 含 .onnx 且无 CJK（R5-P1-1）")
    func unsupportedExtensionLocalizesInEnglish() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-\(UUID().uuidString).onnx")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (viewModel, settings) = makeViewModel(language: .en)
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        viewModel.edits["face_embedding_model_path"] = url.path
        viewModel.saveField(field, with: en)

        let text = viewModel.errorMessage.map { CommandErrorText.resolve($0, with: en) } ?? ""
        #expect(text.contains(".onnx"), "英文错误必须含扩展名，实际：\(text)")
        #expect(text.contains("Unsupported face embedding model extension"), "实际：\(text)")
        #expect(!Self.containsCJK(text), "英文错误不得出现中文，实际：\(text)")
        #expect(viewModel.errorMessage?.code == SettingsViewModel.FaceModelPathIssue.unsupportedFormatKey)
        #expect(settings.setInputs.isEmpty)
    }

    @Test("标签查表：滑杆键、分组键、未知键")
    func labelLookup() {
        #expect(SettingsViewModel.label(for: "face_match_margin", with: zh) == "歧义判定间隔")
        #expect(SettingsViewModel.label(for: "face_embedding_model_path", with: zh) == "专用人脸模型路径")
        #expect(SettingsViewModel.label(for: "face_incremental_clustering", with: zh) == "增量聚类")
        #expect(SettingsViewModel.label(for: "no_such_key", with: zh) == "no_such_key")
        // Cut 4 / 4b-2g：同一个动态 key 在 en 下出英文（语言来自显式 L10n）。
        #expect(SettingsViewModel.label(for: "face_match_margin", with: en) == "Ambiguity margin")
        #expect(SettingsViewModel.label(for: "face_embedding_model_path", with: en) == "Dedicated face model path")
        #expect(SettingsViewModel.label(for: "face_incremental_clustering", with: en) == "Incremental clustering")
        #expect(SettingsViewModel.label(for: "no_such_key", with: en) == "no_such_key")
    }

    @Test("新增人脸参数端到端可写（界面 → settings.set 参数正确）")
    func faceAlgorithmKeysAreWritable() async {
        let (viewModel, settings) = makeViewModel()
        let margin = SettingField(
            key: "face_match_margin", type: .number(min: 0, max: 0.2),
            zhLabel: "歧义判定间隔", zhDesc: "")
        viewModel.edits["face_match_margin"] = "0.05"
        viewModel.saveField(margin, with: zh)

        let retry = SettingField(
            key: "face_core_retry_min_samples", type: .number(min: 1, max: 10),
            zhLabel: "二遍最小样本数", zhDesc: "")
        viewModel.edits["face_core_retry_min_samples"] = "3"
        viewModel.saveField(retry, with: zh)

        let modelVersion = SettingField(
            key: "face_embedding_model_version", type: .text,
            zhLabel: "模型版本标签", zhDesc: "")
        viewModel.edits["face_embedding_model_version"] = "arcface-r100-w600k"
        viewModel.saveField(modelVersion, with: zh)

        await waitForSets(settings, count: 3)
        let sent = settings.setInputs
        #expect(sent.count == 3)
        #expect(sent.contains { $0.key.value == "face_match_margin"
            && $0.value.value == "0.05" })
        #expect(sent.contains { $0.key.value == "face_core_retry_min_samples"
            && $0.value.value == "3" })
        #expect(sent.contains { $0.key.value == "face_embedding_model_version"
            && $0.value.value == "arcface-r100-w600k" })
    }

    // ── 保存不再加载/哈希（V1 探针 I：256 MiB 模型同步加载 48.4s 卡主线程）──

    @Test("廉价校验：垃圾 .mlmodelc 包（存在 + 扩展名合法）放行，不做加载/哈希")
    func junkModelPackageIsAcceptedWithoutLoading() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-junk-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x00]).write(to: dir.appendingPathComponent("model.mil"))
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧实现会走 MLModel 编译/加载 + 内容指纹哈希并抛 modelLoadFailed；
        // 新实现只做存在性/扩展名判定 → 放行（能否真正加载由分析路径负责）。
        #expect(SettingsViewModel.faceEmbeddingModelPathError(dir.path) == nil)

        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        viewModel.edits["face_embedding_model_path"] = dir.path
        viewModel.saveField(field, with: zh)
        await waitForSets(settings, count: 1)
        #expect(viewModel.errorMessage == nil, "廉价校验不得加载模型（垃圾包也应可保存）")
        #expect(settings.setInputs.contains {
            $0.key.value == "face_embedding_model_path" && $0.value.value == dir.path
        }, "合法形态的路径必须真正写入")
    }

    @Test("廉价校验：展开 ~（与 core 的 expandingTildeInPath 语义一致）")
    func tildeIsExpanded() {
        let name = "gather-missing-\(UUID().uuidString).mlmodelc"
        let reason = SettingsViewModel.faceEmbeddingModelPathError("~/\(name)")
        let resolved = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(name)
            .resolvingSymlinksInPath()
            .path
        #expect(reason == .modelNotFound(path: resolved))
        let reportedPath = reason?.params.first ?? ""
        #expect(reportedPath == resolved, "~ 必须展开后再报路径，实际：\(reportedPath)")
        #expect(reportedPath.contains("~") == false)
    }

    @Test("廉价校验：扩展名不是 .mlmodel/.mlmodelc → 固定模板拒绝")
    func unsupportedExtensionIsRejected() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-\(UUID().uuidString).onnx")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reason = SettingsViewModel.faceEmbeddingModelPathError(url.path)
        #expect(reason == .unsupportedFormat(ext: "onnx"))
        #expect((reason?.key ?? "").contains("不支持的人脸嵌入模型扩展名"))
    }

    @Test("廉价校验：空目录 .mlmodelc 按『模型不存在』拒绝（core 指纹为空语义）")
    func emptyModelDirectoryIsRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-empty-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reason = SettingsViewModel.faceEmbeddingModelPathError(dir.path)
        let resolved = URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path
        #expect(reason == .modelNotFound(path: resolved), "实际：\(String(describing: reason))")
    }

    @Test("廉价校验：软链解析后合法路径放行（指向真实 .mlmodelc 目录）")
    func symlinkToModelDirectoryIsAccepted() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-target-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0x00]).write(to: target.appendingPathComponent("coremldata.bin"))
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-link-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        #expect(SettingsViewModel.faceEmbeddingModelPathError(link.path) == nil)
    }

    // MARK: - Cut 4 / 4b-2g：显式 L10n（动态 key / 日期 / 数字）

    @Test("保存提示按传入的 en L10n 渲染（动态 label 不回落中文）")
    func noticeUsesEnglishLabel() async {
        let (viewModel, settings) = makeViewModel(language: .en)
        let field = SettingField(
            key: "face_core_quality", type: .number(min: 0, max: 1),
            zhLabel: "核心点质量门槛", zhDesc: "")
        viewModel.edits["face_core_quality"] = "0.5"
        viewModel.saveField(field, with: en)
        #expect(await waitUntilAsync { viewModel.notice != nil }, "保存提示未在超时内落定")
        await waitForSets(settings, count: 1)

        let notice = viewModel.notice.map { en.resolve($0) } ?? ""
        #expect(notice == "Core-point quality floor saved", "实际：\(notice)")
        #expect(!notice.contains("核心点质量门槛"))
    }

    @Test("校验错误参数按传入的 en L10n 解析（「%@」模板 + 动态 label）")
    func validationErrorUsesEnglishLabel() {
        let (viewModel, settings) = makeViewModel()
        let field = SettingField(
            key: "detector_model_path", type: .text,
            zhLabel: "检测模型路径", zhDesc: "")
        viewModel.edits["detector_model_path"] = "   "
        viewModel.saveField(field, with: en)

        let resolved = viewModel.errorMessage.map { CommandErrorText.resolve($0, with: en) } ?? ""
        #expect(resolved == "“Detection Model Path” cannot be empty", "实际：\(resolved)")
        #expect(settings.setInputs.isEmpty)
    }

    @Test("dateText：跟随设置语言（zh/en），不再按系统 Locale 选格式")
    func dateTextFollowsSettingLanguage() {
        // 固定时刻：只依赖时区，不依赖「今天」。
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let zhText = SettingsViewModel.dateText(date, with: zh)
        let enText = SettingsViewModel.dateText(date, with: en)

        #expect(zhText == Self.mediumShort(date, locale: Locale(identifier: "zh_CN")))
        #expect(enText == Self.mediumShort(date, locale: Locale(identifier: "en_US")))
        #expect(zhText != enText)
        #expect(zhText.contains("年") && zhText.contains("月") && zhText.contains("日"))
        #expect(!enText.contains("年"))
    }

    /// 与 dateText 同一套系统格式化语义（medium 日期 + short 时间），仅显式 locale。
    private static func mediumShort(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    @Test("numberText：整数不带小数，其余两位小数（zh/en 同值）")
    func numberTextIsLocaleNeutral() {
        #expect(SettingsViewModel.numberText(2, with: zh) == "2")
        #expect(SettingsViewModel.numberText(0.5, with: zh) == "0.50")
        #expect(SettingsViewModel.numberText(0.5, with: en) == "0.50")
        #expect(SettingsViewModel.numberText(2, with: en) == "2")
    }
}
