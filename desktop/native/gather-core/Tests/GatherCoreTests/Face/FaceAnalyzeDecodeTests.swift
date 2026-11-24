// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceAnalyzeDecodeTests.swift
// P1（rev-swift 并发复审）：analyze 的照片级落库粒度、失败降级与解码并发 seam。
//
// 覆盖：
// 1. 批事务次数 = ceil(照片数 / batchWindow)——用**真正开事务**并计数的
//    TransactionRunner 替身，在 "face.detect" 起点与 "face.cluster" 相位各取一次计数；
// 2. 批内一张写失败时其余照片仍落库、detectionFailures 只计那一张（降级逐张重试），
//    且不再把整轮污染成 allDetectionsFailed；
// 3. 并发解码 seam（analyze 实际调用的 `decodeConcurrently`，注入计数解码器）：在飞
//    解码数 ≤ concurrency、结果按原索引归位、abort 后不再发起解码；
// 4. 解码并发度纯函数（resolveDecodeConcurrency）：自动值保底、显式更大才覆盖、
//    上限 16、0/负数 = 自动。
//
// 边界：内存 SchemaCurrent + 临时真实文件；解码/推理以闭包替身注入。注入的
// DecodeProvider 不是 @Sendable，analyze 只能走串行分支，所以第 3 项测的是同一个
// 函数的 seam，不是端到端 analyze；端到端并发仍由 -c / -emit-sil 编译探针 + 真机
// 耗时验收覆盖。
import Foundation
import Synchronization
import Testing
import GatherTestSupport
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherPersistence

/// 计数 + 真实事务的 TransactionRunner 替身。
///
/// 为什么不直接用 PortFakeTransactionRunner：它只数数、不真正开事务，批写入失败时
/// 已经写下的照片不会被回滚——那样「一批一事务」与「批失败降级」两件事都测不出来。
/// 这里把闭包转发给 DBConnection：嵌套仍退化为 SAVEPOINT，语义与生产完全一致。
final class CountingDBTransactionRunner: TransactionRunner {
    private let base: DBConnection
    private let started = Mutex(0)

    init(base: DBConnection) {
        self.base = base
    }

    var transactionCount: Int { started.withLock { $0 } }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        started.withLock { $0 += 1 }
        return try base.transaction(body)
    }
}

/// 进度回调里取样事务计数（闭包捕获可变 var 在 Swift 6 下是硬错误，用类承载）。
final class FaceAnalyzeProgressProbe {
    private let transactions: CountingDBTransactionRunner
    /// "face.detect" 起点（current == 0）时的事务数：此刻只有照片/index_seq 快照读。
    private(set) var countAtDetectStart: Int?
    /// "face.cluster" 相位开始时的事务数：批事务已全部结束、C 阶段尚未开始。
    private(set) var countAtClusterPhase: Int?

    init(transactions: CountingDBTransactionRunner) {
        self.transactions = transactions
    }

    func record(current: Int, total: Int, phase: String) {
        if phase == "face.detect", current == 0, countAtDetectStart == nil {
            countAtDetectStart = transactions.transactionCount
        }
        if phase == "face.cluster" && countAtClusterPhase == nil {
            countAtClusterPhase = transactions.transactionCount
        }
    }
}

