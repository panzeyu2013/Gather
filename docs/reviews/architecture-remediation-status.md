# 架构整改执行状态（WP0–WP6c，2026-10-22）

> 计划：docs/reviews/architecture-remediation-plan.md。本文件是执行状态索引；详细设计见 macro 报告与 wp6 设计。
> 工作区：分支 refactor，HEAD f0eb94d 之后追加 WP2c/WP5/WP4c/WP6c；本地 commit，未 push。

## 1. 已完成 WP

| WP | 结果 | 关键提交 |
| --- | --- | --- |
| WP0 | 基线冻结 | — |
| WP1 | Protocol 347→251 类型、1,752→1,320 声明、零引用 89→0、Router 信封 6→0；新增 protocol surface ratchet | 65c0179 |
| WP2a | GatherDelivery target 提取（4 文件 3,630 行），Delivery 仅依赖 Protocol+Persistence | 62551b6 |
| WP2b | Coordinator 1,964→319；状态写入 33→8；模块适配器 15→0；DB 删除+intent.finish 单事务 | b6db25a |
| WP2c | 删除 FeatureDeliveryPorts 与 14 个旧转发；服务直接持 DeliveryModuleAdapter | 7bbfc94 |
| WP3a | GatherDomain→GatherApplication（21 文件/15,211 行纯 rename） | b97d10f |
| WP3b-1 | 8 组 Repo Ports；DBConnection 文件 13→5，prepare 120→76 | 9387fa4 |
| WP3b-2 | Similarity/FaceKw/Culling/Indexer SQL 下沉；DBConnection 5→1，prepare 76→25 | 93304b5 |
| WP3b-3 | Duplicate SQL 下沉；DBConnection 1→0，prepare 25→0；services_prepare ratchet 0 | 6bccb77 |
| WP4a | RootShell/RootView 882 行迁 GatherUI/Shell | bf9adba |
| WP4b | 删 27 sync 核 + 18 UI sync 端口 + Bridge；3 个 Live provider 迁 Host | 66adef8 |
| WP4c | AppComposition 421→107；Composition/ 4 文件；AppServices 301→161 | c644e6b |
| WP5a | CullingService 2,496→138 门面 + 6 文件 2,370 行 | efc6598 |
| WP5b | FaceKwService 2,528→171 门面 + 5 文件 2,406 行 | c475974 |
| WP6a | Schema migration framework；Database.swift 679→505 | 67eb35d |
| WP6b | Schema V2 no-op 迁移 + 备份/回滚；user_version=2 | 95f0075 |
| WP6c | universal/arm64/x86_64、版本注入、签名/公证接口、release CI | f0eb94d |
| WP7 | GatherTestSupport product；manifest 去 xcrun；CI schema verify；app 复用夹具 | d2527a8 |

## 2. 当前指标（HEAD 工作区实测）

- core：1,095 tests / 164 suites，exit 0。
- app：616 tests / 68 suites，串行 + 并行 3 次，exit 0。
- Schema：43 表 / 373 列 / 69 索引 / 62 FK / user_version=2 / FK 违规 0。
- 门禁：9 道 strict 全绿；ratchet 53/231/0/0/0；protocol surface 254/1,338/0/0；preview 14。
- Application：DBConnection 0、connection.prepare 0；services_prepare ratchet 0。
- Delivery：Coordinator 319 行；GatherDelivery 15 文件；状态写入 8；模块适配器 5 方法。
- Protocol：254 个 public 类型 / 1,338 声明；零引用 0；Router 信封 0。
- Host：RootShell 已在 UI；UI sync 端口 0；AppComposition 107 行。
- Release：真实 universal build + build.sh 全流程通过；签名/公证未验证（无凭据）。

## 3. 剩余

1. WP7b：Job/Delivery trace id、结构化阶段耗时；未做。
2. WP4d：7 个 VM 生命周期语义统一（PageVisibility/LoadPhase 契约）仍为增量修复；Host Commands 仍 import SwiftUI。
3. WP6c 发布验证：真实 Developer ID/notarytool/staple/spctl、CI release job 未实跑；x86_64 运行期未在 Rosetta 验证。
4. 文档：final-report 的 Cut 6c 数字仍为历史快照，§1.2 已注记当前架构指标；其余历史报告保留快照口径。
5. 未 push；30 个本地 commit 等待 owner review。

## 4. 结论

计划中的 WP0–WP6c 已完成，核心指标达到或超过目标：Application SQL 0（目标 ≤15）、Delivery Coordinator 319（目标 ≤600）、状态写入 8（目标 ≤8）、adapters 5（目标 ≤5）、Protocol 254（目标 ≤260）、Host shell 迁移、sync 0、Composition 107、Schema V2。
剩余为可观测性、生命周期细节与真实发布凭据验证，不影响当前架构整改主体结论。
