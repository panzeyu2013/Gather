// desktop/native/gather-app/Tests/GatherAppTests/MetadataDiskStateTests.swift
// D3（task-31 review）：批量直改的 diskKnown 判定——无 sidecar 且盘上为空 = 未知，
// 不能把导入包照片的缓存 IPTC 判成外部改动。
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("批量直改盘上可信度（D3）")
struct MetadataDiskStateTests {
    private func availability(
        title: String?, sidecarExists: Bool
    ) -> DiskDescriptiveAvailability {
        var descriptive = DescriptiveMetadata()
        descriptive.title = title
        return DiskDescriptiveAvailability(
            descriptive: descriptive, sidecarExists: sidecarExists)
    }

    @Test func unavailableIsUnknown() {
        let fallback = DescriptiveMetadata(title: "缓存标题")
        let state = MetadataBatchEditorSheet.diskState(
            availability: nil, fallback: fallback)
        #expect(!state.known)
        #expect(state.descriptive.title == "缓存标题")
    }

    @Test func emptyWithoutSidecarIsUnknown() {
        let state = MetadataBatchEditorSheet.diskState(
            availability: availability(title: nil, sidecarExists: false),
            fallback: DescriptiveMetadata(title: "缓存标题"))
        #expect(!state.known, "无 sidecar 且盘上为空时不能断言「盘上已知为空」")
        #expect(state.descriptive.title == "缓存标题", "未知时仍用缓存作当前值基线")
    }

    @Test func embeddedValueWithoutSidecarIsKnown() {
        let state = MetadataBatchEditorSheet.diskState(
            availability: availability(title: "盘上标题", sidecarExists: false),
            fallback: DescriptiveMetadata())
        #expect(state.known, "JPEG 内嵌 IPTC 无 sidecar 也是可信盘上值")
        #expect(state.descriptive.title == "盘上标题")
    }

    @Test func sidecarEmptyIsKnown() {
        let state = MetadataBatchEditorSheet.diskState(
            availability: availability(title: nil, sidecarExists: true),
            fallback: DescriptiveMetadata(title: "缓存标题"))
        #expect(state.known, "sidecar 存在时盘上空值可信，cache 差异应判外部改动")
    }
}
