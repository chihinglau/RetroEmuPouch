"""FastAPI Depends —— get_current_user / require_entitlement / require_admin。"""
from __future__ import annotations

from typing import Optional

from fastapi import Depends, HTTPException, Request, status
from jose import JWTError
from sqlalchemy.orm import Session

from .database import get_db
from .models import Entitlement, User
from .security import decode_admin_token, decode_token


def _extract_bearer(request: Request) -> Optional[str]:
    auth = request.headers.get("Authorization")
    if auth and auth.startswith("Bearer "):
        return auth[7:]
    return None


async def get_current_user(
    request: Request,
    db: Session = Depends(get_db),
) -> User:
    token = _extract_bearer(request)
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing token")
    payload = decode_token(token)
    if not payload or payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid token")
    user_id = payload.get("sub")
    user = db.get(User, user_id) if user_id else None
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="user not found")
    return user


async def get_current_user_optional(
    request: Request,
    db: Session = Depends(get_db),
) -> Optional[User]:
    """无 token 也能过，返回 None。"""
    token = _extract_bearer(request)
    if not token:
        return None
    payload = decode_token(token)
    if not payload or payload.get("type") != "access":
        return None
    user_id = payload.get("sub")
    return db.get(User, user_id) if user_id else None


async def require_admin(request: Request) -> str:
    """Admin 端点 —— 用独立 ADMIN_TOKEN_SECRET 签发。"""
    token = _extract_bearer(request)
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing admin token")
    payload = decode_admin_token(token)
    if not payload:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="admin required")
    return payload["sub"]


async def require_cloud_save_entitlement(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """云存档端点 —— 必须 cloudSaveEnabled=True。"""
    ent = db.query(Entitlement).filter(Entitlement.user_id == current_user.id).first()
    if not ent or not ent.cloud_save_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="cloud_save_requires_premium",
        )
    return current_user
