"""Admin Web UI 子路由聚合（由 admin_ui.py 挂到 /admin/ui 前缀下）。"""
from fastapi import APIRouter

from . import content, operations, users

router = APIRouter()
router.include_router(users.router)
router.include_router(operations.router)
router.include_router(content.router)

__all__ = ["router"]
