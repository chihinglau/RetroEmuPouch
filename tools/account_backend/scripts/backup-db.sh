#!/bin/bash
# =================================================================
# RetroEmuPouch Account Backend — 每日数据库备份
# 由 deploy.ps1 -Action setup 安装到 root crontab（默认 03:15 每天）
# 手动执行：/opt/retroemupouch-account/scripts/backup-db.sh
# 产物：/opt/backups/db-YYYY-MM-DD.sql.gz，保留 7 天
# =================================================================
set -euo pipefail

APP_DIR=/opt/retroemupouch-account
OUT_DIR=/opt/backups
KEEP_DAYS=7
STAMP="$(date +%F)"
OUT_FILE="$OUT_DIR/db-$STAMP.sql.gz"

mkdir -p "$OUT_DIR"

# 容器内 local 连接是 trust 认证，不需要密码；-T 供 cron/非交互使用
cd "$APP_DIR"
docker compose -f docker-compose.prod.yml exec -T db \
    pg_dump -U retroemupouch retroemupouch | gzip > "$OUT_FILE"

# 只删本脚本生成的备份，保留 7 天
find "$OUT_DIR" -name 'db-*.sql.gz' -mtime +"$KEEP_DAYS" -delete

echo "[backup] $(date '+%F %T') -> $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
