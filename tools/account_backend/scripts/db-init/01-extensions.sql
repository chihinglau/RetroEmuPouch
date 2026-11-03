# =================================================================
# 首次启动 DB 时执行（PostgreSQL 初始化）
# =================================================================

# 启用 pgcrypto（生成 UUID 用）
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
    -- 额外的优化（可选）
    ALTER SYSTEM SET max_connections = '200';
EOSQL

echo "✅ PostgreSQL 初始化完成"
