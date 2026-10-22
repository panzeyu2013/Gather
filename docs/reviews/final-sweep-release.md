# 发布与提交卫生最终扫查（只读）

- 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`，HEAD `ab7752e`，分支 `refactor`，工作区干净。
- 方式：只读静态审计；仅执行 `bash -n`、`ruby -YAML`、`make -n`、`lipo`、`otool`、`git` 元数据、`security find-identity`、`arch -x86_64 /usr/bin/true`。**未执行 build/test/门禁，未签名、未公证、未启动 GUI。**
- 口径：已确认 = 代码/命令直接证据；疑似 = 未在目标环境实跑或依赖版本推断。

## 结论

**发布链“代码已具备、门禁未闭环”。P0 = 0，P1 = 6，P2 = 18。**

- 无直接产出不可启动/崩溃/泄密包的 P0；版本缺失、签名缺失均 fail-closed，CI release 固定 `GATHER_ARCHS=universal` + `GATHER_NOTARIZE=1` + `GATHER_RELEASE=1`（`ci.yml:146-148`）。
- 但 tag release 与文档承诺仍有 3 个实质缺口：**发布门不强制公证/universal**、**上传的 zip 在 staple 前生成**、**当前 hosted runner 配置不含 C1 插件**；另有 **CI runner SDK 不可能 ≥26**、**无 app icon**、**发布链从未实跑**。
- 版本/架构主路径（`GATHER_VERSION` / `git describe` / `GATHER_BUILD_NUMBER` / `--arch` + `lipo` 断言 / `build-info.json`）设计自洽；偏移集中在“发布门范围”和“CI runner 能力”。
- Git：工作区干净、无 secrets/临时文件；**50 ahead（含整个 WP6c release pipeline）、0 tag**，状态文档已明确写“未 push”，但因此无法触发 release。

## P0

无。

- 依据：`build.sh:110-113`（release 无版本 exit 1）、`:518-521`（release 无签名 exit 1）、`:548-553`（release 缺公证凭据 exit 1，但仅在 `GATHER_NOTARIZE=1` 时可达，见 P1-1）；未发现会把明文凭据写入产物或把不可启动二进制上传的路径。
- P1-2 在“离线 Gatekeeper 严格验收”口径下可视为坏包；若发布要求离线首启，应升级处理优先级。

## P1

### P1-1 发布门只强制“版本 + 签名”，不强制公证、不强制 universal

- 已确认（代码路径）：
  - `desktop/native/build.sh:15` 承诺“`GATHER_RELEASE=1`：版本/签名/公证任一缺失即 exit 1”。
  - 实际 `build.sh:529-535`：`NOTARIZE="${GATHER_NOTARIZE:-0}"`，公证整段只在 `NOTARIZE=1` 时进入；在版本/签名已满足时，`GATHER_RELEASE=1` 且未设 `GATHER_NOTARIZE` 会跳过公证并以 0 退出（末尾打印 `notarization: not notarized`）。
  - `build.sh:518-521` 只要求 `CODESIGN_IDENTITY` 非空；`-`（ad-hoc）也走签名分支并置 `SIGNED=1`。
  - `build.sh:303-316` 的 universal 断言只在 `EXPECTED_ARCHS` 非空时执行；release 未设 `GATHER_ARCHS` 时 host 单架构也可过门。
  - 文档同口径错误：`docs/DEVELOPMENT.md:89-90`、`:120-121`。
- 影响：按文档执行 `GATHER_RELEASE=1` 可得到 **ad-hoc 或未公证的单架构“发布包”**；CI 因三个变量都设置才安全。发布契约与实现不一致。
- 修复：`RELEASE_MODE=1` 时强制 `GATHER_NOTARIZE=1`、`GATHER_ARCHS=universal`，并拒绝 `CODESIGN_IDENTITY=-`；补三条反向用例；同步改文档。
- 关联：`docs/DEVELOPMENT.md:126-130` 的“本机完整发布”命令**没有** `GATHER_RELEASE=1`，连现有门都不启用（见 P2-13）。

### P1-2 notarize 的 zip 在 staple 之前生成，上传/校验的 zip 不含装订票据

- 已确认：
  - `build.sh:556-563` 顺序是 `ditto` 打包 → `notarytool submit --wait` → `stapler staple/validate`（staple 只作用于磁盘 `Gather.app`）→ `spctl`；之后**没有重新 zip**。
  - `ci.yml:237-239` 直接对旧 `Gather.zip` 做 `shasum`；`ci.yml:240-247` 上传该 zip 与 sha。
  - `docs/DEVELOPMENT.md:153` 的手工校验也只重算 sha。
- 影响：下载者解压得到的是**未装订 ticket 的 app**；离线首启 Gatekeeper 可能拒绝；发布 zip 与 CI 验证过的 stapled app 不是同一份字节，sha 也无法证明“被验证的那份 app”就是分发的那份。
- 修复：staple/validate 后删除旧 zip，重新 `ditto`，再生成 `.sha256`；CI 解压新 zip 后再跑 `stapler validate`。

### P1-3 当前 workflow 配置下 tag release 不含 GatherLink.coplugin；“插件 universal 已收口”无构建证据

- 已确认：
  - `ci.yml:141` release 固定 `macos-14`；授权 SDK 被 `.gitignore:33`（`Capture*One*Plugin*SDK*/`）排除，hosted runner 没有它。
  - `build.sh:431-435` SDK/Makefile 缺失时只 warning，release 继续；`ci.yml:205-211` 插件不存在时 `::warning::` + `exit 0`。
  - 本地现存 `desktop/coplugin/GatherLink.coplugin/Contents/MacOS/GatherLink`（mtime 2026-10-03）`lipo -archs` = **arm64**；`docs/reviews/final-acceptance-build.md:101` 也记录 arm64-only。
  - 插件 universal 代码在 `796a2b2`，晚于验收报告 `07fdd95`；此后无构建/验收记录；`docs/reviews/architecture-remediation-status.md:62` 却称“插件 universal”已收口，`:41` 称 “build.sh 全流程通过”。
- 影响：按当前 hosted runner 配置，每个 tag release 都缺 C1 入口，只能靠人工发布说明兜底；插件双切片路径**从未被执行过**，Intel 用户静默丢功能。
- 修复：把 SDK 装到 self-hosted runner；或 tag release 在 SDK 缺失时直接失败。CI 增加“插件必须存在且含两切片”的必过断言，并留一次 universal 插件构建日志/产物。

### P1-4 release runner 的 SDK 不可能 ≥26，Liquid Glass 设计与发布产物脱节

- 已确认：`ci.yml:141` `runs-on: macos-14`；`ci.yml:92-96`（app job）与 `:162-169`（release job）都用 runner 的 `xcrun --show-sdk-version` 注入 `GATHER_SDK_VERSION`；`gather-app/Package.swift:42-45` 明确该 SDK 版本决定 macOS 26+ 外观，`:50-54` 从环境读取。
- 本机验收用 SDK 27.0：`docs/reviews/final-acceptance-build.md:94`（两切片 `minos 14.0 / sdk 27.0`）、`:13`、`:87`。但 release job 没有固定新 SDK，`build.sh` / `ci.yml` 全仓**没有 `vtool` 断言**（仅 `build.sh:127` 注释提到）。
- 疑似（版本依赖，无法联网复核）：macOS 14 镜像最多提供 Xcode 16.x/SDK 15.x（Xcode 26 要求 macOS 15.6+），因此 release 的 `LC_BUILD_VERSION.sdk` 不可能到 26/27，发布包与本地验收包外观不一致。
- 影响：发布产物无 Liquid Glass；且门禁无法发现该回归。
- 修复：release 改 `macos-26`/self-hosted + Xcode 26；在 `build.sh` 增加 `vtool -show-build` 两切片 `sdk` 断言，CI 断言 `xcrun --show-sdk-version` 下限。

### P1-5 发布 bundle 没有 app icon

- 已确认：`desktop/native/gather-app/Sources/GatherUI/Support/Info.plist` 无 `CFBundleIconFile`；全仓无业务 `.icns`（唯一命中是 ignored 的 `Capture_One_Plugin_SDK.../Samples/CODemoPlugin/.../CODemoPluginIcon.icns`）；`build.sh:275-278` 只拷可执行文件与 Info.plist，没有 Assets.car/icon 步骤。
- 影响：Finder、Dock、关于窗口显示通用可执行图标；对外分发可见缺陷。
- 修复：加入 `Gather.icns` + `CFBundleIconFile`，build.sh/CI 断言存在。

### P1-6 发布链从未在 CI 实跑：50 ahead + 0 tag

- 已确认：
  - `git status -sb` → `refactor...origin/refactor [ahead 50]`。
  - `git tag -l` 为空；`git describe --tags` → `fatal: No names found`。
  - 含 release pipeline 的 `f0eb94d`、`796a2b2` 都在未推送区间。
  - `docs/reviews/architecture-remediation-status.md:4,57` 自述“本地 commit，未 push；等待 owner review”。
- 影响：remote 无 tag 可触发 `release` job；当前 `release` job 从未执行，P1-1..P1-4 均未被目标环境证伪或证真。
- 修复：先 push `refactor`，再推测试 tag 或手动 dispatch，记录 run URL 与产物校验。

## P2

### P2-1 `OUTPUT_DIR` 校验第二条件恒真

`build.sh:29-32` 的 `"$APP_BUNDLE" != "$OUTPUT_DIR/Gather.app"` 恒为 false（`APP_BUNDLE` 就是该串，`:21`），实际只拦 `/`；`OUTPUT_DIR="//"` 等变体可绕过。建议改为 `readlink -f`/规范化后比较，并拒绝 `//`、结尾斜杠、非绝对路径。

