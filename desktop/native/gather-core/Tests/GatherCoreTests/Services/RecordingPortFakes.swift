// desktop/native/gather-core/Tests/GatherCoreTests/Services/RecordingPortFakes.swift
// 测试替身收口（P2）：三个高频端口的共享可配置记录器。
//
// DeliveryFilePort / XMPProvider / MetadataMutationPort 在 GatherCoreTests 里原有
// 7 + 8 + 7 份本地实现（约 900 行），语义大量重复。本文件提供唯一实现，按需配置。
// 只放替身：不打开 DBConnection、不碰真实文件系统；测试串行执行，可变状态仅做记录，
// 因此三个类标 @unchecked Sendable（与 PortFakeSupport 的既有约定一致）。
//
// 与本地实现的有意差异：
// - 缺备份的 restore 统一抛 DeliveryCoordinatorError.backupMissing（本地私有错误
//   类型只用于 setRestoreFailure 注入，测试未断言缺备份错误类型）；
// - restore/remove 的调用记录发生在抛注入错误之前（与多数本地实现一致，失败次数
//   断言仍能看到"已尝试"）；
// - XMP 写合并字段集与真实写回器一致（descriptive/rating/label/keywords/triageSignal）。

import Foundation
import GatherProtocol
import GatherDelivery

// MARK: - 通用注入错误

/// 测试替身通用注入错误：只用于让端口抛错，不参与错误类型断言。
struct InjectedPortError: Error, Equatable, CustomStringConvertible {
    let operation: String

    init(_ operation: String) {
        self.operation = operation
    }

    var description: String { "INJECTED_PORT_ERROR: \(operation)" }
}

// MARK: - DeliveryFilePort

/// 可配置的内存 DeliveryFilePort 记录器：restore = 备份覆盖写 sidecar（幂等），
/// removeFile = 删内存键；失败开关在记录调用之后抛出（断言"已尝试但失败"）。
final class RecordingDeliveryFilePort: DeliveryFilePort, @unchecked Sendable {
    /// restore 进入后、写盘前的探针（file phase 竞态：在 await 窗口注入新输入）。
    var onRestore: (@Sendable () throws -> Void)?
    /// removeFile 进入后、删除前的探针。
    var onRemove: (@Sendable () throws -> Void)?

    private let lock = NSLock()
    private var storage: [String: String]
    private var restoredTargets: [String] = []
    private var removedPaths: [String] = []
    private var restoreFailure: Error?
    private var removeFailure: Error?

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func setContents(_ path: String, _ value: String) { lock.withLock { storage[path] = value } }
    func contents(_ path: String) -> String? { lock.withLock { storage[path] } }
    func setRestoreFailure(_ error: Error?) { lock.withLock { restoreFailure = error } }
    func clearRestoreFailure() { setRestoreFailure(nil) }
    func setRemoveFailure(_ error: Error?) { lock.withLock { removeFailure = error } }

    var restoreCallCount: Int { lock.withLock { restoredTargets.count } }
    var restoreTargets: [String] { lock.withLock { restoredTargets } }
    var removedPathsSnapshot: [String] { lock.withLock { removedPaths } }

    func fileExists(_ path: String) -> Bool { lock.withLock { storage[path] != nil } }

    func restore(photoPath: String, backupPath: String) async throws {
        // 与真实 XMPProvider 同一路径语义：photo.ext → photo.xmp（TSPath.xmpSidecarPath）。
        let target = TSPath.xmpSidecarPath(photoPath)
        try onRestore?()
        try lock.withLock {
            restoredTargets.append(target)
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
            }
            storage[target] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try onRemove?()
        try lock.withLock {
            removedPaths.append(path)
            if let removeFailure { throw removeFailure }
            storage.removeValue(forKey: path)
        }
    }
}

