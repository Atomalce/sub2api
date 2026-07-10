# Directory Structure

> sub2api 后端目录组织规范。内部项目精简版。

---

## Overview

后端是独立 Go module(`github.com/Wei-Shaw/sub2api`,根目录在 `backend/`),Gin + Ent + Wire 分层架构。

核心分层与依赖方向(依赖倒置是本项目最重要的约定):

```
cmd/server ──(Wire 组装所有 ProviderSet)──▶ internal/server ──▶ internal/handler ──▶ internal/service
                                                                                          ▲
                                                              internal/repository ───────┘ (实现 service 定义的接口)
                                                                      │
                                                                      ▼
                                                                  ent/ (生成代码) + migrations/
```

- **接口定义在 service,实现在 repository**:service 层不 import repository,repository import service 并实现其接口。
- 领域实体(如 `Account`)定义在 `internal/service/account.go`,不在独立的 domain 包里。
- 各层通过各自 `wire.go` 中的 `ProviderSet` 注册,最终在 `cmd/server/wire.go` 组装。

---

## Directory Layout

```
backend/
├── cmd/
│   ├── server/            # 入口:main.go、wire.go(wireinject)、wire_gen.go、VERSION
│   └── jwtgen/            # JWT 生成小工具
├── ent/                   # Ent 生成代码(勿手改)+ generate.go
│   └── schema/            # 手写实体 Schema(唯一允许编辑的部分)
├── migrations/            # 编号 SQL 迁移(001_init.sql...),migrations.go 用 go:embed 内嵌,启动时执行
├── internal/
│   ├── config/            # Viper 配置加载与校验,config.ProviderSet
│   ├── domain/            # 跨层共享常量(status/role/platform 等)与少量纯类型,无业务逻辑
│   ├── handler/           # HTTP handler(用户侧 + 网关转发),依赖 service
│   │   ├── admin/         # 管理端 handler
│   │   ├── dto/           # API 请求/响应结构体
│   │   └── quotaview/     # 配额展示辅助
│   ├── middleware/        # 独立的 Redis 限流中间件(rate_limiter.go)
│   ├── payment/           # 支付域:金额/费率/注册表 + provider/(stripe、alipay、wxpay、easypay、airwallex)
│   ├── pkg/               # 无业务依赖的基础库:errors、response、logger、pagination、httpclient、
│   │                      # ctxkey,以及上游协议包 claude/openai/gemini/openai_compat/googleapi/xai 等
│   ├── repository/        # 数据访问:Ent + 原生 SQL + Redis 缓存,实现 service 接口;含 migrations_runner.go
│   ├── server/            # router.go(SetupRouter)、http.go
│   │   ├── middleware/    # Gin 中间件:jwt_auth、api_key_auth、admin_auth、cors、security_headers 等
│   │   └── routes/        # 路由注册,按域拆分:admin.go、auth.go、gateway.go、payment.go、user.go、common.go
│   ├── service/           # 业务核心(最大的包):领域实体 + repository 接口定义 + 业务逻辑
│   │   ├── openai_ws_v2/  # OpenAI WebSocket 透传子模块
│   │   └── prompts/       # 内嵌 prompt 文本资源
│   ├── setup/             # 首次安装向导(CLI + HTTP 两种模式)
│   ├── testutil/          # 测试公共设施:fixtures.go、stubs.go、httptest.go
│   ├── integration/       # e2e 测试(//go:build e2e)
│   ├── util/              # 少量纯函数工具(logredact、urlvalidator 等);新基础设施优先放 internal/pkg
│   └── web/               # 前端产物内嵌:embed_on.go(go:embed all:dist)/ embed_off.go 按 build tag 切换
├── resources/model-pricing/  # 模型价格 JSON(model_prices_and_context_window.json)
├── scripts/               # 构建与测试脚本
└── Makefile               # build / generate / test / test-unit / test-integration / test-e2e
```

---

## Layer Responsibilities

### cmd/server — 组装与生命周期

只做三件事:解析 flag/版本号、调用 Wire 生成的 `initializeApplication`、优雅退出。所有 ProviderSet 在 `cmd/server/wire.go` 汇总:

```go
// backend/cmd/server/wire.go
wire.Build(
    config.ProviderSet,
    repository.ProviderSet,
    service.ProviderSet,
    payment.ProviderSet,
    middleware.ProviderSet,   // internal/server/middleware
    handler.ProviderSet,
    server.ProviderSet,
    ...
)
```

改依赖关系后必须执行 `make generate`(内部跑 `go generate ./cmd/server`)重新生成 `wire_gen.go`。

### internal/server — 路由与 Gin 中间件

`router.go` 的 `SetupRouter` 挂全局中间件并调用 `routes/` 下按域拆分的注册函数。新增路由:改 `internal/server/routes/` 对应文件(admin/auth/gateway/payment/user),不要直接在 router.go 堆 endpoint。

### internal/handler — HTTP 适配层

