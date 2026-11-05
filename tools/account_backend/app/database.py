"""SQLAlchemy 同步引擎 + Session —— 一期 MVP 用同步即可，async 可后续切。"""
from __future__ import annotations

import sys
import os
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import settings


def _build_engine_url(raw_url: str) -> str:
    """修复 SQLite 在 Windows 上的绝对路径问题。
    
    SQLAlchemy Windows 下的 SQLite 绝对路径格式：
      ✅ sqlite:///D:/RetroEmuPouch/backend/sqlite/dev.db
      ✅ sqlite+pysqlite:///D:/RetroEmuPouch/backend/sqlite/dev.db
    （三个斜杠开头，然后是 Windows 绝对路径）
    
    如果用户写了反斜杠 D:\\RetroEmuPouch\\... 也会被修正。
    """
    if raw_url.startswith("sqlite"):
        # 检查是不是已经有盘符的绝对路径（包含 :\ 或 :/）
        import re
        match = re.match(
            r"(sqlite(?:\+\w+)?:\/\/\/?)([A-Za-z]:[\\/].+)",
            raw_url,
        )
        if match:
            prefix = match.group(1)  # sqlite:/// 或 sqlite+pysqlite:///
            drive_path = match.group(2).replace("\\", "/")  # 统一正斜杠
            # 确保 prefix 是三个斜杠
            if not prefix.endswith("///"):
                prefix = prefix.rstrip("/") + "/"
            fixed = prefix + drive_path
            # 确保目录存在
            db_dir = Path(drive_path).parent
            db_dir.mkdir(parents=True, exist_ok=True)
            return fixed
        # 相对路径也转绝对（基于项目目录）
        if raw_url.startswith("sqlite:///") and not re.match(r"sqlite:\/\/\/[A-Za-z]:", raw_url):
            rel = raw_url[len("sqlite:///"):]
            abs_path = (Path.cwd() / rel).resolve()
            abs_path.parent.mkdir(parents=True, exist_ok=True)
            return f"sqlite:///{abs_path.as_posix()}"
    return raw_url


engine_url = _build_engine_url(settings.DATABASE_URL)
# 绝不能把明文数据库密码打进日志（部署脚本的 stdout、docker logs 都会留存）
_safe_url = make_url(engine_url).render_as_string(hide_password=True)
print(f"[database] Engine URL: {_safe_url}", file=sys.stderr)

engine = create_engine(
    engine_url,
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20,
    future=True,
    connect_args={"check_same_thread": False} if engine_url.startswith("sqlite") else {},
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, expire_on_commit=False)


class Base(DeclarativeBase):
    """所有 ORM model 的基类。"""


def get_db():
    """FastAPI Depends —— 请求级 Session 生命周期。"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
