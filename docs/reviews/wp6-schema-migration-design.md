# WP6 Schema 迁移与发布设计（HEAD b97d10f）

> 快照：2026-10-22，HEAD `b97d10f`。只读设计：本文件是唯一落盘产物，未改源码/测试/Package/脚本/CI。
> 依据：`docs/reviews/architecture-remediation-plan.md` WP6（:94-96）、`Database.swift`、`SchemaV1.swift`、`Schema.swift`、`DatabaseFacadeTests`、`SchemaV1Tests`、`MigrationTests`、`desktop/native/build.sh`、`.github/workflows/ci.yml`。
> 路径约定：源码证据相对 `desktop/native/gather-core/Sources/GatherPersistence/Database/`（下文只写文件名:行号）；测试相对 `desktop/native/gather-core/Tests/GatherCoreTests/Database/`。
> 计数口径：全部 file:line 与数字为**读码实测**（grep/wc），不是引用。**未执行** `swift test`：本机 core 构建当前红，原因是他人在编辑的文件（见 §8）。

## 0. 结论（先行）

| 决策 | 选择 | 一句话理由 |
| --- | --- | --- |
| 版本策略 | **user_version 唯一权威 + 线性迁移器；不建 `schema_migrations` 表** | 与 DDL 同事务原子、单一真值；账本的第 2 真值正是 Cut 2 前"双 Schema 真相源"的病灶 |
| V1→V2 内容 | **WP6b 先做 no-op 版本位（DDL 与 V1 逐字相同），真实载荷留给需求驱动的 V3** | fingerprint 的 canonical 不含 user_version（`Database.swift:393-454`）→ 43/373/69/62 与指纹全部不变，首次迁移 diff 面 = 1 个常量 + 1 个注册项 |
| 打开语义 | empty/current/older/**newer 一律 fail closed**；破坏性改名重置只在 `GATHER_DEV_RESET=1`（且 DEBUG）下允许 | 1.0 之后"新版本库被旧版本静默改名"是数据事故；现状 `Database.swift:166-177` 无条件重置 |
| 备份 | 迁移前 `VACUUM INTO <db>.pre-v2-<ts>`，保留 3 套 | 一致性快照、天然不含陈旧 WAL 页；比文件拷贝少管两个 sidecar |
| 事务 | 迁移用 **BEGIN IMMEDIATE** + 同一事务内写 `PRAGMA user_version` | 现状 `DB.swift:346` 是 deferred BEGIN，WAL 下读→写升级会撞 `SQLITE_BUSY_SNAPSHOT` |
| 发布 | build.sh 加版本注入 + `--timestamp` + 双架构 + notary/staple/verify；新增 release workflow | 现状 `build.sh:210-212` 缺 `--timestamp`，**不可公证**；Info.plist 版本硬编码 3.0.0（`Info.plist:26-29`） |

估算：WP6a 2.5 + WP6b 1.5 + WP6c 3 = **7 人日**（plan 给 5–8）。

## 1. 现状：open/reset 流程与 shape fingerprint 的精确行为

### 1.1 入口与状态判定

`Database.open(at:options:)`（`Database.swift:136-183`）：

| 步骤 | 行为 | 证据 |
| --- | --- | --- |
| 内存库短路 | `path == ":memory:"` → `openInMemory` | `:137` → `:186-203` |
| 建父目录 | 失败抛 `.io` | `:138` → `:664-679` |
| 建立连接 | `DBConnection(path:)` 已设 WAL / foreign_keys=ON / busy_timeout=5000（`DB.swift:218-223`），再覆盖 `Options` 的 4 条 PRAGMA | `:144` → `:288-303`、`:306-313` |
| 打开即失败 | 只有 `indicatesNotDatabaseFile`（`DatabaseError.swift:170`）且未重置过 → 重置后重试；其余（busy/io）如实上抛 | `:145-153` |
| 状态判定 | `inspectSchema` | `:156` → `:315-342` |
| 重置上限 | `didReset` 只允许一次，二次不兼容直接抛 `.schema` | `:140-141`、`:168-173` |

`inspectSchema`（`:315-342`）：

```text
v = PRAGMA user_version                        // :317；readUserVersion :344-351
case v == 1:
    if let issue = schemaShapeIssue(...)       // :322
        log "schema_shape_mismatch ..."        // :323-326
        return .incompatible(version: 1)       // :327
    return .current                            // :329
case v == 0:
    return userTableCount == 0 ? .empty : .incompatible(version: 0)   // :330-332；:353-363
default:
    return .incompatible(version: v)           // :333-334
catch DBError:
    if indicatesNotDatabaseFile → .incompatible(nil)   // :336-338
    else throw                                          // :339-340（busy/io 绝不触发重置）
```

### 1.2 三个分支的动作

| 状态 | 动作 | 证据 |
| --- | --- | --- |
| `.current` | `assertReady`（版本 + 列形 + `PRAGMA foreign_keys==1` + `foreign_key_check` 空）→ 返回 | `:157-159` → `:552-573` |
| `.empty` | `createSchema`：**单事务**内 `exec(SchemaV1.sql)`（DDL 尾部自带 `PRAGMA user_version = 1`，`SchemaV1.swift:815`），提交后回读版本断言 | `:161-164` → `:533-545` |
| `.incompatible` | 关连接 → 未重置过则 `resetIncompatibleFiles` → `didReset=true` → continue；已重置过抛 `.schema` | `:166-177` |

重置细节（`:584-617`）：先 `-shm`、再 `-wal`、最后主库（`:592-609`，顺序理由见 `:577-583`），目标名 `<db>.incompatible-yyyyMMdd-HHmmss[-N]`（`:620-637`），随后按 `Options.retainIncompatibleCopies`（默认 3，`:65`、`:71`）从旧到新淘汰（`:640-662`），打一条 `schema_reset` warn（`:613-616`）。任一步移动失败抛 `.io`（`:594-599`、`:603-608`）。

**结论：当前不存在任何"就地升级"路径。version≠1 一律改名重建**（plan 的指标就是"Schema 版本 1（重置）→ 2+（迁移）"，`architecture-remediation-plan.md:145`）。

### 1.3 shape fingerprint 的精确算法

`readSchemaShape`（`:386-467`）把库的物理形态规范化成文本再 SHA-256（`:456-458`）：

| 段 | canonical 行 | 排序 | 证据 |
| --- | --- | --- | --- |
| 表 | `table\t<name>\n` | `ORDER BY name` | `:390`、`:399` |
| 列 | `column\t<name>\t<type>\t<notnull>\t<dflt>\t<pk>\n` | `ORDER BY cid` | `:402-421`（`:415` 按 cid 排） |
| 外键 | `fk\t<refTable>\t<seq>\t<from>\t<to>\t<on_update>\t<on_delete>\t<match>\n` | `ORDER BY (id,seq)` | `:423-444`（`:438` 排序） |
| 显式索引 | `index\t<name>\t<sql>\n` | `ORDER BY name`，且 `sql IS NOT NULL`（排除 `sqlite_autoindex_*`） | `:447-454` |

口径要点（改设计必须知道）：

1. **user_version 不进 fingerprint**（canonical 只有 table/column/fk/index）→ 同一 DDL 下 v1 与 v2 指纹相同。这正是 §3 选 no-op V2 的技术前提。
2. **表级 SQL 原文不进**（没有 `CREATE TABLE` 文本），所以 `CHECK` 表达式、表选项改动**不会**被指纹发现；能发现的是列名/类型/notnull/默认值/pk、外键、显式索引 SQL。
3. 默认值经 `shapeText`（`:513-526`）规范化：NULL→`<null>`、blob→`blob:<count>`。
4. 判定三重（`:473-506`）：4 个计数（`:477-488`）+ `requiredTableColumns` 关键列子集（`:489-499`，`SchemaV1.swift:61-73`）+ 指纹（`:500-504`）；任一不符返回以"；"拼接的中文原因。
5. 指纹被 `assertReady`（`:558`）隐式钉住：stale 常量会让所有 open/内存库用例变红。但**没有任何用例显式断言指纹**（全仓 grep：`expectedShapeFingerprint` 只出现在 `Database.swift:500`、`SchemaV1.swift:80`），失败信息是笼统的"列形不符"——WP6 补测项（§5 T11）。

### 1.4 现状 vs WP6 目标

| 维度 | 现状 | WP6 目标 |
| --- | --- | --- |
| 版本来源 | `SchemaV1.userVersion = 1`（`SchemaV1.swift:46`）+ 镜像 `SchemaSQL.currentSchemaVersion = 1`（`Schema.swift:13`） | `SchemaVersion` 类型 + `SchemaCatalog.current` |
| 迁移 | 无（旧链与 `MigrationRunner` 已在 Cut 2 删除，见 `MigrationTests.swift:8-11`） | `SchemaMigration` 协议 + 线性计划 |
| 旧库 | 改名重置（含 -wal/-shm） | 备份 → 事务迁移 → 校验；失败保留旧库并抛错 |
| 新库 | 重置（会丢弃新版数据） | fail closed；`GATHER_DEV_RESET=1` 才允许改名 |
| 校验 | `Database.open` 内联约 160 行 | 抽到 `SchemaShape.swift`，`Database.swift` 679→约 520 行 |
| 发布 | 版本硬编码 3.0.0、单架构、签名可选、无公证 | 版本注入 + universal + 公证/staple/verify |

## 2. 目标版本策略：user_version=2 + schema_migrations，还是仅迁移器

### 2.1 方案 A（推荐）：`PRAGMA user_version` 唯一权威 + 线性迁移器

- 版本号存库头，**受事务保护**：迁移与版本号同生共死，"迁移一半但版本没动"或"版本动了但 DDL 没落"两个半成品状态都不可能存在。
- 迁移器只认整数序列：`plan(from: 1) = [V1→V2]`；缺步、跳号、重复 `(from,to)` 在注册表构造期就报错，不依赖运行期状态。
- 现状已证明"版本 + 列形"二元判定够用：`inspectSchema` 用 4 计数 + 关键列 + 指纹兜住"版本对但形态错"（`:322`）。账本表能提供的**额外**信息只有"何时、由哪个构建迁移"，对 1.0 单机单写者没有决策价值。

### 2.2 方案 B：`user_version` + `schema_migrations` 表

代价是计数与不变量层面的，不是风格：

1. **形态成本**：账本表必须出现在**目标版本 DDL** 里 → 43→44 表、373→375 列、显式索引**仍 69**（`TEXT PRIMARY KEY` 走 `sqlite_autoindex`，被 `:449` 的 `sql IS NOT NULL` 排除）、外键 62 不变、**指纹必变**。同步点至少 5 处：`SchemaV1.swift:56`、`SchemaV1Tests.swift:399`、`DatabaseFacadeTests.swift:250/283/290/316`、`ADR.md:13/86`、`gather-schema/main.swift:23`。
2. **双真值规则要额外定义**：`user_version=2` 但账本缺 V2 行 / 账本有 V2 行但 `user_version=1`，各判什么？这就是 Cut 2 前"Schema 双真相源"（`docs/reviews/architecture-macro-core.md`）的同构复现。
3. **能力重叠**：checksum 已被指纹覆盖（`:500`）；时间戳只服务排障。
4. **与 WP6a 冲突**：选它就必须给每个 V1 用户库在打开时补建账本表，等于第一次打开就做形态变更，违背"WP6a 只搭框架、行为不变"。

### 2.3 方案 C：只用 `schema_migrations`（明确不采纳）

`user_version` 仍是 SQLite 的公共约定（`sqlite3 file.db 'PRAGMA user_version'`、备份检查、第三方工具都看它），放弃它等于让所有外部检查手段失效；且"读版本"本身要先知道表在哪，bootstrap 顺序无解。

### 2.4 推荐与升级触发条件

**A。** 出现以下任一条件再升级到 B（写进 ADR，避免以后拍脑袋）：

- 出现**非线性**历史（同时维护 1.x / 2.x 两条迁移线，或需要 cherry-pick 单个迁移到旧分支）；
- 需要**压缩基线**（squash）后仍回答"这台机器跑过哪些迁移"；
- 建立支持工单体系，必须回报"何时/哪个构建迁移过"。

届时加账本就是 V3 的一次普通迁移，`SchemaMigration` 协议不变。

## 3. V1→V2 具体迁移内容

### 3.1 选项 A（推荐）：no-op 版本位

```swift
// Sources/GatherPersistence/Database/Migration/SchemaV2.swift
public enum SchemaV2 {
    public static let version = SchemaVersion(2)
    /// 与 V1 逐字相同的 DDL 主体：V2 只做版本位，不改形态。
    public static let ddl = SchemaV1.ddl
    public static let shape = SchemaV1.shape            // 43 / 373 / 69 / 62 + 同指纹
}

// Sources/GatherPersistence/Database/Migration/MigrationV1ToV2.swift
struct MigrationV1ToV2: SchemaMigration {
    let from = SchemaVersion(1)
    let to = SchemaVersion(2)
    let name = "v2-version-only"
    func apply(_ connection: DBConnection) throws {
        // no-op：迁移器在提交前统一写 PRAGMA user_version = 2
    }
}
```

**取舍（必须显式记账）**：

- 得到：① 端到端跑通"备份 → 事务 → 迁移 → 校验 → 提交"的全部真实路径；② 计数/指纹零变动，把"人工同步 5 处数字"这个最大失误源排除在第一次迁移之外；③ `gather-schema dump` 与 V1 只差末行 `PRAGMA user_version`，回归面最小。
- 失去：① 不验证"DDL 变更 + 数据保留"组合（尤其 12-step 表重建）；② 现场无法只靠库文件区分"迁移过"与"忘了迁移"——用 `OpenOutcome.migrated` + `schema_migrate_ok` 日志补足。
- 补偿：**DDL 变更路径用测试专属迁移覆盖**（§5 T3/T4：注入一个 `ALTER TABLE ... ADD COLUMN` 的假迁移 + 一个中途抛错的迁移），不把未使用的 schema 塞进产品。
- 反例先例：`photos.status` 至今不收 `'indexed'`，理由正是"photos 无写入点"（`SchemaV1.swift:38-40`、`SchemaV1Tests.swift:659`）。现在给 `deliveries` 加一个没人写的 `app_build` 列，是同一个味道。

### 3.2 选项 B：带真实载荷（若产品坚持）

最小且安全的是**单条 ADD COLUMN**（`ALTER TABLE ... ADD COLUMN` 只改表头、O(1)、事务内安全；`DROP COLUMN` 需 SQLite ≥3.35，测试已在用 `DatabaseFacadeTests.swift:230`，故本机版本更高）：

```sql
-- V2（示例：记录写 XMP 的构建版本；只有配合 §6 的版本注入才有读者）
ALTER TABLE deliveries ADD COLUMN app_build TEXT NOT NULL DEFAULT '';
```

计数影响：表 **43 不变**；列 **373 → 374**；显式索引 **69 不变**；外键 **62 不变**；**指纹必变**（`:419-420` 的 canonical 含列）。
必须同步的断言点：`SchemaV1.swift:56`、`SchemaV1Tests.swift:6/36/384/399`（含逐表列数表里 `deliveries` 行 +1）、`DatabaseFacadeTests.swift:250/283/290/316`、`ADR.md:13/86`、`gather-schema/main.swift:23`（表数不变，但需新增 374/指纹校验）。
副作用：`deliveries` 写入方（DeliveryRepo）是否补列、`DeliveryRow` 是否按名取值——**这会把 WP6b 变成一次 Delivery 模块改动**，超出 WP6 预算。

若改为新增表 `schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)`：表 **43→44**、列 **373→375**、显式索引 **69 不变**（`TEXT PRIMARY KEY` 是 `sqlite_autoindex`）、外键 62 不变、指纹变；代码侧零读者，属"为迁移而迁移"。

### 3.3 结论

**WP6b 采用 A（no-op）**；第一个**有读者**的 DDL 变更按正常 V3 迁移走，届时同时交 `SchemaV3` 快照 + 迁移 + 计数同步清单（§3.2 即模板）。不采纳"先加列再等读者"的顺序：它让首个迁移同时承担框架与业务两个失败面。

## 4. Database.open 状态机

### 4.1 状态（替换 `Database.SchemaState`，`:279-286`）

```swift
enum OpenState {
    case empty                                   // v==0 且 0 用户表
    case current(SchemaVersion)                  // v==current 且 shape==shape(v)
    case older(SchemaVersion)                    // 0<v<current 且 shape==shape(v)
    case newer(Int)                              // v>current
    case corrupt(CorruptReason)                  // 非 SQLite / v==0 有表 / 版本对但形态不对
}
enum CorruptReason: Sendable {
    case notADatabase, legacyPreV1, shapeMismatch(version: Int, issue: String), unreadableVersion
}
```

### 4.2 转移表（默认 `resetPolicy = .failClosed`）

| 观测 | 状态 | 默认动作 | `GATHER_DEV_RESET=1`（仅 DEBUG） |
| --- | --- | --- | --- |
| 连接/PRAGMA 失败且 errcode 属 NOTADB | corrupt(.notADatabase) | 抛 `.corrupt` | 改名 `.incompatible-*` → 建 current |
| v==0、0 用户表 | empty | 单事务建 current DDL（末行 `PRAGMA user_version = 2`）→ assertReady | 同左 |
| v==0、有表 | corrupt(.legacyPreV1) | 抛 `.corrupt` | 改名重置 |
| 0<v<2、shape==shape(v) | older | **备份 → 单事务迁移 → 校验 shape(2) → assertReady** | 同左 |
| 0<v<2、shape≠shape(v) | corrupt(.shapeMismatch) | 抛 `.corrupt`（**不迁**，避免把残缺库往前提） | 改名重置 |
| v==2、shape==shape(2) | current | assertReady | 同左 |
| v==2、shape≠shape(2) | corrupt(.shapeMismatch) | 抛 `.corrupt` | 改名重置 |
| v>2 | newer | 抛 `.versionUnsupported`，**文件一个字节都不动** | 改名重置 |
| busy/io/interrupted | — | 原样上抛（`:339-340` 的现有纪律保持） | 同左 |

"older 但形态不对不迁移"是新增的关键规则：今天 `Database.swift:322-327` 会把它当 `.incompatible` 直接重置；WP6 之后先看形态——符合 shape(1) 才敢迁，否则交给 devReset。

### 4.3 备份

```swift
// 迁移前、事务外执行
try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")            // 压 WAL，减少副本页
let backup = uniqueBackupPath(for: path, prefix: ".pre-v" + "\(target.rawValue)-")
try connection.exec("VACUUM INTO '" + quoteLiteral(backup) + "';")  // 一致性快照；目标不得存在
try verifyBackup(backup, expecting: from)                          // 只读打开：quick_check + user_version==from
```

- 命名 `<db>.pre-v2-yyyyMMdd-HHmmss[-N]`，复用 `uniqueIncompatiblePath`（`:620-629`）"同秒 `-2`"的逻辑，前缀参数化。
- 保留 `Options.retainMigrationBackups`（默认 3），复用 `:640-662` 的按时间戳淘汰。
- **备份是迁移的前置条件**：备份失败（磁盘满/权限）→ 不迁移、抛 `.io`（与 `:594-599` 同一纪律：绝不吞错）。
- 迁移成功后**不删**备份；迁移失败也保留（它是现场恢复物）。
- 为什么不用 `FileManager.copyItem`：拷贝会把 `-wal` 带出不一致状态，还要额外处理两个 sidecar；`VACUUM INTO` 单文件、只含已提交页。
- 成本约等于库体积（现有资料库 <1 GB → 秒级），启动路径在 `AppBootstrap.swift:146` 的 async 启动里，§7 验收需实测一次耗时。

### 4.4 事务与回滚

```swift
// DB.swift:337：新增事务模式（默认 .deferred，30+ 现有调用点不受影响）
public enum TransactionMode: Sendable { case deferred, immediate, exclusive }
public func transaction<T>(_ mode: TransactionMode = .deferred, _ body: () throws -> T) throws -> T
```

迁移流程（`SchemaMigrator.migrate`）：

```text
1. plan = catalog.plan(from:)                       // 缺步/跳号 → throw .migration（不改库）
2. backup（见 4.3）
3. PRAGMA foreign_keys = OFF                        // 必须在 BEGIN 之前：事务内是 no-op
4. try connection.transaction(.immediate) {
       for step in plan { try step.apply(connection) }
       exec("PRAGMA user_version = <target>;")      // 与 DDL 同事务提交
       guard foreign_key_check 为空 else { throw .migration }
   }                                                // 抛错 → ROLLBACK：DDL 与版本号一起回退
5. PRAGMA foreign_keys = ON
6. 校验 shape==shape(target)，否则抛 .migration     // 库已是 target 版本但形态不对 = 迁移 bug
7. assertReady
```

要点：

- `PRAGMA user_version` 写库头、**随事务提交/回滚**，这是"迁移不可半途"的根本保证。
- `PRAGMA foreign_keys` 在事务内设置被静默忽略（`Database.swift:531-532` 已有同样注释）→ 必须 BEGIN 前关、提交后再开；关闭期间用 `PRAGMA foreign_key_check` 兜底。
- 不用 `Database.write { }`（`:213-217`）：它是 deferred `BEGIN`，且会先拿 `stateLock` 再拿 `connectionLock`；语义没错但掩盖模式选择。迁移直接调 `connection.transaction(.immediate)`。
- 失败后**不重试、不重置**：`didReset` 那套循环（`:140-141`）只服务 reset 分支，迁移绝不能借用——一次瞬时 I/O 错误不能毁掉用户库。
- 迁移失败的库仍停在旧版本，下次启动会再次尝试（幂等），因此 `apply` 必须在事务内自洽。

### 4.5 开发重置

- 开关只在 `Options`：`public var resetPolicy: ResetPolicy = .failClosed`；生产在 `AppBootstrap.swift:146` 构造：

```swift
#if DEBUG
let devReset = ProcessInfo.processInfo.environment["GATHER_DEV_RESET"] == "1"
#else
let devReset = false
#endif
let database = try Database.open(
    at: dbURL.path,
    options: Options(resetPolicy: devReset ? .renameToIncompatible : .failClosed))
```

- **不在 `Database.open` 内部读环境变量**：隐式全局会让测试顺序敏感，也会让 release 包带上一个用户可触发的删库开关。
- 重置永远是**改名**（沿用 `:584-617`），不删除；日志 `schema_reset_dev` 带 `previous_version` 与 `reason`。
- `docs/DEVELOPMENT.md` 增"数据库排障"小节：三种报错（`.corrupt` / `.versionUnsupported` / `.migration`）、备份路径、`GATHER_DEV_RESET=1` 的后果。

### 4.6 `open` 伪代码（可直接落地）

```swift
public static func open(at path: String, options: Options = .default) throws -> Database {
    guard path != inMemoryPath else { return try openInMemory(options: options) }
    try ensureParentDirectory(for: path)

    var didReset = false
    while true {
        let connection: DBConnection
        do { connection = try makeConnection(at: path, options: options) }
        catch {
            let mapped = DatabaseError.map(error)
            guard !didReset, mapped.indicatesNotDatabaseFile else { throw mapped }
            guard options.resetPolicy.allowsReset else { throw DatabaseError.corrupt("不是 SQLite 文件：" + path) }
            try resetIncompatibleFiles(at: path, options: options, detectedVersion: nil, reason: .notADatabase)
            didReset = true; continue
        }
        do {
            switch try inspectSchema(connection, path: path, catalog: options.catalog) {
            case .current(let v):
                try assertReady(connection, expecting: options.catalog.snapshot(v))
                return Database(path: path, connection: connection, options: options, outcome: .opened(v))
            case .empty:
                try createSchema(connection, catalog: options.catalog)
                try assertReady(connection, expecting: options.catalog.currentSnapshot)
                return Database(path: path, connection: connection, options: options,
                                outcome: .created(options.catalog.current))
            case .older(let from):
                let backup = try backupBeforeMigration(connection, path: path, from: from, options: options)
                let to = try SchemaMigrator(catalog: options.catalog).migrate(connection, from: from, path: path)
                try assertReady(connection, expecting: options.catalog.snapshot(to))
                return Database(path: path, connection: connection, options: options,
                                outcome: .migrated(from: from, to: to, backup: backup))
            case .newer(let v):
                connection.close()
                throw DatabaseError.versionUnsupported(
                    "库版本 " + String(v) + " 高于本构建 " + String(options.catalog.current.rawValue) + "：" + path)
            case .corrupt(let reason):
                connection.close()
                guard options.resetPolicy.allowsReset, !didReset else {
                    throw DatabaseError.corrupt("库不可用（" + String(describing: reason) + "）：" + path)
                }
                try resetIncompatibleFiles(at: path, options: options, detectedVersion: nil, reason: reason)
                didReset = true; continue
            }
        } catch {
            connection.close()
            throw error is DatabaseError ? error : DatabaseError.map(error)
        }
    }
}
```

注意：`.older` 分支里 `migrate` 抛错时连接已关、库仍是旧版本、备份保留——**不要**落到 `catch` 里去 reset。

## 5. Migration 协议 / SchemaVersion API 签名 + 测试矩阵

### 5.1 新文件与签名

`Sources/GatherPersistence/Database/Migration/SchemaVersion.swift`

```swift
public struct SchemaVersion: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.init(rawValue: rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "v\(rawValue)" }
    public static let v1 = SchemaVersion(1)
    public static let v2 = SchemaVersion(2)
}
```

`SchemaShape.swift`（把 `Database.swift:368-526` 的 159 行搬出，`Database.swift` 679 → 约 520 行）：

```swift
struct SchemaShapeSnapshot: Sendable {                     // 原 private struct SchemaShape（:368-375）
    let tableCount: Int; let columnCount: Int
    let explicitIndexCount: Int; let foreignKeyCount: Int
    let columnsByTable: [String: Set<String>]; let fingerprint: String
}
public struct SchemaShapeExpectation: Sendable, Equatable {
    public let tableCount: Int, columnCount: Int, explicitIndexCount: Int, foreignKeyCount: Int
    public let requiredColumns: [String: Set<String>]
    public let fingerprint: String
    func issues(against snapshot: SchemaShapeSnapshot) -> [String]   // 原 schemaShapeIssue :473-506
}
enum SchemaShapeReader { static func read(_ connection: DBConnection) throws -> SchemaShapeSnapshot }  // 原 :386-467
```

`Migration/SchemaMigration.swift`

```swift
public struct SchemaSnapshot: Sendable {
    public let version: SchemaVersion
    public let ddl: String          // 不含 PRAGMA user_version
    public let shape: SchemaShapeExpectation
    /// 一次成型：ddl + "PRAGMA user_version = <version>;"
    public var createSQL: String { ddl + "\nPRAGMA user_version = \(version.rawValue);\n" }
}

public protocol SchemaMigration: Sendable {
    var from: SchemaVersion { get }         // 线性：to == from + 1
    var to: SchemaVersion { get }
    var name: String { get }                // 日志/测试标识，如 "v2-version-only"
    /// 在已开启的事务中执行；不得自行 BEGIN/COMMIT，也不得写 user_version（迁移器统一写）。
    func apply(_ connection: DBConnection) throws
}

public struct SchemaCatalog: Sendable {
    public let current: SchemaVersion
    public let snapshots: [SchemaVersion: SchemaSnapshot]
    public let migrations: [any SchemaMigration]
    public static let production: SchemaCatalog          // current=.v2；snapshots=[v1,v2]；migrations=[MigrationV1ToV2()]
    public func snapshot(_ v: SchemaVersion) throws -> SchemaSnapshot
    public var currentSnapshot: SchemaSnapshot
    /// 线性校验：缺步/跳号/重复 (from,to)/环路 → throw .migration（可在构造期与测试期跑）
    public func plan(from: SchemaVersion) throws -> [any SchemaMigration]
}

public struct SchemaMigrator: Sendable {
    let catalog: SchemaCatalog
    func migrate(_ connection: DBConnection, from: SchemaVersion, path: String) throws -> SchemaVersion
}
```

`Schema.swift`（`:10-19`）：`currentSchemaVersion` 改为 **字面量 2**（`check-docs.sh:134` 的正则要求 `currentSchemaVersion = <n>`，不能写表达式），保留 `:12` 的"不要写类型标注"注释纪律。

`Database.Options`（`:57-80`）追加三个带默认值的字段，现有 `Options(...)` 调用点不受影响：

```swift
public var resetPolicy: ResetPolicy = .failClosed          // .failClosed | .renameToIncompatible
public var retainMigrationBackups: Int = 3
public var catalog: SchemaCatalog = .production
public enum ResetPolicy: Sendable {
    case failClosed, renameToIncompatible
    var allowsReset: Bool { self == .renameToIncompatible }
}
```

`Database` 新增只读观测面（启动日志与测试断言用）：

```swift
public enum OpenOutcome: Sendable, Equatable {
    case created(SchemaVersion)
    case opened(SchemaVersion)
    case migrated(from: SchemaVersion, to: SchemaVersion, backup: String?)
    case reset(reason: ResetReason, previousVersion: Int?, backup: String)
}
public let outcome: OpenOutcome        // init 时写入；AppBootstrap 打一条 open_outcome 日志
```

`DatabaseError`（`DatabaseError.swift:24-40`）新增两 case + `Kind` 两项（`:42-58` 的 `kind` switch 同步）：

```swift
case migration(String)           // 迁移失败（已回滚；库仍为旧版本）
case versionUnsupported(String)  // 库比本构建新（fail closed，不改文件）
```

`DBConnection.transaction`（`DB.swift:337`）加 `mode` 参数（见 §4.4）。

**新增 5 个稳定日志 key**（便于日志断言）：`schema_migrate_begin`、`schema_migrate_ok`、`schema_migrate_failed`、`schema_version_unsupported`、`schema_reset_dev`；沿用 `schema_reset`（`:614`）与 `schema_shape_mismatch`（`:324`）的 `key=value` 风格。

### 5.2 测试矩阵

现有基线（静态 `@Test` 计数）：`DatabaseFacadeTests` **12**、`SchemaV1Tests` **18**、`MigrationTests` **3**、`DatabasePragmaTests` 6、`SchemaV1RowMappingTests` 6；core 全量 1084 个 `@Test`（100 文件，含参数化用例，不等于执行数）。

| ID | 场景 | 夹具 | 断言 | 落点 |
| --- | --- | --- | --- | --- |
| T1 | V1 数据保留 | `SchemaV1.createSQL` 建库 + `user_version=1` + sessions/photos/deliveries/delivery_items/person_photos/role_bindings/similarity_cluster_meta 各 1~3 行 | `outcome == .migrated(v1→v2)`；`user_version==2`；**每表行数逐一相等**；`foreign_key_check` 空；无 `.incompatible-*` | 新 `SchemaMigrationTests.swift` |
| T2 | 重复 open 幂等 | T1 迁移后的库 | 第二次 open `outcome == .opened(v2)`；不新增备份；行数不变；`plan(from:.v2).isEmpty` | 同 T1 |
| T3 | 失败回滚 | 注入 `FailingMigration`（apply 里先 `ALTER TABLE ... ADD COLUMN` 再 throw） | 抛 `.migration`；`user_version` **仍为 1**；新列不存在；行数不变；备份存在且可打开 | 同 T1（`Options(catalog:)` 注入） |
| T4 | 迁移后形态不符 | 注入"只 bump 版本、expectation 故意写错"的 catalog | 抛 `.migration`，issue 列表可读（不静默通过） | 同 T1 |
| T5 | V1 版本但缺列（Cut 5 前 370 列） | 改造 `DatabaseFacadeTests.outdatedV1ShapeIsResetWithSidecars`（`:220-271`） | 默认：抛 `.corrupt`，文件字节不变、无 `.incompatible-*`；`.renameToIncompatible`：原行为（三件套改名 + 重建） | `DatabaseFacadeTests.swift:220` |
| T6 | newer（v=99，形态正确） | 改造 `:298-321` | 默认：抛 `.versionUnsupported`，文件 **mtime/size/前 16 字节**都不变；devReset：改名保留 | `DatabaseFacadeTests.swift:298` |
| T7 | 非 SQLite 文件 | 改造 `:200-216` | 默认：抛 `.corrupt(.notADatabase)`；devReset：改名 + 重建 | `DatabaseFacadeTests.swift:200` |
| T8 | legacy：v=0 且有表 | 改造 `:145-198` | 默认：抛 `.corrupt(.legacyPreV1)`；devReset：三件套改名 + 重建 43 表 | `DatabaseFacadeTests.swift:145` |
| T9 | 备份内容有效 | T1 产生的备份 | 前 16 字节 `SQLite format 3\0`；`user_version==1`；`PRAGMA quick_check`==ok；行数与迁移前一致 | 新 `SchemaMigrationTests.swift` |
| T10 | 备份保留策略 | 连续 4 次构造"v1 旧库"并迁移 | 目录里 `.pre-v2-*` 主库恰 3 套；同秒冲突得 `-2` | 同 T1 |
| T11 | 指纹显式断言 | 内存库 `Database.openInMemory` | `SchemaShapeReader.read(conn).fingerprint == catalog.currentSnapshot.shape.fingerprint`，失败信息含 expected/actual（补 §1.3-5 的空白） | 同 T1 |
| T12 | V1 基线冻结 | `SchemaV1.createSQL` | 43 表 / 373 列 / 69 索引 / 62 外键 / `user_version==1`（现有 `SchemaV1Tests` 全部保留，证明基线没被"顺手改"） | `SchemaV1Tests.swift` 不动 |
| T13 | 版本镜像一致 | — | `SchemaSQL.currentSchemaVersion == SchemaCatalog.production.current.rawValue == 2`（改造 `MigrationTests.schemaVersionMirrorMatchesV1`，`MigrationTests.swift:88-90`） | `MigrationTests.swift` |
| T14 | 计划线性校验 | 构造缺步/跳号/重复的 catalog | `plan` 抛 `.migration`，消息点明缺哪一步 | 同 T1 |
| T15 | `gather-schema migrate-check` | 真实 V1 文件库**副本** | 输出 `from=1 to=2 tables=43 rows=<N>`，exit 0；原文件 mtime 不变 | `GatherSchema` 冒烟（P2） |

现有 reset 用例的 `Database.open(at: path)` 调用点要补 `options: Options(resetPolicy: .renameToIncompatible)`：`DatabaseFacadeTests.swift:166、209、245、312`（`:287` 是"正确库不重置"，保持默认更有价值）。

## 6. 与发布 build.sh / CI 的接口

### 6.1 环境变量契约

| 变量 | 读方 | 默认 | 说明 |
| --- | --- | --- | --- |
| `GATHER_DEV_RESET` | `AppBootstrap`（**仅 DEBUG**）→ `Options.resetPolicy` | 未设 = fail closed | 唯一允许破坏性改名的开关；release 包编译期即被 `#if DEBUG` 去掉 |
| `GATHER_SDK_VERSION` | `gather-app/Package.swift` + `build.sh:28-36` | 探测 `xcrun` | 已有，不改 |
| `GATHER_BUILD_VERSION` | `build.sh` → `plutil` | `0.0.0-dev` | 新增；tag 触发时由 workflow 注入 |
| `GATHER_BUILD_NUMBER` | 同上 | `0` | 新增；写 `CFBundleVersion` |
| `GATHER_BUILD_COMMIT` | `build.sh` → `build-info.json` | `git rev-parse --short HEAD` | 新增；排障用 |
| `CODESIGN_IDENTITY` | `build.sh:209-232` | 未设 = 不签名 | 已有 |
| `GATHER_NOTARY_PROFILE` | `build.sh`（新增） | 未设 = 跳过公证 | `notarytool --keychain-profile` |
| `ARCHS` / `UNIVERSAL` | `build.sh`（新增） | 现状 arm64 单架构 | `UNIVERSAL=1` 时双架构 |

### 6.2 build.sh 改动（逐点，行号对应当前文件）

1. **版本注入**（当前 `Info.plist:26-29` 硬编码 3.0.0，`build.sh:172` 原样 `cp`）：

```bash
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${GATHER_BUILD_VERSION:-0.0.0-dev}" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion            -string "${GATHER_BUILD_NUMBER:-0}"   "$APP_BUNDLE/Contents/Info.plist"
```

   并在 `RELEASE=1` 时对两者做 `${VAR:?}` 强制非空（避免发版打出 `0.0.0-dev`）。
2. **公证前置修正**：`:210-212` 的 `codesign --force --deep --options runtime` **缺 `--timestamp`**，这样的签名不能被 notarytool 接受。改为 `--timestamp --options runtime`；`--deep` 换成显式 nested 签名（`Contents/MacOS/Gather` → resources → 主 bundle），否则 `--deep` 会覆盖已签名子项。
3. **公证链**（新增，仅在 `GATHER_NOTARY_PROFILE` 存在时）：

```bash
ditto -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_DIR/Gather.zip"
xcrun notarytool submit "$OUTPUT_DIR/Gather.zip" --keychain-profile "$GATHER_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl -a -t exec -vvv "$APP_BUNDLE"
```

   任一步失败即 `exit 1`（与现有 entitlements 复核 `:214-229` 同级硬门）。
4. **universal**：`APP_BUILD_FLAGS+=(--arch arm64 --arch x86_64)`（SwiftPM 支持多 `--arch` 产出 universal），组装后 `lipo -archs "$APP_BUNDLE/Contents/MacOS/Gather"` 断言两架构。
5. **schema 一致性门**：组装前 `swift run --package-path "$CORE_PACKAGE" gather-schema verify --expect-version 2`，失败即退出（与 CI `:72-73` 同源，但绑到发版脚本）。
6. **bundle 元数据**：`Contents/Resources/build-info.json`（version/build/commit/schema_version=2），供"关于"与排障读取；不新增 Info.plist 键。
7. 保留 `:19-22` 的 `OUTPUT_DIR` 安全断言与 `:62-76`、`:133-147` 的本地化非空门。

### 6.3 CI

现状（`ci.yml`）：`boundary`（`:17`）、`gates`（`:28`）、`gather-core`（`:52`，含 `Schema verification` `:72-73`）、`gather-app`（`:75`）、`toolchain-compat`（`:108`）。WP6 增：

| Job | 触发 | 内容 |
| --- | --- | --- |
| `migration-smoke`（并入 gather-core） | 每次 PR | `gather-schema make-v1 <tmp>` → `sqlite3` 灌 10 行 → `gather-schema migrate-check <tmp>` → 断言 `to=2`、行数不变 |
| `release`（新 `release.yml`） | `workflow_dispatch` 或 `push: tags: ['v*']` | 全部门禁 + core/app 测试 + `gather-schema verify` + `build.sh`（注入版本、双架构、签名、公证、staple、`spctl`）+ `shasum -a 256` + 上传产物 |
| 签名密钥 | 只在 release | `CODESIGN_IDENTITY`/`GATHER_NOTARY_PROFILE` 来自 secrets；PR 不设，保持现有"未签名也能构建"（`:230-231`） |

`gather-schema` 需三个新子命令（当前只有 `dump`/`verify`，`main.swift:103-140`）：`make-v1 <path>`、`migrate-check <path>`（**在临时副本上跑**，绝不碰用户文件，延续 `main.swift:14-16` 的只读纪律）、`fingerprint`（替代 `SchemaV1.swift:78` 注释里"先让正确库 open 报出实际指纹再粘贴"的手工流程）。

### 6.4 发布前检查清单（写进 `docs/DEVELOPMENT.md`）

1. `currentSchemaVersion == 2` 且 `ADR.md:13` "当前 schema：2"（`check-docs.sh:134-158` 否则红）。
2. `gather-schema verify --expect-version 2` 通过（43 表 / 373 列 / 69 索引 / 62 外键 / 指纹）。
3. `plutil -p Gather.app/Contents/Info.plist` 显示 tag 版本。
4. `codesign -dv --verbose=4` 含 `Timestamp` 与 `Runtime Version`。
5. `stapler validate` / `spctl -a -t exec` 通过。
6. 在旧版本库副本上跑一次 `migrate-check`，确认 `.pre-v2-*` 备份存在。

## 7. 分步执行

### 7.1 WP6a 框架（2.5 人日，行为不变的纯框架）

| # | 改动 | 文件 |
| --- | --- | --- |
| a1 | `SchemaVersion`/`SchemaSnapshot`/`SchemaShapeExpectation`/`SchemaCatalog`/`SchemaMigration`/`SchemaMigrator`（`current = .v1`，`migrations = []`） | 新 `Database/Migration/*.swift`（每个 ≤300 行） |
| a2 | `readSchemaShape`/`schemaShapeIssue` 搬到 `SchemaShape.swift` | `Database.swift:365-526` |
| a3 | `inspectSchema` 改返回 `OpenState`；`open` 按 §4.6 重写；`Options` 加 3 字段；`OpenOutcome` | `Database.swift:136-342` |
| a4 | `DBConnection.transaction(_ mode:)` | `DB.swift:337-370` |
| a5 | `DatabaseError` 加 2 case + `Kind` 2 项 | `DatabaseError.swift:24-58` |
| a6 | 测试：T2/T11/T14；5 个 reset 用例补 options | `SchemaMigrationTests.swift`（新）、`DatabaseFacadeTests.swift` |

**验收**：`current == .v1` 时所有现有测试**语义不变**（reset 用例只多传一个 options）；core 全绿；`check-cleanup-ratchet` 里 `Database.swift` 行数只降不升；`check-test-catalog.sh --strict` 通过（新测试文件必须有 `//` 文件头，见脚本第 1 条检查）。
**回滚**：单 commit；`current=.v1` + 空迁移表 = 安全 revert；不 bump 任何版本常量、不动 ADR。

### 7.2 WP6b V2 迁移（1.5 人日）

| # | 改动 |
| --- | --- |
| b1 | `SchemaV2`（`ddl = SchemaV1.ddl`、`shape = SchemaV1.shape`）+ `MigrationV1ToV2`（no-op）+ `SchemaCatalog.production`：`current = .v2`、`migrations = [MigrationV1ToV2()]` |
| b2 | `SchemaV1` 拆 `ddl`（去掉末尾 `PRAGMA user_version = 1`）与 `createSQL`；`SchemaV1.sql` 保留为兼容别名（现有测试与 `gather-schema dump` 继续可用） |
| b3 | `SchemaSQL.currentSchemaVersion = 2`（字面量）；`MigrationTests` 镜像断言改到 catalog |
| b4 | `ADR.md:13`、`:86` 改"当前 schema：2"；记 D-xxx：**A 方案 + no-op V2 + 真实载荷留给 V3** |
| b5 | 测试：T1/T3/T4/T5/T6/T7/T8/T9/T10/T12/T13 |
| b6 | `gather-schema verify` 增加列数/索引/外键/指纹校验（现在只查表数与版本，`main.swift:82-94`） |

**验收**：V1 夹具库迁移后逐表行数不变；迁移失败回滚到 v1 且 `foreign_key_check` 空；重复 open 幂等；`gather-schema verify` 输出 `tables=43 columns=373 indexes=69 fks=62 user_version=2`；`check-docs.sh --strict` 通过。
**回滚**：`.v2` 改回 `.v1` 会让 v2 库变成 `.newer` → 按设计 fail closed。**因此 b6 之前必须先有 T6**，且本步骤只允许在开发机执行（尚无 1.0 用户）。

### 7.3 WP6c 发布 job（3 人日）

| # | 改动 |
| --- | --- |
| c1 | `build.sh`：版本注入、`--timestamp`、显式 nested 签名、双架构、`lipo` 断言、公证/staple/spctl、`build-info.json`、`gather-schema verify` 门 |
| c2 | `.github/workflows/release.yml`（tag + dispatch；secrets 只在 release） |
| c3 | `gather-schema make-v1` / `migrate-check` / `fingerprint` + CI `migration-smoke` |
| c4 | `docs/DEVELOPMENT.md` 发版手册 + 数据库排障；`docs/ADR.md` 记录发布环境变量契约 |
| c5 | `GATHER_DEV_RESET` 接入 `AppBootstrap.swift:146`（`#if DEBUG`），启动日志打 `open_outcome` |

**验收**：本机 `GATHER_BUILD_VERSION=1.0.0 ./desktop/native/build.sh` 产物版本正确、`lipo -archs` 双架构；有凭据时 `spctl -a -t exec` 与 `stapler validate` 通过；无凭据时脚本仍成功（与 `:230-231` 一致）并显式警告"未签名/未公证"；release workflow 在 tag 上 dry-run 一次。

### 7.4 风险

| # | 风险 | 影响 | 概率 | 缓解 |
| --- | --- | --- | --- | --- |
| R1 | 迁移不可逆 | 用户库损坏 | 中 | 备份是迁移前置条件（失败即不迁）；单事务；失败回滚并保留备份；fail closed 不自动重置 |
| R2 | deferred BEGIN 导致 `SQLITE_BUSY_SNAPSHOT` | 迁移随机失败 | 中（双实例同时打开） | 迁移一律 `.immediate`；失败按"可重试"处理（库未变） |
| R3 | 计数/指纹人工同步漂移 | 正确库被判不兼容 | 高（已发生：Cut 5 加列未 bump） | no-op V2 推迟风险；`gather-schema fingerprint` + T11 把"粘贴"变"生成" |
| R4 | 重置策略变更影响 5 个用例与开发机旧库 | 旧库从"静默重建"变"启动报错" | 确定发生 | 一次性补 options；`GATHER_DEV_RESET=1` + 文档；发版说明写清 |
| R5 | 备份占盘（`VACUUM INTO` 全量） | 磁盘满导致迁移失败 | 低 | 备份前查 `volumeAvailableCapacityForImportantUsage`，不足即抛 `.io` 并提示 |
| R6 | 大库上 `VACUUM INTO` 阻塞启动 | 首启白屏数秒 | 低-中 | 测一次真实库；必要时改两阶段"迁移 pending"（backlog，不在 WP6 做） |
| R7 | 公证无凭据 | 发布门无法在 PR 验证 | 确定 | release 仅 tag 触发；PR 只跑 build；凭据缺失显式失败而非静默跳过 |
| R8 | `--deep` 签名与新公证流程冲突 | 公证拒绝 | 中 | c1 改显式 nested 签名 + `codesign --verify --deep --strict` 复核 |
| R9 | 他人并发编辑导致验收红 | 结论不可信 | 当前已发生 | 验收前 `git status` + 单独 `swift build`；红则记录命令与失败点，不伪称通过（§8） |

### 7.5 验收命令（plan §5 原文，flags 不自创）

```bash
swift test --package-path desktop/native/gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error
./scripts/check-layering.sh && ./scripts/check-cleanup-ratchet.sh && ./scripts/check-test-catalog.sh --strict
./scripts/check-duplicate-symbols.sh --strict && ./scripts/check-docs.sh --strict && ./scripts/check-no-legacy.sh && ./scripts/check-select-star.sh --strict
swift run --package-path desktop/native/gather-core gather-schema verify
```

WP6 专属门：`gather-schema verify --expect-version 2`、`gather-schema migrate-check <v1 副本>`、`git diff --stat` 中计数常量与 ADR 版本必须一致。

## 8. 未执行 / 限制

1. **未跑测试**：`swift build --package-path desktop/native/gather-core` 失败在他人正在编辑的文件上——`GatherApplication/Services/JobService.swift:672:51: error: missing argument for parameter 'includeCheckpoint' in call`；同时 `git status` 显示 `GatherPersistence/Database/Repositories/{AnalysisJobRepo,AssetRepo,DeliverySummaryQuery,PersonRepo,PhotoRepo,SessionRepo}.swift` 已修改、`GatherPersistence/Ports/` 未跟踪，mtime 18:42–18:43 与本文采样同分钟。按并发纪律不修白名单外文件、不据此判定基线红。**测试数一律为静态 `@Test` 计数**（12 / 18 / 3），不是执行结果；也未获得 `N tests / M suites` 与 exit code。
2. 未运行 `build.sh`（会写 `release/`，超出只读范围），未验证公证链路（无凭据），未做任何视觉/手工验收。
3. 未验证 `VACUUM INTO` 在真实资料库上的耗时；未测双实例并发打开下的 `SQLITE_BUSY_SNAPSHOT` 概率（R2 属**疑似**，依据是 `DB.swift:346` 的 deferred `BEGIN` 与 WAL 语义）。
4. `ci.yml` 的 schema 门当前只覆盖 core job（`:72-73`）；release workflow 尚不存在，§6.3 是设计不是现状。
