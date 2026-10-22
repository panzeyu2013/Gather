// desktop/native/gather-app/Tests/GatherAppTests/Support/StubSettingsAPI.swift
// Cut 1 / B8.1b：SettingsAPI 的类型化替身（B8.1a 未覆盖设置域）。
//
// 取代 SettingsSaveSemanticsTests 里的 "settings.set" 响应表 + executed 命令名
// 断言：用例直接断言 SettingsSetInput.key/value 与提示/错误语义，走的是页面
// 生产路径（settingsAPI 非 nil 分支），不再为了测试去构造字符串命令响应。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

private struct B8SettingsState {
    var values: [String: String] = [:]
    var allError: (any Error)?
    var getError: (any Error)?
    var setError: (any Error)?
    var resetError: (any Error)?
    var languageError: (any Error)?
    var mlStatusError: (any Error)?
    var languageResult: InterfaceLanguage = .zhCN
    var mlStatusResult = MLStatusData(
        platform: "macOS",
        autoBackend: "",
        autoBackendLabel: "",
        provider: "",
        isAuto: true,
        availableBackends: [],
        modelResourcesDir: "",
        detectorModel: MLModelPresence(path: "", resolvedPath: nil, exists: false),
        encoderModel: MLModelPresence(path: "", resolvedPath: nil, exists: false),
        modelInfo: MLModelInfo(
            detectInputSize: 0, secondaryDetectInputSize: 0,
            previewMaxDimension: 0, encoderInputSize: 0, embeddingDim: 0
        )
    )
    var setInputs: [SettingsSetInput] = []
    var getKeys: [SettingsKey] = []
    var resetCalls = 0
    var languageInputs: [InterfaceLanguage] = []
    var mlStatusCalls = 0
}

/// 可配置 SettingsAPI：默认空设置表、set 成功；记录类型化入参。
final class B8SettingsAPIStub: SettingsAPI, @unchecked Sendable {
    private let box = LockedBox(B8SettingsState())

    init(values: [String: String] = [:]) {
        box.lock.withLock { box.values = values }
    }

    var values: [String: String] {
        get { box.lock.withLock { box.values } }
        set { box.lock.withLock { box.values = newValue } }
    }

    var allError: (any Error)? {
        get { box.lock.withLock { box.allError } }
        set { box.lock.withLock { box.allError = newValue } }
    }

    var setError: (any Error)? {
        get { box.lock.withLock { box.setError } }
        set { box.lock.withLock { box.setError = newValue } }
    }

    var mlStatusError: (any Error)? {
        get { box.lock.withLock { box.mlStatusError } }
        set { box.lock.withLock { box.mlStatusError = newValue } }
    }

    var mlStatusResult: MLStatusData {
        get { box.lock.withLock { box.mlStatusResult } }
        set { box.lock.withLock { box.mlStatusResult = newValue } }
    }

    var setInputs: [SettingsSetInput] { box.lock.withLock { box.setInputs } }
    var getKeys: [SettingsKey] { box.lock.withLock { box.getKeys } }
    var resetCalls: Int { box.lock.withLock { box.resetCalls } }
    var languageInputs: [InterfaceLanguage] { box.lock.withLock { box.languageInputs } }
    var mlStatusCalls: Int { box.lock.withLock { box.mlStatusCalls } }

    func all() async throws -> [String: String] {
        let (error, values): ((any Error)?, [String: String]) = box.lock.withLock {
            (box.allError, box.values)
        }
        if let error { throw error }
        return values
    }

    func get(_ key: SettingsKey) async throws -> String {
        let (error, values): ((any Error)?, [String: String]) = box.lock.withLock {
            box.getKeys.append(key)
            return (box.getError, box.values)
        }
        if let error { throw error }
        return values[key.value] ?? ""
    }

    func set(_ input: SettingsSetInput) async throws {
        let error: (any Error)? = box.lock.withLock {
            box.setInputs.append(input)
            return box.setError
        }
        if let error { throw error }
        box.lock.withLock { box.values[input.key.value] = input.value.value }
    }

    func reset() async throws -> [String: String] {
        let error: (any Error)? = box.lock.withLock {
            box.resetCalls += 1
            return box.resetError
        }
        if let error { throw error }
        return box.lock.withLock {
            box.values = [:]
            return box.values
        }
    }

    func setLanguage(_ language: InterfaceLanguage) async throws -> InterfaceLanguage {
        let (error, result): ((any Error)?, InterfaceLanguage) = box.lock.withLock {
            box.languageInputs.append(language)
            return (box.languageError, box.languageResult)
        }
        if let error { throw error }
        return result
    }

    func mlStatus() async throws -> MLStatusData {
        let (error, result): ((any Error)?, MLStatusData) = box.lock.withLock {
            box.mlStatusCalls += 1
            return (box.mlStatusError, box.mlStatusResult)
        }
        if let error { throw error }
        return result
    }
}