### P2-2 `build.sh` 仍写“Package.swift 默认 26.0”，实际默认 14.0；xcrun 失败时静默退回 14.0

`build.sh:129` 与 `:144` 的注释称默认 26.0、不会静默退回；实际 `gather-app/Package.swift:34` `defaultSDKVersion = macOSDeploymentTarget`（14.0），`:50-54` env 为空即用它。`xcrun --show-sdk-version` 失败的路径（`build.sh:130-137`）会静默链接 14.0；建议失败即 exit 1 或至少把“14.0 fallback”写进 build-info/日志。

### P2-3 `build-info.json` 的元数据缺口

`build.sh:443-449`：`commit` 用 `git rev-parse --short HEAD`，**无 dirty 标记**；`sdk_version` 取环境变量而非实际 Mach-O；`archs` 无插件切片；无 `GATHER_ARCHS`/`configuration`。文档 `docs/DEVELOPMENT.md:156-158` 只承诺 build-info 字段稳定，未覆盖这些缺口。

### P2-4 插件构建戳被拷进发布 bundle

`build.sh:413-422` 在 `cp -R "$PLUGIN_BUNDLE" ...` 前执行 `touch "$PLUGIN_BUNDLE/.arch-$arch"`；`cp -R` 会连隐藏文件一起复制，发布包 `Contents/PlugIns/GatherLink.coplugin/.arch-*` 出现构建临时文件（也破坏 bundle 字节可复现性）。

