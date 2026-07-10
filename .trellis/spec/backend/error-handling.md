# Error Handling

> sub2api 后端错误处理规范。内部项目精简版。

---

## Overview

后端错误处理分三层,错误只向上传递、在 handler 层统一转 HTTP 响应:

```
repository  →  translatePersistenceError() 把 ent/pq 错误翻译成 service 哨兵错误
service     →  只返回 *infraerrors.ApplicationError(或用 %w 包装后上抛)
handler     →  response.ErrorFrom(c, err) 统一转 JSON 响应
```

两套响应体系,不要混用:

- **管理/用户 API**(`/api/v1/...`):统一 envelope,走 `internal/pkg/response`。
- **网关转发 API**(`/v1/messages`、`/v1/chat/completions` 等):按上游协议格式返回错误(Anthropic / OpenAI / Google 各自的 error JSON),走各 handler 的 `errorResponse`。

核心错误包:`backend/internal/pkg/errors`(项目内约定 import 别名 `infraerrors`)。

---

## Error Types

### ApplicationError(唯一业务错误类型)

定义在 `backend/internal/pkg/errors/errors.go`:

```go
type Status struct {
    Code     int32             `json:"code"`     // HTTP 状态码 (400/401/403/404/409/429/500/503...)
    Reason   string            `json:"reason"`   // 机器可读错误码, UPPER_SNAKE_CASE
    Message  string            `json:"message"`  // 人类可读描述
    Metadata map[string]string `json:"metadata"` // 可选附加信息
}

type ApplicationError struct {
    Status
    cause error // 底层原因, 通过 Unwrap() 暴露
}
```

- `Code` 直接就是 HTTP 状态码,不另设业务码空间。
- `Is()` 按 `Code + Reason` 匹配,因此哨兵错误可用 `errors.Is` 判断。
- `FromError(err)` 支持 wrapped error;无法识别的错误统一落到 500 + `"internal error"`。

### 构造方式

优先用 `backend/internal/pkg/errors/types.go` 里的语义构造器:
`BadRequest / Unauthorized / Forbidden / NotFound / Conflict / TooManyRequests / InternalServer / ServiceUnavailable / GatewayTimeout / ClientClosed(499)`,以及对应的 `IsXxx(err)` 判断函数。

非常规状态码用 `New / Newf`:

```go
// backend/internal/service/admin_service.go
var ErrRPMStatusUnavailable = infraerrors.New(http.StatusNotImplemented,
    "RPM_STATUS_UNAVAILABLE", "RPM cache not available")
```

### 哨兵错误(sentinel)

可复用的业务错误在 service 文件顶部以 `var Err...` 定义,`Reason` 用 UPPER_SNAKE_CASE:

```go
// backend/internal/service/account_service.go
var (
    ErrAccountNotFound      = infraerrors.NotFound("ACCOUNT_NOT_FOUND", "account not found")
    ErrAccountNilInput      = infraerrors.BadRequest("ACCOUNT_NIL_INPUT", "account input cannot be nil")
    ErrAccountNotInFallback = infraerrors.BadRequest("ACCOUNT_NOT_IN_FALLBACK", "account is not in proxy fallback state")
)
```

一次性错误直接在返回点内联构造(见 `backend/internal/service/ops_errors.go`):

```go
return nil, infraerrors.BadRequest("OPS_TIME_RANGE_INVALID", "start_time must be <= end_time")
```

---

## Wrapping & Propagation

- **附加底层原因**:用 `WithCause`(内部会 Clone,不会污染哨兵),cause 不会出现在 HTTP 响应里,只用于日志/调试:

  ```go
  // backend/internal/service/admin_user.go
  return nil, infraerrors.InternalServer("ADMIN_AUTH_IDENTITY_BIND_TX_FAILED",
      "failed to start auth identity bind transaction").WithCause(err)
  ```

- **纯内部上下文包装**:service 内部逐层上抛用 `fmt.Errorf("动作: %w", err)`,`FromError` 能穿透 `%w` 链找到 ApplicationError:

  ```go
  // backend/internal/service/account_service.go
  return nil, fmt.Errorf("create account: %w", err)
  ```

- **判断错误类别**:用 `infraerrors.IsNotFound(err)` / `infraerrors.Reason(err)` / `errors.Is(err, service.ErrXxx)`,不要字符串匹配 `err.Error()`。

### Repository 层翻译

数据库细节不允许泄露到 service 层。统一走 `backend/internal/repository/error_translate.go`:

```go
// translatePersistenceError(err, notFound, conflict)
// - sql.ErrNoRows / ent.IsNotFound  → notFound.WithCause(err)
// - pq 错误码 23505(唯一约束冲突)  → conflict.WithCause(err)
// - 其它                             → 原样返回
return translatePersistenceError(err, nil, service.ErrAPIKeyExists)
```

