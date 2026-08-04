# ImageService 解码器注入重构执行计划

- 目标提交：`f384bce`（修复 Linux CI 的 sips 单测失败）之后的 follow-up
- 关联问题：`it.skipIf(process.platform !== 'darwin')` 只是让 CI 变绿的补丁，
  并非根治；本计划将平台相关的解码器组合从服务核心移出，恢复 CI 对
  sharp→sips 回退链的测试覆盖。

---

## 1. 背景与问题

### 1.1 触发事件

`ImageService` 的 sharp→sips 回退单测在 Linux CI（`ubuntu-latest`）失败：

```
FAIL tests/unit/services/image/image-service.test.ts > uses the same
     Sharp-to-sips fallback for priority requests
     → unsupported image
```

本地 macOS 通过（173/173），CI Linux 失败——原因是测试依赖的平台条件只满足于 macOS。

### 1.2 根因

服务核心 `desktop/src/main/services/image/image.service.ts` 中存在**两处**平台耦合：

**耦合点 1 — 构造器硬编码解码器组合**（image.service.ts:219-221）：

```ts
this.registry.register(new SharpDecoder(settings))
if (process.platform === 'darwin') {
  this.registry.register(new SipsDecoder())
}
```

**耦合点 2 — `decodeWithFallback` 硬编码 sharp→sips 特例**（image.service.ts:364-395）：

```ts
const decoder = this.registry.resolve(path)
try { return await decode(decoder) }
catch (primaryError) {
  if (!(decoder instanceof SharpDecoder) || process.platform !== 'darwin') {
    throw primaryError
  }
  const fallback = new SipsDecoder()
  ...
}
```

问题归纳：

1. **组合职责错位**：哪些解码器可用、按什么顺序，属于组合（composition）关注点，
   应位于 DI 组装根（`init.ts`，此处已注入 cache/settings），而非服务类内部。
2. **可测试性被破坏**：回退行为只能在本机平台被确定性验证；在非 darwin 上测试
   必然失败或被迫 skip。`it.skipIf` 使 sharp→sips 回退在 CI 上**永远不执行**。
3. **特例化设计**：`instanceof SharpDecoder` + 平台判断把"回退链"写死为
   sharp→sips 一对，无法表达"按注册顺序依次尝试多个解码器"这一通用语义。

---

## 2. 目标与非目标

### 2.1 目标

1. 解码器集合变为**可注入**，平台判断只存在于 DI 组合根。
2. `decodeWithFallback` 泛化为**按注册顺序的回退链**，删除 `instanceof`、
   `process.platform`、`new SipsDecoder()` 特例。
3. 回退单测在**任意平台**（含 Linux CI）确定性运行，恢复 CI 覆盖。
4. 生产行为在 macOS / Linux 上**完全不变**。

### 2.2 非目标

- 不改动解码器本身的实现（`SharpDecoder` / `SipsDecoder` / `sips-decoder.ts` 逻辑）。
- 不新增第三种解码器。
- 不做性能优化（回退路径调用次数与当前一致）。

---

## 3. 现状梳理

| 位置 | 当前行为 | 问题 |
|---|---|---|
| `container.ts:49` | `THUMBNAIL_CACHE: Symbol(...)` | 已有注入 cache/settings，但无解码器 token |
| `init.ts:88` | `registerSingleton(THUMBNAIL_CACHE, TieredThumbnailCache)` | 组合根未参与解码器组合 |
| `image.service.ts:219-221` | 构造器按平台注册解码器 | 平台分支进入服务核心 |
| `image.service.ts:364-395` | sharp→sips 特例回退 | 硬编码 + 平台判断 + `instanceof` |
| `registry.ts:4-17` | `register()` / `resolve()` 按扩展名返回首个匹配 | 缺少"依次尝试所有匹配解码器"能力 |
| `tests/unit/services/image/image-service.test.ts` | 6 处 `new ImageService(cache, settings)` 依赖构造器自动注册 | 与平台绑定；1 处需 skipIf |

---

## 4. 目标设计

