// desktop/native/gather-app/Tests/GatherAppTests/SettingsSaveSemanticsTests.swift
// 设置保存语义（本轮修复 + 新旋钮可写性）：
//   ① 默认值为空的文本键必须能清空——face_embedding_model_path 清空 = 回到内置 Vision 特征，
//      旧实现一刀切拒绝空值，用户一旦填错模型路径就再也退不回来；
//   ② 默认值非空的键留空仍按无效输入拒绝；
//   ③ 保存提示必须用界面标签（zhLabel）而不是内部键（审查发现「已保存 thumbnail_size」）；
//   ④ 新增的人脸算法参数必须能真正写进去（键在默认表、值过校验、命令参数正确）。

import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("settings 保存语义")
@MainActor
struct SettingsSaveSemanticsTests {
    private func makeViewModel() -> (SettingsViewModel, StubCommandRouter) {
        let router = StubCommandRouter(responses: ["settings.set": .object([:])])
        return (SettingsViewModel(router: router), router)
    }

    @Test("默认值为空的文本键允许清空（专用人脸模型路径 → 回到内置 Vision）")
    func clearingDefaultEmptyTextKeyIsAllowed() {
        let (viewModel, router) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        viewModel.edits["face_embedding_model_path"] = "   "
        viewModel.saveField(field)

        #expect(viewModel.errorMessage == nil)
        let saved = router.executed.contains { entry in
            entry.command == "settings.set"
                && entry.params["key"] == .string("face_embedding_model_path")
                && entry.params["value"] == .string("")
        }
        #expect(saved, "清空模型路径必须真的写入空串（= 回到内置 Vision）")
    }

    @Test("默认值非空的文本键留空仍被拒绝，且不写入")
    func clearingNonEmptyDefaultKeyIsRejected() {
        let (viewModel, router) = makeViewModel()
        let field = SettingField(
            key: "detector_model_path", type: .text,
            zhLabel: "检测模型路径", zhDesc: "")
        viewModel.edits["detector_model_path"] = ""
        viewModel.saveField(field)

        #expect(viewModel.errorMessage != nil)
        #expect(!router.executed.contains { $0.command == "settings.set" })
    }

    @Test("保存提示用人类标签，不暴露内部键")
    func noticeUsesHumanLabel() {
        let (viewModel, _) = makeViewModel()
        let field = SettingField(
            key: "face_core_quality", type: .number(min: 0, max: 1),
            zhLabel: "核心点质量门槛", zhDesc: "")
        viewModel.edits["face_core_quality"] = "0.5"
        viewModel.saveField(field)

        let notice = viewModel.notice ?? ""
        #expect(notice.contains("核心点质量门槛"))
        #expect(!notice.contains("face_core_quality"))
    }

    @Test("数值越界不落库（质量门槛 > 1）")
    func outOfRangeNumberIsRejected() {
        let (viewModel, router) = makeViewModel()
        let field = SettingField(
            key: "face_core_quality", type: .number(min: 0, max: 1),
            zhLabel: "核心点质量门槛", zhDesc: "")
        viewModel.edits["face_core_quality"] = "1.5"
        viewModel.saveField(field)

        #expect(viewModel.errorMessage != nil)
        #expect(!router.executed.contains { $0.command == "settings.set" })
    }

    @Test("不存在的模型路径保存即拒绝：与 core 逐字一致的中文原因，且不写入")
    func missingModelPathIsRejectedOnSave() {
        let (viewModel, router) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        let missing = "/tmp/gather-missing-model-\(UUID().uuidString).mlmodelc"
        viewModel.edits["face_embedding_model_path"] = missing
        viewModel.saveField(field)

        // 关键：错误原因直接给用户（此前会潜伏到分析时才以"发生未知错误"爆出）。
        let expected = FaceEmbeddingError
            .modelNotFound(URL(fileURLWithPath: missing).resolvingSymlinksInPath().path)
            .description
        #expect(viewModel.errorMessage == expected)
        #expect((viewModel.errorMessage ?? "").contains("人脸嵌入模型不存在"))
        #expect(!router.executed.contains { $0.command == "settings.set" }, "不存在的模型路径不得入库")
    }

