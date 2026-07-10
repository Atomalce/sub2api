#!/usr/bin/env sh
# 一键生成生产 deploy/.env(随机密码/密钥)。已存在则拒绝覆盖。
set -e
cd "$(dirname "$0")"
if [ -f .env ]; then
  echo "deploy/.env 已存在,不覆盖。如需重新生成请先删除它。" >&2
  exit 1
fi
cat > .env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)
ADMIN_EMAIL=admin@sub2api.local
ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '=+/')
TZ=Asia/Shanghai
EOF
chmod 600 .env
echo "已生成 deploy/.env。管理员登录信息:"
grep -E '^ADMIN_' .env
