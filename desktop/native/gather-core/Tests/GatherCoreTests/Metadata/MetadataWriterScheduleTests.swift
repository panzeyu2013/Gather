// Tests/GatherCoreTests/Metadata/MetadataWriterScheduleTests.swift
// mww4 / W4-4 ①：MetadataWriter 写面去抖排程骨架直测。
// 覆盖：同路径 100 次 schedule 合流为恰好 1 条 ScheduleEntry（generation 单调到 100）、
// 不同路径互不干扰、waitForIdle 超时抛 scheduleTimeout 且限时返回、
// 结算后再次 schedule 单调续增且 waitForIdle 可重复等待。
// mwwshut：有界关停 —— 空闲立即返回、在飞写被钉住时等待结算后返回、超时抛 scheduleTimeout，
// 以及关停后链尾释放/迟到入队不复活状态。
// 排程面不触库：SQLite Store 仅用于满足 Dependencies 端口装配。

import Foundation
import Testing
@testable import GatherCore

/// mwwshut 测试闸门：把注入写体钉在 in-flight，直到 open() 放行。
private actor MetadataWriterWriteGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Metadata/MetadataWriter (mwsched)")
struct MetadataWriterScheduleTests {

    private func makeWriter(label: String) async throws -> (writer: MetadataWriter, path: String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: SQLiteWritebackStore(database: database),
                metadataStore: SQLiteMetadataStore(database: database)
            )
        )
        return (writer, path)
    }

    @Test func hundredSchedulesOnSamePathCollapseToSingleEntry() async throws {
        let (writer, path) = try await makeWriter(label: "mwsched-burst")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_0001.xmp"

        for _ in 0..<100 {
            writer.schedule(xmpPath: xmpPath)
        }
        // 非阻塞 schedule 把入队 Task 交给全局执行器，先事件驱动汇合到 100 次登记落账。
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 100, timeoutMs: 5_000)
        try await writer.waitForIdle(xmpPath: xmpPath, timeoutMs: 5_000)

        let snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.xmpPath == xmpPath)
        #expect(snapshot.first?.generation == 100)
        #expect(snapshot.first?.phase == "idle")
    }

    @Test func distinctPathsAreScheduledIndependently() async throws {
        let (writer, path) = try await makeWriter(label: "mwsched-paths")
        defer { removeStoreFiles(path) }
        let slow = "/v/IMG_slow.xmp"
        let fast = "/v/IMG_fast.xmp"

        writer.schedule(xmpPath: slow, delayMs: 30_000)
        writer.schedule(xmpPath: fast, delayMs: 0)
        try await writer.waitForGeneration(xmpPath: slow, minGeneration: 1, timeoutMs: 5_000)
        try await writer.waitForGeneration(xmpPath: fast, minGeneration: 1, timeoutMs: 5_000)
        // fast 已结算返回；slow 仍在自己 30s 去抖窗口内 —— 两路径互不阻塞。
        try await writer.waitForIdle(xmpPath: fast, timeoutMs: 5_000)

        let snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.first(where: { $0.xmpPath == slow })?.generation == 1)
        #expect(snapshot.first(where: { $0.xmpPath == slow })?.phase == "debouncing")
        #expect(snapshot.first(where: { $0.xmpPath == fast })?.phase == "idle")
    }

    @Test func waitForIdleTimesOutWithScheduleTimeoutAndReturnsBounded() async throws {
        let (writer, path) = try await makeWriter(label: "mwsched-timeout")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_stuck.xmp"

        writer.schedule(xmpPath: xmpPath, delayMs: 30_000)
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 1, timeoutMs: 5_000)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await writer.waitForIdle(xmpPath: xmpPath, timeoutMs: 50)
            Issue.record("waitForIdle 应超时抛 MetadataWriterError.scheduleTimeout，实际正常返回")
        } catch let error as MetadataWriterError {
            #expect(error == .scheduleTimeout(xmpPath: xmpPath, timeoutMs: 50))
        } catch {
            Issue.record("waitForIdle 抛出了非预期错误：\(error)")
        }
        let elapsed = start.duration(to: clock.now)
        // 限时返回：不早于超时窗口，且不拖到无界等待。
        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .milliseconds(2_000))

        let snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.first?.generation == 1)
        #expect(snapshot.first?.phase == "debouncing")
    }

    @Test func generationIsMonotonicAcrossWavesAndWaitForIdleIsReusable() async throws {
        let (writer, path) = try await makeWriter(label: "mwsched-waves")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_wave.xmp"

        writer.schedule(xmpPath: xmpPath, delayMs: 0)
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 1, timeoutMs: 5_000)
        try await writer.waitForIdle(xmpPath: xmpPath, timeoutMs: 5_000)
        // 已 idle：再次等待立即返回（无条目可等，不挂起）。
        try await writer.waitForIdle(xmpPath: xmpPath, timeoutMs: 5_000)

        for _ in 0..<3 {
            writer.schedule(xmpPath: xmpPath, delayMs: 10)
        }
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 4, timeoutMs: 5_000)
        try await writer.waitForIdle(xmpPath: xmpPath, timeoutMs: 5_000)

        let snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.generation == 4)
        #expect(snapshot.first?.phase == "idle")
    }

    // MARK: - mwwshut / W4-4 有界关停

    @Test func shutdownReturnsImmediatelyWhenIdleAndRejectsLateSchedules() async throws {
        let (writer, path) = try await makeWriter(label: "mwwshut-idle")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_shut_idle.xmp"

        // 去抖中的路径不计入 activeWrites/readyQueue：不得把关停拖入无界等待。
        writer.schedule(xmpPath: xmpPath, delayMs: 30_000)
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 1, timeoutMs: 5_000)

        let clock = ContinuousClock()
        let start = clock.now
        try await writer.shutdown(timeoutMs: 60)
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(2_000))

        var snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.isEmpty)
        // 关停后迟到入队不得复活排程/写面状态（终止态）。
        writer.schedule(xmpPath: xmpPath, delayMs: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        snapshot = await writer.scheduleSnapshot()
        #expect(snapshot.isEmpty)
        let writeState = await writer.writeStateSnapshot()
        #expect(writeState.ready.isEmpty)
        #expect(writeState.active.isEmpty)
        let tails = await writer.mutationTailCount()
        #expect(tails == 0)
    }

    @Test func shutdownWaitsForInFlightWriteToSettle() async throws {
        let (writer, path) = try await makeWriter(label: "mwwshut-wait")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_shut_wait.xmp"
        let gate = MetadataWriterWriteGate()
        await writer.setWriteBodyForTesting { _ in await gate.wait() }

        writer.schedule(xmpPath: xmpPath, delayMs: 0)
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 1, timeoutMs: 5_000)

        let clock = ContinuousClock()
        let start = clock.now
        let shutdownTask = Task { try await writer.shutdown(timeoutMs: 5_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await gate.open()
        try await shutdownTask.value
        let elapsed = start.duration(to: clock.now)
        // 写被钉住期间 shutdown 必须等待，放行后才返回。
        #expect(elapsed >= .milliseconds(150))
        let tails = await writer.mutationTailCount()
        #expect(tails == 0)
    }

    @Test func shutdownTimesOutWithScheduleTimeoutAndReturnsBounded() async throws {
        let (writer, path) = try await makeWriter(label: "mwwshut-timeout")
        defer { removeStoreFiles(path) }
        let xmpPath = "/v/IMG_shut_timeout.xmp"
        let gate = MetadataWriterWriteGate()
        await writer.setWriteBodyForTesting { _ in await gate.wait() }

        writer.schedule(xmpPath: xmpPath, delayMs: 0)
        try await writer.waitForGeneration(xmpPath: xmpPath, minGeneration: 1, timeoutMs: 5_000)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await writer.shutdown(timeoutMs: 60)
            Issue.record("shutdown 应超时抛 MetadataWriterError.scheduleTimeout")
        } catch let error as MetadataWriterError {
            #expect(error == .scheduleTimeout(xmpPath: xmpPath, timeoutMs: 60))
        } catch {
            Issue.record("shutdown 抛出了非预期错误：(error)")
        }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(50))
        #expect(elapsed < .milliseconds(2_000))

        // 超时后强制清场：无在飞/排队状态，链尾不悬挂。
        let writeState = await writer.writeStateSnapshot()
        #expect(writeState.ready.isEmpty)
        #expect(writeState.active.isEmpty)
        let tails = await writer.mutationTailCount()
        #expect(tails == 0)
        await gate.open()
    }
}
