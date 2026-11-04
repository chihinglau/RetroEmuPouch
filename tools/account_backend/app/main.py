"""FastAPI 入口 —— 汇总所有 router、CORS、生命周期事件。"""
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .database import Base, engine
from .routers import (
    admin_router,
    auth_router,
    billing_router,
    cloud_router,
    cms_public_router,
    consent_router,
    legal_public_router,
    pairing_router,
)
from .admin_ui import router as admin_ui_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    import sys
    from . import models  # noqa: F401 — 触发所有 model 注册到 Base
    # 本地 dev：自动建表；生产环境由 `alembic upgrade head` 管理 schema，
    # 避免 create_all 与 Alembic 版本表冲突。
    if settings.APP_ENV != "prod":
        Base.metadata.create_all(engine)
        print(f"[main] DB tables ensured (dev). Engine: {engine.url}", file=sys.stderr)
    else:
        print(f"[main] prod mode: skipping create_all, use `alembic upgrade head`. "
              f"Engine: {engine.url}", file=sys.stderr)
    yield


app = FastAPI(
    title=settings.APP_NAME,
    version="0.2.0",
    description="RetroEmuPouch Account & Membership Backend — 独立于游戏库的公网后端",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册路由
app.include_router(auth_router)
app.include_router(billing_router)
app.include_router(pairing_router)
app.include_router(cloud_router)
app.include_router(cms_public_router)
app.include_router(consent_router)
app.include_router(admin_router)
app.include_router(admin_ui_router)
app.include_router(legal_public_router)


@app.get("/healthz")
def healthz():
    return {"ok": True, "env": settings.APP_ENV, "app": settings.APP_NAME}


@app.get("/")
def root():
    return {
        "app": settings.APP_NAME,
        "version": "0.2.0",
        "docs": "/docs",
        "healthz": "/healthz",
    }