/// 前 N 次 removeFile 注入失败的包装端口（崩溃恢复：删备份失败 → replay 补删）。
final class FailingRemoveFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any DeliveryFilePort
    private let error: Error
    private var remainingFailures: Int

    init(
        inner: any DeliveryFilePort,
        failures: Int,
        error: Error = InjectedPortError("removeFile")
    ) {
        self.inner = inner
        self.error = error
        self.remainingFailures = failures
    }

    func fileExists(_ path: String) -> Bool { inner.fileExists(path) }

    func restore(photoPath: String, backupPath: String) async throws {
        try await inner.restore(photoPath: photoPath, backupPath: backupPath)
    }

    func removeFile(_ path: String) async throws {
        let fail = lock.withLock { () -> Bool in
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if fail { throw error }
        try await inner.removeFile(path)
    }
}

// MARK: - XMPProvider

/// 可配置的内存 XMPProvider 记录器。
///
/// 读：默认读 storage[path]；fixedAttributes 非 nil 时固定返回（单照片夹具）。
/// 可注入全局读错误 / 指定路径读错误 / 丢 GPS 时间 / triage 读回损坏。
/// 写：merge 模式按真实写回器的字段三态合并；ignore 模式只记录不落状态。
final class RecordingXMPProvider: XMPProvider, @unchecked Sendable {
    enum WriteMode: Sendable, Equatable {
        /// 不落状态，只记录 writeCalls（单照片夹具自己 setAttributes 控制读）。
        case ignore
        /// 按字段三态合并进 storage（与真实写回器一致）。
        case merge
    }

    private let lock = NSLock()
    private let writeMode: WriteMode
    private var storage: [String: MetadataWriteAttributes] = [:]
    private var fixedAttributes: MetadataWriteAttributes?
    private var forcedFileExists: Bool?
    private var fileExistsByDefault: Bool
    private var dropsGeoDateOnRead = false
    private var readError: Error?
    private var writeError: Error?
    private var writeCallsStorage: [MetadataWriteAttributes] = []

    /// 模拟宿主丢 GPS/时间（JPEG 内嵌目标的真实形态：写盘成功但读侧拿不到）。
    var corruptReadBack = false
    /// 指定路径读盘直接抛错（撤销探测失败）。
    var unreadablePaths: Set<String> = []

    init(
        attributes: MetadataWriteAttributes? = nil,
        writeMode: WriteMode = .merge,
        fileExists: Bool = false
    ) {
        self.fixedAttributes = attributes
        self.writeMode = writeMode
        self.fileExistsByDefault = fileExists
    }

    // MARK: 种子 / 查询 / 注入

    /// 固定返回给所有路径的属性（单照片夹具；赋值后覆盖 storage 语义）。
    var attributes: MetadataWriteAttributes {
        get { lock.withLock { fixedAttributes ?? MetadataWriteAttributes() } }
        set { lock.withLock { fixedAttributes = newValue } }
    }

    func seed(_ path: String, _ value: MetadataWriteAttributes) {
        lock.withLock { storage[path] = value }
    }

    func attributes(_ path: String) -> MetadataWriteAttributes { snapshot(path) }