解析请求 → 调 service → 用 `internal/pkg/response` 写响应。API 出入参结构体放 `handler/dto/`,管理端放 `handler/admin/`。**handler 不 import repository**(现状已严格遵守,grep 可验证)。

### internal/service — 业务核心

单一扁平包(800+ 文件),按主题命名文件而非再拆子包。每个域通常有:实体定义(`account.go`)、服务(`account_service.go`)、repository 接口(定义在服务文件顶部)。接口定义示例:

```go
// backend/internal/service/account_service.go
type AccountRepository interface {
    Create(ctx context.Context, account *Account) error
    GetByID(ctx context.Context, id int64) (*Account, error)
    ...
}
```

业务错误用 `internal/pkg/errors` 构造并定义为包级变量:

```go
// backend/internal/service/account_service.go
var ErrAccountNotFound = infraerrors.NotFound("ACCOUNT_NOT_FOUND", "account not found")
```

### internal/repository — 数据访问

实现 service 接口;文件名 `xxx_repo.go`。用 Ent 做类型安全 CRUD,复杂查询(批量更新、聚合)允许原生 SQL;Redis 缓存也在这一层(`api_key_cache.go`、`billing_cache.go`)。数据库错误在此翻译为业务错误,不外泄 Ent 错误类型。

### ent/ 与 migrations/ — Schema 与迁移

- 实体改动:编辑 `ent/schema/*.go`,然后 `go generate ./ent`(feature flags 见 `ent/generate.go`:`sql/upsert,intercept,sql/execquery,sql/lock --idtype int64`)。
- **Ent 不负责建表**:所有 DDL 走 `migrations/` 下编号 SQL(PostgreSQL 语法),由 `internal/repository/migrations_runner.go` 启动时按序执行。改 schema 必须同时加迁移 SQL,编号递增不复用。

### internal/pkg 与 internal/util — 基础库

不含业务逻辑、可被任何层 import。上游平台协议(请求/响应格式、SSE 解析)放 `pkg/<platform>/`。新通用代码优先放 `internal/pkg/<topic>`,`internal/util` 只保留既有小工具。

---

## Where New Code Goes

| 要做的事 | 放哪里 |
|---|---|
| 新 REST API | `server/routes/<域>.go` 注册 + `handler/` 或 `handler/admin/` 写 handler + `handler/dto/` 定义出入参 |
| 新业务逻辑 | `service/<域>_service.go`;需要持久化则在同文件定义 repository 接口 |
| 新数据表/字段 | `ent/schema/` + `migrations/NNN_xxx.sql` + `repository/<域>_repo.go` 实现接口 |
| 新 Gin 中间件 | `server/middleware/` 并注册进其 `wire.go` |
| 新支付渠道 | `payment/provider/` 实现,`payment/registry.go` 注册 |
| 新上游平台协议 | `pkg/<platform>/` |
| 跨层常量(状态、角色、平台名) | `domain/constants.go` |
| 测试桩/夹具 | `testutil/` |

新增任何可注入类型后:在所属包 `wire.go` 的 ProviderSet 登记 → `make generate`。

---

## Naming Conventions

- 文件名 snake_case,按角色后缀:`xxx_service.go`、`xxx_repo.go`、`xxx_handler.go`、`xxx_cache.go`。
- 测试三档,用 build tag 区分:无 tag(默认单测)、`//go:build integration`(需 PG/Redis,`make test-integration`)、`//go:build e2e`(`internal/integration/`,`make test-e2e`)。集成测试文件命名 `xxx_integration_test.go`。
- 迁移文件:`NNN_描述.sql`,三位数字前缀递增。
- 错误码常量:`SCREAMING_SNAKE`(如 `ACCOUNT_NOT_FOUND`),错误变量 `ErrXxx`。

---

## Forbidden Patterns

- **禁止 handler import repository 或 ent 的查询构造器**——handler 只能调 service。(现存少数 auth/payment 文件直接用了 ent 类型,属历史遗留,不得新增。)
- **禁止 service import repository / handler / server**——service 只依赖自己定义的接口;数据访问一律"service 定义接口 + repository 实现"。
- **禁止手改生成代码**:`ent/`(schema/ 除外)、`cmd/server/wire_gen.go`。
- **禁止绕过 migrations 改表结构**:不用 Ent auto-migration,不在代码里执行 DDL。
- **禁止在 internal/pkg、internal/util、internal/domain 中引入业务逻辑或反向 import 上层包**。
- **禁止在 service 下新建子包拆分业务域**(现状为扁平单包,例外仅限 `openai_ws_v2` 这类协议隔离模块)。
- **禁止跳过 Wire 手动 new 依赖链**:新组件必须走 ProviderSet 注入。

---

## Examples

- 标准三层落地(实体 + 接口 + 实现 + handler):`internal/service/account.go` / `internal/service/account_service.go` / `internal/repository/account_repo.go` / `internal/handler/admin/account_handler.go`
- 路由注册:`internal/server/routes/admin.go`
- 带缓存的 repository:`internal/repository/api_key_cache.go`
- 可插拔 provider 模式:`internal/payment/provider/factory.go`
