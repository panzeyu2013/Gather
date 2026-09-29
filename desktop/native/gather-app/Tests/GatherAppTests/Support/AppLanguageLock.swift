// 测试进程内的「界面语言」互斥区。
//
// GatherLocalization.appLanguage 是进程级全局量（l()/errorText() 都读它），
// GatherLocalizationTests 会临时把它切成 zh-CN / en 再恢复。swift-testing 默认
// 跨套件并行，于是其它套件在同一窗口内读到的是被临时切换的文案 →
// 「断言中文文案却拿到英文」的间歇性失败（与本轮审查无关的既有 flake）。
//
// 约定：任何断言本地化文案的用例都经此锁运行；切语言的用例用 withCopy（锁内
// 切换并在解锁前恢复），只读用例用 withStableCopy。
import Foundation
import GatherApp

enum AppLanguageLock {
    private static let mutex = NSLock()

    /// 锁内执行（不改变当前语言）。
    @discardableResult
    static func withStableCopy<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    /// 锁内把界面语言临时切到 language（退出前恢复原值，再解锁）。
    @discardableResult
    static func withCopy<T>(_ language: String, _ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        let original = GatherLocalization.appLanguage
        defer { GatherLocalization.setAppLanguage(original) }
        GatherLocalization.setAppLanguage(language)
        return try body()
    }
}