    /// 单照片夹具的读值设置：与真实 SidecarXMP 同口径，空串 dateTaken 归一化为 nil。
    func setAttributes(_ value: MetadataWriteAttributes) {
        var normalized = value
        if let date = normalized.dateTaken,
           date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.dateTaken = nil
        }
        lock.withLock { fixedAttributes = normalized }
    }

    func setSidecarExists(_ exists: Bool) { lock.withLock { forcedFileExists = exists } }
    func setDropsGeoDateOnRead(_ drops: Bool) { lock.withLock { dropsGeoDateOnRead = drops } }
    func failReads(_ error: Error) { lock.withLock { readError = error } }

    /// 注入写盘失败（sidecar 损坏/权限）；注入后所有 writeAttributes 直接抛错。
    func setWriteFailure(_ error: Error?) { lock.withLock { writeError = error } }

    var writeCalls: [MetadataWriteAttributes] { lock.withLock { writeCallsStorage } }
    var writeCount: Int { lock.withLock { writeCallsStorage.count } }

    // MARK: 关键词助手（历史替身里的测试夹具 API）

    /// 按规范化折叠后的关键词做删除（大小写/空格差异视为等价词）。
    func removeKeywords(_ path: String, _ removed: [String]) {
        lock.withLock { mergeKeywords(path, added: [], removed: removed) }
    }

    /// 关键词 delta（added/removed）直接落到内存（模拟宿主写盘后的读回）。
    func applyDelta(photoPath: String, added: [String], removed: [String]) {
        lock.withLock { mergeKeywords(photoPath, added: added, removed: removed) }
    }

    // MARK: XMPProvider

    func readKeywords(photoPath: String) async throws -> [String] {
        snapshot(photoPath).keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        if let injected = lock.withLock({ readError }) { throw injected }
        if lock.withLock({ unreadablePaths.contains(photoPath) }) {
            throw InjectedPortError("readAttributes:\(photoPath)")
        }
        var value = snapshot(photoPath)
        if lock.withLock({ dropsGeoDateOnRead }) {
            // 丢 GPS/时间：其余字段原样保留；服务层回读必须判失败，不能谎报 written。
            value = MetadataWriteAttributes(
                keywords: value.keywords,
                rating: value.rating,
                label: value.label,
                descriptive: value.descriptive,
                triageSignal: value.triageSignal,
                keywordsMode: value.keywordsMode,
                replaceContact: value.replaceContact,
                clearedContactMembers: value.clearedContactMembers)
        }
        if corruptReadBack, value.triageSignal != nil {
            // 写盘成功但回读校验失败 → 服务层判 uncertain（不盲目回写）。
            value.rating = 99
        }
        return value
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        if let injected = lock.withLock({ writeError }) { throw injected }
        lock.withLock {
            writeCallsStorage.append(attributes)
            guard writeMode == .merge else { return }
            var current = storage[photoPath] ?? MetadataWriteAttributes()
            if let descriptive = attributes.descriptive {
                var merged = (current.descriptive ?? DescriptiveMetadata()).applying(descriptive)
                // 与 WritebackService+Execute 一致：只有补丁真的带 contact 才整块替换，
                // 否则"replace_contact=true + 无 contact 字段"会清空整块联系人（P0）。
                if attributes.replaceContact == true, let contact = descriptive.contactInfo {
                    merged.set(.contact(contact), for: .contactInfo)
                }
                // 真实补丁器把"空值"落成"元素不存在"，读回为 nil；替身必须同语义。
                for field in descriptive.explicitlySetFields
                where merged.value(for: field)?.isEmptyValue ?? false {
                    merged.set(nil, for: field)
                }
                current.descriptive = merged
            }
            if let rating = attributes.rating { current.rating = rating }
            if let label = attributes.label { current.label = label }
            if let keywords = attributes.keywords { current.keywords = keywords }
            if let signal = attributes.triageSignal {
                current.triageSignal = signal.isEmpty ? nil : signal
            }
            storage[photoPath] = current
        }
    }

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool {
        lock.withLock {
            if let forcedFileExists { return forcedFileExists }
            return fileExistsByDefault
        }
    }

    func removeFile(_ path: String) async throws {
        lock.withLock { _ = storage.removeValue(forKey: path) }
    }

    private func snapshot(_ path: String) -> MetadataWriteAttributes {
        lock.withLock { fixedAttributes ?? storage[path] ?? MetadataWriteAttributes() }
    }

    /// 锁内调用：按 fold 规范化做 delta 合并。
    private func mergeKeywords(_ path: String, added: [String], removed: [String]) {
        var value = storage[path] ?? MetadataWriteAttributes()
        let drop = Set(removed.map(KeywordNormalizer.fold))
        var keywords = (value.keywords ?? []).filter { !drop.contains(KeywordNormalizer.fold($0)) }
        keywords.append(contentsOf: added)
        value.keywords = keywords
        storage[path] = value
    }
}

