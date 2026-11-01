from fastapi import APIRouter, Depends, Request, status
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import get_current_user, get_current_user_optional
from ..models import User
from ..schemas.auth import *
from ..services import auth_service

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(req: RegisterRequest, db: Session = Depends(get_db)):
    user = auth_service.register(db, req.email, req.password, req.display_name)
    access, refresh = auth_service.issue_tokens(user)
    return TokenResponse(access_token=access, refresh_token=refresh)


@router.post("/login", response_model=TokenResponse)
def login(req: LoginRequest, db: Session = Depends(get_db)):
    user = auth_service.login(db, req.email, req.password)
    access, refresh = auth_service.issue_tokens(user)
    return TokenResponse(access_token=access, refresh_token=refresh)


@router.post("/refresh")
def refresh(req: RefreshRequest, db: Session = Depends(get_db)):
    new_access = auth_service.refresh(db, req.refresh_token)
    return {"access_token": new_access, "token_type": "bearer"}


@router.get("/me", response_model=MeResponse)
def me(current_user: User = Depends(get_current_user)):
    return MeResponse(
        user_id=current_user.id,
        email=current_user.email,
        display_name=current_user.display_name,
        trial_start=current_user.trial_start.isoformat() if current_user.trial_start else None,
        is_admin=current_user.is_admin,
    )


@router.post("/logout")
def logout():
    """无服务端黑名单 —— 客户端清本地 token 即可。"""
    return {"ok": True}


@router.post("/change-password")
def change_password(
    req: ChangePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    auth_service.change_password(db, current_user.id, req.old_password, req.new_password)
    return {"ok": True}


@router.delete("/me")
def delete_account(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """注销账号：级联删除 entitlement / pairings / 云存档 / 同意记录（见 User.relationship）。"""
    auth_service.delete_user(db, current_user.id)
    return {"ok": True}
