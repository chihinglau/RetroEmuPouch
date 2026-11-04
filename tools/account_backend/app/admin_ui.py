"""Admin Web UI —— 服务端渲染的简易管理后台（Jinja2）。

替代纯 curl：在浏览器里管理 CMS 文档（草稿/发布）、AppConfig、查看同意统计。
鉴权：登录口令（settings.ADMIN_WEB_PASSWORD）换取 admin JWT，存于 HttpOnly cookie；
页面渲染时校验该 cookie，未登录跳登录页。底层仍复用 cms_service，与 /admin JSON API 同源。
"""
from __future__ import annotations

import os
from typing import Optional

from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from .config import settings
from .database import get_db
from .models import AppConfig
from .security import create_admin_token, decode_admin_token
from .services import cms_service

_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_TEMPLATES = Jinja2Templates(directory=os.path.join(_BASE_DIR, "templates"))

router = APIRouter(prefix="/admin/ui", tags=["admin-ui"])

_COOKIE = "admin_token"


def _current_admin(request: Request) -> Optional[str]:
    token = request.cookies.get(_COOKIE)
    if not token:
        return None
    payload = decode_admin_token(token)
    return payload.get("sub") if payload else None


def _guard(request: Request):
    """未登录则跳登录页，已登录返回 sub。"""
    sub = _current_admin(request)
    if not sub:
        return RedirectResponse("/admin/ui/login", status_code=303)
    return sub


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request, error: str = ""):
    if _current_admin(request):
        return RedirectResponse("/admin/ui/", status_code=303)
    return _TEMPLATES.TemplateResponse(
        "admin/login.html", {"request": request, "error": error}
    )


@router.post("/login")
def login(request: Request, password: str = Form(...)):
    if not password or password != settings.ADMIN_WEB_PASSWORD:
        return _TEMPLATES.TemplateResponse(
            "admin/login.html",
            {"request": request, "error": "口令错误"},
            status_code=401,
        )
    token = create_admin_token("root")
    resp = RedirectResponse("/admin/ui/", status_code=303)
    resp.set_cookie(
        _COOKIE, token, httponly=True, samesite="lax", max_age=8 * 3600
    )
    return resp


@router.get("/logout")
def logout():
    resp = RedirectResponse("/admin/ui/login", status_code=303)
    resp.delete_cookie(_COOKIE)
    return resp


@router.get("/", response_class=HTMLResponse)
def dashboard(request: Request, db: Session = Depends(get_db)):
    guard = _guard(request)
    if isinstance(guard, RedirectResponse):
        return guard
    docs = cms_service.list_all_docs(db)
    configs = db.query(AppConfig).order_by(AppConfig.config_key).all()
    privacy_stats = cms_service.consent_stats(db, "privacy_policy")
    eula_stats = cms_service.consent_stats(db, "eula")
    return _TEMPLATES.TemplateResponse(
        "admin/dashboard.html",
        {
            "request": request,
            "docs": docs,
            "configs": configs,
            "privacy_stats": privacy_stats,
            "eula_stats": eula_stats,
        },
    )


@router.post("/docs")
def create_doc(
    request: Request,
    db: Session = Depends(get_db),
    doc_key: str = Form(...),
    language: str = Form(...),
    version: int = Form(...),
    title: str = Form(...),
    content: str = Form(...),
    summary: str = Form(""),
):
    guard = _guard(request)
    if isinstance(guard, RedirectResponse):
        return guard
    cms_service.create_draft(
        db, doc_key.strip(), language.strip(), version, title.strip(), content, summary or None
    )
    return RedirectResponse("/admin/ui/", status_code=303)


@router.post("/docs/{doc_id}/publish")
def publish_doc(request: Request, doc_id: str, db: Session = Depends(get_db)):
    guard = _guard(request)
    if isinstance(guard, RedirectResponse):
        return guard
    cms_service.publish_draft(db, doc_id)
    return RedirectResponse("/admin/ui/", status_code=303)


@router.post("/config")
def update_config(
    request: Request,
    db: Session = Depends(get_db),
    config_key: str = Form(...),
    config_value: str = Form(...),
    description: str = Form(""),
):
    guard = _guard(request)
    if isinstance(guard, RedirectResponse):
        return guard
    cms_service.upsert_config(db, config_key, config_value, description or None)
    return RedirectResponse("/admin/ui/", status_code=303)
