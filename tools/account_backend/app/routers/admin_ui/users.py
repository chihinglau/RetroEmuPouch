"""用户管理页面：搜索 / 详情 / 编辑 / 禁用 / 重置密码 / 删除 / 权益调整。"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from ...admin_guard import render, ui_admin
from ...database import get_db
from ...models import User
from ...services import admin_service, billing_service
from ._common import perform

router = APIRouter()


@router.get("/users", response_class=HTMLResponse)
def users_page(
    request: Request,
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_users(
        db, q=q, tier=tier, state=state, page=page, page_size=page_size
    )
    return render(
        "admin/users.html",
        request,
        active="users",
        data=data,
        q=q,
        tier=tier,
        state=state,
        tiers=sorted(billing_service.TIER_CHOICES),
        query=admin_service._pager_params(q=q, tier=tier, state=state),
    )


@router.get("/users/{user_id}", response_class=HTMLResponse)
def user_detail_page(
    user_id: str,
    request: Request,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    return render(
        "admin/user_detail.html",
        request,
        active="users",
        detail=admin_service.get_user_detail(db, user_id),
        tiers=sorted(billing_service.TIER_CHOICES),
    )


@router.post("/users/{user_id}/update")
def update_user(
    user_id: str,
    email: str = Form(...),
    display_name: str = Form(...),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="user.update", target_type="user", target_id=user_id,
        back=f"/admin/ui/users/{user_id}",
        fn=lambda: admin_service.update_user(
            db, user_id, email=email, display_name=display_name
        ),
        detail={"email": email.strip().lower(), "display_name": display_name.strip()},
    )


@router.post("/users/{user_id}/toggle-active")
def toggle_active(
    user_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    user = db.get(User, user_id)
    if not user:
        from fastapi import HTTPException, status
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    new_state = not user.is_active
    return perform(
        db, actor=actor,
        action="user.enable" if new_state else "user.disable",
        target_type="user", target_id=user_id,
        back=f"/admin/ui/users/{user_id}",
        fn=lambda: admin_service.set_user_active(db, user_id, new_state),
        detail={"is_active": new_state},
    )


@router.post("/users/{user_id}/reset-password")
def reset_password(
    user_id: str,
    new_password: str = Form(...),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="user.reset_password",
        target_type="user", target_id=user_id,
        back=f"/admin/ui/users/{user_id}",
        fn=lambda: admin_service.reset_password(db, user_id, new_password),
    )


@router.post("/users/{user_id}/delete")
def delete_user(
    user_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    user = db.get(User, user_id)
    email = user.email if user else user_id
    return perform(
        db, actor=actor, action="user.delete", target_type="user", target_id=user_id,
        back="/admin/ui/users",
        fn=lambda: admin_service.delete_user(db, user_id),
        detail={"email": email},
    )


@router.post("/users/{user_id}/entitlement")
def set_entitlement(
    user_id: str,
    tier: str = Form(...),
    duration_days: str = Form(""),
    expiry_at: str = Form(""),
    lifetime: str = Form(""),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    days = int(duration_days) if duration_days.strip().isdigit() else None
    expiry: datetime | None = None
    if expiry_at.strip():
        try:
            expiry = datetime.fromisoformat(expiry_at.strip())
        except ValueError:
            expiry = None
    return perform(
        db, actor=actor, action="entitlement.set",
        target_type="user", target_id=user_id,
        back=f"/admin/ui/users/{user_id}",
        fn=lambda: billing_service.set_entitlement(
            db, user_id, tier, lifetime=bool(lifetime),
            duration_days=days, expiry_at=expiry,
        ),
        detail={"tier": tier, "lifetime": bool(lifetime),
                "duration_days": days, "expiry_at": expiry_at},
    )


@router.post("/users/{user_id}/trial")
def set_trial(
    user_id: str,
    enabled: str = Form("1"),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    flag = enabled not in ("", "0", "false", "off")
    return perform(
        db, actor=actor, action="entitlement.trial",
        target_type="user", target_id=user_id,
        back=f"/admin/ui/users/{user_id}",
        fn=lambda: billing_service.set_trial(db, user_id, flag),
        detail={"enabled": flag},
    )
