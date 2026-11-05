-- =================================================================
-- 首次启动 DB 时执行（PostgreSQL 官方镜像会自动把 *.sql 交给 psql）
-- 注意：这里必须是纯 SQL，不能写 psql <<-EOSQL heredoc / echo 等 shell 语法，
-- 否则会报 "syntax error at or near #" 且容器初始化失败。
-- =================================================================

-- 启用 pgcrypto（gen_random_uuid() 生成 UUID 用）
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 额外的优化（下次启动生效）
ALTER SYSTEM SET max_connections = '200';
