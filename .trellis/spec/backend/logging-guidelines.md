# Logging Guidelines

> 后端日志规范。内部项目精简版。

---

## Overview

- 日志库:**zap**(`go.uber.org/zap v1.24.0`),统一封装在 `backend/internal/pkg/logger`。业务代码不直接构造 zap logger,只通过该包获取。
- 初始化只发生在 `backend/cmd/server/main.go`:先 `logger.InitBootstrap()`(配置加载前兜底),配置就绪后 `logger.Init(logger.OptionsFromConfig(cfg.Log))`。业务代码**禁止**自行 Init;运行时调级用 `logger.Reconfigure` / `logger.SetLevel`(见 `backend/internal/service/ops_log_runtime.go`)。
- 输出:stdout(warn 以上走 stderr)+ 文件(lumberjack 轮转,默认 `/app/data/logs/sub2api.log` 或 `$DATA_DIR/logs/`)。格式由 `log.format` 决定(`console`/`json`),全局自动附带 `service`、`env` 字段。
- 标准库 `log` 与 `slog` 已被桥接进 zap(见 `logger.go` 的 `bridgeStdLogLocked`/`bridgeSlogLocked`),历史代码的 `log.Printf`/`slog.Warn` 不会丢,但**新代码一律写结构化 zap 日志**。

---

## Getting a Logger

按优先级选择:

1. **请求链路内(handler/service 拿得到 ctx)**:用 `logger.FromContext(ctx)`。`middleware.RequestLogger` 已在入口注入带 `request_id`/`path`/`method` 的 request-scoped logger(`backend/internal/server/middleware/request_logger.go`):

```go
requestLogger := logger.With(
    zap.String("component", "http"),
    zap.String("request_id", requestID),
    zap.String("path", c.Request.URL.Path),
    zap.String("method", c.Request.Method),
)
ctx = logger.IntoContext(ctx, requestLogger)
```

2. **handler 层**:优先用现成的辅助函数 `requestLogger(c, component, fields...)`(`backend/internal/handler/logging.go`),它自动回退到全局 logger:

```go
func requestLogger(c *gin.Context, component string, fields ...zap.Field) *zap.Logger {
    base := logger.L()
    if c != nil && c.Request != nil {
        base = logger.FromContext(c.Request.Context())
    }
    if component != "" {
        fields = append([]zap.Field{zap.String("component", component)}, fields...)
    }
    return base.With(fields...)
}
```

3. **无请求上下文(后台任务、启动逻辑)**:用全局 `logger.L()`,并显式带 `component` 字段。真实示例(`backend/internal/handler/batch_image_handler.go`):

```go
logger.L().Warn("batch_image.mark_downloaded_failed",
    zap.String("batch_id", c.Param("id")),
    zap.Error(err),
)
```

不要用 `logger.S()`(SugaredLogger):项目现存代码零使用,保持一致。

---

## Log Levels

配置项 `log.level`,合法值 `debug`/`info`/`warn`/`error`(`backend/internal/pkg/logger/options.go` 的 `parseLevel`),默认 `info`。

| Level | 使用场景 |
|-------|---------|
| `Debug` | 开发排查细节:转发路径选择、缓存命中等。默认级别下不输出,可放心写详细内容 |
| `Info` | 正常业务事件:任务启动/完成、配置生效、请求关键节点 |
| `Warn` | 已降级/已兜底但需要关注:解析失败用了 fallback、best-effort 操作失败、上游异常已重试 |
| `Error` | 请求失败、数据丢失风险、需要人工介入的问题。默认在此级别附带 stacktrace(`log.stacktrace_level: error`) |
| `Fatal` | 仅 `main.go` 启动阶段允许(现状用 `log.Fatalf`);业务代码禁止,不得让日志库杀进程 |

---

## Structured Fields

- 字段名一律 **snake_case**。项目高频字段(保持同名,不要发明变体):
  - `component` — 代码位置,格式 `层.模块`,如 `service.gateway`、`handler.admin.usage`、`repository.account`、`http`
  - `request_id` / `client_request_id` — 请求追踪(middleware 注入)
  - `account_id`、`user_id`、`api_key_id`、`group_id`、`batch_id` — 业务实体 ID
  - `model`、`upstream_model`、`upstream_status`、`stream`、`platform`、`reason`