### P2-5 非公证构建会留下旧 `Gather.zip`

`build.sh:556` 的 `rm -f "$ZIP_PATH"` 只在 `GATHER_NOTARIZE=1` 分支内；`OUTPUT_DIR` 中已有旧 zip 时，跑一次非公证构建不会清理，容易被误当本次产物。建议在组装开始时无条件删除 zip。

### P2-6 插件 rpath 使用构建机相对路径，且部署目标 10.14

`desktop/coplugin/Makefile:7` `TARGET := ...-apple-macosx10.14`（app 为 14.0）；`:10` `-rpath "$(FRAMEWORK_PATH)"` 是相对路径 `../../Capture_One_Plugin_SDK_(Mac)_v1.0.1/Library/Frameworks`。`make -n` 与 `otool -l`（本地 arm64 插件）确认 `LC_RPATH` 即该相对路径，未用 `@loader_path`/`@executable_path`；dyld 对相对 rpath 按 CWD 解析。**疑似**：插件在 Capture One 中的加载依赖宿主自己的 rpath，未在 C1 中验证；建议改 `@loader_path` 或由宿主提供，并单独验证。

### P2-7 插件版本硬编码，未参与版本注入

`desktop/coplugin/GatherLink/Info.plist:19-22` 固定 `1.0.0 / 1`；`build.sh` 只注入 app 的 `Info.plist`（`:282-291`），不碰插件；CI 也只校验插件架构（`ci.yml:202-223`）。发布包内 app 与插件版本可能长期不一致。

### P2-8 遗留 Electron 时代 entitlements 仍被跟踪

`desktop/resources/entitlements.mac.plist:5-26` 声明 `app-sandbox`、JIT、unsigned executable memory、三版 C1 的 temporary-exception；当前发布只用 `desktop/native/Gather.entitlements`（`build.sh:27`）。该文件未被 build.sh/CI 引用，但仍在仓库中，容易被误用；建议删除或加 `DEPRECATED` 说明。

### P2-9 CI 注释/参数小问题

- `ci.yml:78-79` 注释仍写 `user_version=1`，实际 Schema V2（43 表 / user_version=2；README 与验收报告均 V2）。
- `ci.yml:31-32` 与 `:47-48` 重复执行 `check-no-legacy.sh`（boundary 与 gates 各一次）。
- `ci.yml:14` `version` 输入 `required: false`，但 `:177-180` 空值直接 error exit；UI 与实际约束不一致。
- `ci.yml:17-19` `cancel-in-progress: true` 会在同 ref 新 push 时取消正在进行的 `workflow_dispatch` release。

### P2-10 `GATHER_NOTARY_PROFILE` 在 hosted runner 上实际不可用

`ci.yml:137-150` 提供该 secret，但 `:184-195` 只导入证书，未执行 `xcrun notarytool store-credentials`；hosted runner 的 keychain 没有该 profile。若配置了 profile 而未配置 Apple ID 三件套，`build.sh:540-541` 会优先走 profile 并失败。文档 `docs/DEVELOPMENT.md:165-166` 把两条路径并列，但 CI 实际只有 Apple ID 路径可用；建议在 CI 中用 secret 生成临时 profile，或删除 profile 选项。

### P2-11 release 产物校验不完整

