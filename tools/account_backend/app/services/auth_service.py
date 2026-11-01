"""Auth service —— 注册/登录/JWT 签发。"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Tuple

from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from ..models import Entitlement, User
from ..security import create_access_token, create_refresh_token, hash_password, verify_password


def register(db: Session, email: str, password: str, display_name: str) -> User:
    existing = db.query(User).filter(User.email == email.lower()).first()
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="email_exists")

    user = User(
        id=str(uuid.uuid4()),
        email=email.lower(),
        password_hash=hash_password(password),
        display_name=display_name or "Player",
    )
    # 首次注册给空 entitlement（tier=free，等客户端触发试用或付费）
    user.entitlement = Entitlement(id=str(uuid.uuid4()), user_id=user.id, tier="free")
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def login(db: Session, email: str, password: str) -> User:
    user = db.query(User).filter(User.email == email.lower()).first()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="bad_credentials")
    return user


def issue_tokens(user: User) -> Tuple[str, str]:
    return create_access_token(sub=user.id), create_refresh_token(sub=user.id)


def refresh(db: Session, refresh_token: str) -> str:
    # 用 decode_token 验证（refresh 也是 JWT，type=refresh）
    from ..security import decode_token

    payload = decode_token(refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid_refresh")
    user_id = payload["sub"]
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="user_not_found")
    return create_access_token(sub=user.id)
