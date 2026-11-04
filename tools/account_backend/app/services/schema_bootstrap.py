"""运行时 schema 自愈。

`Base.metadata.create_all()` 只能建新表，不能给既有表补列。老库（0001_initial 建的表）
若没跑 alembic 就升级代码，访问 `users.is_active` / `admin_audit_logs` 会直接报错。
这里做幂等补列/补表，dev 与生产启动都会执行；正式部署仍建议 `alembic upgrade head`
（迁移脚本 0002_admin_management 与本逻辑等价）。
"""
from __future__ import annotations

import sys

from sqlalchemy import inspect, text
from sqlalchemy.engine import Engine

from ..models import AdminAuditLog


def ensure_runtime_schema(engine: Engine) -> list[str]:
    """返回实际补上的对象名列表，便于启动日志排查。"""
    applied: list[str] = []
    insp = inspect(engine)
    tables = set(insp.get_table_names())

    if "admin_audit_logs" not in tables:
        AdminAuditLog.__table__.create(bind=engine, checkfirst=True)
        applied.append("table:admin_audit_logs")

    if "users" in tables:
        cols = {c["name"] for c in insp.get_columns("users")}
        if "is_active" not in cols:
            # SQLite 用 1；PostgreSQL/MySQL 的 boolean 列不接受整数默认值，用 true
            default_sql = "1" if engine.dialect.name == "sqlite" else "true"
            with engine.begin() as conn:
                conn.execute(
                    text(
                        "ALTER TABLE users ADD COLUMN is_active BOOLEAN NOT NULL "
                        f"DEFAULT {default_sql}"
                    )
                )
            applied.append("column:users.is_active")

    if applied:
        print(f"[schema] auto-applied: {', '.join(applied)}", file=sys.stderr)
    return applied