### 4.1 解码器集合可注入

新增 DI token `IMAGE_DECODERS`，在组合根组装并按平台选择：

```ts
// desktop/src/main/di/container.ts
export const DI_TOKENS = {
  ...
  IMAGE_DECODERS: Symbol('ImageDecoders'),
}
```

```ts
// desktop/src/main/di/init.ts
container.register(DI_TOKENS.IMAGE_DECODERS, {
  useFactory: (c) => {
    const settings = c.resolve<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
    const decoders: ImageDecoder[] = [new SharpDecoder(settings)]
    if (process.platform === 'darwin') decoders.push(new SipsDecoder())
    return decoders
  },
})
```

> 唯一保留的 `process.platform` 判断移到这里，且不再引用测试可达的私有构造。

### 4.2 服务构造器接收解码器列表

```ts
// image.service.ts
constructor(
  @inject(DI_TOKENS.THUMBNAIL_CACHE) cache: ThumbnailCache,
  @inject(DI_TOKENS.SETTINGS_SERVICE) settings: SettingsService,
  @inject(DI_TOKENS.IMAGE_DECODERS) decoders: ImageDecoder[],
) {
  for (const decoder of decoders) this.registry.register(decoder)
  ...
}
```

删除构造器中的 `if (process.platform === 'darwin')` 分支。

### 4.3 回退链泛化

`DecoderRegistry` 增加"返回所有匹配扩展名的解码器"能力：

```ts
// registry.ts
resolveAll(filePath: string): ImageDecoder[] {
  const ext = path.extname(filePath).toLowerCase()
  const matches = this.decoders.filter(d => d.supports(ext))
  if (matches.length === 0) {
    throw new Error(`Unsupported file extension: ${ext}`)
  }
  return matches
}
```

`decodeWithFallback` 改为按注册顺序依次尝试：

```ts
// image.service.ts
private async decodeWithFallback<T>(
  path: string,
  operation: string,
  decode: (decoder: ImageDecoder) => Promise<T>,
): Promise<T> {
  const candidates = this.registry.resolveAll(path)
  const errors: unknown[] = []
  for (const decoder of candidates) {
    try {
      return await decode(decoder)
    } catch (error) {
      errors.push(error)
      console.warn(
        `[ImageService] ${decoder.name} failed for ${operation}: ${path}`,
        error,
      )
    }
  }
  throw new AggregateError(
    errors,
    `Unable to decode ${path} for ${operation} with any of: ${candidates.map(d => d.name).join(', ')}`,
  )
}
```

行为对照：

- **macOS**（组合根注册 `[Sharp, Sips]`）：sharp 失败 → 尝试 sips → 均失败抛
  AggregateError。与现有一致。
- **Linux**（组合根仅注册 `[Sharp]`）：sharp 失败 → 无更多候选 → 抛
  AggregateError（仅含一个错误）。与现有"抛 primaryError"的区别仅是包装层，
  语义等价且更一致。
- **新增**：未来若注册第三个解码器，回退链自动延伸，无需改服务代码。

### 4.4 删除全部特例

`decodeWithFallback` 中不再出现：
- `instanceof SharpDecoder`
- `process.platform`
- `new SipsDecoder()`
- 手写 `fallback.supports(ext)` 二次判断（由 `resolveAll` 统一承担）

---

## 5. 详细改动（按文件）

| 文件 | 改动 |
|---|---|
| `desktop/src/main/di/container.ts` | 新增 `IMAGE_DECODERS` token |
| `desktop/src/main/di/init.ts` | 用 `useFactory` 注册 `IMAGE_DECODERS`（平台判断在此）；无需改 `IMAGE_SERVICE` 注册 |
| `desktop/src/main/services/image/registry.ts` | 新增 `resolveAll()`；`resolve()` 保留（兼容其它调用方，若仅服务使用可删） |
| `desktop/src/main/services/image/image.service.ts` | 构造器增加第三注入参数并移除平台分支；`decodeWithFallback` 泛化为回退链 |
| `desktop/src/main/services/image/index.ts` | 如需导出 `ImageDecoder` 类型供 init.ts 引用，确认导出 |
| `tests/unit/services/image/image-service.test.ts` | 6 处构造改为显式传 `decoders`；回退测试注入 `[new SharpDecoder(settings), new SipsDecoder()]` 并**删除 skipIf**；新增"回退链依次尝试"断言 |
| `docs/DEVELOPER.md` | 记录 `IMAGE_DECODERS` 注入约定（平台判断只允许出现在组合根） |