/// 并发解码探针：actor 串行化计数（@Sendable 解码闭包只捕获 actor，本身即 Sendable）。
private actor FaceDecodeProbe {
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var calls = 0

    func enter() {
        inFlight += 1
        calls += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func leave() { inFlight -= 1 }

    func snapshot() -> (calls: Int, maxInFlight: Int) { (calls, maxInFlight) }
}

/// 注入解码：把文件路径写进 buffer。推理替身只有 [Data]，用路径才能区分「哪一张照片」。
private func faceDecodeProvider() -> FaceKwService.DecodeProvider {
    { path, _ in Data(path.utf8) }
}

/// 注入推理：每张图 1 张脸；路径后缀命中 `poisonSuffix` 的那张写 quality = 2.0，
/// 故意违反 face_observations.quality 的 CHECK(quality BETWEEN 0 AND 1)，制造
/// 「这一张真的写不进去」的写失败（不是伪造仓储错误）。
private func faceInferenceProvider(poisonSuffix: String?) -> FaceKwService.FaceInferenceProvider {
    { images, _, _ in
        images.map { image in
            let path = String(decoding: image, as: UTF8.self)
            let quality = isPoisoned(path: path, suffix: poisonSuffix) ? 2.0 : 1.0
            return FaceInferenceItem(observations: [
                FaceInferenceObservation(
                    bbox: [0.1, 0.1, 0.2, 0.2],
                    confidence: 0.9,
                    embedding: [1, 0],
                    quality: quality)
            ])
        }
    }
}

private func isPoisoned(path: String, suffix: String?) -> Bool {
    guard let suffix else { return false }
    return path.hasSuffix(suffix)
}

/// 只覆盖本用例关心的两个键：批窗口与推理 worker 数（其余走 SettingsKey 默认值）。
private func faceSettings(batchWindow: String, inferenceWorkers: String) -> any SettingsReading {
    ClosureSettingsReader { key in
        switch key {
        case .faceDecodeConcurrency: return batchWindow
        case .faceInferenceParallelWorkers: return inferenceWorkers
        default: return nil
        }
    }
}

/// 生产 init 装配：真实 Repo + 计数事务端口 + 注入解码/推理；交付端口用测试替身
/// （analyze 不碰交付层，走到会立刻抛 unimplemented）。
private func makeFaceService(
    db: DBConnection,
    transactions: CountingDBTransactionRunner,
    settings: any SettingsReading,
    inference: @escaping FaceKwService.FaceInferenceProvider
) -> FaceKwService {
    FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: SessionRepo(connection: db),
        faceRepo: FaceRepo(connection: db),
        personRepo: PersonRepo(connection: db),
        feedback: FaceFeedbackRepo(connection: db),
        analysisRuns: AnalysisRunRepo(connection: db),
        deliveryItems: DeliveryRepo(connection: db),
        transactions: transactions,
        settings: settings,
        decodeProvider: faceDecodeProvider(),
        inferenceProvider: inference,
        delivery: PortFakeDeliveryAdapter(module: .faceKeyword)
    )
}

