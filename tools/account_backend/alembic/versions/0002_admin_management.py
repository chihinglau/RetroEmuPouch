"""admin management: users.is_active + admin_audit_logs

Revision ID: 0002_admin_management
Revises: 0001_initial
Create Date: 2026-11-04

与 app/services/schema_bootstrap.py 的运行时自愈等价；两者均幂等，
因此无论是否先跑过 alembic，升级代码后老库都能正常工作。
"""
from alembic import op
import sqlalchemy as sa


revision = "0002_admin_management"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def _tables(conn) -> set[str]:
    return set(sa.inspect(conn).get_table_names())


def _columns(conn, table: str) -> set[str]:
    return {c["name"] for c in sa.inspect(conn).get_columns(table)}


def _now():
    return sa.text("CURRENT_TIMESTAMP")


def upgrade() -> None:
    conn = op.get_bind()
    if "admin_audit_logs" not in _tables(conn):
        op.create_table(
            "admin_audit_logs",
            sa.Column("id", sa.String(36), primary_key=True),
            sa.Column("actor", sa.String(64), nullable=False, server_default="root"),
            sa.Column("action", sa.String(64), nullable=False),
            sa.Column("target_type", sa.String(32), nullable=False, server_default=""),
            sa.Column("target_id", sa.String(64), nullable=False, server_default=""),
            sa.Column("detail", sa.Text(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=_now()),
        )
        for col in ("actor", "action", "target_id", "created_at"):
            op.create_index(f"ix_admin_audit_logs_{col}", "admin_audit_logs", [col])

    if "users" in _tables(conn) and "is_active" not in _columns(conn, "users"):
        op.add_column(
            "users",
            sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        )


def downgrade() -> None:
    conn = op.get_bind()
    if "users" in _tables(conn) and "is_active" in _columns(conn, "users"):
        # batch 模式兼容 SQLite（不支持直接 DROP COLUMN 的老版本）
        with op.batch_alter_table("users") as batch:
            batch.drop_column("is_active")
    if "admin_audit_logs" in _tables(conn):
        for idx in sa.inspect(conn).get_indexes("admin_audit_logs"):
            if idx.get("name"):
                op.drop_index(idx["name"], table_name="admin_audit_logs")
        op.drop_table("admin_audit_logs")