    @Test("标签查表：滑杆键、分组键、未知键")
    func labelLookup() {
        #expect(SettingsViewModel.label(for: "face_match_margin") == "歧义判定间隔")
        #expect(SettingsViewModel.label(for: "face_embedding_model_path") == "专用人脸模型路径")
        #expect(SettingsViewModel.label(for: "face_incremental_clustering") == "增量聚类")
        #expect(SettingsViewModel.label(for: "no_such_key") == "no_such_key")
    }

    @Test("新增人脸参数端到端可写（界面 → settings.set 参数正确）")
    func faceAlgorithmKeysAreWritable() {
        let (viewModel, router) = makeViewModel()
        let margin = SettingField(
            key: "face_match_margin", type: .number(min: 0, max: 0.2),
            zhLabel: "歧义判定间隔", zhDesc: "")
        viewModel.edits["face_match_margin"] = "0.05"
        viewModel.saveField(margin)

        let retry = SettingField(
            key: "face_core_retry_min_samples", type: .number(min: 1, max: 10),
            zhLabel: "二遍最小样本数", zhDesc: "")
        viewModel.edits["face_core_retry_min_samples"] = "3"
        viewModel.saveField(retry)

        let modelVersion = SettingField(
            key: "face_embedding_model_version", type: .text,
            zhLabel: "模型版本标签", zhDesc: "")
        viewModel.edits["face_embedding_model_version"] = "arcface-r100-w600k"
        viewModel.saveField(modelVersion)

        let sent = router.executed.filter { $0.command == "settings.set" }
        #expect(sent.count == 3)
        #expect(sent.contains { $0.params["key"] == .string("face_match_margin")
            && $0.params["value"] == .string("0.05") })
        #expect(sent.contains { $0.params["key"] == .string("face_core_retry_min_samples")
            && $0.params["value"] == .string("3") })
        #expect(sent.contains { $0.params["key"] == .string("face_embedding_model_version")
            && $0.params["value"] == .string("arcface-r100-w600k") })
    }

    // ── 保存不再加载/哈希（V1 探针 I：256 MiB 模型同步加载 48.4s 卡主线程）──

    @Test("廉价校验：垃圾 .mlmodelc 包（存在 + 扩展名合法）放行，不做加载/哈希")
    func junkModelPackageIsAcceptedWithoutLoading() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-junk-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x00]).write(to: dir.appendingPathComponent("model.mil"))
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧实现会走 MLModel 编译/加载 + 内容指纹哈希并抛 modelLoadFailed；
        // 新实现只做存在性/扩展名判定 → 放行（能否真正加载由分析路径负责）。
        #expect(SettingsViewModel.faceEmbeddingModelPathError(dir.path) == nil)

        let (viewModel, router) = makeViewModel()
        let field = SettingField(
            key: "face_embedding_model_path", type: .text,
            zhLabel: "专用人脸模型路径", zhDesc: "")
        viewModel.edits["face_embedding_model_path"] = dir.path
        viewModel.saveField(field)
        #expect(viewModel.errorMessage == nil, "廉价校验不得加载模型（垃圾包也应可保存）")
        #expect(router.executed.contains {
            $0.command == "settings.set" && $0.params["value"] == .string(dir.path)
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
        #expect(reason == FaceEmbeddingError.modelNotFound(resolved).description)
        #expect(!(reason ?? "").contains("~"), "~ 必须展开后再报路径，实际：\(reason ?? "")")
    }

    @Test("廉价校验：扩展名不是 .mlmodel/.mlmodelc → 与 core 同款中文原因")
    func unsupportedExtensionIsRejected() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-\(UUID().uuidString).onnx")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reason = SettingsViewModel.faceEmbeddingModelPathError(url.path)
        #expect(reason == FaceEmbeddingError.unsupportedModelFormat("onnx").description)
        #expect((reason ?? "").contains("不支持的人脸嵌入模型扩展名"))
    }

    @Test("廉价校验：空目录 .mlmodelc 按『模型不存在』拒绝（core 指纹为空语义）")
    func emptyModelDirectoryIsRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gather-empty-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reason = SettingsViewModel.faceEmbeddingModelPathError(dir.path)
        #expect(reason?.contains("人脸嵌入模型不存在") == true, "实际：\(reason ?? "")")
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
}
