# Database Guidelines

> sub2api 后端数据库访问规范。内部项目精简版。

---

## Overview

- **数据库**:PostgreSQL 专用(驱动 `github.com/lib/pq`,副作用导入注册于 `backend/internal/repository/ent.go`)。不支持 MySQL/SQLite。
- **ORM**:Ent。schema 定义在 `backend/ent/schema/`,生成代码在 `backend/ent/`(除 `schema/` 外不得手改)。
- **分层**:repository 接口由 service 层定义(如 `backend/internal/service/user_service.go` 的 `UserRepository interface`),`backend/internal/repository/` 实现并通过 Google Wire 注入(`backend/cmd/server/wire_gen.go`)。数据库错误必须在 repository 层翻译为业务错误,不得让 `sql.ErrNoRows`/pq 错误泄漏到 service。
- **迁移**:`backend/migrations/*.sql` 通过 `go:embed` 编译进二进制,启动时自动执行(`InitEnt`,见 `backend/internal/repository/ent.go`)。SQL 迁移文件是 schema 的唯一权威来源,**不使用 Ent auto-migrate**(代码中无 `Schema.Create` 调用)。
- **Redis**:仅作缓存层,实现在 `backend/internal/repository/*_cache.go`,不属于本文范围。

---

## ORM Usage (Ent)

### Codegen

修改 `backend/ent/schema/` 后运行 `make generate`(即 `go generate ./ent`)。生成配置见 `backend/ent/generate.go`:

```go
//go:generate go run -mod=mod entgo.io/ent/cmd/ent generate --feature sql/upsert,intercept,sql/execquery,sql/lock --idtype int64 ./schema
```

- 主键统一 `int64`;`sql/lock` 提供 `ForUpdate()`;`sql/execquery` 允许在 ent client/tx 上执行原生 SQL。
- 改 schema 必须同时新增对应 SQL 迁移文件,两者保持一致(迁移是权威,ent 只负责查询构建)。

### Mixins 与 Soft Delete

实体统一混入 `mixins.TimeMixin`(created_at/updated_at)与 `mixins.SoftDeleteMixin`(见 `backend/ent/schema/user.go`、`backend/ent/schema/mixins/soft_delete.go`):

- 软删除通过 Interceptor 对**所有查询**自动追加 `deleted_at IS NULL`;Delete 被 Hook 转为 `UPDATE ... SET deleted_at = NOW()`。
- 需要查含已删记录时用 `mixins.SkipSoftDelete(ctx)`(例:`backend/internal/repository/user_repo.go` 的 `GetByIDIncludeDeleted`)。
- 软删除实体的唯一约束用**部分唯一索引**(`WHERE deleted_at IS NULL`)实现,不在 schema 里声明 `Unique()`,见 `migrations/016_soft_delete_partial_unique_indexes.sql` 与 `ent/schema/user.go` 注释。

### Error Translation

repository 层统一用 `translatePersistenceError` / `dbent.IsNotFound` 转换错误(`backend/internal/repository/error_translate.go`):

```go
// backend/internal/repository/user_repo.go
m, err := r.client.User.Query().Where(dbuser.IDEQ(id)).Only(ctx)
if err != nil {
    return nil, translatePersistenceError(err, service.ErrUserNotFound, nil)
}
```

---

## Transactions

### 标准写法:service 开启,context 传递

service 层通过 `entClient.Tx(ctx)` 开启事务,用 `dbent.NewTxContext` 放入 context;repository 方法内部用 `clientFromContext` 自动复用同一事务。示例(`backend/internal/service/redeem_service.go`):

```go
tx, err := s.entClient.Tx(ctx)
if err != nil {
    return nil, fmt.Errorf("begin transaction: %w", err)
}
defer func() { _ = tx.Rollback() }()

txCtx := dbent.NewTxContext(ctx, tx)
if err := s.redeemRepo.Use(txCtx, redeemCode.ID, userID); err != nil { ... }
if err := s.userRepo.UpdateBalance(txCtx, userID, amount); err != nil { ... }

if err := tx.Commit(); err != nil { ... }
// 缓存失效必须放在 Commit 成功之后
```

repository 侧配合(`backend/internal/repository/error_translate.go`):

```go
func clientFromContext(ctx context.Context, defaultClient *dbent.Client) *dbent.Client {
    if tx := dbent.TxFromContext(ctx); tx != nil {
        return tx.Client()
    }
    return defaultClient
}
```

规则:

1. `defer tx.Rollback()` 必写,Commit 成功后 Rollback 是 no-op。
2. repository 自己开事务前必须先查 `dbent.TxFromContext(ctx)`,避免嵌套开启(例:`backend/internal/repository/redeem_code_repo.go` 的 `BatchUpdate`);或按 `user_repo.go Create` 的方式处理 `dbent.ErrTxStarted`。
3. 事务内只做数据库操作;HTTP 调用、发邮件、缓存失效等副作用放在 Commit 之后。

### 并发控制

- **行锁**:`ForUpdate()`(例:`backend/internal/repository/promo_code_repo.go` 的 `GetByCodeForUpdate`),必须在事务内使用。
- **优先用原子条件更新代替读-改-写**:如 `DeductBalance`(`backend/internal/repository/user_repo.go`)用 `Update().Where(dbuser.IDEQ(id), dbuser.BalanceGTE(amount)).AddBalance(-amount)`;兑换码消费用 `WHERE status = 'unused'` 乐观锁(`redeem_service.go` 注释)。
- 计数/余额增减一律用 `AddXxx()` 生成 `SET x = x + ?`,不要先查后写。

---

## Migrations

