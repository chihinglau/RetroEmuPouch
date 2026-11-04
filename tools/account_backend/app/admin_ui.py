"""Admin Web UI —— 服务端渲染的运维后台（Jinja2）。

模块划分：
  admin_ui.py            登录 / 登出 / 运营仪表盘，并挂载各子路由
  routers/admin_ui/      用户、权益与资源、CMS 与配置等分页页面与表单动作

鉴权：登录口令（settings.ADMIN_WEB_PASSWORD）换取 admin JWT，存 HttpOnly cookie；
页面用 `Depends(ui_admin)` 校验，未登录由 main.py 的异常处理器 303 跳登录页。
底层与 `/admin` JSON API 共用同一套 service，行为一致。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy.orm import Session

from .admin_guard import COOKIE_NAME, current_admin, render, ui_admin
from .config import settings
from .database import get_db
from .routers.admin_ui import router as pages_router
from .security import create_admin_token
from .services import admin_service

router = APIRouter(prefix="/admin/ui", tags=["admin-ui"])


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request, error: str = ""):
    if current_admin(request):
        return RedirectResponse("/admin/ui/", status_code=303)
    return render("admin/login.html", request, error=error, active="login")


@router.post("/login")
def login(request: Request, password: str = Form(...)):
    if not password or password != settings.ADMIN_WEB_PASSWORD:
        return render(
            "admin/login.html", request, status_code=401,
            error="口令错误", active="login",
        )
    token = create_admin_token("root")
    resp = RedirectResponse("/admin/ui/", status_code=303)
    resp.set_cookie(COOKIE_NAME, token, httponly=True, samesite="lax", max_age=8 * 3600)
    return resp


@router.get("/logout")
def logout():
    resp = RedirectResponse("/admin/ui/login", status_code=303)
    resp.delete_cookie(COOKIE_NAME)
    return resp


@router.get("/", response_class=HTMLResponse)
def dashboard(
    request: Request,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    return render(
        "admin/dashboard.html",
        request,
        active="dashboard",
        stats=admin_service.dashboard_stats(db),
    )


# 子路由：/admin/ui/users、/admin/ui/entitlements、/admin/ui/cms 等
router.include_router(pages_router)