- 错误统一用 `zap.Error(err)`,不要 `zap.String("error", err.Error())`。
- 日志消息(msg)用**点分事件名**,小写下划线,格式 `模块.事件`,真实示例:`gateway.responses.forward_failed`、`content_moderation.check_failed`、`quota.invalid_window_resets_at_format`(`backend/internal/handler/gateway_handler.go`)。
- 多条日志共享字段时先 `.With(...)` 再打:

```go
// backend/internal/handler/gateway_handler.go
logger.L().With(
    zap.String("component", "handler.gateway.billing"),
    zap.String("raw", raw),
    zap.Error(parseErr),
).Warn("quota.invalid_window_resets_at_format")
```

---

## Sensitive Data Redaction

任何可能含凭据的内容(上游错误体、OAuth 响应、请求体片段)入日志前必须脱敏,统一用 `backend/internal/util/logredact`:

- `logredact.RedactText(s)` — 兜底文本脱敏(错误信息、非结构化内容)
- `logredact.RedactJSON(raw)` / `RedactMap(m)` — JSON/map 载荷
- 默认脱敏 key:`access_token`、`refresh_token`、`id_token`、`client_secret`、`password`、`code`、`code_verifier`、`authorization_code`;另有 `GOCSPX-*`、`AIza*` 等密钥格式的正则兜底。

真实示例(`backend/internal/service/token_refresh_service.go`):

```go
errorMsg := "Token refresh failed (non-retryable): " + logredact.RedactText(err.Error())
```

需要展示部分标识时用现成 mask 辅助函数,不要新造:`MaskEmail`(`backend/internal/service/totp_service.go`)、`maskAPIKey`(`backend/internal/handler/admin/channel_monitor_handler.go`)等。

**绝不入日志**:API Key / token 明文、密码、OAuth code、完整请求头 Authorization、用户消息正文。

---

## Legacy & Special Paths

- `logger.LegacyPrintf(component, format, args...)`:仅用于**存量** printf 风格日志的平滑迁移(现存约 880 处,如 `backend/internal/handler/admin/usage_handler.go`),它按消息内容推断级别。**新代码禁止新增**,直接写结构化 zap。
- `logger.WriteSinkEvent(...)` / `logger.SetSink(...)`:ops 系统日志入库专用(`backend/internal/service/wire.go` 注入 sink,`ops_system_log_sink.go` 消费),绕过全局级别门控。业务日志不要调用。
- `slog.*`:少数包在用(如 `backend/internal/pkg/websearch/manager.go`),经桥接进 zap 可接受,但新代码优先直接用 `logger` 包以获得统一字段。

---

## Configuration

Viper 键前缀 `log.`(默认值见 `backend/internal/config/config.go`):

```
log.level: info            log.format: console
log.caller: true           log.stacktrace_level: error
log.output.to_stdout: true log.output.to_file: true
log.rotation.max_size_mb: 100 / max_backups: 10 / max_age_days: 7 / compress: true
log.sampling.enabled: false
```

改日志行为改配置,不要在代码里硬编码级别或输出目标。

---

## Forbidden Patterns

| 禁止 | 替代 |
|------|------|
| `fmt.Println` / `fmt.Printf` 打日志(服务端路径) | `logger.L()` / `logger.FromContext(ctx)`。例外:交互式 CLI 输出(`backend/internal/setup/cli.go`、`backend/cmd/jwtgen`)不是日志,允许 |
| 新增 `log.Printf` / `logger.LegacyPrintf` | 结构化 zap 调用;桥接只为兜住存量 |
| `logger.S()`(Sugared)/ `Infof` 系列 | `zap.Field` 结构化字段 |
| token / password / API Key / Authorization 头明文入日志 | `logredact.RedactText/RedactJSON` 或 mask 辅助函数 |
| 消息里拼接变量(`"failed for user " + id`) | 固定事件名 msg + `zap.String("user_id", id)` |
| 业务代码调用 `logger.Init` / 自建 `zap.New` | 只在 `cmd/server/main.go` 初始化;调级用 `logger.Reconfigure` |
| 业务代码 `Fatal` / `panic` 代替错误日志 | `Error` + 返回 error,由上层决定 |
| 循环内高频 `Info`(如逐条记录批量项) | 降为 `Debug`,或聚合后打一条带计数字段的日志 |
