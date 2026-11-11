// desktop/native/gather-app/Tests/GatherAppTests/MetadataTemplatePreviewFailureTests.swift
// D4（task-31 review）：预览读盘失败必须可被 UI 识别并禁用应用（与 apply 同源）。
import Foundation
import Testing
import GatherProtocol

@Suite("模板预览读盘失败（D4）")
struct MetadataTemplatePreviewFailureTests {
    @Test func failedPreviewIsMarkedForUI() {
        let result = MetadataTemplatePreviewResult(
            templateId: "t", templateName: "模板", totalPhotos: 2,
            changedPhotos: 1, changedFields: 1, conflictFields: 0,
            photos: [
                MetadataPhotoPreview(
                    photoId: "p1", writes: ["title"], clears: [], conflicts: []),
            ],
            failed: [MetadataTemplatePreviewFailure(photoId: "p2", message: "disk read failed")])
        #expect(result.hasReadFailures)
        #expect(result.readFailureCount == 1)
        #expect(result.failed?.first?.photoId == "p2")
    }

    @Test func oldJSONWithoutFailedStillDecodes() throws {
        let json = """
            {"templateId":"t","templateName":"模板","totalPhotos":1,
             "changedPhotos":0,"changedFields":0,"conflictFields":0,"photos":[]}
            """
        let result = try JSONDecoder().decode(
            MetadataTemplatePreviewResult.self, from: Data(json.utf8))
        #expect(!result.hasReadFailures)
    }
}