- `ci.yml:228` 对 app 只 `lipo -archs` **打印**，未断言 `x86_64`+`arm64`（仅依赖 `build.sh:303-316` 的传递保证）。
- `ci.yml:224-239` 未校验 `build-info.json`、`CFBundleVersion`、Mach-O 的 `minos/sdk`（`vtool`）。
- app 测试 target 没有 core 的 CLT-only `-F/-rpath` 探测（`gather-app/Package.swift:120-134` vs `gather-core/Package.swift:10-32`）；在“只装 CLT、无 Xcode”的机器上 app 测试可能链接失败（r3 已记录，仍成立）。
- `ci.yml:72`/`:103` 的 cache key 只含 `Package.swift` 哈希，不含 Swift/SDK 版本；旧缓存可能污染 `--manifest-cache none` 之外的构建。

### P2-12 release job 的供应链/治理缺口

`ci.yml:149-156` 把全部签名/公证 secret 放在 job 级 `env`，所有 step（含上传）都能读到；`actions/checkout@v4`、`cache@v4`、`upload-artifact@v4` 用浮动 major tag 而非 SHA；无 `environment` 保护/审批，任意 `v*` tag 即可触发签名；只上传 zip，不创建 GitHub Release/DMG/attestation（`permissions: contents: read` `:21-22` 也决定了不能创建 release）。建议 step 级 env、动作 pin SHA、加 environment 与 provenance。

### P2-13 文档命令与脚本参数不一致

- `docs/DEVELOPMENT.md:126-130`“本机完整发布”**缺 `GATHER_RELEASE=1`**（CI 有），按该命令执行不会启用发布门。
- `docs/DEVELOPMENT.md:110` 称“公证要求可递增的数字串”：notarytool 没有该要求（那是 App Store/Sparkle 的 `CFBundleVersion` 规则）。
- `README.md:79-80` 要用户设 `CONFIGURATION=release`，但 `build.sh:19` 默认即 `release`；应改为“默认 release，debug 用 CONFIGURATION=debug”。
- `docs/README.md:85` 称脚本“只构建 Swift 核心和 SwiftUI 应用”，漏了 SDK 存在时的插件构建。
- 没有 `git tag`/`git push` 的发布步骤，也没有 `notarytool store-credentials` 命令（P1-6/P2-10）。

### P2-14 状态文档自指过期，且与验收报告冲突

- `ab7752e` 的 subject 是 “docs: refresh remediation status HEAD”，却把 `architecture-remediation-status.md:4` 的 HEAD 写成 `cdf3962`（该 commit 自身是 `ab7752e`，一提交后就过期）。
- `docs/final-report.md:168` 仍称“工作区未提交…HEAD 82603e0”；实际干净、HEAD `ab7752e`。
- `architecture-remediation-status.md:62` 称插件 universal 已收口，但最新的 `final-acceptance-build.md:101` 仍是 arm64-only，且 796a2b2 后无复验记录。
- 本机 `security find-identity -v -p codesigning` 实有 1 个有效 Developer ID Application 身份（团队 `QW6428Q67R`）；`status.md:41` 的“无凭据”至少不适用于签名证书（仍可能指公证凭据），建议拆分表述。

### P2-15 commit 序列：可读但存在混合范围/超大提交

- 50 个未推送 commit 无 merge、类型前缀清楚；但：
  - `ad9df1b chore: checkpoint native Swift review and UI improvements` 是 WIP/checkpoint 提交。
  - `796a2b2 build(release): make plugin universal and clean release warnings` 同时改 `build.sh/ci.yml` 与 3 个源码文件（CullingWorkbenchViewer/L10n/DB），scope 混杂。
  - `30f51f0 refactor(native)!: 完成破坏性重构与评审修复收尾` 单提交 **719 files / +95,028 / −43,184**，review/bisect 成本高。
  - `ab7752e` 为 1 行 docs 提交，却更新了会立即过期的 HEAD。
- 建议后续按 scope 拆分，release 提交不夹带源码警告修复。

### P2-16 大文件与 LFS

`git ls-tree -r -l HEAD`：`SFace.../weight.bin` **38,542,848 B**、`vector-fixtures.json` **3,630,166 B**、`docs/archive/reviews/assets/*.png` 3.87/3.63/3.60/3.60 MB 等；`.git` **78 MB**；无 `.gitattributes`、无 LFS（`git lfs` 命令也不存在）。模型与 fixtures 是构建/测试必需，但建议 LFS 或至少 `.gitattributes` 标注二进制；历史清理另需 owner 决策。

### P2-17 本地构建垃圾 12.5 GB；`.cleanup-verify` 未被 ignore

- `du -sh`：根 `.build` 1.5G、`desktop/native/.build` 1.0G、`gather-app/.build` 5.5G、`gather-core/.build` 4.5G；均已 ignore（`.gitignore:36`），不在 git 中。
- 未发现 `.cleanup-verify`、`swbuild.tmp.*`、`*.tmp.md`、`release/`、`.gather/`；但 `.gitignore` 未列 `.cleanup-verify/`，后续若生成会变 untracked。建议加 ignore 并定期清理（确认后执行）。

### P2-18 本地版本回退与 `GATHER_BUILD_NUMBER` 静默忽略

