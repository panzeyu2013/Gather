// desktop/native/gather-core/Sources/GatherCore/Runtime/FaceKeywording/FaceKwError.swift
// fkwerr：FaceKeywording 错误类型的归属裁决 —— 属 Runtime 层。
//
// 来源：自 Services/FaceKeywordingRuntime.swift 机械搬迁（枚举/描述/错误码映射逐字
// 不变），唯一变化是类型名去掉 Service 后缀改为 FaceKwError，对齐既有先例
// （Navigation 错误类型搬迁时改为 NavigationError）与 Runtime/{Similarity,
// Quality,Duplicate,Export}/<Feature>Error.swift 的命名。全仓引用已同步，
// 不保留兼容别名/双定义。
//
// 归属理由：Runtime/FaceKeywording/FaceKeywordAssembler.swift L65/68 是唯一
// 跨层抛出方（聚类参数校验），Services/FaceKeywordingRuntime.swift 只做透传；Runtime
// 层必须能独立表达自身错误，且本类型不依赖 Store/SQL/文件系统（仅值类型 +
// GatherErrorCode 映射，与 QualityError 同形）。

import Foundation

public enum FaceKwError: Error, Equatable {
    /// TS: ValidationError('FACE_EPS_INVALID')
    case epsInvalid
    /// TS: ValidationError('FACE_MIN_CLUSTER_INVALID')
    case minClusterInvalid
    /// TS: Error('FKW_ANALYSIS_RUNNING')
    case analysisRunning
    /// TS: NotFoundError('SESSION_NOT_FOUND')
    case sessionNotFound
    /// TS: ValidationError('FACE_NO_PHOTOS')
    case noPhotos
    /// TS: Error('FACE_WORKERS_INIT_FAILED')
    case workersInitFailed
    /// TS: ValidationError('FKW_NO_OBSERVATIONS')
    case noObservations
    /// TS: NotFoundError('FKW_CLUSTER_NOT_FOUND')
    case clusterNotFound
    /// TS: ValidationError('FKW_CLUSTER_NOT_IN_SESSION')
    case clusterNotInSession
    /// TS: NotFoundError('FKW_CLUSTER_MEMBER_NOT_FOUND')
    case clusterMemberNotFound
    /// TS: ValidationError('FKW_ROLE_NAME_EMPTY')
    case roleNameEmpty
    /// TS: ValidationError('FKW_KEYWORDS_INVALID')
    case keywordsInvalid
    /// TS: ValidationError('FACE_SELF_MERGE')
    case selfMerge
    /// TS: Error('FKW_UNBIND_CONFIRM_REQUIRED')
    case unbindConfirmRequired
    /// TS: Error('WRITEBACK_CONFIRM_REQUIRED')
    case writebackConfirmRequired
    /// TS: Error('FKW_ITEMS_INVALID')
    case itemsInvalid
    /// TS: Error('FKW_CLEANUP_CONFIRM_REQUIRED')
    case cleanupConfirmRequired
    /// 写回 Provider 未注入（迁移接缝，非 TS 错误码；3.4 Wave 接线后不可达）。
    case writebackProviderMissing
}

/// TS 错误消息逐字对齐（executor 失败路径经 JobService 以 String(describing:)
/// 记录为 errorMessage，必须等于 TS error.message）。
extension FaceKwError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .epsInvalid: "FACE_EPS_INVALID"
        case .minClusterInvalid: "FACE_MIN_CLUSTER_INVALID"
        case .analysisRunning: "FKW_ANALYSIS_RUNNING"
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .noPhotos: "FACE_NO_PHOTOS"
        case .workersInitFailed: "FACE_WORKERS_INIT_FAILED"
        case .noObservations: "FKW_NO_OBSERVATIONS"
        case .clusterNotFound: "FKW_CLUSTER_NOT_FOUND"
        case .clusterNotInSession: "FKW_CLUSTER_NOT_IN_SESSION"
        case .clusterMemberNotFound: "FKW_CLUSTER_MEMBER_NOT_FOUND"
        case .roleNameEmpty: "FKW_ROLE_NAME_EMPTY"
        case .keywordsInvalid: "FKW_KEYWORDS_INVALID"
        case .selfMerge: "FACE_SELF_MERGE"
        case .unbindConfirmRequired: "FKW_UNBIND_CONFIRM_REQUIRED"
        case .writebackConfirmRequired: "WRITEBACK_CONFIRM_REQUIRED"
        case .itemsInvalid: "FKW_ITEMS_INVALID"
        case .cleanupConfirmRequired: "FKW_CLEANUP_CONFIRM_REQUIRED"
        case .writebackProviderMissing: "WRITEBACK_PROVIDER_NOT_INJECTED"
        }
    }
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension FaceKwError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .epsInvalid: .FACE_EPS_INVALID
        case .minClusterInvalid: .FACE_MIN_CLUSTER_INVALID
        case .analysisRunning: .FKW_ANALYSIS_RUNNING
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .noPhotos: .FACE_NO_PHOTOS
        case .workersInitFailed: .FACE_WORKERS_INIT_FAILED
        case .noObservations: .FKW_NO_OBSERVATIONS
        case .clusterNotFound: .FKW_CLUSTER_NOT_FOUND
        case .clusterNotInSession: .FKW_CLUSTER_NOT_IN_SESSION
        case .clusterMemberNotFound: .FKW_CLUSTER_MEMBER_NOT_FOUND
        case .roleNameEmpty: .FKW_ROLE_NAME_EMPTY
        case .keywordsInvalid: .FKW_KEYWORDS_INVALID
        case .selfMerge: .FACE_SELF_MERGE
        case .unbindConfirmRequired: .FKW_UNBIND_CONFIRM_REQUIRED
        case .writebackConfirmRequired: .WRITEBACK_CONFIRM_REQUIRED
        case .itemsInvalid: .FKW_ITEMS_INVALID
        case .cleanupConfirmRequired: .FKW_CLEANUP_CONFIRM_REQUIRED
        case .writebackProviderMissing: .WRITEBACK_OTHER_MODULE_ACTIVE
        }
    }
}