- 文件位置 `backend/migrations/NNN_description.sql`,`go:embed` 于 `backend/migrations/migrations.go`,启动时由 `applyMigrationsFS` 执行(`backend/internal/repository/migrations_runner.go`)。
- 执行机制:PostgreSQL Advisory Lock 串行化多实例迁移;`schema_migrations` 表记录 filename + SHA256 checksum;已应用的迁移跳过,**checksum 不匹配直接启动失败**。
- 命名:零填充三位数字前缀 + 下划线小写描述,如 `030_add_account_expires_at.sql`。历史上存在同号文件(如 `006_*` 两个),新迁移禁止复用已有编号。
- 内容要求:幂等(`IF NOT EXISTS` / `IF EXISTS`),普通迁移在事务中整体执行。
- **`_notx.sql` 后缀**:含 `CREATE/DROP INDEX CONCURRENTLY` 的迁移必须命名为 `NNN_xxx_notx.sql`,逐条语句非事务执行;runner 强制校验:普通迁移出现 `CONCURRENTLY` 报错,`_notx.sql` 中出现 `BEGIN/COMMIT/ROLLBACK` 报错(`migrations_runner.go`)。
- 已应用的迁移文件**永不修改**;要改 schema 就新增迁移。误改历史文件的兼容豁免走 `migrationChecksumCompatibilityRules`,仅限修复历史事故,不作为常规手段。

---

## Query Patterns

### Eager Loading(避免 N+1)

关联数据用 `With*` 一次取出,并可嵌套裁剪字段(`backend/internal/repository/api_key_repo.go` 的 `GetByKey`):

```go
m, err := r.activeQuery().
    Where(apikey.KeyEQ(key)).
    WithUser(func(q *dbent.UserQuery) {
        q.WithAllowedGroups(func(gq *dbent.GroupQuery) {
            gq.Select(group.FieldID)
        })
    }).
    WithGroup().
    Only(ctx)
```

### 批量查询

列表页需要的关联统计,用一条 `IN` / `ANY($1)` 查询构建 map,禁止循环逐条查(`backend/internal/repository/user_repo.go` 的 `GetLatestUsedAtByUserIDs`、`loadAllowedGroups`):

```go
const query = `
    SELECT user_id, MAX(created_at) AS last_used_at
    FROM usage_logs
    WHERE user_id = ANY($1)
    GROUP BY user_id
`
rows, err := r.sql.QueryContext(ctx, query, pq.Array(userIDs))
```

### 字段裁剪

只需少量字段时用 `Select()`(`api_key_repo.go` 的 `GetKeyAndOwnerID`),避免加载整实体及关联。

### Raw SQL 的边界

- 裸 SQL 仅用于 Ent 难以表达的场景:聚合统计(`backend/internal/repository/usage_log_repo_stats.go` 的 `GROUP BY` 报表)、批量原子更新(`user_repo.go` 的 `ApplyRedeemBalanceAdjustment`)、`ANY($1)` 批量查询。
- 必须走 `sqlExecutor` 接口(定义在 `backend/internal/repository/group_repo.go`)或 `clientFromContext(ctx, ...).ExecContext`,后者可透传事务。
- 一律参数化(`$1, $2`),slice 参数用 `pq.Array`。
- 单行扫描用 `scanSingleRow`(`backend/internal/repository/sql_scan.go`),不要用 `QueryRowContext`(它无法以 `ent.Tx` 作为 executor)。

### Pagination

统一用 `internal/pkg/pagination.PaginationParams`(`Offset()`/`Limit()`)+ `paginationResultFromTotal`(`backend/internal/repository/pagination.go`),不要各自发明分页结构。

---

## Naming Conventions

- 表名:复数 snake_case,通过 `entsql.Annotation{Table: "users"}` 显式指定(`backend/ent/schema/user.go`)。
- 列名:snake_case;时间列 `timestamptz`;金额列 `decimal(20,8)`(schema 中 `SchemaType` 指定)。
- 主键 `int64`;迁移文件名 `NNN_description.sql` / `NNN_description_notx.sql`。

---

## Forbidden Patterns

1. **N+1 查询**:禁止在循环里逐条查库;用 `With*` 预加载、`IDIn(...)`/`ANY($1)` 批量查询。
2. **字符串拼接 SQL**:一律 `$N` 占位符参数化;slice 用 `pq.Array`。
3. **修改已应用的迁移文件**:checksum 校验会导致所有环境启动失败;只允许新增迁移。
4. **手改 `backend/ent/` 生成代码**(`schema/` 除外):会被 `make generate` 覆盖。
5. **用 Ent auto-migrate(`Schema.Create`)**:schema 变更只能走 SQL 迁移。
6. **基于 `*sql.Tx` 手动构造 ent client**:会触发 ExecQuerier 断言错误(见 `user_repo.go Create` 注释);事务传递只用 `dbent.NewTxContext` / `TxFromContext`。
7. **读-改-写更新计数/余额**:并发下丢更新;用 `AddXxx()`、条件 `Where`、`ForUpdate()` 或原子 SQL。
8. **忘记 `defer tx.Rollback()`**,或在事务内做外部调用/缓存失效。
9. **普通迁移中使用 `CONCURRENTLY`**,或 `_notx.sql` 中出现事务控制语句(runner 会直接报错)。
10. **绕过 repository 在 handler 层直接摸数据库**:新代码的 SQL/ORM 访问一律收敛到 `backend/internal/repository/`(service 层现存少量裸 SQL 属历史遗留,不得新增)。
11. **忽略软删除语义**:不要手写 `deleted_at IS NULL`(Interceptor 已自动加);确需查已删数据时显式用 `mixins.SkipSoftDelete(ctx)` 并注明原因。