`git tag -l` 为 0 → `git describe --tags` 失败 → 本地 build 保留 `Info.plist` 的 `3.0.0/3.0.0`（`build.sh:73-84, 292-295`）；`GATHER_BUILD_NUMBER` 单独设置但无版本时被静默忽略（`build.sh:106-108`），文档未写。建议要求本地 bundle 构建显式 `GATHER_VERSION`，并把该行为写入 DEVELOPMENT。

## 1. build.sh / ci.yml 对照

### 1.1 变量接线

| 变量 | build.sh | CI | 文档 | 结论 |
| --- | --- | --- | --- | --- |
| `GATHER_ARCHS` | `:45-67` universal/arm64/x86_64；空=host | `ci.yml:146` universal | `DEVELOPMENT.md:97-105` | 自洽；release 不强制（P1-1） |
| `GATHER_VERSION` | `:78-92`，tag 回退、去 v、正则 | `:170-183`（tag/input） | `:106-108` | 自洽 |
| `GATHER_BUILD_NUMBER` | `:93-105`，否则 commit count | 未设 | `:109-110` | 无版本时静默忽略（P2-18） |
| `GATHER_SDK_VERSION` | `:130-138` 探测并 export | `:92-96` / `:167-169` | `:162` | 无 vtool 断言（P1-4/P2-2） |
| `CODESIGN_IDENTITY` | `:457-523` | `:149` + 导入证书 `:184-195` | `:111-114` | 自洽；允许 `-`（P1-1） |
| `GATHER_NOTARIZE` | `:529-565` | `:147` + 凭据 `:150-153` | `:115-119` | 自洽；zip 顺序缺陷（P1-2） |
| `GATHER_NOTARY_PROFILE` / `APPLE_*` | `:540-546` | `:150-153` | `:165-166` | profile 在 hosted runner 不可用（P2-10） |
| `GATHER_RELEASE` | `:34-40` | `:148` | `:120-121` | 不强制公证/universal（P1-1） |
| `OUTPUT_DIR` | `:20-32` | 默认 `release/` | `:83` | 校验恒真（P2-1） |
| `CONFIGURATION` | `:19` 默认 release | 未设 | README `:79-80` 要求设 | 文档冗余（P2-13） |

### 1.2 CI job 依赖

- `boundary`（ubuntu）→ `gates`（ubuntu）；`gather-core`（macos-14）→ `gather-app`（macos-14）→ `release`（macos-14，`needs: [gates, gather-app]`，tag/dispatch 条件）；`toolchain-compat` 只依赖 `boundary`。
- 合规点：release 传递依赖 core tests 与 app tests；`permissions: contents: read` 足够上传 artifact；`fetch-depth: 0` 仅在 release job 设置（`:158-161`），保证 tag/describe。
- 缺口：release 不依赖 `toolchain-compat`（可接受，drift guard 非发布门）；release 无 `vtool`/build-info/app-arch 断言；插件缺失仅 warning（P1-3）；zip 未重打（P1-2）。

### 1.3 产物校验矩阵

| 校验 | build.sh | CI | 结论 |
| --- | --- | --- | --- |
| app universal 切片 | `:303-316` lipo 断言 | `ci.yml:228` 仅打印 | CI 依赖 build.sh（P2-11） |
| 插件切片 | `:396-411` + release exit | `:213-223` 断言（存在时） | 存在时自洽，缺失时放行（P1-3） |
| 版本注入 | `:282-295` 写后回读 | `:237` 比对 tag | 自洽 |
| build-info.json | `:442-454` 生成/解析 | 未校验 | P2-11 |
| FaceModels/本地化/entitlements | `:201-271` | 通过 build.sh | 自洽 |
| 签名/entitlement 回读 | `:490-516` | `:229-234` | 自洽（真实凭据未验） |
| 公证/stapler/spctl | `:556-563` | `:235-236` | 逻辑自洽；zip 顺序缺陷（P1-2） |
| zip sha | 生成 zip | `:238-239` | 对旧 zip 计算（P1-2） |

## 2. 版本/架构来源

| 产物 | 版本来源 | 架构来源 | 证据/缺口 |
| --- | --- | --- | --- |
| app `Info.plist` | 源文件 `3.0.0/3.0.0` 回退；组装时 `GATHER_VERSION`/tag + `GATHER_BUILD_NUMBER`/commit count | 无 plist 字段；Mach-O 由 `--arch` 决定 | `Info.plist:30-33`；`build.sh:282-291`；无 `CFBundleIconFile`（P1-5） |
| `Gather.entitlements` | 无版本 | 无架构 | 静态文件；`build.sh:259-271, 490-516`；apple-events=true，无 sandbox |
| SPM 资源 bundle | SwiftPM 生成，无注入 | 无架构（资源） | `build.sh:188-199, 320-337`；FaceModels 与 en/zh-Hans 断言 |
| `GatherLink.coplugin` | `Info.plist` 固定 `1.0.0/1` | `Makefile` `TARGET_ARCH` 逐切片 + `lipo` | `Makefile:6-7,10`；`build.sh:364-422`；版本不注入（P2-7） |
| `build-info.json` | 取最终 Info.plist（注入后） | `lipo -archs` app 二进制 | `build.sh:442-449`；无 dirty/插件/SDK 实际值（P2-3） |
| Mach-O `LC_BUILD_VERSION` | 部署目标 14.0 + SDK 版本 | `--arch` | `Package.swift:59-66`；无 vtool 门（P1-4） |