@Suite("FaceKwService.analyze：批事务粒度与失败降级")
struct FaceAnalyzeDecodeTests {
    /// 每批一事务：9 张照片 / 批窗口 2 = 5 个批事务。
    /// worker 数固定 "1"，照片按连续下标攒批（否则批组成随轮询变化，ceil 不成立）。
    @Test func batchTransactionCountMatchesCeilOfPhotosPerWindow() async throws {
        let photoCount = 9
        let batchWindow = 2
        let db = try makeTestDB()
        defer { db.close() }
        let dir = try makeTempDir(prefix: "gather-face-batch")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let session = try SessionRepo(connection: db).create(name: "Batches", source: "folder")
        for index in 0..<photoCount {
            let path = try writeTempFile(in: dir, name: "p\(index).jpg")
            try insertPhoto(db, id: "p\(index)", sessionId: session.id, filepath: path)
        }
        let runner = CountingDBTransactionRunner(base: db)
        let probe = FaceAnalyzeProgressProbe(transactions: runner)
        let service = makeFaceService(
            db: db,
            transactions: runner,
            settings: faceSettings(batchWindow: "\(batchWindow)", inferenceWorkers: "1"),
            inference: faceInferenceProvider(poisonSuffix: nil)
        )

        let result = try await service.analyze(
            sessionId: session.id,
            detectorPath: "detector",
            encoderPath: "encoder",
            onProgress: { current, total, phase in
                probe.record(current: current, total: total, phase: phase)
            }
        )

        #expect(result.status == "done")
        #expect(result.detectionFailures == 0)
        let atDetectStart = try #require(probe.countAtDetectStart)
        #expect(atDetectStart == 1, "face.detect 之前只应有快照读事务")
        let atClusterPhase = try #require(probe.countAtClusterPhase)
        let expectedBatches = (photoCount + batchWindow - 1) / batchWindow
        #expect(expectedBatches == 5)
        #expect(atClusterPhase - atDetectStart == expectedBatches,
                "照片级写入必须每批一个事务：ceil(9 / 2) == 5")
        let states = try FaceRepo(connection: db).getAnalysisStates(session.id)
        #expect(states.count == photoCount)
    }

    /// 批内一张写失败：其余照片照常落库，detectionFailures 只计那一张。
    /// 5 张 / 批窗口 2 ⇒ 批 = [p0,p1] [p2,p3] [p4]；p3 落库时违反 CHECK 失败。
    @Test func singleWriteFailureKeepsTheRestOfTheBatch() async throws {
        let photoCount = 5
        let batchWindow = 2
        let poison = "p3.jpg"
        let db = try makeTestDB()
        defer { db.close() }
        let dir = try makeTempDir(prefix: "gather-face-batch-fail")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let session = try SessionRepo(connection: db).create(name: "BatchFailure", source: "folder")
        for index in 0..<photoCount {
            let path = try writeTempFile(in: dir, name: "p\(index).jpg")
            try insertPhoto(db, id: "p\(index)", sessionId: session.id, filepath: path)
        }
        let runner = CountingDBTransactionRunner(base: db)
        let probe = FaceAnalyzeProgressProbe(transactions: runner)
        let service = makeFaceService(
            db: db,
            transactions: runner,
            settings: faceSettings(batchWindow: "\(batchWindow)", inferenceWorkers: "1"),
            inference: faceInferenceProvider(poisonSuffix: poison)
        )

        let result = try await service.analyze(
            sessionId: session.id,
            detectorPath: "detector",
            encoderPath: "encoder",
            onProgress: { current, total, phase in
                probe.record(current: current, total: total, phase: phase)
            }
        )

        // 一张失败不再放大成「整轮全失败」：状态仍是 done，失败数只 1。
        #expect(result.status == "done")
        #expect(result.detectionFailures == 1)
        let faces = FaceRepo(connection: db)
        let states = try faces.getAnalysisStates(session.id)
        #expect(Set(states.keys) == Set(["p0", "p1", "p2", "p4"]),
                "批事务里失败的一张不应连坐同批的另一张（p2）与其它批")
        let observations = try faces.getObservations(session.id)
        #expect(Set(observations.map(\.photoId)) == Set(["p0", "p1", "p2", "p4"]))
        // 快照 1 + 批事务 3 + 降级重试 2（失败批的 p2、p3 各一次）= 6。
        let atClusterPhase = try #require(probe.countAtClusterPhase)
        #expect(atClusterPhase == 6, "批失败后应降级为逐张重试，而非整批放弃")
    }

    /// 并发解码 seam（P1 rev2）：analyze 默认路径实际调用的函数，注入计数解码器后
    /// 可观测「在飞上限 / 索引归位 / abort 后不再解码」三件事。
    @Test func decodeSeamBoundsInFlightAndKeepsIndexPlacement() async throws {
        let probe = FaceDecodeProbe()
        let paths = (0..<16).map { "photo-\($0).raw" }
        // 乱序 + 跨多片：返回值必须按原索引归位，而不是按完成序。
        let indices = [15, 3, 7, 0, 11, 5, 9, 1, 13, 2, 6, 4]
        let decoded = await FaceKwService.decodeConcurrently(
            indices: indices,
            paths: paths,
            maxDimension: 512,
            concurrency: 3,
            signal: JobAbortSignal(),
            using: { path, _ in
                await probe.enter()
                // 主动让出执行权让解码重叠：无上限实现会把 12 张全部拉起。
                for _ in 0..<8 { await Task.yield() }
                await probe.leave()
                return Data(path.utf8)
            })
        let snapshot = await probe.snapshot()
        #expect(snapshot.maxInFlight <= 3, "在飞解码数不得超过 concurrency")
        #expect(snapshot.maxInFlight >= 2, "解码应当真的重叠，而不是被串行化")
        #expect(snapshot.calls == indices.count)
        #expect(decoded.count == indices.count)
        for index in indices {
            let buffer = try #require(decoded[index])
            #expect(buffer == Data(paths[index].utf8), "结果必须归位到原索引")
        }
    }

    /// abort 后不得再发起解码（默认 provider 在 abort 后先抛，解码本就不该发生）。
    @Test func decodeSeamDoesNotDecodeAfterAbort() async {
        let signal = JobAbortSignal()
        signal.abort()
        let probe = FaceDecodeProbe()
        let decoded = await FaceKwService.decodeConcurrently(
            indices: [0, 1, 2, 3, 4],
            paths: ["a", "b", "c", "d", "e"],
            maxDimension: 512,
            concurrency: 2,
            signal: signal,
            using: { path, _ in
                await probe.enter()
                await probe.leave()
                return Data(path.utf8)
            })
        #expect(decoded.isEmpty)
        let snapshot = await probe.snapshot()
        #expect(snapshot.calls == 0, "abort 后不得再发起解码")
    }

    /// 解码并发度：自动值保底，显式更大才覆盖（旧实现「设 2」反而把并发从 6 降到 2）。
    @Test func decodeConcurrencyKeepsAutoFloor() {
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 1, processorCount: 16) == 6)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 1, processorCount: 4) == 2)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 1, processorCount: 1) == 1)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 2, processorCount: 16) == 6,
                "显式更小不得把自动值拉低")
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 8, processorCount: 16) == 8)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 99, processorCount: 16) == 16)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: 0, processorCount: 16) == 6)
        #expect(FaceKwService.resolveDecodeConcurrency(parallelWorkers: -3, processorCount: 16) == 6)
    }
}
