# V7 构建/签名预验结论（2026-10-31）

- 代码：`a727498a`（dirty=false，含 C1 16 检测修复），版本 3.0.0-validation / build 1。
- 产物：`release/Gather.app`，121 MB。
- 架构：app `x86_64 arm64`；插件 `x86_64 arm64`。
- 签名：Developer ID Application: Zeyu Pan (QW6428Q67R)；`codesign --verify --deep --strict` 通过；
  Apple Events entitlement 进入签名；Runtime 27.2。
- Mach-O：minos 26.0 / sdk 27.2；`build-info.json` 记录 archs/plugin/minos/sdk。
- 本地化：en.lproj、zh-Hans.lproj 均在主 bundle。
- **未公证**：没有 `GATHER_NOTARY_PROFILE`/Apple ID 三件套；本机 security disabled，
  `spctl` 的 accepted（source=Unnotarized Developer ID）不能作为 Gatekeeper 验收。

## 本次修复（V7 预验发现）

1. `32bb453`：x86_64 macOS 没有 `Float16`，universal 构建在 `SemanticFeatureCodec` 失败。
   改为手写 half 编解码，65,536 个位模式与 arm64 原生逐位一致。
2. `32bb453`：插件 x86_64 的 swiftc 模块缓存落在不可写目录，且同一秒架构戳让 make
   跳过重建、复用 arm64 二进制。改为 `-module-cache-path` + `make -B` + 清旧二进制。
3. `31fc9d8`：`xcrun --show-sdk-version` 在本机返回空，build-info 记录成 26.0。
   改为 `xcrun --sdk macosx --show-sdk-version`，记录真实 27.2。
4. `ca577d9`（V2 发现）：C1 16 的 bundle id 是 `com.captureone.captureone16`；修复后重新构建，
   确认 universal/签名不受影响。

## 仍未完成

公证、干净安装/首次启动、旧 v5 库归档、WebDAV/Keychain、日志脱敏、网络审计、真实 Gatekeeper。
