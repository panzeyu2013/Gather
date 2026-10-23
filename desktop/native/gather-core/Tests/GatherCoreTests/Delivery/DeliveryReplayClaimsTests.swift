// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryReplayClaimsTests.swift
// P2-4：DeliveryReplayClaims 的跨实例（跨进程）文件锁语义。
//
// 每个 DeliveryReplayClaims 实例只维护自己的进程内 fd 表；两个实例之间唯一的
// 互斥来自 temporaryDirectory 下按 `scope#xmpPath#id` 命名的 .lock 文件 +
// flock(LOCK_EX | LOCK_NB)。本文件用两个实例模拟两个进程（各自 open 同一锁
// 文件），并钉住 key 三个维度的冲突范围。
//
// 隔离与清理：每个测试用 UUID 生成 scope/xmpPath，锁文件互不相同；测试结束
// 先 release 再删除自己创建的那几个 .lock，绝不扫描/删除目录里的其他锁文件。
//
// 本文件为静态写入，未运行；锁文件路径复刻生产 fnv1a，如果生产改哈希，
// claim 后的 fileExists 断言会先失败，不会静默清理错文件。

import Foundation
import Testing
@testable import GatherDelivery

struct DeliveryReplayClaimsTests {
    // MARK: - 用例 1：跨实例同一 key 互斥，release 后交接

    @Test func crossInstanceSameKeyIsExclusiveUntilRelease() {
        let scope = Self.uniqueScope()
        let xmpPath = Self.uniqueXMPPath()
        let id: Int64 = 42
        let lockFile = Self.lockFileURL(id: id, xmpPath: xmpPath, scope: scope)
        let first = DeliveryReplayClaims()
        let second = DeliveryReplayClaims()

        defer {
            first.release(id, xmpPath: xmpPath, scope: scope)
            second.release(id, xmpPath: xmpPath, scope: scope)
            Self.removeIfPresent(lockFile)
        }

        #expect(
            !FileManager.default.fileExists(atPath: lockFile.path),
            "前置：UUID 隔离的 key 不应有历史锁文件")
        #expect(
            first.claim(id, xmpPath: xmpPath, scope: scope),
            "第一个实例（进程）应抢到")
        #expect(
            FileManager.default.fileExists(atPath: lockFile.path),
            "claim 必须落在两个实例共享的锁文件上，而不是只写 instance 内存")
        #expect(
            !second.claim(id, xmpPath: xmpPath, scope: scope),
            "同 scope/xmpPath/id 的第二个实例必须被 flock 拒绝")
        first.release(id, xmpPath: xmpPath, scope: scope)
        #expect(
            second.claim(id, xmpPath: xmpPath, scope: scope),
            "第一个实例 release 后，第二个实例应能抢到")
        #expect(
            !first.claim(id, xmpPath: xmpPath, scope: scope),
            "交接后反向同样互斥")
        second.release(id, xmpPath: xmpPath, scope: scope)
        #expect(
            first.claim(id, xmpPath: xmpPath, scope: scope),
            "第二个实例 release 后，第一个实例应能再次抢到")
        first.release(id, xmpPath: xmpPath, scope: scope)
    }

    // MARK: - 用例 2：scope / xmpPath / id 任一维度不同则不互斥

    @Test func differentScopeXMPPathOrIntentIdDoesNotBlock() {
        let scopeA = Self.uniqueScope()
        let scopeB = Self.uniqueScope()
        let xmpA = Self.uniqueXMPPath()
        let xmpB = Self.uniqueXMPPath()
        let idA: Int64 = 42
        let idB: Int64 = 43

        let owner = DeliveryReplayClaims()
        let peer = DeliveryReplayClaims()
        let sameKey = DeliveryReplayClaims()
        let ownerFile = Self.lockFileURL(id: idA, xmpPath: xmpA, scope: scopeA)
        let scopeBFile = Self.lockFileURL(id: idA, xmpPath: xmpA, scope: scopeB)
        let idBFile = Self.lockFileURL(id: idB, xmpPath: xmpA, scope: scopeA)
        let xmpBFile = Self.lockFileURL(id: idA, xmpPath: xmpB, scope: scopeA)

        defer {
            owner.release(idA, xmpPath: xmpA, scope: scopeA)
            peer.release(idA, xmpPath: xmpA, scope: scopeB)
            peer.release(idB, xmpPath: xmpA, scope: scopeA)
            peer.release(idA, xmpPath: xmpB, scope: scopeA)
            sameKey.release(idA, xmpPath: xmpA, scope: scopeA)
            for url in [ownerFile, scopeBFile, idBFile, xmpBFile] {
                Self.removeIfPresent(url)
            }
        }

        #expect(owner.claim(idA, xmpPath: xmpA, scope: scopeA))
        #expect(
            peer.claim(idA, xmpPath: xmpA, scope: scopeB),
            "不同 scope 不得互斥")
        #expect(
            peer.claim(idB, xmpPath: xmpA, scope: scopeA),
            "不同 intent id 不得互斥")
        #expect(
            peer.claim(idA, xmpPath: xmpB, scope: scopeA),
            "不同 xmpPath 不得互斥（锁名含路径）")
        #expect(
            !sameKey.claim(idA, xmpPath: xmpA, scope: scopeA),
            "三个维度都相同仍然互斥")
    }

    // MARK: - 锁文件路径 / 隔离 / 清理

    private static func uniqueScope() -> String {
        "DeliveryReplayClaimsTests.\(UUID().uuidString)"
    }

    private static func uniqueXMPPath() -> String {
        "/virtual/delivery-replay-claims/\(UUID().uuidString).xmp"
    }

    /// 复刻生产 `DeliveryReplayClaims.fnv1a` + 文件名规则。
    private static func lockFileURL(id: Int64, xmpPath: String, scope: String) -> URL {
        let key = "\(scope)#\(xmpPath)#\(id)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-replay-\(String(hash, radix: 16)).lock")
    }

    private static func removeIfPresent(_ url: URL) {
        // 目标 key 由 UUID 独占；不存在时 removeItem 的失败直接吞掉。
        try? FileManager.default.removeItem(at: url)
    }
}
