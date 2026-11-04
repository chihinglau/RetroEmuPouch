"""Admin Web UI 公共鉴权与模板对象。

`ui_admin` 作为 FastAPI 依赖使用；未登录抛 NeedLogin，由 main.py 的
exception_handler 统一 303 跳登录页（避免每个端点重复写 guard 分支）。
"""
from __future__ import annotations

import os
from typing import Optional

from fastapi import Request
from fastapi.templating import Jinja2Templates

from .security import decode_admin_token

_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = Jinja2Templates(directory=os.path.join(_BASE_DIR, "templates"))
COOKIE_NAME = "admin_token"


class NeedLogin(Exception):
    """后台页面未登录。"""


def current_admin(request: Request) -> Optional[str]:
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        return None
    payload = decode_admin_token(token)
    return payload.get("sub") if payload else None


def ui_admin(request: Request) -> str:
    sub = current_admin(request)
    if not sub:
        raise NeedLogin()
    return sub


def render(template: str, request: Request, *, status_code: int = 200, **ctx):
    """统一渲染入口，自动带上当前管理员与导航高亮所需上下文。"""
    ctx.setdefault("admin", current_admin(request) or "")
    return TEMPLATES.TemplateResponse(
        template, {"request": request, **ctx}, status_code=status_code
    )