## 3. Git 卫生

| 项 | 实测 | 判断 |
| --- | --- | --- |
| 工作区 | `git status --porcelain` 空 | 干净，无未提交文件 |
| 分支/远端 | `refactor` ahead 50；`main` ahead 305；`origin/main...HEAD` 0/70 | 未推送；release 无法触发（P1-6） |
| tag | 0；`git describe` fatal | 本地版本回退 3.0.0（P2-18） |
| stash/merge | 0 / 0 | 线性历史，无遗留 |
| 临时文件 | 无 `.cleanup-verify`、`swbuild.tmp.*`、`*.tmp.md`、`release/`、`.gather/` | 好；`.cleanup-verify` 未 ignore（P2-17） |
| ignored | `.build` ×4（约 12.5 GB）、SDK 1.9 MB、`tests/` 本地 fixtures | 不入库；磁盘垃圾（P2-17） |
| secrets | 无 p12/pem/key/cer/mobileprovision 跟踪或历史；`.git/config` 无 token；无 `.env*` | 好 |
| 大文件 | weight.bin 38.5 MB、fixtures 3.6 MB、archive PNG 3.6–3.9 MB；`.git` 78 MB | 无 LFS（P2-16） |
| 提交序列 | 50 commits，conventional；1 个 719 文件提交、1 个 checkpoint、1 个混合 scope、1 个自指过期 docs | 可读但不理想（P2-15） |

“未提交/未推送提示”确实存在：`docs/reviews/architecture-remediation-status.md:4` 与 `:57`、`docs/refactor-decisions.md:1496`；但 `docs/final-report.md:168` 的“工作区未提交”已过期（P2-14）。

## 4. 文档发布命令与脚本一致性

| 文档 | 声明/命令 | 脚本实际 | 结论 |
| --- | --- | --- | --- |
| `README.md:78-81` | `build.sh`；设 `CONFIGURATION=release`；无身份不签名 | 默认 release；仅 `CODESIGN_IDENTITY` 存在时签名 | 冗余/易误解（P2-13） |
| `docs/DEVELOPMENT.md:83-90` | 产物 `release/Gather.app`；`GATHER_RELEASE=1` 版本/签名/公证硬门 | 公证不强制（P1-1） | **不一致** |
| `:97-105` | 三架构；插件同切片；release 缺切片 exit 1 | 一致（SDK 存在时） | 一致；缺失时放行（P1-3） |
| `:106-110` | 版本/tag 回退；build number；公证要求递增 | 版本一致；递增说法错误 | 部分不一致（P2-13） |
| `:111-119` | 签名/公证命令与凭据 | 一致 | 一致（zip 顺序除外，P1-2） |
| `:120-121` | release 门任一缺失即失败 | 不强制公证/universal | **不一致**（P1-1） |
| `:126-130` | 本机完整发布命令 | 缺 `GATHER_RELEASE=1` | **不一致**（P2-13） |
| `:133-144` | universal dry-run + lipo/plutil | 一致 | 一致 |
| `:146-154` | 发布前检查 + shasum | shasum 的是 staple 前 zip | **不一致**（P1-2） |
| `:156-158` | build-info 字段 | 字段一致；缺 dirty/插件 | 部分（P2-3） |
| `:160-170` | CI 触发/依赖/secrets/插件断言 | 基本一致；profile 路径不可用 | 部分（P2-10） |
| `docs/README.md:85` | 脚本只构建 core/app | 还会构建插件 | 漏写（P2-13） |

## 5. 真实未验证项与可执行命令

### 5.1 凭据 / 签名 / 公证

- **本机有 1 个有效 Developer ID Application 身份**（`security find-identity -v -p codesigning`，团队 `QW6428Q67R`）；未发现本地 notarytool profile 目录（`~/Library/Developer/notarytool` 不存在；不代表 keychain 中一定没有 profile）。
- **未验证**：真实签名、`--timestamp`、notarytool submit、staple、`spctl`、CI secrets。文档 `final-acceptance-build.md:132` 与 `status.md:41` 已如实记录未验。
- 命令（需在无 DSH 嵌套沙盒的终端；本机 `build.sh` 原样执行曾因 SwiftPM `sandbox-exec` 失败，见 `final-acceptance-build.md:73`）：

