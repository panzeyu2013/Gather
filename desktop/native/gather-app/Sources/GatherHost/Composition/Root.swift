// desktop/native/gather-app/Sources/GatherHost/Composition/Root.swift
// WP4c / 组合根阶段 4：AppServices 装配。
//
// 唯一职责：把 FeatureAPIs 的 16 个 Live API 装进 AppServices（runtime 直接取
// composition.runtime）。本文件不构造业务服务、不打开数据库、不注册 executor；
// AppServices.live(composition:) 是唯一公开入口，委托到这里。
import Foundation
import GatherProtocol

/// AppServices 装配：16 个 Live API + 组合根唯一的 AppRuntime。
enum AppServicesRoot {
    static func make(composition: AppComposition) -> AppServices {
        let apis = FeatureAPIs(composition: composition)
        return AppServices(
            session: apis.session,
            job: apis.job,
            settings: apis.settings,
            photo: apis.photo,
            asset: apis.asset,
            album: apis.album,
            navigation: apis.navigation,
            culling: apis.culling,
            face: apis.face,
            similarity: apis.similarity,
            duplicate: apis.duplicate,
            quality: apis.quality,
            export: apis.export,
            metadata: apis.metadata,
            person: apis.person,
            maintenance: apis.maintenance,
            runtime: composition.runtime
        )
    }
}
