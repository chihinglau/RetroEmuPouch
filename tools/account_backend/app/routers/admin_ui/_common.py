"""后台表单动作公共工具：统一成功跳转 / 业务异常提示 / 审计落库。"""
from __future__ import annotations

from typing import Callable
from urllib.parse import quote

from fastapi import HTTPException
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from ...services import admin_service


def ok(url: str) -> RedirectResponse:
    return RedirectResponse(url, status_code=303)


def fail(url: str, exc: HTTPException) -> RedirectResponse:
    joiner = "&" if "?" in url else "?"
    return ok(f"{url}{joiner}err={quote(str(exc.detail))}")


def perform(
    db: Session,
    *,
    actor: str,
    action: str,
    back: str,
    fn: Callable[[], object],
    target_type: str = "",
    target_id: str = "",
    detail: dict | None = None,
) -> RedirectResponse:
    """执行业务动作；成功后写审计并跳回，业务异常转成页面顶部错误提示。"""
    try:
        fn()
        admin_service.log_action(
            db, actor, action, target_type, target_id, detail or {}
        )
        return ok(back)
    except HTTPException as exc:
        return fail(back, exc)