```bash
# 1) 存公证凭据（App Store Connect app-specific password）
xcrun notarytool store-credentials "gather-notary" \
  --apple-id "<APPLE_ID>" --team-id "QW6428Q67R" --password "<APP_SPECIFIC_PASSWORD>"

# 2) 完整发布（本地；建议补 GATHER_RELEASE=1 以启用硬门）
GATHER_RELEASE=1 GATHER_ARCHS=universal GATHER_VERSION=3.1.0 \
  CODESIGN_IDENTITY="Developer ID Application: Zeyu Pan (QW6428Q67R)" \
  GATHER_NOTARIZE=1 GATHER_NOTARY_PROFILE=gather-notary \
  ./desktop/native/build.sh

# 3) 验证（脚本内部已有，另留日志）
codesign --verify --deep --strict --verbose=2 release/Gather.app
codesign -dv --verbose=4 release/Gather.app 2>&1 | grep -E 'Timestamp|Runtime Version'
xcrun stapler validate release/Gather.app
spctl -a -t exec -vvv release/Gather.app
codesign -d --entitlements :- release/Gather.app 2>/dev/null | grep -A1 'com.apple.security.automation.apple-events'

# 4) 验证分发 zip 确实含 staple（当前 P1-2 会失败）
rm -rf /tmp/gather-zip-check && ditto -x -k release/Gather.zip /tmp/gather-zip-check
xcrun stapler validate /tmp/gather-zip-check/Gather.app
```

### 5.2 universal / x86_64

- `lipo -archs` 历史证据：app `x86_64 arm64`（`final-acceptance-build.md:93`）；本地插件 arm64。
- **未验证 x86_64 运行期**：`arch -x86_64 /usr/bin/true` → `Bad CPU type in executable`（exit 1），本机无 Rosetta；未做 Intel 冷启动、SFace CoreML、资源 bundle、Apple Events。
- 命令：

```bash
# 需要 universal 产物
GATHER_ARCHS=universal GATHER_VERSION=0.0.0-dev ./desktop/native/build.sh
lipo -archs release/Gather.app/Contents/MacOS/Gather
lipo -archs release/Gather.app/Contents/PlugIns/GatherLink.coplugin/Contents/MacOS/GatherLink
vtool -show-build release/Gather.app/Contents/MacOS/Gather

# 安装 Rosetta 后跑 x86 切片
softwareupdate --install-rosetta --agree-to-license
arch -x86_64 release/Gather.app/Contents/MacOS/Gather
```

### 5.3 插件双架构 / C1 加载

- SDK 本机存在（`Capture_One_Plugin_SDK_(Mac)_v1.0.1`，ignored）；`CaptureOnePlugins.framework` `lipo` = `x86_64 arm64`；但 796a2b2 后无实际构建记录。
- **未验证**：在 Capture One 中加载插件、Intel 插件、`gather://import` 端到端、相对 `LC_RPATH` 解析（P2-6）。
- 命令：

```bash
make -C desktop/coplugin clean
make -C desktop/coplugin TARGET_ARCH=arm64 all
lipo -archs desktop/coplugin/GatherLink.coplugin/Contents/MacOS/GatherLink
make -C desktop/coplugin TARGET_ARCH=x86_64 all
lipo -archs desktop/coplugin/GatherLink.coplugin/Contents/MacOS/GatherLink
otool -l desktop/coplugin/GatherLink.coplugin/Contents/MacOS/GatherLink | grep -A2 LC_RPATH
```

### 5.4 GUI

- **未验证**：启动、Dock/菜单图标（P1-5）、Liquid Glass（P1-4）、C1 授权、多语言系统菜单、签名后 TCC。
- 命令：`open release/Gather.app`（人工冒烟；本环境无 GUI 自动化，不得声称视觉验收）。

### 5.5 CI release

- **未验证**：release job 从未运行（P1-6）；secrets 是否存在无法读取；runner SDK 上限为版本推断（P1-4）；`macos-14` 生命周期未联网复核。
- 命令：

```bash
git push origin refactor
git tag -a v3.1.0 -m "Gather 3.1.0" && git push origin v3.1.0
gh run list --workflow ci.yml --limit 5
gh run view <run-id> --log
```

## 限制

- 未运行 `build.sh`/`swift build/test`/门禁/签名/公证/GUI；所有“会失败/会成功”的判断均来自代码路径或文档证据，未把静态推断写成实测。
- 无网络：GitHub runner 生命周期、Xcode 26 最低系统要求未外部复核；P1-4 的 SDK 上限标注为疑似。
- `security find-identity` 只能证明本机存在身份，不能证明 CI secrets、证书私钥或公证凭据可用。

## P2 清理回执（2026-10-22 后续修改）

本节是修复记录，不改变上面的原始审计结论。基线 `f02c715`；只改
`desktop/native/build.sh`、`.github/workflows/ci.yml`、`docs/DEVELOPMENT.md`
与本回执（应用 `Info.plist` 未改）。验证仅 `bash -n`、Ruby YAML 解析，以及临时副本上的
`vtool`/`install_name_tool` 语法探针（不改仓库二进制）；**未跑
build/test/门禁/签名/公证/GUI**。