简单查询也可以直接判断(见 `backend/internal/repository/api_key_repo.go`):

```go
if dbent.IsNotFound(err) {
    return nil, service.ErrAPIKeyNotFound
}
```

---

## API Error Responses(管理/用户 API)

统一 envelope 定义在 `backend/internal/pkg/response/response.go`:

```json
// 成功: {"code": 0, "message": "success", "data": {...}}
// 失败: {"code": 404, "message": "account not found", "reason": "ACCOUNT_NOT_FOUND", "metadata": {...}}
```

失败响应的 `code` 与 HTTP 状态码一致,由 `infraerrors.ToHTTP`(`backend/internal/pkg/errors/http.go`)从 ApplicationError 转换。

handler 标准写法(见 `backend/internal/handler/api_key_handler.go`):

```go
// 参数解析/绑定失败 → handler 层自己给 400
keyID, err := strconv.ParseInt(c.Param("id"), 10, 64)
if err != nil {
    response.BadRequest(c, "Invalid key ID")
    return
}

// service 返回的错误 → 一律 ErrorFrom, 不要自己挑状态码
key, err := h.apiKeyService.GetByID(c.Request.Context(), keyID)
if err != nil {
    response.ErrorFrom(c, err)
    return
}
```

`response.ErrorFrom` 会对 5xx 错误自动打日志(经 `logredact.RedactText` 脱敏),handler 不需要重复 log。

Panic 兜底:`backend/internal/server/middleware/recovery.go` 把 panic 转成同一 envelope 的 500 `"internal error"`(broken pipe 除外,不写响应)。

---

## Gateway Error Responses(转发 API)

网关端点必须返回客户端 SDK 能识别的协议原生格式,不用 envelope:

```go
// Anthropic 格式 — backend/internal/handler/gateway_handler.go: errorResponse
c.JSON(status, gin.H{"type": "error", "error": gin.H{"type": errType, "message": message}})

// OpenAI 格式 — backend/internal/handler/openai_gateway_handler.go: errorResponse
c.JSON(status, gin.H{"error": gin.H{"type": errType, "message": message}})

// Google 格式 — backend/internal/server/middleware/middleware.go: GoogleErrorWriter
c.JSON(status, gin.H{"error": gin.H{"code": status, "message": message, "status": googleStatus}})
```

`errType` 取协议标准值:`invalid_request_error` / `authentication_error` / `permission_error` / `rate_limit_error` / `api_error`。

并发/限流错误的映射集中在 `backend/internal/handler/concurrency_error_response.go`:队列满与并发超限 → 429 `rate_limit_error`;`context.Canceled` → 499;其它 → 503。

中间件写网关错误时通过 `GatewayErrorWriter` 函数类型注入对应协议的 writer,不要在中间件里硬编码某一种格式。

---

## Reason Code Conventions

- 格式:`UPPER_SNAKE_CASE`,`模块前缀 + 语义`,如 `OPS_FILTER_REQUIRED`、`SPARK_SHADOW_ALREADY_EXISTS`、`INVALID_CREDENTIALS`。
- Reason 是对外契约:前端和测试按 Reason 断言(如 `infraerrors.Reason(err)` 断言 `"GROUP_NOT_ACTIVE"`,见 `backend/internal/service/admin_service_apikey_test.go`),改名视为 breaking change。
- Message 用英文小写句子,面向使用者;不含堆栈、SQL、内部路径等敏感信息。

---

## Forbidden Patterns

- **禁止** service/repository 层直接操作 `*gin.Context` 或写 HTTP 响应——转响应只发生在 handler/middleware。
- **禁止** 让 `ent.IsNotFound`、`sql.ErrNoRows`、`pq.Error` 越过 repository 层——必须先翻译成 ApplicationError。
- **禁止** 在 handler 中对 service 错误手工 `response.Error(c, 500, err.Error())`——用 `response.ErrorFrom`,否则丢失 reason/metadata 且可能泄露内部错误文本。
- **禁止** 用字符串匹配判断错误类型(`strings.Contains(err.Error(), ...)`)——用 `errors.Is` / `infraerrors.IsXxx` / `infraerrors.Reason`。仅有的例外已封装在 `sql_errors.go` / `error_translate.go` 内部。
- **禁止** 直接修改哨兵错误的字段(它们是共享指针)——需要加信息时用 `WithCause` / `WithMetadata`(内部 Clone)。
- **禁止** 网关端点返回 envelope 格式,或管理 API 返回 Anthropic/OpenAI 错误格式。
- **禁止** 把 cause / 上游原始错误体直接放进 `message` 或 `metadata` 返回给客户端;5xx 详情只进日志(且经 logredact 脱敏)。
- **禁止** 吞错(`_ = err`)后返回 nil;确属可忽略的错误必须留注释说明原因。
