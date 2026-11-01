"""SQLAlchemy 同步引擎 + Session —— 一期 MVP 用同步即可，async 可后续切。"""
from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import settings

engine = create_engine(
    settings.DATABASE_URL,
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20,
    future=True,
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