// MARK: - MetadataMutationPort

/// 可配置的内存 MetadataMutationPort 记录器。
///
/// queuePhotoValues / queueKeywordDelta 记录入参并返回统一 pending result
/// （调用方当前均忽略返回值，端口只负责"确实被调用"的断言面）；
/// takePending() 复刻"值 → MetadataWriteAttributes"的旧替身语义。
final class RecordingMetadataMutation: MetadataMutationPort, @unchecked Sendable {
    struct KeywordDelta: Sendable {
        let photoId: String
        let added: [String]
        let removed: [String]
    }

    typealias QueuedValue = (
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    )

    /// flush 钩子：记录 sessionId 后 await，可注入失败。
    var flush: ((String) async throws -> Void)?
    /// keyword delta 观察钩子（返回结果前调用）。
    var onKeywordDelta: (([String], [String]) -> Void)?
    /// 指定照片的 keyword delta 注入失败（undo 失败累积语义）。
    var failKeywordDeltaFor: Set<String> = []
    /// queuePhotoValues 注入失败（旧替身用来断言"未走该路径"）。
    var queueValuesError: Error?

    private let lock = NSLock()
    private var queuedStorage: [QueuedValue] = []
    private var deltasStorage: [(sessionId: String, photoId: String, added: [String], removed: [String])] = []
    private var pendingAttributesStorage: [String: MetadataWriteAttributes] = [:]

    var queued: [QueuedValue] { lock.withLock { queuedStorage } }

    func flushQueuedMetadata(sessionId: String) async throws {
        try await flush?(sessionId)
    }

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        if let queueValuesError { throw queueValuesError }
        lock.withLock {
            queuedStorage.append((sessionId, photoId, values, source, schedule))
            pendingAttributesStorage[photoId] = MetadataWriteAttributes(jsonValue: .object(values))
        }
        return Self.result(photoId: photoId, dirtyFields: [])
    }

    func queueKeywordDelta(
        sessionId: String,
        photoId: String,
        added: [String],
        removed: [String],
        owned: [String: Set<MetadataMutationSource>],
        existingKeywords: [String]?
    ) async throws -> MetadataMutationResult? {
        if failKeywordDeltaFor.contains(photoId) {
            throw GatherError.invalidParameter(
                field: "photoId", reason: "injected keyword delta failure")
        }
        onKeywordDelta?(added, removed)
        lock.withLock { deltasStorage.append((sessionId, photoId, added, removed)) }
        return Self.result(photoId: photoId, dirtyFields: [.keywords])
    }

    /// 取出并清空 queuePhotoValues 记录（photoId + values 元组，供旧 drain() 调用点）。
    func drainValues() -> [(photoId: String, values: [String: JSONValue])] {
        lock.withLock {
            let result = queuedStorage.map { (photoId: $0.photoId, values: $0.values) }
            queuedStorage.removeAll()
            return result
        }
    }

    /// 取出并清空 keyword delta 记录（SemanticKeywordWritebackTests 的旧 drain()）。
    func drainKeywordDeltas() -> [KeywordDelta] {
        lock.withLock {
            let result = deltasStorage.map {
                KeywordDelta(photoId: $0.photoId, added: $0.added, removed: $0.removed)
            }
            deltasStorage.removeAll()
            return result
        }
    }

    /// 值 → 属性队列（MetadataService 的地理/时间写盘夹具用）：取出后清空。
    func takePending() -> [String: MetadataWriteAttributes] {
        lock.withLock {
            let result = pendingAttributesStorage
            pendingAttributesStorage = [:]
            return result
        }
    }

    private static func result(
        photoId: String,
        dirtyFields: [MetadataField]
    ) -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: dirtyFields, revision: 1, status: "pending")
    }
}
