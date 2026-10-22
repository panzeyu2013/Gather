// desktop/native/gather-core/Sources/GatherPersistence/Ports/NavigationRepository.swift
// WP3b-1：Navigation 查询/写入端口。
import Foundation

public protocol NavigationRepository {
    func listGroups(sessionId: String) throws -> [NavigationGroupRow]
    func captureRows(sessionId: String) throws -> [NavigationCaptureRow]
    func cachedFingerprint(sessionId: String) throws -> String?
    func replaceGroup(sessionId: String, groupId: String, with groups: [NavigationGroupWrite]) throws
    func mergeGroups(sessionId: String, groupIds: [String], into group: NavigationGroupWrite) throws
    func manualGroups(sessionId: String) throws -> [(type: String, photoIdsJSON: String)]
    func replaceAutomaticGroups(sessionId: String, groups: [NavigationGroupWrite]) throws
}

extension NavigationRepo: NavigationRepository {}