| 条目 | 状态 | 处理与残余 |
| --- | --- | --- |
| P2-1 `OUTPUT_DIR` | 已修 | 相对路径按仓库根解析；拒绝 `/`、`//`、结尾斜杠、含 `.`/`..` 段。残余：未用 `readlink -f` 解析符号链接（macOS BSD readlink 无 `-f`）。 |
| P2-2 SDK 默认值注释 | 已修 | 注释改为 Package.swift 默认 14.0；release 下 xcrun 探测失败 exit 1；build-info 记录 Mach-O 实际 sdk 与声明值。非 release 仍按 14.0 回退并告警。 |
| P2-3 build-info 缺口 | 已修 | 新增 `dirty`（true/false/unknown）、`plugin`（切片或 none）、`minos`、`sdk_version`（Mach-O 实际值）与 `sdk_version_declared`。 |
| P2-4 `.arch-*` 入包 | 已修 | 只从嵌入副本删除构建戳；源 `GatherLink.coplugin` 保留给 make 增量。 |
| P2-5 旧 zip 残留 | 已修 | 组装开始即无条件删除 `Gather.zip` 与 `.sha256`；公证分支仍会重打。 |
| P2-6 插件 rpath/10.14 | 部分 | 以 make 命令行 `TARGET=...-macosx14.0` 对齐 minos，release 断言 14.0；嵌入副本删除非便携的相对 `LC_RPATH`（保留 `@`/绝对路径），源 bundle 与 `Makefile` 未改，需 Capture One 实机验证。 |
| P2-7 插件版本硬编码 | 已修 | 嵌入副本注入 app 最终 `CFBundleShortVersionString`/`CFBundleVersion` 并回读；源 `GatherLink/Info.plist` 保持 1.0.0 回退。 |
| P2-8 旧 entitlements | 未修 | `desktop/resources/entitlements.mac.plist` 不在白名单；仍可能被误用。 |
| P2-9 CI 小问题 | 已修 | 去掉 gates 重复的 legacy 门禁；`user_version=2`；`version` 输入必填；concurrency 带 event_name 且发布不被普通 push 取消；actions pin 到 commit SHA。 |
| P2-10 notary profile | 部分 | CI/文档明确 hosted runner 用 Apple ID 三件套、profile 仅 self-hosted；未在 CI 生成临时 profile。 |
| P2-11 产物校验 | 部分 | 新增 app 双切片、每切片 `vtool` minos/sdk、build-info JSON、插件版本/双切片/minos 断言。cache key 未含 Swift/SDK；app CLT-only 探测未动（源码/Package）。 |
| P2-12 供应链/治理 | 部分 | secrets 改为 step 级；actions pin SHA。仍无 `environment`/审批、provenance、GitHub Release；`permissions: contents: read` 未变。 |
| P2-13 文档命令 | 部分 | DEVELOPMENT 完整命令补 `GATHER_RELEASE=1`/`GATHER_ARCHS`/`GATHER_NOTARIZE`，修正“公证要求递增”说法，补 zip staple 复验与 build-info 字段。README/docs README 不在白名单。 |
| P2-14 状态文档过期 | 未修 | 状态/验收文档不在白名单。 |
| P2-15/16/17 提交/LFS/gitignore | 未修 | 历史整理、LFS、`.gitignore` 均不在白名单。 |
| P2-18 build number 静默 | 部分 | 无版本时 warning 说明如何生效，并写入 DEVELOPMENT；本地仍允许 Info.plist 3.0.0 回退，未强制 `GATHER_VERSION`。 |
| P1-5 app icon | 未修（产品 P1） | 仓库无业务 `.icns`/Assets.car/`CFBundleIconFile`；未伪造素材，`Info.plist` 未改。 |
| P1-4 发布 SDK | 部分 | CI 新增 `Assert release SDK`（<26 fail closed）；`runs-on: macos-14` 仍无法提供 Xcode 26，需外部升级 runner。本地 release 只告警并记录实际 sdk。 |

附带改动：CI 的插件缺失分支从 `::warning:: + exit 0` 改为 `::error::`，与
`build.sh` 在 `GATHER_RELEASE=1` 下缺 SDK 直接 exit 1 一致；授权 SDK 仍需
release runner 自行安装（P1-3 外部项未解）。

**本次修改的风险**

- 未编译、未跑 release/CI；`make TARGET` 覆盖与 `vtool` 断言仅按 Makefile/Xcode 语义静态推断。
- `dirty` 取 `git status --porcelain`，未提交/未跟踪源码会标记 true；构建机 git 不可用时为 `unknown`。
- action SHA 于 2026-10-22 通过 GitHub API 解析（checkout v4.4.0 / cache v4.3.0 / upload-artifact v4.6.2），未在 CI 实跑。
- release job 在当前 `macos-14` 上会在 SDK 断言处失败，这是刻意的 fail-closed，不是本次修改引入的构建错误。
- 插件源 bundle `Makefile` 仍生成构建机相对 `LC_RPATH`（嵌入副本已删）；`install_name_tool` 只在复制的 Mach-O 上做过语法验证，未在 C1 实机加载。app icon 仍缺失。
