# Fork Maintenance Guide

> Fork 二次开发与上游同步规范。内部项目精简版。

---

## Overview

本仓库是 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 的 fork(origin = Atomalce/sub2api),做二次开发并持续合并上游 main。本文档约定分支模型、上游同步流程、冲突处理规则与部署方式。

---

## Branch Model

| 分支 | 用途 | 规则 |
|------|------|------|
| `main` | 上游镜像 | **只接受 `--ff-only` 合并 upstream/main,禁止直接提交** |
| `dev` | 二开主线 | 所有自研提交在此;定期 merge main 吸收上游 |
| `feat/*` | 大功能可选 | 从 dev 切出,完成后合回 dev |

```bash
# 上游同步(标准流程)
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout dev  && git merge main    # 冲突只在这一步解决
```

---

## Conflict Playbook

合并上游时按文件类型处理,不要逐行手解生成文件:

| 文件 | 规则 |
|------|------|
| `backend/cmd/server/VERSION` | 上游 release CI 自动改,**无脑取上游** (`git checkout --theirs`) |
| `frontend/pnpm-lock.yaml` | 取上游后重跑 `pnpm install`,提交再生成的锁文件 |
| `backend/ent/*`(Ent 生成代码) | 不手解;合并后 `go generate ./ent` 重新生成并提交 |
| `backend/cmd/server/wire_gen.go` | 不手解;合并后 `go generate ./cmd/server` 重新生成 |
| `go.mod` / `go.sum` | 手解依赖行后 `go mod tidy` |

合并后必跑:`make -C backend generate && go build ./... && go test -tags=unit ./...`(backend 目录)。

---

## Fork-specific Hard Rules

- **自研代码尽量放独立文件/目录**,少改上游热点文件,直接缩小未来冲突面。
- **禁用上游 CI**:`.github/workflows/release.yml` 会尝试推 `weishaw/sub2api` 镜像并回写 VERSION,`cla.yml` 是上游 CLA——在 GitHub fork 设置里保持 Disabled。
- **不改动 VERSION 文件内容**,版本号归上游 release 管。
- `.gitignore` 忽略了 `AGENTS.md`、`CLAUDE.md`、`.claude/`、`.codex/`、`scripts/`、`docs/*`(白名单除外)——放在这些路径的本地文件不会入库,换机器需重新 `trellis init`。

---

## Deployment (云服务器)

链路:**push dev → GitHub Actions 构建镜像 → ghcr.io/atomalce/sub2api → 云服务器 pull**。

- 服务器用 `deploy/docker-compose.yml`(含 postgres + redis),image 已在 dev 分支指向 GHCR(该行与上游冲突时保留我方)。
- 首次部署:`./deploy/gen-env.sh` 一键生成 `.env`(随机 `POSTGRES_PASSWORD`/`JWT_SECRET`/`TOTP_ENCRYPTION_KEY`/管理员密码,固定密钥防止重启掉登录)。
- 服务器首次:`cd deploy && ../deploy/gen-env.sh && docker compose up -d`;更新:`docker compose pull && docker compose up -d`。

---

## Local Development Quick Reference

```bash
# 依赖(一次性)
docker run -d --name sub2api-pg -e POSTGRES_USER=sub2api -e POSTGRES_PASSWORD=sub2api \
  -e POSTGRES_DB=sub2api -p 127.0.0.1:5432:5432 postgres:18-alpine
docker run -d --name sub2api-redis -p 127.0.0.1:6379:6379 redis:8-alpine

# 后端 :8080(首次加 --setup)
cd backend && go run ./cmd/server

# 前端 :3000(代理 /api /v1 /setup → :8080)
cd frontend && pnpm install && pnpm dev
```

开发模式后端不带 `-tags embed`,`:8080` 根路径 404 "Frontend not embedded" 属正常;完整二进制用 `make -C backend build-embed`。

---

## Forbidden Patterns

- ❌ 在 `main` 上直接提交任何自研代码
- ❌ 手工编辑 `ent/`、`wire_gen.go` 解冲突(必须重新生成)
- ❌ 向上游热点文件(README、CI、VERSION)添加自研逻辑
- ❌ `git push --force` 到 `main`