### 5.1 测试改造要点

```ts
function createService(
  cache: ThumbnailCache,
  settings: SettingsService,
  decoders: ImageDecoder[],
) {
  return new ImageService(cache, settings, decoders)
}
```

- 大多数用例：`[new SharpDecoder(settings)]`（模块已被 `vi.mock`，实例即 mock）。
- 回退用例：`[new SharpDecoder(settings), new SipsDecoder()]`，然后
  `decoderMocks.sharpThumbnail.mockRejectedValueOnce(...)` → 断言
  `sipsThumbnail` 被调用、cache 写入一次。
- 新增断言：sharp、sips 都失败时抛 `AggregateError`，且两次尝试的顺序正确。

> 由于 `vi.mock` 使 `new SharpDecoder()` / `new SipsDecoder()` 返回 mock 实例，
> 测试在所有平台上行为一致；`skipIf` 移除后 Linux CI 会真实执行回退链。

---

## 6. 验收门槛

1. `npm run typecheck`、`npm run lint` 通过。
2. `npm run test:vitest` 全绿，且**回退用例在 Linux 上实际执行**（`it.skipIf` 已删除，
   测试数从 173 增为 176：含新增的 preview/dimensions 回退链用例）。
3. `scripts/application-scale-benchmark.mjs`（macOS）跑通，确认缩略图/预览解码
   行为与 `f384bce` 一致。
   > 注：本环境（无头/非固定机）下 benchmark 在画廊图像解码处超时，且 `f384bce`
   > 基线同样超时——属环境问题，非本次改动引入。生产解码行为改由 CI e2e
   > （macOS runner，真实解码）与单元测试（回退链全平台确定性执行）验证。
4. CI `unit` job（ubuntu）全绿；e2e job（macOS）全绿。
5. `git diff --check` 无空白错误。

---

## 7. 风险与回滚

| 风险 | 概率 | 应对 |
|---|---|---|
| `resolveAll` 改变"首个支持即返回"语义 | 低 | 现有注册顺序唯一（sharp 在前）；e2e 在 mac 回归 |
| AggregateError 包装改变调用方错误识别 | 低 | 主进程 `gather-image` 协议只按非 200 处理；单测覆盖 |
| DI `useFactory` 在测试环境解析失败 | 低 | 单测不经过容器，直接构造；仅生产经 DI |
| 回退链对同一文件重复 warn | 低 | 仅整链失败时 warn 一次（解码语义不变，日志行为收紧） |

回滚：还原 `image.service.ts`、`registry.ts`、`init.ts`、`container.ts` 四处改动，
并恢复测试的 `skipIf` 即可（单一提交，无迁移）。

---

## 8. 执行顺序

1. `registry.ts`：新增 `resolveAll()`（纯增量，不影响现有调用）。
2. `container.ts` / `init.ts`：新增 `IMAGE_DECODERS` token 与组合根注册。
3. `image.service.ts`：构造器注入 + `decodeWithFallback` 泛化；删除平台分支与特例。
4. 测试：6 处构造改造 + 回退用例去 `skipIf` + 新增多解码器失败断言。
5. 本地全量验证（typecheck / lint / test:vitest；benchmark 见 §6 注释）。
6. 提交并推送，观察 CI（unit ubuntu + e2e mac）全绿。

> 建议单次提交完成（改动彼此耦合，拆分会产生中间不可测状态）。
> Commit 建议：`refactor(image): 解码器集合可注入，回退链泛化，恢复 CI 覆盖`
