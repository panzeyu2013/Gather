// Tests/GatherAppTests/Support/TestCommandSurface+Domains.swift
// 测试共享：在空命令面基础上替换单个域（避免测试为无关域写 19 个替身）。
import Foundation
import GatherCore

extension CommandSurface {
    func replacingFace(_ face: any FaceCommands) -> CommandSurface {
        CommandSurface(
            album: album, assets: assets, culling: culling, duplicate: duplicate,
            export: export, face: face, filter: filter, index: index, jobs: jobs,
            metadata: metadata, navigation: navigation, person: person, photo: photo,
            quality: quality, session: session, settings: settings,
            similarity: similarity, template: template, workspace: workspace
        )
    }
}
