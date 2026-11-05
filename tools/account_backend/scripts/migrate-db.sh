#!/bin/bash
# =================================================================
# 本地 SQLite 迁移 SQL 的落地执行器（在 ECS 上跑）
#
# 用法：
#   scripts/migrate-db.sh <dump.sql>            # 试跑：临时库 gp_migrate_test，跑完保留供比对
#   scripts/migrate-db.sh <dump.sql> --apply    # 正式导入生产库（先 pg_dump 快照到 /opt/backups）
#   scripts/migrate-db.sh --cleanup             # 删掉临时库
#
# 生成的 SQL 由 scripts/migrate_sqlite.py 产出（已含 on conflict do nothing）。
# =================================================================
set -euo pipefail

APP_DIR=/opt/retroemupouch-account
BASE_DB=retroemupouch
TMP_DB=gp_migrate_test
COMPOSE="docker compose -f docker-compose.prod.yml"

cd "$APP_DIR"

psql_on() { # psql_on <db> [psql args...]
    local db=$1
    shift
    $COMPOSE exec -T db psql -U retroemupouch -d "$db" "$@"
}

counts() { # counts <db>
    echo "--- 行数（$1）---"
    psql_on "$1" -tA -c "select 'users='||count(*) from users"
    psql_on "$1" -tA -c "select 'entitlements='||count(*) from entitlements"
    psql_on "$1" -tA -c "select 'billing_transactions='||count(*) from billing_transactions"
    psql_on "$1" -tA -c "select 'cloud_save_blobs='||count(*) from cloud_save_blobs"
    psql_on "$1" -tA -c "select 'pc_pairings='||count(*) from pc_pairings"
    psql_on "$1" -tA -c "select 'consent_records='||count(*) from consent_records"
    psql_on "$1" -tA -c "select 'app_configs='||count(*) from app_configs"
    psql_on "$1" -tA -c "select 'cms_documents='||count(*) from cms_documents"
    psql_on "$1" -tA -c "select 'admin_audit_logs='||count(*) from admin_audit_logs"
}

if [ "${1:-}" = "--cleanup" ]; then
    psql_on postgres -c "drop database if exists $TMP_DB" >/dev/null
    echo "已删除临时库 $TMP_DB"
    exit 0
fi

# 备份恢复演练：把 .sql.gz 快照恢复进临时库，逐表比行数（只读生产，不动生产数据）
if [ "${1:-}" = "--restore-drill" ]; then
    SNAP=${2:?用法: migrate-db.sh --restore-drill /opt/backups/db-YYYY-MM-DD.sql.gz}
    [ -r "$SNAP" ] || { echo "读不到 $SNAP"; exit 1; }
    echo "== 1/3 重建临时库 $TMP_DB"
    psql_on postgres -c "drop database if exists $TMP_DB" >/dev/null
    psql_on postgres -c "create database $TMP_DB" >/dev/null
    echo "== 2/3 从快照恢复 $SNAP"
    gzip -dc "$SNAP" | $COMPOSE exec -T db psql -U retroemupouch -d "$TMP_DB" -v ON_ERROR_STOP=1 -q >/dev/null
    echo "== 3/3 生产 vs 恢复后 行数对比"
    counts "$BASE_DB"
    counts "$TMP_DB"
    echo "（核对完执行 scripts/migrate-db.sh --cleanup）"
    exit 0
fi

SQL=${1:?用法: migrate-db.sh <dump.sql> [--apply]}
MODE=${2:-dryrun}
[ -r "$SQL" ] || { echo "读不到 $SQL"; exit 1; }

if [ "$MODE" = "--apply" ]; then
    SNAP="/opt/backups/pre-migrate-$(date +%Y%m%d-%H%M).sql.gz"
    mkdir -p /opt/backups
    echo "== 1/3 生产库快照 -> $SNAP"
    $COMPOSE exec -T db pg_dump -U retroemupouch "$BASE_DB" | gzip > "$SNAP"
    du -h "$SNAP"
    echo "== 2/3 导入（ON_ERROR_STOP）"
    psql_on "$BASE_DB" -v ON_ERROR_STOP=1 -f - < "$SQL"
    echo "== 3/3 行数核对"
    counts "$BASE_DB"
    exit 0
fi

echo "== 1/4 重建临时库 $TMP_DB"
psql_on postgres -c "drop database if exists $TMP_DB" >/dev/null
psql_on postgres -c "create database $TMP_DB" >/dev/null

echo "== 2/4 临时库跑 alembic upgrade head"
# app 容器里的 DATABASE_URL 末尾就是库名，替换掉即可，不必暴露密码
$COMPOSE exec -T app sh -c 'export DATABASE_URL="${DATABASE_URL%/*}/'"$TMP_DB"'"; alembic upgrade head' 2>&1 | tail -5

echo "== 3/4 导入 SQL"
psql_on "$TMP_DB" -v ON_ERROR_STOP=1 -f - < "$SQL"

echo "== 4/4 行数核对"
counts "$TMP_DB"
echo "（比对完可执行 scripts/migrate-db.sh --cleanup 删除临时库）"
