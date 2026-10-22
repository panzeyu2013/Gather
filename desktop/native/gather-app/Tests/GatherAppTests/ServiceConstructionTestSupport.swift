// desktop/native/gather-app/Tests/GatherAppTests/ServiceConstructionTestSupport.swift
// B04 收口：core/app 逐字重复的 344 行装配已合并到 GatherTestSupport（唯一实现：
// desktop/native/gather-core/Tests/GatherTestSupport/ServiceConstructionTestSupport.swift，
// 13 个 public convenience init + reuseSimilarityHashes）。
// app 侧只留 re-export：本 target 已依赖 GatherTestSupport product，35 个调用点文件
// 都直接 import GatherTestSupport（Swift 的 import 是文件级的，@_exported 不会让
// 同一 module 的其他文件免 import；此声明只表达共享来源，便于将来整体迁移）。
@_exported import GatherTestSupport
