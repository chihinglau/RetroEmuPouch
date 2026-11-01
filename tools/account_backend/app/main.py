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
    pairing_router,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 启动时自动建表（首次部署 / 迁移前）
    # 生产上请走 alembic upgrade head
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
