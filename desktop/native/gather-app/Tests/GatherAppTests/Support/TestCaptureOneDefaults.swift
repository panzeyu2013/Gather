// desktop/native/gather-app/Tests/GatherAppTests/Support/TestCaptureOneDefaults.swift
// Cut 3 / 3b-3（E-17）测试适配：生产构造器已删掉「默认自建 CaptureOneBridge」，
// 测试只关心 VM 的其它依赖，这里补一层**仅测试可见**的便利构造器。
//
// 注意：这是测试夹具，不是生产兜底——生产装配（RootView/AppBootstrap）必须
// 显式注入组合根构造的桥，否则 reload ack 会再次被静默丢弃。
import Foundation
import GatherProtocol
import GatherHost
import GatherUI

extension CullingViewModel {
    convenience init(
        sessionId: String,
        culling: any CullingAPI,
        navigation: any NavigationAPI,
        metadata: any MetadataAPI,
        jobs: any JobAPI,
        quality: any QualityAPI,
        qualityPollIntervalMilliseconds: Int? = nil
    ) {
        self.init(
            sessionId: sessionId,
            culling: culling,
            navigation: navigation,
            metadata: metadata,
            jobs: jobs,
            quality: quality,
            captureOne: CaptureOneBridge(),
            qualityPollIntervalMilliseconds: qualityPollIntervalMilliseconds
                ?? CullingViewModel.defaultQualityPollIntervalMilliseconds
        )
    }
}

extension SimilarityViewModel {
    convenience init(
        sessionId: String,
        similarity: any SimilarityAPI,
        jobs: any JobAPI,
        pollInterval: Duration = .seconds(1),
        resultPollInterval: Duration = .seconds(2),
        tierDebounceDelay: Duration = .milliseconds(300)
    ) {
        self.init(
            sessionId: sessionId,
            similarity: similarity,
            jobs: jobs,
            pollInterval: pollInterval,
            resultPollInterval: resultPollInterval,
            tierDebounceDelay: tierDebounceDelay,
            captureOne: CaptureOneBridge()
        )
    }
}

extension SettingsViewModel {
    convenience init(
        session: any SessionAPI,
        settings: any SettingsAPI,
        culling: any CullingAPI
    ) {
        self.init(
            session: session,
            settings: settings,
            culling: culling,
            captureOne: CaptureOneBridge(),
            // 4a-3a：语言 store 也是生产 init 的必填依赖；测试用独立
            // NotificationCenter，避免订阅进程级 languageChanged。
            languageStore: LanguageStore(
                language: nil,
                notificationCenter: NotificationCenter()
            )
        )
    }
}
