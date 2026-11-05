#!/usr/bin/env python3
"""本地 SQLite → ECS PostgreSQL 一次性迁移工具（Phase G2/G3）。

只依赖标准库（sqlite3），不连 PostgreSQL —— 它把数据导出成可审阅的 SQL 文件，
再由 psql 在 ECS 上执行。这样：
  * 本地无需装 psycopg / 不必连生产库；
  * 迁移内容可先 diff 审阅，出问题能回滚（先在临时库试跑）。

用法：
  # 1) 看看源库有什么（表 / 列 / 行数）
  python migrate_sqlite.py inspect --sqlite D:/RetroEmuPouch/backend/sqlite/dev.db

  # 2) 导出可执行 SQL（默认跳过 seed 已有的 app_configs / cms_documents）
  python migrate_sqlite.py dump --sqlite <path> --out migrate.sql

  # 3) 高级：只导部分表
  python migrate_sqlite.py dump --sqlite <path> --out x.sql --only users,entitlements
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

# 源表 → 目标表（本地表名可能和后端模型不完全一致）
TABLE_MAP: dict[str, str] = {
    "users": "users",
    "entitlements": "entitlements",
    "billing_transactions": "billing_transactions",
    "cloud_save_blobs": "cloud_save_blobs",
    "pc_pairings": "pc_pairings",
    "consent_records": "consent_records",
    "app_configs": "app_configs",
    "cms_documents": "cms_documents",
    "admin_audit_logs": "admin_audit_logs",
}

# 依赖顺序（父表在前，满足外键）
LOAD_ORDER = [
    "users",
    "entitlements",
    "billing_transactions",
    "cloud_save_blobs",
    "pc_pairings",
    "consent_records",
    "app_configs",
    "cms_documents",
    "admin_audit_logs",
]

# seed 阶段已由 app/cli_seed.py 写入，默认不覆盖（避免重复/互相踩）
SEEDED_TABLES = {"app_configs", "cms_documents"}

# 主键列（用于 ON CONFLICT DO NOTHING 的目标）
PK = {
    "users": "id",
    "entitlements": "id",
    "billing_transactions": "id",
    "cloud_save_blobs": "id",
    "pc_pairings": "id",
    "consent_records": "id",
    "app_configs": "config_key",
    "cms_documents": "id",
    "admin_audit_logs": "id",
}

# 目标库所有主键都是 varchar（uuid/字符串），没有自增序列需要对齐
SERIAL: dict[str, str] = {}

# 目标库里本工具不写的列（由服务端/默认值负责）
SKIP_COLUMNS = {
    "users": {"is_admin"},  # 生产管理员只通过 seed / 后台授予，绝不从旧库带入
}

# SQLite 用 0/1 存布尔；显式转成 TRUE/FALSE，避免依赖 PG 的隐式转型
BOOLEAN_COLUMNS = {
    ("users", "is_active"),
    ("users", "is_admin"),
    ("entitlements", "is_lifetime"),
}


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _sql_literal(value: object) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, bytes):
        return "decode('" + value.hex() + "', 'hex')"
    text = str(value).replace("'", "''")
    return "'" + text + "'"


def connect(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise SystemExit(f"源库不存在：{path}")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def source_tables(conn: sqlite3.Connection) -> list[str]:
    rows = conn.execute(
        "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name"
    ).fetchall()
    return [r["name"] for r in rows]


def source_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    return [r["name"] for r in conn.execute(f"pragma table_info({_quote_ident(table)})")]


def source_count(conn: sqlite3.Connection, table: str) -> int:
    return int(conn.execute(f"select count(*) from {_quote_ident(table)}").fetchone()[0])


def cmd_inspect(args: argparse.Namespace) -> int:
    conn = connect(Path(args.sqlite))
    tables = source_tables(conn)
    print(f"源库：{args.sqlite}")
    print(f"表数量：{len(tables)}\n")
    total = 0
    print(f"{'源表':<24}{'目标表':<24}{'行数':>8}  列")
    print("-" * 100)
    for t in tables:
        n = source_count(conn, t)
        total += n
        target = TABLE_MAP.get(t, "（未映射，将跳过）")
        cols = ", ".join(source_columns(conn, t))
        print(f"{t:<24}{target:<24}{n:>8}  {cols}")
    print("-" * 100)
    print(f"合计 {total} 行")
    unmapped = [t for t in tables if t not in TABLE_MAP]
    if unmapped:
        print(f"\n未映射的表（会被忽略）：{', '.join(unmapped)}")
    return 0


def cmd_dump(args: argparse.Namespace) -> int:
    conn = connect(Path(args.sqlite))
    out = Path(args.out)
    tables = source_tables(conn)
    if args.only:
        wanted = {x.strip() for x in args.only.split(",") if x.strip()}
        tables = [t for t in tables if t in wanted]

    if not args.keep_seeded:
        tables = [t for t in tables if TABLE_MAP.get(t) not in SEEDED_TABLES]

    tables.sort(key=lambda t: LOAD_ORDER.index(TABLE_MAP[t]) if TABLE_MAP.get(t) in LOAD_ORDER else 99)

    lines: list[str] = []
    counts: dict[str, tuple[str, int, int]] = {}
    lines.append("-- 由 migrate_sqlite.py 生成，请先在小库试跑再上生产")
    lines.append(f"-- 生成时间：{datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(f"-- 源库：{args.sqlite}")
    lines.append("begin;")

    for t in tables:
        target = TABLE_MAP.get(t)
        if target is None:
            continue
        cols = [c for c in source_columns(conn, t) if c not in SKIP_COLUMNS.get(target, set())]
        if not cols:
            continue
        rows = conn.execute(f"select {', '.join(_quote_ident(c) for c in cols)} from {_quote_ident(t)}").fetchall()
        inserted = 0
        lines.append("")
        lines.append(f"-- {t} -> {target} （源 {len(rows)} 行）")
        col_sql = ", ".join(_quote_ident(c) for c in cols)
        pk = PK.get(target)
        for row in rows:
            vals = []
            for c in cols:
                v = row[c]
                if v is not None and (target, c) in BOOLEAN_COLUMNS:
                    vals.append("TRUE" if int(v) else "FALSE")
                else:
                    vals.append(_sql_literal(v))
            val_sql = ", ".join(vals)
            conflict = f" on conflict ({_quote_ident(pk)}) do nothing" if pk else ""
            lines.append(f"insert into {_quote_ident(target)} ({col_sql}) values ({val_sql}){conflict};")
            inserted += 1

        # 序列对齐（有自增主键的表）
        serial = SERIAL.get(target)
        if serial:
            lines.append(
                f"select setval(pg_get_serial_sequence('{target}', '{serial}'), "
                f"coalesce((select max({_quote_ident(serial)}) from {_quote_ident(target)}), 1), "
                f"coalesce((select max({_quote_ident(serial)}) from {_quote_ident(target)}), 0) > 0);"
            )
        counts[target] = (t, len(rows), inserted)

    lines.append("")
    lines.append("commit;")
    lines.append("")
    lines.append("-- 行数核对（源 / 期望写入）")
    for target, (src, n, _ins) in counts.items():
        lines.append(f"\\echo '{target}: source={src} rows={n}'")
        lines.append(f"select count(*) as {_quote_ident('n_' + target)} from {_quote_ident(target)};")

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"已写出 {out}（{len(lines)} 行 SQL）")
    print(f"{'目标表':<24}{'源表':<24}{'行数':>8}")
    for target, (src, n, _ins) in counts.items():
        print(f"{target:<24}{src:<24}{n:>8}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="本地 SQLite → PostgreSQL 迁移导出")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, fn in (("inspect", cmd_inspect), ("dump", cmd_dump)):
        p = sub.add_parser(name)
        p.add_argument("--sqlite", required=True)
        if name == "dump":
            p.add_argument("--out", required=True)
            p.add_argument("--only", default="")
            p.add_argument("--keep-seeded", action="store_true", help="连 app_configs/cms_documents 一起导入")
        p.set_defaults(func=fn)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
